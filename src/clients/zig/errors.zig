// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! ArcherDB Zig SDK - Error types
//!
//! This module defines the error types used by the ArcherDB Zig SDK.
//! Following Zig idioms, we use error unions (`!T`) for fallible operations.

const std = @import("std");

/// ClientError encompasses all errors that can occur during client operations.
/// Use Zig's error handling pattern: `client.queryRadius(allocator, filter) catch |err| ...`
pub const ClientError = error{
    /// Failed to establish connection to any cluster node.
    /// Retryable: yes
    ConnectionFailed,

    /// Connection attempt timed out.
    /// Retryable: yes
    ConnectionTimeout,

    /// Cluster is not accepting requests (no quorum, leader election in progress).
    /// Retryable: yes (after brief delay)
    ClusterUnavailable,

    /// Coordinates are outside valid ranges.
    /// Latitude must be [-90, +90], longitude must be [-180, +180].
    /// Retryable: no (fix the coordinates)
    InvalidCoordinates,

    /// Batch exceeds maximum size (10,000 events).
    /// Retryable: no (reduce batch size)
    BatchTooLarge,

    /// Entity ID is invalid (e.g., zero).
    /// Retryable: no (provide valid entity ID)
    InvalidEntityId,

    /// Entity has expired due to TTL.
    /// Retryable: no
    EntityExpired,

    /// Operation exceeded configured timeout.
    /// Retryable: yes
    OperationTimeout,

    /// Query limit exceeds maximum (81,000).
    /// Retryable: no (reduce limit, use pagination)
    QueryResultTooLarge,

    /// Operations attempted on a closed client.
    /// Retryable: no (create new client)
    ClientClosed,

    /// Server returned an invalid or unexpected response.
    /// Retryable: maybe (could be transient)
    InvalidResponse,

    /// Failed to parse JSON response.
    /// Retryable: no (likely protocol error)
    JsonParseError,

    /// HTTP request failed (non-2xx status code).
    /// Retryable: depends on status code
    HttpError,

    /// Failed to allocate memory.
    /// Retryable: no (OOM condition)
    OutOfMemory,

    /// URL construction or parsing failed.
    /// Retryable: no (invalid URL)
    InvalidUrl,

    /// TLS/SSL error.
    /// Retryable: maybe
    TlsError,

    /// Server returned "not shard leader" error.
    /// Retryable: yes (SDK should auto-retry with correct node)
    NotShardLeader,

    /// Polygon has too many vertices or holes.
    /// Retryable: no (simplify polygon)
    PolygonTooComplex,

    /// Polygon is self-intersecting or invalid.
    /// Retryable: no (fix polygon)
    InvalidPolygon,
};

/// Check if an error is retryable.
/// Retryable errors are typically transient network or cluster issues.
pub fn isRetryable(err: ClientError) bool {
    return switch (err) {
        .ConnectionFailed,
        .ConnectionTimeout,
        .ClusterUnavailable,
        .OperationTimeout,
        .NotShardLeader,
        => true,

        .InvalidCoordinates,
        .BatchTooLarge,
        .InvalidEntityId,
        .EntityExpired,
        .QueryResultTooLarge,
        .ClientClosed,
        .InvalidResponse,
        .JsonParseError,
        .OutOfMemory,
        .InvalidUrl,
        .PolygonTooComplex,
        .InvalidPolygon,
        => false,

        // These depend on the specific situation
        .HttpError => true, // Usually transient
        .TlsError => false, // Usually configuration issue
    };
}

/// Check if an error is a network-related error.
pub fn isNetworkError(err: ClientError) bool {
    return switch (err) {
        .ConnectionFailed,
        .ConnectionTimeout,
        .ClusterUnavailable,
        .OperationTimeout,
        .HttpError,
        .TlsError,
        .NotShardLeader,
        => true,
        else => false,
    };
}

/// Check if an error is a validation error (client-side issue).
pub fn isValidationError(err: ClientError) bool {
    return switch (err) {
        .InvalidCoordinates,
        .BatchTooLarge,
        .InvalidEntityId,
        .QueryResultTooLarge,
        .InvalidUrl,
        .PolygonTooComplex,
        .InvalidPolygon,
        => true,
        else => false,
    };
}

/// Get a human-readable error message for a ClientError.
pub fn errorMessage(err: ClientError) []const u8 {
    return switch (err) {
        .ConnectionFailed => "Failed to establish connection to cluster",
        .ConnectionTimeout => "Connection attempt timed out",
        .ClusterUnavailable => "Cluster is unavailable (no quorum)",
        .InvalidCoordinates => "Coordinates are outside valid ranges",
        .BatchTooLarge => "Batch exceeds maximum size (10,000 events)",
        .InvalidEntityId => "Entity ID is invalid (must not be zero)",
        .EntityExpired => "Entity has expired due to TTL",
        .OperationTimeout => "Operation timed out",
        .QueryResultTooLarge => "Query limit exceeds maximum (81,000)",
        .ClientClosed => "Client has been closed",
        .InvalidResponse => "Server returned invalid response",
        .JsonParseError => "Failed to parse JSON response",
        .HttpError => "HTTP request failed",
        .OutOfMemory => "Out of memory",
        .InvalidUrl => "Invalid URL",
        .TlsError => "TLS/SSL error",
        .NotShardLeader => "Not shard leader (auto-retry in progress)",
        .PolygonTooComplex => "Polygon has too many vertices or holes",
        .InvalidPolygon => "Polygon is self-intersecting or invalid",
    };
}

/// Error code for protocol compatibility.
pub fn errorCode(err: ClientError) u16 {
    return switch (err) {
        .ConnectionFailed => 1001,
        .ConnectionTimeout => 1002,
        .ClusterUnavailable => 2001,
        .InvalidCoordinates => 3001,
        .BatchTooLarge => 3003,
        .InvalidEntityId => 3004,
        .EntityExpired => 210,
        .OperationTimeout => 4001,
        .QueryResultTooLarge => 4002,
        .ClientClosed => 5001,
        .InvalidResponse => 5003,
        .JsonParseError => 5004,
        .HttpError => 5005,
        .OutOfMemory => 5006,
        .InvalidUrl => 5007,
        .TlsError => 5008,
        .NotShardLeader => 220,
        .PolygonTooComplex => 102,
        .InvalidPolygon => 103,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "isRetryable" {
    try std.testing.expect(isRetryable(.ConnectionFailed));
    try std.testing.expect(isRetryable(.ConnectionTimeout));
    try std.testing.expect(isRetryable(.ClusterUnavailable));
    try std.testing.expect(isRetryable(.OperationTimeout));

    try std.testing.expect(!isRetryable(.InvalidCoordinates));
    try std.testing.expect(!isRetryable(.BatchTooLarge));
    try std.testing.expect(!isRetryable(.ClientClosed));
}

test "isNetworkError" {
    try std.testing.expect(isNetworkError(.ConnectionFailed));
    try std.testing.expect(isNetworkError(.ConnectionTimeout));
    try std.testing.expect(isNetworkError(.HttpError));

    try std.testing.expect(!isNetworkError(.InvalidCoordinates));
    try std.testing.expect(!isNetworkError(.JsonParseError));
}

test "isValidationError" {
    try std.testing.expect(isValidationError(.InvalidCoordinates));
    try std.testing.expect(isValidationError(.BatchTooLarge));
    try std.testing.expect(isValidationError(.InvalidEntityId));

    try std.testing.expect(!isValidationError(.ConnectionFailed));
    try std.testing.expect(!isValidationError(.HttpError));
}

test "errorMessage" {
    const msg = errorMessage(.ConnectionFailed);
    try std.testing.expect(msg.len > 0);
}

test "errorCode" {
    try std.testing.expectEqual(@as(u16, 1001), errorCode(.ConnectionFailed));
    try std.testing.expectEqual(@as(u16, 3001), errorCode(.InvalidCoordinates));
    try std.testing.expectEqual(@as(u16, 210), errorCode(.EntityExpired));
}
