// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! S3 Provider Detection and Adaptation
//!
//! Supports multiple S3-compatible storage providers with provider-specific
//! URL formatting and configuration:
//! - AWS S3 (virtual-hosted and path style)
//! - MinIO (path style)
//! - Cloudflare R2 (account-based)
//! - Google Cloud Storage (HMAC interoperability)
//! - Backblaze B2 (S3 compatible API)

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.s3_providers);

/// Supported S3-compatible storage providers
pub const Provider = enum {
    /// Amazon Web Services S3
    aws,
    /// MinIO self-hosted object storage
    minio,
    /// Cloudflare R2
    r2,
    /// Google Cloud Storage (S3-compatible HMAC)
    gcs,
    /// Backblaze B2 (S3-compatible)
    backblaze,
    /// Generic S3-compatible provider (path style)
    generic,

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .aws => "AWS S3",
            .minio => "MinIO",
            .r2 => "Cloudflare R2",
            .gcs => "Google Cloud Storage",
            .backblaze => "Backblaze B2",
            .generic => "Generic S3",
        };
    }

    /// Whether this provider supports virtual-hosted style URLs
    pub fn supportsVirtualHosted(self: Provider) bool {
        return switch (self) {
            .aws => true,
            .r2 => true,
            .gcs => true,
            .backblaze => true,
            .minio => false, // MinIO supports it but path style is more reliable
            .generic => false,
        };
    }
};

/// URL style for S3 requests
pub const UrlStyle = enum {
    /// Path style: https://endpoint/bucket/key
    path,
    /// Virtual-hosted style: https://bucket.endpoint/key
    virtual_hosted,
};

/// Detect the S3 provider from an endpoint URL
pub fn detectProvider(endpoint: []const u8) Provider {
    // Normalize to lowercase for matching
    var lower_buf: [256]u8 = undefined;
    const endpoint_lower = toLowerBuf(endpoint, &lower_buf);

    // AWS S3: s3.amazonaws.com or s3.{region}.amazonaws.com
    if (std.mem.indexOf(u8, endpoint_lower, "amazonaws.com") != null) {
        return .aws;
    }

    // Cloudflare R2: {account_id}.r2.cloudflarestorage.com
    if (std.mem.indexOf(u8, endpoint_lower, "r2.cloudflarestorage.com") != null) {
        return .r2;
    }

    // Google Cloud Storage: storage.googleapis.com
    if (std.mem.indexOf(u8, endpoint_lower, "storage.googleapis.com") != null) {
        return .gcs;
    }

    // Backblaze B2: s3.{region}.backblazeb2.com
    if (std.mem.indexOf(u8, endpoint_lower, "backblazeb2.com") != null) {
        return .backblaze;
    }

    // Default to generic (MinIO-compatible)
    return .generic;
}

/// Get the appropriate region for a provider
/// Some providers use fixed regions (R2 = "auto", GCS = "auto")
pub fn getRegion(provider: Provider, configured_region: []const u8) []const u8 {
    return switch (provider) {
        .r2 => "auto", // R2 always uses "auto" for signing
        .gcs => if (configured_region.len == 0) "auto" else configured_region,
        else => if (configured_region.len == 0) "us-east-1" else configured_region,
    };
}

/// Get the S3 service name for signing
/// Most providers use "s3", but some may differ
pub fn getServiceName(provider: Provider) []const u8 {
    _ = provider;
    return "s3"; // All S3-compatible providers use "s3" for signing
}

/// Build the endpoint URL for an S3 request
/// Handles provider-specific URL formatting (path style vs virtual-hosted)
pub fn buildRequestUrl(
    allocator: Allocator,
    _: Provider, // Provider type, currently unused
    endpoint: []const u8,
    bucket: []const u8,
    key: []const u8,
    url_style: UrlStyle,
) ![]const u8 {
    // Determine the scheme
    const has_scheme = std.mem.startsWith(u8, endpoint, "http://") or
        std.mem.startsWith(u8, endpoint, "https://");

    const scheme = if (has_scheme) "" else "https://";

    // Clean up endpoint (remove trailing slash)
    var clean_endpoint = endpoint;
    if (!has_scheme) {
        clean_endpoint = endpoint;
    }
    while (clean_endpoint.len > 0 and clean_endpoint[clean_endpoint.len - 1] == '/') {
        clean_endpoint = clean_endpoint[0 .. clean_endpoint.len - 1];
    }

    // Clean up key (remove leading slash)
    var clean_key = key;
    while (clean_key.len > 0 and clean_key[0] == '/') {
        clean_key = clean_key[1..];
    }

    // Build URL based on style
    switch (url_style) {
        .path => {
            // Path style: https://endpoint/bucket/key
            if (clean_key.len > 0) {
                return std.fmt.allocPrint(allocator, "{s}{s}/{s}/{s}", .{
                    scheme,
                    clean_endpoint,
                    bucket,
                    clean_key,
                });
            } else {
                return std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{
                    scheme,
                    clean_endpoint,
                    bucket,
                });
            }
        },
        .virtual_hosted => {
            // Virtual-hosted style: https://bucket.endpoint/key
            // Need to insert bucket before the domain

            // Find the host part (after scheme, before first /)
            var host_start: usize = 0;
            const host_end: usize = clean_endpoint.len;

            if (has_scheme) {
                if (std.mem.indexOf(u8, clean_endpoint, "://")) |idx| {
                    host_start = idx + 3;
                }
            }

            const host = clean_endpoint[host_start..host_end];

            if (has_scheme) {
                const scheme_part = clean_endpoint[0..host_start];
                if (clean_key.len > 0) {
                    return std.fmt.allocPrint(allocator, "{s}{s}.{s}/{s}", .{
                        scheme_part,
                        bucket,
                        host,
                        clean_key,
                    });
                } else {
                    return std.fmt.allocPrint(allocator, "{s}{s}.{s}", .{
                        scheme_part,
                        bucket,
                        host,
                    });
                }
            } else {
                if (clean_key.len > 0) {
                    return std.fmt.allocPrint(allocator, "{s}{s}.{s}/{s}", .{
                        scheme,
                        bucket,
                        host,
                        clean_key,
                    });
                } else {
                    return std.fmt.allocPrint(allocator, "{s}{s}.{s}", .{
                        scheme,
                        bucket,
                        host,
                    });
                }
            }
        },
    }
}

/// Get the recommended URL style for a provider
pub fn getRecommendedUrlStyle(provider: Provider) UrlStyle {
    return switch (provider) {
        .aws => .virtual_hosted, // AWS recommends virtual-hosted
        .r2 => .path, // R2 works better with path style
        .gcs => .path, // GCS HMAC works with path style
        .backblaze => .path, // Backblaze works with path style
        .minio => .path, // MinIO path style is more reliable
        .generic => .path, // Path style is most compatible
    };
}

/// Get the host header value for signing
/// This must match exactly what's used in the request
pub fn getHostHeader(
    allocator: Allocator,
    provider: Provider,
    endpoint: []const u8,
    bucket: []const u8,
    url_style: UrlStyle,
) ![]const u8 {
    // Strip scheme if present
    var host = endpoint;
    if (std.mem.indexOf(u8, endpoint, "://")) |idx| {
        host = endpoint[idx + 3 ..];
    }

    // Remove port for host header if present
    if (std.mem.indexOf(u8, host, "/")) |idx| {
        host = host[0..idx];
    }

    if (url_style == .virtual_hosted and provider.supportsVirtualHosted()) {
        return std.fmt.allocPrint(allocator, "{s}.{s}", .{ bucket, host });
    } else {
        return allocator.dupe(u8, host);
    }
}

/// Get the URI path for signing
pub fn getSigningUri(
    allocator: Allocator,
    bucket: []const u8,
    key: []const u8,
    url_style: UrlStyle,
) ![]const u8 {
    // Clean up key (remove leading slash)
    var clean_key = key;
    while (clean_key.len > 0 and clean_key[0] == '/') {
        clean_key = clean_key[1..];
    }

    switch (url_style) {
        .path => {
            // Path style: /bucket/key
            if (clean_key.len > 0) {
                return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ bucket, clean_key });
            } else {
                return std.fmt.allocPrint(allocator, "/{s}", .{bucket});
            }
        },
        .virtual_hosted => {
            // Virtual-hosted: /key
            if (clean_key.len > 0) {
                return std.fmt.allocPrint(allocator, "/{s}", .{clean_key});
            } else {
                return allocator.dupe(u8, "/");
            }
        },
    }
}

/// Extract AWS region from endpoint URL (for AWS S3)
pub fn extractAwsRegion(endpoint: []const u8) ?[]const u8 {
    // Pattern: s3.{region}.amazonaws.com or s3-{region}.amazonaws.com
    // Also: {bucket}.s3.{region}.amazonaws.com

    var lower_buf: [256]u8 = undefined;
    const endpoint_lower = toLowerBuf(endpoint, &lower_buf);

    // Find "amazonaws.com"
    const suffix = ".amazonaws.com";
    const suffix_idx = std.mem.indexOf(u8, endpoint_lower, suffix) orelse return null;

    // Work backwards to find region
    // s3.us-east-1.amazonaws.com
    // s3-us-west-2.amazonaws.com

    const end_idx = suffix_idx;
    var start_idx: usize = 0;

    // Find the region by looking for "s3." or "s3-"
    if (std.mem.lastIndexOf(u8, endpoint_lower[0..end_idx], "s3.")) |idx| {
        start_idx = idx + 3;
    } else if (std.mem.lastIndexOf(u8, endpoint_lower[0..end_idx], "s3-")) |idx| {
        start_idx = idx + 3;
    } else {
        return null;
    }

    if (start_idx >= end_idx) return null;

    // Return the region from original endpoint (preserve case)
    return endpoint[start_idx..end_idx];
}

/// Extract Backblaze region from endpoint URL
pub fn extractBackblazeRegion(endpoint: []const u8) ?[]const u8 {
    // Pattern: s3.{region}.backblazeb2.com
    var lower_buf: [256]u8 = undefined;
    const endpoint_lower = toLowerBuf(endpoint, &lower_buf);

    const suffix = ".backblazeb2.com";
    const suffix_idx = std.mem.indexOf(u8, endpoint_lower, suffix) orelse return null;

    // Find "s3."
    const prefix = "s3.";
    const prefix_idx = std.mem.indexOf(u8, endpoint_lower, prefix) orelse return null;

    const start_idx = prefix_idx + prefix.len;
    const end_idx = suffix_idx;

    if (start_idx >= end_idx) return null;

    return endpoint[start_idx..end_idx];
}

/// Helper to convert string to lowercase in a buffer
fn toLowerBuf(s: []const u8, buf: *[256]u8) []const u8 {
    const len = @min(s.len, buf.len);
    for (s[0..len], 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..len];
}

// ============================================================================
// Tests
// ============================================================================

test "providers detectProvider AWS" {
    try std.testing.expectEqual(Provider.aws, detectProvider("s3.amazonaws.com"));
    try std.testing.expectEqual(Provider.aws, detectProvider("s3.us-east-1.amazonaws.com"));
    try std.testing.expectEqual(Provider.aws, detectProvider("https://s3.eu-west-1.amazonaws.com"));
    try std.testing.expectEqual(Provider.aws, detectProvider("bucket.s3.us-west-2.amazonaws.com"));
}

test "providers detectProvider R2" {
    try std.testing.expectEqual(Provider.r2, detectProvider("abc123.r2.cloudflarestorage.com"));
    try std.testing.expectEqual(Provider.r2, detectProvider("https://abc123.r2.cloudflarestorage.com"));
}

test "providers detectProvider GCS" {
    try std.testing.expectEqual(Provider.gcs, detectProvider("storage.googleapis.com"));
    try std.testing.expectEqual(Provider.gcs, detectProvider("https://storage.googleapis.com"));
}

test "providers detectProvider Backblaze" {
    try std.testing.expectEqual(Provider.backblaze, detectProvider("s3.us-west-001.backblazeb2.com"));
    try std.testing.expectEqual(Provider.backblaze, detectProvider("https://s3.eu-central-003.backblazeb2.com"));
}

test "providers detectProvider MinIO/generic" {
    try std.testing.expectEqual(Provider.generic, detectProvider("localhost:9000"));
    try std.testing.expectEqual(Provider.generic, detectProvider("http://minio.local:9000"));
    try std.testing.expectEqual(Provider.generic, detectProvider("192.168.1.100:9000"));
}

test "providers getRegion" {
    try std.testing.expectEqualStrings("auto", getRegion(.r2, "us-east-1"));
    try std.testing.expectEqualStrings("us-west-2", getRegion(.aws, "us-west-2"));
    try std.testing.expectEqualStrings("us-east-1", getRegion(.minio, ""));
}

test "providers buildRequestUrl path style" {
    const allocator = std.testing.allocator;

    const url = try buildRequestUrl(
        allocator,
        .minio,
        "localhost:9000",
        "mybucket",
        "path/to/object.txt",
        .path,
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://localhost:9000/mybucket/path/to/object.txt", url);
}

test "providers buildRequestUrl path style with scheme" {
    const allocator = std.testing.allocator;

    const url = try buildRequestUrl(
        allocator,
        .minio,
        "http://localhost:9000",
        "mybucket",
        "object.txt",
        .path,
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings("http://localhost:9000/mybucket/object.txt", url);
}

test "providers buildRequestUrl virtual hosted" {
    const allocator = std.testing.allocator;

    const url = try buildRequestUrl(
        allocator,
        .aws,
        "s3.us-east-1.amazonaws.com",
        "mybucket",
        "object.txt",
        .virtual_hosted,
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://mybucket.s3.us-east-1.amazonaws.com/object.txt", url);
}

test "providers buildRequestUrl handles leading slash in key" {
    const allocator = std.testing.allocator;

    const url = try buildRequestUrl(
        allocator,
        .minio,
        "localhost:9000",
        "bucket",
        "/path/key.txt",
        .path,
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://localhost:9000/bucket/path/key.txt", url);
}

test "providers buildRequestUrl bucket only" {
    const allocator = std.testing.allocator;

    const url = try buildRequestUrl(
        allocator,
        .minio,
        "localhost:9000",
        "mybucket",
        "",
        .path,
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://localhost:9000/mybucket", url);
}

test "providers getHostHeader path style" {
    const allocator = std.testing.allocator;

    const host = try getHostHeader(
        allocator,
        .minio,
        "http://localhost:9000",
        "mybucket",
        .path,
    );
    defer allocator.free(host);

    try std.testing.expectEqualStrings("localhost:9000", host);
}

test "providers getHostHeader virtual hosted" {
    const allocator = std.testing.allocator;

    const host = try getHostHeader(
        allocator,
        .aws,
        "s3.us-east-1.amazonaws.com",
        "mybucket",
        .virtual_hosted,
    );
    defer allocator.free(host);

    try std.testing.expectEqualStrings("mybucket.s3.us-east-1.amazonaws.com", host);
}

test "providers getSigningUri path style" {
    const allocator = std.testing.allocator;

    const uri = try getSigningUri(allocator, "mybucket", "path/to/object.txt", .path);
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("/mybucket/path/to/object.txt", uri);
}

test "providers getSigningUri virtual hosted" {
    const allocator = std.testing.allocator;

    const uri = try getSigningUri(allocator, "mybucket", "path/to/object.txt", .virtual_hosted);
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("/path/to/object.txt", uri);
}

test "providers extractAwsRegion" {
    try std.testing.expectEqualStrings("us-east-1", extractAwsRegion("s3.us-east-1.amazonaws.com").?);
    try std.testing.expectEqualStrings("eu-west-1", extractAwsRegion("https://s3.eu-west-1.amazonaws.com").?);
    try std.testing.expect(extractAwsRegion("localhost:9000") == null);
}

test "providers extractBackblazeRegion" {
    try std.testing.expectEqualStrings("us-west-001", extractBackblazeRegion("s3.us-west-001.backblazeb2.com").?);
    try std.testing.expectEqualStrings("eu-central-003", extractBackblazeRegion("https://s3.eu-central-003.backblazeb2.com").?);
    try std.testing.expect(extractBackblazeRegion("localhost:9000") == null);
}

test "providers supportsVirtualHosted" {
    try std.testing.expect(Provider.aws.supportsVirtualHosted());
    try std.testing.expect(!Provider.minio.supportsVirtualHosted());
    try std.testing.expect(!Provider.generic.supportsVirtualHosted());
}

test "providers getRecommendedUrlStyle" {
    try std.testing.expectEqual(UrlStyle.virtual_hosted, getRecommendedUrlStyle(.aws));
    try std.testing.expectEqual(UrlStyle.path, getRecommendedUrlStyle(.minio));
    try std.testing.expectEqual(UrlStyle.path, getRecommendedUrlStyle(.generic));
}
