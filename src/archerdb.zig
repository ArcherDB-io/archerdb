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

// ============================================================================
// ArcherDB Geospatial Types
// ============================================================================

pub const GeoEvent = geo_event.GeoEvent;
pub const GeoEventFlags = geo_event.GeoEventFlags;
pub const QueryUuidFilter = geo_state_machine.QueryUuidFilter;
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

// ============================================================================
// ArcherDB Admin Response Types
// ============================================================================

/// Response to archerdb_ping operation (F1.2.6).
/// Simple echo to verify cluster connectivity at the state machine level.
pub const PingResponse = extern struct {
    /// Server timestamp when ping was processed
    timestamp: u64,
    /// Reserved for future use
    reserved: [120]u8 = @splat(0),

    comptime {
        assert(@sizeOf(PingResponse) == 128);
        assert(stdx.no_padding(PingResponse));
    }
};

/// Response to archerdb_get_status operation (F1.2.6).
/// Returns current cluster and node status information.
pub const StatusResponse = extern struct {
    /// Current view number (monotonically increasing)
    view: u64,
    /// Most recent commit timestamp
    commit_timestamp: u64,
    /// Number of entities in RAM index
    entity_count: u64,
    /// Checkpoint operation number
    checkpoint_op: u64,
    /// Current operation number (log head)
    log_head_op: u64,
    /// Replica index (0-based)
    replica_index: u8,
    /// Total replica count in cluster
    replica_count: u8,
    /// Status flags (bit 0: is_primary, bit 1: is_syncing)
    status_flags: u8,
    /// Reserved for alignment
    reserved_byte: u8 = 0,
    /// Reserved for future use
    reserved: [84]u8 = @splat(0),

    comptime {
        assert(@sizeOf(StatusResponse) == 128);
        assert(stdx.no_padding(StatusResponse));
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
            .archerdb_ping => void,
            .archerdb_get_status => void,

            // ArcherDB TTL cleanup (F2.4.8)
            .cleanup_expired => CleanupRequest,
        };
    }

    pub fn ResultType(comptime operation: Operation) type {
        return switch (operation) {
            .pulse => void,

            // ArcherDB geospatial operations
            .insert_events => InsertGeoEventsResult,
            .upsert_events => InsertGeoEventsResult,
            .delete_entities => DeleteEntitiesResult,
            .query_uuid => GeoEvent,
            .query_uuid_batch => QueryUuidBatchResult,
            .query_radius => GeoEvent,
            .query_polygon => GeoEvent,
            .query_latest => GeoEvent,

            // ArcherDB admin operations (F1.2.6)
            .archerdb_ping => PingResponse,
            .archerdb_get_status => StatusResponse,

            // ArcherDB TTL cleanup (F2.4.8)
            .cleanup_expired => CleanupResponse,
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
        };
    }

    /// Whether the operation has variable-length request body.
    pub inline fn is_variable_length(operation: Operation) bool {
        return switch (operation) {
            // query_polygon body = QueryPolygonFilter + PolygonVertex[]
            .query_polygon => true,
            // query_uuid_batch body = QueryUuidBatchFilter + entity_ids[]
            .query_uuid_batch => true,
            else => false,
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
            inline .query_uuid,
            .query_latest,
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
                comptime assert(@sizeOf(Filter) == 8);

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

    if (target.os.tag != .linux and !target.os.tag.isDarwin() and target.os.tag != .windows) {
        @compileError("linux, windows or macos is required for io");
    }

    // We require little-endian architectures everywhere for efficient network deserialization:
    if (target.cpu.arch.endian() != .little) {
        @compileError("big-endian systems not supported");
    }

    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {},
        .ReleaseFast, .ReleaseSmall => @compileError("safety checks are required for correctness"),
    }
}
