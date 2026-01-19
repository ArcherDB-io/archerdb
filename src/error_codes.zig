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
//!   - 200-212:  State errors (v1)
//!   - 213-218:  Multi-region errors (v2.0)
//!   - 220-224:  Sharding errors (v2.0)
//!   - 230-233:  Tiering errors (v2.1)
//!   - 240-243:  TTL extension errors (v2.1)
//!   - 300-310:  Resource errors
//!   - 400-404:  Security errors (v1)
//!   - 410-414:  Encryption errors (v2.0)
//!   - 500-504:  Internal errors

const std = @import("std");
const stdx = @import("stdx");

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

/// State error codes (200-243)
/// These errors indicate system state issues.
/// Ranges: 200-212 (v1), 213-218 (multi-region), 220-224 (sharding),
/// 230-233 (tiering), 240-243 (TTL)
pub const StateError = enum(u32) {
    // === v1 Core State Errors (200-212) ===
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

    // === v2.0 Multi-Region Errors (213-218) ===
    /// Write sent to follower region (follower is read-only)
    follower_read_only = 213,
    /// Follower has not caught up to requested min_commit_op
    stale_follower = 214,
    /// Target region is not reachable
    region_unavailable = 215,
    /// Cross-region operation timed out
    cross_region_timeout = 216,
    /// Write conflict detected in active-active replication
    conflict_detected = 217,
    /// Entity geo-shard does not match target region
    geo_shard_mismatch = 218,

    // === v2.0 Sharding Errors (220-224) ===
    /// This node is not the leader for target shard
    not_shard_leader = 220,
    /// Target shard has no available replicas
    shard_unavailable = 221,
    /// Cluster is currently resharding
    resharding_in_progress = 222,
    /// Target shard count is invalid
    invalid_shard_count = 223,
    /// Data migration to new shard failed
    shard_migration_failed = 224,

    // === v2.1 Tiering Errors (230-233) ===
    /// Cannot access cold tier storage (S3)
    cold_tier_unavailable = 230,
    /// Cold tier fetch exceeded timeout
    cold_tier_fetch_timeout = 231,
    /// Tier migration failed
    migration_failed = 232,
    /// Target tier storage is full
    tier_storage_full = 233,

    // === v2.1 TTL Extension Errors (240-243) ===
    /// TTL extension is not enabled
    ttl_extension_disabled = 240,
    /// Entity has reached maximum TTL
    ttl_extension_max_reached = 241,
    /// Entity has reached maximum extension count
    ttl_extension_count_exceeded = 242,
    /// TTL extension cooldown period active
    ttl_cooldown_active = 243,

    pub fn description(self: StateError) []const u8 {
        return switch (self) {
            // v1 Core
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
            // Multi-Region
            .follower_read_only => "Follower region cannot accept writes",
            .stale_follower => "Follower has not caught up to requested op",
            .region_unavailable => "Target region is not reachable",
            .cross_region_timeout => "Cross-region operation timed out",
            .conflict_detected => "Write conflict detected (active-active)",
            .geo_shard_mismatch => "Entity geo-shard does not match target region",
            // Sharding
            .not_shard_leader => "This node is not the leader for target shard",
            .shard_unavailable => "Target shard has no available replicas",
            .resharding_in_progress => "Cluster is currently resharding",
            .invalid_shard_count => "Target shard count is invalid",
            .shard_migration_failed => "Data migration to new shard failed",
            // Tiering
            .cold_tier_unavailable => "Cannot access cold tier storage",
            .cold_tier_fetch_timeout => "Cold tier fetch exceeded timeout",
            .migration_failed => "Tier migration failed",
            .tier_storage_full => "Target tier storage is full",
            // TTL Extension
            .ttl_extension_disabled => "TTL extension is not enabled",
            .ttl_extension_max_reached => "Entity has reached maximum TTL",
            .ttl_extension_count_exceeded => "Entity has reached maximum extension count",
            .ttl_cooldown_active => "TTL extension cooldown period active",
        };
    }

    /// Returns true if this state error can be retried
    pub fn isRetriable(self: StateError) bool {
        return switch (self) {
            // v1 retriable
            .cluster_unavailable,
            .view_change_in_progress,
            .not_primary,
            .checkpoint_in_progress,
            .storage_unavailable,
            .index_rebuilding,
            .resource_exhausted,
            .backup_required,
            // Multi-region retriable
            .stale_follower,
            .region_unavailable,
            .cross_region_timeout,
            // Sharding retriable
            .not_shard_leader,
            .shard_unavailable,
            .resharding_in_progress,
            // Tiering retriable
            .cold_tier_unavailable,
            .cold_tier_fetch_timeout,
            => true,
            // Non-retriable
            .entity_not_found,
            .session_expired,
            .duplicate_request,
            .stale_read,
            .entity_expired,
            .follower_read_only,
            .conflict_detected,
            .geo_shard_mismatch,
            .invalid_shard_count,
            .shard_migration_failed,
            .migration_failed,
            .tier_storage_full,
            .ttl_extension_disabled,
            .ttl_extension_max_reached,
            .ttl_extension_count_exceeded,
            .ttl_cooldown_active,
            => false,
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

/// Security error codes (400-415)
/// These errors indicate security/authorization issues.
/// Ranges: 400-404 (v1 auth), 410-415 (v2.0+ encryption)
pub const SecurityError = enum(u32) {
    // === v1 Authentication Errors (400-404) ===
    /// Authentication failed
    authentication_failed = 400,
    /// Missing authorization
    unauthorized = 403,
    /// Wrong cluster key
    cluster_key_mismatch = 404,

    // === v2.0 Encryption Errors (410-414) ===
    /// Cannot retrieve encryption key from provider (KMS/Vault)
    encryption_key_unavailable = 410,
    /// Failed to decrypt data (auth tag mismatch)
    decryption_failed = 411,
    /// Encryption required but not configured
    encryption_not_enabled = 412,
    /// Key rotation in progress, retry later
    key_rotation_in_progress = 413,
    /// File encrypted with unsupported version
    unsupported_encryption_version = 414,

    // === v2.1+ Encryption Errors (415+) ===
    /// AES-NI hardware acceleration not available
    /// Per add-aesni-encryption spec: returned when CPU lacks AES-NI
    /// and --allow-software-crypto is not set
    aesni_not_available = 415,

    pub fn description(self: SecurityError) []const u8 {
        return switch (self) {
            // Authentication
            .authentication_failed => "Authentication failed",
            .unauthorized => "Unauthorized - missing permissions",
            .cluster_key_mismatch => "Cluster key mismatch",
            // Encryption
            .encryption_key_unavailable => "Cannot retrieve encryption key from provider",
            .decryption_failed => "Failed to decrypt data (auth tag mismatch)",
            .encryption_not_enabled => "Encryption required but not configured",
            .key_rotation_in_progress => "Key rotation in progress, retry later",
            .unsupported_encryption_version => "File encrypted with unsupported version",
            .aesni_not_available => "AES-NI not available (use --allow-software-crypto)",
        };
    }

    /// Returns true if this security error can be retried
    pub fn isRetriable(self: SecurityError) bool {
        return switch (self) {
            // Encryption retriable
            .encryption_key_unavailable,
            .key_rotation_in_progress,
            => true,
            // Non-retriable
            .authentication_failed,
            .unauthorized,
            .cluster_key_mismatch,
            .decryption_failed,
            .encryption_not_enabled,
            .unsupported_encryption_version,
            .aesni_not_available,
            => false,
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
    /// - Cluster/view/region state errors: Yes (wait for recovery)
    /// - Resource exhaustion: Yes (backoff and retry)
    /// - Validation errors: No (client must fix input)
    /// - Some security errors: Yes (key unavailable, rotation in progress)
    /// - Internal errors: No (system failure)
    pub fn isRetriable(self: ErrorCode) bool {
        return switch (self) {
            .protocol => |p| p.isRetriable(),
            .validation => false, // Client errors - must fix input
            .state => |s| s.isRetriable(),
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
            .security => |sec| sec.isRetriable(),
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
    const max = @intFromEnum(StateError.ttl_cooldown_active);
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
    const ve = ValidationError;
    try std.testing.expectEqual(@as(u32, 117), @intFromEnum(ve.too_many_holes));
    try std.testing.expectEqual(@as(u32, 118), @intFromEnum(ve.hole_vertex_count_invalid));
    try std.testing.expectEqual(@as(u32, 119), @intFromEnum(ve.hole_not_contained));
    try std.testing.expectEqual(@as(u32, 120), @intFromEnum(ve.holes_overlap));
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

// === v2.0 Error Code Tests ===

test "v2.0 multi-region error codes 213-218" {
    // Multi-region error codes per add-v2-distributed-features spec
    try std.testing.expectEqual(@as(u32, 213), @intFromEnum(StateError.follower_read_only));
    try std.testing.expectEqual(@as(u32, 214), @intFromEnum(StateError.stale_follower));
    try std.testing.expectEqual(@as(u32, 215), @intFromEnum(StateError.region_unavailable));
    try std.testing.expectEqual(@as(u32, 216), @intFromEnum(StateError.cross_region_timeout));
    try std.testing.expectEqual(@as(u32, 217), @intFromEnum(StateError.conflict_detected));
    try std.testing.expectEqual(@as(u32, 218), @intFromEnum(StateError.geo_shard_mismatch));
}

test "v2.0 sharding error codes 220-224" {
    // Sharding error codes per add-v2-distributed-features spec
    try std.testing.expectEqual(@as(u32, 220), @intFromEnum(StateError.not_shard_leader));
    try std.testing.expectEqual(@as(u32, 221), @intFromEnum(StateError.shard_unavailable));
    try std.testing.expectEqual(@as(u32, 222), @intFromEnum(StateError.resharding_in_progress));
    try std.testing.expectEqual(@as(u32, 223), @intFromEnum(StateError.invalid_shard_count));
    try std.testing.expectEqual(@as(u32, 224), @intFromEnum(StateError.shard_migration_failed));
}

test "v2.1 tiering error codes 230-233" {
    // Tiering error codes per add-v2-distributed-features spec
    try std.testing.expectEqual(@as(u32, 230), @intFromEnum(StateError.cold_tier_unavailable));
    try std.testing.expectEqual(@as(u32, 231), @intFromEnum(StateError.cold_tier_fetch_timeout));
    try std.testing.expectEqual(@as(u32, 232), @intFromEnum(StateError.migration_failed));
    try std.testing.expectEqual(@as(u32, 233), @intFromEnum(StateError.tier_storage_full));
}

test "v2.1 TTL extension error codes 240-243" {
    // TTL extension error codes per add-v2-distributed-features spec
    const se = StateError;
    try std.testing.expectEqual(@as(u32, 240), @intFromEnum(se.ttl_extension_disabled));
    try std.testing.expectEqual(@as(u32, 241), @intFromEnum(se.ttl_extension_max_reached));
    try std.testing.expectEqual(@as(u32, 242), @intFromEnum(se.ttl_extension_count_exceeded));
    try std.testing.expectEqual(@as(u32, 243), @intFromEnum(se.ttl_cooldown_active));
}

test "v2.0+ encryption error codes 410-415" {
    // Encryption error codes per add-v2-distributed-features spec
    const sec = SecurityError;
    try std.testing.expectEqual(@as(u32, 410), @intFromEnum(sec.encryption_key_unavailable));
    try std.testing.expectEqual(@as(u32, 411), @intFromEnum(sec.decryption_failed));
    try std.testing.expectEqual(@as(u32, 412), @intFromEnum(sec.encryption_not_enabled));
    try std.testing.expectEqual(@as(u32, 413), @intFromEnum(sec.key_rotation_in_progress));
    try std.testing.expectEqual(@as(u32, 414), @intFromEnum(sec.unsupported_encryption_version));
    // v2.1+ AES-NI error code per add-aesni-encryption spec
    try std.testing.expectEqual(@as(u32, 415), @intFromEnum(sec.aesni_not_available));
}

test "v2.0 isRetriable semantics for distributed errors" {
    // Multi-region: some are retriable
    const stale_follower: ErrorCode = .{ .state = .stale_follower };
    const region_unavail: ErrorCode = .{ .state = .region_unavailable };
    const follower_ro: ErrorCode = .{ .state = .follower_read_only };
    try std.testing.expect(stale_follower.isRetriable());
    try std.testing.expect(region_unavail.isRetriable());
    try std.testing.expect(!follower_ro.isRetriable()); // Must redirect to primary

    // Sharding: leader/availability issues are retriable
    const not_leader: ErrorCode = .{ .state = .not_shard_leader };
    const shard_unavail: ErrorCode = .{ .state = .shard_unavailable };
    const invalid_count: ErrorCode = .{ .state = .invalid_shard_count };
    try std.testing.expect(not_leader.isRetriable());
    try std.testing.expect(shard_unavail.isRetriable());
    try std.testing.expect(!invalid_count.isRetriable()); // Client must fix

    // Tiering: availability issues are retriable
    const cold_unavail: ErrorCode = .{ .state = .cold_tier_unavailable };
    const tier_full: ErrorCode = .{ .state = .tier_storage_full };
    try std.testing.expect(cold_unavail.isRetriable());
    try std.testing.expect(!tier_full.isRetriable()); // Admin action required

    // Encryption: key availability issues are retriable
    const key_unavail: ErrorCode = .{ .security = .encryption_key_unavailable };
    const key_rotation: ErrorCode = .{ .security = .key_rotation_in_progress };
    const decrypt_fail: ErrorCode = .{ .security = .decryption_failed };
    const aesni_unavail: ErrorCode = .{ .security = .aesni_not_available };
    try std.testing.expect(key_unavail.isRetriable());
    try std.testing.expect(key_rotation.isRetriable());
    try std.testing.expect(!decrypt_fail.isRetriable()); // Data corruption
    try std.testing.expect(!aesni_unavail.isRetriable()); // Hardware issue
}

// === Error Context Encoding ===
// Per spec lines 175-186: Error context encoding format:
// - Field count (u16)
// - For each field:
//   - Field name length (u8)
//   - Field name (UTF-8 string, max 255 bytes)
//   - Field value length (u16)
//   - Field value (UTF-8 string, max 65535 bytes)

/// Represents a single context field (name-value pair).
pub const ContextField = struct {
    name: []const u8,
    value: []const u8,
};

/// Encodes error context fields into the wire format per spec.
/// Returns the number of bytes written, or error if buffer is too small.
pub fn encodeContext(fields: []const ContextField, buffer: []u8) !usize {
    if (fields.len > std.math.maxInt(u16)) return error.TooManyFields;
    if (buffer.len < 2) return error.BufferTooSmall;

    // Write field count (u16)
    std.mem.writeInt(u16, buffer[0..2], @intCast(fields.len), .little);
    var offset: usize = 2;

    for (fields) |field| {
        // Validate field name length (max 255 bytes)
        if (field.name.len > 255) return error.NameTooLong;
        // Validate field value length (max 65535 bytes)
        if (field.value.len > std.math.maxInt(u16)) return error.ValueTooLong;

        // Calculate required space: 1 (name_len) + name + 2 (value_len) + value
        const required = 1 + field.name.len + 2 + field.value.len;
        if (offset + required > buffer.len) return error.BufferTooSmall;

        // Write name length (u8)
        buffer[offset] = @intCast(field.name.len);
        offset += 1;

        // Write name
        stdx.copy_disjoint(.exact, u8, buffer[offset..][0..field.name.len], field.name);
        offset += field.name.len;

        // Write value length (u16)
        std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(field.value.len), .little);
        offset += 2;

        // Write value
        stdx.copy_disjoint(.exact, u8, buffer[offset..][0..field.value.len], field.value);
        offset += field.value.len;
    }

    return offset;
}

/// Decodes error context from wire format.
/// Returns slice of ContextField structs and remaining buffer.
pub fn decodeContext(
    buffer: []const u8,
    out_fields: []ContextField,
) !struct { fields: []ContextField, bytes_consumed: usize } {
    if (buffer.len < 2) return error.BufferTooSmall;

    // Read field count (u16)
    const field_count = std.mem.readInt(u16, buffer[0..2], .little);
    if (field_count > out_fields.len) return error.TooManyFields;

    var offset: usize = 2;
    var i: usize = 0;

    while (i < field_count) : (i += 1) {
        // Read name length (u8)
        if (offset >= buffer.len) return error.BufferTooSmall;
        const name_len: usize = buffer[offset];
        offset += 1;

        // Read name
        if (offset + name_len > buffer.len) return error.BufferTooSmall;
        const name = buffer[offset..][0..name_len];
        offset += name_len;

        // Read value length (u16)
        if (offset + 2 > buffer.len) return error.BufferTooSmall;
        const value_len = std.mem.readInt(u16, buffer[offset..][0..2], .little);
        offset += 2;

        // Read value
        if (offset + value_len > buffer.len) return error.BufferTooSmall;
        const value = buffer[offset..][0..value_len];
        offset += value_len;

        out_fields[i] = .{ .name = name, .value = value };
    }

    return .{ .fields = out_fields[0..field_count], .bytes_consumed = offset };
}

// === Error Context Encoding Tests ===

test "error context encoding: empty context" {
    var buffer: [256]u8 = undefined;

    // Encode empty context
    const empty: []const ContextField = &.{};
    const written = try encodeContext(empty, &buffer);
    try std.testing.expectEqual(@as(usize, 2), written);

    // Field count should be 0
    const field_count = std.mem.readInt(u16, buffer[0..2], .little);
    try std.testing.expectEqual(@as(u16, 0), field_count);

    // Decode empty context
    var out_fields: [10]ContextField = undefined;
    const result = try decodeContext(buffer[0..written], &out_fields);
    try std.testing.expectEqual(@as(usize, 0), result.fields.len);
    try std.testing.expectEqual(@as(usize, 2), result.bytes_consumed);
}

test "error context encoding: single field" {
    var buffer: [256]u8 = undefined;

    const fields = [_]ContextField{
        .{ .name = "entity_id", .value = "12345678-1234-1234-1234-123456789abc" },
    };

    const written = try encodeContext(&fields, &buffer);

    // Decode and verify
    var out_fields: [10]ContextField = undefined;
    const result = try decodeContext(buffer[0..written], &out_fields);

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("entity_id", result.fields[0].name);
    const expected_uuid = "12345678-1234-1234-1234-123456789abc";
    try std.testing.expectEqualStrings(expected_uuid, result.fields[0].value);
}

test "error context encoding: multiple fields" {
    var buffer: [1024]u8 = undefined;

    const fields = [_]ContextField{
        .{ .name = "offset", .value = "128" },
        .{ .name = "expected", .value = "0xABCD1234" },
        .{ .name = "actual", .value = "0x00000000" },
    };

    const written = try encodeContext(&fields, &buffer);

    // Decode and verify
    var out_fields: [10]ContextField = undefined;
    const result = try decodeContext(buffer[0..written], &out_fields);

    try std.testing.expectEqual(@as(usize, 3), result.fields.len);
    try std.testing.expectEqualStrings("offset", result.fields[0].name);
    try std.testing.expectEqualStrings("128", result.fields[0].value);
    try std.testing.expectEqualStrings("expected", result.fields[1].name);
    try std.testing.expectEqualStrings("0xABCD1234", result.fields[1].value);
    try std.testing.expectEqualStrings("actual", result.fields[2].name);
    try std.testing.expectEqualStrings("0x00000000", result.fields[2].value);
}

test "error context encoding: max name length (255 bytes)" {
    var buffer: [512]u8 = undefined;

    // Create 255-byte name
    var name_buf: [255]u8 = undefined;
    @memset(&name_buf, 'x');

    const fields = [_]ContextField{
        .{ .name = &name_buf, .value = "test" },
    };

    const written = try encodeContext(&fields, &buffer);

    // Decode and verify
    var out_fields: [10]ContextField = undefined;
    const result = try decodeContext(buffer[0..written], &out_fields);

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqual(@as(usize, 255), result.fields[0].name.len);
    try std.testing.expectEqualStrings("test", result.fields[0].value);
}

test "error context encoding: name too long error" {
    var buffer: [512]u8 = undefined;

    // Create 256-byte name (exceeds max)
    var name_buf: [256]u8 = undefined;
    @memset(&name_buf, 'x');

    const fields = [_]ContextField{
        .{ .name = &name_buf, .value = "test" },
    };

    const result = encodeContext(&fields, &buffer);
    try std.testing.expectError(error.NameTooLong, result);
}

test "error context encoding: buffer too small" {
    var buffer: [5]u8 = undefined; // Too small for any field

    const fields = [_]ContextField{
        .{ .name = "test", .value = "value" },
    };

    const result = encodeContext(&fields, &buffer);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "error context encoding: roundtrip with spec example fields" {
    // Test with actual error code context fields from spec
    var buffer: [1024]u8 = undefined;

    // invalid_coordinates context fields per spec
    const fields = [_]ContextField{
        .{ .name = "lat_nano", .value = "95000000000" },
        .{ .name = "lon_nano", .value = "0" },
        .{ .name = "valid_lat_range", .value = "-90000000000..90000000000" },
        .{ .name = "valid_lon_range", .value = "-180000000000..180000000000" },
    };

    const written = try encodeContext(&fields, &buffer);

    var out_fields: [10]ContextField = undefined;
    const result = try decodeContext(buffer[0..written], &out_fields);

    try std.testing.expectEqual(@as(usize, 4), result.fields.len);
    try std.testing.expectEqualStrings("lat_nano", result.fields[0].name);
    try std.testing.expectEqualStrings("95000000000", result.fields[0].value);
    try std.testing.expectEqualStrings("valid_lon_range", result.fields[3].name);
    try std.testing.expectEqualStrings("-180000000000..180000000000", result.fields[3].value);
}

test "error context encoding: checksum error context fields" {
    // checksum_mismatch_header context fields per spec
    var buffer: [512]u8 = undefined;

    const fields = [_]ContextField{
        .{ .name = "address", .value = "0x123456789ABCDEF0" },
        .{ .name = "expected_checksum", .value = "0xDEADBEEFCAFEBABE" },
        .{ .name = "actual_checksum", .value = "0x0000000000000000" },
    };

    const written = try encodeContext(&fields, &buffer);

    var out_fields: [10]ContextField = undefined;
    const result = try decodeContext(buffer[0..written], &out_fields);

    try std.testing.expectEqual(@as(usize, 3), result.fields.len);
    try std.testing.expectEqualStrings("address", result.fields[0].name);
    try std.testing.expectEqualStrings("expected_checksum", result.fields[1].name);
    try std.testing.expectEqualStrings("actual_checksum", result.fields[2].name);
}
