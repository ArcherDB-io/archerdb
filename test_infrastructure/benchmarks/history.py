# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Historical result storage and retrieval for benchmarks.

Provides persistent storage for benchmark results and baseline management
for regression detection over time.
"""

import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional


@dataclass
class ComparisonResult:
    """Result of comparing current value to baseline.

    Attributes:
        metric: Name of the metric being compared.
        current_value: Current measured value.
        baseline_value: Baseline value for comparison.
        delta_pct: Percentage change from baseline.
        is_regression: True if performance degraded beyond threshold.
        is_improvement: True if performance improved beyond threshold.
    """

    metric: str = ""
    current_value: float = 0.0
    baseline_value: float = 0.0
    delta_pct: float = 0.0
    is_regression: bool = False
    is_improvement: bool = False


def get_history_dir() -> Path:
    """Get the history directory path.

    Returns:
        Path to reports/history/.
    """
    # Try relative to this file
    this_dir = Path(__file__).parent
    project_root = this_dir.parent.parent

    history_dir = project_root / "reports" / "history"
    history_dir.mkdir(parents=True, exist_ok=True)
    return history_dir


def get_baselines_dir() -> Path:
    """Get the baselines directory path.

    Returns:
        Path to reports/baselines/.
    """
    this_dir = Path(__file__).parent
    project_root = this_dir.parent.parent

    baselines_dir = project_root / "reports" / "baselines"
    baselines_dir.mkdir(parents=True, exist_ok=True)
    return baselines_dir


def save_result(result: Dict[str, Any], benchmark_type: str) -> Path:
    """Save benchmark result with timestamp.

    Args:
        result: Benchmark result dict to save.
        benchmark_type: Type of benchmark (e.g., 'throughput', 'scalability').

    Returns:
        Path to saved file.
    """
    history_dir = get_history_dir()

    # Generate timestamp filename
    timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    filename = f"{benchmark_type}-{timestamp}.json"
    filepath = history_dir / filename

    # Add save timestamp to result
    result_with_meta = dict(result)
    result_with_meta["saved_at"] = datetime.utcnow().isoformat() + "Z"
    result_with_meta["benchmark_type"] = benchmark_type

    with open(filepath, "w") as f:
        json.dump(result_with_meta, f, indent=2)

    return filepath


def load_results(
    benchmark_type: str,
    limit: int = 50,
) -> List[Dict[str, Any]]:
    """Load recent benchmark results of specified type.

    Args:
        benchmark_type: Type of benchmark to load.
        limit: Maximum number of results to return.

    Returns:
        List of result dicts, most recent first.
    """
    history_dir = get_history_dir()

    # Find matching files
    pattern = f"{benchmark_type}-*.json"
    files = sorted(history_dir.glob(pattern), reverse=True)

    results = []
    for filepath in files[:limit]:
        try:
            with open(filepath) as f:
                result = json.load(f)
                results.append(result)
        except (json.JSONDecodeError, OSError):
            continue

    return results


def save_baseline(
    result: Dict[str, Any],
    topology: int,
    benchmark_type: str,
) -> Path:
    """Save result as baseline for topology.

    Args:
        result: Benchmark result to save as baseline.
        topology: Number of nodes in cluster.
        benchmark_type: Type of benchmark.

    Returns:
        Path to saved baseline file.
    """
    baselines_dir = get_baselines_dir()

    filename = f"baseline-{topology}node-{benchmark_type}.json"
    filepath = baselines_dir / filename

    # Add baseline metadata
    baseline = dict(result)
    baseline["saved_as_baseline"] = datetime.utcnow().isoformat() + "Z"
    baseline["topology"] = topology
    baseline["benchmark_type"] = benchmark_type

    with open(filepath, "w") as f:
        json.dump(baseline, f, indent=2)

    return filepath


def load_baseline(
    topology: int,
    benchmark_type: str,
) -> Optional[Dict[str, Any]]:
    """Load baseline for topology and benchmark type.

    Args:
        topology: Number of nodes in cluster.
        benchmark_type: Type of benchmark.

    Returns:
        Baseline dict if exists, None otherwise.
    """
    baselines_dir = get_baselines_dir()

    filename = f"baseline-{topology}node-{benchmark_type}.json"
    filepath = baselines_dir / filename

    if not filepath.exists():
        return None

    try:
        with open(filepath) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def compare_to_baseline(
    current: Dict[str, Any],
    baseline: Dict[str, Any],
    threshold_pct: float = 10.0,
) -> Dict[str, ComparisonResult]:
    """Compare current results to baseline.

    Args:
        current: Current benchmark results.
        baseline: Baseline benchmark results.
        threshold_pct: Percentage threshold for regression/improvement.

    Returns:
        Dict mapping metric name to ComparisonResult.
    """
    comparisons: Dict[str, ComparisonResult] = {}

    # Metrics where higher is better (throughput)
    higher_better_metrics = {"throughput_events_per_sec"}

    # Metrics where lower is better (latency)
    lower_better_metrics = {
        "p50_ms", "p95_ms", "p99_ms",
        "mean_ms",
        "read_p50_ms", "read_p95_ms", "read_p99_ms",
        "write_p50_ms", "write_p95_ms", "write_p99_ms",
    }

    all_metrics = higher_better_metrics | lower_better_metrics

    for metric in all_metrics:
        if metric not in current or metric not in baseline:
            continue

        current_val = current[metric]
        baseline_val = baseline[metric]

        if baseline_val == 0:
            continue

        delta_pct = ((current_val - baseline_val) / baseline_val) * 100

        result = ComparisonResult(
            metric=metric,
            current_value=current_val,
            baseline_value=baseline_val,
            delta_pct=delta_pct,
        )

        if metric in higher_better_metrics:
            # Throughput: lower is regression
            result.is_regression = delta_pct < -threshold_pct
            result.is_improvement = delta_pct > threshold_pct
        else:
            # Latency: higher is regression
            result.is_regression = delta_pct > threshold_pct
            result.is_improvement = delta_pct < -threshold_pct

        comparisons[metric] = result

    return comparisons


def detect_regression(
    current: Dict[str, Any],
    baseline: Dict[str, Any],
    threshold_pct: float = 10.0,
) -> bool:
    """Check if current results show regression from baseline.

    Args:
        current: Current benchmark results.
        baseline: Baseline benchmark results.
        threshold_pct: Percentage threshold for regression detection.

    Returns:
        True if any metric shows regression.
    """
    comparisons = compare_to_baseline(current, baseline, threshold_pct)

    for comparison in comparisons.values():
        if comparison.is_regression:
            return True

    return False


def list_baselines() -> List[Dict[str, Any]]:
    """List all available baselines.

    Returns:
        List of dicts with topology, benchmark_type, and saved_at for each baseline.
    """
    baselines_dir = get_baselines_dir()
    baselines = []

    for filepath in baselines_dir.glob("baseline-*.json"):
        try:
            with open(filepath) as f:
                data = json.load(f)
                baselines.append({
                    "topology": data.get("topology"),
                    "benchmark_type": data.get("benchmark_type"),
                    "saved_at": data.get("saved_as_baseline"),
                    "filepath": str(filepath),
                })
        except (json.JSONDecodeError, OSError):
            continue

    return baselines


def get_trend_data(
    benchmark_type: str,
    metric: str,
    limit: int = 20,
) -> List[Dict[str, Any]]:
    """Get trend data for a metric over time.

    Args:
        benchmark_type: Type of benchmark.
        metric: Metric name to extract.
        limit: Maximum data points.

    Returns:
        List of {timestamp, value} dicts for plotting.
    """
    results = load_results(benchmark_type, limit)
    trend = []

    for result in results:
        if metric in result:
            trend.append({
                "timestamp": result.get("saved_at", result.get("timestamp", "")),
                "value": result[metric],
            })

    # Return in chronological order
    return list(reversed(trend))
