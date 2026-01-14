package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import org.junit.jupiter.api.Test;

/**
 * Tests for topology support (F5.1 Smart Client Topology Discovery).
 */
class TopologyTest {

    // ============================================================================
    // ShardStatus Tests
    // ============================================================================

    @Test
    void shardStatus_fromCode() {
        assertEquals(ShardStatus.ACTIVE, ShardStatus.fromCode(0));
        assertEquals(ShardStatus.SYNCING, ShardStatus.fromCode(1));
        assertEquals(ShardStatus.UNAVAILABLE, ShardStatus.fromCode(2));
        assertEquals(ShardStatus.MIGRATING, ShardStatus.fromCode(3));
        assertEquals(ShardStatus.DECOMMISSIONING, ShardStatus.fromCode(4));
    }

    @Test
    void shardStatus_invalidCode() {
        assertThrows(IllegalArgumentException.class, () -> ShardStatus.fromCode(99));
    }

    @Test
    void shardStatus_readWriteCapabilities() {
        assertTrue(ShardStatus.ACTIVE.isReadable());
        assertTrue(ShardStatus.ACTIVE.isWritable());

        assertTrue(ShardStatus.SYNCING.isReadable());
        assertFalse(ShardStatus.SYNCING.isWritable());

        assertFalse(ShardStatus.UNAVAILABLE.isReadable());
        assertFalse(ShardStatus.UNAVAILABLE.isWritable());
    }

    // ============================================================================
    // TopologyChangeType Tests
    // ============================================================================

    @Test
    void topologyChangeType_fromCode() {
        assertEquals(TopologyChangeType.LEADER_CHANGE, TopologyChangeType.fromCode(0));
        assertEquals(TopologyChangeType.REPLICA_ADDED, TopologyChangeType.fromCode(1));
        assertEquals(TopologyChangeType.REPLICA_REMOVED, TopologyChangeType.fromCode(2));
        assertEquals(TopologyChangeType.RESHARDING_STARTED, TopologyChangeType.fromCode(3));
        assertEquals(TopologyChangeType.RESHARDING_COMPLETED, TopologyChangeType.fromCode(4));
        assertEquals(TopologyChangeType.STATUS_CHANGE, TopologyChangeType.fromCode(5));
    }

    @Test
    void topologyChangeType_invalidCode() {
        assertThrows(IllegalArgumentException.class, () -> TopologyChangeType.fromCode(99));
    }

    // ============================================================================
    // ShardInfo Tests
    // ============================================================================

    @Test
    void shardInfo_creation() {
        ShardInfo shard = new ShardInfo(0, "node1:8080", Arrays.asList("node2:8080", "node3:8080"),
                ShardStatus.ACTIVE, 1000L, 2048L);

        assertEquals(0, shard.getId());
        assertEquals("node1:8080", shard.getPrimary());
        assertEquals(2, shard.getReplicas().size());
        assertEquals(ShardStatus.ACTIVE, shard.getStatus());
        assertEquals(1000L, shard.getEntityCount());
        assertEquals(2048L, shard.getSizeBytes());
    }

    @Test
    void shardInfo_minimal() {
        ShardInfo shard = new ShardInfo(1, "node1:8080", ShardStatus.SYNCING);

        assertEquals(1, shard.getId());
        assertEquals("node1:8080", shard.getPrimary());
        assertTrue(shard.getReplicas().isEmpty());
        assertEquals(ShardStatus.SYNCING, shard.getStatus());
    }

    @Test
    void shardInfo_immutableReplicas() {
        List<String> replicas = new ArrayList<>(Arrays.asList("node2:8080"));
        ShardInfo shard = new ShardInfo(0, "node1:8080", replicas, ShardStatus.ACTIVE, 0, 0);

        assertThrows(UnsupportedOperationException.class,
                () -> shard.getReplicas().add("node3:8080"));
    }

    // ============================================================================
    // TopologyResponse Tests
    // ============================================================================

    @Test
    void topologyResponse_creation() {
        List<ShardInfo> shards = Arrays.asList(new ShardInfo(0, "node1:8080", ShardStatus.ACTIVE),
                new ShardInfo(1, "node2:8080", ShardStatus.ACTIVE));

        TopologyResponse response =
                new TopologyResponse(1L, UInt128.of(12345L), 2, 0, shards, System.nanoTime());

        assertEquals(1L, response.getVersion());
        assertEquals(UInt128.of(12345L), response.getClusterId());
        assertEquals(2, response.getNumShards());
        assertEquals(0, response.getReshardingStatus());
        assertFalse(response.isResharding());
        assertEquals(2, response.getShards().size());
    }

    @Test
    void topologyResponse_resharding() {
        TopologyResponse response =
                new TopologyResponse(2L, UInt128.of(1L), 4, 2, Collections.emptyList(), 0L);

        assertTrue(response.isResharding());
        assertEquals(2, response.getReshardingStatus());
    }

    @Test
    void topologyResponse_getShard() {
        List<ShardInfo> shards = Arrays.asList(new ShardInfo(0, "node1:8080", ShardStatus.ACTIVE),
                new ShardInfo(1, "node2:8080", ShardStatus.SYNCING));

        TopologyResponse response = new TopologyResponse(1L, UInt128.of(1L), 2, 0, shards, 0L);

        assertNotNull(response.getShard(0));
        assertEquals("node1:8080", response.getShard(0).getPrimary());
        assertEquals("node2:8080", response.getShard(1).getPrimary());
        assertNull(response.getShard(2));
        assertNull(response.getShard(-1));
    }

    // ============================================================================
    // TopologyCache Tests
    // ============================================================================

    @Test
    void topologyCache_initialState() {
        TopologyCache cache = new TopologyCache();

        assertNull(cache.get());
        assertEquals(0L, cache.getVersion());
        assertNull(cache.getLastRefresh());
        assertEquals(0L, cache.getRefreshCount());
    }

    @Test
    void topologyCache_update() {
        TopologyCache cache = new TopologyCache();
        TopologyResponse response = createTestTopology(2, 1L);

        cache.update(response);

        assertNotNull(cache.get());
        assertEquals(1L, cache.getVersion());
        assertNotNull(cache.getLastRefresh());
        assertEquals(1L, cache.getRefreshCount());
    }

    @Test
    void topologyCache_computeShard() {
        TopologyCache cache = new TopologyCache();
        cache.update(createTestTopology(4, 1L));

        // Different entity IDs should distribute across shards
        UInt128 id1 = UInt128.of(1L);
        UInt128 id2 = UInt128.of(2L);
        UInt128 id3 = UInt128.of(3L);
        UInt128 id4 = UInt128.of(4L);

        int shard1 = cache.computeShard(id1);
        int shard2 = cache.computeShard(id2);
        int shard3 = cache.computeShard(id3);
        int shard4 = cache.computeShard(id4);

        // All shards should be in valid range
        assertTrue(shard1 >= 0 && shard1 < 4);
        assertTrue(shard2 >= 0 && shard2 < 4);
        assertTrue(shard3 >= 0 && shard3 < 4);
        assertTrue(shard4 >= 0 && shard4 < 4);
    }

    @Test
    void topologyCache_computeShardConsistent() {
        TopologyCache cache = new TopologyCache();
        cache.update(createTestTopology(4, 1L));

        UInt128 entityId = UInt128.of(12345L, 67890L);

        // Same ID should always route to same shard
        int shard1 = cache.computeShard(entityId);
        int shard2 = cache.computeShard(entityId);
        int shard3 = cache.computeShard(entityId);

        assertEquals(shard1, shard2);
        assertEquals(shard2, shard3);
    }

    @Test
    void topologyCache_computeShardNoTopology() {
        TopologyCache cache = new TopologyCache();

        // Should return 0 when no topology
        assertEquals(0, cache.computeShard(UInt128.of(123L)));
    }

    @Test
    void topologyCache_getShardPrimary() {
        TopologyCache cache = new TopologyCache();
        cache.update(createTestTopology(2, 1L));

        assertEquals("node0:8080", cache.getShardPrimary(0));
        assertEquals("node1:8080", cache.getShardPrimary(1));
        assertNull(cache.getShardPrimary(2));
        assertNull(cache.getShardPrimary(-1));
    }

    @Test
    void topologyCache_getAllShardPrimaries() {
        TopologyCache cache = new TopologyCache();
        cache.update(createTestTopology(3, 1L));

        List<String> primaries = cache.getAllShardPrimaries();

        assertEquals(3, primaries.size());
        assertTrue(primaries.contains("node0:8080"));
        assertTrue(primaries.contains("node1:8080"));
        assertTrue(primaries.contains("node2:8080"));
    }

    @Test
    void topologyCache_invalidate() {
        TopologyCache cache = new TopologyCache();
        cache.update(createTestTopology(2, 5L));
        assertEquals(5L, cache.getVersion());

        cache.invalidate();

        assertEquals(0L, cache.getVersion());
    }

    @Test
    void topologyCache_onChange() throws InterruptedException {
        TopologyCache cache = new TopologyCache();
        AtomicReference<TopologyChangeNotification> received = new AtomicReference<>();
        CountDownLatch latch = new CountDownLatch(1);

        cache.onChange(notification -> {
            received.set(notification);
            latch.countDown();
        });

        // Initial update (oldVersion=0) should not notify
        cache.update(createTestTopology(2, 1L));
        assertFalse(latch.await(100, TimeUnit.MILLISECONDS));

        // Version change should notify
        CountDownLatch latch2 = new CountDownLatch(1);
        cache.onChange(notification -> {
            received.set(notification);
            latch2.countDown();
        });

        cache.update(createTestTopology(2, 2L));
        assertTrue(latch2.await(1, TimeUnit.SECONDS));
        assertNotNull(received.get());
        assertEquals(2L, received.get().getNewVersion());
        assertEquals(1L, received.get().getOldVersion());
    }

    @Test
    void topologyCache_onChangeUnsubscribe() throws InterruptedException {
        TopologyCache cache = new TopologyCache();
        AtomicInteger callCount = new AtomicInteger(0);

        Runnable unsubscribe = cache.onChange(notification -> callCount.incrementAndGet());

        cache.update(createTestTopology(2, 1L));

        unsubscribe.run();

        cache.update(createTestTopology(2, 2L));

        // Wait briefly to ensure callback would have been invoked
        Thread.sleep(100);
        assertEquals(0, callCount.get());
    }

    @Test
    void topologyCache_threadSafety() throws InterruptedException {
        TopologyCache cache = new TopologyCache();
        int numThreads = 10;
        int iterations = 100;
        CountDownLatch latch = new CountDownLatch(numThreads);

        for (int t = 0; t < numThreads; t++) {
            final int threadId = t;
            new Thread(() -> {
                try {
                    for (int i = 0; i < iterations; i++) {
                        if (threadId % 2 == 0) {
                            cache.update(createTestTopology(4, i + 1L));
                        } else {
                            cache.get();
                            cache.getVersion();
                            cache.computeShard(UInt128.of(i));
                            cache.getShardPrimary(i % 4);
                        }
                    }
                } finally {
                    latch.countDown();
                }
            }).start();
        }

        assertTrue(latch.await(10, TimeUnit.SECONDS));
    }

    // ============================================================================
    // ShardRouter Tests
    // ============================================================================

    @Test
    void shardRouter_routeByEntityId() throws ShardRoutingException {
        TopologyCache cache = new TopologyCache();
        cache.update(createTestTopology(4, 1L));
        ShardRouter router = new ShardRouter(cache);

        UInt128 entityId = UInt128.of(12345L);
        ShardRouter.RouteResult result = router.routeByEntityId(entityId);

        assertTrue(result.getShardId() >= 0 && result.getShardId() < 4);
        assertNotNull(result.getPrimary());
        assertTrue(result.getPrimary().contains(":8080"));
    }

    @Test
    void shardRouter_routeByEntityIdNoPrimary() {
        TopologyCache cache = new TopologyCache();
        // No topology set
        ShardRouter router = new ShardRouter(cache);

        assertThrows(ShardRoutingException.class, () -> router.routeByEntityId(UInt128.of(1L)));
    }

    @Test
    void shardRouter_handleNotShardLeader() {
        TopologyCache cache = new TopologyCache();
        AtomicInteger refreshCount = new AtomicInteger(0);
        ShardRouter router = new ShardRouter(cache, () -> {
            refreshCount.incrementAndGet();
            return true;
        });

        NotShardLeaderException exception = new NotShardLeaderException(0, "newleader:8080");
        boolean shouldRetry = router.handleNotShardLeader(exception);

        assertTrue(shouldRetry);
        assertEquals(1, refreshCount.get());
    }

    @Test
    void shardRouter_handleNotShardLeaderNoCallback() {
        TopologyCache cache = new TopologyCache();
        ShardRouter router = new ShardRouter(cache);

        NotShardLeaderException exception = new NotShardLeaderException(0, null);
        boolean shouldRetry = router.handleNotShardLeader(exception);

        assertFalse(shouldRetry);
    }

    @Test
    void shardRouter_getAllPrimaries() {
        TopologyCache cache = new TopologyCache();
        cache.update(createTestTopology(3, 1L));
        ShardRouter router = new ShardRouter(cache);

        List<String> primaries = router.getAllPrimaries();

        assertEquals(3, primaries.size());
    }

    // ============================================================================
    // ScatterGatherConfig Tests
    // ============================================================================

    @Test
    void scatterGatherConfig_defaults() {
        ScatterGatherConfig config = ScatterGatherConfig.DEFAULT;

        assertEquals(0, config.getMaxConcurrency());
        assertTrue(config.allowPartialResults());
        assertEquals(Duration.ofSeconds(30), config.getTimeout());
    }

    @Test
    void scatterGatherConfig_builder() {
        ScatterGatherConfig config = ScatterGatherConfig.builder().maxConcurrency(4)
                .allowPartialResults(false).timeout(Duration.ofSeconds(10)).build();

        assertEquals(4, config.getMaxConcurrency());
        assertFalse(config.allowPartialResults());
        assertEquals(Duration.ofSeconds(10), config.getTimeout());
    }

    @Test
    void scatterGatherConfig_builderValidation() {
        assertThrows(IllegalArgumentException.class,
                () -> ScatterGatherConfig.builder().maxConcurrency(-1));
        assertThrows(IllegalArgumentException.class,
                () -> ScatterGatherConfig.builder().timeout(Duration.ofSeconds(-1)));
    }

    // ============================================================================
    // ScatterGatherResult Tests
    // ============================================================================

    @Test
    void scatterGatherResult_merge() {
        // Create test events with different timestamps
        List<QueryResult> results = Arrays.asList(createQueryResult(createEvents(0, 100, 200)), // Events
                                                                                                // at
                                                                                                // t=100,
                                                                                                // 200
                createQueryResult(createEvents(1, 150, 250))); // Events at t=150, 250

        ScatterGatherResult merged = ScatterGatherResult.merge(results, 0);

        // Should have 4 unique events sorted by timestamp desc
        assertEquals(4, merged.getEvents().size());
        // Verify sorted by timestamp descending
        for (int i = 0; i < merged.getEvents().size() - 1; i++) {
            assertTrue(merged.getEvents().get(i).getTimestamp() >= merged.getEvents().get(i + 1)
                    .getTimestamp());
        }
    }

    @Test
    void scatterGatherResult_mergeDeduplicate() {
        // Create events with same entity ID but different timestamps
        GeoEvent oldEvent = createEvent(UInt128.of(1L), 100L);
        GeoEvent newEvent = createEvent(UInt128.of(1L), 200L);

        List<QueryResult> results =
                Arrays.asList(new QueryResult(Collections.singletonList(oldEvent), false, 0L),
                        new QueryResult(Collections.singletonList(newEvent), false, 0L));

        ScatterGatherResult merged = ScatterGatherResult.merge(results, 0);

        // Should keep only the most recent event
        assertEquals(1, merged.getEvents().size());
        assertEquals(200L, merged.getEvents().get(0).getTimestamp());
    }

    @Test
    void scatterGatherResult_mergeWithLimit() {
        List<QueryResult> results = Arrays.asList(createQueryResult(createEvents(0, 100, 200, 300)),
                createQueryResult(createEvents(1, 150, 250, 350)));

        ScatterGatherResult merged = ScatterGatherResult.merge(results, 3);

        assertEquals(3, merged.getEvents().size());
        assertTrue(merged.hasMore());
    }

    @Test
    void scatterGatherResult_mergeHasMore() {
        List<QueryResult> results =
                Arrays.asList(new QueryResult(Collections.emptyList(), true, 0L), // Has more
                        new QueryResult(Collections.emptyList(), false, 0L));

        ScatterGatherResult merged = ScatterGatherResult.merge(results, 0);

        assertTrue(merged.hasMore());
    }

    @Test
    void scatterGatherResult_shardResults() {
        List<QueryResult> results = Arrays.asList(createQueryResult(createEvents(0, 100, 200)),
                createQueryResult(createEvents(1, 150)));

        ScatterGatherResult merged = ScatterGatherResult.merge(results, 0);

        assertEquals(2, merged.getShardResults().get(0));
        assertEquals(1, merged.getShardResults().get(1));
    }

    // ============================================================================
    // Exception Tests
    // ============================================================================

    @Test
    void shardRoutingException_message() {
        ShardRoutingException e = new ShardRoutingException(5, "No primary for shard");

        assertEquals(5, e.getShardId());
        assertEquals("No primary for shard", e.getMessage());
    }

    @Test
    void notShardLeaderException_withHint() {
        NotShardLeaderException e = new NotShardLeaderException(2, "newleader:8080");

        assertEquals(2, e.getShardId());
        assertEquals("newleader:8080", e.getLeaderHint());
        assertTrue(e.getMessage().contains("newleader:8080"));
    }

    @Test
    void notShardLeaderException_withoutHint() {
        NotShardLeaderException e = new NotShardLeaderException(3, null);

        assertEquals(3, e.getShardId());
        assertNull(e.getLeaderHint());
        assertTrue(e.getMessage().contains("shard 3"));
    }

    // ============================================================================
    // Helper Methods
    // ============================================================================

    private TopologyResponse createTestTopology(int numShards, long version) {
        List<ShardInfo> shards = new ArrayList<>();
        for (int i = 0; i < numShards; i++) {
            shards.add(new ShardInfo(i, "node" + i + ":8080", ShardStatus.ACTIVE));
        }
        return new TopologyResponse(version, UInt128.of(1L), numShards, 0, shards,
                System.nanoTime());
    }

    private List<GeoEvent> createEvents(int entityBase, long... timestamps) {
        List<GeoEvent> events = new ArrayList<>();
        for (long ts : timestamps) {
            events.add(createEvent(UInt128.of(entityBase * 1000L + ts), ts));
        }
        return events;
    }

    private GeoEvent createEvent(UInt128 entityId, long timestamp) {
        return new GeoEvent.Builder().setEntityId(entityId).setTimestamp(timestamp).setLatitude(0.0)
                .setLongitude(0.0).build();
    }

    private QueryResult createQueryResult(List<GeoEvent> events) {
        return new QueryResult(events, false, 0L);
    }
}
