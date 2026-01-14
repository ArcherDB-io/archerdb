package com.archerdb.geo;

/**
 * Type of topology change event (F5.1.3 Topology Change Push Notifications).
 */
public enum TopologyChangeType {
    /** Shard leader changed (failover). */
    LEADER_CHANGE(0),
    /** Replica was added to a shard. */
    REPLICA_ADDED(1),
    /** Replica was removed from a shard. */
    REPLICA_REMOVED(2),
    /** Resharding has started. */
    RESHARDING_STARTED(3),
    /** Resharding has completed. */
    RESHARDING_COMPLETED(4),
    /** Shard status changed. */
    STATUS_CHANGE(5);

    private final int code;

    TopologyChangeType(int code) {
        this.code = code;
    }

    /**
     * Returns the numeric code for this change type.
     */
    public int getCode() {
        return code;
    }

    /**
     * Returns the TopologyChangeType for the given code.
     *
     * @param code the numeric change type code
     * @return the corresponding TopologyChangeType
     * @throws IllegalArgumentException if the code is invalid
     */
    public static TopologyChangeType fromCode(int code) {
        for (TopologyChangeType type : values()) {
            if (type.code == code) {
                return type;
            }
        }
        throw new IllegalArgumentException("Unknown topology change type code: " + code);
    }
}
