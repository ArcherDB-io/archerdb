// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

/**
 * Policy for resolving write conflicts in active-active replication.
 * <p>
 * Determines how concurrent writes to the same entity from different regions are resolved.
 * </p>
 *
 * @see <a href="https://docs.archerdb.io/reference/active-active#resolution-policy">Resolution
 *      Policy</a>
 */
public enum ConflictResolutionPolicy {
    /**
     * Highest timestamp wins (default).
     */
    LAST_WRITER_WINS((byte) 0),

    /**
     * Primary region write takes precedence.
     */
    PRIMARY_WINS((byte) 1),

    /**
     * Application-provided resolution function.
     */
    CUSTOM_HOOK((byte) 2);

    private final byte value;

    ConflictResolutionPolicy(byte value) {
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
    public static ConflictResolutionPolicy fromValue(byte value) {
        for (ConflictResolutionPolicy policy : values()) {
            if (policy.value == value) {
                return policy;
            }
        }
        return LAST_WRITER_WINS;
    }
}
