# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Thread-safe log capture for subprocess output.

This module provides a LogCapture class that wraps subprocess stdout/stderr
and provides thread-safe access to captured logs with rotation support.
"""

import io
import threading
from typing import Optional


class LogCapture:
    """Thread-safe log capture for subprocess output.

    Captures output from a subprocess in a buffer with optional size limits
    and rotation. All operations are thread-safe.

    Attributes:
        max_bytes: Maximum buffer size before rotation (default 1MB).
    """

    def __init__(self, max_bytes: int = 1048576) -> None:
        """Initialize log capture.

        Args:
            max_bytes: Maximum buffer size before rotation.
        """
        self.max_bytes = max_bytes
        self._buffer = io.StringIO()
        self._lock = threading.Lock()
        self._total_bytes = 0

    def write(self, data: str) -> None:
        """Write data to the log buffer.

        Automatically rotates if buffer exceeds max_bytes.

        Args:
            data: String data to write.
        """
        with self._lock:
            self._buffer.write(data)
            self._total_bytes += len(data.encode("utf-8"))
            if self._total_bytes > self.max_bytes:
                self._rotate_locked()

    def _rotate_locked(self) -> None:
        """Rotate logs, keeping the most recent half. Must hold lock."""
        content = self._buffer.getvalue()
        # Keep the most recent half
        half_point = len(content) // 2
        # Find a newline near the half point to avoid splitting lines
        newline_pos = content.find("\n", half_point)
        if newline_pos != -1:
            half_point = newline_pos + 1

        self._buffer = io.StringIO()
        self._buffer.write(content[half_point:])
        self._total_bytes = len(content[half_point:].encode("utf-8"))

    def rotate_logs(self, max_bytes: Optional[int] = None) -> None:
        """Manually trigger log rotation.

        Args:
            max_bytes: New max bytes limit. If None, uses current setting.
        """
        with self._lock:
            if max_bytes is not None:
                self.max_bytes = max_bytes
            if self._total_bytes > self.max_bytes:
                self._rotate_locked()

    def get_logs(self, max_lines: int = 1000) -> str:
        """Return captured logs, optionally limited to most recent lines.

        Args:
            max_lines: Maximum number of lines to return.

        Returns:
            String containing log content (most recent max_lines).
        """
        with self._lock:
            content = self._buffer.getvalue()
            if max_lines <= 0:
                return content

            lines = content.splitlines(keepends=True)
            if len(lines) <= max_lines:
                return content
            return "".join(lines[-max_lines:])

    def get_all(self) -> str:
        """Return all captured logs without line limit.

        Returns:
            Complete log content.
        """
        with self._lock:
            return self._buffer.getvalue()

    def clear(self) -> None:
        """Clear all captured logs."""
        with self._lock:
            self._buffer = io.StringIO()
            self._total_bytes = 0

    def __len__(self) -> int:
        """Return approximate byte count of captured logs."""
        with self._lock:
            return self._total_bytes
