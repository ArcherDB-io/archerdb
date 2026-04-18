// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.ArrayDeque;
import java.util.Deque;

/**
 * Rolling latency stats for a single region. Mirrors the Python {@code RegionLatencyStats} in
 * {@code geo_routing.py} so the two SDKs behave the same way under the
 * {@link ReadPreference#NEAREST} routing policy.
 *
 * <p>
 * Thread-safety: all mutating and reading methods are synchronized on the instance. The prober
 * writes from a background thread; {@link MultiRegionGeoClient#selectReadClient()} reads from
 * whichever caller thread is making a request.
 *
 * <p>
 * Health model:
 * <ul>
 * <li>{@link Health#UNKNOWN} — never probed; the selector treats this as eligible so routing does
 * not stall waiting for the first probe cycle.</li>
 * <li>{@link Health#HEALTHY} — at least one successful probe, fewer than {@code unhealthyThreshold}
 * consecutive failures.</li>
 * <li>{@link Health#UNHEALTHY} — {@code unhealthyThreshold} consecutive failures; excluded from
 * latency-based selection until the next successful probe.</li>
 * </ul>
 */
final class RegionLatencyStats {

    /** Health enum (IntEnum in Python) kept small and explicit. */
    enum Health {
        UNKNOWN,
        HEALTHY,
        UNHEALTHY
    }

    private final String regionName;
    private final int sampleWindow;
    private final Deque<Long> samplesNanos;
    private int consecutiveFailures = 0;
    private Health health = Health.UNKNOWN;
    private long lastProbeNanos = 0L;

    RegionLatencyStats(String regionName, int sampleWindow) {
        if (sampleWindow <= 0) {
            throw new IllegalArgumentException("sampleWindow must be positive");
        }
        this.regionName = regionName;
        this.sampleWindow = sampleWindow;
        this.samplesNanos = new ArrayDeque<>(sampleWindow);
    }

    String getRegionName() {
        return regionName;
    }

    /**
     * Record a successful probe. Resets the consecutive-failure counter and marks the region
     * healthy. Called from the probe thread.
     */
    synchronized void addSample(long rttNanos) {
        if (samplesNanos.size() >= sampleWindow) {
            samplesNanos.removeFirst();
        }
        samplesNanos.addLast(rttNanos);
        consecutiveFailures = 0;
        lastProbeNanos = System.nanoTime();
        if (health != Health.HEALTHY) {
            health = Health.HEALTHY;
        }
    }

    /**
     * Record a probe failure. Transitions to {@link Health#UNHEALTHY} when
     * {@code consecutiveFailures >= unhealthyThreshold}.
     */
    synchronized void recordFailure(int unhealthyThreshold) {
        consecutiveFailures++;
        lastProbeNanos = System.nanoTime();
        if (consecutiveFailures >= unhealthyThreshold) {
            health = Health.UNHEALTHY;
        }
    }

    /** Returns the rolling-window arithmetic mean in nanoseconds, or -1 if no samples. */
    synchronized long getAverageRttNanos() {
        if (samplesNanos.isEmpty()) {
            return -1L;
        }
        long total = 0L;
        for (long v : samplesNanos) {
            total += v;
        }
        return total / samplesNanos.size();
    }

    synchronized int getSampleCount() {
        return samplesNanos.size();
    }

    synchronized int getConsecutiveFailures() {
        return consecutiveFailures;
    }

    synchronized long getLastProbeNanos() {
        return lastProbeNanos;
    }

    synchronized Health getHealth() {
        return health;
    }

    /**
     * Returns true when the region is eligible for latency-based selection. UNKNOWN counts as
     * eligible so the very first request after client construction does not block on probes.
     */
    synchronized boolean isSelectable() {
        return health != Health.UNHEALTHY;
    }
}
