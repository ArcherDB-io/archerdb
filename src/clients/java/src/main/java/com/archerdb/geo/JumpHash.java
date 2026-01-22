// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

import java.math.BigInteger;

/**
 * Jump Consistent Hash (Google, 2014) implementation.
 * <p>
 * O(1) memory, O(log n) compute, optimal 1/(n+1) key movement on resize.
 * Uses a linear congruential generator (LCG) with specific constants.
 * </p>
 * <p>
 * IMPORTANT: This implementation MUST produce identical results to
 * src/sharding.zig jumpHash() for cross-SDK compatibility.
 * </p>
 *
 * @see <a href="https://research.google/pubs/pub44824/">Jump Consistent Hash (Google, 2014)</a>
 */
public final class JumpHash {

    // Constants for the linear congruential generator
    private static final long LCG_MULTIPLIER = 2862933555777941757L;

    // Constants for murmur3-inspired finalization (computeShardKey)
    private static final long MURMUR_C1 = 0xff51afd7ed558ccdL;
    private static final long MURMUR_C2 = 0xc4ceb9fe1a85ec53L;

    private JumpHash() {
        // Utility class - prevent instantiation
    }

    /**
     * Jump Consistent Hash algorithm.
     * <p>
     * Computes a consistent bucket (shard) for the given key.
     * Same key always maps to the same bucket for a given bucket count.
     * When bucket count changes, approximately 1/(n+1) keys move to the new bucket.
     * </p>
     *
     * @param key 64-bit key to hash
     * @param numBuckets Number of buckets (shards), must be positive
     * @return Bucket index in range [0, numBuckets)
     */
    public static int jumpHash(long key, int numBuckets) {
        if (numBuckets <= 0) {
            return 0;
        }

        long b = -1;
        long j = 0;
        long k = key;

        while (j < numBuckets) {
            b = j;
            // Linear congruential generator step (wrapping addition handled by Java)
            k = k * LCG_MULTIPLIER + 1;
            // Compute next jump
            // Use unsigned division by treating (k >>> 33) as unsigned
            j = (long) ((b + 1) * ((double) (1L << 31) / ((k >>> 33) + 1)));
        }

        return (int) b;
    }

    /**
     * Compute a 64-bit shard key from a 128-bit entity_id.
     * <p>
     * Uses murmur3-inspired finalization for high-quality mixing.
     * </p>
     * <p>
     * IMPORTANT: This implementation MUST produce identical results to
     * src/sharding.zig computeShardKey() for cross-SDK compatibility.
     * </p>
     *
     * @param entityIdLo Low 64 bits of the entity ID
     * @param entityIdHi High 64 bits of the entity ID
     * @return 64-bit shard key
     */
    public static long computeShardKey(long entityIdLo, long entityIdHi) {
        // Finalization mix for lo (h1)
        long h1 = entityIdLo;
        h1 ^= h1 >>> 33;
        h1 *= MURMUR_C1;
        h1 ^= h1 >>> 33;
        h1 *= MURMUR_C2;
        h1 ^= h1 >>> 33;

        // Finalization mix for hi (h2)
        long h2 = entityIdHi;
        h2 ^= h2 >>> 33;
        h2 *= MURMUR_C1;
        h2 ^= h2 >>> 33;
        h2 *= MURMUR_C2;
        h2 ^= h2 >>> 33;

        return h1 ^ h2;
    }

    /**
     * Compute a 64-bit shard key from a BigInteger entity_id.
     *
     * @param entityId 128-bit entity ID as BigInteger
     * @return 64-bit shard key
     */
    public static long computeShardKey(BigInteger entityId) {
        // Extract low and high 64-bit values
        long lo = entityId.longValue();
        long hi = entityId.shiftRight(64).longValue();
        return computeShardKey(lo, hi);
    }

    /**
     * Compute which shard an entity belongs to.
     *
     * @param entityIdLo Low 64 bits of the entity ID
     * @param entityIdHi High 64 bits of the entity ID
     * @param numShards Number of shards
     * @return Shard index in range [0, numShards)
     */
    public static int getShardForEntity(long entityIdLo, long entityIdHi, int numShards) {
        long shardKey = computeShardKey(entityIdLo, entityIdHi);
        return jumpHash(shardKey, numShards);
    }

    /**
     * Compute which shard an entity belongs to.
     *
     * @param entityId 128-bit entity ID as BigInteger
     * @param numShards Number of shards
     * @return Shard index in range [0, numShards)
     */
    public static int getShardForEntity(BigInteger entityId, int numShards) {
        long shardKey = computeShardKey(entityId);
        return jumpHash(shardKey, numShards);
    }
}
