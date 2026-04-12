# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""ArcherDB benchmark framework.

This package exposes benchmark helpers without importing the full benchmark
stack eagerly. Heavy optional dependencies such as numpy/scipy are imported
only when the corresponding symbols are actually accessed.
"""

from importlib import import_module
from typing import Dict, Tuple

_EXPORTS: Dict[str, Tuple[str, str]] = {
    "BenchmarkConfig": (".config", "BenchmarkConfig"),
    "BenchmarkExecutor": (".executor", "BenchmarkExecutor"),
    "BenchmarkResult": (".executor", "BenchmarkResult"),
    "Sample": (".executor", "Sample"),
    "BenchmarkProgress": (".progress", "BenchmarkProgress"),
    "LatencyHistogram": (".histogram", "LatencyHistogram"),
    "BenchmarkReporter": (".reporter", "BenchmarkReporter"),
    "BenchmarkOrchestrator": (".orchestrator", "BenchmarkOrchestrator"),
    "PERFORMANCE_TARGETS": (".orchestrator", "PERFORMANCE_TARGETS"),
    "regression_load_baseline": (".regression", "load_baseline"),
    "regression_save_baseline": (".regression", "save_baseline"),
    "regression_compare_to_baseline": (".regression", "compare_to_baseline"),
    "RegressionReport": (".regression", "RegressionReport"),
    "generate_regression_report": (".regression", "generate_regression_report"),
    "confidence_interval": (".stats", "confidence_interval"),
    "coefficient_of_variation": (".stats", "coefficient_of_variation"),
    "is_stable": (".stats", "is_stable"),
    "detect_regression": (".stats", "detect_regression"),
    "summarize": (".stats", "summarize"),
    "ThroughputWorkload": (".workloads", "ThroughputWorkload"),
    "LatencyReadWorkload": (".workloads", "LatencyReadWorkload"),
    "LatencyWriteWorkload": (".workloads", "LatencyWriteWorkload"),
    "MixedWorkload": (".workloads", "MixedWorkload"),
    "UniformWorkload": (".workloads", "UniformWorkload"),
    "CityConcentratedWorkload": (".workloads", "CityConcentratedWorkload"),
    "ScalabilityBenchmark": (".scalability", "ScalabilityBenchmark"),
    "ScalabilityResult": (".scalability", "ScalabilityResult"),
    "SDKBenchmark": (".sdk_benchmark", "SDKBenchmark"),
    "SDKBenchmarkResult": (".sdk_benchmark", "SDKBenchmarkResult"),
    "ParityStatus": (".sdk_benchmark", "ParityStatus"),
    "save_result": (".history", "save_result"),
    "load_results": (".history", "load_results"),
    "save_baseline": (".history", "save_baseline"),
    "load_baseline": (".history", "load_baseline"),
    "compare_to_baseline": (".history", "compare_to_baseline"),
    "history_detect_regression": (".history", "detect_regression"),
    "ComparisonResult": (".history", "ComparisonResult"),
    "generate_dashboard": (".dashboard", "generate_dashboard"),
    "plot_throughput_trend": (".dashboard", "plot_throughput_trend"),
    "plot_latency_trend": (".dashboard", "plot_latency_trend"),
    "format_regression_status": (".dashboard", "format_regression_status"),
    "generate_summary_table": (".dashboard", "generate_summary_table"),
}

__all__ = list(_EXPORTS)


def __getattr__(name: str):
    if name not in _EXPORTS:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

    module_name, attr_name = _EXPORTS[name]
    module = import_module(module_name, __name__)
    value = getattr(module, attr_name)
    globals()[name] = value
    return value


def __dir__():
    return sorted(list(globals().keys()) + __all__)
