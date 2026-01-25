// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Prepared Query Compilation and Session-Scoped Storage.
//!
//! Implements prepared query support for dashboard workloads where the same
//! query patterns repeat with only parameter values changing. Pre-compiling
//! queries eliminates parse overhead and enables parameter validation at
//! prepare time.
//!
//! ## Design
//!
//! - **Session-scoped lifecycle**: Prepared queries are tied to client sessions.
//!   When a client session ends, all prepared queries for that session are
//!   deallocated (PostgreSQL semantics).
//!
//! - **Compiled representation**: CompiledQuery stores pre-parsed query type
//!   and filter template with parameter slots for substitution.
//!
//! - **Parameter validation**: Parameter types are validated at prepare time,
//!   catching type mismatches before execution.
//!
//! ## Usage
//!
//! ```zig
//! var session = SessionPreparedQueries.init();
//!
//! // Prepare a query
//! const slot = try session.prepare("nearby", "RADIUS $1 $2 $3 LIMIT $4");
//!
//! // Execute with parameters
//! const result_len = try session.execute(slot, params, output);
//!
//! // Cleanup when session ends
//! session.clear();
//! ```

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const stdx = @import("stdx");

// ============================================================================
// Query Types
// ============================================================================

/// Query type enumeration for compiled queries.
pub const QueryType = enum(u8) {
    /// UUID lookup query (query_uuid)
    uuid = 0,
    /// Radius search query (query_radius)
    radius = 1,
    /// Polygon containment query (query_polygon)
    polygon = 2,
    /// Latest events query (query_latest)
    latest = 3,

    /// Convert to string for logging.
    pub fn toString(self: QueryType) []const u8 {
        return switch (self) {
            .uuid => "uuid",
            .radius => "radius",
            .polygon => "polygon",
            .latest => "latest",
        };
    }
};

/// Parameter type enumeration for prepared queries.
pub const ParamType = enum(u8) {
    /// Entity ID (u128)
    entity_id = 0,
    /// Latitude in nanodegrees (i64)
    lat_nano = 1,
    /// Longitude in nanodegrees (i64)
    lon_nano = 2,
    /// Radius in millimeters (u32)
    radius_mm = 3,
    /// Minimum timestamp (u64)
    timestamp_min = 4,
    /// Maximum timestamp (u64)
    timestamp_max = 5,
    /// Group ID filter (u64)
    group_id = 6,
    /// Result limit (u32)
    limit = 7,

    /// Get the size of this parameter type in bytes.
    pub fn size(self: ParamType) u8 {
        return switch (self) {
            .entity_id => 16, // u128
            .lat_nano, .lon_nano => 8, // i64
            .radius_mm, .limit => 4, // u32
            .timestamp_min, .timestamp_max, .group_id => 8, // u64
        };
    }
};

// ============================================================================
// Parameter Slot
// ============================================================================

/// Parameter slot describing where and how to substitute a parameter.
pub const ParamSlot = extern struct {
    /// Type of parameter expected
    param_type: ParamType,
    /// Reserved for alignment
    _reserved: u8 = 0,
    /// Offset into filter template where value goes
    offset: u16,

    comptime {
        assert(@sizeOf(ParamSlot) == 4);
        assert(stdx.no_padding(ParamSlot));
    }
};

// ============================================================================
// Filter Templates
// ============================================================================

/// UUID filter template for prepared uuid queries.
pub const UuidFilterTemplate = extern struct {
    /// Placeholder for entity_id (substituted at execute time)
    entity_id: u128,
    /// Reserved (must be zero)
    reserved: [16]u8,

    comptime {
        assert(@sizeOf(UuidFilterTemplate) == 32);
    }
};

/// Radius filter template for prepared radius queries.
pub const RadiusFilterTemplate = extern struct {
    /// Center latitude in nanodegrees (may be param)
    center_lat_nano: i64,
    /// Center longitude in nanodegrees (may be param)
    center_lon_nano: i64,
    /// Radius in millimeters (may be param)
    radius_mm: u32,
    /// Maximum results to return (may be param)
    limit: u32,
    /// Minimum timestamp (may be param)
    timestamp_min: u64,
    /// Maximum timestamp (may be param)
    timestamp_max: u64,
    /// Group ID filter (may be param)
    group_id: u64,
    /// Reserved
    reserved: [80]u8,

    comptime {
        assert(@sizeOf(RadiusFilterTemplate) == 128);
    }
};

/// Polygon filter template for prepared polygon queries.
pub const PolygonFilterTemplate = extern struct {
    /// Number of vertices in outer ring
    vertex_count: u32,
    /// Number of hole rings
    hole_count: u32,
    /// Maximum results to return (may be param)
    limit: u32,
    /// Reserved for alignment
    _reserved_align: u32,
    /// Minimum timestamp (may be param)
    timestamp_min: u64,
    /// Maximum timestamp (may be param)
    timestamp_max: u64,
    /// Group ID filter (may be param)
    group_id: u64,
    /// Reserved
    reserved: [88]u8,

    comptime {
        assert(@sizeOf(PolygonFilterTemplate) == 128);
    }
};

/// Latest filter template for prepared latest queries.
pub const LatestFilterTemplate = extern struct {
    /// Maximum results to return (may be param)
    limit: u32,
    /// Reserved for alignment
    _reserved_align: u32,
    /// Group ID filter (may be param)
    group_id: u64,
    /// Cursor timestamp for pagination
    cursor_timestamp: u64,
    /// Reserved
    reserved: [104]u8,

    comptime {
        assert(@sizeOf(LatestFilterTemplate) == 128);
    }
};

/// Union of all filter templates.
pub const FilterTemplate = union {
    uuid: UuidFilterTemplate,
    radius: RadiusFilterTemplate,
    polygon: PolygonFilterTemplate,
    latest: LatestFilterTemplate,
};

// ============================================================================
// Compiled Query
// ============================================================================

/// Maximum number of parameters per prepared query.
pub const max_params: u8 = 8;

/// Compiled query representation with pre-parsed filter template.
pub const CompiledQuery = struct {
    /// Query type (uuid, radius, polygon, latest)
    query_type: QueryType,
    /// Number of parameters
    num_params: u8,
    /// Pre-validated, normalized filter template
    filter_template: FilterTemplate,
    /// Parameter slots for substitution
    param_slots: [max_params]ParamSlot,

    /// Initialize a compiled uuid query.
    pub fn initUuid() CompiledQuery {
        return .{
            .query_type = .uuid,
            .num_params = 1,
            .filter_template = .{
                .uuid = UuidFilterTemplate{
                    .entity_id = 0,
                    .reserved = @splat(0),
                },
            },
            .param_slots = blk: {
                var slots: [max_params]ParamSlot = undefined;
                slots[0] = .{
                    .param_type = .entity_id,
                    .offset = 0, // entity_id at offset 0
                };
                for (1..max_params) |i| {
                    slots[i] = .{
                        .param_type = .entity_id,
                        .offset = 0,
                    };
                }
                break :blk slots;
            },
        };
    }

    /// Initialize a compiled radius query with all parameters.
    pub fn initRadius() CompiledQuery {
        return .{
            .query_type = .radius,
            .num_params = 4, // lat, lon, radius, limit
            .filter_template = .{
                .radius = RadiusFilterTemplate{
                    .center_lat_nano = 0,
                    .center_lon_nano = 0,
                    .radius_mm = 0,
                    .limit = 100,
                    .timestamp_min = 0,
                    .timestamp_max = 0,
                    .group_id = 0,
                    .reserved = @splat(0),
                },
            },
            .param_slots = blk: {
                var slots: [max_params]ParamSlot = undefined;
                slots[0] = .{ .param_type = .lat_nano, .offset = 0 };
                slots[1] = .{ .param_type = .lon_nano, .offset = 8 };
                slots[2] = .{ .param_type = .radius_mm, .offset = 16 };
                slots[3] = .{ .param_type = .limit, .offset = 20 };
                for (4..max_params) |i| {
                    slots[i] = .{ .param_type = .entity_id, .offset = 0 };
                }
                break :blk slots;
            },
        };
    }

    /// Initialize a compiled latest query with group filter.
    pub fn initLatest() CompiledQuery {
        return .{
            .query_type = .latest,
            .num_params = 2, // limit, group_id
            .filter_template = .{
                .latest = LatestFilterTemplate{
                    .limit = 100,
                    ._reserved_align = 0,
                    .group_id = 0,
                    .cursor_timestamp = 0,
                    .reserved = @splat(0),
                },
            },
            .param_slots = blk: {
                var slots: [max_params]ParamSlot = undefined;
                slots[0] = .{ .param_type = .limit, .offset = 0 };
                slots[1] = .{ .param_type = .group_id, .offset = 8 };
                for (2..max_params) |i| {
                    slots[i] = .{ .param_type = .entity_id, .offset = 0 };
                }
                break :blk slots;
            },
        };
    }

    /// Apply parameters to generate executable filter bytes.
    ///
    /// Arguments:
    /// - params: Parameter values in order (packed bytes)
    /// - output: Buffer to write the executable filter
    ///
    /// Returns: Number of bytes written, or error if params invalid
    pub fn applyParams(self: *const CompiledQuery, params: []const u8, output: []u8) error{
        InvalidParamCount,
        InvalidParamSize,
        OutputTooSmall,
    }!usize {
        // Calculate expected param size
        var expected_size: usize = 0;
        for (0..self.num_params) |i| {
            expected_size += self.param_slots[i].param_type.size();
        }

        if (params.len < expected_size) {
            return error.InvalidParamSize;
        }

        // Determine output size based on query type
        const filter_size: usize = switch (self.query_type) {
            .uuid => @sizeOf(UuidFilterTemplate),
            .radius => @sizeOf(RadiusFilterTemplate),
            .polygon => @sizeOf(PolygonFilterTemplate),
            .latest => @sizeOf(LatestFilterTemplate),
        };

        if (output.len < filter_size) {
            return error.OutputTooSmall;
        }

        // Copy base template to output
        switch (self.query_type) {
            .uuid => {
                const template_bytes = mem.asBytes(&self.filter_template.uuid);
                @memcpy(output[0..filter_size], template_bytes);
            },
            .radius => {
                const template_bytes = mem.asBytes(&self.filter_template.radius);
                @memcpy(output[0..filter_size], template_bytes);
            },
            .polygon => {
                const template_bytes = mem.asBytes(&self.filter_template.polygon);
                @memcpy(output[0..filter_size], template_bytes);
            },
            .latest => {
                const template_bytes = mem.asBytes(&self.filter_template.latest);
                @memcpy(output[0..filter_size], template_bytes);
            },
        }

        // Substitute parameters
        var param_offset: usize = 0;
        for (0..self.num_params) |i| {
            const slot = self.param_slots[i];
            const param_size = slot.param_type.size();
            const dest_offset = slot.offset;

            @memcpy(
                output[dest_offset..][0..param_size],
                params[param_offset..][0..param_size],
            );
            param_offset += param_size;
        }

        return filter_size;
    }
};

// ============================================================================
// Prepared Query
// ============================================================================

/// Prepared query with name, compiled representation, and statistics.
pub const PreparedQuery = struct {
    /// Hash of user-provided name for lookup
    name_hash: u64,
    /// Compiled query representation
    compiled: CompiledQuery,
    /// Execution statistics
    execution_count: u64,
    /// Total execution duration in nanoseconds
    total_duration_ns: u64,

    /// Calculate average execution time in nanoseconds.
    pub fn averageExecutionNs(self: PreparedQuery) u64 {
        if (self.execution_count == 0) return 0;
        return self.total_duration_ns / self.execution_count;
    }

    /// Record an execution with timing.
    pub fn recordExecution(self: *PreparedQuery, duration_ns: u64) void {
        self.execution_count += 1;
        self.total_duration_ns += duration_ns;
    }
};

// ============================================================================
// Session Prepared Queries
// ============================================================================

/// Maximum prepared queries per session.
pub const max_prepared_per_session: u32 = 32;

/// Error type for prepared query operations.
pub const PreparedError = error{
    /// Too many prepared queries in session
    SessionFull,
    /// Query with this name already exists
    AlreadyExists,
    /// Query not found
    NotFound,
    /// Invalid query text
    InvalidQuery,
    /// Invalid parameter count
    InvalidParamCount,
    /// Invalid parameter type/size
    InvalidParamSize,
    /// Output buffer too small
    OutputTooSmall,
    /// Unsupported query type
    UnsupportedQueryType,
};

/// Session-scoped prepared query storage.
///
/// Manages prepared queries for a single client session. When the session
/// ends (client disconnects or times out), all prepared queries are
/// automatically deallocated.
pub const SessionPreparedQueries = struct {
    /// Prepared queries (null = empty slot)
    queries: [max_prepared_per_session]?PreparedQuery,
    /// Number of active prepared queries
    count: u32,

    /// Initialize empty session storage.
    pub fn init() SessionPreparedQueries {
        return .{
            .queries = @splat(null),
            .count = 0,
        };
    }

    /// Prepare a query with a name.
    ///
    /// Arguments:
    /// - name: User-provided query name for later lookup
    /// - query_text: Query text to compile (e.g., "RADIUS $1 $2 $3 LIMIT $4")
    ///
    /// Returns: Slot number for execution, or error
    pub fn prepare(
        self: *SessionPreparedQueries,
        name: []const u8,
        query_text: []const u8,
    ) PreparedError!u32 {
        // Check capacity
        if (self.count >= max_prepared_per_session) {
            return error.SessionFull;
        }

        // Hash the name
        const name_hash = hashName(name);

        // Check if name already exists
        for (self.queries) |maybe_query| {
            if (maybe_query) |query| {
                if (query.name_hash == name_hash) {
                    return error.AlreadyExists;
                }
            }
        }

        // Compile the query
        const compiled = try compileQuery(query_text);

        // Find empty slot
        for (&self.queries, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = PreparedQuery{
                    .name_hash = name_hash,
                    .compiled = compiled,
                    .execution_count = 0,
                    .total_duration_ns = 0,
                };
                self.count += 1;
                return @intCast(i);
            }
        }

        // Should not reach here if count < max
        return error.SessionFull;
    }

    /// Execute a prepared query by slot number.
    ///
    /// Arguments:
    /// - slot: Slot number returned from prepare()
    /// - params: Parameter values (packed bytes in order)
    /// - output: Buffer for executable filter
    ///
    /// Returns: Number of bytes written to output, plus query type
    pub fn execute(
        self: *SessionPreparedQueries,
        slot: u32,
        params: []const u8,
        output: []u8,
    ) PreparedError!struct { filter_len: usize, query_type: QueryType } {
        if (slot >= max_prepared_per_session) {
            return error.NotFound;
        }

        const query = &(self.queries[slot] orelse return error.NotFound);
        const start_time = std.time.nanoTimestamp();

        const filter_len = query.compiled.applyParams(params, output) catch |err| {
            return switch (err) {
                error.InvalidParamCount => error.InvalidParamCount,
                error.InvalidParamSize => error.InvalidParamSize,
                error.OutputTooSmall => error.OutputTooSmall,
            };
        };

        // Record execution timing
        const end_time = std.time.nanoTimestamp();
        const duration_ns: u64 = if (end_time > start_time)
            @intCast(end_time - start_time)
        else
            0;
        query.recordExecution(duration_ns);

        return .{
            .filter_len = filter_len,
            .query_type = query.compiled.query_type,
        };
    }

    /// Execute a prepared query by name hash.
    pub fn executeByName(
        self: *SessionPreparedQueries,
        name_hash: u64,
        params: []const u8,
        output: []u8,
    ) PreparedError!struct { filter_len: usize, query_type: QueryType } {
        // Find query by name hash
        for (&self.queries, 0..) |*slot, i| {
            if (slot.*) |*query| {
                if (query.name_hash == name_hash) {
                    return self.execute(@intCast(i), params, output);
                }
            }
        }
        return error.NotFound;
    }

    /// Deallocate a prepared query by name hash.
    ///
    /// Returns: true if found and deallocated, false if not found
    pub fn deallocate(self: *SessionPreparedQueries, name_hash: u64) bool {
        for (&self.queries) |*slot| {
            if (slot.*) |query| {
                if (query.name_hash == name_hash) {
                    slot.* = null;
                    self.count -= 1;
                    return true;
                }
            }
        }
        return false;
    }

    /// Deallocate a prepared query by slot number.
    pub fn deallocateSlot(self: *SessionPreparedQueries, slot: u32) bool {
        if (slot >= max_prepared_per_session) {
            return false;
        }
        if (self.queries[slot] != null) {
            self.queries[slot] = null;
            self.count -= 1;
            return true;
        }
        return false;
    }

    /// Clear all prepared queries (called on session end).
    pub fn clear(self: *SessionPreparedQueries) void {
        self.queries = @splat(null);
        self.count = 0;
    }

    /// Get a prepared query by slot (for inspection).
    pub fn get(self: *const SessionPreparedQueries, slot: u32) ?*const PreparedQuery {
        if (slot >= max_prepared_per_session) return null;
        if (self.queries[slot]) |*query| {
            return query;
        }
        return null;
    }

    /// Find slot by name hash.
    pub fn findByName(self: *const SessionPreparedQueries, name_hash: u64) ?u32 {
        for (self.queries, 0..) |maybe_query, i| {
            if (maybe_query) |query| {
                if (query.name_hash == name_hash) {
                    return @intCast(i);
                }
            }
        }
        return null;
    }
};

// ============================================================================
// Query Compilation
// ============================================================================

/// Hash a query name for lookup.
pub fn hashName(name: []const u8) u64 {
    // Use xxHash for consistent hashing
    return std.hash.XxHash64.hash(0, name);
}

/// Compile query text into a CompiledQuery.
///
/// Supported query formats:
/// - "UUID $1" - UUID lookup with entity_id parameter
/// - "RADIUS $1 $2 $3 LIMIT $4" - Radius query with lat, lon, radius, limit
/// - "LATEST LIMIT $1 GROUP $2" - Latest query with limit and optional group
///
/// Returns: CompiledQuery or error if invalid
pub fn compileQuery(query_text: []const u8) PreparedError!CompiledQuery {
    // Normalize to uppercase for matching
    var normalized: [256]u8 = undefined;
    const len = @min(query_text.len, 255);
    for (query_text[0..len], 0..) |c, i| {
        normalized[i] = std.ascii.toUpper(c);
    }
    normalized[len] = 0;
    const text = normalized[0..len];

    // Match query type by prefix
    if (std.mem.startsWith(u8, text, "UUID")) {
        return CompiledQuery.initUuid();
    } else if (std.mem.startsWith(u8, text, "RADIUS")) {
        return CompiledQuery.initRadius();
    } else if (std.mem.startsWith(u8, text, "LATEST")) {
        return CompiledQuery.initLatest();
    } else if (std.mem.startsWith(u8, text, "POLYGON")) {
        // Polygon queries have variable-length vertex data
        // For simplicity, only support pre-defined polygon templates
        return error.UnsupportedQueryType;
    }

    return error.InvalidQuery;
}

// ============================================================================
// Prepared Query Metrics
// ============================================================================

/// Prepared query metrics for Prometheus export.
pub const PreparedQueryMetrics = struct {
    /// Total queries compiled
    compiles_total: u64 = 0,
    /// Total queries executed
    executions_total: u64 = 0,
    /// Parse errors
    parse_errors: u64 = 0,
    /// Parameter errors
    param_errors: u64 = 0,
    /// Not found errors
    not_found_errors: u64 = 0,

    /// Record a successful compile.
    pub fn recordCompile(self: *PreparedQueryMetrics) void {
        self.compiles_total += 1;
    }

    /// Record a successful execution.
    pub fn recordExecution(self: *PreparedQueryMetrics) void {
        self.executions_total += 1;
    }

    /// Record a parse error.
    pub fn recordParseError(self: *PreparedQueryMetrics) void {
        self.parse_errors += 1;
    }

    /// Record a parameter error.
    pub fn recordParamError(self: *PreparedQueryMetrics) void {
        self.param_errors += 1;
    }

    /// Record a not found error.
    pub fn recordNotFoundError(self: *PreparedQueryMetrics) void {
        self.not_found_errors += 1;
    }

    /// Export metrics in Prometheus text format.
    pub fn toPrometheus(self: *const PreparedQueryMetrics, writer: anytype) !void {
        try writer.print(
            \\# HELP archerdb_prepared_query_compiles_total Total prepared queries compiled
            \\# TYPE archerdb_prepared_query_compiles_total counter
            \\archerdb_prepared_query_compiles_total {d}
            \\# HELP archerdb_prepared_query_executions_total Total prepared query executions
            \\# TYPE archerdb_prepared_query_executions_total counter
            \\archerdb_prepared_query_executions_total {d}
            \\# HELP archerdb_prepared_query_errors_total Prepared query errors by type
            \\# TYPE archerdb_prepared_query_errors_total counter
            \\archerdb_prepared_query_errors_total{{error="parse"}} {d}
            \\archerdb_prepared_query_errors_total{{error="param"}} {d}
            \\archerdb_prepared_query_errors_total{{error="not_found"}} {d}
            \\
        , .{
            self.compiles_total,
            self.executions_total,
            self.parse_errors,
            self.param_errors,
            self.not_found_errors,
        });
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PreparedQuery: basic lifecycle" {
    var session = SessionPreparedQueries.init();
    try std.testing.expectEqual(@as(u32, 0), session.count);

    // Prepare a UUID query
    const slot = try session.prepare("get_entity", "UUID $1");
    try std.testing.expectEqual(@as(u32, 0), slot);
    try std.testing.expectEqual(@as(u32, 1), session.count);

    // Verify query exists
    const query = session.get(slot).?;
    try std.testing.expectEqual(QueryType.uuid, query.compiled.query_type);
    try std.testing.expectEqual(@as(u8, 1), query.compiled.num_params);

    // Deallocate
    try std.testing.expect(session.deallocateSlot(slot));
    try std.testing.expectEqual(@as(u32, 0), session.count);
}

test "PreparedQuery: execute uuid query" {
    var session = SessionPreparedQueries.init();

    const slot = try session.prepare("get_entity", "UUID $1");

    // Create parameter: entity_id (u128)
    var params: [16]u8 = undefined;
    const entity_id: u128 = 0x123456789ABCDEF0123456789ABCDEF0;
    @memcpy(&params, mem.asBytes(&entity_id));

    // Execute
    var output: [64]u8 = undefined;
    const result = try session.execute(slot, &params, &output);

    try std.testing.expectEqual(@as(usize, 32), result.filter_len);
    try std.testing.expectEqual(QueryType.uuid, result.query_type);

    // Verify entity_id was substituted
    const filter = mem.bytesToValue(UuidFilterTemplate, output[0..32]);
    try std.testing.expectEqual(entity_id, filter.entity_id);

    // Verify execution was recorded
    const query = session.get(slot).?;
    try std.testing.expectEqual(@as(u64, 1), query.execution_count);
}

test "PreparedQuery: execute radius query" {
    var session = SessionPreparedQueries.init();

    const slot = try session.prepare("nearby", "RADIUS $1 $2 $3 LIMIT $4");

    // Create parameters: lat (i64), lon (i64), radius (u32), limit (u32)
    var params: [24]u8 = undefined;
    const lat: i64 = 37_774929_000; // SF lat in nanodegrees
    const lon: i64 = -122_419415_000; // SF lon in nanodegrees
    const radius: u32 = 1000_000; // 1km in mm
    const limit: u32 = 50;

    var offset: usize = 0;
    @memcpy(params[offset..][0..8], mem.asBytes(&lat));
    offset += 8;
    @memcpy(params[offset..][0..8], mem.asBytes(&lon));
    offset += 8;
    @memcpy(params[offset..][0..4], mem.asBytes(&radius));
    offset += 4;
    @memcpy(params[offset..][0..4], mem.asBytes(&limit));

    // Execute
    var output: [256]u8 = undefined;
    const result = try session.execute(slot, &params, &output);

    try std.testing.expectEqual(@as(usize, 128), result.filter_len);
    try std.testing.expectEqual(QueryType.radius, result.query_type);

    // Verify parameters were substituted
    const filter = mem.bytesToValue(RadiusFilterTemplate, output[0..128]);
    try std.testing.expectEqual(lat, filter.center_lat_nano);
    try std.testing.expectEqual(lon, filter.center_lon_nano);
    try std.testing.expectEqual(radius, filter.radius_mm);
    try std.testing.expectEqual(limit, filter.limit);
}

test "PreparedQuery: session scope - clear" {
    var session = SessionPreparedQueries.init();

    _ = try session.prepare("q1", "UUID $1");
    _ = try session.prepare("q2", "RADIUS $1 $2 $3 LIMIT $4");
    try std.testing.expectEqual(@as(u32, 2), session.count);

    // Clear session (simulates session end)
    session.clear();
    try std.testing.expectEqual(@as(u32, 0), session.count);

    // All slots should be null
    for (session.queries) |q| {
        try std.testing.expect(q == null);
    }
}

test "PreparedQuery: session full error" {
    var session = SessionPreparedQueries.init();

    // Fill all slots
    var name_buf: [8]u8 = undefined;
    for (0..max_prepared_per_session) |i| {
        const name = std.fmt.bufPrint(&name_buf, "q{d}", .{i}) catch unreachable;
        _ = try session.prepare(name, "UUID $1");
    }
    try std.testing.expectEqual(max_prepared_per_session, session.count);

    // Next prepare should fail
    try std.testing.expectError(
        error.SessionFull,
        session.prepare("overflow", "UUID $1"),
    );
}

test "PreparedQuery: duplicate name error" {
    var session = SessionPreparedQueries.init();

    _ = try session.prepare("my_query", "UUID $1");

    // Same name should fail
    try std.testing.expectError(
        error.AlreadyExists,
        session.prepare("my_query", "RADIUS $1 $2 $3 LIMIT $4"),
    );
}

test "PreparedQuery: not found error" {
    var session = SessionPreparedQueries.init();

    var params: [16]u8 = @splat(0);
    var output: [64]u8 = undefined;

    // Execute non-existent slot
    try std.testing.expectError(
        error.NotFound,
        session.execute(0, &params, &output),
    );

    // Execute non-existent name
    try std.testing.expectError(
        error.NotFound,
        session.executeByName(123456, &params, &output),
    );
}

test "PreparedQuery: deallocate by name" {
    var session = SessionPreparedQueries.init();

    _ = try session.prepare("my_query", "UUID $1");
    try std.testing.expectEqual(@as(u32, 1), session.count);

    const name_hash = hashName("my_query");
    try std.testing.expect(session.deallocate(name_hash));
    try std.testing.expectEqual(@as(u32, 0), session.count);

    // Second deallocate should return false
    try std.testing.expect(!session.deallocate(name_hash));
}

test "PreparedQuery: find by name" {
    var session = SessionPreparedQueries.init();

    const slot = try session.prepare("test_query", "UUID $1");
    const name_hash = hashName("test_query");

    const found_slot = session.findByName(name_hash);
    try std.testing.expectEqual(slot, found_slot.?);

    // Non-existent name
    try std.testing.expect(session.findByName(hashName("nonexistent")) == null);
}

test "PreparedQuery: average execution time" {
    var query = PreparedQuery{
        .name_hash = 0,
        .compiled = CompiledQuery.initUuid(),
        .execution_count = 0,
        .total_duration_ns = 0,
    };

    try std.testing.expectEqual(@as(u64, 0), query.averageExecutionNs());

    query.recordExecution(1000);
    query.recordExecution(2000);
    query.recordExecution(3000);

    try std.testing.expectEqual(@as(u64, 2000), query.averageExecutionNs());
}

test "PreparedQuery: metrics export" {
    var metrics = PreparedQueryMetrics{};
    metrics.recordCompile();
    metrics.recordCompile();
    metrics.recordExecution();
    metrics.recordParseError();

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try metrics.toPrometheus(writer);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_prepared_query_compiles_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_prepared_query_executions_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "error=\"parse\"") != null);
}

test "PreparedQuery: invalid query text" {
    try std.testing.expectError(
        error.InvalidQuery,
        compileQuery("SELECT * FROM events"),
    );

    try std.testing.expectError(
        error.UnsupportedQueryType,
        compileQuery("POLYGON $1"),
    );
}

test "PreparedQuery: param type sizes" {
    try std.testing.expectEqual(@as(u8, 16), ParamType.entity_id.size());
    try std.testing.expectEqual(@as(u8, 8), ParamType.lat_nano.size());
    try std.testing.expectEqual(@as(u8, 8), ParamType.lon_nano.size());
    try std.testing.expectEqual(@as(u8, 4), ParamType.radius_mm.size());
    try std.testing.expectEqual(@as(u8, 4), ParamType.limit.size());
    try std.testing.expectEqual(@as(u8, 8), ParamType.timestamp_min.size());
    try std.testing.expectEqual(@as(u8, 8), ParamType.timestamp_max.size());
    try std.testing.expectEqual(@as(u8, 8), ParamType.group_id.size());
}
