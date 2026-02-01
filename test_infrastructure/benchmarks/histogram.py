# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""HDR Histogram wrapper for latency percentile calculation.

Provides O(1) recording and O(1) percentile calculation using
hdrhistogram library. Falls back to sorted percentile calculation
if hdrhistogram is not available.
"""

from typing import Dict, List

try:
    from hdrhistogram import HdrHistogram
    HDR_AVAILABLE = True
except ImportError:
    HDR_AVAILABLE = False


class LatencyHistogram:
    """Wrapper for HDR Histogram optimized for latency measurement.

    Records latency values in microseconds and provides percentile
    calculation with O(1) performance using HDR Histogram.

    Falls back to sorted-array percentile calculation if hdrhistogram
    library is not installed.

    Usage:
        histogram = LatencyHistogram()
        for latency_us in latencies:
            histogram.record(latency_us)

        print(histogram.percentile(99))  # P99 latency
        print(histogram.percentiles())   # All standard percentiles
    """

    def __init__(
        self,
        min_value: int = 1,
        max_value: int = 3600_000_000,
        significant_digits: int = 3,
    ) -> None:
        """Initialize histogram.

        Args:
            min_value: Minimum recordable value (default 1 microsecond).
            max_value: Maximum recordable value (default 1 hour in microseconds).
            significant_digits: Precision digits (default 3).
        """
        self._min_value = min_value
        self._max_value = max_value
        self._significant_digits = significant_digits
        self._count = 0
        self._max_recorded = 0

        if HDR_AVAILABLE:
            self._histogram = HdrHistogram(
                min_value,
                max_value,
                significant_digits,
            )
            self._fallback_samples: List[int] = []
        else:
            self._histogram = None
            self._fallback_samples: List[int] = []

    def record(self, latency_us: int) -> None:
        """Record a latency value.

        Args:
            latency_us: Latency in microseconds.
        """
        value = max(self._min_value, min(latency_us, self._max_value))
        self._count += 1
        self._max_recorded = max(self._max_recorded, value)

        if self._histogram is not None:
            self._histogram.record_value(value)
        else:
            self._fallback_samples.append(value)

    def percentile(self, p: float) -> int:
        """Get value at percentile.

        Args:
            p: Percentile value (0-100).

        Returns:
            Latency value at the given percentile in microseconds.
        """
        if self._count == 0:
            return 0

        if self._histogram is not None:
            return int(self._histogram.get_value_at_percentile(p))
        else:
            return self._fallback_percentile(p)

    def _fallback_percentile(self, p: float) -> int:
        """Calculate percentile using sorted array (fallback method)."""
        if not self._fallback_samples:
            return 0

        sorted_samples = sorted(self._fallback_samples)
        idx = int((p / 100.0) * (len(sorted_samples) - 1))
        return sorted_samples[idx]

    def percentiles(self) -> Dict[str, int]:
        """Get standard percentiles.

        Returns:
            Dict with p50, p95, p99, p999, and max values.
        """
        return {
            "p50": self.percentile(50),
            "p95": self.percentile(95),
            "p99": self.percentile(99),
            "p999": self.percentile(99.9),
            "max": self._max_recorded,
        }

    def reset(self) -> None:
        """Reset histogram to empty state."""
        self._count = 0
        self._max_recorded = 0

        if self._histogram is not None:
            self._histogram.reset()
        else:
            self._fallback_samples.clear()

    def count(self) -> int:
        """Get number of recorded samples.

        Returns:
            Total number of samples recorded.
        """
        return self._count

    @classmethod
    def from_samples(cls, samples: List[int]) -> "LatencyHistogram":
        """Create histogram from list of samples.

        Args:
            samples: List of latency values in microseconds.

        Returns:
            LatencyHistogram with all samples recorded.
        """
        histogram = cls()
        for sample in samples:
            histogram.record(sample)
        return histogram
