#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Command-line interface for running benchmarks.

Provides commands for running benchmarks and comparing results.

Usage:
    python -m test_infrastructure.benchmarks.cli run --topology 3 --time-limit 60
    python -m test_infrastructure.benchmarks.cli compare baseline.json current.json
"""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Optional

from .config import BenchmarkConfig
from .reporter import BenchmarkReporter


def get_output_filename(topology: int, output_dir: str) -> str:
    """Generate timestamped output filename.

    Args:
        topology: Node count for the benchmark.
        output_dir: Directory for output files.

    Returns:
        Full path to output file.
    """
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    filename = f"{timestamp}-{topology}node.json"
    return str(Path(output_dir) / filename)


def cmd_run(args: argparse.Namespace) -> int:
    """Run benchmark command.

    Args:
        args: Parsed command-line arguments.

    Returns:
        Exit code (0 for success, 1 for failure).
    """
    # Create configuration
    config = BenchmarkConfig(
        topology=args.topology,
        time_limit_sec=args.time_limit,
        op_count_limit=args.op_count,
        data_pattern=args.pattern,
        read_write_ratio=args.read_write_ratio,
    )

    print(f"Benchmark configuration:")
    print(f"  Topology: {config.topology} nodes")
    print(f"  Time limit: {config.time_limit_sec}s")
    print(f"  Op count limit: {config.op_count_limit:,}")
    print(f"  Data pattern: {config.data_pattern}")
    print(f"  Read/write ratio: {config.read_write_ratio}")
    print()

    # NOTE: Actual benchmark execution requires orchestrator (Phase 15-02)
    # This CLI sets up configuration and output paths
    print("Benchmark execution requires orchestrator module (15-02-PLAN).")
    print("Configuration validated successfully.")

    # Ensure output directory exists
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    output_path = get_output_filename(args.topology, args.output_dir)
    print(f"Output will be written to: {output_path}")

    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    """Compare two benchmark result files for regression.

    Args:
        args: Parsed command-line arguments.

    Returns:
        Exit code (0 for no regression, 1 for regression detected).
    """
    # Load result files
    try:
        with open(args.baseline) as f:
            baseline = json.load(f)
        with open(args.current) as f:
            current = json.load(f)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        return 1

    print(f"Comparing:")
    print(f"  Baseline: {args.baseline}")
    print(f"  Current:  {args.current}")
    print()

    # Import stats for regression detection
    try:
        from .stats import detect_regression
    except ImportError:
        print("Error: scipy not installed for regression detection")
        return 1

    # Compare key metrics
    regressions = []
    metrics = ["throughput", "read_p95_ms", "read_p99_ms", "write_p95_ms", "write_p99_ms"]

    for metric in metrics:
        if metric not in baseline or metric not in current:
            continue

        b_val = baseline[metric]
        c_val = current[metric]

        # For throughput, lower is regression; for latency, higher is regression
        if metric == "throughput":
            # Swap order for throughput (we want to detect if current < baseline)
            is_reg, p_val = detect_regression([c_val], [b_val], alpha=args.alpha)
        else:
            is_reg, p_val = detect_regression([b_val], [c_val], alpha=args.alpha)

        change_pct = ((c_val - b_val) / b_val) * 100 if b_val != 0 else 0

        status = "REGRESSION" if is_reg else "OK"
        print(f"  {metric}: {b_val:.2f} -> {c_val:.2f} ({change_pct:+.1f}%) [{status}]")

        if is_reg:
            regressions.append(metric)

    print()
    if regressions:
        print(f"FAIL: Regressions detected in: {', '.join(regressions)}")
        return 1
    else:
        print("PASS: No statistically significant regressions detected.")
        return 0


def main(argv: Optional[List[str]] = None) -> int:
    """Main entry point for CLI.

    Args:
        argv: Command-line arguments (defaults to sys.argv[1:]).

    Returns:
        Exit code.
    """
    parser = argparse.ArgumentParser(
        prog="benchmark",
        description="ArcherDB benchmark framework CLI",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # Run command
    run_parser = subparsers.add_parser("run", help="Run benchmark")
    run_parser.add_argument(
        "--topology",
        type=int,
        default=3,
        choices=[1, 3, 5, 6],
        help="Number of nodes in cluster (default: 3)",
    )
    run_parser.add_argument(
        "--time-limit",
        type=float,
        default=60.0,
        help="Time limit in seconds (default: 60)",
    )
    run_parser.add_argument(
        "--op-count",
        type=int,
        default=10_000,
        help="Maximum operation count (default: 10000)",
    )
    run_parser.add_argument(
        "--pattern",
        type=str,
        default="uniform",
        choices=["uniform", "city_concentrated", "hotspot"],
        help="Data distribution pattern (default: uniform)",
    )
    run_parser.add_argument(
        "--output-dir",
        type=str,
        default="reports/benchmarks",
        help="Output directory for results (default: reports/benchmarks)",
    )
    run_parser.add_argument(
        "--read-write-ratio",
        type=float,
        default=1.0,
        help="Read/write ratio for mixed workloads (default: 1.0 = 100%% reads)",
    )
    run_parser.set_defaults(func=cmd_run)

    # Compare command
    compare_parser = subparsers.add_parser("compare", help="Compare benchmark results")
    compare_parser.add_argument(
        "baseline",
        type=str,
        help="Path to baseline results JSON",
    )
    compare_parser.add_argument(
        "current",
        type=str,
        help="Path to current results JSON",
    )
    compare_parser.add_argument(
        "--alpha",
        type=float,
        default=0.05,
        help="Significance level for regression detection (default: 0.05)",
    )
    compare_parser.set_defaults(func=cmd_compare)

    args = parser.parse_args(argv)

    if args.command is None:
        parser.print_help()
        return 0

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
