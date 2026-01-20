// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Data Export Module for ArcherDB (F-Data-Portability)
//!
//! Provides export functionality for GeoEvents in multiple formats:
//! - JSON: Human-readable with schema versioning (RFC 8259)
//! - GeoJSON: RFC 7946 compliant geospatial format
//! - CSV: Tabular format for spreadsheet analysis (see data_export_csv.zig)
//!
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

    /// Initialize a new data exporter.
    pub fn init(allocator: mem.Allocator, options: ExportOptions) DataExporter {
        return .{
            .allocator = allocator,
            .options = options,
            .event_count = 0,
            .started = false,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *DataExporter) void {
        _ = self;
        // No allocations to free currently
    }

    /// Write export header (for formats that need it).
    pub fn writeHeader(self: *DataExporter, writer: anytype) !void {
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
    pub fn writeEvent(self: *DataExporter, writer: anytype, event: *const GeoEvent) !void {
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
    pub fn writeFooter(self: *DataExporter, writer: anytype) !void {
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
    fn writeJsonEvent(self: *DataExporter, writer: anytype, event: *const GeoEvent) !void {
        const indent = if (self.options.pretty) "    " else "";
        const newline = if (self.options.pretty) "\n" else "";
        const sep = if (self.options.pretty) ": " else ":";

        try writer.print("{s}{{", .{indent});
        try writer.print(
            "{s}{s}\"id\"{s}\"{x:0>32}\",",
            .{ newline, indent, sep, event.id },
        );
        try writer.print(
            "{s}{s}\"entity_id\"{s}\"{x:0>32}\",",
            .{ newline, indent, sep, event.entity_id },
        );

        if (event.correlation_id != 0 or self.options.include_nulls) {
            try writer.print(
                "{s}{s}\"correlation_id\"{s}\"{x:0>32}\",",
                .{ newline, indent, sep, event.correlation_id },
            );
        }

        if (event.user_data != 0 or self.options.include_nulls) {
            try writer.print(
                "{s}{s}\"user_data\"{s}\"{x:0>32}\",",
                .{ newline, indent, sep, event.user_data },
            );
        }

        // Coordinates
        const lat = GeoEvent.lat_to_float(event.lat_nano);
        const lon = GeoEvent.lon_to_float(event.lon_nano);
        try writer.print("{s}{s}\"latitude\"{s}{d:.9},", .{ newline, indent, sep, lat });
        try writer.print("{s}{s}\"longitude\"{s}{d:.9},", .{ newline, indent, sep, lon });

        // Timestamp
        try writer.print(
            "{s}{s}\"timestamp_ns\"{s}{d},",
            .{ newline, indent, sep, event.timestamp },
        );
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
            try writer.print(
                "{s}{s}\"heading_deg\"{s}{d:.2},",
                .{ newline, indent, sep, heading_deg },
            );
        }

        if (event.accuracy_mm != 0 or self.options.include_nulls) {
            const acc_m = @as(f64, @floatFromInt(event.accuracy_mm)) / 1000.0;
            try writer.print("{s}{s}\"accuracy_m\"{s}{d:.3},", .{ newline, indent, sep, acc_m });
        }

        if (event.ttl_seconds != 0 or self.options.include_nulls) {
            try writer.print(
                "{s}{s}\"ttl_seconds\"{s}{d},",
                .{ newline, indent, sep, event.ttl_seconds },
            );
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
    fn writeGeoJsonFeature(self: *DataExporter, writer: anytype, event: *const GeoEvent) !void {
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
    pub fn exportAll(self: *DataExporter, writer: anytype, events: []const GeoEvent) !void {
        try self.writeHeader(writer);
        for (events) |*event| {
            try self.writeEvent(writer, event);
        }
        try self.writeFooter(writer);
    }

    /// Export to a string (allocates memory).
    pub fn exportToString(self: *DataExporter, events: []const GeoEvent) ![]u8 {
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
// JSON Import (F6.1 Data Portability - Import)
// =============================================================================

/// JSON import errors.
pub const JsonImportError = error{
    InvalidJson,
    MissingRequiredField,
    InvalidCoordinate,
    InvalidTimestamp,
    InvalidEntityId,
    OutOfMemory,
};

/// Import options for JSON data.
pub const ImportOptions = struct {
    /// Whether to validate coordinates are in valid range.
    validate_coordinates: bool = true,
    /// Whether to generate IDs for events that don't have them.
    generate_ids: bool = false,
    /// Default TTL to apply if not specified in JSON.
    default_ttl_seconds: u32 = 0,
};

/// JSON importer for GeoEvent data.
pub const JsonImporter = struct {
    allocator: mem.Allocator,
    options: ImportOptions,

    pub fn init(allocator: mem.Allocator, options: ImportOptions) JsonImporter {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Parse a single JSON object into a GeoEvent.
    /// Expected format matches the export format from DataExporter.
    pub fn parseEvent(self: *JsonImporter, json_str: []const u8) JsonImportError!GeoEvent {
        var event = GeoEvent.zero();

        // Simple JSON parsing - look for key fields
        // This is a basic implementation; a full JSON parser would be more robust

        // Parse entity_id (required)
        if (findJsonString(json_str, "entity_id")) |entity_id_str| {
            event.entity_id = parseHexU128(entity_id_str) orelse return error.InvalidEntityId;
        } else {
            return error.MissingRequiredField;
        }

        // Parse latitude (required)
        if (findJsonNumber(json_str, "latitude")) |lat_str| {
            const lat = std.fmt.parseFloat(f64, lat_str) catch return error.InvalidCoordinate;
            if (self.options.validate_coordinates) {
                if (lat < -90.0 or lat > 90.0) return error.InvalidCoordinate;
            }
            event.lat_nano = GeoEvent.lat_from_float(lat);
        } else {
            return error.MissingRequiredField;
        }

        // Parse longitude (required)
        if (findJsonNumber(json_str, "longitude")) |lon_str| {
            const lon = std.fmt.parseFloat(f64, lon_str) catch return error.InvalidCoordinate;
            if (self.options.validate_coordinates) {
                if (lon < -180.0 or lon > 180.0) return error.InvalidCoordinate;
            }
            event.lon_nano = GeoEvent.lon_from_float(lon);
        } else {
            return error.MissingRequiredField;
        }

        // Parse optional fields
        // Try timestamp_ns first (exported format), then timestamp (generic format)
        if (findJsonNumber(json_str, "timestamp_ns")) |ts_str| {
            event.timestamp = std.fmt.parseInt(u64, ts_str, 10) catch return error.InvalidTimestamp;
        } else if (findJsonNumber(json_str, "timestamp")) |ts_str| {
            event.timestamp = std.fmt.parseInt(u64, ts_str, 10) catch return error.InvalidTimestamp;
        }

        if (findJsonNumber(json_str, "group_id")) |gid_str| {
            event.group_id = std.fmt.parseInt(u64, gid_str, 10) catch 0;
        }

        if (findJsonNumber(json_str, "altitude_m")) |alt_str| {
            const alt = std.fmt.parseFloat(f64, alt_str) catch 0.0;
            event.altitude_mm = @intFromFloat(alt * 1000.0);
        }

        if (findJsonNumber(json_str, "velocity_ms")) |vel_str| {
            const vel = std.fmt.parseFloat(f64, vel_str) catch 0.0;
            event.velocity_mms = @intFromFloat(vel * 1000.0);
        }

        if (findJsonNumber(json_str, "heading_deg")) |hdg_str| {
            const hdg = std.fmt.parseFloat(f64, hdg_str) catch 0.0;
            event.heading_cdeg = @intFromFloat(hdg * 100.0);
        }

        if (findJsonNumber(json_str, "accuracy_m")) |acc_str| {
            const acc = std.fmt.parseFloat(f64, acc_str) catch 0.0;
            event.accuracy_mm = @intFromFloat(acc * 1000.0);
        }

        if (findJsonNumber(json_str, "ttl_seconds")) |ttl_str| {
            event.ttl_seconds = std.fmt.parseInt(u32, ttl_str, 10) catch
                self.options.default_ttl_seconds;
        } else {
            event.ttl_seconds = self.options.default_ttl_seconds;
        }

        // Parse id if present, otherwise it will be generated during insert
        if (findJsonString(json_str, "id")) |id_str| {
            event.id = parseHexU128(id_str) orelse 0;
        }

        return event;
    }

    /// Parse multiple events from JSON array format.
    pub fn parseEvents(self: *JsonImporter, json_str: []const u8) ![]GeoEvent {
        var events = std.ArrayList(GeoEvent).init(self.allocator);
        errdefer events.deinit();

        // Find events array
        const events_start = mem.indexOf(u8, json_str, "\"events\":[") orelse
            mem.indexOf(u8, json_str, "[") orelse
            return error.InvalidJson;

        var pos = events_start;
        while (pos < json_str.len) {
            // Find next object start
            const obj_start = mem.indexOfPos(u8, json_str, pos, "{") orelse break;
            const obj_end = findMatchingBrace(json_str, obj_start) orelse break;

            const obj_str = json_str[obj_start .. obj_end + 1];
            const event = try self.parseEvent(obj_str);
            try events.append(event);

            pos = obj_end + 1;
        }

        return events.toOwnedSlice();
    }
};

/// GeoJSON importer for RFC 7946 compliant data.
pub const GeoJsonImporter = struct {
    allocator: mem.Allocator,
    options: ImportOptions,

    pub fn init(allocator: mem.Allocator, options: ImportOptions) GeoJsonImporter {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Parse a single GeoJSON Feature into a GeoEvent.
    /// Expects Point geometry with [longitude, latitude] coordinates.
    pub fn parseFeature(self: *GeoJsonImporter, feature_str: []const u8) JsonImportError!GeoEvent {
        var event = GeoEvent.zero();

        // Verify it's a Feature
        if (findJsonString(feature_str, "type")) |type_str| {
            if (!mem.eql(u8, type_str, "Feature")) {
                return error.InvalidJson;
            }
        }

        // Parse geometry - expect Point type
        // Look for coordinates array: [longitude, latitude] or [lon, lat, altitude]
        const coords_start = mem.indexOf(u8, feature_str, "\"coordinates\":[") orelse
            mem.indexOf(u8, feature_str, "\"coordinates\": [") orelse
            return error.MissingRequiredField;

        const bracket_pos = mem.indexOfPos(u8, feature_str, coords_start, "[") orelse
            return error.InvalidJson;
        const bracket_end = mem.indexOfPos(u8, feature_str, bracket_pos, "]") orelse
            return error.InvalidJson;

        const coords_str = feature_str[bracket_pos + 1 .. bracket_end];

        // Parse [lon, lat] or [lon, lat, alt]
        var coords = mem.splitScalar(u8, coords_str, ',');

        // Longitude (first coordinate in GeoJSON)
        const lon_str = mem.trim(u8, coords.next() orelse return error.InvalidCoordinate, " \t");
        const lon = std.fmt.parseFloat(f64, lon_str) catch return error.InvalidCoordinate;
        if (self.options.validate_coordinates) {
            if (lon < -180.0 or lon > 180.0) return error.InvalidCoordinate;
        }
        event.lon_nano = GeoEvent.lon_from_float(lon);

        // Latitude (second coordinate in GeoJSON)
        const lat_str = mem.trim(u8, coords.next() orelse return error.InvalidCoordinate, " \t");
        const lat = std.fmt.parseFloat(f64, lat_str) catch return error.InvalidCoordinate;
        if (self.options.validate_coordinates) {
            if (lat < -90.0 or lat > 90.0) return error.InvalidCoordinate;
        }
        event.lat_nano = GeoEvent.lat_from_float(lat);

        // Optional altitude (third coordinate in geometry)
        if (coords.next()) |alt_str_raw| {
            const alt_str = mem.trim(u8, alt_str_raw, " \t");
            const alt = std.fmt.parseFloat(f64, alt_str) catch 0.0;
            event.altitude_mm = @intFromFloat(alt * 1000.0);
        }

        // Parse properties
        if (mem.indexOf(u8, feature_str, "\"properties\":")) |props_start| {
            const props_brace = mem.indexOfPos(u8, feature_str, props_start, "{") orelse
                props_start;
            const props_end = findMatchingBrace(feature_str, props_brace) orelse
                feature_str.len - 1;
            const props = feature_str[props_brace .. props_end + 1];

            // entity_id (required in properties)
            if (findJsonString(props, "entity_id")) |entity_id_str| {
                event.entity_id = parseHexU128(entity_id_str) orelse return error.InvalidEntityId;
            } else {
                return error.MissingRequiredField;
            }

            // Optional properties
            if (findJsonNumber(props, "timestamp_ns")) |ts_str| {
                event.timestamp = std.fmt.parseInt(u64, ts_str, 10) catch 0;
            } else if (findJsonNumber(props, "timestamp")) |ts_str| {
                event.timestamp = std.fmt.parseInt(u64, ts_str, 10) catch 0;
            }
            if (findJsonNumber(props, "group_id")) |gid_str| {
                event.group_id = std.fmt.parseInt(u64, gid_str, 10) catch 0;
            }
            // Altitude from properties (if not in coordinates)
            if (event.altitude_mm == 0) {
                if (findJsonNumber(props, "altitude_m")) |alt_str| {
                    const alt = std.fmt.parseFloat(f64, alt_str) catch 0.0;
                    event.altitude_mm = @intFromFloat(alt * 1000.0);
                }
            }
            if (findJsonNumber(props, "velocity_ms")) |vel_str| {
                const vel = std.fmt.parseFloat(f64, vel_str) catch 0.0;
                event.velocity_mms = @intFromFloat(vel * 1000.0);
            }
            if (findJsonNumber(props, "heading_deg")) |hdg_str| {
                const hdg = std.fmt.parseFloat(f64, hdg_str) catch 0.0;
                event.heading_cdeg = @intFromFloat(hdg * 100.0);
            }
            if (findJsonNumber(props, "accuracy_m")) |acc_str| {
                const acc = std.fmt.parseFloat(f64, acc_str) catch 0.0;
                event.accuracy_mm = @intFromFloat(acc * 1000.0);
            }
            if (findJsonNumber(props, "ttl_seconds")) |ttl_str| {
                event.ttl_seconds = std.fmt.parseInt(u32, ttl_str, 10) catch
                    self.options.default_ttl_seconds;
            } else {
                event.ttl_seconds = self.options.default_ttl_seconds;
            }
        } else {
            return error.MissingRequiredField;
        }

        return event;
    }

    /// Parse a GeoJSON FeatureCollection into multiple GeoEvents.
    pub fn parseFeatureCollection(self: *GeoJsonImporter, geojson: []const u8) ![]GeoEvent {
        var events = std.ArrayList(GeoEvent).init(self.allocator);
        errdefer events.deinit();

        // Verify it's a FeatureCollection
        if (findJsonString(geojson, "type")) |type_str| {
            if (!mem.eql(u8, type_str, "FeatureCollection")) {
                return error.InvalidJson;
            }
        }

        // Find features array
        const features_start = mem.indexOf(u8, geojson, "\"features\":[") orelse
            mem.indexOf(u8, geojson, "\"features\": [") orelse
            return error.InvalidJson;

        var pos = features_start;
        while (pos < geojson.len) {
            // Find next Feature object
            const obj_start = mem.indexOfPos(u8, geojson, pos, "{") orelse break;
            const obj_end = findMatchingBrace(geojson, obj_start) orelse break;

            const feature_str = geojson[obj_start .. obj_end + 1];

            // Only parse if it's a Feature (skip other objects)
            if (findJsonString(feature_str, "type")) |type_str| {
                if (mem.eql(u8, type_str, "Feature")) {
                    const event = try self.parseFeature(feature_str);
                    try events.append(event);
                }
            }

            pos = obj_end + 1;
        }

        return events.toOwnedSlice();
    }
};

/// Find a JSON string value for a given key.
fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key":"value" pattern
    var search_key: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_key, "\"{s}\":\"", .{key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search) orelse return null;
    const value_start = key_pos + search.len;

    const value_end = mem.indexOfPos(u8, json, value_start, "\"") orelse return null;
    return json[value_start..value_end];
}

/// Find a JSON number value for a given key.
fn findJsonNumber(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key":number pattern
    var search_key: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_key, "\"{s}\":", .{key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search) orelse return null;
    var value_start = key_pos + search.len;

    // Skip whitespace
    while (value_start < json.len and (json[value_start] == ' ' or json[value_start] == '\t')) {
        value_start += 1;
    }

    // Find end of number (until comma, brace, or whitespace)
    var value_end = value_start;
    while (value_end < json.len) {
        const c = json[value_end];
        if (c == ',' or c == '}' or c == ']' or c == ' ' or c == '\n' or c == '\r') break;
        value_end += 1;
    }

    if (value_end > value_start) {
        return json[value_start..value_end];
    }
    return null;
}

/// Parse a hex string (with or without 0x prefix) to u128.
fn parseHexU128(str: []const u8) ?u128 {
    const hex = if (mem.startsWith(u8, str, "0x")) str[2..] else str;
    return std.fmt.parseInt(u128, hex, 16) catch null;
}

/// Find the matching closing brace for an opening brace.
fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '{') return null;

    var depth: usize = 1;
    var pos = start + 1;
    var in_string = false;

    while (pos < json.len and depth > 0) {
        const c = json[pos];
        if (c == '"' and (pos == 0 or json[pos - 1] != '\\')) {
            in_string = !in_string;
        } else if (!in_string) {
            if (c == '{') depth += 1 else if (c == '}') depth -= 1;
        }
        pos += 1;
    }

    if (depth == 0) return pos - 1;
    return null;
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
    try std.testing.expect(
        std.mem.indexOf(u8, output, "\"$schema\":\"archerdb-export-v1\"") != null,
    );
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

// =============================================================================
// JSON Import Tests
// =============================================================================

test "JsonImporter: parse single event" {
    const allocator = std.testing.allocator;

    const json =
        \\{"entity_id":"12345678abcdef0012345678abcdef00","latitude":37.7749,
        \\"longitude":-122.4194,"timestamp":1704067200000000000}
    ;

    var importer = JsonImporter.init(allocator, .{});
    const event = try importer.parseEvent(json);

    try std.testing.expectEqual(@as(u128, 0x12345678abcdef0012345678abcdef00), event.entity_id);
    try std.testing.expect(event.lat_nano > 37_700000000 and event.lat_nano < 37_800000000);
    try std.testing.expect(event.lon_nano > -122_500000000 and event.lon_nano < -122_400000000);
    try std.testing.expectEqual(@as(u64, 1704067200000000000), event.timestamp);
}

test "JsonImporter: parse event with optional fields" {
    const allocator = std.testing.allocator;

    const json =
        \\{"entity_id":"1","latitude":40.7128,"longitude":-74.006,
        \\"timestamp":1704067200000000000,"altitude_m":10.5,"velocity_ms":5.0,
        \\"heading_deg":90.0,"accuracy_m":15.0,"ttl_seconds":3600,"group_id":42}
    ;

    var importer = JsonImporter.init(allocator, .{});
    const event = try importer.parseEvent(json);

    try std.testing.expectEqual(@as(u128, 1), event.entity_id);
    try std.testing.expectEqual(@as(i32, 10500), event.altitude_mm);
    try std.testing.expectEqual(@as(u32, 5000), event.velocity_mms);
    try std.testing.expectEqual(@as(u16, 9000), event.heading_cdeg);
    try std.testing.expectEqual(@as(u32, 15000), event.accuracy_mm);
    try std.testing.expectEqual(@as(u32, 3600), event.ttl_seconds);
    try std.testing.expectEqual(@as(u64, 42), event.group_id);
}

test "JsonImporter: invalid coordinates rejected" {
    const allocator = std.testing.allocator;

    // Latitude out of range
    const bad_lat =
        \\{"entity_id":"1","latitude":91.0,"longitude":0.0}
    ;

    var importer = JsonImporter.init(allocator, .{ .validate_coordinates = true });
    try std.testing.expectError(error.InvalidCoordinate, importer.parseEvent(bad_lat));

    // Longitude out of range
    const bad_lon =
        \\{"entity_id":"1","latitude":0.0,"longitude":181.0}
    ;
    try std.testing.expectError(error.InvalidCoordinate, importer.parseEvent(bad_lon));
}

test "JsonImporter: missing required field" {
    const allocator = std.testing.allocator;

    // Missing entity_id
    const missing_entity =
        \\{"latitude":37.7749,"longitude":-122.4194}
    ;

    var importer = JsonImporter.init(allocator, .{});
    try std.testing.expectError(error.MissingRequiredField, importer.parseEvent(missing_entity));

    // Missing latitude
    const missing_lat =
        \\{"entity_id":"1","longitude":-122.4194}
    ;
    try std.testing.expectError(error.MissingRequiredField, importer.parseEvent(missing_lat));
}

test "JsonImporter: roundtrip export-import" {
    const allocator = std.testing.allocator;

    // Create original event
    var original = GeoEvent.zero();
    original.entity_id = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    original.lat_nano = GeoEvent.lat_from_float(37.7749);
    original.lon_nano = GeoEvent.lon_from_float(-122.4194);
    original.timestamp = 1704067200000000000;
    original.group_id = 42;
    original.altitude_mm = 10000;

    // Export to JSON
    const json = try eventToJson(allocator, &original, false);
    defer allocator.free(json);

    // Import back
    var importer = JsonImporter.init(allocator, .{});
    const imported = try importer.parseEvent(json);

    // Verify key fields match
    try std.testing.expectEqual(original.entity_id, imported.entity_id);
    try std.testing.expectEqual(original.timestamp, imported.timestamp);
    try std.testing.expectEqual(original.group_id, imported.group_id);
    try std.testing.expectEqual(original.altitude_mm, imported.altitude_mm);
    // Allow small floating point tolerance for lat/lon
    try std.testing.expect(@abs(original.lat_nano - imported.lat_nano) < 1000);
    try std.testing.expect(@abs(original.lon_nano - imported.lon_nano) < 1000);
}

test "findJsonString: basic parsing" {
    const json =
        \\{"name":"test","value":"hello"}
    ;

    try std.testing.expectEqualStrings("test", findJsonString(json, "name").?);
    try std.testing.expectEqualStrings("hello", findJsonString(json, "value").?);
    try std.testing.expect(findJsonString(json, "missing") == null);
}

test "findJsonNumber: basic parsing" {
    const json =
        \\{"count":42,"price":19.99,"negative":-5}
    ;

    try std.testing.expectEqualStrings("42", findJsonNumber(json, "count").?);
    try std.testing.expectEqualStrings("19.99", findJsonNumber(json, "price").?);
    try std.testing.expectEqualStrings("-5", findJsonNumber(json, "negative").?);
    try std.testing.expect(findJsonNumber(json, "missing") == null);
}

test "parseHexU128: various formats" {
    try std.testing.expectEqual(@as(u128, 0x12345678), parseHexU128("12345678").?);
    try std.testing.expectEqual(@as(u128, 0xABCDEF), parseHexU128("0xABCDEF").?);
    try std.testing.expectEqual(@as(u128, 1), parseHexU128("1").?);
    try std.testing.expect(parseHexU128("invalid") == null);
}

// =============================================================================
// GeoJSON Import Tests
// =============================================================================

test "GeoJsonImporter: parse single Feature" {
    const allocator = std.testing.allocator;

    const geojson =
        \\{"type":"Feature","geometry":{"type":"Point",
        \\"coordinates":[-74.006,40.7128]},"properties":{"entity_id":"1",
        \\"timestamp":1704067200000000000}}
    ;

    var importer = GeoJsonImporter.init(allocator, .{});
    const event = try importer.parseFeature(geojson);

    try std.testing.expectEqual(@as(u128, 1), event.entity_id);
    // GeoJSON coordinates are [lon, lat]
    try std.testing.expect(event.lon_nano > -74_100000000 and event.lon_nano < -73_900000000);
    try std.testing.expect(event.lat_nano > 40_600000000 and event.lat_nano < 40_800000000);
    try std.testing.expectEqual(@as(u64, 1704067200000000000), event.timestamp);
}

test "GeoJsonImporter: parse Feature with altitude" {
    const allocator = std.testing.allocator;

    const geojson =
        \\{"type":"Feature","geometry":{"type":"Point",
        \\"coordinates":[-122.4194,37.7749,100.5]},"properties":
        \\{"entity_id":"2","group_id":42}}
    ;

    var importer = GeoJsonImporter.init(allocator, .{});
    const event = try importer.parseFeature(geojson);

    try std.testing.expectEqual(@as(u128, 2), event.entity_id);
    try std.testing.expectEqual(@as(i32, 100500), event.altitude_mm);
    try std.testing.expectEqual(@as(u64, 42), event.group_id);
}

test "GeoJsonImporter: roundtrip GeoJSON export-import" {
    const allocator = std.testing.allocator;

    // Create original event
    var original = GeoEvent.zero();
    original.entity_id = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    original.lat_nano = GeoEvent.lat_from_float(40.7128);
    original.lon_nano = GeoEvent.lon_from_float(-74.006);
    original.timestamp = 1704067200000000000;
    original.group_id = 42;
    original.altitude_mm = 10000;

    // Export to GeoJSON
    const geojson = try eventToGeoJson(allocator, &original, false);
    defer allocator.free(geojson);

    // Import back
    var importer = GeoJsonImporter.init(allocator, .{});
    const imported = try importer.parseFeature(geojson);

    // Verify key fields match
    try std.testing.expectEqual(original.entity_id, imported.entity_id);
    try std.testing.expectEqual(original.group_id, imported.group_id);
    try std.testing.expectEqual(original.altitude_mm, imported.altitude_mm);
    // Allow small floating point tolerance for lat/lon
    try std.testing.expect(@abs(original.lat_nano - imported.lat_nano) < 1000);
    try std.testing.expect(@abs(original.lon_nano - imported.lon_nano) < 1000);
}

test "GeoJsonImporter: invalid coordinates rejected" {
    const allocator = std.testing.allocator;

    // Latitude out of range (91 degrees)
    const bad_lat =
        \\{"type":"Feature","geometry":{"type":"Point","coordinates":[0,91]},"properties":{"entity_id":"1"}}
    ;

    var importer = GeoJsonImporter.init(allocator, .{ .validate_coordinates = true });
    try std.testing.expectError(error.InvalidCoordinate, importer.parseFeature(bad_lat));
}
