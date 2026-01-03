//! GeoStateMachine - ArcherDB's geospatial state machine implementation.
//!
//! This module implements the StateMachine interface required by VSR,
//! handling geospatial operations on GeoEvent data.
//!
//! The state machine follows TigerBeetle's three-phase execution model:
//! 1. prepare() - Calculate timestamps (primary only, before consensus)
//! 2. prefetch() - Load required data into cache (async I/O)
//! 3. commit() - Apply state changes (deterministic, after consensus)

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const log = std.log.scoped(.geo_state_machine);

const stdx = @import("stdx");
const maybe = stdx.maybe;

const constants = @import("constants.zig");
const GeoEvent = @import("geo_event.zig").GeoEvent;
const GeoEventFlags = @import("geo_event.zig").GeoEventFlags;
const vsr = @import("vsr.zig");
const ScopeCloseMode = @import("lsm/tree.zig").ScopeCloseMode;
const ForestType = @import("lsm/forest.zig").ForestType;

const MultiBatchEncoder = vsr.multi_batch.MultiBatchEncoder;
const MultiBatchDecoder = vsr.multi_batch.MultiBatchDecoder;

// ============================================================================
// Tree IDs for LSM Storage
// ============================================================================

/// LSM tree identifiers for GeoEvent storage.
/// Each tree provides a different index over GeoEvent data.
pub const tree_ids = struct {
    pub const GeoEventTree = .{
        /// Primary index: composite ID (S2 cell << 64 | timestamp)
        .id = 1,
        /// Secondary index: entity_id for UUID lookups
        .entity_id = 2,
        /// Secondary index: correlation_id for trip/session queries
        .correlation_id = 3,
        /// Secondary index: group_id for fleet/region queries
        .group_id = 4,
        /// Secondary index: timestamp for time-range queries
        .timestamp = 5,
    };
};

// ============================================================================
// Result Types
// ============================================================================

/// Result codes for GeoEvent insert operations.
/// Error codes are ordered by descending precedence.
pub const InsertGeoEventResult = enum(u32) {
    ok = 0,
    linked_event_failed = 1,
    linked_event_chain_open = 2,
    timestamp_must_be_zero = 3,
    reserved_field = 4,
    reserved_flag = 5,
    id_must_not_be_zero = 6,
    entity_id_must_not_be_zero = 7,
    invalid_coordinates = 8,
    lat_out_of_range = 9,
    lon_out_of_range = 10,
    exists_with_different_entity_id = 11,
    exists_with_different_coordinates = 12,
    exists = 13,
    heading_out_of_range = 14,
    ttl_invalid = 15,

    comptime {
        const values = std.enums.values(InsertGeoEventResult);
        for (0..values.len) |index| {
            const result: InsertGeoEventResult = @enumFromInt(index);
            _ = result;
        }
    }
};

/// Result codes for GeoEvent delete operations.
pub const DeleteEntityResult = enum(u32) {
    ok = 0,
    linked_event_failed = 1,
    entity_id_must_not_be_zero = 2,
    entity_not_found = 3,
};

/// Result structure for insert operations.
pub const InsertGeoEventsResult = extern struct {
    index: u32,
    result: InsertGeoEventResult,

    comptime {
        assert(@sizeOf(InsertGeoEventsResult) == 8);
        assert(stdx.no_padding(InsertGeoEventsResult));
    }
};

/// Result structure for delete operations.
pub const DeleteEntitiesResult = extern struct {
    index: u32,
    result: DeleteEntityResult,

    comptime {
        assert(@sizeOf(DeleteEntitiesResult) == 8);
        assert(stdx.no_padding(DeleteEntitiesResult));
    }
};

// ============================================================================
// Query Filters
// ============================================================================

/// Filter for UUID lookup queries.
pub const QueryUuidFilter = extern struct {
    entity_id: u128,
    reserved: [112]u8 = @splat(0),

    comptime {
        assert(@sizeOf(QueryUuidFilter) == 128);
        assert(stdx.no_padding(QueryUuidFilter));
    }
};

/// Filter for radius queries.
pub const QueryRadiusFilter = extern struct {
    /// Center latitude in nanodegrees
    center_lat_nano: i64,
    /// Center longitude in nanodegrees
    center_lon_nano: i64,
    /// Radius in millimeters
    radius_mm: u32,
    /// Maximum results to return
    limit: u32,
    /// Minimum timestamp (inclusive, 0 = no filter)
    timestamp_min: u64,
    /// Maximum timestamp (inclusive, 0 = no filter)
    timestamp_max: u64,
    /// Group ID filter (0 = no filter)
    group_id: u64,
    /// Reserved for future use
    reserved: [80]u8 = @splat(0),

    comptime {
        assert(@sizeOf(QueryRadiusFilter) == 128);
        assert(stdx.no_padding(QueryRadiusFilter));
    }
};

/// Filter for polygon queries.
pub const QueryPolygonFilter = extern struct {
    /// Number of vertices in polygon (vertices follow in message body)
    vertex_count: u32,
    /// Maximum results to return
    limit: u32,
    /// Minimum timestamp (inclusive, 0 = no filter)
    timestamp_min: u64,
    /// Maximum timestamp (inclusive, 0 = no filter)
    timestamp_max: u64,
    /// Group ID filter (0 = no filter)
    group_id: u64,
    /// Reserved for future use
    reserved: [96]u8 = @splat(0),

    comptime {
        assert(@sizeOf(QueryPolygonFilter) == 128);
        assert(stdx.no_padding(QueryPolygonFilter));
    }
};

/// Polygon vertex (lat/lon pair).
pub const PolygonVertex = extern struct {
    lat_nano: i64,
    lon_nano: i64,

    comptime {
        assert(@sizeOf(PolygonVertex) == 16);
        assert(stdx.no_padding(PolygonVertex));
    }
};

// ============================================================================
// State Machine Implementation
// ============================================================================

/// Creates a GeoStateMachine type parameterized by Storage.
pub fn GeoStateMachineType(comptime Storage: type) type {
    return struct {
        const GeoStateMachine = @This();

        /// The operation type exported for client protocol.
        pub const Operation = @import("archerdb.zig").Operation;

        // TODO(F1.2): Define Forest type for GeoEvent storage
        // pub const Forest = ForestType(Storage, tree_ids);

        /// Prepare timestamp for deterministic execution.
        prepare_timestamp: u64 = 0,

        /// Callback for async open completion.
        open_callback: ?*const fn (*GeoStateMachine) void = null,

        /// Callback for async prefetch completion.
        prefetch_callback: ?*const fn (*GeoStateMachine) void = null,

        /// Callback for async compact completion.
        compact_callback: ?*const fn (*GeoStateMachine) void = null,

        /// Batch size limit for this state machine.
        batch_size_limit: u32,

        // ====================================================================
        // Initialization
        // ====================================================================

        pub fn init(
            allocator: std.mem.Allocator,
            storage: *Storage,
            batch_size_limit: u32,
        ) !GeoStateMachine {
            _ = allocator;
            _ = storage;

            return GeoStateMachine{
                .batch_size_limit = batch_size_limit,
            };
        }

        pub fn deinit(self: *GeoStateMachine, allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
            // TODO(F1.1.7): Cleanup resources
        }

        // ====================================================================
        // StateMachine Interface
        // ====================================================================

        /// Open the state machine for recovery.
        /// Called during replica startup to restore state from storage.
        ///
        /// Implementation: F1.1.7
        pub fn open(self: *GeoStateMachine, callback: *const fn (*GeoStateMachine) void) void {
            assert(self.open_callback == null);
            self.open_callback = callback;

            // TODO(F1.1.7): Open forest, restore prepare_timestamp from superblock
            // For now, immediately invoke callback
            if (self.open_callback) |cb| {
                self.open_callback = null;
                cb(self);
            }
        }

        /// Prepare phase - calculate timestamp delta before consensus.
        /// Called only on primary when converting client request to prepare.
        ///
        /// The timestamp delta ensures each event in a batch gets a unique timestamp.
        /// Write operations increment by event count; read operations return 0.
        pub fn prepare(
            self: *GeoStateMachine,
            operation: Operation,
            message_body_used: []align(16) const u8,
        ) void {
            assert(message_body_used.len <= self.batch_size_limit);

            const delta_ns: u64 = self.prepare_delta_nanoseconds(operation, message_body_used);
            maybe(delta_ns == 0);
            self.prepare_timestamp += delta_ns;
        }

        /// Returns the logical time increment (in nanoseconds) for the batch.
        /// Write operations increment by event count for unique timestamps.
        /// Read operations return 0 (no state modification).
        fn prepare_delta_nanoseconds(
            self: *const GeoStateMachine,
            operation: Operation,
            batch: []const u8,
        ) u64 {
            assert(batch.len <= self.batch_size_limit);

            const event_size = operation.event_size();
            if (event_size == 0) return 0;

            return switch (operation) {
                // Write operations: increment by event count
                .create_accounts => @divExact(batch.len, event_size),
                .create_transfers => @divExact(batch.len, event_size),

                // TODO(F1.2): Add GeoEvent operations here
                // .insert_events => @divExact(batch.len, @sizeOf(GeoEvent)),
                // .upsert_events => @divExact(batch.len, @sizeOf(GeoEvent)),
                // .delete_entities => @divExact(batch.len, @sizeOf(u128)),

                // Pulse: max events that could be processed
                .pulse => batch_max_events(),

                // Read operations: no timestamp increment
                .lookup_accounts,
                .lookup_transfers,
                .get_account_transfers,
                .get_account_balances,
                .query_accounts,
                .query_transfers,
                .get_change_events,
                => 0,

                // Deprecated unbatched operations (TigerBeetle compatibility)
                .deprecated_create_accounts_unbatched => @divExact(batch.len, event_size),
                .deprecated_create_transfers_unbatched => @divExact(batch.len, event_size),
                .deprecated_lookup_accounts_unbatched,
                .deprecated_lookup_transfers_unbatched,
                .deprecated_get_account_transfers_unbatched,
                .deprecated_get_account_balances_unbatched,
                .deprecated_query_accounts_unbatched,
                .deprecated_query_transfers_unbatched,
                => 0,
            };
        }

        /// Maximum events per batch (for pulse timestamp delta).
        fn batch_max_events() u64 {
            return @divFloor(constants.message_body_size_max, @sizeOf(GeoEvent));
        }

        /// Prefetch phase - asynchronously load data needed for execution.
        /// Called after consensus, before commit.
        ///
        /// Prefetch loads required data from LSM trees into cache to ensure
        /// cache hits during the commit phase. This is critical for performance
        /// as commit() must be synchronous and deterministic.
        ///
        /// Currently empty implementation - will be populated when Forest is
        /// integrated with GeoEvent grooves.
        pub fn prefetch(
            self: *GeoStateMachine,
            callback: *const fn (*GeoStateMachine) void,
            op: u64,
            operation: Operation,
            message_body_used: []align(16) const u8,
        ) void {
            assert(op > 0);
            assert(self.prefetch_callback == null);
            assert(message_body_used.len <= self.batch_size_limit);

            self.prefetch_callback = callback;

            // Store operation context for future implementation
            // TODO: When Forest is integrated:
            // 1. self.forest.grooves.geo_events.prefetch_setup(null);
            // 2. Dispatch to operation-specific prefetch based on operation type
            // 3. For insert_events: prefetch existing entity_ids for conflict detection
            // 4. For query_uuid: prefetch entity_id index entries
            // 5. For query_radius/polygon: S2 cell range prefetch

            switch (operation) {
                // Write operations will need to prefetch for conflict detection
                .create_accounts,
                .create_transfers,
                .deprecated_create_accounts_unbatched,
                .deprecated_create_transfers_unbatched,
                => {
                    // TODO: Prefetch existing records by ID
                    self.prefetch_finish();
                },

                // Read operations will need to prefetch query results
                .lookup_accounts,
                .lookup_transfers,
                .get_account_transfers,
                .get_account_balances,
                .query_accounts,
                .query_transfers,
                .get_change_events,
                .deprecated_lookup_accounts_unbatched,
                .deprecated_lookup_transfers_unbatched,
                .deprecated_get_account_transfers_unbatched,
                .deprecated_get_account_balances_unbatched,
                .deprecated_query_accounts_unbatched,
                .deprecated_query_transfers_unbatched,
                => {
                    // TODO: Prefetch based on query filters
                    self.prefetch_finish();
                },

                // Pulse has no data to prefetch
                .pulse => self.prefetch_finish(),
            }
        }

        /// Complete prefetch phase and invoke callback.
        fn prefetch_finish(self: *GeoStateMachine) void {
            const callback = self.prefetch_callback.?;
            self.prefetch_callback = null;
            callback(self);
        }

        /// Commit phase - execute operation deterministically.
        /// All replicas MUST produce identical results for identical inputs.
        ///
        /// Implementation: F1.1.5
        pub fn commit(
            self: *GeoStateMachine,
            client: u128,
            op: u64,
            timestamp: u64,
            operation: Operation,
            message_body_used: []align(16) const u8,
            output: []align(16) u8,
        ) usize {
            _ = self;
            _ = client;
            _ = op;
            _ = timestamp;
            _ = message_body_used;
            _ = output;

            // TODO(F1.1.5): Implement operation execution
            return switch (operation) {
                .pulse => 0,
                else => 0, // Stub - return empty result
            };
        }

        /// Compact phase - integrate with checkpoint system.
        /// Called during compaction cycle.
        ///
        /// Implementation: F1.1.6
        pub fn compact(
            self: *GeoStateMachine,
            callback: *const fn (*GeoStateMachine) void,
            op: u64,
        ) void {
            _ = op;

            assert(self.compact_callback == null);
            self.compact_callback = callback;

            // TODO(F1.1.6): Trigger forest compaction
            // For now, immediately invoke callback
            if (self.compact_callback) |cb| {
                self.compact_callback = null;
                cb(self);
            }
        }

        /// Checkpoint phase - save state to disk.
        pub fn checkpoint(
            self: *GeoStateMachine,
            callback: *const fn (*GeoStateMachine) void,
        ) void {
            _ = self;
            _ = callback;
            // TODO: Implement checkpointing
        }

        // ====================================================================
        // Input Validation
        // ====================================================================

        /// Validate input before consensus.
        /// Returns true if the operation body is valid.
        pub fn input_valid(
            self: *const GeoStateMachine,
            operation: Operation,
            message_body_used: []align(16) const u8,
        ) bool {
            _ = self;

            const event_size = operation.event_size();
            if (event_size == 0) return true; // No body expected

            // Body must be properly aligned
            if (message_body_used.len % event_size != 0) return false;

            // TODO(F1.1.3): Add operation-specific validation
            return true;
        }

        // ====================================================================
        // Helper Functions
        // ====================================================================

        /// Validate a GeoEvent for insertion.
        fn validate_geo_event(event: *const GeoEvent) InsertGeoEventResult {
            // Check entity_id
            if (event.entity_id == 0) {
                return .entity_id_must_not_be_zero;
            }

            // Check coordinates
            if (!GeoEvent.validate_coordinates(event.lat_nano, event.lon_nano)) {
                if (event.lat_nano < GeoEvent.lat_nano_min or
                    event.lat_nano > GeoEvent.lat_nano_max)
                {
                    return .lat_out_of_range;
                }
                return .lon_out_of_range;
            }

            // Check heading
            if (event.heading_cdeg > GeoEvent.heading_max) {
                return .heading_out_of_range;
            }

            // Check reserved fields (must be zero)
            if (!stdx.zeroed(&event.reserved)) {
                return .reserved_field;
            }

            // Check reserved flags
            if (event.flags.padding != 0) {
                return .reserved_flag;
            }

            return .ok;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "InsertGeoEventsResult size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(InsertGeoEventsResult));
}

test "QueryUuidFilter size" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(QueryUuidFilter));
}

test "QueryRadiusFilter size" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(QueryRadiusFilter));
}

test "QueryPolygonFilter size" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(QueryPolygonFilter));
}

test "PolygonVertex size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PolygonVertex));
}

test "batch_max_events calculation" {
    // Should calculate max GeoEvents that fit in message body
    const max_events = @divFloor(constants.message_body_size_max, @sizeOf(GeoEvent));
    try std.testing.expect(max_events > 0);
    // With 128-byte GeoEvent and ~1MB body, should fit ~8000 events
    try std.testing.expect(max_events >= 8);
}
