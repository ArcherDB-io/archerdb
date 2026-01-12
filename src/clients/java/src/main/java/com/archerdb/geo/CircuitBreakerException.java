package com.archerdb.geo;

/**
 * Exception thrown when a circuit breaker rejects a request.
 *
 * <p>
 * This exception is thrown when the circuit breaker is in the OPEN state and rejecting requests to
 * protect against cascading failures.
 *
 * <p>
 * This exception is retryable - the client should wait and retry later, potentially on a different
 * replica.
 */
public final class CircuitBreakerException extends ArcherDBException {

    private static final long serialVersionUID = 1L;

    /**
     * Error code for circuit breaker open.
     */
    public static final int CIRCUIT_OPEN = 600;

    private final String circuitName;
    private final CircuitBreaker.State circuitState;

    /**
     * Creates a new circuit breaker exception.
     *
     * @param circuitName the name of the circuit breaker
     * @param state the current state of the circuit breaker
     */
    public CircuitBreakerException(String circuitName, CircuitBreaker.State state) {
        super(CIRCUIT_OPEN,
                String.format("Circuit breaker '%s' is %s - request rejected", circuitName, state),
                true);
        this.circuitName = circuitName;
        this.circuitState = state;
    }

    /**
     * Returns the circuit breaker name.
     *
     * @return the circuit name
     */
    public String getCircuitName() {
        return circuitName;
    }

    /**
     * Returns the circuit breaker state.
     *
     * @return the state
     */
    public CircuitBreaker.State getCircuitState() {
        return circuitState;
    }
}
