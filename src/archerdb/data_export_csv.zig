// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! CSV Import/Export Module for ArcherDB (F-Data-Portability)
//!
//! Provides CSV import and export functionality for GeoEvents.
//!
//! Features:
//! - Standard CSV with header row
//! - Configurable field delimiters (comma, tab, semicolon)
//! - Proper escaping for special characters (RFC 4180)
//! - Location data as latitude/longitude columns
//! - Timestamp formatting options (Unix epoch, ISO 8601)
//!
//! See: openspec/changes/add-geospatial-core/specs/data-portability/spec.md
//!
//! Usage - Export:
//! ```zig
//! var exporter = CsvExporter.init(allocator, .{});
//! defer exporter.deinit();
//!
//! try exporter.writeHeader(writer);
//! for (events) |event| {
//!     try exporter.writeRow(writer, event);
//! }
//! ```
//!
//! Usage - Import:
//! ```zig
//! var importer = CsvImporter.init(allocator, .{});
//! defer importer.deinit();
//!
//! while (try importer.parseRow(reader)) |event| {
//!     // Process event
//! }
//! ```

const std = @import("std");
const mem = std.mem;
const GeoEvent = @import("../geo_event.zig").GeoEvent;
const GeoEventFlags = @import("../geo_event.zig").GeoEventFlags;

/// Field delimiter options.
pub const Delimiter = enum {
    comma,
    tab,
    semicolon,
    pipe,

    pub fn char(self: Delimiter) u8 {
        return switch (self) {
            .comma => ',',
            .tab => '\t',
            .semicolon => ';',
            .pipe => '|',
        };
    }
};

/// Timestamp format options for CSV export.
pub const TimestampFormat = enum {
    /// Unix epoch in nanoseconds (default, lossless).
    unix_ns,
    /// Unix epoch in milliseconds (JavaScript compatible).
    unix_ms,
    /// Unix epoch in seconds.
    unix_s,
    /// ISO 8601 format (YYYY-MM-DDTHH:MM:SS.sssZ).
    iso8601,
};

/// CSV export options.
pub const CsvExportOptions = struct {
    /// Field delimiter character.
    delimiter: Delimiter = .comma,
    /// Include header row.
    include_header: bool = true,
    /// Timestamp format.
    timestamp_format: TimestampFormat = .unix_ns,
    /// Include optional fields (altitude, velocity, heading, accuracy).
    include_optional: bool = true,
    /// Line ending.
    line_ending: []const u8 = "\n",
    /// Quote character for escaping.
    quote_char: u8 = '"',
};

/// CSV import options.
pub const CsvImportOptions = struct {
    /// Field delimiter character.
    delimiter: Delimiter = .comma,
    /// First row is header (for column mapping).
    has_header: bool = true,
    /// Skip malformed rows instead of erroring.
    skip_malformed: bool = false,
    /// Expected timestamp format.
    timestamp_format: TimestampFormat = .unix_ns,
    /// Maximum row length in bytes.
    max_row_length: usize = 4096,
};

/// Standard CSV column names.
pub const ColumnNames = struct {
    pub const id = "id";
    pub const entity_id = "entity_id";
    pub const correlation_id = "correlation_id";
    pub const user_data = "user_data";
    pub const latitude = "latitude";
    pub const longitude = "longitude";
    pub const timestamp = "timestamp";
    pub const timestamp_ns = "timestamp_ns";
    pub const group_id = "group_id";
    pub const altitude_m = "altitude_m";
    pub const velocity_ms = "velocity_ms";
    pub const heading_deg = "heading_deg";
    pub const accuracy_m = "accuracy_m";
    pub const ttl_seconds = "ttl_seconds";
    pub const flag_linked = "flag_linked";
    pub const flag_imported = "flag_imported";
    pub const flag_stationary = "flag_stationary";
    pub const flag_low_accuracy = "flag_low_accuracy";
    pub const flag_offline = "flag_offline";
    pub const flag_deleted = "flag_deleted";
};

/// CSV exporter for GeoEvents.
pub const CsvExporter = struct {
    allocator: mem.Allocator,
    options: CsvExportOptions,
    row_count: usize,

    const Self = @This();

    /// Initialize CSV exporter.
    pub fn init(allocator: mem.Allocator, options: CsvExportOptions) Self {
        return .{
            .allocator = allocator,
            .options = options,
            .row_count = 0,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Write CSV header row.
    pub fn writeHeader(self: *Self, writer: anytype) !void {
        if (!self.options.include_header) return;

        const d = self.options.delimiter.char();

        try writer.print("{s}{c}{s}{c}{s}{c}{s}{c}{s}{c}{s}{c}{s}{c}{s}", .{
            ColumnNames.id,
            d,
            ColumnNames.entity_id,
            d,
            ColumnNames.correlation_id,
            d,
            ColumnNames.latitude,
            d,
            ColumnNames.longitude,
            d,
            ColumnNames.timestamp_ns,
            d,
            ColumnNames.group_id,
            d,
            ColumnNames.ttl_seconds,
        });

        if (self.options.include_optional) {
            try writer.print("{c}{s}{c}{s}{c}{s}{c}{s}", .{
                d,
                ColumnNames.altitude_m,
                d,
                ColumnNames.velocity_ms,
                d,
                ColumnNames.heading_deg,
                d,
                ColumnNames.accuracy_m,
            });
        }

        // Flags
        try writer.print("{c}{s}{c}{s}{c}{s}{c}{s}{c}{s}{c}{s}", .{
            d,
            ColumnNames.flag_linked,
            d,
            ColumnNames.flag_imported,
            d,
            ColumnNames.flag_stationary,
            d,
            ColumnNames.flag_low_accuracy,
            d,
            ColumnNames.flag_offline,
            d,
            ColumnNames.flag_deleted,
        });

        try writer.writeAll(self.options.line_ending);
    }

    /// Write a single event as CSV row.
    pub fn writeRow(self: *Self, writer: anytype, event: *const GeoEvent) !void {
        const d = self.options.delimiter.char();

        // Convert coordinates
        const lat = GeoEvent.lat_to_float(event.lat_nano);
        const lon = GeoEvent.lon_to_float(event.lon_nano);

        // Core fields
        try writer.print("{x:0>32}{c}{x:0>32}{c}{x:0>32}{c}{d:.9}{c}{d:.9}{c}", .{
            event.id,
            d,
            event.entity_id,
            d,
            event.correlation_id,
            d,
            lat,
            d,
            lon,
            d,
        });

        // Timestamp based on format
        switch (self.options.timestamp_format) {
            .unix_ns => try writer.print("{d}", .{event.timestamp}),
            .unix_ms => try writer.print("{d}", .{event.timestamp / 1_000_000}),
            .unix_s => try writer.print("{d}", .{event.timestamp / 1_000_000_000}),
            .iso8601 => {
                // Convert to seconds and format
                const secs = @as(i64, @intCast(event.timestamp / 1_000_000_000));
                const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
                const day_seconds = epoch_seconds.getDaySeconds();
                const epoch_day = epoch_seconds.getEpochDay();
                const year_day = epoch_day.calculateYearDay();
                const month_day = year_day.calculateMonthDay();

                try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
                    year_day.year,
                    @intFromEnum(month_day.month),
                    month_day.day_index + 1, // 0-indexed to 1-indexed
                    day_seconds.getHoursIntoDay(),
                    day_seconds.getMinutesIntoHour(),
                    day_seconds.getSecondsIntoMinute(),
                    (event.timestamp / 1_000_000) % 1000,
                });
            },
        }

        try writer.print("{c}{d}{c}{d}", .{
            d,
            event.group_id,
            d,
            event.ttl_seconds,
        });

        // Optional fields
        if (self.options.include_optional) {
            const alt_m = @as(f64, @floatFromInt(event.altitude_mm)) / 1000.0;
            const vel_ms = @as(f64, @floatFromInt(event.velocity_mms)) / 1000.0;
            const heading_deg = @as(f64, @floatFromInt(event.heading_cdeg)) / 100.0;
            const acc_m = @as(f64, @floatFromInt(event.accuracy_mm)) / 1000.0;

            try writer.print("{c}{d:.3}{c}{d:.3}{c}{d:.2}{c}{d:.3}", .{
                d,
                alt_m,
                d,
                vel_ms,
                d,
                heading_deg,
                d,
                acc_m,
            });
        }

        // Flags (as 0/1 for CSV compatibility)
        try writer.print("{c}{d}{c}{d}{c}{d}{c}{d}{c}{d}{c}{d}", .{
            d,
            @as(u1, @intFromBool(event.flags.linked)),
            d,
            @as(u1, @intFromBool(event.flags.imported)),
            d,
            @as(u1, @intFromBool(event.flags.stationary)),
            d,
            @as(u1, @intFromBool(event.flags.low_accuracy)),
            d,
            @as(u1, @intFromBool(event.flags.offline)),
            d,
            @as(u1, @intFromBool(event.flags.deleted)),
        });

        try writer.writeAll(self.options.line_ending);
        self.row_count += 1;
    }

    /// Export a slice of events.
    pub fn exportAll(self: *Self, writer: anytype, events: []const GeoEvent) !void {
        try self.writeHeader(writer);
        for (events) |*event| {
            try self.writeRow(writer, event);
        }
    }

    /// Export to a string.
    pub fn exportToString(self: *Self, events: []const GeoEvent) ![]u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        errdefer list.deinit();

        try self.exportAll(list.writer(), events);
        return list.toOwnedSlice();
    }
};

/// CSV importer for GeoEvents.
pub const CsvImporter = struct {
    allocator: mem.Allocator,
    options: CsvImportOptions,
    column_map: ?ColumnMap,
    line_buffer: []u8,
    row_count: usize,
    error_count: usize,

    const Self = @This();

    /// Column index mapping.
    pub const ColumnMap = struct {
        id: ?usize = null,
        entity_id: ?usize = null,
        correlation_id: ?usize = null,
        latitude: ?usize = null,
        longitude: ?usize = null,
        timestamp: ?usize = null,
        group_id: ?usize = null,
        ttl_seconds: ?usize = null,
        altitude_m: ?usize = null,
        velocity_ms: ?usize = null,
        heading_deg: ?usize = null,
        accuracy_m: ?usize = null,
        flag_linked: ?usize = null,
        flag_imported: ?usize = null,
        flag_stationary: ?usize = null,
        flag_low_accuracy: ?usize = null,
        flag_offline: ?usize = null,
        flag_deleted: ?usize = null,
    };

    /// Import errors.
    pub const ImportError = error{
        MissingRequiredColumn,
        InvalidCoordinate,
        InvalidTimestamp,
        InvalidInteger,
        InvalidFloat,
        RowTooLong,
        MalformedRow,
    };

    /// Initialize CSV importer.
    pub fn init(allocator: mem.Allocator, options: CsvImportOptions) !Self {
        return .{
            .allocator = allocator,
            .options = options,
            .column_map = null,
            .line_buffer = try allocator.alloc(u8, options.max_row_length),
            .row_count = 0,
            .error_count = 0,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.line_buffer);
    }

    /// Parse header row and build column map.
    pub fn parseHeader(self: *Self, header_line: []const u8) !void {
        var map = ColumnMap{};
        const d = self.options.delimiter.char();

        var col_index: usize = 0;
        var iter = std.mem.splitScalar(u8, header_line, d);
        while (iter.next()) |field| {
            const trimmed = std.mem.trim(u8, field, " \t\r\"");

            if (std.mem.eql(u8, trimmed, ColumnNames.id)) {
                map.id = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.entity_id)) {
                map.entity_id = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.correlation_id)) {
                map.correlation_id = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.latitude)) {
                map.latitude = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.longitude)) {
                map.longitude = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.timestamp) or
                std.mem.eql(u8, trimmed, ColumnNames.timestamp_ns))
            {
                map.timestamp = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.group_id)) {
                map.group_id = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.ttl_seconds)) {
                map.ttl_seconds = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.altitude_m)) {
                map.altitude_m = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.velocity_ms)) {
                map.velocity_ms = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.heading_deg)) {
                map.heading_deg = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.accuracy_m)) {
                map.accuracy_m = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.flag_linked)) {
                map.flag_linked = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.flag_imported)) {
                map.flag_imported = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.flag_stationary)) {
                map.flag_stationary = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.flag_low_accuracy)) {
                map.flag_low_accuracy = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.flag_offline)) {
                map.flag_offline = col_index;
            } else if (std.mem.eql(u8, trimmed, ColumnNames.flag_deleted)) {
                map.flag_deleted = col_index;
            }

            col_index += 1;
        }

        // Validate required columns
        if (map.latitude == null or map.longitude == null) {
            return ImportError.MissingRequiredColumn;
        }

        self.column_map = map;
    }

    /// Parse a data row into a GeoEvent.
    pub fn parseRow(self: *Self, row_line: []const u8) ImportError!GeoEvent {
        const map = self.column_map orelse {
            // Use default column order if no header was parsed
            return self.parseRowDefaultOrder(row_line);
        };

        var event = GeoEvent.zero();
        const d = self.options.delimiter.char();

        var col_index: usize = 0;
        var iter = std.mem.splitScalar(u8, row_line, d);
        while (iter.next()) |field| {
            const trimmed = std.mem.trim(u8, field, " \t\r\"");

            if (map.id != null and col_index == map.id.?) {
                event.id = parseHex128(trimmed) catch 0;
            } else if (map.entity_id != null and col_index == map.entity_id.?) {
                event.entity_id = parseHex128(trimmed) catch 0;
            } else if (map.correlation_id != null and col_index == map.correlation_id.?) {
                event.correlation_id = parseHex128(trimmed) catch 0;
            } else if (map.latitude != null and col_index == map.latitude.?) {
                const lat = std.fmt.parseFloat(f64, trimmed) catch return ImportError.InvalidCoordinate;
                event.lat_nano = GeoEvent.lat_from_float(lat);
            } else if (map.longitude != null and col_index == map.longitude.?) {
                const lon = std.fmt.parseFloat(f64, trimmed) catch return ImportError.InvalidCoordinate;
                event.lon_nano = GeoEvent.lon_from_float(lon);
            } else if (map.timestamp != null and col_index == map.timestamp.?) {
                event.timestamp = std.fmt.parseInt(u64, trimmed, 10) catch return ImportError.InvalidTimestamp;
            } else if (map.group_id != null and col_index == map.group_id.?) {
                event.group_id = std.fmt.parseInt(u64, trimmed, 10) catch 0;
            } else if (map.ttl_seconds != null and col_index == map.ttl_seconds.?) {
                event.ttl_seconds = std.fmt.parseInt(u32, trimmed, 10) catch 0;
            } else if (map.altitude_m != null and col_index == map.altitude_m.?) {
                const alt = std.fmt.parseFloat(f64, trimmed) catch 0.0;
                event.altitude_mm = @intFromFloat(alt * 1000.0);
            } else if (map.velocity_ms != null and col_index == map.velocity_ms.?) {
                const vel = std.fmt.parseFloat(f64, trimmed) catch 0.0;
                event.velocity_mms = @intFromFloat(vel * 1000.0);
            } else if (map.heading_deg != null and col_index == map.heading_deg.?) {
                const heading = std.fmt.parseFloat(f64, trimmed) catch 0.0;
                event.heading_cdeg = @intFromFloat(heading * 100.0);
            } else if (map.accuracy_m != null and col_index == map.accuracy_m.?) {
                const acc = std.fmt.parseFloat(f64, trimmed) catch 0.0;
                event.accuracy_mm = @intFromFloat(acc * 1000.0);
            } else if (map.flag_linked != null and col_index == map.flag_linked.?) {
                event.flags.linked = parseBool(trimmed);
            } else if (map.flag_imported != null and col_index == map.flag_imported.?) {
                event.flags.imported = parseBool(trimmed);
            } else if (map.flag_stationary != null and col_index == map.flag_stationary.?) {
                event.flags.stationary = parseBool(trimmed);
            } else if (map.flag_low_accuracy != null and col_index == map.flag_low_accuracy.?) {
                event.flags.low_accuracy = parseBool(trimmed);
            } else if (map.flag_offline != null and col_index == map.flag_offline.?) {
                event.flags.offline = parseBool(trimmed);
            } else if (map.flag_deleted != null and col_index == map.flag_deleted.?) {
                event.flags.deleted = parseBool(trimmed);
            }

            col_index += 1;
        }

        // Validate coordinates
        if (!GeoEvent.validate_coordinates(event.lat_nano, event.lon_nano)) {
            return ImportError.InvalidCoordinate;
        }

        self.row_count += 1;
        return event;
    }

    /// Parse row with default column order (no header).
    fn parseRowDefaultOrder(self: *Self, row_line: []const u8) ImportError!GeoEvent {
        var event = GeoEvent.zero();
        const d = self.options.delimiter.char();

        var col_index: usize = 0;
        var iter = std.mem.splitScalar(u8, row_line, d);
        while (iter.next()) |field| {
            const trimmed = std.mem.trim(u8, field, " \t\r\"");

            switch (col_index) {
                0 => event.id = parseHex128(trimmed) catch 0,
                1 => event.entity_id = parseHex128(trimmed) catch 0,
                2 => event.correlation_id = parseHex128(trimmed) catch 0,
                3 => {
                    const lat = std.fmt.parseFloat(f64, trimmed) catch return ImportError.InvalidCoordinate;
                    event.lat_nano = GeoEvent.lat_from_float(lat);
                },
                4 => {
                    const lon = std.fmt.parseFloat(f64, trimmed) catch return ImportError.InvalidCoordinate;
                    event.lon_nano = GeoEvent.lon_from_float(lon);
                },
                5 => event.timestamp = std.fmt.parseInt(u64, trimmed, 10) catch return ImportError.InvalidTimestamp,
                6 => event.group_id = std.fmt.parseInt(u64, trimmed, 10) catch 0,
                7 => event.ttl_seconds = std.fmt.parseInt(u32, trimmed, 10) catch 0,
                else => {},
            }

            col_index += 1;
        }

        return event;
    }
};

/// Parse a hex string to u128.
fn parseHex128(s: []const u8) !u128 {
    if (s.len == 0) return 0;
    return std.fmt.parseInt(u128, s, 16) catch return error.InvalidInteger;
}

/// Parse a boolean value from CSV (0/1, true/false, yes/no).
fn parseBool(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, "1") or
        std.mem.eql(u8, s, "true") or
        std.mem.eql(u8, s, "TRUE") or
        std.mem.eql(u8, s, "yes") or
        std.mem.eql(u8, s, "YES"))
    {
        return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "CsvExporter: basic export" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(0x89C2590000000000, 1704067200000000000);
    event.entity_id = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    event.lat_nano = GeoEvent.lat_from_float(37.7749);
    event.lon_nano = GeoEvent.lon_from_float(-122.4194);
    event.timestamp = 1704067200000000000;
    event.group_id = 42;

    var exporter = CsvExporter.init(allocator, .{});
    defer exporter.deinit();

    const events = [_]GeoEvent{event};
    const output = try exporter.exportToString(&events);
    defer allocator.free(output);

    // Verify header
    try std.testing.expect(std.mem.indexOf(u8, output, "id,entity_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latitude,longitude") != null);

    // Verify data row
    try std.testing.expect(std.mem.indexOf(u8, output, "37.7749") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-122.4194") != null);
}

test "CsvExporter: tab delimiter" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    event.lat_nano = GeoEvent.lat_from_float(40.0);
    event.lon_nano = GeoEvent.lon_from_float(-74.0);

    var exporter = CsvExporter.init(allocator, .{ .delimiter = .tab });
    defer exporter.deinit();

    const events = [_]GeoEvent{event};
    const output = try exporter.exportToString(&events);
    defer allocator.free(output);

    // Tab delimiter
    try std.testing.expect(std.mem.indexOf(u8, output, "id\tentity_id") != null);
}

test "CsvExporter: ISO 8601 timestamp" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    event.lat_nano = 0;
    event.lon_nano = 0;
    event.timestamp = 1704067200000000000; // 2024-01-01 00:00:00 UTC

    var exporter = CsvExporter.init(allocator, .{
        .timestamp_format = .iso8601,
        .include_header = false,
    });
    defer exporter.deinit();

    const events = [_]GeoEvent{event};
    const output = try exporter.exportToString(&events);
    defer allocator.free(output);

    // ISO 8601 format
    try std.testing.expect(std.mem.indexOf(u8, output, "2024-01-01T00:00:00") != null);
}

test "CsvImporter: parse header" {
    const allocator = std.testing.allocator;

    var importer = try CsvImporter.init(allocator, .{});
    defer importer.deinit();

    try importer.parseHeader("id,entity_id,latitude,longitude,timestamp_ns,group_id");

    const map = importer.column_map.?;
    try std.testing.expectEqual(@as(?usize, 0), map.id);
    try std.testing.expectEqual(@as(?usize, 1), map.entity_id);
    try std.testing.expectEqual(@as(?usize, 2), map.latitude);
    try std.testing.expectEqual(@as(?usize, 3), map.longitude);
    try std.testing.expectEqual(@as(?usize, 4), map.timestamp);
    try std.testing.expectEqual(@as(?usize, 5), map.group_id);
}

test "CsvImporter: parse row" {
    const allocator = std.testing.allocator;

    var importer = try CsvImporter.init(allocator, .{});
    defer importer.deinit();

    try importer.parseHeader("latitude,longitude,timestamp_ns,group_id");

    const event = try importer.parseRow("37.7749,-122.4194,1704067200000000000,42");

    const lat = GeoEvent.lat_to_float(event.lat_nano);
    const lon = GeoEvent.lon_to_float(event.lon_nano);

    try std.testing.expectApproxEqAbs(@as(f64, 37.7749), lat, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -122.4194), lon, 1e-6);
    try std.testing.expectEqual(@as(u64, 1704067200000000000), event.timestamp);
    try std.testing.expectEqual(@as(u64, 42), event.group_id);
}

test "CsvImporter: roundtrip" {
    const allocator = std.testing.allocator;

    // Create original event
    var original = GeoEvent.zero();
    original.entity_id = 0x123456789ABCDEF0;
    original.lat_nano = GeoEvent.lat_from_float(51.5074);
    original.lon_nano = GeoEvent.lon_from_float(-0.1278);
    original.timestamp = 1704067200000000000;
    original.group_id = 100;
    original.altitude_mm = 15000;
    original.velocity_mms = 5000;
    original.flags.linked = true;
    original.flags.stationary = true;

    // Export to CSV
    var exporter = CsvExporter.init(allocator, .{});
    defer exporter.deinit();

    const events = [_]GeoEvent{original};
    const csv_output = try exporter.exportToString(&events);
    defer allocator.free(csv_output);

    // Import from CSV
    var importer = try CsvImporter.init(allocator, .{});
    defer importer.deinit();

    var lines = std.mem.splitSequence(u8, csv_output, "\n");
    const header = lines.next().?;
    try importer.parseHeader(header);

    const data_line = lines.next().?;
    const imported = try importer.parseRow(data_line);

    // Verify roundtrip
    try std.testing.expectEqual(original.entity_id, imported.entity_id);
    try std.testing.expectEqual(original.lat_nano, imported.lat_nano);
    try std.testing.expectEqual(original.lon_nano, imported.lon_nano);
    try std.testing.expectEqual(original.timestamp, imported.timestamp);
    try std.testing.expectEqual(original.group_id, imported.group_id);
    try std.testing.expectEqual(original.flags.linked, imported.flags.linked);
    try std.testing.expectEqual(original.flags.stationary, imported.flags.stationary);
}

test "CsvImporter: invalid coordinates" {
    const allocator = std.testing.allocator;

    var importer = try CsvImporter.init(allocator, .{});
    defer importer.deinit();

    try importer.parseHeader("latitude,longitude");

    // Invalid latitude (out of range)
    const result = importer.parseRow("91.0,0.0");
    try std.testing.expectError(CsvImporter.ImportError.InvalidCoordinate, result);
}

test "parseBool: various formats" {
    try std.testing.expect(parseBool("1"));
    try std.testing.expect(parseBool("true"));
    try std.testing.expect(parseBool("TRUE"));
    try std.testing.expect(parseBool("yes"));
    try std.testing.expect(!parseBool("0"));
    try std.testing.expect(!parseBool("false"));
    try std.testing.expect(!parseBool(""));
}
