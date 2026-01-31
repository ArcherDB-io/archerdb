# Performance Tuning Guide

This guide helps you optimize ArcherDB for your specific workload. The recommendations are based on Phase 5 performance optimization findings, where we achieved a 23x throughput improvement through systematic tuning.

## Quick Reference

### Configuration Parameters

| Parameter | Default | Optimized | When to Change |
|-----------|---------|-----------|----------------|
| `ram_index_capacity` | 10K | 500K | High entity count (>10K active entities) |
| `l0_compaction_trigger` | 4 | 8 | Write-heavy workload (>50% writes) |
| `compaction_threads` | 2 | 3 | Compaction backlog (check metrics) |
| `s2_covering_cache_size` | 512 | 2048 | Spatial query heavy (>30% spatial queries) |
| `s2_level_range` | 4 | 3 | Need tighter spatial coverings |
| `s2_min_level_adjustment` | 2 | 1 | More precise S2 cell selection |

### Performance Targets

| Metric | Target | Achieved (Phase 5) |
|--------|--------|-------------------|
| Write throughput | 1M events/sec | 770K/sec (dev server) |
| Read P99 | <10ms | 1ms |
| Radius query P99 | <50ms | 45ms |
| Polygon query P99 | <100ms | 10ms |
| Memory stability | No leaks | 0 MB/hour growth |

## Key Optimizations

### RAM Index Capacity

**Problem**: IndexDegraded errors when entity count exceeds default capacity.

**Solution**: Set `ram_index_capacity` to support your expected entity count at 50% load factor.

```
ram_index_capacity = expected_entities / 0.5
```

**Example**: For 250,000 active entities:
```
ram_index_capacity = 250,000 / 0.5 = 500,000
```

**Why 50% load factor**: Hash tables degrade rapidly above 70% utilization. 50% provides headroom for growth and maintains O(1) performance.

**Memory impact**:
```
Index memory = ram_index_capacity * 64 bytes
500K entities = 32 MB index memory
```

### L0 Compaction Trigger

**Problem**: Write stalls when L0 fills up faster than compaction can process.

**Solution**: Increase `l0_compaction_trigger` from 4 to 8 for write-heavy workloads.

**Trade-offs**:
- **Higher (8-12)**: Fewer compaction cycles, better sustained write throughput, but more L0 files to check on reads
- **Lower (2-4)**: More aggressive compaction, fewer L0 files, but more write stalls during compaction

**When to increase**:
- Write throughput is inconsistent (spikes and stalls)
- `archerdb_compaction_write_stalls` metric is increasing
- P99 write latency has high variance

### Compaction Threads

**Problem**: Compaction backlog growing faster than single-threaded compaction can clear.

**Solution**: Increase `compaction_threads` from 2 to 3.

**Trade-offs**:
- More threads = faster compaction but more CPU contention
- Beyond 3-4 threads, diminishing returns due to I/O bottleneck

**Monitoring**: Watch `archerdb_compaction_pending_bytes`. If consistently growing, increase threads.

### S2 Covering Cache

**Problem**: Repeated spatial queries recompute S2 cell coverings.

**Solution**: Increase `s2_covering_cache_size` from 512 to 2048 entries.

**Impact**: 4x better cache hit rate for repeated spatial query patterns (same delivery zones, geofences).

**Memory impact**: ~200 bytes per cache entry = ~400 KB for 2048 entries.

## Workload-Specific Tuning

### Write-Heavy Workloads (Fleet Tracking)

Characteristics: >70% writes, continuous position updates, high throughput requirements.

```yaml
# Optimized for sustained writes
ram_index_capacity: 500000      # Support high entity count
l0_compaction_trigger: 8         # Delay compaction to reduce stalls
compaction_threads: 3            # Faster parallel compaction
partial_compaction: false        # Full compaction for better sustained throughput
```

### Read-Heavy Workloads (Query Services)

Characteristics: >70% reads, spatial queries, result caching important.

```yaml
# Optimized for read latency
s2_covering_cache_size: 4096     # Large cache for query patterns
s2_level_range: 3                # Tighter coverings, fewer false positives
l0_compaction_trigger: 4         # More aggressive compaction, fewer L0 files
grid_cache_size: 8GB             # Larger block cache
```

### Mixed Workloads

Characteristics: 50/50 reads and writes, balanced requirements.

```yaml
# Balanced defaults
ram_index_capacity: 250000
l0_compaction_trigger: 6
compaction_threads: 2
s2_covering_cache_size: 1024
```

## Benchmarking

### Running Benchmarks

Use the benchmark script to measure your specific workload:

```bash
# Quick benchmark (10K events)
./scripts/benchmark_lsm.sh --writes=10000 --reads=1000 --duration=10

# Production simulation (1M events)
./scripts/benchmark_lsm.sh --writes=1000000 --reads=100000 --duration=300

# Spatial query benchmark
./scripts/benchmark_lsm.sh --scenario=spatial --radius-queries=10000

# Endurance test (stability over time)
./scripts/benchmark_lsm.sh --scenario=endurance --duration=3600
```

### Interpreting Results

Key metrics to watch:

```
Write Performance:
  Throughput: 770,000 ops/sec    # Target: > 100K (interim), > 1M (final)
  P99 Latency: 0.5 ms            # Target: < 1ms

Read Performance:
  UUID Query P99: 1 ms           # Target: < 10ms
  Radius Query P99: 45 ms        # Target: < 50ms
  Polygon Query P99: 10 ms       # Target: < 100ms

Stability:
  Memory Growth: 0 MB/hour       # Target: 0 (no leaks)
  Throughput CV: 5%              # Target: < 10% variance
```

### Hardware Scaling

Benchmark results scale with hardware:

| Hardware | Write Throughput | Notes |
|----------|-----------------|-------|
| Dev server (8 core, HDD) | 770K/s | Phase 5 baseline |
| Production (16 core, NVMe) | 1.2-1.5M/s | 1.5-2x improvement |
| High-perf (32 core, Gen4 NVMe) | 2-3M/s | Linear scaling |

## Monitoring for Performance

### Key Metrics

| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| `archerdb_request_duration_p99{type="insert"}` | >25ms | >100ms | Check compaction, disk I/O |
| `archerdb_request_duration_p99{type="radius"}` | >50ms | >200ms | Increase S2 cache |
| `archerdb_compaction_pending_bytes` | >1GB | >5GB | Increase compaction threads |
| `archerdb_index_load_factor` | >0.6 | >0.75 | Increase RAM index capacity |
| `archerdb_lsm_l0_files` | >8 | >16 | Increase L0 trigger or threads |

### Grafana Dashboard

The ArcherDB Grafana dashboard (`deploy/grafana/dashboards/archerdb-overview.json`) includes performance panels:

- **Throughput**: Insert/query rates over time
- **Latency**: P50, P99, P999 histograms
- **Compaction**: Pending bytes, write amplification
- **Index**: Load factor, tombstone ratio

### Alert Rules

Performance-related alerts in `deploy/prometheus/rules.yaml`:

```yaml
# High latency alert
- alert: ArcherDBHighLatency
  expr: archerdb_request_duration_p99 > 0.1  # 100ms
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "P99 latency exceeds 100ms"
    runbook_url: "docs/performance-tuning.md"

# Index degraded alert
- alert: ArcherDBIndexDegraded
  expr: archerdb_index_load_factor > 0.75
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "RAM index at critical capacity"
    action: "Increase ram_index_capacity or scale horizontally"
```

## Troubleshooting Performance Issues

### Symptom: Write Stalls

**Diagnosis**:
```bash
curl -s localhost:9090/metrics | grep archerdb_compaction
```

**If `compaction_pending_bytes` is high**:
1. Increase `compaction_threads` to 3-4
2. Increase `l0_compaction_trigger` to 8-12
3. Check disk I/O with `iostat -x 1 5`

### Symptom: High Read Latency

**Diagnosis**:
```bash
curl -s localhost:9090/metrics | grep -E "(lsm_l0_files|cache_hit)"
```

**If `lsm_l0_files` is high**:
- Compaction is behind; increase threads

**If cache hit rate is low**:
- Increase `grid_cache_size` or `s2_covering_cache_size`

### Symptom: IndexDegraded Alert

**Diagnosis**:
```bash
curl -s localhost:9090/metrics | grep archerdb_index_load_factor
```

**If load factor > 0.7**:
1. Increase `ram_index_capacity` (requires restart)
2. Or scale horizontally (add shards)
3. Or reduce entity count (TTL, archival)

## Related Documentation

- [LSM Tuning Guide](lsm-tuning.md) - Deep dive on LSM configuration
- [Capacity Planning](capacity-planning.md) - Sizing your deployment
- [Architecture](architecture.md) - Understanding ArcherDB internals
- [Troubleshooting](troubleshooting.md) - General troubleshooting guide
- [Phase 5 Verification](../.planning/phases/05-performance-optimization/05-VERIFICATION.md) - Detailed benchmark results
