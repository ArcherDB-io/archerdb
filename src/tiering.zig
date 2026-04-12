// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Hot-Warm-Cold Data Tiering for ArcherDB.
//!
//! Implements tiered storage for cost optimization at extreme scale:
//! - Hot: RAM index + NVMe SSD (recent/active entities)
//! - Warm: RAM index + SATA SSD (less active entities)
//! - Cold: No RAM index, disk-only (archived entities)
//!
//! Entities are automatically promoted/demoted between tiers based on
//! access patterns. Cold tier queries require full scan or secondary
//! index lookup, with higher latency acceptable for historical queries.
//!
//! See specs/hybrid-memory/spec.md for full requirements.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Storage tier classification.
/// Determines where entity data resides and its access characteristics.
pub const Tier = enum(u8) {
    /// Hot tier: RAM index + NVMe SSD.
    /// For recent/frequently accessed entities.
    /// Lowest latency, highest cost per byte.
    hot = 0,

    /// Warm tier: RAM index + SATA SSD.
    /// For moderately accessed entities.
    /// Medium latency, medium cost per byte.
    warm = 1,

    /// Cold tier: No RAM index, disk-only.
    /// For archived/rarely accessed entities.
    /// Higher latency (acceptable for historical queries), lowest cost.
    cold = 2,
};

/// Configuration for tier thresholds and timeouts.
pub const TieringConfig = struct {
    /// Inactivity timeout for hot -> warm demotion (nanoseconds).
    /// Default: 1 hour.
    hot_to_warm_timeout_ns: u64 = 3_600_000_000_000,

    /// Inactivity timeout for warm -> cold demotion (nanoseconds).
    /// Default: 24 hours.
    warm_to_cold_timeout_ns: u64 = 86_400_000_000_000,

    /// Access count threshold for cold -> warm promotion.
    /// Entity is promoted if accessed this many times within window.
    cold_to_warm_access_threshold: u32 = 3,

    /// Access count threshold for warm -> hot promotion.
    warm_to_hot_access_threshold: u32 = 10,

    /// Time window for counting access patterns (nanoseconds).
    /// Default: 1 hour.
    access_window_ns: u64 = 3_600_000_000_000,

    /// Maximum entities in hot tier (0 = unlimited).
    /// When exceeded, least recently accessed are demoted.
    max_hot_entities: u64 = 0,

    /// Maximum entities in warm tier (0 = unlimited).
    max_warm_entities: u64 = 0,

    /// Enable automatic tier management.
    auto_tiering_enabled: bool = true,
};

/// Entity access metadata for tiering decisions.
/// Stored in-memory for hot/warm entities, reconstructed on access for cold.
pub const EntityTierMetadata = struct {
    /// Current tier of the entity.
    tier: Tier = .hot,

    /// Last access timestamp (nanoseconds since epoch).
    last_access_ns: u64 = 0,

    /// Access count within current window.
    access_count: u32 = 0,

    /// Window start timestamp for access counting.
    window_start_ns: u64 = 0,

    /// Timestamp when entity was inserted.
    insert_time_ns: u64 = 0,

    /// Number of times entity has been promoted.
    promotion_count: u16 = 0,

    /// Number of times entity has been demoted.
    demotion_count: u16 = 0,
};

/// Statistics for tier monitoring.
pub const TierStats = struct {
    /// Entities in each tier.
    hot_count: u64 = 0,
    warm_count: u64 = 0,
    cold_count: u64 = 0,

    /// Total promotions by type.
    cold_to_warm_promotions: u64 = 0,
    warm_to_hot_promotions: u64 = 0,

    /// Total demotions by type.
    hot_to_warm_demotions: u64 = 0,
    warm_to_cold_demotions: u64 = 0,

    /// Cold tier queries (require full scan).
    cold_tier_queries: u64 = 0,

    /// Bytes in each tier (estimated).
    hot_bytes: u64 = 0,
    warm_bytes: u64 = 0,
    cold_bytes: u64 = 0,

    /// Calculate total entity count.
    pub fn totalEntities(self: TierStats) u64 {
        return self.hot_count + self.warm_count + self.cold_count;
    }

    /// Calculate hot tier percentage.
    pub fn hotPercentage(self: TierStats) f64 {
        const total = self.totalEntities();
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hot_count)) / @as(f64, @floatFromInt(total)) * 100.0;
    }

    /// Calculate estimated storage cost ratio (hot = 1.0, warm = 0.5, cold = 0.1).
    pub fn estimatedCostRatio(self: TierStats) f64 {
        const total = self.totalEntities();
        if (total == 0) return 0.0;
        const hot_weight: f64 = @as(f64, @floatFromInt(self.hot_count)) * 1.0;
        const warm_weight: f64 = @as(f64, @floatFromInt(self.warm_count)) * 0.5;
        const cold_weight: f64 = @as(f64, @floatFromInt(self.cold_count)) * 0.1;
        return (hot_weight + warm_weight + cold_weight) / @as(f64, @floatFromInt(total));
    }
};

/// Tiering Manager - manages entity tier assignments and transitions.
pub const TieringManager = struct {
    allocator: Allocator,
    config: TieringConfig,
    stats: TierStats,

    /// Metadata for tracked entities (hot and warm only).
    /// Cold entities have metadata reconstructed on access.
    metadata: std.AutoHashMap(u128, EntityTierMetadata),

    /// Priority queue for demotion candidates (by last_access_ns).
    /// Entries are entity_id values.
    hot_demotion_candidates: std.PriorityQueue(DemotionCandidate, void, demotionCompare),
    warm_demotion_candidates: std.PriorityQueue(DemotionCandidate, void, demotionCompare),

    const DemotionCandidate = struct {
        entity_id: u128,
        last_access_ns: u64,
    };

    fn demotionCompare(_: void, a: DemotionCandidate, b: DemotionCandidate) std.math.Order {
        // Min-heap: oldest access time first (smallest last_access_ns).
        return std.math.order(a.last_access_ns, b.last_access_ns);
    }

    /// Initialize tiering manager with configuration.
    pub fn init(allocator: Allocator, config: TieringConfig) TieringManager {
        return .{
            .allocator = allocator,
            .config = config,
            .stats = .{},
            .metadata = std.AutoHashMap(u128, EntityTierMetadata).init(allocator),
            .hot_demotion_candidates = std.PriorityQueue(
                DemotionCandidate,
                void,
                demotionCompare,
            ).init(allocator, {}),
            .warm_demotion_candidates = std.PriorityQueue(
                DemotionCandidate,
                void,
                demotionCompare,
            ).init(allocator, {}),
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *TieringManager) void {
        self.metadata.deinit();
        self.hot_demotion_candidates.deinit();
        self.warm_demotion_candidates.deinit();
    }

    /// Record an entity insert.
    /// New entities start in hot tier.
    pub fn recordInsert(self: *TieringManager, entity_id: u128, current_time_ns: u64) !void {
        const meta = EntityTierMetadata{
            .tier = .hot,
            .last_access_ns = current_time_ns,
            .access_count = 1,
            .window_start_ns = current_time_ns,
            .insert_time_ns = current_time_ns,
        };

        try self.metadata.put(entity_id, meta);
        self.stats.hot_count += 1;

        // Add to demotion candidates queue.
        try self.hot_demotion_candidates.add(.{
            .entity_id = entity_id,
            .last_access_ns = current_time_ns,
        });
    }

    /// Record an entity access.
    /// Updates access patterns and may trigger promotion.
    pub fn recordAccess(
        self: *TieringManager,
        entity_id: u128,
        current_time_ns: u64,
    ) !?TierTransition {
        if (self.metadata.getPtr(entity_id)) |meta| {
            // Update access metadata.
            meta.last_access_ns = current_time_ns;

            // Reset access count if window expired.
            if (current_time_ns - meta.window_start_ns > self.config.access_window_ns) {
                meta.access_count = 1;
                meta.window_start_ns = current_time_ns;
            } else {
                meta.access_count += 1;
            }

            // Check for promotion.
            if (!self.config.auto_tiering_enabled) return null;

            return try self.checkPromotion(entity_id, meta);
        } else {
            // Cold tier entity accessed - record and potentially promote.
            self.stats.cold_tier_queries += 1;

            const meta = EntityTierMetadata{
                .tier = .cold,
                .last_access_ns = current_time_ns,
                .access_count = 1,
                .window_start_ns = current_time_ns,
            };

            try self.metadata.put(entity_id, meta);

            // Cold -> warm promotion on first access (if threshold is 1).
            if (self.config.cold_to_warm_access_threshold <= 1) {
                return try self.promote(entity_id, .cold, .warm);
            }

            return null;
        }
    }

    /// Check if entity should be promoted based on access patterns.
    fn checkPromotion(
        self: *TieringManager,
        entity_id: u128,
        meta: *EntityTierMetadata,
    ) !?TierTransition {
        switch (meta.tier) {
            .cold => {
                if (meta.access_count >= self.config.cold_to_warm_access_threshold) {
                    return try self.promote(entity_id, .cold, .warm);
                }
            },
            .warm => {
                if (meta.access_count >= self.config.warm_to_hot_access_threshold) {
                    return try self.promote(entity_id, .warm, .hot);
                }
            },
            .hot => {
                // Already in highest tier.
            },
        }
        return null;
    }

    /// Promote entity to a higher tier.
    fn promote(
        self: *TieringManager,
        entity_id: u128,
        from_tier: Tier,
        to_tier: Tier,
    ) !TierTransition {
        if (self.metadata.getPtr(entity_id)) |meta| {
            meta.tier = to_tier;
            meta.promotion_count += 1;
            meta.access_count = 0; // Reset after promotion.
        }

        // Update stats.
        switch (from_tier) {
            .cold => {
                self.stats.cold_count -|= 1;
                switch (to_tier) {
                    .warm => {
                        self.stats.warm_count += 1;
                        self.stats.cold_to_warm_promotions += 1;
                    },
                    .hot => {
                        self.stats.hot_count += 1;
                    },
                    .cold => {},
                }
            },
            .warm => {
                self.stats.warm_count -|= 1;
                if (to_tier == .hot) {
                    self.stats.hot_count += 1;
                    self.stats.warm_to_hot_promotions += 1;
                }
            },
            .hot => {},
        }

        return TierTransition{
            .entity_id = entity_id,
            .from_tier = from_tier,
            .to_tier = to_tier,
            .transition_type = .promotion,
        };
    }

    /// Run periodic tier maintenance.
    /// Checks for entities that should be demoted due to inactivity.
    pub fn tick(self: *TieringManager, current_time_ns: u64) ![]TierTransition {
        if (!self.config.auto_tiering_enabled) return &[_]TierTransition{};

        var transitions = std.ArrayList(TierTransition).init(self.allocator);
        errdefer transitions.deinit();

        // Check hot -> warm demotions.
        try self.checkDemotions(
            &self.hot_demotion_candidates,
            .hot,
            .warm,
            self.config.hot_to_warm_timeout_ns,
            current_time_ns,
            &transitions,
        );

        // Check warm -> cold demotions.
        try self.checkDemotions(
            &self.warm_demotion_candidates,
            .warm,
            .cold,
            self.config.warm_to_cold_timeout_ns,
            current_time_ns,
            &transitions,
        );

        // Enforce max tier limits.
        try self.enforceMaxLimits(current_time_ns, &transitions);

        return transitions.toOwnedSlice();
    }

    /// Check and process demotions for a specific tier.
    fn checkDemotions(
        self: *TieringManager,
        queue: *std.PriorityQueue(DemotionCandidate, void, demotionCompare),
        from_tier: Tier,
        to_tier: Tier,
        timeout_ns: u64,
        current_time_ns: u64,
        transitions: *std.ArrayList(TierTransition),
    ) !void {
        while (queue.peek()) |candidate| {
            // Check if candidate has timed out.
            if (current_time_ns - candidate.last_access_ns < timeout_ns) {
                break; // No more expired candidates (queue is sorted).
            }

            _ = queue.remove();

            // Verify entity still exists and is in expected tier.
            if (self.metadata.getPtr(candidate.entity_id)) |meta| {
                if (meta.tier == from_tier) {
                    // Check if entity was accessed since being queued.
                    if (meta.last_access_ns <= candidate.last_access_ns) {
                        const transition = try self.demote(
                            candidate.entity_id,
                            from_tier,
                            to_tier,
                        );
                        try transitions.append(transition);
                    } else {
                        // Re-queue with updated access time.
                        try queue.add(.{
                            .entity_id = candidate.entity_id,
                            .last_access_ns = meta.last_access_ns,
                        });
                    }
                }
            }
        }
    }

    /// Demote entity to a lower tier.
    fn demote(
        self: *TieringManager,
        entity_id: u128,
        from_tier: Tier,
        to_tier: Tier,
    ) !TierTransition {
        if (self.metadata.getPtr(entity_id)) |meta| {
            meta.tier = to_tier;
            meta.demotion_count += 1;
        }

        // Update stats.
        switch (from_tier) {
            .hot => {
                self.stats.hot_count -|= 1;
                if (to_tier == .warm) {
                    self.stats.warm_count += 1;
                    self.stats.hot_to_warm_demotions += 1;

                    // Add to warm demotion queue.
                    if (self.metadata.get(entity_id)) |meta| {
                        try self.warm_demotion_candidates.add(.{
                            .entity_id = entity_id,
                            .last_access_ns = meta.last_access_ns,
                        });
                    }
                } else if (to_tier == .cold) {
                    self.stats.cold_count += 1;
                }
            },
            .warm => {
                self.stats.warm_count -|= 1;
                if (to_tier == .cold) {
                    self.stats.cold_count += 1;
                    self.stats.warm_to_cold_demotions += 1;

                    // Remove from tracked metadata (cold tier not tracked).
                    _ = self.metadata.remove(entity_id);
                }
            },
            .cold => {},
        }

        return TierTransition{
            .entity_id = entity_id,
            .from_tier = from_tier,
            .to_tier = to_tier,
            .transition_type = .demotion,
        };
    }

    /// Enforce maximum tier limits by demoting excess entities.
    fn enforceMaxLimits(
        self: *TieringManager,
        current_time_ns: u64,
        transitions: *std.ArrayList(TierTransition),
    ) !void {
        _ = current_time_ns;

        // Check hot tier limit.
        if (self.config.max_hot_entities > 0) {
            while (self.stats.hot_count > self.config.max_hot_entities) {
                if (self.hot_demotion_candidates.removeOrNull()) |candidate| {
                    if (self.metadata.get(candidate.entity_id)) |meta| {
                        if (meta.tier == .hot) {
                            const transition = try self.demote(candidate.entity_id, .hot, .warm);
                            try transitions.append(transition);
                        }
                    }
                } else {
                    break;
                }
            }
        }

        // Check warm tier limit.
        if (self.config.max_warm_entities > 0) {
            while (self.stats.warm_count > self.config.max_warm_entities) {
                if (self.warm_demotion_candidates.removeOrNull()) |candidate| {
                    if (self.metadata.get(candidate.entity_id)) |meta| {
                        if (meta.tier == .warm) {
                            const transition = try self.demote(candidate.entity_id, .warm, .cold);
                            try transitions.append(transition);
                        }
                    }
                } else {
                    break;
                }
            }
        }
    }

    /// Get the current tier for an entity.
    pub fn getTier(self: *const TieringManager, entity_id: u128) Tier {
        if (self.metadata.get(entity_id)) |meta| {
            return meta.tier;
        }
        return .cold; // Unknown entities assumed cold.
    }

    /// Get metadata for an entity (if tracked).
    pub fn getMetadata(self: *const TieringManager, entity_id: u128) ?EntityTierMetadata {
        return self.metadata.get(entity_id);
    }

    /// Get current statistics.
    pub fn getStats(self: *const TieringManager) TierStats {
        return self.stats;
    }

    /// Check if entity is in RAM index (hot or warm tier).
    pub fn isInRamIndex(self: *const TieringManager, entity_id: u128) bool {
        if (self.metadata.get(entity_id)) |meta| {
            return meta.tier == .hot or meta.tier == .warm;
        }
        return false;
    }

    /// Look up a cold-tier entity by ID.
    ///
    /// Called as a fallback when the RAM index returns null and the entity
    /// may be in the cold tier (LSM-only). This method delegates to the
    /// ColdTierQueryHandler which handles the tiering bookkeeping.
    ///
    /// The `prefetch_found_timestamp` parameter should be set by the caller's
    /// prefetch phase (GeoStateMachine.drive_prefetch_scan). If the entity was
    /// found in the LSM entity_id index, the timestamp will be non-zero and the
    /// full GeoEvent will already be in the Forest cache.
    ///
    /// Returns a ColdTierResult if found, null if the entity does not exist.
    pub fn queryById(
        self: *TieringManager,
        entity_id: u128,
        prefetch_found_timestamp: u64,
    ) !?ColdTierResult {
        // Only attempt cold-tier lookup for entities not in RAM index.
        if (self.isInRamIndex(entity_id)) return null;

        var handler = ColdTierQueryHandler{
            .allocator = self.allocator,
            .tiering_manager = self,
        };
        return handler.queryById(entity_id, prefetch_found_timestamp);
    }

    /// Scan for cold-tier entities within a timestamp range.
    ///
    /// Returns entities whose temporal metadata falls within [min_ts, max_ts].
    /// This is a best-effort scan based on tracked metadata. Full LSM scans
    /// for cold-tier time-range queries require async integration with the
    /// Forest scan_builder (see ColdTierQueryHandler.queryByTimeRange docs).
    ///
    /// The caller is responsible for freeing the returned slice.
    pub fn queryByTimeRange(
        self: *TieringManager,
        min_ts: u64,
        max_ts: u64,
    ) ![]ColdTierResult {
        var handler = ColdTierQueryHandler{
            .allocator = self.allocator,
            .tiering_manager = self,
        };
        return handler.queryByTimeRange(min_ts, max_ts);
    }

    /// Record entity deletion.
    pub fn recordDelete(self: *TieringManager, entity_id: u128) void {
        if (self.metadata.get(entity_id)) |meta| {
            switch (meta.tier) {
                .hot => self.stats.hot_count -|= 1,
                .warm => self.stats.warm_count -|= 1,
                .cold => self.stats.cold_count -|= 1,
            }
        }
        _ = self.metadata.remove(entity_id);
    }
};

/// Represents a tier transition event.
pub const TierTransition = struct {
    entity_id: u128,
    from_tier: Tier,
    to_tier: Tier,
    transition_type: TransitionType,
};

/// Type of tier transition.
pub const TransitionType = enum {
    promotion,
    demotion,
};

/// Cold Tier Query Handler.
///
/// Provides methods for querying entities that have been demoted to the cold
/// tier (no RAM index entry). Cold-tier entities still exist in the LSM tree
/// and can be retrieved through the Forest's entity_id secondary index.
///
/// ## Architecture
///
/// The LSM lookup path in ArcherDB is inherently asynchronous:
///   1. Prefetch phase: Scan the entity_id secondary index to find the
///      latest timestamp for the entity, then enqueue that timestamp for
///      Forest prefetch (loads data into cache from disk).
///   2. Execute phase: Read the cached data synchronously via `get_by_timestamp`.
///
/// This handler integrates with the GeoStateMachine's existing prefetch/execute
/// pipeline. The `queryById` method is called during the execute phase AFTER
/// the prefetch scan has already been driven by the GeoStateMachine. It does
/// not perform its own I/O -- it relies on the caller having already prefetched
/// the relevant data.
///
/// ## Integration Points
///
/// - `GeoStateMachine.prefetch()`: Already drives an entity_id index scan when
///   the RAM index misses (lines 1795-1814 of geo_state_machine.zig). This
///   scan finds the latest timestamp and chains into Forest prefetch.
///
/// - `GeoStateMachine.execute_query_uuid()`: After prefetch, checks
///   `prefetch_found_timestamp` and uses `get_by_timestamp` to retrieve the
///   full GeoEvent from cache.
///
/// - `GeoStateMachine.execute_query_latest()`: Merges RAM-index results with
///   the async cold-tier prefetch scan so demoted entities can still appear in
///   latest-query results.
///
/// ## Limitations
///
/// - `queryById`: Works for point lookups via the existing prefetch pipeline.
///   The prefetch scan is triggered automatically when the RAM index misses.
///
/// - `queryByTimeRange`: Full cold-tier time-range scans are still best-effort.
///   Latest-query coverage is real, but broader cold-tier time-range scans still
///   depend on TieringManager metadata until the async LSM scan path is extended.
pub const ColdTierQueryHandler = struct {
    allocator: Allocator,
    tiering_manager: ?*TieringManager = null,

    /// Statistics for cold tier queries.
    queries_executed: u64 = 0,
    queries_by_id: u64 = 0,
    queries_by_time_range: u64 = 0,
    cache_hits: u64 = 0,
    total_scan_time_ns: u64 = 0,
    avg_scan_time_ns: u64 = 0,

    pub fn init(allocator: Allocator) ColdTierQueryHandler {
        return .{
            .allocator = allocator,
        };
    }

    /// Query a cold-tier entity by entity_id.
    ///
    /// This is called during the execute phase of a query_uuid operation,
    /// AFTER the GeoStateMachine's prefetch phase has already:
    ///   1. Detected the RAM index miss
    ///   2. Scanned the entity_id secondary index in the LSM tree
    ///   3. Found the latest timestamp for this entity (if it exists)
    ///   4. Prefetched the full GeoEvent into the Forest cache
    ///
    /// The caller (GeoStateMachine.execute_query_uuid) passes the
    /// `prefetch_found_timestamp` which was set during the prefetch scan.
    /// If the timestamp is non-zero, the entity was found in the LSM tree
    /// and is now cached. The caller then retrieves it via
    /// `forest.grooves.geo_events.get_by_timestamp()`.
    ///
    /// This method handles the tiering-specific bookkeeping:
    /// - Records the cold-tier query in statistics
    /// - Records the access in the TieringManager for promotion tracking
    /// - Returns a ColdTierResult with metadata for the caller
    ///
    /// Returns null if the entity is not found (prefetch_found_timestamp == 0),
    /// or a ColdTierResult with the entity metadata if found.
    pub fn queryById(
        self: *ColdTierQueryHandler,
        entity_id: u128,
        prefetch_found_timestamp: u64,
    ) !?ColdTierResult {
        self.queries_executed += 1;
        self.queries_by_id += 1;

        if (prefetch_found_timestamp == 0) {
            // Entity not found in LSM tree -- truly does not exist.
            return null;
        }

        // Entity was found by the prefetch scan. The GeoStateMachine has
        // already loaded it into the Forest cache via prefetch_enqueue_by_timestamp.
        self.cache_hits += 1;

        // Record access in tiering manager for promotion tracking.
        // Cold entities that are queried frequently should be promoted back
        // to warm tier so they appear in the RAM index again.
        if (self.tiering_manager) |tm| {
            _ = tm.recordAccess(entity_id, prefetch_found_timestamp) catch {};
        }

        // Determine if this entity should be promoted based on access patterns.
        const promote = if (self.tiering_manager) |tm| blk: {
            if (tm.metadata.get(entity_id)) |meta| {
                break :blk meta.access_count >= tm.config.cold_to_warm_access_threshold;
            }
            break :blk false;
        } else false;

        return ColdTierResult{
            .entity_id = entity_id,
            .latest_id = prefetch_found_timestamp, // timestamp from entity_id index
            .ttl_seconds = 0, // TTL checked by caller from the full GeoEvent
            .promote_recommended = promote,
        };
    }

    /// Scan for cold-tier entities within a timestamp range.
    ///
    /// Returns entity IDs that the TieringManager knows are in the cold tier
    /// and whose last-access timestamps fall within the given range. This is
    /// a best-effort result based on tracked metadata.
    ///
    /// ## Limitations
    ///
    /// A full cold-tier time-range query would require scanning the LSM object
    /// tree asynchronously, which does not fit into the current synchronous
    /// execute_query_latest loop. This implementation returns entities tracked
    /// by the TieringManager that were demoted to cold tier.
    ///
    /// TODO(WS-5): Integrate with Forest scan_builder to perform async LSM
    /// scans for cold-tier time-range queries. This requires:
    ///   1. Adding a cold-tier scan phase to the prefetch pipeline for
    ///      query_latest operations.
    ///   2. Using scan_builder.scan_prefix on the object tree with a
    ///      timestamp range filter.
    ///   3. Merging cold-tier results with the RAM index results in the
    ///      execute phase.
    ///
    /// For now, cold-tier entities that have been accessed at least once
    /// (and thus have TieringManager metadata) can be returned.
    pub fn queryByTimeRange(
        self: *ColdTierQueryHandler,
        min_ts: u64,
        max_ts: u64,
    ) ![]ColdTierResult {
        self.queries_executed += 1;
        self.queries_by_time_range += 1;

        // Collect cold-tier entities whose insert_time or last_access
        // falls within the requested range.
        var results = std.ArrayList(ColdTierResult).init(self.allocator);
        errdefer results.deinit();

        if (self.tiering_manager) |tm| {
            var iter = tm.metadata.iterator();
            while (iter.next()) |entry| {
                const meta = entry.value_ptr.*;
                if (meta.tier != .cold) continue;

                // Check if entity's temporal metadata overlaps the query range.
                // Use insert_time_ns as the primary temporal anchor, falling
                // back to last_access_ns if insert_time is not set.
                const entity_ts = if (meta.insert_time_ns > 0)
                    meta.insert_time_ns
                else
                    meta.last_access_ns;

                if (entity_ts >= min_ts and entity_ts <= max_ts) {
                    const entity_id = entry.key_ptr.*;
                    const promote = meta.access_count >= tm.config.cold_to_warm_access_threshold;

                    try results.append(ColdTierResult{
                        .entity_id = entity_id,
                        .latest_id = 0, // Unknown without LSM scan
                        .ttl_seconds = 0, // Unknown without LSM lookup
                        .promote_recommended = promote,
                    });
                }
            }
        }

        return results.toOwnedSlice();
    }
};

/// Result from cold tier query.
pub const ColdTierResult = struct {
    entity_id: u128,
    /// The latest composite ID (timestamp) from the entity_id index.
    /// Zero if unknown (e.g., from time-range metadata scan).
    latest_id: u128,
    /// TTL in seconds from the GeoEvent. Zero if not yet loaded.
    ttl_seconds: u32,
    /// True if the entity's access pattern suggests it should be promoted
    /// from cold to warm tier (back into the RAM index).
    promote_recommended: bool,
};

// =============================================================================
// Tests
// =============================================================================

test "TieringManager: basic insert and access" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{});
    defer manager.deinit();

    const entity_id: u128 = 12345;
    const now: u64 = 1_000_000_000_000; // 1 second

    // Insert entity - should be hot.
    try manager.recordInsert(entity_id, now);
    try std.testing.expectEqual(Tier.hot, manager.getTier(entity_id));
    try std.testing.expectEqual(@as(u64, 1), manager.stats.hot_count);

    // Access entity.
    _ = try manager.recordAccess(entity_id, now + 1_000_000_000);
    try std.testing.expectEqual(Tier.hot, manager.getTier(entity_id));
}

test "TieringManager: cold tier promotion" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .cold_to_warm_access_threshold = 2,
    });
    defer manager.deinit();

    const entity_id: u128 = 67890;
    const now: u64 = 1_000_000_000_000;

    // Access unknown entity (cold tier).
    _ = try manager.recordAccess(entity_id, now);
    try std.testing.expectEqual(Tier.cold, manager.getTier(entity_id));
    try std.testing.expectEqual(@as(u64, 1), manager.stats.cold_tier_queries);

    // Access again - should promote to warm.
    const transition = try manager.recordAccess(entity_id, now + 1_000_000);
    try std.testing.expect(transition != null);
    try std.testing.expectEqual(Tier.warm, transition.?.to_tier);
    try std.testing.expectEqual(TransitionType.promotion, transition.?.transition_type);
}

test "TieringManager: warm to hot promotion" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .cold_to_warm_access_threshold = 1,
        .warm_to_hot_access_threshold = 3,
    });
    defer manager.deinit();

    const entity_id: u128 = 11111;
    const now: u64 = 1_000_000_000_000;

    // Access cold -> warm.
    _ = try manager.recordAccess(entity_id, now);
    try std.testing.expectEqual(Tier.warm, manager.getTier(entity_id));

    // Access 2 more times to reach hot.
    _ = try manager.recordAccess(entity_id, now + 1_000_000);
    _ = try manager.recordAccess(entity_id, now + 2_000_000);
    const transition = try manager.recordAccess(entity_id, now + 3_000_000);

    try std.testing.expect(transition != null);
    try std.testing.expectEqual(Tier.hot, transition.?.to_tier);
}

test "TieringManager: hot to warm demotion" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .hot_to_warm_timeout_ns = 1_000_000_000, // 1 second
    });
    defer manager.deinit();

    const entity_id: u128 = 22222;
    const now: u64 = 1_000_000_000_000;

    // Insert entity.
    try manager.recordInsert(entity_id, now);
    try std.testing.expectEqual(Tier.hot, manager.getTier(entity_id));

    // Tick with time past timeout.
    const transitions = try manager.tick(now + 2_000_000_000);
    defer manager.allocator.free(transitions);

    try std.testing.expectEqual(@as(usize, 1), transitions.len);
    try std.testing.expectEqual(entity_id, transitions[0].entity_id);
    try std.testing.expectEqual(Tier.warm, transitions[0].to_tier);
    try std.testing.expectEqual(TransitionType.demotion, transitions[0].transition_type);
}

test "TieringManager: max tier limits" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .max_hot_entities = 2,
    });
    defer manager.deinit();

    const now: u64 = 1_000_000_000_000;

    // Insert 3 entities.
    try manager.recordInsert(1, now);
    try manager.recordInsert(2, now + 1_000_000);
    try manager.recordInsert(3, now + 2_000_000);

    try std.testing.expectEqual(@as(u64, 3), manager.stats.hot_count);

    // Tick to enforce limits.
    const transitions = try manager.tick(now + 3_000_000);
    defer manager.allocator.free(transitions);

    // One entity should be demoted.
    try std.testing.expectEqual(@as(usize, 1), transitions.len);
    try std.testing.expectEqual(@as(u64, 2), manager.stats.hot_count);
    try std.testing.expectEqual(@as(u64, 1), manager.stats.warm_count);
}

test "TierStats: calculations" {
    var stats = TierStats{
        .hot_count = 100,
        .warm_count = 300,
        .cold_count = 600,
    };

    try std.testing.expectEqual(@as(u64, 1000), stats.totalEntities());
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), stats.hotPercentage(), 0.01);

    // Cost ratio: (100*1.0 + 300*0.5 + 600*0.1) / 1000 = (100 + 150 + 60) / 1000 = 0.31
    try std.testing.expectApproxEqAbs(@as(f64, 0.31), stats.estimatedCostRatio(), 0.01);
}

test "TieringManager: delete tracking" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{});
    defer manager.deinit();

    const now: u64 = 1_000_000_000_000;

    try manager.recordInsert(1, now);
    try manager.recordInsert(2, now);
    try std.testing.expectEqual(@as(u64, 2), manager.stats.hot_count);

    manager.recordDelete(1);
    try std.testing.expectEqual(@as(u64, 1), manager.stats.hot_count);
    try std.testing.expectEqual(Tier.cold, manager.getTier(1));
}

test "TieringManager: access window reset" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .access_window_ns = 1_000_000_000, // 1 second
        .cold_to_warm_access_threshold = 3,
    });
    defer manager.deinit();

    const entity_id: u128 = 33333;
    const now: u64 = 1_000_000_000_000;

    // Access twice.
    _ = try manager.recordAccess(entity_id, now);
    _ = try manager.recordAccess(entity_id, now + 100_000_000);

    // Access after window expires - count should reset.
    _ = try manager.recordAccess(entity_id, now + 2_000_000_000);

    const meta = manager.getMetadata(entity_id).?;
    try std.testing.expectEqual(@as(u32, 1), meta.access_count);
}

// =============================================================================
// Integration Tests for Complete Tiering Flow
// =============================================================================

test "TieringManager: integration - insert starts in hot tier with RAM index" {
    // Verify that new entities start in hot tier and are in RAM index
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{});
    defer manager.deinit();

    const entity_id: u128 = 0xDEADBEEF_12345678_90ABCDEF_CAFEBABE;
    const now: u64 = 1_000_000_000_000;

    // Insert new entity
    try manager.recordInsert(entity_id, now);

    // Verify entity is in hot tier
    try std.testing.expectEqual(Tier.hot, manager.getTier(entity_id));

    // Verify entity is in RAM index (hot/warm = true)
    try std.testing.expect(manager.isInRamIndex(entity_id));

    // Verify stats
    try std.testing.expectEqual(@as(u64, 1), manager.stats.hot_count);
    try std.testing.expectEqual(@as(u64, 0), manager.stats.warm_count);
    try std.testing.expectEqual(@as(u64, 0), manager.stats.cold_count);
}

test "TieringManager: integration - inactivity demotion hot->warm->cold" {
    // Verify complete demotion flow from hot through warm to cold
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .hot_to_warm_timeout_ns = 1_000_000_000, // 1 second
        .warm_to_cold_timeout_ns = 2_000_000_000, // 2 seconds
    });
    defer manager.deinit();

    const entity_id: u128 = 44444;
    const now: u64 = 1_000_000_000_000;

    // Insert entity (hot tier)
    try manager.recordInsert(entity_id, now);
    try std.testing.expect(manager.isInRamIndex(entity_id));

    // Tick past hot->warm timeout
    const transitions1 = try manager.tick(now + 1_500_000_000);
    defer manager.allocator.free(transitions1);
    try std.testing.expectEqual(@as(usize, 1), transitions1.len);
    try std.testing.expectEqual(Tier.warm, manager.getTier(entity_id));
    try std.testing.expect(manager.isInRamIndex(entity_id)); // Still in RAM index

    // Tick past warm->cold timeout
    const transitions2 = try manager.tick(now + 4_000_000_000);
    defer manager.allocator.free(transitions2);
    try std.testing.expectEqual(@as(usize, 1), transitions2.len);
    try std.testing.expectEqual(Tier.cold, manager.getTier(entity_id));
    try std.testing.expect(!manager.isInRamIndex(entity_id)); // Removed from RAM index

    // Verify stats
    try std.testing.expectEqual(@as(u64, 0), manager.stats.hot_count);
    try std.testing.expectEqual(@as(u64, 0), manager.stats.warm_count);
    try std.testing.expectEqual(@as(u64, 1), manager.stats.cold_count);
    try std.testing.expectEqual(@as(u64, 1), manager.stats.hot_to_warm_demotions);
    try std.testing.expectEqual(@as(u64, 1), manager.stats.warm_to_cold_demotions);
}

test "TieringManager: integration - access pattern promotion cold->warm->hot" {
    // Verify complete promotion flow from cold through warm to hot
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .cold_to_warm_access_threshold = 2,
        .warm_to_hot_access_threshold = 3,
    });
    defer manager.deinit();

    const entity_id: u128 = 55555;
    const now: u64 = 1_000_000_000_000;

    // First access of unknown entity (starts in cold tier, tracked)
    _ = try manager.recordAccess(entity_id, now);
    try std.testing.expectEqual(Tier.cold, manager.getTier(entity_id));
    try std.testing.expect(!manager.isInRamIndex(entity_id));

    // Second access promotes to warm
    const transition1 = try manager.recordAccess(entity_id, now + 1_000_000);
    try std.testing.expect(transition1 != null);
    try std.testing.expectEqual(Tier.warm, transition1.?.to_tier);
    try std.testing.expect(manager.isInRamIndex(entity_id)); // Now in RAM index

    // Three more accesses to promote to hot
    _ = try manager.recordAccess(entity_id, now + 2_000_000);
    _ = try manager.recordAccess(entity_id, now + 3_000_000);
    const transition2 = try manager.recordAccess(entity_id, now + 4_000_000);
    try std.testing.expect(transition2 != null);
    try std.testing.expectEqual(Tier.hot, transition2.?.to_tier);

    // Verify stats
    try std.testing.expectEqual(@as(u64, 1), manager.stats.hot_count);
    try std.testing.expectEqual(@as(u64, 0), manager.stats.warm_count);
    try std.testing.expectEqual(@as(u64, 0), manager.stats.cold_count);
    try std.testing.expectEqual(@as(u64, 1), manager.stats.cold_to_warm_promotions);
    try std.testing.expectEqual(@as(u64, 1), manager.stats.warm_to_hot_promotions);
}

test "TieringManager: integration - tier limits enforcement" {
    // Verify max tier limits demote excess entities
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .max_hot_entities = 10,
        .max_warm_entities = 20,
    });
    defer manager.deinit();

    const now: u64 = 1_000_000_000_000;

    // Insert 15 entities (exceeds max_hot_entities of 10)
    for (0..15) |i| {
        try manager.recordInsert(@as(u128, @intCast(i + 1)), now + i * 1_000_000);
    }

    try std.testing.expectEqual(@as(u64, 15), manager.stats.hot_count);

    // Tick to enforce limits
    const transitions = try manager.tick(now + 100_000_000);
    defer manager.allocator.free(transitions);

    // 5 entities should be demoted to warm
    try std.testing.expectEqual(@as(usize, 5), transitions.len);
    try std.testing.expectEqual(@as(u64, 10), manager.stats.hot_count);
    try std.testing.expectEqual(@as(u64, 5), manager.stats.warm_count);
}

test "TieringManager: integration - cold tier query tracking" {
    // Verify cold tier queries are tracked correctly
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .cold_to_warm_access_threshold = 5, // High threshold to stay in cold
    });
    defer manager.deinit();

    const now: u64 = 1_000_000_000_000;

    // Access 10 unknown entities (all cold tier)
    for (0..10) |i| {
        _ = try manager.recordAccess(@as(u128, @intCast(i + 100)), now + i * 1_000);
    }

    // Verify cold tier queries tracked
    try std.testing.expectEqual(@as(u64, 10), manager.stats.cold_tier_queries);

    // All entities should still be cold (under threshold)
    for (0..10) |i| {
        try std.testing.expectEqual(Tier.cold, manager.getTier(@as(u128, @intCast(i + 100))));
    }
}

test "TieringManager: isInRamIndex for all tiers" {
    // Verify isInRamIndex returns correct values for each tier
    const allocator = std.testing.allocator;

    // Use very long warm->cold timeout so warm entities stay warm
    var manager = TieringManager.init(allocator, .{
        .hot_to_warm_timeout_ns = 1_000_000_000, // 1 second
        .warm_to_cold_timeout_ns = 100_000_000_000_000, // Very long (100k seconds)
        .cold_to_warm_access_threshold = 100, // High threshold to keep cold entity cold
    });
    defer manager.deinit();

    const hot_entity: u128 = 1;
    const warm_entity: u128 = 2;
    const cold_entity: u128 = 3;
    const now: u64 = 1_000_000_000_000;

    // Insert warm entity first (will be demoted to warm)
    try manager.recordInsert(warm_entity, now);

    // Insert hot entity later (fresh access time will keep it hot)
    try manager.recordInsert(hot_entity, now + 1_500_000_000);

    // Tick at later time - warm_entity times out to warm, hot_entity is fresh
    const transitions = try manager.tick(now + 2_000_000_000);
    defer manager.allocator.free(transitions);

    // Access unknown entity (cold) - stays cold with high threshold
    _ = try manager.recordAccess(cold_entity, now + 2_000_000_000);

    // Verify tiers
    try std.testing.expectEqual(Tier.hot, manager.getTier(hot_entity));
    try std.testing.expectEqual(Tier.warm, manager.getTier(warm_entity));
    try std.testing.expectEqual(Tier.cold, manager.getTier(cold_entity));

    // Verify isInRamIndex
    try std.testing.expect(manager.isInRamIndex(hot_entity)); // Hot = in RAM
    try std.testing.expect(manager.isInRamIndex(warm_entity)); // Warm = in RAM
    try std.testing.expect(!manager.isInRamIndex(cold_entity)); // Cold = NOT in RAM
}

test "TieringManager: cost ratio calculation" {
    // Verify cost ratio calculation for cost optimization monitoring
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .hot_to_warm_timeout_ns = 100_000_000, // 100ms
        .warm_to_cold_timeout_ns = 100_000_000, // 100ms
    });
    defer manager.deinit();

    const now: u64 = 1_000_000_000_000;

    // Insert 100 entities at same time
    for (0..100) |i| {
        try manager.recordInsert(@as(u128, @intCast(i + 1)), now);
    }

    // Access first 10 to keep them hot (update their access time)
    for (0..10) |i| {
        _ = try manager.recordAccess(@as(u128, @intCast(i + 1)), now + 150_000_000);
    }

    // Tick to demote the other 90 to warm (past hot timeout)
    const t1 = try manager.tick(now + 150_000_000);
    defer manager.allocator.free(t1);

    // Access 30 warm entities to prevent further demotion
    for (10..40) |i| {
        _ = try manager.recordAccess(@as(u128, @intCast(i + 1)), now + 300_000_000);
    }

    // Tick again to demote the remaining 60 warm entities to cold
    const t2 = try manager.tick(now + 300_000_000);
    defer manager.allocator.free(t2);

    // Verify cost ratio is between 0.1 (all cold) and 1.0 (all hot)
    const stats = manager.getStats();
    const cost_ratio = stats.estimatedCostRatio();
    try std.testing.expect(cost_ratio >= 0.1);
    try std.testing.expect(cost_ratio <= 1.0);
}

// =============================================================================
// Cold Tier Query Tests (WS-5)
// =============================================================================

test "ColdTierQueryHandler: queryById returns null for unknown entity" {
    const allocator = std.testing.allocator;

    var handler = ColdTierQueryHandler{
        .allocator = allocator,
        .tiering_manager = null,
    };

    // Entity not found (prefetch_found_timestamp == 0 means LSM scan found nothing)
    const result = try handler.queryById(0xDEAD, 0);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u64, 1), handler.queries_executed);
    try std.testing.expectEqual(@as(u64, 1), handler.queries_by_id);
}

test "ColdTierQueryHandler: queryById returns result for found entity" {
    const allocator = std.testing.allocator;

    var handler = ColdTierQueryHandler{
        .allocator = allocator,
        .tiering_manager = null,
    };

    const entity_id: u128 = 0xBEEF_CAFE;
    const found_timestamp: u64 = 42_000_000_000;

    // Entity found by prefetch scan (non-zero timestamp)
    const result = try handler.queryById(entity_id, found_timestamp);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(entity_id, result.?.entity_id);
    try std.testing.expectEqual(@as(u128, found_timestamp), result.?.latest_id);
    try std.testing.expectEqual(@as(u64, 1), handler.cache_hits);
}

test "ColdTierQueryHandler: queryById with tiering manager records access" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .cold_to_warm_access_threshold = 5, // High threshold to stay cold
    });
    defer manager.deinit();

    var handler = ColdTierQueryHandler{
        .allocator = allocator,
        .tiering_manager = &manager,
    };

    const entity_id: u128 = 0x1234;
    const timestamp: u64 = 100_000_000_000;

    // First query - entity found in LSM, access count starts at 1
    const result1 = try handler.queryById(entity_id, timestamp);
    try std.testing.expect(result1 != null);
    try std.testing.expect(!result1.?.promote_recommended); // under threshold (1 < 5)

    // Verify tiering manager now tracks this entity as cold
    try std.testing.expectEqual(Tier.cold, manager.getTier(entity_id));
    try std.testing.expectEqual(@as(u64, 1), manager.stats.cold_tier_queries);

    // Second query - access count increases
    const result2 = try handler.queryById(entity_id, timestamp);
    try std.testing.expect(result2 != null);
    try std.testing.expect(!result2.?.promote_recommended); // still under threshold (2 < 5)

    // Verify access count increased (2 calls to queryById = 2 calls to recordAccess)
    const meta = manager.getMetadata(entity_id).?;
    try std.testing.expectEqual(@as(u32, 2), meta.access_count);
    try std.testing.expectEqual(Tier.cold, meta.tier); // still cold
}

test "TieringManager: queryById delegates to ColdTierQueryHandler" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{});
    defer manager.deinit();

    const entity_id: u128 = 0xABCD;

    // Entity not tracked = assumed cold. queryById with zero timestamp = not found.
    const result_not_found = try manager.queryById(entity_id, 0);
    try std.testing.expect(result_not_found == null);

    // Entity found in LSM (non-zero timestamp)
    const result_found = try manager.queryById(entity_id, 999);
    try std.testing.expect(result_found != null);
    try std.testing.expectEqual(entity_id, result_found.?.entity_id);
}

test "TieringManager: queryById skips entities in RAM index" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{});
    defer manager.deinit();

    const entity_id: u128 = 0x5678;
    const now: u64 = 1_000_000_000_000;

    // Insert entity (hot tier, in RAM index)
    try manager.recordInsert(entity_id, now);
    try std.testing.expect(manager.isInRamIndex(entity_id));

    // queryById should return null for entities already in RAM index
    // (they don't need cold-tier lookup)
    const result = try manager.queryById(entity_id, 42);
    try std.testing.expect(result == null);
}

test "TieringManager: queryByTimeRange returns cold entities in range" {
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .hot_to_warm_timeout_ns = 100_000_000, // 100ms
        .warm_to_cold_timeout_ns = 100_000_000, // 100ms
        .cold_to_warm_access_threshold = 100, // High threshold to keep cold
    });
    defer manager.deinit();

    const now: u64 = 1_000_000_000_000; // 1000 seconds

    // Insert entities at different times
    try manager.recordInsert(1, now);
    try manager.recordInsert(2, now + 500_000_000_000);
    try manager.recordInsert(3, now + 1_000_000_000_000);

    // Demote all to warm, then cold
    const t1 = try manager.tick(now + 1_500_000_000_000);
    defer manager.allocator.free(t1);
    const t2 = try manager.tick(now + 2_000_000_000_000);
    defer manager.allocator.free(t2);

    // All should be cold now
    try std.testing.expectEqual(Tier.cold, manager.getTier(1));
    try std.testing.expectEqual(Tier.cold, manager.getTier(2));
    try std.testing.expectEqual(Tier.cold, manager.getTier(3));

    // Query for entities - but cold entities have metadata removed (line 442 of demote),
    // so queryByTimeRange can only find entities that have been re-accessed.

    // Re-access entity 2 to give it metadata back
    _ = try manager.recordAccess(2, now + 2_100_000_000_000);

    // Query time range that covers entity 2's last access time
    const results = try manager.queryByTimeRange(
        now + 2_000_000_000_000,
        now + 2_200_000_000_000,
    );
    defer manager.allocator.free(results);

    // Entity 2 should be found (it has metadata with last_access in range)
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u128, 2), results[0].entity_id);
}

test "TieringManager: cold-tier insert-demote-query round trip" {
    // Integration test: Insert entity, demote to cold, verify queryById works
    const allocator = std.testing.allocator;

    var manager = TieringManager.init(allocator, .{
        .hot_to_warm_timeout_ns = 1_000_000_000, // 1 second
        .warm_to_cold_timeout_ns = 2_000_000_000, // 2 seconds
    });
    defer manager.deinit();

    const entity_id: u128 = 0xFEED_FACE;
    const now: u64 = 1_000_000_000_000;

    // 1. Insert entity (starts in hot tier)
    try manager.recordInsert(entity_id, now);
    try std.testing.expectEqual(Tier.hot, manager.getTier(entity_id));
    try std.testing.expect(manager.isInRamIndex(entity_id));

    // 2. Demote to warm (past hot timeout but within warm timeout)
    const t1 = try manager.tick(now + 1_500_000_000);
    defer manager.allocator.free(t1);
    try std.testing.expectEqual(@as(usize, 1), t1.len);
    try std.testing.expectEqual(Tier.warm, manager.getTier(entity_id));

    // 3. Demote to cold (past warm timeout)
    const t2 = try manager.tick(now + 4_000_000_000);
    defer manager.allocator.free(t2);
    try std.testing.expectEqual(@as(usize, 1), t2.len);
    try std.testing.expectEqual(Tier.cold, manager.getTier(entity_id));
    try std.testing.expect(!manager.isInRamIndex(entity_id));

    // 4. Query by ID - simulating that prefetch scan found the entity in LSM
    // (in real usage, GeoStateMachine.prefetch would have set prefetch_found_timestamp)
    const fake_lsm_timestamp: u64 = now; // The entity's timestamp in the LSM tree
    const result = try manager.queryById(entity_id, fake_lsm_timestamp);

    // 5. Verify entity is returned
    try std.testing.expect(result != null);
    try std.testing.expectEqual(entity_id, result.?.entity_id);
    try std.testing.expectEqual(@as(u128, fake_lsm_timestamp), result.?.latest_id);

    // 6. Verify access was recorded (promotion tracking)
    try std.testing.expectEqual(@as(u64, 1), manager.stats.cold_tier_queries);
}
