# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""ArcherDB benchmark framework.

This package provides performance benchmarking tools with statistical rigor:

- config: BenchmarkConfig for test configuration
- executor: BenchmarkExecutor for running benchmarks with dual termination
- stats: Statistical analysis (CI, CV, t-test)
- histogram: HDR Histogram wrapper for percentile calculation
- progress: Real-time progress display during benchmark runs
- reporter: Multi-format output (JSON, CSV, Markdown, terminal)
- orchestrator: Full suite benchmark coordination across topologies
- regression: Baseline comparison and regression detection
- workloads: Throughput, latency, and mixed workload implementations
"""

from .config import BenchmarkConfig
from .executor import BenchmarkExecutor, BenchmarkResult, Sample
from .progress import BenchmarkProgress
from .histogram import LatencyHistogram
from .reporter import BenchmarkReporter
from .orchestrator import BenchmarkOrchestrator, PERFORMANCE_TARGETS
from .regression import (
    load_baseline,
    save_baseline,
    compare_to_baseline,
    RegressionReport,
    generate_regression_report,
)
from .stats import (
    confidence_interval,
    coefficient_of_variation,
    is_stable,
    detect_regression,
    summarize,
)
from .workloads import (
    ThroughputWorkload,
    LatencyReadWorkload,
    LatencyWriteWorkload,
    MixedWorkload,
)

__all__ = [
    # Config
    "BenchmarkConfig",
    # Executor
    "BenchmarkExecutor",
    "BenchmarkResult",
    "Sample",
    # Progress
    "BenchmarkProgress",
    # Histogram
    "LatencyHistogram",
    # Reporter
    "BenchmarkReporter",
    # Orchestrator
    "BenchmarkOrchestrator",
    "PERFORMANCE_TARGETS",
    # Regression
    "load_baseline",
    "save_baseline",
    "compare_to_baseline",
    "RegressionReport",
    "generate_regression_report",
    # Stats functions
    "confidence_interval",
    "coefficient_of_variation",
    "is_stable",
    "detect_regression",
    "summarize",
    # Workloads
    "ThroughputWorkload",
    "LatencyReadWorkload",
    "LatencyWriteWorkload",
    "MixedWorkload",
]
