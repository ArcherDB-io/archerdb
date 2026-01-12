package com.archerdb.geo;

/**
 * Exception for operation failures.
 *
 * <p>
 * Per client-sdk/spec.md and error-codes/spec.md, operation errors include:
 * <ul>
 * <li>Timeout - Operation timed out (retryable with caution)</li>
 * <li>QueryResultTooLarge - Result set exceeds limits (code 302)</li>
 * <li>OutOfSpace - Disk space exhausted (code 306)</li>
 * <li>SessionExpired - Client session expired (code 204)</li>
 * <li>EntityNotFound - Entity UUID not found (code 200)</li>
 * <li>ResourceExhausted - Internal resource exhausted (code 211)</li>
 * </ul>
 */
public class OperationException extends ArcherDBException {

    private static final long serialVersionUID = 1L;

    // State error codes (200-299)
    public static final int ENTITY_NOT_FOUND = 200;
    public static final int SESSION_EXPIRED = 204;
    public static final int DUPLICATE_REQUEST = 205;
    public static final int ENTITY_EXPIRED = 210;
    public static final int RESOURCE_EXHAUSTED = 211;
    public static final int BACKUP_REQUIRED = 212;

    // Resource error codes (300-399)
    public static final int TOO_MANY_EVENTS = 300;
    public static final int MESSAGE_BODY_TOO_LARGE = 301;
    public static final int RESULT_SET_TOO_LARGE = 302;
    public static final int TOO_MANY_CLIENTS = 303;
    public static final int RATE_LIMIT_EXCEEDED = 304;
    public static final int MEMORY_EXHAUSTED = 305;
    public static final int DISK_FULL = 306;
    public static final int TOO_MANY_QUERIES = 307;
    public static final int PIPELINE_FULL = 308;
    public static final int INDEX_CAPACITY_EXCEEDED = 309;
    public static final int INDEX_DEGRADED = 310;

    // Timeout (custom)
    public static final int TIMEOUT = 999;

    /**
     * Creates an operation exception.
     */
    public OperationException(int errorCode, String message, boolean retryable) {
        super(errorCode, message, retryable);
    }

    /**
     * Creates an operation exception with cause.
     */
    public OperationException(int errorCode, String message, boolean retryable, Throwable cause) {
        super(errorCode, message, retryable, cause);
    }

    /**
     * Creates a timeout exception.
     */
    public static OperationException timeout(String operation, int timeoutMs) {
        // Timeout is retryable but with caution - operation may have committed
        return new OperationException(TIMEOUT,
                String.format("Operation %s timed out after %dms", operation, timeoutMs), true);
    }

    /**
     * Creates an entity not found exception.
     */
    public static OperationException entityNotFound(UInt128 entityId) {
        return new OperationException(ENTITY_NOT_FOUND,
                String.format("Entity %s not found", entityId), false);
    }

    /**
     * Creates an entity expired exception.
     */
    public static OperationException entityExpired(UInt128 entityId) {
        return new OperationException(ENTITY_EXPIRED,
                String.format("Entity %s has expired due to TTL", entityId), false);
    }

    /**
     * Creates a session expired exception.
     */
    public static OperationException sessionExpired(String reason) {
        // Session expired is NOT retryable - SDK handles re-registration
        return new OperationException(SESSION_EXPIRED, "Session expired: " + reason, false);
    }

    /**
     * Creates a result set too large exception.
     */
    public static OperationException resultSetTooLarge(int resultCount, int maxCount) {
        return new OperationException(RESULT_SET_TOO_LARGE,
                String.format("Query result (%d events) exceeds limit (%d)", resultCount, maxCount),
                false);
    }

    /**
     * Creates a disk full exception.
     */
    public static OperationException diskFull() {
        // Disk full is retryable after operator intervention
        return new OperationException(DISK_FULL, "Disk space exhausted", true);
    }

    /**
     * Creates a memory exhausted exception.
     */
    public static OperationException memoryExhausted() {
        return new OperationException(MEMORY_EXHAUSTED, "System memory limit reached", true);
    }

    /**
     * Creates a rate limit exceeded exception.
     */
    public static OperationException rateLimitExceeded(long currentRate, long maxRate) {
        return new OperationException(RATE_LIMIT_EXCEEDED,
                String.format("Rate limit exceeded: %d/%d requests/sec", currentRate, maxRate),
                true);
    }

    /**
     * Creates a too many queries exception.
     */
    public static OperationException tooManyQueries(int current, int max) {
        return new OperationException(TOO_MANY_QUERIES,
                String.format("Too many concurrent queries: %d/%d", current, max), true);
    }

    /**
     * Creates a too many clients exception.
     */
    public static OperationException tooManyClients(int current, int max) {
        return new OperationException(TOO_MANY_CLIENTS,
                String.format("Client limit reached: %d/%d", current, max), true);
    }

    /**
     * Creates an index capacity exceeded exception.
     */
    public static OperationException indexCapacityExceeded(long entityCount, long maxCapacity) {
        return new OperationException(INDEX_CAPACITY_EXCEEDED,
                String.format("Index capacity exceeded: %d/%d entities", entityCount, maxCapacity),
                false);
    }

    /**
     * Creates a resource exhausted exception.
     */
    public static OperationException resourceExhausted(String resourceType) {
        return new OperationException(RESOURCE_EXHAUSTED,
                String.format("Resource exhausted: %s", resourceType), true);
    }
}
