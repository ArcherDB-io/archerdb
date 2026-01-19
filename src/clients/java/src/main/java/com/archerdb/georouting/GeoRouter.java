// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.georouting;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Main coordinator for geo-routing functionality.
 *
 * <p>
 * Per the add-geo-routing spec, provides:
 * <ul>
 * <li>Region Discovery - Fetch from /regions endpoint with caching</li>
 * <li>Latency Probing - Background TCP probing with rolling averages</li>
 * <li>Region Selection - Filter healthy, prefer configured, select lowest latency</li>
 * <li>Automatic Failover - Mark unhealthy after failures, select next best</li>
 * <li>Metrics - Prometheus-format metrics</li>
 * </ul>
 */
public class GeoRouter {

    private final GeoRoutingConfig config;
    private final String discoveryUrl;
    private final GeoRoutingMetrics metrics;
    private final Map<String, RegionLatencyStats> regionStats;
    private final AtomicReference<String> currentRegion;
    private final AtomicReference<DiscoveryCache> discoveryCache;

    private ScheduledExecutorService probeExecutor;
    private volatile boolean running;

    /**
     * Creates a new GeoRouter.
     *
     * @param discoveryUrl Base URL for the discovery endpoint
     * @param config Geo-routing configuration
     */
    public GeoRouter(String discoveryUrl, GeoRoutingConfig config) {
        this.discoveryUrl =
                discoveryUrl.endsWith("/") ? discoveryUrl.substring(0, discoveryUrl.length() - 1)
                        : discoveryUrl;
        this.config = config;
        this.metrics = new GeoRoutingMetrics();
        this.regionStats = new ConcurrentHashMap<>();
        this.currentRegion = new AtomicReference<>("");
        this.discoveryCache = new AtomicReference<>();
        this.running = false;
    }

    /**
     * Starts the geo-router.
     *
     * @throws IOException if region discovery fails
     */
    public void start() throws IOException {
        if (!config.isEnabled()) {
            return;
        }

        // Fetch initial regions
        List<RegionInfo> regions = fetchRegions();
        if (regions.isEmpty()) {
            throw new IOException("No regions discovered");
        }

        // Start background probing
        probeExecutor = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "archerdb-geo-prober");
            t.setDaemon(true);
            return t;
        });

        running = true;

        // Initial probe
        for (RegionInfo region : regions) {
            probeRegion(region);
        }

        // Schedule periodic probing
        probeExecutor.scheduleAtFixedRate(() -> {
            try {
                List<RegionInfo> currentRegions = fetchRegions();
                for (RegionInfo region : currentRegions) {
                    probeRegion(region);
                }
            } catch (Exception e) {
                // Probe errors are expected during network issues and don't need handling
                metrics.recordProbeError();
            }
        }, config.getProbeIntervalMs(), config.getProbeIntervalMs(), TimeUnit.MILLISECONDS);

        // Select initial region
        RegionInfo selected = selectRegion(regions, Collections.emptySet());
        if (selected != null) {
            currentRegion.set(selected.getName());
            metrics.recordSwitch("", selected.getName());
        }
    }

    /**
     * Stops the geo-router.
     */
    public void stop() {
        running = false;
        if (probeExecutor != null) {
            probeExecutor.shutdown();
            try {
                if (!probeExecutor.awaitTermination(5, TimeUnit.SECONDS)) {
                    probeExecutor.shutdownNow();
                }
            } catch (InterruptedException e) {
                probeExecutor.shutdownNow();
                Thread.currentThread().interrupt();
            }
        }
    }

    /**
     * Returns whether the geo-router is currently running.
     */
    public boolean isRunning() {
        return running;
    }

    /**
     * Returns the currently selected region name.
     */
    public String getCurrentRegion() {
        return currentRegion.get();
    }

    /**
     * Returns the endpoint for the currently selected region.
     *
     * @return Endpoint string
     * @throws IOException if no region is selected or discovery fails
     */
    public String getCurrentEndpoint() throws IOException {
        if (!config.isEnabled()) {
            throw new IOException("Geo-routing not enabled");
        }

        String region = currentRegion.get();
        if (region == null || region.isEmpty()) {
            throw new IOException("No region selected");
        }

        List<RegionInfo> regions = fetchRegions();
        for (RegionInfo r : regions) {
            if (r.getName().equals(region)) {
                return r.getEndpoint();
            }
        }

        throw new IOException("Region not found: " + region);
    }

    /**
     * Selects a region, optionally excluding specific regions.
     *
     * @param excludeRegions Regions to exclude from selection
     * @return Selected region or null
     * @throws IOException if discovery fails
     */
    public RegionInfo selectBestRegion(Set<String> excludeRegions) throws IOException {
        List<RegionInfo> regions = fetchRegions();
        RegionInfo selected = selectRegion(regions, excludeRegions);

        if (selected != null) {
            String oldRegion = currentRegion.get();
            if (!selected.getName().equals(oldRegion)) {
                currentRegion.set(selected.getName());
                metrics.recordSwitch(oldRegion, selected.getName());
            }
        }

        return selected;
    }

    /**
     * Records a successful operation to a region.
     *
     * @param regionName Region name
     */
    public void recordSuccess(String regionName) {
        metrics.recordQuery(regionName);
        RegionLatencyStats stats = getOrCreateStats(regionName);
        stats.markHealthy();
    }

    /**
     * Records a failed operation and triggers failover if enabled.
     *
     * @param regionName Failed region name
     * @return New region if failover occurred, null otherwise
     * @throws IOException if discovery fails during failover
     */
    public RegionInfo recordFailure(String regionName) throws IOException {
        RegionLatencyStats stats = getOrCreateStats(regionName);
        stats.recordFailure(config.getFailureThreshold());

        if (!config.isFailoverEnabled()) {
            return null;
        }

        if (!stats.isHealthy()) {
            Set<String> exclude = new HashSet<>();
            exclude.add(regionName);
            return selectBestRegion(exclude);
        }

        return null;
    }

    /**
     * Returns the metrics instance.
     */
    public GeoRoutingMetrics getMetrics() {
        return metrics;
    }

    /**
     * Returns the configuration.
     */
    public GeoRoutingConfig getConfig() {
        return config;
    }

    /**
     * Returns whether geo-routing is enabled.
     */
    public boolean isEnabled() {
        return config.isEnabled();
    }

    /**
     * Refreshes the region list from the discovery endpoint.
     *
     * @throws IOException if discovery fails
     */
    public void refreshRegions() throws IOException {
        discoveryCache.set(null);
        fetchRegions();
    }

    // Internal methods

    private List<RegionInfo> fetchRegions() throws IOException {
        // Check cache
        DiscoveryCache cache = discoveryCache.get();
        if (cache != null && !cache.isExpired(config.getCacheTtlMs())) {
            return cache.regions;
        }

        // Fetch from server
        String url = discoveryUrl + "/regions";
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setConnectTimeout(config.getProbeTimeoutMs());
        conn.setReadTimeout(config.getProbeTimeoutMs());
        conn.setRequestMethod("GET");

        try {
            int status = conn.getResponseCode();
            if (status != 200) {
                throw new IOException("Discovery failed with status: " + status);
            }

            BufferedReader reader =
                    new BufferedReader(new InputStreamReader(conn.getInputStream()));
            StringBuilder response = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                response.append(line);
            }
            reader.close();

            List<RegionInfo> regions = parseRegions(response.toString());
            discoveryCache.set(new DiscoveryCache(regions));
            return regions;
        } finally {
            conn.disconnect();
        }
    }

    private List<RegionInfo> parseRegions(String json) {
        // Simple JSON parsing for regions array
        List<RegionInfo> regions = new ArrayList<>();

        // Find "regions" array
        int regionsStart = json.indexOf("\"regions\"");
        if (regionsStart == -1) {
            return regions;
        }

        int arrayStart = json.indexOf('[', regionsStart);
        int arrayEnd = json.indexOf(']', arrayStart);
        if (arrayStart == -1 || arrayEnd == -1) {
            return regions;
        }

        String regionsArray = json.substring(arrayStart + 1, arrayEnd);

        // Parse each region object
        int pos = 0;
        while (pos < regionsArray.length()) {
            int objStart = regionsArray.indexOf('{', pos);
            if (objStart == -1)
                break;

            int objEnd = regionsArray.indexOf('}', objStart);
            if (objEnd == -1)
                break;

            String obj = regionsArray.substring(objStart, objEnd + 1);
            RegionInfo region = parseRegion(obj);
            if (region != null) {
                regions.add(region);
            }

            pos = objEnd + 1;
        }

        return regions;
    }

    private RegionInfo parseRegion(String json) {
        try {
            RegionInfo region = new RegionInfo();

            // Parse name
            String name = extractString(json, "name");
            if (name != null)
                region.setName(name);

            // Parse endpoint
            String endpoint = extractString(json, "endpoint");
            if (endpoint != null)
                region.setEndpoint(endpoint);

            // Parse location
            int locStart = json.indexOf("\"location\"");
            if (locStart != -1) {
                int locObjStart = json.indexOf('{', locStart);
                int locObjEnd = json.indexOf('}', locObjStart);
                if (locObjStart != -1 && locObjEnd != -1) {
                    String locJson = json.substring(locObjStart, locObjEnd + 1);
                    Double lat = extractNumber(locJson, "Latitude");
                    Double lon = extractNumber(locJson, "Longitude");
                    if (lat != null)
                        region.setLatitude(lat);
                    if (lon != null)
                        region.setLongitude(lon);
                }
            }

            // Parse healthy
            Boolean healthy = extractBoolean(json, "healthy");
            if (healthy != null)
                region.setHealthy(healthy);

            return region;
        } catch (Exception e) {
            return null;
        }
    }

    private String extractString(String json, String key) {
        String pattern = "\"" + key + "\"";
        int keyStart = json.indexOf(pattern);
        if (keyStart == -1)
            return null;

        int colonPos = json.indexOf(':', keyStart);
        if (colonPos == -1)
            return null;

        int valueStart = json.indexOf('"', colonPos);
        if (valueStart == -1)
            return null;

        int valueEnd = json.indexOf('"', valueStart + 1);
        if (valueEnd == -1)
            return null;

        return json.substring(valueStart + 1, valueEnd);
    }

    private Double extractNumber(String json, String key) {
        String pattern = "\"" + key + "\"";
        int keyStart = json.indexOf(pattern);
        if (keyStart == -1)
            return null;

        int colonPos = json.indexOf(':', keyStart);
        if (colonPos == -1)
            return null;

        int start = colonPos + 1;
        while (start < json.length() && Character.isWhitespace(json.charAt(start))) {
            start++;
        }

        StringBuilder num = new StringBuilder();
        while (start < json.length()) {
            char c = json.charAt(start);
            if (Character.isDigit(c) || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E') {
                num.append(c);
                start++;
            } else {
                break;
            }
        }

        try {
            return Double.parseDouble(num.toString());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private Boolean extractBoolean(String json, String key) {
        String pattern = "\"" + key + "\"";
        int keyStart = json.indexOf(pattern);
        if (keyStart == -1)
            return null;

        int colonPos = json.indexOf(':', keyStart);
        if (colonPos == -1)
            return null;

        int start = colonPos + 1;
        while (start < json.length() && Character.isWhitespace(json.charAt(start))) {
            start++;
        }

        if (json.regionMatches(start, "true", 0, 4)) {
            return true;
        } else if (json.regionMatches(start, "false", 0, 5)) {
            return false;
        }

        return null;
    }

    private void probeRegion(RegionInfo region) {
        String endpoint = region.getEndpoint();
        if (endpoint == null || endpoint.isEmpty()) {
            return;
        }

        String[] parts = endpoint.split(":");
        if (parts.length != 2) {
            return;
        }

        String host = parts[0];
        int port;
        try {
            port = Integer.parseInt(parts[1]);
        } catch (NumberFormatException e) {
            return;
        }

        RegionLatencyStats stats = getOrCreateStats(region.getName());

        long startNanos = System.nanoTime();
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(host, port), config.getProbeTimeoutMs());
            long endNanos = System.nanoTime();
            double latencyMs = (endNanos - startNanos) / 1_000_000.0;
            stats.addSample(latencyMs);
            metrics.recordLatency(region.getName(), latencyMs);
        } catch (IOException e) {
            stats.recordFailure(config.getFailureThreshold());
        }
    }

    private RegionLatencyStats getOrCreateStats(String regionName) {
        return regionStats.computeIfAbsent(regionName,
                k -> new RegionLatencyStats(config.getLatencySampleSize()));
    }

    private RegionInfo selectRegion(List<RegionInfo> regions, Set<String> excludeRegions) {
        if (regions.isEmpty()) {
            return null;
        }

        // Filter healthy regions not in exclude list
        List<RegionInfo> candidates = new ArrayList<>();
        for (RegionInfo r : regions) {
            if (excludeRegions.contains(r.getName())) {
                continue;
            }

            RegionLatencyStats stats = regionStats.get(r.getName());
            if (stats != null && !stats.isHealthy()) {
                continue;
            }

            if (!r.isHealthy()) {
                continue;
            }

            candidates.add(r);
        }

        if (candidates.isEmpty()) {
            return null;
        }

        // If preferred region is available, use it
        String preferred = config.getPreferredRegion();
        if (preferred != null && !preferred.isEmpty()) {
            for (RegionInfo r : candidates) {
                if (r.getName().equals(preferred)) {
                    return r;
                }
            }
        }

        // Sort by latency
        candidates.sort((a, b) -> {
            RegionLatencyStats statsA = regionStats.get(a.getName());
            RegionLatencyStats statsB = regionStats.get(b.getName());

            boolean hasStatsA = statsA != null && statsA.getSampleCount() > 0;
            boolean hasStatsB = statsB != null && statsB.getSampleCount() > 0;
            double latA = hasStatsA ? statsA.getAverageMs() : Double.MAX_VALUE;
            double latB = hasStatsB ? statsB.getAverageMs() : Double.MAX_VALUE;

            return Double.compare(latA, latB);
        });

        // If no latency data, fall back to distance
        RegionInfo first = candidates.get(0);
        RegionLatencyStats firstStats = regionStats.get(first.getName());
        boolean noLatencyData = firstStats == null || firstStats.getSampleCount() == 0;
        if (noLatencyData && config.hasClientLocation()) {
            candidates.sort((a, b) -> {
                double distA = haversineDistance(config.getClientLatitude(),
                        config.getClientLongitude(), a.getLatitude(), a.getLongitude());
                double distB = haversineDistance(config.getClientLatitude(),
                        config.getClientLongitude(), b.getLatitude(), b.getLongitude());
                return Double.compare(distA, distB);
            });
        }

        return candidates.get(0);
    }

    private double haversineDistance(double lat1, double lon1, double lat2, double lon2) {
        final double R = 6371.0; // Earth's radius in km

        double dLat = Math.toRadians(lat2 - lat1);
        double dLon = Math.toRadians(lon2 - lon1);

        double a = Math.sin(dLat / 2) * Math.sin(dLat / 2) + Math.cos(Math.toRadians(lat1))
                * Math.cos(Math.toRadians(lat2)) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

        return R * c;
    }

    // Cache class
    private static class DiscoveryCache {
        final List<RegionInfo> regions;
        final long fetchedAtMs;

        DiscoveryCache(List<RegionInfo> regions) {
            this.regions = regions;
            this.fetchedAtMs = System.currentTimeMillis();
        }

        boolean isExpired(int cacheTtlMs) {
            return System.currentTimeMillis() - fetchedAtMs > cacheTtlMs;
        }
    }
}
