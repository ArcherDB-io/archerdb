package com.archerdb.geo;

/**
 * Per-operation options for customizing retry behavior.
 *
 * <p>
 * Per client-retry/spec.md, SDKs MAY support per-operation retry override:
 *
 * <pre>
 * client.insertEvents(events,
 *         OperationOptions.builder().setMaxRetries(3).setTimeoutMs(10000).build());
 * </pre>
 *
 * <p>
 * When not specified, the client's default retry policy is used.
 *
 * <p>
 * This class is immutable and thread-safe.
 */
public final class OperationOptions {

    /**
     * Default options (uses client defaults).
     */
    public static final OperationOptions DEFAULT = new Builder().build();

    private final Integer maxRetries;
    private final Long timeoutMs;
    private final Long baseBackoffMs;
    private final Long maxBackoffMs;
    private final Boolean jitterEnabled;

    private OperationOptions(Builder builder) {
        this.maxRetries = builder.maxRetries;
        this.timeoutMs = builder.timeoutMs;
        this.baseBackoffMs = builder.baseBackoffMs;
        this.maxBackoffMs = builder.maxBackoffMs;
        this.jitterEnabled = builder.jitterEnabled;
    }

    /**
     * Returns the maximum retry attempts, or null to use default.
     *
     * @return max retries or null
     */
    public Integer getMaxRetries() {
        return maxRetries;
    }

    /**
     * Returns the operation timeout in milliseconds, or null to use default.
     *
     * @return timeout in ms or null
     */
    public Long getTimeoutMs() {
        return timeoutMs;
    }

    /**
     * Returns the base backoff delay in milliseconds, or null to use default.
     *
     * @return base backoff in ms or null
     */
    public Long getBaseBackoffMs() {
        return baseBackoffMs;
    }

    /**
     * Returns the maximum backoff delay in milliseconds, or null to use default.
     *
     * @return max backoff in ms or null
     */
    public Long getMaxBackoffMs() {
        return maxBackoffMs;
    }

    /**
     * Returns whether jitter is enabled, or null to use default.
     *
     * @return jitter enabled or null
     */
    public Boolean getJitterEnabled() {
        return jitterEnabled;
    }

    /**
     * Returns true if any option is set (not using all defaults).
     *
     * @return true if any option overridden
     */
    public boolean hasOverrides() {
        return maxRetries != null || timeoutMs != null || baseBackoffMs != null
                || maxBackoffMs != null || jitterEnabled != null;
    }

    /**
     * Creates a RetryPolicy applying these overrides to a base policy.
     *
     * @param basePolicy the base policy to override
     * @return the merged policy
     */
    public RetryPolicy toRetryPolicy(RetryPolicy basePolicy) {
        if (!hasOverrides()) {
            return basePolicy;
        }

        RetryPolicy.Builder builder = RetryPolicy.builder();

        builder.setMaxRetries(maxRetries != null ? maxRetries : basePolicy.getMaxRetries());
        builder.setTotalTimeoutMs(timeoutMs != null ? timeoutMs : basePolicy.getTotalTimeoutMs());
        builder.setBaseBackoffMs(
                baseBackoffMs != null ? baseBackoffMs : basePolicy.getBaseBackoffMs());
        builder.setMaxBackoffMs(maxBackoffMs != null ? maxBackoffMs : basePolicy.getMaxBackoffMs());
        builder.setJitterEnabled(
                jitterEnabled != null ? jitterEnabled : basePolicy.isJitterEnabled());

        return builder.build();
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
     * Creates options with just max retries.
     *
     * @param maxRetries the max retries
     * @return the options
     */
    public static OperationOptions withMaxRetries(int maxRetries) {
        return builder().setMaxRetries(maxRetries).build();
    }

    /**
     * Creates options with just timeout.
     *
     * @param timeoutMs the timeout in milliseconds
     * @return the options
     */
    public static OperationOptions withTimeout(long timeoutMs) {
        return builder().setTimeoutMs(timeoutMs).build();
    }

    /**
     * Creates options with max retries and timeout.
     *
     * @param maxRetries the max retries
     * @param timeoutMs the timeout in milliseconds
     * @return the options
     */
    public static OperationOptions with(int maxRetries, long timeoutMs) {
        return builder().setMaxRetries(maxRetries).setTimeoutMs(timeoutMs).build();
    }

    /**
     * Builder for OperationOptions.
     */
    public static class Builder {
        private Integer maxRetries;
        private Long timeoutMs;
        private Long baseBackoffMs;
        private Long maxBackoffMs;
        private Boolean jitterEnabled;

        /**
         * Sets the maximum number of retry attempts.
         *
         * @param maxRetries the max retries (0 = no retry)
         * @return this builder
         */
        public Builder setMaxRetries(int maxRetries) {
            if (maxRetries < 0) {
                throw new IllegalArgumentException("maxRetries cannot be negative");
            }
            this.maxRetries = maxRetries;
            return this;
        }

        /**
         * Sets the operation timeout in milliseconds.
         *
         * @param timeoutMs the timeout
         * @return this builder
         */
        public Builder setTimeoutMs(long timeoutMs) {
            if (timeoutMs <= 0) {
                throw new IllegalArgumentException("timeoutMs must be positive");
            }
            this.timeoutMs = timeoutMs;
            return this;
        }

        /**
         * Sets the base backoff delay in milliseconds.
         *
         * @param baseBackoffMs the base backoff
         * @return this builder
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
         *
         * @param maxBackoffMs the max backoff
         * @return this builder
         */
        public Builder setMaxBackoffMs(long maxBackoffMs) {
            if (maxBackoffMs < 0) {
                throw new IllegalArgumentException("maxBackoffMs cannot be negative");
            }
            this.maxBackoffMs = maxBackoffMs;
            return this;
        }

        /**
         * Enables or disables jitter.
         *
         * @param enabled whether to enable jitter
         * @return this builder
         */
        public Builder setJitterEnabled(boolean enabled) {
            this.jitterEnabled = enabled;
            return this;
        }

        /**
         * Builds the OperationOptions.
         *
         * @return the options
         */
        public OperationOptions build() {
            return new OperationOptions(this);
        }
    }
}
