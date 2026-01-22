// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! S3 HTTP Client with SigV4 Authentication
//!
//! Provides S3 operations (PUT, GET, multipart upload) with proper
//! AWS Signature Version 4 signing. Supports all S3-compatible providers
//! via the providers module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Md5 = std.crypto.hash.Md5;

const sigv4 = @import("sigv4.zig");
const providers = @import("providers.zig");

const log = std.log.scoped(.s3_client);

/// S3 client credentials
pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
};

/// Configuration for S3Client
pub const Config = struct {
    /// S3 endpoint URL (e.g., "s3.us-east-1.amazonaws.com" or "localhost:9000")
    endpoint: []const u8,
    /// AWS region (e.g., "us-east-1")
    region: []const u8 = "us-east-1",
    /// S3 credentials
    credentials: Credentials,
    /// URL style (path or virtual-hosted)
    url_style: ?providers.UrlStyle = null, // null = auto-detect based on provider
    /// Connection timeout in milliseconds
    connect_timeout_ms: u32 = 5000,
    /// Request timeout in milliseconds
    request_timeout_ms: u32 = 30000,
};

/// Result from a PUT object operation
pub const PutObjectResult = struct {
    /// ETag of the uploaded object
    etag: []const u8,
    /// Version ID (if versioning enabled)
    version_id: ?[]const u8,

    pub fn deinit(self: *PutObjectResult, allocator: Allocator) void {
        allocator.free(self.etag);
        if (self.version_id) |vid| {
            allocator.free(vid);
        }
    }
};

/// Part info for multipart upload completion
pub const PartInfo = struct {
    part_number: u32,
    etag: []const u8,
};

/// S3 API error
pub const S3Error = error{
    ConnectionFailed,
    RequestFailed,
    AuthenticationFailed,
    BucketNotFound,
    ObjectNotFound,
    AccessDenied,
    InvalidResponse,
    UploadFailed,
    MultipartUploadFailed,
    OutOfMemory,
    Timeout,
    SignatureError,
};

/// S3 HTTP client
pub const S3Client = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    credentials: Credentials,
    endpoint: []const u8,
    region: []const u8,
    provider: providers.Provider,
    url_style: providers.UrlStyle,

    // Owned copies of credential strings
    _owned_endpoint: []const u8,
    _owned_region: []const u8,
    _owned_access_key: []const u8,
    _owned_secret_key: []const u8,

    /// Default multipart upload part size: 16MB
    pub const default_part_size: usize = 16 * 1024 * 1024;

    /// Multipart upload threshold: 100MB
    pub const multipart_threshold: usize = 100 * 1024 * 1024;

    pub fn init(allocator: Allocator, config: Config) !S3Client {
        // Detect provider from endpoint
        const provider = providers.detectProvider(config.endpoint);

        // Get effective region
        const effective_region = providers.getRegion(provider, config.region);

        // Get URL style (auto-detect if not specified)
        const url_style = config.url_style orelse providers.getRecommendedUrlStyle(provider);

        // Create HTTP client
        const http_client = std.http.Client{ .allocator = allocator };

        // Make owned copies of strings
        const owned_endpoint = try allocator.dupe(u8, config.endpoint);
        errdefer allocator.free(owned_endpoint);

        const owned_region = try allocator.dupe(u8, effective_region);
        errdefer allocator.free(owned_region);

        const owned_access_key = try allocator.dupe(u8, config.credentials.access_key_id);
        errdefer allocator.free(owned_access_key);

        const owned_secret_key = try allocator.dupe(u8, config.credentials.secret_access_key);
        errdefer allocator.free(owned_secret_key);

        log.info("S3 client initialized: provider={s}, region={s}, style={s}", .{
            provider.toString(),
            owned_region,
            if (url_style == .path) "path" else "virtual-hosted",
        });

        return S3Client{
            .allocator = allocator,
            .http_client = http_client,
            .credentials = .{
                .access_key_id = owned_access_key,
                .secret_access_key = owned_secret_key,
            },
            .endpoint = owned_endpoint,
            .region = owned_region,
            .provider = provider,
            .url_style = url_style,
            ._owned_endpoint = owned_endpoint,
            ._owned_region = owned_region,
            ._owned_access_key = owned_access_key,
            ._owned_secret_key = owned_secret_key,
        };
    }

    pub fn deinit(self: *S3Client) void {
        self.http_client.deinit();
        self.allocator.free(self._owned_endpoint);
        self.allocator.free(self._owned_region);
        self.allocator.free(self._owned_access_key);
        self.allocator.free(self._owned_secret_key);
    }

    /// Upload an object to S3 (single PUT request)
    pub fn putObject(
        self: *S3Client,
        bucket: []const u8,
        key: []const u8,
        body: []const u8,
        content_md5: ?[]const u8,
    ) S3Error!PutObjectResult {
        // Build request URL
        const url = providers.buildRequestUrl(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(url);

        // Get signing URI
        const signing_uri = providers.getSigningUri(
            self.allocator,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(signing_uri);

        // Get host header
        const host = providers.getHostHeader(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(host);

        // Calculate payload hash
        var payload_hash: [64]u8 = undefined;
        sigv4.hashPayload(body, &payload_hash);

        // Format date
        var date_buf: [16]u8 = undefined;
        const amz_date = sigv4.formatAmzDate(&date_buf);

        // Calculate Content-MD5 if not provided
        var md5_buf: [24]u8 = undefined;
        const md5_header = if (content_md5) |md5|
            md5
        else blk: {
            var md5_hash: [16]u8 = undefined;
            Md5.hash(body, &md5_hash, .{});
            const encoded_len = std.base64.standard.Encoder.calcSize(16);
            _ = std.base64.standard.Encoder.encode(md5_buf[0..encoded_len], &md5_hash);
            break :blk md5_buf[0..encoded_len];
        };

        // Build headers for signing
        const headers = [_]sigv4.Header{
            .{ .name = "Host", .value = host },
            .{ .name = "x-amz-content-sha256", .value = &payload_hash },
            .{ .name = "x-amz-date", .value = amz_date },
            .{ .name = "Content-MD5", .value = md5_header },
        };

        const request = sigv4.Request{
            .method = .PUT,
            .uri = signing_uri,
            .query = "",
            .headers = &headers,
            .payload = body,
        };

        // Sign the request
        const auth_header = sigv4.sign(
            self.allocator,
            .{
                .access_key_id = self.credentials.access_key_id,
                .secret_access_key = self.credentials.secret_access_key,
            },
            request,
            self.region,
            providers.getServiceName(self.provider),
        ) catch return error.SignatureError;
        defer self.allocator.free(auth_header);

        // Parse URL
        const uri = std.Uri.parse(url) catch return error.InvalidResponse;

        // Make HTTP request
        var server_header_buffer: [8192]u8 = undefined;
        var req = self.http_client.open(.PUT, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Host", .value = host },
                .{ .name = "x-amz-content-sha256", .value = &payload_hash },
                .{ .name = "x-amz-date", .value = amz_date },
                .{ .name = "Content-MD5", .value = md5_header },
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Length", .value = blk: {
                    var len_buf: [20]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable;
                    break :blk len_str;
                } },
            },
        }) catch |err| {
            log.warn("HTTP request open failed: {}", .{err});
            return error.ConnectionFailed;
        };
        defer req.deinit();

        // Send body
        _ = req.write(body) catch |err| {
            log.warn("HTTP write failed: {}", .{err});
            return error.RequestFailed;
        };

        req.finish() catch |err| {
            log.warn("HTTP finish failed: {}", .{err});
            return error.RequestFailed;
        };

        // Wait for response
        req.wait() catch |err| {
            log.warn("HTTP wait failed: {}", .{err});
            return error.RequestFailed;
        };

        // Check response status
        if (req.response.status != .ok and req.response.status != .created) {
            log.warn("S3 PUT failed: status={}", .{req.response.status});
            return switch (req.response.status) {
                .forbidden => error.AccessDenied,
                .not_found => error.BucketNotFound,
                .unauthorized => error.AuthenticationFailed,
                else => error.UploadFailed,
            };
        }

        // Extract ETag from response headers
        var etag: []const u8 = "";
        var version_id: ?[]const u8 = null;

        var header_iter = req.response.iterateHeaders();
        while (header_iter.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "ETag")) {
                etag = self.allocator.dupe(u8, header.value) catch return error.OutOfMemory;
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-amz-version-id")) {
                version_id = self.allocator.dupe(u8, header.value) catch return error.OutOfMemory;
            }
        }

        if (etag.len == 0) {
            // Some providers don't return ETag, use a placeholder
            etag = self.allocator.dupe(u8, "unknown") catch return error.OutOfMemory;
        }

        log.debug("S3 PUT success: bucket={s}, key={s}, etag={s}", .{ bucket, key, etag });

        return PutObjectResult{
            .etag = etag,
            .version_id = version_id,
        };
    }

    /// Initiate a multipart upload
    pub fn initiateMultipartUpload(
        self: *S3Client,
        bucket: []const u8,
        key: []const u8,
    ) S3Error![]const u8 {
        // Build request URL with ?uploads query
        const base_url = providers.buildRequestUrl(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(base_url);

        const url = std.fmt.allocPrint(self.allocator, "{s}?uploads", .{base_url}) catch return error.OutOfMemory;
        defer self.allocator.free(url);

        // Get signing URI
        const signing_uri = providers.getSigningUri(
            self.allocator,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(signing_uri);

        // Get host header
        const host = providers.getHostHeader(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(host);

        // Empty payload hash for initiate
        var payload_hash: [64]u8 = undefined;
        sigv4.hashPayload("", &payload_hash);

        // Format date
        var date_buf: [16]u8 = undefined;
        const amz_date = sigv4.formatAmzDate(&date_buf);

        // Build headers for signing
        const headers = [_]sigv4.Header{
            .{ .name = "Host", .value = host },
            .{ .name = "x-amz-content-sha256", .value = &payload_hash },
            .{ .name = "x-amz-date", .value = amz_date },
        };

        const request = sigv4.Request{
            .method = .POST,
            .uri = signing_uri,
            .query = "uploads",
            .headers = &headers,
            .payload = "",
        };

        // Sign the request
        const auth_header = sigv4.sign(
            self.allocator,
            .{
                .access_key_id = self.credentials.access_key_id,
                .secret_access_key = self.credentials.secret_access_key,
            },
            request,
            self.region,
            providers.getServiceName(self.provider),
        ) catch return error.SignatureError;
        defer self.allocator.free(auth_header);

        // Parse URL
        const uri = std.Uri.parse(url) catch return error.InvalidResponse;

        // Make HTTP request
        var server_header_buffer: [8192]u8 = undefined;
        var req = self.http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Host", .value = host },
                .{ .name = "x-amz-content-sha256", .value = &payload_hash },
                .{ .name = "x-amz-date", .value = amz_date },
                .{ .name = "Authorization", .value = auth_header },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.finish() catch return error.RequestFailed;
        req.wait() catch return error.RequestFailed;

        if (req.response.status != .ok) {
            log.warn("Initiate multipart upload failed: status={}", .{req.response.status});
            return error.MultipartUploadFailed;
        }

        // Read response body to get upload ID
        var body_buf: [4096]u8 = undefined;
        const body_len = req.reader().readAll(&body_buf) catch return error.InvalidResponse;
        const body = body_buf[0..body_len];

        // Parse upload ID from XML response
        // <UploadId>upload-id</UploadId>
        const upload_id = parseXmlElement(body, "UploadId") orelse {
            log.warn("Could not find UploadId in response", .{});
            return error.InvalidResponse;
        };

        const upload_id_copy = self.allocator.dupe(u8, upload_id) catch return error.OutOfMemory;

        log.debug("Initiated multipart upload: bucket={s}, key={s}, uploadId={s}", .{
            bucket,
            key,
            upload_id_copy,
        });

        return upload_id_copy;
    }

    /// Upload a part in a multipart upload
    pub fn uploadPart(
        self: *S3Client,
        bucket: []const u8,
        key: []const u8,
        upload_id: []const u8,
        part_number: u32,
        body: []const u8,
    ) S3Error![]const u8 {
        // Build request URL with query parameters
        const base_url = providers.buildRequestUrl(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(base_url);

        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}?partNumber={d}&uploadId={s}",
            .{ base_url, part_number, upload_id },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(url);

        // Get signing URI
        const signing_uri = providers.getSigningUri(
            self.allocator,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(signing_uri);

        // Build query string for signing (must be sorted)
        const query = std.fmt.allocPrint(
            self.allocator,
            "partNumber={d}&uploadId={s}",
            .{ part_number, upload_id },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(query);

        // Get host header
        const host = providers.getHostHeader(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(host);

        // Calculate payload hash
        var payload_hash: [64]u8 = undefined;
        sigv4.hashPayload(body, &payload_hash);

        // Format date
        var date_buf: [16]u8 = undefined;
        const amz_date = sigv4.formatAmzDate(&date_buf);

        // Build headers for signing
        const headers = [_]sigv4.Header{
            .{ .name = "Host", .value = host },
            .{ .name = "x-amz-content-sha256", .value = &payload_hash },
            .{ .name = "x-amz-date", .value = amz_date },
        };

        const request = sigv4.Request{
            .method = .PUT,
            .uri = signing_uri,
            .query = query,
            .headers = &headers,
            .payload = body,
        };

        // Sign the request
        const auth_header = sigv4.sign(
            self.allocator,
            .{
                .access_key_id = self.credentials.access_key_id,
                .secret_access_key = self.credentials.secret_access_key,
            },
            request,
            self.region,
            providers.getServiceName(self.provider),
        ) catch return error.SignatureError;
        defer self.allocator.free(auth_header);

        // Parse URL
        const uri = std.Uri.parse(url) catch return error.InvalidResponse;

        // Make HTTP request
        var server_header_buffer: [8192]u8 = undefined;
        var req = self.http_client.open(.PUT, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Host", .value = host },
                .{ .name = "x-amz-content-sha256", .value = &payload_hash },
                .{ .name = "x-amz-date", .value = amz_date },
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Length", .value = blk: {
                    var len_buf: [20]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable;
                    break :blk len_str;
                } },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        _ = req.write(body) catch return error.RequestFailed;
        req.finish() catch return error.RequestFailed;
        req.wait() catch return error.RequestFailed;

        if (req.response.status != .ok) {
            log.warn("Upload part failed: status={}", .{req.response.status});
            return error.MultipartUploadFailed;
        }

        // Extract ETag from response headers
        var etag: []const u8 = "";
        var header_iter = req.response.iterateHeaders();
        while (header_iter.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "ETag")) {
                etag = self.allocator.dupe(u8, header.value) catch return error.OutOfMemory;
                break;
            }
        }

        if (etag.len == 0) {
            return error.InvalidResponse;
        }

        log.debug("Uploaded part: bucket={s}, key={s}, part={d}, etag={s}", .{
            bucket,
            key,
            part_number,
            etag,
        });

        return etag;
    }

    /// Complete a multipart upload
    pub fn completeMultipartUpload(
        self: *S3Client,
        bucket: []const u8,
        key: []const u8,
        upload_id: []const u8,
        parts: []const PartInfo,
    ) S3Error!void {
        // Build completion XML
        var xml = std.ArrayList(u8).init(self.allocator);
        defer xml.deinit();

        xml.appendSlice("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CompleteMultipartUpload>") catch return error.OutOfMemory;
        for (parts) |part| {
            const part_xml = std.fmt.allocPrint(
                self.allocator,
                "<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>",
                .{ part.part_number, part.etag },
            ) catch return error.OutOfMemory;
            defer self.allocator.free(part_xml);
            xml.appendSlice(part_xml) catch return error.OutOfMemory;
        }
        xml.appendSlice("</CompleteMultipartUpload>") catch return error.OutOfMemory;

        const body = xml.items;

        // Build request URL with uploadId query
        const base_url = providers.buildRequestUrl(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(base_url);

        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}?uploadId={s}",
            .{ base_url, upload_id },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(url);

        // Get signing URI
        const signing_uri = providers.getSigningUri(
            self.allocator,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(signing_uri);

        const query = std.fmt.allocPrint(self.allocator, "uploadId={s}", .{upload_id}) catch return error.OutOfMemory;
        defer self.allocator.free(query);

        // Get host header
        const host = providers.getHostHeader(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(host);

        // Calculate payload hash
        var payload_hash: [64]u8 = undefined;
        sigv4.hashPayload(body, &payload_hash);

        // Format date
        var date_buf: [16]u8 = undefined;
        const amz_date = sigv4.formatAmzDate(&date_buf);

        // Build headers for signing
        const headers = [_]sigv4.Header{
            .{ .name = "Host", .value = host },
            .{ .name = "x-amz-content-sha256", .value = &payload_hash },
            .{ .name = "x-amz-date", .value = amz_date },
        };

        const request = sigv4.Request{
            .method = .POST,
            .uri = signing_uri,
            .query = query,
            .headers = &headers,
            .payload = body,
        };

        // Sign the request
        const auth_header = sigv4.sign(
            self.allocator,
            .{
                .access_key_id = self.credentials.access_key_id,
                .secret_access_key = self.credentials.secret_access_key,
            },
            request,
            self.region,
            providers.getServiceName(self.provider),
        ) catch return error.SignatureError;
        defer self.allocator.free(auth_header);

        // Parse URL
        const uri = std.Uri.parse(url) catch return error.InvalidResponse;

        // Make HTTP request
        var server_header_buffer: [8192]u8 = undefined;
        var req = self.http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Host", .value = host },
                .{ .name = "x-amz-content-sha256", .value = &payload_hash },
                .{ .name = "x-amz-date", .value = amz_date },
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/xml" },
                .{ .name = "Content-Length", .value = blk: {
                    var len_buf: [20]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable;
                    break :blk len_str;
                } },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        _ = req.write(body) catch return error.RequestFailed;
        req.finish() catch return error.RequestFailed;
        req.wait() catch return error.RequestFailed;

        if (req.response.status != .ok) {
            log.warn("Complete multipart upload failed: status={}", .{req.response.status});
            return error.MultipartUploadFailed;
        }

        log.debug("Completed multipart upload: bucket={s}, key={s}", .{ bucket, key });
    }

    /// Abort a multipart upload
    pub fn abortMultipartUpload(
        self: *S3Client,
        bucket: []const u8,
        key: []const u8,
        upload_id: []const u8,
    ) S3Error!void {
        // Build request URL with uploadId query
        const base_url = providers.buildRequestUrl(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(base_url);

        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}?uploadId={s}",
            .{ base_url, upload_id },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(url);

        // Get signing URI
        const signing_uri = providers.getSigningUri(
            self.allocator,
            bucket,
            key,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(signing_uri);

        const query = std.fmt.allocPrint(self.allocator, "uploadId={s}", .{upload_id}) catch return error.OutOfMemory;
        defer self.allocator.free(query);

        // Get host header
        const host = providers.getHostHeader(
            self.allocator,
            self.provider,
            self.endpoint,
            bucket,
            self.url_style,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(host);

        // Empty payload
        var payload_hash: [64]u8 = undefined;
        sigv4.hashPayload("", &payload_hash);

        // Format date
        var date_buf: [16]u8 = undefined;
        const amz_date = sigv4.formatAmzDate(&date_buf);

        // Build headers for signing
        const headers = [_]sigv4.Header{
            .{ .name = "Host", .value = host },
            .{ .name = "x-amz-content-sha256", .value = &payload_hash },
            .{ .name = "x-amz-date", .value = amz_date },
        };

        const request = sigv4.Request{
            .method = .DELETE,
            .uri = signing_uri,
            .query = query,
            .headers = &headers,
            .payload = "",
        };

        // Sign the request
        const auth_header = sigv4.sign(
            self.allocator,
            .{
                .access_key_id = self.credentials.access_key_id,
                .secret_access_key = self.credentials.secret_access_key,
            },
            request,
            self.region,
            providers.getServiceName(self.provider),
        ) catch return error.SignatureError;
        defer self.allocator.free(auth_header);

        // Parse URL
        const uri = std.Uri.parse(url) catch return error.InvalidResponse;

        // Make HTTP request
        var server_header_buffer: [8192]u8 = undefined;
        var req = self.http_client.open(.DELETE, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Host", .value = host },
                .{ .name = "x-amz-content-sha256", .value = &payload_hash },
                .{ .name = "x-amz-date", .value = amz_date },
                .{ .name = "Authorization", .value = auth_header },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.finish() catch return error.RequestFailed;
        req.wait() catch return error.RequestFailed;

        if (req.response.status != .no_content and req.response.status != .ok) {
            log.warn("Abort multipart upload failed: status={}", .{req.response.status});
            return error.MultipartUploadFailed;
        }

        log.debug("Aborted multipart upload: bucket={s}, key={s}", .{ bucket, key });
    }

    /// Perform a multipart upload for large content
    pub fn multipartUpload(
        self: *S3Client,
        bucket: []const u8,
        key: []const u8,
        body: []const u8,
    ) S3Error!void {
        const part_size = default_part_size;
        const num_parts = (body.len + part_size - 1) / part_size;

        log.info("Starting multipart upload: bucket={s}, key={s}, size={d}, parts={d}", .{
            bucket,
            key,
            body.len,
            num_parts,
        });

        // Initiate multipart upload
        const upload_id = try self.initiateMultipartUpload(bucket, key);
        defer self.allocator.free(upload_id);

        // Track parts for completion
        var parts = self.allocator.alloc(PartInfo, num_parts) catch return error.OutOfMemory;
        defer {
            for (parts) |part| {
                self.allocator.free(part.etag);
            }
            self.allocator.free(parts);
        }

        // Upload parts
        var part_num: u32 = 0;
        while (part_num < num_parts) : (part_num += 1) {
            const start = part_num * part_size;
            const end = @min(start + part_size, body.len);
            const part_body = body[start..end];

            const etag = self.uploadPart(bucket, key, upload_id, part_num + 1, part_body) catch |err| {
                // Abort on failure
                self.abortMultipartUpload(bucket, key, upload_id) catch {};
                return err;
            };

            parts[part_num] = .{
                .part_number = part_num + 1,
                .etag = etag,
            };
        }

        // Complete multipart upload
        self.completeMultipartUpload(bucket, key, upload_id, parts) catch |err| {
            self.abortMultipartUpload(bucket, key, upload_id) catch {};
            return err;
        };

        log.info("Completed multipart upload: bucket={s}, key={s}", .{ bucket, key });
    }
};

/// Parse a simple XML element value
fn parseXmlElement(xml: []const u8, element: []const u8) ?[]const u8 {
    // Look for <element>value</element>
    var start_tag_buf: [128]u8 = undefined;
    const start_tag = std.fmt.bufPrint(&start_tag_buf, "<{s}>", .{element}) catch return null;

    var end_tag_buf: [128]u8 = undefined;
    const end_tag = std.fmt.bufPrint(&end_tag_buf, "</{s}>", .{element}) catch return null;

    const start_idx = std.mem.indexOf(u8, xml, start_tag) orelse return null;
    const value_start = start_idx + start_tag.len;
    const end_idx = std.mem.indexOf(u8, xml[value_start..], end_tag) orelse return null;

    return xml[value_start .. value_start + end_idx];
}

// ============================================================================
// Tests
// ============================================================================

test "s3_client parseXmlElement" {
    const xml = "<?xml version=\"1.0\"?><InitiateMultipartUploadResult><Bucket>test</Bucket><Key>key</Key><UploadId>abc123</UploadId></InitiateMultipartUploadResult>";

    const upload_id = parseXmlElement(xml, "UploadId");
    try std.testing.expect(upload_id != null);
    try std.testing.expectEqualStrings("abc123", upload_id.?);

    const bucket = parseXmlElement(xml, "Bucket");
    try std.testing.expect(bucket != null);
    try std.testing.expectEqualStrings("test", bucket.?);

    const missing = parseXmlElement(xml, "NotFound");
    try std.testing.expect(missing == null);
}

test "s3_client init and deinit" {
    const allocator = std.testing.allocator;

    var client = try S3Client.init(allocator, .{
        .endpoint = "localhost:9000",
        .region = "us-east-1",
        .credentials = .{
            .access_key_id = "minioadmin",
            .secret_access_key = "minioadmin",
        },
    });
    defer client.deinit();

    try std.testing.expectEqual(providers.Provider.generic, client.provider);
    try std.testing.expectEqualStrings("us-east-1", client.region);
    try std.testing.expectEqual(providers.UrlStyle.path, client.url_style);
}

test "s3_client init with AWS endpoint" {
    const allocator = std.testing.allocator;

    var client = try S3Client.init(allocator, .{
        .endpoint = "s3.us-west-2.amazonaws.com",
        .region = "us-west-2",
        .credentials = .{
            .access_key_id = "AKIAIOSFODNN7EXAMPLE",
            .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        },
    });
    defer client.deinit();

    try std.testing.expectEqual(providers.Provider.aws, client.provider);
    try std.testing.expectEqual(providers.UrlStyle.virtual_hosted, client.url_style);
}

test "s3_client init with R2 endpoint" {
    const allocator = std.testing.allocator;

    var client = try S3Client.init(allocator, .{
        .endpoint = "abc123.r2.cloudflarestorage.com",
        .credentials = .{
            .access_key_id = "r2key",
            .secret_access_key = "r2secret",
        },
    });
    defer client.deinit();

    try std.testing.expectEqual(providers.Provider.r2, client.provider);
    // R2 uses "auto" region for signing
    try std.testing.expectEqualStrings("auto", client.region);
}

test "s3_client default_part_size and threshold" {
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), S3Client.default_part_size);
    try std.testing.expectEqual(@as(usize, 100 * 1024 * 1024), S3Client.multipart_threshold);
}
