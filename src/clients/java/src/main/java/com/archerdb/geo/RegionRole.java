// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Role of a region in a multi-region deployment.
 *
 * <p>
 * Per replication/spec.md v2 multi-region support:
 * <ul>
 * <li>PRIMARY - Accepts reads and writes, ships log entries to followers</li>
 * <li>FOLLOWER - Read-only, applies log entries from primary asynchronously</li>
 * </ul>
 */
public enum RegionRole {

    /**
     * Primary region that accepts all writes and ships log entries to followers. A deployment has
     * exactly one primary region.
     */
    PRIMARY("primary"),

    /**
     * Follower region that replicates from primary via async log shipping. Follower regions are
     * read-only and may have some staleness.
     */
    FOLLOWER("follower");

    private final String value;

    RegionRole(String value) {
        this.value = value;
    }

    /**
     * Returns the string value for configuration/wire format.
     */
    public String getValue() {
        return value;
    }

    /**
     * Returns the RegionRole for the given string value.
     *
     * @param value the string value (case-insensitive)
     * @return the corresponding RegionRole
     * @throws IllegalArgumentException if value is not recognized
     */
    public static RegionRole fromValue(String value) {
        if (value == null) {
            throw new IllegalArgumentException("RegionRole value cannot be null");
        }
        String normalized = value.toLowerCase();
        for (RegionRole role : values()) {
            if (role.value.equals(normalized)) {
                return role;
            }
        }
        throw new IllegalArgumentException("Unknown RegionRole: " + value);
    }
}
