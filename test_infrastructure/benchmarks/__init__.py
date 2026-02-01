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
- scalability: Scalability measurement across node counts
- sdk_benchmark: Cross-SDK performance comparison
- history: Historical result storage and retrieval
- dashboard: Performance trend visualization
"""

from .config import BenchmarkConfig
from .executor import BenchmarkExecutor, BenchmarkResult, Sample
from .progress import BenchmarkProgress
from .histogram import LatencyHistogram
from .reporter import BenchmarkReporter
from .orchestrator import BenchmarkOrchestrator, PERFORMANCE_TARGETS
from .regression import (
    load_baseline as regression_load_baseline,
    save_baseline as regression_save_baseline,
    compare_to_baseline as regression_compare_to_baseline,
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
    UniformWorkload,
    CityConcentratedWorkload,
)
from .scalability import ScalabilityBenchmark, ScalabilityResult
from .sdk_benchmark import SDKBenchmark, SDKBenchmarkResult, ParityStatus
from .history import (
    save_result,
    load_results,
    save_baseline,
    load_baseline,
    compare_to_baseline,
    detect_regression as history_detect_regression,
    ComparisonResult,
)
from .dashboard import (
    generate_dashboard,
    plot_throughput_trend,
    plot_latency_trend,
    format_regression_status,
    generate_summary_table,
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
    # Regression (legacy module)
    "regression_load_baseline",
    "regression_save_baseline",
    "regression_compare_to_baseline",
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
    "UniformWorkload",
    "CityConcentratedWorkload",
    # Scalability
    "ScalabilityBenchmark",
    "ScalabilityResult",
    # SDK Benchmark
    "SDKBenchmark",
    "SDKBenchmarkResult",
    "ParityStatus",
    # History
    "save_result",
    "load_results",
    "save_baseline",
    "load_baseline",
    "compare_to_baseline",
    "ComparisonResult",
    # Dashboard
    "generate_dashboard",
    "plot_throughput_trend",
    "plot_latency_trend",
    "format_regression_status",
    "generate_summary_table",
]
