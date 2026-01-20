// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Data Validation and Quality Assurance Module for ArcherDB (F-Data-Portability)
//!
//! Provides comprehensive data validation during import and export operations:
//! - Coordinate range validity (±90° latitude, ±180° longitude)
//! - Timestamp chronological ordering
//! - Entity ID format and uniqueness
//! - Required field presence
//! - Data type correctness
//! - Business rule compliance
//! - Data profiling and quality metrics
//!
//!
//! Usage:
//! ```zig
//! var validator = DataValidator.init(allocator, .{
//!     .check_coordinates = true,
//!     .check_timestamps = true,
//!     .check_entity_ids = true,
//! });
//! defer validator.deinit();
//!
//! const result = validator.validateEvent(event);
//! if (!result.is_valid) {
//!     for (result.errors) |err| {
//!         std.log.err("Validation error: {s}", .{err.message});
//!     }
//! }
//! ```

const std = @import("std");
const stdx = @import("stdx");
const mem = std.mem;
const Allocator = mem.Allocator;
const GeoEvent = @import("../geo_event.zig").GeoEvent;

/// Maximum number of validation errors to collect per event.
pub const MAX_ERRORS_PER_EVENT: usize = 16;

/// Maximum entity IDs to track for uniqueness checking.
pub const MAX_TRACKED_ENTITIES: usize = 100_000;

/// Validation error severity levels.
pub const ErrorSeverity = enum {
    /// Informational - data is valid but may have quality issues.
    info,
    /// Warning - data is technically valid but unusual.
    warning,
    /// Error - data violates validation rules.
    err,
    /// Critical - data is corrupt or unusable.
    critical,
};

/// Validation error category.
pub const ErrorCategory = enum {
    /// Coordinate out of valid range.
    coordinate_range,
    /// Invalid timestamp value.
    timestamp_invalid,
    /// Timestamp ordering violation.
    timestamp_ordering,
    /// Entity ID format error.
    entity_id_format,
    /// Duplicate entity ID.
    entity_id_duplicate,
    /// Required field missing or zero.
    required_field,
    /// Data type mismatch.
    data_type,
    /// Business rule violation.
    business_rule,
    /// Heading out of valid range.
    heading_range,
    /// TTL exceeds maximum.
    ttl_exceeded,
    /// Reserved field non-zero.
    reserved_field,
    /// Flag validation error.
    flag_invalid,
};

/// A single validation error with details.
pub const ValidationError = struct {
    /// Error category for programmatic handling.
    category: ErrorCategory,
    /// Severity level.
    severity: ErrorSeverity,
    /// Human-readable error message.
    message: [256]u8 = [_]u8{0} ** 256,
    /// Length of the message.
    message_len: u8 = 0,
    /// Field name that failed validation.
    field_name: [64]u8 = [_]u8{0} ** 64,
    /// Length of field name.
    field_name_len: u8 = 0,
    /// Expected value (if applicable).
    expected_value: ?i64 = null,
    /// Actual value (if applicable).
    actual_value: ?i64 = null,
    /// Event index in batch (if applicable).
    event_index: ?usize = null,

    /// Set the message string.
    pub fn setMessage(self: *ValidationError, msg: []const u8) void {
        const len = @min(msg.len, 255);
        stdx.copy_disjoint(.inexact, u8, self.message[0..len], msg[0..len]);
        self.message_len = @intCast(len);
    }

    /// Set the field name.
    pub fn setFieldName(self: *ValidationError, name: []const u8) void {
        const len = @min(name.len, 63);
        stdx.copy_disjoint(.inexact, u8, self.field_name[0..len], name[0..len]);
        self.field_name_len = @intCast(len);
    }

    /// Get the message as a slice.
    pub fn getMessage(self: *const ValidationError) []const u8 {
        return self.message[0..self.message_len];
    }

    /// Get the field name as a slice.
    pub fn getFieldName(self: *const ValidationError) []const u8 {
        return self.field_name[0..self.field_name_len];
    }
};

/// Result of validating a single event.
pub const ValidationResult = struct {
    /// Whether the event passed all validation checks.
    is_valid: bool,
    /// Number of errors found.
    error_count: usize,
    /// Array of validation errors (up to MAX_ERRORS_PER_EVENT).
    errors: [MAX_ERRORS_PER_EVENT]ValidationError,

    /// Initialize an empty result.
    pub fn init() ValidationResult {
        return .{
            .is_valid = true,
            .error_count = 0,
            .errors = undefined,
        };
    }

    /// Add an error to the result.
    pub fn addError(self: *ValidationResult, err: ValidationError) void {
        if (self.error_count < MAX_ERRORS_PER_EVENT) {
            self.errors[self.error_count] = err;
            self.error_count += 1;
        }
        if (err.severity == .err or err.severity == .critical) {
            self.is_valid = false;
        }
    }

    /// Get errors as a slice.
    pub fn getErrors(self: *const ValidationResult) []const ValidationError {
        return self.errors[0..self.error_count];
    }

    /// Check if there are any errors at or above a given severity.
    pub fn hasErrorsAtSeverity(self: *const ValidationResult, min_severity: ErrorSeverity) bool {
        for (self.errors[0..self.error_count]) |err| {
            if (@intFromEnum(err.severity) >= @intFromEnum(min_severity)) {
                return true;
            }
        }
        return false;
    }
};

/// Validation options.
pub const ValidationOptions = struct {
    /// Validate coordinate ranges (±90° lat, ±180° lon).
    check_coordinates: bool = true,
    /// Validate timestamp values.
    check_timestamps: bool = true,
    /// Validate entity ID format and uniqueness.
    check_entity_ids: bool = true,
    /// Validate required fields are non-zero.
    check_required_fields: bool = true,
    /// Validate heading range (0-360°).
    check_heading: bool = true,
    /// Validate TTL doesn't exceed maximum.
    check_ttl: bool = true,
    /// Validate reserved fields are zero.
    check_reserved: bool = true,
    /// Validate flag consistency.
    check_flags: bool = true,
    /// Track timestamps for ordering validation.
    check_timestamp_ordering: bool = false,
    /// Track entity IDs for uniqueness validation.
    check_entity_uniqueness: bool = false,
    /// Maximum allowed TTL in seconds (default: 30 days).
    max_ttl_seconds: u32 = 30 * 24 * 60 * 60,
    /// Minimum valid timestamp (default: year 2000 in ns).
    min_timestamp_ns: u64 = 946_684_800_000_000_000,
    /// Maximum valid timestamp (default: year 2100 in ns).
    max_timestamp_ns: u64 = 4_102_444_800_000_000_000,
};

/// Data profiling statistics.
pub const DataProfile = struct {
    /// Total number of events analyzed.
    total_events: usize = 0,
    /// Number of events that passed validation.
    valid_events: usize = 0,
    /// Number of events with errors.
    invalid_events: usize = 0,
    /// Number of events with warnings.
    warning_events: usize = 0,

    // Coordinate statistics
    /// Minimum latitude seen (nanodegrees).
    min_lat_nano: i64 = GeoEvent.lat_nano_max,
    /// Maximum latitude seen (nanodegrees).
    max_lat_nano: i64 = GeoEvent.lat_nano_min,
    /// Minimum longitude seen (nanodegrees).
    min_lon_nano: i64 = GeoEvent.lon_nano_max,
    /// Maximum longitude seen (nanodegrees).
    max_lon_nano: i64 = GeoEvent.lon_nano_min,

    // Timestamp statistics
    /// Earliest timestamp seen (ns).
    min_timestamp_ns: u64 = std.math.maxInt(u64),
    /// Latest timestamp seen (ns).
    max_timestamp_ns: u64 = 0,
    /// Number of events with zero timestamp.
    zero_timestamp_count: usize = 0,

    // Entity statistics
    /// Number of unique entities seen.
    unique_entity_count: usize = 0,
    /// Number of duplicate entity IDs.
    duplicate_entity_count: usize = 0,
    /// Number of events with zero entity ID.
    zero_entity_count: usize = 0,

    // Field completeness
    /// Events with non-zero correlation ID.
    has_correlation_id: usize = 0,
    /// Events with non-zero altitude.
    has_altitude: usize = 0,
    /// Events with non-zero velocity.
    has_velocity: usize = 0,
    /// Events with non-zero heading.
    has_heading: usize = 0,
    /// Events with non-zero accuracy.
    has_accuracy: usize = 0,
    /// Events with non-zero TTL.
    has_ttl: usize = 0,
    /// Events with non-zero group ID.
    has_group_id: usize = 0,
    /// Events with non-zero user data.
    has_user_data: usize = 0,

    // Flag statistics
    /// Events marked as linked.
    linked_count: usize = 0,
    /// Events marked as imported.
    imported_count: usize = 0,
    /// Events marked as stationary.
    stationary_count: usize = 0,
    /// Events marked as low accuracy.
    low_accuracy_count: usize = 0,
    /// Events marked as offline.
    offline_count: usize = 0,
    /// Events marked as deleted.
    deleted_count: usize = 0,

    // Error statistics by category
    /// Count of coordinate range errors.
    coord_errors: usize = 0,
    /// Count of timestamp errors.
    timestamp_errors: usize = 0,
    /// Count of entity ID errors.
    entity_id_errors: usize = 0,
    /// Count of required field errors.
    required_field_errors: usize = 0,
    /// Count of heading errors.
    heading_errors: usize = 0,
    /// Count of TTL errors.
    ttl_errors: usize = 0,
    /// Count of reserved field errors.
    reserved_errors: usize = 0,
    /// Count of flag errors.
    flag_errors: usize = 0,

    /// Calculate data completeness percentage.
    pub fn completenessPercent(self: *const DataProfile) f64 {
        if (self.total_events == 0) return 0.0;
        // Count optional fields that have values
        const optional_fields: f64 = 8.0;
        const filled_sum: f64 = @as(f64, @floatFromInt(
            self.has_correlation_id +
                self.has_altitude +
                self.has_velocity +
                self.has_heading +
                self.has_accuracy +
                self.has_ttl +
                self.has_group_id +
                self.has_user_data,
        ));
        const total: f64 = optional_fields * @as(f64, @floatFromInt(self.total_events));
        return (filled_sum / total) * 100.0;
    }

    /// Calculate validation success rate.
    pub fn validationSuccessRate(self: *const DataProfile) f64 {
        if (self.total_events == 0) return 100.0;
        return (@as(f64, @floatFromInt(self.valid_events)) /
            @as(f64, @floatFromInt(self.total_events))) * 100.0;
    }

    /// Get the spatial bounding box as float degrees.
    pub fn getBoundingBox(self: *const DataProfile) struct {
        min_lat: f64,
        max_lat: f64,
        min_lon: f64,
        max_lon: f64,
    } {
        return .{
            .min_lat = GeoEvent.lat_to_float(self.min_lat_nano),
            .max_lat = GeoEvent.lat_to_float(self.max_lat_nano),
            .min_lon = GeoEvent.lon_to_float(self.min_lon_nano),
            .max_lon = GeoEvent.lon_to_float(self.max_lon_nano),
        };
    }

    /// Get time range as Unix seconds.
    pub fn getTimeRange(self: *const DataProfile) struct {
        min_seconds: u64,
        max_seconds: u64,
        span_seconds: u64,
    } {
        const min_s = self.min_timestamp_ns / 1_000_000_000;
        const max_s = self.max_timestamp_ns / 1_000_000_000;
        return .{
            .min_seconds = min_s,
            .max_seconds = max_s,
            .span_seconds = if (max_s > min_s) max_s - min_s else 0,
        };
    }
};

/// Data validator for GeoEvents.
pub const DataValidator = struct {
    allocator: Allocator,
    options: ValidationOptions,
    profile: DataProfile,

    // Timestamp ordering tracking
    last_timestamp_by_entity: ?std.AutoHashMap(u128, u64),

    // Entity uniqueness tracking
    seen_entities: ?std.AutoHashMap(u128, usize),

    /// Initialize a new data validator.
    pub fn init(allocator: Allocator, options: ValidationOptions) DataValidator {
        return .{
            .allocator = allocator,
            .options = options,
            .profile = .{},
            .last_timestamp_by_entity = if (options.check_timestamp_ordering)
                std.AutoHashMap(u128, u64).init(allocator)
            else
                null,
            .seen_entities = if (options.check_entity_uniqueness)
                std.AutoHashMap(u128, usize).init(allocator)
            else
                null,
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *DataValidator) void {
        if (self.last_timestamp_by_entity) |*map| {
            map.deinit();
        }
        if (self.seen_entities) |*map| {
            map.deinit();
        }
    }

    /// Reset the validator state (keeps options).
    pub fn reset(self: *DataValidator) void {
        self.profile = .{};
        if (self.last_timestamp_by_entity) |*map| {
            map.clearRetainingCapacity();
        }
        if (self.seen_entities) |*map| {
            map.clearRetainingCapacity();
        }
    }

    /// Validate a single GeoEvent.
    pub fn validateEvent(self: *DataValidator, event: *const GeoEvent) ValidationResult {
        return self.validateEventAt(event, null);
    }

    /// Validate a single GeoEvent with index for error reporting.
    pub fn validateEventAt(
        self: *DataValidator,
        event: *const GeoEvent,
        index: ?usize,
    ) ValidationResult {
        var result = ValidationResult.init();

        // Update profile statistics
        self.profile.total_events += 1;
        self.updateProfileStats(event);

        // Run validation checks
        if (self.options.check_coordinates) {
            self.validateCoordinates(event, &result, index);
        }

        if (self.options.check_timestamps) {
            self.validateTimestamp(event, &result, index);
        }

        if (self.options.check_timestamp_ordering) {
            self.validateTimestampOrdering(event, &result, index);
        }

        if (self.options.check_entity_ids) {
            self.validateEntityId(event, &result, index);
        }

        if (self.options.check_entity_uniqueness) {
            self.validateEntityUniqueness(event, &result, index);
        }

        if (self.options.check_required_fields) {
            self.validateRequiredFields(event, &result, index);
        }

        if (self.options.check_heading) {
            self.validateHeading(event, &result, index);
        }

        if (self.options.check_ttl) {
            self.validateTtl(event, &result, index);
        }

        if (self.options.check_reserved) {
            self.validateReserved(event, &result, index);
        }

        if (self.options.check_flags) {
            self.validateFlags(event, &result, index);
        }

        // Update profile with result
        if (result.is_valid) {
            self.profile.valid_events += 1;
        } else {
            self.profile.invalid_events += 1;
        }
        if (result.hasErrorsAtSeverity(.warning) and !result.hasErrorsAtSeverity(.err)) {
            self.profile.warning_events += 1;
        }

        return result;
    }

    /// Validate a batch of events.
    pub fn validateBatch(self: *DataValidator, events: []const GeoEvent) struct {
        valid_count: usize,
        invalid_count: usize,
        results: []ValidationResult,
    } {
        var results = self.allocator.alloc(ValidationResult, events.len) catch {
            return .{
                .valid_count = 0,
                .invalid_count = events.len,
                .results = &[_]ValidationResult{},
            };
        };

        var valid_count: usize = 0;
        var invalid_count: usize = 0;

        for (events, 0..) |*event, i| {
            results[i] = self.validateEventAt(event, i);
            if (results[i].is_valid) {
                valid_count += 1;
            } else {
                invalid_count += 1;
            }
        }

        return .{
            .valid_count = valid_count,
            .invalid_count = invalid_count,
            .results = results,
        };
    }

    /// Free batch validation results.
    pub fn freeBatchResults(self: *DataValidator, results: []ValidationResult) void {
        self.allocator.free(results);
    }

    /// Get the current data profile.
    pub fn getProfile(self: *const DataValidator) DataProfile {
        return self.profile;
    }

    // === Private validation methods ===

    fn updateProfileStats(self: *DataValidator, event: *const GeoEvent) void {
        // Coordinate bounds
        if (event.lat_nano < self.profile.min_lat_nano) {
            self.profile.min_lat_nano = event.lat_nano;
        }
        if (event.lat_nano > self.profile.max_lat_nano) {
            self.profile.max_lat_nano = event.lat_nano;
        }
        if (event.lon_nano < self.profile.min_lon_nano) {
            self.profile.min_lon_nano = event.lon_nano;
        }
        if (event.lon_nano > self.profile.max_lon_nano) {
            self.profile.max_lon_nano = event.lon_nano;
        }

        // Timestamp bounds
        if (event.timestamp > 0) {
            if (event.timestamp < self.profile.min_timestamp_ns) {
                self.profile.min_timestamp_ns = event.timestamp;
            }
            if (event.timestamp > self.profile.max_timestamp_ns) {
                self.profile.max_timestamp_ns = event.timestamp;
            }
        } else {
            self.profile.zero_timestamp_count += 1;
        }

        // Entity tracking
        if (event.entity_id == 0) {
            self.profile.zero_entity_count += 1;
        }

        // Field completeness
        if (event.correlation_id != 0) self.profile.has_correlation_id += 1;
        if (event.altitude_mm != 0) self.profile.has_altitude += 1;
        if (event.velocity_mms != 0) self.profile.has_velocity += 1;
        if (event.heading_cdeg != 0) self.profile.has_heading += 1;
        if (event.accuracy_mm != 0) self.profile.has_accuracy += 1;
        if (event.ttl_seconds != 0) self.profile.has_ttl += 1;
        if (event.group_id != 0) self.profile.has_group_id += 1;
        if (event.user_data != 0) self.profile.has_user_data += 1;

        // Flag statistics
        if (event.flags.linked) self.profile.linked_count += 1;
        if (event.flags.imported) self.profile.imported_count += 1;
        if (event.flags.stationary) self.profile.stationary_count += 1;
        if (event.flags.low_accuracy) self.profile.low_accuracy_count += 1;
        if (event.flags.offline) self.profile.offline_count += 1;
        if (event.flags.deleted) self.profile.deleted_count += 1;
    }

    fn validateCoordinates(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        // Latitude check
        if (event.lat_nano < GeoEvent.lat_nano_min or
            event.lat_nano > GeoEvent.lat_nano_max)
        {
            const expected = if (event.lat_nano < GeoEvent.lat_nano_min)
                GeoEvent.lat_nano_min
            else
                GeoEvent.lat_nano_max;
            var err = ValidationError{
                .category = .coordinate_range,
                .severity = .err,
                .expected_value = expected,
                .actual_value = event.lat_nano,
                .event_index = index,
            };
            err.setFieldName("lat_nano");
            err.setMessage("Latitude out of range (±90°)");
            result.addError(err);
            self.profile.coord_errors += 1;
        }

        // Longitude check
        if (event.lon_nano < GeoEvent.lon_nano_min or
            event.lon_nano > GeoEvent.lon_nano_max)
        {
            const expected = if (event.lon_nano < GeoEvent.lon_nano_min)
                GeoEvent.lon_nano_min
            else
                GeoEvent.lon_nano_max;
            var err = ValidationError{
                .category = .coordinate_range,
                .severity = .err,
                .expected_value = expected,
                .actual_value = event.lon_nano,
                .event_index = index,
            };
            err.setFieldName("lon_nano");
            err.setMessage("Longitude out of range (±180°)");
            result.addError(err);
            self.profile.coord_errors += 1;
        }
    }

    fn validateTimestamp(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        // Zero timestamp check
        if (event.timestamp == 0) {
            var err = ValidationError{
                .category = .timestamp_invalid,
                .severity = .err,
                .actual_value = 0,
                .event_index = index,
            };
            err.setFieldName("timestamp");
            err.setMessage("Timestamp is zero");
            result.addError(err);
            self.profile.timestamp_errors += 1;
            return;
        }

        // Range check
        if (event.timestamp < self.options.min_timestamp_ns) {
            var err = ValidationError{
                .category = .timestamp_invalid,
                .severity = .warning,
                .expected_value = @intCast(self.options.min_timestamp_ns),
                .actual_value = @intCast(event.timestamp),
                .event_index = index,
            };
            err.setFieldName("timestamp");
            err.setMessage("Timestamp before minimum (year 2000)");
            result.addError(err);
            self.profile.timestamp_errors += 1;
        }

        if (event.timestamp > self.options.max_timestamp_ns) {
            var err = ValidationError{
                .category = .timestamp_invalid,
                .severity = .warning,
                .expected_value = @intCast(self.options.max_timestamp_ns),
                .actual_value = @intCast(event.timestamp),
                .event_index = index,
            };
            err.setFieldName("timestamp");
            err.setMessage("Timestamp after maximum (year 2100)");
            result.addError(err);
            self.profile.timestamp_errors += 1;
        }

        // Verify composite ID consistency
        const unpacked = GeoEvent.unpack_id(event.id);
        if (unpacked.timestamp_ns != event.timestamp) {
            var err = ValidationError{
                .category = .timestamp_invalid,
                .severity = .err,
                .expected_value = @intCast(event.timestamp),
                .actual_value = @intCast(unpacked.timestamp_ns),
                .event_index = index,
            };
            err.setFieldName("id");
            err.setMessage("Composite ID timestamp doesn't match timestamp field");
            result.addError(err);
            self.profile.timestamp_errors += 1;
        }
    }

    fn validateTimestampOrdering(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        if (self.last_timestamp_by_entity) |*map| {
            if (event.entity_id != 0) {
                if (map.get(event.entity_id)) |last_ts| {
                    if (event.timestamp < last_ts) {
                        var err = ValidationError{
                            .category = .timestamp_ordering,
                            .severity = .warning,
                            .expected_value = @intCast(last_ts),
                            .actual_value = @intCast(event.timestamp),
                            .event_index = index,
                        };
                        err.setFieldName("timestamp");
                        err.setMessage(
                            "Timestamp out of chronological order for entity",
                        );
                        result.addError(err);
                        self.profile.timestamp_errors += 1;
                    }
                }
                map.put(event.entity_id, event.timestamp) catch {};
            }
        }
    }

    fn validateEntityId(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        // Zero entity ID check
        if (event.entity_id == 0) {
            var err = ValidationError{
                .category = .entity_id_format,
                .severity = .err,
                .actual_value = 0,
                .event_index = index,
            };
            err.setFieldName("entity_id");
            err.setMessage("Entity ID is zero");
            result.addError(err);
            self.profile.entity_id_errors += 1;
        }
    }

    fn validateEntityUniqueness(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        if (self.seen_entities) |*map| {
            if (event.entity_id != 0) {
                const gop = map.getOrPut(event.entity_id) catch {
                    return;
                };

                if (gop.found_existing) {
                    // Not necessarily an error - same entity can have multiple events
                    // But we track it for profiling
                    self.profile.duplicate_entity_count += 1;

                    // Only report if we're checking for true duplicates
                    // (same entity, same timestamp)
                    if (self.last_timestamp_by_entity) |ts_map| {
                        if (ts_map.get(event.entity_id)) |last_ts| {
                            if (last_ts == event.timestamp) {
                                var err = ValidationError{
                                    .category = .entity_id_duplicate,
                                    .severity = .warning,
                                    .actual_value = @intCast(event.timestamp),
                                    .event_index = index,
                                };
                                err.setFieldName("entity_id");
                                err.setMessage(
                                    "Duplicate event: same entity and timestamp",
                                );
                                result.addError(err);
                            }
                        }
                    }
                } else {
                    gop.value_ptr.* = 1;
                    self.profile.unique_entity_count += 1;
                }
            }
        }
    }

    fn validateRequiredFields(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        // id is required
        if (event.id == 0) {
            var err = ValidationError{
                .category = .required_field,
                .severity = .err,
                .event_index = index,
            };
            err.setFieldName("id");
            err.setMessage("Required field 'id' is zero");
            result.addError(err);
            self.profile.required_field_errors += 1;
        }
    }

    fn validateHeading(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        if (event.heading_cdeg > GeoEvent.heading_max) {
            var err = ValidationError{
                .category = .heading_range,
                .severity = .err,
                .expected_value = GeoEvent.heading_max,
                .actual_value = event.heading_cdeg,
                .event_index = index,
            };
            err.setFieldName("heading_cdeg");
            err.setMessage("Heading exceeds 360 degrees");
            result.addError(err);
            self.profile.heading_errors += 1;
        }
    }

    fn validateTtl(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        if (event.ttl_seconds > self.options.max_ttl_seconds) {
            var err = ValidationError{
                .category = .ttl_exceeded,
                .severity = .warning,
                .expected_value = self.options.max_ttl_seconds,
                .actual_value = event.ttl_seconds,
                .event_index = index,
            };
            err.setFieldName("ttl_seconds");
            err.setMessage("TTL exceeds maximum allowed value");
            result.addError(err);
            self.profile.ttl_errors += 1;
        }
    }

    fn validateReserved(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        // Check reserved bytes are zero
        var has_nonzero: bool = false;
        for (event.reserved) |byte| {
            if (byte != 0) {
                has_nonzero = true;
                break;
            }
        }

        if (has_nonzero) {
            var err = ValidationError{
                .category = .reserved_field,
                .severity = .warning,
                .event_index = index,
            };
            err.setFieldName("reserved");
            err.setMessage("Reserved bytes are non-zero");
            result.addError(err);
            self.profile.reserved_errors += 1;
        }
    }

    fn validateFlags(
        self: *DataValidator,
        event: *const GeoEvent,
        result: *ValidationResult,
        index: ?usize,
    ) void {
        // Check padding bits are zero
        if (event.flags.padding != 0) {
            var err = ValidationError{
                .category = .flag_invalid,
                .severity = .warning,
                .actual_value = event.flags.padding,
                .event_index = index,
            };
            err.setFieldName("flags.padding");
            err.setMessage("Flag padding bits are non-zero");
            result.addError(err);
            self.profile.flag_errors += 1;
        }

        // Business rule: deleted events shouldn't have other activity flags
        if (event.flags.deleted) {
            if (event.flags.linked) {
                var err = ValidationError{
                    .category = .business_rule,
                    .severity = .info,
                    .event_index = index,
                };
                err.setFieldName("flags");
                err.setMessage("Deleted event is marked as linked");
                result.addError(err);
            }
        }
    }
};

/// Quick validation helper - validates a single event with default options.
pub fn validateEvent(event: *const GeoEvent) ValidationResult {
    var validator = DataValidator.init(std.heap.page_allocator, .{});
    defer validator.deinit();
    return validator.validateEvent(event);
}

/// Quick coordinate validation.
pub fn isValidCoordinate(lat_nano: i64, lon_nano: i64) bool {
    return GeoEvent.validate_coordinates(lat_nano, lon_nano);
}

/// Quick timestamp validation.
pub fn isValidTimestamp(timestamp_ns: u64) bool {
    const min_ts: u64 = 946_684_800_000_000_000; // Year 2000
    const max_ts: u64 = 4_102_444_800_000_000_000; // Year 2100
    return timestamp_ns >= min_ts and timestamp_ns <= max_ts;
}

/// Convert validation result to JSON string.
pub fn resultToJson(allocator: Allocator, result: *const ValidationResult) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    const writer = buffer.writer();

    try writer.writeAll("{\"is_valid\":");
    try writer.writeAll(if (result.is_valid) "true" else "false");
    try writer.writeAll(",\"error_count\":");
    try std.fmt.formatInt(result.error_count, 10, .lower, .{}, writer);
    try writer.writeAll(",\"errors\":[");

    for (result.errors[0..result.error_count], 0..) |err, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"category\":\"");
        try writer.writeAll(@tagName(err.category));
        try writer.writeAll("\",\"severity\":\"");
        try writer.writeAll(@tagName(err.severity));
        try writer.writeAll("\",\"field\":\"");
        try writer.writeAll(err.getFieldName());
        try writer.writeAll("\",\"message\":\"");
        try writer.writeAll(err.getMessage());
        try writer.writeAll("\"}");
    }

    try writer.writeAll("]}");

    return buffer.toOwnedSlice();
}

// === Tests ===

test "validate valid event" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{});
    defer validator.deinit();

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(12345, 1700000000000000000);
    event.entity_id = 42;
    event.timestamp = 1700000000000000000;
    event.lat_nano = 37_774929000; // ~37.77° (San Francisco)
    event.lon_nano = -122_419418000; // ~-122.42°

    const result = validator.validateEvent(&event);
    try testing.expect(result.is_valid);
    try testing.expectEqual(@as(usize, 0), result.error_count);
}

test "validate invalid latitude" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{});
    defer validator.deinit();

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(12345, 1700000000000000000);
    event.entity_id = 42;
    event.timestamp = 1700000000000000000;
    event.lat_nano = 100_000_000_000; // 100° - invalid
    event.lon_nano = 0;

    const result = validator.validateEvent(&event);
    try testing.expect(!result.is_valid);
    try testing.expect(result.error_count > 0);
    try testing.expectEqual(ErrorCategory.coordinate_range, result.errors[0].category);
}

test "validate invalid longitude" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{});
    defer validator.deinit();

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(12345, 1700000000000000000);
    event.entity_id = 42;
    event.timestamp = 1700000000000000000;
    event.lat_nano = 0;
    event.lon_nano = 200_000_000_000; // 200° - invalid

    const result = validator.validateEvent(&event);
    try testing.expect(!result.is_valid);
    try testing.expect(result.error_count > 0);
    try testing.expectEqual(ErrorCategory.coordinate_range, result.errors[0].category);
}

test "validate zero timestamp" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{});
    defer validator.deinit();

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(12345, 0);
    event.entity_id = 42;
    event.timestamp = 0; // Invalid
    event.lat_nano = 0;
    event.lon_nano = 0;

    const result = validator.validateEvent(&event);
    try testing.expect(!result.is_valid);
    try testing.expect(result.error_count > 0);
}

test "validate zero entity_id" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{});
    defer validator.deinit();

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(12345, 1700000000000000000);
    event.entity_id = 0; // Invalid
    event.timestamp = 1700000000000000000;
    event.lat_nano = 0;
    event.lon_nano = 0;

    const result = validator.validateEvent(&event);
    try testing.expect(!result.is_valid);
    try testing.expect(result.error_count > 0);
    try testing.expectEqual(ErrorCategory.entity_id_format, result.errors[0].category);
}

test "validate heading out of range" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{});
    defer validator.deinit();

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(12345, 1700000000000000000);
    event.entity_id = 42;
    event.timestamp = 1700000000000000000;
    event.lat_nano = 0;
    event.lon_nano = 0;
    event.heading_cdeg = 40000; // 400° - invalid

    const result = validator.validateEvent(&event);
    try testing.expect(!result.is_valid);
    try testing.expect(result.error_count > 0);
    try testing.expectEqual(ErrorCategory.heading_range, result.errors[0].category);
}

test "validate ttl exceeded" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{
        .max_ttl_seconds = 1000,
    });
    defer validator.deinit();

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(12345, 1700000000000000000);
    event.entity_id = 42;
    event.timestamp = 1700000000000000000;
    event.lat_nano = 0;
    event.lon_nano = 0;
    event.ttl_seconds = 2000; // Exceeds max

    const result = validator.validateEvent(&event);
    // TTL exceeded is a warning, not error
    try testing.expect(result.is_valid);
    try testing.expect(result.error_count > 0);
    try testing.expectEqual(ErrorCategory.ttl_exceeded, result.errors[0].category);
    try testing.expectEqual(ErrorSeverity.warning, result.errors[0].severity);
}

test "validate reserved bytes non-zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{});
    defer validator.deinit();

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(12345, 1700000000000000000);
    event.entity_id = 42;
    event.timestamp = 1700000000000000000;
    event.lat_nano = 0;
    event.lon_nano = 0;
    event.reserved[0] = 0xFF; // Non-zero reserved

    const result = validator.validateEvent(&event);
    // Reserved non-zero is a warning
    try testing.expect(result.is_valid);
    try testing.expect(result.error_count > 0);
    try testing.expectEqual(ErrorCategory.reserved_field, result.errors[0].category);
}

test "data profiling statistics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{
        .check_entity_uniqueness = true,
    });
    defer validator.deinit();

    // Create multiple valid events
    var event1 = GeoEvent.zero();
    event1.id = GeoEvent.pack_id(12345, 1700000000000000000);
    event1.entity_id = 42;
    event1.timestamp = 1700000000000000000;
    event1.lat_nano = 37_774929000;
    event1.lon_nano = -122_419418000;
    event1.altitude_mm = 10000;
    event1.velocity_mms = 5000;

    var event2 = GeoEvent.zero();
    event2.id = GeoEvent.pack_id(12346, 1700000001000000000);
    event2.entity_id = 43;
    event2.timestamp = 1700000001000000000;
    event2.lat_nano = 40_712776000;
    event2.lon_nano = -74_005974000;
    event2.heading_cdeg = 9000;

    _ = validator.validateEvent(&event1);
    _ = validator.validateEvent(&event2);

    const profile = validator.getProfile();

    try testing.expectEqual(@as(usize, 2), profile.total_events);
    try testing.expectEqual(@as(usize, 2), profile.valid_events);
    try testing.expectEqual(@as(usize, 0), profile.invalid_events);
    try testing.expectEqual(@as(usize, 2), profile.unique_entity_count);
    try testing.expectEqual(@as(usize, 1), profile.has_altitude);
    try testing.expectEqual(@as(usize, 1), profile.has_velocity);
    try testing.expectEqual(@as(usize, 1), profile.has_heading);

    // Check bounding box
    const bbox = profile.getBoundingBox();
    try testing.expect(bbox.min_lat < bbox.max_lat);
    try testing.expect(bbox.min_lon < bbox.max_lon);
}

test "batch validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = DataValidator.init(allocator, .{});
    defer validator.deinit();

    var events: [3]GeoEvent = undefined;

    // Valid event
    events[0] = GeoEvent.zero();
    events[0].id = GeoEvent.pack_id(1, 1700000000000000000);
    events[0].entity_id = 1;
    events[0].timestamp = 1700000000000000000;

    // Invalid latitude
    events[1] = GeoEvent.zero();
    events[1].id = GeoEvent.pack_id(2, 1700000001000000000);
    events[1].entity_id = 2;
    events[1].timestamp = 1700000001000000000;
    events[1].lat_nano = 100_000_000_000; // Invalid

    // Valid event
    events[2] = GeoEvent.zero();
    events[2].id = GeoEvent.pack_id(3, 1700000002000000000);
    events[2].entity_id = 3;
    events[2].timestamp = 1700000002000000000;

    const batch_result = validator.validateBatch(&events);
    defer validator.freeBatchResults(batch_result.results);

    try testing.expectEqual(@as(usize, 2), batch_result.valid_count);
    try testing.expectEqual(@as(usize, 1), batch_result.invalid_count);
    try testing.expect(batch_result.results[0].is_valid);
    try testing.expect(!batch_result.results[1].is_valid);
    try testing.expect(batch_result.results[2].is_valid);
}

test "quick validation helpers" {
    const testing = std.testing;

    // Coordinate validation
    try testing.expect(isValidCoordinate(0, 0));
    try testing.expect(isValidCoordinate(GeoEvent.lat_nano_max, GeoEvent.lon_nano_max));
    try testing.expect(!isValidCoordinate(GeoEvent.lat_nano_max + 1, 0));
    try testing.expect(!isValidCoordinate(0, GeoEvent.lon_nano_max + 1));

    // Timestamp validation
    try testing.expect(isValidTimestamp(1700000000000000000)); // 2023
    try testing.expect(!isValidTimestamp(0));
    try testing.expect(!isValidTimestamp(5_000_000_000_000_000_000)); // Year 2128
}

test "result to JSON" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var result = ValidationResult.init();
    var err = ValidationError{
        .category = .coordinate_range,
        .severity = .err,
    };
    err.setFieldName("lat_nano");
    err.setMessage("Latitude out of range");
    result.addError(err);

    const json = try resultToJson(allocator, &result);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"is_valid\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "coordinate_range") != null);
    try testing.expect(std.mem.indexOf(u8, json, "lat_nano") != null);
}
