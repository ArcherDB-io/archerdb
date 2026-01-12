package com.archerdb.geo;

import java.util.concurrent.atomic.AtomicLong;

/**
 * Manages client sessions for request idempotency.
 *
 * <p>
 * Per client-sdk/spec.md session management requirements:
 * <ul>
 * <li>Generate random client_id: u128 (persistent per SDK instance)</li>
 * <li>Maintain monotonic request_number: u64 per session</li>
 * <li>Include (client_id, request_number) in request header</li>
 * <li>Server uses this for duplicate detection</li>
 * </ul>
 *
 * <p>
 * This class is thread-safe.
 */
public final class SessionManager {

    /**
     * Default session timeout in milliseconds (60 seconds per spec).
     */
    public static final long DEFAULT_SESSION_TIMEOUT_MS = 60_000;

    private final UInt128 clientId;
    private final AtomicLong requestNumber;
    private volatile long sessionId;
    private volatile long lastActivityMs;
    private volatile boolean registered;
    private final long sessionTimeoutMs;

    /**
     * Creates a new session manager with default timeout.
     */
    public SessionManager() {
        this(DEFAULT_SESSION_TIMEOUT_MS);
    }

    /**
     * Creates a new session manager with custom timeout.
     *
     * @param sessionTimeoutMs session timeout in milliseconds
     */
    public SessionManager(long sessionTimeoutMs) {
        // Generate random client_id (persistent per SDK instance)
        this.clientId = UInt128.random();
        this.requestNumber = new AtomicLong(0);
        this.sessionId = 0;
        this.lastActivityMs = System.currentTimeMillis();
        this.registered = false;
        this.sessionTimeoutMs = sessionTimeoutMs;
    }

    /**
     * Returns the client ID (persistent per SDK instance).
     *
     * @return the 128-bit client ID
     */
    public UInt128 getClientId() {
        return clientId;
    }

    /**
     * Returns the current session ID.
     *
     * @return the session ID, or 0 if not registered
     */
    public long getSessionId() {
        return sessionId;
    }

    /**
     * Returns the next request number and increments atomically.
     *
     * @return the next request number
     */
    public long nextRequestNumber() {
        updateActivity();
        return requestNumber.incrementAndGet();
    }

    /**
     * Returns the current request number without incrementing.
     *
     * @return the current request number
     */
    public long currentRequestNumber() {
        return requestNumber.get();
    }

    /**
     * Returns true if the session is registered with the server.
     *
     * @return true if registered
     */
    public boolean isRegistered() {
        return registered;
    }

    /**
     * Returns true if the session has expired.
     *
     * @return true if expired
     */
    public boolean isExpired() {
        return System.currentTimeMillis() - lastActivityMs > sessionTimeoutMs;
    }

    /**
     * Registers the session with the given session ID from the server.
     *
     * @param sessionId the session ID from register operation
     */
    public void register(long sessionId) {
        this.sessionId = sessionId;
        this.registered = true;
        updateActivity();
    }

    /**
     * Clears the session state (call when session_expired error received).
     */
    public void clearSession() {
        this.sessionId = 0;
        this.registered = false;
        // Note: request_number is NOT reset - server may still have pending requests
    }

    /**
     * Updates the last activity timestamp.
     */
    public void updateActivity() {
        this.lastActivityMs = System.currentTimeMillis();
    }

    /**
     * Returns the session timeout in milliseconds.
     *
     * @return the session timeout
     */
    public long getSessionTimeoutMs() {
        return sessionTimeoutMs;
    }

    /**
     * Returns time until session expires in milliseconds.
     *
     * @return milliseconds until expiration, or 0 if already expired
     */
    public long timeUntilExpirationMs() {
        long remaining = sessionTimeoutMs - (System.currentTimeMillis() - lastActivityMs);
        return Math.max(0, remaining);
    }

    /**
     * Creates a request header containing session information.
     *
     * <p>
     * Per spec, the header includes:
     * <ul>
     * <li>client_id: u128</li>
     * <li>request_number: u64</li>
     * </ul>
     *
     * @return a new request header
     */
    public RequestHeader createHeader() {
        return new RequestHeader(clientId, nextRequestNumber(), sessionId);
    }

    /**
     * Header structure for requests.
     */
    public static final class RequestHeader {
        private final UInt128 clientId;
        private final long requestNumber;
        private final long sessionId;

        RequestHeader(UInt128 clientId, long requestNumber, long sessionId) {
            this.clientId = clientId;
            this.requestNumber = requestNumber;
            this.sessionId = sessionId;
        }

        /**
         * Returns the client ID.
         */
        public UInt128 getClientId() {
            return clientId;
        }

        /**
         * Returns the request number.
         */
        public long getRequestNumber() {
            return requestNumber;
        }

        /**
         * Returns the session ID.
         */
        public long getSessionId() {
            return sessionId;
        }

        @Override
        public String toString() {
            return "RequestHeader{clientId=" + clientId + ", requestNumber=" + requestNumber
                    + ", sessionId=" + sessionId + "}";
        }
    }
}
