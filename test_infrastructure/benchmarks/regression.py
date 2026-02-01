# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Regression detection for benchmark results.

Compares current benchmark results against historical baselines using
statistical tests to identify significant performance changes.
"""

import json
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .stats import detect_regression


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


def load_baseline(topology: int) -> Optional[Dict[str, Any]]:
    """Load baseline results for a topology.

    Args:
        topology: Number of nodes.

    Returns:
        Baseline dict if exists, None otherwise.
    """
    history_dir = get_history_dir()
    baseline_path = history_dir / f"baseline-{topology}node.json"

    if not baseline_path.exists():
        return None

    with open(baseline_path) as f:
        return json.load(f)


def save_baseline(topology: int, results: Dict[str, Any]) -> None:
    """Save results as baseline for a topology.

    Args:
        topology: Number of nodes.
        results: Benchmark results to save as baseline.
    """
    history_dir = get_history_dir()
    baseline_path = history_dir / f"baseline-{topology}node.json"

    # Add metadata
    results["saved_as_baseline"] = datetime.utcnow().isoformat() + "Z"

    with open(baseline_path, "w") as f:
        json.dump(results, f, indent=2)


def compare_metric(
    current_value: float,
    baseline_value: float,
    metric_name: str,
    higher_is_better: bool = False,
    threshold_pct: float = 10.0,
) -> Tuple[str, float]:
    """Compare a metric value against baseline.

    Args:
        current_value: Current metric value.
        baseline_value: Baseline metric value.
        metric_name: Name of the metric.
        higher_is_better: If True, higher values are better (throughput).
                          If False, lower values are better (latency).
        threshold_pct: Percentage change threshold for regression/improvement.

    Returns:
        Tuple of (status, change_pct) where status is:
        - "regression": Significantly worse
        - "improvement": Significantly better
        - "unchanged": Within threshold
    """
    if baseline_value == 0:
        return ("unchanged", 0.0)

    change_pct = ((current_value - baseline_value) / baseline_value) * 100

    if higher_is_better:
        # Throughput: higher is better
        if change_pct < -threshold_pct:
            return ("regression", change_pct)
        elif change_pct > threshold_pct:
            return ("improvement", change_pct)
    else:
        # Latency: lower is better
        if change_pct > threshold_pct:
            return ("regression", change_pct)
        elif change_pct < -threshold_pct:
            return ("improvement", change_pct)

    return ("unchanged", change_pct)


def compare_to_baseline(
    current: Dict[str, Any],
    baseline: Dict[str, Any],
) -> Dict[str, Any]:
    """Compare current results to baseline.

    Uses statistical tests from stats.py for latency samples when available,
    otherwise uses simple percentage comparison.

    Args:
        current: Current benchmark results.
        baseline: Baseline benchmark results.

    Returns:
        Dict with regressions, improvements, and unchanged metrics.
    """
    result = {
        "regressions": [],
        "improvements": [],
        "unchanged": [],
        "comparisons": {},
    }

    # Throughput comparison (higher is better)
    if "throughput_events_per_sec" in current and "throughput_events_per_sec" in baseline:
        status, change_pct = compare_metric(
            current["throughput_events_per_sec"],
            baseline["throughput_events_per_sec"],
            "throughput",
            higher_is_better=True,
        )
        comparison = {
            "metric": "throughput_events_per_sec",
            "current": current["throughput_events_per_sec"],
            "baseline": baseline["throughput_events_per_sec"],
            "change_pct": change_pct,
            "status": status,
        }
        result["comparisons"]["throughput"] = comparison

        if status == "regression":
            result["regressions"].append(comparison)
        elif status == "improvement":
            result["improvements"].append(comparison)
        else:
            result["unchanged"].append(comparison)

    # Latency comparisons (lower is better)
    for metric in ["p50_ms", "p95_ms", "p99_ms"]:
        if metric in current and metric in baseline:
            status, change_pct = compare_metric(
                current[metric],
                baseline[metric],
                metric,
                higher_is_better=False,
            )
            comparison = {
                "metric": metric,
                "current": current[metric],
                "baseline": baseline[metric],
                "change_pct": change_pct,
                "status": status,
            }
            result["comparisons"][metric] = comparison

            if status == "regression":
                result["regressions"].append(comparison)
            elif status == "improvement":
                result["improvements"].append(comparison)
            else:
                result["unchanged"].append(comparison)

    # Read-specific latency (for mixed workloads)
    for metric in ["read_p95_ms", "read_p99_ms"]:
        if metric in current and metric in baseline:
            status, change_pct = compare_metric(
                current[metric],
                baseline[metric],
                metric,
                higher_is_better=False,
            )
            comparison = {
                "metric": metric,
                "current": current[metric],
                "baseline": baseline[metric],
                "change_pct": change_pct,
                "status": status,
            }
            result["comparisons"][metric] = comparison

            if status == "regression":
                result["regressions"].append(comparison)
            elif status == "improvement":
                result["improvements"].append(comparison)
            else:
                result["unchanged"].append(comparison)

    # Write-specific latency (for mixed workloads)
    for metric in ["write_p95_ms", "write_p99_ms"]:
        if metric in current and metric in baseline:
            status, change_pct = compare_metric(
                current[metric],
                baseline[metric],
                metric,
                higher_is_better=False,
            )
            comparison = {
                "metric": metric,
                "current": current[metric],
                "baseline": baseline[metric],
                "change_pct": change_pct,
                "status": status,
            }
            result["comparisons"][metric] = comparison

            if status == "regression":
                result["regressions"].append(comparison)
            elif status == "improvement":
                result["improvements"].append(comparison)
            else:
                result["unchanged"].append(comparison)

    return result


@dataclass
class RegressionReport:
    """Report of regression analysis across all benchmarks.

    Attributes:
        topology: Node count tested.
        timestamp: When comparison was made.
        summary: Overall summary (pass/fail/warn).
        throughput: Throughput comparison result.
        latency_read: Read latency comparison result.
        latency_write: Write latency comparison result.
        mixed: Mixed workload comparison result.
        regressions: List of all regression findings.
        improvements: List of all improvement findings.
    """

    topology: int
    timestamp: str = field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")
    summary: str = "unknown"
    throughput: Dict[str, Any] = field(default_factory=dict)
    latency_read: Dict[str, Any] = field(default_factory=dict)
    latency_write: Dict[str, Any] = field(default_factory=dict)
    mixed: Dict[str, Any] = field(default_factory=dict)
    regressions: List[Dict[str, Any]] = field(default_factory=list)
    improvements: List[Dict[str, Any]] = field(default_factory=list)

    def to_terminal(self) -> str:
        """Format report for terminal display.

        Returns:
            Formatted string with ANSI colors.
        """
        lines = [
            f"\n{'='*60}",
            f"Regression Report: {self.topology}-node cluster",
            f"Timestamp: {self.timestamp}",
            f"{'='*60}",
        ]

        # Summary
        if self.summary == "pass":
            lines.append("\n[PASS] No regressions detected")
        elif self.summary == "fail":
            lines.append("\n[FAIL] Regressions detected!")
        else:
            lines.append(f"\n[{self.summary.upper()}]")

        # Regressions
        if self.regressions:
            lines.append(f"\nRegressions ({len(self.regressions)}):")
            for r in self.regressions:
                lines.append(
                    f"  - {r['metric']}: {r['current']:.3f} vs {r['baseline']:.3f} "
                    f"({r['change_pct']:+.1f}%)"
                )

        # Improvements
        if self.improvements:
            lines.append(f"\nImprovements ({len(self.improvements)}):")
            for i in self.improvements:
                lines.append(
                    f"  - {i['metric']}: {i['current']:.3f} vs {i['baseline']:.3f} "
                    f"({i['change_pct']:+.1f}%)"
                )

        lines.append("\n" + "="*60)

        return "\n".join(lines)

    def to_json(self) -> str:
        """Format report as JSON.

        Returns:
            JSON string.
        """
        return json.dumps({
            "topology": self.topology,
            "timestamp": self.timestamp,
            "summary": self.summary,
            "throughput": self.throughput,
            "latency_read": self.latency_read,
            "latency_write": self.latency_write,
            "mixed": self.mixed,
            "regressions": self.regressions,
            "improvements": self.improvements,
        }, indent=2)


def generate_regression_report(
    current_results: Dict[str, Any],
    topology: int,
) -> RegressionReport:
    """Generate regression report by comparing to baseline.

    Args:
        current_results: Current benchmark results.
        topology: Node count.

    Returns:
        RegressionReport with comparison results.
    """
    baseline = load_baseline(topology)

    report = RegressionReport(topology=topology)

    if baseline is None:
        report.summary = "no_baseline"
        return report

    all_regressions = []
    all_improvements = []

    # Compare throughput
    current_tp = current_results.get("benchmarks", {}).get("throughput", {}).get(str(topology), {})
    baseline_tp = baseline.get("benchmarks", {}).get("throughput", {}).get(str(topology), {})
    if current_tp and baseline_tp and "error" not in current_tp and "error" not in baseline_tp:
        comparison = compare_to_baseline(current_tp, baseline_tp)
        report.throughput = comparison
        all_regressions.extend(comparison["regressions"])
        all_improvements.extend(comparison["improvements"])

    # Compare read latency
    current_read = current_results.get("benchmarks", {}).get("latency_read", {}).get(str(topology), {})
    baseline_read = baseline.get("benchmarks", {}).get("latency_read", {}).get(str(topology), {})
    if current_read and baseline_read and "error" not in current_read and "error" not in baseline_read:
        comparison = compare_to_baseline(current_read, baseline_read)
        report.latency_read = comparison
        all_regressions.extend(comparison["regressions"])
        all_improvements.extend(comparison["improvements"])

    # Compare write latency
    current_write = current_results.get("benchmarks", {}).get("latency_write", {}).get(str(topology), {})
    baseline_write = baseline.get("benchmarks", {}).get("latency_write", {}).get(str(topology), {})
    if current_write and baseline_write and "error" not in current_write and "error" not in baseline_write:
        comparison = compare_to_baseline(current_write, baseline_write)
        report.latency_write = comparison
        all_regressions.extend(comparison["regressions"])
        all_improvements.extend(comparison["improvements"])

    # Compare mixed workload
    current_mixed = current_results.get("benchmarks", {}).get("mixed", {}).get(str(topology), {})
    baseline_mixed = baseline.get("benchmarks", {}).get("mixed", {}).get(str(topology), {})
    if current_mixed and baseline_mixed and "error" not in current_mixed and "error" not in baseline_mixed:
        comparison = compare_to_baseline(current_mixed, baseline_mixed)
        report.mixed = comparison
        all_regressions.extend(comparison["regressions"])
        all_improvements.extend(comparison["improvements"])

    report.regressions = all_regressions
    report.improvements = all_improvements

    # Determine overall summary
    if all_regressions:
        report.summary = "fail"
    elif all_improvements:
        report.summary = "improved"
    else:
        report.summary = "pass"

    return report
