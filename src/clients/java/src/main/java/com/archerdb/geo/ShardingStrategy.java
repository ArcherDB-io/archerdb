// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

/**
 * Strategy for distributing entities across shards.
 * <p>
 * Different strategies offer different trade-offs:
 * <ul>
 * <li>{@link #MODULO} - Simple, requires power-of-2 shard counts, moves most data on resize</li>
 * <li>{@link #VIRTUAL_RING} - Consistent hashing with O(log N) lookup and memory cost</li>
 * <li>{@link #JUMP_HASH} - Google's algorithm - O(1) memory, O(log N) compute, optimal
 * movement</li>
 * </ul>
 * </p>
 *
 * @see <a href="https://research.google/pubs/pub44824/">Jump Consistent Hash (Google, 2014)</a>
 */
public enum ShardingStrategy {
    /**
     * Simple modulo-based sharding: hash % num_shards. Requires power-of-2 shard counts for
     * efficient computation. Moves ~(N-1)/N entities when adding one shard.
     */
    MODULO((byte) 0),

    /**
     * Virtual node ring-based consistent hashing. Uses 150 virtual nodes per shard by default.
     * Moves ~1/N entities when adding one shard. Has O(log N) lookup overhead and memory cost.
     */
    VIRTUAL_RING((byte) 1),

    /**
     * Jump Consistent Hash (Google, 2014). O(1) memory, O(log N) compute, optimal 1/(N+1) movement.
     * Default strategy - best balance of performance and movement.
     */
    JUMP_HASH((byte) 2);

    private final byte value;

    ShardingStrategy(byte value) {
        this.value = value;
    }

    /**
     * Returns the wire format value.
     */
    public byte getValue() {
        return value;
    }

    /**
     * Check if this strategy requires power-of-2 shard counts.
     */
    public boolean requiresPowerOfTwo() {
        return this == MODULO;
    }

    /**
     * Converts a wire format value to the enum.
     */
    public static ShardingStrategy fromValue(byte value) {
        for (ShardingStrategy strategy : values()) {
            if (strategy.value == value) {
                return strategy;
            }
        }
        return JUMP_HASH; // Default
    }

    /**
     * Parse from string representation.
     */
    public static ShardingStrategy fromString(String str) {
        switch (str.toLowerCase()) {
            case "modulo":
                return MODULO;
            case "virtual_ring":
                return VIRTUAL_RING;
            case "jump_hash":
                return JUMP_HASH;
            default:
                return null;
        }
    }

    /**
     * Convert to string representation.
     */
    @Override
    public String toString() {
        switch (this) {
            case MODULO:
                return "modulo";
            case VIRTUAL_RING:
                return "virtual_ring";
            case JUMP_HASH:
                return "jump_hash";
            default:
                return "unknown";
        }
    }
}
