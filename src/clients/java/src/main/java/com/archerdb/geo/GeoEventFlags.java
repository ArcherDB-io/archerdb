// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * GeoEvent status flags. Maps to GeoEventFlags in geo_event.zig
 */
public enum GeoEventFlags {
    /** No flags set. */
    NONE(0),

    /** Event is part of a linked chain (all succeed or fail together). */
    LINKED(1 << 0),

    /** Event was imported with client-provided timestamp. */
    IMPORTED(1 << 1),

    /** Entity is not moving (stationary). */
    STATIONARY(1 << 2),

    /** GPS accuracy below threshold. */
    LOW_ACCURACY(1 << 3),

    /** Entity is offline/unreachable. */
    OFFLINE(1 << 4),

    /** Entity has been deleted (GDPR compliance). */
    DELETED(1 << 5);

    private final short value;

    GeoEventFlags(int value) {
        this.value = (short) value;
    }

    /**
     * Returns the numeric value of this flag.
     */
    public short getValue() {
        return value;
    }

    /**
     * Combines multiple flags into a single value.
     */
    public static short combine(GeoEventFlags... flags) {
        short result = 0;
        for (GeoEventFlags flag : flags) {
            result |= flag.value;
        }
        return result;
    }
}
