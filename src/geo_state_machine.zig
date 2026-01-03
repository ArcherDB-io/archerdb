//! GeoStateMachine - ArcherDB's geospatial state machine implementation.
//!
//! This module implements the StateMachine interface required by VSR,
//! handling geospatial operations on GeoEvent data.
//!
//! The state machine follows TigerBeetle's three-phase execution model:
//! 1. prepare() - Calculate timestamps (primary only, before consensus)
//! 2. prefetch() - Load required data into cache (async I/O)
//! 3. commit() - Apply state changes (deterministic, after consensus)
//!
//! ## Client Session Management
//!
//! Client sessions (register operation 0x00) are handled by the VSR replica
//! layer, NOT the state machine. The replica manages:
//! - client_table_entry_create() for new client registration
//! - client_table_entry_update() for subsequent operations
//! - Session expiry and eviction for LRU cleanup
//!
//! This state machine only handles user operations (pulse, insert_events,
//! query_*, etc.) that pass through VSR consensus. Register operations
//! are intercepted by the replica before reaching commit().

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
    /// GeoEvent LSM tree configuration.
    /// - id (1): Primary index - composite ID (S2 cell << 64 | timestamp)
    /// - entity_id (2): Secondary index for UUID lookups
    /// - correlation_id (3): Secondary index for trip/session queries
    /// - group_id (4): Secondary index for fleet/region queries
    /// - timestamp (5): Secondary index for time-range queries
    pub const GeoEventTree = .{
        .id = 1,
        .entity_id = 2,
        .correlation_id = 3,
        .group_id = 4,
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
/// Returns latest GeoEvent for the specified entity_id, or empty if not found.
pub const QueryUuidFilter = extern struct {
    entity_id: u128,
    /// Maximum results to return (typically 1 for UUID lookups)
    limit: u32,
    /// Reserved for future use
    reserved: [108]u8 = @splat(0),

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

/// Filter for query_latest operation (F1.3.3).
/// Returns the N most recent events globally or filtered by group_id.
pub const QueryLatestFilter = extern struct {
    /// Maximum results to return (default 1000, max 81000)
    limit: u32,
    /// Reserved for alignment
    _reserved_align: u32 = 0,
    /// Group ID filter (0 = all groups)
    group_id: u64,
    /// Cursor timestamp for pagination (0 = start from latest)
    cursor_timestamp: u64,
    /// Reserved for future use
    reserved: [104]u8 = @splat(0),

    comptime {
        assert(@sizeOf(QueryLatestFilter) == 128);
        assert(stdx.no_padding(QueryLatestFilter));
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

        /// Commit timestamp - monotonically increasing per operation.
        commit_timestamp: u64 = 0,

        /// Callback for async open completion.
        open_callback: ?*const fn (*GeoStateMachine) void = null,

        /// Callback for async prefetch completion.
        prefetch_callback: ?*const fn (*GeoStateMachine) void = null,

        /// Callback for async compact completion.
        compact_callback: ?*const fn (*GeoStateMachine) void = null,

        /// Callback for async checkpoint completion.
        checkpoint_callback: ?*const fn (*GeoStateMachine) void = null,

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
        /// Opening restores the LSM tree state from the most recent checkpoint,
        /// allowing the replica to resume processing after a restart. The forest
        /// loads manifest data and rebuilds in-memory structures.
        ///
        /// After open completes, the state machine is ready to:
        /// - Process new prepares (as primary)
        /// - Replay prepares from the WAL (during recovery)
        /// - Handle queries against persisted data
        pub fn open(self: *GeoStateMachine, callback: *const fn (*GeoStateMachine) void) void {
            assert(self.open_callback == null);
            self.open_callback = callback;

            // TODO: When Forest is integrated:
            // self.forest.open(open_finish);
            //
            // For now, immediately complete since we have no LSM tree yet
            self.open_finish();
        }

        /// Internal callback when forest open completes.
        fn open_finish(self: *GeoStateMachine) void {
            assert(self.open_callback != null);

            const callback = self.open_callback.?;
            self.open_callback = null;
            callback(self);
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
        /// This is the core execution phase after consensus. The timestamp
        /// is assigned by VSR and must be used for all operations. All replicas
        /// execute the same operations in the same order with the same timestamps,
        /// ensuring bit-exact determinism.
        ///
        /// Returns the number of bytes written to the output buffer.
        pub fn commit(
            self: *GeoStateMachine,
            client: u128,
            op: u64,
            timestamp: u64,
            operation: Operation,
            message_body_used: []align(16) const u8,
            output: []align(16) u8,
        ) usize {
            // Validate operation number
            assert(op != 0);

            // Timestamp must be strictly increasing (determinism invariant)
            // During AOF recovery, timestamps may be replayed in order
            assert(timestamp > self.commit_timestamp or constants.aof_recovery);

            // Message body must fit within batch size limit
            assert(message_body_used.len <= self.batch_size_limit);

            // Only pulse operations can have client=0 (internal operations)
            if (client == 0) assert(operation == .pulse);

            // Update commit timestamp for monotonicity check
            self.commit_timestamp = timestamp;

            // Dispatch to operation-specific execution
            const result: usize = switch (operation) {
                // Pulse: internal maintenance (TTL cleanup, etc.)
                .pulse => self.execute_pulse(timestamp),

                // Write operations
                .create_accounts => self.execute_create_accounts(timestamp, message_body_used, output),
                .create_transfers => self.execute_create_transfers(timestamp, message_body_used, output),

                // Read operations
                .lookup_accounts => self.execute_lookup_accounts(message_body_used, output),
                .lookup_transfers => self.execute_lookup_transfers(message_body_used, output),
                .get_account_transfers => self.execute_get_account_transfers(message_body_used, output),
                .get_account_balances => self.execute_get_account_balances(message_body_used, output),
                .query_accounts => self.execute_query_accounts(message_body_used, output),
                .query_transfers => self.execute_query_transfers(message_body_used, output),
                .get_change_events => self.execute_get_change_events(message_body_used, output),

                // Deprecated unbatched operations (TigerBeetle compatibility)
                .deprecated_create_accounts_unbatched => self.execute_create_accounts(timestamp, message_body_used, output),
                .deprecated_create_transfers_unbatched => self.execute_create_transfers(timestamp, message_body_used, output),
                .deprecated_lookup_accounts_unbatched => self.execute_lookup_accounts(message_body_used, output),
                .deprecated_lookup_transfers_unbatched => self.execute_lookup_transfers(message_body_used, output),
                .deprecated_get_account_transfers_unbatched => self.execute_get_account_transfers(message_body_used, output),
                .deprecated_get_account_balances_unbatched => self.execute_get_account_balances(message_body_used, output),
                .deprecated_query_accounts_unbatched => self.execute_query_accounts(message_body_used, output),
                .deprecated_query_transfers_unbatched => self.execute_query_transfers(message_body_used, output),
            };

            return result;
        }

        // ====================================================================
        // Execute Functions (Stubs - to be implemented with Forest integration)
        // ====================================================================

        fn execute_pulse(self: *GeoStateMachine, timestamp: u64) usize {
            _ = self;
            _ = timestamp;
            // TODO: Execute TTL cleanup sweep
            return 0;
        }

        fn execute_create_accounts(self: *GeoStateMachine, timestamp: u64, input: []const u8, output: []u8) usize {
            _ = self;
            _ = timestamp;
            _ = input;
            _ = output;
            // TODO: Create TigerBeetle accounts (for compatibility during transition)
            return 0;
        }

        fn execute_create_transfers(self: *GeoStateMachine, timestamp: u64, input: []const u8, output: []u8) usize {
            _ = self;
            _ = timestamp;
            _ = input;
            _ = output;
            // TODO: Create TigerBeetle transfers (for compatibility during transition)
            return 0;
        }

        fn execute_lookup_accounts(self: *GeoStateMachine, input: []const u8, output: []u8) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Lookup TigerBeetle accounts
            return 0;
        }

        fn execute_lookup_transfers(self: *GeoStateMachine, input: []const u8, output: []u8) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Lookup TigerBeetle transfers
            return 0;
        }

        fn execute_get_account_transfers(self: *GeoStateMachine, input: []const u8, output: []u8) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Get account transfers
            return 0;
        }

        fn execute_get_account_balances(self: *GeoStateMachine, input: []const u8, output: []u8) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Get account balances
            return 0;
        }

        fn execute_query_accounts(self: *GeoStateMachine, input: []const u8, output: []u8) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Query accounts
            return 0;
        }

        fn execute_query_transfers(self: *GeoStateMachine, input: []const u8, output: []u8) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Query transfers
            return 0;
        }

        fn execute_get_change_events(self: *GeoStateMachine, input: []const u8, output: []u8) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Get change events
            return 0;
        }

        /// Compact phase - integrate with checkpoint system.
        /// Called during compaction cycle to trigger LSM tree compaction.
        ///
        /// Compaction merges sorted runs in the LSM tree, reducing read
        /// amplification and freeing space. This is called periodically
        /// by VSR as part of the checkpoint cycle.
        ///
        /// The operation number `op` is used to determine which LSM levels
        /// need compaction based on the compaction schedule.
        pub fn compact(
            self: *GeoStateMachine,
            callback: *const fn (*GeoStateMachine) void,
            op: u64,
        ) void {
            // Must have committed at least one operation
            assert(op != 0);

            // Cannot start compaction while another compact/checkpoint is in progress
            assert(self.compact_callback == null);
            assert(self.checkpoint_callback == null);

            self.compact_callback = callback;

            // TODO: When Forest is integrated:
            // self.forest.compact(compact_finish, op);
            //
            // For now, immediately complete since we have no LSM tree yet
            self.compact_finish();
        }

        /// Internal callback when forest compaction completes.
        fn compact_finish(self: *GeoStateMachine) void {
            const callback = self.compact_callback.?;
            self.compact_callback = null;
            callback(self);
        }

        /// Checkpoint phase - save state to durable storage.
        /// Called after compaction to persist the compacted state.
        ///
        /// Checkpointing writes the current LSM tree state to disk,
        /// creating a recovery point. After checkpoint, the WAL entries
        /// before this point can be discarded.
        pub fn checkpoint(
            self: *GeoStateMachine,
            callback: *const fn (*GeoStateMachine) void,
        ) void {
            // Cannot start checkpoint while another compact/checkpoint is in progress
            assert(self.compact_callback == null);
            assert(self.checkpoint_callback == null);

            self.checkpoint_callback = callback;

            // TODO: When Forest is integrated:
            // self.forest.checkpoint(checkpoint_finish);
            //
            // For now, immediately complete since we have no LSM tree yet
            self.checkpoint_finish();
        }

        /// Internal callback when forest checkpoint completes.
        fn checkpoint_finish(self: *GeoStateMachine) void {
            const callback = self.checkpoint_callback.?;
            self.checkpoint_callback = null;
            callback(self);
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
