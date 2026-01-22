// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

/**
 * Jump Consistent Hash Golden Vector Tests.
 * <p>
 * Source of truth: src/sharding.zig - these values MUST match exactly.
 * </p>
 */
class JumpHashTest {

    @Nested
    @DisplayName("JumpHash Golden Vectors")
    class JumpHashGoldenVectors {

        @Test
        @DisplayName("Key 0 always maps to bucket 0")
        void testKey0() {
            assertEquals(0, JumpHash.jumpHash(0L, 1));
            assertEquals(0, JumpHash.jumpHash(0L, 10));
            assertEquals(0, JumpHash.jumpHash(0L, 100));
            assertEquals(0, JumpHash.jumpHash(0L, 256));
        }

        @Test
        @DisplayName("Key 0xDEADBEEF canonical test vectors")
        void testKeyDeadbeef() {
            assertEquals(5, JumpHash.jumpHash(0xDEADBEEFL, 8));
            assertEquals(5, JumpHash.jumpHash(0xDEADBEEFL, 16));
            assertEquals(16, JumpHash.jumpHash(0xDEADBEEFL, 32));
            assertEquals(16, JumpHash.jumpHash(0xDEADBEEFL, 64));
            assertEquals(87, JumpHash.jumpHash(0xDEADBEEFL, 128));
            assertEquals(87, JumpHash.jumpHash(0xDEADBEEFL, 256));
        }

        @Test
        @DisplayName("Key 0xCAFEBABE canonical test vectors")
        void testKeyCafebabe() {
            assertEquals(5, JumpHash.jumpHash(0xCAFEBABEL, 8));
            assertEquals(5, JumpHash.jumpHash(0xCAFEBABEL, 16));
            assertEquals(5, JumpHash.jumpHash(0xCAFEBABEL, 32));
            assertEquals(46, JumpHash.jumpHash(0xCAFEBABEL, 64));
            assertEquals(85, JumpHash.jumpHash(0xCAFEBABEL, 128));
            assertEquals(85, JumpHash.jumpHash(0xCAFEBABEL, 256));
        }

        @Test
        @DisplayName("Key max u64 edge case")
        void testKeyMaxU64() {
            // Note: In Java, -1L represents 0xFFFFFFFFFFFFFFFF
            assertEquals(7, JumpHash.jumpHash(-1L, 8));
            assertEquals(10, JumpHash.jumpHash(-1L, 16));
            assertEquals(248, JumpHash.jumpHash(-1L, 256));
        }

        @Test
        @DisplayName("Additional test keys")
        void testAdditionalKeys() {
            assertEquals(4, JumpHash.jumpHash(0x123456789ABCDEF0L, 8));
            assertEquals(4, JumpHash.jumpHash(0x123456789ABCDEF0L, 16));
            assertEquals(33, JumpHash.jumpHash(0x123456789ABCDEF0L, 256));

            // Note: 0xFEDCBA9876543210 as unsigned is -81985529216486896L in Java
            assertEquals(1, JumpHash.jumpHash(0xFEDCBA9876543210L, 8));
            assertEquals(10, JumpHash.jumpHash(0xFEDCBA9876543210L, 16));
            assertEquals(143, JumpHash.jumpHash(0xFEDCBA9876543210L, 256));
        }
    }

    @Nested
    @DisplayName("JumpHash Determinism")
    class JumpHashDeterminism {

        @Test
        @DisplayName("Same key+buckets always produces same result over 1000 iterations")
        void testDeterminism1000Iterations() {
            long[][] testCases = {
                {0xDEADBEEFL, 16, 5},
                {0xCAFEBABEL, 64, 46},
                {0x123456789ABCDEF0L, 256, 33},
                {-1L, 8, 7}, // 0xFFFFFFFFFFFFFFFF
            };

            for (long[] tc : testCases) {
                long key = tc[0];
                int buckets = (int) tc[1];
                int expected = (int) tc[2];

                for (int i = 0; i < 1000; i++) {
                    int result = JumpHash.jumpHash(key, buckets);
                    assertEquals(expected, result,
                        String.format("Iteration %d: jumpHash(0x%X, %d) = %d, want %d",
                            i, key, buckets, result, expected));
                }
            }
        }
    }

    @Nested
    @DisplayName("ComputeShardKey Golden Vectors")
    class ComputeShardKeyGoldenVectors {

        @Test
        @DisplayName("Entity ID 1")
        void testEntity1() {
            long lo = 0x0000000000000001L;
            long hi = 0x0000000000000000L;
            assertEquals(0xB456BCFC34C2CB2CL, JumpHash.computeShardKey(lo, hi));
        }

        @Test
        @DisplayName("Entity ID DEADBEEF/CAFEBABE pattern")
        void testEntityDeadbeefCafebabe() {
            long lo = 0x123456789ABCDEF0L;
            long hi = 0xDEADBEEFCAFEBABEL;
            assertEquals(0x683A5932FE04E714L, JumpHash.computeShardKey(lo, hi));
        }

        @Test
        @DisplayName("Max entity ID")
        void testEntityMax() {
            long lo = -1L; // 0xFFFFFFFFFFFFFFFF
            long hi = -1L; // 0xFFFFFFFFFFFFFFFF
            assertEquals(0x0000000000000000L, JumpHash.computeShardKey(lo, hi));
        }

        @Test
        @DisplayName("Symmetric entity ID")
        void testEntitySymmetric() {
            long lo = 0x12345678ABCDEF00L;
            long hi = 0x12345678ABCDEF00L;
            assertEquals(0x0000000000000000L, JumpHash.computeShardKey(lo, hi));
        }
    }

    @Nested
    @DisplayName("ComputeShardKey Determinism")
    class ComputeShardKeyDeterminism {

        @Test
        @DisplayName("Same entity_id always produces same shard_key over 1000 iterations")
        void testDeterminism1000Iterations() {
            long[][] testCases = {
                {0x0000000000000001L, 0x0000000000000000L, 0xB456BCFC34C2CB2CL},
                {0x123456789ABCDEF0L, 0xDEADBEEFCAFEBABEL, 0x683A5932FE04E714L},
            };

            for (long[] tc : testCases) {
                long lo = tc[0];
                long hi = tc[1];
                long expected = tc[2];

                for (int i = 0; i < 1000; i++) {
                    long result = JumpHash.computeShardKey(lo, hi);
                    assertEquals(expected, result,
                        String.format("Iteration %d: computeShardKey(0x%X, 0x%X) = 0x%X, want 0x%X",
                            i, lo, hi, result, expected));
                }
            }
        }
    }

    @Nested
    @DisplayName("GetShardForEntity")
    class GetShardForEntityTests {

        @Test
        @DisplayName("Deterministic routing")
        void testDeterministicRouting() {
            long lo = 0xDEADBEEFL;
            long hi = 0xCAFEBABEL;

            int shard1 = JumpHash.getShardForEntity(lo, hi, 16);
            int shard2 = JumpHash.getShardForEntity(lo, hi, 16);
            int shard3 = JumpHash.getShardForEntity(lo, hi, 16);

            assertEquals(shard1, shard2);
            assertEquals(shard2, shard3);
            assertTrue(shard1 < 16);
        }
    }
}
