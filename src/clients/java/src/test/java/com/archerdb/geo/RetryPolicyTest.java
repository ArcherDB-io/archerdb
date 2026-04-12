// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.util.concurrent.atomic.AtomicInteger;

/**
 * Unit tests for RetryPolicy.
 *
 * <p>
 * Per client-retry/spec.md, tests verify:
 * <ul>
 * <li>Exponential backoff: 100ms, 200ms, 400ms, 800ms, 1600ms</li>
 * <li>Jitter: random(0, base_delay/2) added</li>
 * <li>Max retries: 5 (total 6 attempts)</li>
 * <li>Total timeout enforcement</li>
 * <li>Non-retryable errors are not retried</li>
 * </ul>
 */
class RetryPolicyTest {

    // ========================================================================
    // Default Policy Tests
    // ========================================================================

    @Test
    void testDefaultPolicyValues() {
        RetryPolicy policy = RetryPolicy.DEFAULT;

        assertEquals(5, policy.getMaxRetries());
        assertEquals(100, policy.getBaseBackoffMs());
        assertEquals(1600, policy.getMaxBackoffMs());
        assertEquals(30000, policy.getTotalTimeoutMs());
        assertTrue(policy.isJitterEnabled());
    }

    @Test
    void testNoRetryPolicy() {
        RetryPolicy policy = RetryPolicy.NO_RETRY;

        assertEquals(0, policy.getMaxRetries());
    }

    // ========================================================================
    // Backoff Calculation Tests
    // ========================================================================

    @Test
    void testFirstAttemptIsImmediate() {
        RetryPolicy policy = RetryPolicy.builder().setJitterEnabled(false).build();

        assertEquals(0, policy.calculateBackoff(0), "First attempt should have no delay");
    }

    @Test
    void testExponentialBackoffWithoutJitter() {
        RetryPolicy policy = RetryPolicy.builder().setJitterEnabled(false).build();

        // attempt 1: 100ms * 2^0 = 100ms
        assertEquals(100, policy.calculateBackoff(1));
        // attempt 2: 100ms * 2^1 = 200ms
        assertEquals(200, policy.calculateBackoff(2));
        // attempt 3: 100ms * 2^2 = 400ms
        assertEquals(400, policy.calculateBackoff(3));
        // attempt 4: 100ms * 2^3 = 800ms
        assertEquals(800, policy.calculateBackoff(4));
        // attempt 5: 100ms * 2^4 = 1600ms (at max)
        assertEquals(1600, policy.calculateBackoff(5));
    }

    @Test
    void testMaxBackoffIsCapped() {
        RetryPolicy policy =
                RetryPolicy.builder().setMaxBackoffMs(1600).setJitterEnabled(false).build();

        // attempt 6 would be 3200ms, but capped at 1600ms
        assertEquals(1600, policy.calculateBackoff(6));
        assertEquals(1600, policy.calculateBackoff(10));
    }

    @ParameterizedTest
    @CsvSource({"1, 100, 150", // Base + up to 50% jitter
            "2, 200, 300", "3, 400, 600", "4, 800, 1200", "5, 1600, 2400"})
    void testBackoffWithJitterIsInRange(int attempt, long minExpected, long maxExpected) {
        RetryPolicy policy = RetryPolicy.builder().setJitterEnabled(true).build();

        // Run multiple times to verify range
        for (int i = 0; i < 20; i++) {
            long backoff = policy.calculateBackoff(attempt);
            assertTrue(backoff >= minExpected,
                    String.format("Backoff %d should be >= %d", backoff, minExpected));
            assertTrue(backoff <= maxExpected,
                    String.format("Backoff %d should be <= %d", backoff, maxExpected));
        }
    }

    // ========================================================================
    // Retry Execution Tests
    // ========================================================================

    @Test
    void testSuccessfulExecutionOnFirstAttempt() {
        RetryPolicy policy = RetryPolicy.DEFAULT;
        AtomicInteger attempts = new AtomicInteger(0);

        String result = policy.execute(() -> {
            attempts.incrementAndGet();
            return "success";
        });

        assertEquals("success", result);
        assertEquals(1, attempts.get());
    }

    @Test
    void testSuccessAfterRetries() {
        RetryPolicy policy =
                RetryPolicy.builder().setBaseBackoffMs(1).setJitterEnabled(false).build();

        AtomicInteger attempts = new AtomicInteger(0);

        String result = policy.execute(() -> {
            int current = attempts.incrementAndGet();
            if (current < 3) {
                throw new ConnectionException(1, "Connection failed");
            }
            return "success";
        });

        assertEquals("success", result);
        assertEquals(3, attempts.get());
    }

    @Test
    void testNonRetryableExceptionNotRetried() {
        RetryPolicy policy = RetryPolicy.builder().setBaseBackoffMs(1).build();

        AtomicInteger attempts = new AtomicInteger(0);

        ValidationException thrown = assertThrows(ValidationException.class, () -> {
            policy.execute(() -> {
                attempts.incrementAndGet();
                throw ValidationException.invalidCoordinates(91.0, 0.0);
            });
        });

        assertEquals(1, attempts.get(), "Non-retryable error should not be retried");
        assertEquals(ValidationException.INVALID_COORDINATES, thrown.getErrorCode());
    }

    @Test
    void testMaxRetriesExhausted() {
        RetryPolicy policy = RetryPolicy.builder().setMaxRetries(3).setBaseBackoffMs(1)
                .setJitterEnabled(false).setTotalTimeoutMs(30000).build();

        AtomicInteger attempts = new AtomicInteger(0);

        ArcherDBException thrown = assertThrows(ArcherDBException.class, () -> {
            policy.execute(() -> {
                attempts.incrementAndGet();
                throw new ConnectionException(1, "Connection failed");
            });
        });

        assertEquals(4, attempts.get(), "Should make initial + 3 retries = 4 attempts");
        assertTrue(thrown.getMessage().contains("4"));
    }

    @Test
    void testTotalTimeoutEnforced() {
        RetryPolicy policy =
                RetryPolicy.builder().setMaxRetries(100).setBaseBackoffMs(50).setTotalTimeoutMs(100) // Very
                                                                                                     // short
                                                                                                     // timeout
                        .setJitterEnabled(false).build();

        AtomicInteger attempts = new AtomicInteger(0);

        ArcherDBException thrown = assertThrows(ArcherDBException.class, () -> {
            policy.execute(() -> {
                attempts.incrementAndGet();
                throw new ConnectionException(1, "Connection failed");
            });
        });

        assertTrue(
                thrown.getMessage().contains("timeout") || thrown.getMessage().contains("Timeout"),
                "Should fail due to timeout");
        assertTrue(attempts.get() < 100, "Should stop before max retries due to timeout");
    }

    // ========================================================================
    // Builder Tests
    // ========================================================================

    @Test
    void testBuilderCustomValues() {
        RetryPolicy policy = RetryPolicy.builder().setMaxRetries(10).setBaseBackoffMs(200)
                .setMaxBackoffMs(5000).setTotalTimeoutMs(60000).setJitterEnabled(false).build();

        assertEquals(10, policy.getMaxRetries());
        assertEquals(200, policy.getBaseBackoffMs());
        assertEquals(5000, policy.getMaxBackoffMs());
        assertEquals(60000, policy.getTotalTimeoutMs());
        assertFalse(policy.isJitterEnabled());
    }

    @Test
    void testBuilderRejectsNegativeMaxRetries() {
        assertThrows(IllegalArgumentException.class, () -> {
            RetryPolicy.builder().setMaxRetries(-1);
        });
    }

    @Test
    void testBuilderRejectsNegativeBaseBackoff() {
        assertThrows(IllegalArgumentException.class, () -> {
            RetryPolicy.builder().setBaseBackoffMs(-1);
        });
    }

    @Test
    void testBuilderRejectsNegativeMaxBackoff() {
        assertThrows(IllegalArgumentException.class, () -> {
            RetryPolicy.builder().setMaxBackoffMs(-1);
        });
    }

    @Test
    void testBuilderRejectsZeroTotalTimeout() {
        assertThrows(IllegalArgumentException.class, () -> {
            RetryPolicy.builder().setTotalTimeoutMs(0);
        });
    }

    @Test
    void testBuilderRejectsNegativeTotalTimeout() {
        assertThrows(IllegalArgumentException.class, () -> {
            RetryPolicy.builder().setTotalTimeoutMs(-100);
        });
    }

    // ========================================================================
    // Exception Propagation Tests
    // ========================================================================

    @Test
    void testOriginalExceptionIsCause() {
        RetryPolicy policy = RetryPolicy.builder().setMaxRetries(1).setBaseBackoffMs(1)
                .setJitterEnabled(false).build();

        ConnectionException originalException = new ConnectionException(1, "Original error");

        ArcherDBException thrown = assertThrows(ArcherDBException.class, () -> {
            policy.execute(() -> {
                throw originalException;
            });
        });

        assertEquals(originalException, thrown.getCause());
    }

    @Test
    void testInterruptionHandled() {
        RetryPolicy policy = RetryPolicy.builder().setBaseBackoffMs(10000) // Long backoff
                .build();

        Thread.currentThread().interrupt(); // Set interrupt flag

        assertThrows(ArcherDBException.class, () -> {
            policy.execute(() -> {
                throw new ConnectionException(1, "Connection failed");
            });
        });

        // Clean up interrupt flag
        Thread.interrupted();
    }

    // ========================================================================
    // Edge Case Tests
    // ========================================================================

    @Test
    void testZeroBaseBackoff() {
        RetryPolicy policy =
                RetryPolicy.builder().setBaseBackoffMs(0).setJitterEnabled(false).build();

        assertEquals(0, policy.calculateBackoff(1));
        assertEquals(0, policy.calculateBackoff(5));
    }

    @Test
    void testNoRetryPolicyExecutes() {
        AtomicInteger attempts = new AtomicInteger(0);

        ArcherDBException thrown = assertThrows(ArcherDBException.class, () -> {
            RetryPolicy.NO_RETRY.execute(() -> {
                attempts.incrementAndGet();
                throw new ConnectionException(1, "Connection failed");
            });
        });

        assertEquals(1, attempts.get(), "NO_RETRY should execute exactly once");
    }

    // ========================================================================
    // Metrics Integration Tests
    // ========================================================================

    @Test
    void testRetryMetricsRecordedOnRetry() {
        ClientMetrics metrics = new ClientMetrics();
        RetryPolicy policy = RetryPolicy.builder().setMaxRetries(3).setBaseBackoffMs(1)
                .setJitterEnabled(false).setMetrics(metrics).build();

        AtomicInteger attempts = new AtomicInteger(0);

        // Operation succeeds on 3rd attempt
        String result = policy.execute(() -> {
            int current = attempts.incrementAndGet();
            if (current < 3) {
                throw new ConnectionException(1, "Connection failed");
            }
            return "success";
        });

        assertEquals("success", result);
        assertEquals(3, attempts.get());
        // 2 retries recorded (first 2 failures triggered retries)
        assertEquals(2, metrics.getRetriesTotal());
        // No retry exhaustion - we succeeded
        assertEquals(0, metrics.getRetryExhaustedTotal());
    }

    @Test
    void testRetryExhaustedMetricRecorded() {
        ClientMetrics metrics = new ClientMetrics();
        RetryPolicy policy = RetryPolicy.builder().setMaxRetries(3).setBaseBackoffMs(1)
                .setJitterEnabled(false).setTotalTimeoutMs(30000).setMetrics(metrics).build();

        AtomicInteger attempts = new AtomicInteger(0);

        assertThrows(ArcherDBException.class, () -> {
            policy.execute(() -> {
                attempts.incrementAndGet();
                throw new ConnectionException(1, "Connection failed");
            });
        });

        assertEquals(4, attempts.get(), "Should make initial + 3 retries = 4 attempts");
        // 3 retries recorded
        assertEquals(3, metrics.getRetriesTotal());
        // Retry exhaustion recorded
        assertEquals(1, metrics.getRetryExhaustedTotal());
    }

    @Test
    void testNoMetricsRecordedOnSuccess() {
        ClientMetrics metrics = new ClientMetrics();
        RetryPolicy policy = RetryPolicy.builder().setMetrics(metrics).build();

        String result = policy.execute(() -> "immediate success");

        assertEquals("immediate success", result);
        assertEquals(0, metrics.getRetriesTotal());
        assertEquals(0, metrics.getRetryExhaustedTotal());
    }

    @Test
    void testNoMetricsRecordedForNonRetryableError() {
        ClientMetrics metrics = new ClientMetrics();
        RetryPolicy policy = RetryPolicy.builder().setMetrics(metrics).build();

        assertThrows(ValidationException.class, () -> {
            policy.execute(() -> {
                throw ValidationException.invalidCoordinates(91.0, 0.0);
            });
        });

        // Non-retryable errors don't trigger retry metrics
        assertEquals(0, metrics.getRetriesTotal());
        assertEquals(0, metrics.getRetryExhaustedTotal());
    }

    @Test
    void testNullMetricsDoesNotCrash() {
        RetryPolicy policy = RetryPolicy.builder().setMaxRetries(2).setBaseBackoffMs(1)
                .setJitterEnabled(false).setMetrics(null).build();

        AtomicInteger attempts = new AtomicInteger(0);

        // Should not throw NullPointerException
        assertThrows(ArcherDBException.class, () -> {
            policy.execute(() -> {
                attempts.incrementAndGet();
                throw new ConnectionException(1, "Connection failed");
            });
        });

        assertEquals(3, attempts.get());
    }
}
