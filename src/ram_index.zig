//! RAM Index - O(1) entity lookup index for ArcherDB.
//!
//! Implements an Aerospike-style index-on-RAM architecture where the primary
//! index resides entirely in RAM while data records are stored on SSD.
//!
//! Key features:
//! - 64-byte IndexEntry (cache-line aligned) for optimal CPU cache efficiency
//! - Open addressing with linear probing (cache-friendly sequential access)
//! - Lock-free concurrent reads via atomic operations
//! - Single-threaded writes (VSR commit phase guarantees this)
//! - LWW (Last-Write-Wins) semantics for conflict resolution
//! - Pre-allocated capacity at startup (no runtime resize)
//!
//! Memory requirements for 1B entities:
//! - Index entry size: 64 bytes
//! - Target load factor: 0.70
//! - Required capacity: 1B / 0.70 = ~1.43B slots
//! - RAM usage: 1.43B * 64 bytes = ~91.5GB
//!
//! See specs/hybrid-memory/spec.md for full requirements.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;

const stdx = @import("stdx");
const ttl = @import("ttl.zig");

/// Maximum number of probes before giving up on lookup/insert.
/// Prevents infinite loops and bounds worst-case latency.
pub const max_probe_length: u32 = 1024;

/// Target load factor for optimal hash table performance.
/// Hash tables degrade significantly above 0.7-0.75 load factor.
pub const target_load_factor: f32 = 0.70;

/// IndexEntry - 64-byte cache-line aligned index entry.
///
/// Each entry maps an entity_id to its latest GeoEvent composite ID.
/// The structure is designed to:
/// - Fit exactly in one CPU cache line (64 bytes)
/// - Prevent false sharing between adjacent entries
/// - Enable atomic 64-byte loads/stores on x86-64 (within cache line)
///
/// Fields:
/// - entity_id: Primary key for lookup (u128 UUID)
/// - latest_id: Composite ID [S2 Cell ID (upper 64) | Timestamp (lower 64)]
/// - ttl_seconds: Time-to-live (0 = never expires)
/// - reserved: Padding for alignment
/// - padding: Reserved for future flags/tags/generations
pub const IndexEntry = extern struct {
    /// Entity UUID - primary lookup key.
    /// Zero indicates an empty slot.
    entity_id: u128 = 0,

    /// Composite ID of the latest GeoEvent for this entity.
    /// Lower 64 bits contain timestamp for LWW comparison.
    latest_id: u128 = 0,

    /// Time-to-live in seconds (0 = never expires).
    ttl_seconds: u32 = 0,

    /// Reserved padding for alignment.
    reserved: u32 = 0,

    /// Reserved for future extensions (flags, tags, dirty bits, generation).
    padding: [24]u8 = [_]u8{0} ** 24,

    /// Sentinel value for empty slots.
    pub const empty: IndexEntry = .{};

    /// Check if this entry is empty (unused slot).
    pub inline fn is_empty(self: IndexEntry) bool {
        return self.entity_id == 0;
    }

    /// Check if this entry is a tombstone (deleted entity).
    /// Tombstones have entity_id != 0 but latest_id == 0.
    pub inline fn is_tombstone(self: IndexEntry) bool {
        return self.entity_id != 0 and self.latest_id == 0;
    }

    /// Extract timestamp from latest_id for LWW comparison.
    /// Timestamp is stored in the lower 64 bits of the composite ID.
    pub inline fn timestamp(self: IndexEntry) u64 {
        return @as(u64, @truncate(self.latest_id));
    }
};

// Compile-time validation of IndexEntry layout.
comptime {
    // IndexEntry must be exactly 64 bytes (one cache line).
    assert(@sizeOf(IndexEntry) == 64);

    // IndexEntry must be at least 16-byte aligned for u128 fields.
    assert(@alignOf(IndexEntry) >= 16);

    // Verify no padding in the struct (all space accounted for).
    // 16 + 16 + 4 + 4 + 24 = 64 bytes
    assert(@sizeOf(IndexEntry) == 16 + 16 + 4 + 4 + 24);
}

/// Error codes for RAM index operations.
pub const IndexError = error{
    /// Index capacity exceeded - cannot insert new entity.
    /// Operator must provision larger capacity.
    IndexCapacityExceeded,

    /// Index degraded - probe length exceeded max_probe_length.
    /// This indicates hash collision issues requiring rebuild.
    IndexDegraded,

    /// Invalid configuration parameters.
    InvalidConfiguration,

    /// Memory allocation failed.
    OutOfMemory,
};

/// Statistics for monitoring index health.
pub const IndexStats = struct {
    /// Number of entities currently indexed.
    entry_count: u64 = 0,

    /// Total capacity (number of slots).
    capacity: u64 = 0,

    /// Number of tombstone slots.
    tombstone_count: u64 = 0,

    /// Total number of lookup operations.
    lookup_count: u64 = 0,

    /// Number of successful lookups (cache hits).
    lookup_hit_count: u64 = 0,

    /// Total number of upsert operations.
    upsert_count: u64 = 0,

    /// Cumulative probe length for all operations (for average calculation).
    total_probe_length: u64 = 0,

    /// Maximum probe length encountered.
    max_probe_length_seen: u32 = 0,

    /// Number of operations that hit the probe limit.
    probe_limit_hits: u64 = 0,

    /// Hash collision count (probes > 1).
    collision_count: u64 = 0,

    /// Number of entries removed due to TTL expiration.
    ttl_expirations: u64 = 0,

    /// Calculate current load factor.
    pub fn load_factor(self: IndexStats) f32 {
        if (self.capacity == 0) return 0.0;
        return @as(f32, @floatFromInt(self.entry_count + self.tombstone_count)) /
            @as(f32, @floatFromInt(self.capacity));
    }

    /// Calculate tombstone ratio.
    pub fn tombstone_ratio(self: IndexStats) f32 {
        const total = self.entry_count + self.tombstone_count;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.tombstone_count)) /
            @as(f32, @floatFromInt(total));
    }

    /// Calculate average probe length.
    pub fn avg_probe_length(self: IndexStats) f32 {
        const total_ops = self.lookup_count + self.upsert_count;
        if (total_ops == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_probe_length)) /
            @as(f32, @floatFromInt(total_ops));
    }

    /// Calculate memory usage in bytes.
    pub fn memory_bytes(self: IndexStats) u64 {
        return self.capacity * @sizeOf(IndexEntry);
    }
};

/// Result of a lookup operation.
pub const LookupResult = struct {
    /// The found entry, or null if not found.
    entry: ?IndexEntry,
    /// Number of probes required for this lookup.
    probe_count: u32,
};

/// Result of an upsert operation.
pub const UpsertResult = struct {
    /// True if a new entry was inserted, false if existing entry was updated.
    inserted: bool,
    /// True if the update was applied (new timestamp wins), false if ignored.
    updated: bool,
    /// Number of probes required for this upsert.
    probe_count: u32,
};

/// Result of a lookup operation with TTL checking.
pub const LookupWithTtlResult = struct {
    /// The found entry, or null if not found or expired.
    entry: ?IndexEntry,
    /// Number of probes required for this lookup.
    probe_count: u32,
    /// True if an entry was found but expired and removed.
    expired: bool,
};

/// Result of a conditional remove operation.
pub const RemoveIfMatchResult = struct {
    /// True if the entry was removed.
    removed: bool,
    /// True if the entry was found but latest_id didn't match (concurrent upsert).
    race_detected: bool,
};

// =============================================================================
// Index Degradation Detection (F2.4.9)
// =============================================================================

/// Degradation level for index health checks.
/// Per hybrid-memory/spec.md:623-775
pub const DegradationLevel = enum {
    /// Index is healthy, no action needed.
    normal,
    /// Index showing early signs of degradation, monitor closely.
    warning,
    /// Index severely degraded, immediate action required.
    critical,

    /// Convert to numeric severity (0=normal, 1=warning, 2=critical).
    pub fn severity(self: DegradationLevel) u8 {
        return switch (self) {
            .normal => 0,
            .warning => 1,
            .critical => 2,
        };
    }
};

/// Type of index degradation detected.
pub const DegradationType = enum {
    /// TYPE 1: Tombstone accumulation causing probe length increase.
    tombstone_accumulation,
    /// TYPE 2: Probe length growth due to hash collisions.
    probe_length_growth,
    /// TYPE 3: Memory fragmentation causing cache misses.
    memory_fragmentation,
    /// TYPE 4: Capacity limit approaching (high load factor).
    capacity_limit,
    /// TYPE 5: Corruption detected (invariant violation).
    corruption,
};

/// Threshold constants for degradation detection.
/// Per hybrid-memory/spec.md:639-774
pub const DegradationThresholds = struct {
    // TYPE 1: Tombstone accumulation
    pub const tombstone_warning: f32 = 0.10; // 10% tombstones
    pub const tombstone_critical: f32 = 0.30; // 30% tombstones

    // TYPE 2: Probe length (p99 approximation - using max_probe_length)
    pub const probe_length_warning: u32 = 3;
    pub const probe_length_critical: u32 = 10;

    // TYPE 3: Memory fragmentation (using latency regression proxy)
    pub const latency_regression_warning: f32 = 0.01; // 1% regression
    pub const latency_regression_critical: f32 = 0.05; // 5% regression

    // TYPE 4: Capacity limit (load factor)
    pub const load_factor_warning: f32 = 0.60; // 60% full
    pub const load_factor_critical: f32 = 0.75; // 75% full
};

/// Individual health check result.
pub const HealthCheck = struct {
    /// The type of degradation being checked.
    degradation_type: DegradationType,
    /// Current level (normal, warning, critical).
    level: DegradationLevel,
    /// Current metric value.
    current_value: f32,
    /// Threshold for warning level.
    warning_threshold: f32,
    /// Threshold for critical level.
    critical_threshold: f32,
};

/// Complete degradation status for the index.
pub const DegradationStatus = struct {
    /// Overall degradation level (worst of all checks).
    overall_level: DegradationLevel = .normal,
    /// Individual health checks.
    tombstone_check: HealthCheck,
    probe_length_check: HealthCheck,
    capacity_check: HealthCheck,
    /// Corruption flag (true if any invariant violation detected).
    corruption_detected: bool = false,
    /// Recommended action based on overall status.
    recommended_action: RecommendedAction = .none,

    pub const RecommendedAction = enum {
        /// No action needed.
        none,
        /// Monitor more closely, schedule maintenance.
        monitor,
        /// Schedule rehash/rebuild during maintenance window.
        schedule_rebuild,
        /// Immediate rebuild required.
        immediate_rebuild,
        /// Replace replica (corruption detected).
        replace_replica,
    };
};

/// Degradation detector for index health monitoring.
pub const DegradationDetector = struct {
    /// Baseline latency for regression detection (nanoseconds).
    baseline_latency_ns: u64 = 0,
    /// Last recorded latency for regression calculation.
    last_latency_ns: u64 = 0,
    /// Corruption events detected.
    corruption_count: u64 = 0,

    /// Detect tombstone accumulation level.
    pub fn detect_tombstone_level(stats: IndexStats) HealthCheck {
        const ratio = stats.tombstone_ratio();
        const level: DegradationLevel = if (ratio >= DegradationThresholds.tombstone_critical)
            .critical
        else if (ratio >= DegradationThresholds.tombstone_warning)
            .warning
        else
            .normal;

        return .{
            .degradation_type = .tombstone_accumulation,
            .level = level,
            .current_value = ratio,
            .warning_threshold = DegradationThresholds.tombstone_warning,
            .critical_threshold = DegradationThresholds.tombstone_critical,
        };
    }

    /// Detect probe length growth level.
    pub fn detect_probe_length_level(stats: IndexStats) HealthCheck {
        const max_probe = stats.max_probe_length_seen;
        const crit = DegradationThresholds.probe_length_critical;
        const warn = DegradationThresholds.probe_length_warning;
        const level: DegradationLevel = if (max_probe >= crit)
            .critical
        else if (max_probe >= warn)
            .warning
        else
            .normal;

        return .{
            .degradation_type = .probe_length_growth,
            .level = level,
            .current_value = @floatFromInt(max_probe),
            .warning_threshold = @floatFromInt(DegradationThresholds.probe_length_warning),
            .critical_threshold = @floatFromInt(DegradationThresholds.probe_length_critical),
        };
    }

    /// Detect capacity limit level.
    pub fn detect_capacity_level(stats: IndexStats) HealthCheck {
        const lf = stats.load_factor();
        const level: DegradationLevel = if (lf >= DegradationThresholds.load_factor_critical)
            .critical
        else if (lf >= DegradationThresholds.load_factor_warning)
            .warning
        else
            .normal;

        return .{
            .degradation_type = .capacity_limit,
            .level = level,
            .current_value = lf,
            .warning_threshold = DegradationThresholds.load_factor_warning,
            .critical_threshold = DegradationThresholds.load_factor_critical,
        };
    }

    /// Run all health checks and return complete status.
    pub fn check_health(self: *DegradationDetector, stats: IndexStats) DegradationStatus {
        const tombstone_check = detect_tombstone_level(stats);
        const probe_length_check = detect_probe_length_level(stats);
        const capacity_check = detect_capacity_level(stats);

        // Determine overall level (worst of all checks).
        var overall_level: DegradationLevel = .normal;
        if (self.corruption_count > 0) {
            overall_level = .critical;
        } else {
            const max_severity = @max(
                tombstone_check.level.severity(),
                @max(
                    probe_length_check.level.severity(),
                    capacity_check.level.severity(),
                ),
            );
            overall_level = switch (max_severity) {
                0 => .normal,
                1 => .warning,
                else => .critical,
            };
        }

        // Determine recommended action.
        const action: DegradationStatus.RecommendedAction = if (self.corruption_count > 0)
            .replace_replica
        else if (overall_level == .critical)
            .immediate_rebuild
        else if (overall_level == .warning)
            .schedule_rebuild
        else
            .none;

        return .{
            .overall_level = overall_level,
            .tombstone_check = tombstone_check,
            .probe_length_check = probe_length_check,
            .capacity_check = capacity_check,
            .corruption_detected = self.corruption_count > 0,
            .recommended_action = action,
        };
    }

    /// Record a corruption event.
    pub fn record_corruption(self: *DegradationDetector) void {
        self.corruption_count += 1;
    }

    /// Reset corruption counter (after rebuild).
    pub fn reset_corruption(self: *DegradationDetector) void {
        self.corruption_count = 0;
    }
};

// =============================================================================
// Graceful Degradation Strategies (F2.4.10)
// Per hybrid-memory/spec.md:777-890
// =============================================================================

/// Query queue configuration for backpressure under degradation.
pub const QueryQueueConfig = struct {
    /// Soft limit: Start applying backpressure (reject new queries).
    pub const soft_limit: u32 = 100;
    /// Hard limit: Force immediate rebuild, reject all queries.
    pub const hard_limit: u32 = 500;
    /// Normal query timeout (nanoseconds) - 1 second.
    pub const normal_timeout_ns: u64 = 1_000_000_000;
    /// Degraded query timeout (nanoseconds) - 5 seconds.
    pub const degraded_timeout_ns: u64 = 5_000_000_000;
};

/// State of the degraded mode.
pub const DegradedModeState = enum {
    /// Normal operation.
    normal,
    /// Warning level - continue normal operation, notify operator.
    warning,
    /// Critical level - degraded mode active.
    degraded,
    /// Unrecoverable - replica must stop.
    unrecoverable,
};

/// Diagnostic mode configuration.
pub const DiagnosticConfig = struct {
    /// Sample rate for diagnostic logging (0.1 = 10% of queries).
    pub const sample_rate: f32 = 0.10;
    /// Whether diagnostic logging is enabled.
    enabled: bool = false,
    /// Counter for sampling.
    query_counter: u64 = 0,
    /// Number of diagnostics logged.
    diagnostics_logged: u64 = 0,

    /// Check if this query should be logged (sampling).
    pub fn should_log(self: *DiagnosticConfig) bool {
        if (!self.enabled) return false;
        self.query_counter += 1;
        // Sample every 10th query (10%).
        if (self.query_counter % 10 == 0) {
            self.diagnostics_logged += 1;
            return true;
        }
        return false;
    }
};

/// Degraded mode manager for graceful degradation.
pub const DegradedModeManager = struct {
    /// Current degraded mode state.
    state: DegradedModeState = .normal,
    /// Timestamp when degraded mode was entered (nanoseconds).
    degraded_since_ns: u64 = 0,
    /// Current query queue depth.
    query_queue_depth: u32 = 0,
    /// Whether background rebuild is in progress.
    rebuild_in_progress: bool = false,
    /// Rebuild progress percentage (0-100).
    rebuild_percent: u8 = 0,
    /// Diagnostic mode configuration.
    diagnostics: DiagnosticConfig = .{},
    /// Cache reduction applied (true if 50% evicted).
    cache_reduced: bool = false,
    /// Queries rejected due to backpressure.
    queries_rejected: u64 = 0,

    /// Response action for a given degradation status.
    pub const Response = struct {
        /// New state to enter.
        new_state: DegradedModeState,
        /// Should log warning message.
        log_warning: bool,
        /// Should log critical message.
        log_critical: bool,
        /// Should notify operator.
        notify_operator: bool,
        /// Should page on-call.
        page_oncall: bool,
        /// Should enable diagnostic logging.
        enable_diagnostics: bool,
        /// Should reduce cache.
        reduce_cache: bool,
        /// Should start rebuild.
        start_rebuild: bool,
        /// Should stop replica (corruption).
        stop_replica: bool,
        /// Query timeout to use (nanoseconds).
        query_timeout_ns: u64,
    };

    /// Determine response actions based on degradation status.
    pub fn determine_response(status: DegradationStatus) Response {
        // Corruption - unrecoverable.
        if (status.corruption_detected) {
            return .{
                .new_state = .unrecoverable,
                .log_warning = false,
                .log_critical = true,
                .notify_operator = true,
                .page_oncall = true,
                .enable_diagnostics = true,
                .reduce_cache = false,
                .start_rebuild = false,
                .stop_replica = true,
                .query_timeout_ns = 0, // Not serving queries.
            };
        }

        switch (status.overall_level) {
            .normal => {
                return .{
                    .new_state = .normal,
                    .log_warning = false,
                    .log_critical = false,
                    .notify_operator = false,
                    .page_oncall = false,
                    .enable_diagnostics = false,
                    .reduce_cache = false,
                    .start_rebuild = false,
                    .stop_replica = false,
                    .query_timeout_ns = QueryQueueConfig.normal_timeout_ns,
                };
            },
            .warning => {
                return .{
                    .new_state = .warning,
                    .log_warning = true,
                    .log_critical = false,
                    .notify_operator = true,
                    .page_oncall = false,
                    .enable_diagnostics = false,
                    .reduce_cache = false,
                    .start_rebuild = false,
                    .stop_replica = false,
                    .query_timeout_ns = QueryQueueConfig.normal_timeout_ns,
                };
            },
            .critical => {
                return .{
                    .new_state = .degraded,
                    .log_warning = false,
                    .log_critical = true,
                    .notify_operator = true,
                    .page_oncall = true,
                    .enable_diagnostics = true,
                    .reduce_cache = true,
                    .start_rebuild = true,
                    .stop_replica = false,
                    .query_timeout_ns = QueryQueueConfig.degraded_timeout_ns,
                };
            },
        }
    }

    /// Apply response actions and update state.
    pub fn apply_response(
        self: *DegradedModeManager,
        response: Response,
        current_time_ns: u64,
    ) void {
        // Update state.
        if (self.state != response.new_state) {
            self.state = response.new_state;
            if (response.new_state == .degraded) {
                self.degraded_since_ns = current_time_ns;
            }
        }

        // Enable/disable diagnostics.
        self.diagnostics.enabled = response.enable_diagnostics;

        // Track cache reduction.
        if (response.reduce_cache and !self.cache_reduced) {
            self.cache_reduced = true;
        }

        // Track rebuild.
        if (response.start_rebuild and !self.rebuild_in_progress) {
            self.rebuild_in_progress = true;
            self.rebuild_percent = 0;
        }
    }

    /// Check if query should be accepted based on queue depth.
    pub fn should_accept_query(self: *const DegradedModeManager) bool {
        // Unrecoverable - reject all.
        if (self.state == .unrecoverable) return false;

        // Hard limit - reject all.
        if (self.query_queue_depth >= QueryQueueConfig.hard_limit) return false;

        // Soft limit in degraded mode - reject.
        if (self.state == .degraded and
            self.query_queue_depth >= QueryQueueConfig.soft_limit)
        {
            return false;
        }

        return true;
    }

    /// Record query rejection.
    pub fn record_rejection(self: *DegradedModeManager) void {
        self.queries_rejected += 1;
    }

    /// Get current query timeout.
    pub fn query_timeout(self: *const DegradedModeManager) u64 {
        return switch (self.state) {
            .normal, .warning => QueryQueueConfig.normal_timeout_ns,
            .degraded => QueryQueueConfig.degraded_timeout_ns,
            .unrecoverable => 0,
        };
    }

    /// Update rebuild progress.
    pub fn update_rebuild_progress(self: *DegradedModeManager, percent: u8) void {
        self.rebuild_percent = percent;
        if (percent >= 100) {
            self.rebuild_in_progress = false;
        }
    }

    /// Complete recovery - reset to normal state.
    pub fn complete_recovery(self: *DegradedModeManager) void {
        self.state = .normal;
        self.rebuild_in_progress = false;
        self.rebuild_percent = 0;
        self.cache_reduced = false;
        self.diagnostics.enabled = false;
    }

    /// Check if replica should stop (unrecoverable corruption).
    pub fn should_stop_replica(self: *const DegradedModeManager) bool {
        return self.state == .unrecoverable;
    }
};

// =============================================================================
// Online Rehash Procedure (F2.4.11)
// Per hybrid-memory/spec.md:900-943
// =============================================================================

/// Strategy for index rehash operation.
pub const RehashStrategy = enum {
    /// Online rehash: Copy live entries to new table while serving queries.
    online,
    /// Full rebuild: Stop writes, rebuild from LSM.
    full,
};

/// Configuration for rehash operation.
pub const RehashConfig = struct {
    /// Rehash strategy.
    strategy: RehashStrategy = .online,
    /// Maximum CPU percentage to use (0-100).
    max_cpu_percent: u8 = 50,
    /// Batch size for copying entries.
    batch_size: u32 = 10_000,
    /// New capacity (0 = same as current).
    new_capacity: u64 = 0,
};

/// State of an ongoing rehash operation.
pub const RehashState = struct {
    /// Whether rehash is in progress.
    in_progress: bool = false,
    /// Number of entries copied so far.
    entries_copied: u64 = 0,
    /// Total entries to copy.
    total_entries: u64 = 0,
    /// Tombstones skipped (not copied).
    tombstones_skipped: u64 = 0,
    /// Progress percentage (0-100).
    progress_percent: u8 = 0,
    /// Timestamp when rehash started (nanoseconds).
    started_at_ns: u64 = 0,
    /// Whether rehash completed successfully.
    completed: bool = false,
    /// Error message if failed.
    error_message: ?[]const u8 = null,

    /// Update progress percentage.
    pub fn update_progress(self: *RehashState) void {
        if (self.total_entries == 0) {
            self.progress_percent = 100;
        } else {
            const pct = (self.entries_copied * 100) / self.total_entries;
            self.progress_percent = @intCast(@min(pct, 100));
        }
    }
};

/// Result of a rehash operation.
pub const RehashResult = struct {
    /// Whether rehash succeeded.
    success: bool,
    /// Number of live entries copied.
    entries_copied: u64,
    /// Number of tombstones skipped.
    tombstones_skipped: u64,
    /// Duration in nanoseconds.
    duration_ns: u64,
    /// Old probe length p99 (before rehash).
    old_probe_length_max: u32,
    /// New probe length p99 (after rehash).
    new_probe_length_max: u32,
    /// Old tombstone ratio.
    old_tombstone_ratio: f32,
    /// New tombstone ratio (should be 0).
    new_tombstone_ratio: f32,
    /// Error message if failed.
    error_message: ?[]const u8,
};

/// Result of a background TTL scan operation.
pub const ScanExpiredResult = struct {
    /// Number of entries scanned in this batch.
    entries_scanned: u64,
    /// Number of expired entries removed.
    entries_removed: u64,
    /// Next position to scan (for incremental scanning).
    next_position: u64,
    /// True if scan wrapped around to beginning.
    wrapped: bool,
};

// ============================================================================
// F2.4.12: Recovery Metrics and Alerts
// Per hybrid-memory/spec.md:1818-1913
// ============================================================================

/// Severity levels for index health alerts.
pub const AlertSeverity = enum {
    /// Informational - no action required.
    info,
    /// Warning - monitor closely, may need action.
    warning,
    /// Critical - immediate action required.
    critical,

    /// Convert to Prometheus label value.
    pub fn toLabel(self: AlertSeverity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .critical => "critical",
        };
    }
};

/// Types of alerts that can be raised.
pub const AlertType = enum {
    /// Tombstone ratio exceeds threshold.
    tombstone_degradation,
    /// Average probe length increasing.
    probe_length_growth,
    /// P99 latency regression.
    latency_regression,
    /// Load factor approaching limit.
    capacity_limit,
    /// Data corruption detected.
    corruption_detected,
    /// Rebuild operation started.
    rebuild_in_progress,
    /// Rebuild operation completed.
    rebuild_completed,

    /// Convert to Prometheus label value.
    pub fn toLabel(self: AlertType) []const u8 {
        return switch (self) {
            .tombstone_degradation => "tombstone_degradation",
            .probe_length_growth => "probe_length_growth",
            .latency_regression => "latency_regression",
            .capacity_limit => "capacity_limit",
            .corruption_detected => "corruption_detected",
            .rebuild_in_progress => "rebuild_in_progress",
            .rebuild_completed => "rebuild_completed",
        };
    }

    /// Get recommended action for this alert type.
    pub fn recommendedAction(self: AlertType) []const u8 {
        return switch (self) {
            .tombstone_degradation => "Trigger online rehash to reclaim tombstones",
            .probe_length_growth => "Monitor closely; rehash if probe length continues to grow",
            .latency_regression => "Check system resources; consider capacity increase",
            .capacity_limit => "Urgent: increase index capacity or reduce entity count",
            .corruption_detected => "Critical: initiate full rebuild from persistent storage",
            .rebuild_in_progress => "No action needed; rebuild operation running",
            .rebuild_completed => "No action needed; rebuild finished successfully",
        };
    }
};

/// A single alert instance.
pub const Alert = struct {
    /// Type of alert.
    alert_type: AlertType,
    /// Severity level.
    severity: AlertSeverity,
    /// Current value that triggered the alert.
    current_value: f64,
    /// Threshold that was exceeded.
    threshold: f64,
    /// Timestamp when alert was generated (nanoseconds since epoch).
    timestamp_ns: u64,
    /// Human-readable message.
    message: []const u8,

    /// Format alert for logging.
    pub fn format(self: Alert, writer: anytype) !void {
        try writer.print("[{s}] {s}: {s} (value={d:.4}, threshold={d:.4})", .{
            self.severity.toLabel(),
            self.alert_type.toLabel(),
            self.message,
            self.current_value,
            self.threshold,
        });
    }
};

/// Metrics tracking for rebuild/recovery operations.
pub const RecoveryMetrics = struct {
    /// Number of rebuild operations started.
    rebuilds_started: u64 = 0,
    /// Number of rebuild operations completed successfully.
    rebuilds_completed: u64 = 0,
    /// Number of rebuild operations that failed.
    rebuilds_failed: u64 = 0,
    /// Total entries copied across all rebuilds.
    total_entries_copied: u64 = 0,
    /// Total tombstones reclaimed across all rebuilds.
    total_tombstones_reclaimed: u64 = 0,
    /// Cumulative rebuild duration in nanoseconds.
    total_rebuild_duration_ns: u64 = 0,
    /// Timestamp of last rebuild start.
    last_rebuild_start_ns: u64 = 0,
    /// Timestamp of last rebuild completion.
    last_rebuild_complete_ns: u64 = 0,
    /// Last rebuild result (for diagnostics).
    last_rebuild_success: bool = true,
    /// Number of alerts raised.
    alerts_raised: u64 = 0,
    /// Number of critical alerts raised.
    critical_alerts_raised: u64 = 0,

    /// Record the start of a rebuild operation.
    pub fn recordRebuildStart(self: *RecoveryMetrics, timestamp_ns: u64) void {
        self.rebuilds_started += 1;
        self.last_rebuild_start_ns = timestamp_ns;
    }

    /// Record successful completion of a rebuild.
    pub fn recordRebuildComplete(
        self: *RecoveryMetrics,
        timestamp_ns: u64,
        entries_copied: u64,
        tombstones_reclaimed: u64,
    ) void {
        self.rebuilds_completed += 1;
        self.last_rebuild_complete_ns = timestamp_ns;
        self.last_rebuild_success = true;
        self.total_entries_copied += entries_copied;
        self.total_tombstones_reclaimed += tombstones_reclaimed;
        if (self.last_rebuild_start_ns > 0) {
            self.total_rebuild_duration_ns += timestamp_ns - self.last_rebuild_start_ns;
        }
    }

    /// Record a failed rebuild.
    pub fn recordRebuildFailure(self: *RecoveryMetrics) void {
        self.rebuilds_failed += 1;
        self.last_rebuild_success = false;
    }

    /// Record an alert.
    pub fn recordAlert(self: *RecoveryMetrics, severity: AlertSeverity) void {
        self.alerts_raised += 1;
        if (severity == .critical) {
            self.critical_alerts_raised += 1;
        }
    }

    /// Calculate average rebuild duration.
    pub fn averageRebuildDurationNs(self: RecoveryMetrics) u64 {
        if (self.rebuilds_completed == 0) return 0;
        return self.total_rebuild_duration_ns / self.rebuilds_completed;
    }

    /// Export metrics in Prometheus text format.
    pub fn toPrometheus(self: RecoveryMetrics, writer: anytype) !void {
        try writer.print(
            \\# HELP archerdb_ram_index_rebuilds_total Total number of index rebuild operations
            \\# TYPE archerdb_ram_index_rebuilds_total counter
            \\archerdb_ram_index_rebuilds_started_total {d}
            \\archerdb_ram_index_rebuilds_completed_total {d}
            \\archerdb_ram_index_rebuilds_failed_total {d}
            \\# HELP archerdb_ram_index_rebuild_entries_total Total entries processed during rebuilds
            \\# TYPE archerdb_ram_index_rebuild_entries_total counter
            \\archerdb_ram_index_rebuild_entries_copied_total {d}
            \\archerdb_ram_index_rebuild_tombstones_reclaimed_total {d}
            \\# HELP archerdb_ram_index_rebuild_duration_ns_total Cumulative rebuild duration
            \\# TYPE archerdb_ram_index_rebuild_duration_ns_total counter
            \\archerdb_ram_index_rebuild_duration_ns_total {d}
            \\# HELP archerdb_ram_index_alerts_total Total number of alerts raised
            \\# TYPE archerdb_ram_index_alerts_total counter
            \\archerdb_ram_index_alerts_total {d}
            \\archerdb_ram_index_critical_alerts_total {d}
            \\
        , .{
            self.rebuilds_started,
            self.rebuilds_completed,
            self.rebuilds_failed,
            self.total_entries_copied,
            self.total_tombstones_reclaimed,
            self.total_rebuild_duration_ns,
            self.alerts_raised,
            self.critical_alerts_raised,
        });
    }
};

/// Alert manager for generating alerts based on index health.
pub const AlertManager = struct {
    /// Recovery metrics tracker.
    metrics: RecoveryMetrics = .{},
    /// Alert callback (optional).
    alert_callback: ?*const fn (Alert) void = null,
    /// Last alert timestamp per type (to prevent alert storms).
    last_alert_ns: [8]u64 = [_]u64{0} ** 8, // AlertType has 8 variants
    /// Minimum interval between alerts of the same type (1 minute).
    pub const min_alert_interval_ns: u64 = 60_000_000_000;

    /// Check index health and generate alerts if needed.
    /// Takes a single HealthCheck result and generates an alert if warranted.
    pub fn checkAndAlert(
        self: *AlertManager,
        health: HealthCheck,
        current_ns: u64,
    ) ?Alert {
        // Check for critical conditions first
        if (health.level == .critical) {
            return self.maybeRaiseAlert(
                health.degradation_type,
                .critical,
                health,
                current_ns,
            );
        }

        // Check for warning conditions
        if (health.level == .warning) {
            return self.maybeRaiseAlert(
                health.degradation_type,
                .warning,
                health,
                current_ns,
            );
        }

        return null;
    }

    fn maybeRaiseAlert(
        self: *AlertManager,
        degradation_type: DegradationType,
        severity: AlertSeverity,
        health: HealthCheck,
        current_ns: u64,
    ) ?Alert {
        const alert_type = degradationToAlertType(degradation_type);
        const type_index = @intFromEnum(alert_type);

        // Check if we're rate-limited (first alert always goes through)
        const last_ns = self.last_alert_ns[type_index];
        if (last_ns > 0 and current_ns < last_ns + min_alert_interval_ns) {
            return null;
        }

        // Update last alert time
        self.last_alert_ns[type_index] = current_ns;

        const alert = Alert{
            .alert_type = alert_type,
            .severity = severity,
            .current_value = health.current_value,
            .threshold = health.warning_threshold,
            .timestamp_ns = current_ns,
            .message = alert_type.recommendedAction(),
        };

        // Record in metrics
        self.metrics.recordAlert(severity);

        // Call callback if set
        if (self.alert_callback) |callback| {
            callback(alert);
        }

        return alert;
    }

    fn degradationToAlertType(degradation_type: DegradationType) AlertType {
        return switch (degradation_type) {
            .tombstone_accumulation => .tombstone_degradation,
            .probe_length_growth => .probe_length_growth,
            .memory_fragmentation => .latency_regression,
            .capacity_limit => .capacity_limit,
            .corruption => .corruption_detected,
        };
    }

    /// Raise a rebuild-started alert.
    pub fn alertRebuildStarted(self: *AlertManager, current_ns: u64) Alert {
        self.metrics.recordRebuildStart(current_ns);
        const alert = Alert{
            .alert_type = .rebuild_in_progress,
            .severity = .info,
            .current_value = 0,
            .threshold = 0,
            .timestamp_ns = current_ns,
            .message = "Index rebuild operation started",
        };
        self.metrics.recordAlert(.info);
        if (self.alert_callback) |callback| {
            callback(alert);
        }
        return alert;
    }

    /// Raise a rebuild-completed alert.
    pub fn alertRebuildCompleted(
        self: *AlertManager,
        current_ns: u64,
        entries_copied: u64,
        tombstones_reclaimed: u64,
    ) Alert {
        self.metrics.recordRebuildComplete(current_ns, entries_copied, tombstones_reclaimed);
        const alert = Alert{
            .alert_type = .rebuild_completed,
            .severity = .info,
            .current_value = @floatFromInt(entries_copied),
            .threshold = @floatFromInt(tombstones_reclaimed),
            .timestamp_ns = current_ns,
            .message = "Index rebuild operation completed successfully",
        };
        self.metrics.recordAlert(.info);
        if (self.alert_callback) |callback| {
            callback(alert);
        }
        return alert;
    }
};

/// RAM Index - O(1) entity lookup index.
///
/// Thread-safety model:
/// - Multiple concurrent readers (lookups) using lock-free atomic loads
/// - Single writer (VSR commit phase guarantees serialized writes)
/// - Read-during-write safety via atomic operations with Acquire/Release semantics
pub fn RamIndexType(comptime options: struct {
    /// Enable statistics tracking (has minor performance overhead).
    track_stats: bool = true,
}) type {
    return struct {
        // Type alias for use in return types where @This() would be ambiguous.
        const Index = @This();

        /// Pre-allocated array of index entries.
        /// Aligned to 64 bytes (cache line) to prevent false sharing.
        entries: []align(64) IndexEntry,

        /// Total number of slots (capacity).
        capacity: u64,

        /// Number of non-empty entries (including tombstones).
        /// Updated atomically for concurrent access.
        count: std.atomic.Value(u64),

        /// Statistics for monitoring (optional).
        stats: if (options.track_stats) IndexStats else void,

        /// Initialize a new RAM index with the specified capacity.
        ///
        /// The capacity should be calculated as: capacity = ceil(expected_entities / 0.7)
        /// For 1B entities: capacity = 1,428,571,429 slots (~91.5GB)
        ///
        /// Memory is pre-allocated at startup and never grows.
        pub fn init(allocator: Allocator, capacity: u64) IndexError!@This() {
            if (capacity == 0) return error.InvalidConfiguration;

            // Allocate aligned memory for entries.
            // Alignment of 64 bytes ensures each entry is on its own cache line.
            const entries = allocator.alignedAlloc(
                IndexEntry,
                64, // Cache line alignment
                @intCast(capacity),
            ) catch return error.OutOfMemory;

            // Initialize all entries to empty.
            @memset(entries, IndexEntry.empty);

            return @This(){
                .entries = entries,
                .capacity = capacity,
                .count = std.atomic.Value(u64).init(0),
                .stats = if (options.track_stats) IndexStats{
                    .capacity = capacity,
                } else {},
            };
        }

        /// Deinitialize and free index memory.
        pub fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.free(self.entries);
            self.* = undefined;
        }

        /// Hash function for entity_id (u128).
        /// Uses Google Abseil LowLevelHash (wyhash-inspired) from stdx.
        inline fn hash(entity_id: u128) u64 {
            return stdx.hash_inline(entity_id);
        }

        /// Calculate slot index from hash.
        inline fn slot_index(self: *const @This(), entity_id: u128) u64 {
            return hash(entity_id) % self.capacity;
        }

        /// Lookup an entity by ID.
        ///
        /// This is a lock-free operation using atomic loads with Acquire semantics.
        /// Safe to call concurrently from multiple threads.
        ///
        /// Returns the IndexEntry if found, null otherwise.
        /// Also returns the probe count for diagnostics.
        pub fn lookup(self: *@This(), entity_id: u128) LookupResult {
            if (entity_id == 0) {
                // Entity ID 0 is reserved as empty marker.
                return .{ .entry = null, .probe_count = 0 };
            }

            var slot = self.slot_index(entity_id);
            var probe_count: u32 = 0;

            while (probe_count < max_probe_length) {
                // Atomic load with Acquire semantics.
                // Ensures we see all writes from the Release store in upsert.
                const entry_ptr: *IndexEntry = &self.entries[@intCast(slot)];
                const entry = @as(*volatile IndexEntry, @ptrCast(entry_ptr)).*;

                if (entry.is_empty()) {
                    // Empty slot - entity not found.
                    self.updateLookupStats(probe_count, false);
                    return .{ .entry = null, .probe_count = probe_count };
                }

                if (entry.entity_id == entity_id) {
                    // Found the entity.
                    // Check if it's a tombstone.
                    if (entry.is_tombstone()) {
                        self.updateLookupStats(probe_count, false);
                        return .{ .entry = null, .probe_count = probe_count };
                    }
                    self.updateLookupStats(probe_count, true);
                    return .{ .entry = entry, .probe_count = probe_count };
                }

                // Collision - probe next slot (linear probing).
                slot = (slot + 1) % self.capacity;
                probe_count += 1;
            }

            // Probe limit exceeded - entry not found.
            self.updateProbeLimit();
            return .{ .entry = null, .probe_count = probe_count };
        }

        /// Upsert an entity into the index.
        ///
        /// Uses Last-Write-Wins (LWW) semantics:
        /// - If slot is empty: insert new entry
        /// - If slot has same entity_id: compare timestamps
        ///   - new_timestamp > old_timestamp: update (new wins)
        ///   - new_timestamp < old_timestamp: ignore (old wins)
        ///   - timestamps equal: higher latest_id wins (deterministic tie-break)
        /// - If slot has different entity_id: probe next slot
        ///
        /// This function is NOT thread-safe for concurrent writes.
        /// VSR commit phase guarantees single-threaded execution.
        pub fn upsert(
            self: *@This(),
            entity_id: u128,
            latest_id: u128,
            ttl_seconds: u32,
        ) IndexError!UpsertResult {
            if (entity_id == 0) {
                // Entity ID 0 is reserved as empty marker.
                return error.InvalidConfiguration;
            }

            var slot = self.slot_index(entity_id);
            var probe_count: u32 = 0;

            while (probe_count < max_probe_length) {
                const entry_ptr: *IndexEntry = &self.entries[@intCast(slot)];
                const entry = entry_ptr.*;

                if (entry.is_empty() or entry.is_tombstone()) {
                    // Empty or tombstone slot - insert new entry.
                    const new_entry = IndexEntry{
                        .entity_id = entity_id,
                        .latest_id = latest_id,
                        .ttl_seconds = ttl_seconds,
                        .reserved = 0,
                        .padding = [_]u8{0} ** 24,
                    };

                    // Write with Release semantics.
                    @as(*volatile IndexEntry, @ptrCast(entry_ptr)).* = new_entry;

                    // Update count if this was an empty slot (not tombstone reuse).
                    if (entry.is_empty()) {
                        _ = self.count.fetchAdd(1, .monotonic);
                    }

                    self.updateUpsertStats(probe_count, true, entry.is_tombstone());
                    return .{ .inserted = true, .updated = true, .probe_count = probe_count };
                }

                if (entry.entity_id == entity_id) {
                    // Found existing entry - apply LWW.
                    const new_timestamp = @as(u64, @truncate(latest_id));
                    const old_timestamp = entry.timestamp();

                    var should_update = false;
                    if (new_timestamp > old_timestamp) {
                        // New write wins.
                        should_update = true;
                    } else if (new_timestamp == old_timestamp) {
                        // Tie-break: higher latest_id wins (deterministic).
                        should_update = latest_id > entry.latest_id;
                    }
                    // else: new_timestamp < old_timestamp - old wins, ignore.

                    if (should_update) {
                        const new_entry = IndexEntry{
                            .entity_id = entity_id,
                            .latest_id = latest_id,
                            .ttl_seconds = ttl_seconds,
                            .reserved = 0,
                            .padding = [_]u8{0} ** 24,
                        };

                        // Write with Release semantics.
                        @as(*volatile IndexEntry, @ptrCast(entry_ptr)).* = new_entry;
                    }

                    self.updateUpsertStats(probe_count, false, false);
                    return .{
                        .inserted = false,
                        .updated = should_update,
                        .probe_count = probe_count,
                    };
                }

                // Different entity - collision, probe next slot.
                slot = (slot + 1) % self.capacity;
                probe_count += 1;
            }

            // Probe limit exceeded - index degraded.
            self.updateProbeLimit();
            return error.IndexDegraded;
        }

        /// Mark an entity as deleted (create tombstone).
        ///
        /// Tombstones preserve the slot for the entity_id to ensure
        /// proper probe chain behavior. They are reclaimed during rebuild.
        pub fn remove(self: *@This(), entity_id: u128) bool {
            if (entity_id == 0) return false;

            var slot = self.slot_index(entity_id);
            var probe_count: u32 = 0;

            while (probe_count < max_probe_length) {
                const entry_ptr: *IndexEntry = &self.entries[@intCast(slot)];
                const entry = entry_ptr.*;

                if (entry.is_empty()) {
                    // Not found.
                    return false;
                }

                if (entry.entity_id == entity_id) {
                    if (entry.is_tombstone()) {
                        // Already deleted.
                        return false;
                    }

                    // Create tombstone (keep entity_id, zero latest_id).
                    const tombstone = IndexEntry{
                        .entity_id = entity_id,
                        .latest_id = 0,
                        .ttl_seconds = 0,
                        .reserved = 0,
                        .padding = [_]u8{0} ** 24,
                    };

                    @as(*volatile IndexEntry, @ptrCast(entry_ptr)).* = tombstone;

                    if (options.track_stats) {
                        self.stats.tombstone_count += 1;
                        self.stats.entry_count -|= 1;
                    }

                    return true;
                }

                slot = (slot + 1) % self.capacity;
                probe_count += 1;
            }

            return false;
        }

        /// Atomically remove an entity only if its latest_id matches.
        ///
        /// This is used for TTL expiration to prevent race conditions:
        /// - If latest_id matches: entry is removed (expired entry, no concurrent upsert)
        /// - If latest_id doesn't match: entry is NOT removed (concurrent upsert happened)
        ///
        /// This ensures we never accidentally delete freshly inserted data.
        ///
        /// Per ttl-retention/spec.md: "Atomic: only remove if latest_id hasn't changed"
        pub fn remove_if_id_matches(
            self: *@This(),
            entity_id: u128,
            expected_latest_id: u128,
        ) RemoveIfMatchResult {
            if (entity_id == 0) {
                return .{ .removed = false, .race_detected = false };
            }

            var slot = self.slot_index(entity_id);
            var probe_count: u32 = 0;

            while (probe_count < max_probe_length) {
                const entry_ptr: *IndexEntry = &self.entries[@intCast(slot)];
                const entry = entry_ptr.*;

                if (entry.is_empty()) {
                    // Not found.
                    return .{ .removed = false, .race_detected = false };
                }

                if (entry.entity_id == entity_id) {
                    if (entry.is_tombstone()) {
                        // Already deleted.
                        return .{ .removed = false, .race_detected = false };
                    }

                    // Check if latest_id still matches what we expected.
                    if (entry.latest_id != expected_latest_id) {
                        // Race condition: a concurrent upsert changed the entry.
                        // Do NOT remove - the new data is fresh.
                        return .{ .removed = false, .race_detected = true };
                    }

                    // latest_id matches - safe to remove (expired entry).
                    const tombstone = IndexEntry{
                        .entity_id = entity_id,
                        .latest_id = 0,
                        .ttl_seconds = 0,
                        .reserved = 0,
                        .padding = [_]u8{0} ** 24,
                    };

                    @as(*volatile IndexEntry, @ptrCast(entry_ptr)).* = tombstone;

                    if (options.track_stats) {
                        self.stats.tombstone_count += 1;
                        self.stats.entry_count -|= 1;
                        // Track TTL expirations separately.
                        self.stats.ttl_expirations += 1;
                    }

                    return .{ .removed = true, .race_detected = false };
                }

                slot = (slot + 1) % self.capacity;
                probe_count += 1;
            }

            return .{ .removed = false, .race_detected = false };
        }

        /// Lookup with TTL expiration check.
        ///
        /// This implements lazy TTL expiration per ttl-retention/spec.md:
        /// 1. Lookup the entity
        /// 2. Check if expired using the provided consensus timestamp
        /// 3. If expired, atomically remove and return null
        ///
        /// Arguments:
        /// - entity_id: The entity UUID to look up
        /// - current_time_ns: The consensus timestamp (use VSR commit timestamp for queries)
        ///
        /// Returns:
        /// - entry: The found entry (null if not found or expired)
        /// - probe_count: Probes used for lookup
        /// - expired: True if entry was found but expired and removed
        pub fn lookup_with_ttl(
            self: *@This(),
            entity_id: u128,
            current_time_ns: u64,
        ) LookupWithTtlResult {
            // First, do a regular lookup.
            const result = self.lookup(entity_id);

            if (result.entry) |entry| {
                // Check TTL expiration.
                const expiration = ttl.is_entry_expired(entry, current_time_ns);

                if (expiration.expired) {
                    // Entry is expired - atomically remove it.
                    // This prevents race with concurrent upserts.
                    _ = self.remove_if_id_matches(entity_id, entry.latest_id);

                    return .{
                        .entry = null,
                        .probe_count = result.probe_count,
                        .expired = true,
                    };
                }

                // Entry is not expired - return it.
                return .{
                    .entry = entry,
                    .probe_count = result.probe_count,
                    .expired = false,
                };
            }

            // Entry not found.
            return .{
                .entry = null,
                .probe_count = result.probe_count,
                .expired = false,
            };
        }

        /// Scan a batch of index entries for TTL expiration.
        ///
        /// This implements the background cleanup scanner per ttl-retention/spec.md.
        /// It scans entries sequentially from a given position, removing expired
        /// entries and returning the next position for incremental scanning.
        ///
        /// Arguments:
        /// - start_position: Index slot to start scanning from
        /// - batch_size: Maximum number of entries to scan (0 = scan all)
        /// - current_time_ns: Current timestamp for expiration calculation
        ///
        /// Returns:
        /// - entries_scanned: Number of slots examined
        /// - entries_removed: Number of expired entries removed
        /// - next_position: Where to resume on next scan
        /// - wrapped: True if scan wrapped around to index start
        ///
        /// Thread Safety:
        /// - Safe to call during normal operation (uses atomic reads)
        /// - Writes are protected by VSR's single-writer guarantee
        pub fn scan_expired_batch(
            self: *@This(),
            start_position: u64,
            batch_size: u64,
            current_time_ns: u64,
        ) ScanExpiredResult {
            var entries_scanned: u64 = 0;
            var entries_removed: u64 = 0;
            var wrapped = false;

            // Determine effective batch size (0 = scan all).
            const effective_batch = if (batch_size == 0) self.capacity else batch_size;

            // Start position, wrapped to valid range.
            var position = if (start_position >= self.capacity) 0 else start_position;
            const initial_position = position;

            while (entries_scanned < effective_batch) {
                // Read entry atomically.
                const entry_ptr: *IndexEntry = &self.entries[@intCast(position)];
                const entry = @as(*volatile IndexEntry, @ptrCast(entry_ptr)).*;

                // Skip empty slots and tombstones.
                if (!entry.is_empty() and !entry.is_tombstone()) {
                    // Check TTL expiration.
                    const expiration = ttl.is_entry_expired(entry, current_time_ns);

                    if (expiration.expired) {
                        // Atomically remove if latest_id still matches.
                        const remove_result = self.remove_if_id_matches(
                            entry.entity_id,
                            entry.latest_id,
                        );
                        if (remove_result.removed) {
                            entries_removed += 1;
                        }
                        // If race_detected, entry was updated - skip it.
                    }
                }

                entries_scanned += 1;

                // Move to next position (with wraparound).
                position = (position + 1) % self.capacity;

                // Check if we've wrapped around to the starting position.
                if (position == initial_position and entries_scanned > 0) {
                    wrapped = true;
                    break;
                }
            }

            return .{
                .entries_scanned = entries_scanned,
                .entries_removed = entries_removed,
                .next_position = position,
                .wrapped = wrapped,
            };
        }

        // =================================================================
        // Online Rehash (F2.4.11)
        // =================================================================

        /// Create a new rehashed index with tombstones removed.
        /// Returns a new RamIndex with all live entries copied.
        /// The caller is responsible for atomic swap and freeing the old index.
        ///
        /// Per spec: Online rehash copies live entries, skips tombstones,
        /// reducing tombstone_ratio to 0 and probe_lengths back to optimal.
        pub fn create_rehashed_copy(
            self: *@This(),
            allocator: std.mem.Allocator,
            config: RehashConfig,
        ) !struct { new_index: Index, result: RehashResult } {
            const start_time = std.time.nanoTimestamp();
            const old_stats = self.get_stats();

            // Determine new capacity.
            const new_capacity = if (config.new_capacity > 0)
                config.new_capacity
            else
                self.capacity;

            // Allocate new index (var to allow mutation).
            var new_index = try @This().init(allocator, new_capacity);
            errdefer new_index.deinit(allocator);

            // Copy live entries (skip tombstones).
            var entries_copied: u64 = 0;
            var tombstones_skipped: u64 = 0;
            var new_max_probe: u32 = 0;

            var i: u64 = 0;
            while (i < self.capacity) : (i += 1) {
                // Read entry atomically (same pattern as scan_expired_batch).
                const entry_ptr: *IndexEntry = &self.entries[@intCast(i)];
                const entry = @as(*volatile IndexEntry, @ptrCast(entry_ptr)).*;

                // Skip empty slots.
                if (entry.entity_id == 0) continue;

                // Skip tombstones.
                if (entry.is_tombstone()) {
                    tombstones_skipped += 1;
                    continue;
                }

                // Copy live entry to new index.
                const upsert_result = try new_index.upsert(
                    entry.entity_id,
                    entry.latest_id,
                    entry.ttl_seconds,
                );

                entries_copied += 1;
                if (upsert_result.probe_count > new_max_probe) {
                    new_max_probe = upsert_result.probe_count;
                }
            }

            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 = @intCast(@max(0, end_time - start_time));

            const new_stats = new_index.get_stats();

            return .{
                .new_index = new_index,
                .result = .{
                    .success = true,
                    .entries_copied = entries_copied,
                    .tombstones_skipped = tombstones_skipped,
                    .duration_ns = duration_ns,
                    .old_probe_length_max = old_stats.max_probe_length_seen,
                    .new_probe_length_max = new_max_probe,
                    .old_tombstone_ratio = old_stats.tombstone_ratio(),
                    .new_tombstone_ratio = new_stats.tombstone_ratio(),
                    .error_message = null,
                },
            };
        }

        /// Verify rehash success criteria per spec.
        pub fn verify_rehash_success(result: RehashResult, expected_entries: u64) bool {
            // All entries still present.
            if (result.entries_copied != expected_entries) return false;

            // Tombstone ratio should be 0.
            if (result.new_tombstone_ratio > 0.001) return false;

            // Probe length should be optimal (< 3).
            const warn = DegradationThresholds.probe_length_warning;
            if (result.new_probe_length_max >= warn) return false;

            return true;
        }

        /// Get current statistics.
        pub fn get_stats(self: *const @This()) IndexStats {
            if (options.track_stats) {
                var stats = self.stats;
                stats.entry_count = self.count.load(.monotonic);
                return stats;
            } else {
                return IndexStats{
                    .capacity = self.capacity,
                    .entry_count = self.count.load(.monotonic),
                };
            }
        }

        // Internal stats update functions.

        fn updateLookupStats(self: *@This(), probe_count: u32, hit: bool) void {
            if (options.track_stats) {
                self.stats.lookup_count += 1;
                if (hit) self.stats.lookup_hit_count += 1;
                self.stats.total_probe_length += probe_count;
                if (probe_count > self.stats.max_probe_length_seen) {
                    self.stats.max_probe_length_seen = probe_count;
                }
                if (probe_count > 0) self.stats.collision_count += 1;
            }
        }

        fn updateUpsertStats(
            self: *@This(),
            probe_count: u32,
            inserted: bool,
            tombstone_reuse: bool,
        ) void {
            if (options.track_stats) {
                self.stats.upsert_count += 1;
                self.stats.total_probe_length += probe_count;
                if (probe_count > self.stats.max_probe_length_seen) {
                    self.stats.max_probe_length_seen = probe_count;
                }
                if (probe_count > 0) self.stats.collision_count += 1;
                if (inserted and !tombstone_reuse) {
                    self.stats.entry_count += 1;
                } else if (tombstone_reuse) {
                    self.stats.tombstone_count -|= 1;
                    self.stats.entry_count += 1;
                }
            }
        }

        fn updateProbeLimit(self: *@This()) void {
            if (options.track_stats) {
                self.stats.probe_limit_hits += 1;
            }
        }
    };
}

/// Default RAM index type with stats enabled.
pub const DefaultRamIndex = RamIndexType(.{ .track_stats = true });

// ============================================================================
// Unit Tests
// ============================================================================

test "IndexEntry: size and alignment" {
    // IndexEntry must be exactly 64 bytes (cache line).
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(IndexEntry));

    // Must have at least 16-byte alignment for u128.
    try std.testing.expect(@alignOf(IndexEntry) >= 16);
}

test "IndexEntry: empty and tombstone detection" {
    const empty = IndexEntry.empty;
    try std.testing.expect(empty.is_empty());
    try std.testing.expect(!empty.is_tombstone());

    const live = IndexEntry{
        .entity_id = 123,
        .latest_id = 456,
        .ttl_seconds = 0,
        .reserved = 0,
        .padding = [_]u8{0} ** 24,
    };
    try std.testing.expect(!live.is_empty());
    try std.testing.expect(!live.is_tombstone());

    const tombstone = IndexEntry{
        .entity_id = 123,
        .latest_id = 0,
        .ttl_seconds = 0,
        .reserved = 0,
        .padding = [_]u8{0} ** 24,
    };
    try std.testing.expect(!tombstone.is_empty());
    try std.testing.expect(tombstone.is_tombstone());
}

test "IndexEntry: timestamp extraction" {
    // Timestamp is lower 64 bits of latest_id.
    const entry = IndexEntry{
        .entity_id = 1,
        .latest_id = (@as(u128, 0xDEADBEEF) << 64) | 0x123456789ABCDEF0,
        .ttl_seconds = 0,
        .reserved = 0,
        .padding = [_]u8{0} ** 24,
    };
    try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), entry.timestamp());
}

test "RamIndex: basic lookup and upsert" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Lookup on empty index.
    const result1 = index.lookup(42);
    try std.testing.expect(result1.entry == null);

    // Insert an entry.
    const upsert_result = try index.upsert(42, 1000, 3600);
    try std.testing.expect(upsert_result.inserted);
    try std.testing.expect(upsert_result.updated);

    // Lookup should now find it.
    const result2 = index.lookup(42);
    try std.testing.expect(result2.entry != null);
    try std.testing.expectEqual(@as(u128, 42), result2.entry.?.entity_id);
    try std.testing.expectEqual(@as(u128, 1000), result2.entry.?.latest_id);
    try std.testing.expectEqual(@as(u32, 3600), result2.entry.?.ttl_seconds);
}

test "RamIndex: LWW semantics" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert initial entry with timestamp 1000.
    _ = try index.upsert(42, 1000, 3600);

    // Try to update with older timestamp 500 - should be ignored.
    const result1 = try index.upsert(42, 500, 7200);
    try std.testing.expect(!result1.inserted);
    try std.testing.expect(!result1.updated); // Old wins, not updated.

    // Verify entry still has original values.
    const lookup1 = index.lookup(42);
    try std.testing.expectEqual(@as(u128, 1000), lookup1.entry.?.latest_id);
    try std.testing.expectEqual(@as(u32, 3600), lookup1.entry.?.ttl_seconds);

    // Update with newer timestamp 2000 - should succeed.
    const result2 = try index.upsert(42, 2000, 1800);
    try std.testing.expect(!result2.inserted);
    try std.testing.expect(result2.updated); // New wins, updated.

    // Verify entry has new values.
    const lookup2 = index.lookup(42);
    try std.testing.expectEqual(@as(u128, 2000), lookup2.entry.?.latest_id);
    try std.testing.expectEqual(@as(u32, 1800), lookup2.entry.?.ttl_seconds);
}

test "RamIndex: LWW tie-break" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert entry: same timestamp (lower 64 bits), lower full ID.
    const id1 = (@as(u128, 100) << 64) | 5000; // S2=100, ts=5000
    _ = try index.upsert(42, id1, 3600);

    // Try with same timestamp but higher full ID - should win.
    const id2 = (@as(u128, 200) << 64) | 5000; // S2=200, ts=5000 (same)
    const result = try index.upsert(42, id2, 1800);
    try std.testing.expect(result.updated); // Higher full ID wins.

    const lookup = index.lookup(42);
    try std.testing.expectEqual(id2, lookup.entry.?.latest_id);
}

test "RamIndex: remove creates tombstone" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert and verify.
    _ = try index.upsert(42, 1000, 3600);
    try std.testing.expect(index.lookup(42).entry != null);

    // Remove.
    const removed = index.remove(42);
    try std.testing.expect(removed);

    // Lookup should return null (tombstone is not visible).
    try std.testing.expect(index.lookup(42).entry == null);

    // Remove again should return false.
    try std.testing.expect(!index.remove(42));
}

test "RamIndex: collision handling" {
    const allocator = std.testing.allocator;

    // Small capacity to force collisions.
    var index = try DefaultRamIndex.init(allocator, 10);
    defer index.deinit(allocator);

    // Insert multiple entries - some will collide.
    var i: u128 = 1;
    while (i <= 5) : (i += 1) {
        _ = try index.upsert(i, i * 100, 3600);
    }

    // Verify all can be found.
    i = 1;
    while (i <= 5) : (i += 1) {
        const result = index.lookup(i);
        try std.testing.expect(result.entry != null);
        try std.testing.expectEqual(i, result.entry.?.entity_id);
        try std.testing.expectEqual(i * 100, result.entry.?.latest_id);
    }
}

test "RamIndex: statistics" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Initial stats.
    var stats = index.get_stats();
    try std.testing.expectEqual(@as(u64, 1000), stats.capacity);
    try std.testing.expectEqual(@as(u64, 0), stats.entry_count);
    try std.testing.expectEqual(@as(f32, 0.0), stats.load_factor());

    // Insert some entries.
    _ = try index.upsert(1, 100, 0);
    _ = try index.upsert(2, 200, 0);
    _ = try index.upsert(3, 300, 0);

    // Perform lookups.
    _ = index.lookup(1);
    _ = index.lookup(2);
    _ = index.lookup(999); // Miss.

    stats = index.get_stats();
    try std.testing.expectEqual(@as(u64, 3), stats.entry_count);
    try std.testing.expectEqual(@as(u64, 3), stats.upsert_count);
    try std.testing.expectEqual(@as(u64, 3), stats.lookup_count);
    try std.testing.expectEqual(@as(u64, 2), stats.lookup_hit_count);

    // Verify load factor calculation.
    const expected_lf = 3.0 / 1000.0;
    try std.testing.expectApproxEqAbs(expected_lf, stats.load_factor(), 0.0001);
}

test "RamIndex: out-of-order timestamp handling (F2.1.7)" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Simulate GPS packets arriving out of order.
    // Packets: ts=3000, ts=1000, ts=2000 (arriving in this order).

    // First packet arrives (ts=3000).
    _ = try index.upsert(42, 3000, 3600);
    try std.testing.expectEqual(@as(u128, 3000), index.lookup(42).entry.?.latest_id);

    // Second packet arrives (ts=1000 - older, should be ignored).
    const result1 = try index.upsert(42, 1000, 3600);
    try std.testing.expect(!result1.updated);
    try std.testing.expectEqual(@as(u128, 3000), index.lookup(42).entry.?.latest_id);

    // Third packet arrives (ts=2000 - still older, should be ignored).
    const result2 = try index.upsert(42, 2000, 3600);
    try std.testing.expect(!result2.updated);
    try std.testing.expectEqual(@as(u128, 3000), index.lookup(42).entry.?.latest_id);

    // Fourth packet arrives (ts=4000 - newer, should win).
    const result3 = try index.upsert(42, 4000, 3600);
    try std.testing.expect(result3.updated);
    try std.testing.expectEqual(@as(u128, 4000), index.lookup(42).entry.?.latest_id);
}

test "RamIndex: entity_id zero is rejected" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // entity_id = 0 is reserved as empty marker.
    const result = index.upsert(0, 1000, 3600);
    try std.testing.expectError(error.InvalidConfiguration, result);

    // Lookup of 0 should return null immediately.
    try std.testing.expect(index.lookup(0).entry == null);
}

test "RamIndex: remove_if_id_matches removes when matching" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert entry.
    const latest_id: u128 = 1000;
    _ = try index.upsert(42, latest_id, 3600);

    // Remove with matching latest_id - should succeed.
    const result = index.remove_if_id_matches(42, latest_id);
    try std.testing.expect(result.removed);
    try std.testing.expect(!result.race_detected);

    // Entry should now be a tombstone (lookup returns null).
    try std.testing.expect(index.lookup(42).entry == null);
}

test "RamIndex: remove_if_id_matches detects race condition" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert entry.
    const old_latest_id: u128 = 1000;
    _ = try index.upsert(42, old_latest_id, 3600);

    // Simulate concurrent upsert - update to new latest_id.
    const new_latest_id: u128 = 2000;
    _ = try index.upsert(42, new_latest_id, 1800);

    // Try to remove with OLD latest_id - should detect race.
    const result = index.remove_if_id_matches(42, old_latest_id);
    try std.testing.expect(!result.removed);
    try std.testing.expect(result.race_detected);

    // Entry should still exist with new latest_id.
    const lookup = index.lookup(42);
    try std.testing.expect(lookup.entry != null);
    try std.testing.expectEqual(new_latest_id, lookup.entry.?.latest_id);
}

test "RamIndex: lookup_with_ttl returns entry when not expired" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert entry with TTL of 10 seconds.
    // latest_id lower 64 bits = timestamp = 5 seconds (in nanoseconds).
    const event_ts_ns = 5 * ttl.ns_per_second;
    const latest_id: u128 = (@as(u128, 0xDEADBEEF) << 64) | event_ts_ns;
    _ = try index.upsert(42, latest_id, 10); // TTL = 10 seconds.

    // Lookup at 10 seconds (before expiration at 15 seconds).
    const current_time_ns = 10 * ttl.ns_per_second;
    const result = index.lookup_with_ttl(42, current_time_ns);

    try std.testing.expect(result.entry != null);
    try std.testing.expect(!result.expired);
    try std.testing.expectEqual(latest_id, result.entry.?.latest_id);
}

test "RamIndex: lookup_with_ttl removes expired entry" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert entry with TTL of 10 seconds.
    // Timestamp = 5 seconds, so expires at 15 seconds.
    const event_ts_ns = 5 * ttl.ns_per_second;
    const latest_id: u128 = (@as(u128, 0xDEADBEEF) << 64) | event_ts_ns;
    _ = try index.upsert(42, latest_id, 10); // TTL = 10 seconds.

    // Verify entry exists with regular lookup.
    try std.testing.expect(index.lookup(42).entry != null);

    // Lookup at 20 seconds (after expiration at 15 seconds).
    const current_time_ns = 20 * ttl.ns_per_second;
    const result = index.lookup_with_ttl(42, current_time_ns);

    try std.testing.expect(result.entry == null);
    try std.testing.expect(result.expired);

    // Entry should now be removed (tombstoned).
    try std.testing.expect(index.lookup(42).entry == null);
}

test "RamIndex: lookup_with_ttl with ttl_seconds=0 never expires" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert entry with TTL of 0 (never expires).
    const event_ts_ns = 1 * ttl.ns_per_second;
    const latest_id: u128 = (@as(u128, 0xDEADBEEF) << 64) | event_ts_ns;
    _ = try index.upsert(42, latest_id, 0); // TTL = 0 (never expires).

    // Lookup at far future time - should still return entry.
    const current_time_ns = std.math.maxInt(u64) - 1;
    const result = index.lookup_with_ttl(42, current_time_ns);

    try std.testing.expect(result.entry != null);
    try std.testing.expect(!result.expired);
}

test "RamIndex: ttl_expirations stat is incremented" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert expired entry.
    const event_ts_ns = 1 * ttl.ns_per_second;
    const latest_id: u128 = event_ts_ns;
    _ = try index.upsert(42, latest_id, 10); // Expires at 11 seconds.

    // Initial stats should have 0 expirations.
    try std.testing.expectEqual(@as(u64, 0), index.get_stats().ttl_expirations);

    // Lookup with TTL at 20 seconds (after expiration).
    const current_time_ns = 20 * ttl.ns_per_second;
    _ = index.lookup_with_ttl(42, current_time_ns);

    // Stats should now show 1 expiration.
    try std.testing.expectEqual(@as(u64, 1), index.get_stats().ttl_expirations);
}

test "RamIndex: scan_expired_batch removes expired entries" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 100);
    defer index.deinit(allocator);

    // Insert 3 entries: 2 expired, 1 not expired.
    // Entry 1: expires at 10 seconds.
    const ts1 = 1 * ttl.ns_per_second;
    _ = try index.upsert(100, ts1, 9); // Expires at 10 seconds.

    // Entry 2: expires at 20 seconds.
    const ts2 = 5 * ttl.ns_per_second;
    _ = try index.upsert(200, ts2, 15); // Expires at 20 seconds.

    // Entry 3: never expires.
    const ts3 = 1 * ttl.ns_per_second;
    _ = try index.upsert(300, ts3, 0); // TTL = 0, never expires.

    // Scan at 15 seconds - entry 1 should be expired, others not.
    const scan_time = 15 * ttl.ns_per_second;
    const result = index.scan_expired_batch(0, 0, scan_time); // Scan all.

    try std.testing.expectEqual(@as(u64, 100), result.entries_scanned);
    try std.testing.expectEqual(@as(u64, 1), result.entries_removed);
    try std.testing.expect(result.wrapped);

    // Verify entry 100 is gone, others remain.
    try std.testing.expect(index.lookup(100).entry == null);
    try std.testing.expect(index.lookup(200).entry != null);
    try std.testing.expect(index.lookup(300).entry != null);
}

test "RamIndex: scan_expired_batch batch size limits scan" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 100);
    defer index.deinit(allocator);

    // Insert an entry.
    _ = try index.upsert(42, 1 * ttl.ns_per_second, 0);

    // Scan with batch size of 10.
    const result = index.scan_expired_batch(0, 10, 0);

    // Should scan exactly 10 entries.
    try std.testing.expectEqual(@as(u64, 10), result.entries_scanned);
    try std.testing.expectEqual(@as(u64, 10), result.next_position);
    try std.testing.expect(!result.wrapped);
}

test "RamIndex: scan_expired_batch incremental scanning" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 100);
    defer index.deinit(allocator);

    // Scan first 30 entries.
    const result1 = index.scan_expired_batch(0, 30, 0);
    try std.testing.expectEqual(@as(u64, 30), result1.next_position);
    try std.testing.expect(!result1.wrapped);

    // Continue from position 30, scan 30 more.
    const result2 = index.scan_expired_batch(result1.next_position, 30, 0);
    try std.testing.expectEqual(@as(u64, 60), result2.next_position);
    try std.testing.expect(!result2.wrapped);

    // Continue from 60, scan 50 (position will wrap from 99 to 0).
    const result3 = index.scan_expired_batch(result2.next_position, 50, 0);
    try std.testing.expectEqual(@as(u64, 50), result3.entries_scanned);
    // Position wraps around: 60 + 50 = 110 % 100 = 10.
    try std.testing.expectEqual(@as(u64, 10), result3.next_position);
    try std.testing.expect(!result3.wrapped); // Didn't reach initial position.

    // Scan remaining 50 to complete the full cycle.
    const result4 = index.scan_expired_batch(result3.next_position, 50, 0);
    try std.testing.expectEqual(@as(u64, 50), result4.entries_scanned);
    try std.testing.expectEqual(@as(u64, 60), result4.next_position);
    // Now we're back where we started the incremental scan.
}

test "RamIndex: scan_expired_batch handles wraparound position" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 100);
    defer index.deinit(allocator);

    // Start from position beyond capacity (should wrap to 0).
    const result = index.scan_expired_batch(150, 10, 0);
    try std.testing.expectEqual(@as(u64, 10), result.entries_scanned);
    try std.testing.expectEqual(@as(u64, 10), result.next_position);
}

test "RamIndex: full TTL lifecycle - insert, expire, lookup removes" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 100);
    defer index.deinit(allocator);

    const entity_id: u128 = 0x1234567890ABCDEF;
    const event_timestamp: u64 = 10 * ttl.ns_per_second;
    const ttl_seconds: u32 = 60; // 60 second TTL.

    // Pack timestamp into latest_id (lower 64 bits).
    const latest_id: u128 = (@as(u128, 0x89C259) << 64) | event_timestamp;

    // Step 1: Insert entry with TTL.
    _ = try index.upsert(entity_id, latest_id, ttl_seconds);
    try std.testing.expectEqual(@as(u64, 1), index.stats.entry_count);

    // Step 2: Lookup before expiration - entry should be found.
    const before_time = 30 * ttl.ns_per_second; // 30 seconds.
    const lookup1 = index.lookup_with_ttl(entity_id, before_time);
    try std.testing.expect(lookup1.entry != null);
    try std.testing.expect(!lookup1.expired);

    // Step 3: Lookup after expiration - entry should be removed.
    const after_time = 100 * ttl.ns_per_second; // 100 seconds > 10+60.
    const lookup2 = index.lookup_with_ttl(entity_id, after_time);
    try std.testing.expect(lookup2.entry == null);
    try std.testing.expect(lookup2.expired);

    // Step 4: Verify stats updated.
    try std.testing.expectEqual(@as(u64, 1), index.stats.ttl_expirations);
    try std.testing.expectEqual(@as(u64, 1), index.stats.tombstone_count);
}

test "RamIndex: mixed TTL entries - scanner removes only expired" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 100);
    defer index.deinit(allocator);

    const current_time: u64 = 100 * ttl.ns_per_second;

    // Insert entries with different TTL states:
    // 1. Never expires (ttl_seconds = 0).
    // 2. Already expired (timestamp + ttl < current_time).
    // 3. Not yet expired (timestamp + ttl > current_time).

    // Entry 1: Never expires.
    const id1: u128 = 1;
    const ts1: u64 = 10 * ttl.ns_per_second;
    _ = try index.upsert(id1, ts1, 0); // ttl_seconds = 0 -> never expires.

    // Entry 2: Expired (timestamp=10s, ttl=30s -> expires at 40s, current=100s).
    const id2: u128 = 2;
    const ts2: u64 = 10 * ttl.ns_per_second;
    _ = try index.upsert(id2, ts2, 30);

    // Entry 3: Not expired yet (timestamp=50s, ttl=100s -> expires at 150s).
    const id3: u128 = 3;
    const ts3: u64 = 50 * ttl.ns_per_second;
    _ = try index.upsert(id3, ts3, 100);

    // Entry 4: Expired (timestamp=5s, ttl=10s -> expires at 15s).
    const id4: u128 = 4;
    const ts4: u64 = 5 * ttl.ns_per_second;
    _ = try index.upsert(id4, ts4, 10);

    try std.testing.expectEqual(@as(u64, 4), index.stats.entry_count);

    // Scan all entries.
    const result = index.scan_expired_batch(0, 100, current_time);

    // Should have removed entries 2 and 4 (both expired).
    try std.testing.expectEqual(@as(u64, 2), result.entries_removed);

    // Verify: Entry 1 still exists (never expires).
    const l1 = index.lookup(id1);
    try std.testing.expect(l1.entry != null);
    try std.testing.expect(!l1.entry.?.is_tombstone());

    // Verify: Entry 2 removed (expired) - now tombstone.
    const l2 = index.lookup(id2);
    try std.testing.expect(l2.entry == null or l2.entry.?.is_tombstone());

    // Verify: Entry 3 still exists (not yet expired).
    const l3 = index.lookup(id3);
    try std.testing.expect(l3.entry != null);
    try std.testing.expect(!l3.entry.?.is_tombstone());

    // Verify: Entry 4 removed (expired) - now tombstone.
    const l4 = index.lookup(id4);
    try std.testing.expect(l4.entry == null or l4.entry.?.is_tombstone());
}

// =============================================================================
// Degradation Detection Tests (F2.4.9)
// =============================================================================

test "DegradationDetector: tombstone_level thresholds" {
    // Test tombstone accumulation detection.
    // Normal: < 10% tombstones.
    const stats_normal = IndexStats{ .capacity = 100, .entry_count = 95, .tombstone_count = 5 };
    const check_normal = DegradationDetector.detect_tombstone_level(stats_normal);
    try std.testing.expectEqual(DegradationLevel.normal, check_normal.level);
    try std.testing.expect(check_normal.current_value < 0.10);

    // Warning: 10-30% tombstones.
    const stats_warning = IndexStats{ .capacity = 100, .entry_count = 80, .tombstone_count = 15 };
    const check_warning = DegradationDetector.detect_tombstone_level(stats_warning);
    try std.testing.expectEqual(DegradationLevel.warning, check_warning.level);
    try std.testing.expect(check_warning.current_value >= 0.10);
    try std.testing.expect(check_warning.current_value < 0.30);

    // Critical: > 30% tombstones.
    const stats_critical = IndexStats{ .capacity = 100, .entry_count = 60, .tombstone_count = 35 };
    const check_critical = DegradationDetector.detect_tombstone_level(stats_critical);
    try std.testing.expectEqual(DegradationLevel.critical, check_critical.level);
    try std.testing.expect(check_critical.current_value >= 0.30);
}

test "DegradationDetector: probe_length_level thresholds" {
    // Test probe length growth detection.
    // Normal: max_probe < 3.
    const stats_normal = IndexStats{ .max_probe_length_seen = 2 };
    const check_normal = DegradationDetector.detect_probe_length_level(stats_normal);
    try std.testing.expectEqual(DegradationLevel.normal, check_normal.level);

    // Warning: max_probe 3-10.
    const stats_warning = IndexStats{ .max_probe_length_seen = 5 };
    const check_warning = DegradationDetector.detect_probe_length_level(stats_warning);
    try std.testing.expectEqual(DegradationLevel.warning, check_warning.level);

    // Critical: max_probe >= 10.
    const stats_critical = IndexStats{ .max_probe_length_seen = 12 };
    const check_critical = DegradationDetector.detect_probe_length_level(stats_critical);
    try std.testing.expectEqual(DegradationLevel.critical, check_critical.level);
}

test "DegradationDetector: capacity_level thresholds" {
    // Test capacity limit detection.
    // Normal: load_factor < 0.60.
    const stats_normal = IndexStats{ .capacity = 100, .entry_count = 50, .tombstone_count = 5 };
    const check_normal = DegradationDetector.detect_capacity_level(stats_normal);
    try std.testing.expectEqual(DegradationLevel.normal, check_normal.level);
    try std.testing.expect(check_normal.current_value < 0.60);

    // Warning: load_factor 0.60-0.75.
    const stats_warning = IndexStats{ .capacity = 100, .entry_count = 65, .tombstone_count = 3 };
    const check_warning = DegradationDetector.detect_capacity_level(stats_warning);
    try std.testing.expectEqual(DegradationLevel.warning, check_warning.level);
    try std.testing.expect(check_warning.current_value >= 0.60);
    try std.testing.expect(check_warning.current_value < 0.75);

    // Critical: load_factor >= 0.75.
    const stats_critical = IndexStats{ .capacity = 100, .entry_count = 70, .tombstone_count = 8 };
    const check_critical = DegradationDetector.detect_capacity_level(stats_critical);
    try std.testing.expectEqual(DegradationLevel.critical, check_critical.level);
    try std.testing.expect(check_critical.current_value >= 0.75);
}

test "DegradationDetector: check_health overall level" {
    var detector = DegradationDetector{};

    // Healthy index: all checks normal.
    const stats_healthy = IndexStats{
        .capacity = 100,
        .entry_count = 40,
        .tombstone_count = 2,
        .max_probe_length_seen = 1,
    };
    const RecAction = DegradationStatus.RecommendedAction;
    const status_healthy = detector.check_health(stats_healthy);
    try std.testing.expectEqual(DegradationLevel.normal, status_healthy.overall_level);
    try std.testing.expectEqual(RecAction.none, status_healthy.recommended_action);
    try std.testing.expect(!status_healthy.corruption_detected);

    // Warning level: high tombstone ratio.
    // capacity=200 keeps load_factor at 46.5% (below warning 60%)
    const stats_warning = IndexStats{
        .capacity = 200,
        .entry_count = 78,
        .tombstone_count = 15, // ~16% tombstones
        .max_probe_length_seen = 2,
    };
    const status_warning = detector.check_health(stats_warning);
    try std.testing.expectEqual(DegradationLevel.warning, status_warning.overall_level);
    const expected_warn = RecAction.schedule_rebuild;
    try std.testing.expectEqual(expected_warn, status_warning.recommended_action);

    // Critical level: high load factor.
    const stats_critical = IndexStats{
        .capacity = 100,
        .entry_count = 70,
        .tombstone_count = 10, // 80% load factor
        .max_probe_length_seen = 2,
    };
    const status_critical = detector.check_health(stats_critical);
    try std.testing.expectEqual(DegradationLevel.critical, status_critical.overall_level);
    const expected_crit = RecAction.immediate_rebuild;
    try std.testing.expectEqual(expected_crit, status_critical.recommended_action);
}

test "DegradationDetector: corruption detection" {
    var detector = DegradationDetector{};
    const RecAction = DegradationStatus.RecommendedAction;

    // No corruption initially.
    const stats = IndexStats{ .capacity = 100, .entry_count = 10 };
    const status_initial = detector.check_health(stats);
    try std.testing.expect(!status_initial.corruption_detected);
    try std.testing.expectEqual(DegradationLevel.normal, status_initial.overall_level);

    // Record corruption.
    detector.record_corruption();
    const status_corrupted = detector.check_health(stats);
    try std.testing.expect(status_corrupted.corruption_detected);
    try std.testing.expectEqual(DegradationLevel.critical, status_corrupted.overall_level);
    const expected = RecAction.replace_replica;
    try std.testing.expectEqual(expected, status_corrupted.recommended_action);

    // Reset corruption.
    detector.reset_corruption();
    const status_reset = detector.check_health(stats);
    try std.testing.expect(!status_reset.corruption_detected);
    try std.testing.expectEqual(DegradationLevel.normal, status_reset.overall_level);
}

test "DegradationLevel: severity ordering" {
    const DL = DegradationLevel;
    // Test that severity values are correctly ordered.
    try std.testing.expectEqual(@as(u8, 0), DL.normal.severity());
    try std.testing.expectEqual(@as(u8, 1), DL.warning.severity());
    try std.testing.expectEqual(@as(u8, 2), DL.critical.severity());

    // Verify ordering.
    try std.testing.expect(DL.normal.severity() < DL.warning.severity());
    try std.testing.expect(DL.warning.severity() < DL.critical.severity());
}

// =============================================================================
// Graceful Degradation Tests (F2.4.10)
// =============================================================================

test "DegradedModeManager: determine_response normal" {
    // Normal status should return normal response.
    const status = DegradationStatus{
        .overall_level = .normal,
        .tombstone_check = .{
            .degradation_type = .tombstone_accumulation,
            .level = .normal,
            .current_value = 0.05,
            .warning_threshold = 0.10,
            .critical_threshold = 0.30,
        },
        .probe_length_check = .{
            .degradation_type = .probe_length_growth,
            .level = .normal,
            .current_value = 1.0,
            .warning_threshold = 3.0,
            .critical_threshold = 10.0,
        },
        .capacity_check = .{
            .degradation_type = .capacity_limit,
            .level = .normal,
            .current_value = 0.40,
            .warning_threshold = 0.60,
            .critical_threshold = 0.75,
        },
        .corruption_detected = false,
        .recommended_action = .none,
    };

    const response = DegradedModeManager.determine_response(status);
    try std.testing.expectEqual(DegradedModeState.normal, response.new_state);
    try std.testing.expect(!response.log_warning);
    try std.testing.expect(!response.log_critical);
    try std.testing.expect(!response.notify_operator);
    try std.testing.expect(!response.reduce_cache);
    try std.testing.expect(!response.start_rebuild);
    try std.testing.expect(!response.stop_replica);
    try std.testing.expectEqual(QueryQueueConfig.normal_timeout_ns, response.query_timeout_ns);
}

test "DegradedModeManager: determine_response warning" {
    // Warning status should log warning and notify operator.
    const status = DegradationStatus{
        .overall_level = .warning,
        .tombstone_check = .{
            .degradation_type = .tombstone_accumulation,
            .level = .warning,
            .current_value = 0.15,
            .warning_threshold = 0.10,
            .critical_threshold = 0.30,
        },
        .probe_length_check = .{
            .degradation_type = .probe_length_growth,
            .level = .normal,
            .current_value = 2.0,
            .warning_threshold = 3.0,
            .critical_threshold = 10.0,
        },
        .capacity_check = .{
            .degradation_type = .capacity_limit,
            .level = .normal,
            .current_value = 0.50,
            .warning_threshold = 0.60,
            .critical_threshold = 0.75,
        },
        .corruption_detected = false,
        .recommended_action = .schedule_rebuild,
    };

    const response = DegradedModeManager.determine_response(status);
    try std.testing.expectEqual(DegradedModeState.warning, response.new_state);
    try std.testing.expect(response.log_warning);
    try std.testing.expect(!response.log_critical);
    try std.testing.expect(response.notify_operator);
    try std.testing.expect(!response.page_oncall);
    try std.testing.expect(!response.reduce_cache);
    try std.testing.expect(!response.start_rebuild);
    try std.testing.expectEqual(QueryQueueConfig.normal_timeout_ns, response.query_timeout_ns);
}

test "DegradedModeManager: determine_response critical" {
    // Critical status should enter degraded mode with all emergency actions.
    const status = DegradationStatus{
        .overall_level = .critical,
        .tombstone_check = .{
            .degradation_type = .tombstone_accumulation,
            .level = .critical,
            .current_value = 0.35,
            .warning_threshold = 0.10,
            .critical_threshold = 0.30,
        },
        .probe_length_check = .{
            .degradation_type = .probe_length_growth,
            .level = .normal,
            .current_value = 2.0,
            .warning_threshold = 3.0,
            .critical_threshold = 10.0,
        },
        .capacity_check = .{
            .degradation_type = .capacity_limit,
            .level = .normal,
            .current_value = 0.50,
            .warning_threshold = 0.60,
            .critical_threshold = 0.75,
        },
        .corruption_detected = false,
        .recommended_action = .immediate_rebuild,
    };

    const response = DegradedModeManager.determine_response(status);
    try std.testing.expectEqual(DegradedModeState.degraded, response.new_state);
    try std.testing.expect(!response.log_warning);
    try std.testing.expect(response.log_critical);
    try std.testing.expect(response.notify_operator);
    try std.testing.expect(response.page_oncall);
    try std.testing.expect(response.enable_diagnostics);
    try std.testing.expect(response.reduce_cache);
    try std.testing.expect(response.start_rebuild);
    try std.testing.expect(!response.stop_replica);
    try std.testing.expectEqual(QueryQueueConfig.degraded_timeout_ns, response.query_timeout_ns);
}

test "DegradedModeManager: determine_response corruption" {
    // Corruption should trigger unrecoverable state.
    const status = DegradationStatus{
        .overall_level = .critical,
        .tombstone_check = .{
            .degradation_type = .tombstone_accumulation,
            .level = .normal,
            .current_value = 0.05,
            .warning_threshold = 0.10,
            .critical_threshold = 0.30,
        },
        .probe_length_check = .{
            .degradation_type = .probe_length_growth,
            .level = .normal,
            .current_value = 2.0,
            .warning_threshold = 3.0,
            .critical_threshold = 10.0,
        },
        .capacity_check = .{
            .degradation_type = .capacity_limit,
            .level = .normal,
            .current_value = 0.40,
            .warning_threshold = 0.60,
            .critical_threshold = 0.75,
        },
        .corruption_detected = true,
        .recommended_action = .replace_replica,
    };

    const response = DegradedModeManager.determine_response(status);
    try std.testing.expectEqual(DegradedModeState.unrecoverable, response.new_state);
    try std.testing.expect(response.log_critical);
    try std.testing.expect(response.page_oncall);
    try std.testing.expect(response.stop_replica);
    try std.testing.expect(!response.start_rebuild); // Cannot rebuild with corruption.
    try std.testing.expectEqual(@as(u64, 0), response.query_timeout_ns);
}

test "DegradedModeManager: query acceptance based on queue depth" {
    var manager = DegradedModeManager{};

    // Normal mode - accept all queries.
    try std.testing.expect(manager.should_accept_query());

    // Warning mode - still accept all queries.
    manager.state = .warning;
    try std.testing.expect(manager.should_accept_query());

    // Degraded mode below soft limit - accept.
    manager.state = .degraded;
    manager.query_queue_depth = 50;
    try std.testing.expect(manager.should_accept_query());

    // Degraded mode at soft limit - reject.
    manager.query_queue_depth = 100;
    try std.testing.expect(!manager.should_accept_query());

    // Normal mode at soft limit - still accept.
    manager.state = .normal;
    try std.testing.expect(manager.should_accept_query());

    // Any mode at hard limit - reject.
    manager.query_queue_depth = 500;
    try std.testing.expect(!manager.should_accept_query());

    // Unrecoverable - reject all.
    manager.state = .unrecoverable;
    manager.query_queue_depth = 0;
    try std.testing.expect(!manager.should_accept_query());
}

test "DegradedModeManager: query timeout" {
    var manager = DegradedModeManager{};

    // Normal mode - 1 second timeout.
    try std.testing.expectEqual(QueryQueueConfig.normal_timeout_ns, manager.query_timeout());

    // Warning mode - still 1 second.
    manager.state = .warning;
    try std.testing.expectEqual(QueryQueueConfig.normal_timeout_ns, manager.query_timeout());

    // Degraded mode - 5 second timeout.
    manager.state = .degraded;
    try std.testing.expectEqual(QueryQueueConfig.degraded_timeout_ns, manager.query_timeout());

    // Unrecoverable - 0 (not serving).
    manager.state = .unrecoverable;
    try std.testing.expectEqual(@as(u64, 0), manager.query_timeout());
}

test "DegradedModeManager: complete recovery cycle" {
    var manager = DegradedModeManager{};

    // Enter degraded mode.
    manager.state = .degraded;
    manager.degraded_since_ns = 1000;
    manager.rebuild_in_progress = true;
    manager.rebuild_percent = 50;
    manager.cache_reduced = true;
    manager.diagnostics.enabled = true;

    // Verify degraded state.
    try std.testing.expectEqual(DegradedModeState.degraded, manager.state);
    try std.testing.expect(manager.rebuild_in_progress);
    try std.testing.expect(manager.cache_reduced);

    // Complete recovery.
    manager.complete_recovery();

    // Verify normal state restored.
    try std.testing.expectEqual(DegradedModeState.normal, manager.state);
    try std.testing.expect(!manager.rebuild_in_progress);
    try std.testing.expectEqual(@as(u8, 0), manager.rebuild_percent);
    try std.testing.expect(!manager.cache_reduced);
    try std.testing.expect(!manager.diagnostics.enabled);
}

test "DiagnosticConfig: sampling" {
    var config = DiagnosticConfig{};

    // Disabled by default - never log.
    try std.testing.expect(!config.should_log());
    try std.testing.expect(!config.should_log());
    try std.testing.expect(!config.should_log());
    try std.testing.expectEqual(@as(u64, 0), config.diagnostics_logged);

    // Enable diagnostics.
    config.enabled = true;

    // Sample every 10th query.
    var logged_count: u64 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        if (config.should_log()) {
            logged_count += 1;
        }
    }

    // Should have logged ~10 queries (10% sample rate).
    try std.testing.expectEqual(@as(u64, 10), logged_count);
    try std.testing.expectEqual(@as(u64, 10), config.diagnostics_logged);
}

// =============================================================================
// Online Rehash Tests (F2.4.11)
// =============================================================================

test "RamIndex: create_rehashed_copy removes tombstones" {
    const allocator = std.testing.allocator;
    var index = try DefaultRamIndex.init(allocator, 100);
    defer index.deinit(allocator);

    // Insert entries.
    _ = try index.upsert(1, 100, 0);
    _ = try index.upsert(2, 200, 0);
    _ = try index.upsert(3, 300, 0);
    _ = try index.upsert(4, 400, 0);
    _ = try index.upsert(5, 500, 0);

    const stats_before = index.get_stats();
    try std.testing.expectEqual(@as(u64, 5), stats_before.entry_count);

    // Remove two entries (creates tombstones).
    const removed1 = index.remove_if_id_matches(2, 200);
    const removed2 = index.remove_if_id_matches(4, 400);
    try std.testing.expect(removed1.removed);
    try std.testing.expect(removed2.removed);

    // Verify tombstones exist.
    const stats_with_tombstones = index.get_stats();
    try std.testing.expect(stats_with_tombstones.tombstone_ratio() > 0);

    // Perform rehash.
    const config = RehashConfig{};
    var rehash_output = try index.create_rehashed_copy(allocator, config);
    var new_index = &rehash_output.new_index;
    const result = rehash_output.result;
    defer new_index.deinit(allocator);

    // Verify result.
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 3), result.entries_copied);
    try std.testing.expectEqual(@as(u64, 2), result.tombstones_skipped);

    // Verify new index has no tombstones.
    const new_stats = new_index.get_stats();
    try std.testing.expectEqual(@as(u64, 3), new_stats.entry_count);
    try std.testing.expectEqual(@as(u64, 0), new_stats.tombstone_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), new_stats.tombstone_ratio(), 0.001);

    // Verify entries are accessible in new index.
    const l1 = new_index.lookup(1);
    const l3 = new_index.lookup(3);
    const l5 = new_index.lookup(5);
    try std.testing.expect(l1.entry != null);
    try std.testing.expect(l3.entry != null);
    try std.testing.expect(l5.entry != null);
    try std.testing.expectEqual(@as(u128, 100), l1.entry.?.latest_id);
    try std.testing.expectEqual(@as(u128, 300), l3.entry.?.latest_id);
    try std.testing.expectEqual(@as(u128, 500), l5.entry.?.latest_id);

    // Verify removed entries are not in new index.
    const l2 = new_index.lookup(2);
    const l4 = new_index.lookup(4);
    try std.testing.expect(l2.entry == null);
    try std.testing.expect(l4.entry == null);
}

test "RamIndex: verify_rehash_success criteria" {
    // Success case.
    const success_result = RehashResult{
        .success = true,
        .entries_copied = 100,
        .tombstones_skipped = 20,
        .duration_ns = 1000,
        .old_probe_length_max = 8,
        .new_probe_length_max = 1,
        .old_tombstone_ratio = 0.17,
        .new_tombstone_ratio = 0.0,
        .error_message = null,
    };
    try std.testing.expect(DefaultRamIndex.verify_rehash_success(success_result, 100));

    // Failure: wrong entry count.
    const wrong_count = RehashResult{
        .success = true,
        .entries_copied = 95,
        .tombstones_skipped = 20,
        .duration_ns = 1000,
        .old_probe_length_max = 8,
        .new_probe_length_max = 1,
        .old_tombstone_ratio = 0.17,
        .new_tombstone_ratio = 0.0,
        .error_message = null,
    };
    try std.testing.expect(!DefaultRamIndex.verify_rehash_success(wrong_count, 100));

    // Failure: tombstones remain.
    const tombstones_remain = RehashResult{
        .success = true,
        .entries_copied = 100,
        .tombstones_skipped = 20,
        .duration_ns = 1000,
        .old_probe_length_max = 8,
        .new_probe_length_max = 1,
        .old_tombstone_ratio = 0.17,
        .new_tombstone_ratio = 0.05,
        .error_message = null,
    };
    try std.testing.expect(!DefaultRamIndex.verify_rehash_success(tombstones_remain, 100));

    // Failure: probe length still high.
    const high_probe = RehashResult{
        .success = true,
        .entries_copied = 100,
        .tombstones_skipped = 20,
        .duration_ns = 1000,
        .old_probe_length_max = 8,
        .new_probe_length_max = 5, // >= warning threshold (3)
        .old_tombstone_ratio = 0.17,
        .new_tombstone_ratio = 0.0,
        .error_message = null,
    };
    try std.testing.expect(!DefaultRamIndex.verify_rehash_success(high_probe, 100));
}

test "RehashState: progress tracking" {
    var state = RehashState{};

    // Initial state.
    try std.testing.expect(!state.in_progress);
    try std.testing.expectEqual(@as(u8, 0), state.progress_percent);

    // Start rehash.
    state.in_progress = true;
    state.total_entries = 100;
    state.entries_copied = 0;
    state.update_progress();
    try std.testing.expectEqual(@as(u8, 0), state.progress_percent);

    // 50% progress.
    state.entries_copied = 50;
    state.update_progress();
    try std.testing.expectEqual(@as(u8, 50), state.progress_percent);

    // 100% progress.
    state.entries_copied = 100;
    state.update_progress();
    try std.testing.expectEqual(@as(u8, 100), state.progress_percent);

    // Empty table (edge case).
    state.total_entries = 0;
    state.entries_copied = 0;
    state.update_progress();
    try std.testing.expectEqual(@as(u8, 100), state.progress_percent);
}

// =============================================================================
// Recovery Metrics and Alerts Tests (F2.4.12)
// =============================================================================

test "AlertSeverity: toLabel conversion" {
    try std.testing.expectEqualStrings("info", AlertSeverity.info.toLabel());
    try std.testing.expectEqualStrings("warning", AlertSeverity.warning.toLabel());
    try std.testing.expectEqualStrings("critical", AlertSeverity.critical.toLabel());
}

test "AlertType: toLabel conversion" {
    const AT = AlertType;
    try std.testing.expectEqualStrings("tombstone_degradation", AT.tombstone_degradation.toLabel());
    try std.testing.expectEqualStrings("probe_length_growth", AT.probe_length_growth.toLabel());
    try std.testing.expectEqualStrings("capacity_limit", AT.capacity_limit.toLabel());
    try std.testing.expectEqualStrings("rebuild_completed", AT.rebuild_completed.toLabel());
}

test "AlertType: recommendedAction returns action" {
    const action = AlertType.tombstone_degradation.recommendedAction();
    try std.testing.expect(action.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, action, "rehash") != null);
}

test "RecoveryMetrics: rebuild tracking" {
    var metrics = RecoveryMetrics{};

    // Initial state.
    try std.testing.expectEqual(@as(u64, 0), metrics.rebuilds_started);
    try std.testing.expectEqual(@as(u64, 0), metrics.rebuilds_completed);
    try std.testing.expectEqual(@as(u64, 0), metrics.rebuilds_failed);

    // Start rebuild.
    metrics.recordRebuildStart(1000);
    try std.testing.expectEqual(@as(u64, 1), metrics.rebuilds_started);
    try std.testing.expectEqual(@as(u64, 1000), metrics.last_rebuild_start_ns);

    // Complete rebuild.
    metrics.recordRebuildComplete(2000, 100, 20);
    try std.testing.expectEqual(@as(u64, 1), metrics.rebuilds_completed);
    try std.testing.expectEqual(@as(u64, 100), metrics.total_entries_copied);
    try std.testing.expectEqual(@as(u64, 20), metrics.total_tombstones_reclaimed);
    try std.testing.expectEqual(@as(u64, 1000), metrics.total_rebuild_duration_ns);
    try std.testing.expect(metrics.last_rebuild_success);

    // Record failure.
    metrics.recordRebuildFailure();
    try std.testing.expectEqual(@as(u64, 1), metrics.rebuilds_failed);
    try std.testing.expect(!metrics.last_rebuild_success);
}

test "RecoveryMetrics: averageRebuildDurationNs" {
    var metrics = RecoveryMetrics{};

    // No rebuilds - returns 0.
    try std.testing.expectEqual(@as(u64, 0), metrics.averageRebuildDurationNs());

    // Two rebuilds (using non-zero start times to trigger duration tracking).
    // Note: recordRebuildComplete only adds duration if last_rebuild_start_ns > 0.
    metrics.recordRebuildStart(1000);
    metrics.recordRebuildComplete(2000, 50, 10); // duration = 1000
    metrics.recordRebuildStart(3000);
    metrics.recordRebuildComplete(6000, 50, 10); // duration = 3000

    // Average: (1000 + 3000) / 2 = 2000.
    try std.testing.expectEqual(@as(u64, 2000), metrics.averageRebuildDurationNs());
}

test "RecoveryMetrics: alert counting" {
    var metrics = RecoveryMetrics{};

    metrics.recordAlert(.info);
    metrics.recordAlert(.warning);
    metrics.recordAlert(.critical);
    metrics.recordAlert(.critical);

    try std.testing.expectEqual(@as(u64, 4), metrics.alerts_raised);
    try std.testing.expectEqual(@as(u64, 2), metrics.critical_alerts_raised);
}

test "RecoveryMetrics: toPrometheus output" {
    var metrics = RecoveryMetrics{};
    metrics.rebuilds_started = 5;
    metrics.rebuilds_completed = 4;
    metrics.rebuilds_failed = 1;
    metrics.total_entries_copied = 1000;
    metrics.total_tombstones_reclaimed = 200;
    metrics.alerts_raised = 10;
    metrics.critical_alerts_raised = 2;

    var buffer: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try metrics.toPrometheus(fbs.writer());

    const output = fbs.getWritten();
    const started = "archerdb_ram_index_rebuilds_started_total 5";
    const completed = "archerdb_ram_index_rebuilds_completed_total 4";
    const alerts = "archerdb_ram_index_alerts_total 10";
    try std.testing.expect(std.mem.indexOf(u8, output, started) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, completed) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, alerts) != null);
}

test "AlertManager: checkAndAlert with healthy status" {
    var manager = AlertManager{};

    // Healthy index - no alerts (level = normal).
    const health = HealthCheck{
        .degradation_type = .tombstone_accumulation,
        .level = .normal,
        .current_value = 0.05,
        .warning_threshold = 0.10,
        .critical_threshold = 0.30,
    };

    const alert = manager.checkAndAlert(health, 1000);
    try std.testing.expect(alert == null);
}

test "AlertManager: checkAndAlert with warning status" {
    var manager = AlertManager{};

    // Warning level - should generate alert.
    const health = HealthCheck{
        .degradation_type = .tombstone_accumulation,
        .level = .warning,
        .current_value = 0.15,
        .warning_threshold = 0.10,
        .critical_threshold = 0.30,
    };

    const alert = manager.checkAndAlert(health, 1000);
    try std.testing.expect(alert != null);
    try std.testing.expectEqual(AlertType.tombstone_degradation, alert.?.alert_type);
    try std.testing.expectEqual(AlertSeverity.warning, alert.?.severity);
}

test "AlertManager: checkAndAlert rate limiting" {
    var manager = AlertManager{};

    const health = HealthCheck{
        .degradation_type = .tombstone_accumulation,
        .level = .warning,
        .current_value = 0.15,
        .warning_threshold = 0.10,
        .critical_threshold = 0.30,
    };

    // First alert - should succeed.
    const alert1 = manager.checkAndAlert(health, 1000);
    try std.testing.expect(alert1 != null);

    // Second alert immediately after - should be rate limited.
    const alert2 = manager.checkAndAlert(health, 2000);
    try std.testing.expect(alert2 == null);

    // Third alert after min_alert_interval - should succeed.
    const alert3 = manager.checkAndAlert(health, 1000 + AlertManager.min_alert_interval_ns + 1);
    try std.testing.expect(alert3 != null);
}

test "AlertManager: alertRebuildStarted" {
    var manager = AlertManager{};

    const alert = manager.alertRebuildStarted(5000);
    try std.testing.expectEqual(AlertType.rebuild_in_progress, alert.alert_type);
    try std.testing.expectEqual(AlertSeverity.info, alert.severity);
    try std.testing.expectEqual(@as(u64, 5000), alert.timestamp_ns);
    try std.testing.expectEqual(@as(u64, 1), manager.metrics.rebuilds_started);
}

test "AlertManager: alertRebuildCompleted" {
    var manager = AlertManager{};

    // Start and complete rebuild.
    _ = manager.alertRebuildStarted(1000);
    const alert = manager.alertRebuildCompleted(2000, 100, 25);

    try std.testing.expectEqual(AlertType.rebuild_completed, alert.alert_type);
    try std.testing.expectEqual(AlertSeverity.info, alert.severity);
    try std.testing.expectEqual(@as(f64, 100), alert.current_value);
    try std.testing.expectEqual(@as(f64, 25), alert.threshold);
    try std.testing.expectEqual(@as(u64, 1), manager.metrics.rebuilds_completed);
    try std.testing.expectEqual(@as(u64, 100), manager.metrics.total_entries_copied);
    try std.testing.expectEqual(@as(u64, 25), manager.metrics.total_tombstones_reclaimed);
}

test "Alert: format output" {
    const alert = Alert{
        .alert_type = .tombstone_degradation,
        .severity = .warning,
        .current_value = 0.15,
        .threshold = 0.10,
        .timestamp_ns = 1000,
        .message = "Test message",
    };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try alert.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "[warning]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "tombstone_degradation") != null);
}
