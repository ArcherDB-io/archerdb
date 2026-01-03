//! TTL (Time-to-Live) expiration and cleanup module.
//!
//! This module implements the TTL functionality as specified in:
//! `openspec/changes/add-geospatial-core/specs/ttl-retention/spec.md`
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
