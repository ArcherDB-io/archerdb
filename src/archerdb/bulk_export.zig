// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Bulk Data Export with Range Filtering (F-Data-Portability)
//!
//! Provides efficient bulk export of large location datasets with filtering capabilities:
//! - Time range filtering (start/end timestamps)
//! - Spatial range filtering (bounding boxes)
//! - Entity ID range filtering
//! - Pagination for large result sets
//! - Resume capability for interrupted exports
//!
//! Target: >100MB/sec throughput for sequential scans on NVMe storage.
//!
//! See: openspec/changes/add-geospatial-core/specs/data-portability/spec.md
//!
//! Usage:
//! ```zig
//! var filter = ExportFilter{
//!     .time_range = .{ .start_ns = start, .end_ns = end },
//!     .bounding_box = .{ .min_lat = 37.0, .max_lat = 38.0, .min_lon = -123.0, .max_lon = -122.0 },
//! };
//!
//! var exporter = BulkExporter.init(allocator, filter, .{});
//! defer exporter.deinit();
//!
//! while (try exporter.nextBatch(events_source)) |batch| {
//!     try exporter.exportBatch(writer, batch);
//! }
//! ```

const std = @import("std");
const mem = std.mem;
const GeoEvent = @import("../geo_event.zig").GeoEvent;
const data_export = @import("data_export.zig");

/// Time range filter for exports.
pub const TimeRange = struct {
    /// Start timestamp (inclusive), in nanoseconds since Unix epoch.
    start_ns: u64 = 0,
    /// End timestamp (exclusive), in nanoseconds since Unix epoch.
    /// Use maxInt for no upper bound.
    end_ns: u64 = std.math.maxInt(u64),

    /// Check if a timestamp is within this range.
    pub fn contains(self: TimeRange, timestamp_ns: u64) bool {
        return timestamp_ns >= self.start_ns and timestamp_ns < self.end_ns;
    }

    /// Create a range covering all time.
    pub fn all() TimeRange {
        return .{};
    }

    /// Create a range for a specific day (UTC).
    pub fn forDay(year: u16, month: u4, day: u5) TimeRange {
        const start_secs = dayToEpochSeconds(year, month, day);
        const end_secs = start_secs + 86400; // 24 hours

        return .{
            .start_ns = @as(u64, start_secs) * 1_000_000_000,
            .end_ns = @as(u64, end_secs) * 1_000_000_000,
        };
    }

    /// Helper to convert date to epoch seconds.
    fn dayToEpochSeconds(year: u16, month: u4, day: u5) u64 {
        // Simple epoch calculation (not handling leap seconds)
        var days: i64 = 0;

        // Years since 1970
        var y: u16 = 1970;
        while (y < year) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }

        // Months
        const days_per_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var m: u4 = 1;
        while (m < month) : (m += 1) {
            days += days_per_month[m - 1];
            if (m == 2 and isLeapYear(year)) days += 1;
        }

        // Days (1-indexed to 0-indexed)
        days += day - 1;

        return @intCast(days * 86400);
    }

    fn isLeapYear(year: u16) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }
};

/// Geographic bounding box filter.
/// Uses WGS84 coordinates in degrees.
pub const BoundingBox = struct {
    /// Minimum latitude (southern boundary), in degrees.
    min_lat: f64 = -90.0,
    /// Maximum latitude (northern boundary), in degrees.
    max_lat: f64 = 90.0,
    /// Minimum longitude (western boundary), in degrees.
    min_lon: f64 = -180.0,
    /// Maximum longitude (eastern boundary), in degrees.
    max_lon: f64 = 180.0,

    /// Check if a coordinate is within this bounding box.
    pub fn contains(self: BoundingBox, lat: f64, lon: f64) bool {
        return lat >= self.min_lat and lat <= self.max_lat and
            lon >= self.min_lon and lon <= self.max_lon;
    }

    /// Check if a GeoEvent is within this bounding box.
    pub fn containsEvent(self: BoundingBox, event: *const GeoEvent) bool {
        const lat = GeoEvent.lat_to_float(event.lat_nano);
        const lon = GeoEvent.lon_to_float(event.lon_nano);
        return self.contains(lat, lon);
    }

    /// Create a bounding box covering the entire world.
    pub fn world() BoundingBox {
        return .{};
    }

    /// Create a bounding box from center point and radius (approximate).
    /// Note: This is a simple approximation that doesn't account for
    /// Earth's curvature. For accurate radius queries, use S2 cells.
    pub fn fromCenterRadius(center_lat: f64, center_lon: f64, radius_km: f64) BoundingBox {
        // Rough approximation: 1 degree ~= 111 km at equator
        const lat_delta = radius_km / 111.0;
        // Longitude delta varies with latitude
        const cos_lat = @cos(center_lat * std.math.pi / 180.0);
        const lon_delta = if (cos_lat > 0.001) radius_km / (111.0 * cos_lat) else 180.0;

        return .{
            .min_lat = @max(-90.0, center_lat - lat_delta),
            .max_lat = @min(90.0, center_lat + lat_delta),
            .min_lon = @max(-180.0, center_lon - lon_delta),
            .max_lon = @min(180.0, center_lon + lon_delta),
        };
    }

    /// Calculate approximate area in square kilometers.
    pub fn areaKm2(self: BoundingBox) f64 {
        const lat_span = self.max_lat - self.min_lat;
        const lon_span = self.max_lon - self.min_lon;
        const mid_lat = (self.min_lat + self.max_lat) / 2.0;

        // Account for longitude narrowing at higher latitudes
        const cos_lat = @cos(mid_lat * std.math.pi / 180.0);

        // 1 degree lat ~= 111 km, 1 degree lon ~= 111 * cos(lat) km
        return lat_span * 111.0 * lon_span * 111.0 * cos_lat;
    }
};

/// Entity ID filter for exports.
pub const EntityFilter = struct {
    /// Specific entity IDs to include (null = all entities).
    entity_ids: ?[]const u128 = null,
    /// Group IDs to include (null = all groups).
    group_ids: ?[]const u64 = null,
    /// Exclude deleted/tombstone records.
    exclude_deleted: bool = true,
    /// Exclude expired records (based on TTL).
    exclude_expired: bool = true,

    /// Check if an event matches this filter.
    pub fn matches(self: EntityFilter, event: *const GeoEvent, current_time_ns: u64) bool {
        // Check deleted flag
        if (self.exclude_deleted and event.flags.deleted) {
            return false;
        }

        // Check TTL expiration
        if (self.exclude_expired and event.is_expired(current_time_ns)) {
            return false;
        }

        // Check entity ID filter
        if (self.entity_ids) |ids| {
            var found = false;
            for (ids) |id| {
                if (id == event.entity_id) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        // Check group ID filter
        if (self.group_ids) |groups| {
            var found = false;
            for (groups) |gid| {
                if (gid == event.group_id) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }
};

/// Combined export filter.
pub const ExportFilter = struct {
    /// Time range filter.
    time_range: TimeRange = .{},
    /// Spatial bounding box filter.
    bounding_box: BoundingBox = .{},
    /// Entity filter.
    entity_filter: EntityFilter = .{},

    /// Check if an event matches all filters.
    pub fn matches(self: ExportFilter, event: *const GeoEvent, current_time_ns: u64) bool {
        // Check time range
        if (!self.time_range.contains(event.timestamp)) {
            return false;
        }

        // Check bounding box
        if (!self.bounding_box.containsEvent(event)) {
            return false;
        }

        // Check entity filter
        if (!self.entity_filter.matches(event, current_time_ns)) {
            return false;
        }

        return true;
    }

    /// Create a filter that matches everything.
    pub fn all() ExportFilter {
        return .{};
    }
};

/// Export progress tracking for resumption.
pub const ExportProgress = struct {
    /// Total events processed.
    events_processed: u64 = 0,
    /// Total events exported (after filtering).
    events_exported: u64 = 0,
    /// Total bytes written.
    bytes_written: u64 = 0,
    /// Last event ID processed (for resumption).
    last_event_id: u128 = 0,
    /// Last timestamp processed.
    last_timestamp_ns: u64 = 0,
    /// Export start time.
    start_time_ns: u64 = 0,
    /// Export is complete.
    completed: bool = false,

    /// Calculate throughput in MB/sec.
    pub fn throughputMBps(self: ExportProgress, current_time_ns: u64) f64 {
        const elapsed_ns = current_time_ns - self.start_time_ns;
        if (elapsed_ns == 0) return 0;

        const elapsed_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const mb_written = @as(f64, @floatFromInt(self.bytes_written)) / (1024.0 * 1024.0);

        return mb_written / elapsed_secs;
    }

    /// Calculate filter ratio (exported / processed).
    pub fn filterRatio(self: ExportProgress) f64 {
        if (self.events_processed == 0) return 0;
        return @as(f64, @floatFromInt(self.events_exported)) /
            @as(f64, @floatFromInt(self.events_processed));
    }
};

/// Bulk export options.
pub const BulkExportOptions = struct {
    /// Export format.
    format: data_export.ExportFormat = .json,
    /// Batch size for processing.
    batch_size: usize = 10000,
    /// Current time for TTL calculations (0 = use wall clock).
    current_time_ns: u64 = 0,
    /// Include metadata in output.
    include_metadata: bool = true,
    /// Pretty print output.
    pretty: bool = false,
    /// Resume from previous progress.
    resume_from: ?ExportProgress = null,
};

/// Bulk exporter with range filtering.
pub const BulkExporter = struct {
    allocator: mem.Allocator,
    filter: ExportFilter,
    options: BulkExportOptions,
    progress: ExportProgress,
    data_exporter: data_export.DataExporter,
    current_time_ns: u64,

    const Self = @This();

    /// Initialize bulk exporter.
    pub fn init(allocator: mem.Allocator, filter: ExportFilter, options: BulkExportOptions) Self {
        const current_time = if (options.current_time_ns != 0)
            options.current_time_ns
        else
            @as(u64, @intCast(std.time.nanoTimestamp()));

        var progress = options.resume_from orelse ExportProgress{};
        if (progress.start_time_ns == 0) {
            progress.start_time_ns = current_time;
        }

        return .{
            .allocator = allocator,
            .filter = filter,
            .options = options,
            .progress = progress,
            .data_exporter = data_export.DataExporter.init(allocator, .{
                .format = options.format,
                .include_metadata = options.include_metadata,
                .pretty = options.pretty,
            }),
            .current_time_ns = current_time,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *Self) void {
        self.data_exporter.deinit();
    }

    /// Filter a slice of events and return matching ones.
    /// Returns a slice pointing into the provided output buffer.
    pub fn filterEvents(
        self: *Self,
        events: []const GeoEvent,
        output: []GeoEvent,
    ) []GeoEvent {
        var count: usize = 0;

        for (events) |*event| {
            self.progress.events_processed += 1;

            // Skip events before resume point
            if (self.options.resume_from != null) {
                if (event.id <= self.progress.last_event_id) {
                    continue;
                }
            }

            if (self.filter.matches(event, self.current_time_ns)) {
                if (count < output.len) {
                    output[count] = event.*;
                    count += 1;
                    self.progress.events_exported += 1;
                    self.progress.last_event_id = event.id;
                    self.progress.last_timestamp_ns = event.timestamp;
                }
            }
        }

        return output[0..count];
    }

    /// Export filtered events to a writer.
    pub fn exportFiltered(self: *Self, writer: anytype, events: []const GeoEvent) !void {
        for (events) |*event| {
            try self.data_exporter.writeEvent(writer, event);
        }
    }

    /// Write export header.
    pub fn writeHeader(self: *Self, writer: anytype) !void {
        try self.data_exporter.writeHeader(writer);
    }

    /// Write export footer.
    pub fn writeFooter(self: *Self, writer: anytype) !void {
        try self.data_exporter.writeFooter(writer);
        self.progress.completed = true;
    }

    /// Get current progress.
    pub fn getProgress(self: *const Self) ExportProgress {
        return self.progress;
    }

    /// Update bytes written (call after writing to track progress).
    pub fn updateBytesWritten(self: *Self, bytes: u64) void {
        self.progress.bytes_written += bytes;
    }
};

/// Export statistics for reporting.
pub const ExportStats = struct {
    /// Total events in source.
    total_events: u64,
    /// Events matching time filter.
    time_matched: u64,
    /// Events matching spatial filter.
    spatial_matched: u64,
    /// Events matching entity filter.
    entity_matched: u64,
    /// Final exported count.
    exported: u64,
    /// Export duration in nanoseconds.
    duration_ns: u64,
    /// Throughput in events/second.
    events_per_sec: f64,
    /// Throughput in MB/second.
    mb_per_sec: f64,
};

// =============================================================================
// Tests
// =============================================================================

test "TimeRange: contains" {
    const range = TimeRange{
        .start_ns = 1000,
        .end_ns = 2000,
    };

    try std.testing.expect(range.contains(1000)); // inclusive start
    try std.testing.expect(range.contains(1500));
    try std.testing.expect(!range.contains(2000)); // exclusive end
    try std.testing.expect(!range.contains(999));
}

test "TimeRange: forDay" {
    const range = TimeRange.forDay(2024, 1, 1);

    // 2024-01-01 00:00:00 UTC = 1704067200 seconds
    const expected_start: u64 = 1704067200 * 1_000_000_000;
    const expected_end: u64 = (1704067200 + 86400) * 1_000_000_000;

    try std.testing.expectEqual(expected_start, range.start_ns);
    try std.testing.expectEqual(expected_end, range.end_ns);
}

test "BoundingBox: contains" {
    const bbox = BoundingBox{
        .min_lat = 37.0,
        .max_lat = 38.0,
        .min_lon = -123.0,
        .max_lon = -122.0,
    };

    try std.testing.expect(bbox.contains(37.5, -122.5)); // Inside
    try std.testing.expect(bbox.contains(37.0, -123.0)); // On boundary
    try std.testing.expect(!bbox.contains(36.5, -122.5)); // Outside (south)
    try std.testing.expect(!bbox.contains(37.5, -121.0)); // Outside (east)
}

test "BoundingBox: containsEvent" {
    const bbox = BoundingBox{
        .min_lat = 37.0,
        .max_lat = 38.0,
        .min_lon = -123.0,
        .max_lon = -122.0,
    };

    var event = GeoEvent.zero();
    event.lat_nano = GeoEvent.lat_from_float(37.5);
    event.lon_nano = GeoEvent.lon_from_float(-122.5);

    try std.testing.expect(bbox.containsEvent(&event));

    event.lat_nano = GeoEvent.lat_from_float(36.0);
    try std.testing.expect(!bbox.containsEvent(&event));
}

test "BoundingBox: fromCenterRadius" {
    const bbox = BoundingBox.fromCenterRadius(37.7749, -122.4194, 10.0);

    // Should contain the center
    try std.testing.expect(bbox.contains(37.7749, -122.4194));

    // Should have reasonable bounds (~10km radius)
    try std.testing.expect(bbox.max_lat - bbox.min_lat > 0.15);
    try std.testing.expect(bbox.max_lat - bbox.min_lat < 0.25);
}

test "EntityFilter: matches" {
    const filter = EntityFilter{
        .exclude_deleted = true,
        .exclude_expired = false,
    };

    var event = GeoEvent.zero();
    event.entity_id = 123;
    event.group_id = 1;

    try std.testing.expect(filter.matches(&event, 0));

    event.flags.deleted = true;
    try std.testing.expect(!filter.matches(&event, 0));
}

test "EntityFilter: entity_ids filter" {
    const ids = [_]u128{ 100, 200, 300 };
    const filter = EntityFilter{
        .entity_ids = &ids,
    };

    var event = GeoEvent.zero();
    event.entity_id = 200;
    try std.testing.expect(filter.matches(&event, 0));

    event.entity_id = 999;
    try std.testing.expect(!filter.matches(&event, 0));
}

test "ExportFilter: combined filters" {
    const filter = ExportFilter{
        .time_range = .{ .start_ns = 1000, .end_ns = 2000 },
        .bounding_box = .{ .min_lat = 37.0, .max_lat = 38.0, .min_lon = -123.0, .max_lon = -122.0 },
    };

    var event = GeoEvent.zero();
    event.timestamp = 1500;
    event.lat_nano = GeoEvent.lat_from_float(37.5);
    event.lon_nano = GeoEvent.lon_from_float(-122.5);

    try std.testing.expect(filter.matches(&event, 0));

    // Outside time range
    event.timestamp = 500;
    try std.testing.expect(!filter.matches(&event, 0));

    // Reset time, outside bounding box
    event.timestamp = 1500;
    event.lat_nano = GeoEvent.lat_from_float(36.0);
    try std.testing.expect(!filter.matches(&event, 0));
}

test "BulkExporter: filterEvents" {
    const allocator = std.testing.allocator;

    const filter = ExportFilter{
        .bounding_box = .{ .min_lat = 37.0, .max_lat = 38.0, .min_lon = -123.0, .max_lon = -122.0 },
    };

    var exporter = BulkExporter.init(allocator, filter, .{});
    defer exporter.deinit();

    // Create test events
    var events: [3]GeoEvent = undefined;

    // Event 1: Inside bounding box
    events[0] = GeoEvent.zero();
    events[0].entity_id = 1;
    events[0].lat_nano = GeoEvent.lat_from_float(37.5);
    events[0].lon_nano = GeoEvent.lon_from_float(-122.5);

    // Event 2: Outside bounding box
    events[1] = GeoEvent.zero();
    events[1].entity_id = 2;
    events[1].lat_nano = GeoEvent.lat_from_float(36.0);
    events[1].lon_nano = GeoEvent.lon_from_float(-122.5);

    // Event 3: Inside bounding box
    events[2] = GeoEvent.zero();
    events[2].entity_id = 3;
    events[2].lat_nano = GeoEvent.lat_from_float(37.8);
    events[2].lon_nano = GeoEvent.lon_from_float(-122.8);

    var output: [3]GeoEvent = undefined;
    const filtered = exporter.filterEvents(&events, &output);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqual(@as(u128, 1), filtered[0].entity_id);
    try std.testing.expectEqual(@as(u128, 3), filtered[1].entity_id);

    // Check progress
    try std.testing.expectEqual(@as(u64, 3), exporter.progress.events_processed);
    try std.testing.expectEqual(@as(u64, 2), exporter.progress.events_exported);
}

test "ExportProgress: throughput calculation" {
    var progress = ExportProgress{
        .start_time_ns = 0,
        .bytes_written = 100 * 1024 * 1024, // 100 MB
    };

    // After 1 second
    const current_time: u64 = 1_000_000_000;
    const throughput = progress.throughputMBps(current_time);

    try std.testing.expectApproxEqAbs(@as(f64, 100.0), throughput, 0.1);
}

test "ExportProgress: filter ratio" {
    var progress = ExportProgress{
        .events_processed = 1000,
        .events_exported = 250,
    };

    try std.testing.expectApproxEqAbs(@as(f64, 0.25), progress.filterRatio(), 0.001);
}
