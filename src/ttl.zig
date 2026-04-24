// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! TTL (Time-to-Live) expiration and cleanup module.
//!
//! Key features:
//! - Expiration calculation with overflow protection
//! - Lazy expiration during index lookup
//! - Background cleanup scanning
//! - Atomic removal with race condition protection
//!
//! TTL Design:
//! - `ttl_seconds = 0` means the event never expires (infinite retention)
//! - `ttl_seconds > 0` means the event expires after that many seconds from its timestamp
//! - Timestamp is extracted from the lower 64 bits of the composite ID (latest_id)
//!
//! Timestamp Sources (CRITICAL):
//! - Query operations: Use consensus_timestamp from VSR commit (deterministic across replicas)
//! - Background cleanup: May use clock.now_synchronized() (acceptable for non-critical timing)

const std = @import("std");
const assert = std.debug.assert;

/// Nanoseconds per second for TTL calculations.
pub const ns_per_second: u64 = 1_000_000_000;

/// Default cleanup configuration.
pub const Config = struct {
    /// Interval between background cleanup runs (milliseconds).
    /// Default: 5 minutes = 300,000ms.
    /// Configurable via --ttl-cleanup-interval-ms.
    cleanup_interval_ms: u32 = 5 * 60 * 1000,

    /// Number of index entries to scan per cleanup run.
    /// Default: 1,000,000 entries.
    /// Higher values = faster full scan, but more CPU per run.
    batch_size: u32 = 1_000_000,

    /// Maximum time allowed for a single cleanup batch (milliseconds).
    /// If exceeded, the batch is interrupted and resumed on next run.
    batch_timeout_ms: u32 = 100,
};

/// Default TTL configuration.
pub const default_config = Config{};

// ============================================================================
// TTL Extension on Read
// ============================================================================

/// TTL Extension configuration.
pub const ExtensionConfig = struct {
    /// Whether TTL extension on read is enabled.
    enabled: bool = false,

    /// Amount of time to extend TTL by (seconds).
    /// Default: 1 day = 86,400 seconds.
    extension_amount_seconds: u32 = 86_400,

    /// Maximum total TTL after extension (seconds).
    /// Default: 30 days = 2,592,000 seconds.
    max_ttl_seconds: u32 = 2_592_000,

    /// Minimum time between extensions for same entity (seconds).
    /// Default: 1 hour = 3,600 seconds.
    cooldown_seconds: u32 = 3_600,

    /// Maximum number of extensions allowed per entity (0 = unlimited).
    max_extension_count: u32 = 0,
};

/// Default TTL extension configuration (disabled by default).
pub const default_extension_config = ExtensionConfig{};

/// Result of attempting to extend an entity's TTL.
pub const ExtensionResult = enum(u8) {
    /// TTL was successfully extended.
    extended,
    /// Extension is disabled globally.
    disabled,
    /// Entity has reached maximum TTL.
    max_ttl_reached,
    /// Entity has reached maximum extension count.
    max_count_exceeded,
    /// Cooldown period has not elapsed.
    cooldown_active,
    /// Entity has no_auto_extend flag set.
    no_auto_extend,
    /// Entity has no TTL (ttl_seconds = 0).
    no_ttl,
};

/// Metadata for tracking TTL extension state per entity.
/// This is stored alongside the IndexEntry (or in extended metadata).
pub const ExtensionMetadata = struct {
    /// Original TTL at insertion time (seconds).
    original_ttl_seconds: u32 = 0,
    /// Current effective TTL (seconds).
    current_ttl_seconds: u32 = 0,
    /// Number of times TTL has been extended.
    extension_count: u32 = 0,
    /// Timestamp of last extension (nanoseconds).
    last_extension_time_ns: u64 = 0,
    /// Whether auto-extension is disabled for this entity.
    no_auto_extend: bool = false,
};

/// Check if an entity's TTL can be extended and calculate the new TTL.
///
/// Arguments:
/// - current_ttl_seconds: The entity's current TTL
/// - metadata: Extension metadata for this entity (may be null for first read)
/// - config: Extension configuration
/// - current_time_ns: Current timestamp (nanoseconds)
///
/// Returns:
/// - ExtensionResult indicating whether extension is allowed
/// - New TTL value (only valid if result is .extended)
pub fn check_extension(
    current_ttl_seconds: u32,
    metadata: ?ExtensionMetadata,
    config: ExtensionConfig,
    current_time_ns: u64,
) struct { result: ExtensionResult, new_ttl_seconds: u32 } {
    // Check if extension is globally disabled.
    if (!config.enabled) {
        return .{ .result = .disabled, .new_ttl_seconds = current_ttl_seconds };
    }

    // Check if entity has no TTL (infinite retention).
    if (current_ttl_seconds == 0) {
        return .{ .result = .no_ttl, .new_ttl_seconds = 0 };
    }

    // Check metadata constraints if present.
    if (metadata) |m| {
        // Check no_auto_extend flag.
        if (m.no_auto_extend) {
            return .{ .result = .no_auto_extend, .new_ttl_seconds = current_ttl_seconds };
        }

        // Check max extension count.
        if (config.max_extension_count > 0 and m.extension_count >= config.max_extension_count) {
            return .{ .result = .max_count_exceeded, .new_ttl_seconds = current_ttl_seconds };
        }

        // Check cooldown period.
        if (m.last_extension_time_ns > 0) {
            const cooldown_ns: u64 = @as(u64, config.cooldown_seconds) * ns_per_second;
            const elapsed = current_time_ns -| m.last_extension_time_ns;
            if (elapsed < cooldown_ns) {
                return .{ .result = .cooldown_active, .new_ttl_seconds = current_ttl_seconds };
            }
        }
    }

    // Calculate new TTL (current + extension amount, capped at max).
    const new_ttl = @min(
        current_ttl_seconds + config.extension_amount_seconds,
        config.max_ttl_seconds,
    );

    // Check if already at max TTL.
    if (new_ttl == current_ttl_seconds) {
        return .{ .result = .max_ttl_reached, .new_ttl_seconds = current_ttl_seconds };
    }

    return .{ .result = .extended, .new_ttl_seconds = new_ttl };
}

/// TTL Extension metrics for observability.
pub const ExtensionMetrics = struct {
    /// Total extensions performed.
    extensions_total: u64 = 0,
    /// Extensions skipped due to cooldown.
    skipped_cooldown: u64 = 0,
    /// Extensions skipped due to max TTL reached.
    skipped_max_ttl: u64 = 0,
    /// Extensions skipped due to max count exceeded.
    skipped_max_count: u64 = 0,
    /// Extensions skipped due to no_auto_extend flag.
    skipped_no_auto_extend: u64 = 0,
    /// Extensions skipped due to disabled.
    skipped_disabled: u64 = 0,

    /// Record an extension attempt result.
    pub fn record(self: *ExtensionMetrics, result: ExtensionResult) void {
        switch (result) {
            .extended => self.extensions_total += 1,
            .cooldown_active => self.skipped_cooldown += 1,
            .max_ttl_reached => self.skipped_max_ttl += 1,
            .max_count_exceeded => self.skipped_max_count += 1,
            .no_auto_extend => self.skipped_no_auto_extend += 1,
            .disabled => self.skipped_disabled += 1,
            .no_ttl => {}, // Not counted as a skip
        }
    }

    /// Get total skipped extensions.
    pub fn total_skipped(self: ExtensionMetrics) u64 {
        return self.skipped_cooldown +
            self.skipped_max_ttl +
            self.skipped_max_count +
            self.skipped_no_auto_extend +
            self.skipped_disabled;
    }
};

/// Result of expiration check.
pub const ExpirationResult = struct {
    /// Whether the entry is expired.
    expired: bool,
    /// Calculated expiration timestamp (nanoseconds).
    /// Only valid if expired is false and ttl_seconds > 0.
    expiration_time_ns: u64,
};

/// Check if an entry is expired given its timestamp, TTL, and current time.
///
/// This function implements the expiration calculation with overflow protection
/// as specified in the TTL spec.
///
/// Arguments:
/// - event_timestamp_ns: The timestamp from the event's composite ID (lower 64 bits of latest_id)
/// - ttl_seconds: The TTL value (0 = never expires)
/// - current_time_ns: The current time in nanoseconds (consensus or wall clock)
///
/// Returns:
/// - ExpirationResult with expired flag and expiration_time_ns
///
/// Overflow Protection:
/// If timestamp + TTL would exceed u64 max, treat as never expires.
/// This is theoretically possible for timestamps near year 2554 with 136-year TTL.
pub fn is_expired(
    event_timestamp_ns: u64,
    ttl_seconds: u32,
    current_time_ns: u64,
) ExpirationResult {
    // TTL of 0 means never expires.
    if (ttl_seconds == 0) {
        return .{
            .expired = false,
            .expiration_time_ns = std.math.maxInt(u64),
        };
    }

    // Convert TTL from seconds to nanoseconds.
    const ttl_ns: u64 = @as(u64, ttl_seconds) * ns_per_second;

    // Overflow protection: if ttl_ns > maxInt(u64) - event_timestamp_ns,
    // then adding them would overflow. Treat as never expires.
    const max_addable = std.math.maxInt(u64) - event_timestamp_ns;
    if (ttl_ns > max_addable) {
        // Overflow would occur - treat as never expires (safe default).
        return .{
            .expired = false,
            .expiration_time_ns = std.math.maxInt(u64),
        };
    }

    // Safe to add without overflow.
    const expiration_time_ns = event_timestamp_ns + ttl_ns;

    return .{
        .expired = current_time_ns >= expiration_time_ns,
        .expiration_time_ns = expiration_time_ns,
    };
}

/// Check expiration using an IndexEntry-like struct.
///
/// This is a convenience wrapper that extracts the timestamp from the composite ID.
/// The entry must have:
/// - latest_id: u128 (timestamp in lower 64 bits)
/// - ttl_seconds: u32
pub fn is_entry_expired(entry: anytype, current_time_ns: u64) ExpirationResult {
    const event_timestamp_ns = @as(u64, @truncate(entry.latest_id));
    return is_expired(event_timestamp_ns, entry.ttl_seconds, current_time_ns);
}

/// Cleanup request body (64 bytes, cache-line aligned).
///
/// Used for the cleanup_expired operation (opcode 0x30).
pub const CleanupRequest = extern struct {
    /// Number of index entries to scan (0 = scan all).
    batch_size: u32 = 0,

    /// Reserved for future use.
    reserved: [60]u8 = [_]u8{0} ** 60,

    comptime {
        assert(@sizeOf(CleanupRequest) == 64);
    }
};

/// Cleanup response body (64 bytes, cache-line aligned).
///
/// Returned from the cleanup_expired operation.
pub const CleanupResponse = extern struct {
    /// Number of index entries scanned in this operation.
    entries_scanned: u64 = 0,

    /// Number of expired entries removed from the index.
    entries_removed: u64 = 0,

    /// Reserved for future use.
    reserved: [48]u8 = [_]u8{0} ** 48,

    comptime {
        assert(@sizeOf(CleanupResponse) == 64);
    }
};

// ============================================================================
// Manual TTL Operations
// ============================================================================

/// TTL operation result codes.
pub const TtlOperationResult = enum(u8) {
    /// Operation succeeded.
    success = 0,
    /// Entity not found.
    entity_not_found = 1,
    /// Invalid TTL value.
    invalid_ttl = 2,
    /// Operation not permitted.
    not_permitted = 3,
    /// Entity is immutable (system entity).
    entity_immutable = 4,
    /// Replica's storage is at capacity; the TTL mutation was refused. Transient —
    /// retry against a healthy replica after operator mitigation. Mirrors the
    /// `storage_space_exhausted` variants on `InsertGeoEventResult` and
    /// `DeleteEntityResult`.
    storage_space_exhausted = 5,
};

/// Request to set absolute TTL for an entity (64 bytes).
///
/// CLI: `archerdb ttl set <entity_id> --ttl=<seconds>`
pub const TtlSetRequest = extern struct {
    /// Entity ID to modify.
    entity_id: u128,

    /// New TTL value in seconds (0 = infinite, see ttl_clear for explicit clear).
    ttl_seconds: u32,

    /// Reserved for future flags.
    flags: u32 = 0,

    /// Reserved for future use.
    reserved: [40]u8 = [_]u8{0} ** 40,

    comptime {
        assert(@sizeOf(TtlSetRequest) == 64);
    }
};

/// Response from TTL set operation (64 bytes).
pub const TtlSetResponse = extern struct {
    /// Entity ID that was modified.
    entity_id: u128,

    /// Previous TTL value in seconds.
    previous_ttl_seconds: u32,

    /// New TTL value in seconds.
    new_ttl_seconds: u32,

    /// Operation result.
    result: TtlOperationResult,

    /// Reserved for alignment.
    _padding: [3]u8 = [_]u8{0} ** 3,

    /// Reserved for future use.
    reserved: [32]u8 = [_]u8{0} ** 32,

    comptime {
        assert(@sizeOf(TtlSetResponse) == 64);
    }
};

/// Request to extend TTL for an entity by a relative amount (64 bytes).
///
/// CLI: `archerdb ttl extend <entity_id> --by=<seconds>`
pub const TtlExtendRequest = extern struct {
    /// Entity ID to modify.
    entity_id: u128,

    /// Amount to extend TTL by (seconds).
    extend_by_seconds: u32,

    /// Reserved for future flags.
    flags: u32 = 0,

    /// Reserved for future use.
    reserved: [40]u8 = [_]u8{0} ** 40,

    comptime {
        assert(@sizeOf(TtlExtendRequest) == 64);
    }
};

/// Response from TTL extend operation (64 bytes).
pub const TtlExtendResponse = extern struct {
    /// Entity ID that was modified.
    entity_id: u128,

    /// Previous TTL value in seconds.
    previous_ttl_seconds: u32,

    /// New TTL value in seconds.
    new_ttl_seconds: u32,

    /// Operation result.
    result: TtlOperationResult,

    /// Reserved for alignment.
    _padding: [3]u8 = [_]u8{0} ** 3,

    /// Reserved for future use.
    reserved: [32]u8 = [_]u8{0} ** 32,

    comptime {
        assert(@sizeOf(TtlExtendResponse) == 64);
    }
};

/// Request to clear TTL for an entity (infinite retention) (64 bytes).
///
/// CLI: `archerdb ttl clear <entity_id>`
pub const TtlClearRequest = extern struct {
    /// Entity ID to modify.
    entity_id: u128,

    /// Reserved for future flags.
    flags: u32 = 0,

    /// Reserved for future use.
    reserved: [44]u8 = [_]u8{0} ** 44,

    comptime {
        assert(@sizeOf(TtlClearRequest) == 64);
    }
};

/// Response from TTL clear operation (64 bytes).
pub const TtlClearResponse = extern struct {
    /// Entity ID that was modified.
    entity_id: u128,

    /// Previous TTL value in seconds.
    previous_ttl_seconds: u32,

    /// Operation result.
    result: TtlOperationResult,

    /// Reserved for alignment.
    _padding: [3]u8 = [_]u8{0} ** 3,

    /// Reserved for future use.
    reserved: [36]u8 = [_]u8{0} ** 36,

    comptime {
        assert(@sizeOf(TtlClearResponse) == 64);
    }
};

/// Background cleanup scanner state.
///
/// Tracks the position in the index for incremental scanning.
/// Reset to 0 on system restart (not persisted).
pub const CleanupScanner = struct {
    /// Current position in the index (entry offset).
    position: u64,

    /// Total entries scanned across all runs.
    total_scanned: u64,

    /// Total entries removed across all runs.
    total_removed: u64,

    /// Timestamp of last cleanup run (nanoseconds).
    last_run_ns: u64,

    /// Initialize scanner at position 0.
    pub fn init() CleanupScanner {
        return .{
            .position = 0,
            .total_scanned = 0,
            .total_removed = 0,
            .last_run_ns = 0,
        };
    }

    /// Reset scanner position (e.g., after index rebuild).
    pub fn reset(self: *CleanupScanner) void {
        self.position = 0;
        // Keep statistics.
    }

    /// Check if a cleanup run is due based on the interval.
    pub fn is_due(self: CleanupScanner, current_time_ns: u64, config: Config) bool {
        const interval_ns = @as(u64, config.cleanup_interval_ms) * 1_000_000;
        return current_time_ns >= self.last_run_ns + interval_ns;
    }

    /// Update state after a cleanup batch.
    pub fn record_batch(
        self: *CleanupScanner,
        entries_scanned: u64,
        entries_removed: u64,
        new_position: u64,
        run_time_ns: u64,
    ) void {
        self.position = new_position;
        self.total_scanned += entries_scanned;
        self.total_removed += entries_removed;
        self.last_run_ns = run_time_ns;
    }
};

/// TTL-related metrics for observability.
pub const TtlMetrics = struct {
    /// Events expired during lookup (lazy expiration).
    expirations_on_lookup: u64 = 0,

    /// Events expired during background cleanup.
    expirations_on_cleanup: u64 = 0,

    /// Events expired during compaction.
    expirations_on_compaction: u64 = 0,

    /// Explicit cleanup_expired() operations executed.
    cleanup_operations: u64 = 0,

    /// Increment lookup expiration counter.
    pub fn record_lookup_expiration(self: *TtlMetrics) void {
        self.expirations_on_lookup += 1;
    }

    /// Increment cleanup expiration counter.
    pub fn record_cleanup_expiration(self: *TtlMetrics, count: u64) void {
        self.expirations_on_cleanup += count;
    }

    /// Increment compaction expiration counter.
    pub fn record_compaction_expiration(self: *TtlMetrics, count: u64) void {
        self.expirations_on_compaction += count;
    }

    /// Record a cleanup operation.
    pub fn record_cleanup_operation(self: *TtlMetrics) void {
        self.cleanup_operations += 1;
    }

    /// Get total expirations across all paths.
    pub fn total_expirations(self: TtlMetrics) u64 {
        return self.expirations_on_lookup +
            self.expirations_on_cleanup +
            self.expirations_on_compaction;
    }
};

/// Statistics for compaction with TTL and liveness checks.
///
/// Per ttl-retention/spec.md, compaction tracks:
/// - Events discarded due to TTL expiration
/// - Events discarded because superseded by newer version
/// - Events copied forward (still live)
pub const CompactionStats = struct {
    /// Events discarded due to TTL expiration.
    events_expired: u64 = 0,

    /// Events discarded because superseded by newer version (not in index).
    events_superseded: u64 = 0,

    /// Events copied forward (still live in index).
    events_copied: u64 = 0,

    /// Total events processed in this compaction.
    pub fn total_events(self: CompactionStats) u64 {
        return self.events_expired + self.events_superseded + self.events_copied;
    }

    /// Expiration rate (fraction of events discarded due to TTL).
    pub fn expiration_rate(self: CompactionStats) f32 {
        const total = self.total_events();
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.events_expired)) /
            @as(f32, @floatFromInt(total));
    }

    /// Record an expired event during compaction.
    pub fn record_expired(self: *CompactionStats) void {
        self.events_expired += 1;
    }

    /// Record a superseded event during compaction.
    pub fn record_superseded(self: *CompactionStats) void {
        self.events_superseded += 1;
    }

    /// Record a copied event during compaction.
    pub fn record_copied(self: *CompactionStats) void {
        self.events_copied += 1;
    }

    /// Merge stats from another compaction.
    pub fn merge(self: *CompactionStats, other: CompactionStats) void {
        self.events_expired += other.events_expired;
        self.events_superseded += other.events_superseded;
        self.events_copied += other.events_copied;
    }
};

/// Prometheus-formatted TTL metrics.
///
/// Per ttl-retention/spec.md, exposes:
/// - archerdb_index_expirations_total (counter)
/// - archerdb_compaction_events_expired_total (counter)
/// - archerdb_cleanup_entries_removed_total (counter)
/// - archerdb_index_expired_entries_estimate (gauge)
pub const TtlPrometheusMetrics = struct {
    /// Format TtlMetrics as Prometheus text format.
    pub fn format_ttl_metrics(
        writer: anytype,
        metrics: *const TtlMetrics,
        labels: []const u8,
    ) !void {
        // Events expired during lookup.
        try writer.print(
            \\# HELP archerdb_index_expirations_total Events expired during lookup
            \\# TYPE archerdb_index_expirations_total counter
            \\archerdb_index_expirations_total{{{s}}} {d}
            \\
        , .{ labels, metrics.expirations_on_lookup });

        // Events expired during background cleanup.
        try writer.print(
            \\# HELP archerdb_cleanup_entries_removed_total Entries removed via cleanup
            \\# TYPE archerdb_cleanup_entries_removed_total counter
            \\archerdb_cleanup_entries_removed_total{{{s}}} {d}
            \\
        , .{ labels, metrics.expirations_on_cleanup });

        // Events expired during compaction.
        try writer.print(
            \\# HELP archerdb_compaction_events_expired_total Events expired during compaction
            \\# TYPE archerdb_compaction_events_expired_total counter
            \\archerdb_compaction_events_expired_total{{{s}}} {d}
            \\
        , .{ labels, metrics.expirations_on_compaction });

        // Total expirations across all paths.
        try writer.print(
            \\# HELP archerdb_ttl_expirations_total Total TTL expirations
            \\# TYPE archerdb_ttl_expirations_total counter
            \\archerdb_ttl_expirations_total{{{s}}} {d}
            \\
        , .{ labels, metrics.total_expirations() });

        // Cleanup operations count.
        try writer.print(
            \\# HELP archerdb_cleanup_operations_total Explicit cleanup operations
            \\# TYPE archerdb_cleanup_operations_total counter
            \\archerdb_cleanup_operations_total{{{s}}} {d}
            \\
        , .{ labels, metrics.cleanup_operations });
    }

    /// Format CompactionStats as Prometheus text format.
    pub fn format_compaction_stats(
        writer: anytype,
        stats: *const CompactionStats,
        labels: []const u8,
    ) !void {
        try writer.print(
            \\# HELP archerdb_compaction_events_expired Events expired in compaction
            \\# TYPE archerdb_compaction_events_expired counter
            \\archerdb_compaction_events_expired{{{s}}} {d}
            \\
        , .{ labels, stats.events_expired });

        try writer.print(
            \\# HELP archerdb_compaction_events_superseded Events superseded in compaction
            \\# TYPE archerdb_compaction_events_superseded counter
            \\archerdb_compaction_events_superseded{{{s}}} {d}
            \\
        , .{ labels, stats.events_superseded });

        try writer.print(
            \\# HELP archerdb_compaction_events_copied Events copied in compaction
            \\# TYPE archerdb_compaction_events_copied counter
            \\archerdb_compaction_events_copied{{{s}}} {d}
            \\
        , .{ labels, stats.events_copied });

        try writer.print(
            \\# HELP archerdb_compaction_expiration_rate Fraction of events expired
            \\# TYPE archerdb_compaction_expiration_rate gauge
            \\archerdb_compaction_expiration_rate{{{s}}} {d:.4}
            \\
        , .{ labels, stats.expiration_rate() });
    }

    /// Format CleanupScanner state as Prometheus text format.
    pub fn format_scanner_state(
        writer: anytype,
        scanner: *const CleanupScanner,
        labels: []const u8,
    ) !void {
        try writer.print(
            \\# HELP archerdb_ttl_scanner_position Current scan position
            \\# TYPE archerdb_ttl_scanner_position gauge
            \\archerdb_ttl_scanner_position{{{s}}} {d}
            \\
        , .{ labels, scanner.position });

        try writer.print(
            \\# HELP archerdb_ttl_scanner_total_scanned Total entries scanned
            \\# TYPE archerdb_ttl_scanner_total_scanned counter
            \\archerdb_ttl_scanner_total_scanned{{{s}}} {d}
            \\
        , .{ labels, scanner.total_scanned });

        try writer.print(
            \\# HELP archerdb_ttl_scanner_total_removed Total entries removed
            \\# TYPE archerdb_ttl_scanner_total_removed counter
            \\archerdb_ttl_scanner_total_removed{{{s}}} {d}
            \\
        , .{ labels, scanner.total_removed });
    }
};

/// Validate TTL value for insertion.
///
/// Per the spec, all u32 values are valid:
/// - ttl_seconds = 0: Never expires
/// - 1 <= ttl_seconds <= maxInt(u32): Expires after that many seconds
///
/// Returns error if the event would already be expired upon insertion
/// (only applies to imported events with past timestamps).
pub fn validate_ttl_on_insert(
    event_timestamp_ns: u64,
    ttl_seconds: u32,
    current_time_ns: u64,
) error{EventAlreadyExpired}!void {
    // All u32 TTL values are valid by definition.
    // However, we reject events that are already expired at insertion time
    // (edge case for imported events with past timestamps).
    if (ttl_seconds == 0) {
        // Never expires - always valid.
        return;
    }

    const result = is_expired(event_timestamp_ns, ttl_seconds, current_time_ns);
    if (result.expired) {
        return error.EventAlreadyExpired;
    }
}

/// Calculate remaining TTL for an entry.
///
/// Returns:
/// - null if the entry never expires (ttl_seconds = 0)
/// - 0 if the entry is expired
/// - remaining seconds otherwise
pub fn remaining_ttl_seconds(
    event_timestamp_ns: u64,
    ttl_seconds: u32,
    current_time_ns: u64,
) ?u64 {
    if (ttl_seconds == 0) {
        return null; // Never expires.
    }

    const result = is_expired(event_timestamp_ns, ttl_seconds, current_time_ns);
    if (result.expired) {
        return 0;
    }

    // Calculate remaining time in nanoseconds, then convert to seconds.
    const remaining_ns = result.expiration_time_ns - current_time_ns;
    return remaining_ns / ns_per_second;
}

/// Result of a tombstone batch operation.
pub const TombstoneBatchResult = struct {
    /// Number of tombstones generated.
    count: u64,
    /// Timestamp used for all tombstones in this batch.
    batch_timestamp_ns: u64,
};

/// Statistics for tombstone generation.
pub const TombstoneStats = struct {
    /// Tombstones generated from TTL expiration.
    ttl_expirations: u64 = 0,
    /// Tombstones generated from explicit deletion (GDPR).
    explicit_deletions: u64 = 0,

    /// Record TTL expiration tombstones.
    pub fn record_ttl_expirations(self: *TombstoneStats, count: u64) void {
        self.ttl_expirations += count;
    }

    /// Record explicit deletion tombstones.
    pub fn record_explicit_deletions(self: *TombstoneStats, count: u64) void {
        self.explicit_deletions += count;
    }

    /// Get total tombstones generated.
    pub fn total(self: TombstoneStats) u64 {
        return self.ttl_expirations + self.explicit_deletions;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "is_expired: ttl_seconds = 0 never expires" {
    const result = is_expired(1_000_000_000, 0, std.math.maxInt(u64));
    try std.testing.expect(!result.expired);
    try std.testing.expectEqual(std.math.maxInt(u64), result.expiration_time_ns);
}

test "is_expired: entry not yet expired" {
    // Event at timestamp 1 second, TTL 10 seconds.
    // Current time: 5 seconds. Expiration: 11 seconds.
    const event_ts = 1 * ns_per_second;
    const ttl: u32 = 10;
    const current_time = 5 * ns_per_second;

    const result = is_expired(event_ts, ttl, current_time);
    try std.testing.expect(!result.expired);
    try std.testing.expectEqual(11 * ns_per_second, result.expiration_time_ns);
}

test "is_expired: entry is expired" {
    // Event at timestamp 1 second, TTL 10 seconds.
    // Current time: 15 seconds. Expiration: 11 seconds (already passed).
    const event_ts = 1 * ns_per_second;
    const ttl: u32 = 10;
    const current_time = 15 * ns_per_second;

    const result = is_expired(event_ts, ttl, current_time);
    try std.testing.expect(result.expired);
    try std.testing.expectEqual(11 * ns_per_second, result.expiration_time_ns);
}

test "is_expired: exactly at expiration time is expired" {
    // Event at timestamp 1 second, TTL 10 seconds.
    // Current time: exactly 11 seconds (expiration boundary).
    const event_ts = 1 * ns_per_second;
    const ttl: u32 = 10;
    const current_time = 11 * ns_per_second;

    const result = is_expired(event_ts, ttl, current_time);
    try std.testing.expect(result.expired);
}

test "is_expired: overflow protection" {
    // Event at near maxInt timestamp, with large TTL.
    // Should NOT overflow, treat as never expires.
    const event_ts = std.math.maxInt(u64) - 1_000_000_000;
    const ttl: u32 = 100; // 100 seconds = 100B ns, would overflow.
    const current_time = std.math.maxInt(u64);

    const result = is_expired(event_ts, ttl, current_time);
    try std.testing.expect(!result.expired);
    try std.testing.expectEqual(std.math.maxInt(u64), result.expiration_time_ns);
}

test "is_entry_expired: wrapper function" {
    const MockEntry = struct {
        latest_id: u128,
        ttl_seconds: u32,
    };

    const entry = MockEntry{
        .latest_id = (@as(u128, 0xDEADBEEF) << 64) | (5 * ns_per_second),
        .ttl_seconds = 10,
    };

    // Not expired at 10 seconds.
    const result1 = is_entry_expired(entry, 10 * ns_per_second);
    try std.testing.expect(!result1.expired);

    // Expired at 20 seconds.
    const result2 = is_entry_expired(entry, 20 * ns_per_second);
    try std.testing.expect(result2.expired);
}

test "CleanupRequest: size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(CleanupRequest));
}

test "CleanupResponse: size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(CleanupResponse));
}

test "CleanupScanner: is_due calculation" {
    var scanner = CleanupScanner.init();
    const config = Config{ .cleanup_interval_ms = 1000 }; // 1 second interval.

    // Initially (last_run_ns = 0), cleanup is due when current >= 0 + 1 second.
    // At 0.5 seconds, not due yet.
    try std.testing.expect(!scanner.is_due(500_000_000, config));

    // At 1 second exactly, cleanup is due.
    try std.testing.expect(scanner.is_due(1 * ns_per_second, config));

    // Record a run at 1 second.
    scanner.record_batch(100, 5, 100, 1 * ns_per_second);

    // Not due at 1.5 seconds (only 0.5 seconds since last run).
    try std.testing.expect(!scanner.is_due(1_500_000_000, config));

    // Due at 2.5 seconds (1.5 seconds since last run, exceeds 1 second interval).
    try std.testing.expect(scanner.is_due(2_500_000_000, config));
}

test "TtlMetrics: counters" {
    var metrics = TtlMetrics{};

    metrics.record_lookup_expiration();
    metrics.record_lookup_expiration();
    metrics.record_cleanup_expiration(10);
    metrics.record_compaction_expiration(5);

    try std.testing.expectEqual(@as(u64, 2), metrics.expirations_on_lookup);
    try std.testing.expectEqual(@as(u64, 10), metrics.expirations_on_cleanup);
    try std.testing.expectEqual(@as(u64, 5), metrics.expirations_on_compaction);
    try std.testing.expectEqual(@as(u64, 17), metrics.total_expirations());
}

test "CompactionStats: counters and calculations" {
    var stats = CompactionStats{};

    // Record some events.
    stats.record_expired();
    stats.record_expired();
    stats.record_superseded();
    stats.record_superseded();
    stats.record_superseded();
    stats.record_copied();
    stats.record_copied();
    stats.record_copied();
    stats.record_copied();
    stats.record_copied();

    // Verify counts: 2 expired, 3 superseded, 5 copied.
    try std.testing.expectEqual(@as(u64, 2), stats.events_expired);
    try std.testing.expectEqual(@as(u64, 3), stats.events_superseded);
    try std.testing.expectEqual(@as(u64, 5), stats.events_copied);
    try std.testing.expectEqual(@as(u64, 10), stats.total_events());

    // Expiration rate: 2/10 = 0.2
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), stats.expiration_rate(), 0.001);
}

test "CompactionStats: merge" {
    var stats1 = CompactionStats{};
    stats1.record_expired();
    stats1.record_copied();

    var stats2 = CompactionStats{};
    stats2.events_expired = 5;
    stats2.events_superseded = 3;
    stats2.events_copied = 10;

    stats1.merge(stats2);

    try std.testing.expectEqual(@as(u64, 6), stats1.events_expired);
    try std.testing.expectEqual(@as(u64, 3), stats1.events_superseded);
    try std.testing.expectEqual(@as(u64, 11), stats1.events_copied);
}

test "validate_ttl_on_insert: accepts valid TTL" {
    // Event at current time, TTL 3600 seconds.
    const now = 1_000 * ns_per_second;
    try validate_ttl_on_insert(now, 3600, now);
    try validate_ttl_on_insert(now, 0, now); // Never expires.
}

test "validate_ttl_on_insert: rejects already expired" {
    // Event at past time, already expired.
    const event_ts = 1 * ns_per_second;
    const current = 100 * ns_per_second;
    const ttl: u32 = 10; // Expires at 11 seconds, but we're at 100.

    const result = validate_ttl_on_insert(event_ts, ttl, current);
    try std.testing.expectError(error.EventAlreadyExpired, result);
}

test "remaining_ttl_seconds: calculation" {
    const event_ts = 10 * ns_per_second;
    const ttl: u32 = 100;
    const current = 50 * ns_per_second;

    // Expiration at 110 seconds, current at 50. Remaining: 60 seconds.
    const remaining = remaining_ttl_seconds(event_ts, ttl, current);
    try std.testing.expectEqual(@as(?u64, 60), remaining);
}

test "remaining_ttl_seconds: never expires returns null" {
    const remaining = remaining_ttl_seconds(1 * ns_per_second, 0, 1000 * ns_per_second);
    try std.testing.expectEqual(@as(?u64, null), remaining);
}

test "remaining_ttl_seconds: expired returns 0" {
    const event_ts = 1 * ns_per_second;
    const ttl: u32 = 10;
    const current = 100 * ns_per_second; // Well past expiration.

    const remaining = remaining_ttl_seconds(event_ts, ttl, current);
    try std.testing.expectEqual(@as(?u64, 0), remaining);
}

test "TtlPrometheusMetrics: format_ttl_metrics" {
    var metrics = TtlMetrics{};
    metrics.expirations_on_lookup = 100;
    metrics.expirations_on_cleanup = 50;
    metrics.expirations_on_compaction = 25;
    metrics.cleanup_operations = 10;

    var buffer: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    try TtlPrometheusMetrics.format_ttl_metrics(writer, &metrics, "instance=\"node1\"");
    const output = fbs.getWritten();

    // Verify key metric lines are present.
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "archerdb_index_expirations_total{instance=\"node1\"} 100",
    ));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "archerdb_ttl_expirations_total{instance=\"node1\"} 175",
    ));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "# TYPE archerdb_index_expirations_total counter",
    ));
}

test "TtlPrometheusMetrics: format_compaction_stats" {
    var stats = CompactionStats{};
    stats.events_expired = 20;
    stats.events_superseded = 30;
    stats.events_copied = 50;

    var buffer: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    try TtlPrometheusMetrics.format_compaction_stats(writer, &stats, "level=\"0\"");
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "archerdb_compaction_events_expired{level=\"0\"} 20",
    ));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "archerdb_compaction_events_copied{level=\"0\"} 50",
    ));
    // Expiration rate: 20/100 = 0.2
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "archerdb_compaction_expiration_rate{level=\"0\"} 0.2",
    ));
}

test "TtlPrometheusMetrics: format_scanner_state" {
    var scanner = CleanupScanner.init();
    scanner.position = 5000;
    scanner.total_scanned = 100000;
    scanner.total_removed = 250;

    var buffer: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    try TtlPrometheusMetrics.format_scanner_state(writer, &scanner, "");
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "archerdb_ttl_scanner_position{} 5000",
    ));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "archerdb_ttl_scanner_total_scanned{} 100000",
    ));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "archerdb_ttl_scanner_total_removed{} 250",
    ));
}

// =============================================================================
// TTL-Aware Compaction Prioritization
// =============================================================================
//
// Per ttl-retention/spec.md Non-Goals:
// Implements TTL-aware compaction prioritization to automatically compact
// levels/tables with high expired data ratios.
//

/// Per-level TTL statistics for compaction prioritization.
pub const LevelTtlStats = struct {
    /// LSM level (0-7 typically).
    level: u8,

    /// Total events in this level.
    total_events: u64,

    /// Estimated expired events (sampled).
    estimated_expired: u64,

    /// Last sample timestamp.
    last_sample_ns: u64,

    /// Sample count used for estimation.
    sample_count: u64,

    /// Get expiration ratio for this level.
    pub fn expirationRatio(self: LevelTtlStats) f64 {
        if (self.total_events == 0) return 0.0;
        return @as(f64, @floatFromInt(self.estimated_expired)) /
            @as(f64, @floatFromInt(self.total_events));
    }

    /// Check if this level should be prioritized for compaction.
    /// Threshold: > 30% expired data triggers priority compaction.
    pub fn shouldPrioritize(self: LevelTtlStats) bool {
        return self.expirationRatio() > 0.30;
    }
};

/// TTL-aware compaction prioritizer.
pub const CompactionPrioritizer = struct {
    const MAX_LEVELS: usize = 8;

    /// Statistics per level.
    level_stats: [MAX_LEVELS]LevelTtlStats,

    /// Compaction debt ratio (expired bytes / total bytes).
    debt_ratio: f64,

    /// High water mark for triggering aggressive compaction.
    high_water_mark: f64,

    /// Low water mark for normal compaction.
    low_water_mark: f64,

    /// Initialize the compaction prioritizer.
    pub fn init() CompactionPrioritizer {
        var stats: [MAX_LEVELS]LevelTtlStats = undefined;
        for (&stats, 0..) |*s, i| {
            s.* = .{
                .level = @intCast(i),
                .total_events = 0,
                .estimated_expired = 0,
                .last_sample_ns = 0,
                .sample_count = 0,
            };
        }

        return .{
            .level_stats = stats,
            .debt_ratio = 0.0,
            .high_water_mark = 0.50, // 50% expired triggers aggressive compaction
            .low_water_mark = 0.20, // 20% expired is normal
        };
    }

    /// Update level statistics from sampling.
    pub fn updateLevelStats(
        self: *CompactionPrioritizer,
        level: u8,
        total_events: u64,
        sampled_expired: u64,
        sample_size: u64,
        current_time_ns: u64,
    ) void {
        if (level >= MAX_LEVELS) return;

        // Extrapolate expired count from sample
        const ratio = if (sample_size > 0)
            @as(f64, @floatFromInt(sampled_expired)) / @as(f64, @floatFromInt(sample_size))
        else
            0.0;
        const estimated = @as(u64, @intFromFloat(ratio * @as(f64, @floatFromInt(total_events))));

        self.level_stats[level] = .{
            .level = level,
            .total_events = total_events,
            .estimated_expired = estimated,
            .last_sample_ns = current_time_ns,
            .sample_count = sample_size,
        };

        self.updateDebtRatio();
    }

    /// Update overall compaction debt ratio.
    fn updateDebtRatio(self: *CompactionPrioritizer) void {
        var total_events: u64 = 0;
        var total_expired: u64 = 0;

        for (&self.level_stats) |*s| {
            total_events += s.total_events;
            total_expired += s.estimated_expired;
        }

        self.debt_ratio = if (total_events > 0)
            @as(f64, @floatFromInt(total_expired)) / @as(f64, @floatFromInt(total_events))
        else
            0.0;
    }

    /// Get levels that should be prioritized for compaction.
    pub fn getPriorityLevels(self: *const CompactionPrioritizer) []const u8 {
        var result: [MAX_LEVELS]u8 = undefined;
        var count: usize = 0;

        for (&self.level_stats) |*s| {
            if (s.shouldPrioritize()) {
                result[count] = s.level;
                count += 1;
            }
        }

        return result[0..count];
    }

    /// Check if aggressive compaction is needed.
    pub fn isAggressiveCompactionNeeded(self: *const CompactionPrioritizer) bool {
        return self.debt_ratio > self.high_water_mark;
    }

    /// Get the compaction debt ratio gauge.
    pub fn getDebtRatio(self: *const CompactionPrioritizer) f64 {
        return self.debt_ratio;
    }
};

// =============================================================================
// TTL Cliff Mitigation
// =============================================================================
//
// Per ttl-retention/spec.md Non-Goals:
// Automatic detection and mitigation of upcoming TTL expiration cliffs
// that could cause compaction storms.
//

/// TTL expiration cliff detector and mitigator.
pub const CliffMitigator = struct {
    /// Histogram bucket size for expiration time distribution (1 hour).
    const BUCKET_SIZE_NS: u64 = 3600 * ns_per_second;

    /// Number of histogram buckets (24 hours lookahead).
    const NUM_BUCKETS: usize = 24;

    /// Expiration time histogram.
    expiration_histogram: [NUM_BUCKETS]u64,

    /// Peak threshold for cliff detection.
    cliff_threshold: f64,

    /// Last analysis timestamp.
    last_analysis_ns: u64,

    /// Initialize cliff mitigator.
    pub fn init() CliffMitigator {
        return .{
            .expiration_histogram = [_]u64{0} ** NUM_BUCKETS,
            .cliff_threshold = 3.0, // 3x average = cliff
            .last_analysis_ns = 0,
        };
    }

    /// Reset histogram for new analysis.
    pub fn reset(self: *CliffMitigator) void {
        self.expiration_histogram = [_]u64{0} ** NUM_BUCKETS;
    }

    /// Record an event's expiration time.
    pub fn recordExpiration(
        self: *CliffMitigator,
        expiration_time_ns: u64,
        current_time_ns: u64,
    ) void {
        if (expiration_time_ns <= current_time_ns) return;

        const delta = expiration_time_ns - current_time_ns;
        const bucket = @min(delta / BUCKET_SIZE_NS, NUM_BUCKETS - 1);
        self.expiration_histogram[bucket] += 1;
    }

    /// Analyze histogram for cliffs.
    /// Returns the most severe cliff (highest severity) if any bucket exceeds the threshold.
    pub fn analyzeForCliffs(self: *CliffMitigator, current_time_ns: u64) ?CliffInfo {
        self.last_analysis_ns = current_time_ns;

        // Calculate average events per bucket
        var total: u64 = 0;
        for (self.expiration_histogram) |count| {
            total += count;
        }

        if (total == 0) return null;

        const average = @as(f64, @floatFromInt(total)) / @as(f64, NUM_BUCKETS);
        const threshold = average * self.cliff_threshold;

        // Find the most severe cliff (bucket with highest severity above threshold)
        var max_severity: f64 = 0;
        var max_bucket: ?usize = null;
        var max_count: u64 = 0;

        for (self.expiration_histogram, 0..) |count, bucket| {
            const count_f = @as(f64, @floatFromInt(count));
            if (count_f > threshold) {
                const severity = count_f / average;
                if (severity > max_severity) {
                    max_severity = severity;
                    max_bucket = bucket;
                    max_count = count;
                }
            }
        }

        if (max_bucket) |bucket| {
            const start_time = current_time_ns + bucket * BUCKET_SIZE_NS;
            return CliffInfo{
                .start_time_ns = start_time,
                .end_time_ns = start_time + BUCKET_SIZE_NS,
                .expected_expirations = max_count,
                .severity = max_severity,
            };
        }

        return null;
    }

    /// Get recommended action for cliff mitigation.
    pub fn getRecommendation(self: *const CliffMitigator, cliff: CliffInfo) CliffMitigation {
        _ = self;

        if (cliff.severity > 10.0) {
            return .{
                .action = .emergency_compact,
                .reason = "Severe cliff detected (>10x average)",
            };
        } else if (cliff.severity > 5.0) {
            return .{
                .action = .pre_compact,
                .reason = "Significant cliff detected (>5x average)",
            };
        } else {
            return .{ .action = .monitor, .reason = "Moderate cliff detected, monitoring" };
        }
    }
};

/// Information about a detected TTL cliff.
pub const CliffInfo = struct {
    /// Start of cliff window.
    start_time_ns: u64,
    /// End of cliff window.
    end_time_ns: u64,
    /// Expected expirations in this window.
    expected_expirations: u64,
    /// Severity (ratio to average).
    severity: f64,
};

/// Cliff mitigation action.
pub const CliffMitigation = struct {
    /// Recommended action.
    action: enum {
        /// No action needed.
        none,
        /// Monitor closely.
        monitor,
        /// Pre-emptively compact before cliff.
        pre_compact,
        /// Emergency compaction (severe cliff).
        emergency_compact,
    },
    /// Human-readable reason.
    reason: []const u8,
};

// === TTL Optimization Tests ===

test "LevelTtlStats expirationRatio" {
    const stats = LevelTtlStats{
        .level = 0,
        .total_events = 1000,
        .estimated_expired = 250,
        .last_sample_ns = 0,
        .sample_count = 100,
    };

    try std.testing.expectApproxEqAbs(@as(f64, 0.25), stats.expirationRatio(), 0.001);
    try std.testing.expect(!stats.shouldPrioritize()); // 25% < 30% threshold
}

test "LevelTtlStats shouldPrioritize" {
    const high_ratio = LevelTtlStats{
        .level = 1,
        .total_events = 1000,
        .estimated_expired = 400, // 40% expired
        .last_sample_ns = 0,
        .sample_count = 100,
    };

    try std.testing.expect(high_ratio.shouldPrioritize()); // 40% > 30% threshold
}

test "CompactionPrioritizer basic" {
    var prioritizer = CompactionPrioritizer.init();

    // Initially no debt
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), prioritizer.getDebtRatio(), 0.001);
    try std.testing.expect(!prioritizer.isAggressiveCompactionNeeded());

    // Add level stats with high expiration
    prioritizer.updateLevelStats(0, 10000, 6000, 1000, 1000); // 60% expired

    try std.testing.expect(prioritizer.getDebtRatio() > 0.5);
    try std.testing.expect(prioritizer.isAggressiveCompactionNeeded());
}

test "CliffMitigator detection" {
    var mitigator = CliffMitigator.init();

    const current_time = 1000 * ns_per_second;

    // Record uniform distribution
    for (0..100) |_| {
        mitigator.recordExpiration(current_time + 3600 * ns_per_second, current_time);
    }

    // Record cliff at bucket 5 (5 hours from now)
    for (0..500) |_| {
        mitigator.recordExpiration(current_time + 5 * 3600 * ns_per_second + 100, current_time);
    }

    const cliff = mitigator.analyzeForCliffs(current_time);
    try std.testing.expect(cliff != null);

    if (cliff) |c| {
        try std.testing.expect(c.severity > 3.0);
        try std.testing.expectEqual(@as(u64, 500), c.expected_expirations);
    }
}

test "CliffMitigation recommendations" {
    const mitigator = CliffMitigator.init();

    // Severe cliff
    const severe = CliffInfo{
        .start_time_ns = 0,
        .end_time_ns = 0,
        .expected_expirations = 1000,
        .severity = 12.0,
    };
    const severe_rec = mitigator.getRecommendation(severe);
    try std.testing.expectEqual(severe_rec.action, .emergency_compact);

    // Moderate cliff
    const moderate = CliffInfo{
        .start_time_ns = 0,
        .end_time_ns = 0,
        .expected_expirations = 500,
        .severity = 4.0,
    };
    const moderate_rec = mitigator.getRecommendation(moderate);
    try std.testing.expectEqual(moderate_rec.action, .monitor);
}

// ============================================================================
// TTL Extension Tests
// ============================================================================

test "TTL Extension: disabled by default" {
    const config = default_extension_config;
    const result = check_extension(3600, null, config, 1_000_000_000);
    try std.testing.expectEqual(result.result, ExtensionResult.disabled);
    try std.testing.expectEqual(result.new_ttl_seconds, 3600);
}

test "TTL Extension: no TTL entities not extended" {
    var config = default_extension_config;
    config.enabled = true;
    const result = check_extension(0, null, config, 1_000_000_000);
    try std.testing.expectEqual(result.result, ExtensionResult.no_ttl);
    try std.testing.expectEqual(result.new_ttl_seconds, 0);
}

test "TTL Extension: successful extension" {
    var config = default_extension_config;
    config.enabled = true;
    config.extension_amount_seconds = 3600; // 1 hour
    config.max_ttl_seconds = 86400; // 1 day

    const result = check_extension(7200, null, config, 1_000_000_000);
    try std.testing.expectEqual(result.result, ExtensionResult.extended);
    try std.testing.expectEqual(result.new_ttl_seconds, 10800); // 7200 + 3600
}

test "TTL Extension: capped at max TTL" {
    var config = default_extension_config;
    config.enabled = true;
    config.extension_amount_seconds = 3600;
    config.max_ttl_seconds = 10000;

    const result = check_extension(9000, null, config, 1_000_000_000);
    try std.testing.expectEqual(result.result, ExtensionResult.extended);
    try std.testing.expectEqual(result.new_ttl_seconds, 10000); // capped at max
}

test "TTL Extension: max TTL already reached" {
    var config = default_extension_config;
    config.enabled = true;
    config.extension_amount_seconds = 3600;
    config.max_ttl_seconds = 10000;

    const result = check_extension(10000, null, config, 1_000_000_000);
    try std.testing.expectEqual(result.result, ExtensionResult.max_ttl_reached);
    try std.testing.expectEqual(result.new_ttl_seconds, 10000);
}

test "TTL Extension: cooldown active" {
    var config = default_extension_config;
    config.enabled = true;
    config.cooldown_seconds = 3600; // 1 hour cooldown

    const metadata = ExtensionMetadata{
        .last_extension_time_ns = 1_000_000_000, // Extended at t=1s
        .extension_count = 1,
    };

    // Only 30 minutes have passed
    const current_time = 1_000_000_000 + (1800 * ns_per_second);
    const result = check_extension(7200, metadata, config, current_time);
    try std.testing.expectEqual(result.result, ExtensionResult.cooldown_active);
}

test "TTL Extension: cooldown elapsed" {
    var config = default_extension_config;
    config.enabled = true;
    config.cooldown_seconds = 3600;
    config.extension_amount_seconds = 1800;

    const metadata = ExtensionMetadata{
        .last_extension_time_ns = 1_000_000_000,
        .extension_count = 1,
    };

    // 2 hours have passed
    const current_time = 1_000_000_000 + (7200 * ns_per_second);
    const result = check_extension(7200, metadata, config, current_time);
    try std.testing.expectEqual(result.result, ExtensionResult.extended);
    try std.testing.expectEqual(result.new_ttl_seconds, 9000);
}

test "TTL Extension: max extension count exceeded" {
    var config = default_extension_config;
    config.enabled = true;
    config.max_extension_count = 5;

    const metadata = ExtensionMetadata{
        .extension_count = 5, // Already at max
    };

    const result = check_extension(7200, metadata, config, 1_000_000_000);
    try std.testing.expectEqual(result.result, ExtensionResult.max_count_exceeded);
}

test "TTL Extension: no_auto_extend flag respected" {
    var config = default_extension_config;
    config.enabled = true;

    const metadata = ExtensionMetadata{
        .no_auto_extend = true,
    };

    const result = check_extension(7200, metadata, config, 1_000_000_000);
    try std.testing.expectEqual(result.result, ExtensionResult.no_auto_extend);
}

test "TTL Extension metrics recording" {
    var metrics = ExtensionMetrics{};

    metrics.record(.extended);
    metrics.record(.extended);
    metrics.record(.cooldown_active);
    metrics.record(.max_ttl_reached);

    try std.testing.expectEqual(metrics.extensions_total, 2);
    try std.testing.expectEqual(metrics.skipped_cooldown, 1);
    try std.testing.expectEqual(metrics.skipped_max_ttl, 1);
    try std.testing.expectEqual(metrics.total_skipped(), 2);
}

// ============================================================================
// Manual TTL Operations Tests
// ============================================================================

test "TtlSetRequest: size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(TtlSetRequest));
}

test "TtlSetResponse: size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(TtlSetResponse));
}

test "TtlExtendRequest: size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(TtlExtendRequest));
}

test "TtlExtendResponse: size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(TtlExtendResponse));
}

test "TtlClearRequest: size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(TtlClearRequest));
}

test "TtlClearResponse: size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(TtlClearResponse));
}

test "TtlOperationResult: enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(TtlOperationResult.success));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(TtlOperationResult.entity_not_found));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(TtlOperationResult.invalid_ttl));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(TtlOperationResult.not_permitted));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(TtlOperationResult.entity_immutable));
}

test "TtlSetRequest: field initialization" {
    const request = TtlSetRequest{
        .entity_id = 0x12345678_9ABCDEF0_12345678_9ABCDEF0,
        .ttl_seconds = 86400,
        .flags = 0,
    };
    try std.testing.expectEqual(
        @as(u128, 0x12345678_9ABCDEF0_12345678_9ABCDEF0),
        request.entity_id,
    );
    try std.testing.expectEqual(@as(u32, 86400), request.ttl_seconds);
}

test "TtlSetResponse: default result is entity_not_found" {
    const response = TtlSetResponse{
        .entity_id = 1,
        .previous_ttl_seconds = 0,
        .new_ttl_seconds = 0,
        .result = .entity_not_found,
    };
    try std.testing.expectEqual(TtlOperationResult.entity_not_found, response.result);
}

test "TtlExtendRequest: extend by amount" {
    const request = TtlExtendRequest{
        .entity_id = 12345,
        .extend_by_seconds = 3600, // 1 hour
    };
    try std.testing.expectEqual(@as(u128, 12345), request.entity_id);
    try std.testing.expectEqual(@as(u32, 3600), request.extend_by_seconds);
}

test "TtlClearRequest: entity_id field" {
    const request = TtlClearRequest{
        .entity_id = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF,
    };
    try std.testing.expectEqual(
        @as(u128, 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF),
        request.entity_id,
    );
}

test "TtlClearResponse: reports previous TTL" {
    const response = TtlClearResponse{
        .entity_id = 12345,
        .previous_ttl_seconds = 86400,
        .result = .success,
    };
    try std.testing.expectEqual(@as(u32, 86400), response.previous_ttl_seconds);
    try std.testing.expectEqual(TtlOperationResult.success, response.result);
}
