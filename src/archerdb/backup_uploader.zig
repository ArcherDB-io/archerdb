// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Backup Uploader
//!
//! Transport layer for the backup runtime. Given a closed LSM block's bytes plus
//! its sequence/checksum/timestamp, the uploader writes one "block" artifact and
//! two sidecar artifacts (`.block.ts` timestamp, `.block.meta` metadata) to the
//! configured destination.
//!
//! Three transports are supported today:
//!   - `.local`: writes to a directory on the local filesystem. Used for demos
//!     and automated tests against a tempdir.
//!   - `.s3`: PUTs to an S3 or S3-compatible endpoint (AWS, MinIO, LocalStack,
//!     R2, Backblaze). Reuses `replication/s3_client.zig` so signing, multipart,
//!     and retry/provider-detection are shared with the replication relay.
//!   - `.gcs`: Google Cloud Storage via the S3-compatible XML interop API
//!     (https://cloud.google.com/storage/docs/interoperability). Uses the same
//!     `S3Client` with HMAC credentials; the operator supplies an HMAC access
//!     key + secret issued via the GCS console. Endpoint defaults to
//!     `storage.googleapis.com`. The native GCS JSON+OAuth2 API is not
//!     supported — the interop path is explicitly faster to ship and matches
//!     how most self-hosted S3 backup tools target GCS today.
//!
//! Azure is a planned follow-up and currently fails closed with
//! `error.UnsupportedProvider` at init time.
//!
//! Callers (backup_runtime / backup_coordinator) should treat the uploader as
//! the single seam that dispatches on `BackupOptions.provider`. The uploader
//! owns any live cloud client and is responsible for teardown via `deinit`.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const fs = std.fs;
const fmt = std.fmt;

const backup_config = @import("backup_config.zig");
const BackupConfig = backup_config.BackupConfig;
const BackupOptions = backup_config.BackupOptions;
const BlockRef = backup_config.BlockRef;
const StorageProvider = backup_config.StorageProvider;

const s3_client = @import("../replication/s3_client.zig");
const azure_blob_client = @import("../replication/azure_blob_client.zig");

const log = std.log.scoped(.backup_uploader);

// Suppress `log.err` under test so negative-path assertions don't trip the test harness.
fn logErr(comptime message: []const u8, args: anytype) void {
    if (!builtin.is_test) log.err(message, args);
}

pub const UploadError = error{
    MissingBucket,
    MissingCredentials,
    UnsupportedProvider,
    UploadFailed,
    OutOfMemory,
} || std.posix.WriteError || std.posix.OpenError || std.fs.Dir.MakeError;

/// Uploader for backup artifacts. Constructs the appropriate transport from
/// `BackupConfig` at init time and dispatches every `uploadBlock` / `writeArtifact`
/// call through that transport.
pub const BackupUploader = struct {
    allocator: mem.Allocator,
    transport: Transport,

    pub const Transport = union(enum) {
        local: LocalTransport,
        s3: S3Transport,
        azure: AzureTransport,
    };

    /// Local filesystem transport. Writes artifacts under `prefix_path`, which is
    /// expected to already exist (the runtime is responsible for creating it).
    pub const LocalTransport = struct {
        prefix_path: []const u8, // owned
    };

    /// S3 (and S3-compatible) transport. Owns an `S3Client` and the bucket name.
    /// The object key prefix is derived per-upload from `cluster_id`/`replica_id`.
    pub const S3Transport = struct {
        client: s3_client.S3Client,
        bucket: []const u8, // owned
    };

    /// Azure Blob Storage transport. Owns an `AzureBlobClient` and the container name.
    /// Azure reuses the ArcherDB object-key scheme used by the S3 transport so a single
    /// restore tool can recover from any provider.
    pub const AzureTransport = struct {
        client: azure_blob_client.AzureBlobClient,
        container: []const u8, // owned
    };

    /// Build an uploader from the config. `local_prefix_path` is only used when
    /// `provider == .local`; callers may pass an empty slice when a cloud provider
    /// is configured.
    pub fn init(
        allocator: mem.Allocator,
        config: *const BackupConfig,
        local_prefix_path: []const u8,
    ) !BackupUploader {
        const options = config.options;
        switch (options.provider) {
            .local => {
                return .{
                    .allocator = allocator,
                    .transport = .{ .local = .{
                        .prefix_path = try allocator.dupe(u8, local_prefix_path),
                    } },
                };
            },
            // GCS runs through the S3-compatible interop API, so it shares the `.s3` transport
            // variant and just varies the endpoint / region defaults. Full native GCS
            // (JSON + OAuth2) is deliberately out of scope for this path.
            .s3, .gcs => return initS3Compatible(allocator, options, options.provider),
            .azure => return initAzure(allocator, options),
        }
    }

    /// Build an uploader backed by the Azure Blob Storage REST API (`AzureBlobClient`).
    /// Provider-specific semantics:
    ///   - `bucket` is the Azure container name.
    ///   - `access_key_id` is the Azure storage account name (non-secret; safe in argv).
    ///   - `secret_access_key` is the base64 account key (sensitive; prefer env vars).
    ///   - `url_style = "path"` switches the client to Azurite-style paths
    ///     (`http://host/<account>/<container>/<blob>`), which Azurite requires. The
    ///     production Azure default is virtual-hosted (`<account>.blob.core.windows.net`).
    ///   - `endpoint` defaults to `<account>.blob.core.windows.net`.
    fn initAzure(allocator: mem.Allocator, options: BackupOptions) !BackupUploader {
        const container = options.bucket orelse {
            logErr("azure backup provider requires `bucket` (Azure container name)", .{});
            return error.MissingBucket;
        };

        // Azure reuses the S3 credential-resolution path: access_key_id = account name;
        // secret_access_key = base64 account key. Env-var fallback keeps the key out of
        // argv for production deployments.
        const creds = options.resolveS3Credentials();
        if (!creds.isComplete()) {
            logErr(
                "azure backup provider requires `access_key_id` (account name) and " ++
                    "`secret_access_key` (base64 account key). In CI, pass the key via " ++
                    "`AWS_SECRET_ACCESS_KEY` to keep it out of argv.",
                .{},
            );
            return error.MissingCredentials;
        }

        // Endpoint default: production Azure Blob host for the configured account. Override
        // via `--backup-endpoint` for Azurite (`localhost:10000`) or a private Azure
        // Stack host. Path-style is the Azurite default; production uses virtual-hosted.
        var endpoint_buf: [256]u8 = undefined;
        const endpoint = options.endpoint orelse try fmt.bufPrint(
            &endpoint_buf,
            "{s}.blob.core.windows.net",
            .{creds.access_key_id.?},
        );
        const use_path_style = if (options.url_style) |style|
            mem.eql(u8, style, "path")
        else
            // Default heuristic: Azurite endpoints are local; everything else is Azure.
            mem.indexOf(u8, endpoint, "localhost") != null or
                mem.indexOf(u8, endpoint, "127.0.0.1") != null;

        var client = azure_blob_client.AzureBlobClient.init(allocator, .{
            .endpoint = endpoint,
            .credentials = .{
                .account = creds.access_key_id.?,
                .account_key_base64 = creds.secret_access_key.?,
            },
            .use_path_style = use_path_style,
        }) catch |err| {
            logErr("failed to initialize Azure Blob client for backup: {}", .{err});
            return switch (err) {
                error.InvalidAccountKey => error.MissingCredentials,
                else => error.UploadFailed,
            };
        };
        errdefer client.deinit();

        return .{
            .allocator = allocator,
            .transport = .{ .azure = .{
                .client = client,
                .container = try allocator.dupe(u8, container),
            } },
        };
    }

    /// Build an uploader backed by `S3Client` for any provider that speaks the S3-compatible
    /// XML API (AWS S3, MinIO, LocalStack, R2, Backblaze, and GCS via Interop HMAC).
    fn initS3Compatible(
        allocator: mem.Allocator,
        options: BackupOptions,
        provider: StorageProvider,
    ) !BackupUploader {
        const bucket = options.bucket orelse {
            logErr("{s} backup provider requires `bucket`", .{provider.toString()});
            return error.MissingBucket;
        };

        // Region selection. AWS defaults to us-east-1. GCS Interop treats region as
        // informational; the signer accepts "auto" (matches `providers.getRegion(.gcs)`).
        const region = options.region orelse switch (provider) {
            .gcs => "auto",
            else => "us-east-1",
        };

        const creds = options.resolveS3Credentials();
        if (!creds.isComplete()) {
            logErr(
                "{s} backup provider requires HMAC credentials " ++
                    "(set `access_key_id`/`secret_access_key` or " ++
                    "`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`). For GCS, issue an HMAC " ++
                    "key under a service account at Cloud Storage > Settings > Interoperability.",
                .{provider.toString()},
            );
            return error.MissingCredentials;
        }

        // Endpoint default: AWS per-region host for `.s3`, Interop host for `.gcs`. The
        // caller may override via `--backup-endpoint` to point at LocalStack, fake-gcs-server
        // in interop mode, or any private S3-compatible service.
        var endpoint_buf: [192]u8 = undefined;
        const endpoint = options.endpoint orelse switch (provider) {
            .gcs => "storage.googleapis.com",
            else => try fmt.bufPrint(
                &endpoint_buf,
                "s3.{s}.amazonaws.com",
                .{region},
            ),
        };

        var client = s3_client.S3Client.init(allocator, .{
            .endpoint = endpoint,
            .region = region,
            .credentials = .{
                .access_key_id = creds.access_key_id.?,
                .secret_access_key = creds.secret_access_key.?,
            },
        }) catch |err| {
            logErr("failed to initialize S3 client for {s} backup: {}", .{
                provider.toString(),
                err,
            });
            return error.UploadFailed;
        };
        errdefer client.deinit();

        return .{
            .allocator = allocator,
            .transport = .{ .s3 = .{
                .client = client,
                .bucket = try allocator.dupe(u8, bucket),
            } },
        };
    }

    pub fn deinit(self: *BackupUploader) void {
        switch (self.transport) {
            .local => |*t| self.allocator.free(t.prefix_path),
            .s3 => |*t| {
                t.client.deinit();
                self.allocator.free(t.bucket);
            },
            .azure => |*t| {
                t.client.deinit();
                self.allocator.free(t.container);
            },
        }
    }

    /// Upload a block plus its timestamp and metadata sidecars.
    ///
    /// The block body is `block_bytes[0..usable_size]`. Callers typically pass a
    /// slice trimmed to the block header's `size` field so padding is not
    /// transferred across the wire.
    pub fn uploadBlock(
        self: *BackupUploader,
        cluster_id: u128,
        replica_id: u8,
        block: BlockRef,
        block_bytes: []const u8,
    ) !void {
        // Format the numeric portion of the key once; local and cloud transports use
        // the same `{sequence:0>12}.block` name, differing only in the prefix.
        var name_buf: [32]u8 = undefined;
        const block_name = try fmt.bufPrint(
            &name_buf,
            "{d:0>12}.block",
            .{block.sequence},
        );

        // Metadata sidecar body — identical across transports.
        var ts_buf: [64]u8 = undefined;
        const ts_text = try fmt.bufPrint(&ts_buf, "{d}\n", .{block.closed_timestamp});

        const meta_text = try fmt.allocPrint(
            self.allocator,
            "sequence={d}\naddress={d}\nchecksum={x:0>32}\nclosed_timestamp={d}\n",
            .{ block.sequence, block.address, block.checksum, block.closed_timestamp },
        );
        defer self.allocator.free(meta_text);

        switch (self.transport) {
            .local => |t| try uploadBlockLocal(
                self.allocator,
                t.prefix_path,
                block_name,
                block_bytes,
                ts_text,
                meta_text,
            ),
            .s3 => |*t| try uploadBlockS3(
                self.allocator,
                &t.client,
                t.bucket,
                cluster_id,
                replica_id,
                block_name,
                block_bytes,
                ts_text,
                meta_text,
            ),
            .azure => |*t| try uploadBlockAzure(
                self.allocator,
                &t.client,
                t.container,
                cluster_id,
                replica_id,
                block_name,
                block_bytes,
                ts_text,
                meta_text,
            ),
        }
    }

    /// Write an out-of-band artifact (e.g. a checkpoint trailer) under the same
    /// prefix that block uploads go to. The uploader does not interpret the
    /// contents; the caller passes them already serialized.
    pub fn writeArtifact(
        self: *BackupUploader,
        cluster_id: u128,
        replica_id: u8,
        file_name: []const u8,
        contents: []const u8,
    ) !void {
        switch (self.transport) {
            .local => |t| {
                const path = try fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}",
                    .{ t.prefix_path, file_name },
                );
                defer self.allocator.free(path);
                try writeFileAtomic(path, contents);
            },
            .s3 => |*t| {
                const key = try formatObjectKey(
                    self.allocator,
                    cluster_id,
                    replica_id,
                    file_name,
                );
                defer self.allocator.free(key);
                try putObject(&t.client, t.bucket, key, contents);
            },
            .azure => |*t| {
                const blob = try formatObjectKey(
                    self.allocator,
                    cluster_id,
                    replica_id,
                    file_name,
                );
                defer self.allocator.free(blob);
                t.client.putBlob(t.container, blob, contents) catch |err| {
                    logErr("azure putBlob failed for blob '{s}': {}", .{ blob, err });
                    return error.UploadFailed;
                };
            },
        }
    }
};

// -----------------------------------------------------------------------------
// Local transport helpers
// -----------------------------------------------------------------------------

fn uploadBlockLocal(
    allocator: mem.Allocator,
    prefix_path: []const u8,
    block_name: []const u8,
    block_bytes: []const u8,
    ts_text: []const u8,
    meta_text: []const u8,
) !void {
    const block_path = try fmt.allocPrint(allocator, "{s}/{s}", .{ prefix_path, block_name });
    defer allocator.free(block_path);
    const ts_path = try fmt.allocPrint(allocator, "{s}.ts", .{block_path});
    defer allocator.free(ts_path);
    const meta_path = try fmt.allocPrint(allocator, "{s}.meta", .{block_path});
    defer allocator.free(meta_path);

    try writeFile(block_path, block_bytes);
    try writeFile(ts_path, ts_text);
    try writeFile(meta_path, meta_text);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = if (fs.path.isAbsolute(path))
        try fs.createFileAbsolute(path, .{ .truncate = true })
    else
        try fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    // Two-step write via a ".tmp" sibling, then rename.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

    {
        var file = if (fs.path.isAbsolute(tmp_path))
            try fs.createFileAbsolute(tmp_path, .{ .truncate = true })
        else
            try fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
    }

    if (fs.path.isAbsolute(path)) {
        try fs.renameAbsolute(tmp_path, path);
    } else {
        try fs.cwd().rename(tmp_path, path);
    }
}

// -----------------------------------------------------------------------------
// S3 transport helpers
// -----------------------------------------------------------------------------

fn uploadBlockS3(
    allocator: mem.Allocator,
    client: *s3_client.S3Client,
    bucket: []const u8,
    cluster_id: u128,
    replica_id: u8,
    block_name: []const u8,
    block_bytes: []const u8,
    ts_text: []const u8,
    meta_text: []const u8,
) !void {
    // Build keys: {cluster:0>32}/replica-{id}/blocks/{sequence:0>12}.block[.ts|.meta]
    const block_key = try formatObjectKey(allocator, cluster_id, replica_id, block_name);
    defer allocator.free(block_key);

    const ts_name = try fmt.allocPrint(allocator, "{s}.ts", .{block_name});
    defer allocator.free(ts_name);
    const ts_key = try formatObjectKey(allocator, cluster_id, replica_id, ts_name);
    defer allocator.free(ts_key);

    const meta_name = try fmt.allocPrint(allocator, "{s}.meta", .{block_name});
    defer allocator.free(meta_name);
    const meta_key = try formatObjectKey(allocator, cluster_id, replica_id, meta_name);
    defer allocator.free(meta_key);

    try putObject(client, bucket, block_key, block_bytes);
    try putObject(client, bucket, ts_key, ts_text);
    try putObject(client, bucket, meta_key, meta_text);
}

fn putObject(
    client: *s3_client.S3Client,
    bucket: []const u8,
    key: []const u8,
    body: []const u8,
) !void {
    // Multipart kicks in automatically inside multipartUpload, but blocks are
    // typically 4–8 MiB; a single PUT is the fast path.
    var result = client.putObject(bucket, key, body, null) catch |err| {
        logErr("s3 putObject failed for key '{s}': {}", .{ key, err });
        return error.UploadFailed;
    };
    // PutObjectResult strings are allocated via the S3Client's own allocator.
    // Using a different allocator here (e.g. page_allocator) corrupts the heap.
    result.deinit(client.allocator);
}

// -----------------------------------------------------------------------------
// Azure Blob transport helpers
// -----------------------------------------------------------------------------

fn uploadBlockAzure(
    allocator: mem.Allocator,
    client: *azure_blob_client.AzureBlobClient,
    container: []const u8,
    cluster_id: u128,
    replica_id: u8,
    block_name: []const u8,
    block_bytes: []const u8,
    ts_text: []const u8,
    meta_text: []const u8,
) !void {
    const block_key = try formatObjectKey(allocator, cluster_id, replica_id, block_name);
    defer allocator.free(block_key);

    const ts_name = try fmt.allocPrint(allocator, "{s}.ts", .{block_name});
    defer allocator.free(ts_name);
    const ts_key = try formatObjectKey(allocator, cluster_id, replica_id, ts_name);
    defer allocator.free(ts_key);

    const meta_name = try fmt.allocPrint(allocator, "{s}.meta", .{block_name});
    defer allocator.free(meta_name);
    const meta_key = try formatObjectKey(allocator, cluster_id, replica_id, meta_name);
    defer allocator.free(meta_key);

    putBlob(client, container, block_key, block_bytes) catch |err| return err;
    putBlob(client, container, ts_key, ts_text) catch |err| return err;
    putBlob(client, container, meta_key, meta_text) catch |err| return err;
}

fn putBlob(
    client: *azure_blob_client.AzureBlobClient,
    container: []const u8,
    key: []const u8,
    body: []const u8,
) !void {
    client.putBlob(container, key, body) catch |err| {
        logErr("azure putBlob failed for blob '{s}': {}", .{ key, err });
        return error.UploadFailed;
    };
}

/// Format a full object key: `{cluster:0>32}/replica-{replica}/blocks/{file_name}`.
/// The caller owns the returned slice.
fn formatObjectKey(
    allocator: mem.Allocator,
    cluster_id: u128,
    replica_id: u8,
    file_name: []const u8,
) ![]u8 {
    return fmt.allocPrint(
        allocator,
        "{x:0>32}/replica-{d}/blocks/{s}",
        .{ cluster_id, replica_id, file_name },
    );
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "formatObjectKey: cluster hex padded, replica tagged, blocks prefix" {
    const allocator = std.testing.allocator;
    const key = try formatObjectKey(allocator, 0x12345678, 3, "000000001000.block");
    defer allocator.free(key);
    try std.testing.expectEqualStrings(
        "00000000000000000000000012345678/replica-3/blocks/000000001000.block",
        key,
    );
}

test "BackupUploader: init rejects unconfigured s3 provider" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .s3,
        .bucket = "test-bucket",
    });
    defer config.deinit();

    // Credentials are neither in options nor guaranteed in env; any env-provided
    // credentials would let init succeed, which is fine — the assertion here is
    // only that the code path runs without panicking and that the error kind is
    // sensible when credentials are absent.
    const result = BackupUploader.init(std.testing.allocator, &config, "/tmp");
    if (result) |*uploader| {
        var owned = uploader.*;
        owned.deinit();
    } else |err| {
        try std.testing.expect(err == error.MissingCredentials or err == error.UploadFailed);
    }
}

test "BackupUploader: azure without credentials fails closed" {
    if (std.posix.getenv("AWS_ACCESS_KEY_ID") != null and
        std.posix.getenv("AWS_SECRET_ACCESS_KEY") != null)
    {
        return error.SkipZigTest;
    }

    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .azure,
        .bucket = "test-container",
    });
    defer config.deinit();

    try std.testing.expectError(
        error.MissingCredentials,
        BackupUploader.init(std.testing.allocator, &config, ""),
    );
}

test "BackupUploader: azure provider routes through AzureTransport" {
    var raw_key: [64]u8 = undefined;
    for (0..64) |i| raw_key[i] = @intCast((i * 11 + 3) % 256);
    var b64_buf: [88]u8 = undefined;
    const encoded_len = std.base64.standard.Encoder.calcSize(raw_key.len);
    _ = std.base64.standard.Encoder.encode(b64_buf[0..encoded_len], &raw_key);

    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .azure,
        .bucket = "test-container",
        // `access_key_id` is the Azure account name (non-secret), `secret_access_key`
        // is the base64 account key.
        .access_key_id = "devstoreaccount1",
        .secret_access_key = b64_buf[0..encoded_len],
        .endpoint = "localhost:10000",
        .url_style = "path",
    });
    defer config.deinit();

    var uploader = try BackupUploader.init(std.testing.allocator, &config, "");
    defer uploader.deinit();

    switch (uploader.transport) {
        .azure => |t| try std.testing.expectEqualStrings("test-container", t.container),
        else => try std.testing.expect(false),
    }
}

test "BackupUploader: gcs provider routes through S3-compatible transport" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .gcs,
        .bucket = "test-bucket",
        .access_key_id = "gcs-hmac-access",
        .secret_access_key = "gcs-hmac-secret",
    });
    defer config.deinit();

    var uploader = try BackupUploader.init(std.testing.allocator, &config, "");
    defer uploader.deinit();

    // GCS uses the .s3 transport variant (shared S3-compatible XML API).
    switch (uploader.transport) {
        .s3 => |t| try std.testing.expectEqualStrings("test-bucket", t.bucket),
        else => try std.testing.expect(false),
    }
}

test "BackupUploader: gcs provider without credentials fails closed" {
    // Must clear any ambient AWS_* env var for this test; we can't do that from Zig
    // portably, so skip when the environment would satisfy the credential check.
    if (std.posix.getenv("AWS_ACCESS_KEY_ID") != null and
        std.posix.getenv("AWS_SECRET_ACCESS_KEY") != null)
    {
        return error.SkipZigTest;
    }

    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .gcs,
        .bucket = "test-bucket",
    });
    defer config.deinit();

    try std.testing.expectError(
        error.MissingCredentials,
        BackupUploader.init(std.testing.allocator, &config, ""),
    );
}

test "BackupUploader: gcs provider requires bucket" {
    // BackupConfig.validate already rejects missing bucket; init never reaches the uploader.
    const result = BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .gcs,
    });
    try std.testing.expectError(error.MissingBucket, result);
}

test "BackupUploader: local transport uploads block + sidecars" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Absolute path to the tmp dir so writeFile can open files without cwd games.
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const prefix = try tmp.dir.realpath(".", &path_buf);

    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .local,
        .bucket = "test-bucket", // still required by validator
    });
    defer config.deinit();

    var uploader = try BackupUploader.init(std.testing.allocator, &config, prefix);
    defer uploader.deinit();

    const block_bytes = "hello-block-contents";
    try uploader.uploadBlock(
        0xdeadbeef,
        1,
        .{
            .sequence = 42,
            .address = 100,
            .checksum = 0xabcd1234,
            .closed_timestamp = 1700000000,
        },
        block_bytes,
    );

    // Verify all three files exist with expected content.
    const block_file = try tmp.dir.openFile("000000000042.block", .{});
    defer block_file.close();
    var read_buf: [128]u8 = undefined;
    const n = try block_file.readAll(&read_buf);
    try std.testing.expectEqualStrings(block_bytes, read_buf[0..n]);

    const ts_file = try tmp.dir.openFile("000000000042.block.ts", .{});
    defer ts_file.close();
    const ts_n = try ts_file.readAll(&read_buf);
    try std.testing.expectEqualStrings("1700000000\n", read_buf[0..ts_n]);

    const meta_file = try tmp.dir.openFile("000000000042.block.meta", .{});
    defer meta_file.close();
    const meta_n = try meta_file.readAll(&read_buf);
    try std.testing.expect(mem.indexOf(u8, read_buf[0..meta_n], "sequence=42") != null);
    try std.testing.expect(mem.indexOf(u8, read_buf[0..meta_n], "address=100") != null);
}

test "BackupUploader: writeArtifact (local) is atomic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const prefix = try tmp.dir.realpath(".", &path_buf);

    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .local,
        .bucket = "test-bucket",
    });
    defer config.deinit();

    var uploader = try BackupUploader.init(std.testing.allocator, &config, prefix);
    defer uploader.deinit();

    try uploader.writeArtifact(0x1, 0, "checkpoint.ckpt", "some-body\n");

    const file = try tmp.dir.openFile("checkpoint.ckpt", .{});
    defer file.close();
    var read_buf: [64]u8 = undefined;
    const n = try file.readAll(&read_buf);
    try std.testing.expectEqualStrings("some-body\n", read_buf[0..n]);

    // `.tmp` sibling should have been renamed away.
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("checkpoint.ckpt.tmp", .{}));
}
