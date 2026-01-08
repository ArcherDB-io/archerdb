// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! ArcherDB Error Codes (F1.2.4)
//!
//! Defines system-wide error codes for ArcherDB operations.
//! These codes follow the ranges defined in:
//! openspec/changes/add-geospatial-core/specs/error-codes/spec.md
//!
//! Error Code Ranges:
//!   - 1-10:     Protocol errors
//!   - 100-120:  Validation errors (117-120: polygon hole errors)
//!   - 200-212:  State errors
//!   - 300-310:  Resource errors
//!   - 400-404:  Security errors
//!   - 500-504:  Internal errors

const std = @import("std");

/// Protocol error codes (1-10)
/// These errors indicate protocol-level issues with message format.
pub const ProtocolError = enum(u32) {
    /// Message format is invalid
    invalid_message = 1,
    /// Header checksum verification failed
    checksum_mismatch_header = 2,
    /// Body checksum verification failed
    checksum_mismatch_body = 3,
    /// Message exceeds message_size_max
    message_too_large = 4,
    /// Message smaller than header size
    message_too_small = 5,
    /// Protocol version not supported
    unsupported_version = 6,
    /// Operation code not recognized
    invalid_operation = 7,
    /// Message cluster ID does not match
    cluster_id_mismatch = 8,
    /// Magic number incorrect (not "ARCH")
    invalid_magic = 9,
    /// Reserved field contains non-zero data
    reserved_field_nonzero = 10,

    /// Returns a human-readable description of the error.
    pub fn description(self: ProtocolError) []const u8 {
        return switch (self) {
            .invalid_message => "Message format is invalid",
            .checksum_mismatch_header => "Header checksum verification failed",
            .checksum_mismatch_body => "Body checksum verification failed",
            .message_too_large => "Message exceeds maximum size",
            .message_too_small => "Message smaller than header size",
            .unsupported_version => "Protocol version not supported",
            .invalid_operation => "Operation code not recognized",
            .cluster_id_mismatch => "Cluster ID mismatch",
            .invalid_magic => "Invalid magic number (expected ARCH)",
            .reserved_field_nonzero => "Reserved field contains non-zero data",
        };
    }

    /// Protocol errors are retriable if they're checksum-related (transient network issues).
    pub fn isRetriable(self: ProtocolError) bool {
        return switch (self) {
            .checksum_mismatch_header, .checksum_mismatch_body => true,
            else => false,
        };
    }
};

/// Validation error codes (100-116)
/// These errors indicate invalid input data.
pub const ValidationError = enum(u32) {
    /// lat_nano=95,000,000,000 (95° > 90° max)
    invalid_coordinates = 100,
    /// timestamp=maxInt(u64)-1000, ttl_seconds=2000 (overflow)
    ttl_overflow = 101,
    /// ttl_seconds=maxInt(u32)+1 (type prevents in Zig)
    invalid_ttl = 102,
    /// entity_id=null or malformed UUID
    invalid_entity_id = 103,
    /// batch_size=15,000 (exceeds 10,000 limit)
    invalid_batch_size = 104,
    /// Reserved - empty batches are valid no-ops
    reserved_105 = 105,
    /// s2_cell_id with invalid level encoding
    invalid_s2_cell = 106,
    /// radius_meters=2,000,000 (exceeds 1,000,000 max)
    invalid_radius = 107,
    /// Generic polygon error with malformed input
    invalid_polygon = 108,
    /// Bowtie polygon (edges cross)
    polygon_self_intersecting = 109,
    /// radius_meters=0 (use UUID query instead)
    radius_zero = 110,
    /// Polygon spanning 360° longitude
    polygon_too_large = 111,
    /// All 3+ vertices on same line (zero area)
    polygon_degenerate = 112,
    /// vertex_count=0
    polygon_empty = 113,
    /// Manually set ID not matching lat/lon
    coordinate_mismatch = 114,
    /// event_timestamp > current_time + 60s
    timestamp_in_future = 115,
    /// event_timestamp < current_time - max_age
    timestamp_too_old = 116,
    /// hole_count exceeds polygon_holes_max (100)
    too_many_holes = 117,
    /// Hole has fewer than 3 vertices (minimum for valid ring)
    hole_vertex_count_invalid = 118,
    /// Hole ring is not contained within outer ring
    hole_not_contained = 119,
    /// Two or more hole rings overlap
    holes_overlap = 120,

    /// Returns a human-readable description of the error.
    pub fn description(self: ValidationError) []const u8 {
        return switch (self) {
            .invalid_coordinates => "Coordinates out of range (lat: -90..90, lon: -180..180)",
            .ttl_overflow => "TTL calculation would overflow timestamp",
            .invalid_ttl => "TTL value exceeds maximum allowed",
            .invalid_entity_id => "Entity ID is null or malformed",
            .invalid_batch_size => "Batch size exceeds maximum (10,000)",
            .reserved_105 => "Reserved error code",
            .invalid_s2_cell => "S2 cell ID has invalid level encoding",
            .invalid_radius => "Radius exceeds maximum (1,000,000 meters)",
            .invalid_polygon => "Polygon has malformed input",
            .polygon_self_intersecting => "Polygon edges cross (bowtie shape)",
            .radius_zero => "Zero radius - use UUID query instead",
            .polygon_too_large => "Polygon spans 360 degrees longitude",
            .polygon_degenerate => "Polygon vertices are collinear (zero area)",
            .polygon_empty => "Polygon has no vertices",
            .coordinate_mismatch => "Manually set ID does not match coordinates",
            .timestamp_in_future => "Event timestamp is too far in future",
            .timestamp_too_old => "Event timestamp is too old",
            .too_many_holes => "Polygon has too many holes (max 100)",
            .hole_vertex_count_invalid => "Hole has fewer than 3 vertices",
            .hole_not_contained => "Hole ring is not contained within outer ring",
            .holes_overlap => "Two or more hole rings overlap",
        };
    }
};

/// State error codes (200-209)
/// These errors indicate system state issues.
pub const StateError = enum(u32) {
    /// Query UUID that doesn't exist in index
    entity_not_found = 200,
    /// Cluster is unavailable (quorum lost)
    cluster_unavailable = 201,
    /// View change in progress
    view_change_in_progress = 202,
    /// Write sent to backup replica
    not_primary = 203,
    /// Session ID has been evicted
    session_expired = 204,
    /// Duplicate (client_id, request) pair
    duplicate_request = 205,
    /// Request snapshot older than compacted
    stale_read = 206,
    /// Query during checkpoint write
    checkpoint_in_progress = 207,
    /// Storage is unavailable
    storage_unavailable = 208,
    /// Index rebuilding during cold start
    index_rebuilding = 209,
    /// Entity has expired due to TTL
    entity_expired = 210,
    /// Internal resource pool exhausted
    resource_exhausted = 211,
    /// Writes halted pending backup (mandatory mode)
    backup_required = 212,

    pub fn description(self: StateError) []const u8 {
        return switch (self) {
            .entity_not_found => "Entity not found in index",
            .cluster_unavailable => "Cluster is unavailable - quorum lost",
            .view_change_in_progress => "View change is in progress",
            .not_primary => "Node is not the primary replica",
            .session_expired => "Client session has expired",
            .duplicate_request => "Duplicate request detected",
            .stale_read => "Requested snapshot has been compacted",
            .checkpoint_in_progress => "Checkpoint is in progress",
            .storage_unavailable => "Storage is unavailable",
            .index_rebuilding => "Index is rebuilding after cold start",
            .entity_expired => "Entity has expired due to TTL",
            .resource_exhausted => "Internal resource pool exhausted",
            .backup_required => "Writes halted pending backup completion (mandatory mode)",
        };
    }
};

/// Resource error codes (300-310)
/// These errors indicate resource exhaustion.
pub const ResourceError = enum(u32) {
    /// Batch exceeds 10,000 events
    too_many_events = 300,
    /// Body exceeds message_body_size_max
    message_body_too_large = 301,
    /// Result set exceeds 81,000 events
    result_set_too_large = 302,
    /// Exceeds clients_max
    too_many_clients = 303,
    /// Rate limit exceeded
    rate_limit_exceeded = 304,
    /// Index at capacity
    memory_exhausted = 305,
    /// Disk full
    disk_full = 306,
    /// Too many concurrent queries (>100)
    too_many_queries = 307,
    /// Pipeline full
    pipeline_full = 308,
    /// RAM index capacity limit reached
    index_capacity_exceeded = 309,
    /// Hash table probe length exceeded max_probe_length
    index_degraded = 310,

    pub fn description(self: ResourceError) []const u8 {
        return switch (self) {
            .too_many_events => "Batch exceeds maximum event count (10,000)",
            .message_body_too_large => "Message body exceeds size limit",
            .result_set_too_large => "Result set exceeds maximum (81,000)",
            .too_many_clients => "Maximum client count exceeded",
            .rate_limit_exceeded => "Rate limit exceeded",
            .memory_exhausted => "Memory exhausted - index at capacity",
            .disk_full => "Disk full",
            .too_many_queries => "Too many concurrent queries (>100)",
            .pipeline_full => "Write pipeline is full",
            .index_capacity_exceeded => "RAM index capacity limit reached",
            .index_degraded => "Hash table probe length exceeded limit",
        };
    }
};

/// Security error codes (400-404)
/// These errors indicate security/authorization issues.
pub const SecurityError = enum(u32) {
    /// Authentication failed
    authentication_failed = 400,
    /// Missing authorization
    unauthorized = 403,
    /// Wrong cluster key
    cluster_key_mismatch = 404,

    pub fn description(self: SecurityError) []const u8 {
        return switch (self) {
            .authentication_failed => "Authentication failed",
            .unauthorized => "Unauthorized - missing permissions",
            .cluster_key_mismatch => "Cluster key mismatch",
        };
    }
};

/// Internal error codes (500-504)
/// These errors indicate internal system failures.
pub const InternalError = enum(u32) {
    /// Unexpected error
    internal_error = 500,
    /// Assertion failed
    assertion_failed = 501,
    /// Unreachable code path hit
    unreachable_reached = 502,
    /// Data corruption detected
    corruption_detected = 503,
    /// Invariant violation
    invariant_violation = 504,

    pub fn description(self: InternalError) []const u8 {
        return switch (self) {
            .internal_error => "Internal error - check logs",
            .assertion_failed => "Assertion failed",
            .unreachable_reached => "Unreachable code path was executed",
            .corruption_detected => "Data corruption detected",
            .invariant_violation => "System invariant violation",
        };
    }
};

/// Generic error code that can hold any error type.
/// Used for returning errors across operation boundaries.
pub const ErrorCode = union(enum) {
    protocol: ProtocolError,
    validation: ValidationError,
    state: StateError,
    resource: ResourceError,
    security: SecurityError,
    internal: InternalError,

    /// Get the numeric error code.
    pub fn code(self: ErrorCode) u32 {
        return switch (self) {
            .protocol => |p| @intFromEnum(p),
            .validation => |v| @intFromEnum(v),
            .state => |s| @intFromEnum(s),
            .resource => |r| @intFromEnum(r),
            .security => |sec| @intFromEnum(sec),
            .internal => |i| @intFromEnum(i),
        };
    }

    /// Get a human-readable description.
    pub fn description(self: ErrorCode) []const u8 {
        return switch (self) {
            .protocol => |p| p.description(),
            .validation => |v| v.description(),
            .state => |s| s.description(),
            .resource => |r| r.description(),
            .security => |sec| sec.description(),
            .internal => |i| i.description(),
        };
    }

    /// Returns true if this error can be retried.
    /// Retry semantics per spec:
    /// - Protocol checksum errors: Yes (transient network issues)
    /// - Cluster/view state errors: Yes (wait for cluster recovery)
    /// - Resource exhaustion: Yes (backoff and retry)
    /// - Validation errors: No (client must fix input)
    /// - Security errors: No (authentication required)
    /// - Internal errors: No (system failure)
    pub fn isRetriable(self: ErrorCode) bool {
        return switch (self) {
            .protocol => |p| p.isRetriable(),
            .validation => false, // Client errors - must fix input
            .state => |s| switch (s) {
                .cluster_unavailable,
                .view_change_in_progress,
                .not_primary,
                .checkpoint_in_progress,
                .storage_unavailable,
                .index_rebuilding,
                .resource_exhausted,
                .backup_required,
                => true,
                // Non-retriable state errors
                .entity_not_found,
                .session_expired,
                .duplicate_request,
                .stale_read,
                .entity_expired,
                => false,
            },
            .resource => |r| switch (r) {
                // Temporary capacity issues - can retry after backoff
                .too_many_clients,
                .rate_limit_exceeded,
                .memory_exhausted,
                .disk_full,
                .too_many_queries,
                .pipeline_full,
                .index_capacity_exceeded,
                .index_degraded,
                => true,
                // Validation-like errors - must fix input
                .too_many_events,
                .message_body_too_large,
                .result_set_too_large,
                => false,
            },
            .security => false, // Must fix authentication
            .internal => false, // System failure - not retriable
        };
    }
};

// Tests
test "validation error codes in expected range" {
    const min = @intFromEnum(ValidationError.invalid_coordinates);
    const max = @intFromEnum(ValidationError.holes_overlap);
    try std.testing.expect(min >= 100);
    try std.testing.expect(max <= 199);
}

test "state error codes in expected range" {
    const min = @intFromEnum(StateError.entity_not_found);
    const max = @intFromEnum(StateError.resource_exhausted);
    try std.testing.expect(min >= 200);
    try std.testing.expect(max <= 299);
}

test "resource error codes in expected range" {
    const min = @intFromEnum(ResourceError.too_many_events);
    const max = @intFromEnum(ResourceError.index_degraded);
    try std.testing.expect(min >= 300);
    try std.testing.expect(max <= 399);
}

test "polygon-specific error codes" {
    // F1.2.4: Verify polygon-specific codes 109-113 exist
    const self_int = @intFromEnum(ValidationError.polygon_self_intersecting);
    try std.testing.expectEqual(@as(u32, 109), self_int);
    try std.testing.expectEqual(@as(u32, 110), @intFromEnum(ValidationError.radius_zero));
    try std.testing.expectEqual(@as(u32, 111), @intFromEnum(ValidationError.polygon_too_large));
    try std.testing.expectEqual(@as(u32, 112), @intFromEnum(ValidationError.polygon_degenerate));
    try std.testing.expectEqual(@as(u32, 113), @intFromEnum(ValidationError.polygon_empty));
}

test "updated error codes 114-116" {
    // F1.2.4: Verify updated codes 114-116 exist
    try std.testing.expectEqual(@as(u32, 114), @intFromEnum(ValidationError.coordinate_mismatch));
    try std.testing.expectEqual(@as(u32, 115), @intFromEnum(ValidationError.timestamp_in_future));
    try std.testing.expectEqual(@as(u32, 116), @intFromEnum(ValidationError.timestamp_too_old));
}

test "polygon hole error codes 117-120" {
    // Polygon hole validation error codes per add-polygon-holes spec
    try std.testing.expectEqual(@as(u32, 117), @intFromEnum(ValidationError.too_many_holes));
    try std.testing.expectEqual(@as(u32, 118), @intFromEnum(ValidationError.hole_vertex_count_invalid));
    try std.testing.expectEqual(@as(u32, 119), @intFromEnum(ValidationError.hole_not_contained));
    try std.testing.expectEqual(@as(u32, 120), @intFromEnum(ValidationError.holes_overlap));
}

test "spec synchronization - all error codes from spec exist" {
    // F1.2.5: Verify implementation matches spec in:
    // openspec/changes/add-geospatial-core/specs/error-codes/spec.md
    // This test verifies key error codes from each category exist at expected values.

    // Validation errors (100-120)
    try std.testing.expectEqual(@as(u32, 100), @intFromEnum(ValidationError.invalid_coordinates));
    try std.testing.expectEqual(@as(u32, 108), @intFromEnum(ValidationError.invalid_polygon));
    try std.testing.expectEqual(@as(u32, 116), @intFromEnum(ValidationError.timestamp_too_old));
    try std.testing.expectEqual(@as(u32, 120), @intFromEnum(ValidationError.holes_overlap));

    // State errors (200-211)
    try std.testing.expectEqual(@as(u32, 200), @intFromEnum(StateError.entity_not_found));
    try std.testing.expectEqual(@as(u32, 209), @intFromEnum(StateError.index_rebuilding));
    try std.testing.expectEqual(@as(u32, 210), @intFromEnum(StateError.entity_expired));
    try std.testing.expectEqual(@as(u32, 211), @intFromEnum(StateError.resource_exhausted));

    // Resource errors (300-310)
    try std.testing.expectEqual(@as(u32, 300), @intFromEnum(ResourceError.too_many_events));
    try std.testing.expectEqual(@as(u32, 308), @intFromEnum(ResourceError.pipeline_full));
    try std.testing.expectEqual(@as(u32, 309), @intFromEnum(ResourceError.index_capacity_exceeded));
    try std.testing.expectEqual(@as(u32, 310), @intFromEnum(ResourceError.index_degraded));

    // Security errors (400-404)
    try std.testing.expectEqual(@as(u32, 400), @intFromEnum(SecurityError.authentication_failed));
    try std.testing.expectEqual(@as(u32, 404), @intFromEnum(SecurityError.cluster_key_mismatch));

    // Internal errors (500-504)
    try std.testing.expectEqual(@as(u32, 500), @intFromEnum(InternalError.internal_error));
    try std.testing.expectEqual(@as(u32, 504), @intFromEnum(InternalError.invariant_violation));
}

test "protocol error codes in expected range" {
    const min = @intFromEnum(ProtocolError.invalid_message);
    const max = @intFromEnum(ProtocolError.reserved_field_nonzero);
    try std.testing.expect(min >= 1);
    try std.testing.expect(max <= 99);
}

test "protocol error codes 1-10 per spec" {
    // F1.2.5: Verify protocol error codes 1-10 exist per spec
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(ProtocolError.invalid_message));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(ProtocolError.checksum_mismatch_header));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(ProtocolError.checksum_mismatch_body));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(ProtocolError.message_too_large));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(ProtocolError.message_too_small));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(ProtocolError.unsupported_version));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(ProtocolError.invalid_operation));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(ProtocolError.cluster_id_mismatch));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(ProtocolError.invalid_magic));
    try std.testing.expectEqual(@as(u32, 10), @intFromEnum(ProtocolError.reserved_field_nonzero));
}

test "isRetriable semantics per spec" {
    // Protocol checksum errors are retriable
    const checksum_header: ErrorCode = .{ .protocol = .checksum_mismatch_header };
    const checksum_body: ErrorCode = .{ .protocol = .checksum_mismatch_body };
    try std.testing.expect(checksum_header.isRetriable());
    try std.testing.expect(checksum_body.isRetriable());

    // Other protocol errors are not retriable
    const invalid_msg: ErrorCode = .{ .protocol = .invalid_message };
    const version: ErrorCode = .{ .protocol = .unsupported_version };
    try std.testing.expect(!invalid_msg.isRetriable());
    try std.testing.expect(!version.isRetriable());

    // Validation errors are not retriable
    const invalid_coords: ErrorCode = .{ .validation = .invalid_coordinates };
    try std.testing.expect(!invalid_coords.isRetriable());

    // Cluster state errors are retriable
    const cluster_unavail: ErrorCode = .{ .state = .cluster_unavailable };
    const view_change: ErrorCode = .{ .state = .view_change_in_progress };
    try std.testing.expect(cluster_unavail.isRetriable());
    try std.testing.expect(view_change.isRetriable());

    // Entity not found is not retriable
    const not_found: ErrorCode = .{ .state = .entity_not_found };
    try std.testing.expect(!not_found.isRetriable());

    // Resource exhaustion is retriable (backoff)
    const rate_limit: ErrorCode = .{ .resource = .rate_limit_exceeded };
    try std.testing.expect(rate_limit.isRetriable());

    // Batch too large is not retriable (must fix input)
    const too_many: ErrorCode = .{ .resource = .too_many_events };
    try std.testing.expect(!too_many.isRetriable());

    // Security and internal errors are not retriable
    const auth_fail: ErrorCode = .{ .security = .authentication_failed };
    const internal: ErrorCode = .{ .internal = .internal_error };
    try std.testing.expect(!auth_fail.isRetriable());
    try std.testing.expect(!internal.isRetriable());
}
