// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! SIMD-accelerated key comparison for RAM index batch operations.
//!
//! Uses Zig's @Vector for portable SIMD that compiles to AVX2/SSE
//! based on target CPU. Provides parallel key comparison for batch lookups.

const std = @import("std");

/// Number of keys to compare in parallel.
/// 4 keys * 16 bytes = 64 bytes = one cache line.
pub const batch_size: usize = 4;

/// Compare multiple keys against a target using SIMD.
/// Returns bitmask where bit N is set if keys[N] matches target.
///
/// Since u128 is too wide for most SIMD, we split into high/low u64
/// and compare both halves.
pub inline fn compare_keys(
    keys: *const [batch_size]u128,
    target: u128,
) u4 {
    // Split target into high and low halves
    const target_lo: u64 = @truncate(target);
    const target_hi: u64 = @truncate(target >> 64);

    // Load key halves into vectors
    var keys_lo: @Vector(batch_size, u64) = undefined;
    var keys_hi: @Vector(batch_size, u64) = undefined;

    inline for (0..batch_size) |i| {
        keys_lo[i] = @truncate(keys[i]);
        keys_hi[i] = @truncate(keys[i] >> 64);
    }

    // Splat target for parallel comparison
    const target_lo_vec: @Vector(batch_size, u64) = @splat(target_lo);
    const target_hi_vec: @Vector(batch_size, u64) = @splat(target_hi);

    // Compare both halves
    const match_lo = keys_lo == target_lo_vec;
    const match_hi = keys_hi == target_hi_vec;

    // Both halves must match - AND the bool vectors element-wise
    // Using @select: if match_lo is true, return match_hi, else false
    const false_vec: @Vector(batch_size, bool) = @splat(false);
    const match_both = @select(bool, match_lo, match_hi, false_vec);

    return @bitCast(match_both);
}

/// Scalar comparison fallback for verification and small batches.
pub inline fn compare_keys_scalar(
    keys: []const u128,
    target: u128,
) u64 {
    var result: u64 = 0;
    for (keys, 0..) |key, i| {
        if (key == target) {
            result |= (@as(u64, 1) << @intCast(i));
        }
    }
    return result;
}

/// Find first set bit in mask (0-based index).
/// Returns null if mask is zero.
pub inline fn find_first_match(mask: u4) ?u2 {
    if (mask == 0) return null;
    return @intCast(@ctz(mask));
}

// ============================================================================
// Tests
// ============================================================================

test "compare_keys: exact match in first position" {
    const keys = [_]u128{ 0x123, 0x456, 0x789, 0xABC };
    const result = compare_keys(&keys, 0x123);
    try std.testing.expectEqual(@as(u4, 0b0001), result);
}

test "compare_keys: exact match in last position" {
    const keys = [_]u128{ 0x123, 0x456, 0x789, 0xABC };
    const result = compare_keys(&keys, 0xABC);
    try std.testing.expectEqual(@as(u4, 0b1000), result);
}

test "compare_keys: no match" {
    const keys = [_]u128{ 0x123, 0x456, 0x789, 0xABC };
    const result = compare_keys(&keys, 0xDEF);
    try std.testing.expectEqual(@as(u4, 0b0000), result);
}

test "compare_keys: multiple matches" {
    const keys = [_]u128{ 0x123, 0x456, 0x123, 0xABC };
    const result = compare_keys(&keys, 0x123);
    try std.testing.expectEqual(@as(u4, 0b0101), result);
}

test "compare_keys: large u128 values" {
    const keys = [_]u128{
        0xFFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFF,
        0x12345678_9ABCDEF0_12345678_9ABCDEF0,
        0x0,
        0x1,
    };
    const result = compare_keys(&keys, 0x12345678_9ABCDEF0_12345678_9ABCDEF0);
    try std.testing.expectEqual(@as(u4, 0b0010), result);
}

test "find_first_match: finds first bit" {
    try std.testing.expectEqual(@as(?u2, 0), find_first_match(0b0001));
    try std.testing.expectEqual(@as(?u2, 1), find_first_match(0b0010));
    try std.testing.expectEqual(@as(?u2, 2), find_first_match(0b0100));
    try std.testing.expectEqual(@as(?u2, 3), find_first_match(0b1000));
    try std.testing.expectEqual(@as(?u2, 0), find_first_match(0b1111));
    try std.testing.expectEqual(@as(?u2, null), find_first_match(0b0000));
}

test "compare_keys_scalar: matches simd version" {
    const keys = [_]u128{ 0x123, 0x456, 0x789, 0xABC };
    const simd_result = compare_keys(&keys, 0x456);
    const scalar_result: u4 = @truncate(compare_keys_scalar(&keys, 0x456));
    try std.testing.expectEqual(simd_result, scalar_result);
}
