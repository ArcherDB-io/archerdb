// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.georouting;

/**
 * Configuration for geo-routing functionality.
 *
 * <p>
 * Per the add-geo-routing spec, this configures:
 * <ul>
 * <li>Region discovery settings</li>
 * <li>Latency probing parameters</li>
 * <li>Failover behavior</li>
 * </ul>
 */
public class GeoRoutingConfig {

    private boolean enabled = false;
    private String preferredRegion = null;
    private boolean failoverEnabled = true;
    private int probeIntervalMs = 30000;
    private int probeTimeoutMs = 5000;
    private int failureThreshold = 3;
    private int cacheTtlMs = 300000;
    private int latencySampleSize = 5;
    private double clientLatitude = Double.NaN;
    private double clientLongitude = Double.NaN;

    /**
     * Creates a new GeoRoutingConfig with default values.
     */
    public GeoRoutingConfig() {}

    /**
     * Creates a builder for GeoRoutingConfig.
     */
    public static Builder builder() {
        return new Builder();
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getPreferredRegion() {
        return preferredRegion;
    }

    public void setPreferredRegion(String preferredRegion) {
        this.preferredRegion = preferredRegion;
    }

    public boolean isFailoverEnabled() {
        return failoverEnabled;
    }

    public void setFailoverEnabled(boolean failoverEnabled) {
        this.failoverEnabled = failoverEnabled;
    }

    public int getProbeIntervalMs() {
        return probeIntervalMs;
    }

    public void setProbeIntervalMs(int probeIntervalMs) {
        this.probeIntervalMs = probeIntervalMs;
    }

    public int getProbeTimeoutMs() {
        return probeTimeoutMs;
    }

    public void setProbeTimeoutMs(int probeTimeoutMs) {
        this.probeTimeoutMs = probeTimeoutMs;
    }

    public int getFailureThreshold() {
        return failureThreshold;
    }

    public void setFailureThreshold(int failureThreshold) {
        this.failureThreshold = failureThreshold;
    }

    public int getCacheTtlMs() {
        return cacheTtlMs;
    }

    public void setCacheTtlMs(int cacheTtlMs) {
        this.cacheTtlMs = cacheTtlMs;
    }

    public int getLatencySampleSize() {
        return latencySampleSize;
    }

    public void setLatencySampleSize(int latencySampleSize) {
        this.latencySampleSize = latencySampleSize;
    }

    public double getClientLatitude() {
        return clientLatitude;
    }

    public void setClientLatitude(double clientLatitude) {
        this.clientLatitude = clientLatitude;
    }

    public double getClientLongitude() {
        return clientLongitude;
    }

    public void setClientLongitude(double clientLongitude) {
        this.clientLongitude = clientLongitude;
    }

    public boolean hasClientLocation() {
        return !Double.isNaN(clientLatitude) && !Double.isNaN(clientLongitude);
    }

    /**
     * Builder for GeoRoutingConfig.
     */
    public static class Builder {
        private final GeoRoutingConfig config = new GeoRoutingConfig();

        public Builder enabled(boolean enabled) {
            config.setEnabled(enabled);
            return this;
        }

        public Builder preferredRegion(String region) {
            config.setPreferredRegion(region);
            return this;
        }

        public Builder failoverEnabled(boolean enabled) {
            config.setFailoverEnabled(enabled);
            return this;
        }

        public Builder probeIntervalMs(int ms) {
            config.setProbeIntervalMs(ms);
            return this;
        }

        public Builder probeTimeoutMs(int ms) {
            config.setProbeTimeoutMs(ms);
            return this;
        }

        public Builder failureThreshold(int threshold) {
            config.setFailureThreshold(threshold);
            return this;
        }

        public Builder cacheTtlMs(int ms) {
            config.setCacheTtlMs(ms);
            return this;
        }

        public Builder latencySampleSize(int size) {
            config.setLatencySampleSize(size);
            return this;
        }

        public Builder clientLocation(double latitude, double longitude) {
            config.setClientLatitude(latitude);
            config.setClientLongitude(longitude);
            return this;
        }

        public GeoRoutingConfig build() {
            return config;
        }
    }
}
