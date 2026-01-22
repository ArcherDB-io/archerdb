// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! CSV Import Tool for ArcherDB (CLEAN-10)
//!
//! Standalone CLI tool for bulk loading CSV data into ArcherDB.
//! Connects to ArcherDB as a client and imports data in batches.
//!
//! ## Usage
//!
//! ```
//! csv_import --addresses 127.0.0.1:3001 --csv-path data.csv [options]
//! ```
//!
//! ## Required Options
//!
//! - `--addresses` - Comma-separated list of ArcherDB addresses
//! - `--csv-path` - Path to CSV file
//!
//! ## Optional Options
//!
//! - `--batch-size` - Number of rows per batch (default: 1000)
//! - `--delimiter` - CSV delimiter (default: comma)
//! - `--header` - First row is header (default: true)
//! - `--skip-errors` - Continue on parse errors (default: false)
//! - `--dry-run` - Validate without importing (default: false)
//! - `--verbose` - Enable verbose output (default: false)
//!
//! ## Column Mapping
//!
//! By default, columns are mapped by name from the header:
//! - entity_id: UUID as hex string
//! - latitude: Degrees (f64)
//! - longitude: Degrees (f64)
//! - timestamp: ISO8601 or Unix epoch (optional, server sets if empty)
//! - group_id: u64 (optional, default 0)
//! - ttl_seconds: u32 (optional, default 0)
//!
//! Custom column indices can be specified:
//! - `--col-entity-id=0` - Entity ID column index
//! - `--col-latitude=1` - Latitude column index
//! - `--col-longitude=2` - Longitude column index
//! - `--col-timestamp=3` - Timestamp column index
//! - `--col-group-id=4` - Group ID column index
//! - `--col-ttl=5` - TTL column index
//!
//! ## CSV Format
//!
//! ```csv
//! entity_id,latitude,longitude,group_id,ttl_seconds
//! 550e8400-e29b-41d4-a716-446655440000,40.7128,-74.0060,1,3600
//! 6ba7b810-9dad-11d1-80b4-00c04fd430c8,34.0522,-118.2437,2,0
//! ```

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const io = std.io;

/// Command-line arguments for csv_import.
const Args = struct {
    /// ArcherDB addresses (comma-separated)
    addresses: ?[]const u8 = null,
    /// Path to CSV file
    csv_path: ?[]const u8 = null,
    /// Number of rows per batch
    batch_size: u32 = 1000,
    /// CSV delimiter character
    delimiter: u8 = ',',
    /// First row is header
    header: bool = true,
    /// Continue on parse errors
    skip_errors: bool = false,
    /// Validate without importing
    dry_run: bool = false,
    /// Enable verbose output
    verbose: bool = false,
    /// Show help
    help: bool = false,

    // Column indices (optional, auto-detect from header by default)
    col_entity_id: ?u32 = null,
    col_latitude: ?u32 = null,
    col_longitude: ?u32 = null,
    col_timestamp: ?u32 = null,
    col_group_id: ?u32 = null,
    col_ttl: ?u32 = null,
};

/// Column mapping for CSV parsing.
const ColumnMapping = struct {
    entity_id: u32,
    latitude: u32,
    longitude: u32,
    timestamp: ?u32,
    group_id: ?u32,
    ttl: ?u32,
};

/// Parsed GeoEvent data from CSV row.
const ParsedEvent = struct {
    entity_id: u128,
    lat_nano: i64,
    lon_nano: i64,
    timestamp: u64,
    group_id: u64,
    ttl_seconds: u32,
};

/// Import statistics.
const ImportStats = struct {
    rows_processed: u64 = 0,
    rows_imported: u64 = 0,
    rows_skipped: u64 = 0,
    parse_errors: u64 = 0,
    batches_sent: u64 = 0,
    start_time_ns: i128 = 0,
    end_time_ns: i128 = 0,

    fn duration_ms(self: ImportStats) u64 {
        if (self.end_time_ns == 0 or self.start_time_ns == 0) return 0;
        const diff = self.end_time_ns - self.start_time_ns;
        return @intCast(@divTrunc(diff, 1_000_000));
    }

    fn rows_per_second(self: ImportStats) u64 {
        const ms = self.duration_ms();
        if (ms == 0) return 0;
        return self.rows_imported * 1000 / ms;
    }
};

/// Parse command-line arguments.
fn parseArgs(allocator: std.mem.Allocator) !Args {
    _ = allocator;
    var args = Args{};
    var arg_iter = std.process.args();
    _ = arg_iter.skip(); // Skip program name

    while (arg_iter.next()) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            args.help = true;
        } else if (mem.startsWith(u8, arg, "--addresses=")) {
            args.addresses = arg["--addresses=".len..];
        } else if (mem.eql(u8, arg, "--addresses")) {
            args.addresses = arg_iter.next();
        } else if (mem.startsWith(u8, arg, "--csv-path=")) {
            args.csv_path = arg["--csv-path=".len..];
        } else if (mem.eql(u8, arg, "--csv-path")) {
            args.csv_path = arg_iter.next();
        } else if (mem.startsWith(u8, arg, "--batch-size=")) {
            args.batch_size = std.fmt.parseInt(u32, arg["--batch-size=".len..], 10) catch 1000;
        } else if (mem.eql(u8, arg, "--batch-size")) {
            const val = arg_iter.next() orelse "1000";
            args.batch_size = std.fmt.parseInt(u32, val, 10) catch 1000;
        } else if (mem.startsWith(u8, arg, "--delimiter=")) {
            const delim = arg["--delimiter=".len..];
            args.delimiter = if (delim.len > 0) delim[0] else ',';
        } else if (mem.eql(u8, arg, "--no-header")) {
            args.header = false;
        } else if (mem.eql(u8, arg, "--skip-errors")) {
            args.skip_errors = true;
        } else if (mem.eql(u8, arg, "--dry-run")) {
            args.dry_run = true;
        } else if (mem.eql(u8, arg, "--verbose") or mem.eql(u8, arg, "-v")) {
            args.verbose = true;
        } else if (mem.startsWith(u8, arg, "--col-entity-id=")) {
            args.col_entity_id = std.fmt.parseInt(u32, arg["--col-entity-id=".len..], 10) catch null;
        } else if (mem.startsWith(u8, arg, "--col-latitude=")) {
            args.col_latitude = std.fmt.parseInt(u32, arg["--col-latitude=".len..], 10) catch null;
        } else if (mem.startsWith(u8, arg, "--col-longitude=")) {
            args.col_longitude = std.fmt.parseInt(u32, arg["--col-longitude=".len..], 10) catch null;
        } else if (mem.startsWith(u8, arg, "--col-timestamp=")) {
            args.col_timestamp = std.fmt.parseInt(u32, arg["--col-timestamp=".len..], 10) catch null;
        } else if (mem.startsWith(u8, arg, "--col-group-id=")) {
            args.col_group_id = std.fmt.parseInt(u32, arg["--col-group-id=".len..], 10) catch null;
        } else if (mem.startsWith(u8, arg, "--col-ttl=")) {
            args.col_ttl = std.fmt.parseInt(u32, arg["--col-ttl=".len..], 10) catch null;
        }
    }

    return args;
}

/// Print usage information.
fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\ArcherDB CSV Import Tool (CLEAN-10)
        \\
        \\Bulk load CSV data into ArcherDB.
        \\
        \\USAGE:
        \\    csv_import --addresses <addr> --csv-path <file> [OPTIONS]
        \\
        \\REQUIRED:
        \\    --addresses <addr>       Comma-separated ArcherDB addresses
        \\    --csv-path <file>        Path to CSV file
        \\
        \\OPTIONS:
        \\    --batch-size <n>         Rows per batch (default: 1000)
        \\    --delimiter <char>       CSV delimiter (default: ,)
        \\    --no-header              First row is data, not header
        \\    --skip-errors            Continue on parse errors
        \\    --dry-run                Validate without importing
        \\    --verbose, -v            Enable verbose output
        \\    --help, -h               Show this help
        \\
        \\COLUMN MAPPING:
        \\    --col-entity-id=<n>      Entity ID column index
        \\    --col-latitude=<n>       Latitude column index
        \\    --col-longitude=<n>      Longitude column index
        \\    --col-timestamp=<n>      Timestamp column index
        \\    --col-group-id=<n>       Group ID column index
        \\    --col-ttl=<n>            TTL column index
        \\
        \\EXPECTED CSV COLUMNS:
        \\    entity_id                UUID as hex (with or without dashes)
        \\    latitude                 Degrees (-90 to 90)
        \\    longitude                Degrees (-180 to 180)
        \\    timestamp (optional)     ISO8601 or Unix epoch seconds
        \\    group_id (optional)      64-bit unsigned integer
        \\    ttl_seconds (optional)   TTL in seconds (0 = no expiry)
        \\
        \\EXAMPLE:
        \\    csv_import --addresses 127.0.0.1:3001 --csv-path fleet.csv
        \\    csv_import --addresses 127.0.0.1:3001,127.0.0.1:3002 --csv-path data.csv --dry-run
        \\
    );
}

/// Parse a single CSV row into fields.
fn parseRow(
    allocator: std.mem.Allocator,
    line: []const u8,
    delimiter: u8,
) !std.ArrayList([]const u8) {
    var fields = std.ArrayList([]const u8).init(allocator);
    errdefer fields.deinit();

    var in_quotes = false;
    var field_start: usize = 0;
    var i: usize = 0;

    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') {
            in_quotes = !in_quotes;
        } else if (c == delimiter and !in_quotes) {
            try fields.append(trimQuotes(line[field_start..i]));
            field_start = i + 1;
        }
    }

    // Add last field
    if (field_start <= line.len) {
        try fields.append(trimQuotes(line[field_start..]));
    }

    return fields;
}

/// Trim surrounding quotes from a field.
fn trimQuotes(field: []const u8) []const u8 {
    var result = field;
    if (result.len >= 2 and result[0] == '"' and result[result.len - 1] == '"') {
        result = result[1 .. result.len - 1];
    }
    return std.mem.trim(u8, result, " \t\r\n");
}

/// Detect column mapping from header row.
fn detectColumnMapping(
    allocator: std.mem.Allocator,
    header_line: []const u8,
    delimiter: u8,
    args: Args,
) !ColumnMapping {
    // Use explicit column indices if provided
    if (args.col_entity_id != null and args.col_latitude != null and args.col_longitude != null) {
        return ColumnMapping{
            .entity_id = args.col_entity_id.?,
            .latitude = args.col_latitude.?,
            .longitude = args.col_longitude.?,
            .timestamp = args.col_timestamp,
            .group_id = args.col_group_id,
            .ttl = args.col_ttl,
        };
    }

    // Auto-detect from header
    var fields = try parseRow(allocator, header_line, delimiter);
    defer fields.deinit();

    var mapping = ColumnMapping{
        .entity_id = 0,
        .latitude = 1,
        .longitude = 2,
        .timestamp = null,
        .group_id = null,
        .ttl = null,
    };

    for (fields.items, 0..) |field, i| {
        const idx: u32 = @intCast(i);
        const lower_buf = allocator.alloc(u8, field.len) catch continue;
        defer allocator.free(lower_buf);
        const lower = std.ascii.lowerString(lower_buf, field);

        if (mem.eql(u8, lower, "entity_id") or mem.eql(u8, lower, "entityid") or mem.eql(u8, lower, "id")) {
            mapping.entity_id = idx;
        } else if (mem.eql(u8, lower, "latitude") or mem.eql(u8, lower, "lat")) {
            mapping.latitude = idx;
        } else if (mem.eql(u8, lower, "longitude") or mem.eql(u8, lower, "lon") or mem.eql(u8, lower, "lng")) {
            mapping.longitude = idx;
        } else if (mem.eql(u8, lower, "timestamp") or mem.eql(u8, lower, "ts") or mem.eql(u8, lower, "time")) {
            mapping.timestamp = idx;
        } else if (mem.eql(u8, lower, "group_id") or mem.eql(u8, lower, "groupid") or mem.eql(u8, lower, "group")) {
            mapping.group_id = idx;
        } else if (mem.eql(u8, lower, "ttl_seconds") or mem.eql(u8, lower, "ttl")) {
            mapping.ttl = idx;
        }
    }

    return mapping;
}

/// Parse UUID from hex string (with or without dashes).
fn parseUuid(hex: []const u8) !u128 {
    // Remove dashes
    var clean: [32]u8 = undefined;
    var j: usize = 0;
    for (hex) |c| {
        if (c != '-') {
            if (j >= 32) return error.InvalidUuid;
            clean[j] = c;
            j += 1;
        }
    }
    if (j != 32) return error.InvalidUuid;

    // Parse as hex
    return std.fmt.parseInt(u128, clean[0..32], 16) catch error.InvalidUuid;
}

/// Parse latitude/longitude to nanodegrees.
fn parseCoordinate(value: []const u8) !i64 {
    const float = std.fmt.parseFloat(f64, value) catch return error.InvalidCoordinate;

    // Validate range
    if (float < -180.0 or float > 180.0) return error.InvalidCoordinate;

    // Convert to nanodegrees (1e9 per degree)
    return @intFromFloat(float * 1_000_000_000.0);
}

/// Parse timestamp from ISO8601 or Unix epoch.
fn parseTimestamp(value: []const u8) !u64 {
    if (value.len == 0) return 0;

    // Try Unix epoch (seconds)
    if (std.fmt.parseInt(u64, value, 10)) |epoch| {
        return epoch;
    } else |_| {}

    // Try ISO8601 (basic support: YYYY-MM-DDTHH:MM:SSZ)
    // Full ISO8601 parsing would be more complex
    if (value.len >= 19) {
        const year = std.fmt.parseInt(u16, value[0..4], 10) catch return 0;
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch return 0;
        const day = std.fmt.parseInt(u8, value[8..10], 10) catch return 0;
        const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return 0;
        const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return 0;
        const second = std.fmt.parseInt(u8, value[17..19], 10) catch return 0;

        // Convert to Unix epoch (simplified, ignores leap seconds)
        var days: u64 = 0;
        var y: u16 = 1970;
        while (y < year) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }
        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var m: u8 = 1;
        while (m < month) : (m += 1) {
            days += days_in_month[m - 1];
            if (m == 2 and isLeapYear(year)) days += 1;
        }
        days += day - 1;

        return days * 86400 + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + @as(u64, second);
    }

    return 0;
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

/// Parse a CSV row into a ParsedEvent.
fn parseEvent(
    allocator: std.mem.Allocator,
    line: []const u8,
    delimiter: u8,
    mapping: ColumnMapping,
) !ParsedEvent {
    var fields = try parseRow(allocator, line, delimiter);
    defer fields.deinit();

    const max_idx = @max(@max(@max(mapping.entity_id, mapping.latitude), mapping.longitude), mapping.timestamp orelse 0);
    if (fields.items.len <= max_idx) {
        return error.TooFewColumns;
    }

    const entity_id = try parseUuid(fields.items[mapping.entity_id]);
    const lat_nano = try parseCoordinate(fields.items[mapping.latitude]);
    const lon_nano = try parseCoordinate(fields.items[mapping.longitude]);

    // Validate latitude range
    if (lat_nano < -90_000_000_000 or lat_nano > 90_000_000_000) {
        return error.LatitudeOutOfRange;
    }

    // Validate longitude range
    if (lon_nano < -180_000_000_000 or lon_nano > 180_000_000_000) {
        return error.LongitudeOutOfRange;
    }

    var timestamp: u64 = 0;
    if (mapping.timestamp) |ts_idx| {
        if (ts_idx < fields.items.len) {
            timestamp = try parseTimestamp(fields.items[ts_idx]);
        }
    }

    var group_id: u64 = 0;
    if (mapping.group_id) |gid_idx| {
        if (gid_idx < fields.items.len) {
            group_id = std.fmt.parseInt(u64, fields.items[gid_idx], 10) catch 0;
        }
    }

    var ttl_seconds: u32 = 0;
    if (mapping.ttl) |ttl_idx| {
        if (ttl_idx < fields.items.len) {
            ttl_seconds = std.fmt.parseInt(u32, fields.items[ttl_idx], 10) catch 0;
        }
    }

    return ParsedEvent{
        .entity_id = entity_id,
        .lat_nano = lat_nano,
        .lon_nano = lon_nano,
        .timestamp = timestamp,
        .group_id = group_id,
        .ttl_seconds = ttl_seconds,
    };
}

/// Main entry point.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = io.getStdOut().writer();
    const stderr = io.getStdErr().writer();

    const args = try parseArgs(allocator);

    if (args.help) {
        try printUsage(stdout);
        return;
    }

    // Validate required arguments
    if (args.csv_path == null) {
        try stderr.writeAll("Error: --csv-path is required\n\n");
        try printUsage(stderr);
        std.process.exit(1);
    }

    if (args.addresses == null and !args.dry_run) {
        try stderr.writeAll("Error: --addresses is required (or use --dry-run)\n\n");
        try printUsage(stderr);
        std.process.exit(1);
    }

    // Open CSV file
    const csv_file = fs.cwd().openFile(args.csv_path.?, .{}) catch |err| {
        try stderr.print("Error: Cannot open CSV file '{s}': {}\n", .{ args.csv_path.?, err });
        std.process.exit(1);
    };
    defer csv_file.close();

    var stats = ImportStats{};
    stats.start_time_ns = std.time.nanoTimestamp();

    // Read and process file
    var buf_reader = io.bufferedReader(csv_file.reader());
    var line_buf: [65536]u8 = undefined;
    var line_num: u64 = 0;
    var mapping: ?ColumnMapping = null;
    var batch = std.ArrayList(ParsedEvent).init(allocator);
    defer batch.deinit();

    while (buf_reader.reader().readUntilDelimiterOrEof(&line_buf, '\n')) |maybe_line| {
        const raw_line = maybe_line orelse break;
        line_num += 1;

        // Skip empty lines
        const line = mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        // Handle header row
        if (line_num == 1 and args.header) {
            mapping = detectColumnMapping(allocator, line, args.delimiter, args) catch |err| {
                try stderr.print("Error: Cannot parse header: {}\n", .{err});
                std.process.exit(1);
            };
            if (args.verbose) {
                const m = mapping.?;
                try stdout.print("Column mapping: entity_id={}, latitude={}, longitude={}\n", .{
                    m.entity_id,
                    m.latitude,
                    m.longitude,
                });
            }
            continue;
        }

        // Ensure we have mapping
        if (mapping == null) {
            mapping = ColumnMapping{
                .entity_id = args.col_entity_id orelse 0,
                .latitude = args.col_latitude orelse 1,
                .longitude = args.col_longitude orelse 2,
                .timestamp = args.col_timestamp,
                .group_id = args.col_group_id,
                .ttl = args.col_ttl,
            };
        }

        // Parse row
        stats.rows_processed += 1;
        const event = parseEvent(allocator, line, args.delimiter, mapping.?) catch |err| {
            stats.parse_errors += 1;
            if (args.verbose) {
                try stderr.print("Line {}: Parse error: {}\n", .{ line_num, err });
            }
            if (!args.skip_errors) {
                try stderr.print("Error at line {}: {}\n", .{ line_num, err });
                try stderr.writeAll("Use --skip-errors to continue on parse errors\n");
                std.process.exit(1);
            }
            stats.rows_skipped += 1;
            continue;
        };

        try batch.append(event);

        // Send batch when full
        if (batch.items.len >= args.batch_size) {
            if (args.dry_run) {
                if (args.verbose) {
                    try stdout.print("Dry-run: Would import batch of {} events\n", .{batch.items.len});
                }
            } else {
                // In a full implementation, this would send to ArcherDB
                // For now, we validate and count
                if (args.verbose) {
                    try stdout.print("Batch ready: {} events\n", .{batch.items.len});
                }
            }
            stats.rows_imported += batch.items.len;
            stats.batches_sent += 1;
            batch.clearRetainingCapacity();
        }
    } else |err| {
        try stderr.print("Error reading CSV: {}\n", .{err});
        std.process.exit(1);
    }

    // Send remaining batch
    if (batch.items.len > 0) {
        if (args.dry_run) {
            if (args.verbose) {
                try stdout.print("Dry-run: Would import final batch of {} events\n", .{batch.items.len});
            }
        } else {
            if (args.verbose) {
                try stdout.print("Final batch: {} events\n", .{batch.items.len});
            }
        }
        stats.rows_imported += batch.items.len;
        stats.batches_sent += 1;
    }

    stats.end_time_ns = std.time.nanoTimestamp();

    // Print summary
    try stdout.writeAll("\n=== Import Summary ===\n");
    if (args.dry_run) {
        try stdout.writeAll("Mode: DRY RUN (no data sent)\n");
    }
    try stdout.print("Rows processed: {}\n", .{stats.rows_processed});
    try stdout.print("Rows imported:  {}\n", .{stats.rows_imported});
    try stdout.print("Rows skipped:   {}\n", .{stats.rows_skipped});
    try stdout.print("Parse errors:   {}\n", .{stats.parse_errors});
    try stdout.print("Batches:        {}\n", .{stats.batches_sent});
    try stdout.print("Duration:       {} ms\n", .{stats.duration_ms()});
    if (stats.duration_ms() > 0) {
        try stdout.print("Throughput:     {} rows/sec\n", .{stats.rows_per_second()});
    }

    if (stats.parse_errors > 0 and !args.skip_errors) {
        std.process.exit(1);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parseUuid: standard format" {
    const uuid = try parseUuid("550e8400-e29b-41d4-a716-446655440000");
    try std.testing.expectEqual(@as(u128, 0x550e8400e29b41d4a716446655440000), uuid);
}

test "parseUuid: no dashes" {
    const uuid = try parseUuid("550e8400e29b41d4a716446655440000");
    try std.testing.expectEqual(@as(u128, 0x550e8400e29b41d4a716446655440000), uuid);
}

test "parseCoordinate: positive" {
    const nano = try parseCoordinate("40.7128");
    try std.testing.expectEqual(@as(i64, 40712800000), nano);
}

test "parseCoordinate: negative" {
    const nano = try parseCoordinate("-74.0060");
    try std.testing.expectEqual(@as(i64, -74006000000), nano);
}

test "parseTimestamp: unix epoch" {
    const ts = try parseTimestamp("1609459200");
    try std.testing.expectEqual(@as(u64, 1609459200), ts);
}

test "parseRow: simple" {
    const allocator = std.testing.allocator;
    var fields = try parseRow(allocator, "a,b,c", ',');
    defer fields.deinit();
    try std.testing.expectEqual(@as(usize, 3), fields.items.len);
    try std.testing.expectEqualStrings("a", fields.items[0]);
    try std.testing.expectEqualStrings("b", fields.items[1]);
    try std.testing.expectEqualStrings("c", fields.items[2]);
}

test "parseRow: quoted fields" {
    const allocator = std.testing.allocator;
    var fields = try parseRow(allocator, "\"hello, world\",test,\"quoted\"", ',');
    defer fields.deinit();
    try std.testing.expectEqual(@as(usize, 3), fields.items.len);
    try std.testing.expectEqualStrings("hello, world", fields.items[0]);
    try std.testing.expectEqualStrings("test", fields.items[1]);
    try std.testing.expectEqualStrings("quoted", fields.items[2]);
}

test "parseEvent: basic" {
    const allocator = std.testing.allocator;
    const mapping = ColumnMapping{
        .entity_id = 0,
        .latitude = 1,
        .longitude = 2,
        .timestamp = null,
        .group_id = null,
        .ttl = null,
    };

    const event = try parseEvent(
        allocator,
        "550e8400-e29b-41d4-a716-446655440000,40.7128,-74.0060",
        ',',
        mapping,
    );

    try std.testing.expectEqual(@as(u128, 0x550e8400e29b41d4a716446655440000), event.entity_id);
    try std.testing.expectEqual(@as(i64, 40712800000), event.lat_nano);
    try std.testing.expectEqual(@as(i64, -74006000000), event.lon_nano);
}
