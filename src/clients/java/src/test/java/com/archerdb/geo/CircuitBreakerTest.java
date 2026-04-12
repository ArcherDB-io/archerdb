// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.DisplayName;

/**
 * Tests for CircuitBreaker.
 *
 * Per client-retry/spec.md circuit breaker requirements: - States: Closed (normal), Open
 * (fail-fast), Half-Open (testing recovery) - Opens when: 50% failure rate in 10s window AND >= 10
 * requests - Stays open for 30 seconds before transitioning to half-open - Half-open allows 5 test
 * requests before deciding to close or re-open - Per-replica scope (not global)
 */
class CircuitBreakerTest {

    private CircuitBreaker breaker;

    @BeforeEach
    void setUp() {
        // Use short durations for testing
        breaker = CircuitBreaker.builder().setName("test-replica").setFailureThreshold(0.5)
                .setMinimumRequests(10).setWindowMs(10_000).setOpenDurationMs(100) // Short for
                                                                                   // testing
                .setHalfOpenRequests(5).build();
    }

    @Test
    @DisplayName("Initial state is CLOSED")
    void testInitialStateClosed() {
        assertEquals(CircuitBreaker.State.CLOSED, breaker.getState());
        assertTrue(breaker.isClosed());
        assertFalse(breaker.isOpen());
        assertFalse(breaker.isHalfOpen());
    }

    @Test
    @DisplayName("Requests allowed when circuit is closed")
    void testRequestsAllowedWhenClosed() {
        for (int i = 0; i < 100; i++) {
            assertTrue(breaker.allowRequest());
        }
    }

    @Test
    @DisplayName("Circuit stays closed under failure threshold")
    void testStaysClosedUnderThreshold() {
        // 9 requests with 4 failures (44%) - under 50% threshold
        for (int i = 0; i < 5; i++) {
            breaker.allowRequest();
            breaker.recordSuccess();
        }
        for (int i = 0; i < 4; i++) {
            breaker.allowRequest();
            breaker.recordFailure();
        }

        assertTrue(breaker.isClosed());
        assertEquals(4.0 / 9, breaker.getCurrentFailureRate(), 0.01);
    }

    @Test
    @DisplayName("Circuit opens after failure threshold exceeded")
    void testOpensAfterThresholdExceeded() {
        // 10 requests with 6 failures (60%) - exceeds 50% threshold
        for (int i = 0; i < 4; i++) {
            breaker.allowRequest();
            breaker.recordSuccess();
        }
        for (int i = 0; i < 6; i++) {
            breaker.allowRequest();
            breaker.recordFailure();
        }

        assertTrue(breaker.isOpen());
        assertEquals(6.0 / 10, breaker.getCurrentFailureRate(), 0.01);
    }

    @Test
    @DisplayName("Circuit rejects requests when open")
    void testRejectsRequestsWhenOpen() {
        breaker.forceOpen();

        assertFalse(breaker.allowRequest());
        assertFalse(breaker.allowRequest());
        assertFalse(breaker.allowRequest());

        assertTrue(breaker.getRejectedRequests() >= 3);
    }

    @Test
    @DisplayName("Circuit transitions to half-open after open duration")
    void testTransitionsToHalfOpen() throws InterruptedException {
        breaker.forceOpen();
        assertTrue(breaker.isOpen());

        // Wait for open duration
        Thread.sleep(150);

        // Should transition to half-open on next check
        assertEquals(CircuitBreaker.State.HALF_OPEN, breaker.getState());
        assertTrue(breaker.isHalfOpen());
    }

    @Test
    @DisplayName("Successful half-open requests close the circuit")
    void testSuccessfulHalfOpenCloses() throws InterruptedException {
        breaker.forceOpen();
        Thread.sleep(150);

        // Allow and succeed 5 requests in half-open
        for (int i = 0; i < 5; i++) {
            assertTrue(breaker.allowRequest());
            breaker.recordSuccess();
        }

        assertTrue(breaker.isClosed());
    }

    @Test
    @DisplayName("Failed half-open request reopens the circuit")
    void testFailedHalfOpenReopens() throws InterruptedException {
        breaker.forceOpen();
        Thread.sleep(150);

        // First half-open request fails
        assertTrue(breaker.allowRequest());
        breaker.recordFailure();

        assertTrue(breaker.isOpen());
    }

    @Test
    @DisplayName("Half-open limits test requests")
    void testHalfOpenLimitsRequests() throws InterruptedException {
        breaker.forceOpen();
        Thread.sleep(150);

        // Allow exactly 5 requests
        for (int i = 0; i < 5; i++) {
            assertTrue(breaker.allowRequest());
        }

        // 6th request should be rejected
        assertFalse(breaker.allowRequest());
    }

    @Test
    @DisplayName("Minimum requests required before opening")
    void testMinimumRequestsRequired() {
        // 9 requests all failures (100%) - under minimum of 10
        for (int i = 0; i < 9; i++) {
            breaker.allowRequest();
            breaker.recordFailure();
        }

        assertTrue(breaker.isClosed());
        assertEquals(1.0, breaker.getCurrentFailureRate(), 0.01);

        // 10th failure opens circuit
        breaker.allowRequest();
        breaker.recordFailure();

        assertTrue(breaker.isOpen());
    }

    @Test
    @DisplayName("Force close resets state")
    void testForceClose() {
        breaker.forceOpen();
        assertTrue(breaker.isOpen());

        breaker.forceClose();

        assertTrue(breaker.isClosed());
        assertEquals(0.0, breaker.getCurrentFailureRate(), 0.01);
    }

    @Test
    @DisplayName("State changes are tracked")
    void testStateChangesTracked() {
        assertEquals(0, breaker.getStateChanges());

        breaker.forceOpen();
        assertEquals(1, breaker.getStateChanges());

        breaker.forceClose();
        assertEquals(2, breaker.getStateChanges());
    }

    @Test
    @DisplayName("Builder validates parameters")
    void testBuilderValidation() {
        assertThrows(IllegalArgumentException.class, () -> CircuitBreaker.builder().setName(null));

        assertThrows(IllegalArgumentException.class, () -> CircuitBreaker.builder().setName(""));

        assertThrows(IllegalArgumentException.class,
                () -> CircuitBreaker.builder().setFailureThreshold(-0.1));

        assertThrows(IllegalArgumentException.class,
                () -> CircuitBreaker.builder().setFailureThreshold(1.1));

        assertThrows(IllegalArgumentException.class,
                () -> CircuitBreaker.builder().setMinimumRequests(0));

        assertThrows(IllegalArgumentException.class, () -> CircuitBreaker.builder().setWindowMs(0));

        assertThrows(IllegalArgumentException.class,
                () -> CircuitBreaker.builder().setOpenDurationMs(-1));

        assertThrows(IllegalArgumentException.class,
                () -> CircuitBreaker.builder().setHalfOpenRequests(0));
    }

    @Test
    @DisplayName("Default constants match spec requirements")
    void testDefaultConstants() {
        assertEquals(0.5, CircuitBreaker.DEFAULT_FAILURE_THRESHOLD);
        assertEquals(10, CircuitBreaker.DEFAULT_MINIMUM_REQUESTS);
        assertEquals(10_000, CircuitBreaker.DEFAULT_WINDOW_MS);
        assertEquals(30_000, CircuitBreaker.DEFAULT_OPEN_DURATION_MS);
        assertEquals(5, CircuitBreaker.DEFAULT_HALF_OPEN_REQUESTS);
    }

    @Test
    @DisplayName("toString returns meaningful string")
    void testToString() {
        String str = breaker.toString();

        assertTrue(str.contains("test-replica"));
        assertTrue(str.contains("CLOSED"));
    }

    @Test
    @DisplayName("Circuit breaker is per-replica")
    void testPerReplicaScope() {
        CircuitBreaker breaker1 = new CircuitBreaker("replica-1");
        CircuitBreaker breaker2 = new CircuitBreaker("replica-2");

        // Open breaker1
        breaker1.forceOpen();

        // breaker2 should still be closed
        assertTrue(breaker1.isOpen());
        assertTrue(breaker2.isClosed());
        assertTrue(breaker2.allowRequest());
    }

    @Test
    @DisplayName("Concurrent access is safe")
    void testConcurrentAccess() throws InterruptedException {
        int threads = 10;
        int iterations = 1000;
        Thread[] threadArray = new Thread[threads];

        for (int i = 0; i < threads; i++) {
            final int threadId = i;
            threadArray[i] = new Thread(() -> {
                for (int j = 0; j < iterations; j++) {
                    if (breaker.allowRequest()) {
                        if (threadId % 2 == 0) {
                            breaker.recordSuccess();
                        } else {
                            breaker.recordFailure();
                        }
                    }
                }
            });
        }

        for (Thread t : threadArray) {
            t.start();
        }
        for (Thread t : threadArray) {
            t.join();
        }

        // No exceptions = success
        // State should be deterministic
        assertNotNull(breaker.getState());
    }

    @Test
    @DisplayName("Failure rate at exactly threshold opens circuit")
    void testExactThresholdOpens() {
        // Exactly 50% failure rate
        for (int i = 0; i < 5; i++) {
            breaker.allowRequest();
            breaker.recordSuccess();
        }
        for (int i = 0; i < 5; i++) {
            breaker.allowRequest();
            breaker.recordFailure();
        }

        assertTrue(breaker.isOpen());
    }

    @Test
    @DisplayName("CircuitBreakerException contains correct info")
    void testCircuitBreakerException() {
        CircuitBreakerException ex =
                new CircuitBreakerException("test-circuit", CircuitBreaker.State.OPEN);

        assertEquals("test-circuit", ex.getCircuitName());
        assertEquals(CircuitBreaker.State.OPEN, ex.getCircuitState());
        assertEquals(CircuitBreakerException.CIRCUIT_OPEN, ex.getErrorCode());
        assertTrue(ex.isRetryable());
        assertTrue(ex.getMessage().contains("test-circuit"));
        assertTrue(ex.getMessage().contains("OPEN"));
    }

    @Test
    @DisplayName("Recording success in closed state records in window")
    void testSuccessRecordsInWindow() {
        for (int i = 0; i < 5; i++) {
            breaker.allowRequest();
            breaker.recordSuccess();
        }

        assertEquals(0.0, breaker.getCurrentFailureRate(), 0.01);
    }

    @Test
    @DisplayName("Mixed success/failure maintains accurate rate")
    void testMixedSuccessFailure() {
        // 3 successes, 2 failures = 40% failure rate
        for (int i = 0; i < 3; i++) {
            breaker.allowRequest();
            breaker.recordSuccess();
        }
        for (int i = 0; i < 2; i++) {
            breaker.allowRequest();
            breaker.recordFailure();
        }

        assertEquals(0.4, breaker.getCurrentFailureRate(), 0.01);
        assertTrue(breaker.isClosed()); // Under threshold
    }

    @Test
    @DisplayName("getName returns circuit name")
    void testGetName() {
        assertEquals("test-replica", breaker.getName());
    }

    @Test
    @DisplayName("Rejected requests counter increments")
    void testRejectedRequestsCounter() {
        breaker.forceOpen();

        long before = breaker.getRejectedRequests();
        breaker.allowRequest();
        breaker.allowRequest();
        long after = breaker.getRejectedRequests();

        assertEquals(before + 2, after);
    }
}
