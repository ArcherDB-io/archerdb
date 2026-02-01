# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Real-time benchmark progress display.

Uses rich library for progress bar with live metrics showing:
- Progress bar (based on time or ops, whichever is limiting)
- Sample count
- Elapsed time
- Live metrics (avg latency, p99, throughput)
"""

import time
from typing import Optional

try:
    from rich.console import Console
    from rich.progress import (
        Progress,
        BarColumn,
        TextColumn,
        TimeElapsedColumn,
        TaskProgressColumn,
    )
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False


class BenchmarkProgress:
    """Real-time progress display for benchmark runs.

    Shows a progress bar with live metrics during benchmark execution.
    Can be disabled for non-interactive environments or testing.

    Attributes:
        total_ops: Total operations expected (None for time-based).
        time_limit_sec: Time limit in seconds.
        live_display: Whether to show live progress (disable for tests).
    """

    def __init__(
        self,
        total_ops: Optional[int],
        time_limit_sec: float,
        live_display: bool = True,
    ) -> None:
        """Initialize progress display.

        Args:
            total_ops: Expected operation count (None if unknown/time-based).
            time_limit_sec: Time limit for the benchmark run.
            live_display: If True, show live progress; if False, no output.
        """
        self.total_ops = total_ops
        self.time_limit_sec = time_limit_sec
        self.live_display = live_display and RICH_AVAILABLE

        self._start_time: Optional[float] = None
        self._sample_count: int = 0
        self._latency_sum_us: int = 0
        self._latency_max_us: int = 0

        self._progress: Optional["Progress"] = None
        self._task_id: Optional[int] = None
        self._console: Optional["Console"] = None

    def start(self) -> None:
        """Begin progress display."""
        self._start_time = time.perf_counter()
        self._sample_count = 0
        self._latency_sum_us = 0
        self._latency_max_us = 0

        if not self.live_display:
            return

        self._console = Console()
        self._progress = Progress(
            TextColumn("[bold blue]Benchmark"),
            BarColumn(bar_width=30),
            TaskProgressColumn(),
            TextColumn("[cyan]{task.fields[samples]} samples"),
            TextColumn("[yellow]{task.fields[elapsed]}"),
            TextColumn("[green]{task.fields[metrics]}"),
            console=self._console,
            refresh_per_second=4,
        )
        self._progress.start()

        # Determine total for progress bar
        # If we have total_ops, use that; otherwise use time as percentage
        total = self.total_ops if self.total_ops else 100
        self._task_id = self._progress.add_task(
            "benchmark",
            total=total,
            samples="0",
            elapsed="0.0s / {:.1f}s".format(self.time_limit_sec),
            metrics="starting...",
        )

    def update(self, sample_count: int, latest_latency_us: int) -> None:
        """Update progress display with new sample data.

        Args:
            sample_count: Total samples collected so far.
            latest_latency_us: Latency of the most recent sample in microseconds.
        """
        self._sample_count = sample_count
        self._latency_sum_us += latest_latency_us
        self._latency_max_us = max(self._latency_max_us, latest_latency_us)

        if not self.live_display or self._progress is None:
            return

        elapsed = time.perf_counter() - (self._start_time or time.perf_counter())

        # Calculate metrics
        avg_latency_us = self._latency_sum_us / max(1, sample_count)
        throughput = sample_count / max(0.001, elapsed)

        # Format metrics string
        avg_ms = avg_latency_us / 1000.0
        max_ms = self._latency_max_us / 1000.0
        if throughput >= 1000:
            throughput_str = f"{throughput/1000:.1f}K/s"
        else:
            throughput_str = f"{throughput:.0f}/s"

        metrics_str = f"avg: {avg_ms:.2f}ms, max: {max_ms:.2f}ms, {throughput_str}"

        # Determine progress value
        if self.total_ops:
            progress_value = sample_count
        else:
            # Time-based progress as percentage
            progress_value = min(100, int((elapsed / self.time_limit_sec) * 100))

        self._progress.update(
            self._task_id,
            completed=progress_value,
            samples=str(sample_count),
            elapsed=f"{elapsed:.1f}s / {self.time_limit_sec:.1f}s",
            metrics=metrics_str,
        )

    def stop(self) -> None:
        """Finalize and stop progress display."""
        if self._progress is not None:
            self._progress.stop()
            self._progress = None

    @property
    def elapsed_seconds(self) -> float:
        """Get elapsed time since start."""
        if self._start_time is None:
            return 0.0
        return time.perf_counter() - self._start_time

    @property
    def sample_count(self) -> int:
        """Get total samples collected."""
        return self._sample_count
