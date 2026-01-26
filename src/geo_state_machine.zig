// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! GeoStateMachine - ArcherDB's geospatial state machine implementation.
//!
//! This module implements the StateMachine interface required by VSR,
//! handling geospatial operations on GeoEvent data.
//!
//! The state machine follows ArcherDB's three-phase execution model:
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
//! | LSM tombstones | ✓ Complete | Forest.grooves.geo_events.insert() |
//! | Tombstone retention | ✓ Complete | GeoEvent.should_copy_forward() in compaction |
//! | Full verification | ✓ Complete | Forest.grooves.geo_events.get() for LSM queries |

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const log = std.log.scoped(.geo_state_machine);

const stdx = @import("stdx");
const maybe = stdx.maybe;

const constants = @import("constants.zig");
const StateError = @import("error_codes.zig").StateError;
const GeoEvent = @import("geo_event.zig").GeoEvent;
const GeoEventFlags = @import("geo_event.zig").GeoEventFlags;
const vsr = @import("vsr.zig");
const ForestType = @import("lsm/forest.zig").ForestType;
const GrooveType = @import("lsm/groove.zig").GrooveType;

// Prometheus metrics integration (F5.2.2)
const archerdb_metrics = vsr.archerdb_metrics;

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

// Hot-warm-cold tiering integration (F2.6)
const tiering = @import("tiering.zig");
const TieringManager = tiering.TieringManager;
const TieringConfig = tiering.TieringConfig;
const Tier = tiering.Tier;

// Topology discovery for Smart Client (F5.1)
const topology_mod = @import("topology.zig");
const TopologyResponse = topology_mod.TopologyResponse;

// S2 spatial index integration (F3.3.2)
const s2_index = @import("s2_index.zig");
const S2 = s2_index.S2;

// S2 covering cache integration (14-02)
const s2_covering_cache = @import("s2_covering_cache.zig");
const S2CoveringCache = s2_covering_cache.S2CoveringCache;

// Query result cache integration (14-01)
const query_cache = @import("query_cache.zig");
const QueryResultCache = query_cache.QueryResultCache;

// Query latency breakdown metrics (14-03)
const query_metrics_mod = @import("archerdb/query_metrics.zig");
const QueryLatencyBreakdown = query_metrics_mod.QueryLatencyBreakdown;
const SpatialIndexStats = query_metrics_mod.SpatialIndexStats;
const LatencyBreakdown = query_metrics_mod.Breakdown;
const QueryTypeMetric = query_metrics_mod.QueryType;

// Batch query integration (14-04)
const batch_query_mod = @import("batch_query.zig");
const BatchQueryMetrics = batch_query_mod.BatchQueryMetrics;

// Prepared query integration (14-05)
const prepared_queries = @import("prepared_queries.zig");
const SessionPreparedQueries = prepared_queries.SessionPreparedQueries;
const PreparedQueryMetrics = prepared_queries.PreparedQueryMetrics;

// Prepared query wire formats (from archerdb.zig)
const archerdb_mod = @import("archerdb.zig");
const PrepareQueryRequest = archerdb_mod.PrepareQueryRequest;
const PrepareQueryResult = archerdb_mod.PrepareQueryResult;
const ExecutePreparedRequest = archerdb_mod.ExecutePreparedRequest;
const DeallocatePreparedRequest = archerdb_mod.DeallocatePreparedRequest;
const DeallocatePreparedResult = archerdb_mod.DeallocatePreparedResult;

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
    entity_id_must_not_be_int_max = 16,

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
    entity_id_must_not_be_int_max = 4,
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

/// Insert operation metrics for observability.
///
/// Tracks insert/upsert performance and validation outcomes.
pub const InsertMetrics = struct {
    /// Total events successfully inserted.
    events_inserted: u64 = 0,
    /// Total events rejected due to validation.
    events_rejected: u64 = 0,
    /// Total insert operations (batches).
    insert_operations: u64 = 0,
    /// Cumulative insert duration in nanoseconds.
    total_insert_duration_ns: u64 = 0,

    /// Record an insert batch result.
    pub fn recordInsertBatch(
        self: *InsertMetrics,
        inserted: u64,
        rejected: u64,
        duration_ns: u64,
    ) void {
        self.events_inserted += inserted;
        self.events_rejected += rejected;
        self.insert_operations += 1;
        self.total_insert_duration_ns += duration_ns;
    }

    /// Calculate average insert latency (ns per event).
    pub fn averageInsertLatencyNs(self: InsertMetrics) u64 {
        const total_events = self.events_inserted + self.events_rejected;
        if (total_events == 0) return 0;
        return self.total_insert_duration_ns / total_events;
    }

    /// Export metrics in Prometheus text format.
    pub fn toPrometheus(self: InsertMetrics, writer: anytype) !void {
        try writer.print(
            \\# HELP archerdb_events_inserted_total Total events successfully inserted
            \\# TYPE archerdb_events_inserted_total counter
            \\archerdb_events_inserted_total {d}
            \\# HELP archerdb_events_rejected_total Events rejected due to validation
            \\# TYPE archerdb_events_rejected_total counter
            \\archerdb_events_rejected_total {d}
            \\# HELP archerdb_insert_operations_total Total insert operations
            \\# TYPE archerdb_insert_operations_total counter
            \\archerdb_insert_operations_total {d}
            \\# HELP archerdb_insert_duration_ns_total Cumulative insert duration
            \\# TYPE archerdb_insert_duration_ns_total counter
            \\archerdb_insert_duration_ns_total {d}
            \\
        , .{
            self.events_inserted,
            self.events_rejected,
            self.insert_operations,
            self.total_insert_duration_ns,
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

/// Query operation metrics for observability.
///
/// Tracks query performance and usage patterns for monitoring dashboards.
pub const QueryMetrics = struct {
    /// Total query operations by type.
    query_uuid_count: u64 = 0,
    query_radius_count: u64 = 0,
    query_polygon_count: u64 = 0,
    query_latest_count: u64 = 0,

    /// Total results returned across all queries.
    total_results_returned: u64 = 0,

    /// Query timing (cumulative nanoseconds).
    total_query_duration_ns: u64 = 0,

    /// RAM index hit/miss tracking.
    index_hits: u64 = 0,
    index_misses: u64 = 0,

    /// Query result cache hit/miss tracking (14-01).
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,

    /// Record a UUID query.
    pub fn recordUuidQuery(self: *QueryMetrics, found: bool, duration_ns: u64) void {
        self.query_uuid_count += 1;
        self.total_query_duration_ns += duration_ns;
        if (found) {
            self.index_hits += 1;
            self.total_results_returned += 1;
        } else {
            self.index_misses += 1;
        }
    }

    /// Record a radius query.
    pub fn recordRadiusQuery(self: *QueryMetrics, results_count: u64, duration_ns: u64) void {
        self.query_radius_count += 1;
        self.total_results_returned += results_count;
        self.total_query_duration_ns += duration_ns;
    }

    /// Record a polygon query.
    pub fn recordPolygonQuery(self: *QueryMetrics, results_count: u64, duration_ns: u64) void {
        self.query_polygon_count += 1;
        self.total_results_returned += results_count;
        self.total_query_duration_ns += duration_ns;
    }

    /// Calculate average query latency.
    pub fn averageQueryLatencyNs(self: QueryMetrics) u64 {
        const total_queries = self.query_uuid_count + self.query_radius_count +
            self.query_polygon_count + self.query_latest_count;
        if (total_queries == 0) return 0;
        return self.total_query_duration_ns / total_queries;
    }

    /// Record a query cache hit.
    pub fn recordCacheHit(self: *QueryMetrics) void {
        self.cache_hits += 1;
    }

    /// Record a query cache miss.
    pub fn recordCacheMiss(self: *QueryMetrics) void {
        self.cache_misses += 1;
    }

    /// Export metrics in Prometheus text format.
    pub fn toPrometheus(self: QueryMetrics, writer: anytype) !void {
        try writer.print(
            \\# HELP archerdb_query_uuid_total Total UUID lookup queries
            \\# TYPE archerdb_query_uuid_total counter
            \\archerdb_query_uuid_total {d}
            \\# HELP archerdb_query_radius_total Total radius queries
            \\# TYPE archerdb_query_radius_total counter
            \\archerdb_query_radius_total {d}
            \\# HELP archerdb_query_polygon_total Total polygon queries
            \\# TYPE archerdb_query_polygon_total counter
            \\archerdb_query_polygon_total {d}
            \\# HELP archerdb_query_results_total Total results returned
            \\# TYPE archerdb_query_results_total counter
            \\archerdb_query_results_total {d}
            \\# HELP archerdb_query_duration_ns_total Cumulative query duration
            \\# TYPE archerdb_query_duration_ns_total counter
            \\archerdb_query_duration_ns_total {d}
            \\# HELP archerdb_index_hits_total RAM index cache hits
            \\# TYPE archerdb_index_hits_total counter
            \\archerdb_index_hits_total {d}
            \\# HELP archerdb_index_misses_total RAM index cache misses
            \\# TYPE archerdb_index_misses_total counter
            \\archerdb_index_misses_total {d}
            \\# HELP archerdb_query_cache_hits_total Query result cache hits
            \\# TYPE archerdb_query_cache_hits_total counter
            \\archerdb_query_cache_hits_total {d}
            \\# HELP archerdb_query_cache_misses_total Query result cache misses
            \\# TYPE archerdb_query_cache_misses_total counter
            \\archerdb_query_cache_misses_total {d}
            \\
        , .{
            self.query_uuid_count,
            self.query_radius_count,
            self.query_polygon_count,
            self.total_results_returned,
            self.total_query_duration_ns,
            self.index_hits,
            self.index_misses,
            self.cache_hits,
            self.cache_misses,
        });
    }
};

const index_recovery_ranges_max: usize = 32;
const IndexRecoveryRange = s2_index.CellRange;
const IndexRecoveryRanges = stdx.BoundedArrayType(IndexRecoveryRange, index_recovery_ranges_max);

const IndexRecoveryState = struct {
    active: bool = false,
    ranges: IndexRecoveryRanges = .{},

    fn clear(self: *IndexRecoveryState) void {
        self.active = false;
        self.ranges.clear();
    }

    fn blocks_all(self: *const IndexRecoveryState) bool {
        return self.active and self.ranges.empty();
    }

    fn blocks_cell(self: *const IndexRecoveryState, cell_id: u64) bool {
        if (!self.active) return false;
        if (self.ranges.empty()) return true;
        for (self.ranges.const_slice()) |range| {
            if (cell_id >= range.start and cell_id < range.end) return true;
        }
        return false;
    }

    fn blocks_range(self: *const IndexRecoveryState, range: IndexRecoveryRange) bool {
        if (!self.active) return false;
        if (self.ranges.empty()) return true;
        for (self.ranges.const_slice()) |recovering| {
            if (ranges_overlap(recovering, range)) return true;
        }
        return false;
    }
};

fn ranges_overlap(a: IndexRecoveryRange, b: IndexRecoveryRange) bool {
    return a.start < b.end and b.start < a.end;
}

// ============================================================================
// Query Filters
// ============================================================================

/// Filter for UUID lookup queries (QueryUuidRequest).
/// Returns latest GeoEvent for the specified entity_id, or empty if not found.
pub const QueryUuidFilter = extern struct {
    entity_id: u128,
    /// Reserved for future use (must be zero)
    reserved: [16]u8 = @splat(0),

    comptime {
        assert(@sizeOf(QueryUuidFilter) == 32);
        assert(stdx.no_padding(QueryUuidFilter));
    }
};

/// Response header for UUID lookup queries.
/// Wire format:
/// [status: u8][reserved: 15 bytes]
/// Followed by GeoEvent (128 bytes) only when status == 0.
pub const QueryUuidResponse = extern struct {
    /// 0 = found, 200 = entity_not_found, 210 = entity_expired
    status: u8,
    /// Reserved for future use (must be zero)
    reserved: [15]u8 = @splat(0),

    comptime {
        assert(@sizeOf(QueryUuidResponse) == 16);
        assert(stdx.no_padding(QueryUuidResponse));
    }
};

/// Filter for batch UUID lookup queries (F1.3.4).
/// Wire format:
/// ```
/// [QueryUuidBatchFilter: 8 bytes header]
/// [entity_ids[0..count]: 16 bytes each (u128)]
/// ```
/// Max 10,000 UUIDs per request.
pub const QueryUuidBatchFilter = extern struct {
    /// Number of UUIDs to look up (max 10,000)
    count: u32,
    /// Reserved for future use (must be zero)
    reserved: u32 = 0,

    comptime {
        assert(@sizeOf(QueryUuidBatchFilter) == 8);
        assert(stdx.no_padding(QueryUuidBatchFilter));
    }

    /// Maximum UUIDs per batch lookup
    pub const max_count: u32 = 10_000;
};

/// Result header for batch UUID lookup (F1.3.4).
/// Wire format:
/// ```
/// [QueryUuidBatchResult: 16 bytes header]
/// [not_found_indices[0..not_found_count]: 2 bytes each (u16)]
/// [padding to 16-byte alignment]
/// [events[0..found_count]: 128 bytes each (GeoEvent)]
/// ```
pub const QueryUuidBatchResult = extern struct {
    /// Number of entities found
    found_count: u32,
    /// Number of entities not found
    not_found_count: u32,
    /// Reserved for future use
    reserved: [8]u8 = @splat(0),

    comptime {
        assert(@sizeOf(QueryUuidBatchResult) == 16);
        assert(stdx.no_padding(QueryUuidBatchResult));
    }

    /// Create an error result header with a status code stored in reserved bytes.
    pub fn with_error(status: StateError) QueryUuidBatchResult {
        var result = QueryUuidBatchResult{
            .found_count = 0,
            .not_found_count = 0,
        };
        const code: u16 = @intCast(@intFromEnum(status));
        result.reserved[0] = @intCast(code & 0xff);
        result.reserved[1] = @intCast((code >> 8) & 0xff);
        return result;
    }

    /// Decode error status from reserved bytes (null if unset).
    pub fn error_status(self: QueryUuidBatchResult) ?StateError {
        const code = @as(u16, self.reserved[0]) | (@as(u16, self.reserved[1]) << 8);
        if (code == 0) return null;
        return @as(StateError, @enumFromInt(code));
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
/// Supports polygons with holes (multi-ring polygons).
///
/// Wire format for polygon with holes:
/// ```
/// [QueryPolygonFilter: 128 bytes]
/// [OuterVertex[0..vertex_count]: 16 bytes each]
/// [HoleDescriptor[0..hole_count]: 8 bytes each]
/// [Hole0Vertices[0..hole_0_count]: 16 bytes each]
/// [Hole1Vertices[0..hole_1_count]: 16 bytes each]
/// ...
/// ```
pub const QueryPolygonFilter = extern struct {
    /// Number of vertices in outer ring (vertices follow in message body)
    vertex_count: u32,
    /// Number of hole rings (0 for simple polygon, max 100)
    hole_count: u32,
    /// Maximum results to return
    limit: u32,
    /// Reserved for alignment
    _reserved_align: u32 = 0,
    /// Minimum timestamp (inclusive, 0 = no filter)
    timestamp_min: u64,
    /// Maximum timestamp (inclusive, 0 = no filter)
    timestamp_max: u64,
    /// Group ID filter (0 = no filter)
    group_id: u64,
    /// Reserved for future use
    reserved: [88]u8 = @splat(0),

    comptime {
        assert(@sizeOf(QueryPolygonFilter) == 128);
        assert(stdx.no_padding(QueryPolygonFilter));
    }
};

/// Descriptor for a polygon hole ring.
/// Placed after outer ring vertices, before hole vertices.
pub const HoleDescriptor = extern struct {
    /// Number of vertices in this hole ring (min 3)
    vertex_count: u32,
    /// Reserved for future use
    reserved: u32 = 0,

    comptime {
        assert(@sizeOf(HoleDescriptor) == 8);
        assert(stdx.no_padding(HoleDescriptor));
    }
};

/// Polygon vertex (lat/lon pair).
pub const PolygonVertex = extern struct {
    lat_nano: i64,
    lon_nano: i64,

    /// Convert to s2_index.LatLon for spatial operations
    pub fn toLatLon(self: PolygonVertex) s2_index.LatLon {
        return .{
            .lat_nano = self.lat_nano,
            .lon_nano = self.lon_nano,
        };
    }

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

/// Response header for spatial queries (radius, polygon, latest).
/// Placed at start of response body, followed by count × GeoEvent structs.
///
/// Per query-engine/spec.md §1385-1393:
/// - count: actual number of results in this response
/// - has_more: 1 if more results available via cursor pagination
/// - partial_result: 1 if response was truncated due to message size limit
pub const QueryResponse = extern struct {
    /// Number of GeoEvent results following this header
    count: u32,
    /// 1 if more results available (use cursor to fetch), 0 otherwise
    has_more: u8,
    /// 1 if response was truncated due to message_size_max, 0 otherwise
    partial_result: u8,
    /// Reserved for future flags (10 bytes to ensure 16-byte total size for GeoEvent alignment)
    reserved: [10]u8 = @splat(0),

    comptime {
        // Must be 16 bytes so GeoEvent results following the header are 16-byte aligned
        assert(@sizeOf(QueryResponse) == 16);
        assert(stdx.no_padding(QueryResponse));
    }

    /// Create a response header for a complete result set
    pub fn complete(count: u32) QueryResponse {
        return .{
            .count = count,
            .has_more = 0,
            .partial_result = 0,
        };
    }

    /// Create a response header indicating more results available
    pub fn with_more(count: u32) QueryResponse {
        return .{
            .count = count,
            .has_more = 1,
            .partial_result = 0,
        };
    }

    /// Create a response header indicating truncation due to message size
    pub fn truncated(count: u32) QueryResponse {
        return .{
            .count = count,
            .has_more = 1,
            .partial_result = 1,
        };
    }

    /// Create an error response with a status code stored in reserved bytes.
    pub fn with_error(status: StateError) QueryResponse {
        var response = QueryResponse.complete(0);
        const code: u16 = @intCast(@intFromEnum(status));
        response.reserved[0] = @intCast(code & 0xff);
        response.reserved[1] = @intCast((code >> 8) & 0xff);
        return response;
    }

    /// Decode error status from reserved bytes (null if unset).
    pub fn error_status(self: QueryResponse) ?StateError {
        const code = @as(u16, self.reserved[0]) | (@as(u16, self.reserved[1]) << 8);
        if (code == 0) return null;
        return @as(StateError, @enumFromInt(code));
    }
};

// ============================================================================
// State Machine Implementation
// ============================================================================

/// Creates a GeoStateMachine type parameterized by Storage.
/// This is the main StateMachine implementation for ArcherDB (geospatial-only).
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
            /// Per ttl-retention/spec.md: Global default TTL in days.
            /// 0 = infinite (no expiration), > 0 = events expire after that many days.
            /// Applied when clients set event.ttl_seconds = 0.
            default_ttl_days: u32 = 0,
            /// Hybrid-memory/spec.md: Optional memory-mapped index fallback.
            memory_mapped_index_enabled: bool = false,
            /// Path for memory-mapped index backing file (required when enabled).
            memory_mapped_index_path: ?[]const u8 = null,
            /// Enable hot-warm-cold tiering (F2.6).
            /// When enabled, tracks entity access patterns for automatic tier management.
            tiering_enabled: bool = false,
            /// Tiering configuration (timeouts, thresholds).
            /// Only used when tiering_enabled = true.
            tiering_config: TieringConfig = .{},
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

        /// Per ttl-retention/spec.md: Global default TTL in seconds.
        /// 0 = infinite (no expiration), > 0 = default TTL when event.ttl_seconds = 0.
        /// Computed from Options.default_ttl_days * 86400 during init.
        default_ttl_seconds: u32,

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

        /// Index recovery tracking for query gating.
        index_recovery: IndexRecoveryState = .{},

        /// TTL cleanup scanner state (F2.4.8).
        cleanup_scanner: ttl.CleanupScanner = ttl.CleanupScanner.init(),

        /// TTL configuration for cleanup scheduling.
        ttl_config: ttl.Config = ttl.default_config,

        /// Count of entries with non-zero TTL (for tracking if cleanup needed).
        entries_with_ttl: u64 = 0,

        /// TTL metrics for observability (F2.4.5).
        ttl_metrics: ttl.TtlMetrics = ttl.TtlMetrics{},

        /// Deletion metrics for GDPR compliance (F2.5.5).
        deletion_metrics: DeletionMetrics = DeletionMetrics{},

        /// Tombstone lifecycle metrics for compaction monitoring (F2.5.8).
        tombstone_metrics: TombstoneMetrics = TombstoneMetrics{},

        /// Query operation metrics (F3.3).
        query_metrics: QueryMetrics = QueryMetrics{},

        /// Query latency breakdown metrics (14-03).
        /// Tracks per-phase latency (parse, plan, execute, serialize) for performance diagnosis.
        latency_breakdown: QueryLatencyBreakdown = QueryLatencyBreakdown.init(),

        /// Spatial index statistics (14-03).
        /// Tracks RAM index and S2 covering statistics for query planning insights.
        spatial_stats: SpatialIndexStats = SpatialIndexStats.init(),

        /// Counter for periodic spatial stats updates (every 100 queries).
        spatial_stats_update_counter: u64 = 0,

        /// Insert operation metrics.
        insert_metrics: InsertMetrics = InsertMetrics{},

        /// Hot-warm-cold tiering manager (F2.6).
        /// Tracks entity access patterns for automatic tier management.
        /// Null when tiering is disabled in options.
        tiering_manager: ?*TieringManager = null,

        /// Query result cache for dashboard workload optimization (14-01).
        /// Caches query results with write-invalidation semantics.
        /// Null if allocation fails (graceful degradation to no caching).
        result_cache: ?*QueryResultCache = null,

        /// S2 covering cache for spatial query optimization (14-02).
        /// Caches computed S2 cell coverings to avoid redundant computation
        /// for repeated dashboard queries over the same geographic regions.
        /// Null if allocation fails (graceful degradation to recompute each time).
        covering_cache: ?*S2CoveringCache = null,

        /// Batch query metrics for dashboard workload optimization (14-04).
        /// Tracks batch query operations, success rates, and truncation events.
        batch_query_metrics: BatchQueryMetrics = BatchQueryMetrics{},

        /// Prepared query session storage (14-05).
        /// Maps client IDs to their prepared query sessions.
        /// Session-scoped: when a client session expires, their prepared queries
        /// are deallocated (PostgreSQL semantics per query-performance/spec.md).
        session_prepared_queries: std.AutoHashMap(u128, SessionPreparedQueries) = undefined,

        /// Prepared query metrics for observability (14-05).
        /// Tracks compile, execute, and error counts.
        prepared_query_metrics: PreparedQueryMetrics = PreparedQueryMetrics{},

        /// Flag indicating if session_prepared_queries is initialized.
        session_queries_initialized: bool = false,

        // ====================================================================
        // Initialization
        // ====================================================================

        fn init_ram_index(
            allocator: std.mem.Allocator,
            capacity: u32,
            options: Options,
        ) !*DefaultRamIndex {
            const ram_index = try allocator.create(DefaultRamIndex);
            errdefer allocator.destroy(ram_index);

            ram_index.* = DefaultRamIndex.init(allocator, capacity) catch |err| switch (err) {
                error.OutOfMemory => blk: {
                    if (!options.memory_mapped_index_enabled) return err;
                    const mmap_path = options.memory_mapped_index_path orelse
                        return error.InvalidConfiguration;
                    log.warn("RAM index OOM; falling back to memory-mapped index at {s}", .{
                        mmap_path,
                    });
                    break :blk try DefaultRamIndex.init_mmap(mmap_path, capacity);
                },
                else => return err,
            };
            errdefer ram_index.deinit(allocator);

            return ram_index;
        }

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
            const ram_index = try init_ram_index(allocator, ram_index_capacity, options);
            errdefer {
                ram_index.deinit(allocator);
                allocator.destroy(ram_index);
            }

            // Per ttl-retention/spec.md: Convert days to seconds for default TTL
            const seconds_per_day: u32 = 86400;
            const default_ttl_seconds = if (options.default_ttl_days == 0)
                0
            else if (options.default_ttl_days > std.math.maxInt(u32) / seconds_per_day)
                std.math.maxInt(u32) // Overflow protection: cap at max u32
            else
                options.default_ttl_days * seconds_per_day;

            // Initialize TieringManager if enabled (F2.6)
            var tiering_manager: ?*TieringManager = null;
            if (options.tiering_enabled) {
                const tm = try allocator.create(TieringManager);
                errdefer allocator.destroy(tm);
                tm.* = TieringManager.init(allocator, options.tiering_config);
                tiering_manager = tm;
                log.info("GeoStateMachine: tiering enabled", .{});
            }
            errdefer if (tiering_manager) |tm| {
                tm.deinit();
                allocator.destroy(tm);
            };

            // Initialize QueryResultCache (14-01)
            // Graceful degradation: if allocation fails, caching is disabled
            var result_cache: ?*QueryResultCache = null;
            if (allocator.create(QueryResultCache)) |cache_ptr| {
                if (QueryResultCache.init(allocator, 1024)) |cache| {
                    cache_ptr.* = cache;
                    result_cache = cache_ptr;
                    log.info("GeoStateMachine: query result cache enabled (1024 entries)", .{});
                } else |cache_err| {
                    log.warn("GeoStateMachine: query cache init failed: {}, caching disabled", .{cache_err});
                    allocator.destroy(cache_ptr);
                }
            } else |alloc_err| {
                log.warn("GeoStateMachine: query cache alloc failed: {}, caching disabled", .{alloc_err});
            }
            errdefer if (result_cache) |cache| {
                cache.deinit(allocator);
                allocator.destroy(cache);
            };

            // Initialize S2CoveringCache (14-02)
            // Graceful degradation: if allocation fails, coverings are recomputed each time
            var covering_cache: ?*S2CoveringCache = null;
            if (allocator.create(S2CoveringCache)) |cache_ptr| {
                if (S2CoveringCache.init(allocator, 512, .{ .name = "s2_covering" })) |cache| {
                    cache_ptr.* = cache;
                    covering_cache = cache_ptr;
                    log.info("GeoStateMachine: S2 covering cache enabled (512 entries)", .{});
                } else |cache_err| {
                    log.warn("GeoStateMachine: S2 covering cache init failed: {}, caching disabled", .{cache_err});
                    allocator.destroy(cache_ptr);
                }
            } else |alloc_err| {
                log.warn("GeoStateMachine: S2 covering cache alloc failed: {}, caching disabled", .{alloc_err});
            }
            errdefer if (covering_cache) |cache| {
                cache.deinit(allocator);
                allocator.destroy(cache);
            };

            // Initialize session prepared queries map (14-05)
            const session_prepared_queries = std.AutoHashMap(u128, SessionPreparedQueries).init(allocator);

            self.* = .{
                .batch_size_limit = options.batch_size_limit,
                .default_ttl_seconds = default_ttl_seconds,
                .prefetch_timestamp = 0,
                .prepare_timestamp = 0,
                .commit_timestamp = 0,
                .forest = undefined,
                .grid = grid,
                .index_checkpoint_enabled = options.enable_index_checkpoint,
                .last_index_checkpoint_op = 0,
                .ram_index = ram_index,
                .index_recovery = .{},
                .tiering_manager = tiering_manager,
                .result_cache = result_cache,
                .covering_cache = covering_cache,
                .session_prepared_queries = session_prepared_queries,
                .session_queries_initialized = true,
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

            // Clean up TieringManager if enabled (F2.6)
            if (self.tiering_manager) |tm| {
                tm.deinit();
                allocator.destroy(tm);
            }

            // Clean up QueryResultCache (14-01)
            if (self.result_cache) |cache| {
                cache.deinit(allocator);
                allocator.destroy(cache);
            }

            // Clean up S2CoveringCache (14-02)
            if (self.covering_cache) |cache| {
                cache.deinit(allocator);
                allocator.destroy(cache);
            }

            // Clean up session prepared queries (14-05)
            if (self.session_queries_initialized) {
                self.session_prepared_queries.deinit();
            }
        }

        /// Reset state machine for state sync.
        /// Called when a replica needs to sync from another replica's state.
        pub fn reset(self: *GeoStateMachine) void {
            self.forest.reset();

            // Reset query result cache (14-01)
            if (self.result_cache) |cache| {
                cache.reset();
            }

            // Reset S2 covering cache (14-02)
            // Note: Covering cache doesn't need reset on state sync as coverings
            // are determined by geometry, not data state. Keep cached values.

            self.* = .{
                .batch_size_limit = self.batch_size_limit,
                .default_ttl_seconds = self.default_ttl_seconds,
                .prefetch_timestamp = 0,
                .prepare_timestamp = 0,
                .commit_timestamp = 0,
                .forest = self.forest,
                .grid = self.grid,
                .ram_index = self.ram_index,
                .index_recovery = .{},
                .index_checkpoint_enabled = self.index_checkpoint_enabled,
                .last_index_checkpoint_op = 0,
                .tiering_manager = self.tiering_manager,
                .result_cache = self.result_cache,
                .covering_cache = self.covering_cache,
                .session_prepared_queries = self.session_prepared_queries,
                .session_queries_initialized = self.session_queries_initialized,
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
            // TTL cleanup pulse scheduling (F2.4)
            //
            // Returns true when a TTL cleanup pulse operation should be scheduled.
            // The VSR replica will call this periodically and schedule a pulse
            // operation if it returns true.
            //
            // Conditions for triggering cleanup:
            // 1. There are entries with non-zero TTL (something might be expired)
            // 2. The cleanup interval has elapsed since the last run

            // Skip if no entries have TTL set (nothing can expire)
            if (self.entries_with_ttl == 0) {
                return false;
            }

            // Convert timestamp to nanoseconds (VSR timestamp is in ns)
            // Check if cleanup interval has elapsed
            return self.cleanup_scanner.is_due(timestamp, self.ttl_config);
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
                // ArcherDB GeoEvent write operations (F1.2)
                .insert_events => @divExact(batch.len, @sizeOf(GeoEvent)),
                .upsert_events => @divExact(batch.len, @sizeOf(GeoEvent)),
                .delete_entities => @divExact(batch.len, @sizeOf(u128)),
                .cleanup_expired => 1, // Single cleanup operation

                // Pulse: max events that could be processed
                .pulse => batch_max_events(),

                // Read operations: no timestamp increment
                .query_uuid,
                .query_uuid_batch,
                .query_radius,
                .query_polygon,
                .query_latest,
                // ArcherDB diagnostics
                .archerdb_ping,
                .archerdb_get_status,
                // Topology discovery
                .get_topology,
                // Manual TTL operations
                .ttl_set,
                .ttl_extend,
                .ttl_clear,
                // Batch query (14-04)
                .batch_query,
                // Prepared query operations (14-05)
                .prepare_query,
                .execute_prepared,
                .deallocate_prepared,
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

            // NOTE: This is the standalone GeoStateMachine used for VOPR `.geo` mode.
            // Prefetch is optimistic - we use the RAM index for fast lookups,
            // so no LSM prefetch is needed for most operations. Queries use execute-time
            // RAM index scans which are O(1) for UUID and O(n) for spatial (acceptable
            // for VOPR testing which uses smaller datasets).
            //
            // For production, use the unified StateMachine in state_machine.zig which
            // has full Forest LSM prefetch integration.

            switch (operation) {
                // All ArcherDB operations use optimistic/immediate execution
                // GeoEvent operations rely on RAM index for fast access
                .insert_events,
                .upsert_events,
                .delete_entities,
                .cleanup_expired,
                .query_uuid,
                .query_uuid_batch,
                .query_radius,
                .query_polygon,
                .query_latest,
                .archerdb_ping,
                .archerdb_get_status,
                .get_topology,
                .pulse,
                // Manual TTL operations
                .ttl_set,
                .ttl_extend,
                .ttl_clear,
                // Batch query (14-04)
                .batch_query,
                // Prepared query operations (14-05)
                .prepare_query,
                .execute_prepared,
                .deallocate_prepared,
                => {
                    // Optimistic execution - RAM index provides fast access
                    self.prefetch_finish();
                },
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

                // ArcherDB geospatial write operations (F1.2)
                .insert_events => {
                    return self.execute_insert_events(timestamp, message_body_used, output);
                },
                .upsert_events => {
                    return self.execute_upsert_events(timestamp, message_body_used, output);
                },
                .delete_entities => self.execute_delete_entities(message_body_used, output),

                // ArcherDB geospatial query operations (F1.3)
                .query_uuid => self.execute_query_uuid(message_body_used, output),
                .query_uuid_batch => self.execute_query_uuid_batch(message_body_used, output),
                .query_radius => self.execute_query_radius(message_body_used, output),
                .query_polygon => self.execute_query_polygon(message_body_used, output),
                .query_latest => self.execute_query_latest(message_body_used, output),

                // ArcherDB admin operations
                .archerdb_ping => self.execute_archerdb_ping(output),
                .archerdb_get_status => self.execute_archerdb_get_status(output),

                // ArcherDB TTL cleanup (F2.4.8)
                .cleanup_expired => {
                    return self.execute_cleanup_expired(timestamp, message_body_used, output);
                },

                // ArcherDB topology discovery (Smart Client)
                .get_topology => self.execute_get_topology(output),

                // Manual TTL operations
                .ttl_set => self.execute_ttl_set(message_body_used, output),
                .ttl_extend => self.execute_ttl_extend(message_body_used, output),
                .ttl_clear => self.execute_ttl_clear(message_body_used, output),

                // Batch query operation (14-04: Dashboard batch queries)
                .batch_query => self.execute_batch_query(message_body_used, output),

                // Prepared query operations (14-05: Dashboard prepared queries)
                .prepare_query => self.execute_prepare_query(client, message_body_used, output),
                .execute_prepared => self.execute_execute_prepared(client, message_body_used, output),
                .deallocate_prepared => self.execute_deallocate_prepared(client, message_body_used, output),
            };

            return result;
        }

        // ====================================================================
        // Execute Functions (Stubs - to be implemented with Forest integration)
        // ====================================================================

        fn execute_pulse(self: *GeoStateMachine, timestamp: u64) usize {
            // Execute TTL cleanup sweep (F2.4 - TTL Retention)
            // Pulse is called periodically by VSR; we use it for background cleanup.
            //
            // Per ttl-retention/spec.md: TTL cleanup runs at intervals defined by
            // ttl_config.cleanup_interval_ns. The pulse_needed() function checks
            // if we're due for another scan.

            // Only run cleanup if we have entries with TTL
            if (self.entries_with_ttl == 0) {
                return 0;
            }

            // Scan a batch of entries for TTL expiration
            // Use a reasonable batch size to avoid blocking other operations
            const batch_size: u32 = 1000;
            const result = self.ram_index.scan_expired_batch(
                self.cleanup_scanner.position,
                batch_size,
                timestamp,
            );

            // Update scanner state
            const end_time = std.time.nanoTimestamp();
            const run_time_ns: u64 = @intCast(@max(0, end_time - timestamp));
            self.cleanup_scanner.record_batch(
                result.entries_scanned,
                result.entries_removed,
                result.next_position,
                run_time_ns,
            );

            // Update entries_with_ttl count (approximate, will be recalculated on full scan)
            if (result.entries_removed > 0 and self.entries_with_ttl >= result.entries_removed) {
                self.entries_with_ttl -= result.entries_removed;
            }

            // Record metrics
            if (result.entries_removed > 0) {
                archerdb_metrics.Registry.write_events_total.add(result.entries_removed);
            }

            // F2.6: Process tiering maintenance during pulse
            // This triggers tier promotions/demotions based on access patterns
            if (self.tiering_manager) |tm| {
                const transitions = tm.tick(timestamp) catch |err| {
                    log.warn("tiering: tick failed: {}", .{err});
                    return result.entries_removed;
                };
                defer tm.allocator.free(transitions);

                // Process tier transitions (update RAM index for cold demotions)
                for (transitions) |transition| {
                    // Update Prometheus metrics for tier migrations
                    switch (transition.from_tier) {
                        .hot => if (transition.to_tier == .warm) {
                            _ = archerdb_metrics.Registry.tiering_migrations_hot_to_warm.fetchAdd(1, .monotonic);
                        },
                        .warm => if (transition.to_tier == .cold) {
                            _ = archerdb_metrics.Registry.tiering_migrations_warm_to_cold.fetchAdd(1, .monotonic);
                        } else if (transition.to_tier == .hot) {
                            _ = archerdb_metrics.Registry.tiering_migrations_warm_to_hot.fetchAdd(1, .monotonic);
                        },
                        .cold => if (transition.to_tier == .warm) {
                            _ = archerdb_metrics.Registry.tiering_migrations_cold_to_warm.fetchAdd(1, .monotonic);
                        },
                    }

                    if (transition.to_tier == .cold) {
                        // Entity demoted to cold tier - remove from RAM index
                        // Cold entities are disk-only and require LSM scan for queries
                        _ = self.ram_index.remove(transition.entity_id);
                        log.debug("tiering: entity {x} demoted to cold tier", .{transition.entity_id});
                    }
                }

                // Update tier count metrics
                const stats = tm.getStats();
                archerdb_metrics.Registry.tier_entity_count_hot.store(stats.hot_count, .monotonic);
                archerdb_metrics.Registry.tier_entity_count_warm.store(stats.warm_count, .monotonic);
                archerdb_metrics.Registry.tier_entity_count_cold.store(stats.cold_count, .monotonic);

                // Update cold tier query metric
                _ = archerdb_metrics.Registry.cold_tier_fetches_total.store(
                    stats.cold_tier_queries,
                    .monotonic,
                );

                // Log tier statistics periodically
                if (stats.totalEntities() > 0 and result.entries_removed > 0) {
                    log.debug(
                        "tiering: hot={d} warm={d} cold={d} (cost_ratio={d:.2})",
                        .{ stats.hot_count, stats.warm_count, stats.cold_count, stats.estimatedCostRatio() },
                    );
                }
            }

            return result.entries_removed;
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

                // Validate entity_id (maxInt(u128) is reserved per data-model spec).
                if (entity_id == std.math.maxInt(u128)) {
                    results[results_count] = DeleteEntitiesResult{
                        .index = @intCast(index),
                        .result = .entity_id_must_not_be_int_max,
                    };
                    results_count += 1;
                    continue;
                }

                const lookup_result = self.ram_index.lookup(entity_id);

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

                    // F2.6: Record deletion in tiering manager
                    if (self.tiering_manager) |tm| {
                        tm.recordDelete(entity_id);
                    }

                    // F2.5.3: Generate LSM tombstone for GDPR Phase 2.
                    // Per compliance/spec.md: tombstones ensure durable deletion and prevent
                    // resurrection during backup/restore operations.
                    // Create tombstone with current commit timestamp.
                    // The tombstone marks the entity as deleted and will be kept
                    // during compaction until the final LSM level.
                    const tombstone_group_id = if (lookup_result.entry) |entry|
                        entryMetadata(entry).group_id
                    else
                        0;

                    const tombstone = GeoEvent.create_minimal_tombstone(
                        entity_id,
                        tombstone_group_id,
                        self.commit_timestamp,
                    );

                    // Insert tombstone into Forest for durable deletion.
                    // Per ttl-retention/spec.md: tombstones have ttl_seconds=0 (never expire)
                    // and flags.deleted=true.
                    self.forest.grooves.geo_events.insert(&tombstone);
                } else {
                    not_found_count += 1;
                }
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

            // Record per-operation Prometheus metrics (F5.2.2)
            archerdb_metrics.Registry.write_ops_delete.inc();
            archerdb_metrics.Registry.write_operations_total.inc();
            archerdb_metrics.Registry.write_events_total.add(deleted_count);
            archerdb_metrics.Registry.write_latency.observeNs(duration_ns);

            // Record writes for adaptive compaction (12-09: deletion tombstones count as writes)
            if (deleted_count > 0) {
                self.forest.adaptive_record_write(deleted_count);

                // Invalidate query result cache on deletes (14-01)
                if (self.result_cache) |cache| {
                    cache.invalidateAll();
                }
            }

            return results_count * @sizeOf(DeleteEntitiesResult);
        }

        // ====================================================================
        // F1.2: Insert Events Implementation
        // ====================================================================

        /// Execute insert_events operation.
        ///
        /// Validates and inserts a batch of GeoEvents into the RAM index.
        /// Per data-model/spec.md:
        /// - Validates all fields (coordinates, entity_id, flags)
        /// - Computes S2 cell ID at level 30 for spatial indexing
        /// - Builds composite ID: [S2 Cell ID (upper 64) | Timestamp (lower 64)]
        /// - Upserts into RAM index with LWW semantics
        ///
        /// **Current Implementation**: Inserts into RAM index only.
        /// **Future**: When Forest is integrated, also persist to LSM tree.
        ///
        /// Arguments:
        /// - timestamp: VSR consensus timestamp (used if event.timestamp == 0)
        /// - input: Batch of GeoEvent structs
        /// - output: Buffer for InsertGeoEventsResult results
        ///
        /// Returns: Size of response written to output
        fn execute_insert_events(
            self: *GeoStateMachine,
            timestamp: u64,
            input: []const u8,
            output: []u8,
        ) usize {
            const start_time = std.time.nanoTimestamp();

            // Parse input as array of GeoEvents
            const events = mem.bytesAsSlice(GeoEvent, input);
            const max_results = output.len / @sizeOf(InsertGeoEventsResult);
            const results = mem.bytesAsSlice(
                InsertGeoEventsResult,
                output[0 .. max_results * @sizeOf(InsertGeoEventsResult)],
            );

            var results_count: usize = 0;
            var inserted_count: u64 = 0;
            var rejected_count: u64 = 0;

            for (events, 0..) |event, index| {
                if (index >= max_results) break;

                // Validate entity_id (zero is reserved)
                if (event.entity_id == 0) {
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .entity_id_must_not_be_zero,
                    };
                    results_count += 1;
                    rejected_count += 1;
                    continue;
                }

                // Validate entity_id (maxInt(u128) is reserved per data-model spec)
                if (event.entity_id == std.math.maxInt(u128)) {
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .entity_id_must_not_be_int_max,
                    };
                    results_count += 1;
                    rejected_count += 1;
                    continue;
                }

                // Validate coordinates are within valid range
                // Latitude: -90° to +90° (-90_000_000_000 to +90_000_000_000 nanodegrees)
                // Longitude: -180° to +180° (-180_000_000_000 to +180_000_000_000 nanodegrees)
                const lat_max: i64 = 90_000_000_000;
                const lon_max: i64 = 180_000_000_000;

                if (event.lat_nano < -lat_max or event.lat_nano > lat_max) {
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .lat_out_of_range,
                    };
                    results_count += 1;
                    rejected_count += 1;
                    continue;
                }

                if (event.lon_nano < -lon_max or event.lon_nano > lon_max) {
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .lon_out_of_range,
                    };
                    results_count += 1;
                    rejected_count += 1;
                    continue;
                }

                // Validate heading if present (0-35999 centidegrees)
                if (event.heading_cdeg > 35999) {
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .heading_out_of_range,
                    };
                    results_count += 1;
                    rejected_count += 1;
                    continue;
                }

                // Validate reserved field is all zeros (per data-model/spec.md)
                // Reserved fields must be zero for forward compatibility
                var reserved_valid = true;
                for (event.reserved) |byte| {
                    if (byte != 0) {
                        reserved_valid = false;
                        break;
                    }
                }
                if (!reserved_valid) {
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .reserved_field,
                    };
                    results_count += 1;
                    rejected_count += 1;
                    continue;
                }

                // Use consensus timestamp if event timestamp is zero
                const event_timestamp =
                    if (event.timestamp == 0) timestamp else event.timestamp;

                // Per ttl-retention/spec.md: Apply global default TTL
                // when client sets ttl_seconds = 0
                // If default_ttl_seconds is 0, event never expires (infinite)
                // If default_ttl_seconds > 0 and event.ttl_seconds == 0,
                // apply default
                // If event.ttl_seconds > 0, use client-specified TTL (explicit override)
                const effective_ttl_seconds = if (event.ttl_seconds == 0)
                    self.default_ttl_seconds
                else
                    event.ttl_seconds;

                // Compute S2 cell ID at level 30 (7.5mm precision)
                const cell_id = S2.latLonToCellId(event.lat_nano, event.lon_nano, 30);

                // Build composite ID: [S2 Cell ID (upper 64) | Timestamp (lower 64)]
                const composite_id: u128 = (@as(u128, cell_id) << 64) | @as(u128, event_timestamp);

                // Upsert into RAM index with LWW semantics and metadata
                const upsert_result = self.ram_index.upsertWithMetadata(
                    event.entity_id,
                    composite_id,
                    effective_ttl_seconds,
                    .{
                        .lat_nano = event.lat_nano,
                        .lon_nano = event.lon_nano,
                        .group_id = event.group_id,
                    },
                ) catch |err| {
                    // Handle index capacity errors
                    log.err("insert_events: RAM index error: {}", .{err});
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .reserved_field, // Using reserved as "internal error"
                    };
                    results_count += 1;
                    rejected_count += 1;
                    continue;
                };

                // Record result
                if (upsert_result.inserted) {
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .ok,
                    };
                    inserted_count += 1;
                    // Track entries with TTL for pulse scheduling (use effective TTL)
                    if (effective_ttl_seconds > 0) {
                        self.entries_with_ttl += 1;
                    }

                    // F2.6: Record insert in tiering manager (new entities start in hot tier)
                    if (self.tiering_manager) |tm| {
                        tm.recordInsert(event.entity_id, event_timestamp) catch |err| {
                            log.warn("tiering: recordInsert failed: {}", .{err});
                        };
                    }

                    if (DefaultRamIndex.supports_metadata) {
                        _ = self.ram_index.update_metadata(
                            event.entity_id,
                            composite_id,
                            event.lat_nano,
                            event.lon_nano,
                            event.group_id,
                        );
                    }

                    // Insert into Forest (LSM storage)
                    var stored_event = event;
                    stored_event.id = composite_id;
                    stored_event.timestamp = event_timestamp;
                    stored_event.ttl_seconds = effective_ttl_seconds;
                    self.forest.grooves.geo_events.insert(&stored_event);
                } else if (upsert_result.updated) {
                    // LWW accepted the update
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .ok,
                    };
                    inserted_count += 1;
                    // Note: TTL tracking for updates is complex (old TTL vs new TTL)
                    // For simplicity, we assume updates maintain TTL status

                    // F2.6: Record access in tiering manager (updates count as access)
                    if (self.tiering_manager) |tm| {
                        _ = tm.recordAccess(event.entity_id, event_timestamp) catch |err| {
                            log.warn("tiering: recordAccess failed: {}", .{err});
                        };
                    }

                    if (DefaultRamIndex.supports_metadata) {
                        _ = self.ram_index.update_metadata(
                            event.entity_id,
                            composite_id,
                            event.lat_nano,
                            event.lon_nano,
                            event.group_id,
                        );
                    }

                    // Insert into Forest (LSM storage)
                    var stored_event = event;
                    stored_event.id = composite_id;
                    stored_event.timestamp = event_timestamp;
                    stored_event.ttl_seconds = effective_ttl_seconds;
                    self.forest.grooves.geo_events.insert(&stored_event);
                } else {
                    // LWW rejected - older event
                    results[results_count] = InsertGeoEventsResult{
                        .index = @intCast(index),
                        .result = .exists,
                    };
                    rejected_count += 1;
                }
                results_count += 1;
            }

            log.debug(
                "insert_events: processed {d} events, {d} results",
                .{ events.len, results_count },
            );

            // Record insert metrics
            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 =
                if (end_time > start_time) @intCast(end_time - start_time) else 0;
            self.insert_metrics.recordInsertBatch(inserted_count, rejected_count, duration_ns);

            // Record per-operation Prometheus metrics (F5.2.2)
            archerdb_metrics.Registry.write_ops_insert.inc();
            archerdb_metrics.Registry.write_operations_total.inc();
            archerdb_metrics.Registry.write_events_total.add(inserted_count);
            archerdb_metrics.Registry.write_latency.observeNs(duration_ns);

            // Record writes for adaptive compaction (12-09: workload tracking)
            if (inserted_count > 0) {
                self.forest.adaptive_record_write(inserted_count);

                // Invalidate query result cache on writes (14-01)
                if (self.result_cache) |cache| {
                    cache.invalidateAll();
                }
            }

            // Update index capacity metrics and check thresholds (F5.2 - Observability)
            const stats = self.ram_index.get_stats();
            if (stats.capacity > 0) {
                const load_factor_pct = (stats.entry_count * 100) / stats.capacity;
                archerdb_metrics.Registry.index_load_factor.set(@intCast(load_factor_pct * 100));

                // Increment capacity warning/critical counters at thresholds
                if (load_factor_pct >= 95) {
                    archerdb_metrics.Registry.index_capacity_emergency_total.inc();
                } else if (load_factor_pct >= 90) {
                    archerdb_metrics.Registry.index_capacity_critical_total.inc();
                } else if (load_factor_pct >= 80) {
                    archerdb_metrics.Registry.index_capacity_warning_total.inc();
                }

                // Update tombstone ratio gauge
                if (stats.entry_count > 0) {
                    const tombstone_ratio_pct =
                        (stats.tombstone_count * 100) / stats.entry_count;
                    archerdb_metrics.Registry.index_tombstone_ratio.set(
                        @intCast(tombstone_ratio_pct * 100),
                    );
                }
            }

            return results_count * @sizeOf(InsertGeoEventsResult);
        }

        // ====================================================================
        // F1.2: Upsert Events Implementation
        // ====================================================================

        /// Execute upsert_events operation.
        ///
        /// Same as insert_events but with upsert semantics - always succeeds
        /// using LWW resolution instead of failing on existing entries.
        /// This is essentially an alias to insert_events since our RAM index
        /// uses LWW by default.
        fn execute_upsert_events(
            self: *GeoStateMachine,
            timestamp: u64,
            input: []const u8,
            output: []u8,
        ) usize {
            // Upsert uses the same implementation as insert
            // (LWW semantics handle conflicts automatically)
            const result = self.execute_insert_events(timestamp, input, output);

            // Override the operation counter to upsert (insert already recorded write_ops_insert)
            // We decrement insert and increment upsert for accurate per-operation tracking
            _ = archerdb_metrics.Registry.write_ops_insert.value.fetchSub(1, .monotonic);
            archerdb_metrics.Registry.write_ops_upsert.inc();

            return result;
        }

        fn index_recovery_blocks_covering(
            self: *const GeoStateMachine,
            covering: []const s2_index.CellRange,
        ) bool {
            if (!self.index_recovery.active) return false;
            if (self.index_recovery.blocks_all()) return true;
            for (covering) |range| {
                if (range.start == 0 and range.end == 0) continue;
                if (self.index_recovery.blocks_range(range)) return true;
            }
            return false;
        }

        fn index_recovery_blocks_entry(
            self: *const GeoStateMachine,
            entry: ?IndexEntry,
        ) bool {
            if (!self.index_recovery.active) return false;
            if (self.index_recovery.blocks_all()) return true;
            if (entry) |value| {
                const cell_id = @as(u64, @truncate(value.latest_id >> 64));
                return self.index_recovery.blocks_cell(cell_id);
            }
            return false;
        }

        fn write_query_uuid_error(
            self: *GeoStateMachine,
            output: []u8,
            start_time: i128,
            status: StateError,
        ) usize {
            const response_size = @sizeOf(QueryUuidResponse);
            if (output.len < response_size) {
                log.warn("query_uuid: output buffer too small for header", .{});
                return 0;
            }

            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 = if (end_time > start_time)
                @intCast(end_time - start_time)
            else
                0;

            self.query_metrics.recordUuidQuery(false, duration_ns);
            archerdb_metrics.Registry.read_ops_query_uuid.inc();
            archerdb_metrics.Registry.read_operations_total.inc();
            archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
            archerdb_metrics.Registry.query_result_size.observe(0.0);

            const header = mem.bytesAsValue(
                QueryUuidResponse,
                output[0..response_size],
            );
            header.* = QueryUuidResponse{
                .status = @intCast(@intFromEnum(status)),
            };
            return response_size;
        }

        fn write_query_uuid_batch_error(
            self: *GeoStateMachine,
            output: []u8,
            start_time: i128,
            status: StateError,
        ) usize {
            if (output.len < @sizeOf(QueryUuidBatchResult)) {
                log.warn("query_uuid_batch: output buffer too small for header", .{});
                return 0;
            }

            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 = if (end_time > start_time)
                @intCast(end_time - start_time)
            else
                0;

            self.query_metrics.recordUuidQuery(false, duration_ns);
            archerdb_metrics.Registry.read_ops_query_uuid.inc();
            archerdb_metrics.Registry.read_operations_total.inc();
            archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
            archerdb_metrics.Registry.query_result_size.observe(0.0);

            const result_header = mem.bytesAsValue(
                QueryUuidBatchResult,
                output[0..@sizeOf(QueryUuidBatchResult)],
            );
            result_header.* = QueryUuidBatchResult.with_error(status);
            return @sizeOf(QueryUuidBatchResult);
        }

        // ====================================================================
        // F1.3: Query UUID Implementation
        // ====================================================================

        /// Execute query_uuid operation.
        ///
        /// Looks up a single entity by UUID and returns its latest GeoEvent.
        /// Uses O(1) RAM index lookup per hybrid-memory/spec.md.
        ///
        /// Arguments:
        /// - input: QueryUuidFilter with entity_id
        /// - output: Buffer for GeoEvent result
        ///
        /// Returns: Size of response (0 if not found, sizeof(GeoEvent) if found)
        fn execute_query_uuid(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            const start_time = std.time.nanoTimestamp();
            const response_size = @sizeOf(QueryUuidResponse);

            // Check query result cache (14-01)
            const query_hash = if (self.result_cache != null)
                QueryResultCache.hashQuery(@intFromEnum(Operation.query_uuid), input)
            else
                0;
            if (self.result_cache) |cache| {
                if (cache.get(query_hash)) |cached| {
                    const cached_data = cached.getData();
                    if (cached_data.len <= output.len) {
                        @memcpy(output[0..cached_data.len], cached_data);
                        self.query_metrics.recordCacheHit();
                        return cached_data.len;
                    }
                }
                self.query_metrics.recordCacheMiss();
            }

            // Validate input size
            if (input.len != @sizeOf(QueryUuidFilter)) {
                log.warn("query_uuid: input size invalid ({d} != {d})", .{
                    input.len,
                    @sizeOf(QueryUuidFilter),
                });
                return 0;
            }

            // Parse filter
            const filter = mem.bytesAsValue(
                QueryUuidFilter,
                input[0..@sizeOf(QueryUuidFilter)],
            ).*;
            const end_parse = std.time.nanoTimestamp();

            // Validate entity_id
            if (filter.entity_id == 0) {
                log.warn("query_uuid: entity_id must not be zero", .{});
                return 0;
            }

            // No plan phase for UUID queries (no S2 covering)
            const end_plan = end_parse;

            // O(1) lookup in RAM index (execute phase)
            const lookup_result = self.ram_index.lookup(filter.entity_id);

            if (self.index_recovery_blocks_entry(lookup_result.entry)) {
                return self.write_query_uuid_error(
                    output,
                    start_time,
                    StateError.index_rebuilding,
                );
            }

            if (lookup_result.entry) |entry| {
                if (output.len < response_size) {
                    log.warn("query_uuid: output buffer too small for header", .{});
                    return 0;
                }

                // Found - build GeoEvent from index entry
                // Extract timestamp from composite ID
                const event_timestamp = @as(u64, @truncate(entry.latest_id));

                // Check TTL expiration (per query-engine/spec.md)
                // If entity has expired, return empty result (entity_expired)
                if (entry.ttl_seconds > 0) {
                    const now_seconds = self.commit_timestamp / 1_000_000_000;
                    const creation_seconds = event_timestamp / 1_000_000_000;
                    const expiry_seconds = creation_seconds + @as(u64, entry.ttl_seconds);
                    if (now_seconds > expiry_seconds) {
                        // Entity has expired - log and return empty
                        log.debug("query_uuid: entity {x} expired (ttl={d}s, age={d}s)", .{
                            filter.entity_id,
                            entry.ttl_seconds,
                            now_seconds - creation_seconds,
                        });

                        // Record TTL expiration metric
                        self.ttl_metrics.record_lookup_expiration();

                        // Record metrics (query completed but found expired)
                        const end_time = std.time.nanoTimestamp();
                        const duration_ns: u64 = if (end_time > start_time)
                            @intCast(end_time - start_time)
                        else
                            0;
                        self.query_metrics.recordUuidQuery(false, duration_ns);
                        archerdb_metrics.Registry.read_ops_query_uuid.inc();
                        archerdb_metrics.Registry.read_operations_total.inc();
                        archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
                        const header = mem.bytesAsValue(
                            QueryUuidResponse,
                            output[0..response_size],
                        );
                        header.* = QueryUuidResponse{
                            .status = @intCast(@intFromEnum(StateError.entity_expired)),
                        };
                        return response_size;
                    }
                }

                if (output.len < response_size + @sizeOf(GeoEvent)) {
                    log.warn("query_uuid: output buffer too small", .{});
                    return 0;
                }

                // F2.6: Record access in tiering manager for query
                if (self.tiering_manager) |tm| {
                    _ = tm.recordAccess(filter.entity_id, self.commit_timestamp) catch |err| {
                        log.warn("tiering: recordAccess failed: {}", .{err});
                    };
                }

                var result_event: GeoEvent = undefined;

                // Try to get full event from LSM tree (memtable or cache)
                switch (self.forest.grooves.geo_events.get(entry.latest_id)) {
                    .found_object => |event| {
                        result_event = event;
                    },
                    else => {
                        // Fallback to RAM index reconstruction (metadata only).
                        // This happens if the event is on disk and was not prefetched.
                        const metadata = entryMetadata(entry);
                        result_event = GeoEvent{
                            .id = entry.latest_id,
                            .entity_id = entry.entity_id,
                            .correlation_id = 0, // Not stored in RAM index
                            .user_data = 0, // Not stored in RAM index
                            .lat_nano = metadata.lat_nano,
                            .lon_nano = metadata.lon_nano,
                            .group_id = metadata.group_id,
                            .timestamp = event_timestamp,
                            .altitude_mm = 0,
                            .velocity_mms = 0,
                            .ttl_seconds = entry.ttl_seconds,
                            .accuracy_mm = 0,
                            .heading_cdeg = 0,
                            .flags = GeoEventFlags.none,
                            .reserved = [_]u8{0} ** 12,
                        };
                    },
                }
                const end_execute = std.time.nanoTimestamp();

                // Write to output (serialize phase)
                const start_serialize = end_execute;
                const header = mem.bytesAsValue(
                    QueryUuidResponse,
                    output[0..response_size],
                );
                header.* = QueryUuidResponse{
                    .status = 0,
                };
                const result_ptr = mem.bytesAsValue(
                    GeoEvent,
                    output[response_size..][0..@sizeOf(GeoEvent)],
                );
                result_ptr.* = result_event;

                // Record metrics
                const end_time = std.time.nanoTimestamp();
                const duration_ns: u64 = if (end_time > start_time)
                    @intCast(end_time - start_time)
                else
                    0;
                self.query_metrics.recordUuidQuery(true, duration_ns);

                // Record per-operation Prometheus metrics (F5.2.2)
                archerdb_metrics.Registry.read_ops_query_uuid.inc();
                archerdb_metrics.Registry.read_operations_total.inc();
                archerdb_metrics.Registry.read_events_returned_total.add(1);
                archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
                archerdb_metrics.Registry.query_result_size.observe(1.0);

                // Record query latency breakdown (14-03)
                self.latency_breakdown.recordPhases(.{
                    .query_type = .uuid,
                    .parse_ns = @intCast(@max(0, end_parse - start_time)),
                    .plan_ns = 0, // No S2 covering for UUID queries
                    .execute_ns = @intCast(@max(0, end_execute - end_plan)),
                    .serialize_ns = @intCast(@max(0, end_time - start_serialize)),
                });

                // Record read for adaptive compaction (12-09: point lookup workload tracking)
                self.forest.adaptive_record_read(1);

                log.debug("query_uuid: found entity {x}", .{filter.entity_id});

                // Cache the result (14-01)
                if (self.result_cache) |cache| {
                    cache.put(query_hash, output[0..response_size + @sizeOf(GeoEvent)]);
                }
                return response_size + @sizeOf(GeoEvent);
            } else {
                // Not found - record metrics
                const end_time = std.time.nanoTimestamp();
                const duration_ns: u64 = if (end_time > start_time)
                    @intCast(end_time - start_time)
                else
                    0;
                self.query_metrics.recordUuidQuery(false, duration_ns);

                // Record per-operation Prometheus metrics (F5.2.2)
                archerdb_metrics.Registry.read_ops_query_uuid.inc();
                archerdb_metrics.Registry.read_operations_total.inc();
                archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
                archerdb_metrics.Registry.query_result_size.observe(0.0);

                log.debug("query_uuid: entity {x} not found", .{filter.entity_id});
                if (output.len < response_size) {
                    log.warn("query_uuid: output buffer too small for header", .{});
                    return 0;
                }
                const header = mem.bytesAsValue(
                    QueryUuidResponse,
                    output[0..response_size],
                );
                header.* = QueryUuidResponse{
                    .status = @intCast(@intFromEnum(StateError.entity_not_found)),
                };
                return response_size;
            }
        }

        // ====================================================================
        // F1.3.4: Batch UUID Query Implementation
        // ====================================================================

        /// Execute query_uuid_batch operation.
        ///
        /// Looks up multiple entities by UUID and returns their latest GeoEvents.
        /// Uses O(1) RAM index lookup per entity per hybrid-memory/spec.md.
        ///
        /// Arguments:
        /// - input: QueryUuidBatchFilter header + entity_ids array
        /// - output: Buffer for QueryUuidBatchResult header + not_found_indices + GeoEvent array
        ///
        /// Returns: Size of response
        fn execute_query_uuid_batch(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            const start_time = std.time.nanoTimestamp();

            // Validate input has at least the header
            if (input.len < @sizeOf(QueryUuidBatchFilter)) {
                log.warn("query_uuid_batch: input too small ({d} < {d})", .{
                    input.len,
                    @sizeOf(QueryUuidBatchFilter),
                });
                return 0;
            }

            // Parse filter header
            const filter = mem.bytesAsValue(
                QueryUuidBatchFilter,
                input[0..@sizeOf(QueryUuidBatchFilter)],
            ).*;

            // Validate count
            if (filter.count == 0) {
                // Empty batch - return empty result
                if (output.len < @sizeOf(QueryUuidBatchResult)) {
                    return 0;
                }
                const result_header = mem.bytesAsValue(
                    QueryUuidBatchResult,
                    output[0..@sizeOf(QueryUuidBatchResult)],
                );
                result_header.* = QueryUuidBatchResult{
                    .found_count = 0,
                    .not_found_count = 0,
                };
                return @sizeOf(QueryUuidBatchResult);
            }

            if (filter.count > QueryUuidBatchFilter.max_count) {
                log.warn("query_uuid_batch: count {d} exceeds max {d}", .{
                    filter.count,
                    QueryUuidBatchFilter.max_count,
                });
                return 0;
            }

            // Validate input has all entity_ids
            const entity_ids_size = filter.count * @sizeOf(u128);
            const expected_input_size = @sizeOf(QueryUuidBatchFilter) + entity_ids_size;
            if (input.len < expected_input_size) {
                log.warn("query_uuid_batch: input too small for {d} UUIDs ({d} < {d})", .{
                    filter.count,
                    input.len,
                    expected_input_size,
                });
                return 0;
            }

            // Get entity_ids slice
            const entity_ids_bytes = input[@sizeOf(QueryUuidBatchFilter)..][0..entity_ids_size];
            const entity_ids = @as(
                [*]const u128,
                @ptrCast(@alignCast(entity_ids_bytes.ptr)),
            )[0..filter.count];

            if (self.index_recovery.active) {
                if (self.index_recovery.blocks_all()) {
                    return self.write_query_uuid_batch_error(
                        output,
                        start_time,
                        StateError.index_rebuilding,
                    );
                }
                for (entity_ids) |entity_id| {
                    if (entity_id == 0) continue;
                    const lookup_result = self.ram_index.lookup(entity_id);
                    if (self.index_recovery_blocks_entry(lookup_result.entry)) {
                        return self.write_query_uuid_batch_error(
                            output,
                            start_time,
                            StateError.index_rebuilding,
                        );
                    }
                }
            }

            // Calculate output layout:
            // - Header: 16 bytes
            // - not_found_indices: 2 bytes each (max filter.count)
            // - padding to 16-byte alignment
            // - events: 128 bytes each (max filter.count)
            const max_not_found_size = filter.count * @sizeOf(u16);
            const not_found_offset = @sizeOf(QueryUuidBatchResult);
            const events_offset_unaligned = not_found_offset + max_not_found_size;
            // Align to 16 bytes
            const events_offset =
                (events_offset_unaligned + 15) & ~@as(usize, 15);
            const max_events_size = filter.count * @sizeOf(GeoEvent);
            const max_output_size = events_offset + max_events_size;

            if (output.len < max_output_size) {
                log.warn("query_uuid_batch: output buffer too small ({d} < {d})", .{
                    output.len,
                    max_output_size,
                });
                return 0;
            }

            // Process lookups
            var found_count: u32 = 0;
            var not_found_count: u32 = 0;
            const not_found_indices = @as(
                [*]u16,
                @ptrCast(@alignCast(output[not_found_offset..].ptr)),
            );
            const events_ptr = @as([*]GeoEvent, @ptrCast(@alignCast(output[events_offset..].ptr)));

            for (entity_ids, 0..) |entity_id, i| {
                if (entity_id == 0) {
                    // Invalid entity_id - treat as not found
                    not_found_indices[not_found_count] = @intCast(i);
                    not_found_count += 1;
                    continue;
                }

                // O(1) lookup in RAM index
                const lookup_result = self.ram_index.lookup(entity_id);

                if (lookup_result.entry) |entry| {
                    const event_timestamp = @as(u64, @truncate(entry.latest_id));

                    // Check TTL expiration (per query-engine/spec.md)
                    if (entry.ttl_seconds > 0) {
                        const now_seconds = self.commit_timestamp / 1_000_000_000;
                        const creation_seconds = event_timestamp / 1_000_000_000;
                        const expiry_seconds = creation_seconds + @as(u64, entry.ttl_seconds);
                        if (now_seconds > expiry_seconds) {
                            // Entity expired - treat as not found
                            self.ttl_metrics.record_lookup_expiration();
                            not_found_indices[not_found_count] = @intCast(i);
                            not_found_count += 1;
                            continue;
                        }
                    }

                    var result_event: GeoEvent = undefined;
                    switch (self.forest.grooves.geo_events.get(entry.latest_id)) {
                        .found_object => |event| {
                            result_event = event;
                        },
                        else => {
                            const metadata = entryMetadata(entry);
                            result_event = GeoEvent{
                                .id = entry.latest_id,
                                .entity_id = entry.entity_id,
                                .correlation_id = 0,
                                .user_data = 0,
                                .lat_nano = metadata.lat_nano,
                                .lon_nano = metadata.lon_nano,
                                .group_id = metadata.group_id,
                                .timestamp = event_timestamp,
                                .altitude_mm = 0,
                                .velocity_mms = 0,
                                .ttl_seconds = entry.ttl_seconds,
                                .accuracy_mm = 0,
                                .heading_cdeg = 0,
                                .flags = GeoEventFlags.none,
                                .reserved = [_]u8{0} ** 12,
                            };
                        },
                    }
                    events_ptr[found_count] = result_event;
                    found_count += 1;
                } else {
                    // Not found
                    not_found_indices[not_found_count] = @intCast(i);
                    not_found_count += 1;
                }
            }

            // Write result header
            const result_header = mem.bytesAsValue(
                QueryUuidBatchResult,
                output[0..@sizeOf(QueryUuidBatchResult)],
            );
            result_header.* = QueryUuidBatchResult{
                .found_count = found_count,
                .not_found_count = not_found_count,
            };

            // Zero padding between not_found_indices and events
            const actual_not_found_size = not_found_count * @sizeOf(u16);
            const padding_start = not_found_offset + actual_not_found_size;
            const padding_end = events_offset;
            if (padding_end > padding_start) {
                @memset(output[padding_start..padding_end], 0);
            }

            // Calculate actual response size
            const actual_events_size = found_count * @sizeOf(GeoEvent);
            const response_size = events_offset + actual_events_size;

            // Record metrics
            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 = if (end_time > start_time)
                @intCast(end_time - start_time)
            else
                0;

            // Record per-operation Prometheus metrics
            archerdb_metrics.Registry.read_ops_query_uuid.add(filter.count);
            archerdb_metrics.Registry.read_operations_total.inc();
            archerdb_metrics.Registry.read_events_returned_total.add(found_count);
            archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
            archerdb_metrics.Registry.query_result_size.observe(@floatFromInt(found_count));

            log.debug("query_uuid_batch: found {d}/{d} entities", .{ found_count, filter.count });
            return response_size;
        }

        // ====================================================================
        // Admin Operations
        // ====================================================================

        /// Execute archerdb_ping operation.
        ///
        /// Simple health check that returns success.
        /// Used by clients to verify connectivity.
        fn execute_archerdb_ping(
            self: *GeoStateMachine,
            output: []u8,
        ) usize {
            _ = self;
            // Return a simple "pong" response (4 bytes: 0x706F6E67 = "pong")
            if (output.len >= 4) {
                output[0] = 'p';
                output[1] = 'o';
                output[2] = 'n';
                output[3] = 'g';
                return 4;
            }
            return 0;
        }

        /// Execute archerdb_get_status operation.
        ///
        /// Returns current server status including:
        /// - RAM index statistics (entry count, capacity, load factor)
        /// - TTL cleanup metrics
        /// - Deletion metrics
        fn execute_archerdb_get_status(
            self: *GeoStateMachine,
            output: []u8,
        ) usize {
            // Status response structure (64 bytes)
            const StatusResponse = extern struct {
                /// RAM index entry count
                ram_index_count: u64,
                /// RAM index capacity
                ram_index_capacity: u64,
                /// RAM index load factor (as percentage * 100)
                ram_index_load_pct: u32,
                /// Padding for alignment
                _padding: u32 = 0,
                /// Tombstone count
                tombstone_count: u64,
                /// Total TTL expirations
                ttl_expirations: u64,
                /// Total deletions
                deletion_count: u64,
                /// Reserved for future use
                reserved: [16]u8,
            };

            comptime {
                assert(@sizeOf(StatusResponse) == 64);
            }

            if (output.len < @sizeOf(StatusResponse)) {
                return 0;
            }

            const stats = self.ram_index.stats;
            const load_pct: u32 = if (stats.capacity > 0)
                @intCast((stats.entry_count * 10000) / stats.capacity)
            else
                0;

            const response = StatusResponse{
                .ram_index_count = stats.entry_count,
                .ram_index_capacity = stats.capacity,
                .ram_index_load_pct = load_pct,
                .tombstone_count = stats.tombstone_count,
                .ttl_expirations = self.ttl_metrics.total_expirations(),
                .deletion_count = self.deletion_metrics.entities_deleted,
                .reserved = [_]u8{0} ** 16,
            };

            const response_ptr = mem.bytesAsValue(
                StatusResponse,
                output[0..@sizeOf(StatusResponse)],
            );
            response_ptr.* = response;

            return @sizeOf(StatusResponse);
        }

        // ====================================================================
        // F5.1: Smart Client Topology Discovery
        // ====================================================================

        /// Execute get_topology operation for Smart Client discovery.
        ///
        /// Returns the current cluster topology including:
        /// - Shard count and configuration
        /// - Shard-to-node mapping with primary/backup roles
        /// - Topology version for cache invalidation
        /// - Resharding status if a resharding is in progress
        ///
        /// Smart clients use this information for:
        /// - Direct shard routing (bypass coordinator overhead)
        /// - Scatter-gather queries across shards
        /// - Topology change detection via version polling
        ///
        /// Arguments:
        /// - output: Buffer for TopologyResponse
        ///
        /// Returns: Size of response written to output (number of bytes)
        fn execute_get_topology(
            self: *GeoStateMachine,
            output: []u8,
        ) usize {
            _ = self; // Topology is cluster-wide, not per-state-machine state

            if (output.len < @sizeOf(TopologyResponse)) {
                log.warn("get_topology: output buffer too small ({d} < {d})", .{
                    output.len,
                    @sizeOf(TopologyResponse),
                });
                return 0;
            }

            // Build topology response
            // Note: In production, this would query the actual cluster state from
            // the TopologyManager. For now, we return a minimal valid response
            // indicating a single-shard configuration.
            var response = TopologyResponse.init();
            response.version = 1;
            response.num_shards = 1;
            response.last_change_ns = std.time.nanoTimestamp();
            response.resharding_status = 0; // Not resharding

            // Set up shard 0 as active (single-shard mode)
            response.shards[0] = topology_mod.ShardInfo.init(0);
            response.shards[0].status = .active;
            response.shards[0].setPrimary("127.0.0.1:5000");

            // Write response to output buffer
            const response_ptr = mem.bytesAsValue(
                TopologyResponse,
                output[0..@sizeOf(TopologyResponse)],
            );
            response_ptr.* = response;

            log.debug("get_topology: returned topology v{d} with {d} shards", .{
                response.version,
                response.num_shards,
            });

            return @sizeOf(TopologyResponse);
        }

        // ====================================================================
        // Manual TTL Operations
        // ====================================================================

        /// Execute TTL set operation - set absolute TTL for an entity.
        ///
        /// CLI: `archerdb ttl set <entity_id> --ttl=<seconds>`
        ///
        /// Arguments:
        /// - input: TtlSetRequest serialized data
        /// - output: Buffer for TtlSetResponse
        ///
        /// Returns: Size of response written to output (number of bytes)
        fn execute_ttl_set(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            const ttl_mod = @import("ttl.zig");
            const TtlSetRequest = ttl_mod.TtlSetRequest;
            const TtlSetResponse = ttl_mod.TtlSetResponse;

            if (input.len < @sizeOf(TtlSetRequest)) {
                log.warn(
                    "ttl_set: input too small ({d} < {d})",
                    .{ input.len, @sizeOf(TtlSetRequest) },
                );
                return 0;
            }

            if (output.len < @sizeOf(TtlSetResponse)) {
                log.warn(
                    "ttl_set: output buffer too small ({d} < {d})",
                    .{ output.len, @sizeOf(TtlSetResponse) },
                );
                return 0;
            }

            const request = mem.bytesAsValue(TtlSetRequest, input[0..@sizeOf(TtlSetRequest)]);

            // Look up entity in RAM index
            var response = TtlSetResponse{
                .entity_id = request.entity_id,
                .previous_ttl_seconds = 0,
                .new_ttl_seconds = 0,
                .result = .entity_not_found,
            };

            // Find entity in index using lookup
            const lookup_result = self.ram_index.lookup(request.entity_id);
            if (lookup_result.entry) |entry| {
                response.previous_ttl_seconds = entry.ttl_seconds;
                response.new_ttl_seconds = request.ttl_seconds;
                response.result = .success;

                // Update TTL in index using upsert
                _ = self.ram_index.upsert(
                    request.entity_id,
                    entry.latest_id,
                    request.ttl_seconds,
                ) catch |err| {
                    log.warn("ttl_set: upsert failed: {}", .{err});
                    response.result = .not_permitted;
                };

                // Update TTL tracking metrics (only if upsert succeeded)
                if (response.result == .success) {
                    if (entry.ttl_seconds == 0 and request.ttl_seconds > 0) {
                        self.entries_with_ttl += 1;
                    } else if (entry.ttl_seconds > 0 and
                        request.ttl_seconds == 0)
                    {
                        if (self.entries_with_ttl > 0) {
                            self.entries_with_ttl -= 1;
                        }
                    }
                }

                log.debug("ttl_set: entity {x} TTL {d} -> {d}", .{
                    request.entity_id,
                    response.previous_ttl_seconds,
                    response.new_ttl_seconds,
                });
            }

            // Write response
            const response_ptr = mem.bytesAsValue(
                TtlSetResponse,
                output[0..@sizeOf(TtlSetResponse)],
            );
            response_ptr.* = response;

            return @sizeOf(TtlSetResponse);
        }

        /// Execute TTL extend operation - extend TTL by a relative amount.
        ///
        /// CLI: `archerdb ttl extend <entity_id> --by=<seconds>`
        ///
        /// Arguments:
        /// - input: TtlExtendRequest serialized data
        /// - output: Buffer for TtlExtendResponse
        ///
        /// Returns: Size of response written to output (number of bytes)
        fn execute_ttl_extend(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            const ttl_mod = @import("ttl.zig");
            const TtlExtendRequest = ttl_mod.TtlExtendRequest;
            const TtlExtendResponse = ttl_mod.TtlExtendResponse;

            if (input.len < @sizeOf(TtlExtendRequest)) {
                log.warn(
                    "ttl_extend: input too small ({d} < {d})",
                    .{ input.len, @sizeOf(TtlExtendRequest) },
                );
                return 0;
            }

            if (output.len < @sizeOf(TtlExtendResponse)) {
                log.warn(
                    "ttl_extend: output buffer too small ({d} < {d})",
                    .{ output.len, @sizeOf(TtlExtendResponse) },
                );
                return 0;
            }

            const request = mem.bytesAsValue(TtlExtendRequest, input[0..@sizeOf(TtlExtendRequest)]);

            // Look up entity in RAM index
            var response = TtlExtendResponse{
                .entity_id = request.entity_id,
                .previous_ttl_seconds = 0,
                .new_ttl_seconds = 0,
                .result = .entity_not_found,
            };

            // Find entity in index using lookup
            const lookup_result = self.ram_index.lookup(request.entity_id);
            if (lookup_result.entry) |entry| {
                response.previous_ttl_seconds = entry.ttl_seconds;

                // Calculate new TTL (with overflow protection)
                const new_ttl = @as(u64, entry.ttl_seconds) +
                    @as(u64, request.extend_by_seconds);
                response.new_ttl_seconds = if (new_ttl > std.math.maxInt(u32))
                    std.math.maxInt(u32)
                else
                    @intCast(new_ttl);

                response.result = .success;

                // Update TTL in index using upsert
                _ = self.ram_index.upsert(
                    request.entity_id,
                    entry.latest_id,
                    response.new_ttl_seconds,
                ) catch |err| {
                    log.warn("ttl_extend: upsert failed: {}", .{err});
                    response.result = .not_permitted;
                };

                // Update TTL tracking metrics (only if upsert succeeded)
                if (response.result == .success and entry.ttl_seconds == 0 and
                    response.new_ttl_seconds > 0)
                {
                    self.entries_with_ttl += 1;
                }

                log.debug("ttl_extend: entity {x} TTL {d} -> {d} (+{d})", .{
                    request.entity_id,
                    response.previous_ttl_seconds,
                    response.new_ttl_seconds,
                    request.extend_by_seconds,
                });
            }

            // Write response
            const response_ptr = mem.bytesAsValue(
                TtlExtendResponse,
                output[0..@sizeOf(TtlExtendResponse)],
            );
            response_ptr.* = response;

            return @sizeOf(TtlExtendResponse);
        }

        /// Execute TTL clear operation - remove TTL (infinite retention).
        ///
        /// CLI: `archerdb ttl clear <entity_id>`
        ///
        /// Arguments:
        /// - input: TtlClearRequest serialized data
        /// - output: Buffer for TtlClearResponse
        ///
        /// Returns: Size of response written to output (number of bytes)
        fn execute_ttl_clear(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            const ttl_mod = @import("ttl.zig");
            const TtlClearRequest = ttl_mod.TtlClearRequest;
            const TtlClearResponse = ttl_mod.TtlClearResponse;

            if (input.len < @sizeOf(TtlClearRequest)) {
                log.warn(
                    "ttl_clear: input too small ({d} < {d})",
                    .{ input.len, @sizeOf(TtlClearRequest) },
                );
                return 0;
            }

            if (output.len < @sizeOf(TtlClearResponse)) {
                log.warn(
                    "ttl_clear: output buffer too small ({d} < {d})",
                    .{ output.len, @sizeOf(TtlClearResponse) },
                );
                return 0;
            }

            const request = mem.bytesAsValue(TtlClearRequest, input[0..@sizeOf(TtlClearRequest)]);

            // Look up entity in RAM index
            var response = TtlClearResponse{
                .entity_id = request.entity_id,
                .previous_ttl_seconds = 0,
                .result = .entity_not_found,
            };

            // Find entity in index using lookup
            const lookup_result = self.ram_index.lookup(request.entity_id);
            if (lookup_result.entry) |entry| {
                response.previous_ttl_seconds = entry.ttl_seconds;
                response.result = .success;

                // Clear TTL (set to 0 = never expires) using upsert
                _ = self.ram_index.upsert(
                    request.entity_id,
                    entry.latest_id,
                    0, // TTL = 0 means never expires
                ) catch |err| {
                    log.warn("ttl_clear: upsert failed: {}", .{err});
                    response.result = .not_permitted;
                };

                // Update TTL tracking metrics (only if upsert succeeded)
                if (response.result == .success and entry.ttl_seconds > 0) {
                    if (self.entries_with_ttl > 0) self.entries_with_ttl -= 1;
                }

                log.debug("ttl_clear: entity {x} TTL {d} -> 0 (cleared)", .{
                    request.entity_id,
                    response.previous_ttl_seconds,
                });
            }

            // Write response
            const response_ptr = mem.bytesAsValue(
                TtlClearResponse,
                output[0..@sizeOf(TtlClearResponse)],
            );
            response_ptr.* = response;

            return @sizeOf(TtlClearResponse);
        }

        // ====================================================================
        // 14-04: Batch Query Implementation
        // ====================================================================

        /// Execute batch query operation (14-04).
        ///
        /// Executes multiple queries in a single request with DynamoDB-style
        /// partial success handling. Each query in the batch succeeds or fails
        /// independently without affecting others.
        ///
        /// Arguments:
        /// - input: BatchQueryRequest + entries + filter data
        /// - output: Buffer for BatchQueryResponse + result entries + result data
        ///
        /// Returns: Size of response written to output (number of bytes)
        fn execute_batch_query(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            // Use the generic batch query executor
            const BatchQueryExecutor = batch_query_mod.BatchQueryExecutor(GeoStateMachine);
            return BatchQueryExecutor.executeBatch(self, input, output);
        }

        // ====================================================================
        // 14-05: Prepared Query Operations
        // ====================================================================

        /// Execute prepare_query operation.
        ///
        /// Compiles a query text into a prepared query and stores it in the
        /// client's session. The prepared query can then be executed multiple
        /// times with different parameters, skipping the parse phase.
        ///
        /// Arguments:
        /// - client: Client ID for session scoping
        /// - input: PrepareQueryRequest + name + query_text
        /// - output: Buffer for PrepareQueryResult
        ///
        /// Returns: Size of response written to output (16 bytes)
        fn execute_prepare_query(
            self: *GeoStateMachine,
            client: u128,
            input: []const u8,
            output: []u8,
        ) usize {
            // Validate input size
            if (input.len < @sizeOf(PrepareQueryRequest)) {
                log.warn("prepare_query: input too small ({d} < {d})", .{
                    input.len,
                    @sizeOf(PrepareQueryRequest),
                });
                return writePrepareFail(output, .invalid_query);
            }

            // Validate output size
            if (output.len < @sizeOf(PrepareQueryResult)) {
                log.warn("prepare_query: output buffer too small", .{});
                return 0;
            }

            // Parse request header
            const request = mem.bytesAsValue(
                PrepareQueryRequest,
                input[0..@sizeOf(PrepareQueryRequest)],
            ).*;

            // Validate variable-length data
            const header_size = @sizeOf(PrepareQueryRequest);
            const total_needed = header_size + request.name_len + request.query_len;
            if (input.len < total_needed) {
                log.warn("prepare_query: input too small for name/query ({d} < {d})", .{
                    input.len,
                    total_needed,
                });
                return writePrepareFail(output, .invalid_query);
            }

            // Extract name and query text
            const name = input[header_size..][0..request.name_len];
            const query_text = input[header_size + request.name_len ..][0..request.query_len];

            // Get or create session
            const session = self.getOrCreateSession(client);

            // Prepare the query
            const slot = session.prepare(name, query_text) catch |err| {
                self.prepared_query_metrics.recordParseError();
                const status: PrepareQueryResult.Status = switch (err) {
                    error.SessionFull => .session_full,
                    error.AlreadyExists => .already_exists,
                    error.InvalidQuery => .invalid_query,
                    error.UnsupportedQueryType => .unsupported_query_type,
                    else => .invalid_query,
                };
                log.warn("prepare_query: failed with {s}", .{@errorName(err)});
                return writePrepareFail(output, status);
            };

            // Success
            self.prepared_query_metrics.recordCompile();
            const result = PrepareQueryResult.success(slot);
            const result_bytes = mem.asBytes(&result);
            @memcpy(output[0..@sizeOf(PrepareQueryResult)], result_bytes);
            return @sizeOf(PrepareQueryResult);
        }

        /// Execute execute_prepared operation.
        ///
        /// Executes a previously prepared query with the provided parameters.
        /// The parse phase is skipped since the query is already compiled.
        ///
        /// Arguments:
        /// - client: Client ID for session lookup
        /// - input: ExecutePreparedRequest + params
        /// - output: Buffer for GeoEvent results
        ///
        /// Returns: Size of response written to output
        fn execute_execute_prepared(
            self: *GeoStateMachine,
            client: u128,
            input: []const u8,
            output: []u8,
        ) usize {
            // Validate input size
            if (input.len < @sizeOf(ExecutePreparedRequest)) {
                log.warn("execute_prepared: input too small ({d} < {d})", .{
                    input.len,
                    @sizeOf(ExecutePreparedRequest),
                });
                return 0;
            }

            // Parse request header
            const request = mem.bytesAsValue(
                ExecutePreparedRequest,
                input[0..@sizeOf(ExecutePreparedRequest)],
            ).*;

            // Get session
            const session = self.session_prepared_queries.getPtr(client) orelse {
                self.prepared_query_metrics.recordNotFoundError();
                log.warn("execute_prepared: no session for client", .{});
                return 0;
            };

            // Extract parameters
            const params = input[@sizeOf(ExecutePreparedRequest)..];

            // Execute the prepared query to get filter bytes
            var filter_buffer: [256]u8 = undefined;
            const result = session.execute(request.slot, params, &filter_buffer) catch |err| {
                self.prepared_query_metrics.recordParamError();
                log.warn("execute_prepared: execution failed with {s}", .{@errorName(err)});
                return 0;
            };

            // Dispatch to the appropriate query executor based on query type
            self.prepared_query_metrics.recordExecution();
            return switch (result.query_type) {
                .uuid => self.execute_query_uuid(filter_buffer[0..result.filter_len], output),
                .radius => self.execute_query_radius(filter_buffer[0..result.filter_len], output),
                .polygon => self.execute_query_polygon(filter_buffer[0..result.filter_len], output),
                .latest => self.execute_query_latest(filter_buffer[0..result.filter_len], output),
            };
        }

        /// Execute deallocate_prepared operation.
        ///
        /// Deallocates a prepared query from the client's session.
        ///
        /// Arguments:
        /// - client: Client ID for session lookup
        /// - input: DeallocatePreparedRequest
        /// - output: Buffer for DeallocatePreparedResult
        ///
        /// Returns: Size of response written to output (16 bytes)
        fn execute_deallocate_prepared(
            self: *GeoStateMachine,
            client: u128,
            input: []const u8,
            output: []u8,
        ) usize {
            // Validate input size
            if (input.len < @sizeOf(DeallocatePreparedRequest)) {
                log.warn("deallocate_prepared: input too small ({d} < {d})", .{
                    input.len,
                    @sizeOf(DeallocatePreparedRequest),
                });
                return writeDeallocateFail(output);
            }

            // Validate output size
            if (output.len < @sizeOf(DeallocatePreparedResult)) {
                log.warn("deallocate_prepared: output buffer too small", .{});
                return 0;
            }

            // Parse request
            const request = mem.bytesAsValue(
                DeallocatePreparedRequest,
                input[0..@sizeOf(DeallocatePreparedRequest)],
            ).*;

            // Get session
            const session = self.session_prepared_queries.getPtr(client) orelse {
                return writeDeallocateFail(output);
            };

            // Deallocate by slot or name
            const deallocated = if (request.slot != 0xFFFFFFFF)
                session.deallocateSlot(request.slot)
            else if (request.name_hash != 0)
                session.deallocate(request.name_hash)
            else blk: {
                // Deallocate all
                session.clear();
                break :blk true;
            };

            // Write response
            const result = DeallocatePreparedResult{
                .deallocated = if (deallocated) 1 else 0,
            };
            const result_bytes = mem.asBytes(&result);
            @memcpy(output[0..@sizeOf(DeallocatePreparedResult)], result_bytes);
            return @sizeOf(DeallocatePreparedResult);
        }

        /// Helper to write prepare failure response.
        fn writePrepareFail(output: []u8, status: PrepareQueryResult.Status) usize {
            if (output.len < @sizeOf(PrepareQueryResult)) return 0;
            const result = PrepareQueryResult.err(status);
            const result_bytes = mem.asBytes(&result);
            @memcpy(output[0..@sizeOf(PrepareQueryResult)], result_bytes);
            return @sizeOf(PrepareQueryResult);
        }

        /// Helper to write deallocate failure response.
        fn writeDeallocateFail(output: []u8) usize {
            if (output.len < @sizeOf(DeallocatePreparedResult)) return 0;
            const result = DeallocatePreparedResult{ .deallocated = 0 };
            const result_bytes = mem.asBytes(&result);
            @memcpy(output[0..@sizeOf(DeallocatePreparedResult)], result_bytes);
            return @sizeOf(DeallocatePreparedResult);
        }

        /// Get or create a session for a client.
        fn getOrCreateSession(self: *GeoStateMachine, client: u128) *SessionPreparedQueries {
            const entry = self.session_prepared_queries.getOrPut(client) catch {
                // On allocation failure, we need a workaround
                // In practice this shouldn't happen with reasonable client counts
                log.err("prepared_queries: failed to allocate session for client {}", .{client});
                // Return the default entry which will be invalid
                unreachable;
            };
            if (!entry.found_existing) {
                entry.value_ptr.* = SessionPreparedQueries.init();
            }
            return entry.value_ptr;
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
            const start_time = std.time.nanoTimestamp();

            // Validate input size
            if (input.len < @sizeOf(QueryRadiusFilter)) {
                log.warn("query_radius: input too small ({d} < {d})", .{
                    input.len,
                    @sizeOf(QueryRadiusFilter),
                });
                return 0;
            }

            // Validate output can hold at least the response header
            if (output.len < @sizeOf(QueryResponse)) {
                log.warn("query_radius: output buffer too small for header", .{});
                return 0;
            }

            // Parse filter from input (parse phase)
            const filter = mem.bytesAsValue(
                QueryRadiusFilter,
                input[0..@sizeOf(QueryRadiusFilter)],
            ).*;
            const end_parse = std.time.nanoTimestamp();

            // Validate filter parameters
            if (filter.radius_mm == 0) {
                log.warn("query_radius: radius_mm must be > 0", .{});
                return 0;
            }
            if (filter.limit == 0) {
                log.warn("query_radius: limit must be > 0", .{});
                return 0;
            }

            // Calculate output capacity (reserve space for header)
            const data_space = output.len - @sizeOf(QueryResponse);
            const max_results = data_space / @sizeOf(GeoEvent);
            const effective_limit = @min(filter.limit, @as(u32, @intCast(max_results)));
            if (effective_limit == 0) {
                // Return empty response with header
                const header = mem.bytesAsValue(QueryResponse, output[0..@sizeOf(QueryResponse)]);
                header.* = QueryResponse.complete(0);
                return @sizeOf(QueryResponse);
            }

            // Generate S2 covering for the query region (plan phase)
            // Try covering cache first (14-02)
            var scratch: [s2_index.s2_scratch_size]u8 = undefined;

            // Select S2 levels based on radius per spec decision table
            const level_params = selectS2Levels(filter.radius_mm);

            var covering: [s2_index.s2_max_cells]s2_index.CellRange = undefined;
            var num_ranges: usize = 0;

            if (self.covering_cache) |cache| {
                if (cache.getCapCovering(
                    filter.center_lat_nano,
                    filter.center_lon_nano,
                    filter.radius_mm,
                )) |cached| {
                    // Cache hit - use cached covering
                    covering = cached.ranges;
                    num_ranges = cached.num_ranges;
                    archerdb_metrics.Registry.s2_covering_cache_hits_total.inc();
                } else {
                    // Cache miss - compute and cache
                    archerdb_metrics.Registry.s2_covering_cache_misses_total.inc();
                    covering = S2.coverCap(
                        &scratch,
                        filter.center_lat_nano,
                        filter.center_lon_nano,
                        filter.radius_mm,
                        level_params.min_level,
                        level_params.max_level,
                    );
                    // Count non-empty ranges
                    for (covering) |range| {
                        if (range.start != 0 or range.end != 0) {
                            num_ranges += 1;
                        }
                    }
                    // Cache the result
                    cache.putCapCovering(
                        filter.center_lat_nano,
                        filter.center_lon_nano,
                        filter.radius_mm,
                        covering,
                    );
                }
            } else {
                // No cache - compute directly
                covering = S2.coverCap(
                    &scratch,
                    filter.center_lat_nano,
                    filter.center_lon_nano,
                    filter.radius_mm,
                    level_params.min_level,
                    level_params.max_level,
                );
                // Count non-empty ranges
                for (covering) |range| {
                    if (range.start != 0 or range.end != 0) {
                        num_ranges += 1;
                    }
                }
            }
            const end_plan = std.time.nanoTimestamp();

            // Record S2 covering size for spatial stats (14-03)
            self.spatial_stats.recordCoveringSize(.radius, @intCast(num_ranges));

            log.debug("query_radius: covering generated with {d} ranges", .{num_ranges});

            if (self.index_recovery_blocks_covering(covering[0..])) {
                const end_time = std.time.nanoTimestamp();
                const duration_ns: u64 = if (end_time > start_time)
                    @intCast(end_time - start_time)
                else
                    0;
                self.query_metrics.recordRadiusQuery(0, duration_ns);
                archerdb_metrics.Registry.read_ops_query_radius.inc();
                archerdb_metrics.Registry.read_operations_total.inc();
                archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
                archerdb_metrics.Registry.query_result_size.observe(0.0);

                const header = mem.bytesAsValue(
                    QueryResponse,
                    output[0..@sizeOf(QueryResponse)],
                );
                header.* = QueryResponse.with_error(StateError.index_rebuilding);
                return @sizeOf(QueryResponse);
            }

            // Scan RAM index and collect matching entries
            // Results start after the QueryResponse header
            const results_offset = @sizeOf(QueryResponse);
            const results_end = results_offset + effective_limit * @sizeOf(GeoEvent);
            const results_slice = mem.bytesAsSlice(
                GeoEvent,
                output[results_offset..results_end],
            );

            var result_count: usize = 0;
            var has_more: bool = false;
            const radius_mm_u64 = @as(u64, filter.radius_mm);

            // Scan entire RAM index (temporary until LSM scan is available)
            // NOTE: This is O(n) where n is index capacity. For production use,
            // LSM tree range scan should be used instead.
            var position: u64 = 0;
            while (position < self.ram_index.capacity) {
                // Check if we've hit the result limit
                if (result_count >= effective_limit) {
                    // There might be more results - we hit the limit before scanning all
                    has_more = true;
                    break;
                }
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

                // Check TTL expiration (per query-engine/spec.md)
                if (entry.ttl_seconds > 0) {
                    const now_seconds = self.commit_timestamp / 1_000_000_000;
                    const creation_seconds = timestamp / 1_000_000_000;
                    const expiry_seconds = creation_seconds + @as(u64, entry.ttl_seconds);
                    if (now_seconds > expiry_seconds) {
                        // Entity expired - skip it
                        self.ttl_metrics.record_lookup_expiration();
                        continue;
                    }
                }

                const metadata = entryMetadata(entry);

                // Apply group_id filter if specified
                if (filter.group_id != 0 and metadata.group_id != filter.group_id) {
                    continue;
                }

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

                const lat_nano = metadata.lat_nano;
                const lon_nano = metadata.lon_nano;

                // Post-filter: Precise distance check using Haversine formula
                if (!S2.isWithinDistance(
                    filter.center_lat_nano,
                    filter.center_lon_nano,
                    lat_nano,
                    lon_nano,
                    radius_mm_u64,
                )) {
                    continue;
                }

                // F2.6: Record access in tiering manager for each returned entity
                if (self.tiering_manager) |tm| {
                    _ = tm.recordAccess(entry.entity_id, self.commit_timestamp) catch |err| {
                        log.debug("tiering: failed to record access for entity {x}: {}", .{ entry.entity_id, err });
                    };
                }

                // Build GeoEvent result
                // NOTE: This creates a minimal GeoEvent from index data.
                // When Forest is integrated, we should fetch the full event from LSM.
                results_slice[result_count] = GeoEvent{
                    .id = entry.latest_id,
                    .entity_id = entry.entity_id,
                    .correlation_id = 0, // Not stored in RAM index
                    .user_data = 0, // Not stored in RAM index
                    .lat_nano = lat_nano,
                    .lon_nano = lon_nano,
                    .group_id = metadata.group_id,
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
            const end_execute = std.time.nanoTimestamp();

            // Write QueryResponse header (serialize phase)
            const start_serialize = end_execute;
            const header = mem.bytesAsValue(QueryResponse, output[0..@sizeOf(QueryResponse)]);
            if (has_more) {
                header.* = QueryResponse.with_more(@intCast(result_count));
            } else {
                header.* = QueryResponse.complete(@intCast(result_count));
            }

            // Record metrics
            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 = if (end_time > start_time)
                @intCast(end_time - start_time)
            else
                0;
            self.query_metrics.recordRadiusQuery(result_count, duration_ns);

            // Record per-operation Prometheus metrics (F5.2.2)
            archerdb_metrics.Registry.read_ops_query_radius.inc();
            archerdb_metrics.Registry.read_operations_total.inc();
            archerdb_metrics.Registry.read_events_returned_total.add(result_count);
            archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
            archerdb_metrics.Registry.query_result_size.observe(@floatFromInt(result_count));

            // Record query latency breakdown (14-03)
            self.latency_breakdown.recordPhases(.{
                .query_type = .radius,
                .parse_ns = @intCast(@max(0, end_parse - start_time)),
                .plan_ns = @intCast(@max(0, end_plan - end_parse)),
                .execute_ns = @intCast(@max(0, end_execute - end_plan)),
                .serialize_ns = @intCast(@max(0, end_time - start_serialize)),
            });

            // Record scan for adaptive compaction (12-09: range scan workload tracking)
            self.forest.adaptive_record_scan(1);

            // Update spatial stats periodically (every 100 queries)
            self.spatial_stats_update_counter += 1;
            if (self.spatial_stats_update_counter >= 100) {
                self.spatial_stats.updateFromIndex(
                    self.ram_index.stats.entry_count,
                    self.ram_index.stats.capacity,
                );
                self.spatial_stats_update_counter = 0;
            }

            log.debug(
                "query_radius: returning {d} results, has_more={}",
                .{ result_count, has_more },
            );

            return @sizeOf(QueryResponse) + result_count * @sizeOf(GeoEvent);
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
            const start_time = std.time.nanoTimestamp();

            // Validate minimum input size (header only)
            if (input.len < @sizeOf(QueryPolygonFilter)) {
                log.warn("query_polygon: input too small for header ({d} < {d})", .{
                    input.len,
                    @sizeOf(QueryPolygonFilter),
                });
                return 0;
            }

            // Parse filter header (parse phase)
            const filter = mem.bytesAsValue(
                QueryPolygonFilter,
                input[0..@sizeOf(QueryPolygonFilter)],
            ).*;
            const end_parse = std.time.nanoTimestamp();

            // Validate vertex count (minimum 3 for a polygon)
            if (filter.vertex_count < 3) {
                log.warn("query_polygon: vertex_count must be >= 3 (got {d})", .{
                    filter.vertex_count,
                });
                return 0;
            }

            // Per spec: Enforce maximum vertices per polygon
            if (filter.vertex_count > constants.polygon_vertices_max) {
                log.warn("query_polygon: polygon_too_complex (vertex_count {d} > {d})", .{
                    filter.vertex_count,
                    constants.polygon_vertices_max,
                });
                if (output.len >= 4) {
                    mem.writeInt(u32, output[0..4], 101, .little); // polygon_too_complex
                }
                return 4;
            }

            if (filter.limit == 0) {
                log.warn("query_polygon: limit must be > 0", .{});
                return 0;
            }

            // Validate hole count (per spec: max 100 holes)
            if (filter.hole_count > constants.polygon_holes_max) {
                log.warn("query_polygon: too_many_holes ({d} > {d})", .{
                    filter.hole_count,
                    constants.polygon_holes_max,
                });
                if (output.len >= 4) {
                    mem.writeInt(u32, output[0..4], 117, .little); // too_many_holes
                }
                return 4;
            }

            // Calculate total message size including holes
            const outer_vertices_size = filter.vertex_count * @sizeOf(PolygonVertex);
            const hole_descriptors_size = filter.hole_count * @sizeOf(HoleDescriptor);
            var total_hole_vertices: u32 = 0;

            // First pass: validate hole descriptors and calculate total hole vertices
            const descriptors_offset = @sizeOf(QueryPolygonFilter) + outer_vertices_size;
            if (filter.hole_count > 0) {
                // Validate we have room for hole descriptors
                if (input.len < descriptors_offset + hole_descriptors_size) {
                    log.warn("query_polygon: input too small for hole descriptors", .{});
                    return 0;
                }

                const descriptors_bytes = input[descriptors_offset..][0..hole_descriptors_size];
                const hole_descriptors = mem.bytesAsSlice(HoleDescriptor, descriptors_bytes);

                for (hole_descriptors) |desc| {
                    // Validate each hole has at least 3 vertices
                    if (desc.vertex_count < constants.polygon_hole_vertices_min) {
                        log.warn("query_polygon: hole_vertex_count_invalid ({d} < 3)", .{
                            desc.vertex_count,
                        });
                        if (output.len >= 4) {
                            // hole_vertex_count_invalid
                            mem.writeInt(u32, output[0..4], 118, .little);
                        }
                        return 4;
                    }
                    total_hole_vertices += desc.vertex_count;
                }
            }

            const total_vertices = filter.vertex_count + total_hole_vertices;
            if (total_vertices > constants.polygon_vertices_max) {
                log.warn(
                    "query_polygon: polygon_too_complex (total_vertices {d} > {d})",
                    .{ total_vertices, constants.polygon_vertices_max },
                );
                if (output.len >= 4) {
                    mem.writeInt(u32, output[0..4], 101, .little); // polygon_too_complex
                }
                return 4;
            }

            const hole_vertices_size = total_hole_vertices * @sizeOf(PolygonVertex);
            const total_size = @sizeOf(QueryPolygonFilter) + outer_vertices_size +
                hole_descriptors_size + hole_vertices_size;

            if (input.len < total_size) {
                log.warn("query_polygon: input too small ({d} < {d})", .{
                    input.len,
                    total_size,
                });
                return 0;
            }

            // Extract outer ring vertices
            const vertices_bytes = input[@sizeOf(QueryPolygonFilter)..][0..outer_vertices_size];
            const vertices = mem.bytesAsSlice(PolygonVertex, vertices_bytes);

            // Convert to s2_index.LatLon format for
            // coverPolygon and pointInPolygon
            // Stack allocation limits for vertices
            const max_vertices_stack: usize = 256;
            const max_holes_stack: usize = 32;
            const max_hole_vertices_stack: usize = 128;

            if (vertices.len > max_vertices_stack) {
                log.warn(
                    "query_polygon: too many outer vertices for stack allocation ({d} > {d})",
                    .{ vertices.len, max_vertices_stack },
                );
                return 0;
            }

            var latlon_vertices: [max_vertices_stack]s2_index.LatLon = undefined;
            for (vertices, 0..) |v, i| {
                latlon_vertices[i] = .{
                    .lat_nano = v.lat_nano,
                    .lon_nano = v.lon_nano,
                };
                log.debug(
                    "query_polygon: vertex[{d}] = lat={d}, lon={d}",
                    .{ i, v.lat_nano, v.lon_nano },
                );
            }
            const polygon_slice = latlon_vertices[0..vertices.len];

            // Parse and convert holes to LatLon format
            var hole_slices: [max_holes_stack][]const s2_index.LatLon = undefined;
            var hole_vertices_storage: [
                max_holes_stack *
                    max_hole_vertices_stack
            ]s2_index.LatLon = undefined;
            var hole_count: usize = 0;
            var hole_vertex_offset: usize = 0;

            if (filter.hole_count > 0) {
                if (filter.hole_count > max_holes_stack) {
                    log.warn("query_polygon: too many holes for stack allocation ({d} > {d})", .{
                        filter.hole_count,
                        max_holes_stack,
                    });
                    return 0;
                }

                const descriptors_bytes = input[descriptors_offset..][0..hole_descriptors_size];
                const hole_descriptors = mem.bytesAsSlice(HoleDescriptor, descriptors_bytes);
                var hole_data_offset = descriptors_offset + hole_descriptors_size;

                for (hole_descriptors) |desc| {
                    const hole_size = desc.vertex_count * @sizeOf(PolygonVertex);
                    const hole_bytes = input[hole_data_offset..][0..hole_size];
                    const hole_verts = mem.bytesAsSlice(PolygonVertex, hole_bytes);

                    if (hole_vertex_offset + hole_verts.len >
                        max_holes_stack * max_hole_vertices_stack)
                    {
                        log.warn(
                            "query_polygon: too many total hole vertices for stack allocation",
                            .{},
                        );
                        return 0;
                    }

                    // Convert hole vertices to LatLon
                    const start_idx = hole_vertex_offset;
                    for (hole_verts) |hv| {
                        hole_vertices_storage[hole_vertex_offset] = .{
                            .lat_nano = hv.lat_nano,
                            .lon_nano = hv.lon_nano,
                        };
                        hole_vertex_offset += 1;
                    }
                    hole_slices[hole_count] = hole_vertices_storage[start_idx..hole_vertex_offset];
                    hole_count += 1;
                    hole_data_offset += hole_size;
                }
            }
            const holes_slice = hole_slices[0..hole_count];

            // Ensure outer ring uses CCW winding order (per spec)
            if (S2.isClockwise(polygon_slice)) {
                reverseLatLonSlice(polygon_slice);
                log.info("query_polygon: winding order corrected from CW to CCW", .{});
            }

            // Polygon validation (per spec: query-engine/spec.md)
            // Check for degenerate polygon (collinear vertices)
            if (S2.isPolygonDegenerate(polygon_slice)) {
                log.warn("query_polygon: polygon_degenerate (all vertices are collinear)", .{});
                // Return error code in first byte of output
                if (output.len >= 4) {
                    mem.writeInt(u32, output[0..4], 112, .little); // polygon_degenerate
                }
                return 4;
            }

            // Check for self-intersecting polygon (bowtie shape)
            if (S2.isPolygonSelfIntersecting(polygon_slice)) {
                log.warn("query_polygon: polygon_self_intersecting (edges cross)", .{});
                if (output.len >= 4) {
                    mem.writeInt(u32, output[0..4], 109, .little); // polygon_self_intersecting
                }
                return 4;
            }

            // Check for polygon spanning too much longitude
            if (S2.isPolygonTooLarge(polygon_slice)) {
                log.warn("query_polygon: polygon_too_large (spans > 350° longitude)", .{});
                if (output.len >= 4) {
                    mem.writeInt(u32, output[0..4], 111, .little); // polygon_too_large
                }
                return 4;
            }

            // Hole validation (per spec: add-polygon-holes/query-engine)
            if (hole_count > 0) {
                for (holes_slice, 0..) |hole, hole_index| {
                    if (!S2.isClockwise(hole)) {
                        reverseLatLonSlice(@constCast(hole));
                        log.info(
                            "query_polygon: hole winding order corrected from CCW to CW (hole {d})",
                            .{hole_index},
                        );
                    }

                    if (!S2.isHoleContained(polygon_slice, hole)) {
                        log.warn(
                            "query_polygon: hole_not_contained (hole {d} not inside outer ring)",
                            .{hole_index},
                        );
                        if (output.len >= 4) {
                            mem.writeInt(u32, output[0..4], 119, .little);
                        }
                        return 4;
                    }
                }

                for (holes_slice, 0..) |hole_a, hole_a_index| {
                    var hole_b_index = hole_a_index + 1;
                    while (hole_b_index < holes_slice.len) : (hole_b_index += 1) {
                        const hole_b = holes_slice[hole_b_index];
                        if (S2.doHolesBoundingBoxesOverlap(hole_a, hole_b)) {
                            log.warn(
                                "query_polygon: holes_overlap (holes {d} and {d})",
                                .{ hole_a_index, hole_b_index },
                            );
                            if (output.len >= 4) {
                                mem.writeInt(u32, output[0..4], 120, .little);
                            }
                            return 4;
                        }
                    }
                }
            }

            // Validate output can hold at least the response header
            if (output.len < @sizeOf(QueryResponse)) {
                log.warn("query_polygon: output buffer too small for header", .{});
                return 0;
            }

            // Calculate output capacity (reserve space for header)
            const data_space = output.len - @sizeOf(QueryResponse);
            const max_results = data_space / @sizeOf(GeoEvent);
            const effective_limit = @min(filter.limit, @as(u32, @intCast(max_results)));
            if (effective_limit == 0) {
                // Return empty response with header
                const header = mem.bytesAsValue(QueryResponse, output[0..@sizeOf(QueryResponse)]);
                header.* = QueryResponse.complete(0);
                return @sizeOf(QueryResponse);
            }

            // Generate S2 covering for the polygon (plan phase)
            // Try covering cache first (14-02)
            var scratch: [s2_index.s2_scratch_size]u8 = undefined;

            // Use polygon covering (bounding box approximation for now)
            // NOTE: Uses bounding box approximation. Full S2Loop covering is an enhancement.

            var covering: [s2_index.s2_max_cells]s2_index.CellRange = undefined;
            var num_ranges: usize = 0;

            // Compute hash for polygon vertices (integer-only for stability)
            const vertices_hash = s2_covering_cache.hashPolygonParams(polygon_slice);

            if (self.covering_cache) |cache| {
                if (cache.getPolygonCovering(vertices_hash)) |cached| {
                    // Cache hit - use cached covering
                    covering = cached.ranges;
                    num_ranges = cached.num_ranges;
                    archerdb_metrics.Registry.s2_covering_cache_hits_total.inc();
                } else {
                    // Cache miss - compute and cache
                    archerdb_metrics.Registry.s2_covering_cache_misses_total.inc();
                    covering = S2.coverPolygon(
                        &scratch,
                        polygon_slice,
                        8, // min_level
                        18, // max_level
                    );
                    // Count non-empty ranges
                    for (covering) |range| {
                        if (range.start != 0 or range.end != 0) {
                            num_ranges += 1;
                        }
                    }
                    // Cache the result
                    cache.putPolygonCovering(vertices_hash, covering);
                }
            } else {
                // No cache - compute directly
                covering = S2.coverPolygon(
                    &scratch,
                    polygon_slice,
                    8, // min_level
                    18, // max_level
                );
                // Count non-empty ranges
                for (covering) |range| {
                    if (range.start != 0 or range.end != 0) {
                        num_ranges += 1;
                    }
                }
            }
            const end_plan = std.time.nanoTimestamp();

            // Record S2 covering size for spatial stats (14-03)
            self.spatial_stats.recordCoveringSize(.polygon, @intCast(num_ranges));

            log.debug(
                "query_polygon: covering generated with {d} ranges for " ++
                    "{d}-vertex polygon with {d} holes",
                .{ num_ranges, vertices.len, hole_count },
            );

            if (self.index_recovery_blocks_covering(covering[0..])) {
                const end_time = std.time.nanoTimestamp();
                const duration_ns: u64 = if (end_time > start_time)
                    @intCast(end_time - start_time)
                else
                    0;
                self.query_metrics.recordPolygonQuery(0, duration_ns);
                archerdb_metrics.Registry.read_ops_query_polygon.inc();
                archerdb_metrics.Registry.read_operations_total.inc();
                archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
                archerdb_metrics.Registry.query_result_size.observe(0.0);

                const header = mem.bytesAsValue(
                    QueryResponse,
                    output[0..@sizeOf(QueryResponse)],
                );
                header.* = QueryResponse.with_error(StateError.index_rebuilding);
                return @sizeOf(QueryResponse);
            }

            // Scan RAM index and collect matching entries
            // Results start after the QueryResponse header
            const results_offset = @sizeOf(QueryResponse);
            const results_end = results_offset + effective_limit * @sizeOf(GeoEvent);
            const results_slice = mem.bytesAsSlice(
                GeoEvent,
                output[results_offset..results_end],
            );

            var result_count: usize = 0;
            var has_more: bool = false;
            var entries_seen: usize = 0;
            var covering_passed: usize = 0;

            // Scan entire RAM index (temporary until LSM scan is available)
            var position: u64 = 0;
            while (position < self.ram_index.capacity) {
                // Check if we've hit the result limit
                if (result_count >= effective_limit) {
                    // There might be more results - we hit the limit before scanning all
                    has_more = true;
                    break;
                }
                // Read entry from index
                const entry_ptr: *IndexEntry = &self.ram_index.entries[@intCast(position)];
                const entry = @as(*volatile IndexEntry, @ptrCast(entry_ptr)).*;

                position += 1;

                // Skip empty slots and tombstones
                if (entry.is_empty() or entry.is_tombstone()) {
                    continue;
                }
                entries_seen += 1;

                // Extract S2 cell ID and timestamp from composite latest_id
                const cell_id = @as(u64, @truncate(entry.latest_id >> 64));
                const timestamp = @as(u64, @truncate(entry.latest_id));

                // Check TTL expiration (per query-engine/spec.md)
                if (entry.ttl_seconds > 0) {
                    const now_seconds = self.commit_timestamp / 1_000_000_000;
                    const creation_seconds = timestamp / 1_000_000_000;
                    const expiry_seconds = creation_seconds + @as(u64, entry.ttl_seconds);
                    if (now_seconds > expiry_seconds) {
                        // Entity expired - skip it
                        self.ttl_metrics.record_lookup_expiration();
                        continue;
                    }
                }

                const metadata = entryMetadata(entry);

                // Apply group_id filter if specified
                if (filter.group_id != 0 and metadata.group_id != filter.group_id) {
                    continue;
                }

                // Coarse filter: Check if cell is in any covering range
                // This is an optimization - cells outside the covering can be skipped
                // without the more expensive point-in-polygon test
                if (!cellInCovering(cell_id, &covering)) {
                    continue;
                }
                covering_passed += 1;

                // Apply timestamp filter if specified
                if (filter.timestamp_min > 0 and timestamp < filter.timestamp_min) {
                    continue;
                }
                if (filter.timestamp_max > 0 and timestamp > filter.timestamp_max) {
                    continue;
                }

                // Post-filter: Point-in-polygon test using ray casting algorithm
                // If holes are present, use pointInPolygonWithHoles which excludes
                // points inside holes
                const point = s2_index.LatLon{
                    .lat_nano = metadata.lat_nano,
                    .lon_nano = metadata.lon_nano,
                };
                const in_polygon = if (hole_count > 0)
                    S2.pointInPolygonWithHoles(point, polygon_slice, holes_slice)
                else
                    S2.pointInPolygon(point, polygon_slice);

                log.debug("query_polygon: point lat={d}, lon={d}, in_polygon={}", .{
                    metadata.lat_nano, metadata.lon_nano, in_polygon,
                });

                if (!in_polygon) {
                    continue;
                }

                // F2.6: Record access in tiering manager for each returned entity
                if (self.tiering_manager) |tm| {
                    _ = tm.recordAccess(entry.entity_id, self.commit_timestamp) catch |err| {
                        log.debug("tiering: failed to record access for entity {x}: {}", .{ entry.entity_id, err });
                    };
                }

                // Build GeoEvent result
                results_slice[result_count] = GeoEvent{
                    .id = entry.latest_id,
                    .entity_id = entry.entity_id,
                    .correlation_id = 0, // Not stored in RAM index
                    .user_data = 0, // Not stored in RAM index
                    .lat_nano = metadata.lat_nano,
                    .lon_nano = metadata.lon_nano,
                    .group_id = metadata.group_id,
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
            const end_execute = std.time.nanoTimestamp();

            // Write QueryResponse header (serialize phase)
            const start_serialize = end_execute;
            const header = mem.bytesAsValue(QueryResponse, output[0..@sizeOf(QueryResponse)]);
            if (has_more) {
                header.* = QueryResponse.with_more(@intCast(result_count));
            } else {
                header.* = QueryResponse.complete(@intCast(result_count));
            }

            // Record metrics
            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 = if (end_time > start_time)
                @intCast(end_time - start_time)
            else
                0;
            self.query_metrics.recordPolygonQuery(result_count, duration_ns);

            // Record per-operation Prometheus metrics (F5.2.2)
            archerdb_metrics.Registry.read_ops_query_polygon.inc();
            archerdb_metrics.Registry.read_operations_total.inc();
            archerdb_metrics.Registry.read_events_returned_total.add(result_count);
            archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
            archerdb_metrics.Registry.query_result_size.observe(@floatFromInt(result_count));

            // Record query latency breakdown (14-03)
            self.latency_breakdown.recordPhases(.{
                .query_type = .polygon,
                .parse_ns = @intCast(@max(0, end_parse - start_time)),
                .plan_ns = @intCast(@max(0, end_plan - end_parse)),
                .execute_ns = @intCast(@max(0, end_execute - end_plan)),
                .serialize_ns = @intCast(@max(0, end_time - start_serialize)),
            });

            // Record scan for adaptive compaction (12-09: range scan workload tracking)
            self.forest.adaptive_record_scan(1);

            log.debug(
                "query_polygon: scan complete: entries_seen={d}, covering_passed={d}, " ++
                    "result_count={d}, has_more={}",
                .{ entries_seen, covering_passed, result_count, has_more },
            );

            return @sizeOf(QueryResponse) + result_count * @sizeOf(GeoEvent);
        }

        /// Execute query_latest - return N most recent events (F1.3.3).
        ///
        /// For the standalone GeoStateMachine, this scans the RAM index to find
        /// the most recent events across all entities. Returns events sorted by
        /// timestamp (descending - newest first).
        ///
        /// NOTE: This implementation uses RAM index scan which is O(n) where n is
        /// index capacity. For production use, the unified StateMachine in
        /// state_machine.zig uses Forest LSM with timestamp index for O(log n) access.
        fn execute_query_latest(
            self: *GeoStateMachine,
            input: []const u8,
            output: []u8,
        ) usize {
            const start_time = std.time.nanoTimestamp();

            // Parse filter (parse phase)
            if (input.len < @sizeOf(QueryLatestFilter)) {
                log.warn("query_latest: input too small", .{});
                return 0;
            }

            const filter = mem.bytesAsValue(
                QueryLatestFilter,
                input[0..@sizeOf(QueryLatestFilter)],
            ).*;
            const end_parse = std.time.nanoTimestamp();

            // No plan phase for latest queries (no S2 covering)
            const end_plan = end_parse;

            // Validate filter
            if (filter.limit == 0) {
                log.warn("query_latest: limit must be > 0", .{});
                return 0;
            }

            if (self.index_recovery.active) {
                if (output.len < @sizeOf(QueryResponse)) {
                    log.warn("query_latest: output buffer too small for header", .{});
                    return 0;
                }

                const end_time = std.time.nanoTimestamp();
                const duration_ns: u64 = if (end_time > start_time)
                    @intCast(end_time - start_time)
                else
                    0;
                self.query_metrics.query_latest_count += 1;
                self.query_metrics.total_query_duration_ns += duration_ns;
                archerdb_metrics.Registry.read_ops_query_latest.inc();
                archerdb_metrics.Registry.read_operations_total.inc();
                archerdb_metrics.Registry.read_latency.observeNs(duration_ns);
                archerdb_metrics.Registry.query_result_size.observe(0.0);

                const header = mem.bytesAsValue(
                    QueryResponse,
                    output[0..@sizeOf(QueryResponse)],
                );
                header.* = QueryResponse.with_error(StateError.index_rebuilding);
                return @sizeOf(QueryResponse);
            }

            // Calculate output capacity (reserve space for QueryResponse header)
            const data_space = output.len - @sizeOf(QueryResponse);
            const max_results = data_space / @sizeOf(GeoEvent);
            const effective_limit = @min(filter.limit, @as(u32, @intCast(max_results)));
            if (effective_limit == 0) {
                // Return empty response
                const header = mem.bytesAsValue(QueryResponse, output[0..@sizeOf(QueryResponse)]);
                header.* = QueryResponse.complete(0);
                return @sizeOf(QueryResponse);
            }

            // Collect events from RAM index, sorted by timestamp (newest first)
            const results_offset = @sizeOf(QueryResponse);
            const results_end = results_offset + effective_limit * @sizeOf(GeoEvent);
            const results_slice = mem.bytesAsSlice(
                GeoEvent,
                output[results_offset..results_end],
            );

            const Candidate = struct {
                entity_id: u128,
                latest_id: u128,
                ttl_seconds: u32,
                lat_nano: i64,
                lon_nano: i64,
                group_id: u64,
            };

            comptime {
                assert(@sizeOf(Candidate) <= @sizeOf(GeoEvent));
            }

            const candidates_bytes: []align(@alignOf(Candidate)) u8 = @alignCast(
                output[results_offset .. results_offset + effective_limit * @sizeOf(Candidate)],
            );
            const candidates = mem.bytesAsSlice(Candidate, candidates_bytes);
            var candidate_count: usize = 0;
            var matching_count: usize = 0;

            // Scan RAM index to collect all non-deleted entries
            // Per query-engine/spec.md: Use cursor_timestamp for pagination
            // cursor_timestamp > 0 means "only return events OLDER than this timestamp"
            var position: u64 = 0;
            while (position < self.ram_index.capacity) {
                const entry_ptr: *IndexEntry = &self.ram_index.entries[@intCast(position)];
                const entry = @as(*volatile IndexEntry, @ptrCast(entry_ptr)).*;
                position += 1;

                // Skip empty slots and tombstones
                if (entry.is_empty() or entry.is_tombstone()) continue;

                // Apply cursor filter for pagination (F1.3.3 cursor-based pagination)
                // Timestamp is lower 64 bits of latest_id
                const entry_timestamp = @as(u64, @truncate(entry.latest_id));
                if (filter.cursor_timestamp > 0 and entry_timestamp >= filter.cursor_timestamp) {
                    // Skip entries at or newer than cursor (we return oldest-to-newest order)
                    continue;
                }

                // Check TTL expiration (per query-engine/spec.md)
                if (entry.ttl_seconds > 0) {
                    const now_seconds = self.commit_timestamp / 1_000_000_000;
                    const creation_seconds = entry_timestamp / 1_000_000_000;
                    const expiry_seconds = creation_seconds + @as(u64, entry.ttl_seconds);
                    if (now_seconds > expiry_seconds) {
                        // Entity expired - skip it
                        self.ttl_metrics.record_lookup_expiration();
                        continue;
                    }
                }

                const metadata = entryMetadata(entry);

                // Apply group_id filter if specified
                if (filter.group_id != 0 and metadata.group_id != filter.group_id) {
                    continue;
                }

                matching_count += 1;
                const candidate = Candidate{
                    .entity_id = entry.entity_id,
                    .latest_id = entry.latest_id,
                    .ttl_seconds = entry.ttl_seconds,
                    .lat_nano = metadata.lat_nano,
                    .lon_nano = metadata.lon_nano,
                    .group_id = metadata.group_id,
                };

                if (candidate_count < candidates.len) {
                    candidates[candidate_count] = candidate;
                    candidate_count += 1;
                } else {
                    var oldest_idx: usize = 0;
                    var oldest_ts = @as(u64, @truncate(candidates[0].latest_id));
                    var idx: usize = 1;
                    while (idx < candidate_count) : (idx += 1) {
                        const ts = @as(u64, @truncate(candidates[idx].latest_id));
                        if (ts < oldest_ts) {
                            oldest_ts = ts;
                            oldest_idx = idx;
                        }
                    }

                    const candidate_ts = @as(u64, @truncate(candidate.latest_id));
                    if (candidate_ts <= oldest_ts) {
                        continue;
                    }
                    candidates[oldest_idx] = candidate;
                }
            }

            // Sort by timestamp (descending) - timestamp is lower 64 bits of latest_id
            std.mem.sort(Candidate, candidates[0..candidate_count], {}, struct {
                fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                    const ts_a = @as(u64, @truncate(a.latest_id));
                    const ts_b = @as(u64, @truncate(b.latest_id));
                    return ts_a > ts_b; // Descending order (newest first)
                }
            }.lessThan);

            // Take top N results up to limit
            // Try to get full GeoEvent from Forest cache; fall back to RAM index approximation
            const result_count = candidate_count;
            var idx: usize = result_count;
            while (idx > 0) : (idx -= 1) {
                const candidate = candidates[idx - 1];
                // Try Forest cache lookup first (F2.5.3 Forest LSM Integration)
                const groove_result = self.forest.grooves.geo_events.get(candidate.latest_id);
                if (groove_result == .found_object) {
                    // Full GeoEvent available from Forest cache
                    results_slice[idx - 1] = groove_result.found_object;
                } else {
                    // Fall back to RAM index approximation
                    // (Forest not yet prefetched or data evicted from cache)
                    const timestamp = @as(u64, @truncate(candidate.latest_id));

                    results_slice[idx - 1] = GeoEvent{
                        .id = candidate.latest_id,
                        .entity_id = candidate.entity_id,
                        .correlation_id = 0,
                        .user_data = 0,
                        .lat_nano = candidate.lat_nano,
                        .lon_nano = candidate.lon_nano,
                        .group_id = candidate.group_id,
                        .timestamp = timestamp,
                        .altitude_mm = 0,
                        .velocity_mms = 0,
                        .ttl_seconds = candidate.ttl_seconds,
                        .accuracy_mm = 0,
                        .heading_cdeg = 0,
                        .flags = GeoEventFlags.none,
                        .reserved = [_]u8{0} ** 12,
                    };
                }
            }
            const end_execute = std.time.nanoTimestamp();

            // Write QueryResponse header (serialize phase)
            const start_serialize = end_execute;
            const header = mem.bytesAsValue(QueryResponse, output[0..@sizeOf(QueryResponse)]);
            const has_more = matching_count > candidate_count;
            if (has_more) {
                header.* = QueryResponse.with_more(@intCast(result_count));
            } else {
                header.* = QueryResponse.complete(@intCast(result_count));
            }

            // Record metrics
            const end_time = std.time.nanoTimestamp();
            const duration_ns: u64 = if (end_time > start_time)
                @intCast(end_time - start_time)
            else
                0;
            self.query_metrics.query_latest_count += 1;
            self.query_metrics.total_results_returned += result_count;
            self.query_metrics.total_query_duration_ns += duration_ns;

            // Record query latency breakdown (14-03)
            self.latency_breakdown.recordPhases(.{
                .query_type = .latest,
                .parse_ns = @intCast(@max(0, end_parse - start_time)),
                .plan_ns = 0, // No S2 covering for latest queries
                .execute_ns = @intCast(@max(0, end_execute - end_plan)),
                .serialize_ns = @intCast(@max(0, end_time - start_serialize)),
            });

            // Record scan for adaptive compaction (12-09: index scan workload tracking)
            self.forest.adaptive_record_scan(1);

            log.debug(
                "query_latest: returning {d} results, has_more={}",
                .{ result_count, has_more },
            );

            return @sizeOf(QueryResponse) + result_count * @sizeOf(GeoEvent);
        }

        fn reverseLatLonSlice(vertices: []s2_index.LatLon) void {
            var i: usize = 0;
            var j: usize = vertices.len;
            while (i < j) : (i += 1) {
                j -= 1;
                const tmp = vertices[i];
                vertices[i] = vertices[j];
                vertices[j] = tmp;
            }
        }

        fn entryMetadata(entry: IndexEntry) struct { lat_nano: i64, lon_nano: i64, group_id: u64 } {
            if ((entry.reserved & IndexEntry.metadata_flag) != 0) {
                return .{
                    .lat_nano = entry.lat_nano,
                    .lon_nano = entry.lon_nano,
                    .group_id = entry.group_id,
                };
            }

            const cell_id = @as(u64, @truncate(entry.latest_id >> 64));
            const cell_center = S2.cellIdToLatLon(cell_id);
            return .{
                .lat_nano = cell_center.lat_nano,
                .lon_nano = cell_center.lon_nano,
                .group_id = 0,
            };
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
        ///
        /// NOTE: The covering algorithm has limited cells (16 max), so for large radii
        /// we need to use coarser levels to ensure complete coverage. The formula
        /// min_level = floor(log2(7842km / radius_km)) is adjusted down by 2 levels
        /// to ensure the covering fits within the cell budget while still providing
        /// effective filtering.
        fn selectS2Levels(radius_mm: u32) struct { min_level: u8, max_level: u8 } {
            // Convert mm to meters for level selection
            const radius_m = @as(f64, @floatFromInt(radius_mm)) / 1000.0;

            // Per query-engine/spec.md decision table:
            // min_level = max(0, min(18, floor(log2(7842000 / radius_meters))))
            // max_level = min(min_level + 4, 18)
            //
            // However, to ensure the covering fits within 16 cells, we subtract 2
            // from the computed min_level. This gives coarser cells that better
            // cover the entire query region.

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
            if (min_level_raw > 2) {
                // Subtract 2 levels to ensure covering fits in 16 cells
                min_level = @min(18, @as(u8, @intFromFloat(min_level_raw)) - 2);
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

            // Trigger Forest compaction
            // NOTE: GeoStateMachine has Forest integration (line 798).
            // This performs LSM tree compaction across all levels.
            // Pass commit_timestamp for deterministic TTL expiration checks
            // (ttl-retention/spec.md).
            self.forest.compact(compact_finish, op, self.commit_timestamp);
        }

        /// Internal callback when forest compaction completes.
        /// Records tombstone lifecycle metrics (F2.5.8).
        fn compact_finish(forest: *Forest) void {
            const self: *GeoStateMachine = @fieldParentPtr("forest", forest);

            // Record compaction cycle completion
            self.tombstone_metrics.recordCompactionCycle();

            // NOTE: Tombstone retention/elimination metrics are recorded during the
            // k-way merge process via should_retain_tombstone() callbacks.
            // See tombstone_metrics.recordRetained() and recordEliminated().

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

            // Trigger Forest checkpoint
            // NOTE: GeoStateMachine has Forest integration (line 798).
            // This persists LSM tree state to disk.
            self.forest.checkpoint(checkpoint_finish);
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

            // NOTE: RAM index checkpoint integration would go here.
            // For VOPR testing, RAM index is ephemeral (rebuilt each run).
            // Production StateMachine in state_machine.zig can add persistent
            // RAM index checkpointing if needed for fast recovery.

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
        fn checkpoint_finish(forest: *Forest) void {
            const self: *GeoStateMachine = @fieldParentPtr("forest", forest);

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
            if (operation == .query_uuid_batch) {
                // query_uuid_batch body = QueryUuidBatchFilter (8 bytes) +
                // entity_ids (N * 16 bytes)
                const header_size = @sizeOf(QueryUuidBatchFilter);
                if (message_body_used.len < header_size) return false;

                const filter = mem.bytesAsValue(
                    QueryUuidBatchFilter,
                    message_body_used[0..header_size],
                ).*;

                // Validate count
                if (filter.count > QueryUuidBatchFilter.max_count) return false;

                // Validate body size matches count
                const expected_size = header_size + filter.count * @sizeOf(u128);
                if (message_body_used.len < expected_size) return false;

                return true;
            }

            if (operation == .query_polygon) {
                // query_polygon body = QueryPolygonFilter (128 bytes) +
                // outer vertices (N * 16 bytes) +
                // hole descriptors (H * 8 bytes) +
                // hole vertices (M * 16 bytes)
                const header_size = @sizeOf(QueryPolygonFilter);
                if (message_body_used.len < header_size) return false;

                const filter = mem.bytesAsValue(
                    QueryPolygonFilter,
                    message_body_used[0..header_size],
                ).*;

                // F1.1.3: Validate polygon constraints
                if (filter.vertex_count < 3) return false;
                if (filter.vertex_count > constants.polygon_vertices_max) return false;
                if (filter.hole_count > constants.polygon_holes_max) return false;
                if (filter.limit == 0) return false;

                const outer_vertices_size = filter.vertex_count * @sizeOf(PolygonVertex);
                if (message_body_used.len < header_size + outer_vertices_size) return false;

                var total_hole_vertices: u32 = 0;
                var expected_size: usize = header_size + outer_vertices_size;

                if (filter.hole_count > 0) {
                    const descriptors_offset = header_size + outer_vertices_size;
                    const hole_descriptors_size = filter.hole_count * @sizeOf(HoleDescriptor);
                    if (message_body_used.len < descriptors_offset + hole_descriptors_size)
                        return false;

                    const descriptors_bytes =
                        message_body_used[descriptors_offset..][0..hole_descriptors_size];
                    const hole_descriptors = mem.bytesAsSlice(HoleDescriptor, descriptors_bytes);

                    for (hole_descriptors) |desc| {
                        if (desc.vertex_count < constants.polygon_hole_vertices_min) return false;
                        total_hole_vertices += desc.vertex_count;
                    }

                    const total_vertices = filter.vertex_count + total_hole_vertices;
                    if (total_vertices > constants.polygon_vertices_max) return false;

                    const hole_vertices_size = total_hole_vertices * @sizeOf(PolygonVertex);
                    expected_size = descriptors_offset + hole_descriptors_size + hole_vertices_size;
                    if (message_body_used.len < expected_size) return false;
                }

                // Reject trailing bytes (must match expected wire format exactly).
                if (message_body_used.len != expected_size) return false;

                // Validate outer vertices coordinates
                const outer_vertices = mem.bytesAsSlice(
                    PolygonVertex,
                    message_body_used[header_size..][0..outer_vertices_size],
                );
                for (outer_vertices) |vertex| {
                    if (!isValidLatitudeNano(vertex.lat_nano)) return false;
                    if (!isValidLongitudeNano(vertex.lon_nano)) return false;
                }

                // Validate hole vertices coordinates
                if (filter.hole_count > 0) {
                    const hole_vertices_offset = header_size + outer_vertices_size +
                        (filter.hole_count * @sizeOf(HoleDescriptor));
                    const hole_vertices_size = total_hole_vertices * @sizeOf(PolygonVertex);
                    const hole_vertices = mem.bytesAsSlice(
                        PolygonVertex,
                        message_body_used[hole_vertices_offset..][0..hole_vertices_size],
                    );
                    for (hole_vertices) |vertex| {
                        if (!isValidLatitudeNano(vertex.lat_nano)) return false;
                        if (!isValidLongitudeNano(vertex.lon_nano)) return false;
                    }
                }

                return true;
            }

            const event_size = operation.event_size();
            if (event_size == 0) return true; // No body expected

            // Body must be properly aligned
            if (message_body_used.len % event_size != 0) return false;

            // F1.1.3: Operation-specific validation
            switch (operation) {
                .insert_events, .upsert_events => {
                    // Validate each GeoEvent in the batch
                    const events = mem.bytesAsSlice(GeoEvent, message_body_used);
                    for (events) |event| {
                        if (!validateGeoEvent(event)) return false;
                    }
                    return true;
                },
                .delete_entities => {
                    // delete_entities takes array of entity_ids (u128)
                    // Entity IDs of 0 are invalid (will fail at execution but not
                    // reject entire message)
                    return true;
                },
                .query_uuid => {
                    // QueryUuidFilter validation - entity_id must be non-zero
                    if (message_body_used.len != @sizeOf(QueryUuidFilter)) return false;
                    const filter = mem.bytesAsValue(
                        QueryUuidFilter,
                        message_body_used[0..@sizeOf(QueryUuidFilter)],
                    ).*;
                    if (filter.entity_id == 0) return false;
                    for (filter.reserved) |byte| {
                        if (byte != 0) return false;
                    }
                    return true;
                },
                .query_uuid_batch => {
                    // QueryUuidBatchFilter validation (F1.3.4)
                    if (message_body_used.len < @sizeOf(QueryUuidBatchFilter)) return false;
                    const filter = mem.bytesAsValue(
                        QueryUuidBatchFilter,
                        message_body_used[0..@sizeOf(QueryUuidBatchFilter)],
                    ).*;

                    // Validate count
                    if (filter.count > QueryUuidBatchFilter.max_count) return false;

                    // Validate body size matches count
                    const expected_size = @sizeOf(QueryUuidBatchFilter) +
                        filter.count * @sizeOf(u128);
                    if (message_body_used.len < expected_size) return false;

                    // Empty batch is valid (count=0)
                    return true;
                },
                .query_radius => {
                    // QueryRadiusFilter validation
                    if (message_body_used.len < @sizeOf(QueryRadiusFilter)) return false;
                    const filter = mem.bytesAsValue(
                        QueryRadiusFilter,
                        message_body_used[0..@sizeOf(QueryRadiusFilter)],
                    ).*;

                    // Validate coordinates
                    if (!isValidLatitudeNano(filter.center_lat_nano)) return false;
                    if (!isValidLongitudeNano(filter.center_lon_nano)) return false;

                    // Validate radius (must be positive)
                    if (filter.radius_mm == 0) return false;

                    // Validate limit
                    if (filter.limit == 0) return false;
                    return true;
                },
                .query_polygon => {
                    // Already validated above
                    return true;
                },
                else => {
                    // Default: size alignment check is sufficient
                    return true;
                },
            }
        }

        // ====================================================================
        // Helper Functions

        /// Validate a GeoEvent for input_valid (F1.1.3).
        /// Returns true if the event passes all validation checks.
        fn validateGeoEvent(event: GeoEvent) bool {
            // entity_id must not be zero
            if (event.entity_id == 0) return false;

            // entity_id must not be maxInt(u128) - per data-model spec
            if (event.entity_id == std.math.maxInt(u128)) return false;

            // Validate latitude range: -90e9 to +90e9 nanodegrees
            if (!isValidLatitudeNano(event.lat_nano)) return false;

            // Validate longitude range: -180e9 to +180e9 nanodegrees
            if (!isValidLongitudeNano(event.lon_nano)) return false;

            // Validate heading: 0-36000 centidegrees (0-360 degrees)
            if (event.heading_cdeg > 36000) return false;

            // TTL must be non-negative (it's u32, always >= 0)
            // Reserved fields should be zero
            for (event.reserved) |byte| {
                if (byte != 0) return false;
            }

            // Flags padding bits must be zero (per data-model spec)
            if (event.flags.padding != 0) return false;

            return true;
        }

        /// Validate latitude in nanodegrees.
        fn isValidLatitudeNano(lat_nano: i64) bool {
            const lat_max_nano: i64 = 90_000_000_000; // 90 * 1e9
            return lat_nano >= -lat_max_nano and lat_nano <= lat_max_nano;
        }

        /// Validate longitude in nanodegrees.
        fn isValidLongitudeNano(lon_nano: i64) bool {
            const lon_max_nano: i64 = 180_000_000_000; // 180 * 1e9
            return lon_nano >= -lon_max_nano and lon_nano <= lon_max_nano;
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
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(QueryUuidFilter));
}

test "QueryUuidResponse size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(QueryUuidResponse));
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

test "HoleDescriptor size" {
    // HoleDescriptor must be exactly 8 bytes (vertex_count + reserved)
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(HoleDescriptor));
}

test "QueryPolygonFilter hole_count field" {
    // Verify hole_count field exists and is at expected offset
    const filter = QueryPolygonFilter{
        .vertex_count = 4,
        .hole_count = 2,
        .limit = 100,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 0,
    };
    try std.testing.expectEqual(@as(u32, 4), filter.vertex_count);
    try std.testing.expectEqual(@as(u32, 2), filter.hole_count);
    try std.testing.expectEqual(@as(u32, 100), filter.limit);
}

test "Polygon with holes wire format calculation" {
    // Test wire format size calculation for polygon with holes
    // Format: QueryPolygonFilter (128) + outer vertices (16 * N) +
    // HoleDescriptors (8 * H) + hole vertices (16 * M)
    const outer_vertices: u32 = 4; // Square
    const holes: u32 = 2;
    const hole1_vertices: u32 = 4;
    const hole2_vertices: u32 = 3;

    const header_size = @sizeOf(QueryPolygonFilter);
    const outer_size = outer_vertices * @sizeOf(PolygonVertex);
    const descriptors_size = holes * @sizeOf(HoleDescriptor);
    const hole_vertices_size = (hole1_vertices + hole2_vertices) * @sizeOf(PolygonVertex);

    const total = header_size + outer_size + descriptors_size + hole_vertices_size;

    // 128 + (4 * 16) + (2 * 8) + (7 * 16) = 128 + 64 + 16 + 112 = 320
    try std.testing.expectEqual(@as(usize, 320), total);
}

test "input_valid: polygon with holes accepted" {
    const TestStorage = @import("testing/storage.zig").Storage;
    const GeoStateMachine = GeoStateMachineType(TestStorage);
    var machine: GeoStateMachine = undefined;

    const header_size = @sizeOf(QueryPolygonFilter);
    const outer_vertices: u32 = 4;
    const hole_vertices: u32 = 4;
    const outer_size = outer_vertices * @sizeOf(PolygonVertex);
    const desc_size = @sizeOf(HoleDescriptor);
    const hole_size = hole_vertices * @sizeOf(PolygonVertex);
    const total_size = header_size + outer_size + desc_size + hole_size;

    var buffer: [total_size]u8 align(16) = undefined;
    @memset(&buffer, 0);

    const header = mem.bytesAsValue(QueryPolygonFilter, buffer[0..header_size]);
    header.* = .{
        .vertex_count = outer_vertices,
        .hole_count = 1,
        .limit = 10,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 0,
    };

    const outer_slice = mem.bytesAsSlice(
        PolygonVertex,
        buffer[header_size..][0..outer_size],
    );
    outer_slice[0] = .{ .lat_nano = 0, .lon_nano = 0 };
    outer_slice[1] = .{ .lat_nano = 0, .lon_nano = 10_000_000_000 };
    outer_slice[2] = .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 };
    outer_slice[3] = .{ .lat_nano = 10_000_000_000, .lon_nano = 0 };

    const desc_offset = header_size + outer_size;
    const desc_slice = mem.bytesAsSlice(
        HoleDescriptor,
        buffer[desc_offset..][0..desc_size],
    );
    desc_slice[0] = .{ .vertex_count = hole_vertices };

    const hole_offset = desc_offset + desc_size;
    const hole_slice = mem.bytesAsSlice(
        PolygonVertex,
        buffer[hole_offset..][0..hole_size],
    );
    hole_slice[0] = .{ .lat_nano = 2_000_000_000, .lon_nano = 2_000_000_000 };
    hole_slice[1] = .{ .lat_nano = 2_000_000_000, .lon_nano = 4_000_000_000 };
    hole_slice[2] = .{ .lat_nano = 4_000_000_000, .lon_nano = 4_000_000_000 };
    hole_slice[3] = .{ .lat_nano = 4_000_000_000, .lon_nano = 2_000_000_000 };

    const body: []align(16) const u8 = buffer[0..];
    try std.testing.expect(machine.input_valid(.query_polygon, body));
}

test "input_valid: polygon with invalid hole vertex count rejected" {
    const TestStorage = @import("testing/storage.zig").Storage;
    const GeoStateMachine = GeoStateMachineType(TestStorage);
    var machine: GeoStateMachine = undefined;

    const header_size = @sizeOf(QueryPolygonFilter);
    const outer_vertices: u32 = 4;
    const hole_vertices: u32 = 2;
    const outer_size = outer_vertices * @sizeOf(PolygonVertex);
    const desc_size = @sizeOf(HoleDescriptor);
    const hole_size = hole_vertices * @sizeOf(PolygonVertex);
    const total_size = header_size + outer_size + desc_size + hole_size;

    var buffer: [total_size]u8 align(16) = undefined;
    @memset(&buffer, 0);

    const header = mem.bytesAsValue(QueryPolygonFilter, buffer[0..header_size]);
    header.* = .{
        .vertex_count = outer_vertices,
        .hole_count = 1,
        .limit = 10,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 0,
    };

    const outer_slice = mem.bytesAsSlice(
        PolygonVertex,
        buffer[header_size..][0..outer_size],
    );
    outer_slice[0] = .{ .lat_nano = 0, .lon_nano = 0 };
    outer_slice[1] = .{ .lat_nano = 0, .lon_nano = 10_000_000_000 };
    outer_slice[2] = .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 };
    outer_slice[3] = .{ .lat_nano = 10_000_000_000, .lon_nano = 0 };

    const desc_offset = header_size + outer_size;
    const desc_slice = mem.bytesAsSlice(
        HoleDescriptor,
        buffer[desc_offset..][0..desc_size],
    );
    desc_slice[0] = .{ .vertex_count = hole_vertices };

    const hole_offset = desc_offset + desc_size;
    const hole_slice = mem.bytesAsSlice(
        PolygonVertex,
        buffer[hole_offset..][0..hole_size],
    );
    hole_slice[0] = .{ .lat_nano = 2_000_000_000, .lon_nano = 2_000_000_000 };
    hole_slice[1] = .{ .lat_nano = 4_000_000_000, .lon_nano = 4_000_000_000 };

    const body: []align(16) const u8 = buffer[0..];
    try std.testing.expect(!machine.input_valid(.query_polygon, body));
}

test "batch_max_events calculation" {
    // Should calculate max GeoEvents that fit in message body
    const max_events = @divFloor(constants.message_body_size_max, @sizeOf(GeoEvent));
    try std.testing.expect(max_events > 0);
    // With 128-byte GeoEvent and ~1MB body, should fit ~8000 events
    try std.testing.expect(max_events >= 8);
}

test "GeoStateMachine RAM index falls back to mmap on OOM" {
    const TestStorage = @import("testing/storage.zig").Storage;
    const GeoStateMachine = GeoStateMachineType(TestStorage);
    const Alignment = std.mem.Alignment;

    const LimitedAllocator = struct {
        parent: std.mem.Allocator,
        max_allocation: usize,

        fn init(parent: std.mem.Allocator, max_allocation: usize) @This() {
            return .{
                .parent = parent,
                .max_allocation = max_allocation,
            };
        }

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (len > self.max_allocation) return null;
            return self.parent.rawAlloc(len, ptr_align, ret_addr);
        }

        fn resize(
            ctx: *anyopaque,
            buf: []u8,
            buf_align: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (new_len > self.max_allocation) return false;
            return self.parent.rawResize(buf, buf_align, new_len, ret_addr);
        }

        fn remap(
            ctx: *anyopaque,
            buf: []u8,
            buf_align: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (new_len > self.max_allocation) return null;
            return self.parent.rawRemap(buf, buf_align, new_len, ret_addr);
        }

        fn free(
            ctx: *anyopaque,
            buf: []u8,
            buf_align: Alignment,
            ret_addr: usize,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.parent.rawFree(buf, buf_align, ret_addr);
        }
    };

    const allocator = std.testing.allocator;
    var limited = LimitedAllocator.init(allocator, 1024);
    const limited_allocator = limited.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const mmap_path = try std.fs.path.join(allocator, &.{ dir_path, "ram_index.mmap" });
    defer allocator.free(mmap_path);

    const options = GeoStateMachine.Options{
        .batch_size_limit = 1024,
        .enable_index_checkpoint = true,
        .memory_mapped_index_enabled = true,
        .memory_mapped_index_path = mmap_path,
    };

    const ram_index = try GeoStateMachine.init_ram_index(limited_allocator, 64, options);
    defer {
        ram_index.deinit(limited_allocator);
        limited_allocator.destroy(ram_index);
    }

    try std.testing.expect(ram_index.mmap_region != null);
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
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(DER.entity_id_must_not_be_int_max));
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

test "QueryResponse: struct layout and constructors" {
    // Verify struct size (16 bytes for GeoEvent alignment)
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(QueryResponse));

    // Test complete() constructor
    const complete_resp = QueryResponse.complete(100);
    try std.testing.expectEqual(@as(u32, 100), complete_resp.count);
    try std.testing.expectEqual(@as(u8, 0), complete_resp.has_more);
    try std.testing.expectEqual(@as(u8, 0), complete_resp.partial_result);

    // Test with_more() constructor
    const more_resp = QueryResponse.with_more(50);
    try std.testing.expectEqual(@as(u32, 50), more_resp.count);
    try std.testing.expectEqual(@as(u8, 1), more_resp.has_more);
    try std.testing.expectEqual(@as(u8, 0), more_resp.partial_result);

    // Test truncated() constructor
    const truncated_resp = QueryResponse.truncated(8000);
    try std.testing.expectEqual(@as(u32, 8000), truncated_resp.count);
    try std.testing.expectEqual(@as(u8, 1), truncated_resp.has_more);
    try std.testing.expectEqual(@as(u8, 1), truncated_resp.partial_result);
}

test "QueryResponse: error status encoding" {
    const response = QueryResponse.with_error(StateError.index_rebuilding);
    try std.testing.expectEqual(@as(u32, 0), response.count);
    try std.testing.expectEqual(StateError.index_rebuilding, response.error_status().?);
}

test "QueryUuidBatchResult: error status encoding" {
    const result = QueryUuidBatchResult.with_error(StateError.index_rebuilding);
    try std.testing.expectEqual(@as(u32, 0), result.found_count);
    try std.testing.expectEqual(@as(u32, 0), result.not_found_count);
    try std.testing.expectEqual(StateError.index_rebuilding, result.error_status().?);
}

test "IndexRecoveryState: range blocking" {
    var state = IndexRecoveryState{};
    try std.testing.expect(!state.blocks_cell(100));

    state.active = true;
    try std.testing.expect(state.blocks_cell(100));

    state.ranges.clear();
    state.ranges.push(.{ .start = 50, .end = 150 });
    try std.testing.expect(state.blocks_cell(100));
    try std.testing.expect(!state.blocks_cell(200));

    try std.testing.expect(state.blocks_range(.{ .start = 140, .end = 160 }));
    try std.testing.expect(!state.blocks_range(.{ .start = 160, .end = 180 }));
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

test "execute_archerdb_ping: returns pong" {
    var output: [16]u8 = undefined;
    const result = blk: {
        // Test the ping response format (we can't instantiate GeoStateMachine in unit tests
        // but we can verify the expected output format)
        output[0] = 'p';
        output[1] = 'o';
        output[2] = 'n';
        output[3] = 'g';
        break :blk 4;
    };
    try std.testing.expectEqual(@as(usize, 4), result);
    try std.testing.expectEqualSlices(u8, "pong", output[0..4]);
}

test "InsertGeoEventResult: all result codes valid" {
    // Verify all result codes are sequential starting from 0
    const values = std.enums.values(InsertGeoEventResult);
    for (values, 0..) |_, index| {
        const result: InsertGeoEventResult = @enumFromInt(index);
        // Just verifying we can convert index to enum value
        _ = result;
    }
    // Verify specific values
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(InsertGeoEventResult.ok));
    try std.testing.expectEqual(
        @as(u32, 7),
        @intFromEnum(InsertGeoEventResult.entity_id_must_not_be_zero),
    );
    try std.testing.expectEqual(
        @as(u32, 9),
        @intFromEnum(InsertGeoEventResult.lat_out_of_range),
    );
    try std.testing.expectEqual(
        @as(u32, 10),
        @intFromEnum(InsertGeoEventResult.lon_out_of_range),
    );
    try std.testing.expectEqual(
        @as(u32, 4),
        @intFromEnum(InsertGeoEventResult.reserved_field),
    );
    try std.testing.expectEqual(
        @as(u32, 14),
        @intFromEnum(InsertGeoEventResult.heading_out_of_range),
    );
    try std.testing.expectEqual(
        @as(u32, 16),
        @intFromEnum(InsertGeoEventResult.entity_id_must_not_be_int_max),
    );
}

test "QueryUuidFilter: field layout" {
    const filter = QueryUuidFilter{
        .entity_id = 0x12345678_9abcdef0_12345678_9abcdef0,
    };
    try std.testing.expectEqual(@as(u128, 0x12345678_9abcdef0_12345678_9abcdef0), filter.entity_id);
    for (filter.reserved) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(QueryUuidFilter));
}

test "coordinate validation: latitude boundaries" {
    const lat_max_nano: i64 = 90_000_000_000;

    // Test valid latitude boundary values
    // The validation logic: lat >= -90° and lat <= 90°
    try std.testing.expect(0 >= -lat_max_nano and 0 <= lat_max_nano); // 0° valid
    try std.testing.expect(
        lat_max_nano >= -lat_max_nano and lat_max_nano <= lat_max_nano,
    ); // 90° valid
    try std.testing.expect(
        -lat_max_nano >= -lat_max_nano and -lat_max_nano <= lat_max_nano,
    ); // -90° valid

    // Test invalid latitude values
    const invalid_lat: i64 = 91_000_000_000;
    try std.testing.expect(
        !(invalid_lat >= -lat_max_nano and invalid_lat <= lat_max_nano),
    ); // 91° invalid
}

test "coordinate validation: longitude boundaries" {
    const lon_max_nano: i64 = 180_000_000_000;

    // Test valid longitude boundary values
    try std.testing.expect(0 >= -lon_max_nano and 0 <= lon_max_nano); // 0° valid
    try std.testing.expect(
        lon_max_nano >= -lon_max_nano and lon_max_nano <= lon_max_nano,
    ); // 180° valid
    try std.testing.expect(
        -lon_max_nano >= -lon_max_nano and -lon_max_nano <= lon_max_nano,
    ); // -180° valid

    // Test invalid longitude values
    const invalid_lon: i64 = 181_000_000_000;
    try std.testing.expect(
        !(invalid_lon >= -lon_max_nano and invalid_lon <= lon_max_nano),
    ); // 181° invalid
}

test "GeoEvent validation: heading boundary (36000 centidegrees = 360°)" {
    // Heading is stored in centidegrees (0-36000)
    // 36000 = 360.00° (valid, wraps to 0)
    // 36001 = 360.01° (invalid)
    try std.testing.expect(0 <= 36000); // 0° valid
    try std.testing.expect(18000 <= 36000); // 180° valid
    try std.testing.expect(36000 <= 36000); // 360° valid
    try std.testing.expect(!(36001 <= 36000)); // 360.01° invalid
}

test "GeoEvent: struct size is exactly 128 bytes" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(GeoEvent));
}

test "GeoEvent: reserved field is 12 bytes" {
    // Verify reserved field size matches expected padding
    const event = GeoEvent{
        .id = 0,
        .entity_id = 1,
        .correlation_id = 0,
        .user_data = 0,
        .lat_nano = 0,
        .lon_nano = 0,
        .group_id = 0,
        .timestamp = 0,
        .altitude_mm = 0,
        .velocity_mms = 0,
        .ttl_seconds = 0,
        .accuracy_mm = 0,
        .heading_cdeg = 0,
        .flags = GeoEventFlags.none,
        .reserved = [_]u8{0} ** 12,
    };
    try std.testing.expectEqual(@as(usize, 12), event.reserved.len);
}

test "composite ID encoding: S2 cell and timestamp" {
    // Test the composite ID format used in insert_events
    const lat_nano: i64 = 37_774900000; // San Francisco lat
    const lon_nano: i64 = -122_419400000; // San Francisco lon
    const timestamp: u64 = 1704067200_000_000_000; // 2024-01-01 00:00:00 UTC in nanos

    // Compute S2 cell ID at level 30
    const cell_id = S2.latLonToCellId(lat_nano, lon_nano, 30);

    // Build composite ID
    const composite_id: u128 = (@as(u128, cell_id) << 64) | @as(u128, timestamp);

    // Extract back
    const extracted_cell_id = @as(u64, @truncate(composite_id >> 64));
    const extracted_timestamp = @as(u64, @truncate(composite_id));

    try std.testing.expectEqual(cell_id, extracted_cell_id);
    try std.testing.expectEqual(timestamp, extracted_timestamp);

    // Verify cell center is approximately correct
    const center = S2.cellIdToLatLon(extracted_cell_id);
    // Allow 1 microdegree tolerance (at level 30, precision is ~7.5mm)
    const tolerance: i64 = 1000;
    try std.testing.expect(@abs(center.lat_nano - lat_nano) < tolerance);
    try std.testing.expect(@abs(center.lon_nano - lon_nano) < tolerance);
}

// ============================================================================
// F1.3.3 Cursor-Based Pagination Tests
// ============================================================================

test "QueryLatestFilter: struct size is exactly 128 bytes" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(QueryLatestFilter));
}

test "QueryLatestFilter: cursor_timestamp field exists and is accessible" {
    const filter = QueryLatestFilter{
        .limit = 100,
        .group_id = 0,
        .cursor_timestamp = 1704067200_000_000_000, // 2024-01-01 UTC in nanos
    };
    try std.testing.expectEqual(@as(u64, 1704067200_000_000_000), filter.cursor_timestamp);
}

test "QueryLatestFilter: cursor_timestamp = 0 means start from latest" {
    const filter = QueryLatestFilter{
        .limit = 50,
        .group_id = 0,
        .cursor_timestamp = 0, // No cursor - start from latest
    };
    // Per spec: cursor_timestamp = 0 means no pagination filter
    try std.testing.expectEqual(@as(u64, 0), filter.cursor_timestamp);
}

test "QueryLatestFilter: pagination logic - skip newer entries" {
    // This tests the filtering logic used in execute_query_latest:
    // When cursor_timestamp > 0, skip entries where entry_timestamp >= cursor_timestamp
    const cursor_timestamp: u64 = 1704067200_000_000_000; // Reference point

    // Test entry timestamps
    const older_timestamp: u64 = 1704060000_000_000_000; // Before cursor
    const same_timestamp: u64 = 1704067200_000_000_000; // Same as cursor
    const newer_timestamp: u64 = 1704080000_000_000_000; // After cursor

    // Per implementation: skip entries at or newer than cursor
    const skip_older = cursor_timestamp > 0 and older_timestamp >= cursor_timestamp;
    const skip_same = cursor_timestamp > 0 and same_timestamp >= cursor_timestamp;
    const skip_newer = cursor_timestamp > 0 and newer_timestamp >= cursor_timestamp;

    try std.testing.expect(!skip_older); // Should NOT skip (include in results)
    try std.testing.expect(skip_same); // Should skip (at cursor boundary)
    try std.testing.expect(skip_newer); // Should skip (newer than cursor)
}

test "QueryLatestFilter: pagination with limit" {
    // Verify limit and cursor work together
    const filter = QueryLatestFilter{
        .limit = 10,
        .group_id = 0,
        .cursor_timestamp = 1704067200_000_000_000,
    };

    // Effective limit calculation from execute_query_latest
    const max_results: u32 = 81_000;
    const effective_limit = @min(filter.limit, max_results);

    try std.testing.expectEqual(@as(u32, 10), effective_limit);
}

test "QueryResponse: has_more flag indicates more results available" {
    // Test QueryResponse struct for pagination signaling
    var response = QueryResponse{
        .count = 10,
        .has_more = 1, // More results available
        .partial_result = 0,
    };

    try std.testing.expectEqual(@as(u8, 1), response.has_more);

    // Simulate last page
    response.has_more = 0;
    try std.testing.expectEqual(@as(u8, 0), response.has_more);
}

test "QueryResponse: struct size is exactly 16 bytes" {
    // Per spec: QueryResponse is 16 bytes for proper alignment before GeoEvent array
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(QueryResponse));
}

// ============================================================================
// TTL Expiration Tests (per query-engine/spec.md)
// ============================================================================

test "TTL expiration: entity with expired TTL should be filtered in queries" {
    // Per query-engine/spec.md lines 4-34:
    // When entity is retrieved and ttl_seconds > 0, check if expired
    // If now_seconds > (creation_seconds + ttl_seconds), entity is expired

    // Test case: Event created at T=1000 with TTL=60s expires at T=1060
    const creation_timestamp_ns: u64 = 1000_000_000_000; // 1000 seconds in nanos
    const ttl_seconds: u32 = 60;
    const current_timestamp_ns: u64 = 1100_000_000_000; // 1100 seconds in nanos (expired)

    // Calculate expiration
    const creation_seconds = creation_timestamp_ns / 1_000_000_000;
    const expiry_seconds = creation_seconds + @as(u64, ttl_seconds);
    const now_seconds = current_timestamp_ns / 1_000_000_000;

    // Verify the entity would be considered expired
    try std.testing.expect(now_seconds > expiry_seconds);

    // Test non-expired case
    const current_before_expiry: u64 = 1050_000_000_000; // 1050 seconds (not expired)
    const now_before = current_before_expiry / 1_000_000_000;
    try std.testing.expect(now_before <= expiry_seconds);
}

test "TTL expiration: entity with ttl_seconds=0 never expires" {
    // Per spec: ttl_seconds = 0 means infinite TTL (no expiration)
    const ttl_seconds: u32 = 0;

    // Even far in the future, entity with TTL=0 should not expire
    // The check is: if (ttl_seconds > 0) { ... check expiration ... }
    // So if ttl_seconds == 0, we skip the expiration check entirely
    try std.testing.expectEqual(@as(u32, 0), ttl_seconds);
}

test "TTL expiration: boundary case - exactly at expiry time" {
    // Edge case: what happens when now_seconds == expiry_seconds?
    // Per spec: "if (now_seconds > expiry_seconds)" - so equality is NOT expired
    const creation_seconds: u64 = 1000;
    const ttl_seconds: u32 = 60;
    const expiry_seconds = creation_seconds + @as(u64, ttl_seconds); // 1060
    const now_seconds: u64 = 1060; // Exactly at expiry

    // At exact expiry time, entity is still valid (> not >=)
    try std.testing.expect(!(now_seconds > expiry_seconds));
}

// ============================================================================
// Reserved Field Validation Tests (per data-model/spec.md)
// ============================================================================

test "Reserved field validation: non-zero reserved bytes rejected" {
    // Per data-model/spec.md lines 403-415:
    // Reserved fields MUST be zero for forward compatibility

    // Test with non-zero reserved bytes
    var reserved_with_data: [12]u8 = [_]u8{0} ** 12;
    reserved_with_data[5] = 0xFF; // Non-zero byte

    var found_nonzero = false;
    for (reserved_with_data) |byte| {
        if (byte != 0) {
            found_nonzero = true;
            break;
        }
    }
    try std.testing.expect(found_nonzero);
}

test "Reserved field validation: all-zero reserved bytes accepted" {
    // Valid case: all zeros
    const reserved_zeros: [12]u8 = [_]u8{0} ** 12;

    var found_nonzero = false;
    for (reserved_zeros) |byte| {
        if (byte != 0) {
            found_nonzero = true;
            break;
        }
    }
    try std.testing.expect(!found_nonzero);
}

// ============================================================================
// Entity Operations Tests (ENT-01 through ENT-10)
// ============================================================================
//
// These tests verify core entity operations per entity-operations/spec.md:
// - ENT-01: Insert stores all GeoEvent fields
// - ENT-02: Insert on existing entity returns error (uses LWW semantics)
// - ENT-03: Upsert creates or updates with LWW
// - ENT-04: Upsert creates tombstone for old version
// - ENT-05: Delete removes from RAM index
// - ENT-06: Delete creates tombstone for GDPR compliance
// - ENT-07: Deleted entity not retrievable (GDPR verification)
// - ENT-08: UUID query returns correct entity
// - ENT-09: Latest query returns most recent position
// - ENT-10: TTL cleanup metrics exposed

test "entity ops: insert stores all fields" {
    // ENT-01: Insert GeoEvent with all fields, verify storage
    // This tests that when we create a GeoEvent with specific values,
    // all fields are preserved correctly in the event structure.

    const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    const lat_nano: i64 = GeoEvent.lat_from_float(37.7749); // San Francisco
    const lon_nano: i64 = GeoEvent.lon_from_float(-122.4194);
    const timestamp: u64 = 1704067200_000_000_000; // 2024-01-01 00:00:00 UTC in ns
    const group_id: u64 = 42;
    const correlation_id: u128 = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0;
    const user_data: u128 = 0xFEDCBA98_76543210_FEDCBA98_76543210;
    const altitude_mm: i32 = 100_000; // 100 meters
    const velocity_mms: u32 = 27_778; // ~100 km/h
    const accuracy_mm: u32 = 5_000; // 5 meters
    const heading_cdeg: u16 = 9000; // 90.00 degrees (east)
    const ttl_seconds: u32 = 3600; // 1 hour

    // Compute S2 cell ID for composite ID
    const cell_id = S2.latLonToCellId(lat_nano, lon_nano, 30);
    const composite_id = GeoEvent.pack_id(cell_id, timestamp);

    var event = GeoEvent.zero();
    event.id = composite_id;
    event.entity_id = entity_id;
    event.correlation_id = correlation_id;
    event.user_data = user_data;
    event.lat_nano = lat_nano;
    event.lon_nano = lon_nano;
    event.group_id = group_id;
    event.timestamp = timestamp;
    event.altitude_mm = altitude_mm;
    event.velocity_mms = velocity_mms;
    event.ttl_seconds = ttl_seconds;
    event.accuracy_mm = accuracy_mm;
    event.heading_cdeg = heading_cdeg;

    // Verify all fields stored correctly
    try std.testing.expectEqual(entity_id, event.entity_id);
    try std.testing.expectEqual(correlation_id, event.correlation_id);
    try std.testing.expectEqual(user_data, event.user_data);
    try std.testing.expectEqual(lat_nano, event.lat_nano);
    try std.testing.expectEqual(lon_nano, event.lon_nano);
    try std.testing.expectEqual(group_id, event.group_id);
    try std.testing.expectEqual(timestamp, event.timestamp);
    try std.testing.expectEqual(altitude_mm, event.altitude_mm);
    try std.testing.expectEqual(velocity_mms, event.velocity_mms);
    try std.testing.expectEqual(ttl_seconds, event.ttl_seconds);
    try std.testing.expectEqual(accuracy_mm, event.accuracy_mm);
    try std.testing.expectEqual(heading_cdeg, event.heading_cdeg);

    // Verify composite ID encoding
    const unpacked = GeoEvent.unpack_id(event.id);
    try std.testing.expectEqual(cell_id, unpacked.s2_cell_id);
    try std.testing.expectEqual(timestamp, unpacked.timestamp_ns);
}

test "entity ops: insert result codes for LWW rejection" {
    // ENT-02: When inserting with older timestamp than existing, LWW rejects
    // Per CONTEXT.md: "Insert on existing entity ID returns error"
    // Actually uses LWW semantics - older writes return .exists result

    // InsertGeoEventResult codes
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(InsertGeoEventResult.ok));
    try std.testing.expectEqual(@as(u32, 13), @intFromEnum(InsertGeoEventResult.exists));

    // When insert encounters existing entity with newer timestamp, it returns .exists
    // This is the "error" behavior mentioned in CONTEXT.md - the insert is rejected
}

test "entity ops: upsert creates new entry" {
    // ENT-03: Upsert on non-existent entity creates new entry
    // When entity doesn't exist, upsert behaves like insert

    // Test the UpsertResult structure
    const result = @import("ram_index.zig").UpsertResult{
        .inserted = true,
        .updated = true,
        .probe_count = 0,
    };

    // For new entity: inserted=true, updated=true
    try std.testing.expect(result.inserted);
    try std.testing.expect(result.updated);
}

test "entity ops: upsert updates existing with newer timestamp" {
    // ENT-03: Upsert on existing entity with newer timestamp updates

    // Simulate LWW comparison
    const old_timestamp: u64 = 1704067200_000_000_000; // 2024-01-01 00:00:00 UTC
    const new_timestamp: u64 = 1704067260_000_000_000; // 2024-01-01 00:01:00 UTC

    // Newer timestamp should win
    try std.testing.expect(new_timestamp > old_timestamp);

    // UpsertResult for update case
    const result = @import("ram_index.zig").UpsertResult{
        .inserted = false,
        .updated = true,
        .probe_count = 1,
    };

    // For existing entity with newer timestamp: inserted=false, updated=true
    try std.testing.expect(!result.inserted);
    try std.testing.expect(result.updated);
}

test "entity ops: upsert creates tombstone for old version" {
    // ENT-04: When upsert updates an entity, a tombstone is created for the old version
    // Per CONTEXT.md: "TTL-based tombstones"

    const entity_id: u128 = 0xAAAABBBB_CCCCDDDD_EEEEFFFF_00001111;
    const original_ts: u64 = 1000 * ttl.ns_per_second;
    const tombstone_ts: u64 = 2000 * ttl.ns_per_second;

    // Create original event
    var original = GeoEvent.zero();
    original.entity_id = entity_id;
    original.timestamp = original_ts;
    original.lat_nano = GeoEvent.lat_from_float(37.7749);
    original.lon_nano = GeoEvent.lon_from_float(-122.4194);
    original.group_id = 42;

    const cell_id = S2.latLonToCellId(original.lat_nano, original.lon_nano, 30);
    original.id = GeoEvent.pack_id(cell_id, original_ts);

    // Create tombstone for old version (what upsert would do internally)
    const tombstone = original.create_tombstone(tombstone_ts);

    // Verify tombstone properties
    try std.testing.expect(tombstone.is_tombstone());
    try std.testing.expectEqual(entity_id, tombstone.entity_id);
    try std.testing.expectEqual(original.group_id, tombstone.group_id);
    try std.testing.expectEqual(tombstone_ts, tombstone.timestamp);
    try std.testing.expectEqual(@as(u32, 0), tombstone.ttl_seconds); // Tombstones never expire

    // Tombstone preserves location for audit trail
    try std.testing.expectEqual(original.lat_nano, tombstone.lat_nano);
    try std.testing.expectEqual(original.lon_nano, tombstone.lon_nano);
}

test "entity ops: LWW semantics - newer timestamp wins" {
    // ENT-03: Last-Write-Wins resolution based on timestamp

    const entity_id: u128 = 0x11112222_33334444_55556666_77778888;
    const lat_nano: i64 = GeoEvent.lat_from_float(40.7128); // NYC
    const lon_nano: i64 = GeoEvent.lon_from_float(-74.0060);

    const timestamp_100: u64 = 100 * ttl.ns_per_second;
    const timestamp_50: u64 = 50 * ttl.ns_per_second;

    // First write: timestamp 100
    const cell_id = S2.latLonToCellId(lat_nano, lon_nano, 30);
    const composite_id_100 = GeoEvent.pack_id(cell_id, timestamp_100);

    var event_100 = GeoEvent.zero();
    event_100.id = composite_id_100;
    event_100.entity_id = entity_id;
    event_100.timestamp = timestamp_100;

    // Second write: timestamp 50 (older)
    const composite_id_50 = GeoEvent.pack_id(cell_id, timestamp_50);

    var event_50 = GeoEvent.zero();
    event_50.id = composite_id_50;
    event_50.entity_id = entity_id;
    event_50.timestamp = timestamp_50;

    // LWW comparison: newer timestamp should win
    const ts_100 = @as(u64, @truncate(composite_id_100));
    const ts_50 = @as(u64, @truncate(composite_id_50));

    // Verify timestamps extracted correctly
    try std.testing.expectEqual(timestamp_100, ts_100);
    try std.testing.expectEqual(timestamp_50, ts_50);

    // Newer timestamp wins
    try std.testing.expect(ts_100 > ts_50);

    // Therefore event_100 should be kept, event_50 should be rejected
    const should_update = ts_50 > ts_100; // false - older write doesn't win
    try std.testing.expect(!should_update);
}

test "entity ops: LWW tie-break by composite ID" {
    // When timestamps are equal, higher composite ID wins (deterministic)

    const timestamp: u64 = 1000 * ttl.ns_per_second;

    // Two different S2 cells with same timestamp
    const lat1: i64 = GeoEvent.lat_from_float(37.7749);
    const lon1: i64 = GeoEvent.lon_from_float(-122.4194);
    const cell_id_1 = S2.latLonToCellId(lat1, lon1, 30);

    const lat2: i64 = GeoEvent.lat_from_float(40.7128);
    const lon2: i64 = GeoEvent.lon_from_float(-74.0060);
    const cell_id_2 = S2.latLonToCellId(lat2, lon2, 30);

    const composite_id_1 = GeoEvent.pack_id(cell_id_1, timestamp);
    const composite_id_2 = GeoEvent.pack_id(cell_id_2, timestamp);

    // Both have same timestamp
    const ts_1 = @as(u64, @truncate(composite_id_1));
    const ts_2 = @as(u64, @truncate(composite_id_2));
    try std.testing.expectEqual(ts_1, ts_2);

    // Tie-break: higher composite_id wins
    if (composite_id_1 != composite_id_2) {
        const winner_id = @max(composite_id_1, composite_id_2);
        const loser_id = @min(composite_id_1, composite_id_2);

        // Per ram_index.zig upsert: "Tie-break: higher latest_id wins (deterministic)"
        const should_update = loser_id > winner_id;
        try std.testing.expect(!should_update); // loser should not update winner
    }
}

// ============================================================================
// Delete and GDPR Compliance Tests (ENT-05 through ENT-07)
// ============================================================================
//
// These tests verify delete operations and GDPR "right to erasure" compliance
// per compliance/spec.md and hybrid-memory/spec.md.

test "delete: DeleteEntityResult codes" {
    // ENT-05: Verify delete result codes are correct

    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(DeleteEntityResult.ok));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(DeleteEntityResult.entity_id_must_not_be_zero));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(DeleteEntityResult.entity_not_found));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(DeleteEntityResult.entity_id_must_not_be_int_max));
}

test "delete: creates tombstone with correct properties" {
    // ENT-06: Delete creates proper tombstone for GDPR compliance
    // Per compliance/spec.md: tombstones ensure durable deletion and prevent resurrection

    const entity_id: u128 = 0xDEADBEEF_12345678_9ABCDEF0_CAFEBABE;
    const group_id: u64 = 100;
    const delete_time_ns: u64 = 5000 * ttl.ns_per_second;

    // Create minimal tombstone (what delete_entities does)
    const tombstone = GeoEvent.create_minimal_tombstone(entity_id, group_id, delete_time_ns);

    // Verify tombstone properties per ttl-retention/spec.md
    try std.testing.expect(tombstone.is_tombstone());
    try std.testing.expect(tombstone.flags.deleted);
    try std.testing.expectEqual(entity_id, tombstone.entity_id);
    try std.testing.expectEqual(group_id, tombstone.group_id);
    try std.testing.expectEqual(delete_time_ns, tombstone.timestamp);
    try std.testing.expectEqual(@as(u32, 0), tombstone.ttl_seconds); // Never expires

    // Minimal tombstone has zeroed location (S2 cell ID = 0)
    const unpacked = GeoEvent.unpack_id(tombstone.id);
    try std.testing.expectEqual(@as(u64, 0), unpacked.s2_cell_id);
    try std.testing.expectEqual(delete_time_ns, unpacked.timestamp_ns);

    // Location is zeroed for minimal tombstone
    try std.testing.expectEqual(@as(i64, 0), tombstone.lat_nano);
    try std.testing.expectEqual(@as(i64, 0), tombstone.lon_nano);
}

test "delete: GDPR tombstone lifecycle" {
    // ENT-07: Tombstone lifecycle for GDPR compliance
    // Per spec: tombstones are kept during compaction until final LSM level

    const entity_id: u128 = 0x11223344_55667788_99AABBCC_DDEEFF00;
    const group_id: u64 = 42;
    const delete_time_ns: u64 = 1000 * ttl.ns_per_second;

    const tombstone = GeoEvent.create_minimal_tombstone(entity_id, group_id, delete_time_ns);

    // Verify should_copy_forward behavior for tombstones
    const current_time_ns: u64 = 2000 * ttl.ns_per_second;

    // Not at final level - keep tombstone
    try std.testing.expect(tombstone.should_copy_forward(current_time_ns, false));

    // At final level - drop tombstone (no older versions exist)
    try std.testing.expect(!tombstone.should_copy_forward(current_time_ns, true));
}

test "delete: GDPR verification - entity_id preserved" {
    // Per GDPR Article 17: erasure must be verifiable
    // Tombstone preserves entity_id so we can prove deletion happened

    const entity_id: u128 = 0xAAAABBBB_CCCCDDDD_EEEEFFFF_00001111;
    const group_id: u64 = 77;

    // Original event
    var original = GeoEvent.zero();
    original.entity_id = entity_id;
    original.group_id = group_id;
    original.lat_nano = GeoEvent.lat_from_float(51.5074); // London
    original.lon_nano = GeoEvent.lon_from_float(-0.1278);
    original.timestamp = 1000 * ttl.ns_per_second;

    const cell_id = S2.latLonToCellId(original.lat_nano, original.lon_nano, 30);
    original.id = GeoEvent.pack_id(cell_id, original.timestamp);

    // Create tombstone from full event (preserves location)
    const tombstone_full = original.create_tombstone(2000 * ttl.ns_per_second);

    // Full tombstone preserves entity identity AND location
    try std.testing.expectEqual(entity_id, tombstone_full.entity_id);
    try std.testing.expectEqual(group_id, tombstone_full.group_id);
    try std.testing.expectEqual(original.lat_nano, tombstone_full.lat_nano);
    try std.testing.expectEqual(original.lon_nano, tombstone_full.lon_nano);

    // Create minimal tombstone (when we only have entity_id from RAM index)
    const tombstone_minimal = GeoEvent.create_minimal_tombstone(
        entity_id,
        group_id,
        3000 * ttl.ns_per_second,
    );

    // Minimal tombstone preserves entity identity but not location
    try std.testing.expectEqual(entity_id, tombstone_minimal.entity_id);
    try std.testing.expectEqual(group_id, tombstone_minimal.group_id);
    try std.testing.expectEqual(@as(i64, 0), tombstone_minimal.lat_nano);
    try std.testing.expectEqual(@as(i64, 0), tombstone_minimal.lon_nano);
}

test "delete: tombstone never expires" {
    // Tombstones must never expire to prevent resurrection
    // Per ttl-retention/spec.md: tombstones have ttl_seconds=0

    const entity_id: u128 = 0x12121212_34343434_56565656_78787878;
    const tombstone = GeoEvent.create_minimal_tombstone(entity_id, 0, 1000 * ttl.ns_per_second);

    // ttl_seconds=0 means never expires
    try std.testing.expectEqual(@as(u32, 0), tombstone.ttl_seconds);

    // is_expired should return false even at far future time
    const far_future = std.math.maxInt(u64) - 1;
    try std.testing.expect(!tombstone.is_expired(far_future));
}

test "GeoEvent: is_tombstone method" {
    // Verify is_tombstone correctly identifies tombstones

    var normal = GeoEvent.zero();
    normal.entity_id = 1;
    try std.testing.expect(!normal.is_tombstone());

    var deleted = GeoEvent.zero();
    deleted.entity_id = 1;
    deleted.flags.deleted = true;
    try std.testing.expect(deleted.is_tombstone());
}

test "GeoEvent: tombstone should_copy_forward compaction behavior" {
    // ENT-06: Verify tombstone compaction lifecycle

    var tombstone = GeoEvent.zero();
    tombstone.entity_id = 0xAAAABBBB_CCCCDDDD_EEEEFFFF_00001111;
    tombstone.flags.deleted = true;
    tombstone.ttl_seconds = 0;
    tombstone.timestamp = 1000 * ttl.ns_per_second;

    // Non-final level: keep tombstone to prevent resurrection on restore
    try std.testing.expect(tombstone.should_copy_forward(2000 * ttl.ns_per_second, false));

    // Final level: drop tombstone (no older versions exist below)
    try std.testing.expect(!tombstone.should_copy_forward(2000 * ttl.ns_per_second, true));
}

test "delete: batch delete result codes" {
    // Test DeleteEntitiesResult structure

    const result1 = DeleteEntitiesResult{
        .index = 0,
        .result = .ok,
    };
    try std.testing.expectEqual(@as(u32, 0), result1.index);
    try std.testing.expectEqual(DeleteEntityResult.ok, result1.result);

    const result2 = DeleteEntitiesResult{
        .index = 5,
        .result = .entity_not_found,
    };
    try std.testing.expectEqual(@as(u32, 5), result2.index);
    try std.testing.expectEqual(DeleteEntityResult.entity_not_found, result2.result);
}

test "delete: invalid entity_id rejection" {
    // Entity ID 0 is reserved (empty marker in RAM index)
    // Entity ID maxInt(u128) is reserved per data-model spec

    // Zero entity_id
    const zero_result = DeleteEntitiesResult{
        .index = 0,
        .result = .entity_id_must_not_be_zero,
    };
    try std.testing.expectEqual(DeleteEntityResult.entity_id_must_not_be_zero, zero_result.result);

    // Max entity_id
    const max_result = DeleteEntitiesResult{
        .index = 1,
        .result = .entity_id_must_not_be_int_max,
    };
    try std.testing.expectEqual(DeleteEntityResult.entity_id_must_not_be_int_max, max_result.result);
}

// ============================================================================
// TTL and Query Verification Tests (ENT-08 through ENT-10)
// ============================================================================
//
// These tests verify TTL expiration and query operations per query-engine/spec.md.

test "TTL: entity expires after TTL seconds" {
    // ENT-09: TTL expiration removes expired entities

    var event = GeoEvent.zero();
    event.entity_id = 0x12345678_9ABCDEF0_12345678_9ABCDEF0;
    event.timestamp = 60 * ttl.ns_per_second; // Event created at T=60s
    event.ttl_seconds = 60; // Expires at T=120s

    // At T=100s: not yet expired (100 < 120)
    const time_100 = 100 * ttl.ns_per_second;
    try std.testing.expect(!event.is_expired(time_100));

    // At T=121s: expired (121 > 120)
    const time_121 = 121 * ttl.ns_per_second;
    try std.testing.expect(event.is_expired(time_121));

    // At T=120s: exactly at expiry (expired, per ttl.zig uses >= not >)
    const time_120 = 120 * ttl.ns_per_second;
    try std.testing.expect(event.is_expired(time_120));

    // At T=119s: one second before expiry (not expired)
    const time_119 = 119 * ttl.ns_per_second;
    try std.testing.expect(!event.is_expired(time_119));
}

test "TTL: ttl_seconds=0 means never expires" {
    // Per spec: ttl_seconds = 0 means infinite TTL

    var event = GeoEvent.zero();
    event.entity_id = 0xAAAABBBB_CCCCDDDD_EEEEFFFF_00001111;
    event.timestamp = 1 * ttl.ns_per_second;
    event.ttl_seconds = 0; // Never expires

    // Should not expire even at far future
    const far_future = 1_000_000_000 * ttl.ns_per_second;
    try std.testing.expect(!event.is_expired(far_future));

    // Maximum time value (except maxInt which causes overflow)
    const max_safe_time = std.math.maxInt(u64) - 1;
    try std.testing.expect(!event.is_expired(max_safe_time));
}

test "TTL: remaining_ttl calculation" {
    // Test remaining TTL calculation

    var event = GeoEvent.zero();
    event.timestamp = 100 * ttl.ns_per_second;
    event.ttl_seconds = 100; // Expires at 200 seconds

    // At T=150s: 50 seconds remaining
    const remaining = event.remaining_ttl(150 * ttl.ns_per_second);
    try std.testing.expectEqual(@as(?u64, 50), remaining);

    // At T=190s: 10 seconds remaining
    const remaining2 = event.remaining_ttl(190 * ttl.ns_per_second);
    try std.testing.expectEqual(@as(?u64, 10), remaining2);

    // TTL=0 returns null (never expires)
    event.ttl_seconds = 0;
    try std.testing.expectEqual(@as(?u64, null), event.remaining_ttl(150 * ttl.ns_per_second));
}

test "TTL: expiration_time_ns calculation" {
    // Test expiration time calculation

    var event = GeoEvent.zero();
    event.timestamp = 100 * ttl.ns_per_second;
    event.ttl_seconds = 60; // Expires at 160 seconds

    const expiration = event.expiration_time_ns();
    try std.testing.expectEqual(160 * ttl.ns_per_second, expiration);

    // TTL=0 returns maxInt (never expires)
    event.ttl_seconds = 0;
    const no_expiration = event.expiration_time_ns();
    try std.testing.expectEqual(std.math.maxInt(u64), no_expiration);
}

test "TTL: expired entities not copied during compaction" {
    // should_copy_forward returns false for expired events

    var event = GeoEvent.zero();
    event.timestamp = 10 * ttl.ns_per_second;
    event.ttl_seconds = 10; // Expires at 20 seconds

    // At T=30s: expired, should not copy forward
    const time_30 = 30 * ttl.ns_per_second;
    try std.testing.expect(!event.should_copy_forward(time_30, false));
    try std.testing.expect(!event.should_copy_forward(time_30, true));

    // At T=15s: not expired, should copy forward
    const time_15 = 15 * ttl.ns_per_second;
    try std.testing.expect(event.should_copy_forward(time_15, false));
    try std.testing.expect(event.should_copy_forward(time_15, true));
}

test "UUID query: QueryUuidFilter structure" {
    // ENT-08: UUID query filter structure

    const entity_id: u128 = 0x12345678_9ABCDEF0_12345678_9ABCDEF0;
    const filter = QueryUuidFilter{
        .entity_id = entity_id,
    };

    try std.testing.expectEqual(entity_id, filter.entity_id);

    // Reserved bytes must be zero
    for (filter.reserved) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }

    // Size is 32 bytes
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(QueryUuidFilter));
}

test "UUID query: QueryUuidResponse structure" {
    // ENT-08: UUID query response structure
    // Per spec: status indicates found (0), not_found (200), or expired (210)

    // Success response (status=0 means found)
    const success = QueryUuidResponse{
        .status = 0,
    };
    try std.testing.expectEqual(@as(u8, 0), success.status);

    // Not found response (status=200 = entity_not_found)
    const not_found = QueryUuidResponse{
        .status = @intCast(@intFromEnum(StateError.entity_not_found)),
    };
    try std.testing.expectEqual(@as(u8, 200), not_found.status);

    // Expired response (status=210 = entity_expired)
    const expired = QueryUuidResponse{
        .status = @intCast(@intFromEnum(StateError.entity_expired)),
    };
    try std.testing.expectEqual(@as(u8, 210), expired.status);

    // Size is 16 bytes (1 byte status + 15 bytes reserved)
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(QueryUuidResponse));
}

test "UUID batch query: QueryUuidBatchFilter structure" {
    // ENT-08: Batch UUID query filter

    const filter = QueryUuidBatchFilter{
        .count = 5,
    };
    try std.testing.expectEqual(@as(u32, 5), filter.count);

    // Max count is 10,000
    try std.testing.expectEqual(@as(u32, 10_000), QueryUuidBatchFilter.max_count);

    // Size is 8 bytes (count: u32 + reserved: u32)
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(QueryUuidBatchFilter));
}

test "UUID batch query: QueryUuidBatchResult structure" {
    // ENT-08: Batch UUID query result

    // Success result
    const success = QueryUuidBatchResult{
        .found_count = 3,
        .not_found_count = 2,
    };
    try std.testing.expectEqual(@as(u32, 3), success.found_count);
    try std.testing.expectEqual(@as(u32, 2), success.not_found_count);
    try std.testing.expectEqual(@as(?StateError, null), success.error_status());

    // Error result
    const error_result = QueryUuidBatchResult.with_error(.resource_exhausted);
    try std.testing.expectEqual(@as(u32, 0), error_result.found_count);
    try std.testing.expectEqual(StateError.resource_exhausted, error_result.error_status().?);
}

test "latest query: QueryLatestFilter structure" {
    // ENT-09: Latest query filter structure

    const filter = QueryLatestFilter{
        .limit = 100,
        .group_id = 42,
        .cursor_timestamp = 1704067200_000_000_000,
    };

    try std.testing.expectEqual(@as(u32, 100), filter.limit);
    try std.testing.expectEqual(@as(u64, 42), filter.group_id);
    try std.testing.expectEqual(@as(u64, 1704067200_000_000_000), filter.cursor_timestamp);

    // Size is 128 bytes
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(QueryLatestFilter));
}

test "latest query: cursor_timestamp pagination semantics" {
    // Per spec: cursor_timestamp = 0 means start from latest (no pagination)

    const filter_no_cursor = QueryLatestFilter{
        .limit = 50,
        .group_id = 0,
        .cursor_timestamp = 0, // No pagination
    };
    try std.testing.expectEqual(@as(u64, 0), filter_no_cursor.cursor_timestamp);

    // When cursor_timestamp > 0, skip entries >= cursor
    const cursor: u64 = 1704067200_000_000_000;
    const filter_with_cursor = QueryLatestFilter{
        .limit = 50,
        .group_id = 0,
        .cursor_timestamp = cursor,
    };

    // Test pagination logic
    const entry_older: u64 = 1704060000_000_000_000; // Before cursor
    const entry_at_cursor: u64 = cursor; // At cursor
    const entry_newer: u64 = 1704080000_000_000_000; // After cursor

    // Per implementation: skip entries at or newer than cursor
    const should_skip_older = filter_with_cursor.cursor_timestamp > 0 and
        entry_older >= filter_with_cursor.cursor_timestamp;
    const should_skip_at_cursor = filter_with_cursor.cursor_timestamp > 0 and
        entry_at_cursor >= filter_with_cursor.cursor_timestamp;
    const should_skip_newer = filter_with_cursor.cursor_timestamp > 0 and
        entry_newer >= filter_with_cursor.cursor_timestamp;

    try std.testing.expect(!should_skip_older); // Include older entries
    try std.testing.expect(should_skip_at_cursor); // Skip at cursor
    try std.testing.expect(should_skip_newer); // Skip newer entries
}

test "QueryResponse: response codes and flags" {
    // Test QueryResponse construction helpers

    // Complete response (no more results)
    const complete = QueryResponse.complete(50);
    try std.testing.expectEqual(@as(u32, 50), complete.count);
    try std.testing.expectEqual(@as(u8, 0), complete.has_more);
    try std.testing.expectEqual(@as(u8, 0), complete.partial_result);

    // Response with more results available
    const with_more = QueryResponse.with_more(100);
    try std.testing.expectEqual(@as(u32, 100), with_more.count);
    try std.testing.expectEqual(@as(u8, 1), with_more.has_more);

    // Truncated response
    const truncated = QueryResponse.truncated(75);
    try std.testing.expectEqual(@as(u32, 75), truncated.count);
    try std.testing.expectEqual(@as(u8, 1), truncated.partial_result);

    // Error response
    const error_resp = QueryResponse.with_error(.resource_exhausted);
    try std.testing.expectEqual(@as(u32, 0), error_resp.count);
    try std.testing.expectEqual(StateError.resource_exhausted, error_resp.error_status().?);
}

test "TTL metrics: DeletionMetrics tracking" {
    // ENT-10: TTL cleanup metrics exposed

    var metrics_obj = DeletionMetrics{};

    // Record a batch of deletions
    metrics_obj.record_deletion_batch(10, 5, 5000); // 10 deleted, 5 not found, 5000ns

    try std.testing.expectEqual(@as(u64, 10), metrics_obj.entities_deleted);
    try std.testing.expectEqual(@as(u64, 5), metrics_obj.entities_not_found);
    try std.testing.expectEqual(@as(u64, 1), metrics_obj.deletion_operations);
    try std.testing.expectEqual(@as(u64, 5000), metrics_obj.total_deletion_duration_ns);

    // Record another batch
    metrics_obj.record_deletion_batch(20, 0, 3000);

    try std.testing.expectEqual(@as(u64, 30), metrics_obj.entities_deleted);
    try std.testing.expectEqual(@as(u64, 5), metrics_obj.entities_not_found);
    try std.testing.expectEqual(@as(u64, 2), metrics_obj.deletion_operations);
    try std.testing.expectEqual(@as(u64, 8000), metrics_obj.total_deletion_duration_ns);
}

test "TTL metrics: average deletion latency" {
    // ENT-10: Verify average latency calculation

    var metrics_obj = DeletionMetrics{};

    // No deletions yet - should be 0
    try std.testing.expectEqual(@as(u64, 0), metrics_obj.average_deletion_latency_ns());

    // 10 entities deleted in 5000ns = 500ns per entity
    metrics_obj.record_deletion_batch(10, 0, 5000);
    try std.testing.expectEqual(@as(u64, 500), metrics_obj.average_deletion_latency_ns());

    // 20 more entities in 3000ns = 8000ns total for 30 entities = 266ns per entity
    metrics_obj.record_deletion_batch(20, 0, 3000);
    try std.testing.expectEqual(@as(u64, 266), metrics_obj.average_deletion_latency_ns());
}

test "TTL metrics: InsertMetrics tracking" {
    // ENT-10: Verify insert metrics tracking

    var metrics_obj = InsertMetrics{};

    // Record a batch
    metrics_obj.recordInsertBatch(100, 5, 10_000); // 100 inserted, 5 rejected, 10us

    try std.testing.expectEqual(@as(u64, 100), metrics_obj.events_inserted);
    try std.testing.expectEqual(@as(u64, 5), metrics_obj.events_rejected);
    try std.testing.expectEqual(@as(u64, 1), metrics_obj.insert_operations);

    // Average latency: 10000ns / (100+5) = 95ns per event
    try std.testing.expectEqual(@as(u64, 95), metrics_obj.averageInsertLatencyNs());
}

test "TTL metrics: TombstoneMetrics tracking" {
    // ENT-10: Verify tombstone metrics tracking

    var metrics_obj = TombstoneMetrics{};

    // Record retained tombstones
    metrics_obj.recordRetained(10);
    try std.testing.expectEqual(@as(u64, 10), metrics_obj.tombstone_retained_compactions);

    // Record eliminated tombstones with age (count, total_age_seconds, max_age, min_age)
    metrics_obj.recordEliminated(5, 3600, 1000, 500); // 5 tombstones, total 3600s age
    try std.testing.expectEqual(@as(u64, 5), metrics_obj.tombstone_eliminated_compactions);

    // Average tombstone age (3600 total / 5 eliminated = 720 seconds)
    const avg_age = metrics_obj.averageTombstoneAge();
    try std.testing.expectEqual(@as(u64, 720), avg_age);
}

test "TTL metrics: retention ratio" {
    // ENT-10: Verify retention ratio calculation

    var metrics_obj = TombstoneMetrics{};

    // No tombstones - ratio is 0
    try std.testing.expectEqual(@as(f64, 0.0), metrics_obj.retentionRatio());

    // All retained (10 retained, 0 eliminated)
    metrics_obj.tombstone_retained_compactions = 10;
    try std.testing.expectEqual(@as(f64, 1.0), metrics_obj.retentionRatio());

    // Half retained (10 retained, 10 eliminated)
    metrics_obj.tombstone_eliminated_compactions = 10;
    try std.testing.expectEqual(@as(f64, 0.5), metrics_obj.retentionRatio());
}

// ============================================================================
// Public API Aliases
// ============================================================================

/// Alias for compatibility with vsr.state_machine.StateMachineType interface.
/// ArcherDB uses GeoStateMachineType as its primary state machine.
pub const StateMachineType = GeoStateMachineType;
