"""
ArcherDB Python SDK - Observability Module

Provides logging, metrics, and health check functionality per client-sdk/spec.md.

Logging:
    - Pluggable logger interface
    - DEBUG: Connection state changes, request/response details
    - INFO: Successful connection, session registration
    - WARN: Reconnection, view change handling, retries
    - ERROR: Connection failures, unrecoverable errors

Metrics:
    - archerdb_client_requests_total{operation, status}
    - archerdb_client_request_duration_seconds{operation}
    - archerdb_client_connections_active
    - archerdb_client_reconnections_total
    - archerdb_client_session_renewals_total
    - archerdb_client_retries_total (per client-retry/spec.md)
    - archerdb_client_retry_exhausted_total (per client-retry/spec.md)
    - archerdb_client_primary_discoveries_total (per client-retry/spec.md)

Health Check:
    - Connection status monitoring
    - Last successful operation timestamp
"""

from __future__ import annotations

import logging
import threading
import time
from abc import ABC, abstractmethod
from collections import defaultdict
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional, Protocol, TypeVar, Union


# ============================================================================
# Logging Infrastructure
# ============================================================================


class LogLevel(Enum):
    """SDK log levels."""
    DEBUG = 10
    INFO = 20
    WARN = 30
    ERROR = 40


class SDKLogger(ABC):
    """
    Abstract base class for SDK loggers.

    Applications can implement this interface to integrate with their
    existing logging infrastructure.
    """

    @abstractmethod
    def debug(self, message: str, **kwargs: Any) -> None:
        """Log debug message (connection state, request/response details)."""
        pass

    @abstractmethod
    def info(self, message: str, **kwargs: Any) -> None:
        """Log info message (successful connection, session registration)."""
        pass

    @abstractmethod
    def warn(self, message: str, **kwargs: Any) -> None:
        """Log warning message (reconnection, view change, retries)."""
        pass

    @abstractmethod
    def error(self, message: str, **kwargs: Any) -> None:
        """Log error message (connection failures, unrecoverable errors)."""
        pass


class StandardLogger(SDKLogger):
    """
    Default logger using Python's standard logging module.

    Example:
        # Use default logger
        logger = StandardLogger()

        # Or with custom name/level
        logger = StandardLogger(name="myapp.archerdb", level=logging.DEBUG)
    """

    def __init__(
        self,
        name: str = "archerdb",
        level: int = logging.INFO
    ) -> None:
        self._logger = logging.getLogger(name)
        self._logger.setLevel(level)

        # Add handler if none exists
        if not self._logger.handlers:
            handler = logging.StreamHandler()
            handler.setLevel(level)
            formatter = logging.Formatter(
                "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
            )
            handler.setFormatter(formatter)
            self._logger.addHandler(handler)

    def debug(self, message: str, **kwargs: Any) -> None:
        extra = " ".join(f"{k}={v}" for k, v in kwargs.items())
        full_msg = f"{message} {extra}".strip() if extra else message
        self._logger.debug(full_msg)

    def info(self, message: str, **kwargs: Any) -> None:
        extra = " ".join(f"{k}={v}" for k, v in kwargs.items())
        full_msg = f"{message} {extra}".strip() if extra else message
        self._logger.info(full_msg)

    def warn(self, message: str, **kwargs: Any) -> None:
        extra = " ".join(f"{k}={v}" for k, v in kwargs.items())
        full_msg = f"{message} {extra}".strip() if extra else message
        self._logger.warning(full_msg)

    def error(self, message: str, **kwargs: Any) -> None:
        extra = " ".join(f"{k}={v}" for k, v in kwargs.items())
        full_msg = f"{message} {extra}".strip() if extra else message
        self._logger.error(full_msg)


class NullLogger(SDKLogger):
    """Logger that discards all messages (for testing or disabled logging)."""

    def debug(self, message: str, **kwargs: Any) -> None:
        pass

    def info(self, message: str, **kwargs: Any) -> None:
        pass

    def warn(self, message: str, **kwargs: Any) -> None:
        pass

    def error(self, message: str, **kwargs: Any) -> None:
        pass


# Global default logger
_default_logger: SDKLogger = NullLogger()


def configure_logging(
    logger: Optional[SDKLogger] = None,
    debug: bool = False
) -> None:
    """
    Configure SDK logging.

    Args:
        logger: Custom logger instance (defaults to StandardLogger)
        debug: If True, enable debug logging (only if using StandardLogger)

    Example:
        # Enable debug logging with standard logger
        archerdb.configure_logging(debug=True)

        # Use custom logger
        archerdb.configure_logging(logger=MyCustomLogger())
    """
    global _default_logger

    if logger is not None:
        _default_logger = logger
    else:
        level = logging.DEBUG if debug else logging.INFO
        _default_logger = StandardLogger(level=level)


def get_logger() -> SDKLogger:
    """Get the current SDK logger."""
    return _default_logger


# ============================================================================
# Metrics Infrastructure
# ============================================================================


@dataclass
class MetricLabels:
    """Labels for a metric."""
    operation: str = ""
    status: str = ""

    def to_dict(self) -> Dict[str, str]:
        """Convert to dictionary for serialization."""
        return {k: v for k, v in {
            "operation": self.operation,
            "status": self.status,
        }.items() if v}


@dataclass
class MetricValue:
    """A metric value with labels."""
    value: float
    labels: MetricLabels = field(default_factory=MetricLabels)
    timestamp_ns: int = field(default_factory=lambda: time.time_ns())


class Counter:
    """Thread-safe counter metric."""

    def __init__(self, name: str, description: str):
        self.name = name
        self.description = description
        self._values: Dict[str, float] = defaultdict(float)
        self._lock = threading.Lock()

    def inc(self, labels: Optional[MetricLabels] = None, value: float = 1.0) -> None:
        """Increment counter by value."""
        key = self._label_key(labels)
        with self._lock:
            self._values[key] += value

    def get(self, labels: Optional[MetricLabels] = None) -> float:
        """Get current value for labels."""
        key = self._label_key(labels)
        with self._lock:
            return self._values.get(key, 0.0)

    def get_all(self) -> List[MetricValue]:
        """Get all values with labels."""
        with self._lock:
            result = []
            for key, value in self._values.items():
                labels = self._parse_key(key)
                result.append(MetricValue(value=value, labels=labels))
            return result

    def _label_key(self, labels: Optional[MetricLabels]) -> str:
        if labels is None:
            return ""
        return f"{labels.operation}:{labels.status}"

    def _parse_key(self, key: str) -> MetricLabels:
        if not key:
            return MetricLabels()
        parts = key.split(":")
        return MetricLabels(
            operation=parts[0] if len(parts) > 0 else "",
            status=parts[1] if len(parts) > 1 else "",
        )


class Gauge:
    """Thread-safe gauge metric."""

    def __init__(self, name: str, description: str):
        self.name = name
        self.description = description
        self._value: float = 0.0
        self._lock = threading.Lock()

    def set(self, value: float) -> None:
        """Set gauge value."""
        with self._lock:
            self._value = value

    def inc(self, value: float = 1.0) -> None:
        """Increment gauge by value."""
        with self._lock:
            self._value += value

    def dec(self, value: float = 1.0) -> None:
        """Decrement gauge by value."""
        with self._lock:
            self._value -= value

    def get(self) -> float:
        """Get current value."""
        with self._lock:
            return self._value


class Histogram:
    """
    Thread-safe histogram metric for request durations.

    Default buckets match Prometheus defaults for HTTP latencies.
    """

    DEFAULT_BUCKETS = (
        0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5,
        0.75, 1.0, 2.5, 5.0, 7.5, 10.0, float("inf")
    )

    def __init__(
        self,
        name: str,
        description: str,
        buckets: tuple[float, ...] = DEFAULT_BUCKETS
    ):
        self.name = name
        self.description = description
        self.buckets = buckets
        self._counts: Dict[str, Dict[float, int]] = defaultdict(
            lambda: {b: 0 for b in buckets}
        )
        self._sums: Dict[str, float] = defaultdict(float)
        self._totals: Dict[str, int] = defaultdict(int)
        self._lock = threading.Lock()

    def observe(self, value: float, labels: Optional[MetricLabels] = None) -> None:
        """Record an observation."""
        key = self._label_key(labels)
        with self._lock:
            self._sums[key] += value
            self._totals[key] += 1
            for bucket in self.buckets:
                if value <= bucket:
                    self._counts[key][bucket] += 1

    def get_count(self, labels: Optional[MetricLabels] = None) -> int:
        """Get total observation count."""
        key = self._label_key(labels)
        with self._lock:
            return self._totals.get(key, 0)

    def get_sum(self, labels: Optional[MetricLabels] = None) -> float:
        """Get sum of all observations."""
        key = self._label_key(labels)
        with self._lock:
            return self._sums.get(key, 0.0)

    def get_bucket(
        self,
        bucket: float,
        labels: Optional[MetricLabels] = None
    ) -> int:
        """Get count for a specific bucket."""
        key = self._label_key(labels)
        with self._lock:
            return self._counts.get(key, {}).get(bucket, 0)

    def _label_key(self, labels: Optional[MetricLabels]) -> str:
        if labels is None:
            return ""
        return labels.operation


class SDKMetrics:
    """
    SDK metrics registry.

    Metrics exposed per client-sdk/spec.md:
    - archerdb_client_requests_total{operation, status}
    - archerdb_client_request_duration_seconds{operation}
    - archerdb_client_connections_active
    - archerdb_client_reconnections_total
    - archerdb_client_session_renewals_total

    Retry metrics per client-retry/spec.md:
    - archerdb_client_retries_total
    - archerdb_client_retry_exhausted_total
    - archerdb_client_primary_discoveries_total
    """

    def __init__(self):
        # Request metrics
        self.requests_total = Counter(
            "archerdb_client_requests_total",
            "Total number of requests by operation and status"
        )
        self.request_duration = Histogram(
            "archerdb_client_request_duration_seconds",
            "Request duration in seconds by operation"
        )

        # Connection metrics
        self.connections_active = Gauge(
            "archerdb_client_connections_active",
            "Number of active connections"
        )
        self.reconnections_total = Counter(
            "archerdb_client_reconnections_total",
            "Total number of reconnection attempts"
        )
        self.session_renewals_total = Counter(
            "archerdb_client_session_renewals_total",
            "Total number of session renewals"
        )

        # Retry metrics (per client-retry/spec.md)
        self.retries_total = Counter(
            "archerdb_client_retries_total",
            "Total number of retry attempts"
        )
        self.retry_exhausted_total = Counter(
            "archerdb_client_retry_exhausted_total",
            "Total number of operations that exhausted all retry attempts"
        )
        self.primary_discoveries_total = Counter(
            "archerdb_client_primary_discoveries_total",
            "Total number of primary discovery events"
        )

    def record_request(
        self,
        operation: str,
        status: str,
        duration_seconds: float
    ) -> None:
        """Record a completed request."""
        labels = MetricLabels(operation=operation, status=status)
        self.requests_total.inc(labels)
        self.request_duration.observe(duration_seconds, labels)

    def record_connection_opened(self) -> None:
        """Record a new connection being opened."""
        self.connections_active.inc()

    def record_connection_closed(self) -> None:
        """Record a connection being closed."""
        self.connections_active.dec()

    def record_reconnection(self) -> None:
        """Record a reconnection attempt."""
        self.reconnections_total.inc()

    def record_session_renewal(self) -> None:
        """Record a session renewal."""
        self.session_renewals_total.inc()

    def record_retry(self) -> None:
        """Record a retry attempt (per client-retry/spec.md)."""
        self.retries_total.inc()

    def record_retry_exhausted(self) -> None:
        """Record that all retry attempts were exhausted (per client-retry/spec.md)."""
        self.retry_exhausted_total.inc()

    def record_primary_discovery(self) -> None:
        """Record a primary discovery event (per client-retry/spec.md)."""
        self.primary_discoveries_total.inc()

    def to_prometheus(self) -> str:
        """
        Export metrics in Prometheus text format.

        Returns:
            Prometheus-formatted metrics string
        """
        lines = []

        # requests_total
        lines.append(f"# HELP {self.requests_total.name} {self.requests_total.description}")
        lines.append(f"# TYPE {self.requests_total.name} counter")
        for mv in self.requests_total.get_all():
            label_str = ",".join(
                f'{k}="{v}"' for k, v in mv.labels.to_dict().items()
            )
            if label_str:
                lines.append(f"{self.requests_total.name}{{{label_str}}} {mv.value}")
            else:
                lines.append(f"{self.requests_total.name} {mv.value}")

        # request_duration histogram
        lines.append(f"# HELP {self.request_duration.name} {self.request_duration.description}")
        lines.append(f"# TYPE {self.request_duration.name} histogram")
        # Note: Full histogram export would include buckets - simplified for now
        lines.append(f"{self.request_duration.name}_count {self.request_duration.get_count()}")
        lines.append(f"{self.request_duration.name}_sum {self.request_duration.get_sum()}")

        # connections_active
        lines.append(f"# HELP {self.connections_active.name} {self.connections_active.description}")
        lines.append(f"# TYPE {self.connections_active.name} gauge")
        lines.append(f"{self.connections_active.name} {self.connections_active.get()}")

        # reconnections_total
        lines.append(f"# HELP {self.reconnections_total.name} {self.reconnections_total.description}")
        lines.append(f"# TYPE {self.reconnections_total.name} counter")
        lines.append(f"{self.reconnections_total.name} {self.reconnections_total.get()}")

        # session_renewals_total
        lines.append(f"# HELP {self.session_renewals_total.name} {self.session_renewals_total.description}")
        lines.append(f"# TYPE {self.session_renewals_total.name} counter")
        lines.append(f"{self.session_renewals_total.name} {self.session_renewals_total.get()}")

        # Retry metrics (per client-retry/spec.md)
        # retries_total
        lines.append(f"# HELP {self.retries_total.name} {self.retries_total.description}")
        lines.append(f"# TYPE {self.retries_total.name} counter")
        lines.append(f"{self.retries_total.name} {self.retries_total.get()}")

        # retry_exhausted_total
        lines.append(f"# HELP {self.retry_exhausted_total.name} {self.retry_exhausted_total.description}")
        lines.append(f"# TYPE {self.retry_exhausted_total.name} counter")
        lines.append(f"{self.retry_exhausted_total.name} {self.retry_exhausted_total.get()}")

        # primary_discoveries_total
        lines.append(f"# HELP {self.primary_discoveries_total.name} {self.primary_discoveries_total.description}")
        lines.append(f"# TYPE {self.primary_discoveries_total.name} counter")
        lines.append(f"{self.primary_discoveries_total.name} {self.primary_discoveries_total.get()}")

        return "\n".join(lines)


# Global metrics registry
_metrics: Optional[SDKMetrics] = None


def get_metrics() -> SDKMetrics:
    """Get or create the global metrics registry."""
    global _metrics
    if _metrics is None:
        _metrics = SDKMetrics()
    return _metrics


def reset_metrics() -> None:
    """Reset the global metrics registry (for testing)."""
    global _metrics
    _metrics = SDKMetrics()


# ============================================================================
# Health Check
# ============================================================================


class ConnectionState(Enum):
    """Connection health states."""
    CONNECTED = "connected"
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    RECONNECTING = "reconnecting"
    FAILED = "failed"


@dataclass
class HealthStatus:
    """
    Health check result.

    Attributes:
        healthy: Overall health status
        state: Current connection state
        last_successful_op_ns: Timestamp of last successful operation (nanoseconds)
        consecutive_failures: Number of consecutive failures
        details: Additional details about health status
    """
    healthy: bool
    state: ConnectionState
    last_successful_op_ns: int = 0
    consecutive_failures: int = 0
    details: str = ""

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "healthy": self.healthy,
            "state": self.state.value,
            "last_successful_operation_ns": self.last_successful_op_ns,
            "consecutive_failures": self.consecutive_failures,
            "details": self.details,
        }


class HealthTracker:
    """
    Tracks connection health status.

    Thread-safe health tracking for SDK clients.
    """

    def __init__(self, failure_threshold: int = 3):
        self._state = ConnectionState.DISCONNECTED
        self._last_successful_op_ns: int = 0
        self._consecutive_failures: int = 0
        self._failure_threshold = failure_threshold
        self._lock = threading.Lock()

    def record_success(self) -> None:
        """Record a successful operation."""
        with self._lock:
            self._last_successful_op_ns = time.time_ns()
            self._consecutive_failures = 0
            self._state = ConnectionState.CONNECTED

    def record_failure(self) -> None:
        """Record a failed operation."""
        with self._lock:
            self._consecutive_failures += 1
            if self._consecutive_failures >= self._failure_threshold:
                self._state = ConnectionState.FAILED

    def set_connecting(self) -> None:
        """Mark as currently connecting."""
        with self._lock:
            self._state = ConnectionState.CONNECTING

    def set_reconnecting(self) -> None:
        """Mark as currently reconnecting."""
        with self._lock:
            self._state = ConnectionState.RECONNECTING

    def set_disconnected(self) -> None:
        """Mark as disconnected."""
        with self._lock:
            self._state = ConnectionState.DISCONNECTED

    def get_status(self) -> HealthStatus:
        """Get current health status."""
        with self._lock:
            healthy = (
                self._state == ConnectionState.CONNECTED and
                self._consecutive_failures < self._failure_threshold
            )

            details = ""
            if self._state == ConnectionState.FAILED:
                details = f"Connection failed after {self._consecutive_failures} consecutive failures"
            elif self._state == ConnectionState.RECONNECTING:
                details = "Attempting to reconnect"
            elif self._state == ConnectionState.CONNECTING:
                details = "Initial connection in progress"
            elif self._state == ConnectionState.DISCONNECTED:
                details = "Client is disconnected"

            return HealthStatus(
                healthy=healthy,
                state=self._state,
                last_successful_op_ns=self._last_successful_op_ns,
                consecutive_failures=self._consecutive_failures,
                details=details,
            )


# ============================================================================
# Operation Timing Context Manager
# ============================================================================


class RequestTimer:
    """
    Context manager for timing operations and recording metrics.

    Example:
        with RequestTimer("query_radius", metrics) as timer:
            result = do_query()
        # Metrics automatically recorded on exit
    """

    def __init__(
        self,
        operation: str,
        metrics: SDKMetrics,
        logger: Optional[SDKLogger] = None,
        health: Optional[HealthTracker] = None,
    ):
        self.operation = operation
        self.metrics = metrics
        self.logger = logger
        self.health = health
        self._start_ns: int = 0
        self._status: str = "success"
        self._error: Optional[Exception] = None

    def __enter__(self) -> "RequestTimer":
        self._start_ns = time.time_ns()
        if self.logger:
            self.logger.debug(f"Starting operation", operation=self.operation)
        return self

    def __exit__(
        self,
        exc_type: Optional[type],
        exc_val: Optional[Exception],
        exc_tb: Any
    ) -> bool:
        duration_ns = time.time_ns() - self._start_ns
        duration_seconds = duration_ns / 1_000_000_000

        if exc_val is not None:
            self._status = "error"
            self._error = exc_val

            if self.logger:
                self.logger.error(
                    f"Operation failed",
                    operation=self.operation,
                    duration_ms=duration_ns // 1_000_000,
                    error=str(exc_val),
                )

            if self.health:
                self.health.record_failure()
        else:
            if self.logger:
                self.logger.debug(
                    f"Operation completed",
                    operation=self.operation,
                    duration_ms=duration_ns // 1_000_000,
                )

            if self.health:
                self.health.record_success()

        self.metrics.record_request(self.operation, self._status, duration_seconds)

        # Don't suppress exceptions
        return False

    def set_status(self, status: str) -> None:
        """Override the status (e.g., for partial success)."""
        self._status = status
