# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""SDK benchmark for cross-SDK performance comparison.

Benchmarks all 6 SDKs (Python, Node, Go, Java, C, Zig) performing identical
operations and verifies performance parity within acceptable threshold.
"""

import statistics
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

# Import SDK runners
from tests.parity_tests.sdk_runners import (
    python_runner,
    node_runner,
    go_runner,
    java_runner,
    c_runner,
    zig_runner,
)


@dataclass
class ParityStatus:
    """Status of SDK parity check.

    Attributes:
        passed: True if all SDKs within threshold.
        mean_latency_ms: Mean latency across all SDKs.
        threshold_ms: 20% of mean latency.
        within_threshold: Per-SDK pass/fail status.
    """

    passed: bool = False
    mean_latency_ms: float = 0.0
    threshold_ms: float = 0.0
    within_threshold: Dict[str, bool] = field(default_factory=dict)


@dataclass
class SDKBenchmarkResult:
    """Results from SDK benchmark run.

    Attributes:
        operation: Operation that was benchmarked.
        sdk_timings: Mean latency in ms per SDK.
        sdk_p50: P50 latency in ms per SDK.
        sdk_p95: P95 latency in ms per SDK.
        parity_passed: True if all SDKs within 20% of mean.
        outlier_sdks: List of SDKs outside 20% threshold.
        timestamp: When benchmark was run.
    """

    operation: str = ""
    sdk_timings: Dict[str, float] = field(default_factory=dict)
    sdk_p50: Dict[str, float] = field(default_factory=dict)
    sdk_p95: Dict[str, float] = field(default_factory=dict)
    parity_passed: bool = False
    outlier_sdks: List[str] = field(default_factory=list)
    timestamp: str = field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")


# SDK name to runner module mapping
SDK_RUNNERS: Dict[str, Any] = {
    "python": python_runner,
    "node": node_runner,
    "go": go_runner,
    "java": java_runner,
    "c": c_runner,
    "zig": zig_runner,
}

# Default operations to benchmark
DEFAULT_OPERATIONS = ["insert", "query-uuid", "query-radius"]


class SDKBenchmark:
    """Benchmarks SDKs and verifies performance parity.

    Runs identical operations through all 6 SDKs and measures latency.
    Parity check verifies all SDKs are within 20% of the mean latency.

    Usage:
        benchmark = SDKBenchmark()
        result = benchmark.run_sdk_benchmark("insert", iterations=1000)
        if not result.parity_passed:
            print(f"Outliers: {result.outlier_sdks}")
    """

    PARITY_THRESHOLD_PCT = 20.0  # SDKs must be within 20% of mean

    def __init__(self, output_dir: str = "reports/sdk_benchmark") -> None:
        """Initialize SDK benchmark.

        Args:
            output_dir: Directory for output files.
        """
        self.output_dir = output_dir
        Path(output_dir).mkdir(parents=True, exist_ok=True)

    def run_sdk_benchmark(
        self,
        operation: str,
        server_url: str = "http://127.0.0.1:7000",
        iterations: int = 1000,
        warmup_iterations: int = 100,
    ) -> SDKBenchmarkResult:
        """Benchmark a single operation across all SDKs.

        Args:
            operation: Operation to benchmark (e.g., 'insert', 'query-uuid').
            server_url: ArcherDB server URL.
            iterations: Number of iterations per SDK.
            warmup_iterations: Warmup iterations before measurement.

        Returns:
            SDKBenchmarkResult with timings and parity status.
        """
        result = SDKBenchmarkResult(operation=operation)

        # Generate test input data
        input_data = self._generate_input_data(operation)

        for sdk_name, runner in SDK_RUNNERS.items():
            print(f"  Benchmarking {sdk_name} SDK...")

            try:
                timings = self._benchmark_sdk(
                    runner=runner,
                    server_url=server_url,
                    operation=operation,
                    input_data=input_data,
                    iterations=iterations,
                    warmup_iterations=warmup_iterations,
                )

                if timings:
                    result.sdk_timings[sdk_name] = statistics.mean(timings)
                    result.sdk_p50[sdk_name] = self._percentile(timings, 50)
                    result.sdk_p95[sdk_name] = self._percentile(timings, 95)
                else:
                    result.sdk_timings[sdk_name] = 0.0

            except Exception as e:
                print(f"    Error: {e}")
                result.sdk_timings[sdk_name] = 0.0

        # Check parity
        parity = self.check_parity(result)
        result.parity_passed = parity.passed
        result.outlier_sdks = [
            sdk for sdk, within in parity.within_threshold.items()
            if not within
        ]

        return result

    def _benchmark_sdk(
        self,
        runner: Any,
        server_url: str,
        operation: str,
        input_data: Dict[str, Any],
        iterations: int,
        warmup_iterations: int,
    ) -> List[float]:
        """Benchmark single SDK.

        Args:
            runner: SDK runner module.
            server_url: Server URL.
            operation: Operation to run.
            input_data: Input data for operation.
            iterations: Measurement iterations.
            warmup_iterations: Warmup iterations.

        Returns:
            List of latencies in milliseconds.
        """
        # Warmup
        for _ in range(warmup_iterations):
            try:
                runner.run_operation(server_url, operation, input_data)
            except Exception:
                pass  # Ignore warmup errors

        # Measurement
        timings: List[float] = []
        for _ in range(iterations):
            start_ns = time.perf_counter_ns()
            try:
                result = runner.run_operation(server_url, operation, input_data)
                if "error" not in result:
                    end_ns = time.perf_counter_ns()
                    latency_ms = (end_ns - start_ns) / 1e6
                    timings.append(latency_ms)
            except Exception:
                pass  # Skip failed iterations

        return timings

    def _generate_input_data(self, operation: str) -> Dict[str, Any]:
        """Generate test input data for operation.

        Args:
            operation: Operation name.

        Returns:
            Input data dict suitable for the operation.
        """
        import uuid

        if operation == "insert":
            return {
                "events": [
                    {
                        "entity_id": str(uuid.uuid4()),
                        "latitude": 40.7128,
                        "longitude": -74.0060,
                        "correlation_id": 12345,
                        "user_data": 0,
                    }
                ]
            }

        elif operation == "query-uuid":
            return {
                "entity_id": str(uuid.uuid4()),
            }

        elif operation == "query-radius":
            return {
                "latitude": 40.7128,
                "longitude": -74.0060,
                "radius_m": 1000,
            }

        elif operation == "query-polygon":
            return {
                "vertices": [
                    {"latitude": 40.7, "longitude": -74.1},
                    {"latitude": 40.8, "longitude": -74.1},
                    {"latitude": 40.8, "longitude": -73.9},
                    {"latitude": 40.7, "longitude": -73.9},
                ],
            }

        elif operation == "ping":
            return {}

        elif operation == "status":
            return {}

        else:
            return {}

    def _percentile(self, data: List[float], pct: int) -> float:
        """Calculate percentile from data.

        Args:
            data: List of values.
            pct: Percentile (0-100).

        Returns:
            Percentile value.
        """
        if not data:
            return 0.0

        sorted_data = sorted(data)
        index = (pct / 100.0) * (len(sorted_data) - 1)
        lower = int(index)
        upper = min(lower + 1, len(sorted_data) - 1)
        weight = index - lower

        return sorted_data[lower] * (1 - weight) + sorted_data[upper] * weight

    def check_parity(self, result: SDKBenchmarkResult) -> ParityStatus:
        """Check if all SDKs are within 20% of mean latency.

        Args:
            result: SDKBenchmarkResult with sdk_timings.

        Returns:
            ParityStatus with pass/fail and per-SDK status.
        """
        parity = ParityStatus()

        # Filter out zero/missing timings
        valid_timings = {
            sdk: timing for sdk, timing in result.sdk_timings.items()
            if timing > 0
        }

        if not valid_timings:
            return parity

        # Calculate mean across all SDKs
        parity.mean_latency_ms = statistics.mean(valid_timings.values())
        parity.threshold_ms = parity.mean_latency_ms * (self.PARITY_THRESHOLD_PCT / 100)

        # Check each SDK
        all_within = True
        for sdk, timing in valid_timings.items():
            deviation = abs(timing - parity.mean_latency_ms)
            within = deviation <= parity.threshold_ms
            parity.within_threshold[sdk] = within
            if not within:
                all_within = False

        parity.passed = all_within

        return parity

    def run_full_suite(
        self,
        operations: Optional[List[str]] = None,
        server_url: str = "http://127.0.0.1:7000",
        iterations: int = 1000,
    ) -> Dict[str, SDKBenchmarkResult]:
        """Run benchmark suite for multiple operations.

        Args:
            operations: List of operations (default: insert, query-uuid, query-radius).
            server_url: ArcherDB server URL.
            iterations: Iterations per operation per SDK.

        Returns:
            Dict mapping operation to SDKBenchmarkResult.
        """
        if operations is None:
            operations = DEFAULT_OPERATIONS

        results: Dict[str, SDKBenchmarkResult] = {}

        for operation in operations:
            print(f"\n--- SDK Benchmark: {operation} ---")
            results[operation] = self.run_sdk_benchmark(
                operation=operation,
                server_url=server_url,
                iterations=iterations,
            )

        return results

    def generate_report(self, results: Dict[str, SDKBenchmarkResult]) -> str:
        """Generate human-readable comparison report.

        Args:
            results: Dict of operation -> SDKBenchmarkResult.

        Returns:
            Formatted report string.
        """
        lines = [
            "",
            "=" * 70,
            "SDK Performance Comparison Report",
            f"Timestamp: {datetime.utcnow().isoformat()}Z",
            "=" * 70,
        ]

        for operation, result in results.items():
            lines.extend([
                "",
                f"Operation: {operation}",
                "-" * 50,
                "",
                "  SDK              Mean (ms)     P50 (ms)     P95 (ms)",
                "  " + "-" * 48,
            ])

            for sdk_name in sorted(result.sdk_timings.keys()):
                mean = result.sdk_timings.get(sdk_name, 0)
                p50 = result.sdk_p50.get(sdk_name, 0)
                p95 = result.sdk_p95.get(sdk_name, 0)
                marker = "" if sdk_name not in result.outlier_sdks else " *"
                lines.append(
                    f"  {sdk_name:15} {mean:10.3f}    {p50:10.3f}    {p95:10.3f}{marker}"
                )

            # Parity status
            if result.parity_passed:
                lines.append(f"\n  [PASS] All SDKs within {self.PARITY_THRESHOLD_PCT}% parity")
            else:
                lines.append(f"\n  [FAIL] Outliers: {', '.join(result.outlier_sdks)}")

        lines.extend([
            "",
            "=" * 70,
            f"Parity threshold: {self.PARITY_THRESHOLD_PCT}% of mean latency",
            "* = outside parity threshold",
            "=" * 70,
        ])

        return "\n".join(lines)
