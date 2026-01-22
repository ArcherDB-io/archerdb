# LSM Tree Tuning Guide

This guide explains how to tune ArcherDB's LSM (Log-Structured Merge-tree) storage layer
for optimal performance across different hardware configurations.

## Overview

ArcherDB uses an LSM tree for persistent storage, providing excellent write throughput
while maintaining competitive read performance. The LSM tree organizes data into levels,
with each level containing sorted runs (tables) that are periodically merged through
compaction.

### Performance Targets

Per the ArcherDB specification, the following targets must be met:

| Metric | Enterprise Tier | Mid-Tier | Lite |
|--------|-----------------|----------|------|
| Write throughput | 1M+ ops/sec | 500k+ ops/sec | 10k+ ops/sec |
| Read throughput | 100k+ ops/sec | 50k+ ops/sec | 5k+ ops/sec |
| Point query p99 | < 1ms | < 2ms | < 10ms |
| Range query p99 | < 10ms | < 20ms | < 100ms |
| Compaction p99 impact | None | Minimal | Acceptable |

## Hardware Requirements

### Enterprise Tier

For achieving 1M+ writes/sec and 100k+ reads/sec:

- **Storage**: NVMe SSDs with 4+ GB/s sequential read/write
  - Recommended: Intel Optane, Samsung PM1735, or equivalent
  - Multiple drives in RAID 0 for maximum throughput
  - Avoid SATA SSDs for this tier

- **CPU**: 16+ cores
  - Modern x86_64 (Intel Xeon, AMD EPYC) or ARM (Graviton3+)
  - High single-thread performance for compaction

- **Memory**: 64+ GB RAM
  - Grid cache: 4 GB (configurable)
  - Geo events cache: 4 MB per tree
  - Manifest memory: 128+ MB
  - OS page cache: Remaining memory

- **Network**: 10+ Gbps for replication

### Mid-Tier

For achieving 500k+ writes/sec and 50k+ reads/sec:

- **Storage**: SATA SSDs with 500+ MB/s sequential read/write
  - Consumer-grade NVMe also acceptable
  - Avoid spinning disks (HDDs)

- **CPU**: 8+ cores
  - Any modern x86_64 or ARM processor

- **Memory**: 32 GB RAM
  - Grid cache: 2 GB
  - Geo events cache: 2 MB per tree
  - Manifest memory: 64+ MB

- **Network**: 1+ Gbps for replication

### Minimum Requirements

For evaluation and development:

- **Storage**: Any SSD
- **CPU**: 4+ cores
- **Memory**: 8 GB RAM
- **Network**: 100+ Mbps

## Configuration Presets

ArcherDB provides three built-in configuration presets in `src/config.zig`:

### Enterprise Configuration

```zig
pub const enterprise = Config{
    .cluster = .{
        .lsm_levels = 7,
        .lsm_growth_factor = 8,
        .lsm_compaction_ops = 64,
        .block_size = 512 * KiB,
        .lsm_manifest_compact_extra_blocks = 2,
        .lsm_table_coalescing_threshold_percent = 40,
        // ... other settings
    },
};
```

### Mid-Tier Configuration

```zig
pub const mid_tier = Config{
    .cluster = .{
        .lsm_levels = 6,
        .lsm_growth_factor = 10,
        .lsm_compaction_ops = 32,
        .block_size = 256 * KiB,
        .lsm_manifest_compact_extra_blocks = 1,
        .lsm_table_coalescing_threshold_percent = 50,
        // ... other settings
    },
};
```

### Lite Configuration

For testing with minimal resources:

```zig
pub const lite = Config{
    .cluster = .{
        .lsm_levels = 7,
        .lsm_growth_factor = 4,
        .lsm_compaction_ops = 4,
        .block_size = 4 * KiB,  // sector_size
        // ... other settings
    },
};
```

## Configuration Parameters Explained

### lsm_levels

**Default**: 7 (enterprise), 6 (mid-tier)
**Range**: 2-10

The number of levels in the LSM tree. More levels provide larger storage capacity
but increase read amplification (more levels to check during reads).

| Levels | Read Amplification | Capacity Factor |
|--------|-------------------|-----------------|
| 5 | Lower | ~40K tables max |
| 6 | Medium | ~1M tables max |
| 7 | Higher | ~2.4M tables max |

**Recommendation**:
- Use 7 levels for datasets > 100 GB
- Use 6 levels for datasets < 100 GB
- Never use < 5 levels in production

### lsm_growth_factor

**Default**: 8 (enterprise), 10 (mid-tier)
**Range**: 4-16

The ratio between consecutive level sizes. A growth factor of 8 means level N+1
is 8x larger than level N.

**Trade-offs**:
- **Higher growth factor (10-16)**:
  - Fewer levels needed for same capacity
  - Lower read amplification
  - Higher write amplification (more data moved per compaction)
  - Better for read-heavy workloads

- **Lower growth factor (4-8)**:
  - More levels for same capacity
  - Higher read amplification
  - Lower write amplification
  - Better for write-heavy workloads

**Write Amplification Formula**:
```
Write Amp ≈ growth_factor × (levels - 1) / 2
```

| Growth Factor | Levels | Approx Write Amp |
|---------------|--------|------------------|
| 8 | 7 | ~24x |
| 10 | 6 | ~25x |
| 4 | 7 | ~12x |

### lsm_compaction_ops

**Default**: 64 (enterprise), 32 (mid-tier), 4 (lite)
**Range**: 4-128

The number of operations (batches) accumulated in memory before flushing to disk.
This determines the memtable size.

**Trade-offs**:
- **Higher value (64-128)**:
  - Fewer flushes (less I/O)
  - Lower write amplification
  - More memory usage
  - Longer recovery time after crash

- **Lower value (4-32)**:
  - More frequent flushes
  - Higher write amplification
  - Less memory usage
  - Faster recovery

**Memory Impact**:
```
Memtable size ≈ lsm_compaction_ops × message_size_max × batch_utilization
```

### block_size

**Default**: 512 KiB (enterprise), 256 KiB (mid-tier), 4 KiB (lite)
**Range**: 4 KiB - 1 MiB

The unit of I/O for LSM table blocks.

**Trade-offs**:
- **Larger blocks (512 KiB - 1 MiB)**:
  - Better sequential read/write throughput
  - Lower metadata overhead
  - Higher space amplification (partially filled blocks)
  - Best for NVMe with high bandwidth

- **Smaller blocks (4 KiB - 128 KiB)**:
  - Lower space amplification
  - Better random read latency
  - Higher metadata overhead
  - Better for SATA SSDs

**Recommendation**:
- NVMe: 512 KiB
- SATA SSD: 256 KiB
- Evaluation: 4 KiB (matches sector size)

### lsm_manifest_compact_extra_blocks

**Default**: 2 (enterprise), 1 (mid-tier)
**Range**: 1-5

Extra blocks compacted beyond the minimum per half-bar. Higher values mean more
aggressive manifest compaction, keeping the manifest smaller but doing more work.

### lsm_table_coalescing_threshold_percent

**Default**: 40 (enterprise), 50 (mid-tier)
**Range**: 10-90

Tables with utilization below this threshold are candidates for coalescing (merging
with adjacent tables). Lower values trigger more aggressive coalescing.

**Trade-offs**:
- **Lower threshold (30-40%)**:
  - More coalescing, better space efficiency
  - More compaction work
  - Better for datasets with many deletions

- **Higher threshold (50-70%)**:
  - Less coalescing, higher space usage
  - Less compaction overhead
  - Better for append-only workloads

## Key-Range Filtering (vs Bloom Filters)

ArcherDB does **not** use traditional bloom filters. Instead, it uses key-range
filtering at the index block level:

### How It Works

1. Each table's index block stores:
   - Minimum key (`key_min`)
   - Maximum key (`key_max`)
   - Per-value-block key ranges

2. During point lookups:
   - Check if `key_min <= key <= key_max` for each table
   - Skip tables where key is outside range
   - For matching tables, check per-block ranges

3. Advantages over bloom filters:
   - Zero false positives for out-of-range keys
   - Works perfectly for range scans
   - No additional memory overhead
   - No configuration needed (no "bits per key")

### Equivalent False Positive Rate

For point queries, the effective false positive rate depends on key distribution:

| Key Distribution | Effective FP Rate |
|-----------------|-------------------|
| Sequential/monotonic | 0% (perfect) |
| Random uniform | ~1/levels (7-15%) |
| Clustered | Near 0% |

This is comparable to bloom filters with 14+ bits/key for most workloads.

## Compaction Tuning for Latency

### Ensuring No p99 Latency Spikes

ArcherDB's compaction is designed to not impact p99 latency:

1. **Dedicated Resources**: Compaction has dedicated I/O operations:
   ```zig
   lsm_compaction_iops_read_max = 18  // 16 + 2 index blocks
   lsm_compaction_iops_write_max = 17 // 16 + 1 index block
   ```

2. **Paced Execution**: Compaction is spread across "beats" (ticks), avoiding
   bursts of I/O that could starve foreground operations.

3. **I/O Separation**: Journal I/O and grid I/O have separate IOPS limits,
   preventing compaction from blocking writes.

### Monitoring Compaction Impact

Use the benchmark script to verify no latency spikes:

```bash
# Run compaction stress test
./scripts/benchmark_lsm.sh --scenario=compaction_stress --duration=300

# Check p99 metrics
# Expected: p99 during compaction should be < 2x baseline
```

If you observe spikes:
1. Reduce `grid_iops_write_max` to limit compaction throughput
2. Increase `lsm_compaction_ops` to reduce flush frequency
3. Check for disk I/O contention with other processes

## Memory Budget Calculation

### Formula

```
Total LSM Memory =
    grid_cache_size +
    manifest_memory +
    memtables +
    compaction_buffers

Where:
  grid_cache_size = grid_cache_size_default (configurable)
  manifest_memory = lsm_manifest_node_size × node_count
  memtables = 2 × lsm_compaction_ops × max_value_size × trees
  compaction_buffers = compaction_block_count × block_size
```

### Example: Enterprise Tier

```
Grid cache:       4 GB
Manifest:         128 MB
Memtables:        2 × 64 × 10 MB × 3 trees = 3.8 GB
Compaction:       64 × 512 KB = 32 MB
-----------------------------------------
Total:            ~8 GB + OS overhead
```

### Example: Mid-Tier

```
Grid cache:       2 GB
Manifest:         64 MB
Memtables:        2 × 32 × 10 MB × 3 trees = 1.9 GB
Compaction:       64 × 256 KB = 16 MB
-----------------------------------------
Total:            ~4 GB + OS overhead
```

## Benchmarking

### Running Benchmarks

```bash
# Quick verification
./scripts/benchmark_lsm.sh --writes=10000 --reads=1000 --duration=10

# Enterprise tier benchmark
./scripts/benchmark_lsm.sh --config=enterprise --duration=300 --scenario=mixed

# Mid-tier benchmark
./scripts/benchmark_lsm.sh --config=mid_tier --duration=300 --scenario=mixed

# Compaction stress test
./scripts/benchmark_lsm.sh --scenario=compaction_stress --duration=600

# JSON output for CI
./scripts/benchmark_lsm.sh --output=json --writes=100000 --reads=10000
```

### Interpreting Results

```
============================================================
  LSM Benchmark Results
============================================================

Configuration: enterprise
Scenario: mixed

Write Performance:
  Throughput: 1,234,567 ops/sec     # Target: > 1M
  Latency p99: 450 us               # Target: < 1ms

Read Performance:
  Throughput: 156,789 ops/sec       # Target: > 100k
  Latency p99: 780 us               # Target: < 1ms

Compaction Stress:
  p99 Spike Detected: false         # Target: false
  p99 During Compaction: 0.8 ms     # Should be < 2x baseline
  p99 Baseline: 0.6 ms
  Impact: 33%                       # Acceptable if < 100%
```

### Expected Results by Hardware

| Hardware | Writes/sec | Reads/sec | p99 Write | p99 Read |
|----------|-----------|-----------|-----------|----------|
| Enterprise NVMe | 1M+ | 100k+ | < 500us | < 800us |
| Mid-tier SSD | 500k+ | 50k+ | < 1ms | < 2ms |
| Development | 10k+ | 5k+ | < 5ms | < 10ms |

## What NOT to Change

Some parameters should not be modified without deep understanding:

### Never Modify in Production

1. **sector_size** (4096): Must match actual disk sector size
2. **superblock_copies** (4): Required for durability guarantees
3. **lsm_compaction_iops_***: Calculated automatically

### Avoid Modifying

1. **lsm_scans_max**: Can cause query failures if too low
2. **lsm_snapshots_max**: Can cause long-running queries to fail
3. **cache_line_size**: Must match CPU architecture

### Requires Restart

All cluster-level configurations require a full cluster restart to take effect.
There is no hot-reload capability for these parameters.

```bash
# Proper upgrade procedure:
1. Stop all replicas
2. Update configuration in build
3. Rebuild with new config
4. Start replicas (will re-verify config checksum)
```

## Troubleshooting

### High Write Latency

1. Check disk I/O with `iostat -x 1`
2. Verify NVMe is not thermal throttling
3. Reduce `lsm_compaction_ops` if memory pressure
4. Increase `journal_iops_write_max`

### High Read Latency

1. Increase `grid_cache_size_default`
2. Check if compaction is keeping up (`compaction pending` metric)
3. Reduce `lsm_levels` if dataset is small

### Compaction Falling Behind

1. Increase `lsm_growth_factor` (less data per compaction)
2. Increase `lsm_compaction_ops` (fewer compactions)
3. Add more CPU cores

### Out of Memory

1. Reduce `grid_cache_size_default`
2. Reduce `lsm_compaction_ops`
3. Use `lite` configuration for testing

## References

- [LSM Tree Design](docs/internals/lsm.md)
- [ArcherDB Configuration](src/config.zig)
- [Constants Documentation](src/constants.zig)
- [Benchmark Script](scripts/benchmark_lsm.sh)
