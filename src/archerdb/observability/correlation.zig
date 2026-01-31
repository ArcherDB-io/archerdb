// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Correlation context for distributed tracing.
//!
//! Provides parsing and propagation of trace context across service boundaries,
//! supporting both W3C Trace Context and B3 (Zipkin) header formats.
//!
//! W3C Trace Context spec: https://www.w3.org/TR/trace-context/
//! B3 propagation spec: https://github.com/openzipkin/b3-propagation
//!
//! Example:
//!
//!     // Parse incoming trace context from HTTP headers
//!     const ctx = CorrelationContext.fromTraceparent(traceparent_header) orelse
//!         CorrelationContext.fromB3Headers(b3_trace_id, b3_span_id, b3_sampled) orelse
//!         CorrelationContext.newRoot(replica_id);
//!
//!     // Set as current context for this request
//!     setCurrent(&ctx);
//!     defer setCurrent(null);
//!
//!     // Create child span for downstream calls
//!     const child_ctx = ctx.newChild();
//!     var buf: [55]u8 = undefined;
//!     const traceparent = child_ctx.toTraceparent(&buf);

const std = @import("std");
const assert = std.debug.assert;

/// Trace flags bit definitions per W3C Trace Context spec.
pub const TraceFlags = struct {
    /// The sampled flag indicates the trace should be recorded.
    pub const sampled: u8 = 0x01;
    /// Reserved flags (bits 1-7) should be preserved.
    pub const reserved_mask: u8 = 0xFE;
};

/// Correlation context for distributed tracing.
///
/// Contains identifiers for correlating spans across service boundaries:
/// - trace_id: 16-byte identifier shared by all spans in a trace
/// - span_id: 8-byte identifier unique to this span
/// - flags: trace flags (sampled, etc.)
/// - request_id: internal request correlation
/// - replica_id: replica that received the request
pub const CorrelationContext = struct {
    /// W3C trace-id (16 bytes, 32 hex chars).
    /// All spans in a trace share this identifier.
    trace_id: [16]u8,

    /// W3C parent-id / span-id (8 bytes, 16 hex chars).
    /// Unique identifier for this span.
    span_id: [8]u8,

    /// Trace flags (sampled, etc.).
    /// Bit 0 (0x01): sampled flag - when set, trace should be recorded.
    /// Bits 1-7: reserved, should be preserved.
    flags: u8,

    /// Internal request ID for correlation within ArcherDB.
    /// Allows mapping external trace IDs to internal request processing.
    request_id: u128,

    /// Replica that received the request.
    /// Used to distinguish spans from different replicas.
    replica_id: u8,

    /// Parse from W3C traceparent header.
    ///
    /// Format: version-trace_id-parent_id-flags
    /// Example: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    ///
    /// Returns null if header is invalid or version is unsupported.
    pub fn fromTraceparent(header: []const u8) ?CorrelationContext {
        // Minimum length: 2 (version) + 1 (-) + 32 (trace_id) + 1 (-) + 16 (span_id) + 1 (-) + 2 (flags) = 55
        if (header.len < 55) return null;

        // Split by '-' delimiter
        var parts: [4][]const u8 = undefined;
        var count: usize = 0;
        var start: usize = 0;

        for (header, 0..) |c, i| {
            if (c == '-') {
                if (count >= 4) return null; // Too many parts
                parts[count] = header[start..i];
                count += 1;
                start = i + 1;
            }
        }
        // Add final part
        if (count >= 4) return null;
        parts[count] = header[start..];
        count += 1;

        if (count != 4) return null;

        const version = parts[0];
        const trace_id_hex = parts[1];
        const span_id_hex = parts[2];
        const flags_hex = parts[3];

        // Validate version (only 00 is supported)
        if (version.len != 2) return null;
        if (version[0] != '0' or version[1] != '0') return null;

        // Validate trace_id length (32 hex chars = 16 bytes)
        if (trace_id_hex.len != 32) return null;

        // Validate span_id length (16 hex chars = 8 bytes)
        if (span_id_hex.len != 16) return null;

        // Validate flags length (2 hex chars = 1 byte)
        if (flags_hex.len != 2) return null;

        // Parse trace_id
        var trace_id: [16]u8 = undefined;
        for (0..16) |i| {
            const high = hexDigit(trace_id_hex[i * 2]) orelse return null;
            const low = hexDigit(trace_id_hex[i * 2 + 1]) orelse return null;
            trace_id[i] = (high << 4) | low;
        }

        // Validate trace_id is not all zeros
        var all_zero = true;
        for (trace_id) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return null;

        // Parse span_id
        var span_id: [8]u8 = undefined;
        for (0..8) |i| {
            const high = hexDigit(span_id_hex[i * 2]) orelse return null;
            const low = hexDigit(span_id_hex[i * 2 + 1]) orelse return null;
            span_id[i] = (high << 4) | low;
        }

        // Validate span_id is not all zeros
        all_zero = true;
        for (span_id) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return null;

        // Parse flags
        const flags_high = hexDigit(flags_hex[0]) orelse return null;
        const flags_low = hexDigit(flags_hex[1]) orelse return null;
        const flags = (flags_high << 4) | flags_low;

        return CorrelationContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .flags = flags,
            .request_id = generateRequestId(),
            .replica_id = 0, // Will be set by caller
        };
    }

    /// Parse from B3 headers (X-B3-TraceId, X-B3-SpanId, X-B3-Sampled).
    ///
    /// B3 supports both 64-bit and 128-bit trace IDs. 64-bit IDs are
    /// zero-padded in the high bytes to become 128-bit.
    ///
    /// Returns null if required headers are missing or invalid.
    pub fn fromB3Headers(
        trace_id_header: ?[]const u8,
        span_id_header: ?[]const u8,
        sampled_header: ?[]const u8,
    ) ?CorrelationContext {
        const trace_id_hex = trace_id_header orelse return null;
        const span_id_hex = span_id_header orelse return null;

        // B3 trace_id can be 16 chars (64-bit) or 32 chars (128-bit)
        var trace_id: [16]u8 = [_]u8{0} ** 16;
        if (trace_id_hex.len == 32) {
            // 128-bit trace ID
            for (0..16) |i| {
                const high = hexDigit(trace_id_hex[i * 2]) orelse return null;
                const low = hexDigit(trace_id_hex[i * 2 + 1]) orelse return null;
                trace_id[i] = (high << 4) | low;
            }
        } else if (trace_id_hex.len == 16) {
            // 64-bit trace ID - pad high bytes with zeros
            for (0..8) |i| {
                const high = hexDigit(trace_id_hex[i * 2]) orelse return null;
                const low = hexDigit(trace_id_hex[i * 2 + 1]) orelse return null;
                trace_id[8 + i] = (high << 4) | low;
            }
        } else {
            return null;
        }

        // Validate trace_id is not all zeros
        var all_zero = true;
        for (trace_id) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return null;

        // B3 span_id is always 16 chars (64-bit)
        if (span_id_hex.len != 16) return null;

        var span_id: [8]u8 = undefined;
        for (0..8) |i| {
            const high = hexDigit(span_id_hex[i * 2]) orelse return null;
            const low = hexDigit(span_id_hex[i * 2 + 1]) orelse return null;
            span_id[i] = (high << 4) | low;
        }

        // Validate span_id is not all zeros
        all_zero = true;
        for (span_id) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return null;

        // Parse sampled flag (optional)
        var flags: u8 = 0;
        if (sampled_header) |sampled| {
            if (sampled.len == 1) {
                if (sampled[0] == '1' or sampled[0] == 'd') {
                    flags = TraceFlags.sampled;
                }
            } else if (std.mem.eql(u8, sampled, "true")) {
                flags = TraceFlags.sampled;
            }
        }

        return CorrelationContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .flags = flags,
            .request_id = generateRequestId(),
            .replica_id = 0, // Will be set by caller
        };
    }

    /// Generate a new root context (when no incoming trace exists).
    ///
    /// Creates a new trace with a randomly generated trace_id and span_id.
    /// The sampled flag is set by default.
    pub fn newRoot(replica_id: u8) CorrelationContext {
        var trace_id: [16]u8 = undefined;
        var span_id: [8]u8 = undefined;

        std.crypto.random.bytes(&trace_id);
        std.crypto.random.bytes(&span_id);

        return CorrelationContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .flags = TraceFlags.sampled, // Sample by default for new traces
            .request_id = generateRequestId(),
            .replica_id = replica_id,
        };
    }

    /// Generate a child span context.
    ///
    /// The child inherits the trace_id and flags from the parent,
    /// but gets a new random span_id.
    pub fn newChild(self: *const CorrelationContext) CorrelationContext {
        var span_id: [8]u8 = undefined;
        std.crypto.random.bytes(&span_id);

        return CorrelationContext{
            .trace_id = self.trace_id,
            .span_id = span_id,
            .flags = self.flags, // Preserve sampling decision
            .request_id = self.request_id, // Keep same request correlation
            .replica_id = self.replica_id,
        };
    }

    /// Format as W3C traceparent header value.
    ///
    /// Format: "00-{trace_id}-{span_id}-{flags}"
    /// Example: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    ///
    /// Buffer must be at least 55 bytes.
    pub fn toTraceparent(self: *const CorrelationContext, buf: []u8) []const u8 {
        assert(buf.len >= 55);

        // Version
        buf[0] = '0';
        buf[1] = '0';
        buf[2] = '-';

        // Trace ID (32 hex chars)
        for (self.trace_id, 0..) |b, i| {
            buf[3 + i * 2] = hexChar(b >> 4);
            buf[3 + i * 2 + 1] = hexChar(b & 0x0F);
        }
        buf[35] = '-';

        // Span ID (16 hex chars)
        for (self.span_id, 0..) |b, i| {
            buf[36 + i * 2] = hexChar(b >> 4);
            buf[36 + i * 2 + 1] = hexChar(b & 0x0F);
        }
        buf[52] = '-';

        // Flags (2 hex chars)
        buf[53] = hexChar(self.flags >> 4);
        buf[54] = hexChar(self.flags & 0x0F);

        return buf[0..55];
    }

    /// Format trace_id as lowercase hex string (for JSON/logs).
    pub fn traceIdHex(self: *const CorrelationContext) [32]u8 {
        var result: [32]u8 = undefined;
        for (self.trace_id, 0..) |b, i| {
            result[i * 2] = hexChar(b >> 4);
            result[i * 2 + 1] = hexChar(b & 0x0F);
        }
        return result;
    }

    /// Format span_id as lowercase hex string (for JSON/logs).
    pub fn spanIdHex(self: *const CorrelationContext) [16]u8 {
        var result: [16]u8 = undefined;
        for (self.span_id, 0..) |b, i| {
            result[i * 2] = hexChar(b >> 4);
            result[i * 2 + 1] = hexChar(b & 0x0F);
        }
        return result;
    }

    /// Returns first 12 characters of trace ID hex for easier communication.
    /// Full trace ID is preserved internally for W3C compatibility.
    /// The short ID is sufficient for verbal communication during incidents
    /// while keeping logs greppable.
    pub fn shortTraceId(self: *const CorrelationContext) [12]u8 {
        var result: [12]u8 = undefined;
        const full_hex = self.traceIdHex();
        @memcpy(&result, full_hex[0..12]);
        return result;
    }

    /// Check if sampled flag is set.
    pub fn isSampled(self: *const CorrelationContext) bool {
        return (self.flags & TraceFlags.sampled) != 0;
    }

    /// Set the sampled flag.
    pub fn setSampled(self: *CorrelationContext, sampled: bool) void {
        if (sampled) {
            self.flags |= TraceFlags.sampled;
        } else {
            self.flags &= ~TraceFlags.sampled;
        }
    }

    /// Get the parent span ID for creating child spans.
    /// Returns the current span_id which becomes the parent of the child.
    pub fn parentSpanId(self: *const CorrelationContext) [8]u8 {
        return self.span_id;
    }
};

/// Thread-local storage for current correlation context.
/// Used to propagate context through the request handling path.
threadlocal var current_context: ?*const CorrelationContext = null;

/// Set the current correlation context for this thread.
///
/// Call at the start of request handling with the parsed context.
/// Call with null at the end of request handling to clear.
pub fn setCurrent(ctx: ?*const CorrelationContext) void {
    current_context = ctx;
}

/// Get the current correlation context for this thread.
///
/// Returns null if no context has been set (e.g., outside request handling).
pub fn getCurrent() ?*const CorrelationContext {
    return current_context;
}

// Helper functions

/// Convert a hex character to its 4-bit value.
fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Convert a 4-bit value to lowercase hex character.
fn hexChar(val: u8) u8 {
    assert(val < 16);
    return if (val < 10) '0' + val else 'a' + val - 10;
}

/// Generate a unique request ID using random bytes.
fn generateRequestId() u128 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.mem.readInt(u128, &bytes, .little);
}

// =============================================================================
// Tests
// =============================================================================

test "fromTraceparent: valid header" {
    const header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const ctx = CorrelationContext.fromTraceparent(header).?;

    // Check trace_id was parsed correctly
    const expected_trace_id = [_]u8{
        0x0a, 0xf7, 0x65, 0x19, 0x16, 0xcd, 0x43, 0xdd,
        0x84, 0x48, 0xeb, 0x21, 0x1c, 0x80, 0x31, 0x9c,
    };
    try std.testing.expectEqualSlices(u8, &expected_trace_id, &ctx.trace_id);

    // Check span_id was parsed correctly
    const expected_span_id = [_]u8{
        0xb7, 0xad, 0x6b, 0x71, 0x69, 0x20, 0x33, 0x31,
    };
    try std.testing.expectEqualSlices(u8, &expected_span_id, &ctx.span_id);

    // Check flags
    try std.testing.expectEqual(@as(u8, 0x01), ctx.flags);
    try std.testing.expect(ctx.isSampled());
}

test "fromTraceparent: not sampled" {
    const header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00";
    const ctx = CorrelationContext.fromTraceparent(header).?;

    try std.testing.expectEqual(@as(u8, 0x00), ctx.flags);
    try std.testing.expect(!ctx.isSampled());
}

test "fromTraceparent: invalid version" {
    const header = "01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    try std.testing.expect(CorrelationContext.fromTraceparent(header) == null);
}

test "fromTraceparent: all-zero trace_id" {
    const header = "00-00000000000000000000000000000000-b7ad6b7169203331-01";
    try std.testing.expect(CorrelationContext.fromTraceparent(header) == null);
}

test "fromTraceparent: all-zero span_id" {
    const header = "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01";
    try std.testing.expect(CorrelationContext.fromTraceparent(header) == null);
}

test "fromTraceparent: too short" {
    const header = "00-0af7651916cd43dd";
    try std.testing.expect(CorrelationContext.fromTraceparent(header) == null);
}

test "fromTraceparent: invalid hex" {
    const header = "00-0af7651916cd43dd8448eb211c80319g-b7ad6b7169203331-01";
    try std.testing.expect(CorrelationContext.fromTraceparent(header) == null);
}

test "fromB3Headers: 128-bit trace ID" {
    const ctx = CorrelationContext.fromB3Headers(
        "0af7651916cd43dd8448eb211c80319c",
        "b7ad6b7169203331",
        "1",
    ).?;

    const expected_trace_id = [_]u8{
        0x0a, 0xf7, 0x65, 0x19, 0x16, 0xcd, 0x43, 0xdd,
        0x84, 0x48, 0xeb, 0x21, 0x1c, 0x80, 0x31, 0x9c,
    };
    try std.testing.expectEqualSlices(u8, &expected_trace_id, &ctx.trace_id);
    try std.testing.expect(ctx.isSampled());
}

test "fromB3Headers: 64-bit trace ID (zero-padded)" {
    const ctx = CorrelationContext.fromB3Headers(
        "8448eb211c80319c",
        "b7ad6b7169203331",
        "true",
    ).?;

    // 64-bit trace ID should be zero-padded in high bytes
    const expected_trace_id = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x84, 0x48, 0xeb, 0x21, 0x1c, 0x80, 0x31, 0x9c,
    };
    try std.testing.expectEqualSlices(u8, &expected_trace_id, &ctx.trace_id);
    try std.testing.expect(ctx.isSampled());
}

test "fromB3Headers: not sampled" {
    const ctx = CorrelationContext.fromB3Headers(
        "0af7651916cd43dd8448eb211c80319c",
        "b7ad6b7169203331",
        "0",
    ).?;

    try std.testing.expect(!ctx.isSampled());
}

test "fromB3Headers: missing trace ID" {
    try std.testing.expect(CorrelationContext.fromB3Headers(
        null,
        "b7ad6b7169203331",
        "1",
    ) == null);
}

test "fromB3Headers: missing span ID" {
    try std.testing.expect(CorrelationContext.fromB3Headers(
        "0af7651916cd43dd8448eb211c80319c",
        null,
        "1",
    ) == null);
}

test "newRoot: generates valid context" {
    const ctx = CorrelationContext.newRoot(5);

    try std.testing.expectEqual(@as(u8, 5), ctx.replica_id);
    try std.testing.expect(ctx.isSampled()); // New traces are sampled by default

    // Verify trace_id and span_id are not all zeros
    var trace_all_zero = true;
    for (ctx.trace_id) |b| {
        if (b != 0) {
            trace_all_zero = false;
            break;
        }
    }
    try std.testing.expect(!trace_all_zero);

    var span_all_zero = true;
    for (ctx.span_id) |b| {
        if (b != 0) {
            span_all_zero = false;
            break;
        }
    }
    try std.testing.expect(!span_all_zero);
}

test "newChild: inherits trace_id and flags" {
    const parent = CorrelationContext.newRoot(3);
    const child = parent.newChild();

    // Child should inherit trace_id
    try std.testing.expectEqualSlices(u8, &parent.trace_id, &child.trace_id);

    // Child should inherit flags
    try std.testing.expectEqual(parent.flags, child.flags);

    // Child should inherit replica_id
    try std.testing.expectEqual(parent.replica_id, child.replica_id);

    // Child should have different span_id
    try std.testing.expect(!std.mem.eql(u8, &parent.span_id, &child.span_id));
}

test "toTraceparent: roundtrip" {
    const original = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const ctx = CorrelationContext.fromTraceparent(original).?;

    var buf: [55]u8 = undefined;
    const result = ctx.toTraceparent(&buf);

    try std.testing.expectEqualStrings(original, result);
}

test "traceIdHex and spanIdHex" {
    const header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const ctx = CorrelationContext.fromTraceparent(header).?;

    const trace_hex = ctx.traceIdHex();
    try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &trace_hex);

    const span_hex = ctx.spanIdHex();
    try std.testing.expectEqualStrings("b7ad6b7169203331", &span_hex);
}

test "shortTraceId returns first 12 chars" {
    const header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const ctx = CorrelationContext.fromTraceparent(header).?;

    const short_id = ctx.shortTraceId();
    // Should be first 12 characters of "0af7651916cd43dd8448eb211c80319c"
    try std.testing.expectEqualStrings("0af7651916cd", &short_id);
    try std.testing.expectEqual(@as(usize, 12), short_id.len);
}

test "thread-local context" {
    try std.testing.expect(getCurrent() == null);

    const ctx = CorrelationContext.newRoot(1);
    setCurrent(&ctx);
    defer setCurrent(null);

    const retrieved = getCurrent().?;
    try std.testing.expectEqualSlices(u8, &ctx.trace_id, &retrieved.trace_id);
}

test "setSampled" {
    var ctx = CorrelationContext.newRoot(0);
    try std.testing.expect(ctx.isSampled());

    ctx.setSampled(false);
    try std.testing.expect(!ctx.isSampled());

    ctx.setSampled(true);
    try std.testing.expect(ctx.isSampled());
}
