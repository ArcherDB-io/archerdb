package com.archerdb.geo;

/**
 * Status of a shard in the cluster (F5.1 Smart Client Topology Discovery).
 */
public enum ShardStatus {
    /** Shard is active and accepting requests. */
    ACTIVE(0),
    /** Shard is syncing data (read-only). */
    SYNCING(1),
    /** Shard is unavailable. */
    UNAVAILABLE(2),
    /** Shard is being migrated during resharding. */
    MIGRATING(3),
    /** Shard is being decommissioned. */
    DECOMMISSIONING(4);

    private final int code;

    ShardStatus(int code) {
        this.code = code;
    }

    /**
     * Returns the numeric code for this status.
     */
    public int getCode() {
        return code;
    }

    /**
     * Returns the ShardStatus for the given code.
     *
     * @param code the numeric status code
     * @return the corresponding ShardStatus
     * @throws IllegalArgumentException if the code is invalid
     */
    public static ShardStatus fromCode(int code) {
        for (ShardStatus status : values()) {
            if (status.code == code) {
                return status;
            }
        }
        throw new IllegalArgumentException("Unknown shard status code: " + code);
    }

    /**
     * Returns true if this shard can accept read requests.
     */
    public boolean isReadable() {
        return this == ACTIVE || this == SYNCING;
    }

    /**
     * Returns true if this shard can accept write requests.
     */
    public boolean isWritable() {
        return this == ACTIVE;
    }
}
