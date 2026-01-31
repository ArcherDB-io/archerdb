// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Structured JSON log handler with correlation context and redaction.
//!
//! Provides NDJSON (newline-delimited JSON) output for log aggregation systems
//! like Elasticsearch, Loki, or Splunk. Integrates with the correlation context
//! module to include trace/span IDs in log output.
//!
//! Log entry schema:
//! ```json
//! {
//!   "ts": 1706000000000,      // Unix timestamp milliseconds
//!   "level": "info",          // err, warn, info, debug
//!   "scope": "replica",       // Log scope
//!   "msg": "the message",     // Log message
//!   "trace_id": "0af7651916cd", // Optional, 12-char short ID for verbal communication
//!   "span_id": "b7ad6b71...",   // Optional, full 16-char span ID
//!   "request_id": "...",      // Optional (as hex string)
//!   "replica_id": 0           // Optional
//! }
//! ```
//!
//! Note: trace_id uses a 12-character short form for easier copy/paste during
//! incident response. The full 32-character W3C trace ID is available via the
//! correlation context (CorrelationContext.traceIdHex()) when needed for
//! external tracing system integration.
//!
//! Redaction:
//! At info/warn levels, sensitive data (coordinates, content) is automatically
//! redacted to prevent PII exposure in production logs. Debug level includes
//! full data for development troubleshooting.
//!
//! Example:
//!
//!     const handler = JsonLogHandler.init(std.io.getStdErr().writer(), true);
//!     handler.log(.info, .replica, "processing request {}", .{42});
//!     // Output: {"ts":1706000000000,"level":"info","scope":"replica","msg":"processing request 42",...}

const std = @import("std");
const assert = std.debug.assert;

const correlation = @import("correlation.zig");

/// JSON log handler for structured logging output.
///
/// Outputs NDJSON (newline-delimited JSON) suitable for log aggregation.
/// Includes correlation context when available and redacts sensitive
/// data at info/warn levels.
pub const JsonLogHandler = struct {
    writer: std.fs.File.Writer,
    /// Whether to redact sensitive data at info/warn levels.
    redact_sensitive: bool,

    /// Initialize a JSON log handler.
    ///
    /// writer: Output destination (typically stderr or a log file).
    /// redact_sensitive: If true, sensitive data is redacted at info/warn levels.
    pub fn init(writer: std.fs.File.Writer, redact_sensitive: bool) JsonLogHandler {
        return .{
            .writer = writer,
            .redact_sensitive = redact_sensitive,
        };
    }

    /// Log a message in JSON format.
    ///
    /// Formats the message as NDJSON with timestamp, level, scope, message,
    /// and optional correlation context fields.
    pub fn log(
        self: *const JsonLogHandler,
        comptime level: std.log.Level,
        comptime scope: @Type(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const level_text = comptime levelString(level);
        const scope_name = comptime if (scope == .default) "default" else @tagName(scope);

        // Format the message first
        var msg_buf: [4096]u8 = undefined;
        const raw_message = std.fmt.bufPrint(&msg_buf, format, args) catch "[message truncated]";

        // Apply redaction if needed (at info/warn levels when enabled)
        var redacted_buf: [4096]u8 = undefined;
        const message = if (self.redact_sensitive and shouldRedact(level))
            redactSensitiveData(raw_message, &redacted_buf)
        else
            raw_message;

        // Build JSON output
        var log_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&log_buf);
        const writer = fbs.writer();

        // Get current timestamp in milliseconds
        const ts_ns = std.time.nanoTimestamp();
        const ts_ms: i64 = @intCast(@divFloor(ts_ns, 1_000_000));

        // Start JSON object
        writer.print("{{\"ts\":{d},\"level\":\"{s}\",\"scope\":\"{s}\",\"msg\":\"", .{
            ts_ms,
            level_text,
            scope_name,
        }) catch return;

        // JSON-escape the message
        escapeJsonToWriter(writer, message) catch return;
        writer.writeByte('"') catch return;

        // Add correlation context if available
        // trace_id: 12-char short ID for verbal communication during incidents
        // Full trace ID is available via correlation context if needed for W3C compatibility
        if (correlation.getCurrent()) |ctx| {
            const short_trace = ctx.shortTraceId();
            const span_hex = ctx.spanIdHex();
            writer.print(",\"trace_id\":\"{s}\",\"span_id\":\"{s}\"", .{
                short_trace,
                span_hex,
            }) catch return;

            // Format request_id as hex
            var req_buf: [32]u8 = undefined;
            const req_hex = formatU128Hex(ctx.request_id, &req_buf);
            writer.print(",\"request_id\":\"{s}\",\"replica_id\":{d}", .{
                req_hex,
                ctx.replica_id,
            }) catch return;
        }

        // Close JSON object with newline
        writer.writeAll("}\n") catch return;

        // Write to output
        _ = self.writer.write(fbs.getWritten()) catch {};
    }
};

/// Convert log level to lowercase string.
fn levelString(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "err",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

/// Check if redaction should be applied for this log level.
fn shouldRedact(level: std.log.Level) bool {
    return switch (level) {
        .err => false, // Don't redact errors (need full context for debugging)
        .warn => true,
        .info => true,
        .debug => false, // Debug has full data
    };
}

/// Redact sensitive data patterns in a message.
///
/// Detects and redacts:
/// - Coordinates (lat/lon patterns)
/// - Entity content fields
/// - Metadata fields
///
/// Returns a slice into redacted_buf with the redacted message.
fn redactSensitiveData(input: []const u8, redacted_buf: []u8) []const u8 {
    var output_len: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        // Check for coordinate patterns
        if (matchesCoordinatePattern(input, i)) |end_idx| {
            // Replace with redaction marker
            const marker = "[REDACTED:coords]";
            if (output_len + marker.len < redacted_buf.len) {
                @memcpy(redacted_buf[output_len..][0..marker.len], marker);
                output_len += marker.len;
            }
            i = end_idx;
            continue;
        }

        // Check for content/metadata field patterns
        if (matchesContentPattern(input, i)) |end_idx| {
            const marker = "[REDACTED:content]";
            if (output_len + marker.len < redacted_buf.len) {
                @memcpy(redacted_buf[output_len..][0..marker.len], marker);
                output_len += marker.len;
            }
            i = end_idx;
            continue;
        }

        // Copy character as-is
        if (output_len < redacted_buf.len) {
            redacted_buf[output_len] = input[i];
            output_len += 1;
        }
        i += 1;
    }

    return redacted_buf[0..output_len];
}

/// Check if input at position matches coordinate patterns.
/// Returns end index if matched, null otherwise.
///
/// Patterns:
/// - "lat" followed by digits and "lon"
/// - "latitude" followed by digits and "longitude"
fn matchesCoordinatePattern(input: []const u8, start: usize) ?usize {
    const remaining = input[start..];

    // Check for "lat" pattern (case insensitive start)
    if (remaining.len >= 3) {
        const prefix = remaining[0..3];
        if (std.ascii.eqlIgnoreCase(prefix, "lat")) {
            // Look for "lon" after some digits
            var j: usize = 3;
            while (j < remaining.len) : (j += 1) {
                if (j + 3 <= remaining.len) {
                    if (std.ascii.eqlIgnoreCase(remaining[j..][0..3], "lon")) {
                        // Found lon, skip past the value
                        var end = j + 3;
                        // Skip digits, dots, minus, spaces, colons, equals
                        while (end < remaining.len) {
                            const c = remaining[end];
                            if (isCoordChar(c)) {
                                end += 1;
                            } else {
                                break;
                            }
                        }
                        return start + end;
                    }
                }
                // Stop if we hit a clear separator without finding lon
                if (remaining[j] == '}' or remaining[j] == ']' or remaining[j] == '\n') {
                    break;
                }
            }
        }
    }

    // Check for "latitude" pattern
    if (remaining.len >= 8) {
        if (std.ascii.eqlIgnoreCase(remaining[0..8], "latitude")) {
            var j: usize = 8;
            while (j < remaining.len) : (j += 1) {
                if (j + 9 <= remaining.len) {
                    if (std.ascii.eqlIgnoreCase(remaining[j..][0..9], "longitude")) {
                        var end = j + 9;
                        while (end < remaining.len) {
                            const c = remaining[end];
                            if (isCoordChar(c)) {
                                end += 1;
                            } else {
                                break;
                            }
                        }
                        return start + end;
                    }
                }
                if (remaining[j] == '}' or remaining[j] == ']' or remaining[j] == '\n') {
                    break;
                }
            }
        }
    }

    return null;
}

/// Check if character is part of a coordinate value.
fn isCoordChar(c: u8) bool {
    return switch (c) {
        '0'...'9', '.', '-', '+', ' ', ':', '=', ',', 'e', 'E' => true,
        else => false,
    };
}

/// Check if input at position matches content/metadata field patterns.
/// Returns end index if matched, null otherwise.
///
/// Patterns:
/// - "content:" or "content="
/// - "metadata:" or "metadata="
fn matchesContentPattern(input: []const u8, start: usize) ?usize {
    const remaining = input[start..];

    // Check for "content:" or "content="
    const patterns = [_][]const u8{ "content:", "content=", "metadata:", "metadata=" };
    for (patterns) |pattern| {
        if (remaining.len >= pattern.len) {
            if (std.ascii.eqlIgnoreCase(remaining[0..pattern.len], pattern)) {
                // Skip until we hit a clear boundary
                var end: usize = pattern.len;
                // Skip quoted string or until separator
                if (end < remaining.len and remaining[end] == '"') {
                    // Skip quoted string
                    end += 1;
                    while (end < remaining.len) {
                        if (remaining[end] == '"' and (end == 0 or remaining[end - 1] != '\\')) {
                            end += 1;
                            break;
                        }
                        end += 1;
                    }
                } else {
                    // Skip until comma, brace, bracket, or newline
                    while (end < remaining.len) {
                        const c = remaining[end];
                        if (c == ',' or c == '}' or c == ']' or c == '\n' or c == ' ') {
                            break;
                        }
                        end += 1;
                    }
                }
                return start + end;
            }
        }
    }

    return null;
}

/// Escape a string for JSON and write to a writer.
fn escapeJsonToWriter(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
}

/// Format a u128 as lowercase hex string.
fn formatU128Hex(value: u128, buf: []u8) []const u8 {
    assert(buf.len >= 32);
    const bytes: [16]u8 = @bitCast(std.mem.nativeToBig(u128, value));
    for (bytes, 0..) |b, i| {
        buf[i * 2] = hexChar(b >> 4);
        buf[i * 2 + 1] = hexChar(b & 0x0F);
    }
    return buf[0..32];
}

/// Convert a 4-bit value to lowercase hex character.
fn hexChar(val: u8) u8 {
    assert(val < 16);
    return if (val < 10) '0' + val else 'a' + val - 10;
}

// =============================================================================
// Auto-detection helper for TTY vs pipe
// =============================================================================

/// Log format enumeration (mirrors cli.LogFormat).
pub const LogFormat = enum {
    text,
    json,
};

/// Determine the appropriate log format based on explicit setting or auto-detection.
///
/// If explicit_format is provided, use it directly.
/// Otherwise, auto-detect: text for TTY, JSON for pipes/files.
pub fn determineLogFormat(explicit_format: ?LogFormat) LogFormat {
    if (explicit_format) |fmt| {
        return fmt;
    }
    // Auto-detect: JSON for pipes/files, text for TTY
    const stderr = std.io.getStdErr();
    return if (stderr.isTty()) .text else .json;
}

// =============================================================================
// Tests
// =============================================================================

test "levelString" {
    try std.testing.expectEqualStrings("err", levelString(.err));
    try std.testing.expectEqualStrings("warn", levelString(.warn));
    try std.testing.expectEqualStrings("info", levelString(.info));
    try std.testing.expectEqualStrings("debug", levelString(.debug));
}

test "shouldRedact" {
    try std.testing.expect(!shouldRedact(.err));
    try std.testing.expect(shouldRedact(.warn));
    try std.testing.expect(shouldRedact(.info));
    try std.testing.expect(!shouldRedact(.debug));
}

test "redactSensitiveData: coordinates" {
    var buf: [256]u8 = undefined;

    // Test lat/lon pattern
    const input1 = "entity at lat=37.7749 lon=-122.4194";
    const result1 = redactSensitiveData(input1, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result1, "[REDACTED:coords]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result1, "37.7749") == null);

    // Test latitude/longitude pattern
    var buf2: [256]u8 = undefined;
    const input2 = "position latitude: 51.5074 longitude: -0.1278";
    const result2 = redactSensitiveData(input2, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, result2, "[REDACTED:coords]") != null);
}

test "redactSensitiveData: content" {
    var buf: [256]u8 = undefined;

    const input = "event content:sensitive_data here";
    const result = redactSensitiveData(input, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED:content]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sensitive_data") == null);
}

test "redactSensitiveData: no redaction needed" {
    var buf: [256]u8 = undefined;

    const input = "normal log message without sensitive data";
    const result = redactSensitiveData(input, &buf);
    try std.testing.expectEqualStrings(input, result);
}

test "escapeJsonToWriter" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try escapeJsonToWriter(writer, "hello \"world\"\ntest\ttab");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\ntest\\ttab", fbs.getWritten());
}

test "formatU128Hex" {
    var buf: [32]u8 = undefined;

    const result = formatU128Hex(0x0123456789abcdef0123456789abcdef, &buf);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", result);
}

test "determineLogFormat: explicit" {
    try std.testing.expectEqual(LogFormat.json, determineLogFormat(.json));
    try std.testing.expectEqual(LogFormat.text, determineLogFormat(.text));
}

test "isCoordChar" {
    try std.testing.expect(isCoordChar('0'));
    try std.testing.expect(isCoordChar('9'));
    try std.testing.expect(isCoordChar('.'));
    try std.testing.expect(isCoordChar('-'));
    try std.testing.expect(!isCoordChar('x'));
    try std.testing.expect(!isCoordChar('\n'));
}

test "hexChar" {
    try std.testing.expectEqual(@as(u8, '0'), hexChar(0));
    try std.testing.expectEqual(@as(u8, '9'), hexChar(9));
    try std.testing.expectEqual(@as(u8, 'a'), hexChar(10));
    try std.testing.expectEqual(@as(u8, 'f'), hexChar(15));
}
