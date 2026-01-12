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

    private final UInt128 clusterId;
    private final List<RegionConfig> regions;
    private final ReadPreference readPreference;
    private final int connectTimeoutMs;
    private final int requestTimeoutMs;
    private final int maxStalenessMs;

    private ClientConfig(Builder builder) {
        this.clusterId = builder.clusterId;
        this.regions = Collections.unmodifiableList(new ArrayList<>(builder.regions));
        this.readPreference = builder.readPreference;
        this.connectTimeoutMs = builder.connectTimeoutMs;
        this.requestTimeoutMs = builder.requestTimeoutMs;
        this.maxStalenessMs = builder.maxStalenessMs;
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
                && maxStalenessMs == other.maxStalenessMs;
    }

    @Override
    public int hashCode() {
        return Objects.hash(clusterId, regions, readPreference, connectTimeoutMs, requestTimeoutMs,
                maxStalenessMs);
    }

    @Override
    public String toString() {
        return "ClientConfig{clusterId=" + clusterId + ", regions=" + regions + ", readPreference="
                + readPreference + ", connectTimeoutMs=" + connectTimeoutMs + ", requestTimeoutMs="
                + requestTimeoutMs + ", maxStalenessMs=" + maxStalenessMs + "}";
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
