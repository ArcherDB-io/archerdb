package com.archerdb.geo;

/**
 * Exception thrown when shard routing fails (F5.1.4 Shard-Aware Routing).
 *
 * <p>
 * Error code: 220 (shard_routing_failed)
 */
public class ShardRoutingException extends ArcherDBException {

    /** Error code for shard routing failures. */
    public static final int ERROR_CODE = 220;

    private final int shardId;

    /**
     * Creates a new ShardRoutingException.
     *
     * @param shardId the shard ID that failed routing
     * @param message the error message
     */
    public ShardRoutingException(int shardId, String message) {
        super(ERROR_CODE, message, true); // Routing errors are typically retryable
        this.shardId = shardId;
    }

    /**
     * Creates a new ShardRoutingException with a cause.
     *
     * @param shardId the shard ID that failed routing
     * @param message the error message
     * @param cause the underlying cause
     */
    public ShardRoutingException(int shardId, String message, Throwable cause) {
        super(ERROR_CODE, message, true, cause);
        this.shardId = shardId;
    }

    /**
     * Returns the shard ID that failed routing.
     */
    public int getShardId() {
        return shardId;
    }
}
