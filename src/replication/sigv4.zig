// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! AWS Signature Version 4 (SigV4) Signing Implementation
//!
//! Implements request signing for AWS S3 and S3-compatible storage providers.
//! This module provides the cryptographic signing required for authenticated
//! requests to S3, MinIO, Cloudflare R2, GCS (HMAC), and Backblaze B2.
//!
//! Reference: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html

const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const log = std.log.scoped(.sigv4);

/// AWS credentials for signing requests
pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
};

/// HTTP method for the request
pub const Method = enum {
    GET,
    PUT,
    POST,
    DELETE,
    HEAD,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .PUT => "PUT",
            .POST => "POST",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
        };
    }
};

/// Header key-value pair for signing
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Request information needed for signing
pub const Request = struct {
    method: Method,
    uri: []const u8,
    query: []const u8, // Already URL-encoded query string (without leading ?)
    headers: []const Header,
    payload: []const u8,

    /// Get datetime in YYYYMMDD'T'HHMMSS'Z' format from headers
    pub fn getAmzDate(self: Request) ?[]const u8 {
        for (self.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-amz-date")) {
                return header.value;
            }
        }
        return null;
    }

    /// Get date in YYYYMMDD format from x-amz-date header
    pub fn getDate(self: Request) ?[]const u8 {
        const amz_date = self.getAmzDate() orelse return null;
        if (amz_date.len >= 8) {
            return amz_date[0..8];
        }
        return null;
    }
};

/// Derive the SigV4 signing key
/// DateKey = HMAC("AWS4" + SecretAccessKey, Date)
/// DateRegionKey = HMAC(DateKey, Region)
/// DateRegionServiceKey = HMAC(DateRegionKey, Service)
/// SigningKey = HMAC(DateRegionServiceKey, "aws4_request")
pub fn deriveSigningKey(
    secret_key: []const u8,
    date: []const u8, // YYYYMMDD format
    region: []const u8,
    service: []const u8,
) [32]u8 {
    // DateKey = HMAC("AWS4" + SecretAccessKey, Date)
    var prefixed_key_buf: [256]u8 = undefined;
    if (4 + secret_key.len > prefixed_key_buf.len) {
        // Secret key too long - this should never happen with valid AWS keys
        @panic("Secret key too long for SigV4 signing");
    }
    @memcpy(prefixed_key_buf[0..4], "AWS4");
    @memcpy(prefixed_key_buf[4..][0..secret_key.len], secret_key);
    const prefixed_key = prefixed_key_buf[0 .. 4 + secret_key.len];

    var date_key: [32]u8 = undefined;
    HmacSha256.create(&date_key, date, prefixed_key);

    // DateRegionKey = HMAC(DateKey, Region)
    var date_region_key: [32]u8 = undefined;
    HmacSha256.create(&date_region_key, region, &date_key);

    // DateRegionServiceKey = HMAC(DateRegionKey, Service)
    var date_region_service_key: [32]u8 = undefined;
    HmacSha256.create(&date_region_service_key, service, &date_region_key);

    // SigningKey = HMAC(DateRegionServiceKey, "aws4_request")
    var signing_key: [32]u8 = undefined;
    HmacSha256.create(&signing_key, "aws4_request", &date_region_service_key);

    return signing_key;
}

/// Create the canonical request string
/// Format:
///   HTTPMethod\n
///   CanonicalURI\n
///   CanonicalQueryString\n
///   CanonicalHeaders\n
///   SignedHeaders\n
///   HashedPayload
pub fn createCanonicalRequest(
    allocator: Allocator,
    method: Method,
    uri: []const u8,
    query: []const u8,
    headers: []const Header,
    payload_hash: []const u8, // Hex-encoded SHA256 of payload
) ![]const u8 {
    // Get canonical URI (encode path components)
    const canonical_uri = try encodeUri(allocator, uri);
    defer allocator.free(canonical_uri);

    // Canonicalize the query string: each parameter name and value must be URI-encoded
    // (RFC 3986 unreserved only), parameters sorted by name. The caller passes the
    // un-encoded query string `k1=v1&k2=v2&...`; we split, encode per-param, and re-join.
    // Canonicalization here is required — S3 uses the canonical query in the signature,
    // and any mismatch with what the server reconstructs produces HTTP 403.
    const canonical_query = try canonicalizeQuery(allocator, query);
    defer allocator.free(canonical_query);

    // Sort headers by lowercase name
    const sorted_headers = try allocator.alloc(Header, headers.len);
    defer allocator.free(sorted_headers);
    @memcpy(sorted_headers, headers);

    std.mem.sort(Header, sorted_headers, {}, struct {
        fn lessThan(_: void, a: Header, b: Header) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    // Build canonical headers and signed headers list
    var canonical_headers_buf = std.ArrayList(u8).init(allocator);
    defer canonical_headers_buf.deinit();

    var signed_headers_buf = std.ArrayList(u8).init(allocator);
    defer signed_headers_buf.deinit();

    for (sorted_headers, 0..) |header, i| {
        // Canonical header: lowercase name:trimmed value\n
        for (header.name) |c| {
            try canonical_headers_buf.append(std.ascii.toLower(c));
        }
        try canonical_headers_buf.append(':');

        // Trim leading/trailing whitespace from value
        const trimmed_value = std.mem.trim(u8, header.value, " \t");
        try canonical_headers_buf.appendSlice(trimmed_value);
        try canonical_headers_buf.append('\n');

        // Signed headers list
        if (i > 0) {
            try signed_headers_buf.append(';');
        }
        for (header.name) |c| {
            try signed_headers_buf.append(std.ascii.toLower(c));
        }
    }

    const canonical_headers = canonical_headers_buf.items;
    const signed_headers = signed_headers_buf.items;

    // Build the canonical request
    return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        method.toString(),
        canonical_uri,
        canonical_query,
        canonical_headers,
        signed_headers,
        payload_hash,
    });
}

/// Canonicalize a query string for SigV4 signing.
///
/// - Splits on `&` into `k=v` pairs (a pair with no `=` is treated as key-only with empty value).
/// - URI-encodes each key and value using the RFC 3986 unreserved set
///   (`A-Z a-z 0-9 - _ . ~`); everything else becomes `%XX`.
/// - Sorts pairs by the encoded key (ties broken by encoded value).
/// - Joins with `&`; pairs always include `=` even when the value is empty.
///
/// Accepts an empty query (returns an empty string) so callers do not need to branch.
fn canonicalizeQuery(allocator: Allocator, query: []const u8) ![]const u8 {
    if (query.len == 0) return allocator.dupe(u8, "");

    const Pair = struct {
        key: []const u8,
        value: []const u8,
    };

    var pairs = std.ArrayList(Pair).init(allocator);
    defer {
        for (pairs.items) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        }
        pairs.deinit();
    }

    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, segment, '=');
        const raw_key = if (eq) |i| segment[0..i] else segment;
        const raw_value = if (eq) |i| segment[i + 1 ..] else "";
        const key = try encodeQueryComponent(allocator, raw_key);
        errdefer allocator.free(key);
        const value = try encodeQueryComponent(allocator, raw_value);
        errdefer allocator.free(value);
        try pairs.append(.{ .key = key, .value = value });
    }

    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            const key_order = std.mem.order(u8, a.key, b.key);
            if (key_order != .eq) return key_order == .lt;
            return std.mem.order(u8, a.value, b.value) == .lt;
        }
    }.lessThan);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (pairs.items, 0..) |pair, i| {
        if (i > 0) try out.append('&');
        try out.appendSlice(pair.key);
        try out.append('=');
        try out.appendSlice(pair.value);
    }
    return out.toOwnedSlice();
}

fn encodeQueryComponent(allocator: Allocator, component: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    for (component) |c| {
        if (isUnreservedUriChar(c)) {
            try result.append(c);
        } else {
            try result.appendSlice(&[_]u8{
                '%',
                hexDigit(@truncate(c >> 4)),
                hexDigit(@truncate(c & 0xF)),
            });
        }
    }
    return result.toOwnedSlice();
}

/// Create the string to sign
/// Format:
///   Algorithm\n
///   RequestDateTime\n
///   CredentialScope\n
///   HashedCanonicalRequest
pub fn createStringToSign(
    allocator: Allocator,
    datetime: []const u8, // YYYYMMDD'T'HHMMSS'Z'
    region: []const u8,
    service: []const u8,
    canonical_request_hash: *const [64]u8, // Hex-encoded
) ![]const u8 {
    const date = datetime[0..8]; // YYYYMMDD

    return std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/{s}/aws4_request\n{s}", .{
        datetime,
        date,
        region,
        service,
        canonical_request_hash,
    });
}

/// Build the Authorization header value
/// Format: AWS4-HMAC-SHA256 Credential=<access_key>/<date>/<region>/<service>/aws4_request,
///         SignedHeaders=<headers>, Signature=<signature>
pub fn buildAuthorizationHeader(
    allocator: Allocator,
    access_key_id: []const u8,
    date: []const u8, // YYYYMMDD
    region: []const u8,
    service: []const u8,
    signed_headers: []const u8,
    signature: *const [64]u8, // Hex-encoded
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders={s}, Signature={s}",
        .{ access_key_id, date, region, service, signed_headers, signature },
    );
}

/// Sign a request and return the Authorization header value
pub fn sign(
    allocator: Allocator,
    credentials: Credentials,
    request: Request,
    region: []const u8,
    service: []const u8,
) ![]const u8 {
    // Get datetime from headers
    const datetime = request.getAmzDate() orelse return error.MissingAmzDate;
    const date = request.getDate() orelse return error.MissingAmzDate;

    // Calculate payload hash
    var payload_hash_bytes: [32]u8 = undefined;
    Sha256.hash(request.payload, &payload_hash_bytes, .{});
    const payload_hash = std.fmt.bytesToHex(payload_hash_bytes, .lower);

    // Create canonical request
    const canonical_request = try createCanonicalRequest(
        allocator,
        request.method,
        request.uri,
        request.query,
        request.headers,
        &payload_hash,
    );
    defer allocator.free(canonical_request);

    // Hash canonical request
    var canonical_hash_bytes: [32]u8 = undefined;
    Sha256.hash(canonical_request, &canonical_hash_bytes, .{});
    const canonical_hash = std.fmt.bytesToHex(canonical_hash_bytes, .lower);

    // Create string to sign
    const string_to_sign = try createStringToSign(
        allocator,
        datetime,
        region,
        service,
        &canonical_hash,
    );
    defer allocator.free(string_to_sign);

    // Derive signing key
    const signing_key = deriveSigningKey(
        credentials.secret_access_key,
        date,
        region,
        service,
    );

    // Calculate signature
    var signature_bytes: [32]u8 = undefined;
    HmacSha256.create(&signature_bytes, string_to_sign, &signing_key);
    const signature = std.fmt.bytesToHex(signature_bytes, .lower);

    // Build signed headers list (must match canonical request)
    var signed_headers_buf = std.ArrayList(u8).init(allocator);
    defer signed_headers_buf.deinit();

    // Sort headers by lowercase name
    const sorted_headers = try allocator.alloc(Header, request.headers.len);
    defer allocator.free(sorted_headers);
    @memcpy(sorted_headers, request.headers);

    std.mem.sort(Header, sorted_headers, {}, struct {
        fn lessThan(_: void, a: Header, b: Header) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    for (sorted_headers, 0..) |header, i| {
        if (i > 0) {
            try signed_headers_buf.append(';');
        }
        for (header.name) |c| {
            try signed_headers_buf.append(std.ascii.toLower(c));
        }
    }

    // Build Authorization header
    return buildAuthorizationHeader(
        allocator,
        credentials.access_key_id,
        date,
        region,
        service,
        signed_headers_buf.items,
        &signature,
    );
}

/// URI encode a path component per RFC 3986
/// Encodes all characters except: A-Z a-z 0-9 - _ . ~ /
fn encodeUri(allocator: Allocator, uri: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    for (uri) |c| {
        if (isUnreservedUriChar(c) or c == '/') {
            try result.append(c);
        } else {
            try result.appendSlice(&[_]u8{ '%', hexDigit(@truncate(c >> 4)), hexDigit(@truncate(c & 0xF)) });
        }
    }

    return result.toOwnedSlice();
}

fn isUnreservedUriChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

fn hexDigit(n: u4) u8 {
    const digits = "0123456789ABCDEF";
    return digits[n];
}

/// Format current time as x-amz-date: YYYYMMDD'T'HHMMSS'Z'
pub fn formatAmzDate(buf: *[16]u8) []const u8 {
    const timestamp = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(timestamp);
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(@divFloor(epoch_seconds, std.time.s_per_day)) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_seconds: u64 = @mod(epoch_seconds, std.time.s_per_day);
    const hours: u32 = @intCast(@divFloor(day_seconds, 3600));
    const minutes: u32 = @intCast(@divFloor(@mod(day_seconds, 3600), 60));
    const seconds: u32 = @intCast(@mod(day_seconds, 60));

    _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        hours,
        minutes,
        seconds,
    }) catch unreachable;

    return buf;
}

/// Format current time as date only: YYYYMMDD
pub fn formatDate(buf: *[8]u8) []const u8 {
    const timestamp = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(timestamp);
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(@divFloor(epoch_seconds, std.time.s_per_day)) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch unreachable;

    return buf;
}

/// Calculate SHA256 hash of payload and return as hex string
pub fn hashPayload(payload: []const u8, out: *[64]u8) void {
    var hash: [32]u8 = undefined;
    Sha256.hash(payload, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    @memcpy(out, &hex);
}

// ============================================================================
// Tests
// ============================================================================

test "sigv4 deriveSigningKey with AWS test vector" {
    // AWS test vector from documentation
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
    const secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    const date = "20150830";
    const region = "us-east-1";
    const service = "iam";

    const signing_key = deriveSigningKey(secret_key, date, region, service);

    // Expected signing key (hex): c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9
    const expected: [32]u8 = .{
        0xc4, 0xaf, 0xb1, 0xcc, 0x57, 0x71, 0xd8, 0x71,
        0x76, 0x3a, 0x39, 0x3e, 0x44, 0xb7, 0x03, 0x57,
        0x1b, 0x55, 0xcc, 0x28, 0x42, 0x4d, 0x1a, 0x5e,
        0x86, 0xda, 0x6e, 0xd3, 0xc1, 0x54, 0xa4, 0xb9,
    };

    try std.testing.expectEqualSlices(u8, &expected, &signing_key);
}

test "sigv4 createCanonicalRequest basic" {
    const allocator = std.testing.allocator;

    const headers = [_]Header{
        .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "x-amz-content-sha256", .value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        .{ .name = "x-amz-date", .value = "20130524T000000Z" },
    };

    const canonical = try createCanonicalRequest(
        allocator,
        .GET,
        "/test.txt",
        "",
        &headers,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
    defer allocator.free(canonical);

    // Verify structure
    var lines = std.mem.splitScalar(u8, canonical, '\n');

    // Method
    try std.testing.expectEqualStrings("GET", lines.next().?);

    // URI
    try std.testing.expectEqualStrings("/test.txt", lines.next().?);

    // Query (empty)
    try std.testing.expectEqualStrings("", lines.next().?);

    // Canonical headers (sorted)
    try std.testing.expectEqualStrings("host:examplebucket.s3.amazonaws.com", lines.next().?);
    try std.testing.expectEqualStrings("x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", lines.next().?);
    try std.testing.expectEqualStrings("x-amz-date:20130524T000000Z", lines.next().?);

    // Empty line after headers
    try std.testing.expectEqualStrings("", lines.next().?);

    // Signed headers
    try std.testing.expectEqualStrings("host;x-amz-content-sha256;x-amz-date", lines.next().?);

    // Payload hash
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", lines.next().?);
}

test "sigv4 createStringToSign basic" {
    const allocator = std.testing.allocator;

    var canonical_hash: [64]u8 = undefined;
    @memcpy(&canonical_hash, "3511de7e95d28ecd39e9513b642aee07e54f4941150d8df8bf94b328ef7e55e2");

    const string_to_sign = try createStringToSign(
        allocator,
        "20130524T000000Z",
        "us-east-1",
        "s3",
        &canonical_hash,
    );
    defer allocator.free(string_to_sign);

    var lines = std.mem.splitScalar(u8, string_to_sign, '\n');

    try std.testing.expectEqualStrings("AWS4-HMAC-SHA256", lines.next().?);
    try std.testing.expectEqualStrings("20130524T000000Z", lines.next().?);
    try std.testing.expectEqualStrings("20130524/us-east-1/s3/aws4_request", lines.next().?);
    try std.testing.expectEqualStrings("3511de7e95d28ecd39e9513b642aee07e54f4941150d8df8bf94b328ef7e55e2", lines.next().?);
}

test "sigv4 buildAuthorizationHeader format" {
    const allocator = std.testing.allocator;

    var signature: [64]u8 = undefined;
    @memcpy(&signature, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    const auth_header = try buildAuthorizationHeader(
        allocator,
        "AKIAIOSFODNN7EXAMPLE",
        "20130524",
        "us-east-1",
        "s3",
        "host;x-amz-content-sha256;x-amz-date",
        &signature,
    );
    defer allocator.free(auth_header);

    try std.testing.expect(std.mem.startsWith(u8, auth_header, "AWS4-HMAC-SHA256 Credential="));
    try std.testing.expect(std.mem.indexOf(u8, auth_header, "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_header, "SignedHeaders=host;x-amz-content-sha256;x-amz-date") != null);
}

test "sigv4 full sign workflow" {
    const allocator = std.testing.allocator;

    const credentials = Credentials{
        .access_key_id = "AKIAIOSFODNN7EXAMPLE",
        .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    };

    const headers = [_]Header{
        .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "x-amz-content-sha256", .value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        .{ .name = "x-amz-date", .value = "20130524T000000Z" },
    };

    const request = Request{
        .method = .GET,
        .uri = "/test.txt",
        .query = "",
        .headers = &headers,
        .payload = "",
    };

    const auth_header = try sign(allocator, credentials, request, "us-east-1", "s3");
    defer allocator.free(auth_header);

    // Verify the header is properly formatted
    try std.testing.expect(std.mem.startsWith(u8, auth_header, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/"));
    try std.testing.expect(std.mem.indexOf(u8, auth_header, "SignedHeaders=") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_header, "Signature=") != null);
}

test "sigv4 encodeUri special characters" {
    const allocator = std.testing.allocator;

    // Test path with spaces and special characters
    const encoded = try encodeUri(allocator, "/path/with spaces/and+plus");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("/path/with%20spaces/and%2Bplus", encoded);
}

test "sigv4 encodeUri preserves safe characters" {
    const allocator = std.testing.allocator;

    const encoded = try encodeUri(allocator, "/path/file-name_v1.2~test");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("/path/file-name_v1.2~test", encoded);
}

test "sigv4 hashPayload" {
    var out: [64]u8 = undefined;
    hashPayload("", &out);

    // SHA256 of empty string
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &out,
    );
}

test "sigv4 hashPayload with content" {
    var out: [64]u8 = undefined;
    hashPayload("hello", &out);

    // SHA256 of "hello"
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &out,
    );
}

test "sigv4 Request getAmzDate" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "bucket.s3.amazonaws.com" },
        .{ .name = "x-amz-date", .value = "20130524T000000Z" },
    };

    const request = Request{
        .method = .GET,
        .uri = "/",
        .query = "",
        .headers = &headers,
        .payload = "",
    };

    try std.testing.expectEqualStrings("20130524T000000Z", request.getAmzDate().?);
    try std.testing.expectEqualStrings("20130524", request.getDate().?);
}

test "sigv4 header sorting case insensitive" {
    const allocator = std.testing.allocator;

    // Headers in unsorted order with mixed case
    const headers = [_]Header{
        .{ .name = "X-Amz-Date", .value = "20130524T000000Z" },
        .{ .name = "Host", .value = "bucket.s3.amazonaws.com" },
        .{ .name = "Content-Type", .value = "text/plain" },
    };

    const canonical = try createCanonicalRequest(
        allocator,
        .PUT,
        "/test.txt",
        "",
        &headers,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
    defer allocator.free(canonical);

    // Find signed headers line (second to last)
    var last_newline: usize = 0;
    var second_last_newline: usize = 0;
    for (canonical, 0..) |c, i| {
        if (c == '\n') {
            second_last_newline = last_newline;
            last_newline = i;
        }
    }

    const signed_headers = canonical[second_last_newline + 1 .. last_newline];
    try std.testing.expectEqualStrings("content-type;host;x-amz-date", signed_headers);
}
