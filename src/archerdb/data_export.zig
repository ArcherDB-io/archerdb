// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Data Export Module for ArcherDB (F-Data-Portability)
//!
//! Provides export functionality for GeoEvents in multiple formats:
//! - JSON: Human-readable with schema versioning (RFC 8259)
//! - GeoJSON: RFC 7946 compliant geospatial format
//! - CSV: Tabular format for spreadsheet analysis (see data_export_csv.zig)
//!
//! See: openspec/changes/add-geospatial-core/specs/data-portability/spec.md
//!
//! Usage:
//! ```zig
//! var exporter = DataExporter.init(allocator, .{
//!     .format = .geojson,
//!     .include_metadata = true,
//! });
//! defer exporter.deinit();
//!
//! try exporter.writeHeader(writer);
//! for (events) |event| {
//!     try exporter.writeEvent(writer, event);
//! }
//! try exporter.writeFooter(writer);
//! ```

const std = @import("std");
const mem = std.mem;
const GeoEvent = @import("../geo_event.zig").GeoEvent;
const GeoEventFlags = @import("../geo_event.zig").GeoEventFlags;

/// Current schema version for JSON export format.
/// Increment when making breaking changes to the export format.
pub const SCHEMA_VERSION = "1.0.0";

/// Export format types.
pub const ExportFormat = enum {
    /// Standard JSON format (RFC 8259).
    json,
    /// GeoJSON format (RFC 7946).
    geojson,
    /// Newline-delimited JSON (one record per line).
    ndjson,
};

/// Export options.
pub const ExportOptions = struct {
    /// Output format.
    format: ExportFormat = .json,
    /// Include schema version and metadata in output.
    include_metadata: bool = true,
    /// Pretty-print with indentation (slower, larger output).
    pretty: bool = false,
    /// Include null fields in output.
    include_nulls: bool = false,
    /// Coordinate precision (decimal places for lat/lon).
    coordinate_precision: u4 = 9,
};

/// GeoJSON Feature type.
pub const GeoJSONFeature = struct {
    type_: []const u8 = "Feature",
    geometry: GeoJSONGeometry,
    properties: GeoJSONProperties,
    id: ?[]const u8 = null,
};

/// GeoJSON Point geometry.
pub const GeoJSONGeometry = struct {
    type_: []const u8 = "Point",
    coordinates: [2]f64, // [longitude, latitude] per RFC 7946
};

/// GeoJSON Feature properties (mapped from GeoEvent fields).
pub const GeoJSONProperties = struct {
    entity_id: []const u8,
    correlation_id: ?[]const u8,
    timestamp: i64, // Unix milliseconds for JavaScript compatibility
    timestamp_ns: u64, // Original nanosecond precision
    altitude_m: ?f64,
    velocity_ms: ?f64,
    heading_deg: ?f64,
    accuracy_m: ?f64,
    ttl_seconds: ?u32,
    group_id: u64,
    flags: FlagProperties,
};

/// Exported flag properties.
pub const FlagProperties = struct {
    linked: bool,
    imported: bool,
    stationary: bool,
    low_accuracy: bool,
    offline: bool,
    deleted: bool,
};

/// Data exporter for streaming export of GeoEvents.
pub const DataExporter = struct {
    allocator: mem.Allocator,
    options: ExportOptions,
    event_count: usize,
    started: bool,

    const Self = @This();

    /// Initialize a new data exporter.
    pub fn init(allocator: mem.Allocator, options: ExportOptions) Self {
        return .{
            .allocator = allocator,
            .options = options,
            .event_count = 0,
            .started = false,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *Self) void {
        _ = self;
        // No allocations to free currently
    }

    /// Write export header (for formats that need it).
    pub fn writeHeader(self: *Self, writer: anytype) !void {
        self.started = true;
        self.event_count = 0;

        switch (self.options.format) {
            .json => {
                if (self.options.pretty) {
                    try writer.writeAll("{\n");
                    if (self.options.include_metadata) {
                        try writer.writeAll("  \"$schema\": \"archerdb-export-v1\",\n");
                        try writer.print("  \"schema_version\": \"{s}\",\n", .{SCHEMA_VERSION});
                        try writer.writeAll("  \"format\": \"json\",\n");
                    }
                    try writer.writeAll("  \"events\": [\n");
                } else {
                    try writer.writeAll("{");
                    if (self.options.include_metadata) {
                        try writer.writeAll("\"$schema\":\"archerdb-export-v1\",");
                        try writer.print("\"schema_version\":\"{s}\",", .{SCHEMA_VERSION});
                        try writer.writeAll("\"format\":\"json\",");
                    }
                    try writer.writeAll("\"events\":[");
                }
            },
            .geojson => {
                if (self.options.pretty) {
                    try writer.writeAll("{\n");
                    try writer.writeAll("  \"type\": \"FeatureCollection\",\n");
                    if (self.options.include_metadata) {
                        try writer.writeAll("  \"$schema\": \"archerdb-geojson-v1\",\n");
                        try writer.print("  \"schema_version\": \"{s}\",\n", .{SCHEMA_VERSION});
                    }
                    try writer.writeAll("  \"features\": [\n");
                } else {
                    try writer.writeAll("{\"type\":\"FeatureCollection\",");
                    if (self.options.include_metadata) {
                        try writer.writeAll("\"$schema\":\"archerdb-geojson-v1\",");
                        try writer.print("\"schema_version\":\"{s}\",", .{SCHEMA_VERSION});
                    }
                    try writer.writeAll("\"features\":[");
                }
            },
            .ndjson => {
                // NDJSON has no header
            },
        }
    }

    /// Write a single GeoEvent.
    pub fn writeEvent(self: *Self, writer: anytype, event: *const GeoEvent) !void {
        if (!self.started and self.options.format != .ndjson) {
            return error.HeaderNotWritten;
        }

        // Write separator for non-first events
        if (self.event_count > 0) {
            switch (self.options.format) {
                .json, .geojson => {
                    if (self.options.pretty) {
                        try writer.writeAll(",\n");
                    } else {
                        try writer.writeAll(",");
                    }
                },
                .ndjson => {
                    // Each line is independent
                },
            }
        }

        switch (self.options.format) {
            .json => try self.writeJsonEvent(writer, event),
            .geojson => try self.writeGeoJsonFeature(writer, event),
            .ndjson => {
                try self.writeJsonEvent(writer, event);
                try writer.writeAll("\n");
            },
        }

        self.event_count += 1;
    }

    /// Write export footer.
    pub fn writeFooter(self: *Self, writer: anytype) !void {
        switch (self.options.format) {
            .json => {
                if (self.options.pretty) {
                    try writer.writeAll("\n  ],\n");
                    try writer.print("  \"count\": {d}\n", .{self.event_count});
                    try writer.writeAll("}\n");
                } else {
                    try writer.writeAll("],");
                    try writer.print("\"count\":{d}", .{self.event_count});
                    try writer.writeAll("}");
                }
            },
            .geojson => {
                if (self.options.pretty) {
                    try writer.writeAll("\n  ],\n");
                    try writer.print("  \"totalFeatures\": {d}\n", .{self.event_count});
                    try writer.writeAll("}\n");
                } else {
                    try writer.writeAll("],");
                    try writer.print("\"totalFeatures\":{d}", .{self.event_count});
                    try writer.writeAll("}");
                }
            },
            .ndjson => {
                // NDJSON has no footer
            },
        }
    }

    /// Write a single event in JSON format.
    fn writeJsonEvent(self: *Self, writer: anytype, event: *const GeoEvent) !void {
        const indent = if (self.options.pretty) "    " else "";
        const newline = if (self.options.pretty) "\n" else "";
        const sep = if (self.options.pretty) ": " else ":";

        try writer.print("{s}{{", .{indent});
        try writer.print("{s}{s}\"id\"{s}\"{x:0>32}\",", .{ newline, indent, sep, event.id });
        try writer.print("{s}{s}\"entity_id\"{s}\"{x:0>32}\",", .{ newline, indent, sep, event.entity_id });

        if (event.correlation_id != 0 or self.options.include_nulls) {
            try writer.print("{s}{s}\"correlation_id\"{s}\"{x:0>32}\",", .{ newline, indent, sep, event.correlation_id });
        }

        if (event.user_data != 0 or self.options.include_nulls) {
            try writer.print("{s}{s}\"user_data\"{s}\"{x:0>32}\",", .{ newline, indent, sep, event.user_data });
        }

        // Coordinates
        const lat = GeoEvent.lat_to_float(event.lat_nano);
        const lon = GeoEvent.lon_to_float(event.lon_nano);
        try writer.print("{s}{s}\"latitude\"{s}{d:.9},", .{ newline, indent, sep, lat });
        try writer.print("{s}{s}\"longitude\"{s}{d:.9},", .{ newline, indent, sep, lon });

        // Timestamp
        try writer.print("{s}{s}\"timestamp_ns\"{s}{d},", .{ newline, indent, sep, event.timestamp });
        // Also include ISO 8601 timestamp for human readability
        const timestamp_ms = event.timestamp / 1_000_000;
        try writer.print("{s}{s}\"timestamp_ms\"{s}{d},", .{ newline, indent, sep, timestamp_ms });

        try writer.print("{s}{s}\"group_id\"{s}{d},", .{ newline, indent, sep, event.group_id });

        // Optional numeric fields
        if (event.altitude_mm != 0 or self.options.include_nulls) {
            const alt_m = @as(f64, @floatFromInt(event.altitude_mm)) / 1000.0;
            try writer.print("{s}{s}\"altitude_m\"{s}{d:.3},", .{ newline, indent, sep, alt_m });
        }

        if (event.velocity_mms != 0 or self.options.include_nulls) {
            const vel_ms = @as(f64, @floatFromInt(event.velocity_mms)) / 1000.0;
            try writer.print("{s}{s}\"velocity_ms\"{s}{d:.3},", .{ newline, indent, sep, vel_ms });
        }

        if (event.heading_cdeg != 0 or self.options.include_nulls) {
            const heading_deg = @as(f64, @floatFromInt(event.heading_cdeg)) / 100.0;
            try writer.print("{s}{s}\"heading_deg\"{s}{d:.2},", .{ newline, indent, sep, heading_deg });
        }

        if (event.accuracy_mm != 0 or self.options.include_nulls) {
            const acc_m = @as(f64, @floatFromInt(event.accuracy_mm)) / 1000.0;
            try writer.print("{s}{s}\"accuracy_m\"{s}{d:.3},", .{ newline, indent, sep, acc_m });
        }

        if (event.ttl_seconds != 0 or self.options.include_nulls) {
            try writer.print("{s}{s}\"ttl_seconds\"{s}{d},", .{ newline, indent, sep, event.ttl_seconds });
        }

        // Flags
        try writer.print("{s}{s}\"flags\"{s}{{", .{ newline, indent, sep });
        try writer.print("\"linked\"{s}{},", .{ sep, event.flags.linked });
        try writer.print("\"imported\"{s}{},", .{ sep, event.flags.imported });
        try writer.print("\"stationary\"{s}{},", .{ sep, event.flags.stationary });
        try writer.print("\"low_accuracy\"{s}{},", .{ sep, event.flags.low_accuracy });
        try writer.print("\"offline\"{s}{},", .{ sep, event.flags.offline });
        try writer.print("\"deleted\"{s}{}", .{ sep, event.flags.deleted });
        try writer.writeAll("}");

        try writer.print("{s}{s}}}", .{ newline, indent });
    }

    /// Write a single event as a GeoJSON Feature.
    fn writeGeoJsonFeature(self: *Self, writer: anytype, event: *const GeoEvent) !void {
        const indent = if (self.options.pretty) "    " else "";
        const indent2 = if (self.options.pretty) "      " else "";
        const newline = if (self.options.pretty) "\n" else "";
        const sep = if (self.options.pretty) ": " else ":";

        // Convert coordinates
        const lat = GeoEvent.lat_to_float(event.lat_nano);
        const lon = GeoEvent.lon_to_float(event.lon_nano);

        // GeoJSON Feature
        try writer.print("{s}{{", .{indent});
        try writer.print("{s}{s}\"type\"{s}\"Feature\",", .{ newline, indent2, sep });

        // Feature ID (using event ID as hex string)
        try writer.print("{s}{s}\"id\"{s}\"{x:0>32}\",", .{ newline, indent2, sep, event.id });

        // Geometry (Point)
        try writer.print("{s}{s}\"geometry\"{s}{{", .{ newline, indent2, sep });
        try writer.print("\"type\"{s}\"Point\",", .{sep});
        // RFC 7946: coordinates are [longitude, latitude]
        try writer.print("\"coordinates\"{s}[{d:.9},{d:.9}]", .{ sep, lon, lat });
        try writer.writeAll("},");

        // Properties
        try writer.print("{s}{s}\"properties\"{s}{{", .{ newline, indent2, sep });

        try writer.print("\"entity_id\"{s}\"{x:0>32}\",", .{ sep, event.entity_id });

        if (event.correlation_id != 0) {
            try writer.print("\"correlation_id\"{s}\"{x:0>32}\",", .{ sep, event.correlation_id });
        }

        // Timestamps
        const timestamp_ms: i64 = @intCast(event.timestamp / 1_000_000);
        try writer.print("\"timestamp\"{s}{d},", .{ sep, timestamp_ms });
        try writer.print("\"timestamp_ns\"{s}{d},", .{ sep, event.timestamp });

        try writer.print("\"group_id\"{s}{d},", .{ sep, event.group_id });

        // Optional fields with unit conversions
        if (event.altitude_mm != 0) {
            const alt_m = @as(f64, @floatFromInt(event.altitude_mm)) / 1000.0;
            try writer.print("\"altitude_m\"{s}{d:.3},", .{ sep, alt_m });
        }

        if (event.velocity_mms != 0) {
            const vel_ms = @as(f64, @floatFromInt(event.velocity_mms)) / 1000.0;
            try writer.print("\"velocity_ms\"{s}{d:.3},", .{ sep, vel_ms });
        }

        if (event.heading_cdeg != 0) {
            const heading_deg = @as(f64, @floatFromInt(event.heading_cdeg)) / 100.0;
            try writer.print("\"heading_deg\"{s}{d:.2},", .{ sep, heading_deg });
        }

        if (event.accuracy_mm != 0) {
            const acc_m = @as(f64, @floatFromInt(event.accuracy_mm)) / 1000.0;
            try writer.print("\"accuracy_m\"{s}{d:.3},", .{ sep, acc_m });
        }

        if (event.ttl_seconds != 0) {
            try writer.print("\"ttl_seconds\"{s}{d},", .{ sep, event.ttl_seconds });
        }

        // Flags as nested object
        try writer.print("\"flags\"{s}{{", .{sep});
        try writer.print("\"linked\"{s}{},", .{ sep, event.flags.linked });
        try writer.print("\"imported\"{s}{},", .{ sep, event.flags.imported });
        try writer.print("\"stationary\"{s}{},", .{ sep, event.flags.stationary });
        try writer.print("\"low_accuracy\"{s}{},", .{ sep, event.flags.low_accuracy });
        try writer.print("\"offline\"{s}{},", .{ sep, event.flags.offline });
        try writer.print("\"deleted\"{s}{}", .{ sep, event.flags.deleted });
        try writer.writeAll("}");

        try writer.writeAll("}"); // End properties
        try writer.print("{s}{s}}}", .{ newline, indent }); // End Feature
    }

    /// Export a slice of events to a writer.
    pub fn exportAll(self: *Self, writer: anytype, events: []const GeoEvent) !void {
        try self.writeHeader(writer);
        for (events) |*event| {
            try self.writeEvent(writer, event);
        }
        try self.writeFooter(writer);
    }

    /// Export to a string (allocates memory).
    pub fn exportToString(self: *Self, events: []const GeoEvent) ![]u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        errdefer list.deinit();

        try self.exportAll(list.writer(), events);
        return list.toOwnedSlice();
    }
};

/// Convert a single GeoEvent to GeoJSON string.
pub fn eventToGeoJson(allocator: mem.Allocator, event: *const GeoEvent, pretty: bool) ![]u8 {
    var exporter = DataExporter.init(allocator, .{
        .format = .geojson,
        .pretty = pretty,
        .include_metadata = false,
    });
    defer exporter.deinit();

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    // Write as single Feature (not FeatureCollection)
    try exporter.writeGeoJsonFeature(list.writer(), event);
    return list.toOwnedSlice();
}

/// Convert a single GeoEvent to JSON string.
pub fn eventToJson(allocator: mem.Allocator, event: *const GeoEvent, pretty: bool) ![]u8 {
    var exporter = DataExporter.init(allocator, .{
        .format = .json,
        .pretty = pretty,
        .include_metadata = false,
    });
    defer exporter.deinit();

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try exporter.writeJsonEvent(list.writer(), event);
    return list.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "DataExporter: JSON format basic export" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(0x89C2590000000000, 1704067200000000000);
    event.entity_id = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    event.lat_nano = GeoEvent.lat_from_float(37.7749);
    event.lon_nano = GeoEvent.lon_from_float(-122.4194);
    event.timestamp = 1704067200000000000;
    event.group_id = 42;

    var exporter = DataExporter.init(allocator, .{ .format = .json });
    defer exporter.deinit();

    const events = [_]GeoEvent{event};
    const output = try exporter.exportToString(&events);
    defer allocator.free(output);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, output, "\"$schema\":\"archerdb-export-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"events\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"latitude\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"longitude\":") != null);
}

test "DataExporter: GeoJSON format RFC 7946 compliance" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(0x89C2590000000000, 1704067200000000000);
    event.entity_id = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0;
    event.lat_nano = GeoEvent.lat_from_float(40.7128); // New York
    event.lon_nano = GeoEvent.lon_from_float(-74.0060);
    event.timestamp = 1704067200000000000;
    event.altitude_mm = 10000; // 10 meters
    event.velocity_mms = 5000; // 5 m/s
    event.heading_cdeg = 9000; // 90 degrees (East)
    event.group_id = 1;

    var exporter = DataExporter.init(allocator, .{ .format = .geojson });
    defer exporter.deinit();

    const events = [_]GeoEvent{event};
    const output = try exporter.exportToString(&events);
    defer allocator.free(output);

    // Verify GeoJSON structure
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"FeatureCollection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"features\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"Feature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"Point\"") != null);
    // RFC 7946: coordinates are [longitude, latitude]
    try std.testing.expect(std.mem.indexOf(u8, output, "\"coordinates\":[-74.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"properties\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"altitude_m\":10.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"velocity_ms\":5.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"heading_deg\":90.") != null);
}

test "DataExporter: NDJSON format" {
    const allocator = std.testing.allocator;

    var event1 = GeoEvent.zero();
    event1.entity_id = 1;
    event1.lat_nano = GeoEvent.lat_from_float(37.0);
    event1.lon_nano = GeoEvent.lon_from_float(-122.0);
    event1.timestamp = 1000;

    var event2 = GeoEvent.zero();
    event2.entity_id = 2;
    event2.lat_nano = GeoEvent.lat_from_float(38.0);
    event2.lon_nano = GeoEvent.lon_from_float(-121.0);
    event2.timestamp = 2000;

    var exporter = DataExporter.init(allocator, .{ .format = .ndjson, .include_metadata = false });
    defer exporter.deinit();

    const events = [_]GeoEvent{ event1, event2 };
    const output = try exporter.exportToString(&events);
    defer allocator.free(output);

    // NDJSON should have one JSON object per line
    var lines = std.mem.splitSequence(u8, output, "\n");
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) {
            line_count += 1;
            // Each line should start with { and contain entity_id
            try std.testing.expect(line[0] == '{');
            try std.testing.expect(std.mem.indexOf(u8, line, "\"entity_id\"") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

test "DataExporter: pretty printing" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    event.entity_id = 0x123456789ABCDEF0;
    event.lat_nano = GeoEvent.lat_from_float(51.5074);
    event.lon_nano = GeoEvent.lon_from_float(-0.1278);
    event.timestamp = 1704067200000000000;

    var exporter = DataExporter.init(allocator, .{ .format = .json, .pretty = true });
    defer exporter.deinit();

    const events = [_]GeoEvent{event};
    const output = try exporter.exportToString(&events);
    defer allocator.free(output);

    // Pretty printed output should have newlines and indentation
    try std.testing.expect(std.mem.indexOf(u8, output, "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  ") != null);
}

test "DataExporter: single event to GeoJSON" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    event.entity_id = 0xABCDEF;
    event.lat_nano = GeoEvent.lat_from_float(35.6762);
    event.lon_nano = GeoEvent.lon_from_float(139.6503);
    event.timestamp = 1704067200000000000;

    const output = try eventToGeoJson(allocator, &event, false);
    defer allocator.free(output);

    // Single Feature, not FeatureCollection
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"Feature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"FeatureCollection\"") == null);
}

test "DataExporter: flags export" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    event.entity_id = 1;
    event.lat_nano = 0;
    event.lon_nano = 0;
    event.flags.linked = true;
    event.flags.stationary = true;
    event.flags.deleted = true;

    const output = try eventToJson(allocator, &event, false);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"linked\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stationary\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"deleted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"imported\":false") != null);
}

test "DataExporter: coordinate precision" {
    const allocator = std.testing.allocator;

    var event = GeoEvent.zero();
    // Use exact nanodegree values that convert cleanly
    event.lat_nano = 37_774900000; // 37.7749 exactly
    event.lon_nano = -122_419400000; // -122.4194 exactly

    const output = try eventToJson(allocator, &event, false);
    defer allocator.free(output);

    // Should have 9 decimal places of precision
    try std.testing.expect(std.mem.indexOf(u8, output, "37.7749") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-122.4194") != null);
}

test "DataExporter: empty event slice" {
    const allocator = std.testing.allocator;

    var exporter = DataExporter.init(allocator, .{ .format = .json });
    defer exporter.deinit();

    const events = [_]GeoEvent{};
    const output = try exporter.exportToString(&events);
    defer allocator.free(output);

    // Should still produce valid JSON with empty array
    try std.testing.expect(std.mem.indexOf(u8, output, "\"events\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"count\":0") != null);
}
