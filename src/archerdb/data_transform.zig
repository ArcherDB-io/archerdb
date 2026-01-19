// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Data Transformation Pipeline Module (F-Data-Portability)
//!
//! Provides configurable data transformation during import/export operations:
//! - Field name mapping and renaming
//! - Data type conversion and formatting
//! - Coordinate system transformation
//! - Unit conversion (meters to feet, etc.)
//! - Data enrichment and augmentation
//! - Filtering and data cleansing
//!
//! See: openspec/changes/add-geospatial-core/specs/data-portability/spec.md
//!
//! Usage:
//! ```zig
//! var pipeline = TransformPipeline.init(allocator);
//! defer pipeline.deinit();
//!
//! // Add transformations
//! try pipeline.addTransform(.{ .unit_conversion = .meters_to_feet });
//! try pipeline.addTransform(.{ .coordinate_transform = .wgs84_to_web_mercator });
//!
//! // Transform events
//! const transformed = try pipeline.transform(events);
//! ```

const std = @import("std");
const stdx = @import("stdx");
const mem = std.mem;
const Allocator = mem.Allocator;
const math = std.math;
const GeoEvent = @import("../geo_event.zig").GeoEvent;

// ============================================================================
// Unit Conversion Constants
// ============================================================================

/// Meters to feet conversion factor.
pub const METERS_TO_FEET: f64 = 3.28084;

/// Feet to meters conversion factor.
pub const FEET_TO_METERS: f64 = 0.3048;

/// Kilometers to miles conversion factor.
pub const KM_TO_MILES: f64 = 0.621371;

/// Miles to kilometers conversion factor.
pub const MILES_TO_KM: f64 = 1.60934;

/// Meters per second to km/h conversion factor.
pub const MPS_TO_KMH: f64 = 3.6;

/// km/h to meters per second conversion factor.
pub const KMH_TO_MPS: f64 = 1.0 / 3.6;

/// Meters per second to mph conversion factor.
pub const MPS_TO_MPH: f64 = 2.23694;

/// mph to meters per second conversion factor.
pub const MPH_TO_MPS: f64 = 0.44704;

/// Degrees to radians.
pub const DEG_TO_RAD: f64 = math.pi / 180.0;

/// Radians to degrees.
pub const RAD_TO_DEG: f64 = 180.0 / math.pi;

// ============================================================================
// Transformation Types
// ============================================================================

/// Unit conversion types.
pub const UnitConversion = enum {
    /// No conversion.
    none,
    /// Meters to feet.
    meters_to_feet,
    /// Feet to meters.
    feet_to_meters,
    /// Kilometers to miles.
    km_to_miles,
    /// Miles to kilometers.
    miles_to_km,
    /// m/s to km/h.
    mps_to_kmh,
    /// km/h to m/s.
    kmh_to_mps,
    /// m/s to mph.
    mps_to_mph,
    /// mph to m/s.
    mph_to_mps,
};

/// Coordinate reference system.
pub const CoordinateSystem = enum {
    /// WGS84 (EPSG:4326) - Default.
    wgs84,
    /// Web Mercator (EPSG:3857).
    web_mercator,
    /// NAD83 (EPSG:4269).
    nad83,
    /// ETRS89 (EPSG:4258).
    etrs89,
    /// GCJ-02 (Chinese coordinate system).
    gcj02,
    /// BD-09 (Baidu coordinate system).
    bd09,
};

/// Coordinate transformation types.
pub const CoordinateTransform = enum {
    /// No transformation.
    none,
    /// WGS84 to Web Mercator.
    wgs84_to_web_mercator,
    /// Web Mercator to WGS84.
    web_mercator_to_wgs84,
    /// WGS84 to GCJ-02 (China).
    wgs84_to_gcj02,
    /// GCJ-02 to WGS84.
    gcj02_to_wgs84,
    /// GCJ-02 to BD-09 (Baidu).
    gcj02_to_bd09,
    /// BD-09 to GCJ-02.
    bd09_to_gcj02,
};

/// Field to transform.
pub const TransformField = enum {
    /// Latitude field.
    latitude,
    /// Longitude field.
    longitude,
    /// Altitude field.
    altitude,
    /// Velocity field.
    velocity,
    /// Accuracy field.
    accuracy,
    /// Heading field.
    heading,
    /// Timestamp field.
    timestamp,
    /// All coordinates (lat, lon).
    coordinates,
    /// All fields.
    all,
};

/// Transformation operation type.
pub const TransformType = enum {
    /// Unit conversion.
    unit_conversion,
    /// Coordinate system transformation.
    coordinate_transform,
    /// Field value filtering.
    filter,
    /// Default value assignment.
    default_value,
    /// Value clamping.
    clamp,
    /// Mathematical operation.
    math_op,
    /// Timestamp adjustment.
    timestamp_adjust,
    /// Flag modification.
    flag_modify,
};

/// Filter operator.
pub const FilterOperator = enum {
    /// Equal.
    eq,
    /// Not equal.
    ne,
    /// Greater than.
    gt,
    /// Greater than or equal.
    gte,
    /// Less than.
    lt,
    /// Less than or equal.
    lte,
    /// Within range.
    in_range,
    /// Outside range.
    out_range,
    /// Is null/zero.
    is_null,
    /// Is not null/zero.
    is_not_null,
};

/// Mathematical operation.
pub const MathOp = enum {
    /// Add constant.
    add,
    /// Subtract constant.
    subtract,
    /// Multiply by constant.
    multiply,
    /// Divide by constant.
    divide,
    /// Round to nearest.
    round,
    /// Floor.
    floor,
    /// Ceiling.
    ceiling,
    /// Absolute value.
    abs,
    /// Negate.
    negate,
};

// ============================================================================
// Transformation Configuration
// ============================================================================

/// A single transformation step.
pub const Transform = struct {
    /// Transform type.
    transform_type: TransformType,
    /// Target field.
    field: TransformField = .all,
    /// Unit conversion (if applicable).
    unit_conversion: UnitConversion = .none,
    /// Coordinate transform (if applicable).
    coordinate_transform: CoordinateTransform = .none,
    /// Filter operator (if applicable).
    filter_op: FilterOperator = .eq,
    /// Math operation (if applicable).
    math_op: MathOp = .add,
    /// Numeric value (for operations).
    value: f64 = 0.0,
    /// Secondary value (for ranges).
    value2: f64 = 0.0,
    /// Flag name (for flag operations).
    flag_name: FlagName = .none,
    /// Flag value (for flag operations).
    flag_value: bool = false,
    /// Whether to skip event if transform fails.
    skip_on_failure: bool = false,
    /// Description of this transform.
    description: [128]u8 = [_]u8{0} ** 128,
    /// Description length.
    description_len: u8 = 0,

    /// Set description.
    pub fn setDescription(self: *Transform, desc: []const u8) void {
        const len = @min(desc.len, 127);
        stdx.copy_disjoint(.inexact, u8, self.description[0..len], desc[0..len]);
        self.description_len = @intCast(len);
    }
};

/// Flag names for flag operations.
pub const FlagName = enum {
    /// No flag.
    none,
    /// linked flag.
    linked,
    /// imported flag.
    imported,
    /// stationary flag.
    stationary,
    /// low_accuracy flag.
    low_accuracy,
    /// offline flag.
    offline,
    /// deleted flag.
    deleted,
};

// ============================================================================
// Transformation Pipeline
// ============================================================================

/// Pipeline configuration.
pub const PipelineConfig = struct {
    /// Maximum transforms in pipeline.
    max_transforms: usize = 100,
    /// Continue on transform error.
    continue_on_error: bool = true,
    /// Collect statistics.
    collect_stats: bool = true,
    /// Validate output.
    validate_output: bool = true,
};

/// Pipeline statistics.
pub const PipelineStats = struct {
    /// Events processed.
    events_processed: usize = 0,
    /// Events transformed successfully.
    events_succeeded: usize = 0,
    /// Events that failed transformation.
    events_failed: usize = 0,
    /// Events filtered out.
    events_filtered: usize = 0,
    /// Total transform operations.
    total_transforms: usize = 0,
    /// Transform errors.
    transform_errors: usize = 0,
    /// Processing time (nanoseconds).
    processing_time_ns: u64 = 0,

    /// Reset statistics.
    pub fn reset(self: *PipelineStats) void {
        self.* = .{};
    }

    /// Calculate success rate.
    pub fn successRate(self: *const PipelineStats) f64 {
        if (self.events_processed == 0) return 100.0;
        return (@as(f64, @floatFromInt(self.events_succeeded)) /
            @as(f64, @floatFromInt(self.events_processed))) * 100.0;
    }
};

/// Data transformation pipeline.
pub const TransformPipeline = struct {
    const MAX_TRANSFORMS = 100;

    allocator: Allocator,
    transforms: std.ArrayList(Transform),
    config: PipelineConfig,
    stats: PipelineStats,

    /// Initialize a transform pipeline.
    pub fn init(allocator: Allocator) TransformPipeline {
        return TransformPipeline.initWithConfig(allocator, .{});
    }

    /// Initialize with custom config.
    pub fn initWithConfig(allocator: Allocator, config: PipelineConfig) TransformPipeline {
        return .{
            .allocator = allocator,
            .transforms = std.ArrayList(Transform).init(allocator),
            .config = config,
            .stats = .{},
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *TransformPipeline) void {
        self.transforms.deinit();
    }

    /// Add a transformation to the pipeline.
    pub fn addTransform(self: *TransformPipeline, transform: Transform) !void {
        if (self.transforms.items.len >= MAX_TRANSFORMS) {
            return error.TooManyTransforms;
        }
        try self.transforms.append(transform);
    }

    /// Clear all transforms.
    pub fn clear(self: *TransformPipeline) void {
        self.transforms.clearRetainingCapacity();
        self.stats.reset();
    }

    /// Get transform count.
    pub fn transformCount(self: *const TransformPipeline) usize {
        return self.transforms.items.len;
    }

    /// Transform a single event.
    pub fn transformEvent(self: *TransformPipeline, event: *GeoEvent) !bool {
        const start_time = std.time.nanoTimestamp();
        defer {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            self.stats.processing_time_ns += elapsed;
        }

        self.stats.events_processed += 1;

        for (self.transforms.items) |transform| {
            self.stats.total_transforms += 1;

            const success = self.applyTransform(event, &transform);
            if (!success) {
                self.stats.transform_errors += 1;
                if (transform.skip_on_failure) {
                    self.stats.events_filtered += 1;
                    return false;
                }
                if (!self.config.continue_on_error) {
                    self.stats.events_failed += 1;
                    return error.TransformFailed;
                }
            }
        }

        // Validate output if configured
        if (self.config.validate_output) {
            if (!GeoEvent.validate_coordinates(event.lat_nano, event.lon_nano)) {
                self.stats.events_failed += 1;
                return false;
            }
        }

        self.stats.events_succeeded += 1;
        return true;
    }

    /// Transform a batch of events.
    pub fn transformBatch(self: *TransformPipeline, events: []GeoEvent) !TransformBatchResult {
        var succeeded: usize = 0;
        var failed: usize = 0;
        var filtered: usize = 0;

        for (events) |*event| {
            const result = self.transformEvent(event) catch {
                failed += 1;
                continue;
            };
            if (result) {
                succeeded += 1;
            } else {
                filtered += 1;
            }
        }

        return .{
            .total = events.len,
            .succeeded = succeeded,
            .failed = failed,
            .filtered = filtered,
        };
    }

    /// Apply a single transform to an event.
    fn applyTransform(
        self: *TransformPipeline,
        event: *GeoEvent,
        transform: *const Transform,
    ) bool {
        _ = self;
        switch (transform.transform_type) {
            .unit_conversion => return applyUnitConversion(event, transform),
            .coordinate_transform => return applyCoordinateTransform(event, transform),
            .filter => return applyFilter(event, transform),
            .default_value => return applyDefaultValue(event, transform),
            .clamp => return applyClamp(event, transform),
            .math_op => return applyMathOp(event, transform),
            .timestamp_adjust => return applyTimestampAdjust(event, transform),
            .flag_modify => return applyFlagModify(event, transform),
        }
    }

    /// Get pipeline statistics.
    pub fn getStats(self: *const TransformPipeline) PipelineStats {
        return self.stats;
    }

    /// Reset statistics.
    pub fn resetStats(self: *TransformPipeline) void {
        self.stats.reset();
    }
};

/// Result of batch transformation.
pub const TransformBatchResult = struct {
    /// Total events in batch.
    total: usize,
    /// Successfully transformed.
    succeeded: usize,
    /// Failed transformation.
    failed: usize,
    /// Filtered out.
    filtered: usize,
};

// ============================================================================
// Transform Implementations
// ============================================================================

/// Apply unit conversion.
fn applyUnitConversion(event: *GeoEvent, transform: *const Transform) bool {
    switch (transform.unit_conversion) {
        .none => return true,
        .meters_to_feet => {
            if (transform.field == .altitude or transform.field == .all) {
                event.altitude_mm = @intFromFloat(
                    @as(f64, @floatFromInt(event.altitude_mm)) * METERS_TO_FEET,
                );
            }
            if (transform.field == .accuracy or transform.field == .all) {
                event.accuracy_mm = @intFromFloat(
                    @as(f64, @floatFromInt(event.accuracy_mm)) * METERS_TO_FEET,
                );
            }
        },
        .feet_to_meters => {
            if (transform.field == .altitude or transform.field == .all) {
                event.altitude_mm = @intFromFloat(
                    @as(f64, @floatFromInt(event.altitude_mm)) * FEET_TO_METERS,
                );
            }
            if (transform.field == .accuracy or transform.field == .all) {
                event.accuracy_mm = @intFromFloat(
                    @as(f64, @floatFromInt(event.accuracy_mm)) * FEET_TO_METERS,
                );
            }
        },
        .mps_to_kmh => {
            if (transform.field == .velocity or transform.field == .all) {
                event.velocity_mms = @intFromFloat(
                    @as(f64, @floatFromInt(event.velocity_mms)) * MPS_TO_KMH,
                );
            }
        },
        .kmh_to_mps => {
            if (transform.field == .velocity or transform.field == .all) {
                event.velocity_mms = @intFromFloat(
                    @as(f64, @floatFromInt(event.velocity_mms)) * KMH_TO_MPS,
                );
            }
        },
        .mps_to_mph => {
            if (transform.field == .velocity or transform.field == .all) {
                event.velocity_mms = @intFromFloat(
                    @as(f64, @floatFromInt(event.velocity_mms)) * MPS_TO_MPH,
                );
            }
        },
        .mph_to_mps => {
            if (transform.field == .velocity or transform.field == .all) {
                event.velocity_mms = @intFromFloat(
                    @as(f64, @floatFromInt(event.velocity_mms)) * MPH_TO_MPS,
                );
            }
        },
        else => {},
    }
    return true;
}

/// Apply coordinate transformation.
fn applyCoordinateTransform(event: *GeoEvent, transform: *const Transform) bool {
    const lat = GeoEvent.lat_to_float(event.lat_nano);
    const lon = GeoEvent.lon_to_float(event.lon_nano);

    var new_lat = lat;
    var new_lon = lon;

    switch (transform.coordinate_transform) {
        .none => return true,
        .wgs84_to_gcj02 => {
            const result = wgs84ToGcj02(lat, lon);
            new_lat = result.lat;
            new_lon = result.lon;
        },
        .gcj02_to_wgs84 => {
            const result = gcj02ToWgs84(lat, lon);
            new_lat = result.lat;
            new_lon = result.lon;
        },
        .gcj02_to_bd09 => {
            const result = gcj02ToBd09(lat, lon);
            new_lat = result.lat;
            new_lon = result.lon;
        },
        .bd09_to_gcj02 => {
            const result = bd09ToGcj02(lat, lon);
            new_lat = result.lat;
            new_lon = result.lon;
        },
        .wgs84_to_web_mercator, .web_mercator_to_wgs84 => {
            // Web Mercator is a projection, not suitable for storage
            // Events should stay in WGS84
            return true;
        },
    }

    event.lat_nano = GeoEvent.lat_from_float(new_lat);
    event.lon_nano = GeoEvent.lon_from_float(new_lon);

    return true;
}

/// Apply filter.
fn applyFilter(event: *GeoEvent, transform: *const Transform) bool {
    const field_value: f64 = switch (transform.field) {
        .latitude => GeoEvent.lat_to_float(event.lat_nano),
        .longitude => GeoEvent.lon_to_float(event.lon_nano),
        .altitude => @as(f64, @floatFromInt(event.altitude_mm)) / 1000.0,
        .velocity => @as(f64, @floatFromInt(event.velocity_mms)) / 1000.0,
        .accuracy => @as(f64, @floatFromInt(event.accuracy_mm)) / 1000.0,
        .heading => @as(f64, @floatFromInt(event.heading_cdeg)) / 100.0,
        .timestamp => @floatFromInt(event.timestamp),
        else => 0.0,
    };

    return switch (transform.filter_op) {
        .eq => field_value == transform.value,
        .ne => field_value != transform.value,
        .gt => field_value > transform.value,
        .gte => field_value >= transform.value,
        .lt => field_value < transform.value,
        .lte => field_value <= transform.value,
        .in_range => field_value >= transform.value and field_value <= transform.value2,
        .out_range => field_value < transform.value or field_value > transform.value2,
        .is_null => field_value == 0.0,
        .is_not_null => field_value != 0.0,
    };
}

/// Apply default value.
fn applyDefaultValue(event: *GeoEvent, transform: *const Transform) bool {
    const int_value: i64 = @intFromFloat(transform.value);

    switch (transform.field) {
        .altitude => {
            if (event.altitude_mm == 0) {
                event.altitude_mm = @intCast(int_value);
            }
        },
        .velocity => {
            if (event.velocity_mms == 0) {
                event.velocity_mms = @intCast(@as(u64, @bitCast(int_value)));
            }
        },
        .accuracy => {
            if (event.accuracy_mm == 0) {
                event.accuracy_mm = @intCast(@as(u64, @bitCast(int_value)));
            }
        },
        .heading => {
            if (event.heading_cdeg == 0) {
                event.heading_cdeg = @intCast(@as(u64, @bitCast(int_value)));
            }
        },
        else => {},
    }
    return true;
}

/// Apply value clamping.
fn applyClamp(event: *GeoEvent, transform: *const Transform) bool {
    switch (transform.field) {
        .latitude => {
            var lat = GeoEvent.lat_to_float(event.lat_nano);
            lat = @max(transform.value, @min(transform.value2, lat));
            event.lat_nano = GeoEvent.lat_from_float(lat);
        },
        .longitude => {
            var lon = GeoEvent.lon_to_float(event.lon_nano);
            lon = @max(transform.value, @min(transform.value2, lon));
            event.lon_nano = GeoEvent.lon_from_float(lon);
        },
        .altitude => {
            const min_val: i32 = @intFromFloat(transform.value);
            const max_val: i32 = @intFromFloat(transform.value2);
            event.altitude_mm = @max(min_val, @min(max_val, event.altitude_mm));
        },
        .velocity => {
            const max_val: u32 = @intFromFloat(transform.value2);
            event.velocity_mms = @min(max_val, event.velocity_mms);
        },
        .heading => {
            if (event.heading_cdeg > 36000) {
                event.heading_cdeg = event.heading_cdeg % 36001;
            }
        },
        else => {},
    }
    return true;
}

/// Apply math operation.
fn applyMathOp(event: *GeoEvent, transform: *const Transform) bool {
    switch (transform.field) {
        .altitude => {
            var val = @as(f64, @floatFromInt(event.altitude_mm));
            val = applyMathOperation(val, transform.math_op, transform.value);
            event.altitude_mm = @intFromFloat(val);
        },
        .velocity => {
            var val = @as(f64, @floatFromInt(event.velocity_mms));
            val = applyMathOperation(val, transform.math_op, transform.value);
            if (val >= 0) {
                event.velocity_mms = @intFromFloat(val);
            }
        },
        .timestamp => {
            var val = @as(f64, @floatFromInt(event.timestamp));
            val = applyMathOperation(val, transform.math_op, transform.value);
            if (val >= 0) {
                event.timestamp = @intFromFloat(val);
            }
        },
        else => {},
    }
    return true;
}

/// Apply a math operation to a value.
fn applyMathOperation(value: f64, op: MathOp, operand: f64) f64 {
    return switch (op) {
        .add => value + operand,
        .subtract => value - operand,
        .multiply => value * operand,
        .divide => if (operand != 0) value / operand else value,
        .round => @round(value),
        .floor => @floor(value),
        .ceiling => @ceil(value),
        .abs => @abs(value),
        .negate => -value,
    };
}

/// Apply timestamp adjustment.
fn applyTimestampAdjust(event: *GeoEvent, transform: *const Transform) bool {
    const adjustment: i64 = @intFromFloat(transform.value);
    if (adjustment > 0) {
        event.timestamp += @as(u64, @bitCast(adjustment));
    } else if (adjustment < 0) {
        const abs_adj: u64 = @bitCast(-adjustment);
        if (event.timestamp >= abs_adj) {
            event.timestamp -= abs_adj;
        }
    }
    return true;
}

/// Apply flag modification.
fn applyFlagModify(event: *GeoEvent, transform: *const Transform) bool {
    switch (transform.flag_name) {
        .none => {},
        .linked => event.flags.linked = transform.flag_value,
        .imported => event.flags.imported = transform.flag_value,
        .stationary => event.flags.stationary = transform.flag_value,
        .low_accuracy => event.flags.low_accuracy = transform.flag_value,
        .offline => event.flags.offline = transform.flag_value,
        .deleted => event.flags.deleted = transform.flag_value,
    }
    return true;
}

// ============================================================================
// Coordinate Transformations (China-specific)
// ============================================================================

const GCJ_A: f64 = 6378245.0;
const GCJ_EE: f64 = 0.00669342162296594323;
const BD_PI: f64 = 3.14159265358979324 * 3000.0 / 180.0;

/// Check if coordinates are in China.
fn isInChina(lat: f64, lon: f64) bool {
    return lon > 73.66 and lon < 135.05 and lat > 3.86 and lat < 53.55;
}

/// WGS84 to GCJ-02.
fn wgs84ToGcj02(lat: f64, lon: f64) struct { lat: f64, lon: f64 } {
    if (!isInChina(lat, lon)) {
        return .{ .lat = lat, .lon = lon };
    }

    var dlat = transformLat(lon - 105.0, lat - 35.0);
    var dlon = transformLon(lon - 105.0, lat - 35.0);

    const radlat = lat * DEG_TO_RAD;
    var magic = @sin(radlat);
    magic = 1 - GCJ_EE * magic * magic;
    const sqrtmagic = @sqrt(magic);

    dlat = (dlat * 180.0) / ((GCJ_A * (1 - GCJ_EE)) / (magic * sqrtmagic) * math.pi);
    dlon = (dlon * 180.0) / (GCJ_A / sqrtmagic * @cos(radlat) * math.pi);

    return .{
        .lat = lat + dlat,
        .lon = lon + dlon,
    };
}

/// GCJ-02 to WGS84 (approximate).
fn gcj02ToWgs84(lat: f64, lon: f64) struct { lat: f64, lon: f64 } {
    if (!isInChina(lat, lon)) {
        return .{ .lat = lat, .lon = lon };
    }

    const gcj = wgs84ToGcj02(lat, lon);
    return .{
        .lat = lat * 2 - gcj.lat,
        .lon = lon * 2 - gcj.lon,
    };
}

/// GCJ-02 to BD-09.
fn gcj02ToBd09(lat: f64, lon: f64) struct { lat: f64, lon: f64 } {
    const z = @sqrt(lon * lon + lat * lat) + 0.00002 * @sin(lat * BD_PI);
    const theta = math.atan2(lat, lon) + 0.000003 * @cos(lon * BD_PI);
    return .{
        .lat = z * @sin(theta) + 0.006,
        .lon = z * @cos(theta) + 0.0065,
    };
}

/// BD-09 to GCJ-02.
fn bd09ToGcj02(lat: f64, lon: f64) struct { lat: f64, lon: f64 } {
    const x = lon - 0.0065;
    const y = lat - 0.006;
    const z = @sqrt(x * x + y * y) - 0.00002 * @sin(y * BD_PI);
    const theta = math.atan2(y, x) - 0.000003 * @cos(x * BD_PI);
    return .{
        .lat = z * @sin(theta),
        .lon = z * @cos(theta),
    };
}

fn transformLat(x: f64, y: f64) f64 {
    var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * @sqrt(@abs(x));
    ret += (20.0 * @sin(6.0 * x * math.pi) + 20.0 * @sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * @sin(y * math.pi) + 40.0 * @sin(y / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (160.0 * @sin(y / 12.0 * math.pi) + 320 * @sin(y * math.pi / 30.0)) * 2.0 / 3.0;
    return ret;
}

fn transformLon(x: f64, y: f64) f64 {
    var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * @sqrt(@abs(x));
    ret += (20.0 * @sin(6.0 * x * math.pi) + 20.0 * @sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * @sin(x * math.pi) + 40.0 * @sin(x / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (150.0 * @sin(x / 12.0 * math.pi) + 300.0 * @sin(x / 30.0 * math.pi)) * 2.0 / 3.0;
    return ret;
}

// ============================================================================
// Tests
// ============================================================================

test "unit conversion - meters to feet" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pipeline = TransformPipeline.init(allocator);
    defer pipeline.deinit();

    try pipeline.addTransform(.{
        .transform_type = .unit_conversion,
        .unit_conversion = .meters_to_feet,
        .field = .altitude,
    });

    var event = GeoEvent.zero();
    event.altitude_mm = 1000; // 1 meter in mm

    const success = try pipeline.transformEvent(&event);
    try testing.expect(success);
    // 1m * 3.28084 = ~3281 mm in feet
    try testing.expect(event.altitude_mm > 3000 and event.altitude_mm < 3500);
}

test "filter transform - greater than" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pipeline = TransformPipeline.init(allocator);
    defer pipeline.deinit();

    try pipeline.addTransform(.{
        .transform_type = .filter,
        .field = .velocity,
        .filter_op = .gt,
        .value = 10.0, // velocity > 10 m/s
        .skip_on_failure = true,
    });

    // Event with velocity 15 m/s (15000 mm/s)
    var event1 = GeoEvent.zero();
    event1.velocity_mms = 15000;

    const success1 = try pipeline.transformEvent(&event1);
    try testing.expect(success1);

    // Event with velocity 5 m/s (5000 mm/s) - should be filtered
    var event2 = GeoEvent.zero();
    event2.velocity_mms = 5000;

    const success2 = try pipeline.transformEvent(&event2);
    try testing.expect(!success2);
}

test "clamp transform" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pipeline = TransformPipeline.init(allocator);
    defer pipeline.deinit();

    try pipeline.addTransform(.{
        .transform_type = .clamp,
        .field = .latitude,
        .value = -85.0, // min
        .value2 = 85.0, // max
    });

    var event = GeoEvent.zero();
    event.lat_nano = GeoEvent.lat_from_float(100.0); // Invalid latitude

    const success = try pipeline.transformEvent(&event);
    try testing.expect(success);

    const lat = GeoEvent.lat_to_float(event.lat_nano);
    try testing.expect(lat <= 85.0);
}

test "math operation - add" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pipeline = TransformPipeline.init(allocator);
    defer pipeline.deinit();

    try pipeline.addTransform(.{
        .transform_type = .math_op,
        .field = .altitude,
        .math_op = .add,
        .value = 1000.0, // Add 1000mm (1m)
    });

    var event = GeoEvent.zero();
    event.altitude_mm = 5000;

    const success = try pipeline.transformEvent(&event);
    try testing.expect(success);
    try testing.expectEqual(@as(i32, 6000), event.altitude_mm);
}

test "default value assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pipeline = TransformPipeline.init(allocator);
    defer pipeline.deinit();

    try pipeline.addTransform(.{
        .transform_type = .default_value,
        .field = .accuracy,
        .value = 10000.0, // Default 10m accuracy
    });

    var event = GeoEvent.zero();
    event.accuracy_mm = 0; // No accuracy set

    const success = try pipeline.transformEvent(&event);
    try testing.expect(success);
    try testing.expectEqual(@as(u32, 10000), event.accuracy_mm);
}

test "flag modification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pipeline = TransformPipeline.init(allocator);
    defer pipeline.deinit();

    try pipeline.addTransform(.{
        .transform_type = .flag_modify,
        .flag_name = .imported,
        .flag_value = true,
    });

    var event = GeoEvent.zero();
    try testing.expect(!event.flags.imported);

    const success = try pipeline.transformEvent(&event);
    try testing.expect(success);
    try testing.expect(event.flags.imported);
}

test "pipeline statistics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pipeline = TransformPipeline.init(allocator);
    defer pipeline.deinit();

    try pipeline.addTransform(.{
        .transform_type = .filter,
        .field = .velocity,
        .filter_op = .gt,
        .value = 0.0,
        .skip_on_failure = true,
    });

    var events: [3]GeoEvent = undefined;
    events[0] = GeoEvent.zero();
    events[0].velocity_mms = 100;
    events[1] = GeoEvent.zero();
    events[1].velocity_mms = 0; // Will be filtered
    events[2] = GeoEvent.zero();
    events[2].velocity_mms = 200;

    const result = try pipeline.transformBatch(&events);
    try testing.expectEqual(@as(usize, 3), result.total);
    try testing.expectEqual(@as(usize, 2), result.succeeded);
    try testing.expectEqual(@as(usize, 1), result.filtered);

    const stats = pipeline.getStats();
    try testing.expectEqual(@as(usize, 3), stats.events_processed);
}

test "coordinate transform - China coordinates" {
    const testing = std.testing;

    // Test WGS84 to GCJ-02 transformation
    const beijing_wgs84 = .{ .lat = 39.9042, .lon = 116.4074 };
    const gcj02 = wgs84ToGcj02(beijing_wgs84.lat, beijing_wgs84.lon);

    // GCJ-02 should be offset from WGS84
    try testing.expect(gcj02.lat != beijing_wgs84.lat);
    try testing.expect(gcj02.lon != beijing_wgs84.lon);

    // Round-trip should be close to original
    const wgs84_back = gcj02ToWgs84(gcj02.lat, gcj02.lon);
    const lat_diff = @abs(wgs84_back.lat - beijing_wgs84.lat);
    const lon_diff = @abs(wgs84_back.lon - beijing_wgs84.lon);
    try testing.expect(lat_diff < 0.001);
    try testing.expect(lon_diff < 0.001);
}
