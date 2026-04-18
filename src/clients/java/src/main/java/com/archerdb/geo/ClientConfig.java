// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

/**
 * Configuration for a multi-region GeoClient.
 *
 * <p>
 * Per client-sdk/spec.md v2 multi-region support, the client config includes:
 * <ul>
 * <li>regions - List of RegionConfig objects defining the topology</li>
 * <li>readPreference - Routing strategy for read operations</li>
 * <li>clusterId - Cluster identifier for validation</li>
 * <li>requestTimeoutMs - Default timeout for operations</li>
 * </ul>
 *
 * <p>
 * Write operations always go to the primary region. Read operations are routed according to the
 * read preference setting.
 *
 * <p>
 * This class is immutable and thread-safe.
 */
public final class ClientConfig {

    private static final int DEFAULT_CONNECT_TIMEOUT_MS = 5000;
    private static final int DEFAULT_REQUEST_TIMEOUT_MS = 30000;
    private static final int DEFAULT_MAX_STALENESS_MS = 10000;
    // Latency-aware NEAREST routing defaults. Values match Python's geo_routing defaults so
    // the two SDKs behave consistently under the same ReadPreference.
    private static final int DEFAULT_PROBE_INTERVAL_MS = 30_000;
    private static final int DEFAULT_PROBE_TIMEOUT_MS = 5_000;
    private static final int DEFAULT_PROBE_SAMPLE_COUNT = 5;
    private static final int DEFAULT_UNHEALTHY_THRESHOLD = 3;

    private final UInt128 clusterId;
    private final List<RegionConfig> regions;
    private final ReadPreference readPreference;
    private final int connectTimeoutMs;
    private final int requestTimeoutMs;
    private final int maxStalenessMs;
    private final int probeIntervalMs;
    private final int probeTimeoutMs;
    private final int probeSampleCount;
    private final int unhealthyThreshold;
    private final boolean backgroundProbingEnabled;

    private ClientConfig(Builder builder) {
        this.clusterId = builder.clusterId;
        this.regions = Collections.unmodifiableList(new ArrayList<>(builder.regions));
        this.readPreference = builder.readPreference;
        this.connectTimeoutMs = builder.connectTimeoutMs;
        this.requestTimeoutMs = builder.requestTimeoutMs;
        this.maxStalenessMs = builder.maxStalenessMs;
        this.probeIntervalMs = builder.probeIntervalMs;
        this.probeTimeoutMs = builder.probeTimeoutMs;
        this.probeSampleCount = builder.probeSampleCount;
        this.unhealthyThreshold = builder.unhealthyThreshold;
        this.backgroundProbingEnabled = builder.backgroundProbingEnabled;
    }

    /**
     * Returns the cluster ID.
     */
    public UInt128 getClusterId() {
        return clusterId;
    }

    /**
     * Returns the list of regions (unmodifiable).
     */
    public List<RegionConfig> getRegions() {
        return regions;
    }

    /**
     * Returns the read preference.
     */
    public ReadPreference getReadPreference() {
        return readPreference;
    }

    /**
     * Returns the connection timeout in milliseconds. This is the maximum time to wait for a
     * connection to be established. Default: 5000ms per client-sdk/spec.md.
     */
    public int getConnectTimeoutMs() {
        return connectTimeoutMs;
    }

    /**
     * Returns the request timeout in milliseconds.
     */
    public int getRequestTimeoutMs() {
        return requestTimeoutMs;
    }

    /**
     * Returns the maximum acceptable staleness for follower reads in milliseconds. Reads from
     * followers with staleness exceeding this value will fail.
     */
    public int getMaxStalenessMs() {
        return maxStalenessMs;
    }

    /**
     * Returns the interval between latency probes for NEAREST routing, in milliseconds. Only
     * consulted when {@link #getReadPreference()} is {@link ReadPreference#NEAREST} and
     * {@link #isBackgroundProbingEnabled()} is true.
     */
    public int getProbeIntervalMs() {
        return probeIntervalMs;
    }

    /**
     * Returns the TCP connect timeout used by the latency prober, in milliseconds.
     */
    public int getProbeTimeoutMs() {
        return probeTimeoutMs;
    }

    /**
     * Returns the size of the rolling window of latency samples kept per region.
     */
    public int getProbeSampleCount() {
        return probeSampleCount;
    }

    /**
     * Returns the number of consecutive probe failures that transitions a region to unhealthy and
     * excludes it from latency-based NEAREST selection.
     */
    public int getUnhealthyThreshold() {
        return unhealthyThreshold;
    }

    /**
     * Returns whether the background latency prober is enabled. Default: true. Tests and embedded
     * uses that cannot afford a background thread can disable this, in which case NEAREST routing
     * falls back to static config order (v1 behavior).
     */
    public boolean isBackgroundProbingEnabled() {
        return backgroundProbingEnabled;
    }

    /**
     * Returns the primary region, or null if not found.
     */
    public RegionConfig getPrimaryRegion() {
        for (RegionConfig region : regions) {
            if (region.isPrimary()) {
                return region;
            }
        }
        return null;
    }

    /**
     * Returns all follower regions.
     */
    public List<RegionConfig> getFollowerRegions() {
        List<RegionConfig> followers = new ArrayList<>();
        for (RegionConfig region : regions) {
            if (region.isFollower()) {
                followers.add(region);
            }
        }
        return Collections.unmodifiableList(followers);
    }

    /**
     * Returns the region with the given name, or null if not found.
     */
    public RegionConfig getRegion(String name) {
        for (RegionConfig region : regions) {
            if (region.getName().equals(name)) {
                return region;
            }
        }
        return null;
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) {
            return true;
        }
        if (!(obj instanceof ClientConfig)) {
            return false;
        }
        ClientConfig other = (ClientConfig) obj;
        return Objects.equals(clusterId, other.clusterId) && Objects.equals(regions, other.regions)
                && readPreference == other.readPreference
                && connectTimeoutMs == other.connectTimeoutMs
                && requestTimeoutMs == other.requestTimeoutMs
                && maxStalenessMs == other.maxStalenessMs
                && probeIntervalMs == other.probeIntervalMs
                && probeTimeoutMs == other.probeTimeoutMs
                && probeSampleCount == other.probeSampleCount
                && unhealthyThreshold == other.unhealthyThreshold
                && backgroundProbingEnabled == other.backgroundProbingEnabled;
    }

    @Override
    public int hashCode() {
        return Objects.hash(clusterId, regions, readPreference, connectTimeoutMs, requestTimeoutMs,
                maxStalenessMs, probeIntervalMs, probeTimeoutMs, probeSampleCount,
                unhealthyThreshold, backgroundProbingEnabled);
    }

    @Override
    public String toString() {
        return "ClientConfig{clusterId=" + clusterId + ", regions=" + regions + ", readPreference="
                + readPreference + ", connectTimeoutMs=" + connectTimeoutMs + ", requestTimeoutMs="
                + requestTimeoutMs + ", maxStalenessMs=" + maxStalenessMs + ", probeIntervalMs="
                + probeIntervalMs + ", probeTimeoutMs=" + probeTimeoutMs + ", probeSampleCount="
                + probeSampleCount + ", unhealthyThreshold=" + unhealthyThreshold
                + ", backgroundProbingEnabled=" + backgroundProbingEnabled + "}";
    }

    /**
     * Creates a new Builder for ClientConfig.
     */
    public static Builder builder() {
        return new Builder();
    }

    /**
     * Creates a simple single-region configuration for backwards compatibility.
     *
     * @param clusterId the cluster ID
     * @param addresses replica addresses
     * @return the client configuration
     */
    public static ClientConfig singleRegion(UInt128 clusterId, String... addresses) {
        return builder().setClusterId(clusterId)
                .addRegion(RegionConfig.primary("default", addresses)).build();
    }

    /**
     * Builder for ClientConfig.
     */
    public static class Builder {
        private UInt128 clusterId;
        private final List<RegionConfig> regions = new ArrayList<>();
        private ReadPreference readPreference = ReadPreference.PRIMARY;
        private int connectTimeoutMs = DEFAULT_CONNECT_TIMEOUT_MS;
        private int requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS;
        private int maxStalenessMs = DEFAULT_MAX_STALENESS_MS;
        private int probeIntervalMs = DEFAULT_PROBE_INTERVAL_MS;
        private int probeTimeoutMs = DEFAULT_PROBE_TIMEOUT_MS;
        private int probeSampleCount = DEFAULT_PROBE_SAMPLE_COUNT;
        private int unhealthyThreshold = DEFAULT_UNHEALTHY_THRESHOLD;
        private boolean backgroundProbingEnabled = true;

        /**
         * Sets the cluster ID (required).
         */
        public Builder setClusterId(UInt128 clusterId) {
            this.clusterId = clusterId;
            return this;
        }

        /**
         * Adds a region to the configuration.
         */
        public Builder addRegion(RegionConfig region) {
            if (region == null) {
                throw new IllegalArgumentException("Region cannot be null");
            }
            this.regions.add(region);
            return this;
        }

        /**
         * Adds multiple regions to the configuration.
         */
        public Builder addRegions(List<RegionConfig> regions) {
            for (RegionConfig region : regions) {
                addRegion(region);
            }
            return this;
        }

        /**
         * Sets the read preference.
         */
        public Builder setReadPreference(ReadPreference readPreference) {
            if (readPreference == null) {
                throw new IllegalArgumentException("ReadPreference cannot be null");
            }
            this.readPreference = readPreference;
            return this;
        }

        /**
         * Sets the connection timeout in milliseconds. This is the maximum time to wait for a
         * connection to be established. Default: 5000ms per client-sdk/spec.md.
         */
        public Builder setConnectTimeoutMs(int timeoutMs) {
            if (timeoutMs <= 0) {
                throw new IllegalArgumentException("Connect timeout must be positive");
            }
            this.connectTimeoutMs = timeoutMs;
            return this;
        }

        /**
         * Sets the request timeout in milliseconds.
         */
        public Builder setRequestTimeoutMs(int timeoutMs) {
            if (timeoutMs <= 0) {
                throw new IllegalArgumentException("Request timeout must be positive");
            }
            this.requestTimeoutMs = timeoutMs;
            return this;
        }

        /**
         * Sets the maximum acceptable staleness for follower reads in milliseconds.
         */
        public Builder setMaxStalenessMs(int maxStalenessMs) {
            if (maxStalenessMs < 0) {
                throw new IllegalArgumentException("Max staleness cannot be negative");
            }
            this.maxStalenessMs = maxStalenessMs;
            return this;
        }

        /**
         * Sets the interval between latency probes for NEAREST routing.
         */
        public Builder setProbeIntervalMs(int probeIntervalMs) {
            if (probeIntervalMs <= 0) {
                throw new IllegalArgumentException("Probe interval must be positive");
            }
            this.probeIntervalMs = probeIntervalMs;
            return this;
        }

        /**
         * Sets the TCP connect timeout used by the latency prober.
         */
        public Builder setProbeTimeoutMs(int probeTimeoutMs) {
            if (probeTimeoutMs <= 0) {
                throw new IllegalArgumentException("Probe timeout must be positive");
            }
            this.probeTimeoutMs = probeTimeoutMs;
            return this;
        }

        /**
         * Sets the rolling window size of probe samples kept per region.
         */
        public Builder setProbeSampleCount(int probeSampleCount) {
            if (probeSampleCount <= 0) {
                throw new IllegalArgumentException("Probe sample count must be positive");
            }
            this.probeSampleCount = probeSampleCount;
            return this;
        }

        /**
         * Sets the number of consecutive probe failures that marks a region unhealthy.
         */
        public Builder setUnhealthyThreshold(int unhealthyThreshold) {
            if (unhealthyThreshold <= 0) {
                throw new IllegalArgumentException("Unhealthy threshold must be positive");
            }
            this.unhealthyThreshold = unhealthyThreshold;
            return this;
        }

        /**
         * Enables or disables the background latency prober. When false, NEAREST routing uses the
         * static region order (v1 behavior) instead of latency-aware selection.
         */
        public Builder setBackgroundProbingEnabled(boolean enabled) {
            this.backgroundProbingEnabled = enabled;
            return this;
        }

        /**
         * Builds the ClientConfig.
         *
         * @return the client configuration
         * @throws IllegalArgumentException if configuration is invalid
         */
        public ClientConfig build() {
            validate();
            return new ClientConfig(this);
        }

        private void validate() {
            if (clusterId == null) {
                throw new IllegalArgumentException("Cluster ID is required");
            }
            if (regions.isEmpty()) {
                throw new IllegalArgumentException("At least one region is required");
            }

            // Count primaries
            int primaryCount = 0;
            for (RegionConfig region : regions) {
                if (region.isPrimary()) {
                    primaryCount++;
                }
            }

            if (primaryCount == 0) {
                throw new IllegalArgumentException("Exactly one primary region is required");
            }
            if (primaryCount > 1) {
                throw new IllegalArgumentException(
                        "Only one primary region is allowed, found " + primaryCount);
            }
        }
    }
}
