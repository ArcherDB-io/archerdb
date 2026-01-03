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

// RAM Index integration (F2.1)
const RamIndex = @import("ram_index.zig").RamIndex;
const DefaultRamIndex = @import("ram_index.zig").DefaultRamIndex;
const IndexEntry = @import("ram_index.zig").IndexEntry;

// Index checkpoint coordination (F2.2)
const index_checkpoint = @import("index/checkpoint.zig");
const CheckpointHeader = index_checkpoint.CheckpointHeader;

// TTL cleanup integration (F2.4.8)
const ttl = @import("ttl.zig");
const CleanupRequest = ttl.CleanupRequest;
const CleanupResponse = ttl.CleanupResponse;

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
    // Grid type for accessing superblock (VSR checkpoint coordination)
    const Grid = @import("vsr/grid.zig").GridType(Storage);

    return struct {
        const GeoStateMachine = @This();

        /// The operation type exported for client protocol.
        pub const Operation = @import("archerdb.zig").Operation;

        // TODO(F1.2): Define Forest type for GeoEvent storage
        // pub const Forest = ForestType(Storage, tree_ids);

        /// Configuration options for state machine initialization.
        pub const Options = struct {
            /// Maximum batch size for operations.
            batch_size_limit: u32,
            /// Enable index checkpoint coordination (F2.2.3).
            enable_index_checkpoint: bool = true,
        };

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

        /// Grid reference for VSR checkpoint coordination (F2.2.3).
        /// Through grid.superblock, we access vsr_state.checkpoint for
        /// coordinating index checkpoint with VSR checkpoint sequence.
        grid: *Grid,

        /// Index checkpoint enabled flag.
        index_checkpoint_enabled: bool,

        /// Last recorded VSR checkpoint op (for monitoring lag).
        last_index_checkpoint_op: u64 = 0,

        /// RAM Index reference for entity lookups (F2.1).
        /// Note: Currently a stub pointer - to be integrated with Forest.
        ram_index: *DefaultRamIndex = undefined,

        /// TTL cleanup scanner state (F2.4.8).
        cleanup_scanner: ttl.CleanupScanner = ttl.CleanupScanner.init(),

        /// TTL metrics for observability (F2.4.5).
        ttl_metrics: ttl.TtlMetrics = ttl.TtlMetrics{},

        // ====================================================================
        // Initialization
        // ====================================================================

        /// Initialize the GeoStateMachine with Grid reference for VSR coordination.
        ///
        /// The Grid reference provides access to:
        /// - grid.superblock.working.vsr_state.checkpoint.header.op - VSR checkpoint op
        /// - grid.superblock.working.vsr_state.commit_max - Commit max
        ///
        /// This enables coordination between RAM index checkpoints and VSR checkpoints
        /// as required by the hybrid-memory spec (F2.2.3).
        pub fn init(
            self: *GeoStateMachine,
            allocator: std.mem.Allocator,
            time: vsr.time.Time,
            grid: *Grid,
            options: Options,
        ) !void {
            _ = allocator;
            _ = time;

            self.* = .{
                .batch_size_limit = options.batch_size_limit,
                .prepare_timestamp = 0,
                .commit_timestamp = 0,
                .grid = grid,
                .index_checkpoint_enabled = options.enable_index_checkpoint,
                .last_index_checkpoint_op = 0,
            };

            log.info("GeoStateMachine: index checkpoint coordination enabled (F2.2.3)", .{});
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
                .create_accounts => {
                    return self.execute_create_accounts(timestamp, message_body_used, output);
                },
                .create_transfers => {
                    return self.execute_create_transfers(timestamp, message_body_used, output);
                },

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

                // ArcherDB geospatial operations (TODO: implement with Forest)
                .insert_events => 0, // TODO: execute_insert_events
                .upsert_events => 0, // TODO: execute_upsert_events
                .delete_entities => self.execute_delete_entities(message_body_used, output),
                .query_uuid => 0, // TODO: execute_query_uuid
                .query_radius => 0, // TODO: execute_query_radius
                .query_polygon => 0, // TODO: execute_query_polygon
                .query_latest => 0, // TODO: execute_query_latest

                // ArcherDB admin operations
                .archerdb_ping => 0, // TODO: execute_archerdb_ping
                .archerdb_get_status => 0, // TODO: execute_archerdb_get_status

                // ArcherDB TTL cleanup (F2.4.8)
                .cleanup_expired => self.execute_cleanup_expired(timestamp, message_body_used, output),
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

        // ====================================================================
        // F2.5: GDPR Entity Deletion Implementation
        // ====================================================================

        /// Execute delete_entities operation (F2.5.1).
        ///
        /// Deletes entities from the RAM index for GDPR compliance.
        /// Per hybrid-memory/spec.md GDPR requirements:
        /// - Removes entity from RAM index immediately
        /// - Returns result for each entity (ok, not_found, invalid_id)
        /// - LSM tombstones generated separately in F2.5.3
        ///
        /// Deterministic Ordering (F2.5.4):
        /// This function processes entity_ids in the order they appear in the input
        /// batch. Since VSR consensus ensures all replicas receive the same batch
        /// with the same ordering, deletion order is deterministic across replicas.
        /// No timestamps or external state affect the processing order.
        ///
        /// Arguments:
        /// - input: Array of u128 entity_ids to delete
        /// - output: Buffer for DeleteEntitiesResult array
        ///
        /// Returns: Size of response written to output
        fn execute_delete_entities(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            // Parse input as array of entity_ids.
            const entity_ids = mem.bytesAsSlice(u128, input);
            const max_results = output.len / @sizeOf(DeleteEntitiesResult);
            const results = mem.bytesAsSlice(
                DeleteEntitiesResult,
                output[0 .. max_results * @sizeOf(DeleteEntitiesResult)],
            );

            var results_count: usize = 0;
            for (entity_ids, 0..) |entity_id, index| {
                if (index >= max_results) break;

                // Validate entity_id (zero is reserved).
                if (entity_id == 0) {
                    results[results_count] = DeleteEntitiesResult{
                        .index = @intCast(index),
                        .result = .entity_id_must_not_be_zero,
                    };
                    results_count += 1;
                    continue;
                }

                // Remove from RAM index (F2.5.2).
                const removed = self.ram_index.remove(entity_id);

                results[results_count] = DeleteEntitiesResult{
                    .index = @intCast(index),
                    .result = if (removed) .ok else .entity_not_found,
                };
                results_count += 1;

                // F2.5.3: Generate LSM tombstones for cascading delete.
                // When Forest is integrated, this will:
                // 1. Query tree_ids.GeoEventTree.entity_id index for all events
                // 2. Generate tombstone for each event found
                // 3. Insert tombstones into LSM tree for compaction
                // Currently blocked on Forest integration (see execute_insert_events TODO).
                // The RAM index deletion above is sufficient for immediate lookup removal.
            }

            return results_count * @sizeOf(DeleteEntitiesResult);
        }

        /// Generate LSM tombstones for cascading entity delete (F2.5.3).
        ///
        /// When implemented, this function will:
        /// 1. Query the entity_id secondary index for all GeoEvents
        /// 2. For each event found, generate a tombstone with the same key
        /// 3. Insert tombstones into the LSM tree for compaction
        ///
        /// GDPR compliance: Tombstones must persist until compaction
        /// eliminates all historical versions of the events.
        ///
        /// Returns: Number of tombstones generated
        fn generate_lsm_tombstones_for_entity(
            self: *GeoStateMachine,
            entity_id: u128,
        ) u64 {
            _ = self;
            _ = entity_id;
            // TODO: Implement when Forest is integrated
            // Steps:
            // 1. self.forest.grooves.geo_events.scan_by_entity_id(entity_id)
            // 2. For each event: self.forest.grooves.geo_events.delete(event.id)
            // 3. Return count of tombstones generated
            return 0;
        }

        /// Execute cleanup_expired operation (F2.4.8).
        ///
        /// Scans the RAM index for expired entries and removes them.
        /// Per ttl-retention/spec.md:
        /// - Uses consensus timestamp for deterministic cleanup across replicas
        /// - Scans batch_size entries (or all if batch_size = 0)
        /// - Returns count of entries scanned and removed
        ///
        /// Arguments:
        /// - timestamp: VSR consensus timestamp (nanoseconds)
        /// - input: CleanupRequest bytes
        /// - output: Buffer for CleanupResponse
        ///
        /// Returns: Size of response written to output
        fn execute_cleanup_expired(
            self: *GeoStateMachine,
            timestamp: u64,
            input: []const u8,
            output: []u8,
        ) usize {
            // Parse request (if provided).
            var batch_size: u32 = 0;
            if (input.len >= @sizeOf(CleanupRequest)) {
                const request = @as(*const CleanupRequest, @ptrCast(@alignCast(input.ptr))).*;
                batch_size = request.batch_size;
            }

            // Scan the index for expired entries.
            // If batch_size = 0, scan all entries (use capacity as batch size).
            const scan_batch_size = if (batch_size == 0)
                self.ram_index.capacity
            else
                batch_size;

            // Run the scan using the consensus timestamp.
            // This ensures all replicas remove the same entries.
            const result = self.ram_index.scan_expired_batch(
                self.cleanup_scanner.position,
                scan_batch_size,
                timestamp,
            );

            // Update scanner state.
            self.cleanup_scanner.record_batch(
                result.entries_scanned,
                result.entries_removed,
                result.next_position,
                timestamp,
            );

            // Update TTL metrics.
            self.ttl_metrics.record_cleanup_expiration(result.entries_removed);
            self.ttl_metrics.record_cleanup_operation();

            // Write response.
            if (output.len >= @sizeOf(CleanupResponse)) {
                const response = @as(*CleanupResponse, @ptrCast(@alignCast(output.ptr)));
                response.* = CleanupResponse{
                    .entries_scanned = result.entries_scanned,
                    .entries_removed = result.entries_removed,
                };
                return @sizeOf(CleanupResponse);
            }

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
        ///
        /// VSR Checkpoint Coordination (F2.2.3):
        /// This function coordinates the index checkpoint with VSR's checkpoint sequence:
        /// 1. Extract current VSR state from grid.superblock.working.vsr_state
        /// 2. Record vsr_checkpoint_op and commit_max in index checkpoint header
        /// 3. The index checkpoint ensures recovery can determine correct WAL replay range
        ///
        /// Recovery will use the recorded vsr_checkpoint_op to:
        /// - Case A: WAL replay if gap <= journal_slot_count (fast)
        /// - Case B: LSM scan if gap is moderate (medium)
        /// - Case C: Full rebuild if checkpoint is too old (slow)
        pub fn checkpoint(
            self: *GeoStateMachine,
            callback: *const fn (*GeoStateMachine) void,
        ) void {
            // Cannot start checkpoint while another compact/checkpoint is in progress
            assert(self.compact_callback == null);
            assert(self.checkpoint_callback == null);

            self.checkpoint_callback = callback;

            // F2.2.3: Extract VSR checkpoint state for index checkpoint coordination
            if (self.index_checkpoint_enabled) {
                self.coordinate_index_checkpoint();
            }

            // TODO: When Forest is integrated:
            // self.forest.checkpoint(checkpoint_finish);
            //
            // For now, immediately complete since we have no LSM tree yet
            self.checkpoint_finish();
        }

        /// Coordinate index checkpoint with VSR checkpoint sequence (F2.2.3).
        ///
        /// This function extracts VSR state from the superblock and would pass it
        /// to the RAM index checkpoint system. The recorded state enables:
        /// - Determining correct WAL replay range during recovery
        /// - Detecting if index checkpoint is too far behind VSR checkpoint
        /// - Metrics for monitoring checkpoint lag
        fn coordinate_index_checkpoint(self: *GeoStateMachine) void {
            // Access VSR checkpoint state through grid.superblock
            const checkpoint_state = &self.grid.superblock.working.vsr_state.checkpoint;
            const vsr_checkpoint_op = checkpoint_state.header.op;
            const vsr_commit_max = self.grid.superblock.working.vsr_state.commit_max;

            // Log checkpoint coordination for debugging
            log.debug("Index checkpoint coordination: vsr_checkpoint_op={} commit_max={} last_index_op={}", .{
                vsr_checkpoint_op,
                vsr_commit_max,
                self.last_index_checkpoint_op,
            });

            // Calculate checkpoint lag (ops since last index checkpoint)
            const checkpoint_lag = if (vsr_checkpoint_op > self.last_index_checkpoint_op)
                vsr_checkpoint_op - self.last_index_checkpoint_op
            else
                0;

            // Warn if index checkpoint is lagging significantly behind VSR
            // The spec suggests triggering LSM scan if gap exceeds journal_slot_count
            if (checkpoint_lag > constants.journal_slot_count) {
                log.warn("Index checkpoint lagging behind VSR: gap={} (journal_slot_count={})", .{
                    checkpoint_lag,
                    constants.journal_slot_count,
                });
            }

            // TODO(F2.2): When RAM index is integrated, call:
            // index_checkpoint.write_incremental(
            //     &self.ram_index,
            //     vsr_checkpoint_op,
            //     vsr_commit_max,
            //     timestamp_high_water,
            // );

            // Record the VSR checkpoint op we've coordinated with
            self.last_index_checkpoint_op = vsr_checkpoint_op;
        }

        /// Get current VSR checkpoint state (F2.2.3).
        /// Returns the VSR checkpoint op and commit_max for external coordination.
        pub fn get_vsr_checkpoint_state(self: *const GeoStateMachine) struct {
            vsr_checkpoint_op: u64,
            vsr_commit_max: u64,
        } {
            const checkpoint_state = &self.grid.superblock.working.vsr_state.checkpoint;
            return .{
                .vsr_checkpoint_op = checkpoint_state.header.op,
                .vsr_commit_max = self.grid.superblock.working.vsr_state.commit_max,
            };
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

test "GeoStateMachine has checkpoint coordination fields (F2.2.3)" {
    // This compile-time test verifies the GeoStateMachine has the required
    // fields for VSR checkpoint coordination (F2.2.3).
    const TestStorage = @import("testing/storage.zig").Storage;
    const GeoStateMachine = GeoStateMachineType(TestStorage);

    // Verify Options struct has required fields
    _ = GeoStateMachine.Options{
        .batch_size_limit = 1024,
        .enable_index_checkpoint = true,
    };

    // Verify the struct has checkpoint coordination fields
    comptime {
        // Must have grid field for VSR access
        _ = @offsetOf(GeoStateMachine, "grid");
        // Must have index_checkpoint_enabled flag
        _ = @offsetOf(GeoStateMachine, "index_checkpoint_enabled");
        // Must track last checkpoint op for lag detection
        _ = @offsetOf(GeoStateMachine, "last_index_checkpoint_op");
    }
}

test "CheckpointHeader has VSR state fields (F2.2.3)" {
    // Verify CheckpointHeader can store VSR checkpoint coordination data.
    const header = CheckpointHeader{
        .vsr_checkpoint_op = 12345,
        .vsr_commit_max = 12400,
        .checkpoint_timestamp_ns = 1704067200_000_000_000,
    };
    try std.testing.expectEqual(@as(u64, 12345), header.vsr_checkpoint_op);
    try std.testing.expectEqual(@as(u64, 12400), header.vsr_commit_max);
}
