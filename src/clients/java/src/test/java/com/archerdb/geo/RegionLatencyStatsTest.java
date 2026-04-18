// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class RegionLatencyStatsTest {

    @Test
    void newStatsIsSelectableWithNoSamples() {
        RegionLatencyStats stats = new RegionLatencyStats("us-east-1", 5);
        assertEquals(RegionLatencyStats.Health.UNKNOWN, stats.getHealth());
        assertTrue(stats.isSelectable(),
                "UNKNOWN regions must be eligible so the first request does not block on probes");
        assertEquals(-1L, stats.getAverageRttNanos());
        assertEquals(0, stats.getSampleCount());
    }

    @Test
    void addSampleTransitionsToHealthyAndRecordsAverage() {
        RegionLatencyStats stats = new RegionLatencyStats("us-east-1", 5);
        stats.addSample(10_000_000L);
        stats.addSample(20_000_000L);
        assertEquals(RegionLatencyStats.Health.HEALTHY, stats.getHealth());
        assertEquals(2, stats.getSampleCount());
        assertEquals(15_000_000L, stats.getAverageRttNanos());
    }

    @Test
    void rollingWindowEvictsOldestSample() {
        RegionLatencyStats stats = new RegionLatencyStats("us-east-1", 3);
        stats.addSample(1_000L);
        stats.addSample(2_000L);
        stats.addSample(3_000L);
        stats.addSample(4_000L);
        assertEquals(3, stats.getSampleCount());
        // Oldest sample (1000) dropped; window holds 2000, 3000, 4000 — average 3000.
        assertEquals(3_000L, stats.getAverageRttNanos());
    }

    @Test
    void successfulSampleClearsConsecutiveFailures() {
        RegionLatencyStats stats = new RegionLatencyStats("us-east-1", 5);
        stats.recordFailure(3);
        stats.recordFailure(3);
        assertEquals(2, stats.getConsecutiveFailures());
        stats.addSample(5_000_000L);
        assertEquals(0, stats.getConsecutiveFailures());
        assertEquals(RegionLatencyStats.Health.HEALTHY, stats.getHealth());
    }

    @Test
    void consecutiveFailuresAtThresholdMarkUnhealthy() {
        RegionLatencyStats stats = new RegionLatencyStats("us-east-1", 5);
        stats.recordFailure(3);
        stats.recordFailure(3);
        assertEquals(RegionLatencyStats.Health.UNKNOWN, stats.getHealth());
        assertTrue(stats.isSelectable());
        stats.recordFailure(3);
        assertEquals(RegionLatencyStats.Health.UNHEALTHY, stats.getHealth());
        assertFalse(stats.isSelectable(),
                "UNHEALTHY regions must be excluded from latency-based selection");
    }

    @Test
    void recoveryFromUnhealthyOnNextSuccess() {
        RegionLatencyStats stats = new RegionLatencyStats("us-east-1", 5);
        for (int i = 0; i < 3; i++)
            stats.recordFailure(3);
        assertEquals(RegionLatencyStats.Health.UNHEALTHY, stats.getHealth());
        stats.addSample(8_000_000L);
        assertEquals(RegionLatencyStats.Health.HEALTHY, stats.getHealth());
        assertTrue(stats.isSelectable());
    }
}
