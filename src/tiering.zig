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
const assert = std.debug.assert;
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
    const Self = @This();

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
    pub fn init(allocator: Allocator, config: TieringConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .stats = .{},
            .metadata = std.AutoHashMap(u128, EntityTierMetadata).init(allocator),
            .hot_demotion_candidates = std.PriorityQueue(DemotionCandidate, void, demotionCompare).init(allocator, {}),
            .warm_demotion_candidates = std.PriorityQueue(DemotionCandidate, void, demotionCompare).init(allocator, {}),
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *Self) void {
        self.metadata.deinit();
        self.hot_demotion_candidates.deinit();
        self.warm_demotion_candidates.deinit();
    }

    /// Record an entity insert.
    /// New entities start in hot tier.
    pub fn recordInsert(self: *Self, entity_id: u128, current_time_ns: u64) !void {
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
    pub fn recordAccess(self: *Self, entity_id: u128, current_time_ns: u64) !?TierTransition {
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
    fn checkPromotion(self: *Self, entity_id: u128, meta: *EntityTierMetadata) !?TierTransition {
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
    fn promote(self: *Self, entity_id: u128, from_tier: Tier, to_tier: Tier) !TierTransition {
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
    pub fn tick(self: *Self, current_time_ns: u64) ![]TierTransition {
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
        self: *Self,
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
                        const transition = try self.demote(candidate.entity_id, from_tier, to_tier);
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
    fn demote(self: *Self, entity_id: u128, from_tier: Tier, to_tier: Tier) !TierTransition {
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
    fn enforceMaxLimits(self: *Self, current_time_ns: u64, transitions: *std.ArrayList(TierTransition)) !void {
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
    pub fn getTier(self: *const Self, entity_id: u128) Tier {
        if (self.metadata.get(entity_id)) |meta| {
            return meta.tier;
        }
        return .cold; // Unknown entities assumed cold.
    }

    /// Get metadata for an entity (if tracked).
    pub fn getMetadata(self: *const Self, entity_id: u128) ?EntityTierMetadata {
        return self.metadata.get(entity_id);
    }

    /// Get current statistics.
    pub fn getStats(self: *const Self) TierStats {
        return self.stats;
    }

    /// Check if entity is in RAM index (hot or warm tier).
    pub fn isInRamIndex(self: *const Self, entity_id: u128) bool {
        if (self.metadata.get(entity_id)) |meta| {
            return meta.tier == .hot or meta.tier == .warm;
        }
        return false;
    }

    /// Record entity deletion.
    pub fn recordDelete(self: *Self, entity_id: u128) void {
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
/// Provides methods for querying entities not in RAM index.
pub const ColdTierQueryHandler = struct {
    const Self = @This();

    allocator: Allocator,

    /// Statistics for cold tier queries.
    queries_executed: u64 = 0,
    total_scan_time_ns: u64 = 0,
    avg_scan_time_ns: u64 = 0,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Query cold tier entities by entity_id.
    /// Returns true if found, false if not found.
    /// Note: This requires full scan or secondary index lookup.
    pub fn queryById(self: *Self, entity_id: u128, _: u64) !?ColdTierResult {
        _ = entity_id;
        self.queries_executed += 1;

        // In a real implementation, this would:
        // 1. Check secondary indexes (if available)
        // 2. Fall back to full LSM scan if no secondary index
        // 3. Track scan time for metrics

        // Placeholder - actual implementation integrates with LSM tree.
        return null;
    }

    /// Query cold tier entities by time range.
    pub fn queryByTimeRange(self: *Self, _: u64, _: u64) ![]ColdTierResult {
        self.queries_executed += 1;

        // In a real implementation, this would scan LSM for events
        // within the time range.

        return &[_]ColdTierResult{};
    }
};

/// Result from cold tier query.
pub const ColdTierResult = struct {
    entity_id: u128,
    latest_id: u128,
    ttl_seconds: u32,
    /// True if entity should be promoted to warm tier.
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
