// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

import org.junit.jupiter.api.Test;

/**
 * Unit tests for the latency-aware behavior of {@link ReadPreference#NEAREST} routing in
 * {@link MultiRegionGeoClient}. Uses the package-private {@code seed}/{@code peek} accessors on the
 * client and prober so no real network I/O is required.
 */
class MultiRegionNearestLatencyTest {

    private static ClientConfig twoRegionConfig(boolean backgroundProbingEnabled) {
        return ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("us-east-1", "127.0.0.1:3001"))
                .addRegion(RegionConfig.follower("us-west-2", "127.0.0.1:3002"))
                .setReadPreference(ReadPreference.NEAREST)
                .setBackgroundProbingEnabled(backgroundProbingEnabled).build();
    }

    @Test
    void nearestWithProbingDisabledFallsBackToStaticOrder() {
        MultiRegionGeoClient client = new MultiRegionGeoClient(twoRegionConfig(false));
        try {
            assertNull(client.getLatencyProberForTest(),
                    "Prober must not be started when backgroundProbingEnabled=false");
            // Static fallback: first region in config order (us-east-1).
            assertEquals("us-east-1", client.selectedReadRegionNameForTest());
        } finally {
            client.close();
        }
    }

    @Test
    void nearestWithNoProbeSamplesFallsBackToStaticOrder() {
        MultiRegionGeoClient client = new MultiRegionGeoClient(twoRegionConfig(true));
        try {
            LatencyProber prober = client.getLatencyProberForTest();
            assertNotNull(prober, "Prober must be constructed for NEAREST + probing enabled");
            prober.stop(); // Halt background thread; we only want manually seeded state.
            // No samples seeded yet — selection must return the first region (v1 fallback).
            assertEquals("us-east-1", client.selectedReadRegionNameForTest());
        } finally {
            client.close();
        }
    }

    @Test
    void nearestPicksRegionWithLowestAverageRtt() {
        MultiRegionGeoClient client = new MultiRegionGeoClient(twoRegionConfig(true));
        try {
            LatencyProber prober = client.getLatencyProberForTest();
            prober.stop();
            // us-east-1 is slower (50ms average); us-west-2 is faster (5ms).
            prober.recordSample("us-east-1", 50_000_000L);
            prober.recordSample("us-east-1", 50_000_000L);
            prober.recordSample("us-west-2", 5_000_000L);
            prober.recordSample("us-west-2", 5_000_000L);
            assertEquals("us-west-2", client.selectedReadRegionNameForTest(),
                    "Latency-aware NEAREST must pick the region with the lowest average RTT");
        } finally {
            client.close();
        }
    }

    @Test
    void nearestExcludesUnhealthyRegionEvenIfPreviouslyFaster() {
        MultiRegionGeoClient client = new MultiRegionGeoClient(twoRegionConfig(true));
        try {
            LatencyProber prober = client.getLatencyProberForTest();
            prober.stop();
            // Seed us-west-2 with low RTT, then knock it unhealthy via three probe failures
            // (the default unhealthyThreshold from ClientConfig).
            prober.recordSample("us-west-2", 3_000_000L);
            prober.recordFailure("us-west-2");
            prober.recordFailure("us-west-2");
            prober.recordFailure("us-west-2");
            // us-east-1 stays healthy with a slower sample.
            prober.recordSample("us-east-1", 40_000_000L);
            assertEquals("us-east-1", client.selectedReadRegionNameForTest(),
                    "Unhealthy regions must be excluded regardless of their last RTT sample");
        } finally {
            client.close();
        }
    }

    @Test
    void nearestIsStableWhenOnlyOneHealthyRegionHasSamples() {
        MultiRegionGeoClient client = new MultiRegionGeoClient(twoRegionConfig(true));
        try {
            LatencyProber prober = client.getLatencyProberForTest();
            prober.stop();
            // Only us-east-1 has any samples; us-west-2 is UNKNOWN and, per the Python-mirrored
            // contract, still eligible. But with a measured sample on us-east-1 and none on
            // us-west-2, the selector should pick the only region with a measured average.
            prober.recordSample("us-east-1", 20_000_000L);
            assertEquals("us-east-1", client.selectedReadRegionNameForTest());
        } finally {
            client.close();
        }
    }
}
