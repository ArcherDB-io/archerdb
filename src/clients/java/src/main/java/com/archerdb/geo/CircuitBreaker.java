package com.archerdb.geo;

import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Circuit breaker for per-replica failure isolation.
 *
 * <p>
 * Per client-retry/spec.md, the circuit breaker implements:
 * <ul>
 * <li>Three states: Closed (normal), Open (fail-fast), Half-Open (testing recovery)</li>
 * <li>Opens when: 50% failure rate in 10s window AND &gt;= 10 requests</li>
 * <li>Stays open for 30 seconds before transitioning to half-open</li>
 * <li>Half-open allows 5 test requests before deciding to close or re-open</li>
 * <li>Per-replica scope (not global) to allow trying other replicas</li>
 * </ul>
 *
 * <p>
 * This class is thread-safe.
 */
public final class CircuitBreaker {

    /**
     * Circuit breaker states.
     */
    public enum State {
        /**
         * Normal operation - requests are allowed through.
         */
        CLOSED,
        /**
         * Fail-fast mode - requests are rejected immediately.
         */
        OPEN,
        /**
         * Recovery testing - limited requests allowed to test recovery.
         */
        HALF_OPEN
    }

    /**
     * Default failure rate threshold (50%).
     */
    public static final double DEFAULT_FAILURE_THRESHOLD = 0.5;

    /**
     * Default minimum requests in window before circuit can open.
     */
    public static final int DEFAULT_MINIMUM_REQUESTS = 10;

    /**
     * Default sliding window duration in milliseconds (10 seconds).
     */
    public static final long DEFAULT_WINDOW_MS = 10_000;

    /**
     * Default duration to stay open before half-open transition (30 seconds).
     */
    public static final long DEFAULT_OPEN_DURATION_MS = 30_000;

    /**
     * Default number of test requests in half-open state.
     */
    public static final int DEFAULT_HALF_OPEN_REQUESTS = 5;

    private final String name;
    private final double failureThreshold;
    private final int minimumRequests;
    private final long windowMs;
    private final long openDurationMs;
    private final int halfOpenRequests;

    private final AtomicReference<State> state;
    private final AtomicLong openedAt;

    // Sliding window counters
    private final AtomicInteger totalRequests;
    private final AtomicInteger failedRequests;
    private final AtomicLong windowStartMs;

    // Half-open state tracking
    private final AtomicInteger halfOpenSuccesses;
    private final AtomicInteger halfOpenFailures;
    private final AtomicInteger halfOpenTotal;

    // Metrics
    private final AtomicLong stateChanges;
    private final AtomicLong rejectedRequests;

    /**
     * Creates a circuit breaker with default settings.
     *
     * @param name the circuit breaker name (typically replica address)
     */
    public CircuitBreaker(String name) {
        this(new Builder().setName(name));
    }

    private CircuitBreaker(Builder builder) {
        this.name = builder.name;
        this.failureThreshold = builder.failureThreshold;
        this.minimumRequests = builder.minimumRequests;
        this.windowMs = builder.windowMs;
        this.openDurationMs = builder.openDurationMs;
        this.halfOpenRequests = builder.halfOpenRequests;

        this.state = new AtomicReference<>(State.CLOSED);
        this.openedAt = new AtomicLong(0);

        this.totalRequests = new AtomicInteger(0);
        this.failedRequests = new AtomicInteger(0);
        this.windowStartMs = new AtomicLong(System.currentTimeMillis());

        this.halfOpenSuccesses = new AtomicInteger(0);
        this.halfOpenFailures = new AtomicInteger(0);
        this.halfOpenTotal = new AtomicInteger(0);

        this.stateChanges = new AtomicLong(0);
        this.rejectedRequests = new AtomicLong(0);
    }

    /**
     * Checks if a request is allowed through the circuit breaker.
     *
     * @return true if request is allowed, false if circuit is open
     */
    public boolean allowRequest() {
        State currentState = state.get();

        switch (currentState) {
            case CLOSED:
                return true;

            case OPEN:
                // Check if open duration has elapsed
                long elapsed = System.currentTimeMillis() - openedAt.get();
                if (elapsed >= openDurationMs) {
                    // Transition to half-open
                    if (transitionTo(State.HALF_OPEN)) {
                        resetHalfOpenCounters();
                    }
                    return allowHalfOpenRequest();
                }
                rejectedRequests.incrementAndGet();
                return false;

            case HALF_OPEN:
                return allowHalfOpenRequest();

            default:
                return false;
        }
    }

    private boolean allowHalfOpenRequest() {
        int current = halfOpenTotal.get();
        if (current >= halfOpenRequests) {
            // All test slots used - reject
            rejectedRequests.incrementAndGet();
            return false;
        }
        // Allow if we can increment within limit
        return halfOpenTotal.incrementAndGet() <= halfOpenRequests;
    }

    /**
     * Records a successful request.
     */
    public void recordSuccess() {
        State currentState = state.get();

        switch (currentState) {
            case CLOSED:
                recordInWindow(false);
                break;

            case HALF_OPEN:
                int successes = halfOpenSuccesses.incrementAndGet();
                // Check if we've completed all test requests successfully
                if (successes >= halfOpenRequests) {
                    transitionTo(State.CLOSED);
                    resetCounters();
                }
                break;

            case OPEN:
                // Shouldn't happen - request shouldn't have been allowed
                break;
        }
    }

    /**
     * Records a failed request.
     */
    public void recordFailure() {
        State currentState = state.get();

        switch (currentState) {
            case CLOSED:
                recordInWindow(true);
                checkThreshold();
                break;

            case HALF_OPEN:
                halfOpenFailures.incrementAndGet();
                // Any failure in half-open immediately reopens
                transitionTo(State.OPEN);
                break;

            case OPEN:
                // Shouldn't happen - request shouldn't have been allowed
                break;
        }
    }

    private void recordInWindow(boolean failed) {
        long now = System.currentTimeMillis();
        long windowStart = windowStartMs.get();

        // Check if window has expired and reset atomically
        if (now - windowStart >= windowMs && windowStartMs.compareAndSet(windowStart, now)) {
            totalRequests.set(0);
            failedRequests.set(0);
        }

        totalRequests.incrementAndGet();
        if (failed) {
            failedRequests.incrementAndGet();
        }
    }

    private void checkThreshold() {
        int total = totalRequests.get();
        int failed = failedRequests.get();

        // Only check if minimum requests reached
        if (total < minimumRequests) {
            return;
        }

        // Calculate failure rate
        double failureRate = (double) failed / total;

        // Open circuit if threshold exceeded
        if (failureRate >= failureThreshold) {
            transitionTo(State.OPEN);
        }
    }

    private boolean transitionTo(State newState) {
        State current = state.get();
        if (current == newState) {
            return false;
        }

        if (state.compareAndSet(current, newState)) {
            stateChanges.incrementAndGet();

            if (newState == State.OPEN) {
                openedAt.set(System.currentTimeMillis());
            }

            return true;
        }
        return false;
    }

    private void resetCounters() {
        totalRequests.set(0);
        failedRequests.set(0);
        windowStartMs.set(System.currentTimeMillis());
    }

    private void resetHalfOpenCounters() {
        halfOpenSuccesses.set(0);
        halfOpenFailures.set(0);
        halfOpenTotal.set(0);
    }

    /**
     * Returns the current state.
     *
     * @return the state
     */
    public State getState() {
        // Check for automatic transition from OPEN to HALF_OPEN
        if (state.get() == State.OPEN) {
            long elapsed = System.currentTimeMillis() - openedAt.get();
            if (elapsed >= openDurationMs) {
                transitionTo(State.HALF_OPEN);
                resetHalfOpenCounters();
            }
        }
        return state.get();
    }

    /**
     * Returns the circuit breaker name.
     *
     * @return the name
     */
    public String getName() {
        return name;
    }

    /**
     * Returns the total number of state changes.
     *
     * @return state change count
     */
    public long getStateChanges() {
        return stateChanges.get();
    }

    /**
     * Returns the total number of rejected requests.
     *
     * @return rejected request count
     */
    public long getRejectedRequests() {
        return rejectedRequests.get();
    }

    /**
     * Returns the current failure rate in the sliding window.
     *
     * @return failure rate (0.0 to 1.0)
     */
    public double getCurrentFailureRate() {
        int total = totalRequests.get();
        if (total == 0) {
            return 0.0;
        }
        return (double) failedRequests.get() / total;
    }

    /**
     * Forces the circuit breaker to close. Use with caution - primarily for testing.
     */
    public void forceClose() {
        State prev = state.getAndSet(State.CLOSED);
        if (prev != State.CLOSED) {
            stateChanges.incrementAndGet();
        }
        resetCounters();
        resetHalfOpenCounters();
    }

    /**
     * Forces the circuit breaker to open. Use with caution - primarily for testing.
     */
    public void forceOpen() {
        State prev = state.getAndSet(State.OPEN);
        if (prev != State.OPEN) {
            stateChanges.incrementAndGet();
        }
        openedAt.set(System.currentTimeMillis());
    }

    /**
     * Returns true if the circuit is open (rejecting requests).
     *
     * @return true if open
     */
    public boolean isOpen() {
        return getState() == State.OPEN;
    }

    /**
     * Returns true if the circuit is closed (normal operation).
     *
     * @return true if closed
     */
    public boolean isClosed() {
        return getState() == State.CLOSED;
    }

    /**
     * Returns true if the circuit is half-open (testing recovery).
     *
     * @return true if half-open
     */
    public boolean isHalfOpen() {
        return getState() == State.HALF_OPEN;
    }

    @Override
    public String toString() {
        return String.format("CircuitBreaker[name=%s, state=%s, failureRate=%.2f%%]", name,
                getState(), getCurrentFailureRate() * 100);
    }

    /**
     * Creates a new builder.
     *
     * @return the builder
     */
    public static Builder builder() {
        return new Builder();
    }

    /**
     * Builder for CircuitBreaker.
     */
    public static class Builder {
        private String name = "default";
        private double failureThreshold = DEFAULT_FAILURE_THRESHOLD;
        private int minimumRequests = DEFAULT_MINIMUM_REQUESTS;
        private long windowMs = DEFAULT_WINDOW_MS;
        private long openDurationMs = DEFAULT_OPEN_DURATION_MS;
        private int halfOpenRequests = DEFAULT_HALF_OPEN_REQUESTS;

        /**
         * Sets the circuit breaker name.
         *
         * @param name the name (typically replica address)
         * @return this builder
         */
        public Builder setName(String name) {
            if (name == null || name.isEmpty()) {
                throw new IllegalArgumentException("Name cannot be null or empty");
            }
            this.name = name;
            return this;
        }

        /**
         * Sets the failure rate threshold to open the circuit.
         *
         * @param threshold the threshold (0.0 to 1.0)
         * @return this builder
         */
        public Builder setFailureThreshold(double threshold) {
            if (threshold < 0.0 || threshold > 1.0) {
                throw new IllegalArgumentException("Threshold must be between 0.0 and 1.0");
            }
            this.failureThreshold = threshold;
            return this;
        }

        /**
         * Sets the minimum number of requests before the circuit can open.
         *
         * @param minimum the minimum requests
         * @return this builder
         */
        public Builder setMinimumRequests(int minimum) {
            if (minimum <= 0) {
                throw new IllegalArgumentException("Minimum requests must be positive");
            }
            this.minimumRequests = minimum;
            return this;
        }

        /**
         * Sets the sliding window duration.
         *
         * @param windowMs the window in milliseconds
         * @return this builder
         */
        public Builder setWindowMs(long windowMs) {
            if (windowMs <= 0) {
                throw new IllegalArgumentException("Window must be positive");
            }
            this.windowMs = windowMs;
            return this;
        }

        /**
         * Sets how long the circuit stays open before half-open.
         *
         * @param openDurationMs the duration in milliseconds
         * @return this builder
         */
        public Builder setOpenDurationMs(long openDurationMs) {
            if (openDurationMs <= 0) {
                throw new IllegalArgumentException("Open duration must be positive");
            }
            this.openDurationMs = openDurationMs;
            return this;
        }

        /**
         * Sets the number of test requests allowed in half-open state.
         *
         * @param requests the number of test requests
         * @return this builder
         */
        public Builder setHalfOpenRequests(int requests) {
            if (requests <= 0) {
                throw new IllegalArgumentException("Half-open requests must be positive");
            }
            this.halfOpenRequests = requests;
            return this;
        }

        /**
         * Builds the circuit breaker.
         *
         * @return the circuit breaker
         */
        public CircuitBreaker build() {
            return new CircuitBreaker(this);
        }
    }
}
