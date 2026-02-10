// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! REPL Parser for ArcherDB Geospatial Database
//!
//! Provides an interactive command-line interface for geospatial operations:
//! - INSERT: Add geospatial events
//! - QUERY: Query by UUID, radius, polygon, or latest
//! - DELETE: Remove entities
//! - STATUS: Check cluster status
//! - HELP: Display available commands
//!
//! Syntax follows SQL-like conventions for familiarity.

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;

/// Maximum length of a single command.
pub const MAX_COMMAND_LENGTH: usize = 4096;

/// Maximum number of arguments per command.
pub const MAX_ARGS: usize = 32;

/// REPL command types.
pub const Command = enum {
    /// No command (empty input).
    none,

    /// Display help information.
    help,

    /// Insert a geospatial event.
    insert,

    /// Query events by UUID.
    query_uuid,

    /// Query events by radius (geographic circle).
    query_radius,

    /// Query events by polygon (geographic region).
    query_polygon,

    /// Query most recent event for entities.
    query_latest,

    /// Delete an entity and all its events.
    delete,

    /// Delete multiple entities.
    delete_batch,

    /// Show cluster status.
    status,

    /// Exit the REPL.
    exit,

    /// Set configuration option.
    set,

    /// Show current configuration.
    show,

    /// Describe table/entity schema.
    describe,

    /// Begin a transaction batch.
    begin,

    /// Commit a transaction batch.
    commit,

    /// Rollback a transaction batch.
    rollback,

    pub fn toString(self: Command) []const u8 {
        return switch (self) {
            .none => "NONE",
            .help => "HELP",
            .insert => "INSERT",
            .query_uuid => "QUERY UUID",
            .query_radius => "QUERY RADIUS",
            .query_polygon => "QUERY POLYGON",
            .query_latest => "QUERY LATEST",
            .delete => "DELETE",
            .delete_batch => "DELETE BATCH",
            .status => "STATUS",
            .exit => "EXIT",
            .set => "SET",
            .show => "SHOW",
            .describe => "DESCRIBE",
            .begin => "BEGIN",
            .commit => "COMMIT",
            .rollback => "ROLLBACK",
        };
    }
};

/// Parsed coordinate value.
pub const Coordinate = struct {
    /// Latitude in nanodegrees.
    lat_nano: i64,

    /// Longitude in nanodegrees.
    lon_nano: i64,

    /// Parse from string format: "lat,lon" or "(lat, lon)".
    pub fn parse(input: []const u8) !Coordinate {
        var trimmed = mem.trim(u8, input, " \t()");

        // Find comma separator
        const comma_idx = mem.indexOf(u8, trimmed, ",") orelse
            return error.InvalidCoordinate;

        const lat_str = mem.trim(u8, trimmed[0..comma_idx], " \t");
        const lon_str = mem.trim(u8, trimmed[comma_idx + 1 ..], " \t");

        const lat = fmt.parseFloat(f64, lat_str) catch return error.InvalidLatitude;
        const lon = fmt.parseFloat(f64, lon_str) catch return error.InvalidLongitude;

        // Validate ranges
        if (lat < -90.0 or lat > 90.0) return error.LatitudeOutOfRange;
        if (lon < -180.0 or lon > 180.0) return error.LongitudeOutOfRange;

        return .{
            .lat_nano = @intFromFloat(lat * 1_000_000_000.0),
            .lon_nano = @intFromFloat(lon * 1_000_000_000.0),
        };
    }
};

/// Insert command arguments.
pub const InsertArgs = struct {
    /// Entity UUID (128-bit).
    entity_id: u128,

    /// Coordinate.
    coord: Coordinate,

    /// Timestamp (milliseconds since epoch, 0 = server time).
    timestamp: u64 = 0,

    /// Altitude in centimeters.
    altitude_cm: i32 = 0,

    /// Speed in centimeters per second.
    speed_cmps: u16 = 0,

    /// Heading in centidegrees (0-36000).
    heading_cdeg: u16 = 0,

    /// Accuracy in millimeters.
    accuracy_mm: u16 = 0,

    /// TTL in seconds (0 = no expiration).
    ttl_seconds: u32 = 0,
};

/// Query UUID arguments.
pub const QueryUuidArgs = struct {
    /// Entity UUID to query.
    entity_id: u128,
};

/// Query radius arguments.
pub const QueryRadiusArgs = struct {
    /// Center coordinate.
    center: Coordinate,

    /// Radius in meters.
    radius_m: u32,

    /// Start timestamp filter.
    start_timestamp: u64 = 0,

    /// End timestamp filter.
    end_timestamp: u64 = 0,

    /// Maximum results.
    limit: u32 = 100,
};

/// Query polygon arguments.
pub const QueryPolygonArgs = struct {
    /// Polygon vertices (minimum 3).
    vertices: []const Coordinate,

    /// Start timestamp filter.
    start_timestamp: u64 = 0,

    /// End timestamp filter.
    end_timestamp: u64 = 0,

    /// Maximum results.
    limit: u32 = 100,
};

/// Query latest arguments.
pub const QueryLatestArgs = struct {
    /// Entity IDs to query (empty = all).
    entity_ids: []const u128,

    /// Maximum results.
    limit: u32 = 100,
};

/// Delete arguments.
pub const DeleteArgs = struct {
    /// Entity ID to delete.
    entity_id: u128,
};

/// Set command arguments.
pub const SetArgs = struct {
    /// Setting name.
    name: []const u8,

    /// Setting value.
    value: []const u8,
};

/// Parsed command result.
pub const ParseResult = union(Command) {
    none: void,
    help: void,
    insert: InsertArgs,
    query_uuid: QueryUuidArgs,
    query_radius: QueryRadiusArgs,
    query_polygon: QueryPolygonArgs,
    query_latest: QueryLatestArgs,
    delete: DeleteArgs,
    delete_batch: []const u128,
    status: void,
    exit: void,
    set: SetArgs,
    show: []const u8,
    describe: []const u8,
    begin: void,
    commit: void,
    rollback: void,
};

/// Parser errors.
pub const Error = error{
    InvalidCommand,
    InvalidCoordinate,
    InvalidLatitude,
    InvalidLongitude,
    LatitudeOutOfRange,
    LongitudeOutOfRange,
    InvalidEntityId,
    InvalidRadius,
    InvalidTimestamp,
    InvalidLimit,
    MissingArgument,
    TooManyArguments,
    InvalidPolygon,
    UnterminatedString,
    OutOfMemory,
};

/// REPL Parser.
pub const Parser = struct {
    /// Allocator for dynamic allocations.
    allocator: std.mem.Allocator,

    /// Input buffer.
    input: []const u8,

    /// Current position in input.
    pos: usize,

    /// Polygon vertices buffer (for query_polygon).
    vertices_buffer: [64]Coordinate,

    /// Entity IDs buffer (for delete_batch, query_latest).
    entity_ids_buffer: [64]u128,

    /// Uppercase scratch buffer for case-insensitive parsing.
    upper_buffer: [128]u8,

    /// Initialize parser with input string.
    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .vertices_buffer = undefined,
            .entity_ids_buffer = undefined,
            .upper_buffer = undefined,
        };
    }

    /// Parse the input and return a result.
    pub fn parse(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return .{ .none = {} };
        }

        // Get command keyword
        const cmd_str = self.readWord() orelse return .{ .none = {} };
        const cmd_upper = self.toUpper(cmd_str);

        // Match command
        if (mem.eql(u8, cmd_upper, "HELP") or mem.eql(u8, cmd_upper, "?")) {
            return .{ .help = {} };
        } else if (mem.eql(u8, cmd_upper, "INSERT")) {
            return try self.parseInsert();
        } else if (mem.eql(u8, cmd_upper, "QUERY")) {
            return try self.parseQuery();
        } else if (mem.eql(u8, cmd_upper, "DELETE")) {
            return try self.parseDelete();
        } else if (mem.eql(u8, cmd_upper, "STATUS")) {
            return .{ .status = {} };
        } else if (mem.eql(u8, cmd_upper, "EXIT") or
            mem.eql(u8, cmd_upper, "QUIT") or
            mem.eql(u8, cmd_upper, "\\Q"))
        {
            return .{ .exit = {} };
        } else if (mem.eql(u8, cmd_upper, "SET")) {
            return try self.parseSet();
        } else if (mem.eql(u8, cmd_upper, "SHOW")) {
            return try self.parseShow();
        } else if (mem.eql(u8, cmd_upper, "DESCRIBE") or mem.eql(u8, cmd_upper, "DESC")) {
            return try self.parseDescribe();
        } else if (mem.eql(u8, cmd_upper, "BEGIN")) {
            return .{ .begin = {} };
        } else if (mem.eql(u8, cmd_upper, "COMMIT")) {
            return .{ .commit = {} };
        } else if (mem.eql(u8, cmd_upper, "ROLLBACK")) {
            return .{ .rollback = {} };
        }

        return error.InvalidCommand;
    }

    /// Parse INSERT command.
    /// Syntax: INSERT entity_id (lat, lon) [OPTIONS...]
    fn parseInsert(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        // Parse entity ID
        const entity_str = self.readWord() orelse return error.MissingArgument;
        const entity_id = self.parseEntityId(entity_str) catch return error.InvalidEntityId;

        self.skipWhitespace();

        // Parse coordinate
        const coord_str = self.readUntilChar(')') orelse return error.MissingArgument;
        const coord = Coordinate.parse(coord_str) catch |err| return err;

        var args = InsertArgs{
            .entity_id = entity_id,
            .coord = coord,
        };

        // Parse optional arguments
        while (self.readWord()) |opt_str| {
            const opt_upper = self.toUpper(opt_str);

            if (mem.eql(u8, opt_upper, "TIMESTAMP") or mem.eql(u8, opt_upper, "TS")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.timestamp = fmt.parseInt(u64, val, 10) catch return error.InvalidTimestamp;
            } else if (mem.eql(u8, opt_upper, "ALTITUDE") or mem.eql(u8, opt_upper, "ALT")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.altitude_cm = fmt.parseInt(i32, val, 10) catch return error.MissingArgument;
            } else if (mem.eql(u8, opt_upper, "SPEED")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.speed_cmps = fmt.parseInt(u16, val, 10) catch return error.MissingArgument;
            } else if (mem.eql(u8, opt_upper, "HEADING")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.heading_cdeg = fmt.parseInt(u16, val, 10) catch return error.MissingArgument;
            } else if (mem.eql(u8, opt_upper, "ACCURACY")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.accuracy_mm = fmt.parseInt(u16, val, 10) catch return error.MissingArgument;
            } else if (mem.eql(u8, opt_upper, "TTL")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.ttl_seconds = fmt.parseInt(u32, val, 10) catch return error.MissingArgument;
            }
        }

        return .{ .insert = args };
    }

    /// Parse QUERY command.
    /// Syntax: QUERY UUID|RADIUS|POLYGON|LATEST ...
    fn parseQuery(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        const subtype = self.readWord() orelse return error.MissingArgument;
        const subtype_upper = self.toUpper(subtype);

        if (mem.eql(u8, subtype_upper, "UUID")) {
            return try self.parseQueryUuid();
        } else if (mem.eql(u8, subtype_upper, "RADIUS")) {
            return try self.parseQueryRadius();
        } else if (mem.eql(u8, subtype_upper, "POLYGON")) {
            return try self.parseQueryPolygon();
        } else if (mem.eql(u8, subtype_upper, "LATEST")) {
            return try self.parseQueryLatest();
        }

        return error.InvalidCommand;
    }

    /// Parse QUERY UUID command.
    fn parseQueryUuid(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        const entity_str = self.readWord() orelse return error.MissingArgument;
        const entity_id = self.parseEntityId(entity_str) catch return error.InvalidEntityId;

        const args = QueryUuidArgs{
            .entity_id = entity_id,
        };

        // query_uuid only accepts an entity_id; consume any extra tokens.
        while (self.readWord()) |_| {}

        return .{ .query_uuid = args };
    }

    /// Parse QUERY RADIUS command.
    fn parseQueryRadius(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        // Parse center coordinate
        const coord_str = self.readUntilChar(')') orelse return error.MissingArgument;
        const center = Coordinate.parse(coord_str) catch |err| return err;

        self.skipWhitespace();

        // Parse radius
        const radius_str = self.readWord() orelse return error.MissingArgument;
        const radius_m = fmt.parseInt(u32, radius_str, 10) catch return error.InvalidRadius;

        var args = QueryRadiusArgs{
            .center = center,
            .radius_m = radius_m,
        };

        // Parse optional filters
        while (self.readWord()) |opt_str| {
            const opt_upper = self.toUpper(opt_str);

            if (mem.eql(u8, opt_upper, "FROM") or mem.eql(u8, opt_upper, "START")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.start_timestamp = fmt.parseInt(u64, val, 10) catch
                    return error.InvalidTimestamp;
            } else if (mem.eql(u8, opt_upper, "TO") or mem.eql(u8, opt_upper, "END")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.end_timestamp = fmt.parseInt(u64, val, 10) catch
                    return error.InvalidTimestamp;
            } else if (mem.eql(u8, opt_upper, "LIMIT")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.limit = fmt.parseInt(u32, val, 10) catch return error.InvalidLimit;
            }
        }

        return .{ .query_radius = args };
    }

    /// Parse QUERY POLYGON command.
    fn parseQueryPolygon(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        var vertex_count: usize = 0;

        // Parse polygon vertices
        while (self.readUntilChar(')')) |coord_str| {
            if (vertex_count >= 64) return error.TooManyArguments;

            const coord = Coordinate.parse(coord_str) catch |err| return err;
            self.vertices_buffer[vertex_count] = coord;
            vertex_count += 1;

            self.skipWhitespace();

            // Check for keyword (end of coordinates)
            const peek = self.peekWord();
            if (peek) |word| {
                const upper = self.toUpper(word);
                if (mem.eql(u8, upper, "FROM") or
                    mem.eql(u8, upper, "TO") or
                    mem.eql(u8, upper, "LIMIT"))
                {
                    break;
                }
            }
        }

        if (vertex_count < 3) return error.InvalidPolygon;

        var args = QueryPolygonArgs{
            .vertices = self.vertices_buffer[0..vertex_count],
        };

        // Parse optional filters
        while (self.readWord()) |opt_str| {
            const opt_upper = self.toUpper(opt_str);

            if (mem.eql(u8, opt_upper, "FROM") or mem.eql(u8, opt_upper, "START")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.start_timestamp = fmt.parseInt(u64, val, 10) catch
                    return error.InvalidTimestamp;
            } else if (mem.eql(u8, opt_upper, "TO") or mem.eql(u8, opt_upper, "END")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.end_timestamp = fmt.parseInt(u64, val, 10) catch
                    return error.InvalidTimestamp;
            } else if (mem.eql(u8, opt_upper, "LIMIT")) {
                const val = self.readWord() orelse return error.MissingArgument;
                args.limit = fmt.parseInt(u32, val, 10) catch return error.InvalidLimit;
            }
        }

        return .{ .query_polygon = args };
    }

    /// Parse QUERY LATEST command.
    fn parseQueryLatest(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        var entity_count: usize = 0;

        // Parse optional entity IDs
        while (self.readWord()) |word| {
            const upper = self.toUpper(word);

            if (mem.eql(u8, upper, "LIMIT")) {
                const val = self.readWord() orelse return error.MissingArgument;
                const limit = fmt.parseInt(u32, val, 10) catch return error.InvalidLimit;
                return .{ .query_latest = .{
                    .entity_ids = self.entity_ids_buffer[0..entity_count],
                    .limit = limit,
                } };
            }

            if (entity_count >= 64) return error.TooManyArguments;

            const entity_id = self.parseEntityId(word) catch continue;
            self.entity_ids_buffer[entity_count] = entity_id;
            entity_count += 1;
        }

        return .{ .query_latest = .{
            .entity_ids = self.entity_ids_buffer[0..entity_count],
            .limit = 100,
        } };
    }

    /// Parse DELETE command.
    fn parseDelete(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        const entity_str = self.readWord() orelse return error.MissingArgument;
        const entity_id = self.parseEntityId(entity_str) catch return error.InvalidEntityId;

        return .{ .delete = .{ .entity_id = entity_id } };
    }

    /// Parse SET command.
    fn parseSet(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        const name = self.readWord() orelse return error.MissingArgument;

        self.skipWhitespace();

        // Skip '=' if present
        if (self.pos < self.input.len and self.input[self.pos] == '=') {
            self.pos += 1;
            self.skipWhitespace();
        }

        const value = self.readWord() orelse return error.MissingArgument;

        return .{ .set = .{
            .name = name,
            .value = value,
        } };
    }

    /// Parse SHOW command.
    fn parseShow(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        const target = self.readWord() orelse "ALL";

        return .{ .show = target };
    }

    /// Parse DESCRIBE command.
    fn parseDescribe(self: *Parser) Error!ParseResult {
        self.skipWhitespace();

        const target = self.readWord() orelse "EVENTS";

        return .{ .describe = target };
    }

    // Helper methods

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            self.pos += 1;
        }
    }

    fn readWord(self: *Parser) ?[]const u8 {
        self.skipWhitespace();

        if (self.pos >= self.input.len) return null;

        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
                c == '(' or c == ')' or c == ',' or c == ';')
            {
                break;
            }
            self.pos += 1;
        }

        if (self.pos == start) return null;
        return self.input[start..self.pos];
    }

    fn peekWord(self: *Parser) ?[]const u8 {
        const saved_pos = self.pos;
        const word = self.readWord();
        self.pos = saved_pos;
        return word;
    }

    fn readUntilChar(self: *Parser, end_char: u8) ?[]const u8 {
        self.skipWhitespace();

        if (self.pos >= self.input.len) return null;

        // Skip opening paren if present
        if (self.input[self.pos] == '(') {
            self.pos += 1;
        }

        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == end_char) {
                const result = self.input[start..self.pos];
                self.pos += 1; // Skip end char
                return result;
            }
            self.pos += 1;
        }

        // Return rest of input if end char not found
        if (self.pos > start) {
            return self.input[start..self.pos];
        }

        return null;
    }

    fn parseEntityId(self: *Parser, str: []const u8) !u128 {
        _ = self;

        // Try hex format first (0x prefix or all hex chars)
        if (str.len >= 2 and str[0] == '0' and (str[1] == 'x' or str[1] == 'X')) {
            return fmt.parseInt(u128, str[2..], 16) catch return error.InvalidEntityId;
        }

        // Try decimal
        return fmt.parseInt(u128, str, 10) catch {
            // Try hex without prefix
            return fmt.parseInt(u128, str, 16) catch return error.InvalidEntityId;
        };
    }

    fn toUpper(self: *Parser, str: []const u8) []const u8 {
        if (str.len > self.upper_buffer.len) {
            return str;
        }

        for (str, 0..) |ch, i| {
            self.upper_buffer[i] = std.ascii.toUpper(ch);
        }

        return self.upper_buffer[0..str.len];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "parse empty input" {
    var parser = Parser.init(std.testing.allocator, "");
    const result = try parser.parse();
    try std.testing.expectEqual(Command.none, @as(Command, result));
}

test "parse HELP command" {
    var parser = Parser.init(std.testing.allocator, "HELP");
    const result = try parser.parse();
    try std.testing.expectEqual(Command.help, @as(Command, result));
}

test "parse help command lowercase" {
    var parser = Parser.init(std.testing.allocator, "help");
    const result = try parser.parse();
    try std.testing.expectEqual(Command.help, @as(Command, result));
}

test "parse EXIT command" {
    var parser = Parser.init(std.testing.allocator, "EXIT");
    const result = try parser.parse();
    try std.testing.expectEqual(Command.exit, @as(Command, result));
}

test "parse STATUS command" {
    var parser = Parser.init(std.testing.allocator, "STATUS");
    const result = try parser.parse();
    try std.testing.expectEqual(Command.status, @as(Command, result));
}

test "Coordinate.parse valid" {
    const coord = try Coordinate.parse("40.7128, -74.0060");
    try std.testing.expectEqual(@as(i64, 40_712_800_000), coord.lat_nano);
    try std.testing.expectEqual(@as(i64, -74_006_000_000), coord.lon_nano);
}

test "Coordinate.parse with parentheses" {
    const coord = try Coordinate.parse("(51.5074, -0.1278)");
    try std.testing.expect(coord.lat_nano > 51_000_000_000);
    try std.testing.expect(coord.lon_nano < 0);
}

test "Coordinate.parse invalid latitude" {
    const result = Coordinate.parse("91.0, 0.0");
    try std.testing.expectError(error.LatitudeOutOfRange, result);
}

test "Coordinate.parse invalid longitude" {
    const result = Coordinate.parse("0.0, 181.0");
    try std.testing.expectError(error.LongitudeOutOfRange, result);
}

test "Command.toString" {
    try std.testing.expectEqualStrings("INSERT", Command.insert.toString());
    try std.testing.expectEqualStrings("QUERY UUID", Command.query_uuid.toString());
    try std.testing.expectEqualStrings("STATUS", Command.status.toString());
}

test "parse INSERT command" {
    var parser = Parser.init(
        std.testing.allocator,
        "INSERT 123 (37.7749, -122.4194) SPEED 120 HEADING 9000 TTL 60",
    );
    const result = try parser.parse();
    switch (result) {
        .insert => |args| {
            try std.testing.expectEqual(@as(u128, 123), args.entity_id);
            try std.testing.expectEqual(@as(i64, 37_774_900_000), args.coord.lat_nano);
            try std.testing.expectEqual(@as(i64, -122_419_400_000), args.coord.lon_nano);
            try std.testing.expectEqual(@as(u16, 120), args.speed_cmps);
            try std.testing.expectEqual(@as(u16, 9000), args.heading_cdeg);
            try std.testing.expectEqual(@as(u32, 60), args.ttl_seconds);
        },
        else => try std.testing.expect(false),
    }
}

test "parse QUERY RADIUS command" {
    var parser = Parser.init(
        std.testing.allocator,
        "QUERY RADIUS (37.7749, -122.4194) 1500 LIMIT 5 FROM 10 TO 20",
    );
    const result = try parser.parse();
    switch (result) {
        .query_radius => |args| {
            try std.testing.expectEqual(@as(i64, 37_774_900_000), args.center.lat_nano);
            try std.testing.expectEqual(@as(i64, -122_419_400_000), args.center.lon_nano);
            try std.testing.expectEqual(@as(u32, 1500), args.radius_m);
            try std.testing.expectEqual(@as(u32, 5), args.limit);
            try std.testing.expectEqual(@as(u64, 10), args.start_timestamp);
            try std.testing.expectEqual(@as(u64, 20), args.end_timestamp);
        },
        else => try std.testing.expect(false),
    }
}

test "parse QUERY POLYGON command" {
    var parser = Parser.init(
        std.testing.allocator,
        "QUERY POLYGON (0, 0) (0, 1) (1, 1) LIMIT 7",
    );
    const result = try parser.parse();
    switch (result) {
        .query_polygon => |args| {
            try std.testing.expectEqual(@as(usize, 3), args.vertices.len);
            try std.testing.expectEqual(@as(i64, 0), args.vertices[0].lat_nano);
            try std.testing.expectEqual(@as(i64, 0), args.vertices[0].lon_nano);
            try std.testing.expectEqual(@as(u32, 7), args.limit);
        },
        else => try std.testing.expect(false),
    }
}

test "parse QUERY LATEST command" {
    var parser = Parser.init(
        std.testing.allocator,
        "QUERY LATEST 10 20 LIMIT 3",
    );
    const result = try parser.parse();
    switch (result) {
        .query_latest => |args| {
            try std.testing.expectEqual(@as(usize, 2), args.entity_ids.len);
            try std.testing.expectEqual(@as(u128, 10), args.entity_ids[0]);
            try std.testing.expectEqual(@as(u128, 20), args.entity_ids[1]);
            try std.testing.expectEqual(@as(u32, 3), args.limit);
        },
        else => try std.testing.expect(false),
    }
}
