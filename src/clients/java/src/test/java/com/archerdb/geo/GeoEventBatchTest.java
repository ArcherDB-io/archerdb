package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Unit tests for GeoEventBatch.
 *
 * <p>
 * Per client-sdk/spec.md batch operations API:
 * <ul>
 * <li>add(event) - Validates and adds event to batch</li>
 * <li>count() - Returns current event count</li>
 * <li>isFull() - True if count >= 10,000</li>
 * <li>commit() - Blocking commit to cluster</li>
 * <li>commitAsync() - Non-blocking commit returning CompletableFuture</li>
 * </ul>
 *
 * <p>
 * Thread-safe for concurrent add() calls.
 */
class GeoEventBatchTest {

    // Use real client in skeleton mode (NATIVE_ENABLED=false)
    private GeoClientImpl client;

    @BeforeEach
    void setUp() {
        // Create client with skeleton mode - requires non-null addresses
        client = new GeoClientImpl(UInt128.random(), new String[] {"localhost:3000"});
    }

    private GeoEvent createEvent() {
        return new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();
    }

    // ========================================================================
    // Basic Batch Operations
    // ========================================================================

    @Test
    void testAddEvent() {
        GeoEventBatch batch = new GeoEventBatch(client, false);
        GeoEvent event = createEvent();

        batch.add(event);

        assertEquals(1, batch.count());
        assertFalse(batch.isEmpty());
    }

    @Test
    void testCount() {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        assertEquals(0, batch.count());

        batch.add(createEvent());
        assertEquals(1, batch.count());

        batch.add(createEvent());
        batch.add(createEvent());
        assertEquals(3, batch.count());
    }

    @Test
    void testIsEmpty() {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        assertTrue(batch.isEmpty());

        batch.add(createEvent());
        assertFalse(batch.isEmpty());

        batch.clear();
        assertTrue(batch.isEmpty());
    }

    @Test
    void testClear() {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        batch.add(createEvent());
        batch.add(createEvent());
        assertEquals(2, batch.count());

        batch.clear();

        assertEquals(0, batch.count());
        assertTrue(batch.isEmpty());
    }

    @Test
    void testIsFull() {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        assertFalse(batch.isFull());

        // Add up to limit (10,000)
        for (int i = 0; i < CoordinateUtils.BATCH_SIZE_MAX; i++) {
            batch.add(createEvent());
        }

        assertTrue(batch.isFull());
    }

    @Test
    void testAddThrowsWhenFull() {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        // Fill the batch
        for (int i = 0; i < CoordinateUtils.BATCH_SIZE_MAX; i++) {
            batch.add(createEvent());
        }

        // Next add should throw
        assertThrows(IllegalStateException.class, () -> batch.add(createEvent()));
    }

    // ========================================================================
    // Commit Tests
    // ========================================================================

    @Test
    void testCommitInsert() {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        batch.add(createEvent());
        batch.add(createEvent());

        List<InsertGeoEventsError> errors = batch.commit();

        assertTrue(errors.isEmpty());
        assertTrue(batch.isEmpty()); // Batch cleared after commit
    }

    @Test
    void testCommitUpsert() {
        GeoEventBatch batch = new GeoEventBatch(client, true); // upsert mode

        batch.add(createEvent());
        batch.add(createEvent());

        List<InsertGeoEventsError> errors = batch.commit();

        assertTrue(errors.isEmpty());
    }

    @Test
    void testCommitEmptyBatch() {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        List<InsertGeoEventsError> errors = batch.commit();

        assertTrue(errors.isEmpty());
    }

    @Test
    void testCommitClearsBatch() {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        batch.add(createEvent());
        batch.commit();

        assertTrue(batch.isEmpty());
        assertEquals(0, batch.count());
    }

    // ========================================================================
    // Async Commit Tests
    // ========================================================================

    @Test
    void testCommitAsync() throws Exception {
        GeoEventBatch batch = new GeoEventBatch(client, false);

        batch.add(createEvent());
        batch.add(createEvent());

        CompletableFuture<List<InsertGeoEventsError>> future = batch.commitAsync();

        List<InsertGeoEventsError> errors = future.get(5, TimeUnit.SECONDS);

        assertTrue(errors.isEmpty());
        assertTrue(batch.isEmpty()); // Batch cleared after async commit
    }

    @Test
    void testCommitAsyncWithExecutor() throws Exception {
        GeoEventBatch batch = new GeoEventBatch(client, false);
        ExecutorService executor = Executors.newSingleThreadExecutor();

        try {
            batch.add(createEvent());

            CompletableFuture<List<InsertGeoEventsError>> future = batch.commitAsync(executor);
            List<InsertGeoEventsError> errors = future.get(5, TimeUnit.SECONDS);

            assertTrue(errors.isEmpty());
        } finally {
            executor.shutdown();
        }
    }

    @Test
    void testCommitAsyncWithCallback() throws Exception {
        GeoEventBatch batch = new GeoEventBatch(client, false);
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<List<InsertGeoEventsError>> result = new AtomicReference<>();

        batch.add(createEvent());

        batch.commitAsync((java.util.function.Consumer<List<InsertGeoEventsError>>) errors -> {
            result.set(errors);
            latch.countDown();
        });

        assertTrue(latch.await(5, TimeUnit.SECONDS));
        assertNotNull(result.get());
        assertTrue(result.get().isEmpty());
    }

    @Test
    void testCommitAsyncWithSuccessAndErrorCallbacks() throws Exception {
        GeoEventBatch batch = new GeoEventBatch(client, false);
        CountDownLatch latch = new CountDownLatch(1);
        AtomicBoolean successCalled = new AtomicBoolean(false);
        AtomicBoolean errorCalled = new AtomicBoolean(false);

        batch.add(createEvent());

        batch.commitAsync(errors -> {
            successCalled.set(true);
            latch.countDown();
        }, throwable -> {
            errorCalled.set(true);
            latch.countDown();
        });

        assertTrue(latch.await(5, TimeUnit.SECONDS));
        assertTrue(successCalled.get());
        assertFalse(errorCalled.get());
    }

    // ========================================================================
    // Thread Safety Tests
    // ========================================================================

    @Test
    void testConcurrentAdds() throws Exception {
        GeoEventBatch batch = new GeoEventBatch(client, false);
        int threadCount = 10;
        int eventsPerThread = 100;
        ExecutorService executor = Executors.newFixedThreadPool(threadCount);
        CountDownLatch latch = new CountDownLatch(threadCount);

        for (int t = 0; t < threadCount; t++) {
            executor.submit(() -> {
                try {
                    for (int i = 0; i < eventsPerThread; i++) {
                        batch.add(createEvent());
                    }
                } finally {
                    latch.countDown();
                }
            });
        }

        assertTrue(latch.await(10, TimeUnit.SECONDS));
        executor.shutdown();

        assertEquals(threadCount * eventsPerThread, batch.count());
    }

    @Test
    void testConcurrentAddAndCount() throws Exception {
        GeoEventBatch batch = new GeoEventBatch(client, false);
        int iterations = 1000;
        ExecutorService executor = Executors.newFixedThreadPool(4);
        CountDownLatch latch = new CountDownLatch(2);

        // Thread adding events
        executor.submit(() -> {
            try {
                for (int i = 0; i < iterations; i++) {
                    batch.add(createEvent());
                }
            } finally {
                latch.countDown();
            }
        });

        // Thread reading count (should not throw)
        executor.submit(() -> {
            try {
                for (int i = 0; i < iterations; i++) {
                    int count = batch.count();
                    assertTrue(count >= 0);
                }
            } finally {
                latch.countDown();
            }
        });

        assertTrue(latch.await(10, TimeUnit.SECONDS));
        executor.shutdown();
    }

    @Test
    void testConcurrentCommits() throws Exception {
        int batchCount = 10;
        ExecutorService executor = Executors.newFixedThreadPool(batchCount);
        CountDownLatch latch = new CountDownLatch(batchCount);

        List<CompletableFuture<List<InsertGeoEventsError>>> futures = new ArrayList<>();

        for (int b = 0; b < batchCount; b++) {
            GeoEventBatch batch = new GeoEventBatch(client, false);
            for (int i = 0; i < 10; i++) {
                batch.add(createEvent());
            }

            CompletableFuture<List<InsertGeoEventsError>> future = batch.commitAsync(executor);
            future.whenComplete((r, e) -> latch.countDown());
            futures.add(future);
        }

        assertTrue(latch.await(10, TimeUnit.SECONDS));
        executor.shutdown();

        // All commits should succeed (skeleton mode returns empty errors)
        for (CompletableFuture<List<InsertGeoEventsError>> future : futures) {
            assertTrue(future.get().isEmpty());
        }
    }

    // ========================================================================
    // Split Batch Tests (per sdk-retry/spec.md)
    // ========================================================================

    @Test
    void testSplitBatchBasic() {
        List<Integer> items = List.of(1, 2, 3, 4, 5, 6, 7, 8);
        List<List<Integer>> chunks = GeoEventBatch.splitBatch(items, 3);

        assertEquals(3, chunks.size());
        assertEquals(List.of(1, 2, 3), chunks.get(0));
        assertEquals(List.of(4, 5, 6), chunks.get(1));
        assertEquals(List.of(7, 8), chunks.get(2));
    }

    @Test
    void testSplitBatchExactDivision() {
        List<Integer> items = List.of(1, 2, 3, 4, 5, 6);
        List<List<Integer>> chunks = GeoEventBatch.splitBatch(items, 2);

        assertEquals(3, chunks.size());
        assertEquals(List.of(1, 2), chunks.get(0));
        assertEquals(List.of(3, 4), chunks.get(1));
        assertEquals(List.of(5, 6), chunks.get(2));
    }

    @Test
    void testSplitBatchEmptyList() {
        List<Integer> items = List.of();
        List<List<Integer>> chunks = GeoEventBatch.splitBatch(items, 3);

        assertTrue(chunks.isEmpty());
    }

    @Test
    void testSplitBatchSingleChunk() {
        List<Integer> items = List.of(1, 2, 3);
        List<List<Integer>> chunks = GeoEventBatch.splitBatch(items, 10);

        assertEquals(1, chunks.size());
        assertEquals(List.of(1, 2, 3), chunks.get(0));
    }

    @Test
    void testSplitBatchChunkSizeOne() {
        List<Integer> items = List.of(1, 2, 3);
        List<List<Integer>> chunks = GeoEventBatch.splitBatch(items, 1);

        assertEquals(3, chunks.size());
        assertEquals(List.of(1), chunks.get(0));
        assertEquals(List.of(2), chunks.get(1));
        assertEquals(List.of(3), chunks.get(2));
    }

    @Test
    void testSplitBatchInvalidChunkSize() {
        List<Integer> items = List.of(1, 2, 3);

        assertThrows(IllegalArgumentException.class, () -> {
            GeoEventBatch.splitBatch(items, 0);
        });

        assertThrows(IllegalArgumentException.class, () -> {
            GeoEventBatch.splitBatch(items, -1);
        });
    }

    @Test
    void testSplitBatchDefaultChunkSize() {
        // Create list with 2500 items
        List<Integer> items = new ArrayList<>();
        for (int i = 0; i < 2500; i++) {
            items.add(i);
        }

        List<List<Integer>> chunks = GeoEventBatch.splitBatch(items);

        // Default chunk size is 1000
        assertEquals(3, chunks.size());
        assertEquals(1000, chunks.get(0).size());
        assertEquals(1000, chunks.get(1).size());
        assertEquals(500, chunks.get(2).size());
    }

    @Test
    void testSplitBatchWithGeoEvents() {
        List<GeoEvent> events = new ArrayList<>();
        for (int i = 0; i < 10; i++) {
            events.add(createEvent());
        }

        List<List<GeoEvent>> chunks = GeoEventBatch.splitBatch(events, 3);

        assertEquals(4, chunks.size());
        assertEquals(3, chunks.get(0).size());
        assertEquals(3, chunks.get(1).size());
        assertEquals(3, chunks.get(2).size());
        assertEquals(1, chunks.get(3).size());

        // Verify events are preserved
        int totalEvents = chunks.stream().mapToInt(List::size).sum();
        assertEquals(10, totalEvents);
    }

    @Test
    void testSplitBatchNullList() {
        List<List<Integer>> chunks = GeoEventBatch.splitBatch(null, 3);
        assertTrue(chunks.isEmpty());
    }
}
