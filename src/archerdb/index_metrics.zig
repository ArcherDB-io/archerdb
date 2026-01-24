// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! RAM Index Prometheus metrics for memory monitoring.
//!
//! Provides metrics for tracking RAM index memory usage, capacity,
//! entry counts, and load factor. All metrics follow Prometheus
//! naming conventions (archerdb_ram_index_*).

const std = @import("std");
const metrics = @import("metrics.zig");

const Gauge = metrics.Gauge;
const Counter = metrics.Counter;

// ============================================================================
// Memory Usage Metrics
// ============================================================================

/// Total RAM index memory usage in bytes.
/// This is capacity * entry_size, not actual used entries.
pub var archerdb_ram_index_memory_bytes = Gauge.init(
    "archerdb_ram_index_memory_bytes",
    "Total RAM index memory allocation in bytes",
    null,
);

/// Number of entries currently in the index.
/// Does not include empty slots or tombstones.
pub var archerdb_ram_index_entries_total = Gauge.init(
    "archerdb_ram_index_entries_total",
    "Number of entries currently in RAM index",
    null,
);

/// Total capacity of the index in entry slots.
/// Fixed at initialization, does not change at runtime.
pub var archerdb_ram_index_capacity_total = Gauge.init(
    "archerdb_ram_index_capacity_total",
    "Total capacity of RAM index in entry slots",
    null,
);

/// Current load factor of the index (0-1000 scale).
/// 700 = 70% load factor. Target is 500-700 for cuckoo hashing.
pub var archerdb_ram_index_load_factor = Gauge.init(
    "archerdb_ram_index_load_factor",
    "Current load factor of RAM index (scaled by 1000, e.g., 700 = 70%)",
    null,
);

// ============================================================================
// Lookup Performance Metrics
// ============================================================================

/// Total lookup operations performed.
pub var archerdb_ram_index_lookups_total = Counter.init(
    "archerdb_ram_index_lookups_total",
    "Total number of lookup operations on RAM index",
    null,
);

/// Lookup operations that found the entry (hits).
pub var archerdb_ram_index_lookup_hits_total = Counter.init(
    "archerdb_ram_index_lookup_hits_total",
    "Number of lookup operations that found an entry",
    null,
);

/// Lookup operations that did not find the entry (misses).
pub var archerdb_ram_index_lookup_misses_total = Counter.init(
    "archerdb_ram_index_lookup_misses_total",
    "Number of lookup operations that did not find an entry",
    null,
);

// ============================================================================
// Insert/Update Metrics
// ============================================================================

/// Total insert operations performed.
pub var archerdb_ram_index_inserts_total = Counter.init(
    "archerdb_ram_index_inserts_total",
    "Total number of insert operations on RAM index",
    null,
);

/// Insert operations that displaced existing entries (cuckoo displacement).
pub var archerdb_ram_index_displacements_total = Counter.init(
    "archerdb_ram_index_displacements_total",
    "Number of cuckoo displacements during insert",
    null,
);

// ============================================================================
// Update Functions
// ============================================================================

/// Update metrics from RAM index state.
/// Call this on metrics scrape (lazy update pattern).
///
/// Parameters:
/// - entry_count: Current number of entries in index
/// - capacity: Total slots in index
/// - entry_size: Size of each entry in bytes (64 for IndexEntry)
pub fn update_from_index(entry_count: u64, capacity: u64, entry_size: u64) void {
    const memory_bytes = capacity * entry_size;
    archerdb_ram_index_memory_bytes.set(@intCast(memory_bytes));
    archerdb_ram_index_entries_total.set(@intCast(entry_count));
    archerdb_ram_index_capacity_total.set(@intCast(capacity));

    // Load factor scaled by 1000 (e.g., 700 = 0.70)
    if (capacity > 0) {
        const load_factor = (entry_count * 1000) / capacity;
        archerdb_ram_index_load_factor.set(@intCast(load_factor));
    }
}

/// Record a lookup operation.
pub fn record_lookup(hit: bool) void {
    archerdb_ram_index_lookups_total.inc();
    if (hit) {
        archerdb_ram_index_lookup_hits_total.inc();
    } else {
        archerdb_ram_index_lookup_misses_total.inc();
    }
}

/// Record an insert operation.
pub fn record_insert(displacement_count: u32) void {
    archerdb_ram_index_inserts_total.inc();
    if (displacement_count > 0) {
        archerdb_ram_index_displacements_total.add(displacement_count);
    }
}

// ============================================================================
// Prometheus Format Output
// ============================================================================

/// Format all RAM index metrics in Prometheus text format.
pub fn format_all(writer: anytype) !void {
    // Memory metrics
    try archerdb_ram_index_memory_bytes.format(writer);
    try archerdb_ram_index_entries_total.format(writer);
    try archerdb_ram_index_capacity_total.format(writer);
    try archerdb_ram_index_load_factor.format(writer);
    try writer.writeAll("\n");

    // Lookup metrics
    try archerdb_ram_index_lookups_total.format(writer);
    try archerdb_ram_index_lookup_hits_total.format(writer);
    try archerdb_ram_index_lookup_misses_total.format(writer);
    try writer.writeAll("\n");

    // Insert metrics
    try archerdb_ram_index_inserts_total.format(writer);
    try archerdb_ram_index_displacements_total.format(writer);
    try writer.writeAll("\n");
}

// ============================================================================
// Tests
// ============================================================================

test "update_from_index: calculates metrics correctly" {
    // Reset metrics for test isolation
    archerdb_ram_index_memory_bytes = Gauge.init(
        "archerdb_ram_index_memory_bytes",
        "Total RAM index memory allocation in bytes",
        null,
    );
    archerdb_ram_index_entries_total = Gauge.init(
        "archerdb_ram_index_entries_total",
        "Number of entries currently in RAM index",
        null,
    );
    archerdb_ram_index_capacity_total = Gauge.init(
        "archerdb_ram_index_capacity_total",
        "Total capacity of RAM index in entry slots",
        null,
    );
    archerdb_ram_index_load_factor = Gauge.init(
        "archerdb_ram_index_load_factor",
        "Current load factor of RAM index (scaled by 1000, e.g., 700 = 70%)",
        null,
    );

    update_from_index(700, 1000, 64);

    try std.testing.expectEqual(@as(i64, 64000), archerdb_ram_index_memory_bytes.get());
    try std.testing.expectEqual(@as(i64, 700), archerdb_ram_index_entries_total.get());
    try std.testing.expectEqual(@as(i64, 1000), archerdb_ram_index_capacity_total.get());
    try std.testing.expectEqual(@as(i64, 700), archerdb_ram_index_load_factor.get());
}

test "update_from_index: handles zero capacity" {
    // Reset metrics for test isolation
    archerdb_ram_index_memory_bytes = Gauge.init(
        "archerdb_ram_index_memory_bytes",
        "Total RAM index memory allocation in bytes",
        null,
    );
    archerdb_ram_index_load_factor = Gauge.init(
        "archerdb_ram_index_load_factor",
        "Current load factor of RAM index (scaled by 1000, e.g., 700 = 70%)",
        null,
    );

    update_from_index(0, 0, 64);
    // Should not crash, load factor stays at previous value (0 from init)
    try std.testing.expectEqual(@as(i64, 0), archerdb_ram_index_memory_bytes.get());
}

test "record_lookup: increments counters" {
    // Reset for test
    archerdb_ram_index_lookups_total = Counter.init(
        "archerdb_ram_index_lookups_total",
        "Total number of lookup operations on RAM index",
        null,
    );
    archerdb_ram_index_lookup_hits_total = Counter.init(
        "archerdb_ram_index_lookup_hits_total",
        "Number of lookup operations that found an entry",
        null,
    );
    archerdb_ram_index_lookup_misses_total = Counter.init(
        "archerdb_ram_index_lookup_misses_total",
        "Number of lookup operations that did not find an entry",
        null,
    );

    record_lookup(true);
    record_lookup(true);
    record_lookup(false);

    try std.testing.expectEqual(@as(u64, 3), archerdb_ram_index_lookups_total.get());
    try std.testing.expectEqual(@as(u64, 2), archerdb_ram_index_lookup_hits_total.get());
    try std.testing.expectEqual(@as(u64, 1), archerdb_ram_index_lookup_misses_total.get());
}

test "record_insert: increments counters" {
    // Reset for test
    archerdb_ram_index_inserts_total = Counter.init(
        "archerdb_ram_index_inserts_total",
        "Total number of insert operations on RAM index",
        null,
    );
    archerdb_ram_index_displacements_total = Counter.init(
        "archerdb_ram_index_displacements_total",
        "Number of cuckoo displacements during insert",
        null,
    );

    record_insert(0);
    record_insert(3);
    record_insert(2);

    try std.testing.expectEqual(@as(u64, 3), archerdb_ram_index_inserts_total.get());
    try std.testing.expectEqual(@as(u64, 5), archerdb_ram_index_displacements_total.get());
}

test "format_all: produces valid output" {
    var buffer: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try format_all(writer);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_memory_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_load_factor") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_lookups_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_inserts_total") != null);
}
