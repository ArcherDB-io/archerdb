# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""
ArcherDB Python SDK - Topology Management

This module provides topology caching, shard routing, and scatter-gather
query support for distributed ArcherDB clusters.
"""

from __future__ import annotations

import asyncio
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple, TYPE_CHECKING

from .types import (
    GeoEvent,
    QueryResult,
    ShardInfo,
    ShardStatus,
    TopologyResponse,
    TopologyChangeNotification,
    TopologyChangeType,
)

if TYPE_CHECKING:
    from .client import GeoClientSync, GeoClientAsync


# ============================================================================
# Errors
# ============================================================================

class ShardRoutingError(Exception):
    """Error during shard routing."""

    def __init__(self, shard_id: int, message: str) -> None:
        super().__init__(message)
        self.shard_id = shard_id


class NotShardLeaderError(Exception):
    """Request was sent to a non-leader node."""

    def __init__(self, shard_id: int, leader_hint: str = "") -> None:
        self.shard_id = shard_id
        self.leader_hint = leader_hint
        msg = f"not shard leader, hint: {leader_hint}" if leader_hint else f"not shard leader for shard {shard_id}"
        super().__init__(msg)


# ============================================================================
# Topology Cache (F5.1.2 Topology Caching)
# ============================================================================

TopologyChangeCallback = Callable[[TopologyChangeNotification], None]


class TopologyCache:
    """
    Thread-safe cache for cluster topology information.

    The cache stores the current topology and notifies registered callbacks
    when the topology changes. This enables smart clients to route requests
    to the correct shard without querying the cluster on every operation.

    Example:
        cache = TopologyCache()

        # Register callback for topology changes
        def on_change(notification):
            print(f"Topology changed: v{notification.old_version} -> v{notification.new_version}")
        unregister = cache.on_change(on_change)

        # Update cache with new topology
        cache.update(topology_response)

        # Get current topology
        topology = cache.get()

        # Compute shard for entity
        shard_id = cache.compute_shard(entity_id)
    """

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._topology: Optional[TopologyResponse] = None
        self._version: int = 0
        self._last_refresh: float = 0.0
        self._refresh_count: int = 0
        self._callbacks: List[Optional[TopologyChangeCallback]] = []

    def get(self) -> Optional[TopologyResponse]:
        """Return the cached topology (may be None if not yet fetched)."""
        with self._lock:
            return self._topology

    def get_version(self) -> int:
        """Return the current cached topology version."""
        with self._lock:
            return self._version

    def update(self, topology: TopologyResponse) -> None:
        """
        Update the cached topology and notify subscribers if version changed.

        Args:
            topology: New topology response from server
        """
        with self._lock:
            old_version = self._version
            self._topology = topology
            self._version = topology.version
            self._last_refresh = time.time()
            self._refresh_count += 1

            # Notify subscribers if version changed
            if topology.version != old_version and old_version != 0:
                notification = TopologyChangeNotification(
                    new_version=topology.version,
                    old_version=old_version,
                    timestamp_ns=int(time.time() * 1e9),
                )
                # Call callbacks outside lock to prevent deadlock
                callbacks = [cb for cb in self._callbacks if cb is not None]

        # Notify outside lock
        if topology.version != old_version and old_version != 0:
            for callback in callbacks:
                try:
                    # Run callback in separate thread to avoid blocking
                    threading.Thread(target=callback, args=(notification,), daemon=True).start()
                except Exception:
                    pass  # Ignore callback errors

    def invalidate(self) -> None:
        """Mark the cache as stale, forcing a refresh on next access."""
        with self._lock:
            self._version = 0

    def last_refresh(self) -> float:
        """Return the time of the last topology refresh (seconds since epoch)."""
        with self._lock:
            return self._last_refresh

    def refresh_count(self) -> int:
        """Return the number of times the cache has been refreshed."""
        with self._lock:
            return self._refresh_count

    def on_change(self, callback: TopologyChangeCallback) -> Callable[[], None]:
        """
        Register a callback to be invoked when topology changes.

        Args:
            callback: Function to call with TopologyChangeNotification

        Returns:
            Function to unregister the callback
        """
        with self._lock:
            self._callbacks.append(callback)
            idx = len(self._callbacks) - 1

        def unregister() -> None:
            with self._lock:
                if idx < len(self._callbacks):
                    self._callbacks[idx] = None

        return unregister

    def compute_shard(self, entity_id: int) -> int:
        """
        Compute the shard ID for a given entity ID.

        Uses consistent hashing: shard = hash(entity_id) % num_shards
        The entity_id is a 128-bit integer; we XOR-fold to 64-bit for hashing.

        Args:
            entity_id: 128-bit entity identifier

        Returns:
            Shard ID (0 to num_shards-1)
        """
        with self._lock:
            if self._topology is None or self._topology.num_shards == 0:
                return 0

            # XOR-fold 128-bit to 64-bit
            lo = entity_id & 0xFFFFFFFFFFFFFFFF
            hi = (entity_id >> 64) & 0xFFFFFFFFFFFFFFFF
            hash_val = lo ^ hi

            return int(hash_val % self._topology.num_shards)

    def get_shard_primary(self, shard_id: int) -> str:
        """
        Return the primary address for a given shard.

        Args:
            shard_id: Shard identifier

        Returns:
            Primary node address, or empty string if not found
        """
        with self._lock:
            if self._topology is None or shard_id >= len(self._topology.shards):
                return ""
            return self._topology.shards[shard_id].primary

    def get_all_shard_primaries(self) -> List[str]:
        """Return addresses of all shard primaries."""
        with self._lock:
            if self._topology is None:
                return []
            return [shard.primary for shard in self._topology.shards]

    def is_resharding(self) -> bool:
        """Return True if the cluster is currently resharding."""
        with self._lock:
            return self._topology is not None and self._topology.resharding_status != 0

    def get_active_shards(self) -> List[int]:
        """Return the list of active shard IDs."""
        with self._lock:
            if self._topology is None:
                return []
            return [
                shard.id for shard in self._topology.shards
                if shard.status == ShardStatus.ACTIVE
            ]

    def get_shard_count(self) -> int:
        """Return the number of shards in the cluster."""
        with self._lock:
            if self._topology is None:
                return 0
            return self._topology.num_shards


# ============================================================================
# Shard Router (F5.1.4 Shard-Aware Routing)
# ============================================================================

class ShardRouter:
    """
    Shard-aware request router.

    Routes requests to the correct shard based on entity ID, and handles
    not_shard_leader errors by refreshing topology and retrying.

    Example:
        router = ShardRouter(cache, refresh_callback=client.refresh_topology)

        # Route by entity ID
        shard_id, primary = router.route_by_entity_id(entity_id)

        # Handle leader errors
        if router.handle_not_shard_leader(error):
            # Retry the request
            pass
    """

    def __init__(
        self,
        cache: TopologyCache,
        refresh_callback: Optional[Callable[[], None]] = None,
    ) -> None:
        """
        Initialize the shard router.

        Args:
            cache: Topology cache for shard lookups
            refresh_callback: Function to call when topology refresh is needed
        """
        self._cache = cache
        self._refresh_callback = refresh_callback

    def route_by_entity_id(self, entity_id: int) -> Tuple[int, str]:
        """
        Route a request to the correct shard based on entity ID.

        Args:
            entity_id: 128-bit entity identifier

        Returns:
            Tuple of (shard_id, primary_address)

        Raises:
            ShardRoutingError: If no primary address available for shard
        """
        shard_id = self._cache.compute_shard(entity_id)
        primary = self._cache.get_shard_primary(shard_id)

        if not primary:
            raise ShardRoutingError(shard_id, "no primary address for shard")

        return shard_id, primary

    def handle_not_shard_leader(self, error: Exception) -> bool:
        """
        Handle a not_shard_leader error by refreshing topology.

        Args:
            error: The error to check

        Returns:
            True if topology was refreshed and retry should be attempted
        """
        if isinstance(error, NotShardLeaderError):
            if self._refresh_callback is not None:
                try:
                    self._refresh_callback()
                    return True
                except Exception:
                    pass
        return False

    def get_all_primaries(self) -> List[str]:
        """Return addresses of all shard primaries for scatter-gather queries."""
        return self._cache.get_all_shard_primaries()


# ============================================================================
# Scatter-Gather Query Support (F5.1.5)
# ============================================================================

@dataclass
class ScatterGatherResult:
    """Results from a scatter-gather query across all shards."""
    events: List[GeoEvent] = field(default_factory=list)
    shard_results: Dict[int, int] = field(default_factory=dict)  # shard_id -> result count
    partial_failures: Dict[int, Exception] = field(default_factory=dict)  # shard_id -> error
    has_more: bool = False


@dataclass
class ScatterGatherConfig:
    """Configuration for scatter-gather query behavior."""
    max_concurrency: int = 0        # 0 = unlimited
    allow_partial_results: bool = True
    timeout_seconds: float = 30.0


def default_scatter_gather_config() -> ScatterGatherConfig:
    """Return sensible defaults for scatter-gather queries."""
    return ScatterGatherConfig(
        max_concurrency=0,
        allow_partial_results=True,
        timeout_seconds=30.0,
    )


def merge_results(results: List[QueryResult], limit: int = 0) -> ScatterGatherResult:
    """
    Merge results from multiple shards.

    Deduplicates by entity ID (keeping most recent) and applies limit.

    Args:
        results: Query results from each shard
        limit: Maximum results to return (0 = unlimited)

    Returns:
        Merged scatter-gather result
    """
    # Use dict to deduplicate by entity ID
    seen: Dict[int, GeoEvent] = {}
    shard_results: Dict[int, int] = {}
    has_more = False

    for i, result in enumerate(results):
        shard_results[i] = len(result.events)
        if result.has_more:
            has_more = True

        for event in result.events:
            # Keep the most recent event for each entity
            existing = seen.get(event.entity_id)
            if existing is None or event.timestamp > existing.timestamp:
                seen[event.entity_id] = event

    # Sort by timestamp descending (most recent first)
    events = sorted(seen.values(), key=lambda e: e.timestamp, reverse=True)

    # Apply limit
    if limit > 0 and len(events) > limit:
        events = events[:limit]
        has_more = True

    return ScatterGatherResult(
        events=events,
        shard_results=shard_results,
        has_more=has_more,
    )


class ScatterGatherExecutor:
    """
    Executes queries across all shards in parallel.

    Example:
        executor = ScatterGatherExecutor(router, config)

        # Execute radius query across all shards
        result = executor.execute_radius_query(
            clients,
            latitude=37.7749,
            longitude=-122.4194,
            radius_m=1000,
        )
    """

    def __init__(
        self,
        router: ShardRouter,
        config: Optional[ScatterGatherConfig] = None,
    ) -> None:
        self._router = router
        self._config = config or default_scatter_gather_config()

    def execute_sync(
        self,
        query_func: Callable[[str], QueryResult],
        limit: int = 0,
    ) -> ScatterGatherResult:
        """
        Execute a query function against all shards in parallel (sync).

        Args:
            query_func: Function that takes a shard primary address and returns QueryResult
            limit: Maximum total results to return

        Returns:
            Merged results from all shards
        """
        primaries = self._router.get_all_primaries()
        if not primaries:
            return ScatterGatherResult()

        results: List[QueryResult] = []
        partial_failures: Dict[int, Exception] = {}

        max_workers = self._config.max_concurrency or len(primaries)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            future_to_shard = {
                executor.submit(query_func, primary): i
                for i, primary in enumerate(primaries)
            }

            for future in as_completed(future_to_shard, timeout=self._config.timeout_seconds):
                shard_id = future_to_shard[future]
                try:
                    result = future.result()
                    results.append(result)
                except Exception as e:
                    partial_failures[shard_id] = e
                    if not self._config.allow_partial_results:
                        raise

        merged = merge_results(results, limit)
        merged.partial_failures = partial_failures
        return merged

    async def execute_async(
        self,
        query_func: Callable[[str], Any],  # Async function
        limit: int = 0,
    ) -> ScatterGatherResult:
        """
        Execute a query function against all shards in parallel (async).

        Args:
            query_func: Async function that takes a shard primary address and returns QueryResult
            limit: Maximum total results to return

        Returns:
            Merged results from all shards
        """
        primaries = self._router.get_all_primaries()
        if not primaries:
            return ScatterGatherResult()

        results: List[QueryResult] = []
        partial_failures: Dict[int, Exception] = {}

        # Create tasks for all primaries
        tasks = [
            asyncio.create_task(query_func(primary))
            for primary in primaries
        ]

        # Wait for all tasks with timeout
        try:
            done, pending = await asyncio.wait(
                tasks,
                timeout=self._config.timeout_seconds,
                return_when=asyncio.ALL_COMPLETED,
            )

            # Cancel any pending tasks
            for task in pending:
                task.cancel()

            # Collect results
            for i, task in enumerate(tasks):
                if task in done:
                    try:
                        result = task.result()
                        results.append(result)
                    except Exception as e:
                        partial_failures[i] = e
                        if not self._config.allow_partial_results:
                            raise
                else:
                    partial_failures[i] = TimeoutError("Shard query timed out")

        except asyncio.TimeoutError:
            if not self._config.allow_partial_results:
                raise

        merged = merge_results(results, limit)
        merged.partial_failures = partial_failures
        return merged
