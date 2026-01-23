/*
 * Copyright 2024-2026 ArcherDB Contributors SPDX-License-Identifier: BUSL-1.1
 */
package com.archerdb.geo;

import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.ForkJoinPool;

/**
 * Asynchronous ArcherDB geospatial client using CompletableFuture.
 *
 * <p>
 * Provides non-blocking versions of all {@link GeoClient} operations. Each async method returns a
 * {@link CompletableFuture} that completes when the operation finishes. Operations are executed on
 * the provided {@link Executor} (defaults to {@link ForkJoinPool#commonPool()}).
 *
 * <p>
 * <b>Thread Safety:</b> This client is thread-safe. A single instance should be shared across
 * threads. The underlying synchronous client handles connection pooling and thread synchronization.
 *
 * <p>
 * <b>Lifecycle:</b> Use try-with-resources or call {@link #close()} when done:
 *
 * <pre>
 * {@code
 * try (GeoClientAsync client = GeoClientAsync.create(0L, "127.0.0.1:3001")) {
 *     // Use client
 * }
 * }
 * </pre>
 *
 * <p>
 * <b>Example - Basic async operations:</b>
 *
 * <pre>
 * {@code
 * GeoClientAsync client = GeoClientAsync.create(0L, "127.0.0.1:3001");
 *
 * // Insert events asynchronously
 * client.insertEventsAsync(events)
 *     .thenAccept(errors -> {
 *         if (errors.isEmpty()) {
 *             System.out.println("All events inserted!");
 *         }
 *     })
 *     .exceptionally(ex -> {
 *         System.err.println("Insert failed: " + ex.getMessage());
 *         return null;
 *     });
 * }
 * </pre>
 *
 * <p>
 * <b>Example - Combining async operations:</b>
 *
 * <pre>
 * {@code
 * // Execute multiple queries in parallel
 * CompletableFuture<QueryResult> region1 = client.queryRadiusAsync(filter1);
 * CompletableFuture<QueryResult> region2 = client.queryRadiusAsync(filter2);
 * CompletableFuture<QueryResult> region3 = client.queryRadiusAsync(filter3);
 *
 * // Wait for all to complete
 * CompletableFuture.allOf(region1, region2, region3)
 *     .thenRun(() -> {
 *         int total = region1.join().getEvents().size()
 *                   + region2.join().getEvents().size()
 *                   + region3.join().getEvents().size();
 *         System.out.println("Total events: " + total);
 *     });
 * }
 * </pre>
 *
 * <p>
 * <b>Example - Chaining operations:</b>
 *
 * <pre>
 * {@code
 * client.getLatestByUuidAsync(entityId)
 *     .thenCompose(event -> {
 *         if (event != null) {
 *             // Query around the entity's current location
 *             QueryRadiusFilter filter = QueryRadiusFilter.builder()
 *                 .setCenter(event.getLatitude(), event.getLongitude())
 *                 .setRadiusMeters(1000)
 *                 .setLimit(100)
 *                 .build();
 *             return client.queryRadiusAsync(filter);
 *         }
 *         return CompletableFuture.completedFuture(QueryResult.empty());
 *     })
 *     .thenAccept(result -> {
 *         System.out.println("Nearby: " + result.getEvents().size());
 *     });
 * }
 * </pre>
 *
 * @see GeoClient for synchronous operations
 * @see CompletableFuture for async composition patterns
 */
public class GeoClientAsync implements AutoCloseable {

    private final GeoClient delegate;
    private final Executor executor;

    /**
     * Creates a new async client wrapping the given sync client.
     *
     * @param delegate the synchronous client to wrap
     * @param executor the executor for async operations
     */
    private GeoClientAsync(GeoClient delegate, Executor executor) {
        if (delegate == null) {
            throw new IllegalArgumentException("Delegate client must not be null");
        }
        if (executor == null) {
            throw new IllegalArgumentException("Executor must not be null");
        }
        this.delegate = delegate;
        this.executor = executor;
    }

    /**
     * Creates a new async client connected to the specified cluster.
     *
     * <p>
     * Uses the default executor ({@link ForkJoinPool#commonPool()}) for async operations.
     *
     * @param clusterId the cluster ID
     * @param addresses replica addresses (host:port format)
     * @return a new async client
     * @throws IllegalArgumentException if addresses is null or empty
     */
    public static GeoClientAsync create(long clusterId, String... addresses) {
        return new GeoClientAsync(GeoClient.create(clusterId, addresses),
                ForkJoinPool.commonPool());
    }

    /**
     * Creates a new async client with a 128-bit cluster ID.
     *
     * <p>
     * Uses the default executor ({@link ForkJoinPool#commonPool()}) for async operations.
     *
     * @param clusterId the cluster ID
     * @param addresses replica addresses (host:port format)
     * @return a new async client
     * @throws IllegalArgumentException if addresses is null or empty
     */
    public static GeoClientAsync create(UInt128 clusterId, String... addresses) {
        return new GeoClientAsync(GeoClient.create(clusterId, addresses),
                ForkJoinPool.commonPool());
    }

    /**
     * Creates a new async client wrapping an existing sync client.
     *
     * <p>
     * This allows using a custom executor for async operations.
     *
     * @param client the synchronous client to wrap (takes ownership)
     * @param executor the executor for async operations
     * @return a new async client
     * @throws IllegalArgumentException if client or executor is null
     */
    public static GeoClientAsync create(GeoClient client, Executor executor) {
        return new GeoClientAsync(client, executor);
    }

    /**
     * Creates a new async client from configuration.
     *
     * <p>
     * Uses the default executor ({@link ForkJoinPool#commonPool()}) for async operations.
     *
     * @param config the multi-region client configuration
     * @return a new async client
     */
    public static GeoClientAsync create(ClientConfig config) {
        return new GeoClientAsync(GeoClient.create(config), ForkJoinPool.commonPool());
    }

    /**
     * Creates a new async client from configuration with custom executor.
     *
     * @param config the multi-region client configuration
     * @param executor the executor for async operations
     * @return a new async client
     */
    public static GeoClientAsync create(ClientConfig config, Executor executor) {
        return new GeoClientAsync(GeoClient.create(config), executor);
    }

    /**
     * Returns the underlying synchronous client.
     *
     * @return the wrapped sync client
     */
    public GeoClient getSyncClient() {
        return delegate;
    }

    // ============================================================================
    // Insert/Upsert Operations
    // ============================================================================

    /**
     * Inserts a single event asynchronously.
     *
     * <p>
     * Convenience method equivalent to {@code insertEventsAsync(List.of(event))}.
     *
     * @param event the event to insert
     * @return a future containing the list of errors (empty if all succeeded)
     * @throws NullPointerException if event is null
     * @see #insertEventsAsync(List)
     */
    public CompletableFuture<List<InsertGeoEventsError>> insertEventAsync(GeoEvent event) {
        return CompletableFuture.supplyAsync(() -> delegate.insertEvent(event), executor);
    }

    /**
     * Inserts multiple events asynchronously.
     *
     * <p>
     * Events are replicated to the cluster and durably persisted before the future completes. The
     * returned list contains errors for any events that failed to insert - an empty list indicates
     * all events were inserted successfully.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * List<GeoEvent> events = createEvents();
     * client.insertEventsAsync(events)
     *     .thenAccept(errors -> {
     *         if (errors.isEmpty()) {
     *             System.out.println("All " + events.size() + " events inserted!");
     *         } else {
     *             for (InsertGeoEventsError error : errors) {
     *                 System.err.println("Event " + error.getIndex() + " failed: "
     *                     + error.getResult());
     *             }
     *         }
     *     });
     * }
     * </pre>
     *
     * @param events the events to insert (max 10,000 per call)
     * @return a future containing the list of errors (empty if all succeeded)
     * @throws ValidationException if batch exceeds 10,000 events
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #insertEventAsync(GeoEvent)
     * @see #upsertEventsAsync(List)
     */
    public CompletableFuture<List<InsertGeoEventsError>> insertEventsAsync(List<GeoEvent> events) {
        return CompletableFuture.supplyAsync(() -> delegate.insertEvents(events), executor);
    }

    /**
     * Inserts multiple events asynchronously with per-operation options.
     *
     * @param events the events to insert
     * @param options per-operation options (null for defaults)
     * @return a future containing the list of errors (empty if all succeeded)
     * @see #insertEventsAsync(List)
     */
    public CompletableFuture<List<InsertGeoEventsError>> insertEventsAsync(List<GeoEvent> events,
            OperationOptions options) {
        return CompletableFuture.supplyAsync(() -> delegate.insertEvents(events, options),
                executor);
    }

    /**
     * Upserts multiple events asynchronously.
     *
     * <p>
     * Upsert inserts new events or updates existing ones based on entity ID. If an event with the
     * same entity ID exists, it is replaced with the new event using last-writer-wins (LWW)
     * semantics.
     *
     * @param events the events to upsert (max 10,000 per call)
     * @return a future containing the list of errors (empty if all succeeded)
     * @throws ValidationException if batch exceeds 10,000 events
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #insertEventsAsync(List)
     */
    public CompletableFuture<List<InsertGeoEventsError>> upsertEventsAsync(List<GeoEvent> events) {
        return CompletableFuture.supplyAsync(() -> delegate.upsertEvents(events), executor);
    }

    /**
     * Upserts multiple events asynchronously with per-operation options.
     *
     * @param events the events to upsert
     * @param options per-operation options (null for defaults)
     * @return a future containing the list of errors (empty if all succeeded)
     * @see #upsertEventsAsync(List)
     */
    public CompletableFuture<List<InsertGeoEventsError>> upsertEventsAsync(List<GeoEvent> events,
            OperationOptions options) {
        return CompletableFuture.supplyAsync(() -> delegate.upsertEvents(events, options),
                executor);
    }

    // ============================================================================
    // Delete Operations
    // ============================================================================

    /**
     * Deletes entities by their IDs asynchronously.
     *
     * <p>
     * GDPR-compliant deletion of all events for specified entities. The deletion is replicated and
     * durable once the future completes.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * List<UInt128> entityIds = List.of(entityId1, entityId2, entityId3);
     * client.deleteEntitiesAsync(entityIds)
     *     .thenAccept(result -> {
     *         System.out.println("Deleted: " + result.getDeletedCount());
     *         System.out.println("Not found: " + result.getNotFoundCount());
     *     });
     * }
     * </pre>
     *
     * @param entityIds the entity IDs to delete (max 10,000 per call)
     * @return a future containing the delete result with counts
     * @throws ValidationException if batch exceeds 10,000 entity IDs
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     */
    public CompletableFuture<DeleteResult> deleteEntitiesAsync(List<UInt128> entityIds) {
        return CompletableFuture.supplyAsync(() -> delegate.deleteEntities(entityIds), executor);
    }

    /**
     * Deletes entities by their IDs asynchronously with per-operation options.
     *
     * @param entityIds the entity IDs to delete
     * @param options per-operation options (null for defaults)
     * @return a future containing the delete result with counts
     * @see #deleteEntitiesAsync(List)
     */
    public CompletableFuture<DeleteResult> deleteEntitiesAsync(List<UInt128> entityIds,
            OperationOptions options) {
        return CompletableFuture.supplyAsync(() -> delegate.deleteEntities(entityIds, options),
                executor);
    }

    // ============================================================================
    // Query Operations
    // ============================================================================

    /**
     * Looks up the latest event for an entity by UUID asynchronously.
     *
     * <p>
     * Returns the most recent event for the given entity, or null if not found.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * client.getLatestByUuidAsync(entityId)
     *     .thenAccept(event -> {
     *         if (event != null) {
     *             System.out.printf("Last location: (%.6f, %.6f)%n",
     *                 event.getLatitude(), event.getLongitude());
     *         } else {
     *             System.out.println("Entity not found");
     *         }
     *     });
     * }
     * </pre>
     *
     * @param entityId the entity UUID
     * @return a future containing the latest event, or null if not found
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see #lookupBatchAsync(List)
     */
    public CompletableFuture<GeoEvent> getLatestByUuidAsync(UInt128 entityId) {
        return CompletableFuture.supplyAsync(() -> delegate.getLatestByUuid(entityId), executor);
    }

    /**
     * Looks up multiple entities by UUID in a single batch request asynchronously.
     *
     * <p>
     * Returns a map of entity ID to event. Entities not found will have null values.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * List<UInt128> ids = List.of(id1, id2, id3);
     * client.lookupBatchAsync(ids)
     *     .thenAccept(results -> {
     *         for (UInt128 id : ids) {
     *             GeoEvent event = results.get(id);
     *             if (event != null) {
     *                 System.out.printf("Entity %s at (%.6f, %.6f)%n",
     *                     id, event.getLatitude(), event.getLongitude());
     *             }
     *         }
     *     });
     * }
     * </pre>
     *
     * @param entityIds the entity UUIDs to look up (max 10,000 per call)
     * @return a future containing map of entity_id to GeoEvent (null values for not found)
     * @throws ValidationException if batch exceeds 10,000 UUIDs
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see #getLatestByUuidAsync(UInt128)
     */
    public CompletableFuture<Map<UInt128, GeoEvent>> lookupBatchAsync(List<UInt128> entityIds) {
        return CompletableFuture.supplyAsync(() -> delegate.lookupBatch(entityIds), executor);
    }

    /**
     * Queries events within a circular radius asynchronously.
     *
     * <p>
     * Returns events within the specified radius of the center point, ordered by timestamp
     * (descending). Use pagination with {@link QueryResult#hasMore()} and cursor-based continuation
     * for large result sets.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * QueryRadiusFilter filter = QueryRadiusFilter.builder()
     *     .setCenter(37.7749, -122.4194)
     *     .setRadiusMeters(5000)
     *     .setLimit(100)
     *     .build();
     *
     * client.queryRadiusAsync(filter)
     *     .thenAccept(result -> {
     *         System.out.println("Found " + result.getEvents().size() + " events");
     *         for (GeoEvent event : result.getEvents()) {
     *             System.out.printf("Entity %s at (%.6f, %.6f)%n",
     *                 event.getEntityId(),
     *                 event.getLatitude(),
     *                 event.getLongitude());
     *         }
     *     });
     * }
     * </pre>
     *
     * @param filter the radius query filter specifying center, radius, and optional constraints
     * @return a future containing query result with matched events and pagination info
     * @throws ValidationException if coordinates are out of range or radius is invalid
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see QueryRadiusFilter
     * @see #queryPolygonAsync(QueryPolygonFilter)
     */
    public CompletableFuture<QueryResult> queryRadiusAsync(QueryRadiusFilter filter) {
        return CompletableFuture.supplyAsync(() -> delegate.queryRadius(filter), executor);
    }

    /**
     * Queries events within a radius asynchronously with per-operation options.
     *
     * @param filter the radius query filter
     * @param options per-operation options (null for defaults)
     * @return a future containing the query result
     * @see #queryRadiusAsync(QueryRadiusFilter)
     */
    public CompletableFuture<QueryResult> queryRadiusAsync(QueryRadiusFilter filter,
            OperationOptions options) {
        return CompletableFuture.supplyAsync(() -> delegate.queryRadius(filter, options), executor);
    }

    /**
     * Queries events within a polygon asynchronously.
     *
     * <p>
     * Returns events within the specified polygon (geofence), ordered by timestamp (descending).
     * Polygon vertices must be in counter-clockwise order. Holes use clockwise winding.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * QueryPolygonFilter filter = QueryPolygonFilter.builder()
     *     .addVertex(37.78, -122.42)
     *     .addVertex(37.78, -122.40)
     *     .addVertex(37.76, -122.40)
     *     .addVertex(37.76, -122.42)
     *     .setLimit(100)
     *     .build();
     *
     * client.queryPolygonAsync(filter)
     *     .thenAccept(result -> {
     *         System.out.println("Found " + result.getEvents().size() + " events in geofence");
     *     });
     * }
     * </pre>
     *
     * @param filter the polygon query filter specifying vertices and optional constraints
     * @return a future containing query result with matched events and pagination info
     * @throws ValidationException if polygon is invalid (self-intersecting, degenerate, etc.)
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see QueryPolygonFilter
     * @see #queryRadiusAsync(QueryRadiusFilter)
     */
    public CompletableFuture<QueryResult> queryPolygonAsync(QueryPolygonFilter filter) {
        return CompletableFuture.supplyAsync(() -> delegate.queryPolygon(filter), executor);
    }

    /**
     * Queries events within a polygon asynchronously with per-operation options.
     *
     * @param filter the polygon query filter
     * @param options per-operation options (null for defaults)
     * @return a future containing the query result
     * @see #queryPolygonAsync(QueryPolygonFilter)
     */
    public CompletableFuture<QueryResult> queryPolygonAsync(QueryPolygonFilter filter,
            OperationOptions options) {
        return CompletableFuture.supplyAsync(() -> delegate.queryPolygon(filter, options),
                executor);
    }

    /**
     * Queries the most recent events globally or by group asynchronously.
     *
     * <p>
     * Returns the latest events, optionally filtered by group ID and time range.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * QueryLatestFilter filter = QueryLatestFilter.builder()
     *     .setLimit(100)
     *     .setGroupId(1L)
     *     .build();
     *
     * client.queryLatestAsync(filter)
     *     .thenAccept(result -> {
     *         System.out.println("Latest events in group 1:");
     *         for (GeoEvent event : result.getEvents()) {
     *             System.out.printf("  Entity %s: (%.6f, %.6f)%n",
     *                 event.getEntityId(),
     *                 event.getLatitude(),
     *                 event.getLongitude());
     *         }
     *     });
     * }
     * </pre>
     *
     * @param filter the query filter specifying limit and optional group filter
     * @return a future containing query result with matched events and pagination info
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see QueryLatestFilter
     */
    public CompletableFuture<QueryResult> queryLatestAsync(QueryLatestFilter filter) {
        return CompletableFuture.supplyAsync(() -> delegate.queryLatest(filter), executor);
    }

    /**
     * Queries the latest events asynchronously with per-operation options.
     *
     * @param filter the query filter
     * @param options per-operation options (null for defaults)
     * @return a future containing the query result
     * @see #queryLatestAsync(QueryLatestFilter)
     */
    public CompletableFuture<QueryResult> queryLatestAsync(QueryLatestFilter filter,
            OperationOptions options) {
        return CompletableFuture.supplyAsync(() -> delegate.queryLatest(filter, options), executor);
    }

    // ============================================================================
    // TTL Operations
    // ============================================================================

    /**
     * Sets an absolute TTL for an entity asynchronously.
     *
     * <p>
     * Sets the entity's time-to-live to the specified value in seconds. A TTL of 0 means the entity
     * never expires.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * // Set 24-hour TTL
     * client.setTtlAsync(entityId, 86400)
     *     .thenAccept(response -> {
     *         System.out.println("Previous TTL: " + response.getPreviousTtlSeconds());
     *         System.out.println("New TTL: " + response.getNewTtlSeconds());
     *     });
     * }
     * </pre>
     *
     * @param entityId the entity UUID to set TTL for
     * @param ttlSeconds the absolute TTL in seconds (0 = never expires)
     * @return a future containing TTL set response with previous and new TTL values
     * @throws IllegalArgumentException if entityId is null/zero or ttlSeconds is negative
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #extendTtlAsync(UInt128, int)
     * @see #clearTtlAsync(UInt128)
     */
    public CompletableFuture<TtlSetResponse> setTtlAsync(UInt128 entityId, int ttlSeconds) {
        return CompletableFuture.supplyAsync(() -> delegate.setTtl(entityId, ttlSeconds), executor);
    }

    /**
     * Extends an entity's TTL by a relative amount asynchronously.
     *
     * <p>
     * Adds the specified seconds to the entity's current TTL. If the entity has no TTL, sets it to
     * the extension amount.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * // Extend TTL by 1 hour
     * client.extendTtlAsync(entityId, 3600)
     *     .thenAccept(response -> {
     *         System.out.println("TTL extended from " + response.getPreviousTtlSeconds()
     *             + " to " + response.getNewTtlSeconds() + " seconds");
     *     });
     * }
     * </pre>
     *
     * @param entityId the entity UUID to extend TTL for
     * @param extendBySeconds number of seconds to extend the TTL by
     * @return a future containing TTL extend response with previous and new TTL values
     * @throws IllegalArgumentException if entityId is null/zero or extendBySeconds is negative
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #setTtlAsync(UInt128, int)
     * @see #clearTtlAsync(UInt128)
     */
    public CompletableFuture<TtlExtendResponse> extendTtlAsync(UInt128 entityId,
            int extendBySeconds) {
        return CompletableFuture.supplyAsync(() -> delegate.extendTtl(entityId, extendBySeconds),
                executor);
    }

    /**
     * Clears an entity's TTL, making it never expire, asynchronously.
     *
     * <p>
     * Removes the entity's TTL (sets to 0). The entity will not expire until a TTL is set again.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * client.clearTtlAsync(entityId)
     *     .thenAccept(response -> {
     *         System.out.println("Cleared TTL (was " + response.getPreviousTtlSeconds() + "s)");
     *     });
     * }
     * </pre>
     *
     * @param entityId the entity UUID to clear TTL for
     * @return a future containing TTL clear response with previous TTL value
     * @throws IllegalArgumentException if entityId is null or zero
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #setTtlAsync(UInt128, int)
     * @see #extendTtlAsync(UInt128, int)
     */
    public CompletableFuture<TtlClearResponse> clearTtlAsync(UInt128 entityId) {
        return CompletableFuture.supplyAsync(() -> delegate.clearTtl(entityId), executor);
    }

    /**
     * Triggers explicit TTL expiration cleanup asynchronously.
     *
     * <p>
     * Scans the index for expired entries and removes them. The cleanup goes through VSR consensus
     * so all replicas apply with the same timestamp.
     *
     * @param batchSize number of index entries to scan (0 = scan all)
     * @return a future containing cleanup result with entries scanned and removed
     * @throws IllegalArgumentException if batchSize is negative
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     */
    public CompletableFuture<CleanupResult> cleanupExpiredAsync(int batchSize) {
        return CompletableFuture.supplyAsync(() -> delegate.cleanupExpired(batchSize), executor);
    }

    /**
     * Triggers explicit TTL expiration cleanup (scan all entries) asynchronously.
     *
     * @return a future containing cleanup result with entries scanned and removed
     * @see #cleanupExpiredAsync(int)
     */
    public CompletableFuture<CleanupResult> cleanupExpiredAsync() {
        return CompletableFuture.supplyAsync(() -> delegate.cleanupExpired(), executor);
    }

    // ============================================================================
    // Admin Operations
    // ============================================================================

    /**
     * Sends a ping to verify server connectivity asynchronously.
     *
     * <p>
     * Use this to check if the cluster is reachable and responding.
     *
     * @return a future containing true if server responded, false otherwise
     */
    public CompletableFuture<Boolean> pingAsync() {
        return CompletableFuture.supplyAsync(() -> delegate.ping(), executor);
    }

    /**
     * Returns current server status asynchronously.
     *
     * <p>
     * Provides metrics about the cluster including RAM index count, capacity, tombstones, and TTL
     * expirations.
     *
     * @return a future containing the server status response
     * @throws ConnectionException if cluster connection fails
     */
    public CompletableFuture<StatusResponse> getStatusAsync() {
        return CompletableFuture.supplyAsync(() -> delegate.getStatus(), executor);
    }

    /**
     * Fetches the current cluster topology asynchronously.
     *
     * <p>
     * Returns information about all shards, their primaries, replicas, and status.
     *
     * @return a future containing topology response with shard information
     * @throws ConnectionException if cluster connection fails
     */
    public CompletableFuture<TopologyResponse> getTopologyAsync() {
        return CompletableFuture.supplyAsync(() -> delegate.getTopology(), executor);
    }

    /**
     * Forces a topology refresh from the cluster asynchronously.
     *
     * @return a future containing updated topology response
     * @throws ConnectionException if cluster connection fails
     */
    public CompletableFuture<TopologyResponse> refreshTopologyAsync() {
        return CompletableFuture.supplyAsync(() -> delegate.refreshTopology(), executor);
    }

    /**
     * Closes the client and releases resources.
     *
     * <p>
     * After calling close, all pending async operations will fail. The underlying synchronous
     * client is also closed.
     */
    @Override
    public void close() {
        delegate.close();
    }
}
