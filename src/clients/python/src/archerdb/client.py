"""
ArcherDB Python SDK - GeoClient

This module provides synchronous and asynchronous clients for
ArcherDB geospatial operations, following the client-sdk spec.
"""

from __future__ import annotations

import asyncio
import os
import time
from contextlib import contextmanager, asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Iterator, List, Optional, TYPE_CHECKING

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
    BATCH_SIZE_MAX,
    QUERY_LIMIT_MAX,
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


class TLSError(ArcherDBError):
    """TLS handshake or certificate error."""
    code = 1003
    retryable = False


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
class TLSConfig:
    """TLS configuration for secure connections."""
    cert_path: Optional[str] = None  # Client certificate (mTLS)
    key_path: Optional[str] = None   # Client private key
    ca_path: Optional[str] = None    # CA certificate for server validation


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
class GeoClientConfig:
    """Client configuration options."""
    cluster_id: int
    addresses: List[str]
    tls: Optional[TLSConfig] = None
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
    Non-retryable: invalid coordinates, polygon too complex, batch/query too large, TLS errors.
    """
    if isinstance(error, ArcherDBError):
        return error.retryable
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

    start_time = time.time() * 1000  # Convert to ms
    max_attempts = config.max_retries + 1
    last_error: Exception = Exception("No attempts made")

    for attempt in range(1, max_attempts + 1):
        # Check total timeout before starting attempt
        elapsed = (time.time() * 1000) - start_time
        if elapsed >= config.total_timeout_ms:
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

    start_time = time.time() * 1000  # Convert to ms
    max_attempts = config.max_retries + 1
    last_error: Exception = Exception("No attempts made")

    for attempt in range(1, max_attempts + 1):
        # Check total timeout before starting attempt
        elapsed = (time.time() * 1000) - start_time
        if elapsed >= config.total_timeout_ms:
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

    raise RetryExhausted(max_attempts, last_error)


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

        # NOTE: This is a skeleton implementation.
        # In the full implementation, this would initialize the native binding.
        self._connect()

    def _connect(self) -> None:
        """Establish connection to cluster."""
        # Skeleton: mark as connected
        pass

    def close(self) -> None:
        """Close the client and release resources."""
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

        filter = QueryUuidFilter(entity_id=entity_id, limit=1)
        results = self._submit_query(GeoOperation.QUERY_UUID, filter)
        return results[0] if results else None

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

        events = self._submit_query(GeoOperation.QUERY_RADIUS, filter)
        return QueryResult(
            events=events,
            has_more=len(events) == filter.limit,
            cursor=events[-1].timestamp if events else None,
        )

    def query_polygon(
        self,
        vertices: List[tuple[float, float]],
        *,
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
    ) -> QueryResult:
        """Query events within a polygon."""
        self._ensure_connected()

        from .types import create_polygon_query
        filter = create_polygon_query(
            vertices,
            limit=limit,
            timestamp_min=timestamp_min,
            timestamp_max=timestamp_max,
            group_id=group_id,
        )

        if filter.limit > QUERY_LIMIT_MAX:
            raise QueryResultTooLarge(f"Limit {filter.limit} exceeds max {QUERY_LIMIT_MAX}")

        events = self._submit_query(GeoOperation.QUERY_POLYGON, filter)
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

        events = self._submit_query(GeoOperation.QUERY_LATEST, filter)
        return QueryResult(
            events=events,
            has_more=len(events) == filter.limit,
            cursor=events[-1].timestamp if events else None,
        )

    # ========== Internal Methods ==========

    def _ensure_connected(self) -> None:
        if self._closed:
            raise ClientClosedError("Client has been closed")

    def _submit_batch(self, operation: GeoOperation, batch: List[Any]) -> List[Any]:
        """Submit a batch operation to the cluster with automatic retry."""
        self._ensure_connected()

        def do_submit() -> List[Any]:
            # NOTE: Skeleton implementation.
            # In full implementation, this would serialize and send via native binding,
            # using the same request_number for all retries to ensure idempotency.
            return []

        return _with_retry_sync(do_submit, self._retry_config)

    def _submit_query(self, operation: GeoOperation, filter: Any) -> List[GeoEvent]:
        """Submit a query operation to the cluster with automatic retry."""
        self._ensure_connected()

        def do_query() -> List[GeoEvent]:
            # NOTE: Skeleton implementation returns empty results
            return []

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

        filter = QueryUuidFilter(entity_id=entity_id, limit=1)
        results = await self._submit_query(GeoOperation.QUERY_UUID, filter)
        return results[0] if results else None

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
        limit: int = 1000,
        timestamp_min: int = 0,
        timestamp_max: int = 0,
        group_id: int = 0,
    ) -> QueryResult:
        """Query events within a polygon."""
        self._ensure_connected()

        from .types import create_polygon_query
        filter = create_polygon_query(
            vertices,
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

    async def _submit_batch(self, operation: GeoOperation, batch: List[Any]) -> List[Any]:
        """Submit a batch operation to the cluster with automatic retry."""
        self._ensure_connected()

        async def do_submit() -> List[Any]:
            # NOTE: Skeleton implementation.
            # In full implementation, this would serialize and send via native binding,
            # using the same request_number for all retries to ensure idempotency.
            return []

        return await _with_retry_async(do_submit, self._retry_config)

    async def _submit_query(self, operation: GeoOperation, filter: Any) -> List[GeoEvent]:
        """Submit a query operation to the cluster with automatic retry."""
        self._ensure_connected()

        async def do_query() -> List[GeoEvent]:
            # NOTE: Skeleton implementation returns empty results
            return []

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
