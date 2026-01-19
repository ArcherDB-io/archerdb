// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.georouting;

/**
 * Information about a discovered region for geo-routing.
 */
public class RegionInfo {

    private String name;
    private String endpoint;
    private double latitude;
    private double longitude;
    private boolean healthy;

    /**
     * Creates a new RegionInfo.
     */
    public RegionInfo() {
        this.healthy = true;
    }

    /**
     * Creates a new RegionInfo with the given parameters.
     *
     * @param name Unique region identifier (e.g., "us-east-1")
     * @param endpoint Connection endpoint (host:port)
     * @param latitude Geographic latitude
     * @param longitude Geographic longitude
     */
    public RegionInfo(String name, String endpoint, double latitude, double longitude) {
        this.name = name;
        this.endpoint = endpoint;
        this.latitude = latitude;
        this.longitude = longitude;
        this.healthy = true;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public String getEndpoint() {
        return endpoint;
    }

    public void setEndpoint(String endpoint) {
        this.endpoint = endpoint;
    }

    public double getLatitude() {
        return latitude;
    }

    public void setLatitude(double latitude) {
        this.latitude = latitude;
    }

    public double getLongitude() {
        return longitude;
    }

    public void setLongitude(double longitude) {
        this.longitude = longitude;
    }

    public boolean isHealthy() {
        return healthy;
    }

    public void setHealthy(boolean healthy) {
        this.healthy = healthy;
    }

    @Override
    public String toString() {
        return String.format("RegionInfo{name='%s', endpoint='%s', lat=%.4f, lon=%.4f, healthy=%b}",
                name, endpoint, latitude, longitude, healthy);
    }
}
