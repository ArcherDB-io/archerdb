// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

/**
 * Policy for assigning entities to geographic regions.
 * <p>
 * Controls how entities are routed to different geographic regions for data locality optimization.
 * </p>
 *
 * @see <a href="https://docs.archerdb.io/reference/geo-sharding#policy">Geo-Sharding Policy</a>
 */
public enum GeoShardPolicy {
    /**
     * No geo-sharding - all entities in single region.
     */
    NONE((byte) 0),

    /**
     * Route based on entity's lat/lon coordinates to nearest region.
     */
    BY_ENTITY_LOCATION((byte) 1),

    /**
     * Route based on entity_id prefix mapping to regions.
     */
    BY_ENTITY_ID_PREFIX((byte) 2),

    /**
     * Application explicitly specifies target region per entity.
     */
    EXPLICIT((byte) 3);

    private final byte value;

    GeoShardPolicy(byte value) {
        this.value = value;
    }

    /**
     * Returns the wire format value.
     */
    public byte getValue() {
        return value;
    }

    /**
     * Converts a wire format value to the enum.
     */
    public static GeoShardPolicy fromValue(byte value) {
        for (GeoShardPolicy policy : values()) {
            if (policy.value == value) {
                return policy;
            }
        }
        return NONE;
    }
}
