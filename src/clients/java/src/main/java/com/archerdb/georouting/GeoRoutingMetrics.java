// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.georouting;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Metrics for geo-routing operations.
 *
 * <p>
 * Per the add-geo-routing spec, this tracks:
 * <ul>
 * <li>archerdb_geo_routing_queries_total - Total geo-routed queries</li>
 * <li>archerdb_geo_routing_region_switches_total - Total region switches</li>
 * <li>archerdb_geo_routing_region_latency_ms - Region latency in milliseconds</li>
 * </ul>
 */
public class GeoRoutingMetrics {

    private final AtomicLong queriesTotal = new AtomicLong(0);
    private final AtomicLong regionSwitchesTotal = new AtomicLong(0);
    private final AtomicLong probeErrorsTotal = new AtomicLong(0);
    private final Map<String, AtomicLong> regionLatencyTotalMicros = new ConcurrentHashMap<>();
    private final Map<String, AtomicLong> regionLatencyCounts = new ConcurrentHashMap<>();
    private final AtomicReference<String> currentRegion = new AtomicReference<>("");

    /**
     * Records a query to a region.
     *
     * @param region Region name
     */
    public void recordQuery(String region) {
        queriesTotal.incrementAndGet();
    }

    /**
     * Records a region switch.
     *
     * @param fromRegion Previous region
     * @param toRegion New region
     */
    public void recordSwitch(String fromRegion, String toRegion) {
        regionSwitchesTotal.incrementAndGet();
        currentRegion.set(toRegion);
    }

    /**
     * Records a probe error.
     */
    public void recordProbeError() {
        probeErrorsTotal.incrementAndGet();
    }

    /**
     * Returns total probe errors.
     */
    public long getProbeErrorsTotal() {
        return probeErrorsTotal.get();
    }

    /**
     * Records a latency sample for a region.
     *
     * @param region Region name
     * @param latencyMs Latency in milliseconds
     */
    public void recordLatency(String region, double latencyMs) {
        long latencyMicros = (long) (latencyMs * 1000);
        regionLatencyTotalMicros.computeIfAbsent(region, k -> new AtomicLong(0))
                .addAndGet(latencyMicros);
        regionLatencyCounts.computeIfAbsent(region, k -> new AtomicLong(0)).incrementAndGet();
    }

    /**
     * Returns total queries.
     */
    public long getQueriesTotal() {
        return queriesTotal.get();
    }

    /**
     * Returns total region switches.
     */
    public long getSwitchesTotal() {
        return regionSwitchesTotal.get();
    }

    /**
     * Returns the current region.
     */
    public String getCurrentRegion() {
        return currentRegion.get();
    }

    /**
     * Returns average latency for a region in milliseconds.
     *
     * @param region Region name
     * @return Average latency in ms, or 0 if no samples
     */
    public double getAverageLatencyMs(String region) {
        AtomicLong totalMicros = regionLatencyTotalMicros.get(region);
        AtomicLong count = regionLatencyCounts.get(region);
        if (totalMicros == null || count == null || count.get() == 0) {
            return 0.0;
        }
        return totalMicros.get() / (count.get() * 1000.0);
    }

    /**
     * Exports metrics in Prometheus text format.
     */
    public String toPrometheus() {
        StringBuilder sb = new StringBuilder();

        sb.append("# HELP archerdb_geo_routing_queries_total Total geo-routed queries\n");
        sb.append("# TYPE archerdb_geo_routing_queries_total counter\n");
        sb.append(String.format("archerdb_geo_routing_queries_total %d%n", queriesTotal.get()));

        sb.append("# HELP archerdb_geo_routing_region_switches_total Total region switches\n");
        sb.append("# TYPE archerdb_geo_routing_region_switches_total counter\n");
        sb.append(String.format("archerdb_geo_routing_region_switches_total %d%n",
                regionSwitchesTotal.get()));

        sb.append("# HELP archerdb_geo_routing_region_latency_ms Region latency in milliseconds\n");
        sb.append("# TYPE archerdb_geo_routing_region_latency_ms gauge\n");
        for (Map.Entry<String, AtomicLong> entry : regionLatencyTotalMicros.entrySet()) {
            String region = entry.getKey();
            AtomicLong count = regionLatencyCounts.get(region);
            if (count != null && count.get() > 0) {
                double avgMs = entry.getValue().get() / (count.get() * 1000.0);
                sb.append(String.format(
                        "archerdb_geo_routing_region_latency_ms{region=\"%s\"} %.3f%n", region,
                        avgMs));
            }
        }

        return sb.toString();
    }

    /**
     * Resets all metrics.
     */
    public void reset() {
        queriesTotal.set(0);
        regionSwitchesTotal.set(0);
        probeErrorsTotal.set(0);
        regionLatencyTotalMicros.clear();
        regionLatencyCounts.clear();
        currentRegion.set("");
    }
}
