// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Vector Clock Implementation for Active-Active Replication
//!
//! This module provides vector clock tracking for detecting and resolving
//! conflicts in active-active multi-region replication scenarios.
//!
//! Per replication/spec.md:
//! - Each entity maintains a vector clock {region_id: logical_timestamp}
//! - Updated on every write
//! - Propagated with async replication
//! - Size bounded by region count (max 16 regions)
//!
//! ## Conflict Detection
//!
//! Two vector clocks are concurrent (conflict) if:
//! - Neither dominates the other (V1 !< V2 AND V2 !< V1)
//!
//! ## Resolution Policies
//!
//! - **last_writer_wins**: Highest timestamp wins (default)
//! - **primary_wins**: Primary region write takes precedence
//! - **custom_hook**: Application-provided resolution function

const std = @import("std");
const stdx = @import("stdx");

/// Maximum number of regions in a vector clock.
pub const max_regions: usize = 16;

/// Conflict resolution policy for active-active replication.
pub const ConflictResolutionPolicy = enum(u8) {
    /// Highest wall-clock timestamp wins (default).
    last_writer_wins = 0,

    /// Primary region write takes precedence.
    primary_wins = 1,

    /// Application-provided custom resolution.
    custom_hook = 2,

    pub fn toString(self: ConflictResolutionPolicy) []const u8 {
        return switch (self) {
            .last_writer_wins => "last_writer_wins",
            .primary_wins => "primary_wins",
            .custom_hook => "custom_hook",
        };
    }
};

/// Comparison result between two vector clocks.
pub const VectorClockComparison = enum {
    /// First clock dominates (happened-before).
    less_than,
    /// Second clock dominates (happened-after).
    greater_than,
    /// Clocks are equal.
    equal,
    /// Clocks are concurrent (conflict).
    concurrent,
};

/// Vector clock entry for a single region.
pub const VectorClockEntry = struct {
    /// Region identifier.
    region_id: u8,
    /// Logical timestamp for this region.
    timestamp: u64,

    pub fn init(region_id: u8, timestamp: u64) VectorClockEntry {
        return .{
            .region_id = region_id,
            .timestamp = timestamp,
        };
    }
};

/// Vector clock tracking causality across regions.
pub const VectorClock = struct {
    /// Clock entries per region (sparse representation).
    entries: [max_regions]VectorClockEntry,

    /// Number of valid entries.
    count: u8,

    /// Wall-clock timestamp (nanoseconds) of last update.
    wall_time_ns: i128,

    /// Initialize an empty vector clock.
    pub fn init() VectorClock {
        return .{
            .entries = [_]VectorClockEntry{VectorClockEntry.init(0, 0)} ** max_regions,
            .count = 0,
            .wall_time_ns = 0,
        };
    }

    /// Get timestamp for a specific region.
    pub fn get(self: *const VectorClock, region_id: u8) u64 {
        for (self.entries[0..self.count]) |entry| {
            if (entry.region_id == region_id) {
                return entry.timestamp;
            }
        }
        return 0;
    }

    /// Set timestamp for a specific region.
    pub fn set(self: *VectorClock, region_id: u8, timestamp: u64) void {
        // Check if region already exists
        for (self.entries[0..self.count]) |*entry| {
            if (entry.region_id == region_id) {
                entry.timestamp = timestamp;
                self.wall_time_ns = std.time.nanoTimestamp();
                return;
            }
        }

        // Add new region entry
        if (self.count < max_regions) {
            self.entries[self.count] = VectorClockEntry.init(region_id, timestamp);
            self.count += 1;
            self.wall_time_ns = std.time.nanoTimestamp();
        }
    }

    /// Increment timestamp for a region (local write).
    pub fn increment(self: *VectorClock, region_id: u8) u64 {
        const current = self.get(region_id);
        const new_ts = current + 1;
        self.set(region_id, new_ts);
        return new_ts;
    }

    /// Merge another vector clock into this one (take max of each entry).
    pub fn merge(self: *VectorClock, other: *const VectorClock) void {
        for (other.entries[0..other.count]) |entry| {
            const current = self.get(entry.region_id);
            if (entry.timestamp > current) {
                self.set(entry.region_id, entry.timestamp);
            }
        }

        // Update wall time to latest
        if (other.wall_time_ns > self.wall_time_ns) {
            self.wall_time_ns = other.wall_time_ns;
        }
    }

    /// Compare two vector clocks.
    pub fn compare(self: *const VectorClock, other: *const VectorClock) VectorClockComparison {
        var self_less = false;
        var self_greater = false;

        // Check all entries from self
        for (self.entries[0..self.count]) |entry| {
            const other_ts = other.get(entry.region_id);
            if (entry.timestamp < other_ts) {
                self_less = true;
            } else if (entry.timestamp > other_ts) {
                self_greater = true;
            }
        }

        // Check entries in other that might not be in self
        for (other.entries[0..other.count]) |entry| {
            const self_ts = self.get(entry.region_id);
            if (self_ts < entry.timestamp) {
                self_less = true;
            } else if (self_ts > entry.timestamp) {
                self_greater = true;
            }
        }

        if (self_less and self_greater) {
            return .concurrent;
        } else if (self_less) {
            return .less_than;
        } else if (self_greater) {
            return .greater_than;
        } else {
            return .equal;
        }
    }

    /// Check if this clock happened-before another.
    pub fn happenedBefore(self: *const VectorClock, other: *const VectorClock) bool {
        return self.compare(other) == .less_than;
    }

    /// Check if clocks are concurrent (conflict).
    pub fn isConcurrent(self: *const VectorClock, other: *const VectorClock) bool {
        return self.compare(other) == .concurrent;
    }

    /// Get maximum timestamp across all regions.
    pub fn maxTimestamp(self: *const VectorClock) u64 {
        var max_ts: u64 = 0;
        for (self.entries[0..self.count]) |entry| {
            max_ts = @max(max_ts, entry.timestamp);
        }
        return max_ts;
    }

    /// Serialize vector clock to bytes.
    pub fn toBytes(self: *const VectorClock) [256]u8 {
        var bytes: [256]u8 = [_]u8{0} ** 256;

        bytes[0] = self.count;
        var offset: usize = 1;

        for (self.entries[0..self.count]) |entry| {
            bytes[offset] = entry.region_id;
            offset += 1;
            const ts_bytes = std.mem.asBytes(&entry.timestamp);
            stdx.copy_disjoint(.exact, u8, bytes[offset .. offset + 8], ts_bytes);
            offset += 8;
        }

        const wt_bytes = std.mem.asBytes(&self.wall_time_ns);
        stdx.copy_disjoint(.exact, u8, bytes[offset .. offset + 16], wt_bytes);

        return bytes;
    }

    /// Deserialize vector clock from bytes.
    pub fn fromBytes(bytes: []const u8) VectorClock {
        var clock = VectorClock.init();

        if (bytes.len < 1) return clock;

        clock.count = @min(bytes[0], max_regions);
        var offset: usize = 1;

        for (0..clock.count) |i| {
            if (offset + 9 > bytes.len) break;

            clock.entries[i].region_id = bytes[offset];
            offset += 1;

            var ts_bytes: [8]u8 = undefined;
            stdx.copy_disjoint(.exact, u8, &ts_bytes, bytes[offset .. offset + 8]);
            clock.entries[i].timestamp = std.mem.bytesToValue(u64, &ts_bytes);
            offset += 8;
        }

        if (offset + 16 <= bytes.len) {
            var wall_bytes: [16]u8 = undefined;
            stdx.copy_disjoint(.exact, u8, &wall_bytes, bytes[offset .. offset + 16]);
            clock.wall_time_ns = std.mem.bytesToValue(i128, &wall_bytes);
        }

        return clock;
    }
};

/// Conflict detection and resolution for entity writes.
pub const ConflictResolver = struct {
    /// Active resolution policy.
    policy: ConflictResolutionPolicy,

    /// Primary region ID (for primary_wins policy).
    primary_region: u8,

    /// Custom resolution callback (for custom_hook policy).
    custom_resolver: ?*const fn (
        entity_id: u128,
        local_clock: *const VectorClock,
        remote_clock: *const VectorClock,
        local_data: []const u8,
        remote_data: []const u8,
    ) ConflictResolution,

    /// Statistics.
    conflicts_detected: u64,
    conflicts_resolved: u64,
    last_writer_wins_count: u64,
    primary_wins_count: u64,
    custom_resolved_count: u64,

    pub fn init(policy: ConflictResolutionPolicy) ConflictResolver {
        return .{
            .policy = policy,
            .primary_region = 0,
            .custom_resolver = null,
            .conflicts_detected = 0,
            .conflicts_resolved = 0,
            .last_writer_wins_count = 0,
            .primary_wins_count = 0,
            .custom_resolved_count = 0,
        };
    }

    /// Detect if there's a conflict between local and remote writes.
    pub fn detectConflict(
        self: *ConflictResolver,
        local_clock: *const VectorClock,
        remote_clock: *const VectorClock,
    ) bool {
        const is_concurrent = local_clock.isConcurrent(remote_clock);
        if (is_concurrent) {
            self.conflicts_detected += 1;
        }
        return is_concurrent;
    }

    /// Resolve a conflict between two versions.
    /// Returns resolution indicating which version wins.
    pub fn resolve(
        self: *ConflictResolver,
        entity_id: u128,
        local_clock: *const VectorClock,
        remote_clock: *const VectorClock,
        local_data: []const u8,
        remote_data: []const u8,
        remote_region: u8,
    ) ConflictResolution {
        self.conflicts_resolved += 1;

        switch (self.policy) {
            .last_writer_wins => {
                // Compare wall-clock timestamps
                if (remote_clock.wall_time_ns > local_clock.wall_time_ns) {
                    self.last_writer_wins_count += 1;
                    return .{ .winner = .remote, .reason = .later_timestamp };
                } else {
                    self.last_writer_wins_count += 1;
                    return .{ .winner = .local, .reason = .later_timestamp };
                }
            },
            .primary_wins => {
                // Check if remote is from primary region
                if (remote_region == self.primary_region) {
                    self.primary_wins_count += 1;
                    return .{ .winner = .remote, .reason = .primary_region };
                } else {
                    self.primary_wins_count += 1;
                    return .{ .winner = .local, .reason = .primary_region };
                }
            },
            .custom_hook => {
                if (self.custom_resolver) |resolver| {
                    self.custom_resolved_count += 1;
                    return resolver(
                        entity_id,
                        local_clock,
                        remote_clock,
                        local_data,
                        remote_data,
                    );
                } else {
                    // Fallback to last-writer-wins if no custom resolver
                    return .{ .winner = .local, .reason = .fallback };
                }
            },
        }
    }

    /// Get conflict statistics.
    pub fn getStats(self: *const ConflictResolver) ConflictStats {
        return .{
            .conflicts_detected = self.conflicts_detected,
            .conflicts_resolved = self.conflicts_resolved,
            .last_writer_wins_count = self.last_writer_wins_count,
            .primary_wins_count = self.primary_wins_count,
            .custom_resolved_count = self.custom_resolved_count,
        };
    }
};

/// Result of conflict resolution.
pub const ConflictResolution = struct {
    /// Which version wins.
    winner: Winner,
    /// Reason for resolution.
    reason: Reason,

    pub const Winner = enum {
        local,
        remote,
        merged, // For custom merge strategies
    };

    pub const Reason = enum {
        later_timestamp,
        primary_region,
        custom_resolution,
        fallback,
    };
};

/// Conflict statistics for monitoring.
pub const ConflictStats = struct {
    conflicts_detected: u64,
    conflicts_resolved: u64,
    last_writer_wins_count: u64,
    primary_wins_count: u64,
    custom_resolved_count: u64,
};

/// Conflict audit log entry.
pub const ConflictAuditEntry = struct {
    /// Entity that had conflict.
    entity_id: u128,

    /// Local region ID.
    local_region: u8,

    /// Remote region ID.
    remote_region: u8,

    /// Resolution policy used.
    policy: ConflictResolutionPolicy,

    /// Which version won.
    winner: ConflictResolution.Winner,

    /// Resolution reason.
    reason: ConflictResolution.Reason,

    /// Local vector clock at time of conflict.
    local_clock: VectorClock,

    /// Remote vector clock at time of conflict.
    remote_clock: VectorClock,

    /// Timestamp of conflict detection.
    timestamp_ns: i128,

    pub fn init(
        entity_id: u128,
        local_region: u8,
        remote_region: u8,
        policy: ConflictResolutionPolicy,
        resolution: ConflictResolution,
        local_clock: VectorClock,
        remote_clock: VectorClock,
    ) ConflictAuditEntry {
        return .{
            .entity_id = entity_id,
            .local_region = local_region,
            .remote_region = remote_region,
            .policy = policy,
            .winner = resolution.winner,
            .reason = resolution.reason,
            .local_clock = local_clock,
            .remote_clock = remote_clock,
            .timestamp_ns = std.time.nanoTimestamp(),
        };
    }
};

/// Conflict audit log for tracking conflict history.
pub const ConflictAuditLog = struct {
    const max_entries = 10000;

    /// Circular buffer of audit entries.
    entries: [max_entries]ConflictAuditEntry,

    /// Current write position.
    write_pos: usize,

    /// Total entries written (may exceed buffer size).
    total_entries: u64,

    /// Lock for thread-safe access.
    mutex: std.Thread.Mutex,

    pub fn init() ConflictAuditLog {
        return .{
            .entries = undefined,
            .write_pos = 0,
            .total_entries = 0,
            .mutex = .{},
        };
    }

    /// Add an entry to the audit log.
    pub fn add(self: *ConflictAuditLog, entry: ConflictAuditEntry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.entries[self.write_pos] = entry;
        self.write_pos = (self.write_pos + 1) % max_entries;
        self.total_entries += 1;
    }

    /// Get recent entries (up to count).
    pub fn getRecent(
        self: *ConflictAuditLog,
        output: []ConflictAuditEntry,
    ) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const available = @min(self.total_entries, max_entries);
        const to_copy = @min(output.len, available);

        var read_pos = if (self.write_pos >= to_copy)
            self.write_pos - to_copy
        else
            max_entries - (to_copy - self.write_pos);

        for (0..to_copy) |i| {
            output[i] = self.entries[read_pos];
            read_pos = (read_pos + 1) % max_entries;
        }

        return to_copy;
    }

    /// Get total conflicts logged.
    pub fn getTotalCount(self: *ConflictAuditLog) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.total_entries;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "VectorClock initialization" {
    const clock = VectorClock.init();
    try std.testing.expectEqual(@as(u8, 0), clock.count);
    try std.testing.expectEqual(@as(u64, 0), clock.get(0));
}

test "VectorClock set and get" {
    var clock = VectorClock.init();

    clock.set(0, 5);
    clock.set(1, 10);
    clock.set(2, 3);

    try std.testing.expectEqual(@as(u64, 5), clock.get(0));
    try std.testing.expectEqual(@as(u64, 10), clock.get(1));
    try std.testing.expectEqual(@as(u64, 3), clock.get(2));
    try std.testing.expectEqual(@as(u64, 0), clock.get(3)); // non-existent
    try std.testing.expectEqual(@as(u8, 3), clock.count);
}

test "VectorClock increment" {
    var clock = VectorClock.init();

    const ts1 = clock.increment(0);
    try std.testing.expectEqual(@as(u64, 1), ts1);

    const ts2 = clock.increment(0);
    try std.testing.expectEqual(@as(u64, 2), ts2);

    const ts3 = clock.increment(1);
    try std.testing.expectEqual(@as(u64, 1), ts3);
}

test "VectorClock merge" {
    var clock1 = VectorClock.init();
    clock1.set(0, 5);
    clock1.set(1, 3);

    var clock2 = VectorClock.init();
    clock2.set(0, 3);
    clock2.set(1, 7);
    clock2.set(2, 2);

    clock1.merge(&clock2);

    try std.testing.expectEqual(@as(u64, 5), clock1.get(0)); // max(5, 3)
    try std.testing.expectEqual(@as(u64, 7), clock1.get(1)); // max(3, 7)
    try std.testing.expectEqual(@as(u64, 2), clock1.get(2)); // new entry
}

test "VectorClock compare equal" {
    var clock1 = VectorClock.init();
    clock1.set(0, 5);
    clock1.set(1, 3);

    var clock2 = VectorClock.init();
    clock2.set(0, 5);
    clock2.set(1, 3);

    try std.testing.expectEqual(VectorClockComparison.equal, clock1.compare(&clock2));
}

test "VectorClock compare less_than" {
    var clock1 = VectorClock.init();
    clock1.set(0, 3);
    clock1.set(1, 2);

    var clock2 = VectorClock.init();
    clock2.set(0, 5);
    clock2.set(1, 3);

    try std.testing.expectEqual(VectorClockComparison.less_than, clock1.compare(&clock2));
    try std.testing.expect(clock1.happenedBefore(&clock2));
}

test "VectorClock compare concurrent" {
    var clock1 = VectorClock.init();
    clock1.set(0, 5); // Higher on region 0
    clock1.set(1, 2);

    var clock2 = VectorClock.init();
    clock2.set(0, 3);
    clock2.set(1, 7); // Higher on region 1

    try std.testing.expectEqual(VectorClockComparison.concurrent, clock1.compare(&clock2));
    try std.testing.expect(clock1.isConcurrent(&clock2));
}

test "VectorClock serialization roundtrip" {
    var clock = VectorClock.init();
    clock.set(0, 100);
    clock.set(1, 200);
    clock.set(5, 50);
    clock.wall_time_ns = 1234567890;

    const bytes = clock.toBytes();
    const restored = VectorClock.fromBytes(&bytes);

    try std.testing.expectEqual(@as(u8, 3), restored.count);
    try std.testing.expectEqual(@as(u64, 100), restored.get(0));
    try std.testing.expectEqual(@as(u64, 200), restored.get(1));
    try std.testing.expectEqual(@as(u64, 50), restored.get(5));
    try std.testing.expectEqual(@as(i128, 1234567890), restored.wall_time_ns);
}

test "ConflictResolver last_writer_wins" {
    var resolver = ConflictResolver.init(.last_writer_wins);

    var local_clock = VectorClock.init();
    local_clock.set(0, 5);
    local_clock.wall_time_ns = 1000;

    var remote_clock = VectorClock.init();
    remote_clock.set(1, 5);
    remote_clock.wall_time_ns = 2000; // Later

    const resolution = resolver.resolve(
        0x12345678,
        &local_clock,
        &remote_clock,
        "",
        "",
        1,
    );

    try std.testing.expectEqual(ConflictResolution.Winner.remote, resolution.winner);
    try std.testing.expectEqual(ConflictResolution.Reason.later_timestamp, resolution.reason);
}

test "ConflictResolver primary_wins" {
    var resolver = ConflictResolver.init(.primary_wins);
    resolver.primary_region = 0;

    var local_clock = VectorClock.init();
    var remote_clock = VectorClock.init();

    // Remote is from primary region
    const resolution = resolver.resolve(
        0x12345678,
        &local_clock,
        &remote_clock,
        "",
        "",
        0, // Primary region
    );

    try std.testing.expectEqual(ConflictResolution.Winner.remote, resolution.winner);
    try std.testing.expectEqual(ConflictResolution.Reason.primary_region, resolution.reason);
}

test "ConflictResolver detect conflict" {
    var resolver = ConflictResolver.init(.last_writer_wins);

    var clock1 = VectorClock.init();
    clock1.set(0, 5);
    clock1.set(1, 2);

    var clock2 = VectorClock.init();
    clock2.set(0, 3);
    clock2.set(1, 7);

    try std.testing.expect(resolver.detectConflict(&clock1, &clock2));
    try std.testing.expectEqual(@as(u64, 1), resolver.conflicts_detected);
}

test "ConflictAuditLog add and retrieve" {
    var log = ConflictAuditLog.init();

    const local_clock = VectorClock.init();
    const remote_clock = VectorClock.init();

    const entry = ConflictAuditEntry.init(
        0x12345678,
        0,
        1,
        .last_writer_wins,
        .{ .winner = .remote, .reason = .later_timestamp },
        local_clock,
        remote_clock,
    );

    log.add(entry);

    try std.testing.expectEqual(@as(u64, 1), log.getTotalCount());

    var output: [10]ConflictAuditEntry = undefined;
    const count = log.getRecent(&output);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u128, 0x12345678), output[0].entity_id);
}

test "ConflictResolutionPolicy toString" {
    const lww = ConflictResolutionPolicy.last_writer_wins.toString();
    const pw = ConflictResolutionPolicy.primary_wins.toString();
    const ch = ConflictResolutionPolicy.custom_hook.toString();
    try std.testing.expectEqualStrings("last_writer_wins", lww);
    try std.testing.expectEqualStrings("primary_wins", pw);
    try std.testing.expectEqualStrings("custom_hook", ch);
}

test "VectorClock maxTimestamp" {
    var clock = VectorClock.init();
    clock.set(0, 5);
    clock.set(1, 12);
    clock.set(2, 7);

    try std.testing.expectEqual(@as(u64, 12), clock.maxTimestamp());
}
