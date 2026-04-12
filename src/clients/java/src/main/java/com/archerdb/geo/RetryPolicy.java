// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.Random;
import java.util.concurrent.TimeUnit;
import java.util.function.Supplier;

/**
 * Retry policy with exponential backoff for transient failures.
 *
 * <p>
 * Per client-retry/spec.md, the SDK implements automatic retry with:
 * <ul>
 * <li>Exponential backoff: 100ms, 200ms, 400ms, 800ms, 1600ms</li>
 * <li>Jitter: random(0, base_delay/2) added to prevent thundering herd</li>
 * <li>Max retries: 5 (total 6 attempts)</li>
 * <li>Total timeout enforcement</li>
 * </ul>
 *
 * <p>
 * This class is immutable and thread-safe.
 */
public final class RetryPolicy {

    /**
     * Default retry policy matching spec requirements.
     */
    public static final RetryPolicy DEFAULT = new Builder().build();

    /**
     * No-retry policy for operations that should not be retried.
     */
    public static final RetryPolicy NO_RETRY = new Builder().setMaxRetries(0).build();

    private final int maxRetries;
    private final long baseBackoffMs;
    private final long maxBackoffMs;
    private final long totalTimeoutMs;
    private final boolean jitterEnabled;
    private final Random random;
    private final ClientMetrics metrics;

    private RetryPolicy(Builder builder) {
        this.maxRetries = builder.maxRetries;
        this.baseBackoffMs = builder.baseBackoffMs;
        this.maxBackoffMs = builder.maxBackoffMs;
        this.totalTimeoutMs = builder.totalTimeoutMs;
        this.jitterEnabled = builder.jitterEnabled;
        this.random = new Random();
        this.metrics = builder.metrics;
    }

    /**
     * Returns the maximum number of retry attempts.
     */
    public int getMaxRetries() {
        return maxRetries;
    }

    /**
     * Returns the base backoff delay in milliseconds.
     */
    public long getBaseBackoffMs() {
        return baseBackoffMs;
    }

    /**
     * Returns the maximum backoff delay in milliseconds.
     */
    public long getMaxBackoffMs() {
        return maxBackoffMs;
    }

    /**
     * Returns the total timeout in milliseconds.
     */
    public long getTotalTimeoutMs() {
        return totalTimeoutMs;
    }

    /**
     * Returns true if jitter is enabled.
     */
    public boolean isJitterEnabled() {
        return jitterEnabled;
    }

    /**
     * Calculates the backoff delay for a given attempt.
     *
     * @param attempt the attempt number (0-indexed)
     * @return the delay in milliseconds
     */
    public long calculateBackoff(int attempt) {
        if (attempt == 0) {
            return 0; // First attempt is immediate
        }

        // Exponential backoff: baseBackoff * 2^(attempt-1)
        long delay = baseBackoffMs * (1L << (attempt - 1));
        delay = Math.min(delay, maxBackoffMs);

        // Add jitter: random(0, delay/2)
        if (jitterEnabled && delay > 0) {
            long jitter = (long) (random.nextDouble() * delay / 2);
            delay += jitter;
        }

        return delay;
    }

    /**
     * Executes an operation with retry.
     *
     * @param <T> the result type
     * @param operation the operation to execute
     * @return the result
     * @throws ArcherDBException if all retries exhausted
     */
    public <T> T execute(Supplier<T> operation) throws ArcherDBException {
        long startTime = System.nanoTime();
        int attempt = 0;
        ArcherDBException lastException = null;

        while (attempt <= maxRetries) {
            // Record retry metric for actual retry attempts (not first attempt)
            if (attempt > 0 && metrics != null) {
                metrics.recordRetry();
            }

            // Check total timeout
            long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startTime);
            if (elapsedMs >= totalTimeoutMs) {
                throw new OperationException(OperationException.TIMEOUT,
                        String.format("Total timeout exceeded after %d attempts", attempt), true,
                        lastException);
            }

            // Calculate and apply backoff
            long backoff = calculateBackoff(attempt);
            if (backoff > 0) {
                try {
                    Thread.sleep(backoff);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new OperationException(OperationException.TIMEOUT, "Retry interrupted",
                            false, e);
                }
            }

            try {
                return operation.get();
            } catch (ArcherDBException e) {
                lastException = e;

                // Don't retry non-retryable errors
                if (!e.isRetryable()) {
                    throw e;
                }

                attempt++;
            }
        }

        // All retries exhausted - record exhaustion metric
        if (metrics != null) {
            metrics.recordRetryExhausted();
        }
        throw new OperationException(OperationException.TIMEOUT,
                String.format("All %d retry attempts exhausted", maxRetries + 1), false,
                lastException);
    }

    /**
     * Creates a new builder for RetryPolicy.
     */
    public static Builder builder() {
        return new Builder();
    }

    /**
     * Builder for RetryPolicy.
     */
    public static class Builder {
        private int maxRetries = 5;
        private long baseBackoffMs = 100;
        private long maxBackoffMs = 1600;
        private long totalTimeoutMs = 30000;
        private boolean jitterEnabled = true;
        private ClientMetrics metrics = ClientMetrics.global();

        /**
         * Sets the maximum number of retry attempts.
         */
        public Builder setMaxRetries(int maxRetries) {
            if (maxRetries < 0) {
                throw new IllegalArgumentException("maxRetries cannot be negative");
            }
            this.maxRetries = maxRetries;
            return this;
        }

        /**
         * Sets the base backoff delay in milliseconds.
         */
        public Builder setBaseBackoffMs(long baseBackoffMs) {
            if (baseBackoffMs < 0) {
                throw new IllegalArgumentException("baseBackoffMs cannot be negative");
            }
            this.baseBackoffMs = baseBackoffMs;
            return this;
        }

        /**
         * Sets the maximum backoff delay in milliseconds.
         */
        public Builder setMaxBackoffMs(long maxBackoffMs) {
            if (maxBackoffMs < 0) {
                throw new IllegalArgumentException("maxBackoffMs cannot be negative");
            }
            this.maxBackoffMs = maxBackoffMs;
            return this;
        }

        /**
         * Sets the total timeout in milliseconds.
         */
        public Builder setTotalTimeoutMs(long totalTimeoutMs) {
            if (totalTimeoutMs <= 0) {
                throw new IllegalArgumentException("totalTimeoutMs must be positive");
            }
            this.totalTimeoutMs = totalTimeoutMs;
            return this;
        }

        /**
         * Enables or disables jitter.
         */
        public Builder setJitterEnabled(boolean jitterEnabled) {
            this.jitterEnabled = jitterEnabled;
            return this;
        }

        /**
         * Sets the metrics instance for recording retry metrics.
         *
         * @param metrics the metrics instance (null to disable metrics)
         */
        public Builder setMetrics(ClientMetrics metrics) {
            this.metrics = metrics;
            return this;
        }

        /**
         * Builds the RetryPolicy.
         */
        public RetryPolicy build() {
            return new RetryPolicy(this);
        }
    }
}
