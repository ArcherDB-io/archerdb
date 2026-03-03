# ArcherDB Benchmark Guide

Guide for running, interpreting, and tracking ArcherDB performance benchmarks.

## Overview

ArcherDB benchmarks measure:

- **Throughput**: Events processed per second
- **Read latency**: Query response time percentiles
- **Write latency**: Insert response time percentiles
- **Mixed workload**: Combined read/write performance
- **Scaling**: Performance across topologies (1/3/5/6 nodes)

## Performance Targets

Production readiness requires meeting these targets:

| Metric | Baseline Target | Stretch Target |
|--------|-----------------|----------------|
| 3-node throughput | >=770K events/sec | >=1M events/sec |
| Read latency P95 | <1ms | <0.5ms |
| Read latency P99 | <10ms | <5ms |
| Write latency P95 | <10ms | <5ms |
| Write latency P99 | <50ms | <25ms |

## Running Benchmarks Locally

### Prerequisites

```bash
# Install benchmark dependencies
pip install -r test_infrastructure/requirements.txt

# Build ArcherDB (lite config for testing)
./zig/zig build -j4 -Dconfig=lite
```

### Quick Run (Single Topology)

```bash
# Run all benchmark types on 3-node cluster
python test_infrastructure/benchmarks/cli.py run --topology 3

# With time limit
python test_infrastructure/benchmarks/cli.py run --topology 3 --time-limit 60

# With operation count limit
python test_infrastructure/benchmarks/cli.py run --topology 3 --op-count 10000
```

### Full Suite (All Topologies)

```bash
# Run complete benchmark suite (1/3/5/6 node topologies)
python test_infrastructure/benchmarks/cli.py run --full-suite

# Exclude mixed workload tests (faster)
python test_infrastructure/benchmarks/cli.py run --full-suite --no-mixed
```

### Mixed Workload Benchmarks

Control the read/write ratio:

```bash
# 80% reads, 20% writes (default)
python test_infrastructure/benchmarks/cli.py run --topology 3 --read-write-ratio 0.8

# 50% reads, 50% writes
python test_infrastructure/benchmarks/cli.py run --topology 3 --read-write-ratio 0.5

# Write-heavy (20% reads, 80% writes)
python test_infrastructure/benchmarks/cli.py run --topology 3 --read-write-ratio 0.2

# Read-only
python test_infrastructure/benchmarks/cli.py run --topology 3 --read-write-ratio 1.0
```

### Compare to Baseline

```bash
# Compare current run to stored baseline
python test_infrastructure/benchmarks/cli.py compare --baseline baseline.json

# Compare specific topology
python test_infrastructure/benchmarks/cli.py compare --topology 3 --baseline benchmarks/history/baseline-3node.json

# Save current results as new baseline
python test_infrastructure/benchmarks/cli.py baseline --topology 3 --save
```

## Interpreting Results

### Throughput

Events processed per second. Higher is better.

```
Throughput: 823,456 events/sec
Target: >=770,000 events/sec
Status: PASS (107% of target)
```

Key factors:
- Batch size (larger batches = higher throughput)
- Network latency (lower = higher throughput)
- Node count (more nodes = higher total throughput, but overhead)

### Latency Percentiles

Query response times. Lower is better.

```
Read Latency:
  P50: 0.3ms  (median)
  P95: 0.8ms  (95% of requests)
  P99: 4.2ms  (99% of requests)

Target: P95 <1ms, P99 <10ms
Status: PASS
```

Percentile meanings:
- **P50 (median)**: Typical user experience
- **P95**: 95% of requests are this fast or faster
- **P99**: Captures tail latency, important for SLAs

### Confidence Intervals

All means are reported with 95% confidence intervals:

```
P95: 0.8ms +/- 0.1ms (95% CI)
```

Narrower intervals = more stable measurements. Wide intervals suggest:
- Insufficient samples
- High variance in measurements
- System noise

### Coefficient of Variation (CV)

Measures result stability:

```
CV: 8.2% (target: <10%)
```

- **<10%**: Results are stable, trustworthy
- **10-20%**: Somewhat noisy, consider more samples
- **>20%**: High variance, investigate system state

## Regression Detection

### Threshold

A **regression** is detected when:
- Performance degrades by >10% from baseline
- Statistical test confirms significance (p < 0.05)

### Statistical Method

We use **Welch's t-test** (unequal variance):

```python
from scipy.stats import ttest_ind
t_stat, p_value = ttest_ind(baseline, current, equal_var=False)
```

Benefits:
- Does not assume equal variance between runs
- Robust to different sample sizes
- Standard statistical rigor

### Comparison Report

```
Regression Analysis
==================
Baseline: 2026-01-25.json (770,000 events/sec)
Current:  2026-02-01.json (692,000 events/sec)

Change: -10.1%
p-value: 0.003
Status: REGRESSION DETECTED

Recommendation: Investigate recent changes
```

## Historical Tracking

### Weekly Runs

Every Sunday at 2 AM UTC, CI runs the full benchmark suite and stores results:

```
benchmarks/history/
  2026-01-05.json
  2026-01-12.json
  2026-01-19.json
  2026-01-26.json
  2026-02-02.json
  ...
```

### Baseline Files

Reference baselines for regression detection:

```
benchmarks/history/
  baseline-1node.json
  baseline-3node.json
  baseline-5node.json
  baseline-6node.json
```

### Visualization

Results are visualized using github-action-benchmark:

- **Throughput graph**: Events/sec over time
- **Latency graph**: P95/P99 over time
- **Scaling graph**: Performance vs node count

View at: `https://github.com/[org]/archerdb/benchmarks`

## CI Integration

### Weekly Workflow

The `weekly-benchmark.yml` workflow:

1. Spins up clusters (1/3/5/6 nodes)
2. Runs full benchmark suite
3. Compares to baseline
4. Alerts on >10% regression
5. Stores results in `benchmarks/history/`
6. Updates benchmark graphs

### Alerts

On regression detection:

- Workflow fails (visible in GitHub)
- Comment posted on triggering commit
- GitHub issue created with details
- Slack notification (if configured)

### Manual Trigger

```bash
# Trigger weekly benchmark manually
gh workflow run weekly-benchmark.yml
```

## Programmatic Usage

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
throughput = orchestrator.run_throughput_benchmark(config)
read_latency = orchestrator.run_latency_read_benchmark(config)
write_latency = orchestrator.run_latency_write_benchmark(config)
mixed = orchestrator.run_mixed_workload_benchmark(config)

# Access results
print(f"Throughput: {throughput.events_per_sec}")
print(f"Read P95: {read_latency.p95_ms}ms")
print(f"Write P95: {write_latency.p95_ms}ms")

# Run full suite
results = orchestrator.run_full_suite(
    topologies=[1, 3, 5, 6],
    include_mixed=True,
)

# Export results
results.to_json("benchmark_results.json")
results.to_csv("benchmark_results.csv")
```

## Output Formats

| Format | Location | Purpose |
|--------|----------|---------|
| JSON | `reports/benchmarks/*.json` | CI automation, data processing |
| CSV | `reports/benchmarks/*.csv` | Spreadsheet analysis |
| Terminal | stdout | Interactive feedback |
| Markdown | Updated docs | Human review |

### JSON Format

```json
{
  "timestamp": "2026-02-01T02:00:00Z",
  "topology": 3,
  "throughput": {
    "events_per_sec": 823456,
    "target": 770000,
    "passed": true
  },
  "read_latency": {
    "p50_ms": 0.3,
    "p95_ms": 0.8,
    "p99_ms": 4.2,
    "samples": 10000
  },
  "write_latency": {
    "p50_ms": 2.1,
    "p95_ms": 8.5,
    "p99_ms": 42.3,
    "samples": 2000
  },
  "metadata": {
    "version": "1.0.0",
    "git_sha": "abc1234",
    "runner": "ubuntu-latest-8-cores"
  }
}
```

## Best Practices

### Consistent Environment

- Use dedicated hardware or CI runners
- Close other applications during local runs
- Use the same build configuration tier (for example, lite vs standard)

### Warm-up

SDKs with JIT compilation (Java, Node.js) need warm-up:

| SDK | Recommended Warm-up |
|-----|---------------------|
| Java | 500 iterations |
| Node.js | 200 iterations |
| Python | 100 iterations |
| Go | 100 iterations |
| C | 50 iterations |

### Sample Size

- Minimum 1000 samples for percentile accuracy
- Continue until CV < 10% (stability check)
- Maximum 10 stability check rounds

### Fresh Cluster

Each benchmark run should use a fresh cluster to ensure isolated measurements without accumulated state affecting results.

## Troubleshooting

### Results Vary Widely

- Increase sample count
- Check for background processes
- Verify network stability
- Use constrained build (`-Dconfig=lite`)

### Benchmarks Hang

- Check server health: `curl http://localhost:3001/ping`
- Verify cluster formed: `curl http://localhost:3001/topology`
- Check logs for errors

### Results Don't Match CI

- Use same hardware profile as CI
- Use same build configuration
- Account for warm-up differences

## See Also

- [Detailed Benchmark Framework](../BENCHMARKS.md) - Statistical methodology
- [Testing Guide](../testing/README.md) - Running tests locally
- [CI Tiers](../testing/ci-tiers.md) - Weekly benchmark workflow
- [Performance Tuning](../performance-tuning.md) - Optimization guidance

---

*Last updated: 2026-02-01*
