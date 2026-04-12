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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

try:
    from .config import BenchmarkConfig
    from .reporter import BenchmarkReporter
except ImportError:  # Direct script execution
    if __package__ in (None, ""):
        sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
        from test_infrastructure.benchmarks.config import BenchmarkConfig
        from test_infrastructure.benchmarks.reporter import BenchmarkReporter
    else:
        raise


def get_output_filename(name: str, output_dir: str) -> str:
    """Generate timestamped output filename.

    Args:
        name: Benchmark file label.
        output_dir: Directory for output files.

    Returns:
        Full path to output file.
    """
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    filename = f"{timestamp}-{name}.json"
    return str(Path(output_dir) / filename)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def build_config(args: argparse.Namespace) -> BenchmarkConfig:
    """Create benchmark configuration from CLI arguments."""
    kwargs: Dict[str, Any] = {}
    if args.min_samples is not None:
        kwargs["min_samples"] = args.min_samples
    if args.target_samples is not None:
        kwargs["target_samples"] = args.target_samples
    if args.warmup_iterations is not None:
        kwargs["warmup_iterations"] = args.warmup_iterations
    if args.target_cv is not None:
        kwargs["target_cv"] = args.target_cv
    if args.data_size is not None:
        kwargs["data_size"] = args.data_size

    return BenchmarkConfig(
        topology=args.topology,
        time_limit_sec=args.time_limit,
        op_count_limit=args.op_count,
        data_pattern=args.pattern,
        read_write_ratio=args.read_write_ratio,
        seed=args.seed,
        **kwargs,
    )


def summarize_topology_results(results: Dict[str, Any], topology: int) -> Dict[str, Any]:
    """Flatten a topology result set into the reporter's summary format."""
    topo_key = str(topology)
    throughput = results.get("benchmarks", {}).get("throughput", {}).get(topo_key, {})
    latency_read = results.get("benchmarks", {}).get("latency_read", {}).get(topo_key, {})
    latency_write = results.get("benchmarks", {}).get("latency_write", {}).get(topo_key, {})
    mixed = results.get("benchmarks", {}).get("mixed", {}).get(topo_key, {})

    summary: Dict[str, Any] = {
        "topology": topology,
        "generated": utc_now_iso(),
    }

    if "throughput_events_per_sec" in throughput:
        summary["throughput"] = throughput["throughput_events_per_sec"]
    if "p95_ms" in latency_read:
        summary["read_p95_ms"] = latency_read["p95_ms"]
    if "p99_ms" in latency_read:
        summary["read_p99_ms"] = latency_read["p99_ms"]
    if "p95_ms" in latency_write:
        summary["write_p95_ms"] = latency_write["p95_ms"]
    if "p99_ms" in latency_write:
        summary["write_p99_ms"] = latency_write["p99_ms"]
    if "read_p95_ms" in mixed:
        summary["mixed_read_p95_ms"] = mixed["read_p95_ms"]
    if "write_p95_ms" in mixed:
        summary["mixed_write_p95_ms"] = mixed["write_p95_ms"]

    return summary


def run_single_topology(
    orchestrator,
    topology: int,
    include_mixed: bool,
    config: BenchmarkConfig,
    checkpoint_path: Optional[Path] = None,
) -> Dict[str, Any]:
    """Run the benchmark suite for one topology and collect results."""
    def checkpoint() -> None:
        if checkpoint_path is None:
            return
        checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
        with open(checkpoint_path, "w") as f:
            json.dump(results, f, indent=2)

    topo_key = str(topology)
    results: Dict[str, Any] = {
        "suite_start": utc_now_iso(),
        "topologies": [topology],
        "include_mixed": include_mixed,
        "benchmarks": {
            "throughput": {},
            "latency_read": {},
            "latency_write": {},
            "mixed": {},
        },
    }

    print(f"\n=== Throughput Benchmark ({topology}-node) ===")
    try:
        results["benchmarks"]["throughput"][topo_key] = orchestrator.run_throughput_benchmark(
            topology,
            config,
        )
    except Exception as exc:
        results["benchmarks"]["throughput"][topo_key] = {"error": str(exc)}
    checkpoint()

    print(f"\n=== Read Latency Benchmark ({topology}-node) ===")
    try:
        results["benchmarks"]["latency_read"][topo_key] = orchestrator.run_latency_read_benchmark(
            topology,
            config,
        )
    except Exception as exc:
        results["benchmarks"]["latency_read"][topo_key] = {"error": str(exc)}
    checkpoint()

    print(f"\n=== Write Latency Benchmark ({topology}-node) ===")
    try:
        results["benchmarks"]["latency_write"][topo_key] = orchestrator.run_latency_write_benchmark(
            topology,
            config,
        )
    except Exception as exc:
        results["benchmarks"]["latency_write"][topo_key] = {"error": str(exc)}
    checkpoint()

    if include_mixed:
        print(f"\n=== Mixed Workload Benchmark ({topology}-node) ===")
        try:
            results["benchmarks"]["mixed"][topo_key] = orchestrator.run_mixed_workload_benchmark(
                topology,
                config,
            )
        except Exception as exc:
            results["benchmarks"]["mixed"][topo_key] = {"error": str(exc)}
        checkpoint()

    results["suite_end"] = utc_now_iso()
    checkpoint()
    return results


def has_errors(results: Dict[str, Any]) -> bool:
    """Return True if any benchmark section recorded an error."""
    benchmarks = results.get("benchmarks", {})
    for suite in benchmarks.values():
        for topo_result in suite.values():
            if isinstance(topo_result, dict) and "error" in topo_result:
                return True
    return False


def cmd_run(args: argparse.Namespace) -> int:
    """Run benchmark command.

    Args:
        args: Parsed command-line arguments.

    Returns:
        Exit code (0 for success, 1 for failure).
    """
    # Create configuration
    config = build_config(args)
    include_mixed = not args.no_mixed

    print(f"Benchmark configuration:")
    if args.full_suite:
        print(f"  Topology: full suite (1/3/5/6 nodes)")
    else:
        print(f"  Topology: {config.topology} nodes")
    print(f"  Time limit: {config.time_limit_sec}s")
    print(f"  Op count limit: {config.op_count_limit:,}")
    print(f"  Min samples: {config.min_samples:,}")
    print(f"  Warmup iterations: {config.warmup_iterations:,}")
    print(f"  Data pattern: {config.data_pattern}")
    print(f"  Data size: {config.data_size:,}")
    print(f"  Read/write ratio: {config.read_write_ratio}")
    print(f"  Mixed workload: {'enabled' if include_mixed else 'disabled'}")
    if config.seed is not None:
        print(f"  Seed: {config.seed}")
    print()

    # Ensure output directory exists
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        from .orchestrator import BenchmarkOrchestrator
    except ImportError:
        if __package__ in (None, ""):
            from test_infrastructure.benchmarks.orchestrator import BenchmarkOrchestrator
        else:
            raise

    orchestrator = BenchmarkOrchestrator(output_dir=args.output_dir)

    if args.full_suite:
        output_path = Path(get_output_filename("full-suite", args.output_dir))
        results = orchestrator.run_full_suite(
            topologies=[1, 3, 5, 6],
            include_mixed=include_mixed,
            config=config,
            checkpoint_path=output_path,
        )
    else:
        output_path = Path(get_output_filename(f"{args.topology}node", args.output_dir))
        results = run_single_topology(
            orchestrator=orchestrator,
            topology=args.topology,
            include_mixed=include_mixed,
            config=config,
            checkpoint_path=output_path,
        )

    with open(output_path, "w") as f:
        json.dump(results, f, indent=2)

    print(f"\nDetailed results written to: {output_path}")

    if not args.full_suite:
        summary = summarize_topology_results(results, args.topology)
        reporter = BenchmarkReporter(summary)

        summary_json = output_path.with_name(output_path.stem + "-summary.json")
        summary_csv = output_path.with_name(output_path.stem + "-summary.csv")
        summary_md = output_path.with_name(output_path.stem + "-summary.md")

        reporter.to_json(str(summary_json))
        reporter.to_csv(str(summary_csv))
        reporter.to_markdown(str(summary_md))
        reporter.to_terminal()

        print(f"Summary written to: {summary_json}")
        print(f"Summary written to: {summary_csv}")
        print(f"Summary written to: {summary_md}")

    return 1 if has_errors(results) else 0


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
        "--min-samples",
        type=int,
        help="Minimum required samples before a run is considered valid",
    )
    run_parser.add_argument(
        "--target-samples",
        type=int,
        help="Target samples for reporting heuristics",
    )
    run_parser.add_argument(
        "--warmup-iterations",
        type=int,
        help="Warmup iterations before measurement",
    )
    run_parser.add_argument(
        "--target-cv",
        type=float,
        help="Warmup stability coefficient-of-variation target",
    )
    run_parser.add_argument(
        "--data-size",
        type=int,
        help="Preloaded/generated dataset size for read and mixed workloads",
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
    run_parser.add_argument(
        "--full-suite",
        action="store_true",
        help="Run all supported topologies (1, 3, 5, 6)",
    )
    run_parser.add_argument(
        "--no-mixed",
        action="store_true",
        help="Skip mixed workload benchmarks",
    )
    run_parser.add_argument(
        "--seed",
        type=int,
        help="Random seed for deterministic data generation",
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
