package com.archerdb.geo;

import java.util.List;

/**
 * ArcherDB geospatial client interface.
 *
 * <p>
 * Provides methods for inserting, querying, and deleting geospatial events.
 *
 * <p>
 * Example usage:
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
 */
public interface GeoClient extends AutoCloseable {

    /**
     * Creates a new batch for inserting events.
     *
     * @return a new batch builder
     */
    GeoEventBatch createBatch();

    /**
     * Creates a new batch for upserting events.
     *
     * @return a new batch builder
     */
    GeoEventBatch createUpsertBatch();

    /**
     * Creates a new batch for deleting entities.
     *
     * @return a new delete batch builder
     */
    DeleteEntityBatch createDeleteBatch();

    /**
     * Inserts a single event (convenience method).
     *
     * @param event the event to insert
     * @return list of errors (empty if all succeeded)
     */
    List<InsertGeoEventsError> insertEvent(GeoEvent event);

    /**
     * Inserts multiple events.
     *
     * @param events the events to insert
     * @return list of errors (empty if all succeeded)
     */
    List<InsertGeoEventsError> insertEvents(List<GeoEvent> events);

    /**
     * Inserts multiple events with per-operation options.
     *
     * <p>
     * Per client-retry/spec.md, per-operation retry override allows customizing retry behavior for
     * individual operations:
     *
     * <pre>
     * client.insertEvents(events, OperationOptions.with(3, 10000));
     * </pre>
     *
     * @param events the events to insert
     * @param options per-operation options (null for defaults)
     * @return list of errors (empty if all succeeded)
     */
    default List<InsertGeoEventsError> insertEvents(List<GeoEvent> events,
            OperationOptions options) {
        // Default implementation ignores options - subclasses may override
        return insertEvents(events);
    }

    /**
     * Upserts multiple events.
     *
     * @param events the events to upsert
     * @return list of errors (empty if all succeeded)
     */
    List<InsertGeoEventsError> upsertEvents(List<GeoEvent> events);

    /**
     * Upserts multiple events with per-operation options.
     *
     * @param events the events to upsert
     * @param options per-operation options (null for defaults)
     * @return list of errors (empty if all succeeded)
     */
    default List<InsertGeoEventsError> upsertEvents(List<GeoEvent> events,
            OperationOptions options) {
        // Default implementation ignores options - subclasses may override
        return upsertEvents(events);
    }

    /**
     * Deletes entities by their IDs.
     *
     * @param entityIds the entity IDs to delete
     * @return delete result with counts
     */
    DeleteResult deleteEntities(List<UInt128> entityIds);

    /**
     * Deletes entities by their IDs with per-operation options.
     *
     * @param entityIds the entity IDs to delete
     * @param options per-operation options (null for defaults)
     * @return delete result with counts
     */
    default DeleteResult deleteEntities(List<UInt128> entityIds, OperationOptions options) {
        // Default implementation ignores options - subclasses may override
        return deleteEntities(entityIds);
    }

    /**
     * Looks up the latest event for an entity by UUID.
     *
     * @param entityId the entity UUID
     * @return the latest event, or null if not found
     */
    GeoEvent getLatestByUuid(UInt128 entityId);

    /**
     * Queries events within a radius.
     *
     * @param filter the radius query filter
     * @return query result with events
     */
    QueryResult queryRadius(QueryRadiusFilter filter);

    /**
     * Queries events within a radius with per-operation options.
     *
     * @param filter the radius query filter
     * @param options per-operation options (null for defaults)
     * @return query result with events
     */
    default QueryResult queryRadius(QueryRadiusFilter filter, OperationOptions options) {
        return queryRadius(filter);
    }

    /**
     * Queries events within a polygon.
     *
     * @param filter the polygon query filter
     * @return query result with events
     */
    QueryResult queryPolygon(QueryPolygonFilter filter);

    /**
     * Queries events within a polygon with per-operation options.
     *
     * @param filter the polygon query filter
     * @param options per-operation options (null for defaults)
     * @return query result with events
     */
    default QueryResult queryPolygon(QueryPolygonFilter filter, OperationOptions options) {
        return queryPolygon(filter);
    }

    /**
     * Queries the most recent events globally or by group.
     *
     * @param filter the query filter
     * @return query result with events
     */
    QueryResult queryLatest(QueryLatestFilter filter);

    /**
     * Queries the most recent events globally or by group with per-operation options.
     *
     * @param filter the query filter
     * @param options per-operation options (null for defaults)
     * @return query result with events
     */
    default QueryResult queryLatest(QueryLatestFilter filter, OperationOptions options) {
        return queryLatest(filter);
    }

    /**
     * Looks up multiple entities by UUID in a single batch request.
     *
     * <p>
     * Per client-protocol/spec.md query_uuid_batch (0x13):
     * <ul>
     * <li>Maximum 10,000 UUIDs per request</li>
     * <li>Returns map of entity_id to GeoEvent (null if not found)</li>
     * <li>Duplicate UUIDs are allowed</li>
     * </ul>
     *
     * @param entityIds the entity UUIDs to look up
     * @return map of entity_id to GeoEvent (null values for not found)
     */
    java.util.Map<UInt128, GeoEvent> lookupBatch(List<UInt128> entityIds);

    /**
     * Triggers explicit TTL expiration cleanup.
     *
     * <p>
     * Per client-protocol/spec.md cleanup_expired (0x30):
     * <ul>
     * <li>Goes through VSR consensus for deterministic cleanup</li>
     * <li>All replicas apply with same timestamp</li>
     * <li>Returns count of entries scanned and removed</li>
     * </ul>
     *
     * @param batchSize number of index entries to scan (0 = scan all)
     * @return cleanup result with entries scanned and removed
     */
    CleanupResult cleanupExpired(int batchSize);

    /**
     * Triggers explicit TTL expiration cleanup (scan all entries).
     *
     * @return cleanup result with entries scanned and removed
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
     * Per client-sdk/spec.md TTL Extension Client section:
     * <ul>
     * <li>Sets the entity's TTL to the specified value in seconds</li>
     * <li>A TTL of 0 means never expires</li>
     * <li>Returns previous and new TTL values for confirmation</li>
     * </ul>
     *
     * <p>
     * Example usage:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Set 24-hour TTL
     *     TtlSetResponse response = client.setTtl(entityId, 86400);
     *     System.out.println("Previous TTL: " + response.getPreviousTtlSeconds());
     *     System.out.println("New TTL: " + response.getNewTtlSeconds());
     * }
     * </pre>
     *
     * @param entityId the entity UUID to set TTL for
     * @param ttlSeconds the absolute TTL in seconds (0 = never expires)
     * @return TTL set response with previous and new TTL values
     * @throws IllegalArgumentException if entityId is null/zero or ttlSeconds is negative
     */
    TtlSetResponse setTtl(UInt128 entityId, int ttlSeconds);

    /**
     * Extends an entity's TTL by a relative amount.
     *
     * <p>
     * Per client-sdk/spec.md TTL Extension Client section:
     * <ul>
     * <li>Adds the specified seconds to the entity's current TTL</li>
     * <li>If entity has no TTL, sets it to the extension amount</li>
     * <li>Returns previous and new TTL values for confirmation</li>
     * </ul>
     *
     * <p>
     * Example usage:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Extend TTL by 1 day
     *     TtlExtendResponse response = client.extendTtl(entityId, 86400);
     *     System.out.println("Previous TTL: " + response.getPreviousTtlSeconds());
     *     System.out.println("New TTL: " + response.getNewTtlSeconds());
     * }
     * </pre>
     *
     * @param entityId the entity UUID to extend TTL for
     * @param extendBySeconds number of seconds to extend the TTL by
     * @return TTL extend response with previous and new TTL values
     * @throws IllegalArgumentException if entityId is null/zero or extendBySeconds is negative
     */
    TtlExtendResponse extendTtl(UInt128 entityId, int extendBySeconds);

    /**
     * Clears an entity's TTL, making it never expire.
     *
     * <p>
     * Per client-sdk/spec.md TTL Extension Client section:
     * <ul>
     * <li>Removes the entity's TTL (sets to 0)</li>
     * <li>Entity will not expire until TTL is set again</li>
     * <li>Returns previous TTL value for confirmation</li>
     * </ul>
     *
     * <p>
     * Example usage:
     *
     * <pre>
     * {
     *     &#64;code
     *     // Make entity permanent (no expiration)
     *     TtlClearResponse response = client.clearTtl(entityId);
     *     System.out.println("Previous TTL: " + response.getPreviousTtlSeconds());
     * }
     * </pre>
     *
     * @param entityId the entity UUID to clear TTL for
     * @return TTL clear response with previous TTL value
     * @throws IllegalArgumentException if entityId is null or zero
     */
    TtlClearResponse clearTtl(UInt128 entityId);

    /**
     * Sends a ping to verify server connectivity.
     *
     * @return true if server responded
     */
    boolean ping();

    /**
     * Returns current server status.
     *
     * @return server status response
     */
    StatusResponse getStatus();

    /**
     * Closes the client and releases resources.
     */
    @Override
    void close();

    /**
     * Creates a new GeoClient connected to the specified cluster.
     *
     * @param clusterId the cluster ID
     * @param addresses comma-separated list of replica addresses
     * @return a new client
     */
    static GeoClient create(long clusterId, String... addresses) {
        return new GeoClientImpl(UInt128.fromLong(clusterId), addresses);
    }

    /**
     * Creates a new GeoClient with a 128-bit cluster ID.
     *
     * @param clusterId the cluster ID
     * @param addresses comma-separated list of replica addresses
     * @return a new client
     */
    static GeoClient create(UInt128 clusterId, String... addresses) {
        return new GeoClientImpl(clusterId, addresses);
    }

    /**
     * Creates a new multi-region GeoClient from configuration.
     *
     * <p>
     * Example usage:
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
     *         // Multi-region operations with read preference routing
     *     }
     * }
     * </pre>
     *
     * @param config the multi-region client configuration
     * @return a new multi-region client
     */
    static GeoClient create(ClientConfig config) {
        return new MultiRegionGeoClient(config);
    }

    /**
     * Returns the current client configuration, or null for single-region clients.
     *
     * @return the client configuration, or null
     */
    default ClientConfig getConfig() {
        return null;
    }

    /**
     * Returns the current read preference, or PRIMARY for single-region clients.
     *
     * @return the current read preference
     */
    default ReadPreference getReadPreference() {
        return ReadPreference.PRIMARY;
    }
}
