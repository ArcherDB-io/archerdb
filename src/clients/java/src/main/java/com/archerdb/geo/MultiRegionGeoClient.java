package com.archerdb.geo;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Multi-region GeoClient implementation with read preference routing.
 *
 * <p>
 * Per client-sdk/spec.md v2 multi-region support:
 * <ul>
 * <li>Write operations always go to the primary region</li>
 * <li>Read operations are routed based on read preference</li>
 * <li>Follower reads include staleness metadata</li>
 * </ul>
 *
 * <p>
 * This implementation maintains connections to all configured regions and routes requests based on
 * the configured read preference.
 */
final class MultiRegionGeoClient implements GeoClient {

    private final ClientConfig config;
    private final Map<String, GeoClientImpl> regionClients;
    private final GeoClientImpl primaryClient;
    private volatile boolean closed = false;

    /**
     * Creates a multi-region client from configuration.
     */
    MultiRegionGeoClient(ClientConfig config) {
        this.config = config;
        this.regionClients = new HashMap<>();

        GeoClientImpl primary = null;

        // Create a client for each region
        for (RegionConfig region : config.getRegions()) {
            GeoClientImpl client = new GeoClientImpl(config.getClusterId(), region.getAddresses(),
                    config.getRequestTimeoutMs());
            regionClients.put(region.getName(), client);

            if (region.isPrimary()) {
                primary = client;
            }
        }

        if (primary == null) {
            throw new IllegalArgumentException("No primary region found in configuration");
        }
        this.primaryClient = primary;
    }

    @Override
    public ClientConfig getConfig() {
        return config;
    }

    @Override
    public ReadPreference getReadPreference() {
        return config.getReadPreference();
    }

    // ========================================================================
    // Write Operations - Always go to primary
    // ========================================================================

    @Override
    public GeoEventBatch createBatch() {
        ensureOpen();
        return primaryClient.createBatch();
    }

    @Override
    public GeoEventBatch createUpsertBatch() {
        ensureOpen();
        return primaryClient.createUpsertBatch();
    }

    @Override
    public DeleteEntityBatch createDeleteBatch() {
        ensureOpen();
        return primaryClient.createDeleteBatch();
    }

    @Override
    public List<InsertGeoEventsError> insertEvent(GeoEvent event) {
        ensureOpen();
        return primaryClient.insertEvent(event);
    }

    @Override
    public List<InsertGeoEventsError> insertEvents(List<GeoEvent> events) {
        ensureOpen();
        return primaryClient.insertEvents(events);
    }

    @Override
    public List<InsertGeoEventsError> upsertEvents(List<GeoEvent> events) {
        ensureOpen();
        return primaryClient.upsertEvents(events);
    }

    @Override
    public DeleteResult deleteEntities(List<UInt128> entityIds) {
        ensureOpen();
        return primaryClient.deleteEntities(entityIds);
    }

    // ========================================================================
    // Read Operations - Routed by read preference
    // ========================================================================

    @Override
    public GeoEvent getLatestByUuid(UInt128 entityId) {
        ensureOpen();
        return selectReadClient().getLatestByUuid(entityId);
    }

    @Override
    public QueryResult queryRadius(QueryRadiusFilter filter) {
        ensureOpen();
        return selectReadClient().queryRadius(filter);
    }

    @Override
    public QueryResult queryPolygon(QueryPolygonFilter filter) {
        ensureOpen();
        return selectReadClient().queryPolygon(filter);
    }

    @Override
    public QueryResult queryLatest(QueryLatestFilter filter) {
        ensureOpen();
        return selectReadClient().queryLatest(filter);
    }

    @Override
    public Map<UInt128, GeoEvent> lookupBatch(List<UInt128> entityIds) {
        ensureOpen();
        return selectReadClient().lookupBatch(entityIds);
    }

    // ========================================================================
    // Admin/Write Operations - Always go to primary
    // ========================================================================

    @Override
    public CleanupResult cleanupExpired(int batchSize) {
        ensureOpen();
        return primaryClient.cleanupExpired(batchSize);
    }

    // ========================================================================
    // TTL Operations (v2.1 Manual TTL Support) - Write to primary
    // ========================================================================

    @Override
    public TtlSetResponse setTtl(UInt128 entityId, int ttlSeconds) {
        ensureOpen();
        return primaryClient.setTtl(entityId, ttlSeconds);
    }

    @Override
    public TtlExtendResponse extendTtl(UInt128 entityId, int extendBySeconds) {
        ensureOpen();
        return primaryClient.extendTtl(entityId, extendBySeconds);
    }

    @Override
    public TtlClearResponse clearTtl(UInt128 entityId) {
        ensureOpen();
        return primaryClient.clearTtl(entityId);
    }

    // ========================================================================
    // Admin Operations
    // ========================================================================

    @Override
    public boolean ping() {
        ensureOpen();
        return primaryClient.ping();
    }

    @Override
    public StatusResponse getStatus() {
        ensureOpen();
        return primaryClient.getStatus();
    }

    @Override
    public TopologyResponse getTopology() {
        ensureOpen();
        return primaryClient.getTopology();
    }

    @Override
    public TopologyCache getTopologyCache() {
        ensureOpen();
        return primaryClient.getTopologyCache();
    }

    @Override
    public TopologyResponse refreshTopology() {
        ensureOpen();
        return primaryClient.refreshTopology();
    }

    @Override
    public ShardRouter getShardRouter() {
        ensureOpen();
        return primaryClient.getShardRouter();
    }

    /**
     * Pings a specific region by name.
     *
     * @param regionName the region to ping
     * @return true if the region responded
     * @throws IllegalArgumentException if region is not found
     */
    public boolean ping(String regionName) {
        ensureOpen();
        GeoClientImpl client = regionClients.get(regionName);
        if (client == null) {
            throw new IllegalArgumentException("Unknown region: " + regionName);
        }
        return client.ping();
    }

    /**
     * Gets status from a specific region by name.
     *
     * @param regionName the region to query
     * @return the status response from that region
     * @throws IllegalArgumentException if region is not found
     */
    public StatusResponse getStatus(String regionName) {
        ensureOpen();
        GeoClientImpl client = regionClients.get(regionName);
        if (client == null) {
            throw new IllegalArgumentException("Unknown region: " + regionName);
        }
        return client.getStatus();
    }

    @Override
    public void close() {
        if (!closed) {
            closed = true;
            for (GeoClientImpl client : regionClients.values()) {
                client.close();
            }
            regionClients.clear();
        }
    }

    // ========================================================================
    // Read Preference Routing
    // ========================================================================

    /**
     * Selects the appropriate client for read operations based on read preference.
     */
    private GeoClientImpl selectReadClient() {
        switch (config.getReadPreference()) {
            case PRIMARY:
                return primaryClient;

            case FOLLOWER:
                return selectFollowerClient();

            case NEAREST:
                return selectNearestClient();

            default:
                return primaryClient;
        }
    }

    /**
     * Selects a follower client for reading. Falls back to primary if no followers are available.
     */
    private GeoClientImpl selectFollowerClient() {
        List<RegionConfig> followers = config.getFollowerRegions();
        if (followers.isEmpty()) {
            return primaryClient;
        }

        // Simple round-robin selection for now
        // TODO: Add health-aware selection
        RegionConfig follower = followers.get(0);
        return regionClients.get(follower.getName());
    }

    /**
     * Selects the nearest client based on latency. Currently returns the first available client.
     * TODO: Implement latency-based selection with health checks.
     */
    private GeoClientImpl selectNearestClient() {
        // For skeleton implementation, just return primary
        // Real implementation would measure latencies
        return primaryClient;
    }

    private void ensureOpen() {
        if (closed) {
            throw new IllegalStateException("Client has been closed");
        }
    }
}
