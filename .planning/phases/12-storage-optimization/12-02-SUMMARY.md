---
phase: 12-storage-optimization
plan: 02
status: complete
subsystem: lsm/metrics
tags: [write-amplification, space-amplification, prometheus, metrics, observability]

dependency_graph:
  requires: []
  provides:
    - Write amplification metrics infrastructure
    - Space amplification calculation
    - Per-level compaction statistics
    - Storage Prometheus metrics
  affects:
    - 12-03 (compaction strategy will use metrics)
    - 12-04 (bloom filters optimization uses space amp)
    - Any compaction tuning work

tech_stack:
  added: []
  patterns:
    - Atomic counters for thread-safe metrics
    - Rolling window rate calculation
    - Prometheus-compatible metric formatting

key_files:
  created:
    - src/lsm/compaction_metrics.zig
    - src/archerdb/storage_metrics.zig
  modified:
    - src/archerdb/metrics.zig

decisions:
  - id: metrics-scaling
    choice: "Scale ratios by 100 or 1000 for Gauge precision"
    reason: "Gauges use i64, floating point ratios need scaling"
  - id: level-tracking
    choice: "Array of atomics per level using constants.lsm_levels"
    reason: "Configurable LSM levels, compile-time constant array size"
  - id: rolling-windows
    choice: "1min, 5min, 1hr windows for rate metrics"
    reason: "Standard observability windows for trend analysis"

metrics:
  duration: ~7min
  completed: 2026-01-24
---

# Phase 12 Plan 02: Write/Space Amplification Metrics Summary

Write amplification monitoring infrastructure with atomic counters and Prometheus integration.

## One-liner

WriteAmpMetrics with atomic counters tracking physical/logical ratio, per-level stats, and Prometheus export.

## Completed Tasks

| # | Task | Commit | Key Changes |
|---|------|--------|-------------|
| 1 | Create compaction metrics module | 4a8223b | WriteAmpMetrics struct, atomic counters, amplification calculations |
| 2 | Create storage Prometheus metrics | d8cfb24 | Prometheus gauges/counters, per-level metrics with labels |
| 3 | Integrate into main metrics | 01734d0 | Public import, format_all() call in Registry.format() |

## What Was Built

### src/lsm/compaction_metrics.zig (Task 1)

Core write amplification tracking module:

```zig
pub const WriteAmpMetrics = struct {
    logical_bytes_written: std.atomic.Value(u64),   // User data
    physical_bytes_written: std.atomic.Value(u64),  // Disk I/O
    level_writes: [constants.lsm_levels]std.atomic.Value(u64),  // Per-level
    flush_bytes: std.atomic.Value(u64),             // Memtable flushes

    pub fn write_amplification(self) f64;           // physical/logical
    pub fn level_write_amplification(self, level: u8) f64;  // Per-level
    pub fn record_write(self, level: u8, bytes: u64);
    pub fn record_logical_write(self, bytes: u64);
    pub fn record_flush(self, bytes: u64);
};

pub fn space_amplification(logical: u64, physical: u64) f64;
```

Rolling window support for time-based metrics (1min, 5min, 1hr).

### src/archerdb/storage_metrics.zig (Task 2)

Prometheus-compatible storage metrics:

```zig
// Write amplification (ratio, 1.0 = ideal)
pub var archerdb_compaction_write_amplification = Gauge.init(...);

// Space amplification (ratio, 1.0 = ideal)
pub var archerdb_storage_space_amplification = Gauge.init(...);

// Byte counters (for rate calculations)
pub var archerdb_storage_bytes_written_total = Counter.init(...);
pub var archerdb_storage_logical_bytes_total = Counter.init(...);

// Per-level with labels
pub var level_bytes_written: [lsm_levels]std.atomic.Value(u64);

// Compression metrics (for later plans)
pub var archerdb_compression_ratio = Gauge.init(...);
pub var archerdb_compression_bytes_saved_total = Counter.init(...);

pub fn update_from_metrics(metrics: *WriteAmpMetrics);
pub fn format_all(writer: anytype) !void;
```

### src/archerdb/metrics.zig (Task 3)

Integration:

```zig
pub const storage = @import("storage_metrics.zig");

// In Registry.format():
try storage.format_all(writer);
```

## Metrics Exposed

When Prometheus scrapes /metrics, these new metrics appear:

| Metric | Type | Description |
|--------|------|-------------|
| `archerdb_compaction_write_amplification` | gauge | Physical/logical bytes ratio (scaled x100) |
| `archerdb_storage_space_amplification` | gauge | Disk/logical size ratio (scaled x100) |
| `archerdb_storage_bytes_written_total` | counter | Total physical bytes written |
| `archerdb_storage_logical_bytes_total` | counter | Total user data bytes |
| `archerdb_storage_flush_bytes_total` | counter | Bytes flushed from memtable |
| `archerdb_compaction_level_bytes_total{level="N"}` | counter | Bytes written per LSM level |
| `archerdb_compaction_level_write_amplification{level="N"}` | gauge | Per-level write amp |
| `archerdb_compression_ratio` | gauge | Compressed/uncompressed ratio |
| `archerdb_compression_bytes_saved_total` | counter | Bytes saved by compression |
| `archerdb_storage_write_rate_1m` | gauge | 1-minute write rate |
| `archerdb_storage_write_rate_5m` | gauge | 5-minute write rate |
| `archerdb_storage_write_rate_1h` | gauge | 1-hour write rate |

## Usage Example

```zig
// In compaction code:
const compaction_metrics = @import("compaction_metrics.zig");

var metrics = compaction_metrics.WriteAmpMetrics.init();

// Record user write
metrics.record_logical_write(batch_size);

// Record flush to L0
metrics.record_flush(flush_bytes);

// Record compaction write
metrics.record_write(dest_level, output_bytes);

// Query amplification
const wa = metrics.write_amplification();  // e.g., 15.3x
const l1_wa = metrics.level_write_amplification(1);  // e.g., 2.1x

// Update Prometheus metrics
storage_metrics.update_from_metrics(&metrics);
```

## Test Coverage

All new code includes unit tests:

- WriteAmpMetrics: basic calculation, zero handling, per-level tracking, flush tracking, reset
- space_amplification: basic, zero logical size, equal sizes
- RollingWindowMetrics: record accumulation, window rotation
- storage_metrics: update_from_metrics, space amp update, compression recording, format output

## Deviations from Plan

None - plan executed exactly as written.

## Next Phase Readiness

This plan provides the metrics infrastructure that subsequent plans will use:

- **12-03 (Compaction Strategy)**: Can use write_amplification() and level_write_amplification() to measure effectiveness of tiered compaction
- **12-04 (Bloom Filters)**: Can use space_amplification() to measure impact on storage overhead
- **12-05+ (Other optimizations)**: All have metrics to measure before/after impact

Ready for 12-03 execution.
