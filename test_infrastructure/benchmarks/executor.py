# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Benchmark executor with dual termination and warmup stability.

Runs benchmarks until either time limit OR operation count is reached.
Provides warmup phase with coefficient of variation stability check.
"""

import statistics
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional

from .config import BenchmarkConfig
from .progress import BenchmarkProgress


@dataclass
class Sample:
    """A single benchmark sample.

    Attributes:
        latency_ns: Latency in nanoseconds.
        timestamp_ns: Timestamp when sample was taken (nanoseconds).
        success: Whether the operation succeeded.
    """

    latency_ns: int
    timestamp_ns: int
    success: bool = True


@dataclass
class BenchmarkResult:
    """Results from a benchmark run.

    Attributes:
        samples: List of collected samples.
        config: Configuration used for the run.
        duration_ns: Total duration in nanoseconds.
        warmup_stable: Whether warmup reached stability.
    """

    samples: List[Sample]
    config: BenchmarkConfig
    duration_ns: int
    warmup_stable: bool = True


class BenchmarkExecutor:
    """Executes benchmarks with dual termination and progress display.

    Runs workloads until either time limit or operation count is reached.
    Supports warmup phase with stability checking based on coefficient of
    variation (CV).

    Usage:
        config = BenchmarkConfig(time_limit_sec=60, op_count_limit=10000)
        executor = BenchmarkExecutor(config)

        # Warmup first
        stable = executor.warmup(workload_fn)

        # Run measurement
        result = executor.run(workload_fn)
    """

    def __init__(
        self,
        config: BenchmarkConfig,
        show_progress: bool = True,
    ) -> None:
        """Initialize executor.

        Args:
            config: Benchmark configuration.
            show_progress: Whether to show real-time progress display.
        """
        self.config = config
        self.show_progress = show_progress

    def run(self, workload: Callable[[], Sample]) -> BenchmarkResult:
        """Run benchmark with dual termination.

        Executes workload until either time_limit_sec OR op_count_limit
        is reached, whichever comes first. Errors if fewer than min_samples
        are collected.

        Args:
            workload: Function that executes one operation and returns Sample.

        Returns:
            BenchmarkResult with collected samples and metadata.

        Raises:
            ValueError: If fewer than min_samples were collected.
        """
        samples: List[Sample] = []
        config = self.config

        # Create progress display
        progress = BenchmarkProgress(
            total_ops=config.op_count_limit,
            time_limit_sec=config.time_limit_sec,
            live_display=self.show_progress,
        )
        progress.start()

        start_ns = time.perf_counter_ns()
        time_limit_ns = int(config.time_limit_sec * 1_000_000_000)

        try:
            ops = 0
            while True:
                # Check termination conditions
                elapsed_ns = time.perf_counter_ns() - start_ns
                if elapsed_ns >= time_limit_ns:
                    break
                if ops >= config.op_count_limit:
                    break

                # Execute workload and record sample
                sample = workload()
                samples.append(sample)
                ops += 1

                # Update progress display (convert ns to us for display)
                latency_us = sample.latency_ns // 1000
                progress.update(ops, latency_us)

        finally:
            progress.stop()

        duration_ns = time.perf_counter_ns() - start_ns

        # Validate sample count
        if len(samples) < config.min_samples:
            raise ValueError(
                f"Insufficient samples: got {len(samples)}, "
                f"need at least {config.min_samples}. "
                f"Consider increasing time_limit_sec or op_count_limit."
            )

        return BenchmarkResult(
            samples=samples,
            config=config,
            duration_ns=duration_ns,
            warmup_stable=True,  # Set by warmup() if called
        )

    def warmup(self, workload: Callable[[], Sample]) -> bool:
        """Run warmup phase until stable or max iterations reached.

        Runs warmup_iterations from config first, then checks coefficient
        of variation until target_cv is reached or max_stability_runs
        exceeded.

        Args:
            workload: Function that executes one operation and returns Sample.

        Returns:
            True if stability was reached, False if hit max without stabilizing.
        """
        config = self.config
        latencies: List[float] = []

        # Run minimum warmup iterations
        for _ in range(config.warmup_iterations):
            sample = workload()
            latencies.append(sample.latency_ns)

        # Check stability with sliding window
        window_size = 30
        max_additional_iterations = config.max_stability_runs * config.warmup_iterations

        for _ in range(max_additional_iterations):
            # Check if stable using last window_size samples
            if len(latencies) >= window_size:
                recent = latencies[-window_size:]
                mean = statistics.mean(recent)
                if mean > 0:
                    cv = statistics.stdev(recent) / mean
                    if cv < config.target_cv:
                        return True  # Stable

            # Run another iteration
            sample = workload()
            latencies.append(sample.latency_ns)

        # Hit max without stabilizing
        return False

    def run_with_warmup(
        self,
        workload: Callable[[], Sample],
    ) -> BenchmarkResult:
        """Run warmup followed by measurement.

        Convenience method that runs warmup() then run().

        Args:
            workload: Function that executes one operation and returns Sample.

        Returns:
            BenchmarkResult with warmup_stable reflecting warmup outcome.
        """
        stable = self.warmup(workload)
        result = self.run(workload)
        result.warmup_stable = stable
        return result
