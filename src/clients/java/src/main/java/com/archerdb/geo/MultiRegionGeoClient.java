// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Multi-region GeoClient implementation with read preference routing.
 *
 * <p>
 * This implementation maintains connections to all configured regions and, when
 * {@link ReadPreference#NEAREST} is requested with background probing enabled, runs a daemon
 * {@link LatencyProber} that periodically measures TCP RTT to each region. NEAREST selection picks
 * the healthy region with the lowest rolling-average RTT; if no samples exist yet (e.g. the first
 * request after construction) or probing is disabled, NEAREST falls back to the first region in
 * {@link ClientConfig#getRegions()} order (v1 behavior).
 *
 * <ul>
 * <li>Write operations always go to the primary region</li>
 * <li>{@code PRIMARY} reads go to the primary region</li>
 * <li>{@code FOLLOWER} reads use deterministic first-follower selection</li>
 * <li>{@code NEAREST} reads are routed by latency when the prober has data, otherwise by static
 * config order</li>
 * </ul>
 */
final class MultiRegionGeoClient implements GeoClient {

    private final ClientConfig config;
    private final Map<String, GeoClientImpl> regionClients;
    private final GeoClientImpl primaryClient;
    /** Non-null iff NEAREST routing is configured and background probing is enabled. */
    private final LatencyProber prober;
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

        // Start the latency prober only when NEAREST routing is active, probing is enabled,
        // and there is more than one region to choose from. This avoids spawning a daemon
        // thread for PRIMARY/FOLLOWER clients and single-region tests.
        if (config.getReadPreference() == ReadPreference.NEAREST
                && config.isBackgroundProbingEnabled() && config.getRegions().size() > 1) {
            this.prober = new LatencyProber(config.getRegions(), config.getProbeIntervalMs(),
                    config.getProbeTimeoutMs(), config.getProbeSampleCount(),
                    config.getUnhealthyThreshold());
            this.prober.start();
        } else {
            this.prober = null;
        }
    }

    /**
     * Package-private accessor for the latency prober. Test-only — allows seeding samples without
     * opening real sockets.
     */
    LatencyProber getLatencyProberForTest() {
        return prober;
    }

    /**
     * Returns the name of the region the next read operation would be routed to given the current
     * read-preference and (for NEAREST) the current probe stats. Package-private so tests can
     * observe selection without issuing a real read.
     */
    String selectedReadRegionNameForTest() {
        GeoClientImpl selected = selectReadClient();
        for (Map.Entry<String, GeoClientImpl> entry : regionClients.entrySet()) {
            if (entry.getValue() == selected)
                return entry.getKey();
        }
        return null;
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
            if (prober != null) {
                prober.stop();
            }
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
     * Nearest-region routing. When the latency prober has at least one healthy region with a
     * measured RTT sample, returns the client for the region with the lowest rolling-average RTT.
     * Otherwise (prober disabled, no samples yet, or all regions unhealthy) falls back to the first
     * region in {@link ClientConfig#getRegions()} order — the v1 static-priority behavior. The
     * static fallback guarantees the very first request after client construction does not block on
     * a probe.
     */
    private GeoClientImpl selectNearestClient() {
        if (prober != null) {
            String best = pickLowestLatencyRegion();
            if (best != null) {
                GeoClientImpl client = regionClients.get(best);
                if (client != null) {
                    return client;
                }
            }
        }
        // Static fallback: first region in config order.
        List<RegionConfig> regions = config.getRegions();
        if (!regions.isEmpty()) {
            GeoClientImpl client = regionClients.get(regions.get(0).getName());
            if (client != null) {
                return client;
            }
        }
        return primaryClient;
    }

    /**
     * Returns the name of the healthy region with the lowest average probe RTT, or null if no
     * healthy region has any samples yet.
     */
    private String pickLowestLatencyRegion() {
        String bestName = null;
        long bestRtt = Long.MAX_VALUE;
        for (RegionConfig region : config.getRegions()) {
            RegionLatencyStats stats = prober.getStats(region.getName());
            if (stats == null || !stats.isSelectable()) {
                continue;
            }
            long rtt = stats.getAverageRttNanos();
            if (rtt < 0) {
                continue;
            }
            if (rtt < bestRtt) {
                bestRtt = rtt;
                bestName = region.getName();
            }
        }
        return bestName;
    }

    private void ensureOpen() {
        if (closed) {
            throw new IllegalStateException("Client has been closed");
        }
    }
}
