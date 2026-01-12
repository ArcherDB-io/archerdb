package com.archerdb.geo;

/**
 * Exception for connection-related failures.
 *
 * <p>
 * Per client-sdk/spec.md, connection errors include:
 * <ul>
 * <li>ConnectionFailed - Unable to establish connection</li>
 * <li>ConnectionTimeout - Connection attempt timed out</li>
 * <li>TLSError - TLS handshake or certificate error</li>
 * </ul>
 */
public class ConnectionException extends ArcherDBException {

    private static final long serialVersionUID = 1L;

    /**
     * Error code for connection failed (unable to connect).
     */
    public static final int CONNECTION_FAILED = 1;

    /**
     * Error code for connection timeout.
     */
    public static final int CONNECTION_TIMEOUT = 2;

    /**
     * Error code for TLS errors.
     */
    public static final int TLS_ERROR = 3;

    /**
     * Creates a connection exception.
     */
    public ConnectionException(int errorCode, String message) {
        // Connection errors are generally retryable
        super(errorCode, message, true);
    }

    /**
     * Creates a connection exception with cause.
     */
    public ConnectionException(int errorCode, String message, Throwable cause) {
        super(errorCode, message, true, cause);
    }

    /**
     * Creates a connection failed exception.
     */
    public static ConnectionException connectionFailed(String address) {
        return new ConnectionException(CONNECTION_FAILED,
                String.format("Failed to connect to %s", address));
    }

    /**
     * Creates a connection failed exception with cause.
     */
    public static ConnectionException connectionFailed(String address, Throwable cause) {
        return new ConnectionException(CONNECTION_FAILED,
                String.format("Failed to connect to %s: %s", address, cause.getMessage()), cause);
    }

    /**
     * Creates a connection timeout exception.
     */
    public static ConnectionException connectionTimeout(String address, int timeoutMs) {
        return new ConnectionException(CONNECTION_TIMEOUT,
                String.format("Connection to %s timed out after %dms", address, timeoutMs));
    }

    /**
     * Creates a TLS error exception.
     */
    public static ConnectionException tlsError(String message) {
        return new ConnectionException(TLS_ERROR, "TLS error: " + message);
    }

    /**
     * Creates a TLS error exception with cause.
     */
    public static ConnectionException tlsError(String message, Throwable cause) {
        return new ConnectionException(TLS_ERROR, "TLS error: " + message, cause);
    }
}
