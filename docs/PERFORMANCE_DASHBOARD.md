# Performance Dashboard

This document explains how to run benchmarks, view the performance dashboard, manage baselines, and understand regression detection.

## Overview

The ArcherDB benchmark framework provides:

- **Throughput benchmarks**: Measure insert events/second
- **Latency benchmarks**: Measure read/write P50/P95/P99 latency
- **Scalability benchmarks**: Measure throughput scaling across node counts
- **SDK benchmarks**: Compare performance across all 6 SDKs
- **Regression detection**: Compare results against baselines

## Running Benchmarks

### Quick Start

```bash
# Run full benchmark suite (1/3/5/6 node topologies)
python -m test_infrastructure.benchmarks.run_suite

# Run with specific topology
python -m test_infrastructure.benchmarks.run_suite --topology 3

# Run scalability benchmark
python -c "
from test_infrastructure.benchmarks import ScalabilityBenchmark
benchmark = ScalabilityBenchmark()
result = benchmark.run_scalability_suite()
print(benchmark.generate_report(result))
"
```

### SDK Benchmark

Compare performance across Python, Node.js, Go, Java, C, and Zig SDKs:

```bash
python -c "
from test_infrastructure.benchmarks import SDKBenchmark
benchmark = SDKBenchmark()
results = benchmark.run_full_suite()
print(benchmark.generate_report(results))
"
```

SDKs must be within 20% of mean latency to pass parity check.

### Workload Patterns

Two workload patterns are available:

1. **Uniform**: Random distribution across entire globe
   - lat: [-90, +90], lon: [-180, +180]
   - Tests global distribution performance

2. **City Concentrated**: Events clustered around major cities
   - Uses 30 cities from `test_infrastructure/generators/city_coordinates.py`
   - Gaussian distribution within 50km radius
   - Models realistic geographic hotspots

## Viewing the Dashboard

Generate performance dashboard:

```bash
python -c "
from test_infrastructure.benchmarks import generate_dashboard
generate_dashboard('reports/dashboard.md')
"
```

View the dashboard:

```bash
cat reports/dashboard.md
```

The dashboard includes:

- Recent benchmark runs summary table
- Throughput trend chart (ASCII)
- P95 latency trend chart (ASCII)
- Active baselines list
- Performance targets status

## Managing Baselines

### Setting a Baseline

```bash
python -c "
from test_infrastructure.benchmarks import save_baseline
# After running a benchmark, save as baseline
result = {...}  # Your benchmark result
save_baseline(result, topology=3, benchmark_type='throughput')
"
```

### Loading a Baseline

```bash
python -c "
from test_infrastructure.benchmarks import load_baseline
baseline = load_baseline(topology=3, benchmark_type='throughput')
print(baseline)
"
```

### Listing Baselines

```bash
ls -la reports/baselines/
```

Baseline files follow naming convention:
`baseline-{topology}node-{benchmark_type}.json`

## Regression Detection

### How It Works

Regression detection compares current results against stored baselines:

1. **Threshold**: Default 10% change
2. **Throughput**: Lower value = regression (higher is better)
3. **Latency**: Higher value = regression (lower is better)

### Running Regression Check

```bash
python -c "
from test_infrastructure.benchmarks import load_baseline, detect_regression

current = {...}  # Current benchmark result
baseline = load_baseline(topology=3, benchmark_type='throughput')

if baseline:
    is_regression = detect_regression(current, baseline, threshold_pct=10.0)
    print(f'Regression detected: {is_regression}')
"
```

### Detailed Comparison

```bash
python -c "
from test_infrastructure.benchmarks import compare_to_baseline

comparisons = compare_to_baseline(current, baseline)
for metric, comp in comparisons.items():
    status = 'REGRESSION' if comp.is_regression else 'OK'
    print(f'{metric}: {comp.delta_pct:+.1f}% [{status}]')
"
```

## Performance Targets

The following performance targets are from the project requirements:

| Metric | Baseline Target | Stretch Goal |
|--------|-----------------|--------------|
| 3-node throughput | 770,000 events/sec | 1,000,000 events/sec |
| Read latency P95 | < 1 ms | - |
| Read latency P99 | < 10 ms | - |
| Write latency P95 | < 10 ms | - |
| Write latency P99 | < 50 ms | - |

### Checking Targets

```bash
python -c "
from test_infrastructure.benchmarks import BenchmarkOrchestrator

orchestrator = BenchmarkOrchestrator()
results = orchestrator.run_full_suite(topologies=[3])
checks = orchestrator.check_targets(results)

for target, check in checks.items():
    status = 'PASS' if check['passed'] else 'FAIL'
    print(f'{target}: {check[\"value\"]:.0f} vs {check[\"target\"]} [{status}]')
"
```

## Historical Results

Results are stored in `reports/history/` with timestamp filenames:

```
reports/history/
  throughput-20260201-120000.json
  latency_read-20260201-120100.json
  scalability-20260201-120200.json
```

Load historical results:

```bash
python -c "
from test_infrastructure.benchmarks import load_results

results = load_results('throughput', limit=10)
for r in results:
    print(f'{r[\"timestamp\"]}: {r.get(\"throughput_events_per_sec\", 0):,.0f} events/sec')
"
```

## CI Integration

Benchmarks are integrated into CI with three tiers:

1. **Smoke** (<5 min): Every push
2. **PR** (<15 min): Pull requests
3. **Nightly** (2 hours): 2 AM UTC

Regression detection runs automatically and fails the build if performance degrades >10%.

## Troubleshooting

### No Baseline Available

```
Error: No baseline for 3-node topology
```

Solution: Run benchmarks first, then save as baseline.

### High Variance in Results

If results show high coefficient of variation (>10%), try:

1. Increase warmup iterations
2. Run longer benchmarks (increase time limit)
3. Ensure cluster is not under other load

### SDK Parity Failure

If SDK benchmark fails parity check:

1. Check specific outlier SDKs in report
2. Investigate SDK-specific issues
3. 20% threshold may need adjustment for specific operations
