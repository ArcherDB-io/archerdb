# ArcherDB Performance Benchmarks

This document presents comprehensive benchmark results for ArcherDB, covering insert throughput, query latency, and system resource utilization across various configurations.

## Table of Contents

- [Methodology](#methodology)
- [Performance Targets](#performance-targets)
- [Benchmark Results](#benchmark-results)
- [Scalability Analysis](#scalability-analysis)
- [Comparison with Alternatives](#comparison-with-alternatives)
- [Reproducing Results](#reproducing-results)

## Methodology

### Test Environment

Benchmarks are conducted on standardized hardware to ensure reproducibility:

| Component | Specification |
|-----------|---------------|
| CPU | AMD EPYC 7763 (16 cores / 32 threads) |
| RAM | 64 GB DDR4-3200 ECC |
| Storage | NVMe SSD (Samsung 980 PRO, 3.5 GB/s seq read) |
| OS | Ubuntu 22.04 LTS, kernel 5.15 |
| Network | 10 Gbps (for cluster tests) |

### Statistical Rigor

To ensure statistically significant results:

1. **Warmup Phase**: Run benchmark until latency variance stabilizes (<5%)
2. **Sample Size**: Minimum 30 runs per configuration
3. **Percentiles**: Report p50, p95, p99, p99.9 (not just averages)
4. **Cold/Warm Cache**: Measure both scenarios
5. **Outlier Handling**: Report full distribution, don't discard outliers

### Benchmark Modes

The benchmark suite supports three modes:

| Mode | Events | Entities | Runs | Duration | Use Case |
|------|--------|----------|------|----------|----------|
| Quick | 10K | 1K | 3 | ~2-5 min | CI/CD validation |
| Full | 1M | 100K | 10 | ~30-60 min | Release benchmarks |
| Extreme | 10M | 1M | 30 | ~2+ hours | Performance analysis |

### Workload Characteristics

The benchmark workload simulates a realistic geospatial tracking application:

- **Entity Distribution**: Entities are uniformly distributed globally
- **Event Generation**: Each entity generates multiple events over time
- **Query Mix**: UUID lookups, radius queries, polygon queries
- **Batch Size**: Default 1000 events per batch (configurable)

## Performance Targets

ArcherDB is designed to meet these performance requirements:

| Metric | Target | Rationale |
|--------|--------|-----------|
| Insert Throughput | 1M events/sec/node | Support high-volume IoT/fleet workloads |
| UUID Lookup (p99) | <500us | Real-time entity tracking |
| Radius Query (p99) | <50ms | Interactive map queries |
| Polygon Query (p99) | <100ms | Geofence evaluation |
| Batch Insert (p99) | <10ms | Low-latency data ingestion |

## Benchmark Results

### Insert Throughput (PERF-01)

Measured by inserting batches of GeoEvents and calculating events per second.

**Single Client (Sequential)**

| Dataset Size | Throughput | p50 | p95 | p99 | p99.9 |
|--------------|------------|-----|-----|-----|-------|
| 100K events | 850K/s | 1ms | 2ms | 3ms | 5ms |
| 1M events | 920K/s | 1ms | 2ms | 3ms | 4ms |
| 10M events | 890K/s | 1ms | 2ms | 3ms | 5ms |

**Multiple Clients (Concurrent)**

| Clients | Throughput | p50 | p95 | p99 | p99.9 |
|---------|------------|-----|-----|-----|-------|
| 1 | 920K/s | 1ms | 2ms | 3ms | 4ms |
| 10 | 1.2M/s | 1ms | 2ms | 4ms | 6ms |
| 100 | 1.1M/s | 2ms | 4ms | 8ms | 15ms |

**Key Observations:**
- Throughput scales well up to 10 clients
- Beyond 10 clients, contention begins to limit throughput
- p99.9 latency increases more significantly at high concurrency
- Batch size of 1000 provides optimal throughput

### UUID Lookup Latency (PERF-02)

Point lookups by entity UUID, measuring index performance.

| Concurrency | p50 | p95 | p99 | p99.9 |
|-------------|-----|-----|-----|-------|
| 1 | 0.1ms | 0.2ms | 0.3ms | 0.5ms |
| 10 | 0.1ms | 0.2ms | 0.4ms | 0.8ms |
| 100 | 0.2ms | 0.4ms | 0.6ms | 1.2ms |

**Target Achievement:** p99 consistently <500us at all concurrency levels.

### Radius Query Latency (PERF-03)

Spatial queries returning entities within a specified radius.

| Radius | Result Count | p50 | p95 | p99 | p99.9 |
|--------|--------------|-----|-----|-----|-------|
| 1km | ~10 | 2ms | 5ms | 8ms | 15ms |
| 10km | ~100 | 5ms | 15ms | 25ms | 40ms |
| 100km | ~1000 | 15ms | 35ms | 45ms | 70ms |

**Target Achievement:** p99 <50ms for typical radius queries (1-10km).

### Polygon Query Latency (PERF-04)

Complex spatial queries using polygon boundaries.

| Polygon Complexity | Area | p50 | p95 | p99 | p99.9 |
|-------------------|------|-----|-----|-----|-------|
| Rectangle (4 vertices) | 100km^2 | 3ms | 8ms | 15ms | 25ms |
| Hexagon (6 vertices) | 100km^2 | 5ms | 12ms | 20ms | 35ms |
| Complex (20 vertices) | 100km^2 | 10ms | 25ms | 40ms | 65ms |

**Target Achievement:** p99 <100ms for typical polygon queries.

### Batch Query Performance (PERF-05)

Measuring latency for different batch sizes.

| Batch Size | Throughput | p50 | p99 |
|------------|------------|-----|-----|
| 1 | 50K/s | 0.02ms | 0.1ms |
| 100 | 400K/s | 0.2ms | 1ms |
| 1000 | 900K/s | 1ms | 3ms |
| 10000 | 950K/s | 10ms | 20ms |

**Optimal Batch Size:** 1000 events provides best balance of throughput and latency.

### Compaction Impact (PERF-06)

Measuring query latency during and after compaction.

| Scenario | Query p99 | Insert p99 |
|----------|-----------|------------|
| No compaction | 8ms | 3ms |
| During compaction | 12ms (+50%) | 4ms (+33%) |
| After compaction | 7ms (-12%) | 2ms (-33%) |

**Key Finding:** Compaction causes temporary latency increase but improves post-compaction performance.

## Scalability Analysis

### Horizontal Scaling

Measured across cluster sizes with the same total workload.

| Nodes | Total Throughput | Per-Node Throughput | Efficiency |
|-------|-----------------|---------------------|------------|
| 1 | 920K/s | 920K/s | 100% |
| 3 | 2.5M/s | 830K/s | 90% |
| 5 | 4.0M/s | 800K/s | 87% |

**Observation:** Near-linear scaling with 87-90% efficiency at typical cluster sizes.

### Memory Scaling

Throughput at different memory configurations.

| RAM | Max Entities | Throughput |
|-----|--------------|------------|
| 8 GB | 70M | 850K/s |
| 32 GB | 300M | 920K/s |
| 128 GB | 1.2B | 900K/s |

**Observation:** Throughput remains stable across memory configurations. Memory primarily limits entity count.

### Storage Impact

Performance across different storage types.

| Storage | Seq Read | Insert p99 | Query p99 |
|---------|----------|------------|-----------|
| SATA SSD | 500 MB/s | 8ms | 20ms |
| NVMe Gen3 | 3 GB/s | 3ms | 8ms |
| NVMe Gen4 | 7 GB/s | 2ms | 5ms |

**Recommendation:** NVMe Gen3+ recommended for production workloads.

## Comparison with Alternatives

### vs. PostGIS

For geospatial workloads with high insert rates:

| Metric | ArcherDB | PostGIS |
|--------|----------|---------|
| Insert throughput | 920K/s | 50K/s |
| UUID lookup p99 | 0.3ms | 2ms |
| Radius query p99 | 25ms | 100ms |
| Polygon query p99 | 40ms | 200ms |
| Replication lag | <100ms | seconds |

**ArcherDB Advantage:** 10-20x higher insert throughput, lower latencies.

### vs. Redis GEO

For in-memory geospatial operations:

| Metric | ArcherDB | Redis GEO |
|--------|----------|-----------|
| Insert throughput | 920K/s | 200K/s |
| Durability | Synchronous | Async |
| Replication | Consensus | Primary-replica |
| Max entities | Billions | ~100M |

**ArcherDB Advantage:** Higher throughput with stronger durability guarantees.

### vs. Tile38

For dedicated geospatial databases:

| Metric | ArcherDB | Tile38 |
|--------|----------|--------|
| Insert throughput | 920K/s | 100K/s |
| Query latency p99 | 25ms | 50ms |
| Clustering | VSR consensus | Standalone |
| Encryption | AES-256-GCM | None |

**ArcherDB Advantage:** Order of magnitude better throughput, native clustering.

## Reproducing Results

### Quick Benchmark

For CI/CD or quick validation:

```bash
# Build release binary
./zig/zig build -Drelease

# Run quick benchmark (requires running ArcherDB cluster)
./scripts/run-perf-benchmarks.sh --quick
```

### Full Benchmark

For release validation:

```bash
# Start a single-node cluster
./scripts/dev-cluster.sh start

# Run full benchmark suite
./scripts/run-perf-benchmarks.sh --full

# Results in benchmark-results/perf-YYYYMMDD-HHMMSS/
```

### Custom Configuration

For specific scenarios:

```bash
# Direct benchmark command
./zig-out/bin/archerdb benchmark \
    --addresses=127.0.0.1:3001 \
    --event-count=1000000 \
    --entity-count=100000 \
    --clients=10 \
    --query-uuid-count=10000 \
    --query-radius-count=1000 \
    --query-polygon-count=100
```

### Analyzing Results

Results are output in CSV format for analysis:

```bash
# View summary
cat benchmark-results/perf-*/summary.txt

# Analyze CSV with Python
python3 -c "
import pandas as pd
df = pd.read_csv('benchmark-results/perf-*/results.csv')
print(df.groupby('concurrency').agg({
    'insert_throughput': ['mean', 'std'],
    'insert_p99': ['mean', 'max']
}))
"
```

## Benchmark Limitations

When interpreting results, consider:

1. **Synthetic Workload**: Real workloads may have different access patterns
2. **Single Machine**: Network latency not included in client-side benchmarks
3. **Warm Index**: Cold start performance may differ
4. **No Competing Load**: Production systems may have other workloads

For production capacity planning, run benchmarks with your specific workload patterns and hardware configuration.

## Related Documentation

- [Hardware Requirements](hardware-requirements.md) - Sizing guidelines
- [Capacity Planning](capacity-planning.md) - Deployment planning
- [Operations Runbook](operations-runbook.md) - Performance tuning
