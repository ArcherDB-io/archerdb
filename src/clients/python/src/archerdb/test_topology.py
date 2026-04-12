# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""
Unit tests for ArcherDB Python SDK - Topology Support (F5.1)

Tests cover:
- TopologyCache thread safety and caching
- ShardRouter shard computation and routing
- ScatterGatherExecutor parallel query execution
- TopologyResponse parsing
"""

import threading
import time
import struct
import unittest
from unittest.mock import MagicMock, patch

from .topology import (
    TopologyCache,
    ShardRouter,
    ShardRoutingError,
    NotShardLeaderError,
    ScatterGatherExecutor,
    ScatterGatherResult,
    ScatterGatherConfig,
    default_scatter_gather_config,
    merge_results,
)
from .types import (
    GeoEvent,
    QueryResult,
    ShardInfo,
    ShardStatus,
    TopologyResponse,
    TopologyChangeNotification,
    TopologyChangeType,
    MAX_SHARDS,
    MAX_SHARDS_COMPACT,
    MAX_REPLICAS_PER_SHARD,
    MAX_ADDRESS_LEN,
    TOPOLOGY_HEADER_SIZE,
)


class TestShardStatus(unittest.TestCase):
    """Tests for ShardStatus enum."""

    def test_shard_status_values(self):
        """Verify shard status values match spec."""
        self.assertEqual(ShardStatus.ACTIVE, 0)
        self.assertEqual(ShardStatus.SYNCING, 1)
        self.assertEqual(ShardStatus.UNAVAILABLE, 2)
        self.assertEqual(ShardStatus.MIGRATING, 3)
        self.assertEqual(ShardStatus.DECOMMISSIONING, 4)


class TestTopologyChangeType(unittest.TestCase):
    """Tests for TopologyChangeType enum."""

    def test_topology_change_type_values(self):
        """Verify topology change type values match spec."""
        self.assertEqual(TopologyChangeType.LEADER_CHANGE, 0)
        self.assertEqual(TopologyChangeType.REPLICA_ADDED, 1)
        self.assertEqual(TopologyChangeType.REPLICA_REMOVED, 2)
        self.assertEqual(TopologyChangeType.RESHARDING_STARTED, 3)
        self.assertEqual(TopologyChangeType.RESHARDING_COMPLETED, 4)
        self.assertEqual(TopologyChangeType.STATUS_CHANGE, 5)


class TestShardInfo(unittest.TestCase):
    """Tests for ShardInfo dataclass."""

    def test_default_values(self):
        """Test default values for ShardInfo."""
        shard = ShardInfo()
        self.assertEqual(shard.id, 0)
        self.assertEqual(shard.primary, "")
        self.assertEqual(shard.replicas, [])
        self.assertEqual(shard.status, ShardStatus.ACTIVE)
        self.assertEqual(shard.entity_count, 0)
        self.assertEqual(shard.size_bytes, 0)

    def test_custom_values(self):
        """Test ShardInfo with custom values."""
        shard = ShardInfo(
            id=5,
            primary="192.168.1.1:3001",
            replicas=["192.168.1.2:3001", "192.168.1.3:3001"],
            status=ShardStatus.SYNCING,
            entity_count=1000000,
            size_bytes=1024 * 1024 * 100,
        )
        self.assertEqual(shard.id, 5)
        self.assertEqual(shard.primary, "192.168.1.1:3001")
        self.assertEqual(len(shard.replicas), 2)
        self.assertEqual(shard.status, ShardStatus.SYNCING)


class TestTopologyResponse(unittest.TestCase):
    """Tests for TopologyResponse dataclass."""

    def test_default_values(self):
        """Test default values for TopologyResponse."""
        topology = TopologyResponse()
        self.assertEqual(topology.version, 0)
        self.assertEqual(topology.cluster_id, 0)
        self.assertEqual(topology.num_shards, 0)
        self.assertEqual(topology.resharding_status, 0)
        self.assertEqual(topology.shards, [])
        self.assertEqual(topology.last_change_ns, 0)

    def test_with_shards(self):
        """Test TopologyResponse with shards."""
        shards = [
            ShardInfo(id=0, primary="node1:3001"),
            ShardInfo(id=1, primary="node2:3001"),
        ]
        topology = TopologyResponse(
            version=42,
            cluster_id=12345,
            num_shards=2,
            resharding_status=0,
            shards=shards,
        )
        self.assertEqual(topology.version, 42)
        self.assertEqual(topology.num_shards, 2)
        self.assertEqual(len(topology.shards), 2)

    def test_from_bytes_parses_compact_topology_layout(self):
        """Compact topology responses include a padded 64-byte header."""
        shard_info_size = 472
        payload = bytearray(TOPOLOGY_HEADER_SIZE + (MAX_SHARDS_COMPACT * shard_info_size))

        struct.pack_into("<Q", payload, 0, 8)
        struct.pack_into("<I", payload, 8, 1)
        struct.pack_into("<Q", payload, 12, 0x1234)
        struct.pack_into("<Q", payload, 20, 0)
        struct.pack_into("<Q", payload, 28, 0)
        struct.pack_into("<Q", payload, 36, 0)
        payload[44] = 0
        payload[45] = 0

        shard_offset = TOPOLOGY_HEADER_SIZE
        struct.pack_into("<I", payload, shard_offset, 0)
        shard_offset += 4

        primary = b"127.0.0.1:3402"
        payload[shard_offset:shard_offset + len(primary)] = primary
        shard_offset += MAX_ADDRESS_LEN

        replica0 = b"127.0.0.1:3401"
        payload[shard_offset:shard_offset + len(replica0)] = replica0
        shard_offset += MAX_ADDRESS_LEN

        replica1 = b"127.0.0.1:3403"
        payload[shard_offset:shard_offset + len(replica1)] = replica1
        shard_offset += MAX_ADDRESS_LEN

        shard_offset += MAX_ADDRESS_LEN * (MAX_REPLICAS_PER_SHARD - 2)
        payload[shard_offset] = 2
        payload[shard_offset + 1] = ShardStatus.ACTIVE
        struct.pack_into("<Q", payload, shard_offset + 4, 0)
        struct.pack_into("<Q", payload, shard_offset + 12, 0)

        topology = TopologyResponse.from_bytes(bytes(payload))

        self.assertEqual(topology.version, 8)
        self.assertEqual(topology.cluster_id, 0x1234)
        self.assertEqual(topology.num_shards, 1)
        self.assertEqual(len(topology.shards), 1)
        self.assertEqual(topology.shards[0].primary, "127.0.0.1:3402")
        self.assertEqual(
            topology.shards[0].replicas,
            ["127.0.0.1:3401", "127.0.0.1:3403"],
        )


class TestTopologyCache(unittest.TestCase):
    """Tests for TopologyCache thread-safe caching."""

    def test_initial_state(self):
        """Test initial cache state."""
        cache = TopologyCache()
        self.assertIsNone(cache.get())
        self.assertEqual(cache.get_version(), 0)
        self.assertEqual(cache.refresh_count(), 0)
        self.assertFalse(cache.is_resharding())
        self.assertEqual(cache.get_shard_count(), 0)

    def test_update_topology(self):
        """Test updating topology cache."""
        cache = TopologyCache()
        topology = TopologyResponse(
            version=1,
            num_shards=4,
            shards=[ShardInfo(id=i, primary=f"node{i}:3001") for i in range(4)],
        )
        cache.update(topology)

        self.assertEqual(cache.get_version(), 1)
        self.assertEqual(cache.get_shard_count(), 4)
        self.assertEqual(cache.refresh_count(), 1)
        self.assertIsNotNone(cache.get())

    def test_compute_shard(self):
        """Test shard computation from entity ID."""
        cache = TopologyCache()
        topology = TopologyResponse(
            version=1,
            num_shards=4,
            shards=[ShardInfo(id=i, primary=f"node{i}:3001") for i in range(4)],
        )
        cache.update(topology)

        # Test shard computation - should be consistent
        entity_id = 0x123456789ABCDEF0123456789ABCDEF0
        shard1 = cache.compute_shard(entity_id)
        shard2 = cache.compute_shard(entity_id)
        self.assertEqual(shard1, shard2)
        self.assertLess(shard1, 4)  # Should be in range

    def test_compute_shard_empty_topology(self):
        """Test shard computation with empty topology returns 0."""
        cache = TopologyCache()
        entity_id = 0x123456789ABCDEF0123456789ABCDEF0
        self.assertEqual(cache.compute_shard(entity_id), 0)

    def test_get_shard_primary(self):
        """Test getting shard primary address."""
        cache = TopologyCache()
        topology = TopologyResponse(
            version=1,
            num_shards=2,
            shards=[
                ShardInfo(id=0, primary="node0:3001"),
                ShardInfo(id=1, primary="node1:3001"),
            ],
        )
        cache.update(topology)

        self.assertEqual(cache.get_shard_primary(0), "node0:3001")
        self.assertEqual(cache.get_shard_primary(1), "node1:3001")
        self.assertEqual(cache.get_shard_primary(99), "")  # Invalid shard

    def test_get_all_shard_primaries(self):
        """Test getting all shard primaries."""
        cache = TopologyCache()
        topology = TopologyResponse(
            version=1,
            num_shards=3,
            shards=[ShardInfo(id=i, primary=f"node{i}:3001") for i in range(3)],
        )
        cache.update(topology)

        primaries = cache.get_all_shard_primaries()
        self.assertEqual(len(primaries), 3)
        self.assertEqual(primaries[0], "node0:3001")

    def test_is_resharding(self):
        """Test resharding status detection."""
        cache = TopologyCache()

        # No resharding
        topology = TopologyResponse(version=1, num_shards=2, resharding_status=0)
        cache.update(topology)
        self.assertFalse(cache.is_resharding())

        # Resharding in progress (status 1-3)
        for status in [1, 2, 3]:
            topology = TopologyResponse(version=2, num_shards=2, resharding_status=status)
            cache.update(topology)
            self.assertTrue(cache.is_resharding())

    def test_get_active_shards(self):
        """Test getting active shard IDs."""
        cache = TopologyCache()
        topology = TopologyResponse(
            version=1,
            num_shards=4,
            shards=[
                ShardInfo(id=0, status=ShardStatus.ACTIVE),
                ShardInfo(id=1, status=ShardStatus.SYNCING),
                ShardInfo(id=2, status=ShardStatus.ACTIVE),
                ShardInfo(id=3, status=ShardStatus.UNAVAILABLE),
            ],
        )
        cache.update(topology)

        active = cache.get_active_shards()
        self.assertEqual(set(active), {0, 2})

    def test_invalidate(self):
        """Test cache invalidation."""
        cache = TopologyCache()
        topology = TopologyResponse(version=5, num_shards=2)
        cache.update(topology)
        self.assertEqual(cache.get_version(), 5)

        cache.invalidate()
        self.assertEqual(cache.get_version(), 0)

    def test_on_change_callback(self):
        """Test topology change callbacks."""
        cache = TopologyCache()
        notifications = []

        def callback(notification):
            notifications.append(notification)

        unregister = cache.on_change(callback)

        # First update (no notification - old version is 0)
        cache.update(TopologyResponse(version=1, num_shards=2))
        time.sleep(0.1)  # Wait for async callback
        self.assertEqual(len(notifications), 0)

        # Second update (should notify)
        cache.update(TopologyResponse(version=2, num_shards=2))
        time.sleep(0.1)  # Wait for async callback
        self.assertEqual(len(notifications), 1)
        self.assertEqual(notifications[0].old_version, 1)
        self.assertEqual(notifications[0].new_version, 2)

        # Unregister and verify no more notifications
        unregister()
        cache.update(TopologyResponse(version=3, num_shards=2))
        time.sleep(0.1)
        self.assertEqual(len(notifications), 1)

    def test_thread_safety(self):
        """Test thread-safe access to topology cache."""
        cache = TopologyCache()
        errors = []
        iterations = 100

        def reader():
            try:
                for _ in range(iterations):
                    cache.get()
                    cache.get_version()
                    cache.compute_shard(12345)
            except Exception as e:
                errors.append(e)

        def writer():
            try:
                for i in range(iterations):
                    cache.update(TopologyResponse(version=i, num_shards=4))
            except Exception as e:
                errors.append(e)

        threads = [
            threading.Thread(target=reader),
            threading.Thread(target=reader),
            threading.Thread(target=writer),
        ]

        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(len(errors), 0)


class TestShardRouter(unittest.TestCase):
    """Tests for ShardRouter."""

    def setUp(self):
        """Set up test fixtures."""
        self.cache = TopologyCache()
        self.cache.update(TopologyResponse(
            version=1,
            num_shards=4,
            shards=[ShardInfo(id=i, primary=f"node{i}:3001") for i in range(4)],
        ))
        self.refresh_called = False

        def refresh():
            self.refresh_called = True

        self.router = ShardRouter(self.cache, refresh_callback=refresh)

    def test_route_by_entity_id(self):
        """Test routing by entity ID."""
        entity_id = 0x123456789ABCDEF0
        shard_id, primary = self.router.route_by_entity_id(entity_id)

        self.assertLess(shard_id, 4)
        self.assertTrue(primary.startswith("node"))
        self.assertTrue(primary.endswith(":3001"))

    def test_route_by_entity_id_no_primary(self):
        """Test routing error when no primary available."""
        # Create cache with empty primary
        cache = TopologyCache()
        cache.update(TopologyResponse(
            version=1,
            num_shards=1,
            shards=[ShardInfo(id=0, primary="")],
        ))
        router = ShardRouter(cache)

        with self.assertRaises(ShardRoutingError) as ctx:
            router.route_by_entity_id(12345)
        self.assertIn("no primary", str(ctx.exception))

    def test_handle_not_shard_leader(self):
        """Test handling not_shard_leader error."""
        # Test with NotShardLeaderError
        error = NotShardLeaderError(shard_id=2, leader_hint="node3:3001")
        result = self.router.handle_not_shard_leader(error)
        self.assertTrue(result)
        self.assertTrue(self.refresh_called)

        # Test with other error types
        self.refresh_called = False
        result = self.router.handle_not_shard_leader(ValueError("other error"))
        self.assertFalse(result)
        self.assertFalse(self.refresh_called)

    def test_get_all_primaries(self):
        """Test getting all primaries for scatter-gather."""
        primaries = self.router.get_all_primaries()
        self.assertEqual(len(primaries), 4)


class TestNotShardLeaderError(unittest.TestCase):
    """Tests for NotShardLeaderError."""

    def test_error_with_hint(self):
        """Test error message with leader hint."""
        error = NotShardLeaderError(shard_id=5, leader_hint="node5:3001")
        self.assertEqual(error.shard_id, 5)
        self.assertEqual(error.leader_hint, "node5:3001")
        self.assertIn("hint", str(error))

    def test_error_without_hint(self):
        """Test error message without leader hint."""
        error = NotShardLeaderError(shard_id=5)
        self.assertIn("shard 5", str(error))


class TestShardRoutingError(unittest.TestCase):
    """Tests for ShardRoutingError."""

    def test_error_properties(self):
        """Test error properties."""
        error = ShardRoutingError(shard_id=3, message="test error")
        self.assertEqual(error.shard_id, 3)
        self.assertIn("test error", str(error))


class TestScatterGatherConfig(unittest.TestCase):
    """Tests for ScatterGatherConfig."""

    def test_default_config(self):
        """Test default scatter-gather configuration."""
        config = default_scatter_gather_config()
        self.assertEqual(config.max_concurrency, 0)  # Unlimited
        self.assertTrue(config.allow_partial_results)
        self.assertEqual(config.timeout_seconds, 30.0)

    def test_custom_config(self):
        """Test custom configuration."""
        config = ScatterGatherConfig(
            max_concurrency=10,
            allow_partial_results=False,
            timeout_seconds=5.0,
        )
        self.assertEqual(config.max_concurrency, 10)
        self.assertFalse(config.allow_partial_results)
        self.assertEqual(config.timeout_seconds, 5.0)


class TestMergeResults(unittest.TestCase):
    """Tests for merge_results function."""

    def test_merge_empty_results(self):
        """Test merging empty results."""
        result = merge_results([], limit=100)
        self.assertEqual(len(result.events), 0)
        self.assertFalse(result.has_more)

    def test_merge_single_result(self):
        """Test merging single result set."""
        events = [
            GeoEvent(entity_id=1, timestamp=1000),
            GeoEvent(entity_id=2, timestamp=2000),
        ]
        results = [QueryResult(events=events, has_more=False)]

        merged = merge_results(results, limit=0)
        self.assertEqual(len(merged.events), 2)
        # Should be sorted by timestamp descending
        self.assertEqual(merged.events[0].timestamp, 2000)
        self.assertEqual(merged.events[1].timestamp, 1000)

    def test_merge_deduplicates_by_entity_id(self):
        """Test that merge deduplicates by entity ID, keeping latest."""
        # Same entity with different timestamps
        result1 = QueryResult(events=[GeoEvent(entity_id=1, timestamp=1000)])
        result2 = QueryResult(events=[GeoEvent(entity_id=1, timestamp=2000)])

        merged = merge_results([result1, result2], limit=0)
        self.assertEqual(len(merged.events), 1)
        self.assertEqual(merged.events[0].timestamp, 2000)  # Latest kept

    def test_merge_respects_limit(self):
        """Test that merge respects limit."""
        events = [GeoEvent(entity_id=i, timestamp=i * 1000) for i in range(10)]
        results = [QueryResult(events=events, has_more=False)]

        merged = merge_results(results, limit=5)
        self.assertEqual(len(merged.events), 5)
        self.assertTrue(merged.has_more)

    def test_merge_tracks_shard_results(self):
        """Test that merge tracks per-shard result counts."""
        results = [
            QueryResult(events=[GeoEvent(entity_id=1)], has_more=False),
            QueryResult(events=[GeoEvent(entity_id=2), GeoEvent(entity_id=3)], has_more=True),
        ]

        merged = merge_results(results, limit=0)
        self.assertEqual(merged.shard_results[0], 1)
        self.assertEqual(merged.shard_results[1], 2)
        self.assertTrue(merged.has_more)


class TestScatterGatherResult(unittest.TestCase):
    """Tests for ScatterGatherResult dataclass."""

    def test_default_values(self):
        """Test default values."""
        result = ScatterGatherResult()
        self.assertEqual(result.events, [])
        self.assertEqual(result.shard_results, {})
        self.assertEqual(result.partial_failures, {})
        self.assertFalse(result.has_more)


class TestConstants(unittest.TestCase):
    """Tests for topology constants."""

    def test_max_shards(self):
        """Test MAX_SHARDS constant matches spec."""
        self.assertEqual(MAX_SHARDS, 256)

    def test_max_replicas_per_shard(self):
        """Test MAX_REPLICAS_PER_SHARD constant matches spec."""
        self.assertEqual(MAX_REPLICAS_PER_SHARD, 6)


if __name__ == "__main__":
    unittest.main()
