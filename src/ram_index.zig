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
        const level: DegradationLevel = if (max_probe >= DegradationThresholds.probe_length_critical)
            .critical
        else if (max_probe >= DegradationThresholds.probe_length_warning)
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

/// RAM Index - O(1) entity lookup index.
///
/// Thread-safety model:
/// - Multiple concurrent readers (lookups) using lock-free atomic loads
/// - Single writer (VSR commit phase guarantees serialized writes)
/// - Read-during-write safety via atomic operations with Acquire/Release semantics
pub fn RamIndex(comptime options: struct {
    /// Enable statistics tracking (has minor performance overhead).
    track_stats: bool = true,
}) type {
    return struct {
        const Self = @This();

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
        pub fn init(allocator: Allocator, capacity: u64) IndexError!Self {
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

            return Self{
                .entries = entries,
                .capacity = capacity,
                .count = std.atomic.Value(u64).init(0),
                .stats = if (options.track_stats) IndexStats{
                    .capacity = capacity,
                } else {},
            };
        }

        /// Deinitialize and free index memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.entries);
            self.* = undefined;
        }

        /// Hash function for entity_id (u128).
        /// Uses Google Abseil LowLevelHash (wyhash-inspired) from stdx.
        inline fn hash(entity_id: u128) u64 {
            return stdx.hash_inline(entity_id);
        }

        /// Calculate slot index from hash.
        inline fn slot_index(self: *const Self, entity_id: u128) u64 {
            return hash(entity_id) % self.capacity;
        }

        /// Lookup an entity by ID.
        ///
        /// This is a lock-free operation using atomic loads with Acquire semantics.
        /// Safe to call concurrently from multiple threads.
        ///
        /// Returns the IndexEntry if found, null otherwise.
        /// Also returns the probe count for diagnostics.
        pub fn lookup(self: *Self, entity_id: u128) LookupResult {
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
            self: *Self,
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
                    return .{ .inserted = false, .updated = should_update, .probe_count = probe_count };
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
        pub fn remove(self: *Self, entity_id: u128) bool {
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
            self: *Self,
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
            self: *Self,
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
            self: *Self,
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

        /// Get current statistics.
        pub fn get_stats(self: *const Self) IndexStats {
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

        fn updateLookupStats(self: *Self, probe_count: u32, hit: bool) void {
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

        fn updateUpsertStats(self: *Self, probe_count: u32, inserted: bool, tombstone_reuse: bool) void {
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

        fn updateProbeLimit(self: *Self) void {
            if (options.track_stats) {
                self.stats.probe_limit_hits += 1;
            }
        }
    };
}

/// Default RAM index type with stats enabled.
pub const DefaultRamIndex = RamIndex(.{ .track_stats = true });

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
    const status_healthy = detector.check_health(stats_healthy);
    try std.testing.expectEqual(DegradationLevel.normal, status_healthy.overall_level);
    try std.testing.expectEqual(DegradationStatus.RecommendedAction.none, status_healthy.recommended_action);
    try std.testing.expect(!status_healthy.corruption_detected);

    // Warning level: high tombstone ratio.
    const stats_warning = IndexStats{
        .capacity = 100,
        .entry_count = 78,
        .tombstone_count = 15, // ~16% tombstones
        .max_probe_length_seen = 2,
    };
    const status_warning = detector.check_health(stats_warning);
    try std.testing.expectEqual(DegradationLevel.warning, status_warning.overall_level);
    try std.testing.expectEqual(DegradationStatus.RecommendedAction.schedule_rebuild, status_warning.recommended_action);

    // Critical level: high load factor.
    const stats_critical = IndexStats{
        .capacity = 100,
        .entry_count = 70,
        .tombstone_count = 10, // 80% load factor
        .max_probe_length_seen = 2,
    };
    const status_critical = detector.check_health(stats_critical);
    try std.testing.expectEqual(DegradationLevel.critical, status_critical.overall_level);
    try std.testing.expectEqual(DegradationStatus.RecommendedAction.immediate_rebuild, status_critical.recommended_action);
}

test "DegradationDetector: corruption detection" {
    var detector = DegradationDetector{};

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
    try std.testing.expectEqual(DegradationStatus.RecommendedAction.replace_replica, status_corrupted.recommended_action);

    // Reset corruption.
    detector.reset_corruption();
    const status_reset = detector.check_health(stats);
    try std.testing.expect(!status_reset.corruption_detected);
    try std.testing.expectEqual(DegradationLevel.normal, status_reset.overall_level);
}

test "DegradationLevel: severity ordering" {
    // Test that severity values are correctly ordered.
    try std.testing.expectEqual(@as(u8, 0), DegradationLevel.normal.severity());
    try std.testing.expectEqual(@as(u8, 1), DegradationLevel.warning.severity());
    try std.testing.expectEqual(@as(u8, 2), DegradationLevel.critical.severity());

    // Verify ordering.
    try std.testing.expect(DegradationLevel.normal.severity() < DegradationLevel.warning.severity());
    try std.testing.expect(DegradationLevel.warning.severity() < DegradationLevel.critical.severity());
}
