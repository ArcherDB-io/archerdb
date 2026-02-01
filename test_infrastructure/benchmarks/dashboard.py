# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Performance dashboard for benchmark visualization.

Generates ASCII trend charts and Markdown reports for tracking
benchmark performance over time.
"""

from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from .history import (
    ComparisonResult,
    get_trend_data,
    list_baselines,
    load_baseline,
    load_results,
)


def generate_dashboard(
    output_path: str = "reports/dashboard.md",
) -> str:
    """Generate full performance dashboard.

    Args:
        output_path: Path for Markdown output file.

    Returns:
        Dashboard content as string.
    """
    lines = [
        "# Performance Dashboard",
        "",
        f"Generated: {datetime.utcnow().isoformat()}Z",
        "",
    ]

    # Summary table of recent runs
    lines.extend([
        "## Recent Benchmark Runs",
        "",
    ])
    lines.append(generate_summary_table(load_results("throughput", limit=10)))

    # Throughput trend
    lines.extend([
        "",
        "## Throughput Trend",
        "",
    ])
    throughput_data = get_trend_data("throughput", "throughput_events_per_sec", limit=20)
    lines.append(plot_throughput_trend(throughput_data))

    # Latency trend
    lines.extend([
        "",
        "## P95 Latency Trend",
        "",
    ])
    latency_data = get_trend_data("latency_read", "p95_ms", limit=20)
    lines.append(plot_latency_trend(latency_data))

    # Baselines
    lines.extend([
        "",
        "## Baselines",
        "",
    ])
    baselines = list_baselines()
    if baselines:
        lines.append("| Topology | Type | Saved At |")
        lines.append("|----------|------|----------|")
        for b in baselines:
            lines.append(f"| {b['topology']}-node | {b['benchmark_type']} | {b['saved_at']} |")
    else:
        lines.append("No baselines set. Run benchmarks with `--save-baseline` to create.")

    # Performance targets
    lines.extend([
        "",
        "## Performance Targets",
        "",
        "| Metric | Target | Status |",
        "|--------|--------|--------|",
        "| 3-node throughput (baseline) | 770,000 events/sec | - |",
        "| 3-node throughput (stretch) | 1,000,000 events/sec | - |",
        "| Read latency P95 | <1 ms | - |",
        "| Read latency P99 | <10 ms | - |",
        "| Write latency P95 | <10 ms | - |",
        "| Write latency P99 | <50 ms | - |",
    ])

    content = "\n".join(lines)

    # Write to file
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        f.write(content)

    return content


def plot_throughput_trend(data: List[Dict[str, Any]]) -> str:
    """Generate ASCII chart of throughput over time.

    Args:
        data: List of {timestamp, value} dicts.

    Returns:
        ASCII chart string.
    """
    if not data:
        return "```\nNo throughput data available.\n```"

    return _generate_ascii_chart(
        data=data,
        title="Throughput (events/sec)",
        y_format=lambda v: f"{v/1000:.0f}K" if v >= 1000 else f"{v:.0f}",
        height=10,
    )


def plot_latency_trend(data: List[Dict[str, Any]]) -> str:
    """Generate ASCII chart of P95 latency over time.

    Args:
        data: List of {timestamp, value} dicts.

    Returns:
        ASCII chart string.
    """
    if not data:
        return "```\nNo latency data available.\n```"

    return _generate_ascii_chart(
        data=data,
        title="P95 Latency (ms)",
        y_format=lambda v: f"{v:.2f}",
        height=10,
    )


def _generate_ascii_chart(
    data: List[Dict[str, Any]],
    title: str,
    y_format: callable,
    height: int = 10,
    width: int = 60,
) -> str:
    """Generate ASCII chart with data points.

    Args:
        data: List of {timestamp, value} dicts.
        title: Chart title.
        y_format: Function to format Y-axis values.
        height: Chart height in rows.
        width: Chart width in columns.

    Returns:
        ASCII chart as string.
    """
    if not data:
        return f"```\n{title}\nNo data available.\n```"

    values = [d["value"] for d in data]
    min_val = min(values)
    max_val = max(values)

    # Handle case where all values are the same
    if max_val == min_val:
        max_val = min_val + 1

    # Build chart
    lines = ["```", title, ""]

    # Y-axis labels
    y_range = max_val - min_val
    y_step = y_range / (height - 1) if height > 1 else y_range

    # Create chart grid
    chart_width = min(width, len(data))
    x_step = max(1, len(data) // chart_width)
    sampled_values = values[::x_step][:chart_width]

    for row in range(height):
        y_val = max_val - (row * y_step)
        y_label = y_format(y_val).rjust(8)

        row_chars = []
        for val in sampled_values:
            # Determine if point should be at this row
            if y_step > 0:
                point_row = int((max_val - val) / y_step)
            else:
                point_row = 0
            point_row = max(0, min(height - 1, point_row))

            if point_row == row:
                row_chars.append("*")
            else:
                row_chars.append(" ")

        lines.append(f"{y_label} |{''.join(row_chars)}")

    # X-axis
    lines.append(" " * 9 + "+" + "-" * len(sampled_values))

    # X-axis label (just show first and last date)
    if data:
        first_ts = data[0].get("timestamp", "")[:10]
        last_ts = data[-1].get("timestamp", "")[:10]
        x_label = f"         {first_ts}" + " " * max(1, len(sampled_values) - 20) + last_ts
        lines.append(x_label)

    lines.append("```")

    return "\n".join(lines)


def format_regression_status(comparison: ComparisonResult) -> str:
    """Format comparison result with status indicator.

    Args:
        comparison: ComparisonResult to format.

    Returns:
        Formatted string with status.
    """
    if comparison.is_regression:
        status = "[REGRESSION]"
    elif comparison.is_improvement:
        status = "[IMPROVED]"
    else:
        status = "[OK]"

    return (
        f"{status} {comparison.metric}: "
        f"{comparison.current_value:.3f} vs {comparison.baseline_value:.3f} "
        f"({comparison.delta_pct:+.1f}%)"
    )


def generate_summary_table(results: List[Dict[str, Any]]) -> str:
    """Generate Markdown table summarizing recent runs.

    Args:
        results: List of benchmark result dicts.

    Returns:
        Markdown table string.
    """
    if not results:
        return "No benchmark results available."

    lines = [
        "| Date | Type | Topology | Throughput | P95 (ms) |",
        "|------|------|----------|------------|----------|",
    ]

    for result in results[:10]:  # Limit to 10 rows
        date = result.get("timestamp", result.get("saved_at", ""))[:10]
        btype = result.get("benchmark_type", "-")
        topology = result.get("topology", "-")
        throughput = result.get("throughput_events_per_sec", 0)
        p95 = result.get("p95_ms", 0)

        tp_str = f"{throughput:,.0f}" if throughput else "-"
        p95_str = f"{p95:.2f}" if p95 else "-"

        lines.append(f"| {date} | {btype} | {topology} | {tp_str} | {p95_str} |")

    return "\n".join(lines)


def generate_comparison_report(
    current: Dict[str, Any],
    baseline: Dict[str, Any],
) -> str:
    """Generate report comparing current results to baseline.

    Args:
        current: Current benchmark results.
        baseline: Baseline benchmark results.

    Returns:
        Markdown comparison report.
    """
    from .history import compare_to_baseline

    comparisons = compare_to_baseline(current, baseline)

    lines = [
        "## Comparison to Baseline",
        "",
        "| Metric | Current | Baseline | Change | Status |",
        "|--------|---------|----------|--------|--------|",
    ]

    for metric, comp in sorted(comparisons.items()):
        if comp.is_regression:
            status = "REGRESSION"
        elif comp.is_improvement:
            status = "IMPROVED"
        else:
            status = "OK"

        lines.append(
            f"| {metric} | {comp.current_value:.3f} | "
            f"{comp.baseline_value:.3f} | {comp.delta_pct:+.1f}% | {status} |"
        )

    # Summary
    regressions = sum(1 for c in comparisons.values() if c.is_regression)
    improvements = sum(1 for c in comparisons.values() if c.is_improvement)

    lines.extend([
        "",
        f"**Summary:** {regressions} regressions, {improvements} improvements, "
        f"{len(comparisons) - regressions - improvements} unchanged",
    ])

    return "\n".join(lines)
