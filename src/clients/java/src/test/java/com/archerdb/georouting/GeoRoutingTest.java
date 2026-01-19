// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.georouting;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

/**
 * Unit tests for geo-routing functionality.
 *
 * <p>
 * Per the add-geo-routing spec, tests verify:
 * <ul>
 * <li>Configuration - settings and builder pattern</li>
 * <li>Latency tracking - rolling averages and health status</li>
 * <li>Metrics - counters and Prometheus export</li>
 * </ul>
 *
 * <p>
 * Note: Integration tests requiring network access are in separate test files.
 */
class GeoRoutingTest {

    // ========================================================================
    // GeoRoutingConfig Tests
    // ========================================================================

    @Test
    void testDefaultConfig() {
        GeoRoutingConfig config = new GeoRoutingConfig();

        assertFalse(config.isEnabled());
        assertTrue(config.isFailoverEnabled());
        assertEquals(30000, config.getProbeIntervalMs());
        assertEquals(5000, config.getProbeTimeoutMs());
        assertEquals(3, config.getFailureThreshold());
        assertEquals(300000, config.getCacheTtlMs());
        assertEquals(5, config.getLatencySampleSize());
        assertNull(config.getPreferredRegion());
    }

    @Test
    void testConfigBuilder() {
        GeoRoutingConfig config = GeoRoutingConfig.builder().enabled(true)
                .preferredRegion("us-west-2").failoverEnabled(false).probeIntervalMs(10000)
                .probeTimeoutMs(2000).failureThreshold(5).cacheTtlMs(60000).latencySampleSize(10)
                .clientLocation(40.7128, -74.0060).build();

        assertTrue(config.isEnabled());
        assertEquals("us-west-2", config.getPreferredRegion());
        assertFalse(config.isFailoverEnabled());
        assertEquals(10000, config.getProbeIntervalMs());
        assertEquals(2000, config.getProbeTimeoutMs());
        assertEquals(5, config.getFailureThreshold());
        assertEquals(60000, config.getCacheTtlMs());
        assertEquals(10, config.getLatencySampleSize());
        assertTrue(config.hasClientLocation());
        assertEquals(40.7128, config.getClientLatitude(), 0.0001);
        assertEquals(-74.0060, config.getClientLongitude(), 0.0001);
    }

    @Test
    void testConfigHasClientLocation() {
        GeoRoutingConfig config = new GeoRoutingConfig();
        assertFalse(config.hasClientLocation());

        config.setClientLatitude(40.0);
        config.setClientLongitude(-74.0);
        assertTrue(config.hasClientLocation());
    }

    @Test
    void testConfigSetters() {
        GeoRoutingConfig config = new GeoRoutingConfig();

        config.setEnabled(true);
        config.setPreferredRegion("eu-west-1");
        config.setFailoverEnabled(false);
        config.setProbeIntervalMs(15000);
        config.setProbeTimeoutMs(3000);
        config.setFailureThreshold(5);
        config.setCacheTtlMs(120000);
        config.setLatencySampleSize(7);

        assertTrue(config.isEnabled());
        assertEquals("eu-west-1", config.getPreferredRegion());
        assertFalse(config.isFailoverEnabled());
        assertEquals(15000, config.getProbeIntervalMs());
        assertEquals(3000, config.getProbeTimeoutMs());
        assertEquals(5, config.getFailureThreshold());
        assertEquals(120000, config.getCacheTtlMs());
        assertEquals(7, config.getLatencySampleSize());
    }

    // ========================================================================
    // RegionInfo Tests
    // ========================================================================

    @Test
    void testRegionInfoConstruction() {
        RegionInfo region = new RegionInfo("us-east-1", "localhost:8080", 37.7749, -122.4194);

        assertEquals("us-east-1", region.getName());
        assertEquals("localhost:8080", region.getEndpoint());
        assertEquals(37.7749, region.getLatitude(), 0.0001);
        assertEquals(-122.4194, region.getLongitude(), 0.0001);
        assertTrue(region.isHealthy());
    }

    @Test
    void testRegionInfoDefaultConstructor() {
        RegionInfo region = new RegionInfo();

        assertNull(region.getName());
        assertNull(region.getEndpoint());
        assertTrue(region.isHealthy()); // Default to healthy
    }

    @Test
    void testRegionInfoSetters() {
        RegionInfo region = new RegionInfo();
        region.setName("eu-west-1");
        region.setEndpoint("eu.example.com:8080");
        region.setLatitude(51.5074);
        region.setLongitude(-0.1278);
        region.setHealthy(false);

        assertEquals("eu-west-1", region.getName());
        assertEquals("eu.example.com:8080", region.getEndpoint());
        assertEquals(51.5074, region.getLatitude(), 0.0001);
        assertEquals(-0.1278, region.getLongitude(), 0.0001);
        assertFalse(region.isHealthy());
    }

    @Test
    void testRegionInfoToString() {
        RegionInfo region = new RegionInfo("us-east-1", "localhost:8080", 37.7749, -122.4194);
        String str = region.toString();

        assertTrue(str.contains("us-east-1"));
        assertTrue(str.contains("localhost:8080"));
    }

    // ========================================================================
    // RegionLatencyStats Tests
    // ========================================================================

    @Test
    void testLatencyStatsAddSample() {
        RegionLatencyStats stats = new RegionLatencyStats(5);

        stats.addSample(10.0);

        assertEquals(10.0, stats.getAverageMs(), 0.001);
        assertTrue(stats.isHealthy());
        assertEquals(1, stats.getSampleCount());
    }

    @Test
    void testLatencyStatsMultipleSamples() {
        RegionLatencyStats stats = new RegionLatencyStats(5);

        stats.addSample(10.0);
        stats.addSample(20.0);
        stats.addSample(30.0);

        assertEquals(20.0, stats.getAverageMs(), 0.001); // (10+20+30)/3
        assertEquals(3, stats.getSampleCount());
    }

    @Test
    void testLatencyStatsRollingWindow() {
        RegionLatencyStats stats = new RegionLatencyStats(3);

        stats.addSample(10.0);
        stats.addSample(20.0);
        stats.addSample(30.0);
        stats.addSample(40.0); // Should drop 10.0

        double expected = (20.0 + 30.0 + 40.0) / 3.0;
        assertEquals(expected, stats.getAverageMs(), 0.001);
        assertEquals(3, stats.getSampleCount());
    }

    @Test
    void testLatencyStatsRecordFailure() {
        RegionLatencyStats stats = new RegionLatencyStats(5);
        int threshold = 3;

        // Record failures up to threshold
        for (int i = 0; i < threshold; i++) {
            assertTrue(stats.isHealthy(), "Should be healthy before " + threshold + " failures");
            stats.recordFailure(threshold);
        }

        assertFalse(stats.isHealthy());
        assertEquals(threshold, stats.getConsecutiveFailures());
    }

    @Test
    void testLatencyStatsFailureBeforeThreshold() {
        RegionLatencyStats stats = new RegionLatencyStats(5);

        stats.recordFailure(3);
        stats.recordFailure(3);

        assertTrue(stats.isHealthy()); // Not yet at threshold
        assertEquals(2, stats.getConsecutiveFailures());
    }

    @Test
    void testLatencyStatsSuccessResetsFailures() {
        RegionLatencyStats stats = new RegionLatencyStats(5);

        stats.recordFailure(3);
        stats.recordFailure(3);
        stats.addSample(10.0);

        assertEquals(0, stats.getConsecutiveFailures());
        assertTrue(stats.isHealthy());
    }

    @Test
    void testLatencyStatsMarkHealthy() {
        RegionLatencyStats stats = new RegionLatencyStats(5);

        // Make unhealthy
        for (int i = 0; i < 3; i++) {
            stats.recordFailure(3);
        }
        assertFalse(stats.isHealthy());

        // Mark healthy
        stats.markHealthy();
        assertTrue(stats.isHealthy());
        assertEquals(0, stats.getConsecutiveFailures());
    }

    @Test
    void testLatencyStatsMarkUnhealthy() {
        RegionLatencyStats stats = new RegionLatencyStats(5);
        stats.addSample(10.0);
        assertTrue(stats.isHealthy());

        stats.markUnhealthy();
        assertFalse(stats.isHealthy());
    }

    @Test
    void testLatencyStatsLastProbeTime() {
        RegionLatencyStats stats = new RegionLatencyStats(5);
        assertEquals(0, stats.getLastProbeTimeMs());

        stats.addSample(10.0);
        assertTrue(stats.getLastProbeTimeMs() > 0);

        long firstProbe = stats.getLastProbeTimeMs();
        try {
            Thread.sleep(10);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }

        stats.recordFailure(3);
        assertTrue(stats.getLastProbeTimeMs() >= firstProbe);
    }

    @Test
    void testLatencyStatsDefaultMaxSamples() {
        RegionLatencyStats stats = new RegionLatencyStats(0); // Should default to 5

        for (int i = 0; i < 10; i++) {
            stats.addSample(i * 10.0);
        }

        // Should have only kept the last 5 samples
        assertEquals(5, stats.getSampleCount());
    }

    // ========================================================================
    // GeoRoutingMetrics Tests
    // ========================================================================

    @Test
    void testMetricsRecordQuery() {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();

        metrics.recordQuery("us-east-1");
        metrics.recordQuery("us-east-1");

        assertEquals(2, metrics.getQueriesTotal());
    }

    @Test
    void testMetricsRecordSwitch() {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();

        metrics.recordSwitch("us-east-1", "us-west-2");

        assertEquals(1, metrics.getSwitchesTotal());
        assertEquals("us-west-2", metrics.getCurrentRegion());
    }

    @Test
    void testMetricsMultipleSwitches() {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();

        metrics.recordSwitch("", "us-east-1");
        metrics.recordSwitch("us-east-1", "us-west-2");
        metrics.recordSwitch("us-west-2", "eu-west-1");

        assertEquals(3, metrics.getSwitchesTotal());
        assertEquals("eu-west-1", metrics.getCurrentRegion());
    }

    @Test
    void testMetricsRecordLatency() {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();

        metrics.recordLatency("us-east-1", 10.0);
        metrics.recordLatency("us-east-1", 20.0);

        assertEquals(15.0, metrics.getAverageLatencyMs("us-east-1"), 0.001);
    }

    @Test
    void testMetricsLatencyMultipleRegions() {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();

        metrics.recordLatency("us-east-1", 10.0);
        metrics.recordLatency("us-west-2", 50.0);

        assertEquals(10.0, metrics.getAverageLatencyMs("us-east-1"), 0.001);
        assertEquals(50.0, metrics.getAverageLatencyMs("us-west-2"), 0.001);
        assertEquals(0.0, metrics.getAverageLatencyMs("unknown"), 0.001);
    }

    @Test
    void testMetricsToPrometheus() {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();

        metrics.recordQuery("us-east-1");
        metrics.recordSwitch("", "us-east-1");
        metrics.recordLatency("us-east-1", 10.0);

        String prometheus = metrics.toPrometheus();

        assertTrue(prometheus.contains("archerdb_geo_routing_queries_total 1"));
        assertTrue(prometheus.contains("archerdb_geo_routing_region_switches_total 1"));
        assertTrue(prometheus.contains("archerdb_geo_routing_region_latency_ms"));
        assertTrue(prometheus.contains("us-east-1"));
        assertTrue(prometheus.contains("# HELP"));
        assertTrue(prometheus.contains("# TYPE"));
    }

    @Test
    void testMetricsPrometheusEmpty() {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();

        String prometheus = metrics.toPrometheus();

        assertTrue(prometheus.contains("archerdb_geo_routing_queries_total 0"));
        assertTrue(prometheus.contains("archerdb_geo_routing_region_switches_total 0"));
    }

    @Test
    void testMetricsReset() {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();

        metrics.recordQuery("us-east-1");
        metrics.recordSwitch("", "us-east-1");
        metrics.recordLatency("us-east-1", 10.0);
        metrics.reset();

        assertEquals(0, metrics.getQueriesTotal());
        assertEquals(0, metrics.getSwitchesTotal());
        assertEquals("", metrics.getCurrentRegion());
        assertEquals(0.0, metrics.getAverageLatencyMs("us-east-1"), 0.001);
    }

    // ========================================================================
    // GeoRouter Basic Tests (no network)
    // ========================================================================

    @Test
    void testGeoRouterNotEnabled() {
        GeoRoutingConfig config = new GeoRoutingConfig();
        config.setEnabled(false);

        GeoRouter router = new GeoRouter("http://localhost:8080", config);

        assertFalse(router.isEnabled());
        assertNotNull(router.getMetrics());
        assertNotNull(router.getConfig());
    }

    @Test
    void testGeoRouterIsEnabled() {
        GeoRoutingConfig config = GeoRoutingConfig.builder().enabled(true).build();

        GeoRouter router = new GeoRouter("http://localhost:8080", config);

        assertTrue(router.isEnabled());
    }

    @Test
    void testGeoRouterGetConfig() {
        GeoRoutingConfig config =
                GeoRoutingConfig.builder().enabled(true).preferredRegion("us-west-2").build();

        GeoRouter router = new GeoRouter("http://localhost:8080", config);

        assertEquals("us-west-2", router.getConfig().getPreferredRegion());
        assertTrue(router.getConfig().isEnabled());
    }

    @Test
    void testGeoRouterRecordSuccess() {
        GeoRoutingConfig config = GeoRoutingConfig.builder().enabled(true).build();

        GeoRouter router = new GeoRouter("http://localhost:8080", config);
        router.recordSuccess("us-east-1");

        assertEquals(1, router.getMetrics().getQueriesTotal());
    }

    @Test
    void testGeoRouterUrlNormalization() {
        GeoRoutingConfig config = GeoRoutingConfig.builder().enabled(true).build();

        // Test with trailing slash
        GeoRouter router1 = new GeoRouter("http://localhost:8080/", config);
        assertNotNull(router1);

        // Test without trailing slash
        GeoRouter router2 = new GeoRouter("http://localhost:8080", config);
        assertNotNull(router2);
    }

    @Test
    void testGeoRouterStartWhenDisabled() throws Exception {
        GeoRoutingConfig config = new GeoRoutingConfig();
        config.setEnabled(false);

        GeoRouter router = new GeoRouter("http://localhost:8080", config);
        router.start(); // Should not throw when disabled
        router.stop(); // Should handle gracefully
    }

    @Test
    void testGeoRouterGetCurrentRegionEmpty() {
        GeoRoutingConfig config = GeoRoutingConfig.builder().enabled(true).build();

        GeoRouter router = new GeoRouter("http://localhost:8080", config);

        // Before start, current region should be empty
        assertEquals("", router.getCurrentRegion());
    }

    // ========================================================================
    // Concurrent Access Tests
    // ========================================================================

    @Test
    void testLatencyStatsConcurrentAccess() throws InterruptedException {
        RegionLatencyStats stats = new RegionLatencyStats(10);
        int threadCount = 10;
        int samplesPerThread = 100;

        Thread[] threads = new Thread[threadCount];
        for (int i = 0; i < threadCount; i++) {
            threads[i] = new Thread(() -> {
                for (int j = 0; j < samplesPerThread; j++) {
                    stats.addSample(Math.random() * 100);
                }
            });
        }

        for (Thread t : threads) {
            t.start();
        }
        for (Thread t : threads) {
            t.join();
        }

        // Stats should be consistent after concurrent access
        assertTrue(stats.getSampleCount() <= 10); // Max samples
        assertTrue(stats.isHealthy());
    }

    @Test
    void testMetricsConcurrentAccess() throws InterruptedException {
        GeoRoutingMetrics metrics = new GeoRoutingMetrics();
        int threadCount = 10;
        int queriesPerThread = 100;

        Thread[] threads = new Thread[threadCount];
        for (int i = 0; i < threadCount; i++) {
            threads[i] = new Thread(() -> {
                for (int j = 0; j < queriesPerThread; j++) {
                    metrics.recordQuery("region-" + (j % 3));
                }
            });
        }

        for (Thread t : threads) {
            t.start();
        }
        for (Thread t : threads) {
            t.join();
        }

        assertEquals(threadCount * queriesPerThread, metrics.getQueriesTotal());
    }
}
