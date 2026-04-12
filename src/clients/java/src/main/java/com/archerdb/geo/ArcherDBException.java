// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Base exception for all ArcherDB client errors.
 *
 * <p>
 * Per client-sdk/spec.md error handling requirements, this provides:
 * <ul>
 * <li>Error code (u16)</li>
 * <li>Human-readable message</li>
 * <li>Retryable flag</li>
 * <li>Optional operation context (entity ID, shard ID, operation type)</li>
 * </ul>
 *
 * <p>
 * Subclasses provide typed errors for different failure categories:
 * <ul>
 * <li>{@link ConnectionException} - Connection failures</li>
 * <li>{@link ClusterException} - Cluster state errors</li>
 * <li>{@link ValidationException} - Invalid input errors</li>
 * <li>{@link OperationException} - Operation failures</li>
 * </ul>
 */
public class ArcherDBException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    /**
     * Type of operation that caused an error.
     */
    public enum OperationType {
        UNKNOWN(""),
        INSERT("insert"),
        UPDATE("update"),
        DELETE("delete"),
        QUERY("query"),
        GET("get");

        private final String value;

        OperationType(String value) {
            this.value = value;
        }

        public String getValue() {
            return value;
        }
    }

    private final int errorCode;
    private final boolean retryable;
    private final String entityId;
    private final Integer shardId;
    private final OperationType operationType;

    /**
     * Creates an ArcherDB exception.
     *
     * @param errorCode the numeric error code
     * @param message human-readable error message
     * @param retryable whether the operation can be retried
     */
    public ArcherDBException(int errorCode, String message, boolean retryable) {
        super(message);
        this.errorCode = errorCode;
        this.retryable = retryable;
        this.entityId = null;
        this.shardId = null;
        this.operationType = null;
    }

    /**
     * Creates an ArcherDB exception with a cause.
     *
     * @param errorCode the numeric error code
     * @param message human-readable error message
     * @param retryable whether the operation can be retried
     * @param cause the underlying cause
     */
    public ArcherDBException(int errorCode, String message, boolean retryable, Throwable cause) {
        super(message, cause);
        this.errorCode = errorCode;
        this.retryable = retryable;
        this.entityId = null;
        this.shardId = null;
        this.operationType = null;
    }

    /**
     * Creates an ArcherDB exception with operation context.
     *
     * @param errorCode the numeric error code
     * @param message human-readable error message
     * @param retryable whether the operation can be retried
     * @param entityId the entity ID involved in the error (may be null)
     * @param shardId the shard ID involved in the error (may be null)
     * @param operationType the type of operation that caused the error (may be null)
     */
    public ArcherDBException(int errorCode, String message, boolean retryable, String entityId,
            Integer shardId, OperationType operationType) {
        super(message);
        this.errorCode = errorCode;
        this.retryable = retryable;
        this.entityId = entityId;
        this.shardId = shardId;
        this.operationType = operationType;
    }

    /**
     * Returns the numeric error code.
     */
    public int getErrorCode() {
        return errorCode;
    }

    /**
     * Returns true if the operation can be safely retried.
     */
    public boolean isRetryable() {
        return retryable;
    }

    /**
     * Returns the entity ID involved in the error, or null if not available.
     */
    public String getEntityId() {
        return entityId;
    }

    /**
     * Returns the shard ID involved in the error, or null if not available.
     */
    public Integer getShardId() {
        return shardId;
    }

    /**
     * Returns the operation type that caused the error, or null if not available.
     */
    public OperationType getOperationType() {
        return operationType;
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder();
        sb.append(String.format("%s[code=%d, retryable=%s", getClass().getSimpleName(), errorCode,
                retryable));
        if (entityId != null) {
            sb.append(String.format(", entityId=%s", entityId));
        }
        if (shardId != null) {
            sb.append(String.format(", shardId=%d", shardId));
        }
        if (operationType != null) {
            sb.append(String.format(", operationType=%s", operationType.getValue()));
        }
        sb.append(String.format("]: %s", getMessage()));
        return sb.toString();
    }
}
