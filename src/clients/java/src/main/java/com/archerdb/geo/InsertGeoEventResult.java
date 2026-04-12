// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Result codes for GeoEvent insert operations. Maps to InsertGeoEventResult in
 * geo_state_machine.zig
 */
public enum InsertGeoEventResult {
    OK(0),
    LINKED_EVENT_FAILED(1),
    LINKED_EVENT_CHAIN_OPEN(2),
    TIMESTAMP_MUST_BE_ZERO(3),
    RESERVED_FIELD(4),
    RESERVED_FLAG(5),
    ID_MUST_NOT_BE_ZERO(6),
    ENTITY_ID_MUST_NOT_BE_ZERO(7),
    INVALID_COORDINATES(8),
    LAT_OUT_OF_RANGE(9),
    LON_OUT_OF_RANGE(10),
    EXISTS_WITH_DIFFERENT_ENTITY_ID(11),
    EXISTS_WITH_DIFFERENT_COORDINATES(12),
    EXISTS(13),
    HEADING_OUT_OF_RANGE(14),
    TTL_INVALID(15);

    private final int code;

    InsertGeoEventResult(int code) {
        this.code = code;
    }

    /**
     * Returns the numeric code for this result.
     */
    public int getCode() {
        return code;
    }

    /**
     * Returns the result for the given code, or null if not found.
     */
    public static InsertGeoEventResult fromCode(int code) {
        for (InsertGeoEventResult result : values()) {
            if (result.code == code) {
                return result;
            }
        }
        return null;
    }
}
