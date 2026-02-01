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
"""

from .config import BenchmarkConfig
from .executor import BenchmarkExecutor, BenchmarkResult, Sample
from .progress import BenchmarkProgress

__all__ = [
    "BenchmarkConfig",
    "BenchmarkExecutor",
    "BenchmarkResult",
    "Sample",
    "BenchmarkProgress",
]
