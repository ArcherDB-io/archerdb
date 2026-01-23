package com.archerdb.geo;

import java.util.List;

/**
 * ArcherDB geospatial client interface.
 *
 * <p>
 * Provides methods for inserting, querying, and deleting geospatial events in an ArcherDB cluster.
 * The client handles connection management, retries, and topology discovery automatically.
 *
 * <p>
 * <b>Thread Safety:</b> All implementations of this interface are thread-safe. A single instance
 * should be shared across threads. Each client maintains a connection pool and handles concurrent
 * requests efficiently.
 *
 * <p>
 * <b>Lifecycle:</b> Clients implement {@link AutoCloseable} and should be used with
 * try-with-resources:
 *
 * <pre>
 * {@code
 * try (GeoClient client = GeoClient.create(0L, "127.0.0.1:3001")) {
 *     // Use client
 * }
 * }
 * </pre>
 *
 * <p>
 * <b>Example - Insert and query:</b>
 *
 * <pre>
 * {@code
 * try (GeoClient client = GeoClient.create(0, "127.0.0.1:3000")) {
 *     // Insert events
 *     GeoEventBatch batch = client.createBatch();
 *     batch.add(new GeoEvent.Builder()
 *         .setEntityId(UInt128.random())
 *         .setLatitude(37.7749)
 *         .setLongitude(-122.4194)
 *         .build());
 *     batch.commit();
 *
 *     // Query by radius
 *     QueryResult result = client.queryRadius(
 *         QueryRadiusFilter.create(37.7749, -122.4194, 1000, 100)
 *     );
 *     for (GeoEvent event : result.getEvents()) {
 *         System.out.println(event);
 *     }
 * }
 * }
 * </pre>
 *
 * @see GeoClientAsync for asynchronous operations with CompletableFuture
 * @see GeoClientImpl for the default implementation
 */
public interface GeoClient extends AutoCloseable {

    /**
     * Creates a new batch for inserting events.
     *
     * <p>
     * Use batches for efficient bulk inserts. Events are buffered locally until
     * {@link GeoEventBatch#commit()} is called, which sends them to the cluster atomically.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     GeoEventBatch batch = client.createBatch();
     *     batch.add(event1);
     *     batch.add(event2);
     *     batch.commit(); // All events sent atomically
     * }
     * </pre>
     *
     * @return a new batch builder for insert operations
     * @throws IllegalStateException if the client has been closed
     * @see #createUpsertBatch()
     * @see GeoEventBatch
     */
    GeoEventBatch createBatch();

    /**
     * Creates a new batch for upserting events.
     *
     * <p>
     * Upsert batches insert new events or update existing ones based on entity ID. If an event with
     * the same entity ID exists, it is replaced using last-writer-wins (LWW) semantics.
     *
     * @return a new batch builder for upsert operations
     * @throws IllegalStateException if the client has been closed
     * @see #createBatch()
     * @see GeoEventBatch
     */
    GeoEventBatch createUpsertBatch();

    /**
     * Creates a new batch for deleting entities.
     *
     * <p>
     * Use delete batches for GDPR-compliant bulk deletion. All events for specified entities are
     * permanently removed.
     *
     * @return a new delete batch builder
     * @throws IllegalStateException if the client has been closed
     * @see DeleteEntityBatch
     */
    DeleteEntityBatch createDeleteBatch();

    /**
     * Inserts a single event.
     *
     * <p>
     * Convenience method equivalent to {@code insertEvents(List.of(event))}. For bulk inserts, use
     * {@link #insertEvents(List)} or {@link #createBatch()} for better performance.
     *
     * @param event the event to insert (must not be null)
     * @return list of errors (empty if insertion succeeded)
     * @throws IllegalArgumentException if event is null
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #insertEvents(List)
     * @see #createBatch()
     */
    List<InsertGeoEventsError> insertEvent(GeoEvent event);

    /**
     * Inserts multiple events.
     *
     * <p>
     * Events are replicated to the cluster and durably persisted before returning. The returned
     * list contains errors for any events that failed to insert - an empty list indicates all
     * events were inserted successfully.
     *
     * <p>
     * <b>Batch limits:</b> Maximum 10,000 events per call. For larger datasets, split into multiple
     * calls or use {@link #createBatch()}.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     List<GeoEvent> events = createEvents();
     *     List<InsertGeoEventsError> errors = client.insertEvents(events);
     *
     *     if (errors.isEmpty()) {
     *         System.out.println("All events inserted!");
     *     } else {
     *         for (InsertGeoEventsError error : errors) {
     *             System.err.println("Event " + error.getIndex() + " failed: " + error.getResult());
     *         }
     *     }
     * }
     * </pre>
     *
     * @param events the events to insert (max 10,000 per call)
     * @return list of errors for failed events (empty if all succeeded)
     * @throws IllegalArgumentException if events is null
     * @throws ValidationException if batch exceeds 10,000 events
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #insertEvent(GeoEvent)
     * @see #upsertEvents(List)
     * @see GeoClientAsync#insertEventsAsync(List) for async version
     */
    List<InsertGeoEventsError> insertEvents(List<GeoEvent> events);

    /**
     * Inserts multiple events with per-operation options.
     *
     * <p>
     * Allows customizing retry behavior for individual operations. Use this when you need different
     * timeout or retry settings than the client defaults.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Custom retry: 3 attempts, 10 second timeout
     *     OperationOptions options = OperationOptions.with(3, 10000);
     *     List<InsertGeoEventsError> errors = client.insertEvents(events, options);
     * }
     * </pre>
     *
     * @param events the events to insert
     * @param options per-operation options (null for defaults)
     * @return list of errors for failed events (empty if all succeeded)
     * @throws ValidationException if batch exceeds 10,000 events
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #insertEvents(List)
     * @see OperationOptions
     */
    default List<InsertGeoEventsError> insertEvents(List<GeoEvent> events,
            OperationOptions options) {
        // Default implementation ignores options - subclasses may override
        return insertEvents(events);
    }

    /**
     * Upserts multiple events.
     *
     * <p>
     * Upsert inserts new events or updates existing ones based on entity ID. If an event with the
     * same entity ID exists, it is replaced with the new event using last-writer-wins (LWW)
     * semantics based on timestamp.
     *
     * <p>
     * Use upsert when you want to update entity locations without checking for existence first.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Update vehicle locations - existing positions are replaced
     *     List<GeoEvent> locationUpdates = getVehicleUpdates();
     *     List<InsertGeoEventsError> errors = client.upsertEvents(locationUpdates);
     * }
     * </pre>
     *
     * @param events the events to upsert (max 10,000 per call)
     * @return list of errors for failed events (empty if all succeeded)
     * @throws IllegalArgumentException if events is null
     * @throws ValidationException if batch exceeds 10,000 events
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #insertEvents(List)
     * @see GeoClientAsync#upsertEventsAsync(List) for async version
     */
    List<InsertGeoEventsError> upsertEvents(List<GeoEvent> events);

    /**
     * Upserts multiple events with per-operation options.
     *
     * @param events the events to upsert
     * @param options per-operation options (null for defaults)
     * @return list of errors for failed events (empty if all succeeded)
     * @throws ValidationException if batch exceeds 10,000 events
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #upsertEvents(List)
     */
    default List<InsertGeoEventsError> upsertEvents(List<GeoEvent> events,
            OperationOptions options) {
        // Default implementation ignores options - subclasses may override
        return upsertEvents(events);
    }

    /**
     * Deletes entities by their IDs.
     *
     * <p>
     * GDPR-compliant deletion of all events for specified entities. The deletion is replicated and
     * durable once this method returns. Deleted entities cannot be recovered.
     *
     * <p>
     * <b>Batch limits:</b> Maximum 10,000 entity IDs per call.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     List<UInt128> entityIds = Arrays.asList(entityId1, entityId2, entityId3);
     *     DeleteResult result = client.deleteEntities(entityIds);
     *     System.out.println("Deleted: " + result.getDeletedCount());
     *     System.out.println("Not found: " + result.getNotFoundCount());
     * }
     * </pre>
     *
     * @param entityIds the entity IDs to delete (max 10,000 per call)
     * @return delete result with counts of deleted and not-found entities
     * @throws IllegalArgumentException if entityIds is null
     * @throws ValidationException if batch exceeds 10,000 entity IDs
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see DeleteResult
     * @see GeoClientAsync#deleteEntitiesAsync(List) for async version
     */
    DeleteResult deleteEntities(List<UInt128> entityIds);

    /**
     * Deletes entities by their IDs with per-operation options.
     *
     * @param entityIds the entity IDs to delete
     * @param options per-operation options (null for defaults)
     * @return delete result with counts
     * @throws ValidationException if batch exceeds 10,000 entity IDs
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #deleteEntities(List)
     */
    default DeleteResult deleteEntities(List<UInt128> entityIds, OperationOptions options) {
        // Default implementation ignores options - subclasses may override
        return deleteEntities(entityIds);
    }

    /**
     * Looks up the latest event for an entity by UUID.
     *
     * <p>
     * Returns the most recent event for the given entity, or null if the entity is not found.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     GeoEvent event = client.getLatestByUuid(entityId);
     *     if (event != null) {
     *         System.out.printf("Last seen at (%.6f, %.6f)%n", event.getLatitude(),
     *                 event.getLongitude());
     *     } else {
     *         System.out.println("Entity not found");
     *     }
     * }
     * </pre>
     *
     * @param entityId the entity UUID to look up
     * @return the latest event for the entity, or null if not found
     * @throws IllegalArgumentException if entityId is null
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out, entity is expired (code 210), or fails
     * @see #lookupBatch(List) for batch lookups
     * @see GeoClientAsync#getLatestByUuidAsync(UInt128) for async version
     */
    GeoEvent getLatestByUuid(UInt128 entityId);

    /**
     * Queries events within a circular radius of a center point.
     *
     * <p>
     * Events are returned in descending timestamp order. Use pagination with
     * {@link QueryResult#hasMore()} and cursor-based continuation for large result sets.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     QueryRadiusFilter filter = QueryRadiusFilter.builder().setCenter(37.7749, -122.4194) // San
     *                                                                                          // Francisco
     *             .setRadiusMeters(5000) // 5km radius
     *             .setLimit(100) // Max 100 results
     *             .setTimestampMin(startNs) // Optional time filter
     *             .setTimestampMax(endNs).setGroupId(1L) // Optional group filter
     *             .build();
     *
     *     QueryResult result = client.queryRadius(filter);
     *     for (GeoEvent event : result.getEvents()) {
     *         System.out.printf("Entity %s at (%.6f, %.6f)%n", event.getEntityId(),
     *                 event.getLatitude(), event.getLongitude());
     *     }
     *
     *     // Pagination
     *     if (result.hasMore()) {
     *         QueryRadiusFilter nextFilter = QueryRadiusFilter.builder().setCenter(37.7749, -122.4194)
     *                 .setRadiusMeters(5000).setLimit(100).setTimestampMax(result.getCursor() - 1) // Continue
     *                                                                                              // from
     *                                                                                              // cursor
     *                 .build();
     *         QueryResult nextResult = client.queryRadius(nextFilter);
     *     }
     * }
     * </pre>
     *
     * @param filter the radius query filter specifying center, radius, and optional constraints
     * @return query result containing matched events and pagination info
     * @throws IllegalArgumentException if filter is null
     * @throws ValidationException if coordinates are out of range (lat: -90 to 90, lon: -180 to
     *         180) or radius is invalid (zero or too large)
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see QueryRadiusFilter
     * @see QueryResult
     * @see #queryPolygon(QueryPolygonFilter)
     * @see GeoClientAsync#queryRadiusAsync(QueryRadiusFilter) for async version
     */
    QueryResult queryRadius(QueryRadiusFilter filter);

    /**
     * Queries events within a radius with per-operation options.
     *
     * @param filter the radius query filter
     * @param options per-operation options (null for defaults)
     * @return query result with events
     * @throws ValidationException if coordinates or radius are invalid
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see #queryRadius(QueryRadiusFilter)
     */
    default QueryResult queryRadius(QueryRadiusFilter filter, OperationOptions options) {
        return queryRadius(filter);
    }

    /**
     * Queries events within a polygon (geofence).
     *
     * <p>
     * Events are returned in descending timestamp order. Polygon vertices must be in
     * counter-clockwise order (exterior ring). Holes use clockwise winding per GeoJSON convention.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Define a geofence around downtown SF
     *     QueryPolygonFilter filter = QueryPolygonFilter.builder().addVertex(37.78, -122.42)
     *             .addVertex(37.78, -122.40).addVertex(37.76, -122.40).addVertex(37.76, -122.42)
     *             .setLimit(100).setTimestampMin(startNs).setTimestampMax(endNs).build();
     *
     *     QueryResult result = client.queryPolygon(filter);
     *     System.out.println("Found " + result.getEvents().size() + " events in geofence");
     * }
     * </pre>
     *
     * @param filter the polygon query filter specifying vertices and optional constraints
     * @return query result containing matched events and pagination info
     * @throws IllegalArgumentException if filter is null
     * @throws ValidationException if polygon is invalid (self-intersecting, degenerate, too few
     *         vertices, too large, or holes invalid)
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see QueryPolygonFilter
     * @see QueryResult
     * @see #queryRadius(QueryRadiusFilter)
     * @see GeoClientAsync#queryPolygonAsync(QueryPolygonFilter) for async version
     */
    QueryResult queryPolygon(QueryPolygonFilter filter);

    /**
     * Queries events within a polygon with per-operation options.
     *
     * @param filter the polygon query filter
     * @param options per-operation options (null for defaults)
     * @return query result with events
     * @throws ValidationException if polygon is invalid
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see #queryPolygon(QueryPolygonFilter)
     */
    default QueryResult queryPolygon(QueryPolygonFilter filter, OperationOptions options) {
        return queryPolygon(filter);
    }

    /**
     * Queries the most recent events globally or by group.
     *
     * <p>
     * Returns the latest events, optionally filtered by group ID and time range. Events are ordered
     * by timestamp descending.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     QueryLatestFilter filter = QueryLatestFilter.builder().setLimit(100).setGroupId(1L) // Filter
     *                                                                                         // by
     *                                                                                         // fleet/region
     *                                                                                         // group
     *             .build();
     *
     *     QueryResult result = client.queryLatest(filter);
     *     for (GeoEvent event : result.getEvents()) {
     *         System.out.printf("Entity %s: (%.6f, %.6f) at %d%n", event.getEntityId(),
     *                 event.getLatitude(), event.getLongitude(), event.getTimestamp());
     *     }
     * }
     * </pre>
     *
     * @param filter the query filter specifying limit and optional group/time constraints
     * @return query result containing matched events and pagination info
     * @throws IllegalArgumentException if filter is null
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see QueryLatestFilter
     * @see QueryResult
     * @see GeoClientAsync#queryLatestAsync(QueryLatestFilter) for async version
     */
    QueryResult queryLatest(QueryLatestFilter filter);

    /**
     * Queries the most recent events with per-operation options.
     *
     * @param filter the query filter
     * @param options per-operation options (null for defaults)
     * @return query result with events
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see #queryLatest(QueryLatestFilter)
     */
    default QueryResult queryLatest(QueryLatestFilter filter, OperationOptions options) {
        return queryLatest(filter);
    }

    /**
     * Looks up multiple entities by UUID in a single batch request.
     *
     * <p>
     * More efficient than multiple {@link #getLatestByUuid(UInt128)} calls when looking up many
     * entities. Returns a map where keys are entity IDs and values are their latest events (null if
     * not found).
     *
     * <p>
     * <b>Batch limits:</b> Maximum 10,000 UUIDs per request. Duplicate UUIDs are allowed.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     List<UInt128> ids = Arrays.asList(id1, id2, id3);
     *     Map<UInt128, GeoEvent> results = client.lookupBatch(ids);
     *
     *     for (UInt128 id : ids) {
     *         GeoEvent event = results.get(id);
     *         if (event != null) {
     *             System.out.printf("Entity %s at (%.6f, %.6f)%n", id, event.getLatitude(),
     *                     event.getLongitude());
     *         } else {
     *             System.out.println("Entity " + id + " not found");
     *         }
     *     }
     * }
     * </pre>
     *
     * @param entityIds the entity UUIDs to look up (max 10,000)
     * @return map of entity_id to GeoEvent (null values for entities not found)
     * @throws IllegalArgumentException if entityIds is null or exceeds 10,000
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the query times out or fails
     * @see #getLatestByUuid(UInt128)
     * @see GeoClientAsync#lookupBatchAsync(List) for async version
     */
    java.util.Map<UInt128, GeoEvent> lookupBatch(List<UInt128> entityIds);

    /**
     * Triggers explicit TTL expiration cleanup.
     *
     * <p>
     * Scans the index for expired entries and removes them. This operation goes through VSR
     * consensus, ensuring all replicas apply the cleanup with the same timestamp for deterministic
     * behavior.
     *
     * <p>
     * <b>Note:</b> TTL cleanup also happens automatically during normal operations. Use this method
     * for explicit cleanup when needed (e.g., after bulk TTL updates).
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Scan first 10000 entries
     *     CleanupResult result = client.cleanupExpired(10000);
     *     System.out.println("Scanned: " + result.getEntriesScanned());
     *     System.out.println("Removed: " + result.getEntriesRemoved());
     *
     *     // Full cleanup
     *     CleanupResult fullResult = client.cleanupExpired(); // or cleanupExpired(0)
     * }
     * </pre>
     *
     * @param batchSize number of index entries to scan (0 = scan all)
     * @return cleanup result with entries scanned and removed counts
     * @throws IllegalArgumentException if batchSize is negative
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see CleanupResult
     * @see #setTtl(UInt128, int)
     */
    CleanupResult cleanupExpired(int batchSize);

    /**
     * Triggers explicit TTL expiration cleanup (scan all entries).
     *
     * <p>
     * Convenience method equivalent to {@code cleanupExpired(0)}.
     *
     * @return cleanup result with entries scanned and removed
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if the operation times out or fails
     * @see #cleanupExpired(int)
     */
    default CleanupResult cleanupExpired() {
        return cleanupExpired(0);
    }

    // ============================================================================
    // TTL Operations (v2.1 Manual TTL Support)
    // ============================================================================

    /**
     * Sets an absolute TTL for an entity.
     *
     * <p>
     * Sets the entity's time-to-live to the specified value in seconds. A TTL of 0 means the entity
     * never expires. This operation replaces any existing TTL.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Set 24-hour TTL
     *     TtlSetResponse response = client.setTtl(entityId, 86400);
     *     System.out.println("Previous TTL: " + response.getPreviousTtlSeconds());
     *     System.out.println("New TTL: " + response.getNewTtlSeconds());
     *
     *     // Make entity permanent (no expiration)
     *     client.setTtl(entityId, 0);
     * }
     * </pre>
     *
     * @param entityId the entity UUID to set TTL for
     * @param ttlSeconds the absolute TTL in seconds (0 = never expires)
     * @return TTL set response with previous and new TTL values
     * @throws IllegalArgumentException if entityId is null/zero or ttlSeconds is negative
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if entity not found or operation fails
     * @see #extendTtl(UInt128, int)
     * @see #clearTtl(UInt128)
     * @see GeoClientAsync#setTtlAsync(UInt128, int) for async version
     */
    TtlSetResponse setTtl(UInt128 entityId, int ttlSeconds);

    /**
     * Extends an entity's TTL by a relative amount.
     *
     * <p>
     * Adds the specified seconds to the entity's current TTL. If the entity has no TTL (0), this
     * sets the TTL to the extension amount. Use this to "keep alive" entities that are still
     * active.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Extend TTL by 1 hour on each activity
     *     TtlExtendResponse response = client.extendTtl(entityId, 3600);
     *     System.out.println("TTL extended from " + response.getPreviousTtlSeconds() + " to "
     *             + response.getNewTtlSeconds() + " seconds");
     * }
     * </pre>
     *
     * @param entityId the entity UUID to extend TTL for
     * @param extendBySeconds number of seconds to extend the TTL by
     * @return TTL extend response with previous and new TTL values
     * @throws IllegalArgumentException if entityId is null/zero or extendBySeconds is negative
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if entity not found or operation fails
     * @see #setTtl(UInt128, int)
     * @see #clearTtl(UInt128)
     * @see GeoClientAsync#extendTtlAsync(UInt128, int) for async version
     */
    TtlExtendResponse extendTtl(UInt128 entityId, int extendBySeconds);

    /**
     * Clears an entity's TTL, making it never expire.
     *
     * <p>
     * Removes the entity's TTL (sets to 0). The entity will not expire until a TTL is set again.
     * Use this to make previously-expiring entities permanent.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Make entity permanent (no expiration)
     *     TtlClearResponse response = client.clearTtl(entityId);
     *     System.out.println("Cleared TTL (was " + response.getPreviousTtlSeconds() + "s)");
     * }
     * </pre>
     *
     * @param entityId the entity UUID to clear TTL for
     * @return TTL clear response with previous TTL value
     * @throws IllegalArgumentException if entityId is null or zero
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @throws OperationException if entity not found or operation fails
     * @see #setTtl(UInt128, int)
     * @see #extendTtl(UInt128, int)
     * @see GeoClientAsync#clearTtlAsync(UInt128) for async version
     */
    TtlClearResponse clearTtl(UInt128 entityId);

    // ============================================================================
    // Admin Operations
    // ============================================================================

    /**
     * Sends a ping to verify server connectivity.
     *
     * <p>
     * Use this to check if the cluster is reachable and responding. The ping is a lightweight
     * operation that doesn't affect data.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {@code
     * if (client.ping()) {
     *     System.out.println("Cluster is healthy");
     * } else {
     *     System.out.println("Cluster not responding");
     * }
     * }
     * </pre>
     *
     * @return true if server responded successfully, false otherwise
     * @throws IllegalStateException if the client has been closed
     * @see GeoClientAsync#pingAsync() for async version
     */
    boolean ping();

    /**
     * Returns current server status.
     *
     * <p>
     * Provides metrics about the cluster including RAM index count, capacity, load percentage,
     * tombstone count, and TTL expiration statistics.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     StatusResponse status = client.getStatus();
     *     System.out.println("Index entries: " + status.getRamIndexCount());
     *     System.out.println("Capacity: " + status.getRamIndexCapacity());
     *     System.out.println("Load: " + status.getRamIndexLoadPct() + "%");
     *     System.out.println("Tombstones: " + status.getTombstoneCount());
     * }
     * </pre>
     *
     * @return server status response with cluster metrics
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @see StatusResponse
     * @see GeoClientAsync#getStatusAsync() for async version
     */
    StatusResponse getStatus();

    /**
     * Fetches the current cluster topology.
     *
     * <p>
     * Returns information about all shards in the cluster including their primaries, replicas,
     * status, entity counts, and sizes. Use this for monitoring and debugging.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     TopologyResponse topology = client.getTopology();
     *     System.out.println("Cluster version: " + topology.getVersion());
     *     System.out.println("Shards: " + topology.getNumShards());
     *
     *     for (ShardInfo shard : topology.getShards()) {
     *         System.out.printf("Shard %d: %s (status: %s, entities: %d)%n", shard.getShardId(),
     *                 shard.getPrimary(), shard.getStatus(), shard.getEntityCount());
     *     }
     * }
     * </pre>
     *
     * @return topology response with shard information
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @see TopologyResponse
     * @see ShardInfo
     * @see GeoClientAsync#getTopologyAsync() for async version
     */
    TopologyResponse getTopology();

    /**
     * Returns the topology cache for direct access.
     *
     * <p>
     * The topology cache maintains a local copy of cluster topology for efficient routing. It is
     * automatically refreshed when stale.
     *
     * @return the topology cache
     * @throws IllegalStateException if the client has been closed
     * @see TopologyCache
     */
    TopologyCache getTopologyCache();

    /**
     * Forces a topology refresh from the cluster.
     *
     * <p>
     * Explicitly refreshes the topology cache, bypassing staleness checks. Use after detecting
     * topology changes (e.g., receiving NOT_SHARD_LEADER errors).
     *
     * @return updated topology response
     * @throws IllegalStateException if the client has been closed
     * @throws ConnectionException if cluster connection fails
     * @see #getTopology()
     * @see GeoClientAsync#refreshTopologyAsync() for async version
     */
    TopologyResponse refreshTopology();

    /**
     * Returns a shard router for shard-aware operations.
     *
     * <p>
     * The shard router uses jump consistent hashing to route operations to the correct shard based
     * on entity ID. Most applications don't need direct router access.
     *
     * @return the shard router
     * @throws IllegalStateException if the client has been closed
     * @see ShardRouter
     */
    ShardRouter getShardRouter();

    /**
     * Closes the client and releases resources.
     *
     * <p>
     * After calling close, all operations will throw {@link IllegalStateException}. Any pending
     * operations may fail. Use try-with-resources for automatic cleanup:
     *
     * <pre>
     * {@code
     * try (GeoClient client = GeoClient.create(0L, "127.0.0.1:3001")) {
     *     // Use client
     * }  // Automatically closed
     * }
     * </pre>
     */
    @Override
    void close();

    // ============================================================================
    // Factory Methods
    // ============================================================================

    /**
     * Creates a new GeoClient connected to the specified cluster.
     *
     * <p>
     * This is the simplest way to create a client for a single-region cluster.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Single-node cluster
     *     GeoClient client = GeoClient.create(0L, "127.0.0.1:3001");
     *
     *     // Multi-node cluster
     *     GeoClient client = GeoClient.create(0L, "10.0.0.1:3001", "10.0.0.2:3001", "10.0.0.3:3001");
     * }
     * </pre>
     *
     * @param clusterId the cluster ID (must match server configuration)
     * @param addresses replica addresses in host:port format
     * @return a new client connected to the cluster
     * @throws IllegalArgumentException if addresses is null or empty
     * @see #create(UInt128, String...)
     * @see #create(ClientConfig)
     */
    static GeoClient create(long clusterId, String... addresses) {
        return new GeoClientImpl(UInt128.fromLong(clusterId), addresses);
    }

    /**
     * Creates a new GeoClient with a 128-bit cluster ID.
     *
     * <p>
     * Use this when your cluster ID exceeds 64 bits or for explicit UInt128 handling.
     *
     * @param clusterId the 128-bit cluster ID
     * @param addresses replica addresses in host:port format
     * @return a new client connected to the cluster
     * @throws IllegalArgumentException if clusterId is null or addresses is null/empty
     * @see #create(long, String...)
     */
    static GeoClient create(UInt128 clusterId, String... addresses) {
        return new GeoClientImpl(clusterId, addresses);
    }

    /**
     * Creates a new multi-region GeoClient from configuration.
     *
     * <p>
     * Use this for multi-region deployments with read preference routing. The client automatically
     * routes writes to the primary region and reads according to the configured preference.
     *
     * <p>
     * Example:
     *
     * <pre>
     * {
     *     &#64;code
     *     ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
     *             .addRegion(RegionConfig.primary("us-west-2", "10.0.0.1:3001", "10.0.0.2:3001"))
     *             .addRegion(RegionConfig.follower("eu-west-1", "10.1.0.1:3001", "10.1.0.2:3001"))
     *             .setReadPreference(ReadPreference.NEAREST).build();
     *
     *     try (GeoClient client = GeoClient.create(config)) {
     *         // Writes go to us-west-2, reads go to nearest region
     *         client.insertEvents(events); // -> us-west-2
     *         client.queryRadius(filter); // -> nearest region
     *     }
     * }
     * </pre>
     *
     * @param config the multi-region client configuration
     * @return a new multi-region client
     * @throws IllegalArgumentException if config is null or invalid
     * @see ClientConfig
     * @see RegionConfig
     * @see ReadPreference
     */
    static GeoClient create(ClientConfig config) {
        return new MultiRegionGeoClient(config);
    }

    /**
     * Returns the current client configuration, or null for single-region clients.
     *
     * @return the client configuration, or null for simple clients
     * @see ClientConfig
     */
    default ClientConfig getConfig() {
        return null;
    }

    /**
     * Returns the current read preference.
     *
     * <p>
     * For single-region clients, always returns {@link ReadPreference#PRIMARY}. For multi-region
     * clients, returns the configured read preference.
     *
     * @return the current read preference
     * @see ReadPreference
     */
    default ReadPreference getReadPreference() {
        return ReadPreference.PRIMARY;
    }
}
