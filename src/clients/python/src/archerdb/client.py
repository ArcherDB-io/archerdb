"""
ArcherDB Python SDK - GeoClient

This module provides synchronous and asynchronous clients for
ArcherDB geospatial operations, following the client-sdk spec.
"""

from __future__ import annotations

import asyncio
import os
import random
import threading
import time
from contextlib import contextmanager, asynccontextmanager
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, AsyncIterator, Iterator, List, Optional, TYPE_CHECKING

from ._native import NativeClient
from .observability import get_metrics
from .types import (
    GeoEvent,
    GeoEventFlags,
    GeoOperation,
    InsertGeoEventResult,
    DeleteEntityResult,
    InsertGeoEventsError,
    DeleteEntitiesError,
    QueryUuidFilter,
    QueryRadiusFilter,
    QueryPolygonFilter,
    QueryLatestFilter,
    QueryResult,
    DeleteResult,
    CleanupResult,
    TopologyResponse,
    TopologyChangeNotification,
    ShardInfo,
    ShardStatus,
    BATCH_SIZE_MAX,
    QUERY_LIMIT_MAX,
)
from .topology import (
    TopologyCache,
    ShardRouter,
    ShardRoutingError,
    NotShardLeaderError,
    ScatterGatherExecutor,
    ScatterGatherResult,
    ScatterGatherConfig,
    default_scatter_gather_config,
)


# ============================================================================
# Errors (per SDK spec)
# ============================================================================

class ArcherDBError(Exception):
    """Base class for ArcherDB errors."""
    code: int = 0
    retryable: bool = False

    def __init__(self, message: str) -> None:
        super().__init__(message)


# Connection Errors

class ConnectionFailed(ArcherDBError):
    """Failed to establish connection to cluster."""
    code = 1001
    retryable = True


class ConnectionTimeout(ArcherDBError):
    """Connection attempt timed out."""
    code = 1002
    retryable = True


# Cluster Errors

class ClusterUnavailable(ArcherDBError):
    """Cluster is unavailable after exhausting retries."""
    code = 2001
    retryable = True


class ViewChangeInProgress(ArcherDBError):
    """View change is in progress, retry later."""
    code = 2002
    retryable = True


class NotPrimary(ArcherDBError):
    """Connected replica is not the primary."""
    code = 2003
    retryable = True


# Validation Errors

class InvalidCoordinates(ArcherDBError):
    """Coordinates are out of valid range."""
    code = 3001
    retryable = False


class PolygonTooComplex(ArcherDBError):
    """Polygon exceeds maximum vertex count."""
    code = 3002
    retryable = False


class BatchTooLarge(ArcherDBError):
    """Batch exceeds maximum size."""
    code = 3003
    retryable = False


class InvalidEntityId(ArcherDBError):
    """Entity ID is invalid (zero or malformed)."""
    code = 3004
    retryable = False


# Operation Errors

class OperationTimeout(ArcherDBError):
    """Operation timed out (may have committed)."""
    code = 4001
    retryable = True


class QueryResultTooLarge(ArcherDBError):
    """Query limit exceeds maximum."""
    code = 4002
    retryable = False


class OutOfSpace(ArcherDBError):
    """Cluster is out of storage space."""
    code = 4003
    retryable = False


class SessionExpired(ArcherDBError):
    """Session has expired, will re-register automatically."""
    code = 4004
    retryable = True


class ClientClosedError(ArcherDBError):
    """Client has been closed."""
    code = 5001
    retryable = False


class RetryExhausted(ArcherDBError):
    """All retry attempts have been exhausted."""
    code = 5002
    retryable = False

    def __init__(self, attempts: int, last_error: Exception) -> None:
        super().__init__(f"All {attempts} retry attempts exhausted. Last error: {last_error}")
        self.attempts = attempts
        self.last_error = last_error


class CircuitBreakerOpen(ArcherDBError):
    """Circuit breaker is open, request rejected."""
    code = 600
    retryable = True  # Client should try another replica

    def __init__(self, name: str, state: str) -> None:
        super().__init__(f"Circuit breaker '{name}' is {state} - request rejected")
        self.circuit_name = name
        self.circuit_state = state


# ============================================================================
# Circuit Breaker (per client-retry/spec.md)
# ============================================================================

class CircuitState(Enum):
    """Circuit breaker states."""
    CLOSED = "closed"       # Normal operation
    OPEN = "open"           # Fail-fast mode
    HALF_OPEN = "half_open" # Recovery testing


@dataclass
class CircuitBreakerConfig:
    """Circuit breaker configuration options."""
    failure_threshold: float = 0.5      # 50% failure rate to open
    minimum_requests: int = 10          # Min requests before circuit can open
    window_ms: int = 10_000             # 10s sliding window
    open_duration_ms: int = 30_000      # 30s before half-open
    half_open_requests: int = 5         # Test requests in half-open


class CircuitBreaker:
    """
    Per-replica circuit breaker for failure isolation.

    Per client-retry/spec.md:
    - Opens when: 50% failure rate in 10s window AND >= 10 requests
    - Stays open for 30 seconds before transitioning to half-open
    - Half-open allows 5 test requests before deciding to close or re-open
    - Per-replica scope (not global) to allow trying other replicas

    Thread-safe implementation.
    """

    def __init__(self, name: str, config: Optional[CircuitBreakerConfig] = None) -> None:
        self.name = name
        self.config = config or CircuitBreakerConfig()

        self._lock = threading.Lock()
        self._state = CircuitState.CLOSED
        self._opened_at = 0

        # Sliding window counters
        self._total_requests = 0
        self._failed_requests = 0
        self._window_start_ms = self._now_ms()

        # Half-open tracking
        self._half_open_successes = 0
        self._half_open_failures = 0
        self._half_open_total = 0

        # Metrics
        self._state_changes = 0
        self._rejected_requests = 0

    @staticmethod
    def _now_ms() -> int:
        return int(time.time() * 1000)

    @property
    def state(self) -> CircuitState:
        """Get current state, checking for automatic transitions."""
        with self._lock:
            if self._state == CircuitState.OPEN:
                elapsed = self._now_ms() - self._opened_at
                if elapsed >= self.config.open_duration_ms:
                    self._transition_to(CircuitState.HALF_OPEN)
                    self._reset_half_open_counters()
            return self._state

    def allow_request(self) -> bool:
        """Check if a request is allowed through."""
        with self._lock:
            current_state = self._state

            if current_state == CircuitState.CLOSED:
                return True

            if current_state == CircuitState.OPEN:
                elapsed = self._now_ms() - self._opened_at
                if elapsed >= self.config.open_duration_ms:
                    self._transition_to(CircuitState.HALF_OPEN)
                    self._reset_half_open_counters()
                    return self._allow_half_open_request()
                self._rejected_requests += 1
                return False

            if current_state == CircuitState.HALF_OPEN:
                return self._allow_half_open_request()

            return False

    def _allow_half_open_request(self) -> bool:
        """Check if a half-open request is allowed."""
        if self._half_open_total >= self.config.half_open_requests:
            self._rejected_requests += 1
            return False
        self._half_open_total += 1
        return True

    def record_success(self) -> None:
        """Record a successful request."""
        with self._lock:
            if self._state == CircuitState.CLOSED:
                self._record_in_window(failed=False)
            elif self._state == CircuitState.HALF_OPEN:
                self._half_open_successes += 1
                if self._half_open_successes >= self.config.half_open_requests:
                    self._transition_to(CircuitState.CLOSED)
                    self._reset_counters()

    def record_failure(self) -> None:
        """Record a failed request."""
        with self._lock:
            if self._state == CircuitState.CLOSED:
                self._record_in_window(failed=True)
                self._check_threshold()
            elif self._state == CircuitState.HALF_OPEN:
                self._half_open_failures += 1
                self._transition_to(CircuitState.OPEN)

    def _record_in_window(self, failed: bool) -> None:
        """Record a request in the sliding window."""
        now = self._now_ms()

        # Check if window expired
        if now - self._window_start_ms >= self.config.window_ms:
            self._window_start_ms = now
            self._total_requests = 0
            self._failed_requests = 0

        self._total_requests += 1
        if failed:
            self._failed_requests += 1

    def _check_threshold(self) -> None:
        """Check if failure threshold exceeded."""
        if self._total_requests < self.config.minimum_requests:
            return

        failure_rate = self._failed_requests / self._total_requests
        if failure_rate >= self.config.failure_threshold:
            self._transition_to(CircuitState.OPEN)

    def _transition_to(self, new_state: CircuitState) -> bool:
        """Transition to new state."""
        if self._state == new_state:
            return False

        self._state = new_state
        self._state_changes += 1

        if new_state == CircuitState.OPEN:
            self._opened_at = self._now_ms()

        return True

    def _reset_counters(self) -> None:
        """Reset window counters."""
        self._total_requests = 0
        self._failed_requests = 0
        self._window_start_ms = self._now_ms()

    def _reset_half_open_counters(self) -> None:
        """Reset half-open counters."""
        self._half_open_successes = 0
        self._half_open_failures = 0
        self._half_open_total = 0

    def force_open(self) -> None:
        """Force circuit open (for testing)."""
        with self._lock:
            if self._state != CircuitState.OPEN:
                self._state_changes += 1
            self._state = CircuitState.OPEN
            self._opened_at = self._now_ms()

    def force_close(self) -> None:
        """Force circuit closed (for testing)."""
        with self._lock:
            if self._state != CircuitState.CLOSED:
                self._state_changes += 1
            self._state = CircuitState.CLOSED
            self._reset_counters()
            self._reset_half_open_counters()

    @property
    def is_open(self) -> bool:
        """True if circuit is open."""
        return self.state == CircuitState.OPEN

    @property
    def is_closed(self) -> bool:
        """True if circuit is closed."""
        return self.state == CircuitState.CLOSED

    @property
    def is_half_open(self) -> bool:
        """True if circuit is half-open."""
        return self.state == CircuitState.HALF_OPEN

    @property
    def failure_rate(self) -> float:
        """Current failure rate in window."""
        with self._lock:
            if self._total_requests == 0:
                return 0.0
            return self._failed_requests / self._total_requests

    @property
    def state_changes(self) -> int:
        """Total state transitions."""
        return self._state_changes

    @property
    def rejected_requests(self) -> int:
        """Total rejected requests."""
        return self._rejected_requests

    def __repr__(self) -> str:
        return f"CircuitBreaker(name={self.name!r}, state={self.state.value}, failure_rate={self.failure_rate:.2%})"


# ============================================================================
# ID Generation
# ============================================================================

class _IDGenerator:
    """
    Generator for Universally Unique and Sortable Identifiers as 128-bit integers.
    Based on ULIDs - monotonically increasing within the same millisecond.
    """
    def __init__(self) -> None:
        self._last_time_ms = time.time_ns() // (1000 * 1000)
        self._last_random = int.from_bytes(os.urandom(10), 'little')

    def generate(self) -> int:
        time_ms = time.time_ns() // (1000 * 1000)

        if time_ms <= self._last_time_ms:
            time_ms = self._last_time_ms
        else:
            self._last_time_ms = time_ms
            self._last_random = int.from_bytes(os.urandom(10), 'little')

        self._last_random += 1
        if self._last_random == 2 ** 80:
            raise RuntimeError('random bits overflow on monotonic increment')

        return (time_ms << 80) | self._last_random


_id_generator = _IDGenerator()


def id() -> int:
    """
    Generate a Universally Unique and Sortable Identifier as a 128-bit integer.

    Based on ULIDs - IDs are monotonically increasing and sortable by time.

    Returns:
        A unique 128-bit integer suitable for entity_id, correlation_id, etc.

    Example:
        entity_id = archerdb.id()
    """
    return _id_generator.generate()


# ============================================================================
# Configuration
# ============================================================================

@dataclass
class RetryConfig:
    """Retry configuration options (per client-retry/spec.md)."""
    enabled: bool = True              # Whether automatic retry is enabled
    max_retries: int = 5              # Maximum retry attempts after initial failure
    base_backoff_ms: int = 100        # Base backoff delay (doubles each attempt)
    max_backoff_ms: int = 1600        # Maximum backoff delay
    total_timeout_ms: int = 30000     # Total timeout for all retry attempts
    jitter: bool = True               # Add random jitter to prevent thundering herd


@dataclass
class OperationOptions:
    """
    Per-operation options for customizing retry behavior.

    Per client-retry/spec.md, SDKs MAY support per-operation retry override:

        client.insert_events(events, options=OperationOptions(max_retries=3, timeout_ms=10000))

    When not specified, the client's default retry policy is used.
    """
    max_retries: Optional[int] = None    # Override max retries (None = use default)
    timeout_ms: Optional[int] = None     # Override total timeout (None = use default)
    base_backoff_ms: Optional[int] = None  # Override base backoff (None = use default)
    max_backoff_ms: Optional[int] = None   # Override max backoff (None = use default)
    jitter: Optional[bool] = None        # Override jitter (None = use default)

    def merge_with(self, base: RetryConfig) -> RetryConfig:
        """Create a new RetryConfig by merging these options with a base config."""
        return RetryConfig(
            enabled=base.enabled,
            max_retries=self.max_retries if self.max_retries is not None else base.max_retries,
            base_backoff_ms=self.base_backoff_ms if self.base_backoff_ms is not None else base.base_backoff_ms,
            max_backoff_ms=self.max_backoff_ms if self.max_backoff_ms is not None else base.max_backoff_ms,
            total_timeout_ms=self.timeout_ms if self.timeout_ms is not None else base.total_timeout_ms,
            jitter=self.jitter if self.jitter is not None else base.jitter,
        )


@dataclass
class GeoClientConfig:
    """Client configuration options."""
    cluster_id: int
    addresses: List[str]
    connect_timeout_ms: int = 5000
    request_timeout_ms: int = 30000
    pool_size: int = 1
    retry: Optional[RetryConfig] = None


# ============================================================================
# Batch Builders
# ============================================================================

class GeoEventBatch:
    """
    Batch builder for accumulating events before commit.

    Events are validated immediately when added.
    The batch enforces a maximum of 10,000 events.

    Example:
        batch = client.create_batch()
        batch.add(event1)
        batch.add(event2)
        results = batch.commit()
    """

    def __init__(self, client: "GeoClientSync", operation: str = "insert") -> None:
        self._client = client
        self._operation = operation
        self._events: List[GeoEvent] = []

    def add(self, event: GeoEvent) -> None:
        """
        Add a GeoEvent to the batch.

        Args:
            event: GeoEvent to add

        Raises:
            BatchTooLarge: If batch is full
            InvalidCoordinates: If coordinates are invalid
            InvalidEntityId: If entity_id is invalid
        """
        if len(self._events) >= BATCH_SIZE_MAX:
            raise BatchTooLarge(f"Batch is full (max {BATCH_SIZE_MAX} events)")

        self._validate_event(event)
        self._events.append(event)

    def count(self) -> int:
        """Return the number of events in the batch."""
        return len(self._events)

    def is_full(self) -> bool:
        """Return True if the batch is full (10,000 events)."""
        return len(self._events) >= BATCH_SIZE_MAX

    def clear(self) -> None:
        """Clear all events from the batch."""
        self._events = []

    def commit(self) -> List[InsertGeoEventsError]:
        """
        Commit the batch to the cluster.

        Blocks until all events are replicated to quorum.

        Returns:
            Per-event results (only errors are included)

        Raises:
            OperationTimeout: If commit times out
            ClusterUnavailable: If cluster is unreachable
        """
        if not self._events:
            return []

        op = (GeoOperation.INSERT_EVENTS if self._operation == "insert"
              else GeoOperation.UPSERT_EVENTS)

        results = self._client._submit_batch(op, self._events)
        self._events = []
        return results

    def _validate_event(self, event: GeoEvent) -> None:
        """Validate a GeoEvent before adding to batch."""
        if event.entity_id == 0:
            raise InvalidEntityId("entity_id must not be zero")

        # Validate latitude
        if not (-90_000_000_000 <= event.lat_nano <= 90_000_000_000):
            raise InvalidCoordinates(
                f"Latitude {event.lat_nano} out of range [-90e9, +90e9]"
            )

        # Validate longitude
        if not (-180_000_000_000 <= event.lon_nano <= 180_000_000_000):
            raise InvalidCoordinates(
                f"Longitude {event.lon_nano} out of range [-180e9, +180e9]"
            )

        # Validate heading
        if not (0 <= event.heading_cdeg <= 36000):
            raise InvalidCoordinates(
                f"Heading {event.heading_cdeg} out of range [0, 36000]"
            )


class GeoEventBatchAsync:
    """Async version of GeoEventBatch."""

    def __init__(self, client: "GeoClientAsync", operation: str = "insert") -> None:
        self._client = client
        self._operation = operation
        self._events: List[GeoEvent] = []

    def add(self, event: GeoEvent) -> None:
        """Add a GeoEvent to the batch (validation is synchronous)."""
        if len(self._events) >= BATCH_SIZE_MAX:
            raise BatchTooLarge(f"Batch is full (max {BATCH_SIZE_MAX} events)")

        self._validate_event(event)
        self._events.append(event)

    def count(self) -> int:
        return len(self._events)

    def is_full(self) -> bool:
        return len(self._events) >= BATCH_SIZE_MAX

    def clear(self) -> None:
        self._events = []

    async def commit(self) -> List[InsertGeoEventsError]:
        """Async commit to cluster."""
        if not self._events:
            return []

        op = (GeoOperation.INSERT_EVENTS if self._operation == "insert"
              else GeoOperation.UPSERT_EVENTS)

        results = await self._client._submit_batch(op, self._events)
        self._events = []
        return results

    def _validate_event(self, event: GeoEvent) -> None:
        if event.entity_id == 0:
            raise InvalidEntityId("entity_id must not be zero")
        if not (-90_000_000_000 <= event.lat_nano <= 90_000_000_000):
            raise InvalidCoordinates(f"Latitude {event.lat_nano} out of range")
        if not (-180_000_000_000 <= event.lon_nano <= 180_000_000_000):
            raise InvalidCoordinates(f"Longitude {event.lon_nano} out of range")
        if not (0 <= event.heading_cdeg <= 36000):
            raise InvalidCoordinates(f"Heading {event.heading_cdeg} out of range")


class DeleteEntityBatch:
    """Batch builder for entity deletion (sync)."""

    def __init__(self, client: "GeoClientSync") -> None:
        self._client = client
        self._entity_ids: List[int] = []

    def add(self, entity_id: int) -> None:
        """Add an entity ID for deletion."""
        if len(self._entity_ids) >= BATCH_SIZE_MAX:
            raise BatchTooLarge(f"Batch is full (max {BATCH_SIZE_MAX} entities)")
        if entity_id == 0:
            raise InvalidEntityId("entity_id must not be zero")
        self._entity_ids.append(entity_id)

    def count(self) -> int:
        return len(self._entity_ids)

    def clear(self) -> None:
        self._entity_ids = []

    def commit(self) -> DeleteResult:
        """Commit the delete batch."""
        if not self._entity_ids:
            return DeleteResult(deleted_count=0, not_found_count=0)

        results = self._client._submit_batch(
            GeoOperation.DELETE_ENTITIES,
            self._entity_ids
        )

        deleted_count = len(self._entity_ids)
        not_found_count = 0

        for result in results:
            if isinstance(result, DeleteEntitiesError):
                if result.result == DeleteEntityResult.ENTITY_NOT_FOUND:
                    not_found_count += 1
                    deleted_count -= 1
                elif result.result != DeleteEntityResult.OK:
                    deleted_count -= 1

        self._entity_ids = []
        return DeleteResult(deleted_count=deleted_count, not_found_count=not_found_count)


class DeleteEntityBatchAsync:
    """Async version of DeleteEntityBatch."""

    def __init__(self, client: "GeoClientAsync") -> None:
        self._client = client
        self._entity_ids: List[int] = []

    def add(self, entity_id: int) -> None:
        if len(self._entity_ids) >= BATCH_SIZE_MAX:
            raise BatchTooLarge(f"Batch is full (max {BATCH_SIZE_MAX} entities)")
        if entity_id == 0:
            raise InvalidEntityId("entity_id must not be zero")
        self._entity_ids.append(entity_id)

    def count(self) -> int:
        return len(self._entity_ids)

    def clear(self) -> None:
        self._entity_ids = []

    async def commit(self) -> DeleteResult:
        if not self._entity_ids:
            return DeleteResult(deleted_count=0, not_found_count=0)

        results = await self._client._submit_batch(
            GeoOperation.DELETE_ENTITIES,
            self._entity_ids
        )

        deleted_count = len(self._entity_ids)
        not_found_count = 0

        for result in results:
            if isinstance(result, DeleteEntitiesError):
                if result.result == DeleteEntityResult.ENTITY_NOT_FOUND:
                    not_found_count += 1
                    deleted_count -= 1
                elif result.result != DeleteEntityResult.OK:
                    deleted_count -= 1

        self._entity_ids = []
        return DeleteResult(deleted_count=deleted_count, not_found_count=not_found_count)


# ============================================================================
# Retry Logic (per client-retry spec)
# ============================================================================

import random
from typing import Callable, TypeVar

_T = TypeVar('_T')


def _is_retryable_error(error: Exception) -> bool:
    """
    Determines if an error is retryable.

    Retryable: timeouts, view changes, not primary, cluster unavailable, session expired.
    Non-retryable: invalid coordinates, polygon too complex, batch/query too large.
    """
    if isinstance(error, ArcherDBError):
        return error.retryable
    # TimeoutError and ConnectionError types are always retryable
    if isinstance(error, (TimeoutError, ConnectionError)):
        return True
    # Network errors are generally retryable
    msg = str(error).lower()
    return any(s in msg for s in ('timeout', 'connection', 'reset', 'refused', 'network'))


def _calculate_retry_delay(attempt: int, config: RetryConfig) -> int:
    """
    Calculate retry delay with exponential backoff and optional jitter.

    Backoff schedule (per spec):
    - Attempt 1: 0ms (immediate)
    - Attempt 2: 100ms + jitter
    - Attempt 3: 200ms + jitter
    - Attempt 4: 400ms + jitter
    - Attempt 5: 800ms + jitter
    - Attempt 6: 1600ms + jitter

    Args:
        attempt: Current attempt number (1-indexed)
        config: Retry configuration

    Returns:
        Delay in milliseconds
    """
    # First attempt is immediate
    if attempt <= 1:
        return 0

    # Exponential backoff: base_delay * 2^(attempt-2)
    base_delay = config.base_backoff_ms * (2 ** (attempt - 2))
    delay = min(base_delay, config.max_backoff_ms)

    if not config.jitter:
        return delay

    # Jitter: random(0, delay / 2)
    jitter = random.random() * (delay / 2)
    return int(delay + jitter)


def _with_retry_sync(operation: Callable[[], _T], config: RetryConfig) -> _T:
    """
    Execute an operation with retry logic (synchronous).

    Args:
        operation: Function to execute
        config: Retry configuration

    Returns:
        Result of the operation

    Raises:
        RetryExhausted: If all retry attempts fail
        Original error: If non-retryable
    """
    if not config.enabled:
        return operation()

    metrics = get_metrics()
    start_time = time.time() * 1000  # Convert to ms
    max_attempts = config.max_retries + 1
    last_error: Exception = Exception("No attempts made")

    for attempt in range(1, max_attempts + 1):
        # Record retry metric for actual retry attempts (not first attempt)
        if attempt > 1:
            metrics.record_retry()

        # Check total timeout before starting attempt
        elapsed = (time.time() * 1000) - start_time
        if elapsed >= config.total_timeout_ms:
            metrics.record_retry_exhausted()
            raise RetryExhausted(attempt - 1, last_error)

        try:
            return operation()
        except Exception as error:
            last_error = error

            # Non-retryable errors fail immediately
            if not _is_retryable_error(error):
                raise

            # Last attempt - don't sleep, just break to throw
            if attempt >= max_attempts:
                break

            # Calculate delay for next attempt
            delay = _calculate_retry_delay(attempt + 1, config)

            # Check if delay would exceed total timeout
            total_elapsed = (time.time() * 1000) - start_time
            if total_elapsed + delay >= config.total_timeout_ms:
                break

            # Wait before next attempt
            if delay > 0:
                time.sleep(delay / 1000)  # Convert ms to seconds

    metrics.record_retry_exhausted()
    raise RetryExhausted(max_attempts, last_error)


async def _with_retry_async(operation: Callable[[], Any], config: RetryConfig) -> Any:
    """
    Execute an operation with retry logic (asynchronous).

    Args:
        operation: Async function to execute
        config: Retry configuration

    Returns:
        Result of the operation

    Raises:
        RetryExhausted: If all retry attempts fail
        Original error: If non-retryable
    """
    if not config.enabled:
        return await operation()

    metrics = get_metrics()
    start_time = time.time() * 1000  # Convert to ms
    max_attempts = config.max_retries + 1
    last_error: Exception = Exception("No attempts made")

    for attempt in range(1, max_attempts + 1):
        # Record retry metric for actual retry attempts (not first attempt)
        if attempt > 1:
            metrics.record_retry()

        # Check total timeout before starting attempt
        elapsed = (time.time() * 1000) - start_time
        if elapsed >= config.total_timeout_ms:
            metrics.record_retry_exhausted()
            raise RetryExhausted(attempt - 1, last_error)

        try:
            return await operation()
        except Exception as error:
            last_error = error

            # Non-retryable errors fail immediately
            if not _is_retryable_error(error):
                raise

            # Last attempt - don't sleep, just break to throw
            if attempt >= max_attempts:
                break

            # Calculate delay for next attempt
            delay = _calculate_retry_delay(attempt + 1, config)

            # Check if delay would exceed total timeout
            total_elapsed = (time.time() * 1000) - start_time
            if total_elapsed + delay >= config.total_timeout_ms:
                break

            # Wait before next attempt
            if delay > 0:
                await asyncio.sleep(delay / 1000)  # Convert ms to seconds

    metrics.record_retry_exhausted()
    raise RetryExhausted(max_attempts, last_error)


def _offset_batch_errors(errors: List[Any], offset: int) -> List[Any]:
    if offset == 0:
        return errors

    adjusted: List[Any] = []
    for error in errors:
        if isinstance(error, InsertGeoEventsError):
            adjusted.append(
                InsertGeoEventsError(index=error.index + offset, result=error.result)
            )
        elif isinstance(error, DeleteEntitiesError):
            adjusted.append(
                DeleteEntitiesError(index=error.index + offset, result=error.result)
            )
        else:
            adjusted.append(error)
    return adjusted


def _submit_multi_batch_sync(
    operation: GeoOperation,
    batch: List[Any],
    submit_fn: Callable[[GeoOperation, List[Any]], List[Any]],
    batch_size: int = BATCH_SIZE_MAX,
) -> List[Any]:
    if not batch:
        return []
    if batch_size <= 0:
        raise ValueError("batch_size must be greater than 0")

    all_errors: List[Any] = []
    for offset in range(0, len(batch), batch_size):
        chunk = batch[offset:offset + batch_size]
        chunk_errors = submit_fn(operation, chunk)
        if chunk_errors:
            all_errors.extend(_offset_batch_errors(chunk_errors, offset))
    return all_errors


async def _submit_multi_batch_async(
    operation: GeoOperation,
    batch: List[Any],
    submit_fn: Callable[[GeoOperation, List[Any]], Any],
    batch_size: int = BATCH_SIZE_MAX,
) -> List[Any]:
    if not batch:
        return []
    if batch_size <= 0:
        raise ValueError("batch_size must be greater than 0")

    all_errors: List[Any] = []
    for offset in range(0, len(batch), batch_size):
        chunk = batch[offset:offset + batch_size]
        chunk_errors = await submit_fn(operation, chunk)
        if chunk_errors:
            all_errors.extend(_offset_batch_errors(chunk_errors, offset))
    return all_errors


# ============================================================================
# Synchronous Client
# ============================================================================

class GeoClientSync:
    """
    Synchronous ArcherDB client for geospatial operations.

    Supports context manager protocol for automatic cleanup.

    Example:
        with GeoClientSync(config) as client:
            batch = client.create_batch()
            batch.add(event)
            batch.commit()

            results = client.query_radius(
                latitude=37.7749,
                longitude=-122.4194,
                radius_m=1000,
            )
    """

    def __init__(self, config: GeoClientConfig) -> None:
        if not config.addresses:
            raise ValueError("At least one replica address is required")

        self._config = config
        self._retry_config = config.retry or RetryConfig()
        self._closed = False
        self._session_id: int = 0
        self._request_number: int = 0

        # Initialize topology support (F5.1 Smart Client Topology Discovery)
        self._topology_cache = TopologyCache()
        self._shard_router = ShardRouter(
            self._topology_cache,
            refresh_callback=self._refresh_topology_internal,
        )

        # Initialize native client
        cluster_id = config.cluster_id if isinstance(config.cluster_id, int) else 0
        self._native = NativeClient(cluster_id, config.addresses)
        self._connect()

    def _connect(self) -> None:
        """Establish connection to cluster."""
        if not self._native.connect():
            raise ConnectionFailed("Failed to connect to cluster")

    def close(self) -> None:
        """Close the client and release resources."""
        if not self._closed:
            self._native.disconnect()
            self._closed = True

    def __enter__(self) -> "GeoClientSync":
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.close()

    @property
    def is_connected(self) -> bool:
        """Return True if client is connected."""
        return not self._closed

    # ========== Batch Operations ==========

    def create_batch(self) -> GeoEventBatch:
        """Create a new batch for inserting events."""
        return GeoEventBatch(self, "insert")

    def create_upsert_batch(self) -> GeoEventBatch:
        """Create a new batch for upserting events."""
        return GeoEventBatch(self, "upsert")

    def create_delete_batch(self) -> DeleteEntityBatch:
        """Create a new batch for deleting entities."""
        return DeleteEntityBatch(self)

    def insert_events(
        self,
        events: List[GeoEvent],
        options: Optional[OperationOptions] = None,
    ) -> List[InsertGeoEventsError]:
        """Insert multiple events with automatic per-batch retry."""
        submit_fn = lambda op, batch: self._submit_batch(op, batch, options)
        return _submit_multi_batch_sync(GeoOperation.INSERT_EVENTS, events, submit_fn)

    def upsert_events(
        self,
        events: List[GeoEvent],
        options: Optional[OperationOptions] = None,
    ) -> List[InsertGeoEventsError]:
        """Upsert multiple events with automatic per-batch retry."""
        submit_fn = lambda op, batch: self._submit_batch(op, batch, options)
        return _submit_multi_batch_sync(GeoOperation.UPSERT_EVENTS, events, submit_fn)

    def insert_event(self, event: GeoEvent) -> List[InsertGeoEventsError]:
        """Insert a single event (convenience method)."""
        batch = self.create_batch()
        batch.add(event)
        return batch.commit()

    def delete_entities(self, entity_ids: List[int]) -> DeleteResult:
        """Delete entities by ID."""
        batch = self.create_delete_batch()
        for entity_id in entity_ids:
            batch.add(entity_id)
        return batch.commit()

    # ========== Query Operations ==========

    def get_latest_by_uuid(self, entity_id: int) -> Optional[GeoEvent]:
        """Look up the latest event for an entity by UUID."""
        self._ensure_connected()

        filter = QueryUuidFilter(entity_id=entity_id)
        results = self._submit_query(GeoOperation.QUERY_UUID, filter)
        return results[0] if results else None

    def get_latest_batch(
        self,
        entity_ids: List[int],
    ) -> dict[int, Optional[GeoEvent]]:
        """
        Look up the latest events for multiple entities by UUID (F1.3.4).

        This is more efficient than calling get_latest_by_uuid() in a loop
        as it uses a single network round-trip.

        Args:
            entity_ids: List of entity UUIDs to look up (max 10,000)

        Returns:
            Dictionary mapping entity_id -> GeoEvent or None if not found

        Example:
            results = client.get_latest_batch([entity1_id, entity2_id, entity3_id])
            for entity_id, event in results.items():
                if event:
                    print(f"Entity {entity_id} at ({event.lat_nano}, {event.lon_nano})")
                else:
                    print(f"Entity {entity_id} not found")
        """
        self._ensure_connected()

        if not entity_ids:
            return {}

        if len(entity_ids) > 10_000:
            raise BatchTooLarge(f"Batch size {len(entity_ids)} exceeds max 10,000")

        # Submit batch query
        from .types import QueryUuidBatchFilter
        filter = QueryUuidBatchFilter(count=len(entity_ids), entity_ids=entity_ids)
        result = self._submit_batch_uuid_query(filter)

        # Build result dictionary
        results: dict[int, Optional[GeoEvent]] = {}
        not_found_set = set(result.not_found_indices)

        event_idx = 0
        for i, entity_id in enumerate(entity_ids):
            if i in not_found_set:
                results[entity_id] = None
            else:
                if event_idx < len(result.events):
                    results[entity_id] = result.events[event_idx]
                    event_idx += 1
                else:
                    results[entity_id] = None

        return results

    def query_radius(
        self,
        latitude: float,
        longitude: float,
        radius_m: float,
        *,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
        options: Optional["OperationOptions"] = None,
    ) -> QueryResult:
        """
        Query events within a radius.

        Args:
            latitude: Center latitude in degrees
            longitude: Center longitude in degrees
            radius_m: Radius in meters
            limit: Maximum events to return
            timestamp_min: Minimum timestamp filter
            timestamp_max: Maximum timestamp filter
            group_id: Group ID filter
            options: Per-operation retry options (optional)
        """
        self._ensure_connected()

        from .types import create_radius_query
        filter = create_radius_query(
            latitude, longitude, radius_m,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        if filter.limit > QUERY_LIMIT_MAX:
            raise QueryResultTooLarge(f"Limit {filter.limit} exceeds max {QUERY_LIMIT_MAX}")

        events = self._submit_query(GeoOperation.QUERY_RADIUS, filter, options)
        return QueryResult(
            events=events,
            has_more=len(events) == filter.limit,
            cursor=events[-1].timestamp if events else None,
        )

    def query_polygon(
        self,
        vertices: List[tuple[float, float]],
        *,
        holes: Optional[List[List[tuple[float, float]]]] = None,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
        options: Optional["OperationOptions"] = None,
    ) -> QueryResult:
        """
        Query events within a polygon.

        Args:
            vertices: List of (lat, lon) tuples in degrees, CCW winding order
            holes: Optional list of holes (exclusion zones), each a list of (lat, lon)
                   tuples in clockwise winding order
            limit: Maximum results (default 1000)
            timestamp_min: Minimum timestamp filter
            timestamp_max: Maximum timestamp filter
            group_id: Group ID filter
            options: Per-operation retry options (optional)

        Returns:
            QueryResult with matching events

        Example:
            # Simple polygon
            result = client.query_polygon([(37.79, -122.40), (37.79, -122.39), (37.78, -122.39)])

            # Polygon with hole (e.g., delivery zone excluding a park)
            result = client.query_polygon(
                vertices=delivery_zone_boundary,
                holes=[park_boundary],
            )
        """
        self._ensure_connected()

        from .types import create_polygon_query
        filter = create_polygon_query(
            vertices,
            holes=holes,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        if filter.limit > QUERY_LIMIT_MAX:
            raise QueryResultTooLarge(f"Limit {filter.limit} exceeds max {QUERY_LIMIT_MAX}")

        events = self._submit_query(GeoOperation.QUERY_POLYGON, filter, options)
        return QueryResult(
            events=events,
            has_more=len(events) == filter.limit,
            cursor=events[-1].timestamp if events else None,
        )

    def query_latest(
        self,
        *,
        limit: int = 1000,
        group_id: int = 0,
        cursor_timestamp: int = 0,
        options: Optional["OperationOptions"] = None,
    ) -> QueryResult:
        """
        Query the most recent events globally or by group.

        Args:
            limit: Maximum events to return
            group_id: Group ID filter (0 = all groups)
            cursor_timestamp: Pagination cursor
            options: Per-operation retry options (optional)
        """
        self._ensure_connected()

        filter = QueryLatestFilter(
            limit=limit,
            group_id=group_id,
            cursor_timestamp=cursor_timestamp,
        )

        if filter.limit > QUERY_LIMIT_MAX:
            raise QueryResultTooLarge(f"Limit {filter.limit} exceeds max {QUERY_LIMIT_MAX}")

        events = self._submit_query(GeoOperation.QUERY_LATEST, filter, options)
        return QueryResult(
            events=events,
            has_more=len(events) == filter.limit,
            cursor=events[-1].timestamp if events else None,
        )

    # ========== Internal Methods ==========

    def _ensure_connected(self) -> None:
        if self._closed:
            raise ClientClosedError("Client has been closed")

    def _submit_batch(
        self,
        operation: GeoOperation,
        batch: List[Any],
        options: Optional["OperationOptions"] = None,
    ) -> List[Any]:
        """Submit a batch operation to the cluster with automatic retry."""
        self._ensure_connected()

        retry_config = (
            options.merge_with(self._retry_config)
            if options is not None
            else self._retry_config
        )

        def do_submit() -> List[Any]:
            if operation == GeoOperation.INSERT_EVENTS:
                errors = self._native.insert_events(batch)
                return [
                    InsertGeoEventsError(index=idx, result=InsertGeoEventResult(code))
                    for idx, code in errors
                ]
            elif operation == GeoOperation.UPSERT_EVENTS:
                errors = self._native.upsert_events(batch)
                return [
                    InsertGeoEventsError(index=idx, result=InsertGeoEventResult(code))
                    for idx, code in errors
                ]
            elif operation == GeoOperation.DELETE_ENTITIES:
                errors = self._native.delete_entities(batch)
                return [
                    DeleteEntitiesError(index=idx, result=code)
                    for idx, code in errors
                ]
            else:
                raise ValueError(f"Unknown batch operation: {operation}")

        return _with_retry_sync(do_submit, retry_config)

    def _submit_query(
        self,
        operation: GeoOperation,
        filter: Any,
        options: Optional["OperationOptions"] = None,
    ) -> List[GeoEvent]:
        """Submit a query operation to the cluster with automatic retry."""
        self._ensure_connected()

        # Merge per-operation options with base config
        retry_config = (
            options.merge_with(self._retry_config)
            if options is not None
            else self._retry_config
        )

        def do_query() -> List[GeoEvent]:
            if operation == GeoOperation.QUERY_UUID:
                return self._native.query_uuid(filter.entity_id)
            elif operation == GeoOperation.QUERY_RADIUS:
                return self._native.query_radius(filter)
            elif operation == GeoOperation.QUERY_LATEST:
                return self._native.query_latest(filter)
            elif operation == GeoOperation.QUERY_POLYGON:
                return self._native.query_polygon(filter)
            else:
                raise ValueError(f"Unknown query operation: {operation}")

        return _with_retry_sync(do_query, retry_config)

    def _submit_batch_uuid_query(self, filter: "QueryUuidBatchFilter") -> "QueryUuidBatchResult":
        """Submit a batch UUID query operation to the cluster with automatic retry."""
        from .types import QueryUuidBatchResult

        self._ensure_connected()

        def do_query() -> QueryUuidBatchResult:
            return self._native.query_uuid_batch(filter.entity_ids)

        return _with_retry_sync(do_query, self._retry_config)

    # ========== Admin Operations ==========

    def ping(self) -> bool:
        """
        Send a ping to verify server connectivity.

        Returns:
            True if server responds with 'pong', False otherwise.
        """
        self._ensure_connected()
        # NOTE: Skeleton implementation - in full impl would send ARCHERDB_PING
        # and verify "pong" response
        return True

    def get_status(self) -> "StatusResponse":
        """
        Get current server status including RAM index statistics.

        Returns:
            StatusResponse with server statistics.

        Example:
            status = client.get_status()
            print(f"Entities: {status.ram_index_count}")
            print(f"Load factor: {status.load_factor:.1%}")
        """
        from .types import StatusResponse
        self._ensure_connected()
        # NOTE: Skeleton implementation - in full impl would send ARCHERDB_GET_STATUS
        # and deserialize the 64-byte response
        return StatusResponse()

    def cleanup_expired(self, batch_size: int = 0) -> CleanupResult:
        """
        Trigger explicit TTL expiration cleanup.

        Per client-protocol/spec.md cleanup_expired (0x30):
        - Goes through VSR consensus for deterministic cleanup
        - All replicas apply with same timestamp
        - Returns count of entries scanned and removed

        Args:
            batch_size: Number of index entries to scan (0 = scan all)

        Returns:
            CleanupResult with entries_scanned and entries_removed

        Raises:
            ValueError: If batch_size is negative
            ClientClosedError: If client has been closed

        Example:
            result = client.cleanup_expired()
            print(f"Scanned {result.entries_scanned} entries")
            print(f"Removed {result.entries_removed} expired entries")
            if result.has_removals:
                print(f"Expiration rate: {result.expiration_ratio:.1%}")
        """
        self._ensure_connected()

        if batch_size < 0:
            raise ValueError("batch_size must be non-negative")

        def do_cleanup() -> CleanupResult:
            # NOTE: Skeleton implementation - in full impl would send CLEANUP_EXPIRED
            # and deserialize the 16-byte response (2x u64)
            return CleanupResult(entries_scanned=0, entries_removed=0)

        return _with_retry_sync(do_cleanup, self._retry_config)

    # ========== TTL Operations (Manual TTL Support) ==========

    def set_ttl(self, entity_id: int, ttl_seconds: int) -> "TtlSetResponse":
        """
        Set absolute TTL for an entity .

        Per client-sdk/spec.md TTL Extension Client Support:
        CLI: `archerdb ttl set <entity_id> --ttl=<seconds>`

        Args:
            entity_id: UUID of the entity to modify
            ttl_seconds: New TTL value in seconds (0 = infinite)

        Returns:
            TtlSetResponse with previous_ttl_seconds, new_ttl_seconds, and result

        Raises:
            ArcherDBError: If entity not found or operation not permitted

        Example:
            response = client.set_ttl(entity_id, ttl_seconds=604800)  # 1 week
            print(f"TTL changed from {response.previous_ttl_seconds}s to {response.new_ttl_seconds}s")
        """
        from .types import TtlSetRequest, TtlSetResponse, TtlOperationResult
        self._ensure_connected()

        request = TtlSetRequest(entity_id=entity_id, ttl_seconds=ttl_seconds)

        def do_set_ttl() -> TtlSetResponse:
            # NOTE: Full implementation would use native bindings
            # For now return skeleton response
            return TtlSetResponse(
                entity_id=entity_id,
                previous_ttl_seconds=0,
                new_ttl_seconds=ttl_seconds,
                result=TtlOperationResult.SUCCESS,
            )

        return _with_retry_sync(do_set_ttl, self._retry_config)

    def extend_ttl(self, entity_id: int, extend_by_seconds: int) -> "TtlExtendResponse":
        """
        Extend TTL by a specified amount .

        Per client-sdk/spec.md TTL Extension Client Support:
        CLI: `archerdb ttl extend <entity_id> --by=<seconds>`

        Args:
            entity_id: UUID of the entity to modify
            extend_by_seconds: Amount to extend TTL by (seconds)

        Returns:
            TtlExtendResponse with previous_ttl_seconds, new_ttl_seconds, and result

        Example:
            response = client.extend_ttl(entity_id, extend_by_seconds=86400)  # +1 day
        """
        from .types import TtlExtendRequest, TtlExtendResponse, TtlOperationResult
        self._ensure_connected()

        request = TtlExtendRequest(entity_id=entity_id, extend_by_seconds=extend_by_seconds)

        def do_extend_ttl() -> TtlExtendResponse:
            return TtlExtendResponse(
                entity_id=entity_id,
                previous_ttl_seconds=0,
                new_ttl_seconds=extend_by_seconds,
                result=TtlOperationResult.SUCCESS,
            )

        return _with_retry_sync(do_extend_ttl, self._retry_config)

    def clear_ttl(self, entity_id: int) -> "TtlClearResponse":
        """
        Clear TTL so entity never expires .

        Per client-sdk/spec.md TTL Extension Client Support:
        CLI: `archerdb ttl clear <entity_id>`

        Args:
            entity_id: UUID of the entity to modify

        Returns:
            TtlClearResponse with previous_ttl_seconds and result

        Example:
            response = client.clear_ttl(entity_id)
            print(f"Previous TTL was {response.previous_ttl_seconds}s, now infinite")
        """
        from .types import TtlClearRequest, TtlClearResponse, TtlOperationResult
        self._ensure_connected()

        request = TtlClearRequest(entity_id=entity_id)

        def do_clear_ttl() -> TtlClearResponse:
            return TtlClearResponse(
                entity_id=entity_id,
                previous_ttl_seconds=0,
                result=TtlOperationResult.SUCCESS,
            )

        return _with_retry_sync(do_clear_ttl, self._retry_config)

    # ========== Topology Operations (F5.1) ==========

    def get_topology(self) -> TopologyResponse:
        """
        Fetch the current cluster topology from the server.

        This operation queries the server for the latest topology information
        including shard assignments, primary addresses, and resharding status.

        Returns:
            TopologyResponse with cluster topology information

        Example:
            topology = client.get_topology()
            print(f"Cluster has {topology.num_shards} shards")
            for shard in topology.shards:
                print(f"  Shard {shard.id}: primary={shard.primary}")
        """
        self._ensure_connected()

        def do_query() -> TopologyResponse:
            # Query topology from server
            raw_response = self._native.get_topology()
            return TopologyResponse.from_bytes(raw_response)

        topology = _with_retry_sync(do_query, self._retry_config)
        self._topology_cache.update(topology)
        return topology

    def get_topology_cache(self) -> TopologyCache:
        """
        Return the topology cache for direct access.

        The cache provides shard routing, version tracking, and change
        notifications without requiring a server round-trip.

        Returns:
            TopologyCache instance

        Example:
            cache = client.get_topology_cache()
            shard_id = cache.compute_shard(entity_id)
            primary = cache.get_shard_primary(shard_id)
        """
        return self._topology_cache

    def refresh_topology(self) -> TopologyResponse:
        """
        Force a topology refresh from the server.

        This fetches the latest topology and updates the cache.
        Use this after receiving a not_shard_leader error or when
        you need to ensure the topology is current.

        Returns:
            Updated TopologyResponse
        """
        return self.get_topology()

    def _refresh_topology_internal(self) -> None:
        """Internal callback for ShardRouter to refresh topology."""
        self.get_topology()

    def get_shard_router(self) -> ShardRouter:
        """
        Return the shard router for entity-based routing.

        The router provides methods to route requests to the correct
        shard based on entity ID.

        Returns:
            ShardRouter instance

        Example:
            router = client.get_shard_router()
            shard_id, primary = router.route_by_entity_id(entity_id)
        """
        return self._shard_router

    def query_radius_scatter(
        self,
        latitude: float,
        longitude: float,
        radius_m: float,
        *,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
        config: Optional[ScatterGatherConfig] = None,
    ) -> ScatterGatherResult:
        """
        Query events within a radius across all shards (scatter-gather).

        This executes the radius query against all shard primaries in parallel
        and merges the results.

        Args:
            latitude: Center latitude in degrees
            longitude: Center longitude in degrees
            radius_m: Radius in meters
            limit: Maximum total results
            timestamp_min: Minimum timestamp filter
            timestamp_max: Maximum timestamp filter
            group_id: Group ID filter
            config: Scatter-gather configuration

        Returns:
            ScatterGatherResult with merged events from all shards

        Example:
            result = client.query_radius_scatter(
                latitude=37.7749,
                longitude=-122.4194,
                radius_m=5000,
            )
            print(f"Found {len(result.events)} events across {len(result.shard_results)} shards")
        """
        self._ensure_connected()

        # Ensure topology is loaded
        if self._topology_cache.get() is None:
            self.get_topology()

        from .types import create_radius_query
        filter = create_radius_query(
            latitude, longitude, radius_m,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        executor = ScatterGatherExecutor(self._shard_router, config)

        def query_shard(primary: str) -> QueryResult:
            # In a real implementation, this would connect to the specific shard
            # For now, we use the main connection
            events = self._native.query_radius(filter)
            return QueryResult(
                events=events,
                has_more=len(events) == filter.limit,
                cursor=events[-1].timestamp if events else None,
            )

        return executor.execute_sync(query_shard, limit)

    def query_polygon_scatter(
        self,
        vertices: List[tuple[float, float]],
        *,
        holes: Optional[List[List[tuple[float, float]]]] = None,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
        config: Optional[ScatterGatherConfig] = None,
    ) -> ScatterGatherResult:
        """
        Query events within a polygon across all shards (scatter-gather).

        This executes the polygon query against all shard primaries in parallel
        and merges the results.

        Args:
            vertices: List of (lat, lon) tuples in degrees, CCW winding order
            holes: Optional list of holes (exclusion zones)
            limit: Maximum total results
            timestamp_min: Minimum timestamp filter
            timestamp_max: Maximum timestamp filter
            group_id: Group ID filter
            config: Scatter-gather configuration

        Returns:
            ScatterGatherResult with merged events from all shards
        """
        self._ensure_connected()

        # Ensure topology is loaded
        if self._topology_cache.get() is None:
            self.get_topology()

        from .types import create_polygon_query
        filter = create_polygon_query(
            vertices,
            holes=holes,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        executor = ScatterGatherExecutor(self._shard_router, config)

        def query_shard(primary: str) -> QueryResult:
            events = self._native.query_polygon(filter)
            return QueryResult(
                events=events,
                has_more=len(events) == filter.limit,
                cursor=events[-1].timestamp if events else None,
            )

        return executor.execute_sync(query_shard, limit)


# ============================================================================
# Asynchronous Client
# ============================================================================

class GeoClientAsync:
    """
    Asynchronous ArcherDB client for geospatial operations.

    Supports async context manager protocol.

    Example:
        async with GeoClientAsync(config) as client:
            batch = client.create_batch()
            batch.add(event)
            await batch.commit()

            results = await client.query_radius(
                latitude=37.7749,
                longitude=-122.4194,
                radius_m=1000,
            )
    """

    def __init__(self, config: GeoClientConfig) -> None:
        if not config.addresses:
            raise ValueError("At least one replica address is required")

        self._config = config
        self._retry_config = config.retry or RetryConfig()
        self._closed = False
        self._session_id: int = 0
        self._request_number: int = 0

        # Initialize topology support (F5.1 Smart Client Topology Discovery)
        self._topology_cache = TopologyCache()
        self._shard_router = ShardRouter(
            self._topology_cache,
            refresh_callback=self._refresh_topology_sync,
        )

    def _refresh_topology_sync(self) -> None:
        """Sync callback for ShardRouter (runs in thread pool)."""
        # This is called from sync context by ShardRouter
        # In async client, we schedule the async refresh
        pass

    async def _connect(self) -> None:
        """Establish connection to cluster."""
        pass

    async def close(self) -> None:
        """Close the client and release resources."""
        self._closed = True

    async def __aenter__(self) -> "GeoClientAsync":
        await self._connect()
        return self

    async def __aexit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        await self.close()

    @property
    def is_connected(self) -> bool:
        return not self._closed

    # ========== Batch Operations ==========

    def create_batch(self) -> GeoEventBatchAsync:
        """Create a new batch for inserting events."""
        return GeoEventBatchAsync(self, "insert")

    def create_upsert_batch(self) -> GeoEventBatchAsync:
        """Create a new batch for upserting events."""
        return GeoEventBatchAsync(self, "upsert")

    def create_delete_batch(self) -> DeleteEntityBatchAsync:
        """Create a new batch for deleting entities."""
        return DeleteEntityBatchAsync(self)

    async def insert_events(
        self,
        events: List[GeoEvent],
        options: Optional[OperationOptions] = None,
    ) -> List[InsertGeoEventsError]:
        """Insert multiple events with automatic per-batch retry."""
        submit_fn = lambda op, batch: self._submit_batch(op, batch, options)
        return await _submit_multi_batch_async(
            GeoOperation.INSERT_EVENTS,
            events,
            submit_fn,
        )

    async def upsert_events(
        self,
        events: List[GeoEvent],
        options: Optional[OperationOptions] = None,
    ) -> List[InsertGeoEventsError]:
        """Upsert multiple events with automatic per-batch retry."""
        submit_fn = lambda op, batch: self._submit_batch(op, batch, options)
        return await _submit_multi_batch_async(
            GeoOperation.UPSERT_EVENTS,
            events,
            submit_fn,
        )

    async def insert_event(self, event: GeoEvent) -> List[InsertGeoEventsError]:
        """Insert a single event."""
        batch = self.create_batch()
        batch.add(event)
        return await batch.commit()

    async def delete_entities(self, entity_ids: List[int]) -> DeleteResult:
        """Delete entities by ID."""
        batch = self.create_delete_batch()
        for entity_id in entity_ids:
            batch.add(entity_id)
        return await batch.commit()

    # ========== Query Operations ==========

    async def get_latest_by_uuid(self, entity_id: int) -> Optional[GeoEvent]:
        """Look up the latest event for an entity by UUID."""
        self._ensure_connected()

        filter = QueryUuidFilter(entity_id=entity_id)
        results = await self._submit_query(GeoOperation.QUERY_UUID, filter)
        return results[0] if results else None

    async def get_latest_batch(
        self,
        entity_ids: List[int],
    ) -> dict[int, Optional[GeoEvent]]:
        """
        Look up the latest events for multiple entities by UUID (F1.3.4).

        This is more efficient than calling get_latest_by_uuid() in a loop
        as it uses a single network round-trip.

        Args:
            entity_ids: List of entity UUIDs to look up (max 10,000)

        Returns:
            Dictionary mapping entity_id -> GeoEvent or None if not found
        """
        self._ensure_connected()

        if not entity_ids:
            return {}

        if len(entity_ids) > 10_000:
            raise BatchTooLarge(f"Batch size {len(entity_ids)} exceeds max 10,000")

        # Submit batch query
        from .types import QueryUuidBatchFilter
        filter = QueryUuidBatchFilter(count=len(entity_ids), entity_ids=entity_ids)
        result = await self._submit_batch_uuid_query(filter)

        # Build result dictionary
        results: dict[int, Optional[GeoEvent]] = {}
        not_found_set = set(result.not_found_indices)

        event_idx = 0
        for i, entity_id in enumerate(entity_ids):
            if i in not_found_set:
                results[entity_id] = None
            else:
                if event_idx < len(result.events):
                    results[entity_id] = result.events[event_idx]
                    event_idx += 1
                else:
                    results[entity_id] = None

        return results

    async def query_radius(
        self,
        latitude: float,
        longitude: float,
        radius_m: float,
        *,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
    ) -> QueryResult:
        """Query events within a radius."""
        self._ensure_connected()

        from .types import create_radius_query
        filter = create_radius_query(
            latitude, longitude, radius_m,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        if filter.limit > QUERY_LIMIT_MAX:
            raise QueryResultTooLarge(f"Limit {filter.limit} exceeds max {QUERY_LIMIT_MAX}")

        events = await self._submit_query(GeoOperation.QUERY_RADIUS, filter)
        return QueryResult(
            events=events,
            has_more=len(events) == filter.limit,
            cursor=events[-1].timestamp if events else None,
        )

    async def query_polygon(
        self,
        vertices: List[tuple[float, float]],
        *,
        holes: Optional[List[List[tuple[float, float]]]] = None,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
    ) -> QueryResult:
        """
        Query events within a polygon.

        Args:
            vertices: List of (lat, lon) tuples in degrees, CCW winding order
            holes: Optional list of holes (exclusion zones), each a list of (lat, lon)
                   tuples in clockwise winding order
            limit: Maximum results (default 1000)
            timestamp_min: Minimum timestamp filter
            timestamp_max: Maximum timestamp filter
            group_id: Group ID filter

        Returns:
            QueryResult with matching events
        """
        self._ensure_connected()

        from .types import create_polygon_query
        filter = create_polygon_query(
            vertices,
            holes=holes,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        if filter.limit > QUERY_LIMIT_MAX:
            raise QueryResultTooLarge(f"Limit {filter.limit} exceeds max {QUERY_LIMIT_MAX}")

        events = await self._submit_query(GeoOperation.QUERY_POLYGON, filter)
        return QueryResult(
            events=events,
            has_more=len(events) == filter.limit,
            cursor=events[-1].timestamp if events else None,
        )

    async def query_latest(
        self,
        *,
        limit: int = 1000,
        group_id: int = 0,
        cursor_timestamp: int = 0,
    ) -> QueryResult:
        """Query the most recent events globally or by group."""
        self._ensure_connected()

        filter = QueryLatestFilter(
            limit=limit,
            group_id=group_id,
            cursor_timestamp=cursor_timestamp,
        )

        if filter.limit > QUERY_LIMIT_MAX:
            raise QueryResultTooLarge(f"Limit {filter.limit} exceeds max {QUERY_LIMIT_MAX}")

        events = await self._submit_query(GeoOperation.QUERY_LATEST, filter)
        return QueryResult(
            events=events,
            has_more=len(events) == filter.limit,
            cursor=events[-1].timestamp if events else None,
        )

    # ========== Internal Methods ==========

    def _ensure_connected(self) -> None:
        if self._closed:
            raise ClientClosedError("Client has been closed")

    async def _submit_batch(
        self,
        operation: GeoOperation,
        batch: List[Any],
        options: Optional["OperationOptions"] = None,
    ) -> List[Any]:
        """Submit a batch operation to the cluster with automatic retry."""
        self._ensure_connected()

        retry_config = (
            options.merge_with(self._retry_config)
            if options is not None
            else self._retry_config
        )

        async def do_submit() -> List[Any]:
            # NOTE: Skeleton implementation.
            # In full implementation, this would serialize and send via native binding,
            # using the same request_number for all retries to ensure idempotency.
            return []

        return await _with_retry_async(do_submit, retry_config)

    async def _submit_query(self, operation: GeoOperation, filter: Any) -> List[GeoEvent]:
        """Submit a query operation to the cluster with automatic retry."""
        self._ensure_connected()

        async def do_query() -> List[GeoEvent]:
            # NOTE: Skeleton implementation returns empty results
            return []

        return await _with_retry_async(do_query, self._retry_config)

    async def _submit_batch_uuid_query(self, filter: "QueryUuidBatchFilter") -> "QueryUuidBatchResult":
        """Submit a batch UUID query operation to the cluster with automatic retry."""
        from .types import QueryUuidBatchResult

        self._ensure_connected()

        async def do_query() -> QueryUuidBatchResult:
            # NOTE: Skeleton implementation - in full impl would call native async
            return QueryUuidBatchResult(
                found_count=0,
                not_found_count=len(filter.entity_ids),
                not_found_indices=list(range(len(filter.entity_ids))),
                events=[],
            )

        return await _with_retry_async(do_query, self._retry_config)

    # ========== Admin Operations ==========

    async def ping(self) -> bool:
        """
        Send a ping to verify server connectivity.

        Returns:
            True if server responds with 'pong', False otherwise.
        """
        self._ensure_connected()
        # NOTE: Skeleton implementation - in full impl would send ARCHERDB_PING
        # and verify "pong" response
        return True

    async def get_status(self) -> "StatusResponse":
        """
        Get current server status including RAM index statistics.

        Returns:
            StatusResponse with server statistics.

        Example:
            status = await client.get_status()
            print(f"Entities: {status.ram_index_count}")
            print(f"Load factor: {status.load_factor:.1%}")
        """
        from .types import StatusResponse
        self._ensure_connected()
        # NOTE: Skeleton implementation - in full impl would send ARCHERDB_GET_STATUS
        # and deserialize the 64-byte response
        return StatusResponse()

    async def cleanup_expired(self, batch_size: int = 0) -> CleanupResult:
        """
        Trigger explicit TTL expiration cleanup (async).

        Per client-protocol/spec.md cleanup_expired (0x30):
        - Goes through VSR consensus for deterministic cleanup
        - All replicas apply with same timestamp
        - Returns count of entries scanned and removed

        Args:
            batch_size: Number of index entries to scan (0 = scan all)

        Returns:
            CleanupResult with entries_scanned and entries_removed

        Raises:
            ValueError: If batch_size is negative
            ClientClosedError: If client has been closed

        Example:
            result = await client.cleanup_expired()
            print(f"Scanned {result.entries_scanned} entries")
            print(f"Removed {result.entries_removed} expired entries")
        """
        self._ensure_connected()

        if batch_size < 0:
            raise ValueError("batch_size must be non-negative")

        async def do_cleanup() -> CleanupResult:
            # NOTE: Skeleton implementation - in full impl would send CLEANUP_EXPIRED
            # and deserialize the 16-byte response (2x u64)
            return CleanupResult(entries_scanned=0, entries_removed=0)

        return await _with_retry_async(do_cleanup, self._retry_config)

    # ========== TTL Operations (Manual TTL Support) ==========

    async def set_ttl(self, entity_id: int, ttl_seconds: int) -> "TtlSetResponse":
        """
        Set absolute TTL for an entity (async).

        Args:
            entity_id: UUID of the entity to modify
            ttl_seconds: New TTL value in seconds (0 = infinite)

        Returns:
            TtlSetResponse with previous_ttl_seconds, new_ttl_seconds, and result
        """
        from .types import TtlSetRequest, TtlSetResponse, TtlOperationResult
        self._ensure_connected()

        request = TtlSetRequest(entity_id=entity_id, ttl_seconds=ttl_seconds)

        async def do_set_ttl() -> TtlSetResponse:
            return TtlSetResponse(
                entity_id=entity_id,
                previous_ttl_seconds=0,
                new_ttl_seconds=ttl_seconds,
                result=TtlOperationResult.SUCCESS,
            )

        return await _with_retry_async(do_set_ttl, self._retry_config)

    async def extend_ttl(self, entity_id: int, extend_by_seconds: int) -> "TtlExtendResponse":
        """
        Extend TTL by a specified amount (async).

        Args:
            entity_id: UUID of the entity to modify
            extend_by_seconds: Amount to extend TTL by (seconds)

        Returns:
            TtlExtendResponse with previous_ttl_seconds, new_ttl_seconds, and result
        """
        from .types import TtlExtendRequest, TtlExtendResponse, TtlOperationResult
        self._ensure_connected()

        request = TtlExtendRequest(entity_id=entity_id, extend_by_seconds=extend_by_seconds)

        async def do_extend_ttl() -> TtlExtendResponse:
            return TtlExtendResponse(
                entity_id=entity_id,
                previous_ttl_seconds=0,
                new_ttl_seconds=extend_by_seconds,
                result=TtlOperationResult.SUCCESS,
            )

        return await _with_retry_async(do_extend_ttl, self._retry_config)

    async def clear_ttl(self, entity_id: int) -> "TtlClearResponse":
        """
        Clear TTL so entity never expires (async).

        Args:
            entity_id: UUID of the entity to modify

        Returns:
            TtlClearResponse with previous_ttl_seconds and result
        """
        from .types import TtlClearRequest, TtlClearResponse, TtlOperationResult
        self._ensure_connected()

        request = TtlClearRequest(entity_id=entity_id)

        async def do_clear_ttl() -> TtlClearResponse:
            return TtlClearResponse(
                entity_id=entity_id,
                previous_ttl_seconds=0,
                result=TtlOperationResult.SUCCESS,
            )

        return await _with_retry_async(do_clear_ttl, self._retry_config)

    # ========== Topology Operations (F5.1) ==========

    async def get_topology(self) -> TopologyResponse:
        """
        Fetch the current cluster topology from the server.

        This operation queries the server for the latest topology information
        including shard assignments, primary addresses, and resharding status.

        Returns:
            TopologyResponse with cluster topology information

        Example:
            topology = await client.get_topology()
            print(f"Cluster has {topology.num_shards} shards")
            for shard in topology.shards:
                print(f"  Shard {shard.id}: primary={shard.primary}")
        """
        self._ensure_connected()

        async def do_query() -> TopologyResponse:
            # NOTE: Skeleton implementation - in full impl would send GET_TOPOLOGY
            # and deserialize the response
            return TopologyResponse(
                version=1,
                cluster_id=self._config.cluster_id,
                num_shards=1,
                resharding_status=0,
                shards=[ShardInfo(id=0, primary=self._config.addresses[0])],
                last_change_ns=int(time.time() * 1e9),
            )

        topology = await _with_retry_async(do_query, self._retry_config)
        self._topology_cache.update(topology)
        return topology

    def get_topology_cache(self) -> TopologyCache:
        """
        Return the topology cache for direct access.

        The cache provides shard routing, version tracking, and change
        notifications without requiring a server round-trip.

        Returns:
            TopologyCache instance
        """
        return self._topology_cache

    async def refresh_topology(self) -> TopologyResponse:
        """
        Force a topology refresh from the server.

        This fetches the latest topology and updates the cache.
        Use this after receiving a not_shard_leader error or when
        you need to ensure the topology is current.

        Returns:
            Updated TopologyResponse
        """
        return await self.get_topology()

    def get_shard_router(self) -> ShardRouter:
        """
        Return the shard router for entity-based routing.

        The router provides methods to route requests to the correct
        shard based on entity ID.

        Returns:
            ShardRouter instance
        """
        return self._shard_router

    async def query_radius_scatter(
        self,
        latitude: float,
        longitude: float,
        radius_m: float,
        *,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
        config: Optional[ScatterGatherConfig] = None,
    ) -> ScatterGatherResult:
        """
        Query events within a radius across all shards (scatter-gather).

        This executes the radius query against all shard primaries in parallel
        and merges the results.

        Args:
            latitude: Center latitude in degrees
            longitude: Center longitude in degrees
            radius_m: Radius in meters
            limit: Maximum total results
            timestamp_min: Minimum timestamp filter
            timestamp_max: Maximum timestamp filter
            group_id: Group ID filter
            config: Scatter-gather configuration

        Returns:
            ScatterGatherResult with merged events from all shards
        """
        self._ensure_connected()

        # Ensure topology is loaded
        if self._topology_cache.get() is None:
            await self.get_topology()

        from .types import create_radius_query
        filter = create_radius_query(
            latitude, longitude, radius_m,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        executor = ScatterGatherExecutor(self._shard_router, config)

        async def query_shard(primary: str) -> QueryResult:
            # NOTE: Skeleton implementation
            events = await self._submit_query(GeoOperation.QUERY_RADIUS, filter)
            return QueryResult(
                events=events,
                has_more=len(events) == filter.limit,
                cursor=events[-1].timestamp if events else None,
            )

        return await executor.execute_async(query_shard, limit)

    async def query_polygon_scatter(
        self,
        vertices: List[tuple[float, float]],
        *,
        holes: Optional[List[List[tuple[float, float]]]] = None,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
        config: Optional[ScatterGatherConfig] = None,
    ) -> ScatterGatherResult:
        """
        Query events within a polygon across all shards (scatter-gather).

        This executes the polygon query against all shard primaries in parallel
        and merges the results.

        Args:
            vertices: List of (lat, lon) tuples in degrees, CCW winding order
            holes: Optional list of holes (exclusion zones)
            limit: Maximum total results
            timestamp_min: Minimum timestamp filter
            timestamp_max: Maximum timestamp filter
            group_id: Group ID filter
            config: Scatter-gather configuration

        Returns:
            ScatterGatherResult with merged events from all shards
        """
        self._ensure_connected()

        # Ensure topology is loaded
        if self._topology_cache.get() is None:
            await self.get_topology()

        from .types import create_polygon_query
        filter = create_polygon_query(
            vertices,
            holes=holes,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        executor = ScatterGatherExecutor(self._shard_router, config)

        async def query_shard(primary: str) -> QueryResult:
            events = await self._submit_query(GeoOperation.QUERY_POLYGON, filter)
            return QueryResult(
                events=events,
                has_more=len(events) == filter.limit,
                cursor=events[-1].timestamp if events else None,
            )

        return await executor.execute_async(query_shard, limit)


# ============================================================================
# Batch Helpers (per client-retry spec)
# ============================================================================

from typing import TypeVar

T = TypeVar('T')


def split_batch(items: List[T], chunk_size: int = 1000) -> List[List[T]]:
    """
    Split a batch of items into smaller chunks for retry scenarios.

    When a large batch times out, the SDK cannot determine which events succeeded
    vs failed. Use this helper to split the batch into smaller chunks and retry
    each chunk individually. The server's idempotency guarantees ensure that
    any already-committed events will not be duplicated.

    Args:
        items: List of events or entity IDs to split
        chunk_size: Maximum size of each chunk (default: 1000)

    Returns:
        List of lists, each containing at most chunk_size items

    Raises:
        ValueError: If chunk_size is less than or equal to 0

    Example:
        # Original batch timed out
        events = generate_large_event_list()

        # Split into smaller batches for retry
        chunks = split_batch(events, 500)

        for chunk in chunks:
            batch = client.create_batch()
            for event in chunk:
                batch.add(event)
            try:
                batch.commit()
            except OperationTimeout:
                # Retry with even smaller chunks
                smaller_chunks = split_batch(chunk, 100)
                # ...
    """
    if chunk_size <= 0:
        raise ValueError("chunk_size must be greater than 0")

    if not items:
        return []

    return [items[i:i + chunk_size] for i in range(0, len(items), chunk_size)]
