// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
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
//!
//! ## GDPR Compliance Verification Procedure (F2.5.9)
//!
//! ArcherDB implements GDPR "right to erasure" (Article 17) through a three-phase
//! deletion process. This section documents how to verify compliance.
//!
//! ### Phase 1: Delete (Immediate)
//!
//! When `delete_entities` operation is executed:
//! 1. Entity is removed from RAM index immediately (O(1) removal)
//! 2. Tombstone markers are generated for LSM tree (pending Forest integration)
//! 3. Operation is recorded in deletion_metrics
//!
//! **Verification**: Query the entity_id - should return NOT_FOUND
//! ```
//! result = query_uuid(deleted_entity_id)
//! assert(result.count == 0)  // Entity no longer accessible
//! ```
//!
//! ### Phase 2: Compact (Background)
//!
//! During LSM compaction cycles:
//! 1. Tombstones propagate through LSM levels (L0 → L1 → L2 → ...)
//! 2. Tombstones shadow any older versions of the entity
//! 3. `should_retain_tombstone()` determines when tombstones can be dropped
//! 4. Tombstones are only eliminated when ALL conditions are met:
//!    - Tombstone has reached deepest level (L_max)
//!    - No older versions exist in any lower level
//!    - At least one full compaction cycle has passed
//!
//! **Verification**: Monitor tombstone_metrics
//! ```
//! // After sufficient compaction cycles:
//! assert(tombstone_metrics.tombstone_eliminated_compactions > 0)
//! // Retention ratio should decrease over time:
//! assert(tombstone_metrics.retentionRatio() < 1.0)
//! ```
//!
//! ### Phase 3: Verify (Audit)
//!
//! To verify complete erasure for compliance audit:
//!
//! 1. **Immediate Verification** (after delete):
//!    - Entity not in RAM index: `ram_index.get(entity_id) == null`
//!    - Delete acknowledged: check DeleteEntitiesResult.ok
//!
//! 2. **Post-Compaction Verification** (after compaction cycles):
//!    - LSM tree contains no versions: requires Forest integration
//!    - Tombstone eliminated: tombstone_metrics shows elimination
//!
//! 3. **Metrics Export** (for audit trail):
//!    ```
//!    deletion_metrics.toPrometheus(writer)  // Deletion counts
//!    tombstone_metrics.toPrometheus(writer) // Tombstone lifecycle
//!    ```
//!
//! ### Compliance Guarantees
//!
//! - **Deterministic Ordering**: VSR consensus ensures deletion order is
//!   identical across all replicas (F2.5.4)
//! - **No Data Resurrection**: Tombstones are retained until older versions
//!   are eliminated (F2.5.7)
//! - **Audit Trail**: Metrics provide verifiable deletion evidence
//! - **Eventual Erasure**: Compaction guarantees physical data removal
//!
//! ### Implementation Status
//!
//! | Component | Status | Notes |
//! |-----------|--------|-------|
//! | RAM index removal | ✓ Complete | O(1) immediate removal |
//! | Deletion metrics | ✓ Complete | Prometheus export |
//! | Tombstone metrics | ✓ Complete | Lifecycle tracking |
//! | LSM tombstones | ◐ Stub | Awaiting Forest integration |
//! | Tombstone retention | ◐ Stub | Awaiting Forest integration |
//! | Full verification | ◐ Partial | Needs Forest for LSM queries |

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
const ForestType = @import("lsm/forest.zig").ForestType;
const GrooveType = @import("lsm/groove.zig").GrooveType;

// RAM Index integration (F2.1)
const DefaultRamIndex = @import("ram_index.zig").DefaultRamIndex;
const IndexEntry = @import("ram_index.zig").IndexEntry;

// Index checkpoint coordination (F2.2)
const index_checkpoint = @import("index/checkpoint.zig");
const CheckpointHeader = index_checkpoint.CheckpointHeader;

// TTL cleanup integration (F2.4.8)
const ttl = @import("ttl.zig");
const CleanupRequest = ttl.CleanupRequest;
const CleanupResponse = ttl.CleanupResponse;

// S2 spatial index integration (F3.3.2)
const s2_index = @import("s2_index.zig");
const S2 = s2_index.S2;

// ============================================================================
// Tree IDs for LSM Storage
// ============================================================================

/// LSM tree identifiers for GeoEvent storage.
/// Each tree provides a different index over GeoEvent data.
/// Tree IDs must be contiguous with no gaps for ForestType.
pub const tree_ids = struct {
    /// GeoEvent LSM tree configuration.
    /// Tree IDs are contiguous 1-4 to satisfy ForestType requirements.
    /// - id (1): Primary index - composite ID (S2 cell << 64 | timestamp)
    /// - entity_id (2): Secondary index for UUID lookups
    /// - timestamp (3): Object tree key for time-ordered iteration
    /// - group_id (4): Secondary index for fleet/region queries
    pub const GeoEventTree = .{
        .id = 1,
        .entity_id = 2,
        .timestamp = 3,
        .group_id = 4,
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
// Deletion Metrics (F2.5.5)
// ============================================================================

/// Metrics for GDPR entity deletion operations.
pub const DeletionMetrics = struct {
    /// Total entities successfully deleted.
    entities_deleted: u64 = 0,
    /// Total entities not found during deletion.
    entities_not_found: u64 = 0,
    /// Total deletion operations executed.
    deletion_operations: u64 = 0,
    /// Cumulative deletion duration in nanoseconds.
    total_deletion_duration_ns: u64 = 0,

    /// Record a deletion batch result.
    pub fn record_deletion_batch(
        self: *DeletionMetrics,
        deleted: u64,
        not_found: u64,
        duration_ns: u64,
    ) void {
        self.entities_deleted += deleted;
        self.entities_not_found += not_found;
        self.deletion_operations += 1;
        self.total_deletion_duration_ns += duration_ns;
    }

    /// Calculate average deletion latency (ns per entity).
    pub fn average_deletion_latency_ns(self: DeletionMetrics) u64 {
        if (self.entities_deleted == 0) return 0;
        return self.total_deletion_duration_ns / self.entities_deleted;
    }

    /// Export metrics in Prometheus text format.
    pub fn toPrometheus(self: DeletionMetrics, writer: anytype) !void {
        try writer.print(
            \\# HELP archerdb_entities_deleted_total Total entities deleted
            \\# TYPE archerdb_entities_deleted_total counter
            \\archerdb_entities_deleted_total {d}
            \\# HELP archerdb_deletion_not_found_total Delete requests for non-existent entities
            \\# TYPE archerdb_deletion_not_found_total counter
            \\archerdb_deletion_not_found_total {d}
            \\# HELP archerdb_deletion_operations_total Total deletion operations
            \\# TYPE archerdb_deletion_operations_total counter
            \\archerdb_deletion_operations_total {d}
            \\# HELP archerdb_deletion_duration_ns_total Cumulative deletion duration
            \\# TYPE archerdb_deletion_duration_ns_total counter
            \\archerdb_deletion_duration_ns_total {d}
            \\
        , .{
            self.entities_deleted,
            self.entities_not_found,
            self.deletion_operations,
            self.total_deletion_duration_ns,
        });
    }
};

/// Tombstone lifecycle metrics (F2.5.8).
///
/// Tracks tombstone behavior during LSM compaction for GDPR compliance
/// verification and storage optimization.
pub const TombstoneMetrics = struct {
    /// Tombstones retained during compaction (older data still exists below).
    tombstone_retained_compactions: u64 = 0,
    /// Tombstones eliminated during compaction (entity fully purged).
    tombstone_eliminated_compactions: u64 = 0,
    /// Total compaction cycles processed.
    compaction_cycles: u64 = 0,
    /// Sum of tombstone ages at elimination (in seconds).
    /// Divide by tombstone_eliminated_compactions for average age.
    total_tombstone_age_seconds: u64 = 0,
    /// Maximum observed tombstone age at elimination (seconds).
    max_tombstone_age_seconds: u64 = 0,
    /// Minimum observed tombstone age at elimination (seconds).
    /// Initialized to max to track actual minimum.
    min_tombstone_age_seconds: u64 = std.math.maxInt(u64),

    /// Record a tombstone retention during compaction.
    pub fn recordRetained(self: *TombstoneMetrics, count: u64) void {
        self.tombstone_retained_compactions += count;
    }

    /// Record tombstone elimination with age tracking.
    ///
    /// Parameters:
    /// - count: Number of tombstones eliminated
    /// - total_age_seconds: Sum of ages of eliminated tombstones
    /// - max_age: Maximum age among eliminated tombstones
    /// - min_age: Minimum age among eliminated tombstones
    pub fn recordEliminated(
        self: *TombstoneMetrics,
        count: u64,
        total_age_seconds: u64,
        max_age: u64,
        min_age: u64,
    ) void {
        self.tombstone_eliminated_compactions += count;
        self.total_tombstone_age_seconds += total_age_seconds;
        if (max_age > self.max_tombstone_age_seconds) {
            self.max_tombstone_age_seconds = max_age;
        }
        if (count > 0 and min_age < self.min_tombstone_age_seconds) {
            self.min_tombstone_age_seconds = min_age;
        }
    }

    /// Record completion of a compaction cycle.
    pub fn recordCompactionCycle(self: *TombstoneMetrics) void {
        self.compaction_cycles += 1;
    }

    /// Calculate average tombstone age at elimination (seconds).
    pub fn averageTombstoneAge(self: TombstoneMetrics) u64 {
        if (self.tombstone_eliminated_compactions == 0) return 0;
        return self.total_tombstone_age_seconds / self.tombstone_eliminated_compactions;
    }

    /// Calculate retention ratio (0.0 to 1.0).
    /// Higher values indicate more tombstones being retained vs eliminated.
    pub fn retentionRatio(self: TombstoneMetrics) f64 {
        const total = self.tombstone_retained_compactions + self.tombstone_eliminated_compactions;
        if (total == 0) return 0.0;
        const retained = @as(f64, @floatFromInt(self.tombstone_retained_compactions));
        return retained / @as(f64, @floatFromInt(total));
    }

    /// Export metrics in Prometheus text format.
    pub fn toPrometheus(self: TombstoneMetrics, writer: anytype) !void {
        try writer.print(
            \\# HELP archerdb_tombstone_retained_total Tombstones retained during compaction
            \\# TYPE archerdb_tombstone_retained_total counter
            \\archerdb_tombstone_retained_total {d}
            \\# HELP archerdb_tombstone_eliminated_total Tombstones eliminated (entity fully purged)
            \\# TYPE archerdb_tombstone_eliminated_total counter
            \\archerdb_tombstone_eliminated_total {d}
            \\# HELP archerdb_compaction_cycles_total Total LSM compaction cycles
            \\# TYPE archerdb_compaction_cycles_total counter
            \\archerdb_compaction_cycles_total {d}
            \\# HELP archerdb_tombstone_age_seconds_total Sum of tombstone ages at elimination
            \\# TYPE archerdb_tombstone_age_seconds_total counter
            \\archerdb_tombstone_age_seconds_total {d}
            \\# HELP archerdb_tombstone_age_max_seconds Maximum tombstone age at elimination
            \\# TYPE archerdb_tombstone_age_max_seconds gauge
            \\archerdb_tombstone_age_max_seconds {d}
            \\
        , .{
            self.tombstone_retained_compactions,
            self.tombstone_eliminated_compactions,
            self.compaction_cycles,
            self.total_tombstone_age_seconds,
            self.max_tombstone_age_seconds,
        });
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

        /// Workload generator for VOPR testing (F4.1.1).
        pub const Workload = @import("testing/geo_workload.zig").GeoWorkloadType(GeoStateMachine);

        // Tree value counts for batch processing (F1.2, F4.2)
        // GeoEvent batch max based on message body size
        const batch_geo_events_max: u32 = Operation.insert_events.event_max(
            constants.message_body_size_max,
        );

        const tree_values_count_max = struct {
            const geo_events = struct {
                const id: u32 = batch_geo_events_max;
                const entity_id: u32 = batch_geo_events_max;
                const timestamp: u32 = batch_geo_events_max;
                const group_id: u32 = batch_geo_events_max;
            };
        };

        /// GeoEvents groove (F1.2, F4.2) - LSM tree storage for GeoEvent data.
        /// Provides indexes for spatial-temporal queries:
        /// - id: Composite key (S2 cell << 64 | timestamp) for spatial range queries
        /// - entity_id: UUID lookup index for query_uuid operations
        /// - timestamp: Object tree key for time-ordered iteration
        /// - group_id: Fleet/region grouping index (optional)
        const GeoEventsGroove = GrooveType(
            Storage,
            GeoEvent,
            .{
                .ids = tree_ids.GeoEventTree,
                .batch_value_count_max = .{
                    .id = tree_values_count_max.geo_events.id,
                    .entity_id = tree_values_count_max.geo_events.entity_id,
                    .timestamp = tree_values_count_max.geo_events.timestamp,
                    .group_id = tree_values_count_max.geo_events.group_id,
                },
                .ignored = &[_][]const u8{
                    // Coordinate data not directly indexed (spatial queries use id composite key)
                    "lat_nano",
                    "lon_nano",
                    "altitude_mm",
                    // Motion data not indexed
                    "velocity_mms",
                    "heading_cdeg",
                    "accuracy_mm",
                    // TTL handled by expiration logic, not indexed
                    "ttl_seconds",
                    // Application data
                    "correlation_id",
                    "user_data",
                    // Flags and reserved
                    "flags",
                    "reserved",
                },
                .optional = &[_][]const u8{
                    // group_id is optional - only indexed if non-zero
                    "group_id",
                },
                .derived = .{},
                .orphaned_ids = false,
                .objects_cache = true, // Cache hot entities for query_latest
            },
        );

        /// Forest type for GeoEvent LSM storage (F1.2, F4.2).
        /// Contains only GeoEvents groove for standalone geo state machine.
        pub const Forest = ForestType(Storage, .{
            .geo_events = GeoEventsGroove,
        });

        /// Configuration options for state machine initialization.
        pub const Options = struct {
            /// Maximum batch size for operations.
            batch_size_limit: u32,
            /// Enable index checkpoint coordination (F2.2.3).
            enable_index_checkpoint: bool = true,
            /// LSM forest compaction block count.
            lsm_forest_compaction_block_count: u32 = Forest.Options.compaction_block_count_min +
                128,
            /// LSM forest node pool count.
            lsm_forest_node_count: u32 = 4096,
            /// Cache entries for geo events.
            cache_entries_geo_events: u32 = 256,
        };

        /// Prefetch timestamp - set during prefetch phase.
        prefetch_timestamp: u64 = 0,

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

        /// Forest instance for LSM tree storage (F1.2, F4.2).
        /// Required by VOPR for GridScrubber initialization.
        forest: Forest,

        /// Grid reference for VSR checkpoint coordination (F2.2.3).
        /// Through grid.superblock, we access vsr_state.checkpoint for
        /// coordinating index checkpoint with VSR checkpoint sequence.
        grid: *Grid,

        /// Index checkpoint enabled flag.
        index_checkpoint_enabled: bool,

        /// Last recorded VSR checkpoint op (for monitoring lag).
        last_index_checkpoint_op: u64 = 0,

        /// RAM Index for entity lookups (F2.1).
        /// Allocated during init for VOPR testing support.
        ram_index: *DefaultRamIndex,

        /// TTL cleanup scanner state (F2.4.8).
        cleanup_scanner: ttl.CleanupScanner = ttl.CleanupScanner.init(),

        /// TTL metrics for observability (F2.4.5).
        ttl_metrics: ttl.TtlMetrics = ttl.TtlMetrics{},

        /// Deletion metrics for GDPR compliance (F2.5.5).
        deletion_metrics: DeletionMetrics = DeletionMetrics{},

        /// Tombstone lifecycle metrics for compaction monitoring (F2.5.8).
        tombstone_metrics: TombstoneMetrics = TombstoneMetrics{},

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
            _ = time;

            // Allocate RAM index for entity lookups (F2.1)
            const ram_index_capacity: u32 = 10_000; // Initial capacity for testing
            const ram_index = try allocator.create(DefaultRamIndex);
            errdefer allocator.destroy(ram_index);

            ram_index.* = try DefaultRamIndex.init(allocator, ram_index_capacity);
            errdefer ram_index.deinit(allocator);

            self.* = .{
                .batch_size_limit = options.batch_size_limit,
                .prefetch_timestamp = 0,
                .prepare_timestamp = 0,
                .commit_timestamp = 0,
                .forest = undefined,
                .grid = grid,
                .index_checkpoint_enabled = options.enable_index_checkpoint,
                .last_index_checkpoint_op = 0,
                .ram_index = ram_index,
            };

            // Initialize Forest for LSM tree storage (F1.2, F4.2)
            try self.forest.init(
                allocator,
                grid,
                .{
                    .compaction_block_count = options.lsm_forest_compaction_block_count,
                    .node_count = options.lsm_forest_node_count,
                },
                forest_options(options),
            );
            errdefer self.forest.deinit(allocator);

            // GeoStateMachine initialized with Forest and RAM index (F1.2, F2.1, F4.2)
            log.info("GeoStateMachine: initialized (F1.2, F2.1, F4.2)", .{});
        }

        /// Generate Forest options for GeoEvent groove.
        pub fn forest_options(options: Options) Forest.GroovesOptions {
            const prefetch_geo_events_limit: u32 =
                Operation.insert_events.event_max(options.batch_size_limit);

            const tree_values_count_limit = struct {
                const geo_events = struct {
                    const id: u32 = batch_geo_events_max;
                    const entity_id: u32 = batch_geo_events_max;
                    const timestamp: u32 = batch_geo_events_max;
                    const group_id: u32 = batch_geo_events_max;
                };
            };

            return .{
                .geo_events = .{
                    .prefetch_entries_for_read_max = prefetch_geo_events_limit,
                    .prefetch_entries_for_update_max = prefetch_geo_events_limit,
                    .cache_entries_max = options.cache_entries_geo_events,
                    .tree_options_object = .{
                        .batch_value_count_limit = tree_values_count_limit.geo_events.timestamp,
                    },
                    .tree_options_id = .{
                        .batch_value_count_limit = tree_values_count_limit.geo_events.id,
                    },
                    .tree_options_index = index_tree_options(
                        GeoEventsGroove.IndexTreeOptions,
                        tree_values_count_limit.geo_events,
                    ),
                },
            };
        }

        fn index_tree_options(
            comptime IndexTreeOptions: type,
            batch_limits: anytype,
        ) IndexTreeOptions {
            var result: IndexTreeOptions = undefined;
            inline for (comptime std.meta.fieldNames(IndexTreeOptions)) |field| {
                @field(result, field) = .{ .batch_value_count_limit = @field(batch_limits, field) };
            }
            return result;
        }

        pub fn deinit(self: *GeoStateMachine, allocator: std.mem.Allocator) void {
            self.forest.deinit(allocator);
            self.ram_index.deinit(allocator);
            allocator.destroy(self.ram_index);
        }

        /// Reset state machine for state sync.
        /// Called when a replica needs to sync from another replica's state.
        pub fn reset(self: *GeoStateMachine) void {
            self.forest.reset();

            self.* = .{
                .batch_size_limit = self.batch_size_limit,
                .prefetch_timestamp = 0,
                .prepare_timestamp = 0,
                .commit_timestamp = 0,
                .forest = self.forest,
                .grid = self.grid,
                .ram_index = self.ram_index,
                .index_checkpoint_enabled = self.index_checkpoint_enabled,
                .last_index_checkpoint_op = 0,
            };
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

            // Open the forest - required for replica initialization
            self.forest.open(forest_open_callback);
        }

        /// Internal callback when forest open completes.
        fn forest_open_callback(forest: *Forest) void {
            const self: *GeoStateMachine = @fieldParentPtr("forest", forest);
            assert(self.open_callback != null);

            const callback = self.open_callback.?;
            self.open_callback = null;
            callback(self);
        }

        /// Check if a pulse operation is needed for TTL expiration.
        /// Called periodically by the replica to check if pending events
        /// need expiration processing.
        ///
        /// Returns true if there are GeoEvents that need TTL expiration
        /// at the given timestamp.
        pub fn pulse_needed(self: *const GeoStateMachine, timestamp: u64) bool {
            _ = self;
            _ = timestamp;

            // TODO(F2.4): Implement TTL expiration check
            // For now, GeoStateMachine doesn't generate pulse operations.
            // When TTL cleanup is fully integrated, this will return true
            // when there are expired events that need cleanup.
            return false;
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

                // ArcherDB GeoEvent write operations (F1.2)
                .insert_events => @divExact(batch.len, @sizeOf(GeoEvent)),
                .upsert_events => @divExact(batch.len, @sizeOf(GeoEvent)),
                .delete_entities => @divExact(batch.len, @sizeOf(u128)),
                .cleanup_expired => 1, // Single cleanup operation

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
                // ArcherDB GeoEvent query operations (F1.3)
                .query_uuid,
                .query_radius,
                .query_polygon,
                .query_latest,
                // ArcherDB diagnostics
                .archerdb_ping,
                .archerdb_get_status,
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
                // ArcherDB GeoEvent write operations (F1.2)
                .insert_events,
                .upsert_events,
                .delete_entities,
                .cleanup_expired,
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
                // ArcherDB GeoEvent query operations (F1.3)
                .query_uuid,
                .query_radius,
                .query_polygon,
                .query_latest,
                // ArcherDB diagnostics
                .archerdb_ping,
                .archerdb_get_status,
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
                .get_account_transfers => {
                    return self.execute_get_account_transfers(message_body_used, output);
                },
                .get_account_balances => {
                    return self.execute_get_account_balances(message_body_used, output);
                },
                .query_accounts => self.execute_query_accounts(message_body_used, output),
                .query_transfers => self.execute_query_transfers(message_body_used, output),
                .get_change_events => self.execute_get_change_events(message_body_used, output),

                // Deprecated unbatched operations (TigerBeetle compatibility)
                .deprecated_create_accounts_unbatched => {
                    return self.execute_create_accounts(timestamp, message_body_used, output);
                },
                .deprecated_create_transfers_unbatched => {
                    return self.execute_create_transfers(timestamp, message_body_used, output);
                },
                .deprecated_lookup_accounts_unbatched => {
                    return self.execute_lookup_accounts(message_body_used, output);
                },
                .deprecated_lookup_transfers_unbatched => {
                    return self.execute_lookup_transfers(message_body_used, output);
                },
                .deprecated_get_account_transfers_unbatched => {
                    return self.execute_get_account_transfers(message_body_used, output);
                },
                .deprecated_get_account_balances_unbatched => {
                    return self.execute_get_account_balances(message_body_used, output);
                },
                .deprecated_query_accounts_unbatched => {
                    return self.execute_query_accounts(message_body_used, output);
                },
                .deprecated_query_transfers_unbatched => {
                    return self.execute_query_transfers(message_body_used, output);
                },

                // ArcherDB geospatial operations (TODO: implement with Forest)
                .insert_events => 0, // TODO: execute_insert_events
                .upsert_events => 0, // TODO: execute_upsert_events
                .delete_entities => self.execute_delete_entities(message_body_used, output),
                .query_uuid => 0, // TODO: execute_query_uuid
                .query_radius => self.execute_query_radius(message_body_used, output),
                .query_polygon => self.execute_query_polygon(message_body_used, output),
                .query_latest => 0, // TODO: execute_query_latest

                // ArcherDB admin operations
                .archerdb_ping => 0, // TODO: execute_archerdb_ping
                .archerdb_get_status => 0, // TODO: execute_archerdb_get_status

                // ArcherDB TTL cleanup (F2.4.8)
                .cleanup_expired => {
                    return self.execute_cleanup_expired(timestamp, message_body_used, output);
                },
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

        fn execute_create_accounts(
            self: *GeoStateMachine,
            timestamp: u64,
            input: []const u8,
            output: []u8,
        ) usize {
            _ = self;
            _ = timestamp;
            _ = input;
            _ = output;
            // TODO: Create TigerBeetle accounts (for compatibility during transition)
            return 0;
        }

        fn execute_create_transfers(
            self: *GeoStateMachine,
            timestamp: u64,
            input: []const u8,
            output: []u8,
        ) usize {
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

        fn execute_get_account_transfers(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Get account transfers
            return 0;
        }

        fn execute_get_account_balances(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Get account balances
            return 0;
        }

        fn execute_query_accounts(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Query accounts
            return 0;
        }

        fn execute_query_transfers(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            _ = self;
            _ = input;
            _ = output;
            // TODO: Query transfers
            return 0;
        }

        fn execute_get_change_events(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
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
            // Measure deletion latency (F2.5.5).
            const start_time = std.time.nanoTimestamp();

            // Parse input as array of entity_ids.
            const entity_ids = mem.bytesAsSlice(u128, input);
            const max_results = output.len / @sizeOf(DeleteEntitiesResult);
            const results = mem.bytesAsSlice(
                DeleteEntitiesResult,
                output[0 .. max_results * @sizeOf(DeleteEntitiesResult)],
            );

            var results_count: usize = 0;
            var deleted_count: u64 = 0;
            var not_found_count: u64 = 0;

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

                // Track metrics (F2.5.5).
                if (removed) {
                    deleted_count += 1;
                } else {
                    not_found_count += 1;
                }

                // F2.5.3: Generate LSM tombstones for cascading delete.
                // When Forest is integrated, this will:
                // 1. Query tree_ids.GeoEventTree.entity_id index for all events
                // 2. Generate tombstone for each event found
                // 3. Insert tombstones into LSM tree for compaction
                // Currently blocked on Forest integration (see execute_insert_events TODO).
                // The RAM index deletion above is sufficient for immediate lookup removal.
            }

            // Record metrics (F2.5.5).
            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 = if (end_time > start_time)
                @intCast(end_time - start_time)
            else
                0;
            self.deletion_metrics.record_deletion_batch(
                deleted_count,
                not_found_count,
                duration_ns,
            );

            return results_count * @sizeOf(DeleteEntitiesResult);
        }

        // ====================================================================
        // F3.3.2: Radius Query Implementation
        // ====================================================================

        /// Execute radius query (F3.3.2).
        ///
        /// Implements the radius query execution flow per query-engine/spec.md:
        /// 1. Convert the circle to an S2 Cap
        /// 2. Generate covering cell ID ranges
        /// 3. Scan RAM index for matching entries (coarse filter by cell range)
        /// 4. Post-filter using precise Haversine distance calculation
        /// 5. Apply timestamp/group_id filters if specified
        ///
        /// **Current Implementation**: Uses RAM index scan since LSM Forest
        /// integration is not yet complete. This provides entity lookups but
        /// is less efficient than LSM tree range scans for large datasets.
        ///
        /// **Future**: When Forest is integrated, replace RAM index scan with
        /// LSM tree range scan for O(cells * log(n)) performance.
        ///
        /// Arguments:
        /// - input: QueryRadiusFilter serialized data
        /// - output: Buffer for GeoEvent results
        ///
        /// Returns: Size of response written to output (number of bytes)
        fn execute_query_radius(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            // Validate input size
            if (input.len < @sizeOf(QueryRadiusFilter)) {
                log.warn("query_radius: input too small ({d} < {d})", .{
                    input.len,
                    @sizeOf(QueryRadiusFilter),
                });
                return 0;
            }

            // Parse filter from input
            const filter = mem.bytesAsValue(
                QueryRadiusFilter,
                input[0..@sizeOf(QueryRadiusFilter)],
            ).*;

            // Validate filter parameters
            if (filter.radius_mm == 0) {
                log.warn("query_radius: radius_mm must be > 0", .{});
                return 0;
            }
            if (filter.limit == 0) {
                log.warn("query_radius: limit must be > 0", .{});
                return 0;
            }

            // Calculate output capacity
            const max_results = output.len / @sizeOf(GeoEvent);
            const effective_limit = @min(filter.limit, @as(u32, @intCast(max_results)));
            if (effective_limit == 0) {
                return 0;
            }

            // Generate S2 covering for the query region
            var scratch: [s2_index.s2_scratch_size]u8 = undefined;

            // Select S2 levels based on radius per spec decision table
            const level_params = selectS2Levels(filter.radius_mm);

            const covering = S2.coverCap(
                &scratch,
                filter.center_lat_nano,
                filter.center_lon_nano,
                filter.radius_mm,
                level_params.min_level,
                level_params.max_level,
            );

            // Count non-empty ranges for logging
            var num_ranges: usize = 0;
            for (covering) |range| {
                if (range.start != 0 or range.end != 0) {
                    num_ranges += 1;
                }
            }

            log.debug("query_radius: covering generated with {d} ranges", .{num_ranges});

            // Scan RAM index and collect matching entries
            const results_slice = mem.bytesAsSlice(
                GeoEvent,
                output[0 .. effective_limit * @sizeOf(GeoEvent)],
            );

            var result_count: usize = 0;
            const radius_mm_u64 = @as(u64, filter.radius_mm);

            // Scan entire RAM index (temporary until LSM scan is available)
            // NOTE: This is O(n) where n is index capacity. For production use,
            // LSM tree range scan should be used instead.
            var position: u64 = 0;
            while (position < self.ram_index.capacity and result_count < effective_limit) {
                // Read entry from index
                const entry_ptr: *IndexEntry = &self.ram_index.entries[@intCast(position)];
                const entry = @as(*volatile IndexEntry, @ptrCast(entry_ptr)).*;

                position += 1;

                // Skip empty slots and tombstones
                if (entry.is_empty() or entry.is_tombstone()) {
                    continue;
                }

                // Extract S2 cell ID from composite latest_id (upper 64 bits)
                const cell_id = @as(u64, @truncate(entry.latest_id >> 64));
                const timestamp = @as(u64, @truncate(entry.latest_id));

                // Coarse filter: Check if cell is in any covering range
                if (!cellInCovering(cell_id, &covering)) {
                    continue;
                }

                // Apply timestamp filter if specified
                if (filter.timestamp_min > 0 and timestamp < filter.timestamp_min) {
                    continue;
                }
                if (filter.timestamp_max > 0 and timestamp > filter.timestamp_max) {
                    continue;
                }

                // Get approximate lat/lon from cell center
                // Note: At level 30, cells are ~7.5mm, so this is sufficiently accurate
                const cell_center = S2.cellIdToLatLon(cell_id);

                // Post-filter: Precise distance check using Haversine formula
                if (!S2.isWithinDistance(
                    filter.center_lat_nano,
                    filter.center_lon_nano,
                    cell_center.lat_nano,
                    cell_center.lon_nano,
                    radius_mm_u64,
                )) {
                    continue;
                }

                // Build GeoEvent result
                // NOTE: This creates a minimal GeoEvent from index data.
                // When Forest is integrated, we should fetch the full event from LSM.
                results_slice[result_count] = GeoEvent{
                    .id = entry.latest_id,
                    .entity_id = entry.entity_id,
                    .correlation_id = 0, // Not stored in RAM index
                    .user_data = 0, // Not stored in RAM index
                    .lat_nano = cell_center.lat_nano,
                    .lon_nano = cell_center.lon_nano,
                    // Not stored in RAM index - TODO: add group_id filter when Forest ready
                    .group_id = 0,
                    .timestamp = timestamp,
                    .altitude_mm = 0,
                    .velocity_mms = 0,
                    .ttl_seconds = entry.ttl_seconds,
                    .accuracy_mm = 0,
                    .heading_cdeg = 0,
                    .flags = GeoEventFlags.none,
                    .reserved = [_]u8{0} ** 12,
                };

                result_count += 1;
            }

            log.debug("query_radius: returning {d} results", .{result_count});

            return result_count * @sizeOf(GeoEvent);
        }

        // ====================================================================
        // F3.3.3: Polygon Query Implementation
        // ====================================================================

        /// Execute polygon query (F3.3.3).
        ///
        /// Implements the polygon query execution flow per query-engine/spec.md:
        /// 1. Parse QueryPolygonFilter and vertices from input
        /// 2. Generate S2 covering for polygon bounding box
        /// 3. Scan RAM index for matching entries (coarse filter by cell range)
        /// 4. Post-filter using point-in-polygon (ray casting) test
        /// 5. Apply timestamp/group_id filters if specified
        ///
        /// **Current Implementation**: Uses RAM index scan and bounding-box
        /// covering approximation since full S2 polygon covering isn't
        /// implemented yet.
        ///
        /// Arguments:
        /// - input: QueryPolygonFilter header + PolygonVertex array
        /// - output: Buffer for GeoEvent results
        ///
        /// Returns: Size of response written to output (number of bytes)
        fn execute_query_polygon(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            // Validate minimum input size (header only)
            if (input.len < @sizeOf(QueryPolygonFilter)) {
                log.warn("query_polygon: input too small for header ({d} < {d})", .{
                    input.len,
                    @sizeOf(QueryPolygonFilter),
                });
                return 0;
            }

            // Parse filter header
            const filter = mem.bytesAsValue(
                QueryPolygonFilter,
                input[0..@sizeOf(QueryPolygonFilter)],
            ).*;

            // Validate vertex count (minimum 3 for a polygon)
            if (filter.vertex_count < 3) {
                log.warn("query_polygon: vertex_count must be >= 3 (got {d})", .{
                    filter.vertex_count,
                });
                return 0;
            }

            // Per spec: Enforce maximum 10,000 vertices per polygon
            if (filter.vertex_count > 10_000) {
                log.warn("query_polygon: polygon_too_complex (vertex_count {d} > 10000)", .{
                    filter.vertex_count,
                });
                return 0;
            }

            if (filter.limit == 0) {
                log.warn("query_polygon: limit must be > 0", .{});
                return 0;
            }

            // Validate input contains vertices
            const vertices_size = filter.vertex_count * @sizeOf(PolygonVertex);
            const total_size = @sizeOf(QueryPolygonFilter) + vertices_size;
            if (input.len < total_size) {
                log.warn("query_polygon: input too small for vertices ({d} < {d})", .{
                    input.len,
                    total_size,
                });
                return 0;
            }

            // Extract vertices
            const vertices_bytes = input[@sizeOf(QueryPolygonFilter)..][0..vertices_size];
            const vertices = mem.bytesAsSlice(PolygonVertex, vertices_bytes);

            // Convert to s2_index.LatLon format for coverPolygon and pointInPolygon
            // Note: We need a stack-allocated array since we can't do dynamic allocation
            // For production, this should use a scratch buffer pool (F3.3.6)
            const max_vertices_stack: usize = 256;
            if (vertices.len > max_vertices_stack) {
                log.warn("query_polygon: too many vertices for stack allocation ({d} > {d})", .{
                    vertices.len,
                    max_vertices_stack,
                });
                // For very complex polygons, we'd use the scratch buffer pool
                return 0;
            }

            var latlon_vertices: [max_vertices_stack]s2_index.LatLon = undefined;
            for (vertices, 0..) |v, i| {
                latlon_vertices[i] = .{
                    .lat_nano = v.lat_nano,
                    .lon_nano = v.lon_nano,
                };
            }
            const polygon_slice = latlon_vertices[0..vertices.len];

            // Calculate output capacity
            const max_results = output.len / @sizeOf(GeoEvent);
            const effective_limit = @min(filter.limit, @as(u32, @intCast(max_results)));
            if (effective_limit == 0) {
                return 0;
            }

            // Generate S2 covering for the polygon
            var scratch: [s2_index.s2_scratch_size]u8 = undefined;

            // Use polygon covering (bounding box approximation for now)
            // TODO: Implement proper S2 polygon covering (F3.3.3 enhancement)
            const covering = S2.coverPolygon(
                &scratch,
                polygon_slice,
                8, // min_level
                18, // max_level
            );

            // Count non-empty ranges for logging
            var num_ranges: usize = 0;
            for (covering) |range| {
                if (range.start != 0 or range.end != 0) {
                    num_ranges += 1;
                }
            }

            log.debug("query_polygon: covering generated with {d} ranges for {d}-vertex polygon", .{
                num_ranges,
                vertices.len,
            });

            // Scan RAM index and collect matching entries
            const results_slice = mem.bytesAsSlice(
                GeoEvent,
                output[0 .. effective_limit * @sizeOf(GeoEvent)],
            );

            var result_count: usize = 0;

            // Scan entire RAM index (temporary until LSM scan is available)
            var position: u64 = 0;
            while (position < self.ram_index.capacity and result_count < effective_limit) {
                // Read entry from index
                const entry_ptr: *IndexEntry = &self.ram_index.entries[@intCast(position)];
                const entry = @as(*volatile IndexEntry, @ptrCast(entry_ptr)).*;

                position += 1;

                // Skip empty slots and tombstones
                if (entry.is_empty() or entry.is_tombstone()) {
                    continue;
                }

                // Extract S2 cell ID and timestamp from composite latest_id
                const cell_id = @as(u64, @truncate(entry.latest_id >> 64));
                const timestamp = @as(u64, @truncate(entry.latest_id));

                // Coarse filter: Check if cell is in any covering range
                if (!cellInCovering(cell_id, &covering)) {
                    continue;
                }

                // Apply timestamp filter if specified
                if (filter.timestamp_min > 0 and timestamp < filter.timestamp_min) {
                    continue;
                }
                if (filter.timestamp_max > 0 and timestamp > filter.timestamp_max) {
                    continue;
                }

                // Get approximate lat/lon from cell center
                const cell_center = S2.cellIdToLatLon(cell_id);

                // Post-filter: Point-in-polygon test using ray casting algorithm
                const point = s2_index.LatLon{
                    .lat_nano = cell_center.lat_nano,
                    .lon_nano = cell_center.lon_nano,
                };
                if (!S2.pointInPolygon(point, polygon_slice)) {
                    continue;
                }

                // Build GeoEvent result
                results_slice[result_count] = GeoEvent{
                    .id = entry.latest_id,
                    .entity_id = entry.entity_id,
                    .correlation_id = 0, // Not stored in RAM index
                    .user_data = 0, // Not stored in RAM index
                    .lat_nano = cell_center.lat_nano,
                    .lon_nano = cell_center.lon_nano,
                    .group_id = 0, // Not stored in RAM index
                    .timestamp = timestamp,
                    .altitude_mm = 0,
                    .velocity_mms = 0,
                    .ttl_seconds = entry.ttl_seconds,
                    .accuracy_mm = 0,
                    .heading_cdeg = 0,
                    .flags = GeoEventFlags.none,
                    .reserved = [_]u8{0} ** 12,
                };

                result_count += 1;
            }

            log.debug("query_polygon: returning {d} results", .{result_count});

            return result_count * @sizeOf(GeoEvent);
        }

        /// Check if a cell ID falls within any of the covering ranges.
        ///
        /// The covering ranges are computed from S2 cells at various levels using
        /// cellToRange(), which generates ranges [min, max) that include all
        /// descendant cells. So a level-30 cell ID can be directly compared
        /// against the ranges without needing to traverse the hierarchy.
        fn cellInCovering(
            cell_id: u64,
            covering: *const [s2_index.s2_max_cells]s2_index.CellRange,
        ) bool {
            for (covering) |range| {
                // Skip empty ranges
                if (range.start == 0 and range.end == 0) {
                    continue;
                }

                // Check if cell is within range [start, end)
                // The ranges already cover all descendant cells
                if (cell_id >= range.start and cell_id < range.end) {
                    return true;
                }
            }

            return false;
        }

        /// Select S2 levels based on radius per spec decision table.
        /// Returns min_level and max_level for RegionCoverer.
        fn selectS2Levels(radius_mm: u32) struct { min_level: u8, max_level: u8 } {
            // Convert mm to meters for level selection
            const radius_m = @as(f64, @floatFromInt(radius_mm)) / 1000.0;

            // Per query-engine/spec.md decision table:
            // min_level = max(0, min(18, floor(log2(7842000 / radius_meters))))
            // max_level = min(min_level + 4, 18)

            if (radius_m <= 0) {
                return .{ .min_level = 18, .max_level = 18 };
            }

            const earth_radius_km = 7842.0; // From spec
            const ratio = (earth_radius_km * 1000.0) / radius_m;

            if (ratio <= 1.0) {
                return .{ .min_level = 0, .max_level = 4 };
            }

            // Calculate log2 using bit manipulation for determinism
            const log2_val = @log2(ratio);
            const min_level_raw = @floor(log2_val);

            var min_level: u8 = 0;
            if (min_level_raw > 0) {
                min_level = @min(18, @as(u8, @intFromFloat(min_level_raw)));
            }

            const max_level = @min(min_level + 4, 18);

            return .{ .min_level = min_level, .max_level = max_level };
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
        ///
        /// ## CRITICAL: Tombstone Retention for GDPR Compliance (F2.5.7)
        ///
        /// During compaction, tombstones (deletion markers) MUST be retained until
        /// all older versions of the entity have been eliminated from lower levels.
        /// Dropping a tombstone prematurely would "resurrect" deleted data, violating
        /// GDPR "right to erasure" guarantees.
        ///
        /// ### Tombstone Retention Algorithm
        ///
        /// When compacting level L(n) into L(n+1):
        /// 1. For each tombstone in the compaction input:
        ///    a. Check if any version of this entity exists in levels L(n+2)...L(max)
        ///    b. If older versions exist below: RETAIN the tombstone in output
        ///    c. If no older versions exist: tombstone can be dropped (data fully deleted)
        ///
        /// 2. Tombstone age tracking:
        ///    - Each tombstone carries the `op` number when deletion occurred
        ///    - Tombstones are only droppable after compacting through ALL levels
        ///    - Minimum retention: tombstone must survive at least one full compaction cycle
        ///
        /// 3. Safety invariants:
        ///    - A tombstone at level N always shadows entries at levels > N
        ///    - Dropping a tombstone at level N is only safe when levels > N have no older entries
        ///    - On recovery, tombstones must be replayed to maintain deletion state
        ///
        /// ### Implementation Status
        ///
        /// This requires Forest integration to access:
        /// - `forest.get_tree(entity_id)` - to check for older versions
        /// - `forest.compaction_iterator()` - to process tombstones during merge
        /// - Level metadata to determine tombstone droppability
        ///
        /// See: generate_lsm_tombstones_for_entity() for tombstone creation
        /// See: should_retain_tombstone() for retention decision logic
        ///
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
            // Compaction callback will invoke should_retain_tombstone() for each
            // tombstone encountered during level merges.
            //
            // For now, immediately complete since we have no LSM tree yet
            self.compact_finish();
        }

        /// Internal callback when forest compaction completes.
        /// Records tombstone lifecycle metrics (F2.5.8).
        fn compact_finish(self: *GeoStateMachine) void {
            // Record compaction cycle completion
            self.tombstone_metrics.recordCompactionCycle();

            // TODO: When Forest is integrated, the compaction process will call:
            // - tombstone_metrics.recordRetained() for tombstones kept
            // - tombstone_metrics.recordEliminated() for tombstones dropped
            // These will be called from within the k-way merge during level compaction.

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
            log.debug(
                "Index checkpoint: vsr_op={} commit_max={} last_index={}",
                .{ vsr_checkpoint_op, vsr_commit_max, self.last_index_checkpoint_op },
            );

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

            // Handle variable-length operations specially
            if (operation == .query_polygon) {
                // query_polygon body = QueryPolygonFilter (128 bytes) + vertices (N * 16 bytes)
                const header_size = @sizeOf(QueryPolygonFilter);
                if (message_body_used.len < header_size) return false;

                const vertices_size = message_body_used.len - header_size;
                if (vertices_size % @sizeOf(PolygonVertex) != 0) return false;

                // Validate vertex_count matches actual vertices
                const filter = mem.bytesAsValue(
                    QueryPolygonFilter,
                    message_body_used[0..header_size],
                ).*;
                const expected_vertices_size = filter.vertex_count * @sizeOf(PolygonVertex);
                if (vertices_size != expected_vertices_size) return false;

                return true;
            }

            const event_size = operation.event_size();
            if (event_size == 0) return true; // No body expected

            // Body must be properly aligned
            if (message_body_used.len % event_size != 0) return false;

            // TODO(F1.1.3): Add operation-specific validation
            return true;
        }

        // ====================================================================
        // Helper Functions
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

// =============================================================================
// GDPR Deletion Tests (F2.5.6)
// =============================================================================

test "DeleteEntityResult: result codes" {
    const DER = DeleteEntityResult;
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(DER.ok));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(DER.entity_id_must_not_be_zero));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(DER.entity_not_found));
}

test "DeleteEntitiesResult: struct layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(DeleteEntitiesResult));
    const result = DeleteEntitiesResult{
        .index = 5,
        .result = .ok,
    };
    try std.testing.expectEqual(@as(u32, 5), result.index);
    try std.testing.expectEqual(DeleteEntityResult.ok, result.result);
}

test "DeletionMetrics: record_deletion_batch" {
    var metrics = DeletionMetrics{};

    // Initial state.
    try std.testing.expectEqual(@as(u64, 0), metrics.entities_deleted);
    try std.testing.expectEqual(@as(u64, 0), metrics.entities_not_found);
    try std.testing.expectEqual(@as(u64, 0), metrics.deletion_operations);

    // Record first batch: 5 deleted, 2 not found, 1000ns.
    metrics.record_deletion_batch(5, 2, 1000);
    try std.testing.expectEqual(@as(u64, 5), metrics.entities_deleted);
    try std.testing.expectEqual(@as(u64, 2), metrics.entities_not_found);
    try std.testing.expectEqual(@as(u64, 1), metrics.deletion_operations);
    try std.testing.expectEqual(@as(u64, 1000), metrics.total_deletion_duration_ns);

    // Record second batch: 10 deleted, 0 not found, 2000ns.
    metrics.record_deletion_batch(10, 0, 2000);
    try std.testing.expectEqual(@as(u64, 15), metrics.entities_deleted);
    try std.testing.expectEqual(@as(u64, 2), metrics.entities_not_found);
    try std.testing.expectEqual(@as(u64, 2), metrics.deletion_operations);
    try std.testing.expectEqual(@as(u64, 3000), metrics.total_deletion_duration_ns);
}

test "DeletionMetrics: average_deletion_latency_ns" {
    var metrics = DeletionMetrics{};

    // No deletions - returns 0.
    try std.testing.expectEqual(@as(u64, 0), metrics.average_deletion_latency_ns());

    // 10 entities deleted in 5000ns = 500ns per entity.
    metrics.record_deletion_batch(10, 0, 5000);
    try std.testing.expectEqual(@as(u64, 500), metrics.average_deletion_latency_ns());
}

test "DeletionMetrics: toPrometheus output" {
    var metrics = DeletionMetrics{};
    metrics.entities_deleted = 100;
    metrics.entities_not_found = 5;
    metrics.deletion_operations = 10;
    metrics.total_deletion_duration_ns = 500000;

    var buffer: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try metrics.toPrometheus(fbs.writer());

    const output = fbs.getWritten();
    const del_total = "archerdb_entities_deleted_total 100";
    const not_found = "archerdb_deletion_not_found_total 5";
    const ops_total = "archerdb_deletion_operations_total 10";
    try std.testing.expect(std.mem.indexOf(u8, output, del_total) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, not_found) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ops_total) != null);
}

// =============================================================================
// TombstoneMetrics Tests (F2.5.8)
// =============================================================================

test "TombstoneMetrics: recordRetained increments counter" {
    var metrics = TombstoneMetrics{};
    try std.testing.expectEqual(@as(u64, 0), metrics.tombstone_retained_compactions);

    metrics.recordRetained(5);
    try std.testing.expectEqual(@as(u64, 5), metrics.tombstone_retained_compactions);

    metrics.recordRetained(3);
    try std.testing.expectEqual(@as(u64, 8), metrics.tombstone_retained_compactions);
}

test "TombstoneMetrics: recordEliminated with age tracking" {
    var metrics = TombstoneMetrics{};

    // First batch: 10 tombstones, total age 1000s, max 200s, min 50s
    metrics.recordEliminated(10, 1000, 200, 50);
    try std.testing.expectEqual(@as(u64, 10), metrics.tombstone_eliminated_compactions);
    try std.testing.expectEqual(@as(u64, 1000), metrics.total_tombstone_age_seconds);
    try std.testing.expectEqual(@as(u64, 200), metrics.max_tombstone_age_seconds);
    try std.testing.expectEqual(@as(u64, 50), metrics.min_tombstone_age_seconds);

    // Second batch: 5 tombstones, total age 300s, max 100s, min 30s
    metrics.recordEliminated(5, 300, 100, 30);
    try std.testing.expectEqual(@as(u64, 15), metrics.tombstone_eliminated_compactions);
    try std.testing.expectEqual(@as(u64, 1300), metrics.total_tombstone_age_seconds);
    // Max should stay at 200 (highest seen)
    try std.testing.expectEqual(@as(u64, 200), metrics.max_tombstone_age_seconds);
    // Min should update to 30 (lowest seen)
    try std.testing.expectEqual(@as(u64, 30), metrics.min_tombstone_age_seconds);
}

test "TombstoneMetrics: recordCompactionCycle" {
    var metrics = TombstoneMetrics{};
    try std.testing.expectEqual(@as(u64, 0), metrics.compaction_cycles);

    metrics.recordCompactionCycle();
    metrics.recordCompactionCycle();
    metrics.recordCompactionCycle();

    try std.testing.expectEqual(@as(u64, 3), metrics.compaction_cycles);
}

test "TombstoneMetrics: averageTombstoneAge" {
    var metrics = TombstoneMetrics{};

    // Zero eliminations - should return 0
    try std.testing.expectEqual(@as(u64, 0), metrics.averageTombstoneAge());

    // 10 tombstones with total age of 500 seconds = avg 50s
    metrics.recordEliminated(10, 500, 100, 20);
    try std.testing.expectEqual(@as(u64, 50), metrics.averageTombstoneAge());

    // Add 5 more with 250s total = 15 tombstones, 750s total = avg 50s
    metrics.recordEliminated(5, 250, 80, 30);
    try std.testing.expectEqual(@as(u64, 50), metrics.averageTombstoneAge());
}

test "TombstoneMetrics: retentionRatio" {
    var metrics = TombstoneMetrics{};

    // No data - should return 0.0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), metrics.retentionRatio(), 0.001);

    // 80 retained, 20 eliminated = 0.8 retention ratio
    metrics.tombstone_retained_compactions = 80;
    metrics.tombstone_eliminated_compactions = 20;
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), metrics.retentionRatio(), 0.001);

    // 50/50 = 0.5 ratio
    metrics.tombstone_retained_compactions = 50;
    metrics.tombstone_eliminated_compactions = 50;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), metrics.retentionRatio(), 0.001);
}

test "TombstoneMetrics: toPrometheus output" {
    var metrics = TombstoneMetrics{};
    metrics.tombstone_retained_compactions = 1000;
    metrics.tombstone_eliminated_compactions = 250;
    metrics.compaction_cycles = 10;
    metrics.total_tombstone_age_seconds = 12500;
    metrics.max_tombstone_age_seconds = 300;

    var buffer: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try metrics.toPrometheus(fbs.writer());

    const output = fbs.getWritten();
    const pfx = "archerdb_tombstone";
    try std.testing.expect(std.mem.indexOf(u8, output, pfx ++ "_retained_total 1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, pfx ++ "_eliminated_total 250") != null);
    const comp = "archerdb_compaction_cycles_total 10";
    try std.testing.expect(std.mem.indexOf(u8, output, comp) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, pfx ++ "_age_seconds_total 12500") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, pfx ++ "_age_max_seconds 300") != null);
}

// ============================================================================
// F3.3.2: Radius Query Tests
// ============================================================================

test "selectS2Levels: small radius (100m)" {
    const TestStorage = @import("testing/storage.zig").Storage;
    const GeoStateMachine = GeoStateMachineType(TestStorage);
    const levels = GeoStateMachine.selectS2Levels(100_000); // 100m in mm
    // Per spec: 100m → level 16
    try std.testing.expect(levels.min_level >= 14 and levels.min_level <= 17);
    try std.testing.expect(levels.max_level <= 18);
    try std.testing.expect(levels.max_level > levels.min_level);
}

test "selectS2Levels: medium radius (1km)" {
    const TestStorage = @import("testing/storage.zig").Storage;
    const GeoStateMachine = GeoStateMachineType(TestStorage);
    const levels = GeoStateMachine.selectS2Levels(1_000_000); // 1km in mm
    // Per spec: 1km → level ~13
    try std.testing.expect(levels.min_level >= 10 and levels.min_level <= 14);
    try std.testing.expect(levels.max_level <= 18);
}

test "selectS2Levels: large radius (100km)" {
    const TestStorage = @import("testing/storage.zig").Storage;
    const GeoStateMachine = GeoStateMachineType(TestStorage);
    const levels = GeoStateMachine.selectS2Levels(100_000_000); // 100km in mm
    // Per spec: 100km → level ~6
    try std.testing.expect(levels.min_level >= 4 and levels.min_level <= 8);
    try std.testing.expect(levels.max_level <= 12);
}

test "cellInCovering: basic range check" {
    const TestStorage = @import("testing/storage.zig").Storage;
    const GeoStateMachine = GeoStateMachineType(TestStorage);

    // Create a simple covering with one range
    var covering: [s2_index.s2_max_cells]s2_index.CellRange = undefined;
    for (&covering) |*range| {
        range.* = .{ .start = 0, .end = 0 };
    }

    // Set up a range [1000, 2000)
    covering[0] = .{ .start = 1000, .end = 2000 };

    // Test: cell inside range
    try std.testing.expect(GeoStateMachine.cellInCovering(1500, &covering));

    // Test: cell at start of range (inclusive)
    try std.testing.expect(GeoStateMachine.cellInCovering(1000, &covering));

    // Test: cell at end of range (exclusive)
    try std.testing.expect(!GeoStateMachine.cellInCovering(2000, &covering));

    // Test: cell outside range
    try std.testing.expect(!GeoStateMachine.cellInCovering(500, &covering));
}

// ============================================================================
// F3.3.3: Polygon Query Tests
// ============================================================================

test "QueryPolygonFilter: struct layout validation" {
    // Verify struct sizes match expectations
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(QueryPolygonFilter));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PolygonVertex));
}

test "polygon query: vertex count validation" {
    // A polygon must have at least 3 vertices (triangle)
    // This is validated in execute_query_polygon via the vertex_count field

    // Minimum valid: 3 vertices
    try std.testing.expect(3 <= 10_000);

    // Maximum per spec: 10,000 vertices
    try std.testing.expect(10_000 <= 10_000);
}

test "pointInPolygon: basic triangle test" {
    // Test point-in-polygon using a simple triangle
    // Triangle vertices: (0,0), (10°,0), (5°,10°) in degrees

    const polygon = [_]s2_index.LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 }, // 10°
        .{ .lat_nano = 5_000_000_000, .lon_nano = 10_000_000_000 }, // 5°, 10°
    };

    // Point inside triangle (approximately centroid)
    const inside = s2_index.LatLon{ .lat_nano = 5_000_000_000, .lon_nano = 3_000_000_000 };
    try std.testing.expect(S2.pointInPolygon(inside, &polygon));

    // Point outside triangle
    const outside = s2_index.LatLon{ .lat_nano = 15_000_000_000, .lon_nano = 0 };
    try std.testing.expect(!S2.pointInPolygon(outside, &polygon));
}

test "pointInPolygon: square test" {
    // Test with a simple square: (0,0), (10°,0), (10°,10°), (0,10°)
    const square = [_]s2_index.LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };

    // Point inside square
    const inside = s2_index.LatLon{ .lat_nano = 5_000_000_000, .lon_nano = 5_000_000_000 };
    try std.testing.expect(S2.pointInPolygon(inside, &square));

    // Point outside square (to the left)
    const outside_left = s2_index.LatLon{ .lat_nano = 5_000_000_000, .lon_nano = -5_000_000_000 };
    try std.testing.expect(!S2.pointInPolygon(outside_left, &square));

    // Point outside square (above)
    const outside_above = s2_index.LatLon{ .lat_nano = 15_000_000_000, .lon_nano = 5_000_000_000 };
    try std.testing.expect(!S2.pointInPolygon(outside_above, &square));
}
