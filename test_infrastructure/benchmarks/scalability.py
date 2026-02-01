# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Scalability benchmark for measuring throughput across node counts.

Measures how throughput scales from single-node to multi-node topologies
and calculates scaling efficiency factors.
"""

from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from .config import BenchmarkConfig
from .orchestrator import BenchmarkOrchestrator


@dataclass
class ScalabilityResult:
    """Results from scalability benchmark suite.

    Attributes:
        topologies_tested: List of node counts tested.
        throughput_by_topology: Events/sec for each topology.
        scaling_factors: Efficiency vs linear scaling for each topology.
        is_linear: True if all factors within 0.8-1.2 range.
        timestamp: When benchmark was run.
    """

    topologies_tested: List[int] = field(default_factory=list)
    throughput_by_topology: Dict[int, float] = field(default_factory=dict)
    scaling_factors: Dict[int, float] = field(default_factory=dict)
    is_linear: bool = False
    timestamp: str = field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")


class ScalabilityBenchmark:
    """Measures throughput scaling across cluster topologies.

    Runs throughput benchmarks across different node counts (1, 3, 5, 6)
    and calculates how efficiently the system scales with additional nodes.

    Scaling factor interpretation:
    - <0.8: Sub-linear scaling (bottlenecks present)
    - 0.8-1.2: Linear scaling (ideal)
    - >1.2: Super-linear scaling (cache effects or measurement noise)

    Usage:
        benchmark = ScalabilityBenchmark()
        result = benchmark.run_scalability_suite(BenchmarkConfig())
        print(benchmark.generate_report(result))
    """

    DEFAULT_TOPOLOGIES = [1, 3, 5, 6]

    def __init__(self, output_dir: str = "reports/scalability") -> None:
        """Initialize scalability benchmark.

        Args:
            output_dir: Directory for output files.
        """
        self.output_dir = output_dir
        Path(output_dir).mkdir(parents=True, exist_ok=True)
        self._orchestrator = BenchmarkOrchestrator(output_dir=output_dir)

    def run_scalability_suite(
        self,
        config: Optional[BenchmarkConfig] = None,
        topologies: Optional[List[int]] = None,
    ) -> ScalabilityResult:
        """Run scalability benchmark across topologies.

        Args:
            config: Benchmark configuration (uses defaults if None).
            topologies: List of node counts to test (default: [1, 3, 5, 6]).

        Returns:
            ScalabilityResult with throughput and scaling factors.
        """
        if topologies is None:
            topologies = self.DEFAULT_TOPOLOGIES

        if config is None:
            config = BenchmarkConfig(
                time_limit_sec=60.0,
                op_count_limit=10_000,
            )

        result = ScalabilityResult(topologies_tested=list(topologies))

        # Run throughput benchmark for each topology
        for topology in topologies:
            print(f"\n--- Scalability Benchmark: {topology}-node topology ---")

            # Update config with current topology
            topo_config = BenchmarkConfig(
                topology=topology,
                time_limit_sec=config.time_limit_sec,
                op_count_limit=config.op_count_limit,
                min_samples=config.min_samples,
                warmup_iterations=config.warmup_iterations,
                data_pattern=config.data_pattern,
                data_size=config.data_size,
                seed=config.seed,
            )

            try:
                benchmark_result = self._orchestrator.run_throughput_benchmark(
                    topology, topo_config
                )
                throughput = benchmark_result.get("throughput_events_per_sec", 0.0)
                result.throughput_by_topology[topology] = throughput
            except Exception as e:
                print(f"  Error: {e}")
                result.throughput_by_topology[topology] = 0.0

        # Calculate scaling factors
        result.scaling_factors = self.calculate_scaling_factor(
            result.throughput_by_topology
        )

        # Determine if scaling is linear
        result.is_linear = self._check_linear_scaling(result.scaling_factors)

        return result

    def calculate_scaling_factor(
        self,
        throughput_by_topology: Dict[int, float],
    ) -> Dict[int, float]:
        """Compute scaling efficiency for each topology.

        Scaling factor = (throughput_N / throughput_1) / N

        Perfect linear scaling would give factor = 1.0 for all topologies.

        Args:
            throughput_by_topology: Throughput for each node count.

        Returns:
            Dict mapping topology to scaling factor.
        """
        scaling_factors: Dict[int, float] = {}

        # Get baseline (single-node throughput)
        baseline = throughput_by_topology.get(1, 0.0)

        if baseline == 0.0:
            # Cannot calculate scaling without baseline
            return {t: 0.0 for t in throughput_by_topology}

        for topology, throughput in throughput_by_topology.items():
            if topology == 1:
                # Single node is always factor 1.0 by definition
                scaling_factors[topology] = 1.0
            elif topology > 0 and throughput > 0:
                # scaling_factor = (throughput_N / throughput_1) / N
                # If linear: throughput_N = throughput_1 * N, so factor = 1.0
                speedup = throughput / baseline
                scaling_factors[topology] = speedup / topology
            else:
                scaling_factors[topology] = 0.0

        return scaling_factors

    def _check_linear_scaling(
        self,
        scaling_factors: Dict[int, float],
    ) -> bool:
        """Check if all scaling factors are within linear range.

        Linear range is defined as 0.8-1.2 (80%-120% of ideal).

        Args:
            scaling_factors: Scaling factor per topology.

        Returns:
            True if all factors within linear range.
        """
        if not scaling_factors:
            return False

        for factor in scaling_factors.values():
            if factor < 0.8 or factor > 1.2:
                return False

        return True

    def generate_report(self, result: ScalabilityResult) -> str:
        """Generate human-readable scalability report.

        Args:
            result: ScalabilityResult from run_scalability_suite.

        Returns:
            Formatted report string.
        """
        lines = [
            "",
            "=" * 60,
            "Scalability Benchmark Report",
            f"Timestamp: {result.timestamp}",
            "=" * 60,
            "",
            "Throughput by Topology:",
            "-" * 40,
        ]

        for topology in sorted(result.throughput_by_topology.keys()):
            throughput = result.throughput_by_topology[topology]
            factor = result.scaling_factors.get(topology, 0.0)
            classification = self._classify_scaling(factor)
            lines.append(
                f"  {topology}-node: {throughput:,.0f} events/sec "
                f"(factor: {factor:.2f} - {classification})"
            )

        lines.extend([
            "",
            "Scaling Analysis:",
            "-" * 40,
        ])

        if result.is_linear:
            lines.append("  [PASS] System exhibits linear scaling")
        else:
            lines.append("  [WARN] System does not exhibit linear scaling")

        # Scaling summary
        baseline_tp = result.throughput_by_topology.get(1, 0)
        if baseline_tp > 0 and len(result.throughput_by_topology) > 1:
            max_topo = max(t for t in result.throughput_by_topology if t > 1)
            max_tp = result.throughput_by_topology.get(max_topo, 0)
            actual_speedup = max_tp / baseline_tp if baseline_tp > 0 else 0
            ideal_speedup = max_topo
            efficiency = (actual_speedup / ideal_speedup * 100) if ideal_speedup > 0 else 0

            lines.extend([
                "",
                f"  Single-node baseline: {baseline_tp:,.0f} events/sec",
                f"  {max_topo}-node throughput: {max_tp:,.0f} events/sec",
                f"  Actual speedup: {actual_speedup:.2f}x (ideal: {ideal_speedup}x)",
                f"  Scaling efficiency: {efficiency:.1f}%",
            ])

        lines.extend([
            "",
            "=" * 60,
        ])

        return "\n".join(lines)

    def _classify_scaling(self, factor: float) -> str:
        """Classify scaling factor.

        Args:
            factor: Scaling factor value.

        Returns:
            Classification string.
        """
        if factor < 0.01:
            return "no data"
        elif factor < 0.8:
            return "sub-linear"
        elif factor <= 1.2:
            return "linear"
        else:
            return "super-linear"
