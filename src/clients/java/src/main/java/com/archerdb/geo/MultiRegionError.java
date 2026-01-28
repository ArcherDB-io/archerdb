package com.archerdb.geo;

/**
 * Error codes specific to multi-region operations.
 *
 * <p>
 * Per error-codes/spec.md, codes 213-218 are reserved for multi-region errors. These errors occur
 * during cross-region communication and replication.
 */
public enum MultiRegionError {

    /**
     * Write operation attempted on a follower region. Followers are read-only; writes must go to
     * the primary region.
     */
    FOLLOWER_READ_ONLY(213, "Write operation rejected: follower regions are read-only"),

    /**
     * Follower data exceeds acceptable staleness threshold. The read was rejected because the
     * follower's data is too old.
     */
    STALE_FOLLOWER(214, "Follower data exceeds maximum staleness threshold"),

    /**
     * Primary region is unreachable. The client cannot connect to the primary region for writes.
     */
    PRIMARY_UNREACHABLE(215, "Cannot connect to primary region"),

    /**
     * Cross-region replication timeout. The replication operation did not complete within the
     * expected time.
     */
    REPLICATION_TIMEOUT(216, "Cross-region replication timeout"),

    /**
     * Write conflict detected. In active-active replication, two regions attempted to write to the
     * same entity simultaneously.
     */
    CONFLICT_DETECTED(217, "Write conflict detected in active-active replication"),

    /**
     * Geo-shard mismatch. The entity's geo-shard does not match the target region.
     */
    GEO_SHARD_MISMATCH(218, "Entity geo-shard does not match target region");

    private final int code;
    private final String message;

    MultiRegionError(int code, String message) {
        this.code = code;
        this.message = message;
    }

    /**
     * Returns the numeric error code.
     */
    public int getCode() {
        return code;
    }

    /**
     * Returns the human-readable error message.
     */
    public String getMessage() {
        return message;
    }

    /**
     * Returns the MultiRegionError for the given code, or null if not found.
     */
    public static MultiRegionError fromCode(int code) {
        for (MultiRegionError error : values()) {
            if (error.code == code) {
                return error;
            }
        }
        return null;
    }

    /**
     * Returns true if the given code is a multi-region error code (213-218).
     */
    public static boolean isMultiRegionError(int code) {
        return code >= 213 && code <= 218;
    }

    /**
     * Returns true if the operation can be retried.
     */
    public boolean isRetryable() {
        switch (this) {
            case STALE_FOLLOWER:
            case PRIMARY_UNREACHABLE:
            case REPLICATION_TIMEOUT:
                return true;
            default:
                return false;
        }
    }

    /**
     * Creates an ArcherDBException for this error.
     */
    public ArcherDBException toException() {
        return new ArcherDBException(code, message, isRetryable());
    }

    /**
     * Creates an ArcherDBException for this error with operation context.
     *
     * @param entityId the entity ID involved in the error (may be null)
     * @param shardId the shard ID involved in the error (may be null)
     * @param operationType the type of operation that caused the error (may be null)
     */
    public ArcherDBException toException(String entityId, Integer shardId,
            ArcherDBException.OperationType operationType) {
        return new ArcherDBException(code, message, isRetryable(), entityId, shardId,
                operationType);
    }
}
