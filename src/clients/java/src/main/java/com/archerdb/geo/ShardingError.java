package com.archerdb.geo;

/**
 * Sharding error codes (220-224) per v2 index-sharding/spec.md.
 *
 * <p>
 * These errors occur during shard-aware operations and resharding.
 */
public enum ShardingError {
    /**
     * This node is not the leader for target shard. Client should refresh topology and retry with
     * correct leader.
     */
    NOT_SHARD_LEADER(220, "This node is not the leader for target shard", true),

    /**
     * Target shard has no available replicas. Wait and retry - shard may recover.
     */
    SHARD_UNAVAILABLE(221, "Target shard has no available replicas", true),

    /**
     * Cluster is currently resharding. Wait and retry after resharding completes.
     */
    RESHARDING_IN_PROGRESS(222, "Cluster is currently resharding", true),

    /**
     * Target shard count is invalid. Client error - fix shard count parameter.
     */
    INVALID_SHARD_COUNT(223, "Target shard count is invalid", false),

    /**
     * Data migration to new shard failed. Resharding operation failed.
     */
    SHARD_MIGRATION_FAILED(224, "Data migration to new shard failed", false);

    private final int code;
    private final String message;
    private final boolean retryable;

    ShardingError(int code, String message, boolean retryable) {
        this.code = code;
        this.message = message;
        this.retryable = retryable;
    }

    /**
     * Returns the numeric error code.
     */
    public int getCode() {
        return code;
    }

    /**
     * Returns the error message.
     */
    public String getMessage() {
        return message;
    }

    /**
     * Returns true if the operation can be retried.
     */
    public boolean isRetryable() {
        return retryable;
    }

    /**
     * Returns the ShardingError for the given code, or null if not a sharding error.
     */
    public static ShardingError fromCode(int code) {
        for (ShardingError error : values()) {
            if (error.code == code) {
                return error;
            }
        }
        return null;
    }

    /**
     * Returns true if the given code is a sharding error code (220-224).
     */
    public static boolean isShardingError(int code) {
        return code >= 220 && code <= 224;
    }

    /**
     * Creates an ArcherDBException for this error.
     */
    public ArcherDBException toException() {
        return new ArcherDBException(code, message, retryable);
    }

    /**
     * Creates an ArcherDBException for this error with operation context.
     *
     * @param entityId the entity ID involved in the error (may be null)
     * @param shardId the shard ID involved in the error (may be null)
     * @param operationType the type of operation that caused the error (may be null)
     */
    public ArcherDBException toException(String entityId, Integer shardId, ArcherDBException.OperationType operationType) {
        return new ArcherDBException(code, message, retryable, entityId, shardId, operationType);
    }
}
