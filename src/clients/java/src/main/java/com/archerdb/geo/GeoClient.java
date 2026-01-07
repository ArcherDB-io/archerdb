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
     * Upserts multiple events.
     *
     * @param events the events to upsert
     * @return list of errors (empty if all succeeded)
     */
    List<InsertGeoEventsError> upsertEvents(List<GeoEvent> events);

    /**
     * Deletes entities by their IDs.
     *
     * @param entityIds the entity IDs to delete
     * @return delete result with counts
     */
    DeleteResult deleteEntities(List<UInt128> entityIds);

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
     * Queries events within a polygon.
     *
     * @param filter the polygon query filter
     * @return query result with events
     */
    QueryResult queryPolygon(QueryPolygonFilter filter);

    /**
     * Queries the most recent events globally or by group.
     *
     * @param filter the query filter
     * @return query result with events
     */
    QueryResult queryLatest(QueryLatestFilter filter);

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
}
