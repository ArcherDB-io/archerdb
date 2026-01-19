// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.georouting;

import java.util.LinkedList;

/**
 * Tracks latency statistics for a region.
 *
 * <p>
 * Maintains a rolling window of latency samples and tracks consecutive failures for health
 * determination.
 */
public class RegionLatencyStats {

    private final LinkedList<Double> samples;
    private final int maxSamples;
    private double averageMs;
    private int consecutiveFailures;
    private boolean healthy;
    private long lastProbeTimeMs;

    /**
     * Creates a new RegionLatencyStats.
     *
     * @param maxSamples Maximum number of samples in the rolling window
     */
    public RegionLatencyStats(int maxSamples) {
        this.maxSamples = maxSamples > 0 ? maxSamples : 5;
        this.samples = new LinkedList<>();
        this.averageMs = 0.0;
        this.consecutiveFailures = 0;
        this.healthy = true;
        this.lastProbeTimeMs = 0;
    }

    /**
     * Adds a latency sample in milliseconds.
     *
     * @param latencyMs Latency in milliseconds
     */
    public synchronized void addSample(double latencyMs) {
        samples.addLast(latencyMs);
        while (samples.size() > maxSamples) {
            samples.removeFirst();
        }

        // Calculate rolling average
        double sum = 0.0;
        for (Double sample : samples) {
            sum += sample;
        }
        averageMs = sum / samples.size();

        consecutiveFailures = 0;
        healthy = true;
        lastProbeTimeMs = System.currentTimeMillis();
    }

    /**
     * Records a probe failure.
     *
     * @param failureThreshold Number of failures before marking unhealthy
     */
    public synchronized void recordFailure(int failureThreshold) {
        consecutiveFailures++;
        if (consecutiveFailures >= failureThreshold) {
            healthy = false;
        }
        lastProbeTimeMs = System.currentTimeMillis();
    }

    /**
     * Returns the average latency in milliseconds.
     */
    public synchronized double getAverageMs() {
        return averageMs;
    }

    /**
     * Returns whether the region is healthy.
     */
    public synchronized boolean isHealthy() {
        return healthy;
    }

    /**
     * Returns the number of consecutive failures.
     */
    public synchronized int getConsecutiveFailures() {
        return consecutiveFailures;
    }

    /**
     * Marks the region as healthy and resets failures.
     */
    public synchronized void markHealthy() {
        healthy = true;
        consecutiveFailures = 0;
    }

    /**
     * Marks the region as unhealthy.
     */
    public synchronized void markUnhealthy() {
        healthy = false;
    }

    /**
     * Returns the number of samples in the window.
     */
    public synchronized int getSampleCount() {
        return samples.size();
    }

    /**
     * Returns the last probe time in milliseconds since epoch.
     */
    public synchronized long getLastProbeTimeMs() {
        return lastProbeTimeMs;
    }
}
