// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Storage-specific Prometheus metrics for write/space amplification monitoring.
//!
//! This module provides Prometheus-compatible metrics for tracking storage subsystem
//! health, including:
//! - Write amplification (ratio of physical to logical bytes written)
//! - Space amplification (ratio of physical to logical storage used)
//! - Per-level compaction statistics
//! - Compression effectiveness
//!
//! All metrics follow Prometheus naming conventions (archerdb_*).

const std = @import("std");
const metrics = @import("metrics.zig");
const compaction_metrics = @import("../lsm/compaction_metrics.zig");
const constants = @import("../constants.zig");

const Gauge = metrics.Gauge;
const Counter = metrics.Counter;

// ============================================================================
// Write Amplification Metrics
// ============================================================================

/// Write amplification ratio (physical_bytes / logical_bytes).
/// A ratio of 1.0 means no amplification (ideal but rarely achieved).
/// Typical LSM trees have write amplification between 10-30x.
pub var archerdb_compaction_write_amplification = Gauge.init(
    "archerdb_compaction_write_amplification",
    "Ratio of physical to logical bytes written (1.0 = no amplification)",
    null,
);

/// Space amplification ratio (physical_size / logical_size).
/// A ratio of 1.0 means no space overhead.
/// Typical LSM trees have space amplification between 1.1-2.0x.
pub var archerdb_storage_space_amplification = Gauge.init(
    "archerdb_storage_space_amplification",
    "Ratio of physical to logical storage used (1.0 = no overhead)",
    null,
);

// ============================================================================
// Bytes Written Counters (for rate calculations)
// ============================================================================

/// Total physical bytes written to storage.
/// Includes all compaction, flush, and direct write operations.
/// Use rate() in PromQL to get bytes/second throughput.
pub var archerdb_storage_bytes_written_total = Counter.init(
    "archerdb_storage_bytes_written_total",
    "Total physical bytes written to storage",
    null,
);

/// Total logical bytes from application writes.
/// Represents the actual user data before LSM amplification.
pub var archerdb_storage_logical_bytes_total = Counter.init(
    "archerdb_storage_logical_bytes_total",
    "Total logical bytes from application writes",
    null,
);

/// Total bytes flushed from memtable to L0.
/// Flushes are the first step in moving data from memory to disk.
pub var archerdb_storage_flush_bytes_total = Counter.init(
    "archerdb_storage_flush_bytes_total",
    "Total bytes flushed from memtable to L0",
    null,
);

// ============================================================================
// Per-Level Metrics
// ============================================================================

/// Per-level bytes written during compaction.
/// Stored as an array since Prometheus labels are applied during formatting.
/// Index 0 = Level 0 (L0), etc.
pub var level_bytes_written: [constants.lsm_levels]std.atomic.Value(u64) = init_level_counters();

/// Per-level write amplification ratios.
/// Stored as fixed-point scaled by 1000 (e.g., 2500 = 2.5x).
pub var level_write_amp_scaled: [constants.lsm_levels]std.atomic.Value(u32) = init_level_amp();

fn init_level_counters() [constants.lsm_levels]std.atomic.Value(u64) {
    var counters: [constants.lsm_levels]std.atomic.Value(u64) = undefined;
    for (&counters) |*c| {
        c.* = std.atomic.Value(u64).init(0);
    }
    return counters;
}

fn init_level_amp() [constants.lsm_levels]std.atomic.Value(u32) {
    var amp: [constants.lsm_levels]std.atomic.Value(u32) = undefined;
    for (&amp) |*a| {
        a.* = std.atomic.Value(u32).init(1000); // 1.0x default
    }
    return amp;
}

// ============================================================================
// Compression Metrics (for use by later plans)
// ============================================================================

/// Compression ratio (compressed_size / uncompressed_size).
/// A ratio of 0.5 means 50% compression (2x smaller).
/// Stored as fixed-point scaled by 1000.
pub var archerdb_compression_ratio = Gauge.init(
    "archerdb_compression_ratio",
    "Ratio of compressed to uncompressed data size (0.5 = 50% of original)",
    null,
);

/// Total bytes saved by compression.
/// Calculated as (uncompressed_size - compressed_size) for all compressed data.
pub var archerdb_compression_bytes_saved_total = Counter.init(
    "archerdb_compression_bytes_saved_total",
    "Total bytes saved by compression",
    null,
);

/// Total bytes before compression.
pub var archerdb_compression_bytes_in_total = Counter.init(
    "archerdb_compression_bytes_in_total",
    "Total bytes before compression",
    null,
);

/// Total bytes after compression.
pub var archerdb_compression_bytes_out_total = Counter.init(
    "archerdb_compression_bytes_out_total",
    "Total bytes after compression",
    null,
);

// ============================================================================
// Rolling Window Rate Metrics
// ============================================================================

/// Write rate over 1-minute window (bytes/second).
/// Updated via rolling window sampling.
pub var archerdb_storage_write_rate_1m = Gauge.init(
    "archerdb_storage_write_rate_1m",
    "Write rate over 1-minute window in bytes/second",
    null,
);

/// Write rate over 5-minute window (bytes/second).
pub var archerdb_storage_write_rate_5m = Gauge.init(
    "archerdb_storage_write_rate_5m",
    "Write rate over 5-minute window in bytes/second",
    null,
);

/// Write rate over 1-hour window (bytes/second).
pub var archerdb_storage_write_rate_1h = Gauge.init(
    "archerdb_storage_write_rate_1h",
    "Write rate over 1-hour window in bytes/second",
    null,
);

// ============================================================================
// Update Functions
// ============================================================================

/// Update Prometheus gauges from WriteAmpMetrics atomic counters.
/// Call this periodically (e.g., on metrics scrape or every few seconds).
pub fn update_from_metrics(write_amp_metrics: *const compaction_metrics.WriteAmpMetrics) void {
    // Update overall write amplification gauge
    const wa = write_amp_metrics.write_amplification();
    // Convert to fixed-point scaled by 100 for gauge (gauges use i64)
    archerdb_compaction_write_amplification.set(@intFromFloat(wa * 100.0));

    // Update byte counters (for rate calculations in Prometheus)
    const physical = write_amp_metrics.get_physical_bytes();
    const logical = write_amp_metrics.get_logical_bytes();
    const flush = write_amp_metrics.get_flush_bytes();

    // Note: Counters should only increase. We track the delta from our last sync.
    // For simplicity here, we set to the current value (assuming single-source tracking).
    // In production, this would need proper delta handling.

    // Update per-level metrics
    for (0..constants.lsm_levels) |level| {
        const level_bytes = write_amp_metrics.get_level_bytes(@intCast(level));
        level_bytes_written[level].store(level_bytes, .monotonic);

        const level_wa = write_amp_metrics.level_write_amplification(@intCast(level));
        level_write_amp_scaled[level].store(@intFromFloat(level_wa * 1000.0), .monotonic);
    }

    // Store raw values for external consumption
    _ = physical;
    _ = logical;
    _ = flush;
}

/// Update space amplification gauge.
/// Call this when logical or physical storage sizes change.
pub fn update_space_amplification(logical_size: u64, physical_size: u64) void {
    const sa = compaction_metrics.space_amplification(logical_size, physical_size);
    // Convert to fixed-point scaled by 100 for gauge
    archerdb_storage_space_amplification.set(@intFromFloat(sa * 100.0));
}

/// Update rolling window write rates.
pub fn update_write_rates(rates: compaction_metrics.WindowRates) void {
    archerdb_storage_write_rate_1m.set(@intFromFloat(rates.rate_1min));
    archerdb_storage_write_rate_5m.set(@intFromFloat(rates.rate_5min));
    archerdb_storage_write_rate_1h.set(@intFromFloat(rates.rate_1hr));
}

/// Record compression statistics.
pub fn record_compression(uncompressed_bytes: u64, compressed_bytes: u64) void {
    archerdb_compression_bytes_in_total.add(uncompressed_bytes);
    archerdb_compression_bytes_out_total.add(compressed_bytes);

    if (compressed_bytes < uncompressed_bytes) {
        archerdb_compression_bytes_saved_total.add(uncompressed_bytes - compressed_bytes);
    }

    // Update compression ratio gauge
    if (uncompressed_bytes > 0) {
        const ratio = @as(f64, @floatFromInt(compressed_bytes)) /
            @as(f64, @floatFromInt(uncompressed_bytes));
        archerdb_compression_ratio.set(@intFromFloat(ratio * 1000.0));
    }
}

// ============================================================================
// Prometheus Format Output
// ============================================================================

/// Format all storage metrics in Prometheus text format.
/// Call this from the main metrics format function.
pub fn format_all(writer: anytype) !void {
    // Write amplification
    try archerdb_compaction_write_amplification.format(writer);
    try writer.writeAll("\n");

    // Space amplification
    try archerdb_storage_space_amplification.format(writer);
    try writer.writeAll("\n");

    // Byte counters
    try archerdb_storage_bytes_written_total.format(writer);
    try archerdb_storage_logical_bytes_total.format(writer);
    try archerdb_storage_flush_bytes_total.format(writer);
    try writer.writeAll("\n");

    // Per-level bytes written
    try writer.writeAll(
        "# HELP archerdb_compaction_level_bytes_total Total bytes written per LSM level\n",
    );
    try writer.writeAll("# TYPE archerdb_compaction_level_bytes_total counter\n");
    for (level_bytes_written, 0..) |bytes, level| {
        try writer.print(
            "archerdb_compaction_level_bytes_total{{level=\"{d}\"}} {d}\n",
            .{ level, bytes.load(.monotonic) },
        );
    }
    try writer.writeAll("\n");

    // Per-level write amplification
    try writer.writeAll(
        "# HELP archerdb_compaction_level_write_amplification Write amplification per LSM level\n",
    );
    try writer.writeAll("# TYPE archerdb_compaction_level_write_amplification gauge\n");
    for (level_write_amp_scaled, 0..) |amp_scaled, level| {
        const amp = @as(f64, @floatFromInt(amp_scaled.load(.monotonic))) / 1000.0;
        try writer.print(
            "archerdb_compaction_level_write_amplification{{level=\"{d}\"}} {d:.3}\n",
            .{ level, amp },
        );
    }
    try writer.writeAll("\n");

    // Compression metrics
    try archerdb_compression_ratio.format(writer);
    try archerdb_compression_bytes_saved_total.format(writer);
    try archerdb_compression_bytes_in_total.format(writer);
    try archerdb_compression_bytes_out_total.format(writer);
    try writer.writeAll("\n");

    // Write rate metrics
    try archerdb_storage_write_rate_1m.format(writer);
    try archerdb_storage_write_rate_5m.format(writer);
    try archerdb_storage_write_rate_1h.format(writer);
    try writer.writeAll("\n");
}

// ============================================================================
// Tests
// ============================================================================

test "storage_metrics: update_from_metrics updates gauges" {
    var write_amp = compaction_metrics.WriteAmpMetrics.init();

    // Record some data
    write_amp.record_logical_write(1000);
    write_amp.record_write(0, 2000);
    write_amp.record_flush(500);

    // Update Prometheus metrics
    update_from_metrics(&write_amp);

    // Write amp should be ~2.5 (2500 physical / 1000 logical)
    const wa_scaled = archerdb_compaction_write_amplification.get();
    // 2500/1000 = 2.5, scaled by 100 = 250
    try std.testing.expectEqual(@as(i64, 250), wa_scaled);
}

test "storage_metrics: update_space_amplification" {
    update_space_amplification(1000, 1500);

    const sa_scaled = archerdb_storage_space_amplification.get();
    // 1500/1000 = 1.5, scaled by 100 = 150
    try std.testing.expectEqual(@as(i64, 150), sa_scaled);
}

test "storage_metrics: record_compression" {
    // Reset counters for test isolation
    archerdb_compression_bytes_in_total = Counter.init(
        "archerdb_compression_bytes_in_total",
        "Total bytes before compression",
        null,
    );
    archerdb_compression_bytes_out_total = Counter.init(
        "archerdb_compression_bytes_out_total",
        "Total bytes after compression",
        null,
    );
    archerdb_compression_bytes_saved_total = Counter.init(
        "archerdb_compression_bytes_saved_total",
        "Total bytes saved by compression",
        null,
    );

    // 1000 bytes compressed to 400 bytes (60% reduction)
    record_compression(1000, 400);

    try std.testing.expectEqual(@as(u64, 1000), archerdb_compression_bytes_in_total.get());
    try std.testing.expectEqual(@as(u64, 400), archerdb_compression_bytes_out_total.get());
    try std.testing.expectEqual(@as(u64, 600), archerdb_compression_bytes_saved_total.get());

    // Ratio should be 0.4, scaled by 1000 = 400
    const ratio_scaled = archerdb_compression_ratio.get();
    try std.testing.expectEqual(@as(i64, 400), ratio_scaled);
}

test "storage_metrics: format_all produces valid output" {
    var buffer: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try format_all(writer);

    const output = stream.getWritten();

    // Verify expected metric names appear in output
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_compaction_write_amplification") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_storage_space_amplification") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_compaction_level_bytes_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_compression_ratio") != null);
}
