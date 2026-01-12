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

    private final int errorCode;
    private final boolean retryable;

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

    @Override
    public String toString() {
        return String.format("%s[code=%d, retryable=%s]: %s", getClass().getSimpleName(), errorCode,
                retryable, getMessage());
    }
}
