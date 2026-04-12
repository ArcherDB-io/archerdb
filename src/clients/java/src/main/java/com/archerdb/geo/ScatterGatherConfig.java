// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.time.Duration;

/**
 * Configuration for scatter-gather query execution (F5.1.5 Scatter-Gather Query Support).
 *
 * <p>
 * Controls how queries are distributed across shards and how results are aggregated.
 */
public final class ScatterGatherConfig {

    /** Default configuration with sensible defaults. */
    public static final ScatterGatherConfig DEFAULT = new Builder().build();

    private final int maxConcurrency;
    private final boolean allowPartialResults;
    private final Duration timeout;

    private ScatterGatherConfig(Builder builder) {
        this.maxConcurrency = builder.maxConcurrency;
        this.allowPartialResults = builder.allowPartialResults;
        this.timeout = builder.timeout;
    }

    /**
     * Returns the maximum number of concurrent shard queries (0 = unlimited).
     */
    public int getMaxConcurrency() {
        return maxConcurrency;
    }

    /**
     * Returns true if partial results should be returned when some shards fail.
     */
    public boolean allowPartialResults() {
        return allowPartialResults;
    }

    /**
     * Returns the per-shard query timeout.
     */
    public Duration getTimeout() {
        return timeout;
    }

    /**
     * Creates a new builder for ScatterGatherConfig.
     */
    public static Builder builder() {
        return new Builder();
    }

    /**
     * Builder for ScatterGatherConfig.
     */
    public static final class Builder {
        private int maxConcurrency = 0; // Unlimited
        private boolean allowPartialResults = true;
        private Duration timeout = Duration.ofSeconds(30);

        private Builder() {}

        /**
         * Sets the maximum number of concurrent shard queries.
         *
         * @param maxConcurrency max concurrent queries (0 = unlimited)
         * @return this builder
         */
        public Builder maxConcurrency(int maxConcurrency) {
            if (maxConcurrency < 0) {
                throw new IllegalArgumentException("maxConcurrency cannot be negative");
            }
            this.maxConcurrency = maxConcurrency;
            return this;
        }

        /**
         * Sets whether to allow partial results when some shards fail.
         *
         * @param allowPartialResults true to allow partial results
         * @return this builder
         */
        public Builder allowPartialResults(boolean allowPartialResults) {
            this.allowPartialResults = allowPartialResults;
            return this;
        }

        /**
         * Sets the per-shard query timeout.
         *
         * @param timeout the timeout duration
         * @return this builder
         */
        public Builder timeout(Duration timeout) {
            if (timeout == null || timeout.isNegative()) {
                throw new IllegalArgumentException("timeout must be positive");
            }
            this.timeout = timeout;
            return this;
        }

        /**
         * Builds the ScatterGatherConfig.
         */
        public ScatterGatherConfig build() {
            return new ScatterGatherConfig(this);
        }
    }

    @Override
    public String toString() {
        return String.format("ScatterGatherConfig{maxConcurrency=%d, allowPartial=%b, timeout=%s}",
                maxConcurrency, allowPartialResults, timeout);
    }
}
