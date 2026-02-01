# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Benchmark configuration dataclass.

Defines all configuration options for benchmark runs including topology,
duration limits, sample requirements, warmup settings, and data patterns.
"""

from dataclasses import dataclass, field
from typing import Optional

# Import warmup loader to get SDK-specific warmup iterations
try:
    from ..ci.warmup_loader import load_warmup_protocol
    _WARMUP_AVAILABLE = True
except ImportError:
    _WARMUP_AVAILABLE = False


def _default_warmup_iterations() -> int:
    """Get default warmup iterations from warmup_protocols.json.

    Uses Python SDK warmup iterations as default (100).
    Falls back to 100 if warmup_loader not available.
    """
    if _WARMUP_AVAILABLE:
        try:
            protocol = load_warmup_protocol("python")
            return protocol.warmup_iterations
        except (FileNotFoundError, KeyError):
            pass
    return 100


@dataclass
class BenchmarkConfig:
    """Configuration for a benchmark run.

    Attributes:
        topology: Number of nodes in cluster (1, 3, 5, 6).
        time_limit_sec: Maximum run duration in seconds.
        op_count_limit: Maximum number of operations.
        min_samples: Minimum required samples (error if fewer).
        target_samples: Target number of samples to collect.
        warmup_iterations: Iterations to run before measurement.
        target_cv: Coefficient of variation threshold for stability.
        max_stability_runs: Maximum runs to attempt stability.
        data_pattern: Distribution pattern for test data.
        data_size: Number of data items to generate.
        seed: Random seed for reproducibility (None = random).
        read_write_ratio: Ratio for mixed workloads (1.0 = 100% reads,
            0.8 = 80% reads/20% writes, 0.0 = 100% writes).
    """

    topology: int = 3
    time_limit_sec: float = 60.0
    op_count_limit: int = 10_000
    min_samples: int = 1000
    target_samples: int = 10_000
    warmup_iterations: int = field(default_factory=_default_warmup_iterations)
    target_cv: float = 0.10
    max_stability_runs: int = 10
    data_pattern: str = "uniform"  # "uniform", "city_concentrated", "hotspot"
    data_size: int = 10_000
    seed: Optional[int] = None
    read_write_ratio: float = 1.0

    def __post_init__(self) -> None:
        """Validate configuration values."""
        valid_topologies = {1, 3, 5, 6}
        if self.topology not in valid_topologies:
            raise ValueError(
                f"Invalid topology {self.topology}. "
                f"Must be one of {valid_topologies}"
            )

        valid_patterns = {"uniform", "city_concentrated", "hotspot"}
        if self.data_pattern not in valid_patterns:
            raise ValueError(
                f"Invalid data_pattern '{self.data_pattern}'. "
                f"Must be one of {valid_patterns}"
            )

        if not 0.0 <= self.read_write_ratio <= 1.0:
            raise ValueError(
                f"read_write_ratio must be between 0.0 and 1.0, "
                f"got {self.read_write_ratio}"
            )

        if self.min_samples < 1:
            raise ValueError("min_samples must be at least 1")

        if self.time_limit_sec <= 0:
            raise ValueError("time_limit_sec must be positive")

        if self.op_count_limit < 1:
            raise ValueError("op_count_limit must be at least 1")
