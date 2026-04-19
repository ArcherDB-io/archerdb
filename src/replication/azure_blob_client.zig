// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Azure Blob Storage HTTP client with SharedKey authentication.
//!
//! Covers the subset of the Blob REST API needed by ArcherDB's backup uploader:
//!   - PUT Blob (arbitrary bytes, `BlockBlob` type)
//!   - GET Blob
//!   - List Blobs (by container + prefix)
//!
//! Auth follows the standard SharedKey scheme documented at
//! https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key.
//! Operators supply an account name and base64 account key (issued via the Azure portal or
//! Azurite local emulator defaults). Multipart / block-list uploads for large blobs are not
//! implemented here — typical ArcherDB block sizes (4–8 MiB) fit well under the Blob
//! single-PUT ceiling (100 MiB per Microsoft docs).
//!
//! No SDK dependency is introduced: HTTP goes through `std.http.Client`, HMAC-SHA256 through
//! `std.crypto.auth.hmac`. Matches the zero-dep stance of `s3_client.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const log = std.log.scoped(.azure_blob_client);

pub const api_version = "2021-12-02";

/// Blobs at or above this size upload via Put Block + Put Block List instead of a single
/// PUT Blob. Matches the S3Client multipart threshold so large-block operators get the
/// same behaviour on both providers. Azure's hard single-PUT ceiling is 256 MiB on
/// premium/block-blob accounts and 5 TiB via multi-block uploads; 100 MiB is well below
/// both while comfortably above the 4–8 MiB LSM block sizes ArcherDB uses today.
pub const multipart_threshold: usize = 100 * 1024 * 1024;

/// Per-block chunk size for multipart uploads. Azure requires every block inside a single
/// blob to be the same size (except optionally the final block). 8 MiB balances
/// throughput vs request count; 100 MiB blob → 13 blocks.
pub const multipart_block_size: usize = 8 * 1024 * 1024;

pub const AzureError = error{
    ConnectionFailed,
    RequestFailed,
    AuthenticationFailed,
    ContainerNotFound,
    BlobNotFound,
    AccessDenied,
    InvalidResponse,
    UploadFailed,
    OutOfMemory,
    InvalidAccountKey,
};

pub const Credentials = struct {
    account: []const u8,
    /// Base64-encoded account key. Will be decoded at sign time.
    account_key_base64: []const u8,
};

pub const Config = struct {
    endpoint: []const u8, // e.g. "myacct.blob.core.windows.net" or "localhost:10000"
    credentials: Credentials,
    /// Azurite (the local emulator) prepends the account name to every path instead of
    /// using it as a subdomain. Set this to true when pointing the client at Azurite so
    /// paths and the canonical resource string both include `/<account>/` before the
    /// container. Production Azure defaults to false.
    use_path_style: bool = false,
    request_timeout_ms: u32 = 30_000,
    /// Optional multipart threshold override. Tests use this to force the Put Block
    /// List path at a body size small enough to validate on an emulator without
    /// waiting on 100 MiB uploads. `null` means use `multipart_threshold`.
    multipart_threshold_override: ?usize = null,
    /// Optional per-block chunk size override. Only read by the multipart path. Tests
    /// pair this with `multipart_threshold_override` to exercise multi-block uploads
    /// against an emulator at modest body sizes. `null` means use `multipart_block_size`.
    multipart_block_size_override: ?usize = null,
};

pub const ListedBlob = struct {
    name: []const u8,
    size: u64,
};

pub const AzureBlobClient = struct {
    allocator: Allocator,
    http: std.http.Client,
    endpoint: []u8,
    account: []u8,
    account_key: [64]u8, // decoded; up to 64 bytes supported
    account_key_len: usize,
    use_path_style: bool,
    multipart_threshold_override: ?usize,
    multipart_block_size_override: ?usize,

    pub fn init(allocator: Allocator, config: Config) !AzureBlobClient {
        // Decode the base64 account key once, at init; sign loops then just run HMAC.
        var key_buf: [128]u8 = undefined;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(
            config.credentials.account_key_base64,
        ) catch return error.InvalidAccountKey;
        if (decoded_len > 64) return error.InvalidAccountKey;
        std.base64.standard.Decoder.decode(
            key_buf[0..decoded_len],
            config.credentials.account_key_base64,
        ) catch return error.InvalidAccountKey;

        var self = AzureBlobClient{
            .allocator = allocator,
            .http = std.http.Client{ .allocator = allocator },
            .endpoint = try allocator.dupe(u8, config.endpoint),
            .account = try allocator.dupe(u8, config.credentials.account),
            .account_key = undefined,
            .account_key_len = decoded_len,
            .use_path_style = config.use_path_style,
            .multipart_threshold_override = config.multipart_threshold_override,
            .multipart_block_size_override = config.multipart_block_size_override,
        };
        @memcpy(self.account_key[0..decoded_len], key_buf[0..decoded_len]);
        return self;
    }

    pub fn deinit(self: *AzureBlobClient) void {
        self.http.deinit();
        self.allocator.free(self.endpoint);
        self.allocator.free(self.account);
        // Zero the key on drop. Defense in depth: prevents the key from persisting in freed
        // stack/heap memory that might later surface in a crash dump.
        @memset(self.account_key[0..self.account_key_len], 0);
    }

    /// Create a container. Returns `ok` on success. Treats HTTP 409 (ContainerAlreadyExists)
    /// as success so callers can use this idempotently. Needed for tests and one-time
    /// operator setup where the container is not provisioned out of band.
    pub fn createContainer(self: *AzureBlobClient, container: []const u8) AzureError!void {
        const query = try self.allocator.dupe(u8, "restype=container");
        defer self.allocator.free(query);
        const url = try self.buildUrlContainer(container, query);
        defer self.allocator.free(url);

        var date_buf: [48]u8 = undefined;
        const rfc1123_date = formatRfc1123Now(&date_buf);

        // Canonical resource. For production Azure (virtual-hosted URL), the path is just
        // `/<account>/<container>`. For path-style (Azurite, Azure Stack) the URL path
        // already includes the account, so the canonicalized resource — which is defined
        // as `/<account>` + `<url_path>` — ends up with the account name twice. This
        // matches what Azurite logs as the expected string-to-sign.
        const canonical_resource = if (self.use_path_style)
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}\nrestype:container",
                .{ self.account, self.account, container },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}\nrestype:container",
                .{ self.account, container },
            );
        defer self.allocator.free(canonical_resource);

        const canonical_headers = try std.fmt.allocPrint(
            self.allocator,
            "x-ms-date:{s}\nx-ms-version:{s}",
            .{ rfc1123_date, api_version },
        );
        defer self.allocator.free(canonical_headers);

        const string_to_sign = try buildStringToSign(
            self.allocator,
            "PUT",
            "",
            canonical_headers,
            canonical_resource,
        );
        defer self.allocator.free(string_to_sign);

        const authorization = try self.buildAuthHeader(string_to_sign);
        defer self.allocator.free(authorization);

        const uri = std.Uri.parse(url) catch return error.InvalidResponse;
        var header_buf: [8192]u8 = undefined;
        var req = self.http.open(.PUT, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "x-ms-date", .value = rfc1123_date },
                .{ .name = "x-ms-version", .value = api_version },
                .{ .name = "Authorization", .value = authorization },
            },
        }) catch |err| {
            log.warn("azure createContainer open failed: {}", .{err});
            return error.ConnectionFailed;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = 0 };
        req.send() catch |err| return httpErr("send", err);
        req.finish() catch |err| return httpErr("finish", err);
        req.wait() catch |err| return httpErr("wait", err);

        if (req.response.status == .created) return;
        if (req.response.status == .conflict) return; // already exists
        log.warn(
            "azure createContainer failed: container={s} status={}",
            .{ container, req.response.status },
        );
        return mapHttpStatus(req.response.status);
    }

    /// PUT a block blob of `body` bytes. Overwrites any existing blob at the same key.
    /// For `body.len >= multipart_threshold` this delegates to a block-list upload
    /// (`Put Block` per chunk, then `Put Block List` to commit); small bodies take the
    /// single-PUT fast path.
    pub fn putBlob(
        self: *AzureBlobClient,
        container: []const u8,
        blob: []const u8,
        body: []const u8,
    ) AzureError!void {
        if (body.len >= self.multipart_threshold_override orelse multipart_threshold) {
            return self.putBlobMultipart(container, blob, body);
        }
        return self.putBlobSingle(container, blob, body);
    }

    fn putBlobSingle(
        self: *AzureBlobClient,
        container: []const u8,
        blob: []const u8,
        body: []const u8,
    ) AzureError!void {
        const url = try self.buildUrl(container, blob, null);
        defer self.allocator.free(url);

        var date_buf: [48]u8 = undefined;
        const rfc1123_date = formatRfc1123Now(&date_buf);

        var content_length_buf: [20]u8 = undefined;
        const content_length = std.fmt.bufPrint(
            &content_length_buf,
            "{d}",
            .{body.len},
        ) catch return error.OutOfMemory;

        const authorization = self.sign(
            .{ .method = "PUT", .content_length = content_length },
            rfc1123_date,
            container,
            blob,
        ) catch |err| return mapSignErr(err);
        defer self.allocator.free(authorization);

        const uri = std.Uri.parse(url) catch return error.InvalidResponse;
        var header_buf: [8192]u8 = undefined;
        var req = self.http.open(.PUT, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "x-ms-blob-type", .value = "BlockBlob" },
                .{ .name = "x-ms-date", .value = rfc1123_date },
                .{ .name = "x-ms-version", .value = api_version },
                .{ .name = "Authorization", .value = authorization },
            },
        }) catch |err| {
            log.warn("azure PUT open failed: {}", .{err});
            return error.ConnectionFailed;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch |err| return httpErr("send", err);
        req.writeAll(body) catch |err| return httpErr("write", err);
        req.finish() catch |err| return httpErr("finish", err);
        req.wait() catch |err| return httpErr("wait", err);

        if (req.response.status != .created and req.response.status != .ok) {
            log.warn(
                "azure PUT failed: container={s} blob={s} status={}",
                .{ container, blob, req.response.status },
            );
            return mapHttpStatus(req.response.status);
        }
    }

    /// Block-list upload. Splits `body` into chunks of `multipart_block_size` (last chunk
    /// may be smaller), uploads each via `Put Block`, and commits the blob via
    /// `Put Block List`. Azure requires every block ID in a blob to be the same decoded
    /// length; this path generates deterministic base64-encoded IDs from a zero-padded
    /// index that satisfies that rule.
    fn putBlobMultipart(
        self: *AzureBlobClient,
        container: []const u8,
        blob: []const u8,
        body: []const u8,
    ) AzureError!void {
        // Pre-compute the number of blocks and build the ID list up-front so we know the
        // Put Block List payload ahead of time (keeps the request simple, no streaming).
        const block_size = self.multipart_block_size_override orelse multipart_block_size;
        const block_count = (body.len + block_size - 1) / block_size;
        if (block_count == 0) {
            // Defensive: caller should never reach here with an empty body, but treat as
            // single-PUT if they do.
            return self.putBlobSingle(container, blob, body);
        }
        if (block_count > 50_000) {
            // Azure's absolute limit is 50_000 blocks per blob. Clamp with a clear error
            // instead of letting the server reject a multi-gigabyte upload halfway.
            log.warn(
                "azure multipart would exceed 50000 blocks " ++
                    "(body={d}, block_size={d}): refusing",
                .{ body.len, block_size },
            );
            return error.UploadFailed;
        }

        var block_ids = std.ArrayList([]u8).init(self.allocator);
        defer {
            for (block_ids.items) |id| self.allocator.free(id);
            block_ids.deinit();
        }

        var offset: usize = 0;
        var idx: u32 = 0;
        while (offset < body.len) : (idx += 1) {
            const chunk_end = @min(offset + block_size, body.len);
            const chunk = body[offset..chunk_end];
            const block_id = try makeBlockId(self.allocator, idx);
            errdefer self.allocator.free(block_id);
            try self.putBlockRaw(container, blob, block_id, chunk);
            try block_ids.append(block_id);
            offset = chunk_end;
        }

        try self.putBlockListRaw(container, blob, block_ids.items);
    }

    /// Upload a single block under an uncommitted blob. The `block_id` must be
    /// base64-encoded and the same decoded length as every other block in the blob.
    fn putBlockRaw(
        self: *AzureBlobClient,
        container: []const u8,
        blob: []const u8,
        block_id: []const u8,
        body: []const u8,
    ) AzureError!void {
        const query = try std.fmt.allocPrint(
            self.allocator,
            "comp=block&blockid={s}",
            .{block_id},
        );
        defer self.allocator.free(query);
        const url = try self.buildUrl(container, blob, query);
        defer self.allocator.free(url);

        var date_buf: [48]u8 = undefined;
        const rfc1123_date = formatRfc1123Now(&date_buf);

        var content_length_buf: [20]u8 = undefined;
        const content_length = std.fmt.bufPrint(
            &content_length_buf,
            "{d}",
            .{body.len},
        ) catch return error.OutOfMemory;

        const authorization = self.signBlockUpload(
            rfc1123_date,
            container,
            blob,
            block_id,
            content_length,
        ) catch |err| return mapSignErr(err);
        defer self.allocator.free(authorization);

        const uri = std.Uri.parse(url) catch return error.InvalidResponse;
        var header_buf: [8192]u8 = undefined;
        var req = self.http.open(.PUT, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "x-ms-date", .value = rfc1123_date },
                .{ .name = "x-ms-version", .value = api_version },
                .{ .name = "Authorization", .value = authorization },
            },
        }) catch |err| {
            log.warn("azure PutBlock open failed: {}", .{err});
            return error.ConnectionFailed;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch |err| return httpErr("send", err);
        req.writeAll(body) catch |err| return httpErr("write", err);
        req.finish() catch |err| return httpErr("finish", err);
        req.wait() catch |err| return httpErr("wait", err);

        if (req.response.status != .created and req.response.status != .ok) {
            log.warn(
                "azure PutBlock failed: container={s} blob={s} block_id={s} status={}",
                .{ container, blob, block_id, req.response.status },
            );
            return mapHttpStatus(req.response.status);
        }
    }

    /// Commit an uncommitted block list to form the final blob. Sends an XML body listing
    /// each block ID in upload order under the `<Latest>` element; Azure treats that as
    /// "use the latest uploaded version of this block ID", which for us is exactly the
    /// block we just uploaded.
    fn putBlockListRaw(
        self: *AzureBlobClient,
        container: []const u8,
        blob: []const u8,
        block_ids: []const []u8,
    ) AzureError!void {
        var xml = std.ArrayList(u8).init(self.allocator);
        defer xml.deinit();
        try xml.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>");
        for (block_ids) |id| {
            try xml.appendSlice("<Latest>");
            try xml.appendSlice(id);
            try xml.appendSlice("</Latest>");
        }
        try xml.appendSlice("</BlockList>");

        const query = try self.allocator.dupe(u8, "comp=blocklist");
        defer self.allocator.free(query);
        const url = try self.buildUrl(container, blob, query);
        defer self.allocator.free(url);

        var date_buf: [48]u8 = undefined;
        const rfc1123_date = formatRfc1123Now(&date_buf);

        var content_length_buf: [20]u8 = undefined;
        const content_length = std.fmt.bufPrint(
            &content_length_buf,
            "{d}",
            .{xml.items.len},
        ) catch return error.OutOfMemory;

        const authorization = self.signBlockListCommit(
            rfc1123_date,
            container,
            blob,
            content_length,
        ) catch |err| return mapSignErr(err);
        defer self.allocator.free(authorization);

        const uri = std.Uri.parse(url) catch return error.InvalidResponse;
        var header_buf: [8192]u8 = undefined;
        var req = self.http.open(.PUT, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "x-ms-date", .value = rfc1123_date },
                .{ .name = "x-ms-version", .value = api_version },
                .{ .name = "Authorization", .value = authorization },
            },
        }) catch |err| {
            log.warn("azure PutBlockList open failed: {}", .{err});
            return error.ConnectionFailed;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = xml.items.len };
        req.send() catch |err| return httpErr("send", err);
        req.writeAll(xml.items) catch |err| return httpErr("write", err);
        req.finish() catch |err| return httpErr("finish", err);
        req.wait() catch |err| return httpErr("wait", err);

        if (req.response.status != .created and req.response.status != .ok) {
            log.warn(
                "azure PutBlockList failed: container={s} blob={s} status={}",
                .{ container, blob, req.response.status },
            );
            return mapHttpStatus(req.response.status);
        }
    }

    /// GET a blob. Caller owns the returned slice.
    pub fn getBlob(
        self: *AzureBlobClient,
        container: []const u8,
        blob: []const u8,
    ) AzureError![]u8 {
        const url = try self.buildUrl(container, blob, null);
        defer self.allocator.free(url);

        var date_buf: [48]u8 = undefined;
        const rfc1123_date = formatRfc1123Now(&date_buf);

        const authorization = self.sign(
            .{ .method = "GET", .content_length = "" },
            rfc1123_date,
            container,
            blob,
        ) catch |err| return mapSignErr(err);
        defer self.allocator.free(authorization);

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "x-ms-date", .value = rfc1123_date },
                .{ .name = "x-ms-version", .value = api_version },
                .{ .name = "Authorization", .value = authorization },
            },
            .response_storage = .{ .dynamic = &body },
            .max_append_size = 64 * 1024 * 1024,
        }) catch |err| {
            log.warn("azure GET execute failed: {}", .{err});
            return error.RequestFailed;
        };

        if (result.status != .ok) {
            log.warn(
                "azure GET failed: container={s} blob={s} status={}",
                .{ container, blob, result.status },
            );
            return mapHttpStatus(result.status);
        }
        return body.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// List blobs under a prefix, returning the raw Azure XML response body. Callers
    /// handle parsing (existing restore.zig parser), and pagination via the optional
    /// `marker` argument (NextMarker from the previous page). Caller owns the returned
    /// slice.
    ///
    /// Used by restore code paths that already have an XML parser and need multi-page
    /// listing; the `listBlobs` method is a higher-level convenience for simple cases.
    pub fn listBlobsRaw(
        self: *AzureBlobClient,
        container: []const u8,
        prefix: []const u8,
        marker: ?[]const u8,
    ) AzureError![]u8 {
        // Build the query string. Order on the wire does not matter (server canonicalizes),
        // but SharedKey canonical-resource sorting does — handled in signListBlobs.
        const query_parts = if (marker) |m|
            if (prefix.len > 0)
                try std.fmt.allocPrint(
                    self.allocator,
                    "restype=container&comp=list&prefix={s}&marker={s}",
                    .{ prefix, m },
                )
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "restype=container&comp=list&marker={s}",
                    .{m},
                )
        else if (prefix.len > 0)
            try std.fmt.allocPrint(
                self.allocator,
                "restype=container&comp=list&prefix={s}",
                .{prefix},
            )
        else
            try self.allocator.dupe(u8, "restype=container&comp=list");
        defer self.allocator.free(query_parts);

        const url = try self.buildUrlContainer(container, query_parts);
        defer self.allocator.free(url);

        var date_buf: [48]u8 = undefined;
        const rfc1123_date = formatRfc1123Now(&date_buf);

        const authorization = self.signListBlobsWithMarker(
            rfc1123_date,
            container,
            prefix,
            marker,
        ) catch |err| return mapSignErr(err);
        defer self.allocator.free(authorization);

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "x-ms-date", .value = rfc1123_date },
                .{ .name = "x-ms-version", .value = api_version },
                .{ .name = "Authorization", .value = authorization },
            },
            .response_storage = .{ .dynamic = &body },
            .max_append_size = 16 * 1024 * 1024,
        }) catch |err| {
            log.warn("azure list raw execute failed: {}", .{err});
            return error.RequestFailed;
        };
        if (result.status != .ok) {
            log.warn(
                "azure list raw failed: container={s} prefix={s} status={}",
                .{ container, prefix, result.status },
            );
            return mapHttpStatus(result.status);
        }
        return body.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// List blobs under a prefix. Caller owns both the slice and the per-entry `name`
    /// string. Only returns up to 5000 blobs per call (Azure's default page size); no
    /// pagination is implemented — sufficient for backup-verification use cases.
    pub fn listBlobs(
        self: *AzureBlobClient,
        container: []const u8,
        prefix: []const u8,
    ) AzureError![]ListedBlob {
        // Query: ?restype=container&comp=list&prefix=<prefix>
        const query_parts = if (prefix.len > 0)
            try std.fmt.allocPrint(
                self.allocator,
                "restype=container&comp=list&prefix={s}",
                .{prefix},
            )
        else
            try self.allocator.dupe(u8, "restype=container&comp=list");
        defer self.allocator.free(query_parts);

        const url = try self.buildUrlContainer(container, query_parts);
        defer self.allocator.free(url);

        var date_buf: [48]u8 = undefined;
        const rfc1123_date = formatRfc1123Now(&date_buf);

        const authorization = self.signListBlobs(
            rfc1123_date,
            container,
            prefix,
        ) catch |err| return mapSignErr(err);
        defer self.allocator.free(authorization);

        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "x-ms-date", .value = rfc1123_date },
                .{ .name = "x-ms-version", .value = api_version },
                .{ .name = "Authorization", .value = authorization },
            },
            .response_storage = .{ .dynamic = &body },
            .max_append_size = 16 * 1024 * 1024,
        }) catch |err| {
            log.warn("azure list execute failed: {}", .{err});
            return error.RequestFailed;
        };
        if (result.status != .ok) {
            log.warn(
                "azure list failed: container={s} prefix={s} status={}",
                .{ container, prefix, result.status },
            );
            return mapHttpStatus(result.status);
        }
        return parseListResponse(self.allocator, body.items);
    }

    // -------------------------------------------------------------------------
    // URL and signing helpers
    // -------------------------------------------------------------------------

    fn schemeFor(endpoint: []const u8) []const u8 {
        if (std.mem.startsWith(u8, endpoint, "http://")) return "";
        if (std.mem.startsWith(u8, endpoint, "https://")) return "";
        return "https://";
    }

    fn buildUrl(
        self: *AzureBlobClient,
        container: []const u8,
        blob: []const u8,
        query: ?[]const u8,
    ) AzureError![]u8 {
        const scheme = schemeFor(self.endpoint);
        const path = if (self.use_path_style)
            try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/{s}/{s}", .{
                scheme, self.endpoint, self.account, container, blob,
            })
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/{s}", .{
                scheme, self.endpoint, container, blob,
            });
        if (query) |q| {
            defer self.allocator.free(path);
            return std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ path, q });
        }
        return path;
    }

    fn buildUrlContainer(
        self: *AzureBlobClient,
        container: []const u8,
        query: []const u8,
    ) AzureError![]u8 {
        const scheme = schemeFor(self.endpoint);
        const path = if (self.use_path_style)
            try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/{s}?{s}", .{
                scheme, self.endpoint, self.account, container, query,
            })
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}?{s}", .{
                scheme, self.endpoint, container, query,
            });
        return path;
    }

    const SignParams = struct {
        method: []const u8,
        content_length: []const u8, // empty string for 0/no-body requests
    };

    /// Build the SharedKey Authorization header for a single-blob PUT or GET.
    fn sign(
        self: *AzureBlobClient,
        params: SignParams,
        rfc1123_date: []const u8,
        container: []const u8,
        blob: []const u8,
    ) ![]const u8 {
        // Canonicalized resource. Production Azure (virtual-hosted): `/<account>/<c>/<b>`.
        // Path-style (Azurite / Azure Stack): URL already includes the account, so per the
        // SharedKey spec the canonical form is `/<account>` + `<url_path>` which collapses
        // to `/<account>/<account>/<c>/<b>`. See `createContainer` for the same fix.
        const canonical_resource = if (self.use_path_style)
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}/{s}",
                .{ self.account, self.account, container, blob },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}",
                .{ self.account, container, blob },
            );
        defer self.allocator.free(canonical_resource);

        // Canonicalized headers: lowercase `x-ms-*` sorted by name. For our minimal header
        // set the sort order is always: x-ms-blob-type, x-ms-date, x-ms-version.
        const x_ms_blob_type_line = if (std.mem.eql(u8, params.method, "PUT"))
            "x-ms-blob-type:BlockBlob\n"
        else
            "";
        const canonical_headers = try std.fmt.allocPrint(
            self.allocator,
            "{s}x-ms-date:{s}\nx-ms-version:{s}",
            .{ x_ms_blob_type_line, rfc1123_date, api_version },
        );
        defer self.allocator.free(canonical_headers);

        const string_to_sign = try buildStringToSign(
            self.allocator,
            params.method,
            params.content_length,
            canonical_headers,
            canonical_resource,
        );
        defer self.allocator.free(string_to_sign);

        return self.buildAuthHeader(string_to_sign);
    }

    fn signListBlobsWithMarker(
        self: *AzureBlobClient,
        rfc1123_date: []const u8,
        container: []const u8,
        prefix: []const u8,
        marker: ?[]const u8,
    ) ![]const u8 {
        // Canonicalized resource with four possible query params sorted by name:
        //   comp:list
        //   marker:<m>     (only if present)
        //   prefix:<p>     (only if non-empty)
        //   restype:container
        const path = if (self.use_path_style)
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}",
                .{ self.account, self.account, container },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}",
                .{ self.account, container },
            );
        defer self.allocator.free(path);

        const canonical_resource = build: {
            if (marker) |m| {
                if (prefix.len > 0) {
                    break :build try std.fmt.allocPrint(
                        self.allocator,
                        "{s}\ncomp:list\nmarker:{s}\nprefix:{s}\nrestype:container",
                        .{ path, m, prefix },
                    );
                }
                break :build try std.fmt.allocPrint(
                    self.allocator,
                    "{s}\ncomp:list\nmarker:{s}\nrestype:container",
                    .{ path, m },
                );
            }
            if (prefix.len > 0) {
                break :build try std.fmt.allocPrint(
                    self.allocator,
                    "{s}\ncomp:list\nprefix:{s}\nrestype:container",
                    .{ path, prefix },
                );
            }
            break :build try std.fmt.allocPrint(
                self.allocator,
                "{s}\ncomp:list\nrestype:container",
                .{path},
            );
        };
        defer self.allocator.free(canonical_resource);

        const canonical_headers = try std.fmt.allocPrint(
            self.allocator,
            "x-ms-date:{s}\nx-ms-version:{s}",
            .{ rfc1123_date, api_version },
        );
        defer self.allocator.free(canonical_headers);

        const string_to_sign = try buildStringToSign(
            self.allocator,
            "GET",
            "",
            canonical_headers,
            canonical_resource,
        );
        defer self.allocator.free(string_to_sign);

        return self.buildAuthHeader(string_to_sign);
    }

    /// SharedKey signer for `Put Block` (one block within a multipart upload).
    /// Canonical resource layout for `PUT /<container>/<blob>?comp=block&blockid=<id>`:
    ///   /<account>/<container>/<blob>\nblockid:<id>\ncomp:block
    /// (parameters sorted alphabetically by name; `blockid` < `comp`).
    fn signBlockUpload(
        self: *AzureBlobClient,
        rfc1123_date: []const u8,
        container: []const u8,
        blob: []const u8,
        block_id: []const u8,
        content_length: []const u8,
    ) ![]const u8 {
        const base_path = if (self.use_path_style)
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}/{s}",
                .{ self.account, self.account, container, blob },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}",
                .{ self.account, container, blob },
            );
        defer self.allocator.free(base_path);

        const canonical_resource = try std.fmt.allocPrint(
            self.allocator,
            "{s}\nblockid:{s}\ncomp:block",
            .{ base_path, block_id },
        );
        defer self.allocator.free(canonical_resource);

        const canonical_headers = try std.fmt.allocPrint(
            self.allocator,
            "x-ms-date:{s}\nx-ms-version:{s}",
            .{ rfc1123_date, api_version },
        );
        defer self.allocator.free(canonical_headers);

        const string_to_sign = try buildStringToSign(
            self.allocator,
            "PUT",
            content_length,
            canonical_headers,
            canonical_resource,
        );
        defer self.allocator.free(string_to_sign);

        return self.buildAuthHeader(string_to_sign);
    }

    /// SharedKey signer for `Put Block List` (commit). Canonical resource:
    ///   /<account>/<container>/<blob>\ncomp:blocklist
    fn signBlockListCommit(
        self: *AzureBlobClient,
        rfc1123_date: []const u8,
        container: []const u8,
        blob: []const u8,
        content_length: []const u8,
    ) ![]const u8 {
        const base_path = if (self.use_path_style)
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}/{s}",
                .{ self.account, self.account, container, blob },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}",
                .{ self.account, container, blob },
            );
        defer self.allocator.free(base_path);

        const canonical_resource = try std.fmt.allocPrint(
            self.allocator,
            "{s}\ncomp:blocklist",
            .{base_path},
        );
        defer self.allocator.free(canonical_resource);

        const canonical_headers = try std.fmt.allocPrint(
            self.allocator,
            "x-ms-date:{s}\nx-ms-version:{s}",
            .{ rfc1123_date, api_version },
        );
        defer self.allocator.free(canonical_headers);

        const string_to_sign = try buildStringToSign(
            self.allocator,
            "PUT",
            content_length,
            canonical_headers,
            canonical_resource,
        );
        defer self.allocator.free(string_to_sign);

        return self.buildAuthHeader(string_to_sign);
    }

    fn signListBlobs(
        self: *AzureBlobClient,
        rfc1123_date: []const u8,
        container: []const u8,
        prefix: []const u8,
    ) ![]const u8 {
        // Canonicalized resource for list-blobs. Path prefix is doubled under path-style
        // for the same reason as `sign` / `createContainer` above.
        const path = if (self.use_path_style)
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}/{s}",
                .{ self.account, self.account, container },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "/{s}/{s}",
                .{ self.account, container },
            );
        defer self.allocator.free(path);

        const canonical_resource = if (prefix.len > 0)
            try std.fmt.allocPrint(
                self.allocator,
                "{s}\ncomp:list\nprefix:{s}\nrestype:container",
                .{ path, prefix },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{s}\ncomp:list\nrestype:container",
                .{path},
            );
        defer self.allocator.free(canonical_resource);

        const canonical_headers = try std.fmt.allocPrint(
            self.allocator,
            "x-ms-date:{s}\nx-ms-version:{s}",
            .{ rfc1123_date, api_version },
        );
        defer self.allocator.free(canonical_headers);

        const string_to_sign = try buildStringToSign(
            self.allocator,
            "GET",
            "",
            canonical_headers,
            canonical_resource,
        );
        defer self.allocator.free(string_to_sign);

        return self.buildAuthHeader(string_to_sign);
    }

    fn buildAuthHeader(
        self: *AzureBlobClient,
        string_to_sign: []const u8,
    ) ![]const u8 {
        var mac: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(
            &mac,
            string_to_sign,
            self.account_key[0..self.account_key_len],
        );
        var signature_buf: [64]u8 = undefined;
        const signature_len = std.base64.standard.Encoder.calcSize(mac.len);
        _ = std.base64.standard.Encoder.encode(signature_buf[0..signature_len], &mac);
        return std.fmt.allocPrint(
            self.allocator,
            "SharedKey {s}:{s}",
            .{ self.account, signature_buf[0..signature_len] },
        );
    }
};

/// Build the Azure Blob SharedKey "string to sign" for the given method and canonical
/// parts. Exposed at module scope for focused unit testing against Microsoft's documented
/// example vectors.
/// Generate a deterministic, Azure-compliant block ID from a zero-padded sequence number.
/// Azure requires every block ID within a single blob to be the same decoded length
/// (up to 64 bytes) and base64-encoded on the wire. We hash in a fixed-length decimal
/// index so "block-000001" and "block-050000" occupy the same raw-byte width (18 bytes),
/// satisfying the uniformity rule without a separate configuration knob. Caller owns the
/// returned slice.
fn makeBlockId(allocator: Allocator, index: u32) AzureError![]u8 {
    // 18-byte raw form → 24-byte base64 encoded. Well below Azure's 64-byte cap.
    var raw: [18]u8 = undefined;
    _ = std.fmt.bufPrint(&raw, "block-{d:0>12}", .{index}) catch return error.OutOfMemory;
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const buf = allocator.alloc(u8, encoded_len) catch return error.OutOfMemory;
    _ = std.base64.standard.Encoder.encode(buf, &raw);
    return buf;
}

pub fn buildStringToSign(
    allocator: Allocator,
    method: []const u8,
    content_length: []const u8,
    canonical_headers: []const u8,
    canonical_resource: []const u8,
) ![]u8 {
    // Per Microsoft docs, the string-to-sign has thirteen newline-separated fields, most
    // empty for our usage. `content_length == "0"` is represented as the empty string here
    // (Azure requires "" for zero-body requests, not literal "0").
    const cl = if (std.mem.eql(u8, content_length, "0")) "" else content_length;
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\n\n{s}\n\n\n\n\n\n\n\n\n{s}\n{s}",
        .{ method, cl, canonical_headers, canonical_resource },
    );
}

// -----------------------------------------------------------------------------
// Response parsing
// -----------------------------------------------------------------------------

/// Parse the XML body of a ListBlobs response into a slice of `ListedBlob`. Reads only the
/// `<Name>` and `<Content-Length>` elements. Robust against attribute whitespace and
/// nested fields in `<Properties>`. Caller owns the returned slice and every `name`.
fn parseListResponse(allocator: Allocator, xml: []const u8) AzureError![]ListedBlob {
    var result = std.ArrayList(ListedBlob).init(allocator);
    errdefer {
        for (result.items) |b| allocator.free(b.name);
        result.deinit();
    }

    var idx: usize = 0;
    while (true) {
        // Each blob is delimited by <Blob>...</Blob>. Find the next <Blob> and extract
        // the <Name> and <Content-Length> inside.
        const blob_start_rel = std.mem.indexOfPos(u8, xml, idx, "<Blob>");
        if (blob_start_rel == null) break;
        const blob_open = blob_start_rel.? + "<Blob>".len;
        const blob_close = std.mem.indexOfPos(u8, xml, blob_open, "</Blob>") orelse break;
        const blob_xml = xml[blob_open..blob_close];

        const name = try extractXmlElement(allocator, blob_xml, "Name") orelse {
            idx = blob_close + "</Blob>".len;
            continue;
        };
        errdefer allocator.free(name);

        const len_str_opt = try extractXmlElement(allocator, blob_xml, "Content-Length");
        defer if (len_str_opt) |s| allocator.free(s);

        var size: u64 = 0;
        if (len_str_opt) |len_str| {
            size = std.fmt.parseInt(u64, len_str, 10) catch 0;
        }

        try result.append(.{ .name = name, .size = size });
        idx = blob_close + "</Blob>".len;
    }
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

fn extractXmlElement(
    allocator: Allocator,
    xml: []const u8,
    tag: []const u8,
) AzureError!?[]u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open_tag = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return error.OutOfMemory;
    const close_tag = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return error.OutOfMemory;
    const start = std.mem.indexOf(u8, xml, open_tag) orelse return null;
    const value_start = start + open_tag.len;
    const end = std.mem.indexOfPos(u8, xml, value_start, close_tag) orelse return null;
    return try allocator.dupe(u8, xml[value_start..end]);
}

// -----------------------------------------------------------------------------
// Misc
// -----------------------------------------------------------------------------

fn formatRfc1123Now(buf: *[48]u8) []const u8 {
    // RFC 1123 / RFC 7231 HTTP date: "Sun, 06 Nov 1994 08:49:37 GMT". Azure requires this
    // exact format on the `x-ms-date` header for SharedKey requests.
    const secs: i64 = std.time.timestamp();
    const day_count_i: i64 = @divFloor(secs, std.time.s_per_day);
    const day_count: u47 = @intCast(day_count_i);
    const epoch_day = std.time.epoch.EpochDay{ .day = day_count };
    const day_secs: u32 = @intCast(@mod(secs, std.time.s_per_day));
    const yd = epoch_day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const h: u8 = @intCast(day_secs / 3600);
    const m: u8 = @intCast((day_secs % 3600) / 60);
    const s: u8 = @intCast(day_secs % 60);
    // Jan 1 1970 was a Thursday (index 4 in a Sun=0 week).
    const dow: u8 = @intCast(@mod(@as(u64, day_count) + 4, 7));

    const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    const written = std.fmt.bufPrint(
        buf,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            dow_names[dow],
            md.day_index + 1,
            mon_names[@intFromEnum(md.month) - 1],
            @as(u32, yd.year),
            h,
            m,
            s,
        },
    ) catch "Thu, 01 Jan 1970 00:00:00 GMT";
    return written;
}

fn httpErr(stage: []const u8, err: anyerror) AzureError {
    log.warn("azure HTTP {s} failed: {}", .{ stage, err });
    return error.RequestFailed;
}

fn mapSignErr(err: anyerror) AzureError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidAccountKey,
    };
}

fn mapHttpStatus(status: std.http.Status) AzureError {
    return switch (status) {
        .forbidden => error.AccessDenied,
        .unauthorized => error.AuthenticationFailed,
        .not_found => error.BlobNotFound,
        else => error.UploadFailed,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "buildStringToSign: canonical form for PUT blob" {
    const allocator = std.testing.allocator;
    const canonical_headers =
        "x-ms-blob-type:BlockBlob\nx-ms-date:Tue, 15 Apr 2025 12:00:00 GMT\nx-ms-version:2021-12-02";
    const canonical_resource = "/acct/mycontainer/myblob";
    const sts = try buildStringToSign(
        allocator,
        "PUT",
        "128",
        canonical_headers,
        canonical_resource,
    );
    defer allocator.free(sts);

    // Layout: METHOD \n \n \n CL \n \n \n \n \n \n \n \n \n HEADERS \n RESOURCE
    // Twelve intermediate fields empty except Content-Length (index 3).
    const expected =
        "PUT\n\n\n128\n\n\n\n\n\n\n\n\n" ++
        "x-ms-blob-type:BlockBlob\n" ++
        "x-ms-date:Tue, 15 Apr 2025 12:00:00 GMT\n" ++
        "x-ms-version:2021-12-02\n" ++
        "/acct/mycontainer/myblob";
    try std.testing.expectEqualStrings(expected, sts);
}

test "buildStringToSign: zero content length renders as empty field" {
    const allocator = std.testing.allocator;
    const sts = try buildStringToSign(allocator, "GET", "0", "x-ms-date:d\nx-ms-version:v", "/a/c/b");
    defer allocator.free(sts);
    try std.testing.expect(std.mem.startsWith(u8, sts, "GET\n\n\n\n\n")); // CL field is empty
}

test "AzureBlobClient: init rejects invalid base64 account key" {
    const allocator = std.testing.allocator;
    const result = AzureBlobClient.init(allocator, .{
        .endpoint = "localhost:10000",
        .credentials = .{
            .account = "devstoreaccount1",
            .account_key_base64 = "not@valid@base64",
        },
    });
    try std.testing.expectError(error.InvalidAccountKey, result);
}

test "AzureBlobClient: init accepts a valid base64 account key" {
    const allocator = std.testing.allocator;
    // A 64-byte key base64-encoded produces a 88-char string with no padding ambiguity.
    // Using a synthesized deterministic key keeps the test independent of whichever
    // Azurite release happens to be installed.
    var raw_key: [64]u8 = undefined;
    for (0..64) |i| raw_key[i] = @intCast((i * 7 + 13) % 256);
    var b64_buf: [88]u8 = undefined;
    const encoded_len = std.base64.standard.Encoder.calcSize(raw_key.len);
    try std.testing.expectEqual(@as(usize, 88), encoded_len);
    _ = std.base64.standard.Encoder.encode(b64_buf[0..encoded_len], &raw_key);

    var client = try AzureBlobClient.init(allocator, .{
        .endpoint = "localhost:10000",
        .credentials = .{
            .account = "devstoreaccount1",
            .account_key_base64 = b64_buf[0..encoded_len],
        },
        .use_path_style = true,
    });
    defer client.deinit();
    try std.testing.expectEqualStrings("devstoreaccount1", client.account);
    try std.testing.expectEqual(@as(usize, 64), client.account_key_len);
    try std.testing.expectEqualSlices(u8, &raw_key, client.account_key[0..64]);
}

test "makeBlockId: deterministic, uniform length, valid base64" {
    const allocator = std.testing.allocator;
    const id_a = try makeBlockId(allocator, 0);
    defer allocator.free(id_a);
    const id_b = try makeBlockId(allocator, 1);
    defer allocator.free(id_b);
    const id_z = try makeBlockId(allocator, 50_000);
    defer allocator.free(id_z);

    // All IDs must be the same length (Azure rule).
    try std.testing.expectEqual(id_a.len, id_b.len);
    try std.testing.expectEqual(id_a.len, id_z.len);

    // IDs must round-trip as valid base64.
    var decoded: [32]u8 = undefined;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(id_a) catch unreachable;
    try std.base64.standard.Decoder.decode(decoded[0..decoded_len], id_a);

    // Different indices must yield different IDs (otherwise Put Block List would overwrite).
    try std.testing.expect(!std.mem.eql(u8, id_a, id_b));
    try std.testing.expect(!std.mem.eql(u8, id_a, id_z));
}

test "AzureBlobClient: multipart put+get round-trip against Azurite" {
    // Azurite integration test; skipped when not configured. Uses a lowered multipart
    // threshold so we can exercise Put Block / Put Block List without waiting on a real
    // 100 MiB upload.
    const endpoint = std.posix.getenv("AZURITE_ENDPOINT") orelse return error.SkipZigTest;
    const account = std.posix.getenv("AZURITE_ACCOUNT") orelse "devstoreaccount1";
    const key = std.posix.getenv("AZURITE_ACCOUNT_KEY") orelse return error.SkipZigTest;
    const container = std.posix.getenv("AZURITE_CONTAINER") orelse "archerdb-test-container";

    const allocator = std.testing.allocator;

    var client = try AzureBlobClient.init(allocator, .{
        .endpoint = endpoint,
        .credentials = .{
            .account = account,
            .account_key_base64 = key,
        },
        .use_path_style = true,
        // Force multipart at 64 KiB and 48 KiB per block so the 128 KiB test body
        // splits into three blocks (48 KiB + 48 KiB + 32 KiB) — exercises the multi-
        // block Put Block / Put Block List path including a short tail block.
        .multipart_threshold_override = 64 * 1024,
        .multipart_block_size_override = 48 * 1024,
    });
    defer client.deinit();

    try client.createContainer(container);

    // 128 KiB test body with a recognizable fill pattern so a short read would show up
    // in the assertion comparison.
    const body_size: usize = 128 * 1024;
    const body = try allocator.alloc(u8, body_size);
    defer allocator.free(body);
    for (0..body_size) |i| body[i] = @intCast((i * 37) & 0xFF);

    try client.putBlob(container, "multipart-test.bin", body);

    const downloaded = try client.getBlob(container, "multipart-test.bin");
    defer allocator.free(downloaded);
    try std.testing.expectEqual(body_size, downloaded.len);
    try std.testing.expectEqualSlices(u8, body, downloaded);
}

test "parseListResponse: extracts multiple blobs with sizes" {
    const allocator = std.testing.allocator;
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<EnumerationResults>
        \\  <Blobs>
        \\    <Blob>
        \\      <Name>a/b/c.block</Name>
        \\      <Properties>
        \\        <Content-Length>1024</Content-Length>
        \\      </Properties>
        \\    </Blob>
        \\    <Blob>
        \\      <Name>a/b/c.block.ts</Name>
        \\      <Properties>
        \\        <Content-Length>11</Content-Length>
        \\      </Properties>
        \\    </Blob>
        \\  </Blobs>
        \\</EnumerationResults>
    ;
    const blobs = try parseListResponse(allocator, xml);
    defer {
        for (blobs) |b| allocator.free(b.name);
        allocator.free(blobs);
    }
    try std.testing.expectEqual(@as(usize, 2), blobs.len);
    try std.testing.expectEqualStrings("a/b/c.block", blobs[0].name);
    try std.testing.expectEqual(@as(u64, 1024), blobs[0].size);
    try std.testing.expectEqualStrings("a/b/c.block.ts", blobs[1].name);
    try std.testing.expectEqual(@as(u64, 11), blobs[1].size);
}
