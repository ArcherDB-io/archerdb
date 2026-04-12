// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// ArcherDB - High-performance geospatial database
// This file defines the core types and operations for the geospatial state machine.
//
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const vsr = @import("vsr.zig");
const constants = vsr.constants;
const stdx = vsr.stdx;
const maybe = stdx.maybe;

// GeoEvent types for geospatial operations
const geo_event = @import("geo_event.zig");
const geo_state_machine = @import("geo_state_machine.zig");
const ttl = @import("ttl.zig");
const topology_mod = @import("topology.zig");
const prepared_queries = @import("prepared_queries.zig");
const batch_query = @import("batch_query.zig");

// ============================================================================
// ArcherDB Geospatial Types
// ============================================================================

pub const GeoEvent = geo_event.GeoEvent;
pub const GeoEventFlags = geo_event.GeoEventFlags;
pub const QueryUuidFilter = geo_state_machine.QueryUuidFilter;
pub const QueryUuidResponse = geo_state_machine.QueryUuidResponse;
pub const QueryUuidBatchFilter = geo_state_machine.QueryUuidBatchFilter;
pub const QueryUuidBatchResult = geo_state_machine.QueryUuidBatchResult;
pub const QueryRadiusFilter = geo_state_machine.QueryRadiusFilter;
pub const QueryPolygonFilter = geo_state_machine.QueryPolygonFilter;
pub const QueryResponse = geo_state_machine.QueryResponse;
pub const PolygonVertex = geo_state_machine.PolygonVertex;
pub const HoleDescriptor = geo_state_machine.HoleDescriptor;
pub const InsertGeoEventResult = geo_state_machine.InsertGeoEventResult;
pub const InsertGeoEventsResult = geo_state_machine.InsertGeoEventsResult;
pub const DeleteEntityResult = geo_state_machine.DeleteEntityResult;
pub const DeleteEntitiesResult = geo_state_machine.DeleteEntitiesResult;
pub const QueryLatestFilter = geo_state_machine.QueryLatestFilter;

// TTL cleanup types (F2.4.8)
pub const CleanupRequest = ttl.CleanupRequest;
pub const CleanupResponse = ttl.CleanupResponse;

// Manual TTL operation types
pub const TtlOperationResult = ttl.TtlOperationResult;
pub const TtlSetRequest = ttl.TtlSetRequest;
pub const TtlSetResponse = ttl.TtlSetResponse;
pub const TtlExtendRequest = ttl.TtlExtendRequest;
pub const TtlExtendResponse = ttl.TtlExtendResponse;
pub const TtlClearRequest = ttl.TtlClearRequest;
pub const TtlClearResponse = ttl.TtlClearResponse;

// Topology types (Smart Client Discovery)
pub const TopologyRequest = topology_mod.TopologyRequest;
pub const TopologyResponse = topology_mod.TopologyResponse;
pub const TopologyResponseCompact = topology_mod.TopologyResponseCompact;
pub const ShardInfo = topology_mod.ShardInfo;
pub const ShardStatus = topology_mod.ShardStatus;

// Prepared query types (14-05: Dashboard prepared queries)
pub const PreparedQuery = prepared_queries.PreparedQuery;
pub const SessionPreparedQueries = prepared_queries.SessionPreparedQueries;
pub const CompiledQuery = prepared_queries.CompiledQuery;
pub const PreparedQueryMetrics = prepared_queries.PreparedQueryMetrics;

// Batch query types (14-04: Dashboard batch queries)
pub const BatchQueryRequest = batch_query.BatchQueryRequest;
pub const BatchQueryResponse = batch_query.BatchQueryResponse;
pub const BatchQueryEntry = batch_query.BatchQueryEntry;
pub const BatchQueryResultEntry = batch_query.BatchQueryResultEntry;
pub const BatchQueryType = batch_query.QueryType;

// ============================================================================
// ArcherDB Admin Request/Response Types
// ============================================================================

/// Request for archerdb_ping operation (F1.2.6).
/// Payload is ignored by the server; included for consistent wire sizing.
pub const PingRequest = extern struct {
    /// Caller-provided ping payload (optional).
    ping_data: u64 = 0,
};

/// Request for archerdb_get_status operation (F1.2.6).
/// Payload is ignored by the server; reserved for future use.
pub const StatusRequest = extern struct {
    reserved: u64 = 0,
};

/// Response to archerdb_ping operation (F1.2.6).
/// Simple "pong" response (4 bytes: 'p' 'o' 'n' 'g').
pub const PingResponse = extern struct {
    pong: u32,

    comptime {
        assert(@sizeOf(PingResponse) == 4);
        assert(stdx.no_padding(PingResponse));
    }
};

/// Response to archerdb_get_status operation (F1.2.6).
/// Returns current server status information (64 bytes).
pub fn statusIndexResizeName(status: u8) []const u8 {
    return switch (status) {
        0 => "idle",
        1 => "in_progress",
        2 => "completing",
        3 => "aborted",
        else => "unknown",
    };
}

pub fn statusMembershipStateName(state: u8) []const u8 {
    return switch (state) {
        0 => "stable",
        1 => "joint",
        2 => "transitioning",
        else => "unknown",
    };
}

pub const StatusResponse = extern struct {
    /// RAM index entry count.
    ram_index_count: u64,
    /// RAM index capacity.
    ram_index_capacity: u64,
    /// RAM index load factor (percentage * 100).
    ram_index_load_pct: u32,
    /// Padding for alignment.
    _padding: u32 = 0,
    /// Tombstone count.
    tombstone_count: u64,
    /// Total TTL expirations.
    ttl_expirations: u64,
    /// Total deletions.
    deletion_count: u64,
    /// Index resize status code (0=idle, 1=in_progress, 2=completing, 3=aborted).
    index_resize_status: u8 = 0,
    /// Membership state code (0=stable, 1=joint, 2=transitioning).
    membership_state: u8 = 0,
    /// Reserved for future packing within the status extension block.
    _status_padding: u16 = 0,
    /// Index resize progress in percentage * 100 (range 0..10000).
    index_resize_progress: u32 = 0,
    /// Number of voting members in the current cluster configuration.
    membership_voters_count: u32 = 0,
    /// Number of learner members in the current cluster configuration.
    membership_learners_count: u32 = 0,

    pub fn indexResizeStatusName(self: *const StatusResponse) []const u8 {
        return statusIndexResizeName(self.index_resize_status);
    }

    pub fn membershipStateName(self: *const StatusResponse) []const u8 {
        return statusMembershipStateName(self.membership_state);
    }

    pub fn indexResizeProgressPct(self: *const StatusResponse) f64 {
        return @as(f64, @floatFromInt(self.index_resize_progress)) / 100.0;
    }

    comptime {
        assert(@sizeOf(StatusResponse) == 64);
        assert(stdx.no_padding(StatusResponse));
    }
};

test "StatusResponse helper methods decode operator status extensions" {
    const response = std.mem.zeroInit(StatusResponse, .{
        .index_resize_status = 2,
        .membership_state = 1,
        .index_resize_progress = 5050,
        .membership_voters_count = 5,
        .membership_learners_count = 2,
    });

    try std.testing.expectEqualStrings("completing", response.indexResizeStatusName());
    try std.testing.expectEqualStrings("joint", response.membershipStateName());
    try std.testing.expectEqual(@as(f64, 50.5), response.indexResizeProgressPct());
    try std.testing.expectEqual(@as(u32, 5), response.membership_voters_count);
    try std.testing.expectEqual(@as(u32, 2), response.membership_learners_count);
}

// ============================================================================
// ArcherDB Prepared Query Request/Response Types (14-05)
// ============================================================================

/// Request for prepare_query operation.
/// Wire format: [PrepareQueryRequest: 16 bytes][name: name_len bytes][query: query_len bytes]
pub const PrepareQueryRequest = extern struct {
    /// Length of query name in bytes
    name_len: u32,
    /// Length of query text in bytes
    query_len: u32,
    /// Reserved for future use
    reserved: [8]u8 = @splat(0),

    comptime {
        assert(@sizeOf(PrepareQueryRequest) == 16);
        assert(stdx.no_padding(PrepareQueryRequest));
    }
};

/// Response for prepare_query operation.
pub const PrepareQueryResult = extern struct {
    /// Slot number for execution (0xFFFFFFFF on error)
    slot: u32,
    /// Status: 0 = success, non-zero = error code
    status: u32,
    /// Reserved for future use
    reserved: [8]u8 = @splat(0),

    comptime {
        assert(@sizeOf(PrepareQueryResult) == 16);
        assert(stdx.no_padding(PrepareQueryResult));
    }

    /// Status codes for prepare result
    pub const Status = enum(u32) {
        ok = 0,
        session_full = 1,
        already_exists = 2,
        invalid_query = 3,
        unsupported_query_type = 4,
    };

    pub fn success(slot: u32) PrepareQueryResult {
        return .{ .slot = slot, .status = 0 };
    }

    pub fn err(status: Status) PrepareQueryResult {
        return .{ .slot = 0xFFFFFFFF, .status = @intFromEnum(status) };
    }
};

/// Request for execute_prepared operation.
/// Wire format: [ExecutePreparedRequest: 16 bytes][params: variable length]
pub const ExecutePreparedRequest = extern struct {
    /// Slot number from prepare_query result
    slot: u32,
    /// Number of parameters
    param_count: u32,
    /// Reserved for future use
    reserved: [8]u8 = @splat(0),

    comptime {
        assert(@sizeOf(ExecutePreparedRequest) == 16);
        assert(stdx.no_padding(ExecutePreparedRequest));
    }
};

/// Request for deallocate_prepared operation.
pub const DeallocatePreparedRequest = extern struct {
    /// Slot number to deallocate (0xFFFFFFFF for all)
    slot: u32,
    /// Reserved/padding for alignment
    _padding: u32 = 0,
    /// Name hash for deallocate by name (0 to use slot)
    name_hash: u64,

    comptime {
        assert(@sizeOf(DeallocatePreparedRequest) == 16);
        assert(stdx.no_padding(DeallocatePreparedRequest));
    }
};

/// Response for deallocate_prepared operation.
pub const DeallocatePreparedResult = extern struct {
    /// 1 if deallocated, 0 if not found
    deallocated: u32,
    /// Reserved for future use
    reserved: [12]u8 = @splat(0),

    comptime {
        assert(@sizeOf(DeallocatePreparedResult) == 16);
        assert(stdx.no_padding(DeallocatePreparedResult));
    }
};

// ============================================================================
// ArcherDB Operations
// ============================================================================

pub const Operation = enum(u8) {
    /// VSR pulse operation (heartbeat)
    pulse = constants.vsr_operations_reserved + 0,

    // ArcherDB geospatial operations (F1.2)
    insert_events = constants.vsr_operations_reserved + 18,
    upsert_events = constants.vsr_operations_reserved + 19,
    delete_entities = constants.vsr_operations_reserved + 20,
    query_uuid = constants.vsr_operations_reserved + 21,
    query_radius = constants.vsr_operations_reserved + 22,
    query_polygon = constants.vsr_operations_reserved + 23,
    query_latest = constants.vsr_operations_reserved + 26, // F1.3.3: Most recent events globally
    query_uuid_batch = constants.vsr_operations_reserved + 28, // F1.3.4: Batch UUID lookup

    // ArcherDB admin operations (F1.2.6)
    archerdb_ping = constants.vsr_operations_reserved + 24,
    archerdb_get_status = constants.vsr_operations_reserved + 25,

    // ArcherDB TTL cleanup operation (F2.4.8)
    cleanup_expired = constants.vsr_operations_reserved + 27,

    // ArcherDB topology discovery operation (Smart Client)
    get_topology = constants.vsr_operations_reserved + 29,

    // ArcherDB Manual TTL Operations
    ttl_set = constants.vsr_operations_reserved + 30,
    ttl_extend = constants.vsr_operations_reserved + 31,
    ttl_clear = constants.vsr_operations_reserved + 32,

    // ArcherDB Batch Query Operation (14-04: Dashboard batch queries)
    batch_query = constants.vsr_operations_reserved + 33,

    // ArcherDB Prepared Query Operations (14-05: Dashboard prepared queries)
    prepare_query = constants.vsr_operations_reserved + 34,
    execute_prepared = constants.vsr_operations_reserved + 35,
    deallocate_prepared = constants.vsr_operations_reserved + 36,

    pub fn EventType(comptime operation: Operation) type {
        return switch (operation) {
            .pulse => void,

            // ArcherDB geospatial operations
            .insert_events => GeoEvent,
            .upsert_events => GeoEvent,
            .delete_entities => u128, // entity_id to delete
            .query_uuid => QueryUuidFilter,
            .query_uuid_batch => QueryUuidBatchFilter,
            .query_radius => QueryRadiusFilter,
            .query_polygon => QueryPolygonFilter,
            .query_latest => QueryLatestFilter,

            // ArcherDB admin operations (F1.2.6)
            .archerdb_ping => PingRequest,
            .archerdb_get_status => StatusRequest,

            // ArcherDB TTL cleanup (F2.4.8)
            .cleanup_expired => CleanupRequest,

            // ArcherDB topology discovery (Smart Client)
            .get_topology => TopologyRequest,

            // ArcherDB Manual TTL Operations
            .ttl_set => TtlSetRequest,
            .ttl_extend => TtlExtendRequest,
            .ttl_clear => TtlClearRequest,

            // ArcherDB Batch Query (14-04)
            .batch_query => BatchQueryRequest,

            // ArcherDB Prepared Query Operations (14-05)
            .prepare_query => PrepareQueryRequest,
            .execute_prepared => ExecutePreparedRequest,
            .deallocate_prepared => DeallocatePreparedRequest,
        };
    }

    pub fn ResultType(comptime operation: Operation) type {
        return switch (operation) {
            .pulse => void,

            // ArcherDB geospatial operations
            .insert_events => InsertGeoEventsResult,
            .upsert_events => InsertGeoEventsResult,
            .delete_entities => DeleteEntitiesResult,
            .query_uuid => QueryUuidResponse,
            .query_uuid_batch => QueryUuidBatchResult,
            .query_radius => GeoEvent,
            .query_polygon => GeoEvent,
            .query_latest => GeoEvent,

            // ArcherDB admin operations (F1.2.6)
            .archerdb_ping => PingResponse,
            .archerdb_get_status => StatusResponse,

            // ArcherDB TTL cleanup (F2.4.8)
            .cleanup_expired => CleanupResponse,

            // ArcherDB topology discovery (Smart Client)
            // Note: Server returns compact response (max 16 shards) to fit in lite config buffers
            .get_topology => TopologyResponseCompact,

            // ArcherDB Manual TTL Operations
            .ttl_set => TtlSetResponse,
            .ttl_extend => TtlExtendResponse,
            .ttl_clear => TtlClearResponse,

            // ArcherDB Batch Query (14-04)
            .batch_query => BatchQueryResponse,

            // ArcherDB Prepared Query Operations (14-05)
            .prepare_query => PrepareQueryResult,
            .execute_prepared => GeoEvent, // Returns query results (same as radius/polygon)
            .deallocate_prepared => DeallocatePreparedResult,
        };
    }

    /// Inline function so that `operation` can be known at comptime.
    pub inline fn event_size(operation: Operation) u32 {
        return switch (operation) {
            inline else => |operation_comptime| @sizeOf(operation_comptime.EventType()),
        };
    }

    /// Inline function so that `operation` can be known at comptime.
    pub inline fn result_size(operation: Operation) u32 {
        return switch (operation) {
            inline else => |operation_comptime| @sizeOf(operation_comptime.ResultType()),
        };
    }

    /// Whether the operation supports multiple events per batch.
    pub inline fn is_batchable(operation: Operation) bool {
        return switch (operation) {
            .pulse => false,

            // ArcherDB geospatial batch operations
            .insert_events => true,
            .upsert_events => true,
            .delete_entities => true,

            // ArcherDB query operations (single filter per request)
            .query_uuid => false,
            .query_uuid_batch => false, // Variable-length, not batchable
            .query_radius => false,
            .query_polygon => false,
            .query_latest => false,

            // ArcherDB admin operations (F1.2.6)
            .archerdb_ping => false,
            .archerdb_get_status => false,

            // ArcherDB TTL cleanup (F2.4.8)
            .cleanup_expired => false,

            // ArcherDB topology discovery (Smart Client)
            .get_topology => false,

            // ArcherDB Manual TTL Operations
            .ttl_set => false,
            .ttl_extend => false,
            .ttl_clear => false,

            // ArcherDB Batch Query (14-04)
            .batch_query => false,

            // ArcherDB Prepared Query Operations (14-05)
            .prepare_query => false,
            .execute_prepared => false,
            .deallocate_prepared => false,
        };
    }

    /// Whether the operation is multi-batch encoded.
    pub inline fn is_multi_batch(operation: Operation) bool {
        return switch (operation) {
            .pulse => false,

            // ArcherDB geospatial operations - single batch for now (F1.3.5)
            .insert_events,
            .upsert_events,
            .delete_entities,
            .query_uuid,
            .query_uuid_batch,
            .query_latest,
            .query_radius,
            .query_polygon,
            => false,

            // ArcherDB admin operations (F1.2.6)
            .archerdb_ping => false,
            .archerdb_get_status => false,

            // ArcherDB TTL cleanup (F2.4.8)
            .cleanup_expired => false,

            // ArcherDB topology discovery (Smart Client)
            .get_topology => false,

            // ArcherDB Manual TTL Operations
            .ttl_set => false,
            .ttl_extend => false,
            .ttl_clear => false,

            // ArcherDB Batch Query (14-04)
            .batch_query => false,

            // ArcherDB Prepared Query Operations (14-05)
            .prepare_query => false,
            .execute_prepared => false,
            .deallocate_prepared => false,
        };
    }

    /// Whether the operation has variable-length request body.
    pub inline fn is_variable_length(operation: Operation) bool {
        return switch (operation) {
            // query_polygon body = QueryPolygonFilter + PolygonVertex[]
            .query_polygon => true,
            // query_uuid_batch body = QueryUuidBatchFilter + entity_ids[]
            .query_uuid_batch => true,
            // batch_query body = BatchQueryRequest + variable queries
            .batch_query => true,
            // prepare_query body = PrepareQueryRequest + name + query_text
            .prepare_query => true,
            // execute_prepared body = ExecutePreparedRequest + params
            .execute_prepared => true,
            else => false,
        };
    }

    pub fn isReadOnly(self: Operation) bool {
        return switch (self) {
            .query_uuid,
            .query_uuid_batch,
            .query_radius,
            .query_polygon,
            .query_latest,
            .archerdb_ping,
            .archerdb_get_status,
            .get_topology,
            .batch_query,
            .execute_prepared,
            => true,
            .pulse,
            .insert_events,
            .upsert_events,
            .delete_entities,
            .cleanup_expired,
            .ttl_set,
            .ttl_extend,
            .ttl_clear,
            .prepare_query,
            .deallocate_prepared,
            => false,
        };
    }

    /// The maximum number of events per batch.
    pub inline fn event_max(operation: Operation, batch_size_limit: u32) u32 {
        assert(batch_size_limit > 0);
        assert(batch_size_limit <= constants.message_body_size_max);

        const event_size_bytes: u32 = operation.event_size();
        maybe(event_size_bytes == 0);
        const result_size_bytes: u32 = operation.result_size();
        assert(result_size_bytes > 0);

        if (!operation.is_multi_batch()) {
            return if (event_size_bytes == 0)
                @divFloor(constants.message_body_size_max, result_size_bytes)
            else
                @min(
                    @divFloor(batch_size_limit, event_size_bytes),
                    @divFloor(constants.message_body_size_max, result_size_bytes),
                );
        }
        assert(operation.is_multi_batch());

        const reply_trailer_size_min: u32 = vsr.multi_batch.trailer_total_size(.{
            .element_size = result_size_bytes,
            .batch_count = 1,
        });
        assert(reply_trailer_size_min > 0);
        assert(reply_trailer_size_min < batch_size_limit);

        if (event_size_bytes == 0) {
            return @divFloor(
                constants.message_body_size_max - reply_trailer_size_min,
                result_size_bytes,
            );
        } else {
            const request_trailer_size_min: u32 = vsr.multi_batch.trailer_total_size(.{
                .element_size = event_size_bytes,
                .batch_count = 1,
            });
            assert(request_trailer_size_min > 0);
            assert(request_trailer_size_min < constants.message_body_size_max);

            return @min(
                @divFloor(batch_size_limit - request_trailer_size_min, event_size_bytes),
                @divFloor(
                    constants.message_body_size_max - reply_trailer_size_min,
                    result_size_bytes,
                ),
            );
        }
    }

    /// The maximum number of results per batch.
    pub inline fn result_max(operation: Operation, batch_size_limit: u32) u32 {
        assert(batch_size_limit > 0);
        assert(batch_size_limit <= constants.message_body_size_max);
        if (operation.is_batchable()) {
            return operation.event_max(batch_size_limit);
        }
        assert(!operation.is_batchable());

        const result_size_bytes = operation.result_size();
        assert(result_size_bytes > 0);

        if (!operation.is_multi_batch()) {
            return @divFloor(constants.message_body_size_max, result_size_bytes);
        }
        assert(operation.is_multi_batch());

        const reply_trailer_size_min: u32 = vsr.multi_batch.trailer_total_size(.{
            .element_size = result_size_bytes,
            .batch_count = 1,
        });
        return @divFloor(
            constants.message_body_size_max - reply_trailer_size_min,
            result_size_bytes,
        );
    }

    /// Returns the expected number of results for a given batch.
    pub inline fn result_count_expected(
        operation: Operation,
        batch: []const u8,
    ) u32 {
        return switch (operation) {
            .pulse => 0,

            // ArcherDB geospatial batchable operations
            inline .insert_events,
            .upsert_events,
            .delete_entities,
            => |operation_comptime| count: {
                comptime assert(operation_comptime.is_batchable());
                if (batch.len == 0) return 0;

                const event_size_bytes: u32 = operation_comptime.event_size();
                comptime assert(event_size_bytes > 0);
                assert(batch.len % event_size_bytes == 0);

                break :count @intCast(@divExact(batch.len, event_size_bytes));
            },

            // ArcherDB geospatial query operations (fixed-size filters)
            .query_uuid => count: {
                comptime assert(!Operation.query_uuid.is_batchable());

                const Filter = QueryUuidFilter;
                comptime assert(@sizeOf(Filter) > 0);
                assert(batch.len == @sizeOf(Filter));
                maybe(!std.mem.isAligned(@intFromPtr(batch.ptr), @alignOf(Filter)));

                break :count 1;
            },

            inline .query_latest,
            .query_radius,
            => |operation_comptime| count: {
                comptime assert(!operation_comptime.is_batchable());

                const Filter = operation_comptime.EventType();
                comptime assert(@sizeOf(Filter) > 0);
                assert(batch.len == @sizeOf(Filter));
                maybe(!std.mem.isAligned(@intFromPtr(batch.ptr), @alignOf(Filter)));

                const filter: Filter = std.mem.bytesToValue(Filter, batch);
                maybe(filter.limit == 0);

                break :count @min(
                    filter.limit,
                    operation_comptime.result_max(constants.message_body_size_max),
                );
            },

            // ArcherDB polygon query (variable-length: header + vertices + holes)
            .query_polygon => count: {
                comptime assert(!Operation.query_polygon.is_batchable());
                comptime assert(Operation.query_polygon.is_variable_length());

                const Filter = QueryPolygonFilter;
                comptime assert(@sizeOf(Filter) == 128);

                // Must have at least the header
                if (batch.len < @sizeOf(Filter)) {
                    break :count 0;
                }

                const filter: Filter = std.mem.bytesToValue(Filter, batch[0..@sizeOf(Filter)]);
                maybe(filter.limit == 0);

                break :count @min(
                    filter.limit,
                    Operation.query_polygon.result_max(constants.message_body_size_max),
                );
            },

            // ArcherDB batch UUID query (variable-length: header + entity_ids)
            .query_uuid_batch => count: {
                comptime assert(!Operation.query_uuid_batch.is_batchable());
                comptime assert(Operation.query_uuid_batch.is_variable_length());

                const Filter = QueryUuidBatchFilter;
                comptime assert(@sizeOf(Filter) == 16);

                // Must have at least the header
                if (batch.len < @sizeOf(Filter)) {
                    break :count 0;
                }

                const filter: Filter = std.mem.bytesToValue(Filter, batch[0..@sizeOf(Filter)]);

                // For batch UUID, result count = count of UUIDs (each may return 0 or 1 event)
                // Maximum is the count itself since each UUID returns at most one event
                break :count @min(
                    filter.count,
                    QueryUuidBatchFilter.max_count,
                );
            },

            // ArcherDB admin operations (F1.2.6) - always return exactly 1 result
            .archerdb_ping, .archerdb_get_status => 1,

            // ArcherDB TTL cleanup (F2.4.8) - returns exactly 1 CleanupResponse
            .cleanup_expired => 1,

            // ArcherDB topology discovery (Smart Client) - returns exactly 1 TopologyResponse
            .get_topology => 1,

            // Manual TTL operations - each returns exactly 1 response
            .ttl_set, .ttl_extend, .ttl_clear => 1,

            // Batch query - returns 1 BatchQueryResponse (variable-length body)
            .batch_query => 1,

            // Prepared query operations - return 1 result each
            .prepare_query => 1,
            .execute_prepared => Operation.query_radius.result_max(constants.message_body_size_max),
            .deallocate_prepared => 1,
        };
    }

    pub fn from_vsr(operation: vsr.Operation) ?Operation {
        if (operation == .pulse) return .pulse;
        if (operation.vsr_reserved()) return null;

        return vsr.Operation.to(Operation, operation);
    }

    pub fn to_vsr(operation: Operation) vsr.Operation {
        return vsr.Operation.from(Operation, operation);
    }
};

// ============================================================================
// Compile-time Checks
// ============================================================================

comptime {
    const target = builtin.target;

    if (target.os.tag != .linux and !target.os.tag.isDarwin()) {
        @compileError("linux or macos is required for io");
    }

    // We require little-endian architectures everywhere for efficient network deserialization:
    if (target.cpu.arch.endian() != .little) {
        @compileError("big-endian systems not supported");
    }

    // Permit all optimize modes so build matrices can include Debug, ReleaseSafe,
    // ReleaseFast, and ReleaseSmall artifacts.
    switch (builtin.mode) {
        .Debug, .ReleaseSafe, .ReleaseFast, .ReleaseSmall => {},
    }
}
