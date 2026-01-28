package com.archerdb.geo;

/**
 * Encryption error codes (410-414) per v2 security/spec.md.
 *
 * <p>
 * These errors occur during encryption/decryption operations and key management.
 */
public enum EncryptionError {
    /**
     * Cannot retrieve encryption key from provider. May be transient - retry with backoff.
     */
    ENCRYPTION_KEY_UNAVAILABLE(410, "Cannot retrieve encryption key from provider", true),

    /**
     * Failed to decrypt data (auth tag mismatch). Data may be corrupted or tampered.
     */
    DECRYPTION_FAILED(411, "Failed to decrypt data (auth tag mismatch)", false),

    /**
     * Encryption required but not configured. Server expects encrypted connections.
     */
    ENCRYPTION_NOT_ENABLED(412, "Encryption required but not configured", false),

    /**
     * Key rotation in progress, retry later. Wait and retry - operation will succeed once rotation
     * completes.
     */
    KEY_ROTATION_IN_PROGRESS(413, "Key rotation in progress, retry later", true),

    /**
     * File encrypted with unsupported version. Cannot decrypt with current software version.
     */
    UNSUPPORTED_ENCRYPTION_VERSION(414, "File encrypted with unsupported version", false);

    private final int code;
    private final String message;
    private final boolean retryable;

    EncryptionError(int code, String message, boolean retryable) {
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
     * Returns the EncryptionError for the given code, or null if not an encryption error.
     */
    public static EncryptionError fromCode(int code) {
        for (EncryptionError error : values()) {
            if (error.code == code) {
                return error;
            }
        }
        return null;
    }

    /**
     * Returns true if the given code is an encryption error code (410-414).
     */
    public static boolean isEncryptionError(int code) {
        return code >= 410 && code <= 414;
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
    public ArcherDBException toException(String entityId, Integer shardId,
            ArcherDBException.OperationType operationType) {
        return new ArcherDBException(code, message, retryable, entityId, shardId, operationType);
    }
}
