package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * Unit tests for GeoClient implementation.
 *
 * <p>
 * These tests verify the GeoClient skeleton implementation. When native bindings are enabled, these
 * tests will require a running ArcherDB cluster.
 */
class GeoClientTest {

    private GeoClient client;

    @BeforeEach
    void setUp() {
        // Create client with test cluster ID and addresses
        UInt128 clusterId = UInt128.of(1L, 0L);
        client = GeoClient.create(clusterId, new String[] {"127.0.0.1:3001"});
    }

    @AfterEach
    void tearDown() {
        if (client != null) {
            client.close();
        }
    }

    // ========================================================================
    // Connection Lifecycle Tests
    // ========================================================================

    @Test
    void testClientCreation() {
        assertNotNull(client);
    }

    @Test
    void testClientCreationWithNullAddresses() {
        assertThrows(IllegalArgumentException.class, () -> {
            GeoClient.create(UInt128.of(1L), null);
        });
    }

    @Test
    void testClientCreationWithEmptyAddresses() {
        assertThrows(IllegalArgumentException.class, () -> {
            GeoClient.create(UInt128.of(1L), new String[] {});
        });
    }

    @Test
    void testClientClose() {
        client.close();
        // Double close should be safe
        client.close();
    }

    @Test
    void testOperationsAfterClose() {
        client.close();

        assertThrows(IllegalStateException.class, () -> {
            client.ping();
        });
    }

    // ========================================================================
    // Batch Creation Tests
    // ========================================================================

    @Test
    void testCreateBatch() {
        GeoEventBatch batch = client.createBatch();
        assertNotNull(batch);
        assertEquals(0, batch.count());
    }

    @Test
    void testCreateUpsertBatch() {
        GeoEventBatch batch = client.createUpsertBatch();
        assertNotNull(batch);
        assertEquals(0, batch.count());
    }

    @Test
    void testCreateDeleteBatch() {
        DeleteEntityBatch batch = client.createDeleteBatch();
        assertNotNull(batch);
        assertEquals(0, batch.count());
    }

    // ========================================================================
    // Insert Operation Tests
    // ========================================================================

    @Test
    void testInsertSingleEvent() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();

        List<InsertGeoEventsError> errors = client.insertEvent(event);

        // Skeleton implementation returns no errors
        assertTrue(errors.isEmpty());
    }

    @Test
    void testInsertMultipleEvents() {
        GeoEvent event1 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();

        GeoEvent event2 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(40.7128)
                .setLongitude(-74.0060).build();

        List<InsertGeoEventsError> errors = client.insertEvents(List.of(event1, event2));

        assertTrue(errors.isEmpty());
    }

    @Test
    void testInsertEmptyList() {
        List<InsertGeoEventsError> errors = client.insertEvents(List.of());
        assertTrue(errors.isEmpty());
    }

    @Test
    void testSubmitInsertEventsBatchedOffsetsIndices() {
        GeoEvent event1 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();
        GeoEvent event2 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7750)
                .setLongitude(-122.4195).build();
        GeoEvent event3 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7751)
                .setLongitude(-122.4196).build();

        RetryPolicy policy = RetryPolicy.builder().setMaxRetries(0).setBaseBackoffMs(0)
                .setMaxBackoffMs(0).setJitterEnabled(false).build();

        List<InsertGeoEventsError> errors = GeoClientImpl
                .submitInsertEventsBatched(List.of(event1, event2, event3), 2, policy, batch -> {
                    if (batch.size() == 2) {
                        return List.of(new InsertGeoEventsError(1,
                                InsertGeoEventResult.INVALID_COORDINATES));
                    }
                    return List.of(new InsertGeoEventsError(0, InsertGeoEventResult.EXISTS));
                });

        assertEquals(2, errors.size());
        assertEquals(1, errors.get(0).getIndex());
        assertEquals(2, errors.get(1).getIndex());
    }

    @Test
    void testSubmitInsertEventsBatchedRetriesFailedBatchOnly() {
        GeoEvent event1 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();
        GeoEvent event2 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7750)
                .setLongitude(-122.4195).build();
        GeoEvent event3 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7751)
                .setLongitude(-122.4196).build();

        RetryPolicy policy = RetryPolicy.builder().setMaxRetries(1).setBaseBackoffMs(0)
                .setMaxBackoffMs(0).setJitterEnabled(false).build();

        AtomicInteger firstBatchCalls = new AtomicInteger();
        AtomicInteger secondBatchCalls = new AtomicInteger();

        List<InsertGeoEventsError> errors = GeoClientImpl
                .submitInsertEventsBatched(List.of(event1, event2, event3), 2, policy, batch -> {
                    if (batch.size() == 2) {
                        if (firstBatchCalls.getAndIncrement() == 0) {
                            throw new OperationException(OperationException.TIMEOUT, "temporary",
                                    true);
                        }
                        return List.of();
                    }
                    secondBatchCalls.incrementAndGet();
                    return List.of();
                });

        assertTrue(errors.isEmpty());
        assertEquals(2, firstBatchCalls.get());
        assertEquals(1, secondBatchCalls.get());
    }

    // ========================================================================
    // Upsert Operation Tests
    // ========================================================================

    @Test
    void testUpsertEvents() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();

        List<InsertGeoEventsError> errors = client.upsertEvents(List.of(event));

        assertTrue(errors.isEmpty());
    }

    // ========================================================================
    // Delete Operation Tests
    // ========================================================================

    @Test
    void testDeleteEntities() {
        UInt128 entityId = UInt128.random();

        DeleteResult result = client.deleteEntities(List.of(entityId));

        // Skeleton returns all as deleted
        assertEquals(1, result.getDeletedCount());
        assertEquals(0, result.getNotFoundCount());
    }

    @Test
    void testDeleteMultipleEntities() {
        UInt128 id1 = UInt128.random();
        UInt128 id2 = UInt128.random();
        UInt128 id3 = UInt128.random();

        DeleteResult result = client.deleteEntities(List.of(id1, id2, id3));

        assertEquals(3, result.getDeletedCount());
        assertEquals(0, result.getNotFoundCount());
    }

    @Test
    void testDeleteEmptyList() {
        DeleteResult result = client.deleteEntities(List.of());

        assertEquals(0, result.getDeletedCount());
        assertEquals(0, result.getNotFoundCount());
    }

    // ========================================================================
    // Query by UUID Tests
    // ========================================================================

    @Test
    void testGetLatestByUuid() {
        UInt128 entityId = UInt128.random();

        GeoEvent event = client.getLatestByUuid(entityId);

        // Skeleton returns null (not found)
        assertNull(event);
    }

    // ========================================================================
    // Batch UUID Lookup Tests (query_uuid_batch per client-protocol/spec.md)
    // ========================================================================

    @Test
    void testLookupBatchSingleEntity() {
        UInt128 entityId = UInt128.random();

        Map<UInt128, GeoEvent> results = client.lookupBatch(List.of(entityId));

        assertNotNull(results);
        assertEquals(1, results.size());
        assertTrue(results.containsKey(entityId));
        // Skeleton returns null (not found) for all entities
        assertNull(results.get(entityId));
    }

    @Test
    void testLookupBatchMultipleEntities() {
        UInt128 id1 = UInt128.random();
        UInt128 id2 = UInt128.random();
        UInt128 id3 = UInt128.random();

        Map<UInt128, GeoEvent> results = client.lookupBatch(List.of(id1, id2, id3));

        assertNotNull(results);
        assertEquals(3, results.size());
        assertTrue(results.containsKey(id1));
        assertTrue(results.containsKey(id2));
        assertTrue(results.containsKey(id3));
    }

    @Test
    void testLookupBatchEmptyList() {
        Map<UInt128, GeoEvent> results = client.lookupBatch(List.of());

        assertNotNull(results);
        assertTrue(results.isEmpty());
    }

    @Test
    void testLookupBatchNullList() {
        Map<UInt128, GeoEvent> results = client.lookupBatch(null);

        assertNotNull(results);
        assertTrue(results.isEmpty());
    }

    @Test
    void testLookupBatchDuplicateIds() {
        UInt128 entityId = UInt128.random();

        // Per spec: Duplicate UUIDs are allowed
        Map<UInt128, GeoEvent> results = client.lookupBatch(List.of(entityId, entityId, entityId));

        assertNotNull(results);
        // Map will de-duplicate keys
        assertEquals(1, results.size());
        assertTrue(results.containsKey(entityId));
    }

    @Test
    void testLookupBatchMaxLimit() {
        // Per client-protocol/spec.md: Maximum 10,000 UUIDs per request
        List<UInt128> tooManyIds = new ArrayList<>();
        for (int i = 0; i < 10001; i++) {
            tooManyIds.add(UInt128.random());
        }

        assertThrows(IllegalArgumentException.class, () -> {
            client.lookupBatch(tooManyIds);
        });
    }

    @Test
    void testLookupBatchAtMaxLimit() {
        // Exactly at limit should succeed
        List<UInt128> maxIds = new ArrayList<>();
        for (int i = 0; i < 10000; i++) {
            maxIds.add(UInt128.random());
        }

        Map<UInt128, GeoEvent> results = client.lookupBatch(maxIds);

        assertNotNull(results);
        assertEquals(10000, results.size());
    }

    // ========================================================================
    // Radius Query Tests
    // ========================================================================

    @Test
    void testQueryRadius() {
        QueryRadiusFilter filter = QueryRadiusFilter.create(37.7749, -122.4194, 1000.0, // 1km
                                                                                        // radius
                100 // limit
        );

        QueryResult result = client.queryRadius(filter);

        assertNotNull(result);
        assertTrue(result.getEvents().isEmpty()); // Skeleton returns empty
        assertFalse(result.hasMore());
    }

    @Test
    void testQueryRadiusWithBuilder() {
        QueryRadiusFilter filter = new QueryRadiusFilter.Builder().setCenterLatitude(40.7128)
                .setCenterLongitude(-74.0060).setRadiusMeters(500.0).setLimit(50)
                .setTimestampMin(1000L).setTimestampMax(2000L).setGroupId(123L).build();

        QueryResult result = client.queryRadius(filter);

        assertNotNull(result);
        assertTrue(result.getEvents().isEmpty());
    }

    // ========================================================================
    // Polygon Query Tests
    // ========================================================================

    @Test
    void testQueryPolygon() {
        QueryPolygonFilter filter = new QueryPolygonFilter.Builder().addVertex(37.7749, -122.4194)
                .addVertex(37.7849, -122.4094).addVertex(37.7749, -122.3994).setLimit(100).build();

        QueryResult result = client.queryPolygon(filter);

        assertNotNull(result);
        assertTrue(result.getEvents().isEmpty()); // Skeleton returns empty
    }

    @Test
    void testQueryPolygonWithHoles() {
        QueryPolygonFilter filter = new QueryPolygonFilter.Builder()
                // Outer polygon
                .addVertex(37.77, -122.42).addVertex(37.78, -122.42).addVertex(37.78, -122.41)
                .addVertex(37.77, -122.41)
                // Inner hole
                .startHole().addHoleVertex(37.773, -122.417).addHoleVertex(37.777, -122.417)
                .addHoleVertex(37.777, -122.413).addHoleVertex(37.773, -122.413).finishHole()
                .setLimit(100).build();

        QueryResult result = client.queryPolygon(filter);

        assertNotNull(result);
        assertTrue(result.getEvents().isEmpty());
    }

    // ========================================================================
    // Query Latest Tests
    // ========================================================================

    @Test
    void testQueryLatest() {
        QueryLatestFilter filter = QueryLatestFilter.global(100);

        QueryResult result = client.queryLatest(filter);

        assertNotNull(result);
        assertTrue(result.getEvents().isEmpty()); // Skeleton returns empty
    }

    @Test
    void testQueryLatestForGroup() {
        QueryLatestFilter filter = QueryLatestFilter.forGroup(42L, 50);

        QueryResult result = client.queryLatest(filter);

        assertNotNull(result);
        assertTrue(result.getEvents().isEmpty());
    }

    @Test
    void testQueryLatestWithCursor() {
        QueryLatestFilter filter = QueryLatestFilter.withCursor(100, 1234567890L);

        QueryResult result = client.queryLatest(filter);

        assertNotNull(result);
        assertTrue(result.getEvents().isEmpty());
    }

    // ========================================================================
    // Admin Operation Tests
    // ========================================================================

    @Test
    void testPing() {
        boolean result = client.ping();

        // Skeleton always returns true
        assertTrue(result);
    }

    @Test
    void testGetStatus() {
        StatusResponse status = client.getStatus();

        assertNotNull(status);
        // Skeleton returns all zeros
        assertEquals(0, status.getRamIndexCount());
        assertEquals(0, status.getRamIndexCapacity());
        assertEquals(0, status.getRamIndexLoadPct());
        assertEquals(0, status.getTombstoneCount());
        assertEquals(0, status.getTtlExpirations());
        assertEquals(0, status.getDeletionCount());
    }

    // ========================================================================
    // TTL Cleanup Tests (cleanup_expired per client-protocol/spec.md)
    // ========================================================================

    @Test
    void testCleanupExpired() {
        CleanupResult result = client.cleanupExpired();

        assertNotNull(result);
        // Skeleton returns zeros
        assertEquals(0, result.getEntriesScanned());
        assertEquals(0, result.getEntriesRemoved());
        assertFalse(result.hasRemovals());
        assertEquals(0.0, result.getExpirationRatio(), 0.001);
    }

    @Test
    void testCleanupExpiredWithBatchSize() {
        CleanupResult result = client.cleanupExpired(1000);

        assertNotNull(result);
        assertEquals(0, result.getEntriesScanned());
        assertEquals(0, result.getEntriesRemoved());
    }

    @Test
    void testCleanupExpiredScanAll() {
        // 0 = scan all entries per spec
        CleanupResult result = client.cleanupExpired(0);

        assertNotNull(result);
        assertEquals(0, result.getEntriesScanned());
        assertEquals(0, result.getEntriesRemoved());
    }

    @Test
    void testCleanupExpiredNegativeBatchSize() {
        assertThrows(IllegalArgumentException.class, () -> {
            client.cleanupExpired(-1);
        });
    }

    @Test
    void testCleanupResultEquality() {
        CleanupResult r1 = new CleanupResult(100, 50);
        CleanupResult r2 = new CleanupResult(100, 50);
        CleanupResult r3 = new CleanupResult(100, 25);

        assertEquals(r1, r2);
        assertNotEquals(r1, r3);
        assertEquals(r1.hashCode(), r2.hashCode());
    }

    @Test
    void testCleanupResultExpirationRatio() {
        CleanupResult result = new CleanupResult(100, 25);

        assertEquals(100, result.getEntriesScanned());
        assertEquals(25, result.getEntriesRemoved());
        assertTrue(result.hasRemovals());
        assertEquals(0.25, result.getExpirationRatio(), 0.001);
    }

    @Test
    void testCleanupResultToString() {
        CleanupResult result = new CleanupResult(100, 25);

        String str = result.toString();
        assertTrue(str.contains("entriesScanned=100"));
        assertTrue(str.contains("entriesRemoved=25"));
        assertTrue(str.contains("25.00%"));
    }

    // ========================================================================
    // Batch Commit Tests
    // ========================================================================

    @Test
    void testBatchInsertCommit() {
        GeoEventBatch batch = client.createBatch();

        GeoEvent event1 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();

        GeoEvent event2 = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(40.7128)
                .setLongitude(-74.0060).build();

        batch.add(event1);
        batch.add(event2);

        assertEquals(2, batch.count());

        List<InsertGeoEventsError> errors = batch.commit();

        assertTrue(errors.isEmpty());
        assertEquals(0, batch.count()); // Batch should be cleared after commit
    }

    @Test
    void testDeleteBatchCommit() {
        DeleteEntityBatch batch = client.createDeleteBatch();

        batch.add(UInt128.random());
        batch.add(UInt128.random());

        assertEquals(2, batch.count());

        DeleteResult result = batch.commit();

        assertEquals(2, result.getDeletedCount());
        assertEquals(0, result.getNotFoundCount());
        assertEquals(0, batch.count()); // Batch should be cleared after commit
    }
}
