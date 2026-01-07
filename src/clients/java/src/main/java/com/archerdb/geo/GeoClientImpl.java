package com.archerdb.geo;

import java.util.ArrayList;
import java.util.List;

/**
 * Default implementation of the GeoClient interface.
 *
 * <p>
 * NOTE: This is a skeleton implementation. The actual native binding integration is pending.
 */
@SuppressWarnings("PMD.UnusedPrivateField") // Fields used when native bindings are integrated
final class GeoClientImpl implements GeoClient {

    private final UInt128 clusterId;
    private final String[] addresses;
    private boolean closed = false;

    GeoClientImpl(UInt128 clusterId, String[] addresses) {
        if (addresses == null || addresses.length == 0) {
            throw new IllegalArgumentException("At least one replica address is required");
        }
        this.clusterId = clusterId;
        this.addresses = addresses;
    }

    @Override
    public GeoEventBatch createBatch() {
        ensureOpen();
        return new GeoEventBatch(this, false);
    }

    @Override
    public GeoEventBatch createUpsertBatch() {
        ensureOpen();
        return new GeoEventBatch(this, true);
    }

    @Override
    public DeleteEntityBatch createDeleteBatch() {
        ensureOpen();
        return new DeleteEntityBatch(this);
    }

    @Override
    public List<InsertGeoEventsError> insertEvent(GeoEvent event) {
        return insertEvents(List.of(event));
    }

    @Override
    public List<InsertGeoEventsError> insertEvents(List<GeoEvent> events) {
        ensureOpen();
        // NOTE: Skeleton implementation
        return new ArrayList<>();
    }

    @Override
    public List<InsertGeoEventsError> upsertEvents(List<GeoEvent> events) {
        ensureOpen();
        // NOTE: Skeleton implementation
        return new ArrayList<>();
    }

    @Override
    public DeleteResult deleteEntities(List<UInt128> entityIds) {
        ensureOpen();
        // NOTE: Skeleton implementation
        return new DeleteResult(entityIds.size(), 0);
    }

    @Override
    public GeoEvent getLatestByUuid(UInt128 entityId) {
        ensureOpen();
        // NOTE: Skeleton implementation
        return null;
    }

    @Override
    public QueryResult queryRadius(QueryRadiusFilter filter) {
        ensureOpen();
        // NOTE: Skeleton implementation
        return new QueryResult(new ArrayList<>(), false, 0);
    }

    @Override
    public QueryResult queryPolygon(QueryPolygonFilter filter) {
        ensureOpen();
        // NOTE: Skeleton implementation
        return new QueryResult(new ArrayList<>(), false, 0);
    }

    @Override
    public QueryResult queryLatest(QueryLatestFilter filter) {
        ensureOpen();
        // NOTE: Skeleton implementation
        return new QueryResult(new ArrayList<>(), false, 0);
    }

    @Override
    public boolean ping() {
        ensureOpen();
        // NOTE: Skeleton implementation
        return true;
    }

    @Override
    public StatusResponse getStatus() {
        ensureOpen();
        // NOTE: Skeleton implementation
        return new StatusResponse(0, 0, 0, 0, 0, 0);
    }

    @Override
    public void close() {
        closed = true;
    }

    private void ensureOpen() {
        if (closed) {
            throw new IllegalStateException("Client has been closed");
        }
    }
}
