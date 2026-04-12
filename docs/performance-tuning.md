# Performance Tuning Guide

This guide helps you optimize ArcherDB for your specific workload. Use the checked-in benchmark artifacts and `docs/BENCHMARKS.md` for current measured results; this document focuses on tuning levers and validation workflow rather than fixed product numbers.

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

### Validation Goals

| Metric | Goal |
|--------|------|
| Write throughput | Validate against a comparable checked-in baseline |
| Read P99 | <10ms on the target hardware profile |
| Radius query P99 | <50ms on the target hardware profile |
| Polygon query P99 | <100ms on the target hardware profile |
| Memory stability | No leaks or unbounded growth |

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

Use maintained benchmark entry points for current measurements:

```bash
# Quick single-node smoke via the built-in benchmark driver
zig-out/bin/archerdb benchmark --event-count=100000 --query-uuid-count=10000 --query-radius-count=1000 --query-polygon-count=100

# Time-bounded multi-node harness run
python3 test_infrastructure/benchmarks/cli.py run --topology 3 --time-limit 60

# Full release-style suite
python3 test_infrastructure/benchmarks/cli.py run --full-suite
```

The legacy `./scripts/benchmark_lsm.sh` path now only forwards simple single-node
`write_only` / `read_only` / `mixed` smoke runs to `archerdb benchmark`. It no
longer fabricates benchmark numbers or supports time-bounded benchmark modes.

### Interpreting Results

Key metrics to watch:

```
Write Performance:
  Throughput: compare against the latest checked-in baseline on comparable hardware
  P99 Latency: keep tail latency stable while ingest volume increases

Read Performance:
  UUID Query P99: validate against your target SLA and checked-in evidence
  Radius Query P99: validate against your target SLA and checked-in evidence
  Polygon Query P99: validate against your target SLA and checked-in evidence

Stability:
  Memory Growth: 0 MB/hour (no leaks)
  Throughput CV: < 10% variance on repeated runs
```

### Hardware Scaling

Absolute throughput depends primarily on CPU, memory bandwidth, storage, and topology.
Treat checked-in benchmark artifacts as evidence for a specific machine/profile, not as
universal product guarantees.

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
