# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Multi-format benchmark result reporter.

Outputs benchmark results in JSON, CSV, Markdown, and terminal formats.
Includes color-coded pass/fail status based on performance targets.
"""

import csv
import json
from pathlib import Path
from typing import Any, Dict, List

try:
    from rich.console import Console
    from rich.table import Table
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False

# Performance targets from CONTEXT.md
THROUGHPUT_TARGET = 770_000  # events/sec for 3-node baseline
THROUGHPUT_STRETCH = 1_000_000  # events/sec stretch goal

READ_P95_TARGET = 1.0  # ms
READ_P99_TARGET = 10.0  # ms

WRITE_P95_TARGET = 10.0  # ms
WRITE_P99_TARGET = 50.0  # ms


class BenchmarkReporter:
    """Multi-format reporter for benchmark results.

    Outputs results in JSON, CSV, Markdown, and terminal formats.
    Terminal output uses rich for color-coded pass/fail display.

    Usage:
        results = {
            "throughput": 850000,
            "read_p95_ms": 0.8,
            "read_p99_ms": 5.2,
            ...
        }
        reporter = BenchmarkReporter(results)
        reporter.to_terminal()
        reporter.to_json("results.json")
    """

    def __init__(self, results: Dict[str, Any]) -> None:
        """Initialize reporter with results.

        Args:
            results: Dict of metric names to values.
        """
        self.results = results

    def to_json(self, path: str) -> None:
        """Write results to JSON file.

        Args:
            path: Output file path.
        """
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, 'w') as f:
            json.dump(self.results, f, indent=2)

    def to_csv(self, path: str) -> None:
        """Write results to CSV file.

        Args:
            path: Output file path.
        """
        Path(path).parent.mkdir(parents=True, exist_ok=True)

        # Flatten nested dicts for CSV
        flat_results = self._flatten_dict(self.results)

        with open(path, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(["metric", "value"])
            for key, value in flat_results.items():
                writer.writerow([key, value])

    def to_markdown(self, path: str) -> None:
        """Write results to Markdown file.

        Args:
            path: Output file path.
        """
        Path(path).parent.mkdir(parents=True, exist_ok=True)

        lines = [
            "# Benchmark Results",
            "",
            "## Summary",
            "",
            "| Metric | Value | Target | Status |",
            "|--------|-------|--------|--------|",
        ]

        # Add formatted rows
        formatted = self._format_results_for_display()
        for row in formatted:
            status = "PASS" if row["passed"] else "FAIL"
            lines.append(
                f"| {row['metric']} | {row['value']} | {row['target']} | {status} |"
            )

        lines.extend([
            "",
            "## Raw Results",
            "",
            "```json",
            json.dumps(self.results, indent=2),
            "```",
        ])

        with open(path, 'w') as f:
            f.write('\n'.join(lines))

    def to_terminal(self) -> None:
        """Display results in terminal with color-coded status.

        Uses rich library for formatted table output.
        Falls back to plain text if rich is not available.
        """
        formatted = self._format_results_for_display()

        if not RICH_AVAILABLE:
            self._to_terminal_plain(formatted)
            return

        console = Console()
        table = Table(title="Benchmark Results")

        table.add_column("Metric", style="cyan")
        table.add_column("Value", style="white")
        table.add_column("Target", style="yellow")
        table.add_column("vs Target", style="white")
        table.add_column("Status", style="bold")

        for row in formatted:
            if row["passed"]:
                status = "[green]PASS[/green]"
            else:
                status = "[red]FAIL[/red]"

            table.add_row(
                row["metric"],
                row["value"],
                row["target"],
                row["vs_target"],
                status,
            )

        console.print(table)

    def _to_terminal_plain(self, formatted: List[Dict]) -> None:
        """Plain text terminal output fallback."""
        print("\n=== Benchmark Results ===\n")
        print(f"{'Metric':<25} {'Value':<15} {'Target':<15} {'Status':<10}")
        print("-" * 65)
        for row in formatted:
            status = "PASS" if row["passed"] else "FAIL"
            print(
                f"{row['metric']:<25} {row['value']:<15} "
                f"{row['target']:<15} {status:<10}"
            )
        print()

    def _format_results_for_display(self) -> List[Dict]:
        """Format results with pass/fail status for display."""
        formatted = []

        # Throughput (higher is better)
        if "throughput" in self.results:
            formatted.append(
                self.format_result(
                    "Throughput",
                    self.results["throughput"],
                    THROUGHPUT_TARGET,
                    "min",
                    unit="events/sec",
                )
            )

        # Read latencies (lower is better)
        if "read_p95_ms" in self.results:
            formatted.append(
                self.format_result(
                    "Read P95",
                    self.results["read_p95_ms"],
                    READ_P95_TARGET,
                    "max",
                    unit="ms",
                )
            )

        if "read_p99_ms" in self.results:
            formatted.append(
                self.format_result(
                    "Read P99",
                    self.results["read_p99_ms"],
                    READ_P99_TARGET,
                    "max",
                    unit="ms",
                )
            )

        # Write latencies (lower is better)
        if "write_p95_ms" in self.results:
            formatted.append(
                self.format_result(
                    "Write P95",
                    self.results["write_p95_ms"],
                    WRITE_P95_TARGET,
                    "max",
                    unit="ms",
                )
            )

        if "write_p99_ms" in self.results:
            formatted.append(
                self.format_result(
                    "Write P99",
                    self.results["write_p99_ms"],
                    WRITE_P99_TARGET,
                    "max",
                    unit="ms",
                )
            )

        return formatted

    def format_result(
        self,
        metric: str,
        value: float,
        target: float,
        target_type: str,
        unit: str = "",
    ) -> Dict:
        """Format a single result with pass/fail status.

        Args:
            metric: Name of the metric.
            value: Measured value.
            target: Target value for comparison.
            target_type: "min" (must be >= target) or "max" (must be <= target).
            unit: Unit string for display (e.g., "ms", "events/sec").

        Returns:
            Dict with metric, value, target, passed, vs_target keys.
        """
        # Determine pass/fail
        if target_type == "min":
            passed = value >= target
        else:  # max
            passed = value <= target

        # Calculate percentage vs target
        if target > 0:
            pct = (value / target) * 100
            vs_target = f"{pct:.1f}%"
        else:
            vs_target = "N/A"

        # Format value with unit
        if value >= 1_000_000:
            value_str = f"{value/1_000_000:.2f}M {unit}".strip()
        elif value >= 1_000:
            value_str = f"{value/1_000:.2f}K {unit}".strip()
        else:
            value_str = f"{value:.2f} {unit}".strip()

        # Format target with unit
        if target >= 1_000_000:
            target_str = f">={target/1_000_000:.2f}M" if target_type == "min" else f"<={target/1_000_000:.2f}M"
        elif target >= 1_000:
            target_str = f">={target/1_000:.2f}K" if target_type == "min" else f"<={target/1_000:.2f}K"
        else:
            target_str = f">={target:.2f}" if target_type == "min" else f"<={target:.2f}"
        target_str += f" {unit}".strip() if unit else ""

        return {
            "metric": metric,
            "value": value_str,
            "target": target_str,
            "passed": passed,
            "vs_target": vs_target,
        }

    def _flatten_dict(
        self,
        d: Dict,
        parent_key: str = '',
        sep: str = '.',
    ) -> Dict:
        """Flatten nested dict for CSV export."""
        items = []
        for k, v in d.items():
            new_key = f"{parent_key}{sep}{k}" if parent_key else k
            if isinstance(v, dict):
                items.extend(self._flatten_dict(v, new_key, sep).items())
            else:
                items.append((new_key, v))
        return dict(items)
