// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

/**
 * A geographic region in the geo-sharding topology.
 * <p>
 * Represents a physical region where data can be stored for geo-sharding purposes.
 * </p>
 *
 * @see <a href="https://docs.archerdb.io/reference/geo-sharding#region">Geo Region</a>
 */
public class GeoRegion {
    private String regionId;
    private String name;
    private String endpoint;
    private long centerLatNano;
    private long centerLonNano;
    private byte priority;
    private boolean isActive;

    /**
     * Creates a new GeoRegion.
     */
    public GeoRegion() {
        this.regionId = "";
        this.name = "";
        this.endpoint = "";
        this.isActive = true;
    }

    /**
     * Creates a new GeoRegion with the given parameters.
     *
     * @param regionId Unique identifier (max 16 characters)
     * @param name Human-readable name
     * @param endpoint Endpoint address
     * @param centerLatitude Center latitude in degrees
     * @param centerLongitude Center longitude in degrees
     */
    public GeoRegion(String regionId, String name, String endpoint, double centerLatitude,
            double centerLongitude) {
        this.regionId = regionId;
        this.name = name;
        this.endpoint = endpoint;
        this.centerLatNano = (long) (centerLatitude * 1_000_000_000L);
        this.centerLonNano = (long) (centerLongitude * 1_000_000_000L);
        this.priority = 0;
        this.isActive = true;
    }

    /**
     * Returns the unique region identifier.
     */
    public String getRegionId() {
        return regionId;
    }

    /**
     * Sets the unique region identifier.
     */
    public void setRegionId(String regionId) {
        this.regionId = regionId;
    }

    /**
     * Returns the human-readable name.
     */
    public String getName() {
        return name;
    }

    /**
     * Sets the human-readable name.
     */
    public void setName(String name) {
        this.name = name;
    }

    /**
     * Returns the endpoint address.
     */
    public String getEndpoint() {
        return endpoint;
    }

    /**
     * Sets the endpoint address.
     */
    public void setEndpoint(String endpoint) {
        this.endpoint = endpoint;
    }

    /**
     * Returns the center latitude in nanodegrees.
     */
    public long getCenterLatNano() {
        return centerLatNano;
    }

    /**
     * Sets the center latitude in nanodegrees.
     */
    public void setCenterLatNano(long centerLatNano) {
        this.centerLatNano = centerLatNano;
    }

    /**
     * Returns the center longitude in nanodegrees.
     */
    public long getCenterLonNano() {
        return centerLonNano;
    }

    /**
     * Sets the center longitude in nanodegrees.
     */
    public void setCenterLonNano(long centerLonNano) {
        this.centerLonNano = centerLonNano;
    }

    /**
     * Returns the center latitude in degrees.
     */
    public double getCenterLatitude() {
        return centerLatNano / 1_000_000_000.0;
    }

    /**
     * Sets the center latitude from degrees.
     */
    public void setCenterLatitude(double latitude) {
        this.centerLatNano = (long) (latitude * 1_000_000_000L);
    }

    /**
     * Returns the center longitude in degrees.
     */
    public double getCenterLongitude() {
        return centerLonNano / 1_000_000_000.0;
    }

    /**
     * Sets the center longitude from degrees.
     */
    public void setCenterLongitude(double longitude) {
        this.centerLonNano = (long) (longitude * 1_000_000_000L);
    }

    /**
     * Returns the routing priority (lower = higher priority).
     */
    public byte getPriority() {
        return priority;
    }

    /**
     * Sets the routing priority.
     */
    public void setPriority(byte priority) {
        this.priority = priority;
    }

    /**
     * Returns whether this region is currently active.
     */
    public boolean isActive() {
        return isActive;
    }

    /**
     * Sets whether this region is active.
     */
    public void setActive(boolean active) {
        isActive = active;
    }
}
