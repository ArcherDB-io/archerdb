# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 Anthus Labs, Inc.

"""
Jump Consistent Hash Golden Vector Tests

Source of truth: src/sharding.zig - these values MUST match exactly.
Reference: https://research.google/pubs/pub44824/
"""

import unittest
from .types import (
    jump_hash,
    compute_shard_key,
    get_shard_for_entity,
    ShardingStrategy,
)


class TestJumpHashGoldenVectors(unittest.TestCase):
    """Golden vector tests for cross-SDK compatibility."""

    def test_key_0(self):
        """Key 0 always maps to bucket 0."""
        self.assertEqual(jump_hash(0, 1), 0)
        self.assertEqual(jump_hash(0, 10), 0)
        self.assertEqual(jump_hash(0, 100), 0)
        self.assertEqual(jump_hash(0, 256), 0)

    def test_key_deadbeef(self):
        """Key 0xDEADBEEF canonical test vectors."""
        self.assertEqual(jump_hash(0xDEADBEEF, 8), 5)
        self.assertEqual(jump_hash(0xDEADBEEF, 16), 5)
        self.assertEqual(jump_hash(0xDEADBEEF, 32), 16)
        self.assertEqual(jump_hash(0xDEADBEEF, 64), 16)
        self.assertEqual(jump_hash(0xDEADBEEF, 128), 87)
        self.assertEqual(jump_hash(0xDEADBEEF, 256), 87)

    def test_key_cafebabe(self):
        """Key 0xCAFEBABE canonical test vectors."""
        self.assertEqual(jump_hash(0xCAFEBABE, 8), 5)
        self.assertEqual(jump_hash(0xCAFEBABE, 16), 5)
        self.assertEqual(jump_hash(0xCAFEBABE, 32), 5)
        self.assertEqual(jump_hash(0xCAFEBABE, 64), 46)
        self.assertEqual(jump_hash(0xCAFEBABE, 128), 85)
        self.assertEqual(jump_hash(0xCAFEBABE, 256), 85)

    def test_key_max_u64(self):
        """Key 0xFFFFFFFFFFFFFFFF edge case."""
        self.assertEqual(jump_hash(0xFFFFFFFFFFFFFFFF, 8), 7)
        self.assertEqual(jump_hash(0xFFFFFFFFFFFFFFFF, 16), 10)
        self.assertEqual(jump_hash(0xFFFFFFFFFFFFFFFF, 256), 248)

    def test_additional_keys(self):
        """Additional test keys for coverage."""
        self.assertEqual(jump_hash(0x123456789ABCDEF0, 8), 4)
        self.assertEqual(jump_hash(0x123456789ABCDEF0, 16), 4)
        self.assertEqual(jump_hash(0x123456789ABCDEF0, 256), 33)

        self.assertEqual(jump_hash(0xFEDCBA9876543210, 8), 1)
        self.assertEqual(jump_hash(0xFEDCBA9876543210, 16), 10)
        self.assertEqual(jump_hash(0xFEDCBA9876543210, 256), 143)


class TestJumpHashDeterminism(unittest.TestCase):
    """Verify jump_hash is deterministic over multiple iterations."""

    def test_determinism_1000_iterations(self):
        """Same key+buckets always produces same result."""
        test_cases = [
            (0xDEADBEEF, 16, 5),
            (0xCAFEBABE, 64, 46),
            (0x123456789ABCDEF0, 256, 33),
            (0xFFFFFFFFFFFFFFFF, 8, 7),
        ]

        for key, buckets, expected in test_cases:
            for _ in range(1000):
                result = jump_hash(key, buckets)
                self.assertEqual(
                    result, expected,
                    f"jump_hash(0x{key:X}, {buckets}) = {result}, want {expected}"
                )


class TestComputeShardKeyGoldenVectors(unittest.TestCase):
    """Golden vector tests for compute_shard_key."""

    def test_entity_1(self):
        """Entity ID 1."""
        entity_id = 0x00000000_00000000_00000000_00000001
        self.assertEqual(compute_shard_key(entity_id), 0xB456BCFC34C2CB2C)

    def test_entity_deadbeef_cafebabe(self):
        """Entity ID with DEADBEEF/CAFEBABE pattern."""
        entity_id = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0
        self.assertEqual(compute_shard_key(entity_id), 0x683A5932FE04E714)

    def test_entity_max(self):
        """Max entity ID."""
        entity_id = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF
        self.assertEqual(compute_shard_key(entity_id), 0x0000000000000000)

    def test_entity_symmetric(self):
        """Symmetric entity ID."""
        entity_id = 0x12345678_ABCDEF00_12345678_ABCDEF00
        self.assertEqual(compute_shard_key(entity_id), 0x0000000000000000)


class TestComputeShardKeyDeterminism(unittest.TestCase):
    """Verify compute_shard_key is deterministic."""

    def test_determinism_1000_iterations(self):
        """Same entity_id always produces same shard_key."""
        test_cases = [
            (0x00000000_00000000_00000000_00000001, 0xB456BCFC34C2CB2C),
            (0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0, 0x683A5932FE04E714),
        ]

        for entity_id, expected in test_cases:
            for _ in range(1000):
                result = compute_shard_key(entity_id)
                self.assertEqual(
                    result, expected,
                    f"compute_shard_key(0x{entity_id:032X}) = 0x{result:016X}, want 0x{expected:016X}"
                )


class TestGetShardForEntity(unittest.TestCase):
    """Verify get_shard_for_entity is deterministic."""

    def test_deterministic_routing(self):
        """Same entity always routes to same shard."""
        entity_id = 0xDEADBEEF_00000000_CAFEBABE_00000000

        shard1 = get_shard_for_entity(entity_id, 16)
        shard2 = get_shard_for_entity(entity_id, 16)
        shard3 = get_shard_for_entity(entity_id, 16)

        self.assertEqual(shard1, shard2)
        self.assertEqual(shard2, shard3)
        self.assertLess(shard1, 16)


class TestShardingStrategy(unittest.TestCase):
    """Test ShardingStrategy enum."""

    def test_string_conversion(self):
        """Test string conversion."""
        self.assertEqual(ShardingStrategy.MODULO.to_string(), "modulo")
        self.assertEqual(ShardingStrategy.VIRTUAL_RING.to_string(), "virtual_ring")
        self.assertEqual(ShardingStrategy.JUMP_HASH.to_string(), "jump_hash")

    def test_parse_string(self):
        """Test parsing from string."""
        self.assertEqual(ShardingStrategy.from_string("modulo"), ShardingStrategy.MODULO)
        self.assertEqual(ShardingStrategy.from_string("virtual_ring"), ShardingStrategy.VIRTUAL_RING)
        self.assertEqual(ShardingStrategy.from_string("jump_hash"), ShardingStrategy.JUMP_HASH)

    def test_requires_power_of_two(self):
        """Test power-of-two requirement."""
        self.assertTrue(ShardingStrategy.MODULO.requires_power_of_two())
        self.assertFalse(ShardingStrategy.VIRTUAL_RING.requires_power_of_two())
        self.assertFalse(ShardingStrategy.JUMP_HASH.requires_power_of_two())


if __name__ == "__main__":
    unittest.main()
