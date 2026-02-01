# ArcherDB Benchmark Results

This document describes the ArcherDB benchmark framework, performance targets,
methodology, and how to run benchmarks.

## Performance Targets

The following targets must be met for production readiness:

| Metric | Target | Requirement ID |
|--------|--------|----------------|
| 3-node throughput (baseline) | >=770K events/sec | BENCH-T-05 |
| 3-node throughput (stretch) | >=1M events/sec | BENCH-T-06 |
| Read latency P95 | <1ms | BENCH-L-05 |
| Read latency P99 | <10ms | BENCH-L-05 |
| Write latency P95 | <10ms | BENCH-L-06 |
| Write latency P99 | <50ms | BENCH-L-06 |

## Benchmark Types

### Throughput Benchmark

Measures insert throughput in events per second by batch-inserting events and
measuring the time per batch.

- Batch size: 1000 events per insert
- Calculation: `total_events / duration_seconds`
- Tests: 1-node, 3-node, 5-node, 6-node topologies

### Read Latency Benchmark

Measures query latency by looking up entities by UUID after pre-loading data.

- Pre-loads test dataset before measurement
- Queries random entity IDs from the loaded set
- Measures: P50, P95, P99 percentiles
- Tests: 1-node, 3-node, 5-node, 6-node topologies

### Write Latency Benchmark

Measures single-event insert latency (not batch).

- Inserts one event at a time
- Measures per-operation write time
- Measures: P50, P95, P99 percentiles
- Tests: 1-node, 3-node, 5-node, 6-node topologies

### Mixed Workload Benchmark

Combines reads and writes in realistic production ratios to simulate actual
workloads.

**How read_write_ratio works:**

- `read_write_ratio=0.8` means 80% reads, 20% writes (default)
- `read_write_ratio=1.0` means 100% reads (read-only)
- `read_write_ratio=0.0` means 100% writes (write-only)
- `read_write_ratio=0.5` means 50% reads, 50% writes

**Why mixed workloads matter:**

Production systems rarely perform only reads or only writes. Mixed workload
benchmarks capture realistic performance characteristics including:

- Read-write interference patterns
- Lock contention under mixed load
- Cache behavior with concurrent modifications
- Replication overhead during reads

## Running Benchmarks

### Quick Single-Topology Run

```bash
# Run all benchmark types on 3-node cluster
python test_infrastructure/benchmarks/cli.py run --topology 3 --time-limit 60

# Run with specific operation count limit
python test_infrastructure/benchmarks/cli.py run --topology 3 --op-count 10000
```

### Mixed Workload with Custom Ratio

```bash
# 80% reads, 20% writes (default)
python test_infrastructure/benchmarks/cli.py run --topology 3 --read-write-ratio 0.8

# 50% reads, 50% writes
python test_infrastructure/benchmarks/cli.py run --topology 3 --read-write-ratio 0.5

# Write-heavy workload (20% reads, 80% writes)
python test_infrastructure/benchmarks/cli.py run --topology 3 --read-write-ratio 0.2
```

### Full Suite Across All Topologies

```bash
# Run complete benchmark suite (1/3/5/6 node topologies)
python test_infrastructure/benchmarks/cli.py run --full-suite

# Exclude mixed workload tests
python test_infrastructure/benchmarks/cli.py run --full-suite --no-mixed
```

### Compare to Baseline

```bash
# Run benchmarks and compare to stored baseline
python test_infrastructure/benchmarks/cli.py compare --topology 3

# Save current results as new baseline
python test_infrastructure/benchmarks/cli.py baseline --topology 3 --save
```

### Programmatic Usage

```python
from test_infrastructure.benchmarks import BenchmarkOrchestrator, BenchmarkConfig

# Create orchestrator
orchestrator = BenchmarkOrchestrator()

# Configure benchmark
config = BenchmarkConfig(
    topology=3,
    time_limit_sec=60,
    op_count_limit=10_000,
    read_write_ratio=0.8,  # 80% reads, 20% writes
)

# Run individual benchmarks
throughput = orchestrator.run_throughput_benchmark(3, config)
read_latency = orchestrator.run_latency_read_benchmark(3, config)
write_latency = orchestrator.run_latency_write_benchmark(3, config)
mixed = orchestrator.run_mixed_workload_benchmark(3, config)

# Run full suite
results = orchestrator.run_full_suite(
    topologies=[1, 3, 5, 6],
    include_mixed=True,
)
```

## Statistical Methodology

### HDR Histogram for Percentiles

We use HDR (High Dynamic Range) Histogram for latency percentile calculation:

- O(1) recording time per sample
- O(1) percentile retrieval
- High precision across wide range (microseconds to hours)
- Handles outliers without truncation

When hdrhistogram is unavailable, falls back to sorted-array percentile
calculation (same accuracy, O(n log n) per percentile).

### Confidence Intervals

All mean values are reported with 95% confidence intervals using scipy.stats:

```
P95: 0.8ms +/- 0.1ms (95% CI)
```

This shows measurement reliability. Narrower intervals indicate more stable
measurements.

### Welch's t-test for Regression Detection

When comparing to baselines, we use Welch's t-test (unequal variance t-test):

- Does not assume equal variance between runs
- Provides p-value for statistical significance
- alpha=0.05 (5% significance level)
- Detects regressions when current > baseline significantly

### Coefficient of Variation (CV) Stability Check

Benchmarks continue running until measurements stabilize:

- Target CV: <10%
- Minimum samples: 1000
- Maximum stability runs: 10

This ensures results are reproducible and not dominated by noise.

## Output Formats

Results are generated in multiple formats:

| Format | Location | Purpose |
|--------|----------|---------|
| JSON | `reports/benchmarks/*.json` | CI automation, data processing |
| Markdown | `docs/BENCHMARKS.md` | Human review, documentation |
| Terminal | stdout | Interactive feedback during runs |
| CSV | `reports/benchmarks/*.csv` | Spreadsheet analysis |

## Historical Results

Baseline results are stored in `reports/history/`:

```
reports/history/
  baseline-1node.json
  baseline-3node.json
  baseline-5node.json
  baseline-6node.json
```

These are used for regression detection when running `cli.py compare`.

## Results

*Results will be populated after benchmark runs.*

To generate results:

```bash
# Run full suite and update this document
python test_infrastructure/benchmarks/cli.py run --full-suite --update-docs
```

---

*Last updated: 2026-02-01*
*Framework version: Phase 15-02*
