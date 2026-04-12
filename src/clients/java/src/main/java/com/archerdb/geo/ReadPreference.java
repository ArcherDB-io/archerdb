// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Read routing preference for multi-region deployments.
 *
 * <p>
 * The enum expresses the intended routing policy. In the current Java SDK, {@link #PRIMARY} is
 * implemented directly, {@link #FOLLOWER} uses deterministic follower selection, and
 * {@link #NEAREST} is retained as a configuration value but does not yet perform latency-based
 * routing.
 *
 * <p>
 * <ul>
 * <li>PRIMARY - Route all reads to primary region (strongly consistent)</li>
 * <li>FOLLOWER - Route reads to follower regions (eventually consistent)</li>
 * <li>NEAREST - Intended nearest-region routing; currently non-GA in the Java SDK</li>
 * </ul>
 *
 * <p>
 * Write operations always go to the primary region regardless of read preference.
 */
public enum ReadPreference {

    /**
     * Route all reads to the primary region. Provides strong consistency but may have higher
     * latency for distant clients.
     */
    PRIMARY("primary"),

    /**
     * Route reads to follower regions. Provides lower latency but eventual consistency with
     * potential staleness.
     */
    FOLLOWER("follower"),

    /**
     * Intended nearest-region routing. The current Java SDK retains this value for configuration
     * compatibility but does not yet perform latency-based region selection.
     */
    NEAREST("nearest");

    private final String value;

    ReadPreference(String value) {
        this.value = value;
    }

    /**
     * Returns the string value for wire format serialization.
     */
    public String getValue() {
        return value;
    }

    /**
     * Returns the ReadPreference for the given string value.
     *
     * @param value the string value (case-insensitive)
     * @return the corresponding ReadPreference
     * @throws IllegalArgumentException if value is not recognized
     */
    public static ReadPreference fromValue(String value) {
        if (value == null) {
            throw new IllegalArgumentException("ReadPreference value cannot be null");
        }
        String normalized = value.toLowerCase();
        for (ReadPreference pref : values()) {
            if (pref.value.equals(normalized)) {
                return pref;
            }
        }
        throw new IllegalArgumentException("Unknown ReadPreference: " + value);
    }
}
