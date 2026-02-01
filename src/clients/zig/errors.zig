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
        error.ConnectionFailed => true,
        error.ConnectionTimeout => true,
        error.ClusterUnavailable => true,
        error.OperationTimeout => true,
        error.NotShardLeader => true,
        error.HttpError => true, // Usually transient
        error.InvalidCoordinates => false,
        error.BatchTooLarge => false,
        error.InvalidEntityId => false,
        error.EntityExpired => false,
        error.QueryResultTooLarge => false,
        error.ClientClosed => false,
        error.InvalidResponse => false,
        error.JsonParseError => false,
        error.OutOfMemory => false,
        error.InvalidUrl => false,
        error.TlsError => false, // Usually configuration issue
        error.PolygonTooComplex => false,
        error.InvalidPolygon => false,
    };
}

/// Check if an error is a network-related error.
pub fn isNetworkError(err: ClientError) bool {
    return switch (err) {
        error.ConnectionFailed => true,
        error.ConnectionTimeout => true,
        error.ClusterUnavailable => true,
        error.OperationTimeout => true,
        error.HttpError => true,
        error.TlsError => true,
        error.NotShardLeader => true,
        else => false,
    };
}

/// Check if an error is a validation error (client-side issue).
pub fn isValidationError(err: ClientError) bool {
    return switch (err) {
        error.InvalidCoordinates => true,
        error.BatchTooLarge => true,
        error.InvalidEntityId => true,
        error.QueryResultTooLarge => true,
        error.InvalidUrl => true,
        error.PolygonTooComplex => true,
        error.InvalidPolygon => true,
        else => false,
    };
}

/// Get a human-readable error message for a ClientError.
pub fn errorMessage(err: ClientError) []const u8 {
    return switch (err) {
        error.ConnectionFailed => "Failed to establish connection to cluster",
        error.ConnectionTimeout => "Connection attempt timed out",
        error.ClusterUnavailable => "Cluster is unavailable (no quorum)",
        error.InvalidCoordinates => "Coordinates are outside valid ranges",
        error.BatchTooLarge => "Batch exceeds maximum size (10,000 events)",
        error.InvalidEntityId => "Entity ID is invalid (must not be zero)",
        error.EntityExpired => "Entity has expired due to TTL",
        error.OperationTimeout => "Operation timed out",
        error.QueryResultTooLarge => "Query limit exceeds maximum (81,000)",
        error.ClientClosed => "Client has been closed",
        error.InvalidResponse => "Server returned invalid response",
        error.JsonParseError => "Failed to parse JSON response",
        error.HttpError => "HTTP request failed",
        error.OutOfMemory => "Out of memory",
        error.InvalidUrl => "Invalid URL",
        error.TlsError => "TLS/SSL error",
        error.NotShardLeader => "Not shard leader (auto-retry in progress)",
        error.PolygonTooComplex => "Polygon has too many vertices or holes",
        error.InvalidPolygon => "Polygon is self-intersecting or invalid",
    };
}

/// Error code for protocol compatibility.
pub fn errorCode(err: ClientError) u16 {
    return switch (err) {
        error.ConnectionFailed => 1001,
        error.ConnectionTimeout => 1002,
        error.ClusterUnavailable => 2001,
        error.InvalidCoordinates => 3001,
        error.BatchTooLarge => 3003,
        error.InvalidEntityId => 3004,
        error.EntityExpired => 210,
        error.OperationTimeout => 4001,
        error.QueryResultTooLarge => 4002,
        error.ClientClosed => 5001,
        error.InvalidResponse => 5003,
        error.JsonParseError => 5004,
        error.HttpError => 5005,
        error.OutOfMemory => 5006,
        error.InvalidUrl => 5007,
        error.TlsError => 5008,
        error.NotShardLeader => 220,
        error.PolygonTooComplex => 102,
        error.InvalidPolygon => 103,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "isRetryable" {
    try std.testing.expect(isRetryable(error.ConnectionFailed));
    try std.testing.expect(isRetryable(error.ConnectionTimeout));
    try std.testing.expect(isRetryable(error.ClusterUnavailable));
    try std.testing.expect(isRetryable(error.OperationTimeout));

    try std.testing.expect(!isRetryable(error.InvalidCoordinates));
    try std.testing.expect(!isRetryable(error.BatchTooLarge));
    try std.testing.expect(!isRetryable(error.ClientClosed));
}

test "isNetworkError" {
    try std.testing.expect(isNetworkError(error.ConnectionFailed));
    try std.testing.expect(isNetworkError(error.ConnectionTimeout));
    try std.testing.expect(isNetworkError(error.HttpError));

    try std.testing.expect(!isNetworkError(error.InvalidCoordinates));
    try std.testing.expect(!isNetworkError(error.JsonParseError));
}

test "isValidationError" {
    try std.testing.expect(isValidationError(error.InvalidCoordinates));
    try std.testing.expect(isValidationError(error.BatchTooLarge));
    try std.testing.expect(isValidationError(error.InvalidEntityId));

    try std.testing.expect(!isValidationError(error.ConnectionFailed));
    try std.testing.expect(!isValidationError(error.HttpError));
}

test "errorMessage" {
    const msg = errorMessage(error.ConnectionFailed);
    try std.testing.expect(msg.len > 0);
}

test "errorCode" {
    try std.testing.expectEqual(@as(u16, 1001), errorCode(error.ConnectionFailed));
    try std.testing.expectEqual(@as(u16, 3001), errorCode(error.InvalidCoordinates));
    try std.testing.expectEqual(@as(u16, 210), errorCode(error.EntityExpired));
}
