// ArcherDB Java Client - TTL Operation Result
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025 ArcherDB Developers

package com.archerdb.geo;

/**
 * Result codes for TTL operations.
 *
 * <p>
 * Maps to TtlOperationResult enum in ttl.zig (v2.1 Manual TTL Support).
 */
public enum TtlOperationResult {
    /** Operation succeeded */
    SUCCESS(0),
    /** Entity not found in database */
    ENTITY_NOT_FOUND(1),
    /** Invalid TTL value provided */
    INVALID_TTL(2),
    /** Operation not permitted (e.g., entity is immutable) */
    NOT_PERMITTED(3),
    /** Entity is marked immutable and cannot have TTL modified */
    ENTITY_IMMUTABLE(4);

    private final int code;

    TtlOperationResult(int code) {
        this.code = code;
    }

    /**
     * Returns the wire format code.
     *
     * @return the code
     */
    public int getCode() {
        return code;
    }

    /**
     * Returns the TtlOperationResult for the given code.
     *
     * @param code the wire format code
     * @return the result enum value
     * @throws IllegalArgumentException if code is invalid
     */
    public static TtlOperationResult fromCode(int code) {
        for (TtlOperationResult result : values()) {
            if (result.code == code) {
                return result;
            }
        }
        throw new IllegalArgumentException("Unknown TtlOperationResult code: " + code);
    }
}
