// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;


/**
 * Output format for geographic data.
 */
public enum GeoFormat {
    /** Native nanodegree format */
    NATIVE((byte) 0),
    /** GeoJSON format */
    GEOJSON((byte) 1),
    /** Well-Known Text format */
    WKT((byte) 2);

    private final byte value;

    GeoFormat(byte value) {
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
    public static GeoFormat fromValue(byte value) {
        for (GeoFormat format : values()) {
            if (format.value == value) {
                return format;
            }
        }
        return NATIVE;
    }
}
