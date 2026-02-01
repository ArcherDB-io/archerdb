# Phase 15: Benchmark Framework - Research

**Researched:** 2026-02-01
**Domain:** Performance benchmarking with statistical rigor, latency/throughput measurement, regression detection
**Confidence:** HIGH

## Summary

Phase 15 requires building a comprehensive benchmark framework that measures throughput (events/sec across 1/3/5/6 node configurations) and latency (P50/P95/P99 percentiles for reads and writes) with statistical rigor. The framework must validate that ArcherDB meets performance targets (>=770K events/sec on 3-node, read P95 <1ms/P99 <10ms, write P95 <10ms/P99 <50ms).

The research reveals that ArcherDB already has substantial benchmark infrastructure in place: the Zig-based `geo_benchmark_load.zig` for native benchmarking, Python/Node.js SDK benchmarks, and test infrastructure from Phase 11 (cluster management, data generators, warmup protocols). The key work is creating an orchestration layer that ties these together with proper statistical analysis, multi-topology execution, and comprehensive reporting.

**Primary recommendation:** Build a Python-based benchmark orchestrator that leverages existing components (Phase 11 cluster.py, data generators, warmup protocols) and adds statistical analysis (scipy.stats for CI/t-tests), HDR Histogram-based percentile calculation, and multi-format reporting (JSON/Markdown/CSV/terminal).

## Standard Stack

The established libraries/tools for this domain:

### Core (Existing - Leverage)
| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| geo_benchmark_load.zig | src/archerdb/ | Native benchmark driver | Already implements throughput/latency measurement |
| cluster.py | test_infrastructure/harness/ | Cluster lifecycle | Phase 11 infrastructure, handles 1-6 node topologies |
| data_generator.py | test_infrastructure/generators/ | Test data generation | Uniform/city-concentrated distributions per CONTEXT.md |
| warmup_protocols.json | test_infrastructure/ci/ | SDK warmup iterations | Language-specific warmup counts per Phase 11 |

### Core (New - Build)
| Component | Purpose | Why Standard |
|-----------|---------|--------------|
| scipy.stats | Statistical tests (t-test, confidence intervals) | Standard Python stats library |
| hdrhistogram | Percentile calculation with precision | Industry standard for latency, 3-6ns recording |
| rich | Terminal output with colors/tables | Modern Python terminal formatting |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| numpy | latest | Array operations for stats | Sample aggregation |
| pandas | latest | DataFrame for result organization | CSV export, aggregation |
| json | stdlib | JSON serialization | Reports and historical storage |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| hdrhistogram | sorted percentile | HDR has O(1) record, O(1) percentile; sorted is O(n) per percentile |
| scipy t-test | manual calculation | scipy is well-tested, handles edge cases |
| rich | colorama | rich has better table formatting built-in |

**Installation:**
```bash
pip install scipy hdrhistogram rich numpy pandas
```

## Architecture Patterns

### Recommended Project Structure
```
test_infrastructure/
├── benchmarks/                    # NEW: Benchmark framework
│   ├── __init__.py
│   ├── orchestrator.py            # Main benchmark coordinator
│   ├── config.py                  # BenchmarkConfig dataclass
│   ├── executor.py                # Run benchmarks, collect samples
│   ├── stats.py                   # Statistical analysis (CI, t-test, CV)
│   ├── histogram.py               # HDR Histogram wrapper for percentiles
│   ├── reporter.py                # Multi-format output (JSON/MD/CSV/terminal)
│   ├── regression.py              # Regression detection logic
│   ├── workloads/
│   │   ├── __init__.py
│   │   ├── throughput.py          # Insert throughput workload
│   │   ├── latency_read.py        # Read latency workload
│   │   └── latency_write.py       # Write latency workload
│   └── cli.py                     # Command-line interface
├── generators/                    # Phase 11 (existing)
├── harness/                       # Phase 11 (existing)
├── ci/                            # Phase 11 (existing)
└── fixtures/                      # Phase 11 (existing)

reports/
├── benchmarks/                    # JSON results per run
│   └── YYYYMMDD-HHMMSS-{topology}.json
└── history/                       # Git-tracked historical results
    └── baseline-{topology}.json

docs/
└── BENCHMARKS.md                  # Human-readable results
```

### Pattern 1: Dual Termination Benchmark Execution
**What:** Run until EITHER time limit OR operation count is reached, whichever comes first
**When to use:** All benchmark runs per CONTEXT.md decision
**Example:**
```python
# Source: CONTEXT.md decision
class BenchmarkExecutor:
    def run(
        self,
        workload: Workload,
        time_limit_sec: float = 60.0,
        op_count_limit: int = 100_000,
    ) -> List[Sample]:
        samples = []
        start = time.perf_counter()
        ops = 0

        while True:
            elapsed = time.perf_counter() - start
            if elapsed >= time_limit_sec or ops >= op_count_limit:
                break

            sample = workload.execute_one()
            samples.append(sample)
            ops += 1

        return samples
```

### Pattern 2: Warmup Until Stable + Iteration Count
**What:** Combine Phase 11 iteration counts with CV-based stability check
**When to use:** Warmup phase per CONTEXT.md decision
**Example:**
```python
# Source: warmup_protocols.json + CONTEXT.md
def warmup_until_stable(
    workload: Workload,
    min_iterations: int,     # From warmup_protocols.json
    max_iterations: int = 1000,
    target_cv: float = 0.10,  # 10% CV threshold
) -> bool:
    """Run warmup until metrics stabilize or max reached."""
    latencies = []

    for i in range(max_iterations):
        sample = workload.execute_one()
        latencies.append(sample.latency_ns)

        # Check stability after minimum iterations
        if i >= min_iterations and len(latencies) >= 30:
            cv = statistics.stdev(latencies[-30:]) / statistics.mean(latencies[-30:])
            if cv < target_cv:
                return True  # Stable

    return False  # Hit max without stabilizing
```

### Pattern 3: Fresh Cluster Per Run
**What:** Start clean cluster, load data, benchmark, stop cluster
**When to use:** Every benchmark run per CONTEXT.md decision
**Example:**
```python
# Source: CONTEXT.md decision + cluster.py
def run_isolated_benchmark(
    topology: int,
    workload: Workload,
    data_config: DatasetConfig,
) -> BenchmarkResult:
    config = ClusterConfig(node_count=topology)

    with ArcherDBCluster(config) as cluster:
        cluster.wait_for_ready()
        leader_port = cluster.wait_for_leader()

        # Load test data
        events = generate_events(data_config)
        load_data(cluster, events)

        # Run benchmark
        result = executor.run(workload)

    # Cluster automatically stops on context exit
    return result
```

### Pattern 4: Statistical Confidence with CV Stability
**What:** Run multiple times until CV <10% OR max 10 runs
**When to use:** Ensuring stable measurements per CONTEXT.md
**Example:**
```python
# Source: CONTEXT.md decision
def run_until_stable(
    benchmark_fn: Callable[[], BenchmarkResult],
    target_cv: float = 0.10,
    max_runs: int = 10,
) -> List[BenchmarkResult]:
    results = []

    for _ in range(max_runs):
        result = benchmark_fn()
        results.append(result)

        if len(results) >= 3:
            throughputs = [r.throughput for r in results]
            cv = statistics.stdev(throughputs) / statistics.mean(throughputs)
            if cv < target_cv:
                break

    return results
```

### Anti-Patterns to Avoid
- **Outlier removal:** Per CONTEXT.md, include ALL samples. P99 naturally captures tail latency; production cares about worst case.
- **Single-run benchmarks:** Always run multiple times for statistical validity (minimum 3, prefer until CV <10%).
- **Shared cluster state:** Use fresh cluster per run to avoid cache pollution and state accumulation affecting results.
- **Fixed warmup only:** Combine iteration count with stability check; JIT languages need time-based warmup.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Percentile calculation | Sorted array percentile | hdrhistogram | O(1) recording, O(1) percentile, 3-6ns per record |
| Confidence intervals | Manual t-distribution math | scipy.stats.t.interval() | Handles small samples, edge cases correctly |
| Statistical significance | Simple threshold comparison | scipy.stats.ttest_ind() | Proper p-value, accounts for variance |
| Terminal tables | Print formatting | rich.table.Table | Color, alignment, borders handled |
| Cluster lifecycle | Manual process management | test_infrastructure/harness/cluster.py | Already handles 1-6 nodes, ports, health checks |
| Data generation | Custom random points | test_infrastructure/generators/ | Already has uniform, city-concentrated, hotspot patterns |
| Warmup iteration counts | Hardcoded values | warmup_protocols.json | Language-specific, validated in Phase 11 |

**Key insight:** Phase 11 built comprehensive test infrastructure specifically to be reused. The benchmark framework should orchestrate existing components, not recreate them.

## Common Pitfalls

### Pitfall 1: Coordinated Omission
**What goes wrong:** Benchmarks that wait for responses before sending next request underreport latency when system is slow
**Why it happens:** If response takes 100ms but you only measure after waiting, you miss queueing delay
**How to avoid:** Record intended send time vs actual completion time; use HDR Histogram's coordinated omission correction
**Warning signs:** P99 suspiciously close to P95; latency doesn't increase under load

### Pitfall 2: Warmup Instability
**What goes wrong:** Measurements taken before JIT/caches stabilize give artificially high variance
**Why it happens:** JIT compilation, cache warming, connection pool initialization all affect early measurements
**How to avoid:** Use both iteration count (from warmup_protocols.json) AND CV stability check
**Warning signs:** CV >10% after warmup; first measurements 10x slower than later ones

### Pitfall 3: Sample Size Too Small
**What goes wrong:** Confidence intervals too wide to detect regressions; statistical tests lack power
**Why it happens:** Running "a few" iterations seems sufficient but isn't for tail percentiles
**How to avoid:** Enforce minimum 1000 samples per benchmark; error if fewer (per CONTEXT.md)
**Warning signs:** Wide confidence intervals (>20% of mean); P99 changes between runs

### Pitfall 4: Comparing Apples to Oranges
**What goes wrong:** Regression detected when workload or environment changed
**Why it happens:** Different data distribution, cluster size, or hardware
**How to avoid:** Store full benchmark configuration with results; compare only matching configs
**Warning signs:** Baseline from different topology; config mismatch in comparison

### Pitfall 5: Clock Resolution Issues
**What goes wrong:** Latency measurements dominated by clock precision rather than actual work
**Why it happens:** System clock has microsecond or millisecond resolution
**How to avoid:** Use time.perf_counter_ns() in Python (nanosecond resolution); batch small operations
**Warning signs:** All latencies cluster at clock resolution boundaries; P50==P95

### Pitfall 6: Memory/GC Pressure During Measurement
**What goes wrong:** GC pauses appear as latency spikes
**Why it happens:** Python/Java/Node allocate during measurement loop
**How to avoid:** Pre-allocate result arrays; minimize allocations in hot path; use native drivers (Zig)
**Warning signs:** Periodic latency spikes at ~1s intervals; bimodal distribution

## Code Examples

Verified patterns from official sources:

### HDR Histogram for Percentiles
```python
# Source: https://pypi.org/project/hdrhistogram/
from hdrhistogram import HdrHistogram

# Create histogram: 1us to 1h, 3 significant digits
histogram = HdrHistogram(1, 3600000000, 3)  # microseconds

# Record values (O(1) per record)
for latency_us in latencies:
    histogram.record_value(int(latency_us))

# Get percentiles (O(1))
p50 = histogram.get_value_at_percentile(50)
p95 = histogram.get_value_at_percentile(95)
p99 = histogram.get_value_at_percentile(99)
```

### Confidence Interval with scipy
```python
# Source: https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.t.html
from scipy import stats
import numpy as np

def confidence_interval(samples: list, confidence: float = 0.95) -> tuple:
    """Calculate confidence interval for mean."""
    n = len(samples)
    mean = np.mean(samples)
    se = stats.sem(samples)  # Standard error of mean

    # t.interval returns (low, high) for given confidence
    ci = stats.t.interval(confidence, df=n-1, loc=mean, scale=se)
    return ci
```

### Welch's t-test for Regression Detection
```python
# Source: https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.ttest_ind.html
from scipy import stats

def detect_regression(
    baseline_samples: list,
    current_samples: list,
    alpha: float = 0.05,
) -> tuple[bool, float]:
    """
    Detect statistically significant performance regression.
    Uses Welch's t-test (does not assume equal variances).

    Returns (is_regression, p_value)
    """
    # equal_var=False -> Welch's t-test
    stat, p_value = stats.ttest_ind(
        baseline_samples,
        current_samples,
        equal_var=False,
        alternative='greater',  # Current > Baseline = regression (for latency)
    )

    is_regression = p_value < alpha
    return is_regression, p_value
```

### Coefficient of Variation Check
```python
# Source: CONTEXT.md requirement
import statistics

def is_stable(samples: list, threshold_cv: float = 0.10) -> bool:
    """Check if samples are stable (CV < threshold)."""
    if len(samples) < 2:
        return False

    mean = statistics.mean(samples)
    if mean == 0:
        return True  # Avoid division by zero

    std = statistics.stdev(samples)
    cv = std / mean

    return cv < threshold_cv
```

### Multi-Format Reporter
```python
# Source: Rich library documentation
from rich.console import Console
from rich.table import Table
import json
import csv

class BenchmarkReporter:
    def __init__(self, results: dict):
        self.results = results

    def to_json(self, path: str):
        """JSON for CI automation."""
        with open(path, 'w') as f:
            json.dump(self.results, f, indent=2)

    def to_csv(self, path: str):
        """CSV for spreadsheet analysis."""
        with open(path, 'w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=self.results[0].keys())
            writer.writeheader()
            writer.writerows(self.results)

    def to_terminal(self):
        """Color-coded terminal tables."""
        console = Console()
        table = Table(title="Benchmark Results")

        table.add_column("Metric", style="cyan")
        table.add_column("Value", style="green")
        table.add_column("Target", style="yellow")
        table.add_column("Status", style="bold")

        for row in self.results:
            status = "[green]PASS[/green]" if row['passed'] else "[red]FAIL[/red]"
            table.add_row(row['metric'], row['value'], row['target'], status)

        console.print(table)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Average-based reporting | Percentile-based (P50/P95/P99) | 2015+ | Tail latency visibility |
| Fixed-bin histograms | HDR Histogram | 2014 | 3-6ns recording, high dynamic range |
| Eyeball regression detection | Statistical tests (t-test, Mann-Whitney) | 2018+ | Objective pass/fail criteria |
| Single-run benchmarks | Multiple runs with CV check | 2019+ | Statistical validity |
| Outlier removal | Include all samples | 2016+ | Production-realistic measurements |

**Deprecated/outdated:**
- **Mean-only reporting:** P99 is what production cares about; mean hides tail latency
- **Fixed threshold regression:** Use statistical tests, not "5% slower = fail"
- **Manual warmup tuning:** Use automated stability detection

## Performance Targets (from CONTEXT.md)

| Metric | Target | Verification |
|--------|--------|--------------|
| 3-node throughput | >=770K events/sec | BENCH-T-05 |
| 3-node throughput (stretch) | >=1M events/sec | BENCH-T-06 |
| Read latency P95 | <1ms | BENCH-L-05 |
| Read latency P99 | <10ms | BENCH-L-05 |
| Write latency P95 | <10ms | BENCH-L-06 |
| Write latency P99 | <50ms | BENCH-L-06 |

## Open Questions

Things that couldn't be fully resolved:

1. **Real-world dataset sources**
   - What we know: CONTEXT.md requires real-world datasets (actual cities, POIs)
   - What's unclear: Which specific datasets to use; city_coordinates.py has CITIES but unclear if POI data exists
   - Recommendation: Use city_coordinates.py cities; defer POI data to enhancement if needed

2. **Mixed workload ratios**
   - What we know: CONTEXT.md mentions "80% reads, 20% writes" as example
   - What's unclear: What other ratios to test; whether to make configurable
   - Recommendation: Start with 80/20 read/write; make ratio configurable for future experiments

3. **Time limits and operation counts**
   - What we know: CONTEXT.md says Claude's discretion for specific values
   - What's unclear: Optimal duration for statistical validity vs. CI time budget
   - Recommendation: Default 60s or 10K ops for quick; 300s or 100K ops for full suite

## Sources

### Primary (HIGH confidence)
- **geo_benchmark_load.zig:** Existing benchmark implementation with histogram, percentile calculation
- **cluster.py:** Phase 11 cluster management, 1-6 node support
- **warmup_protocols.json:** Per-SDK warmup iteration counts
- **CONTEXT.md:** User decisions on all benchmark behavior

### Secondary (MEDIUM confidence)
- [hdrhistogram PyPI](https://pypi.org/project/hdrhistogram/) - Python HDR Histogram implementation
- [scipy.stats documentation](https://docs.scipy.org/doc/scipy/reference/stats.html) - t-test, confidence intervals
- [Sitespeed.io Mann-Whitney](https://www.sitespeed.io/documentation/sitespeed.io/compare/) - Using Mann-Whitney for regression detection
- [Statistical Methods for Reliable Benchmarks](https://modulovalue.com/blog/statistical-methods-for-reliable-benchmarks/) - CV thresholds

### Tertiary (LOW confidence)
- Web search results on Welch's t-test vs Mann-Whitney - general guidance, not benchmark-specific

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Existing codebase components verified, libraries well-documented
- Architecture: HIGH - Patterns directly from CONTEXT.md decisions
- Pitfalls: MEDIUM - General benchmarking knowledge, some from existing benchmark.py patterns
- Statistical methods: HIGH - scipy documentation verified, well-established techniques

**Research date:** 2026-02-01
**Valid until:** 60 days (stable domain, established libraries)
