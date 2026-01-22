// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package types

import (
	"encoding/binary"
	"testing"
)

// ============================================================================
// Jump Consistent Hash Golden Vector Tests
// Source of truth: src/sharding.zig - these values MUST match exactly.
// ============================================================================

func TestJumpHashGoldenVectors(t *testing.T) {
	// These golden vectors are CANONICAL and MUST match src/sharding.zig exactly.
	// Any deviation indicates an algorithm bug that will break cross-SDK compatibility.

	tests := []struct {
		name       string
		key        uint64
		numBuckets uint32
		expected   uint32
	}{
		// Key 0: always maps to bucket 0
		{"key_0_buckets_1", 0, 1, 0},
		{"key_0_buckets_10", 0, 10, 0},
		{"key_0_buckets_100", 0, 100, 0},
		{"key_0_buckets_256", 0, 256, 0},

		// Key 0xDEADBEEF: canonical test key
		{"key_DEADBEEF_buckets_8", 0xDEADBEEF, 8, 5},
		{"key_DEADBEEF_buckets_16", 0xDEADBEEF, 16, 5},
		{"key_DEADBEEF_buckets_32", 0xDEADBEEF, 32, 16},
		{"key_DEADBEEF_buckets_64", 0xDEADBEEF, 64, 16},
		{"key_DEADBEEF_buckets_128", 0xDEADBEEF, 128, 87},
		{"key_DEADBEEF_buckets_256", 0xDEADBEEF, 256, 87},

		// Key 0xCAFEBABE: another canonical test key
		{"key_CAFEBABE_buckets_8", 0xCAFEBABE, 8, 5},
		{"key_CAFEBABE_buckets_16", 0xCAFEBABE, 16, 5},
		{"key_CAFEBABE_buckets_32", 0xCAFEBABE, 32, 5},
		{"key_CAFEBABE_buckets_64", 0xCAFEBABE, 64, 46},
		{"key_CAFEBABE_buckets_128", 0xCAFEBABE, 128, 85},
		{"key_CAFEBABE_buckets_256", 0xCAFEBABE, 256, 85},

		// Key max u64: edge case
		{"key_MAX_buckets_8", 0xFFFFFFFFFFFFFFFF, 8, 7},
		{"key_MAX_buckets_16", 0xFFFFFFFFFFFFFFFF, 16, 10},
		{"key_MAX_buckets_256", 0xFFFFFFFFFFFFFFFF, 256, 248},

		// Additional test keys
		{"key_123456789ABCDEF0_buckets_8", 0x123456789ABCDEF0, 8, 4},
		{"key_123456789ABCDEF0_buckets_16", 0x123456789ABCDEF0, 16, 4},
		{"key_123456789ABCDEF0_buckets_256", 0x123456789ABCDEF0, 256, 33},

		{"key_FEDCBA9876543210_buckets_8", 0xFEDCBA9876543210, 8, 1},
		{"key_FEDCBA9876543210_buckets_16", 0xFEDCBA9876543210, 16, 10},
		{"key_FEDCBA9876543210_buckets_256", 0xFEDCBA9876543210, 256, 143},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			result := JumpHash(tc.key, tc.numBuckets)
			if result != tc.expected {
				t.Errorf("JumpHash(0x%X, %d) = %d, want %d",
					tc.key, tc.numBuckets, result, tc.expected)
			}
		})
	}
}

func TestJumpHashDeterminism(t *testing.T) {
	// Verify same key+buckets always produces same result over 1000 iterations.
	testCases := []struct {
		key        uint64
		numBuckets uint32
		expected   uint32
	}{
		{0xDEADBEEF, 16, 5},
		{0xCAFEBABE, 64, 46},
		{0x123456789ABCDEF0, 256, 33},
		{0xFFFFFFFFFFFFFFFF, 8, 7},
	}

	for _, tc := range testCases {
		for i := 0; i < 1000; i++ {
			result := JumpHash(tc.key, tc.numBuckets)
			if result != tc.expected {
				t.Errorf("Iteration %d: JumpHash(0x%X, %d) = %d, want %d",
					i, tc.key, tc.numBuckets, result, tc.expected)
			}
		}
	}
}

// makeUint128 creates a Uint128 from low and high 64-bit values.
func makeUint128(lo, hi uint64) Uint128 {
	var bytes [16]byte
	binary.LittleEndian.PutUint64(bytes[0:8], lo)
	binary.LittleEndian.PutUint64(bytes[8:16], hi)
	return BytesToUint128(bytes)
}

func TestComputeShardKeyGoldenVectors(t *testing.T) {
	// These golden vectors MUST match src/sharding.zig computeShardKey() exactly.
	tests := []struct {
		name     string
		lo       uint64
		hi       uint64
		expected uint64
	}{
		{"entity_1", 0x0000000000000001, 0x0000000000000000, 0xB456BCFC34C2CB2C},
		{"entity_DEADBEEF_CAFEBABE", 0x123456789ABCDEF0, 0xDEADBEEFCAFEBABE, 0x683A5932FE04E714},
		{"entity_MAX", 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0x0000000000000000},
		{"entity_symmetric", 0x12345678ABCDEF00, 0x12345678ABCDEF00, 0x0000000000000000},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			entityID := makeUint128(tc.lo, tc.hi)
			result := ComputeShardKey(entityID)
			if result != tc.expected {
				t.Errorf("ComputeShardKey(lo=0x%X, hi=0x%X) = 0x%X, want 0x%X",
					tc.lo, tc.hi, result, tc.expected)
			}
		})
	}
}

func TestComputeShardKeyDeterminism(t *testing.T) {
	// Verify same entity_id always produces same shard_key over 1000 iterations.
	testCases := []struct {
		lo       uint64
		hi       uint64
		expected uint64
	}{
		{0x0000000000000001, 0x0000000000000000, 0xB456BCFC34C2CB2C},
		{0x123456789ABCDEF0, 0xDEADBEEFCAFEBABE, 0x683A5932FE04E714},
	}

	for _, tc := range testCases {
		entityID := makeUint128(tc.lo, tc.hi)
		for i := 0; i < 1000; i++ {
			result := ComputeShardKey(entityID)
			if result != tc.expected {
				t.Errorf("Iteration %d: ComputeShardKey(lo=0x%X, hi=0x%X) = 0x%X, want 0x%X",
					i, tc.lo, tc.hi, result, tc.expected)
			}
		}
	}
}

func TestGetShardForEntity(t *testing.T) {
	// Verify entity routing is deterministic.
	entityID := makeUint128(0xDEADBEEF, 0xCAFEBABE)

	shard1 := GetShardForEntity(entityID, 16)
	shard2 := GetShardForEntity(entityID, 16)
	shard3 := GetShardForEntity(entityID, 16)

	if shard1 != shard2 || shard2 != shard3 {
		t.Errorf("GetShardForEntity not deterministic: %d, %d, %d", shard1, shard2, shard3)
	}

	if shard1 >= 16 {
		t.Errorf("GetShardForEntity returned invalid shard %d (max 15)", shard1)
	}
}

func TestShardingStrategyString(t *testing.T) {
	tests := []struct {
		strategy ShardingStrategy
		expected string
	}{
		{ShardingStrategyModulo, "modulo"},
		{ShardingStrategyVirtualRing, "virtual_ring"},
		{ShardingStrategyJumpHash, "jump_hash"},
		{ShardingStrategy(99), "unknown"},
	}

	for _, tc := range tests {
		if tc.strategy.String() != tc.expected {
			t.Errorf("%d.String() = %q, want %q", tc.strategy, tc.strategy.String(), tc.expected)
		}
	}
}

func TestParseShardingStrategy(t *testing.T) {
	tests := []struct {
		input    string
		expected ShardingStrategy
		ok       bool
	}{
		{"modulo", ShardingStrategyModulo, true},
		{"virtual_ring", ShardingStrategyVirtualRing, true},
		{"jump_hash", ShardingStrategyJumpHash, true},
		{"invalid", 0, false},
	}

	for _, tc := range tests {
		strategy, ok := ParseShardingStrategy(tc.input)
		if ok != tc.ok {
			t.Errorf("ParseShardingStrategy(%q) ok = %v, want %v", tc.input, ok, tc.ok)
		}
		if ok && strategy != tc.expected {
			t.Errorf("ParseShardingStrategy(%q) = %d, want %d", tc.input, strategy, tc.expected)
		}
	}
}

func TestShardingStrategyRequiresPowerOfTwo(t *testing.T) {
	if !ShardingStrategyModulo.RequiresPowerOfTwo() {
		t.Error("Modulo strategy should require power of 2")
	}
	if ShardingStrategyVirtualRing.RequiresPowerOfTwo() {
		t.Error("VirtualRing strategy should not require power of 2")
	}
	if ShardingStrategyJumpHash.RequiresPowerOfTwo() {
		t.Error("JumpHash strategy should not require power of 2")
	}
}
