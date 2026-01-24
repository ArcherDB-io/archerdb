// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Block-level compression primitives for LSM storage optimization.
//!
//! This module provides LZ4 compression for value blocks, reducing storage footprint
//! by 40-60% for typical geospatial workloads. LZ4 is chosen for its exceptional
//! decompression speed, critical for latency-sensitive queries.
//!
//! Design decisions:
//! - Compression is applied at block granularity for random access
//! - Only compress if savings exceed 10% (90% threshold) to avoid overhead
//! - Index blocks remain uncompressed for fast key lookups
//!
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const lz4 = @cImport({
    @cInclude("lz4.h");
});

/// Compression algorithm type stored in block headers.
/// Uses 4 bits to fit in reserved metadata space.
pub const CompressionType = enum(u4) {
    /// No compression - data stored as-is
    none = 0,
    /// LZ4 fast compression
    lz4 = 1,
    // Reserved for future expansion:
    // zstd = 2,

    /// Returns true if this compression type requires decompression.
    pub fn is_compressed(self: CompressionType) bool {
        return self != .none;
    }
};

/// Result of a block compression operation.
pub const CompressionResult = struct {
    /// Number of bytes in the compressed output
    compressed_size: usize,
    /// Compression algorithm used (may be .none if compression didn't help)
    compression_type: CompressionType,
};

/// Compression threshold: only use compression if output is <= 90% of input.
/// This avoids overhead for incompressible data (random bytes, already compressed).
const compression_threshold_percent: usize = 90;

/// Compress a block of data using LZ4.
///
/// If compression doesn't achieve at least 10% space savings, returns the data
/// uncompressed (copies input to output) with CompressionType.none.
///
/// Parameters:
/// - input: The uncompressed data to compress
/// - output: Buffer to write compressed data. Must be at least max_compressed_size(input.len)
///
/// Returns: CompressionResult with compressed size and type used
pub fn compress_block(input: []const u8, output: []u8) CompressionResult {
    if (input.len == 0) {
        return .{
            .compressed_size = 0,
            .compression_type = .none,
        };
    }

    // Ensure output buffer is large enough for worst-case LZ4 output
    assert(output.len >= max_compressed_size(input.len));

    // Attempt LZ4 compression
    const compressed_size = lz4.LZ4_compress_default(
        input.ptr,
        output.ptr,
        @intCast(input.len),
        @intCast(output.len),
    );

    // LZ4_compress_default returns 0 on failure
    if (compressed_size <= 0) {
        // Compression failed - fall back to no compression
        @memcpy(output[0..input.len], input);
        return .{
            .compressed_size = input.len,
            .compression_type = .none,
        };
    }

    const compressed_usize: usize = @intCast(compressed_size);

    // Check if compression achieved sufficient savings
    const threshold = (input.len * compression_threshold_percent) / 100;
    if (compressed_usize > threshold) {
        // Compression didn't help enough - store uncompressed
        @memcpy(output[0..input.len], input);
        return .{
            .compressed_size = input.len,
            .compression_type = .none,
        };
    }

    return .{
        .compressed_size = compressed_usize,
        .compression_type = .lz4,
    };
}

/// Decompression error when LZ4 fails to decompress data.
pub const DecompressionError = error{
    DecompressionFailed,
};

/// Decompress a block of data.
///
/// Parameters:
/// - input: The compressed data
/// - output: Buffer to write decompressed data. Must be at least `original_size`
/// - compression_type: The compression algorithm used
/// - original_size: The original uncompressed size
///
/// Returns: The decompressed data slice, or error if decompression fails
pub fn decompress_block(
    input: []const u8,
    output: []u8,
    compression_type: CompressionType,
    original_size: usize,
) DecompressionError![]u8 {
    assert(output.len >= original_size);

    switch (compression_type) {
        .none => {
            // No compression - just copy
            assert(input.len == original_size);
            @memcpy(output[0..original_size], input);
            return output[0..original_size];
        },
        .lz4 => {
            // LZ4 decompression
            const decompressed_size = lz4.LZ4_decompress_safe(
                input.ptr,
                output.ptr,
                @intCast(input.len),
                @intCast(output.len),
            );

            // LZ4_decompress_safe returns negative on error
            if (decompressed_size < 0) {
                return error.DecompressionFailed;
            }

            const decompressed_usize: usize = @intCast(decompressed_size);
            if (decompressed_usize != original_size) {
                return error.DecompressionFailed;
            }

            return output[0..decompressed_usize];
        },
    }
}

/// Returns the maximum possible size of compressed output for a given input length.
/// Use this to allocate output buffers for compress_block.
pub fn max_compressed_size(input_len: usize) usize {
    if (input_len == 0) return 0;
    // LZ4_compressBound returns the maximum output size
    const bound = lz4.LZ4_compressBound(@intCast(input_len));
    return @intCast(bound);
}

/// Returns true if the compression type indicates the data needs decompression.
pub fn is_compressible(compression_type: CompressionType) bool {
    return compression_type.is_compressed();
}

// ============================================================================
// Unit Tests
// ============================================================================

test "compression: round-trip with compressible data" {
    const allocator = std.testing.allocator;

    // Create compressible data (repeated pattern)
    const original_size: usize = 64 * 1024; // 64 KiB typical block size
    const original = try allocator.alloc(u8, original_size);
    defer allocator.free(original);

    // Fill with repeating pattern (highly compressible)
    for (original, 0..) |*byte, i| {
        byte.* = @truncate(i % 256);
    }

    // Compress
    const compressed_buf = try allocator.alloc(u8, max_compressed_size(original_size));
    defer allocator.free(compressed_buf);

    const result = compress_block(original, compressed_buf);

    // Should achieve compression
    try std.testing.expect(result.compression_type == .lz4);
    try std.testing.expect(result.compressed_size < original_size);

    // Decompress
    const decompressed_buf = try allocator.alloc(u8, original_size);
    defer allocator.free(decompressed_buf);

    const decompressed = try decompress_block(
        compressed_buf[0..result.compressed_size],
        decompressed_buf,
        result.compression_type,
        original_size,
    );

    // Verify round-trip
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "compression: incompressible data falls back to none" {
    const allocator = std.testing.allocator;

    // Create incompressible data (random bytes)
    const original_size: usize = 4096;
    const original = try allocator.alloc(u8, original_size);
    defer allocator.free(original);

    // Fill with pseudo-random data (incompressible)
    var prng = std.Random.DefaultPrng.init(12345);
    prng.fill(original);

    // Compress
    const compressed_buf = try allocator.alloc(u8, max_compressed_size(original_size));
    defer allocator.free(compressed_buf);

    const result = compress_block(original, compressed_buf);

    // Should fall back to no compression
    try std.testing.expect(result.compression_type == .none);
    try std.testing.expect(result.compressed_size == original_size);

    // Decompress (which is just a copy for .none)
    const decompressed_buf = try allocator.alloc(u8, original_size);
    defer allocator.free(decompressed_buf);

    const decompressed = try decompress_block(
        compressed_buf[0..result.compressed_size],
        decompressed_buf,
        result.compression_type,
        original_size,
    );

    // Verify round-trip
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "compression: small block round-trip" {
    const allocator = std.testing.allocator;

    // Test with small data
    const original = "Hello, ArcherDB compression! This is a test of LZ4 block compression.";

    // Compress
    const compressed_buf = try allocator.alloc(u8, max_compressed_size(original.len));
    defer allocator.free(compressed_buf);

    const result = compress_block(original, compressed_buf);

    // Decompress
    const decompressed_buf = try allocator.alloc(u8, original.len);
    defer allocator.free(decompressed_buf);

    const decompressed = try decompress_block(
        compressed_buf[0..result.compressed_size],
        decompressed_buf,
        result.compression_type,
        original.len,
    );

    // Verify round-trip
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "compression: empty input" {
    var output_buf: [16]u8 = undefined;

    const result = compress_block(&[_]u8{}, &output_buf);

    try std.testing.expect(result.compressed_size == 0);
    try std.testing.expect(result.compression_type == .none);
}

test "compression: max_compressed_size" {
    // Verify max_compressed_size returns reasonable values
    try std.testing.expect(max_compressed_size(0) == 0);
    try std.testing.expect(max_compressed_size(100) > 100);
    try std.testing.expect(max_compressed_size(64 * 1024) > 64 * 1024);
}

test "compression: is_compressible helper" {
    try std.testing.expect(!is_compressible(.none));
    try std.testing.expect(is_compressible(.lz4));
}

test "compression: CompressionType.is_compressed" {
    try std.testing.expect(!CompressionType.none.is_compressed());
    try std.testing.expect(CompressionType.lz4.is_compressed());
}

test "compression: various block sizes" {
    const allocator = std.testing.allocator;

    // Test various block sizes
    const sizes = [_]usize{ 512, 1024, 4096, 8192, 16384, 32768, 65536 };

    for (sizes) |size| {
        const original = try allocator.alloc(u8, size);
        defer allocator.free(original);

        // Fill with compressible pattern
        for (original, 0..) |*byte, i| {
            byte.* = @truncate((i * 7) % 256);
        }

        const compressed_buf = try allocator.alloc(u8, max_compressed_size(size));
        defer allocator.free(compressed_buf);

        const result = compress_block(original, compressed_buf);

        const decompressed_buf = try allocator.alloc(u8, size);
        defer allocator.free(decompressed_buf);

        const decompressed = try decompress_block(
            compressed_buf[0..result.compressed_size],
            decompressed_buf,
            result.compression_type,
            size,
        );

        try std.testing.expectEqualSlices(u8, original, decompressed);
    }
}
