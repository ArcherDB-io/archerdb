package com.archerdb.geo;

import com.archerdb.core.GeoNativeBridge;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Default implementation of the GeoClient interface.
 *
 * <p>
 * This implementation uses the native JNI client via GeoNativeBridge for all database operations.
 * All operations are blocking and thread-safe.
 *
 * <p>
 * Per client-sdk/spec.md, this client provides:
 * <ul>
 * <li>Connection lifecycle management</li>
 * <li>Batch operations for insert/upsert/delete</li>
 * <li>Query operations (UUID lookup, radius, polygon, latest)</li>
 * <li>Admin operations (ping, status)</li>
 * </ul>
 */
@SuppressWarnings("PMD.UnusedPrivateField") // Fields used when NATIVE_ENABLED is true
final class GeoClientImpl implements GeoClient {

    // Operation codes (must match archerdb.zig and core/Request.java Operations enum)
    static final byte OP_INSERT_EVENTS = (byte) 146;
    static final byte OP_UPSERT_EVENTS = (byte) 147;
    static final byte OP_DELETE_ENTITIES = (byte) 148;
    static final byte OP_QUERY_UUID = (byte) 149;
    static final byte OP_QUERY_RADIUS = (byte) 150;
    static final byte OP_QUERY_POLYGON = (byte) 151;
    static final byte OP_PING = (byte) 152;
    static final byte OP_GET_STATUS = (byte) 153;
    static final byte OP_QUERY_LATEST = (byte) 154;
    static final byte OP_CLEANUP_EXPIRED = (byte) 155;
    static final byte OP_QUERY_UUID_BATCH = (byte) 156;
    static final byte OP_GET_TOPOLOGY = (byte) 157;
    static final byte OP_TTL_SET = (byte) 158;
    static final byte OP_TTL_EXTEND = (byte) 159;
    static final byte OP_TTL_CLEAR = (byte) 160;

    // Wire format sizes (from client-sdk/spec.md)
    static final int GEO_EVENT_SIZE = 128;
    static final int QUERY_UUID_FILTER_SIZE = 32;
    static final int QUERY_RADIUS_FILTER_SIZE = 128;
    static final int QUERY_LATEST_FILTER_SIZE = 128;
    static final int STATUS_RESPONSE_SIZE = 64;
    static final int QUERY_RESPONSE_HEADER_SIZE = 16;
    static final int INSERT_ERROR_SIZE = 8;
    static final int DELETE_ERROR_SIZE = 8;
    static final int CLEANUP_RESPONSE_SIZE = 16;
    static final int TTL_REQUEST_SIZE = 64;
    static final int TTL_RESPONSE_SIZE = 64;

    // Batch limits (from client-protocol/spec.md)
    static final int MAX_BATCH_UUIDS = 10000;

    // Default timeouts (per client-sdk/spec.md)
    private static final int DEFAULT_REQUEST_TIMEOUT_MS = 30000;

    // Flag to enable native client integration (disable in tests via system property).
    private static final boolean NATIVE_ENABLED =
            Boolean.parseBoolean(System.getProperty("archerdb.native.enabled", "true"));

    private final UInt128 clusterId;
    private final String[] addresses;
    private final int requestTimeoutMs;
    private GeoNativeBridge nativeBridge;
    private volatile boolean closed = false;

    /**
     * Creates a new GeoClient connected to the specified cluster.
     *
     * @param clusterId the cluster ID for validation
     * @param addresses replica addresses (host:port format)
     * @throws IllegalArgumentException if addresses is null or empty
     */
    GeoClientImpl(UInt128 clusterId, String[] addresses) {
        this(clusterId, addresses, DEFAULT_REQUEST_TIMEOUT_MS);
    }

    /**
     * Creates a new GeoClient with custom timeout.
     *
     * @param clusterId the cluster ID for validation
     * @param addresses replica addresses (host:port format)
     * @param requestTimeoutMs request timeout in milliseconds
     * @throws IllegalArgumentException if addresses is null or empty
     */
    GeoClientImpl(UInt128 clusterId, String[] addresses, int requestTimeoutMs) {
        if (addresses == null || addresses.length == 0) {
            throw new IllegalArgumentException("At least one replica address is required");
        }
        this.clusterId = clusterId;
        this.addresses = addresses.clone();
        this.requestTimeoutMs = requestTimeoutMs;

        if (NATIVE_ENABLED) {
            // Initialize native bridge
            byte[] clusterIdBytes = serializeUInt128(clusterId);
            String addressStr = String.join(",", addresses);
            this.nativeBridge = GeoNativeBridge.create(clusterIdBytes, addressStr);
        }
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
        return submitInsertEvents(events, false);
    }

    @Override
    public List<InsertGeoEventsError> upsertEvents(List<GeoEvent> events) {
        ensureOpen();
        return submitInsertEvents(events, true);
    }

    /**
     * Submits insert or upsert events to the cluster.
     */
    private List<InsertGeoEventsError> submitInsertEvents(List<GeoEvent> events, boolean upsert) {
        if (events.isEmpty()) {
            return new ArrayList<>();
        }

        if (!NATIVE_ENABLED) {
            // Skeleton mode - return success for all events
            return new ArrayList<>();
        }

        // Serialize events to native batch format
        NativeGeoEventBatch batch = new NativeGeoEventBatch(events.size());
        for (GeoEvent event : events) {
            batch.add();
            batch.fromGeoEvent(event);
        }

        // Submit via native bridge
        byte operation = upsert ? OP_UPSERT_EVENTS : OP_INSERT_EVENTS;
        ByteBuffer response = nativeBridge.submitRequest(operation, batch, requestTimeoutMs);

        // Parse response - errors are returned as InsertGeoEventsError records
        List<InsertGeoEventsError> errors = new ArrayList<>();
        if (response != null && response.remaining() > 0) {
            response.order(ByteOrder.LITTLE_ENDIAN);
            while (response.remaining() >= INSERT_ERROR_SIZE) {
                int index = response.getInt();
                byte result = response.get();
                response.position(response.position() + 3); // skip padding

                if (result != 0) { // 0 = OK
                    errors.add(
                            new InsertGeoEventsError(index, InsertGeoEventResult.fromCode(result)));
                }
            }
        }

        return errors;
    }

    @Override
    public DeleteResult deleteEntities(List<UInt128> entityIds) {
        ensureOpen();

        if (entityIds.isEmpty()) {
            return new DeleteResult(0, 0);
        }

        if (!NATIVE_ENABLED) {
            // Skeleton mode - report all as deleted
            return new DeleteResult(entityIds.size(), 0);
        }

        // Use a batch for the delete request
        NativeDeleteBatch batch = new NativeDeleteBatch(entityIds.size());
        for (UInt128 id : entityIds) {
            batch.add();
            batch.setEntityId(id.getLo(), id.getHi());
        }

        ByteBuffer response =
                nativeBridge.submitRequest(OP_DELETE_ENTITIES, batch, requestTimeoutMs);

        // Parse response
        int deletedCount = entityIds.size();
        int notFoundCount = 0;

        if (response != null && response.remaining() > 0) {
            response.order(ByteOrder.LITTLE_ENDIAN);
            while (response.remaining() >= DELETE_ERROR_SIZE) {
                response.getInt(); // index (unused)
                byte result = response.get();
                response.position(response.position() + 3); // skip padding

                // Result code 1 typically means entity not found
                if (result == 1) {
                    notFoundCount++;
                    deletedCount--;
                } else if (result != 0) {
                    deletedCount--;
                }
            }
        }

        return new DeleteResult(deletedCount, notFoundCount);
    }

    @Override
    public GeoEvent getLatestByUuid(UInt128 entityId) {
        ensureOpen();

        if (!NATIVE_ENABLED) {
            // Skeleton mode - returns null (not found)
            return null;
        }

        // Build query filter using NativeQueryUuidBatch
        NativeQueryUuidBatch batch = new NativeQueryUuidBatch(1);
        batch.add();
        batch.setEntityId(entityId.getLo(), entityId.getHi());

        ByteBuffer response = nativeBridge.submitRequest(OP_QUERY_UUID, batch, requestTimeoutMs);

        return parseUuidResponse(response, entityId);
    }

    @Override
    public QueryResult queryRadius(QueryRadiusFilter filter) {
        ensureOpen();

        if (!NATIVE_ENABLED) {
            // Skeleton mode - returns empty results
            return new QueryResult(new ArrayList<>(), false, 0);
        }

        // Serialize filter using NativeQueryRadiusBatch
        NativeQueryRadiusBatch batch = new NativeQueryRadiusBatch(1);
        batch.add();
        batch.setCenterLatNano(filter.getCenterLatNano());
        batch.setCenterLonNano(filter.getCenterLonNano());
        batch.setRadiusMm(filter.getRadiusMm());
        batch.setLimit(filter.getLimit());
        batch.setTimestampMin(filter.getTimestampMin());
        batch.setTimestampMax(filter.getTimestampMax());
        batch.setGroupId(filter.getGroupId());

        ByteBuffer response = nativeBridge.submitRequest(OP_QUERY_RADIUS, batch, requestTimeoutMs);

        // Parse response
        List<GeoEvent> events = parseQueryResponse(response);
        boolean hasMore = events.size() >= filter.getLimit();
        long cursor = events.isEmpty() ? 0 : events.get(events.size() - 1).getTimestamp();

        return new QueryResult(events, hasMore, cursor);
    }

    @Override
    public QueryResult queryPolygon(QueryPolygonFilter filter) {
        ensureOpen();

        if (!NATIVE_ENABLED) {
            // Skeleton mode - returns empty results
            return new QueryResult(new ArrayList<>(), false, 0);
        }

        // Polygon queries use variable-length wire format
        // Build using NativeQueryPolygonBatch
        NativeQueryPolygonBatch batch = createPolygonBatch(filter);

        ByteBuffer response = nativeBridge.submitRequest(OP_QUERY_POLYGON, batch, requestTimeoutMs);

        // Parse response
        List<GeoEvent> events = parseQueryResponse(response);
        boolean hasMore = events.size() >= filter.getLimit();
        long cursor = events.isEmpty() ? 0 : events.get(events.size() - 1).getTimestamp();

        return new QueryResult(events, hasMore, cursor);
    }

    @Override
    public QueryResult queryLatest(QueryLatestFilter filter) {
        ensureOpen();

        if (!NATIVE_ENABLED) {
            // Skeleton mode - returns empty results
            return new QueryResult(new ArrayList<>(), false, 0);
        }

        // Use NativeQueryLatestFilterBatch
        NativeQueryLatestFilterBatch batch = new NativeQueryLatestFilterBatch(1);
        batch.add();
        batch.setLimit(filter.getLimit());
        batch.setGroupId(filter.getGroupId());
        batch.setCursorTimestamp(filter.getCursorTimestamp());

        ByteBuffer response = nativeBridge.submitRequest(OP_QUERY_LATEST, batch, requestTimeoutMs);

        // Parse response
        List<GeoEvent> events = parseQueryResponse(response);
        boolean hasMore = events.size() >= filter.getLimit();
        long cursor = events.isEmpty() ? 0 : events.get(events.size() - 1).getTimestamp();

        return new QueryResult(events, hasMore, cursor);
    }

    @Override
    public Map<UInt128, GeoEvent> lookupBatch(List<UInt128> entityIds) {
        ensureOpen();

        Map<UInt128, GeoEvent> results = new HashMap<>();

        if (entityIds == null || entityIds.isEmpty()) {
            return results;
        }

        if (entityIds.size() > MAX_BATCH_UUIDS) {
            throw new IllegalArgumentException("Maximum " + MAX_BATCH_UUIDS
                    + " UUIDs per batch request, got " + entityIds.size());
        }

        if (!NATIVE_ENABLED) {
            // Skeleton mode - return null for all entities (not found)
            for (UInt128 id : entityIds) {
                results.put(id, null);
            }
            return results;
        }

        NativeQueryUuidBatchRequest batch = new NativeQueryUuidBatchRequest(entityIds);
        ByteBuffer response =
                nativeBridge.submitRequest(OP_QUERY_UUID_BATCH, batch, requestTimeoutMs);
        return parseUuidBatchResponse(response, entityIds);
    }

    @Override
    public CleanupResult cleanupExpired(int batchSize) {
        ensureOpen();

        if (batchSize < 0) {
            throw new IllegalArgumentException("Batch size must be non-negative");
        }

        if (!NATIVE_ENABLED) {
            // Skeleton mode - return empty cleanup result
            return new CleanupResult(0, 0);
        }

        // Build cleanup request with batch size
        NativeCleanupBatch batch = new NativeCleanupBatch(1);
        batch.add();
        batch.setBatchSize(batchSize);

        ByteBuffer response =
                nativeBridge.submitRequest(OP_CLEANUP_EXPIRED, batch, requestTimeoutMs);

        // Parse response: entries_scanned (u64), entries_removed (u64)
        if (response != null && response.remaining() >= CLEANUP_RESPONSE_SIZE) {
            response.order(ByteOrder.LITTLE_ENDIAN);
            long entriesScanned = response.getLong();
            long entriesRemoved = response.getLong();
            return new CleanupResult(entriesScanned, entriesRemoved);
        }

        return new CleanupResult(0, 0);
    }

    @Override
    public boolean ping() {
        ensureOpen();

        if (!NATIVE_ENABLED) {
            // Skeleton mode - always returns true
            return true;
        }

        try {
            // Simple ping batch
            NativePingBatch batch = new NativePingBatch(1);
            batch.add();
            batch.setPingData(0x676E6970L); // "ping" in ASCII

            ByteBuffer response = nativeBridge.submitRequest(OP_PING, batch, requestTimeoutMs);

            if (response != null && response.remaining() >= 8) {
                response.order(ByteOrder.LITTLE_ENDIAN);
                long pong = response.getLong();
                return pong == 0x676E6F70L; // "pong" in ASCII
            }
            return true; // Default to success if no explicit response
        } catch (Exception e) {
            return false;
        }
    }

    @Override
    public StatusResponse getStatus() {
        ensureOpen();

        if (!NATIVE_ENABLED) {
            // Skeleton mode - returns zeros
            return new StatusResponse(0, 0, 0, 0, 0, 0);
        }

        NativeStatusBatch batch = new NativeStatusBatch(1);
        batch.add();

        ByteBuffer response = nativeBridge.submitRequest(OP_GET_STATUS, batch, requestTimeoutMs);

        if (response != null && response.remaining() >= STATUS_RESPONSE_SIZE) {
            response.order(ByteOrder.LITTLE_ENDIAN);
            long ramIndexCount = response.getLong();
            long ramIndexCapacity = response.getLong();
            int ramIndexLoadPct = response.getInt();
            response.getInt(); // padding
            long tombstoneCount = response.getLong();
            long ttlExpirations = response.getLong();
            long deletionCount = response.getLong();

            return new StatusResponse(ramIndexCount, ramIndexCapacity, ramIndexLoadPct,
                    tombstoneCount, ttlExpirations, deletionCount);
        }

        return new StatusResponse(0, 0, 0, 0, 0, 0);
    }

    // ============================================================================
    // TTL Operations (v2.1 Manual TTL Support)
    // ============================================================================

    @Override
    public TtlSetResponse setTtl(UInt128 entityId, int ttlSeconds) {
        ensureOpen();

        if (entityId == null || entityId.isZero()) {
            throw new IllegalArgumentException("Entity ID must not be null or zero");
        }
        if (ttlSeconds < 0) {
            throw new IllegalArgumentException("TTL seconds must be non-negative");
        }

        if (!NATIVE_ENABLED) {
            // Skeleton mode - return success response
            return new TtlSetResponse(entityId, 0, ttlSeconds, TtlOperationResult.SUCCESS);
        }

        // Build TTL set request batch
        NativeTtlSetBatch batch = new NativeTtlSetBatch(1);
        batch.add();
        batch.setEntityId(entityId.getLo(), entityId.getHi());
        batch.setTtlSeconds(ttlSeconds);
        batch.setFlags(0);

        ByteBuffer response = nativeBridge.submitRequest(OP_TTL_SET, batch, requestTimeoutMs);

        return parseTtlSetResponse(response);
    }

    @Override
    public TtlExtendResponse extendTtl(UInt128 entityId, int extendBySeconds) {
        ensureOpen();

        if (entityId == null || entityId.isZero()) {
            throw new IllegalArgumentException("Entity ID must not be null or zero");
        }
        if (extendBySeconds < 0) {
            throw new IllegalArgumentException("Extend by seconds must be non-negative");
        }

        if (!NATIVE_ENABLED) {
            // Skeleton mode - return success response
            return new TtlExtendResponse(entityId, 0, extendBySeconds, TtlOperationResult.SUCCESS);
        }

        // Build TTL extend request batch
        NativeTtlExtendBatch batch = new NativeTtlExtendBatch(1);
        batch.add();
        batch.setEntityId(entityId.getLo(), entityId.getHi());
        batch.setExtendBySeconds(extendBySeconds);
        batch.setFlags(0);

        ByteBuffer response = nativeBridge.submitRequest(OP_TTL_EXTEND, batch, requestTimeoutMs);

        return parseTtlExtendResponse(response);
    }

    @Override
    public TtlClearResponse clearTtl(UInt128 entityId) {
        ensureOpen();

        if (entityId == null || entityId.isZero()) {
            throw new IllegalArgumentException("Entity ID must not be null or zero");
        }

        if (!NATIVE_ENABLED) {
            // Skeleton mode - return success response
            return new TtlClearResponse(entityId, 0, TtlOperationResult.SUCCESS);
        }

        // Build TTL clear request batch
        NativeTtlClearBatch batch = new NativeTtlClearBatch(1);
        batch.add();
        batch.setEntityId(entityId.getLo(), entityId.getHi());
        batch.setFlags(0);

        ByteBuffer response = nativeBridge.submitRequest(OP_TTL_CLEAR, batch, requestTimeoutMs);

        return parseTtlClearResponse(response);
    }

    /**
     * Parses a TtlSetResponse from the wire format.
     */
    private TtlSetResponse parseTtlSetResponse(ByteBuffer response) {
        if (response == null || response.remaining() < TTL_RESPONSE_SIZE) {
            throw new RuntimeException("Invalid TTL set response");
        }

        response.order(ByteOrder.LITTLE_ENDIAN);
        long entityIdLo = response.getLong();
        long entityIdHi = response.getLong();
        int previousTtl = response.getInt();
        int newTtl = response.getInt();
        int resultCode = response.get() & 0xFF;

        return new TtlSetResponse(UInt128.of(entityIdHi, entityIdLo), previousTtl, newTtl,
                TtlOperationResult.fromCode(resultCode));
    }

    /**
     * Parses a TtlExtendResponse from the wire format.
     */
    private TtlExtendResponse parseTtlExtendResponse(ByteBuffer response) {
        if (response == null || response.remaining() < TTL_RESPONSE_SIZE) {
            throw new RuntimeException("Invalid TTL extend response");
        }

        response.order(ByteOrder.LITTLE_ENDIAN);
        long entityIdLo = response.getLong();
        long entityIdHi = response.getLong();
        int previousTtl = response.getInt();
        int newTtl = response.getInt();
        int resultCode = response.get() & 0xFF;

        return new TtlExtendResponse(UInt128.of(entityIdHi, entityIdLo), previousTtl, newTtl,
                TtlOperationResult.fromCode(resultCode));
    }

    /**
     * Parses a TtlClearResponse from the wire format.
     */
    private TtlClearResponse parseTtlClearResponse(ByteBuffer response) {
        if (response == null || response.remaining() < TTL_RESPONSE_SIZE) {
            throw new RuntimeException("Invalid TTL clear response");
        }

        response.order(ByteOrder.LITTLE_ENDIAN);
        long entityIdLo = response.getLong();
        long entityIdHi = response.getLong();
        int previousTtl = response.getInt();
        int resultCode = response.get() & 0xFF;

        return new TtlClearResponse(UInt128.of(entityIdHi, entityIdLo), previousTtl,
                TtlOperationResult.fromCode(resultCode));
    }

    @Override
    public void close() {
        if (!closed) {
            closed = true;
            if (nativeBridge != null) {
                nativeBridge.close();
                nativeBridge = null;
            }
        }
    }

    private void ensureOpen() {
        if (closed) {
            throw new IllegalStateException("Client has been closed");
        }
    }

    /**
     * Parses a query response containing GeoEvent records.
     */
    private List<GeoEvent> parseQueryResponse(ByteBuffer response) {
        List<GeoEvent> events = new ArrayList<>();

        if (response == null || response.remaining() < QUERY_RESPONSE_HEADER_SIZE) {
            return events;
        }

        response.order(ByteOrder.LITTLE_ENDIAN);

        // Parse header (16 bytes)
        int count = response.getInt();
        response.get(); // hasMore (handled by caller)
        response.get(); // partialResult
        response.position(response.position() + 10); // skip reserved

        // Parse events using NativeGeoEventBatch
        if (response.remaining() >= GEO_EVENT_SIZE && count > 0) {
            ByteBuffer eventData = response.slice().order(ByteOrder.LITTLE_ENDIAN);
            NativeGeoEventBatch batch = new NativeGeoEventBatch(eventData);
            while (batch.next()) {
                events.add(batch.toGeoEvent());
            }
        }

        return events;
    }

    /**
     * Parses a single UUID lookup response containing a raw GeoEvent.
     */
    private GeoEvent parseUuidResponse(ByteBuffer response, UInt128 entityId) {
        if (response == null || response.remaining() < 16) {
            return null;
        }

        response.order(ByteOrder.LITTLE_ENDIAN);
        int status = response.get() & 0xFF;
        response.position(response.position() + 15); // reserved

        if (status == 0) {
            if (response.remaining() < GEO_EVENT_SIZE) {
                return null;
            }
            ByteBuffer eventData = response.slice().order(ByteOrder.LITTLE_ENDIAN);
            eventData.limit(GEO_EVENT_SIZE);

            NativeGeoEventBatch batch = new NativeGeoEventBatch(eventData);
            if (!batch.next()) {
                return null;
            }
            return batch.toGeoEvent();
        }

        if (status == OperationException.ENTITY_NOT_FOUND) {
            return null;
        }

        if (status == OperationException.ENTITY_EXPIRED) {
            throw OperationException.entityExpired(entityId);
        }

        throw new OperationException(status, "Query UUID failed with status " + status, false);
    }

    /**
     * Parses a batch UUID lookup response per client-protocol/spec.md.
     */
    private Map<UInt128, GeoEvent> parseUuidBatchResponse(ByteBuffer response,
            List<UInt128> entityIds) {
        Map<UInt128, GeoEvent> results = new HashMap<>();
        for (UInt128 entityId : entityIds) {
            results.put(entityId, null);
        }

        if (response == null || response.remaining() < 16) {
            return results;
        }

        response.order(ByteOrder.LITTLE_ENDIAN);

        int foundCount = response.getInt();
        int notFoundCount = response.getInt();
        response.position(response.position() + 8); // reserved

        if (notFoundCount < 0 || foundCount < 0) {
            return results;
        }

        int notFoundBytes = notFoundCount * 2;
        if (response.remaining() < notFoundBytes) {
            return results;
        }

        boolean[] notFound = new boolean[entityIds.size()];
        for (int i = 0; i < notFoundCount; i++) {
            int index = Short.toUnsignedInt(response.getShort());
            if (index < notFound.length) {
                notFound[index] = true;
            }
        }

        int offset = 16 + notFoundBytes;
        int padding = (16 - (offset % 16)) % 16;
        if (padding > 0) {
            if (response.remaining() < padding) {
                return results;
            }
            response.position(response.position() + padding);
        }

        int eventsBytes = foundCount * GEO_EVENT_SIZE;
        if (response.remaining() < eventsBytes) {
            return results;
        }

        ByteBuffer eventsBuffer = response.slice().order(ByteOrder.LITTLE_ENDIAN);
        eventsBuffer.limit(eventsBytes);

        List<GeoEvent> events = new ArrayList<>(foundCount);
        NativeGeoEventBatch batch = new NativeGeoEventBatch(eventsBuffer);
        while (batch.next()) {
            events.add(batch.toGeoEvent());
        }

        int eventIdx = 0;
        for (int i = 0; i < entityIds.size(); i++) {
            if (notFound[i]) {
                continue;
            }
            if (eventIdx >= events.size()) {
                break;
            }
            results.put(entityIds.get(i), events.get(eventIdx));
            eventIdx += 1;
        }

        return results;
    }

    /**
     * Creates a polygon batch from the filter.
     */
    private NativeQueryPolygonBatch createPolygonBatch(QueryPolygonFilter filter) {
        List<QueryPolygonFilter.PolygonVertex> vertices = filter.getVertices();
        List<QueryPolygonFilter.PolygonHole> holes = filter.getHoles();

        // Calculate total vertex count including holes
        int totalVertices = vertices.size();
        if (holes != null) {
            for (QueryPolygonFilter.PolygonHole hole : holes) {
                totalVertices += hole.getVertices().size();
            }
        }

        NativeQueryPolygonBatch batch =
                new NativeQueryPolygonBatch(1, totalVertices, holes != null ? holes.size() : 0);
        batch.add();
        batch.setLimit(filter.getLimit());
        batch.setVertexCount(vertices.size());
        batch.setHoleCount(holes != null ? holes.size() : 0);
        batch.setTimestampMin(filter.getTimestampMin());
        batch.setTimestampMax(filter.getTimestampMax());
        batch.setGroupId(filter.getGroupId());

        // Add vertices
        for (QueryPolygonFilter.PolygonVertex v : vertices) {
            batch.addVertex(v.getLatNano(), v.getLonNano());
        }

        // Add holes
        if (holes != null) {
            for (QueryPolygonFilter.PolygonHole hole : holes) {
                batch.startHole(hole.getVertices().size());
                for (QueryPolygonFilter.PolygonVertex v : hole.getVertices()) {
                    batch.addHoleVertex(v.getLatNano(), v.getLonNano());
                }
            }
        }

        return batch;
    }

    // ========== Helper Methods for Wire Format Serialization ==========

    /**
     * Serializes a UInt128 to a 16-byte array in little-endian format.
     */
    static byte[] serializeUInt128(UInt128 value) {
        byte[] bytes = new byte[16];
        ByteBuffer bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        bb.putLong(value.getLo());
        bb.putLong(value.getHi());
        return bytes;
    }
}
