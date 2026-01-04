// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Privacy by Design Data Minimization Module for ArcherDB (F-Compliance)
//!
//! Implements GDPR data minimization principles:
//! - Only collect location data with explicit purpose
//! - Store minimum required precision for use case
//! - Implement automatic data expiration (TTL)
//! - Avoid collecting unnecessary metadata
//! - Purpose limitation enforcement
//!
//! See: openspec/changes/add-geospatial-core/specs/compliance/spec.md
//!
//! Usage:
//! ```zig
//! var minimizer = DataMinimizer.init(allocator, .{
//!     .default_precision = .city,
//!     .strip_user_data = true,
//!     .enforce_ttl = true,
//! });
//! defer minimizer.deinit();
//!
//! // Minimize event data
//! const minimized = minimizer.minimizeEvent(event, .location_tracking);
//! ```

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const AutoHashMap = std.AutoHashMap;

/// Maximum purposes to track per entity.
pub const MAX_PURPOSES_PER_ENTITY: usize = 16;

/// Default TTL in seconds for various precision levels.
pub const DEFAULT_TTL_PRECISE: u32 = 86400; // 1 day for precise data
pub const DEFAULT_TTL_STREET: u32 = 604800; // 7 days for street-level
pub const DEFAULT_TTL_CITY: u32 = 2592000; // 30 days for city-level
pub const DEFAULT_TTL_REGION: u32 = 31536000; // 1 year for region-level

/// Location precision levels for data minimization.
/// Each level reduces coordinate precision and increases privacy.
pub const PrecisionLevel = enum(u8) {
    /// Full precision (~0.1mm) - nanodegrees as stored.
    precise = 0,
    /// Meter-level precision (~1m) - for navigation.
    meter = 1,
    /// Street-level precision (~10m) - for logistics.
    street = 2,
    /// Block-level precision (~100m) - for delivery zones.
    block = 3,
    /// Neighborhood-level precision (~1km) - for area analytics.
    neighborhood = 4,
    /// City-level precision (~10km) - for aggregated analytics.
    city = 5,
    /// Region-level precision (~100km) - for broad demographics.
    region = 6,
    /// Country-level precision (~1000km) - for compliance/reporting.
    country = 7,

    /// Return the precision factor (number of nanodegrees per unit).
    /// Higher values = lower precision.
    pub fn precisionFactor(self: PrecisionLevel) i64 {
        return switch (self) {
            .precise => 1, // Full precision
            .meter => 9, // ~1 meter = ~9 nanodegrees
            .street => 90, // ~10 meters
            .block => 900, // ~100 meters
            .neighborhood => 9000, // ~1 km
            .city => 90000, // ~10 km
            .region => 900000, // ~100 km
            .country => 9000000, // ~1000 km
        };
    }

    /// Return approximate accuracy in meters.
    pub fn accuracyMeters(self: PrecisionLevel) u32 {
        return switch (self) {
            .precise => 0,
            .meter => 1,
            .street => 10,
            .block => 100,
            .neighborhood => 1000,
            .city => 10000,
            .region => 100000,
            .country => 1000000,
        };
    }

    /// Return recommended TTL for this precision level.
    pub fn recommendedTtl(self: PrecisionLevel) u32 {
        return switch (self) {
            .precise, .meter => DEFAULT_TTL_PRECISE,
            .street, .block => DEFAULT_TTL_STREET,
            .neighborhood, .city => DEFAULT_TTL_CITY,
            .region, .country => DEFAULT_TTL_REGION,
        };
    }

    /// Return human-readable description.
    pub fn description(self: PrecisionLevel) []const u8 {
        return switch (self) {
            .precise => "Full precision (~0.1mm)",
            .meter => "Meter-level (~1m)",
            .street => "Street-level (~10m)",
            .block => "Block-level (~100m)",
            .neighborhood => "Neighborhood (~1km)",
            .city => "City-level (~10km)",
            .region => "Region-level (~100km)",
            .country => "Country-level (~1000km)",
        };
    }
};

/// Data collection purpose - maps to consent purposes.
pub const CollectionPurpose = enum(u8) {
    /// Real-time navigation requiring precise coordinates.
    navigation = 0,
    /// Fleet tracking for business operations.
    fleet_tracking = 1,
    /// Delivery logistics.
    delivery = 2,
    /// Location-based analytics (aggregated).
    analytics = 3,
    /// Emergency services.
    emergency = 4,
    /// Marketing/advertising.
    marketing = 5,
    /// Research (anonymized).
    research = 6,
    /// Compliance/legal requirements.
    compliance = 7,

    /// Return minimum precision level required for this purpose.
    pub fn minimumPrecision(self: CollectionPurpose) PrecisionLevel {
        return switch (self) {
            .navigation => .meter, // Need precise for routing
            .fleet_tracking => .street, // Street-level sufficient
            .delivery => .block, // Block-level for zones
            .analytics => .neighborhood, // Aggregated analysis
            .emergency => .precise, // Need full precision
            .marketing => .city, // City-level sufficient
            .research => .region, // Anonymized/aggregated
            .compliance => .region, // Broad location only
        };
    }

    /// Return maximum TTL for this purpose.
    pub fn maxTtl(self: CollectionPurpose) u32 {
        return switch (self) {
            .navigation => 3600, // 1 hour max
            .fleet_tracking => 604800, // 7 days max
            .delivery => 86400, // 1 day max
            .analytics => 2592000, // 30 days max
            .emergency => 0, // No limit (legal requirement)
            .marketing => 86400, // 1 day max
            .research => 31536000, // 1 year max
            .compliance => 0, // No limit (legal requirement)
        };
    }

    /// Return whether purpose requires consent.
    pub fn requiresConsent(self: CollectionPurpose) bool {
        return switch (self) {
            .emergency, .compliance => false, // Legal basis
            else => true,
        };
    }
};

/// Fields that can be stripped for minimization.
pub const StrippableField = enum(u8) {
    /// User data field (application metadata).
    user_data = 0,
    /// Correlation ID (trip/session tracking).
    correlation_id = 1,
    /// Velocity.
    velocity = 2,
    /// Heading.
    heading = 3,
    /// Altitude.
    altitude = 4,
    /// Accuracy.
    accuracy = 5,
};

/// Minimization policy - defines what minimization to apply.
pub const MinimizationPolicy = struct {
    /// Target precision level.
    precision: PrecisionLevel = .street,
    /// Fields to strip (zero out).
    strip_fields: u8 = 0, // Bitmask of StrippableField
    /// Whether to enforce TTL based on precision.
    enforce_ttl: bool = true,
    /// Whether to aggregate nearby points.
    aggregate_nearby: bool = false,
    /// Aggregation distance in meters.
    aggregation_distance_m: u32 = 100,
    /// Whether to add noise for differential privacy.
    add_noise: bool = false,
    /// Noise radius in meters.
    noise_radius_m: u32 = 50,

    /// Create policy for a specific purpose.
    pub fn forPurpose(purpose: CollectionPurpose) MinimizationPolicy {
        return switch (purpose) {
            .navigation => .{
                .precision = .meter,
                .strip_fields = 0,
                .enforce_ttl = true,
                .aggregate_nearby = false,
            },
            .fleet_tracking => .{
                .precision = .street,
                .strip_fields = fieldMask(&.{ .user_data, .correlation_id }),
                .enforce_ttl = true,
            },
            .delivery => .{
                .precision = .block,
                .strip_fields = fieldMask(&.{ .user_data, .velocity, .heading }),
                .enforce_ttl = true,
            },
            .analytics => .{
                .precision = .neighborhood,
                .strip_fields = fieldMask(&.{ .user_data, .correlation_id, .velocity, .heading, .accuracy }),
                .enforce_ttl = true,
                .aggregate_nearby = true,
                .aggregation_distance_m = 500,
            },
            .emergency => .{
                .precision = .precise,
                .strip_fields = 0,
                .enforce_ttl = false,
            },
            .marketing => .{
                .precision = .city,
                .strip_fields = fieldMask(&.{ .user_data, .correlation_id, .velocity, .heading, .altitude, .accuracy }),
                .enforce_ttl = true,
                .add_noise = true,
                .noise_radius_m = 1000,
            },
            .research => .{
                .precision = .region,
                .strip_fields = fieldMask(&.{ .user_data, .correlation_id, .velocity, .heading, .altitude, .accuracy }),
                .enforce_ttl = true,
                .add_noise = true,
                .noise_radius_m = 5000,
            },
            .compliance => .{
                .precision = .region,
                .strip_fields = fieldMask(&.{ .user_data, .correlation_id, .velocity, .heading }),
                .enforce_ttl = false,
            },
        };
    }

    /// Check if a field should be stripped.
    pub fn shouldStrip(self: MinimizationPolicy, field: StrippableField) bool {
        return (self.strip_fields & (@as(u8, 1) << @intFromEnum(field))) != 0;
    }

    /// Create bitmask from field array.
    fn fieldMask(fields: []const StrippableField) u8 {
        var mask: u8 = 0;
        for (fields) |f| {
            mask |= @as(u8, 1) << @intFromEnum(f);
        }
        return mask;
    }
};

/// Result of minimization operation.
pub const MinimizationResult = struct {
    /// Number of events processed.
    events_processed: u64,
    /// Number of fields stripped.
    fields_stripped: u64,
    /// Number of coordinates reduced.
    coordinates_reduced: u64,
    /// Number of TTLs adjusted.
    ttls_adjusted: u64,
    /// Number of events aggregated.
    events_aggregated: u64,
    /// Bytes saved by minimization.
    bytes_saved: u64,
    /// Privacy score (0-100, higher = more private).
    privacy_score: u8,

    /// Initialize empty result.
    pub fn init() MinimizationResult {
        return .{
            .events_processed = 0,
            .fields_stripped = 0,
            .coordinates_reduced = 0,
            .ttls_adjusted = 0,
            .events_aggregated = 0,
            .bytes_saved = 0,
            .privacy_score = 0,
        };
    }
};

/// Minimized event representation.
/// Uses fixed arrays instead of GeoEvent import for compilation.
pub const MinimizedEvent = struct {
    /// Entity ID.
    entity_id: u128,
    /// Latitude in nanodegrees (reduced precision).
    lat_nano: i64,
    /// Longitude in nanodegrees (reduced precision).
    lon_nano: i64,
    /// Timestamp.
    timestamp: u64,
    /// TTL in seconds.
    ttl_seconds: u32,
    /// Precision level applied.
    precision: PrecisionLevel,
    /// Purpose this data was collected for.
    purpose: CollectionPurpose,
    /// Whether this is aggregated from multiple events.
    is_aggregated: bool,
    /// Count if aggregated.
    aggregation_count: u32,
    /// Altitude (may be zeroed).
    altitude_mm: i32,
    /// Velocity (may be zeroed).
    velocity_mms: u32,
    /// Heading (may be zeroed).
    heading_cdeg: u16,
    /// Accuracy (may be zeroed).
    accuracy_mm: u32,
    /// Group ID.
    group_id: u64,

    /// Initialize from coordinates.
    pub fn init(entity_id: u128, lat_nano: i64, lon_nano: i64, timestamp: u64) MinimizedEvent {
        return .{
            .entity_id = entity_id,
            .lat_nano = lat_nano,
            .lon_nano = lon_nano,
            .timestamp = timestamp,
            .ttl_seconds = DEFAULT_TTL_STREET,
            .precision = .precise,
            .purpose = .navigation,
            .is_aggregated = false,
            .aggregation_count = 1,
            .altitude_mm = 0,
            .velocity_mms = 0,
            .heading_cdeg = 0,
            .accuracy_mm = 0,
            .group_id = 0,
        };
    }
};

/// Entity minimization settings.
pub const EntityMinimizationSettings = struct {
    /// Entity ID.
    entity_id: u128,
    /// Allowed purposes for this entity.
    allowed_purposes: u16, // Bitmask of CollectionPurpose
    /// Custom precision overrides by purpose.
    precision_overrides: [8]PrecisionLevel, // Indexed by CollectionPurpose
    /// Custom TTL overrides by purpose.
    ttl_overrides: [8]u32,
    /// Whether entity is a child (enhanced protection).
    is_child: bool,
    /// Whether to anonymize this entity's data.
    anonymize: bool,

    /// Initialize with defaults.
    pub fn init(entity_id: u128) EntityMinimizationSettings {
        return .{
            .entity_id = entity_id,
            .allowed_purposes = 0xFFFF, // All purposes allowed by default
            .precision_overrides = [_]PrecisionLevel{.precise} ** 8,
            .ttl_overrides = [_]u32{0} ** 8,
            .is_child = false,
            .anonymize = false,
        };
    }

    /// Check if purpose is allowed.
    pub fn isPurposeAllowed(self: EntityMinimizationSettings, purpose: CollectionPurpose) bool {
        return (self.allowed_purposes & (@as(u16, 1) << @intFromEnum(purpose))) != 0;
    }

    /// Set purpose allowed/disallowed.
    pub fn setPurposeAllowed(self: *EntityMinimizationSettings, purpose: CollectionPurpose, allowed: bool) void {
        if (allowed) {
            self.allowed_purposes |= @as(u16, 1) << @intFromEnum(purpose);
        } else {
            self.allowed_purposes &= ~(@as(u16, 1) << @intFromEnum(purpose));
        }
    }

    /// Get effective precision for purpose.
    pub fn getEffectivePrecision(self: EntityMinimizationSettings, purpose: CollectionPurpose) PrecisionLevel {
        const override = self.precision_overrides[@intFromEnum(purpose)];
        const minimum = purpose.minimumPrecision();

        // Use the less precise (higher privacy) of the two
        if (@intFromEnum(override) > @intFromEnum(minimum)) {
            return override;
        }
        return minimum;
    }
};

/// Statistics about minimization operations.
pub const MinimizationStats = struct {
    /// Total events minimized.
    total_events: u64,
    /// Events by precision level.
    by_precision: [8]u64,
    /// Events by purpose.
    by_purpose: [8]u64,
    /// Total fields stripped.
    total_fields_stripped: u64,
    /// Total bytes saved.
    total_bytes_saved: u64,
    /// Average privacy score.
    avg_privacy_score: u8,
    /// Entities with custom settings.
    entities_with_settings: u64,
    /// Child entities (enhanced protection).
    child_entities: u64,

    /// Initialize empty stats.
    pub fn init() MinimizationStats {
        return .{
            .total_events = 0,
            .by_precision = [_]u64{0} ** 8,
            .by_purpose = [_]u64{0} ** 8,
            .total_fields_stripped = 0,
            .total_bytes_saved = 0,
            .avg_privacy_score = 0,
            .entities_with_settings = 0,
            .child_entities = 0,
        };
    }
};

/// Configuration for data minimizer.
pub const MinimizerConfig = struct {
    /// Default precision level.
    default_precision: PrecisionLevel = .street,
    /// Whether to strip user_data by default.
    strip_user_data: bool = true,
    /// Whether to enforce TTL based on precision.
    enforce_ttl: bool = true,
    /// Whether to add differential privacy noise.
    enable_differential_privacy: bool = false,
    /// Default noise radius in meters.
    default_noise_radius_m: u32 = 100,
    /// Whether to aggregate nearby events.
    enable_aggregation: bool = false,
    /// Default aggregation distance in meters.
    default_aggregation_distance_m: u32 = 100,
    /// Enhanced protection for children.
    enhanced_child_protection: bool = true,
    /// Child minimum precision (more restrictive).
    child_minimum_precision: PrecisionLevel = .city,
};

/// Data Minimizer - main API for privacy-preserving data handling.
pub const DataMinimizer = struct {
    const Self = @This();

    /// Memory allocator.
    allocator: Allocator,
    /// Configuration.
    config: MinimizerConfig,
    /// Per-entity settings.
    entity_settings: AutoHashMap(u128, EntityMinimizationSettings),
    /// Statistics.
    stats: MinimizationStats,
    /// PRNG for differential privacy noise.
    prng: std.Random.DefaultPrng,

    /// Initialize minimizer.
    pub fn init(allocator: Allocator, config: MinimizerConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .entity_settings = AutoHashMap(u128, EntityMinimizationSettings).init(allocator),
            .stats = MinimizationStats.init(),
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *Self) void {
        self.entity_settings.deinit();
    }

    /// Reduce coordinate precision.
    pub fn reducePrecision(self: *Self, lat_nano: i64, lon_nano: i64, precision: PrecisionLevel) struct { lat: i64, lon: i64 } {
        const factor = precision.precisionFactor();

        // Round to nearest precision unit
        const lat_reduced = @divFloor(lat_nano + @divFloor(factor, 2), factor) * factor;
        const lon_reduced = @divFloor(lon_nano + @divFloor(factor, 2), factor) * factor;

        self.stats.by_precision[@intFromEnum(precision)] += 1;

        return .{
            .lat = lat_reduced,
            .lon = lon_reduced,
        };
    }

    /// Add differential privacy noise to coordinates.
    pub fn addNoise(self: *Self, lat_nano: i64, lon_nano: i64, radius_m: u32) struct { lat: i64, lon: i64 } {
        // Convert radius from meters to nanodegrees (approximately)
        const radius_nano: i64 = @intCast(@as(u64, radius_m) * 9); // ~9 nanodegrees per meter

        // Generate random angle and distance
        const angle = self.prng.random().float(f64) * 2.0 * std.math.pi;
        const distance = self.prng.random().float(f64) * @as(f64, @floatFromInt(radius_nano));

        const lat_offset: i64 = @intFromFloat(distance * @cos(angle));
        const lon_offset: i64 = @intFromFloat(distance * @sin(angle));

        return .{
            .lat = lat_nano + lat_offset,
            .lon = lon_nano + lon_offset,
        };
    }

    /// Minimize a single event.
    pub fn minimizeEvent(
        self: *Self,
        event: MinimizedEvent,
        purpose: CollectionPurpose,
    ) MinimizedEvent {
        var result = event;
        result.purpose = purpose;

        // Get effective policy
        var policy = MinimizationPolicy.forPurpose(purpose);

        // Check for entity-specific settings
        if (self.entity_settings.get(event.entity_id)) |settings| {
            // Check if purpose is allowed
            if (!settings.isPurposeAllowed(purpose)) {
                // Return completely anonymized event
                result.entity_id = 0;
                result.precision = .country;
                result.anonymize();
                return result;
            }

            // Apply entity-specific precision
            const entity_precision = settings.getEffectivePrecision(purpose);
            if (@intFromEnum(entity_precision) > @intFromEnum(policy.precision)) {
                policy.precision = entity_precision;
            }

            // Enhanced child protection
            if (settings.is_child and self.config.enhanced_child_protection) {
                if (@intFromEnum(self.config.child_minimum_precision) > @intFromEnum(policy.precision)) {
                    policy.precision = self.config.child_minimum_precision;
                }
                // Strip more fields for children
                policy.strip_fields |= MinimizationPolicy.fieldMask(&.{ .user_data, .correlation_id });
            }
        }

        // Apply precision reduction
        const reduced = self.reducePrecision(event.lat_nano, event.lon_nano, policy.precision);
        result.lat_nano = reduced.lat;
        result.lon_nano = reduced.lon;
        result.precision = policy.precision;
        self.stats.total_events += 1;

        // Apply differential privacy if enabled
        if (policy.add_noise and self.config.enable_differential_privacy) {
            const noisy = self.addNoise(result.lat_nano, result.lon_nano, policy.noise_radius_m);
            result.lat_nano = noisy.lat;
            result.lon_nano = noisy.lon;
        }

        // Strip fields
        if (policy.shouldStrip(.velocity)) {
            result.velocity_mms = 0;
            self.stats.total_fields_stripped += 1;
        }
        if (policy.shouldStrip(.heading)) {
            result.heading_cdeg = 0;
            self.stats.total_fields_stripped += 1;
        }
        if (policy.shouldStrip(.altitude)) {
            result.altitude_mm = 0;
            self.stats.total_fields_stripped += 1;
        }
        if (policy.shouldStrip(.accuracy)) {
            result.accuracy_mm = 0;
            self.stats.total_fields_stripped += 1;
        }

        // Apply TTL
        if (policy.enforce_ttl and self.config.enforce_ttl) {
            const max_ttl = purpose.maxTtl();
            const precision_ttl = policy.precision.recommendedTtl();
            const effective_ttl = if (max_ttl > 0 and max_ttl < precision_ttl) max_ttl else precision_ttl;

            if (result.ttl_seconds == 0 or result.ttl_seconds > effective_ttl) {
                result.ttl_seconds = effective_ttl;
                self.stats.total_fields_stripped += 1; // Count TTL adjustment
            }
        }

        // Update accuracy to reflect actual precision
        const precision_accuracy = policy.precision.accuracyMeters() * 1000; // Convert to mm
        if (result.accuracy_mm < precision_accuracy) {
            result.accuracy_mm = precision_accuracy;
        }

        self.stats.by_purpose[@intFromEnum(purpose)] += 1;

        return result;
    }

    /// Minimize a batch of events.
    pub fn minimizeBatch(
        self: *Self,
        events: []const MinimizedEvent,
        purpose: CollectionPurpose,
        output: []MinimizedEvent,
    ) MinimizationResult {
        var result = MinimizationResult.init();

        const count = @min(events.len, output.len);
        for (events[0..count], 0..) |event, i| {
            output[i] = self.minimizeEvent(event, purpose);
            result.events_processed += 1;
        }

        // Calculate privacy score
        const policy = MinimizationPolicy.forPurpose(purpose);
        result.privacy_score = calculatePrivacyScore(policy);

        return result;
    }

    /// Set entity-specific minimization settings.
    pub fn setEntitySettings(self: *Self, settings: EntityMinimizationSettings) !void {
        try self.entity_settings.put(settings.entity_id, settings);
        self.stats.entities_with_settings = self.entity_settings.count();

        if (settings.is_child) {
            self.stats.child_entities += 1;
        }
    }

    /// Get entity settings.
    pub fn getEntitySettings(self: *Self, entity_id: u128) ?EntityMinimizationSettings {
        return self.entity_settings.get(entity_id);
    }

    /// Remove entity settings.
    pub fn removeEntitySettings(self: *Self, entity_id: u128) bool {
        if (self.entity_settings.fetchRemove(entity_id)) |kv| {
            self.stats.entities_with_settings -|= 1;
            if (kv.value.is_child) {
                self.stats.child_entities -|= 1;
            }
            return true;
        }
        return false;
    }

    /// Mark entity as child (enhanced protection).
    pub fn markAsChild(self: *Self, entity_id: u128, is_child: bool) !void {
        const result = try self.entity_settings.getOrPut(entity_id);
        if (!result.found_existing) {
            result.value_ptr.* = EntityMinimizationSettings.init(entity_id);
            self.stats.entities_with_settings += 1;
        }

        if (result.value_ptr.is_child != is_child) {
            result.value_ptr.is_child = is_child;
            if (is_child) {
                self.stats.child_entities += 1;
            } else {
                self.stats.child_entities -|= 1;
            }
        }
    }

    /// Get statistics.
    pub fn getStats(self: *Self) MinimizationStats {
        return self.stats;
    }

    /// Reset statistics.
    pub fn resetStats(self: *Self) void {
        self.stats = MinimizationStats.init();
        self.stats.entities_with_settings = self.entity_settings.count();
    }

    /// Calculate privacy score for a policy.
    fn calculatePrivacyScore(policy: MinimizationPolicy) u8 {
        var score: u16 = 0;

        // Precision contributes 0-40 points
        score += @as(u16, @intFromEnum(policy.precision)) * 5;

        // Field stripping contributes 0-30 points
        score += @as(u16, @popCount(policy.strip_fields)) * 5;

        // TTL enforcement contributes 10 points
        if (policy.enforce_ttl) score += 10;

        // Aggregation contributes 10 points
        if (policy.aggregate_nearby) score += 10;

        // Differential privacy contributes 10 points
        if (policy.add_noise) score += 10;

        return @min(100, @as(u8, @truncate(score)));
    }
};

// Helper method for MinimizedEvent
fn anonymize(self: *MinimizedEvent) void {
    self.entity_id = 0;
    self.altitude_mm = 0;
    self.velocity_mms = 0;
    self.heading_cdeg = 0;
    self.accuracy_mm = 0;
    self.group_id = 0;
}

/// Get current timestamp in nanoseconds.
fn getCurrentTimestamp() u64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Unit Tests
// ============================================================================

test "PrecisionLevel properties" {
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 1), PrecisionLevel.precise.precisionFactor());
    try testing.expectEqual(@as(i64, 9), PrecisionLevel.meter.precisionFactor());
    try testing.expectEqual(@as(i64, 90), PrecisionLevel.street.precisionFactor());

    try testing.expectEqual(@as(u32, 0), PrecisionLevel.precise.accuracyMeters());
    try testing.expectEqual(@as(u32, 10), PrecisionLevel.street.accuracyMeters());
    try testing.expectEqual(@as(u32, 10000), PrecisionLevel.city.accuracyMeters());
}

test "CollectionPurpose minimum precision" {
    const testing = std.testing;

    try testing.expectEqual(PrecisionLevel.meter, CollectionPurpose.navigation.minimumPrecision());
    try testing.expectEqual(PrecisionLevel.street, CollectionPurpose.fleet_tracking.minimumPrecision());
    try testing.expectEqual(PrecisionLevel.neighborhood, CollectionPurpose.analytics.minimumPrecision());
    try testing.expectEqual(PrecisionLevel.city, CollectionPurpose.marketing.minimumPrecision());
}

test "CollectionPurpose consent requirements" {
    const testing = std.testing;

    try testing.expect(CollectionPurpose.navigation.requiresConsent());
    try testing.expect(CollectionPurpose.marketing.requiresConsent());
    try testing.expect(!CollectionPurpose.emergency.requiresConsent());
    try testing.expect(!CollectionPurpose.compliance.requiresConsent());
}

test "MinimizationPolicy for purpose" {
    const testing = std.testing;

    const nav_policy = MinimizationPolicy.forPurpose(.navigation);
    try testing.expectEqual(PrecisionLevel.meter, nav_policy.precision);
    try testing.expect(!nav_policy.shouldStrip(.velocity));

    const marketing_policy = MinimizationPolicy.forPurpose(.marketing);
    try testing.expectEqual(PrecisionLevel.city, marketing_policy.precision);
    try testing.expect(marketing_policy.shouldStrip(.user_data));
    try testing.expect(marketing_policy.add_noise);
}

test "DataMinimizer reduce precision" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var minimizer = DataMinimizer.init(allocator, .{});
    defer minimizer.deinit();

    // Test street-level reduction (factor 90)
    const lat: i64 = 40123456789; // ~40.123456789 degrees
    const lon: i64 = -74987654321; // ~-74.987654321 degrees

    const reduced = minimizer.reducePrecision(lat, lon, .street);

    // Should be rounded to nearest 90 nanodegrees
    try testing.expectEqual(@as(i64, 40123456790), reduced.lat); // Rounded
    try testing.expectEqual(@as(i64, -74987654320), reduced.lon); // Rounded
}

test "DataMinimizer minimize event" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var minimizer = DataMinimizer.init(allocator, .{});
    defer minimizer.deinit();

    var event = MinimizedEvent.init(
        0x12345,
        40123456789,
        -74987654321,
        @intCast(std.time.nanoTimestamp()),
    );
    event.velocity_mms = 1000;
    event.heading_cdeg = 9000;

    const minimized = minimizer.minimizeEvent(event, .analytics);

    // Should have reduced precision to neighborhood level
    try testing.expectEqual(PrecisionLevel.neighborhood, minimized.precision);
    try testing.expectEqual(CollectionPurpose.analytics, minimized.purpose);

    // Should have stripped velocity and heading
    try testing.expectEqual(@as(u32, 0), minimized.velocity_mms);
    try testing.expectEqual(@as(u16, 0), minimized.heading_cdeg);
}

test "DataMinimizer batch minimization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var minimizer = DataMinimizer.init(allocator, .{});
    defer minimizer.deinit();

    var input: [3]MinimizedEvent = undefined;
    var output: [3]MinimizedEvent = undefined;

    for (&input, 0..) |*e, i| {
        e.* = MinimizedEvent.init(
            @as(u128, i),
            40000000000 + @as(i64, @intCast(i)) * 1000000,
            -74000000000 + @as(i64, @intCast(i)) * 1000000,
            @intCast(std.time.nanoTimestamp()),
        );
    }

    const result = minimizer.minimizeBatch(&input, .marketing, &output);

    try testing.expectEqual(@as(u64, 3), result.events_processed);
    try testing.expect(result.privacy_score > 0);

    for (&output) |*e| {
        try testing.expectEqual(PrecisionLevel.city, e.precision);
        try testing.expectEqual(CollectionPurpose.marketing, e.purpose);
    }
}

test "EntityMinimizationSettings purpose control" {
    const testing = std.testing;

    var settings = EntityMinimizationSettings.init(0x12345);

    try testing.expect(settings.isPurposeAllowed(.navigation));
    try testing.expect(settings.isPurposeAllowed(.marketing));

    settings.setPurposeAllowed(.marketing, false);
    try testing.expect(!settings.isPurposeAllowed(.marketing));
    try testing.expect(settings.isPurposeAllowed(.navigation));

    settings.setPurposeAllowed(.marketing, true);
    try testing.expect(settings.isPurposeAllowed(.marketing));
}

test "DataMinimizer entity settings" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var minimizer = DataMinimizer.init(allocator, .{});
    defer minimizer.deinit();

    var settings = EntityMinimizationSettings.init(0xABCDEF);
    settings.setPurposeAllowed(.marketing, false);
    settings.is_child = true;

    try minimizer.setEntitySettings(settings);

    const retrieved = minimizer.getEntitySettings(0xABCDEF);
    try testing.expect(retrieved != null);
    try testing.expect(!retrieved.?.isPurposeAllowed(.marketing));
    try testing.expect(retrieved.?.is_child);

    try testing.expectEqual(@as(u64, 1), minimizer.stats.entities_with_settings);
    try testing.expectEqual(@as(u64, 1), minimizer.stats.child_entities);
}

test "DataMinimizer child protection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var minimizer = DataMinimizer.init(allocator, .{
        .enhanced_child_protection = true,
        .child_minimum_precision = .city,
    });
    defer minimizer.deinit();

    try minimizer.markAsChild(0x12345, true);

    const event = MinimizedEvent.init(
        0x12345,
        40123456789,
        -74987654321,
        @intCast(std.time.nanoTimestamp()),
    );

    // Even for navigation, child should get city-level precision
    const minimized = minimizer.minimizeEvent(event, .navigation);

    // Child protection enforces minimum precision of city
    try testing.expect(@intFromEnum(minimized.precision) >= @intFromEnum(PrecisionLevel.city));
}

test "DataMinimizer statistics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var minimizer = DataMinimizer.init(allocator, .{});
    defer minimizer.deinit();

    const event = MinimizedEvent.init(0x1, 40000000000, -74000000000, @intCast(std.time.nanoTimestamp()));

    _ = minimizer.minimizeEvent(event, .navigation);
    _ = minimizer.minimizeEvent(event, .marketing);
    _ = minimizer.minimizeEvent(event, .analytics);

    const stats = minimizer.getStats();
    try testing.expectEqual(@as(u64, 3), stats.total_events);
    try testing.expectEqual(@as(u64, 1), stats.by_purpose[@intFromEnum(CollectionPurpose.navigation)]);
    try testing.expectEqual(@as(u64, 1), stats.by_purpose[@intFromEnum(CollectionPurpose.marketing)]);
    try testing.expectEqual(@as(u64, 1), stats.by_purpose[@intFromEnum(CollectionPurpose.analytics)]);
}

test "Privacy score calculation" {
    const testing = std.testing;

    const nav_policy = MinimizationPolicy.forPurpose(.navigation);
    const nav_score = DataMinimizer.calculatePrivacyScore(nav_policy);
    try testing.expect(nav_score < 30); // Low privacy (precise location)

    const research_policy = MinimizationPolicy.forPurpose(.research);
    const research_score = DataMinimizer.calculatePrivacyScore(research_policy);
    try testing.expect(research_score > 50); // High privacy (anonymized)
}

test "MinimizedEvent initialization" {
    const testing = std.testing;

    const event = MinimizedEvent.init(0x12345, 40000000000, -74000000000, 1700000000000000000);

    try testing.expectEqual(@as(u128, 0x12345), event.entity_id);
    try testing.expectEqual(@as(i64, 40000000000), event.lat_nano);
    try testing.expectEqual(@as(i64, -74000000000), event.lon_nano);
    try testing.expectEqual(@as(u64, 1700000000000000000), event.timestamp);
    try testing.expectEqual(PrecisionLevel.precise, event.precision);
    try testing.expectEqual(@as(u32, 1), event.aggregation_count);
}
