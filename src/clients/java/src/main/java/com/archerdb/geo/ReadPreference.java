package com.archerdb.geo;

/**
 * Read routing preference for multi-region deployments.
 *
 * <p>
 * Per client-sdk/spec.md v2 multi-region support:
 * <ul>
 * <li>PRIMARY - Route all reads to primary region (strongly consistent)</li>
 * <li>FOLLOWER - Route reads to follower regions (eventually consistent)</li>
 * <li>NEAREST - Route reads to geographically nearest region</li>
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
     * Route reads to the geographically nearest region. Balances latency and consistency based on
     * client location.
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
