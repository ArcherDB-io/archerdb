// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! ArcherDB Zig SDK - HTTP client wrapper
//!
//! This module provides an HTTP client wrapper around std.http.Client
//! for making REST API calls to ArcherDB servers.

const std = @import("std");
const errors = @import("errors.zig");

/// HttpClient wraps std.http.Client with ArcherDB-specific conveniences.
pub const HttpClient = struct {
    inner: std.http.Client,
    allocator: std.mem.Allocator,

    /// Initialize a new HttpClient.
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return HttpClient{
            .inner = std.http.Client{ .allocator = allocator },
            .allocator = allocator,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *HttpClient) void {
        self.inner.deinit();
    }

    /// Perform an HTTP POST request with JSON body.
    ///
    /// Returns the response body as an allocator-owned slice.
    /// Caller is responsible for freeing the returned slice.
    pub fn doPost(
        self: *HttpClient,
        allocator: std.mem.Allocator,
        url: []const u8,
        body: []const u8,
    ) errors.ClientError![]u8 {
        return self.doRequest(allocator, url, .POST, body);
    }

    /// Perform an HTTP GET request.
    ///
    /// Returns the response body as an allocator-owned slice.
    /// Caller is responsible for freeing the returned slice.
    pub fn doGet(
        self: *HttpClient,
        allocator: std.mem.Allocator,
        url: []const u8,
    ) errors.ClientError![]u8 {
        return self.doRequest(allocator, url, .GET, null);
    }

    /// Perform an HTTP DELETE request with optional JSON body.
    ///
    /// Returns the response body as an allocator-owned slice.
    /// Caller is responsible for freeing the returned slice.
    pub fn doDelete(
        self: *HttpClient,
        allocator: std.mem.Allocator,
        url: []const u8,
        body: ?[]const u8,
    ) errors.ClientError![]u8 {
        return self.doRequest(allocator, url, .DELETE, body);
    }

    /// Internal request handler.
    fn doRequest(
        self: *HttpClient,
        allocator: std.mem.Allocator,
        url: []const u8,
        method: std.http.Method,
        body: ?[]const u8,
    ) errors.ClientError![]u8 {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        // Buffer for server headers
        var server_header_buffer: [16384]u8 = undefined;

        var request = self.inner.open(method, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
        }) catch return error.ConnectionFailed;
        defer request.deinit();

        // Send request
        request.send() catch return error.ConnectionFailed;

        // Write body if present
        if (body) |b| {
            request.writeAll(b) catch return error.ConnectionFailed;
        }

        // Finish sending
        request.finish() catch return error.ConnectionFailed;

        // Wait for response
        request.wait() catch return error.OperationTimeout;

        // Check status code
        const status = request.response.status;
        if (status != .ok and status != .created and status != .no_content) {
            // Read error response body if available
            const error_body = request.reader().readAllAlloc(allocator, 1024 * 1024) catch {
                return error.HttpError;
            };
            defer allocator.free(error_body);

            // Map HTTP status to error
            return switch (@intFromEnum(status)) {
                400 => error.InvalidCoordinates,
                401, 403 => error.ClusterUnavailable,
                404 => error.InvalidEntityId,
                408 => error.OperationTimeout,
                413 => error.BatchTooLarge,
                500, 502, 503, 504 => error.ClusterUnavailable,
                else => error.HttpError,
            };
        }

        // Read response body
        const response_body = request.reader().readAllAlloc(allocator, 10 * 1024 * 1024) catch {
            return error.InvalidResponse;
        };

        return response_body;
    }
};

// ============================================================================
// URL Building Helpers
// ============================================================================

/// Build a full URL from base URL and path.
pub fn buildUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) errors.ClientError![]u8 {
    // Strip trailing slash from base if present
    const trimmed_base = if (base_url.len > 0 and base_url[base_url.len - 1] == '/')
        base_url[0 .. base_url.len - 1]
    else
        base_url;

    // Ensure path starts with /
    if (path.len > 0 and path[0] != '/') {
        var result = allocator.alloc(u8, trimmed_base.len + 1 + path.len) catch return error.OutOfMemory;
        @memcpy(result[0..trimmed_base.len], trimmed_base);
        result[trimmed_base.len] = '/';
        @memcpy(result[trimmed_base.len + 1 ..], path);
        return result;
    }

    var result = allocator.alloc(u8, trimmed_base.len + path.len) catch return error.OutOfMemory;
    @memcpy(result[0..trimmed_base.len], trimmed_base);
    @memcpy(result[trimmed_base.len..], path);
    return result;
}

/// Build a URL with a single path parameter.
pub fn buildUrlWithParam(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    path_template: []const u8,
    param: u128,
) errors.ClientError![]u8 {
    // First build the parameter string
    var param_buf: [40]u8 = undefined;
    const param_str = std.fmt.bufPrint(&param_buf, "{d}", .{param}) catch return error.OutOfMemory;

    // Find {} in template and replace
    const placeholder_start = std.mem.indexOf(u8, path_template, "{}") orelse {
        return buildUrl(allocator, base_url, path_template);
    };

    const before = path_template[0..placeholder_start];
    const after = path_template[placeholder_start + 2 ..];

    // Strip trailing slash from base
    const trimmed_base = if (base_url.len > 0 and base_url[base_url.len - 1] == '/')
        base_url[0 .. base_url.len - 1]
    else
        base_url;

    const total_len = trimmed_base.len + before.len + param_str.len + after.len;
    const result = allocator.alloc(u8, total_len) catch return error.OutOfMemory;

    var offset: usize = 0;
    @memcpy(result[offset .. offset + trimmed_base.len], trimmed_base);
    offset += trimmed_base.len;
    @memcpy(result[offset .. offset + before.len], before);
    offset += before.len;
    @memcpy(result[offset .. offset + param_str.len], param_str);
    offset += param_str.len;
    @memcpy(result[offset .. offset + after.len], after);

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "HttpClient: init and deinit" {
    var client = HttpClient.init(std.testing.allocator);
    defer client.deinit();
    // Just ensure it doesn't crash
    try std.testing.expect(true);
}

test "buildUrl: basic" {
    const url = try buildUrl(std.testing.allocator, "http://localhost:3001", "/events");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:3001/events", url);
}

test "buildUrl: base with trailing slash" {
    const url = try buildUrl(std.testing.allocator, "http://localhost:3001/", "/events");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:3001/events", url);
}

test "buildUrlWithParam: entity lookup" {
    const url = try buildUrlWithParam(std.testing.allocator, "http://localhost:3001", "/entity/{}", 12345);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:3001/entity/12345", url);
}
