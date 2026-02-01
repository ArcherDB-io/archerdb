# Phase 17: Edge Cases & Advanced Benchmarking - Research

**Researched:** 2026-02-01
**Domain:** Geographic edge case testing, performance regression detection, historical benchmarking with visualization
**Confidence:** HIGH

## Summary

Phase 17 builds on the substantial foundation from Phase 14 (edge case fixtures) and Phase 15 (benchmark framework) to deliver comprehensive edge case validation and automated performance regression detection with historical tracking. The existing infrastructure provides excellent building blocks:

- **33 edge case fixtures already exist** in `tests/parity_tests/fixtures/edge_cases/` covering polar coordinates, antimeridian crossings, and equator/prime meridian cases
- **geo_workload.zig provides adversarial patterns** including pole queries, antimeridian-crossing queries, zero-radius queries, max-radius queries, boundary polygons, and concave polygons
- **Phase 15 benchmark framework exists** with orchestrator, executor, stats (scipy-based), HDR histogram, and regression detection

The work for Phase 17 focuses on three areas:
1. **Expanding edge case coverage** beyond the existing 33 fixtures to include scale validation (10K batch, 100K+ events), concave/self-intersecting polygons, degenerate cases, and TTL verification
2. **Enhancing regression detection** with statistical (2 std dev) + absolute (10%) thresholds comparing to best historical performance, with CI gate integration
3. **Adding historical tracking and visualization** using JSON files in `benchmarks/history/`, plotext for CLI charts, and Chart.js for HTML dashboards

**Primary recommendation:** Extend existing edge case fixtures and benchmark infrastructure rather than building from scratch. Use plotext (Python) for CLI visualization and Chart.js (JavaScript) for HTML dashboards. Implement dual-threshold regression detection (statistical + absolute) with git SHA and hardware metadata for reproducibility.

## Standard Stack

The established libraries/tools for this domain:

### Core (Existing - Leverage from Phase 14/15)
| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| geo_workload.zig | src/testing/ | Adversarial pattern generator | Already has pole, antimeridian, concave patterns |
| orchestrator.py | test_infrastructure/benchmarks/ | Benchmark coordination | Fresh cluster per run, warmup, multi-topology |
| regression.py | test_infrastructure/benchmarks/ | Regression detection | Load/save baselines, compare metrics |
| stats.py | test_infrastructure/benchmarks/ | Statistical analysis | scipy-based CI, t-test, CV |
| histogram.py | test_infrastructure/benchmarks/ | HDR Histogram wrapper | O(1) percentile calculation |
| edge case fixtures | tests/parity_tests/fixtures/edge_cases/ | 33 edge case test patterns | Polar, antimeridian, equator already defined |

### Core (New - Build)
| Component | Purpose | Why Standard |
|-----------|---------|--------------|
| plotext | CLI visualization charts | Most versatile terminal plotting, Rich integration |
| Chart.js | HTML dashboard charting | Lightweight, simple API, excellent for dashboards |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| numpy | 1.26+ | Statistical computations | Array operations for historical analysis |
| scipy.stats | 1.11+ | Statistical tests | Already used in stats.py |
| rich | 13+ | Terminal formatting | Already used in reporter.py |
| jinja2 | 3.1+ | HTML template generation | Dashboard HTML generation |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| plotext | asciichartpy | asciichartpy simpler but fewer chart types |
| Chart.js | Plotly.js | Plotly more powerful but larger bundle (~3MB vs ~60KB) |
| JSON history files | SQLite | SQLite more structured but JSON is git-friendly |

**Installation:**
```bash
pip install plotext jinja2
# Chart.js included via CDN in HTML templates (no install needed)
```

## Architecture Patterns

### Recommended Project Structure
```
test_infrastructure/
  benchmarks/
    orchestrator.py          # Existing - enhance for historical tracking
    regression.py            # Existing - add dual-threshold detection
    stats.py                 # Existing - add std dev threshold
    visualization/           # NEW
      __init__.py
      cli_charts.py          # plotext-based CLI visualization
      html_dashboard.py      # Chart.js dashboard generator
      templates/
        dashboard.html.j2    # Jinja2 template for HTML report

benchmarks/
  history/                   # NEW: Historical benchmark data
    YYYYMMDD-HHMMSS-{topology}-{benchmark_type}.json

tests/
  edge_case_tests/           # NEW: Comprehensive edge case tests
    conftest.py              # Shared fixtures
    test_geometric_boundaries.py     # Pole, antimeridian, equator
    test_scale_validation.py         # 10K batch, 100K+ events
    test_polygon_edge_cases.py       # Concave, self-intersecting, degenerate
    test_ttl_expiration.py           # TTL verification
    test_empty_results.py            # Empty query handling
    fixtures/
      concave_polygons.json
      degenerate_cases.json
      scale_test_configs.json
```

### Pattern 1: Dual-Threshold Regression Detection
**What:** Combine statistical (2 std dev) and absolute (10%) thresholds for regression detection
**When to use:** All regression checks per CONTEXT.md decision
**Example:**
```python
# Source: CONTEXT.md decision - both statistical + absolute thresholds
from scipy import stats
import numpy as np
from typing import Tuple, NamedTuple

class RegressionResult(NamedTuple):
    is_regression: bool
    trigger: str  # "statistical", "absolute", or "none"
    deviation_std: float
    deviation_pct: float
    p_value: float

def detect_regression_dual_threshold(
    current_samples: list[float],
    baseline_best: float,
    baseline_std: float,
    std_threshold: float = 2.0,  # 2 standard deviations
    pct_threshold: float = 10.0,  # 10% absolute threshold
    higher_is_better: bool = False,  # False for latency, True for throughput
) -> RegressionResult:
    """
    Detect regression using both statistical and absolute thresholds.

    Per CONTEXT.md: Use statistical (2 std dev) for normal variance,
    absolute percentage (10%) for major drops.

    Args:
        current_samples: Current benchmark samples
        baseline_best: Best historical performance value
        baseline_std: Standard deviation of baseline
        std_threshold: Number of std devs for statistical regression
        pct_threshold: Percentage change for absolute regression
        higher_is_better: True for throughput, False for latency

    Returns:
        RegressionResult with regression status and details
    """
    current_mean = np.mean(current_samples)

    # Calculate deviation from best
    if higher_is_better:
        # For throughput: lower than best is regression
        deviation_pct = ((baseline_best - current_mean) / baseline_best) * 100
        deviation_std = (baseline_best - current_mean) / baseline_std if baseline_std > 0 else 0
    else:
        # For latency: higher than best is regression
        deviation_pct = ((current_mean - baseline_best) / baseline_best) * 100
        deviation_std = (current_mean - baseline_best) / baseline_std if baseline_std > 0 else 0

    # Statistical test
    stat_regression = deviation_std > std_threshold

    # Absolute test
    abs_regression = deviation_pct > pct_threshold

    # Determine overall regression
    is_regression = stat_regression or abs_regression

    if stat_regression and abs_regression:
        trigger = "both"
    elif stat_regression:
        trigger = "statistical"
    elif abs_regression:
        trigger = "absolute"
    else:
        trigger = "none"

    # Calculate p-value for statistical significance
    t_stat = deviation_std  # Simplified: using z-score as t approximation
    p_value = 1 - stats.norm.cdf(abs(t_stat))

    return RegressionResult(
        is_regression=is_regression,
        trigger=trigger,
        deviation_std=deviation_std,
        deviation_pct=deviation_pct,
        p_value=p_value,
    )
```

### Pattern 2: Best Historical Performance Baseline
**What:** Compare to peak performance, not average, alerting on any degradation from best-ever
**When to use:** All benchmark comparisons per CONTEXT.md decision
**Example:**
```python
# Source: CONTEXT.md decision - compare to best historical
import json
from pathlib import Path
from dataclasses import dataclass
from typing import Optional

@dataclass
class HistoricalBaseline:
    """Best historical performance with context."""
    best_value: float
    best_std: float
    best_run_timestamp: str
    best_run_git_sha: str
    all_values: list[float]

def load_best_baseline(
    history_dir: Path,
    topology: int,
    benchmark_type: str,
    metric: str,
    higher_is_better: bool = False,
) -> Optional[HistoricalBaseline]:
    """
    Load best historical performance for a metric.

    Per CONTEXT.md: "Best historical performance - compare to peak,
    alert on any degradation from best-ever"

    Args:
        history_dir: Path to benchmarks/history/
        topology: Node count (1, 3, 5, 6)
        benchmark_type: "throughput", "latency_read", etc.
        metric: Specific metric like "throughput_events_per_sec" or "p99_ms"
        higher_is_better: True for throughput, False for latency

    Returns:
        HistoricalBaseline with best value and context
    """
    # Load all historical runs for this topology/benchmark
    pattern = f"*-{topology}node-{benchmark_type}.json"
    history_files = sorted(history_dir.glob(pattern))

    if not history_files:
        return None

    all_values = []
    best_value = None
    best_run = None

    for hist_file in history_files:
        with open(hist_file) as f:
            data = json.load(f)

        if metric not in data:
            continue

        value = data[metric]
        all_values.append(value)

        # Track best
        if best_value is None:
            best_value = value
            best_run = data
        elif higher_is_better and value > best_value:
            best_value = value
            best_run = data
        elif not higher_is_better and value < best_value:
            best_value = value
            best_run = data

    if best_value is None or best_run is None:
        return None

    import numpy as np
    return HistoricalBaseline(
        best_value=best_value,
        best_std=float(np.std(all_values)) if len(all_values) > 1 else 0.0,
        best_run_timestamp=best_run.get("timestamp", "unknown"),
        best_run_git_sha=best_run.get("git_sha", "unknown"),
        all_values=all_values,
    )
```

### Pattern 3: Historical Data with Full Context
**What:** Store complete metadata with each benchmark run for reproducibility
**When to use:** Every benchmark run per CONTEXT.md decision
**Example:**
```python
# Source: CONTEXT.md decision - full context (git SHA, branch, timestamp, hardware, config)
import json
import os
import platform
import subprocess
from datetime import datetime
from dataclasses import dataclass, asdict
from pathlib import Path

@dataclass
class BenchmarkMetadata:
    """Full context for benchmark reproducibility."""
    timestamp: str
    git_sha: str
    git_branch: str
    hostname: str
    cpu_info: str
    memory_gb: float
    config: dict

def capture_metadata(config: dict) -> BenchmarkMetadata:
    """Capture full environment context for benchmark."""
    # Git info
    try:
        git_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            text=True
        ).strip()
    except:
        git_sha = "unknown"

    try:
        git_branch = subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            text=True
        ).strip()
    except:
        git_branch = "unknown"

    # Hardware info
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal"):
                    memory_kb = int(line.split()[1])
                    memory_gb = memory_kb / 1024 / 1024
                    break
            else:
                memory_gb = 0.0
    except:
        memory_gb = 0.0

    return BenchmarkMetadata(
        timestamp=datetime.utcnow().isoformat() + "Z",
        git_sha=git_sha,
        git_branch=git_branch,
        hostname=platform.node(),
        cpu_info=platform.processor(),
        memory_gb=round(memory_gb, 1),
        config=config,
    )

def save_benchmark_result(
    history_dir: Path,
    topology: int,
    benchmark_type: str,
    results: dict,
    metadata: BenchmarkMetadata,
) -> Path:
    """Save benchmark result with full metadata."""
    history_dir.mkdir(parents=True, exist_ok=True)

    # Generate filename with timestamp
    timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    filename = f"{timestamp}-{topology}node-{benchmark_type}.json"
    filepath = history_dir / filename

    # Combine results and metadata
    full_data = {
        **results,
        **asdict(metadata),
    }

    with open(filepath, "w") as f:
        json.dump(full_data, f, indent=2)

    return filepath
```

### Pattern 4: CLI Visualization with plotext
**What:** Generate terminal charts for quick benchmark checks
**When to use:** CLI dashboard and quick checks per CONTEXT.md decision
**Example:**
```python
# Source: CONTEXT.md decision - CLI charts for quick checks
import plotext as plt
from pathlib import Path
import json
from typing import List

def plot_trend_cli(
    history_dir: Path,
    topology: int,
    metric: str,
    benchmark_type: str = "throughput",
    last_n: int = 50,
) -> None:
    """
    Plot metric trend in terminal using plotext.

    Per CONTEXT.md: "CLI charts for quick checks"
    """
    # Load historical data
    pattern = f"*-{topology}node-{benchmark_type}.json"
    history_files = sorted(history_dir.glob(pattern))[-last_n:]

    timestamps = []
    values = []

    for hist_file in history_files:
        with open(hist_file) as f:
            data = json.load(f)
        if metric in data:
            # Extract date from filename
            date_part = hist_file.stem.split("-")[0]
            timestamps.append(date_part)
            values.append(data[metric])

    if not values:
        print(f"No data found for {metric}")
        return

    # Plot
    plt.clear_figure()
    plt.plot(range(len(values)), values, marker="braille")
    plt.title(f"{metric} Trend ({topology}-node)")
    plt.xlabel("Run")
    plt.ylabel(metric)
    plt.show()

def plot_distribution_cli(
    samples: List[float],
    title: str,
    bins: int = 30,
) -> None:
    """Plot latency distribution as histogram in terminal."""
    plt.clear_figure()
    plt.hist(samples, bins=bins)
    plt.title(title)
    plt.xlabel("Latency (ms)")
    plt.ylabel("Count")
    plt.show()

def plot_percentile_bands_cli(
    history_dir: Path,
    topology: int,
    benchmark_type: str = "latency_read",
    last_n: int = 50,
) -> None:
    """Plot P50/P95/P99 bands over time in terminal."""
    pattern = f"*-{topology}node-{benchmark_type}.json"
    history_files = sorted(history_dir.glob(pattern))[-last_n:]

    p50s, p95s, p99s = [], [], []

    for hist_file in history_files:
        with open(hist_file) as f:
            data = json.load(f)
        if "p50_ms" in data:
            p50s.append(data["p50_ms"])
            p95s.append(data["p95_ms"])
            p99s.append(data["p99_ms"])

    if not p50s:
        print("No latency data found")
        return

    plt.clear_figure()
    x = list(range(len(p50s)))
    plt.plot(x, p50s, label="P50", marker="braille")
    plt.plot(x, p95s, label="P95", marker="braille")
    plt.plot(x, p99s, label="P99", marker="braille")
    plt.title(f"Latency Percentiles ({topology}-node)")
    plt.xlabel("Run")
    plt.ylabel("Latency (ms)")
    plt.show()
```

### Pattern 5: HTML Dashboard with Chart.js
**What:** Generate detailed HTML reports with interactive charts
**When to use:** Detailed analysis and sharing per CONTEXT.md decision
**Example:**
```python
# Source: CONTEXT.md decision - HTML reports for detailed analysis
from jinja2 import Template
from pathlib import Path
import json
from datetime import datetime

DASHBOARD_TEMPLATE = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>ArcherDB Benchmark Dashboard</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .chart-container { width: 80%; margin: 20px auto; }
        h1 { color: #333; }
        .summary { background: #f5f5f5; padding: 15px; border-radius: 5px; }
        .regression { color: #d9534f; }
        .improvement { color: #5cb85c; }
    </style>
</head>
<body>
    <h1>ArcherDB Benchmark Dashboard</h1>
    <p>Generated: {{ generated_at }}</p>

    <div class="summary">
        <h2>Summary</h2>
        <p>Total runs: {{ total_runs }}</p>
        <p>Latest regression status:
            <span class="{{ 'regression' if has_regression else 'improvement' }}">
                {{ 'REGRESSION DETECTED' if has_regression else 'OK' }}
            </span>
        </p>
    </div>

    <div class="chart-container">
        <h2>Throughput Trend</h2>
        <canvas id="throughputChart"></canvas>
    </div>

    <div class="chart-container">
        <h2>Latency Percentiles</h2>
        <canvas id="latencyChart"></canvas>
    </div>

    <script>
        // Throughput chart
        new Chart(document.getElementById('throughputChart'), {
            type: 'line',
            data: {
                labels: {{ throughput_labels | tojson }},
                datasets: [{
                    label: 'Throughput (events/sec)',
                    data: {{ throughput_values | tojson }},
                    borderColor: 'rgb(75, 192, 192)',
                    fill: false
                }]
            },
            options: {
                responsive: true,
                scales: {
                    y: { beginAtZero: false }
                }
            }
        });

        // Latency chart
        new Chart(document.getElementById('latencyChart'), {
            type: 'line',
            data: {
                labels: {{ latency_labels | tojson }},
                datasets: [
                    {
                        label: 'P50 (ms)',
                        data: {{ p50_values | tojson }},
                        borderColor: 'rgb(75, 192, 192)',
                        fill: false
                    },
                    {
                        label: 'P95 (ms)',
                        data: {{ p95_values | tojson }},
                        borderColor: 'rgb(255, 206, 86)',
                        fill: false
                    },
                    {
                        label: 'P99 (ms)',
                        data: {{ p99_values | tojson }},
                        borderColor: 'rgb(255, 99, 132)',
                        fill: false
                    }
                ]
            },
            options: {
                responsive: true
            }
        });
    </script>
</body>
</html>
'''

def generate_html_dashboard(
    history_dir: Path,
    output_path: Path,
    topology: int = 3,
) -> None:
    """
    Generate HTML dashboard with Chart.js visualizations.

    Per CONTEXT.md: "HTML reports for detailed analysis"
    """
    # Load throughput history
    tp_files = sorted(history_dir.glob(f"*-{topology}node-throughput.json"))
    throughput_labels = []
    throughput_values = []

    for f in tp_files[-50:]:
        with open(f) as fp:
            data = json.load(fp)
        date_part = f.stem.split("-")[0]
        throughput_labels.append(date_part)
        throughput_values.append(data.get("throughput_events_per_sec", 0))

    # Load latency history
    lat_files = sorted(history_dir.glob(f"*-{topology}node-latency_read.json"))
    latency_labels = []
    p50_values, p95_values, p99_values = [], [], []

    for f in lat_files[-50:]:
        with open(f) as fp:
            data = json.load(fp)
        date_part = f.stem.split("-")[0]
        latency_labels.append(date_part)
        p50_values.append(data.get("p50_ms", 0))
        p95_values.append(data.get("p95_ms", 0))
        p99_values.append(data.get("p99_ms", 0))

    # Check for regression
    has_regression = False  # Compute based on latest comparison

    # Render template
    template = Template(DASHBOARD_TEMPLATE)
    html = template.render(
        generated_at=datetime.utcnow().isoformat() + "Z",
        total_runs=len(tp_files),
        has_regression=has_regression,
        throughput_labels=throughput_labels,
        throughput_values=throughput_values,
        latency_labels=latency_labels,
        p50_values=p50_values,
        p95_values=p95_values,
        p99_values=p99_values,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        f.write(html)
```

### Anti-Patterns to Avoid
- **Single-run baseline comparisons:** Always use multiple samples for statistical validity; single runs have high variance.
- **Ignoring hardware context:** Different machines produce different results; always store hardware metadata.
- **Hardcoded thresholds without justification:** Use statistical tests, not arbitrary "10% slower = fail."
- **Removing outliers from edge case tests:** Edge cases ARE the outliers; include all samples.
- **Storing averages only:** Store full sample distributions for proper statistical comparison.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Edge case coordinate generation | Manual lat/lon values | geo_workload.zig EdgeCaseCoordinates | Already defines pole, antimeridian, equator constants |
| Adversarial query patterns | Custom query generators | geo_workload.zig adversarial queries | 6 adversarial patterns already implemented |
| Statistical regression tests | Manual threshold comparison | stats.py detect_regression() | Welch's t-test handles variance correctly |
| Percentile calculation | Sorted array percentile | histogram.py LatencyHistogram | HDR histogram with O(1) operations |
| Cluster lifecycle | Manual process management | orchestrator.py _isolated_cluster() | Already handles fresh cluster per run |
| Terminal charts | Print formatting | plotext | Professional terminal visualization |

**Key insight:** Phase 14 and 15 built the foundation. Phase 17 enhances and extends, not replaces.

## Common Pitfalls

### Pitfall 1: Testing Near-Boundaries Without Exact Boundaries
**What goes wrong:** Near-boundary tests (89.9999) pass but exact boundaries (90.0) fail
**Why it happens:** Different code paths for exact vs near values
**How to avoid:** Always test BOTH exact boundaries AND near-boundaries
**Warning signs:** Tests pass for 89.9999 but fail for 90.0

### Pitfall 2: Comparing Against Average Baseline Instead of Best
**What goes wrong:** Slow drift in performance goes undetected
**Why it happens:** Average includes degraded runs, masking regression
**How to avoid:** Per CONTEXT.md, compare to best historical performance
**Warning signs:** Regression detected but "within normal range"

### Pitfall 3: CI Flakiness from Statistical Tests
**What goes wrong:** Tests pass/fail non-deterministically
**Why it happens:** Statistical tests with insufficient samples or tight thresholds
**How to avoid:** Use dual thresholds (statistical 2 std dev + absolute 10%); require minimum sample counts
**Warning signs:** Same benchmark passes/fails on different runs

### Pitfall 4: Missing Degenerate Cases
**What goes wrong:** Zero-area polygons, single-point queries crash or hang
**Why it happens:** Edge cases not covered; focus on "normal" inputs
**How to avoid:** Explicitly test zero-radius, zero-area, minimum vertices (3)
**Warning signs:** Production errors with unusual inputs

### Pitfall 5: Scale Tests Running Out of Memory
**What goes wrong:** 100K+ event tests fail with OOM
**Why it happens:** Loading all events in memory at once
**How to avoid:** Stream events, batch processing, monitor memory usage
**Warning signs:** Tests pass at 10K but fail at 100K

### Pitfall 6: Historical Data File Proliferation
**What goes wrong:** benchmarks/history/ grows unbounded, slows git
**Why it happens:** Per CONTEXT.md, keep all history forever
**How to avoid:** Use git-lfs for history files, or exclude from main branch
**Warning signs:** .git directory grows to multiple GB

## Code Examples

Verified patterns from official sources:

### Comprehensive Edge Case Test Fixtures
```python
# Source: Existing fixtures + CONTEXT.md requirements
GEOMETRIC_EDGE_CASES = {
    # Exact boundaries (CONTEXT.md: +/-90, +/-180)
    "exact_boundaries": [
        {"lat": 90.0, "lon": 0.0, "name": "north_pole"},
        {"lat": -90.0, "lon": 0.0, "name": "south_pole"},
        {"lat": 0.0, "lon": 180.0, "name": "antimeridian_east"},
        {"lat": 0.0, "lon": -180.0, "name": "antimeridian_west"},
    ],
    # Near boundaries (CONTEXT.md: 89.9999, 179.9999)
    "near_boundaries": [
        {"lat": 89.9999, "lon": 0.0, "name": "near_north_pole"},
        {"lat": -89.9999, "lon": 0.0, "name": "near_south_pole"},
        {"lat": 0.0, "lon": 179.9999, "name": "near_antimeridian_east"},
        {"lat": 0.0, "lon": -179.9999, "name": "near_antimeridian_west"},
        # Additional precision levels per Claude's discretion
        {"lat": 89.99999, "lon": 0.0, "name": "very_near_north_pole"},
        {"lat": 89.999999, "lon": 0.0, "name": "ultra_near_north_pole"},
    ],
    # Degenerate cases (CONTEXT.md: zero-area, single-point)
    "degenerate": [
        {"type": "zero_radius_query", "lat": 37.0, "lon": -122.0, "radius_m": 0},
        {"type": "zero_area_polygon", "vertices": [(0, 0), (0, 0), (0, 0)]},
        {"type": "collinear_polygon", "vertices": [(0, 0), (1, 0), (2, 0)]},
        {"type": "single_point_result", "query_returns": 0},
    ],
}

# Concave polygon cases (CONTEXT.md: multiple concave shapes)
CONCAVE_POLYGON_CASES = [
    {
        "name": "l_shape",
        "vertices": [(0, 0), (2, 0), (2, 1), (1, 1), (1, 2), (0, 2)],
        "description": "L-shaped concave polygon"
    },
    {
        "name": "star",
        "vertices": [
            (0, 3), (1, 1), (3, 1), (1.5, -0.5),
            (2, -3), (0, -1), (-2, -3), (-1.5, -0.5),
            (-3, 1), (-1, 1)
        ],
        "description": "5-pointed star (highly concave)"
    },
    {
        "name": "arrow",
        "vertices": [(0, 4), (2, 2), (1, 2), (1, 0), (-1, 0), (-1, 2), (-2, 2)],
        "description": "Arrow-shaped concave polygon"
    },
]

# Self-intersecting polygon cases
SELF_INTERSECTING_CASES = [
    {
        "name": "bowtie",
        "vertices": [(0, 0), (2, 2), (2, 0), (0, 2)],
        "expected": "error_or_decompose",
        "description": "Figure-8 / bowtie shape"
    },
    {
        "name": "twisted_rectangle",
        "vertices": [(0, 0), (3, 0), (1, 2), (2, 2)],
        "expected": "error",
        "description": "Self-crossing edges"
    },
]
```

### Scale Validation Test Configuration
```python
# Source: CONTEXT.md - verify correctness AND performance at scale
SCALE_TEST_CONFIGS = {
    "large_batch": {
        # EDGE-04: 10K entities in single batch
        "batch_size": 10_000,
        "verify_correctness": True,  # All inserts succeed
        "verify_performance": True,   # Measure throughput/latency
        "expected_success_rate": 1.0,
    },
    "high_volume": {
        # EDGE-05: 100K+ events inserted
        "total_events": 100_000,
        "batch_size": 1_000,  # Insert in batches to avoid OOM
        "verify_correctness": True,  # Query returns correct results
        "verify_performance": True,  # Track degradation curve
    },
    "multi_topology_scale": {
        # BENCH-A-01: Scalability 1->3->5->6 nodes
        "topologies": [1, 3, 5, 6],
        "events_per_topology": 50_000,
        "measure_linear_scaling": True,
    },
}
```

### CI Gate Integration
```python
# Source: CONTEXT.md - fail CI on regression (strict quality gate)
import sys
from pathlib import Path

def ci_regression_check(
    results_path: Path,
    history_dir: Path,
    topology: int = 3,
) -> int:
    """
    CI gate for regression detection.

    Per CONTEXT.md: "Fail CI on regression - block merges when
    performance degrades (strict quality gate)"

    Returns:
        0 for success (no regression)
        1 for failure (regression detected)
    """
    import json

    with open(results_path) as f:
        current = json.load(f)

    # Load best baseline
    baseline = load_best_baseline(
        history_dir, topology, "throughput", "throughput_events_per_sec",
        higher_is_better=True
    )

    if baseline is None:
        print("No baseline found, skipping regression check")
        return 0

    # Check throughput regression
    current_tp = current.get("throughput_events_per_sec", 0)
    result = detect_regression_dual_threshold(
        current_samples=[current_tp],  # Single run for CI
        baseline_best=baseline.best_value,
        baseline_std=baseline.best_std,
        higher_is_better=True,
    )

    if result.is_regression:
        print(f"REGRESSION DETECTED: {result.trigger}")
        print(f"  Current: {current_tp:.0f} events/sec")
        print(f"  Best:    {baseline.best_value:.0f} events/sec")
        print(f"  Degradation: {result.deviation_pct:.1f}%")
        return 1

    print("No regression detected")
    return 0

if __name__ == "__main__":
    sys.exit(ci_regression_check(
        Path(sys.argv[1]),
        Path("benchmarks/history"),
    ))
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Fixed threshold (5% slower) | Statistical + absolute dual threshold | 2024+ | Handles normal variance vs real regression |
| Average baseline | Best historical performance | 2023+ | Prevents slow drift |
| Single topology tests | Multi-topology validation (1/3/5/6) | ArcherDB specific | Catches scaling issues |
| Manual performance checks | Automated CI gate | 2020+ | Prevents regression merges |
| Text-only reports | Visual dashboards (CLI + HTML) | 2022+ | Faster pattern recognition |

**Deprecated/outdated:**
- **Single-threshold regression:** Use dual (statistical + absolute) for robustness
- **Manual baseline selection:** Automate best-ever tracking
- **Eyeball trend analysis:** Use statistical tests for objectivity

## Recommendations for Claude's Discretion Items

### Near-Boundary Values
**Recommendation:** Use 89.9999 as primary near-boundary, add 89.99999 and 89.999999 for extended coverage
**Rationale:** Five decimal places (89.99999) is approximately 1.1 meters precision; six decimals is ~11cm

### Statistical Confidence Level
**Recommendation:** Use 95% confidence level (alpha=0.05)
**Rationale:** Industry standard; 99% is too strict for CI where false positives block merges

### CLI Chart Library
**Recommendation:** Use plotext
**Rationale:** Most feature-complete terminal plotting; native Rich integration; supports line, bar, histogram

### HTML Charting Library
**Recommendation:** Use Chart.js
**Rationale:** Lightweight (~60KB), simple API, excellent for dashboards; Plotly overkill for this use case

### Additional Degenerate Test Cases
**Recommendation:** Add: collinear points (not a polygon), duplicate vertices, very thin polygons (area ~0)
**Rationale:** These are common data quality issues in production

## Open Questions

Things that couldn't be fully resolved:

1. **Git LFS for History Files**
   - What we know: CONTEXT.md says keep all history forever
   - What's unclear: Whether to use git-lfs or .gitignore for benchmarks/history/
   - Recommendation: Start with regular git tracking; migrate to LFS if repo grows >500MB

2. **Concurrent Benchmark Runs**
   - What we know: CI may have multiple PRs running benchmarks simultaneously
   - What's unclear: How to prevent cross-run interference
   - Recommendation: Use unique hostnames/timestamps in filenames; consider file locking

3. **Baseline Reset After Major Changes**
   - What we know: Best historical performance might be invalidated by architecture changes
   - What's unclear: When/how to reset baselines
   - Recommendation: Add `--reset-baseline` flag to benchmark CLI; document in runbook

## Sources

### Primary (HIGH confidence)
- **geo_workload.zig:** Existing adversarial patterns including EdgeCaseCoordinates constants
- **orchestrator.py:** Phase 15 benchmark orchestration with fresh cluster per run
- **regression.py:** Phase 15 regression detection with baseline comparison
- **stats.py:** scipy-based statistical tests (t-test, CI, CV)
- **Edge case fixtures:** 33 existing test cases in tests/parity_tests/fixtures/edge_cases/

### Secondary (MEDIUM confidence)
- [plotext GitHub](https://github.com/piccolomo/plotext) - Terminal plotting documentation
- [Chart.js Documentation](https://www.chartjs.org/docs/) - HTML charting API
- [Hunter: Change Point Detection](https://research.spec.org/icpe_proceedings/2023/proceedings/p199.pdf) - Regression detection best practices
- [Fighting Regressions with Benchmarks in CI](https://medium.com/androiddevelopers/fighting-regressions-with-benchmarks-in-ci-6ea9a14b5c71) - CI integration patterns

### Tertiary (LOW confidence)
- Web search results on statistical benchmark comparison methods

## Metadata

**Confidence breakdown:**
- Edge case patterns: HIGH - Existing geo_workload.zig and fixtures verified
- Benchmark infrastructure: HIGH - Phase 15 code reviewed
- Regression detection: HIGH - scipy.stats well-documented
- Visualization libraries: MEDIUM - Based on web search and documentation review
- CI gate patterns: MEDIUM - General best practices, project-specific adaptation needed

**Research date:** 2026-02-01
**Valid until:** 2026-03-01 (30 days - stable domain, established patterns)
