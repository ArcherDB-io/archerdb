// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! OTLP (OpenTelemetry Protocol) trace exporter.
//!
//! Exports spans to an OTLP-compatible collector (Jaeger, Tempo, etc.) via HTTP JSON.
//! The exporter buffers spans internally and flushes them asynchronously to avoid
//! blocking request processing.
//!
//! Per RESEARCH.md anti-patterns: No retries on export failure (spans are dropped).
//! This prevents observability from affecting production reliability.
//!
//! OTLP spec: https://opentelemetry.io/docs/specs/otlp/
//!
//! Example:
//!
//!     var exporter = try OtlpTraceExporter.init(allocator, "http://localhost:4318/v1/traces");
//!     defer exporter.deinit();
//!
//!     exporter.recordSpan(.{
//!         .trace_id = ctx.trace_id,
//!         .span_id = ctx.span_id,
//!         .name = "geo.radius_query",
//!         .kind = .server,
//!         .start_time_ns = start,
//!         .end_time_ns = end,
//!         .status = .ok,
//!     });
//!
//!     // Spans are automatically flushed periodically or when buffer is full

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const log = std.log.scoped(.trace_export);

const vsr = @import("vsr");
const stdx = vsr.stdx;

const correlation = @import("correlation.zig");

/// OTLP span kind values per OpenTelemetry spec.
pub const SpanKind = enum(u8) {
    /// Internal operation within an application.
    internal = 1,
    /// Server-side handling of a synchronous request.
    server = 2,
    /// Client-side of an outgoing request.
    client = 3,
    /// Producer of a message (async).
    producer = 4,
    /// Consumer of a message (async).
    consumer = 5,
};

/// OTLP span status code per OpenTelemetry spec.
pub const SpanStatus = enum(u8) {
    /// Status not set.
    unset = 0,
    /// Operation completed successfully.
    ok = 1,
    /// Operation failed with an error.
    @"error" = 2,
};

/// Attribute value types for span attributes.
pub const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
};

/// Span attribute key-value pair.
pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,
};

/// Span event (e.g., log message within a span).
pub const SpanEvent = struct {
    name: []const u8,
    time_ns: i128,
    attributes: []const Attribute,
};

/// Span link connecting spans across services/shards.
pub const SpanLink = struct {
    trace_id: [16]u8,
    span_id: [8]u8,
    attributes: []const Attribute,
};

/// A recorded span for export.
pub const Span = struct {
    /// W3C trace-id (16 bytes).
    trace_id: [16]u8,
    /// Span-id (8 bytes).
    span_id: [8]u8,
    /// Parent span-id (null for root spans).
    parent_span_id: ?[8]u8,
    /// Span name (operation name).
    name: []const u8,
    /// Span kind.
    kind: SpanKind,
    /// Start time in nanoseconds since Unix epoch.
    start_time_ns: i128,
    /// End time in nanoseconds since Unix epoch.
    end_time_ns: i128,
    /// Span attributes.
    attributes: []const Attribute,
    /// Span links for fan-out/parallel operations.
    links: []const SpanLink,
    /// Span events.
    events: []const SpanEvent,
    /// Span status.
    status: SpanStatus,
    /// Status message (for error status).
    status_message: ?[]const u8,
};

/// OTLP trace exporter configuration.
pub const ExporterConfig = struct {
    /// Maximum number of spans to buffer before forcing a flush.
    max_batch_size: usize = 100,
    /// Flush interval in nanoseconds (default 5 seconds).
    flush_interval_ns: i128 = 5_000_000_000,
    /// HTTP timeout in milliseconds.
    timeout_ms: u32 = 5000,
    /// Service name for resource attributes.
    service_name: []const u8 = "archerdb",
    /// Service version for resource attributes.
    service_version: []const u8 = "0.0.1",
};

/// Owned copy of a span for buffering.
const OwnedSpan = struct {
    trace_id: [16]u8,
    span_id: [8]u8,
    parent_span_id: ?[8]u8,
    name: []const u8,
    kind: SpanKind,
    start_time_ns: i128,
    end_time_ns: i128,
    status: SpanStatus,
    status_message: ?[]const u8,
    attributes: []const Attribute,
    links: []const SpanLink,
    events: []const SpanEvent,
};

/// OTLP trace exporter.
///
/// Buffers spans and exports them asynchronously to an OTLP collector.
/// Export happens on a dedicated thread to avoid blocking request processing.
pub const OtlpTraceExporter = struct {
    /// OTLP collector endpoint (e.g., "http://localhost:4318/v1/traces").
    endpoint: []const u8,
    /// Host portion of endpoint for HTTP Host header.
    host: []const u8,
    /// Port number.
    port: u16,
    /// Path portion of endpoint.
    path: []const u8,
    /// Span buffer.
    buffer: std.ArrayList(OwnedSpan),
    /// Allocator for buffer management.
    allocator: std.mem.Allocator,
    /// Configuration.
    config: ExporterConfig,
    /// Last flush timestamp (nanoseconds).
    last_flush_ns: i128,
    /// Mutex for thread-safe buffer access.
    mutex: std.Thread.Mutex,
    /// Export thread.
    export_thread: ?std.Thread,
    /// Running flag for graceful shutdown.
    running: std.atomic.Value(bool),
    /// Signal for flush requests.
    flush_requested: std.atomic.Value(bool),

    /// Initialize a new OTLP trace exporter.
    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !*OtlpTraceExporter {
        return initWithConfig(allocator, endpoint, .{});
    }

    /// Initialize with custom configuration.
    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        config: ExporterConfig,
    ) !*OtlpTraceExporter {
        const self = try allocator.create(OtlpTraceExporter);
        errdefer allocator.destroy(self);

        // Parse endpoint URL
        const parsed = parseEndpoint(endpoint) catch {
            log.warn("invalid OTLP endpoint: {s}, exporter disabled", .{endpoint});
            allocator.destroy(self);
            return error.InvalidEndpoint;
        };

        self.* = OtlpTraceExporter{
            .endpoint = endpoint,
            .host = parsed.host,
            .port = parsed.port,
            .path = parsed.path,
            .buffer = std.ArrayList(OwnedSpan).init(allocator),
            .allocator = allocator,
            .config = config,
            .last_flush_ns = std.time.nanoTimestamp(),
            .mutex = .{},
            .export_thread = null,
            .running = std.atomic.Value(bool).init(true),
            .flush_requested = std.atomic.Value(bool).init(false),
        };

        // Start export thread
        self.export_thread = std.Thread.spawn(.{}, exportLoop, .{self}) catch |err| {
            log.warn("failed to start export thread: {}, exporter disabled", .{err});
            self.buffer.deinit();
            allocator.destroy(self);
            return err;
        };

        log.info("OTLP trace exporter initialized: {s}", .{endpoint});
        return self;
    }

    /// Deinitialize and clean up resources.
    pub fn deinit(self: *OtlpTraceExporter) void {
        // Signal shutdown
        self.running.store(false, .release);
        self.flush_requested.store(true, .release);

        // Wait for export thread
        if (self.export_thread) |thread| {
            thread.join();
        }

        // Free buffered span names
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.buffer.items) |span| {
            freeOwnedSpan(self.allocator, &span);
        }
        self.buffer.deinit();

        log.info("OTLP trace exporter stopped", .{});
        self.allocator.destroy(self);
    }

    /// Record a span (non-blocking, buffers internally).
    ///
    /// This method is safe to call from any thread and will not block
    /// request processing. Spans are batched and sent asynchronously.
    pub fn recordSpan(self: *OtlpTraceExporter, span: Span) void {
        const owned_span = copySpan(self.allocator, span) catch |err| {
            log.warn("failed to allocate span ({}), dropping span", .{err});
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        self.buffer.append(owned_span) catch {
            log.warn("span buffer full, dropping span", .{});
            freeOwnedSpan(self.allocator, &owned_span);
            return;
        };

        // Check if we should trigger a flush
        if (self.buffer.items.len >= self.config.max_batch_size) {
            self.flush_requested.store(true, .release);
        }
    }

    /// Force an immediate flush of buffered spans.
    pub fn flush(self: *OtlpTraceExporter) void {
        self.flush_requested.store(true, .release);
    }

    /// Export loop running on dedicated thread.
    fn exportLoop(self: *OtlpTraceExporter) void {
        while (self.running.load(.acquire)) {
            // Sleep for a short interval, checking for flush requests
            std.time.sleep(100_000_000); // 100ms

            const now = std.time.nanoTimestamp();
            const should_flush = self.flush_requested.swap(false, .acq_rel) or
                (now - self.last_flush_ns >= self.config.flush_interval_ns);

            if (should_flush) {
                self.doExport();
                self.last_flush_ns = now;
            }
        }

        // Final flush on shutdown
        self.doExport();
    }

    /// Perform the actual export.
    fn doExport(self: *OtlpTraceExporter) void {
        // Swap out buffer under lock
        var spans_to_export: std.ArrayList(OwnedSpan) = undefined;
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.buffer.items.len == 0) return;

            // Move buffer contents to local variable
            var unmanaged = self.buffer.moveToUnmanaged();
            spans_to_export = unmanaged.toManaged(self.allocator);
            self.buffer = std.ArrayList(OwnedSpan).init(self.allocator);
        }
        defer {
            // Free exported spans
            for (spans_to_export.items) |span| {
                freeOwnedSpan(self.allocator, &span);
            }
            spans_to_export.deinit();
        }

        // Format as OTLP JSON
        var json_buffer: [64 * 1024]u8 = undefined; // 64KB buffer
        var fbs = std.io.fixedBufferStream(&json_buffer);
        const writer = fbs.writer();

        self.formatOtlpJson(writer, spans_to_export.items) catch |err| {
            log.warn("failed to format OTLP JSON: {}, dropping {} spans", .{
                err,
                spans_to_export.items.len,
            });
            return;
        };

        const json_data = fbs.getWritten();

        // Send via HTTP POST
        self.sendHttp(json_data) catch |err| {
            log.warn("failed to export spans: {}, dropping {} spans", .{
                err,
                spans_to_export.items.len,
            });
            return;
        };

        log.debug("exported {} spans to {s}", .{ spans_to_export.items.len, self.endpoint });
    }

    /// Format spans as OTLP JSON.
    fn formatOtlpJson(
        self: *OtlpTraceExporter,
        writer: anytype,
        spans: []const OwnedSpan,
    ) !void {
        try writer.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":[");

        // Service name attribute
        try writer.print(
            "{{\"key\":\"service.name\",\"value\":{{\"stringValue\":\"{s}\"}}}}",
            .{self.config.service_name},
        );
        try writer.print(
            ",{{\"key\":\"service.version\",\"value\":{{\"stringValue\":\"{s}\"}}}}",
            .{self.config.service_version},
        );

        try writer.writeAll("]},\"scopeSpans\":[{\"scope\":{\"name\":\"archerdb\"},\"spans\":[");

        for (spans, 0..) |span, i| {
            if (i > 0) try writer.writeByte(',');
            try self.formatSpan(writer, span);
        }

        try writer.writeAll("]}]}]}");
    }

    /// Format a single span as OTLP JSON.
    fn formatSpan(self: *OtlpTraceExporter, writer: anytype, span: OwnedSpan) !void {
        _ = self;

        const trace_id_hex = encodeTraceId(span.trace_id);
        const span_id_hex = encodeSpanId(span.span_id);

        try writer.print(
            "{{\"traceId\":\"{s}\",\"spanId\":\"{s}\"",
            .{ trace_id_hex, span_id_hex },
        );

        // Parent span ID if present
        if (span.parent_span_id) |parent| {
            var parent_hex: [16]u8 = undefined;
            for (parent, 0..) |b, j| {
                parent_hex[j * 2] = hexChar(b >> 4);
                parent_hex[j * 2 + 1] = hexChar(b & 0x0F);
            }
            try writer.print(",\"parentSpanId\":\"{s}\"", .{parent_hex});
        }

        // Name and kind
        try writer.print(",\"name\":\"{s}\",\"kind\":{d}", .{
            span.name,
            @intFromEnum(span.kind),
        });

        // Timestamps (convert ns to string for JSON - OTLP uses fixed64)
        try writer.print(",\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\"", .{
            @as(u128, @intCast(span.start_time_ns)),
            @as(u128, @intCast(span.end_time_ns)),
        });

        // Status
        try writer.print(",\"status\":{{\"code\":{d}", .{@intFromEnum(span.status)});
        if (span.status_message) |msg| {
            try writer.print(",\"message\":\"{s}\"", .{msg});
        }
        try writer.writeByte('}');

        try writer.writeAll(",\"attributes\":[");
        try formatAttributes(writer, span.attributes);
        try writer.writeByte(']');

        if (span.links.len > 0) {
            try writer.writeAll(",\"links\":[");
            try formatLinks(writer, span.links);
            try writer.writeByte(']');
        }

        try writer.writeAll(",\"events\":[");
        try formatEvents(writer, span.events);
        try writer.writeAll("]}");
    }

    /// Send HTTP POST request with JSON payload.
    fn sendHttp(self: *OtlpTraceExporter, body: []const u8) !void {
        // Create socket
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        defer posix.close(sock);

        // Set timeouts
        const timeout_timeval = posix.timeval{
            .sec = @intCast(self.config.timeout_ms / 1000),
            .usec = @intCast((self.config.timeout_ms % 1000) * 1000),
        };
        try posix.setsockopt(
            sock,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout_timeval),
        );
        try posix.setsockopt(
            sock,
            posix.SOL.SOCKET,
            posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout_timeval),
        );

        // Connect
        const address = std.net.Address.parseIp4(self.host, self.port) catch {
            // Try as hostname - for localhost this should work
            return error.InvalidHost;
        };
        try posix.connect(sock, &address.any, address.getOsSockLen());

        // Build HTTP request
        var request_buf: [1024]u8 = undefined;
        const header = std.fmt.bufPrint(&request_buf,
            \\POST {s} HTTP/1.1
            \\Host: {s}:{d}
            \\Content-Type: application/json
            \\Content-Length: {d}
            \\Connection: close
            \\
            \\
        , .{ self.path, self.host, self.port, body.len }) catch return error.HeaderTooLarge;

        // Send header
        _ = try posix.write(sock, header);

        // Send body
        _ = try posix.write(sock, body);

        // Read response (just check status code)
        var response_buf: [512]u8 = undefined;
        const bytes_read = posix.read(sock, &response_buf) catch |err| {
            // Timeout is acceptable for fire-and-forget
            if (err == error.WouldBlock) return;
            return err;
        };

        if (bytes_read < 12) return error.InvalidResponse;

        // Check for 2xx status
        const response = response_buf[0..bytes_read];
        if (response.len >= 12) {
            // HTTP/1.1 2xx
            if (response[9] != '2') {
                log.warn("OTLP collector returned non-2xx: {s}", .{response[0..@min(50, bytes_read)]});
                return error.HttpError;
            }
        }
    }

    const ParsedEndpoint = struct {
        host: []const u8,
        port: u16,
        path: []const u8,
    };

    /// Parse endpoint URL.
    fn parseEndpoint(endpoint: []const u8) !ParsedEndpoint {
        // Skip protocol prefix
        var remaining = endpoint;
        if (std.mem.startsWith(u8, remaining, "http://")) {
            remaining = remaining[7..];
        } else if (std.mem.startsWith(u8, remaining, "https://")) {
            // HTTPS not supported yet
            return error.HttpsNotSupported;
        }

        // Find path separator
        const path_start = std.mem.indexOf(u8, remaining, "/") orelse remaining.len;
        const host_port = remaining[0..path_start];
        const path = if (path_start < remaining.len) remaining[path_start..] else "/v1/traces";

        // Parse host:port
        if (std.mem.indexOf(u8, host_port, ":")) |colon| {
            const host = host_port[0..colon];
            const port_str = host_port[colon + 1 ..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
            return ParsedEndpoint{
                .host = host,
                .port = port,
                .path = path,
            };
        } else {
            return ParsedEndpoint{
                .host = host_port,
                .port = 4318, // Default OTLP HTTP port
                .path = path,
            };
        }
    }
};

/// Convert a 4-bit value to lowercase hex character.
fn hexChar(val: u8) u8 {
    assert(val < 16);
    return if (val < 10) '0' + val else 'a' + val - 10;
}

fn encodeTraceId(trace_id: [16]u8) [32]u8 {
    var trace_id_hex: [32]u8 = undefined;
    for (trace_id, 0..) |b, j| {
        trace_id_hex[j * 2] = hexChar(b >> 4);
        trace_id_hex[j * 2 + 1] = hexChar(b & 0x0F);
    }
    return trace_id_hex;
}

fn encodeSpanId(span_id: [8]u8) [16]u8 {
    var span_id_hex: [16]u8 = undefined;
    for (span_id, 0..) |b, j| {
        span_id_hex[j * 2] = hexChar(b >> 4);
        span_id_hex[j * 2 + 1] = hexChar(b & 0x0F);
    }
    return span_id_hex;
}

fn formatAttributes(writer: anytype, attributes: []const Attribute) !void {
    for (attributes, 0..) |attr, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"key\":\"{s}\",\"value\":{{", .{attr.key});
        switch (attr.value) {
            .string => |value| try writer.print("\"stringValue\":\"{s}\"", .{value}),
            .int => |value| try writer.print("\"intValue\":\"{d}\"", .{value}),
            .float => |value| try writer.print("\"doubleValue\":{d}", .{value}),
            .bool => |value| try writer.print("\"boolValue\":{s}", .{if (value) "true" else "false"}),
        }
        try writer.writeAll("}}");
    }
}

fn formatLinks(writer: anytype, links: []const SpanLink) !void {
    for (links, 0..) |link, i| {
        if (i > 0) try writer.writeByte(',');
        const trace_id_hex = encodeTraceId(link.trace_id);
        const span_id_hex = encodeSpanId(link.span_id);
        try writer.print("{{\"traceId\":\"{s}\",\"spanId\":\"{s}\"", .{ trace_id_hex, span_id_hex });
        if (link.attributes.len > 0) {
            try writer.writeAll(",\"attributes\":[");
            try formatAttributes(writer, link.attributes);
            try writer.writeByte(']');
        }
        try writer.writeByte('}');
    }
}

fn formatEvents(writer: anytype, events: []const SpanEvent) !void {
    for (events, 0..) |event, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            "{{\"name\":\"{s}\",\"timeUnixNano\":\"{d}\"",
            .{ event.name, @as(u128, @intCast(event.time_ns)) },
        );
        if (event.attributes.len > 0) {
            try writer.writeAll(",\"attributes\":[");
            try formatAttributes(writer, event.attributes);
            try writer.writeByte(']');
        }
        try writer.writeByte('}');
    }
}

fn copySpan(allocator: std.mem.Allocator, span: Span) !OwnedSpan {
    const name_copy = try allocator.dupe(u8, span.name);
    errdefer allocator.free(name_copy);

    const status_msg_copy: ?[]const u8 = if (span.status_message) |msg|
        try allocator.dupe(u8, msg)
    else
        null;
    errdefer if (status_msg_copy) |msg| allocator.free(msg);

    const attributes_copy = try copyAttributes(allocator, span.attributes);
    errdefer freeAttributes(allocator, attributes_copy);

    const links_copy = try copyLinks(allocator, span.links);
    errdefer freeLinks(allocator, links_copy);

    const events_copy = try copyEvents(allocator, span.events);
    errdefer freeEvents(allocator, events_copy);

    return OwnedSpan{
        .trace_id = span.trace_id,
        .span_id = span.span_id,
        .parent_span_id = span.parent_span_id,
        .name = name_copy,
        .kind = span.kind,
        .start_time_ns = span.start_time_ns,
        .end_time_ns = span.end_time_ns,
        .status = span.status,
        .status_message = status_msg_copy,
        .attributes = attributes_copy,
        .links = links_copy,
        .events = events_copy,
    };
}

fn copyAttributes(allocator: std.mem.Allocator, attributes: []const Attribute) ![]Attribute {
    if (attributes.len == 0) return &[_]Attribute{};
    var owned = try allocator.alloc(Attribute, attributes.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            allocator.free(owned[j].key);
            if (owned[j].value == .string) allocator.free(owned[j].value.string);
        }
        allocator.free(owned);
    }

    for (attributes, 0..) |attr, idx| {
        const key_copy = try allocator.dupe(u8, attr.key);
        errdefer allocator.free(key_copy);

        const value_copy = switch (attr.value) {
            .string => |value| blk: {
                const string_copy = try allocator.dupe(u8, value);
                break :blk AttributeValue{ .string = string_copy };
            },
            .int => |value| AttributeValue{ .int = value },
            .float => |value| AttributeValue{ .float = value },
            .bool => |value| AttributeValue{ .bool = value },
        };
        errdefer if (value_copy == .string) allocator.free(value_copy.string);

        owned[idx] = .{
            .key = key_copy,
            .value = value_copy,
        };
        i = idx + 1;
    }

    return owned;
}

fn copyLinks(allocator: std.mem.Allocator, links: []const SpanLink) ![]SpanLink {
    if (links.len == 0) return &[_]SpanLink{};
    var owned = try allocator.alloc(SpanLink, links.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            freeAttributes(allocator, owned[j].attributes);
        }
        allocator.free(owned);
    }

    for (links, 0..) |link, idx| {
        const attrs_copy = try copyAttributes(allocator, link.attributes);
        owned[idx] = .{
            .trace_id = link.trace_id,
            .span_id = link.span_id,
            .attributes = attrs_copy,
        };
        i = idx + 1;
    }

    return owned;
}

fn copyEvents(allocator: std.mem.Allocator, events: []const SpanEvent) ![]SpanEvent {
    if (events.len == 0) return &[_]SpanEvent{};
    var owned = try allocator.alloc(SpanEvent, events.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            allocator.free(owned[j].name);
            freeAttributes(allocator, owned[j].attributes);
        }
        allocator.free(owned);
    }

    for (events, 0..) |event, idx| {
        const name_copy = try allocator.dupe(u8, event.name);
        errdefer allocator.free(name_copy);

        const attrs_copy = try copyAttributes(allocator, event.attributes);
        errdefer freeAttributes(allocator, attrs_copy);

        owned[idx] = .{
            .name = name_copy,
            .time_ns = event.time_ns,
            .attributes = attrs_copy,
        };
        i = idx + 1;
    }

    return owned;
}

fn freeAttributes(allocator: std.mem.Allocator, attributes: []const Attribute) void {
    if (attributes.len == 0) return;
    for (attributes) |attr| {
        allocator.free(attr.key);
        if (attr.value == .string) allocator.free(attr.value.string);
    }
    allocator.free(attributes);
}

fn freeLinks(allocator: std.mem.Allocator, links: []const SpanLink) void {
    if (links.len == 0) return;
    for (links) |link| {
        freeAttributes(allocator, link.attributes);
    }
    allocator.free(links);
}

fn freeEvents(allocator: std.mem.Allocator, events: []const SpanEvent) void {
    if (events.len == 0) return;
    for (events) |event| {
        allocator.free(event.name);
        freeAttributes(allocator, event.attributes);
    }
    allocator.free(events);
}

fn freeOwnedSpan(allocator: std.mem.Allocator, span: *const OwnedSpan) void {
    allocator.free(span.name);
    if (span.status_message) |msg| {
        allocator.free(msg);
    }
    freeAttributes(allocator, span.attributes);
    freeLinks(allocator, span.links);
    freeEvents(allocator, span.events);
}

// =============================================================================
// Builder helpers for creating spans with attributes
// =============================================================================

/// Helper to create a span with geo-specific attributes.
pub fn geoSpan(
    ctx: *const correlation.CorrelationContext,
    name: []const u8,
    start_ns: i128,
    end_ns: i128,
) Span {
    return Span{
        .trace_id = ctx.trace_id,
        .span_id = ctx.span_id,
        .parent_span_id = null,
        .name = name,
        .kind = .server,
        .start_time_ns = start_ns,
        .end_time_ns = end_ns,
        .attributes = &[_]Attribute{},
        .links = &[_]SpanLink{},
        .events = &[_]SpanEvent{},
        .status = .ok,
        .status_message = null,
    };
}

/// Helper to create a span with attributes and links.
pub fn spanWithAttributes(
    ctx: *const correlation.CorrelationContext,
    name: []const u8,
    kind: SpanKind,
    start_ns: i128,
    end_ns: i128,
    attributes: []const Attribute,
    links: []const SpanLink,
) Span {
    return Span{
        .trace_id = ctx.trace_id,
        .span_id = ctx.span_id,
        .parent_span_id = null,
        .name = name,
        .kind = kind,
        .start_time_ns = start_ns,
        .end_time_ns = end_ns,
        .attributes = attributes,
        .links = links,
        .events = &[_]SpanEvent{},
        .status = .ok,
        .status_message = null,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "parseEndpoint: full URL" {
    const result = OtlpTraceExporter.parseEndpoint("http://localhost:4318/v1/traces") catch unreachable;
    try std.testing.expectEqualStrings("localhost", result.host);
    try std.testing.expectEqual(@as(u16, 4318), result.port);
    try std.testing.expectEqualStrings("/v1/traces", result.path);
}

test "parseEndpoint: without port" {
    const result = OtlpTraceExporter.parseEndpoint("http://collector.example.com/v1/traces") catch unreachable;
    try std.testing.expectEqualStrings("collector.example.com", result.host);
    try std.testing.expectEqual(@as(u16, 4318), result.port);
    try std.testing.expectEqualStrings("/v1/traces", result.path);
}

test "parseEndpoint: without path" {
    const result = OtlpTraceExporter.parseEndpoint("http://localhost:4318") catch unreachable;
    try std.testing.expectEqualStrings("localhost", result.host);
    try std.testing.expectEqual(@as(u16, 4318), result.port);
    try std.testing.expectEqualStrings("/v1/traces", result.path);
}

test "parseEndpoint: https fails" {
    try std.testing.expectError(
        error.HttpsNotSupported,
        OtlpTraceExporter.parseEndpoint("https://localhost:4318/v1/traces"),
    );
}

test "hexChar" {
    try std.testing.expectEqual(@as(u8, '0'), hexChar(0));
    try std.testing.expectEqual(@as(u8, '9'), hexChar(9));
    try std.testing.expectEqual(@as(u8, 'a'), hexChar(10));
    try std.testing.expectEqual(@as(u8, 'f'), hexChar(15));
}

test "Span initialization" {
    const span = Span{
        .trace_id = [_]u8{0x01} ** 16,
        .span_id = [_]u8{0x02} ** 8,
        .parent_span_id = null,
        .name = "test",
        .kind = .server,
        .start_time_ns = 1000,
        .end_time_ns = 2000,
        .attributes = &[_]Attribute{},
        .links = &[_]SpanLink{},
        .events = &[_]SpanEvent{},
        .status = .ok,
        .status_message = null,
    };

    try std.testing.expectEqualStrings("test", span.name);
    try std.testing.expectEqual(SpanKind.server, span.kind);
    try std.testing.expectEqual(SpanStatus.ok, span.status);
}

test "geoSpan helper" {
    const ctx = correlation.CorrelationContext.newRoot(0);
    const start_ns: i128 = 1000000000;
    const end_ns: i128 = 2000000000;

    const span = geoSpan(&ctx, "geo.radius_query", start_ns, end_ns);

    try std.testing.expectEqualSlices(u8, &ctx.trace_id, &span.trace_id);
    try std.testing.expectEqualSlices(u8, &ctx.span_id, &span.span_id);
    try std.testing.expectEqualStrings("geo.radius_query", span.name);
    try std.testing.expectEqual(SpanKind.server, span.kind);
}

test "formatSpan includes attributes and links" {
    const allocator = std.testing.allocator;
    var exporter = OtlpTraceExporter{
        .endpoint = "http://localhost:4318/v1/traces",
        .host = "localhost",
        .port = 4318,
        .path = "/v1/traces",
        .buffer = std.ArrayList(OwnedSpan).init(allocator),
        .allocator = allocator,
        .config = .{},
        .last_flush_ns = 0,
        .mutex = .{},
        .export_thread = null,
        .running = std.atomic.Value(bool).init(false),
        .flush_requested = std.atomic.Value(bool).init(false),
    };
    defer exporter.buffer.deinit();

    const attributes = [_]Attribute{
        .{ .key = "shard_id", .value = .{ .int = 3 } },
        .{ .key = "result_count", .value = .{ .int = 42 } },
    };
    const link_attributes = [_]Attribute{
        .{ .key = "fanout", .value = .{ .bool = true } },
    };
    const event_attributes = [_]Attribute{
        .{ .key = "cache.hit", .value = .{ .bool = false } },
    };
    const links = [_]SpanLink{
        .{
            .trace_id = [_]u8{0x10} ** 16,
            .span_id = [_]u8{0x20} ** 8,
            .attributes = &link_attributes,
        },
    };
    const events = [_]SpanEvent{
        .{
            .name = "cache.miss",
            .time_ns = 1500,
            .attributes = &event_attributes,
        },
    };

    const span = Span{
        .trace_id = [_]u8{0x01} ** 16,
        .span_id = [_]u8{0x02} ** 8,
        .parent_span_id = null,
        .name = "fanout",
        .kind = .server,
        .start_time_ns = 1000,
        .end_time_ns = 2000,
        .attributes = &attributes,
        .links = &links,
        .events = &events,
        .status = .ok,
        .status_message = null,
    };

    var owned_span = try copySpan(allocator, span);
    defer freeOwnedSpan(allocator, &owned_span);

    var buffer: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try exporter.formatOtlpJson(fbs.writer(), &[_]OwnedSpan{owned_span});
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "\"shard_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"result_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"links\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"fanout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"cache.miss\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"cache.hit\"") != null);
}
