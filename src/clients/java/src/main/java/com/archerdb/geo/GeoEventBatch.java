// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.ForkJoinPool;
import java.util.function.Consumer;

/**
 * Batch builder for accumulating events before commit.
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
public final class GeoEventBatch {

    private final List<GeoEvent> events = new ArrayList<>();
    private final GeoClientImpl client;
    private final boolean upsert;
    private final Object lock = new Object();

    GeoEventBatch(GeoClientImpl client, boolean upsert) {
        this.client = client;
        this.upsert = upsert;
    }

    /**
     * Adds a GeoEvent to the batch.
     *
     * @param event the event to add
     * @throws IllegalStateException if batch is full
     * @throws ValidationException if event fails validation
     */
    public void add(GeoEvent event) {
        synchronized (lock) {
            if (events.size() >= CoordinateUtils.BATCH_SIZE_MAX) {
                throw new IllegalStateException(String.format("Batch is full (max %d events)",
                        CoordinateUtils.BATCH_SIZE_MAX));
            }
            events.add(event);
        }
    }

    /**
     * Returns the number of events in the batch.
     */
    public int count() {
        synchronized (lock) {
            return events.size();
        }
    }

    /**
     * Returns true if the batch is full (10,000 events).
     */
    public boolean isFull() {
        synchronized (lock) {
            return events.size() >= CoordinateUtils.BATCH_SIZE_MAX;
        }
    }

    /**
     * Returns true if the batch is empty.
     */
    public boolean isEmpty() {
        synchronized (lock) {
            return events.isEmpty();
        }
    }

    /**
     * Clears all events from the batch.
     */
    public void clear() {
        synchronized (lock) {
            events.clear();
        }
    }

    /**
     * Commits the batch to the cluster (blocking).
     *
     * @return list of errors (empty if all succeeded)
     */
    public List<InsertGeoEventsError> commit() {
        List<GeoEvent> toCommit;
        synchronized (lock) {
            if (events.isEmpty()) {
                return new ArrayList<>();
            }
            toCommit = new ArrayList<>(events);
            events.clear();
        }

        List<InsertGeoEventsError> results;
        if (upsert) {
            results = client.upsertEvents(toCommit);
        } else {
            results = client.insertEvents(toCommit);
        }

        return results;
    }

    /**
     * Commits the batch asynchronously.
     *
     * @return CompletableFuture that completes with error list
     */
    public CompletableFuture<List<InsertGeoEventsError>> commitAsync() {
        return commitAsync(ForkJoinPool.commonPool());
    }

    /**
     * Commits the batch asynchronously with custom executor.
     *
     * @param executor the executor to use for async operation
     * @return CompletableFuture that completes with error list
     */
    public CompletableFuture<List<InsertGeoEventsError>> commitAsync(Executor executor) {
        return CompletableFuture.supplyAsync(this::commit, executor);
    }

    /**
     * Commits the batch asynchronously with callback.
     *
     * @param callback callback invoked with results
     */
    public void commitAsync(Consumer<List<InsertGeoEventsError>> callback) {
        commitAsync().thenAccept(callback);
    }

    /**
     * Commits the batch asynchronously with success and error callbacks.
     *
     * @param onSuccess callback for successful commit
     * @param onError callback for commit failure
     */
    public void commitAsync(Consumer<List<InsertGeoEventsError>> onSuccess,
            Consumer<Throwable> onError) {
        commitAsync().whenComplete((result, error) -> {
            if (error != null) {
                onError.accept(error);
            } else {
                onSuccess.accept(result);
            }
        });
    }

    /**
     * Splits a list into smaller chunks of the specified size.
     *
     * <p>
     * This is useful for retry scenarios when a large batch times out and you need to split it into
     * smaller chunks for retry per sdk-retry/spec.md:
     *
     * <pre>
     * {
     *     &#64;code
     *     List&lt;GeoEvent&gt; events = generateLargeEventList();
     *
     *     try {
     *         client.insertEvents(events);
     *     } catch (OperationTimeoutException e) {
     *         // Split into smaller chunks and retry
     *         List&lt;List&lt;GeoEvent&gt;&gt; chunks = GeoEventBatch.splitBatch(events, 500);
     *         for (List&lt;GeoEvent&gt; chunk : chunks) {
     *             try {
     *                 client.insertEvents(chunk);
     *             } catch (OperationTimeoutException retryError) {
     *                 // Retry with even smaller chunks
     *                 List&lt;List&lt;GeoEvent&gt;&gt; smallerChunks = GeoEventBatch.splitBatch(chunk, 100);
     *                 // ... continue
     *             }
     *         }
     *     }
     * }
     * </pre>
     *
     * @param <T> the element type
     * @param items the list to split
     * @param chunkSize the maximum size of each chunk (must be positive)
     * @return a list of chunks, each containing at most chunkSize elements
     * @throws IllegalArgumentException if chunkSize is not positive
     */
    public static <T> List<List<T>> splitBatch(List<T> items, int chunkSize) {
        if (chunkSize <= 0) {
            throw new IllegalArgumentException("chunkSize must be positive, got: " + chunkSize);
        }
        if (items == null || items.isEmpty()) {
            return new ArrayList<>();
        }

        List<List<T>> chunks = new ArrayList<>();
        for (int i = 0; i < items.size(); i += chunkSize) {
            int end = Math.min(i + chunkSize, items.size());
            chunks.add(new ArrayList<>(items.subList(i, end)));
        }
        return chunks;
    }

    /**
     * Splits a list into chunks of 1000 elements (default chunk size).
     *
     * @param <T> the element type
     * @param items the list to split
     * @return a list of chunks, each containing at most 1000 elements
     */
    public static <T> List<List<T>> splitBatch(List<T> items) {
        return splitBatch(items, 1000);
    }
}
