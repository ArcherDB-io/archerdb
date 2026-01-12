package com.archerdb.geo;

import java.util.Arrays;
import java.util.Objects;

/**
 * Configuration for a single region in a multi-region deployment.
 *
 * <p>
 * Per client-sdk/spec.md v2 multi-region support, each region has:
 * <ul>
 * <li>name - Unique identifier for the region (e.g., "us-west-2")</li>
 * <li>addresses - Array of replica addresses in host:port format</li>
 * <li>role - PRIMARY or FOLLOWER</li>
 * </ul>
 *
 * <p>
 * This class is immutable and thread-safe.
 */
public final class RegionConfig {

    private final String name;
    private final String[] addresses;
    private final RegionRole role;

    private RegionConfig(String name, String[] addresses, RegionRole role) {
        this.name = name;
        this.addresses = addresses;
        this.role = role;
    }

    /**
     * Creates a new RegionConfig.
     *
     * @param name the region name (e.g., "us-west-2")
     * @param addresses replica addresses in host:port format
     * @param role the region role (PRIMARY or FOLLOWER)
     * @return the region configuration
     * @throws IllegalArgumentException if any parameter is invalid
     */
    public static RegionConfig create(String name, String[] addresses, RegionRole role) {
        if (name == null || name.isEmpty()) {
            throw new IllegalArgumentException("Region name cannot be null or empty");
        }
        if (addresses == null || addresses.length == 0) {
            throw new IllegalArgumentException("At least one address is required");
        }
        if (role == null) {
            throw new IllegalArgumentException("Region role cannot be null");
        }
        return new RegionConfig(name, addresses.clone(), role);
    }

    /**
     * Creates a primary region configuration.
     *
     * @param name the region name
     * @param addresses replica addresses
     * @return the region configuration
     */
    public static RegionConfig primary(String name, String... addresses) {
        return create(name, addresses, RegionRole.PRIMARY);
    }

    /**
     * Creates a follower region configuration.
     *
     * @param name the region name
     * @param addresses replica addresses
     * @return the region configuration
     */
    public static RegionConfig follower(String name, String... addresses) {
        return create(name, addresses, RegionRole.FOLLOWER);
    }

    /**
     * Returns the region name.
     */
    public String getName() {
        return name;
    }

    /**
     * Returns a copy of the replica addresses.
     */
    public String[] getAddresses() {
        return addresses.clone();
    }

    /**
     * Returns the region role.
     */
    public RegionRole getRole() {
        return role;
    }

    /**
     * Returns true if this is the primary region.
     */
    public boolean isPrimary() {
        return role == RegionRole.PRIMARY;
    }

    /**
     * Returns true if this is a follower region.
     */
    public boolean isFollower() {
        return role == RegionRole.FOLLOWER;
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) {
            return true;
        }
        if (!(obj instanceof RegionConfig)) {
            return false;
        }
        RegionConfig other = (RegionConfig) obj;
        return Objects.equals(name, other.name) && Arrays.equals(addresses, other.addresses)
                && role == other.role;
    }

    @Override
    public int hashCode() {
        int result = Objects.hash(name, role);
        result = 31 * result + Arrays.hashCode(addresses);
        return result;
    }

    @Override
    public String toString() {
        return "RegionConfig{name='" + name + "', role=" + role + ", addresses="
                + Arrays.toString(addresses) + "}";
    }

    /**
     * Builder for RegionConfig.
     */
    public static class Builder {
        private String name;
        private String[] addresses;
        private RegionRole role = RegionRole.FOLLOWER;

        public Builder setName(String name) {
            this.name = name;
            return this;
        }

        public Builder setAddresses(String... addresses) {
            this.addresses = addresses;
            return this;
        }

        public Builder setRole(RegionRole role) {
            this.role = role;
            return this;
        }

        public Builder asPrimary() {
            this.role = RegionRole.PRIMARY;
            return this;
        }

        public Builder asFollower() {
            this.role = RegionRole.FOLLOWER;
            return this;
        }

        public RegionConfig build() {
            return RegionConfig.create(name, addresses, role);
        }
    }
}
