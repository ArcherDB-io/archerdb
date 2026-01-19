// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Async Log Shipping Module for Multi-Region Replication
//!
//! This module implements asynchronous replication from primary to follower regions
//! as specified in openspec/changes/add-v2-distributed-features/specs/replication/spec.md
//!
//! Key components:
//! - ShipQueue: Memory + disk spillover queue for WAL entries pending shipping
//! - Transport: Pluggable transport layer (Direct TCP, S3 Relay)
//! - ShipCoordinator: Manages shipping to multiple follower regions
//! - FollowerApplicator: Applies received WAL entries on follower nodes
//!
//! The primary region ships committed WAL entries asynchronously to followers,
//! which apply them in commit order to maintain eventual consistency.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const constants = @import("constants.zig");
const log = std.log.scoped(.replication);

// Local constants for replication (mirrors values in repl_constants.zig)
// These are duplicated here to allow standalone testing of this module.
const repl_constants = struct {
    /// Maximum entries to buffer in memory before shipping
    const ship_buffer_max: u32 = 10_000;
    /// Maximum retry attempts for shipping
    const ship_retry_max: u32 = 10;
    /// Initial backoff delay for shipping retries (milliseconds)
    const ship_retry_backoff_initial_ms: u64 = 100;
    /// Maximum backoff delay for shipping retries (milliseconds)
    const ship_retry_backoff_max_ms: u64 = 30_000;
    /// Default interval for async log shipping (milliseconds)
    const async_ship_interval_ms: u64 = 100;
};

/// Role of a node in multi-region deployment
pub const RegionRole = enum(u8) {
    /// Primary region: accepts reads and writes, ships to followers
    primary = 0,
    /// Follower region: read-only, applies entries from primary
    follower = 1,

    pub fn fromString(s: []const u8) ?RegionRole {
        if (std.mem.eql(u8, s, "primary")) return .primary;
        if (std.mem.eql(u8, s, "follower")) return .follower;
        return null;
    }

    pub fn toString(self: RegionRole) []const u8 {
        return switch (self) {
            .primary => "primary",
            .follower => "follower",
        };
    }
};

/// WAL entry format for shipping between regions
/// This wraps the VSR Prepare header with shipping metadata
pub const ShipEntry = extern struct {
    /// Magic bytes for format validation: "SHIP"
    magic: [4]u8 = .{ 'S', 'H', 'I', 'P' },

    /// Format version for future compatibility
    version: u16 = 1,

    /// Reserved for future use
    reserved: u16 = 0,

    /// Operation number (commit order)
    op: u64,

    /// Timestamp when entry was committed (nanoseconds since epoch)
    commit_timestamp_ns: u64,

    /// Size of the WAL entry body following this header
    body_size: u32,

    /// Primary region ID that originated this entry
    primary_region_id: u32,

    /// Checksum of the entire entry (header + body) - 16 bytes
    checksum: u128 = 0,

    /// Padding to align to 64 bytes
    /// Layout: 4 + 2 + 2 + 8 + 8 + 4 + 4 + 16 + 16 = 64
    _padding: [16]u8 = .{0} ** 16,

    pub const size = 64;
    pub const version_current: u16 = 1;

    /// Calculate checksum over header (excluding checksum field) and body
    pub fn calculateChecksum(self: *ShipEntry, body: []const u8) u128 {
        var hasher = std.hash.Wyhash.init(0);

        // Hash header fields (skip checksum)
        hasher.update(&self.magic);
        hasher.update(std.mem.asBytes(&self.version));
        hasher.update(std.mem.asBytes(&self.reserved));
        hasher.update(std.mem.asBytes(&self.op));
        hasher.update(std.mem.asBytes(&self.commit_timestamp_ns));
        hasher.update(std.mem.asBytes(&self.body_size));
        hasher.update(std.mem.asBytes(&self.primary_region_id));

        // Hash body
        hasher.update(body);

        return hasher.final();
    }

    /// Set checksum based on body content
    pub fn setChecksum(self: *ShipEntry, body: []const u8) void {
        self.checksum = self.calculateChecksum(body);
    }

    /// Verify checksum matches
    pub fn validChecksum(self: *ShipEntry, body: []const u8) bool {
        return self.checksum == self.calculateChecksum(body);
    }

    /// Validate magic bytes
    pub fn validMagic(self: *const ShipEntry) bool {
        return std.mem.eql(u8, &self.magic, "SHIP");
    }
};

/// Statistics for the ship queue
pub const ShipQueueStats = struct {
    /// Number of entries currently in memory
    memory_entries: u64 = 0,
    /// Number of entries spilled to disk
    disk_entries: u64 = 0,
    /// Total bytes in memory
    memory_bytes: u64 = 0,
    /// Total bytes on disk
    disk_bytes: u64 = 0,
    /// Highest op number queued
    highest_op: u64 = 0,
    /// Lowest op number queued (oldest unshipped)
    lowest_op: u64 = 0,
    /// Number of entries shipped successfully
    shipped_total: u64 = 0,
    /// Number of ship failures
    ship_failures_total: u64 = 0,

    pub fn depth(self: ShipQueueStats) u64 {
        return self.memory_entries + self.disk_entries;
    }
};

/// Ship queue for buffering WAL entries before sending to followers
/// Implements memory + disk spillover per spec requirements
pub const ShipQueue = struct {
    allocator: Allocator,

    /// In-memory queue (ring buffer)
    memory_queue: std.ArrayList(QueuedEntry),

    /// Maximum entries to hold in memory before spilling to disk
    memory_max: u32,

    /// Path for disk spillover files
    spillover_path: ?[]const u8,

    /// Current statistics
    stats: ShipQueueStats,

    /// Callback when queue exceeds memory limit
    spillover_callback: ?*const fn (*ShipQueue) void,

    const QueuedEntry = struct {
        header: ShipEntry,
        body: []u8,
        queued_at_ns: u64,
        retry_count: u32,
    };

    pub const Config = struct {
        /// Maximum entries in memory (default from constants)
        memory_max: u32 = repl_constants.ship_buffer_max,
        /// Path for disk spillover (null = no spillover, drop on overflow)
        spillover_path: ?[]const u8 = null,
        /// Callback when spillover occurs
        spillover_callback: ?*const fn (*ShipQueue) void = null,
    };

    pub fn init(allocator: Allocator, config: Config) !ShipQueue {
        return ShipQueue{
            .allocator = allocator,
            .memory_queue = std.ArrayList(QueuedEntry).init(allocator),
            .memory_max = config.memory_max,
            .spillover_path = config.spillover_path,
            .stats = .{},
            .spillover_callback = config.spillover_callback,
        };
    }

    pub fn deinit(self: *ShipQueue) void {
        for (self.memory_queue.items) |entry| {
            self.allocator.free(entry.body);
        }
        self.memory_queue.deinit();
    }

    /// Queue a WAL entry for shipping
    pub fn enqueue(
        self: *ShipQueue,
        op: u64,
        commit_timestamp_ns: u64,
        primary_region_id: u32,
        body: []const u8,
    ) !void {
        // Check memory limit
        if (self.memory_queue.items.len >= self.memory_max) {
            if (self.spillover_path != null) {
                // TODO: Implement disk spillover
                try self.spillToDisk();
            } else {
                // No spillover configured, drop oldest entry
                log.warn("Ship queue overflow, dropping oldest entry op={}", .{
                    self.stats.lowest_op,
                });
                if (self.memory_queue.items.len > 0) {
                    const dropped = self.memory_queue.orderedRemove(0);
                    self.allocator.free(dropped.body);
                    self.stats.memory_entries -|= 1;
                    self.stats.memory_bytes -|= dropped.body.len;
                }
            }
        }

        // Create entry
        var header = ShipEntry{
            .op = op,
            .commit_timestamp_ns = commit_timestamp_ns,
            .body_size = @intCast(body.len),
            .primary_region_id = primary_region_id,
        };
        header.setChecksum(body);

        // Copy body
        const body_copy = try self.allocator.dupe(u8, body);

        try self.memory_queue.append(.{
            .header = header,
            .body = body_copy,
            .queued_at_ns = @intCast(std.time.nanoTimestamp()),
            .retry_count = 0,
        });

        // Update stats
        self.stats.memory_entries += 1;
        self.stats.memory_bytes += body.len;
        if (op > self.stats.highest_op) self.stats.highest_op = op;
        if (self.stats.lowest_op == 0 or op < self.stats.lowest_op) {
            self.stats.lowest_op = op;
        }
    }

    /// Dequeue the next entry to ship (FIFO)
    pub fn dequeue(self: *ShipQueue) ?QueuedEntry {
        if (self.memory_queue.items.len == 0) return null;

        const entry = self.memory_queue.orderedRemove(0);
        self.stats.memory_entries -|= 1;
        self.stats.memory_bytes -|= entry.body.len;

        // Update lowest_op
        if (self.memory_queue.items.len > 0) {
            self.stats.lowest_op = self.memory_queue.items[0].header.op;
        } else {
            self.stats.lowest_op = 0;
        }

        return entry;
    }

    /// Peek at the next entry without removing it
    pub fn peek(self: *ShipQueue) ?*const QueuedEntry {
        if (self.memory_queue.items.len == 0) return null;
        return &self.memory_queue.items[0];
    }

    /// Re-queue an entry that failed to ship (for retry)
    pub fn requeue(self: *ShipQueue, entry: QueuedEntry) !void {
        var updated = entry;
        updated.retry_count += 1;

        // Insert at front for immediate retry
        try self.memory_queue.insert(0, updated);
        self.stats.memory_entries += 1;
        self.stats.memory_bytes += entry.body.len;
        self.stats.ship_failures_total += 1;
    }

    /// Mark an entry as successfully shipped
    pub fn markShipped(self: *ShipQueue, entry: QueuedEntry) void {
        self.allocator.free(entry.body);
        self.stats.shipped_total += 1;
    }

    /// Spill oldest entries to disk when memory queue is full
    fn spillToDisk(self: *ShipQueue) !void {
        const path = self.spillover_path orelse return error.NoSpilloverPath;

        // Open spillover file in append mode
        const file = std.fs.cwd().createFile(path, .{
            .truncate = false,
        }) catch |err| {
            log.err("Failed to open spillover file {s}: {}", .{ path, err });
            return error.SpilloverFailed;
        };
        defer file.close();

        // Seek to end for appending
        file.seekFromEnd(0) catch |err| {
            log.err("Failed to seek spillover file: {}", .{err});
            return error.SpilloverFailed;
        };

        // Spill half of memory queue to disk (batch spillover)
        const entries_to_spill = self.memory_queue.items.len / 2;
        if (entries_to_spill == 0) return;

        var spilled: u64 = 0;
        var spilled_bytes: u64 = 0;

        for (0..entries_to_spill) |_| {
            if (self.memory_queue.items.len == 0) break;

            const entry = self.memory_queue.orderedRemove(0);

            // Write entry header (fixed size)
            const header_bytes = std.mem.asBytes(&entry.header);
            file.writeAll(header_bytes) catch |err| {
                log.err("Failed to write spillover header: {}", .{err});
                // Re-queue the entry
                self.memory_queue.insert(0, entry) catch {};
                break;
            };

            // Write body
            file.writeAll(entry.body) catch |err| {
                log.err("Failed to write spillover body: {}", .{err});
                self.memory_queue.insert(0, entry) catch {};
                break;
            };

            // Update stats
            spilled += 1;
            spilled_bytes += entry.body.len;
            self.stats.memory_entries -|= 1;
            self.stats.memory_bytes -|= entry.body.len;
            self.stats.disk_entries += 1;
            self.stats.disk_bytes += entry.body.len;

            // Free the body since it's on disk now
            self.allocator.free(entry.body);
        }

        if (spilled > 0) {
            log.info("Spilled {} entries ({} bytes) to disk", .{ spilled, spilled_bytes });

            // Invoke spillover callback if configured
            if (self.spillover_callback) |callback| {
                callback(self);
            }
        }
    }

    /// Recover entries from disk spillover file back to memory
    pub fn recoverFromDisk(self: *ShipQueue) !u64 {
        const path = self.spillover_path orelse return 0;

        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => {
                log.err("Failed to open spillover file for recovery: {}", .{err});
                return error.RecoveryFailed;
            },
        };
        defer file.close();

        var recovered: u64 = 0;
        var fully_recovered = true;

        while (true) {
            if (self.memory_queue.items.len >= self.memory_max) {
                log.warn("Spillover recovery paused (memory queue full)", .{});
                fully_recovered = false;
                break;
            }

            // Read header
            var header: ShipEntry = undefined;
            const header_bytes = std.mem.asBytes(&header);
            const header_read = file.read(header_bytes) catch break;
            if (header_read < @sizeOf(ShipEntry)) break;

            if (!header.validMagic()) {
                log.warn("Spillover entry has invalid magic, stopping recovery", .{});
                fully_recovered = false;
                break;
            }

            if (header.version != ShipEntry.version_current) {
                log.warn(
                    "Spillover entry has unsupported version {}, stopping recovery",
                    .{header.version},
                );
                fully_recovered = false;
                break;
            }

            if (header.body_size > constants.message_body_size_max) {
                log.warn(
                    "Spillover entry body_size {} exceeds max {}, stopping recovery",
                    .{ header.body_size, constants.message_body_size_max },
                );
                fully_recovered = false;
                break;
            }

            // Allocate and read body
            const body = self.allocator.alloc(u8, header.body_size) catch break;
            errdefer self.allocator.free(body);

            const body_read = file.read(body) catch {
                self.allocator.free(body);
                fully_recovered = false;
                break;
            };
            if (body_read < header.body_size) {
                self.allocator.free(body);
                fully_recovered = false;
                break;
            }

            // Verify checksum
            if (!header.validChecksum(body)) {
                log.warn("Spillover entry failed checksum, skipping op={}", .{header.op});
                self.allocator.free(body);
                continue;
            }

            // Add to memory queue
            self.memory_queue.append(.{
                .header = header,
                .body = body,
                .queued_at_ns = @intCast(std.time.nanoTimestamp()),
                .retry_count = 0,
            }) catch {
                self.allocator.free(body);
                break;
            };

            recovered += 1;
            self.stats.memory_entries += 1;
            self.stats.memory_bytes += body.len;
            self.stats.disk_entries -|= 1;
            self.stats.disk_bytes -|= body.len;
        }

        if (recovered > 0) {
            log.info("Recovered {} entries from disk spillover", .{recovered});

            if (fully_recovered) {
                // Truncate spillover file after successful recovery
                std.fs.cwd().deleteFile(path) catch {};
            }
        }

        return recovered;
    }

    /// Get current queue depth
    pub fn depth(self: *const ShipQueue) u64 {
        return self.stats.depth();
    }

    /// Get current statistics
    pub fn getStats(self: *const ShipQueue) ShipQueueStats {
        return self.stats;
    }
};

/// Transport abstraction for shipping entries to followers
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ship: *const fn (
            ptr: *anyopaque,
            entry: *const ShipEntry,
            body: []const u8,
        ) TransportError!void,
        connect: *const fn (ptr: *anyopaque) TransportError!void,
        disconnect: *const fn (ptr: *anyopaque) void,
        isConnected: *const fn (ptr: *anyopaque) bool,
        getLatencyNs: *const fn (ptr: *anyopaque) u64,
    };

    pub const TransportError = error{
        ConnectionFailed,
        ConnectionClosed,
        Timeout,
        ChecksumMismatch,
        InvalidResponse,
        OutOfMemory,
    };

    pub fn ship(self: Transport, entry: *const ShipEntry, body: []const u8) TransportError!void {
        return self.vtable.ship(self.ptr, entry, body);
    }

    pub fn connect(self: Transport) TransportError!void {
        return self.vtable.connect(self.ptr);
    }

    pub fn disconnect(self: Transport) void {
        return self.vtable.disconnect(self.ptr);
    }

    pub fn isConnected(self: Transport) bool {
        return self.vtable.isConnected(self.ptr);
    }

    pub fn getLatencyNs(self: Transport) u64 {
        return self.vtable.getLatencyNs(self.ptr);
    }
};

/// Direct TCP transport for low-latency replication
///
/// Uses a persistent TCP connection to ship WAL entries directly to follower nodes.
/// Protocol:
/// 1. Connect to follower endpoint
/// 2. Send ShipEntry header (64 bytes)
/// 3. Send body (body_size bytes)
/// 4. Receive ACK (8 bytes: acked_op)
pub const DirectTcpTransport = struct {
    allocator: Allocator,
    endpoint: []const u8,
    port: u16,
    stream: ?std.net.Stream,
    connect_timeout_ms: u32,
    ship_timeout_ms: u32,
    connected: bool,
    last_latency_ns: u64,
    // Statistics
    bytes_sent: u64,
    bytes_received: u64,
    ops_shipped: u64,

    /// Magic bytes for protocol handshake
    const PROTOCOL_MAGIC: [4]u8 = .{ 'A', 'R', 'S', 'H' }; // ArcherDB Ship
    const PROTOCOL_VERSION: u16 = 1;

    pub fn init(allocator: Allocator, endpoint: []const u8, port: u16, config: struct {
        connect_timeout_ms: u32 = 5000,
        ship_timeout_ms: u32 = 30000,
    }) !DirectTcpTransport {
        return DirectTcpTransport{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, endpoint),
            .port = port,
            .stream = null,
            .connect_timeout_ms = config.connect_timeout_ms,
            .ship_timeout_ms = config.ship_timeout_ms,
            .connected = false,
            .last_latency_ns = 0,
            .bytes_sent = 0,
            .bytes_received = 0,
            .ops_shipped = 0,
        };
    }

    pub fn deinit(self: *DirectTcpTransport) void {
        if (self.stream) |*s| {
            s.close();
            self.stream = null;
        }
        self.connected = false;
        self.allocator.free(self.endpoint);
    }

    fn connectImpl(ctx: *anyopaque) Transport.TransportError!void {
        const self: *DirectTcpTransport = @ptrCast(@alignCast(ctx));

        if (self.connected) return;

        // Parse address
        const address = std.net.Address.parseIp4(self.endpoint, self.port) catch {
            // Try resolving hostname
            const list = std.net.getAddressList(self.allocator, self.endpoint, self.port) catch {
                return error.ConnectionFailed;
            };
            defer list.deinit();

            if (list.addrs.len == 0) {
                return error.ConnectionFailed;
            }

            // Try first address
            self.stream = std.net.tcpConnectToAddress(list.addrs[0]) catch {
                return error.ConnectionFailed;
            };
            self.connected = true;
            log.info("Connected to follower at {s}:{d}", .{ self.endpoint, self.port });
            return;
        };

        self.stream = std.net.tcpConnectToAddress(address) catch {
            return error.ConnectionFailed;
        };

        // Send handshake
        var handshake: [8]u8 = undefined;
        stdx.copy_disjoint(.inexact, u8, handshake[0..4], &PROTOCOL_MAGIC);
        std.mem.writeInt(u16, handshake[4..6], PROTOCOL_VERSION, .little);
        std.mem.writeInt(u16, handshake[6..8], 0, .little); // reserved

        _ = self.stream.?.write(&handshake) catch {
            self.stream.?.close();
            self.stream = null;
            return error.ConnectionFailed;
        };

        self.connected = true;
        log.info("Connected to follower at {s}:{d}", .{ self.endpoint, self.port });
    }

    fn disconnectImpl(ctx: *anyopaque) void {
        const self: *DirectTcpTransport = @ptrCast(@alignCast(ctx));
        if (self.stream) |*s| {
            s.close();
            self.stream = null;
        }
        self.connected = false;
    }

    fn isConnectedImpl(ctx: *anyopaque) bool {
        const self: *DirectTcpTransport = @ptrCast(@alignCast(ctx));
        return self.connected and self.stream != null;
    }

    fn shipImpl(
        ctx: *anyopaque,
        entry: *const ShipEntry,
        body: []const u8,
    ) Transport.TransportError!void {
        const self: *DirectTcpTransport = @ptrCast(@alignCast(ctx));

        if (!self.connected or self.stream == null) {
            return error.ConnectionClosed;
        }

        const start_ns = std.time.nanoTimestamp();

        // Send entry header (64 bytes)
        const header_bytes: *const [64]u8 = @ptrCast(entry);
        _ = self.stream.?.write(header_bytes) catch {
            self.connected = false;
            return error.ConnectionClosed;
        };
        self.bytes_sent += 64;

        // Send body
        if (body.len > 0) {
            _ = self.stream.?.write(body) catch {
                self.connected = false;
                return error.ConnectionClosed;
            };
            self.bytes_sent += body.len;
        }

        // Wait for ACK (8 bytes: acked_op)
        var ack_buf: [8]u8 = undefined;
        const bytes_read = self.stream.?.read(&ack_buf) catch {
            self.connected = false;
            return error.ConnectionClosed;
        };

        if (bytes_read != 8) {
            return error.InvalidResponse;
        }

        self.bytes_received += 8;

        const acked_op = std.mem.readInt(u64, &ack_buf, .little);
        if (acked_op != entry.op) {
            log.warn("ACK mismatch: expected op {d}, got {d}", .{ entry.op, acked_op });
            return error.InvalidResponse;
        }

        self.ops_shipped += 1;
        self.last_latency_ns = @intCast(std.time.nanoTimestamp() - start_ns);
    }

    fn getLatencyNsImpl(ctx: *anyopaque) u64 {
        const self: *DirectTcpTransport = @ptrCast(@alignCast(ctx));
        return self.last_latency_ns;
    }

    pub const vtable = Transport.VTable{
        .ship = shipImpl,
        .connect = connectImpl,
        .disconnect = disconnectImpl,
        .isConnected = isConnectedImpl,
        .getLatencyNs = getLatencyNsImpl,
    };

    pub fn transport(self: *DirectTcpTransport) Transport {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// S3 Relay transport for cross-cloud replication
///
/// Ships WAL entries via S3 bucket for scenarios where direct TCP is not feasible
/// (e.g., cross-cloud, firewall restrictions). Provides higher latency but better
/// reliability in heterogeneous environments.
///
/// Protocol:
/// 1. Write ShipEntry + body to S3 object: s3://{bucket}/{prefix}/ship/{op}.wal
/// 2. Follower polls S3 for new entries
/// 3. Follower writes ACK to: s3://{bucket}/{prefix}/ack/{op}.ack
/// 4. Primary reads ACKs to track progress
pub const S3RelayTransport = struct {
    allocator: Allocator,
    bucket: []const u8,
    prefix: []const u8,
    region: []const u8,
    connected: bool,
    last_latency_ns: u64,
    // Statistics
    objects_written: u64,
    bytes_uploaded: u64,

    pub fn init(allocator: Allocator, config: struct {
        bucket: []const u8,
        prefix: []const u8 = "replication",
        region: []const u8 = "us-east-1",
    }) !S3RelayTransport {
        return S3RelayTransport{
            .allocator = allocator,
            .bucket = try allocator.dupe(u8, config.bucket),
            .prefix = try allocator.dupe(u8, config.prefix),
            .region = try allocator.dupe(u8, config.region),
            .connected = false,
            .last_latency_ns = 0,
            .objects_written = 0,
            .bytes_uploaded = 0,
        };
    }

    pub fn deinit(self: *S3RelayTransport) void {
        self.allocator.free(self.bucket);
        self.allocator.free(self.prefix);
        self.allocator.free(self.region);
    }

    fn connectImpl(ctx: *anyopaque) Transport.TransportError!void {
        const self: *S3RelayTransport = @ptrCast(@alignCast(ctx));
        // S3 is stateless - "connect" just validates configuration
        // In a real implementation, this would verify S3 credentials and bucket access
        if (self.bucket.len == 0) {
            return error.ConnectionFailed;
        }
        self.connected = true;
        log.info("S3 Relay transport initialized: s3://{s}/{s}/", .{ self.bucket, self.prefix });
    }

    fn disconnectImpl(ctx: *anyopaque) void {
        const self: *S3RelayTransport = @ptrCast(@alignCast(ctx));
        self.connected = false;
    }

    fn isConnectedImpl(ctx: *anyopaque) bool {
        const self: *S3RelayTransport = @ptrCast(@alignCast(ctx));
        return self.connected;
    }

    fn shipImpl(
        ctx: *anyopaque,
        entry: *const ShipEntry,
        body: []const u8,
    ) Transport.TransportError!void {
        const self: *S3RelayTransport = @ptrCast(@alignCast(ctx));

        if (!self.connected) {
            return error.ConnectionClosed;
        }

        const start_ns = std.time.nanoTimestamp();

        // Build S3 object key: {prefix}/ship/{op}.wal
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(
            &key_buf,
            "{s}/ship/{d:0>20}.wal",
            .{ self.prefix, entry.op },
        ) catch {
            return error.OutOfMemory;
        };

        // Build object content: header (64 bytes) + body
        const total_size = 64 + body.len;
        const content = self.allocator.alloc(u8, total_size) catch {
            return error.OutOfMemory;
        };
        defer self.allocator.free(content);

        const header_bytes: *const [64]u8 = @ptrCast(entry);
        stdx.copy_disjoint(.inexact, u8, content[0..64], header_bytes);
        if (body.len > 0) {
            stdx.copy_disjoint(.inexact, u8, content[64..], body);
        }

        // In a real implementation, this would use AWS SDK to upload to S3
        // For now, we simulate by logging the operation (placeholder)
        // TODO: Implement actual S3 upload using AWS SDK or HTTP API

        log.debug("S3 ship (simulated): op={d}, size={d} to s3://{s}/{s}", .{
            entry.op,
            total_size,
            self.bucket,
            key,
        });

        self.objects_written += 1;
        self.bytes_uploaded += total_size;
        self.last_latency_ns = @intCast(std.time.nanoTimestamp() - start_ns);
    }

    fn getLatencyNsImpl(ctx: *anyopaque) u64 {
        const self: *S3RelayTransport = @ptrCast(@alignCast(ctx));
        return self.last_latency_ns;
    }

    pub const vtable = Transport.VTable{
        .ship = shipImpl,
        .connect = connectImpl,
        .disconnect = disconnectImpl,
        .isConnected = isConnectedImpl,
        .getLatencyNs = getLatencyNsImpl,
    };

    pub fn transport(self: *S3RelayTransport) Transport {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Configuration for a follower region
pub const FollowerConfig = struct {
    /// Unique region identifier
    region_id: u32,
    /// Human-readable region name (e.g., "eu-west-1")
    name: []const u8,
    /// Transport type
    transport_type: TransportType,
    /// Endpoint address for Direct TCP
    endpoint: []const u8 = "",
    /// Port for Direct TCP transport
    port: u16 = 5000,
    /// S3 bucket for S3 Relay transport
    s3_bucket: ?[]const u8 = null,
    /// S3 prefix for S3 Relay transport
    s3_prefix: ?[]const u8 = null,
    /// Connection timeout in milliseconds
    connect_timeout_ms: u32 = 5000,
    /// Ship timeout in milliseconds
    ship_timeout_ms: u32 = 30000,

    pub const TransportType = enum {
        /// Low-latency direct TCP connection
        direct_tcp,
        /// S3-based relay for cross-cloud scenarios
        s3_relay,
    };
};

/// Replication lag metrics for a follower
pub const ReplicationLag = struct {
    /// Highest op shipped to follower
    shipped_op: u64 = 0,
    /// Highest op confirmed by follower
    confirmed_op: u64 = 0,
    /// Lag in number of operations
    lag_ops: u64 = 0,
    /// Estimated lag in nanoseconds
    lag_ns: u64 = 0,
    /// Last successful ship timestamp
    last_ship_ns: u64 = 0,
    /// Ship rate (ops per second)
    ship_rate: f64 = 0,

    pub fn lagSeconds(self: ReplicationLag) f64 {
        return @as(f64, @floatFromInt(self.lag_ns)) / 1_000_000_000.0;
    }
};

/// Ship coordinator manages shipping to multiple follower regions
pub const ShipCoordinator = struct {
    allocator: Allocator,

    /// Queue of entries to ship
    queue: ShipQueue,

    /// Configured follower regions
    followers: std.ArrayList(FollowerState),

    /// Primary region ID
    primary_region_id: u32,

    /// Ship interval in nanoseconds (default: 100ms)
    ship_interval_ns: u64,

    /// Maximum retry attempts before dropping
    max_retries: u32,

    /// Current state
    state: State,

    const FollowerState = struct {
        config: FollowerConfig,
        transport: ?Transport,
        lag: ReplicationLag,
        retry_backoff_ns: u64,
        last_retry_ns: u64,
        consecutive_failures: u32,
    };

    const State = enum {
        idle,
        shipping,
        error_backoff,
    };

    pub const Config = struct {
        primary_region_id: u32,
        ship_interval_ns: u64 = repl_constants.async_ship_interval_ms * std.time.ns_per_ms,
        max_retries: u32 = repl_constants.ship_retry_max,
        queue_config: ShipQueue.Config = .{},
    };

    pub fn init(allocator: Allocator, config: Config) !ShipCoordinator {
        return ShipCoordinator{
            .allocator = allocator,
            .queue = try ShipQueue.init(allocator, config.queue_config),
            .followers = std.ArrayList(FollowerState).init(allocator),
            .primary_region_id = config.primary_region_id,
            .ship_interval_ns = config.ship_interval_ns,
            .max_retries = config.max_retries,
            .state = .idle,
        };
    }

    pub fn deinit(self: *ShipCoordinator) void {
        for (self.followers.items) |*follower| {
            if (follower.transport) |transport| {
                transport.disconnect();
            }
        }
        self.followers.deinit();
        self.queue.deinit();
    }

    /// Add a follower region
    pub fn addFollower(self: *ShipCoordinator, config: FollowerConfig) !void {
        try self.followers.append(.{
            .config = config,
            .transport = null,
            .lag = .{},
            .retry_backoff_ns = repl_constants.ship_retry_backoff_initial_ms * std.time.ns_per_ms,
            .last_retry_ns = 0,
            .consecutive_failures = 0,
        });
        log.info("Added follower region: {} ({})", .{
            config.region_id,
            config.name,
        });
    }

    /// Queue a committed operation for shipping
    pub fn queueCommit(
        self: *ShipCoordinator,
        op: u64,
        commit_timestamp_ns: u64,
        body: []const u8,
    ) !void {
        try self.queue.enqueue(op, commit_timestamp_ns, self.primary_region_id, body);
    }

    /// Ship pending entries to all followers
    /// Called periodically from the main loop
    pub fn tick(self: *ShipCoordinator) !void {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));

        // Process queue for each follower
        for (self.followers.items) |*follower| {
            // Skip if in backoff
            if (follower.consecutive_failures > 0) {
                if (now < follower.last_retry_ns + follower.retry_backoff_ns) {
                    continue;
                }
            }

            // Ensure connected - create transport based on config
            if (follower.transport == null) {
                follower.transport = self.createTransport(follower.config) catch |err| {
                    log.warn("Failed to create transport for region {}: {}", .{
                        follower.config.region_id,
                        err,
                    });
                    follower.consecutive_failures += 1;
                    follower.last_retry_ns = now;
                    continue;
                };

                // Connect the transport
                follower.transport.?.connect() catch |err| {
                    log.warn("Failed to connect to region {}: {}", .{
                        follower.config.region_id,
                        err,
                    });
                    follower.consecutive_failures += 1;
                    follower.last_retry_ns = now;
                    continue;
                };
            }

            // Ship entries
            while (self.queue.peek()) |entry| {
                const transport = follower.transport.?;

                transport.ship(&entry.header, entry.body) catch |err| {
                    log.warn("Ship failed to region {}: {}", .{ follower.config.region_id, err });
                    follower.consecutive_failures += 1;

                    // Exponential backoff with jitter
                    follower.retry_backoff_ns = @min(
                        follower.retry_backoff_ns * 2,
                        repl_constants.ship_retry_backoff_max_ms * std.time.ns_per_ms,
                    );
                    follower.last_retry_ns = now;
                    break;
                };

                // Success
                const dequeued = self.queue.dequeue().?;
                self.queue.markShipped(dequeued);

                follower.lag.shipped_op = entry.header.op;
                follower.lag.last_ship_ns = now;
                follower.consecutive_failures = 0;
                follower.retry_backoff_ns =
                    repl_constants.ship_retry_backoff_initial_ms * std.time.ns_per_ms;
            }
        }
    }

    /// Get replication lag for a follower
    pub fn getLag(self: *ShipCoordinator, region_id: u32) ?ReplicationLag {
        for (self.followers.items) |follower| {
            if (follower.config.region_id == region_id) {
                return follower.lag;
            }
        }
        return null;
    }

    /// Get queue statistics
    pub fn getQueueStats(self: *ShipCoordinator) ShipQueueStats {
        return self.queue.getStats();
    }

    /// Create transport based on follower config
    fn createTransport(self: *ShipCoordinator, config: FollowerConfig) !Transport {
        switch (config.transport_type) {
            .direct_tcp => {
                const tcp = try self.allocator.create(DirectTcpTransport);
                tcp.* = try DirectTcpTransport.init(self.allocator, config.endpoint, config.port, .{
                    .connect_timeout_ms = config.connect_timeout_ms,
                    .ship_timeout_ms = config.ship_timeout_ms,
                });
                return tcp.transport();
            },
            .s3_relay => {
                const s3 = try self.allocator.create(S3RelayTransport);
                s3.* = try S3RelayTransport.init(self.allocator, .{
                    .bucket = config.s3_bucket orelse return error.MissingS3Config,
                    .prefix = config.s3_prefix orelse "replication/",
                    .region = config.name, // Use region name string (e.g., "eu-west-1")
                });
                return s3.transport();
            },
        }
    }
};

/// Follower applicator receives and applies WAL entries from primary
pub const FollowerApplicator = struct {
    allocator: Allocator,

    /// Highest applied operation
    commit_op: u64,

    /// Timestamp of last applied operation
    last_apply_ns: u64,

    /// Primary region we're following
    primary_region_id: u32,

    /// Callback to apply an entry to the state machine
    apply_callback: *const fn (op: u64, body: []const u8) ApplyError!void,

    /// Statistics
    stats: Stats,

    pub const Stats = struct {
        /// Total entries applied
        applied_total: u64 = 0,
        /// Entries skipped (already applied)
        skipped_duplicate: u64 = 0,
        /// Entries rejected (checksum mismatch)
        rejected_checksum: u64 = 0,
        /// Entries rejected (out of order)
        rejected_order: u64 = 0,
    };

    pub const ApplyError = error{
        InvalidEntry,
        ChecksumMismatch,
        OutOfOrder,
        StateMachineError,
    };

    pub fn init(
        allocator: Allocator,
        primary_region_id: u32,
        apply_callback: *const fn (op: u64, body: []const u8) ApplyError!void,
    ) FollowerApplicator {
        return FollowerApplicator{
            .allocator = allocator,
            .commit_op = 0,
            .last_apply_ns = 0,
            .primary_region_id = primary_region_id,
            .apply_callback = apply_callback,
            .stats = .{},
        };
    }

    /// Apply a received entry
    pub fn apply(self: *FollowerApplicator, entry: *ShipEntry, body: []const u8) ApplyError!void {
        // Validate magic
        if (!entry.validMagic()) {
            return error.InvalidEntry;
        }

        // Validate checksum
        if (!entry.validChecksum(body)) {
            self.stats.rejected_checksum += 1;
            return error.ChecksumMismatch;
        }

        // Check for duplicate
        if (entry.op <= self.commit_op) {
            self.stats.skipped_duplicate += 1;
            return; // Already applied, skip
        }

        // Check for gap (out of order)
        if (entry.op != self.commit_op + 1) {
            self.stats.rejected_order += 1;
            log.warn("Out of order entry: expected op={}, got op={}", .{
                self.commit_op + 1,
                entry.op,
            });
            return error.OutOfOrder;
        }

        // Apply to state machine
        try self.apply_callback(entry.op, body);

        // Update state
        self.commit_op = entry.op;
        self.last_apply_ns = @intCast(std.time.nanoTimestamp());
        self.stats.applied_total += 1;
    }

    /// Get current commit operation
    pub fn getCommitOp(self: *const FollowerApplicator) u64 {
        return self.commit_op;
    }

    /// Calculate staleness in nanoseconds
    pub fn getStalenessNs(self: *const FollowerApplicator) u64 {
        const now: u64 = @intCast(std.time.nanoTimestamp());
        if (self.last_apply_ns == 0) return 0;
        return now -| self.last_apply_ns;
    }
};

/// Follower guard for rejecting write operations on follower nodes.
/// This should be checked before processing client requests.
pub const FollowerGuard = struct {
    role: RegionRole,
    /// Commit op from the primary (for staleness tracking)
    primary_commit_op: u64,
    /// Local commit op (what we've applied)
    local_commit_op: u64,
    /// Last time we received an update from primary
    last_update_ns: u64,

    pub fn init(role: RegionRole) FollowerGuard {
        return FollowerGuard{
            .role = role,
            .primary_commit_op = 0,
            .local_commit_op = 0,
            .last_update_ns = 0,
        };
    }

    /// Check if a write operation should be rejected.
    /// Returns the error code if rejected, null if allowed.
    pub fn checkWrite(self: *const FollowerGuard) ?u32 {
        if (self.role == .follower) {
            // Return error code 213: follower_read_only
            return 213;
        }
        return null;
    }

    /// Check if a read operation meets freshness requirements.
    /// Returns the error code if stale, null if fresh enough.
    pub fn checkRead(self: *const FollowerGuard, min_commit_op: ?u64) ?u32 {
        if (self.role != .follower) {
            return null; // Primary always fresh
        }

        if (min_commit_op) |required_op| {
            if (self.local_commit_op < required_op) {
                // Return error code 214: stale_follower
                return 214;
            }
        }
        return null;
    }

    /// Calculate staleness in nanoseconds.
    pub fn getStalenessNs(self: *const FollowerGuard) u64 {
        if (self.role != .follower) return 0;
        const now: u64 = @intCast(std.time.nanoTimestamp());
        return now -| self.last_update_ns;
    }

    /// Calculate lag in operations.
    pub fn getLagOps(self: *const FollowerGuard) u64 {
        return self.primary_commit_op -| self.local_commit_op;
    }

    /// Update follower state after applying an entry.
    pub fn updateLocalCommit(self: *FollowerGuard, op: u64) void {
        self.local_commit_op = op;
        self.last_update_ns = @intCast(std.time.nanoTimestamp());
    }

    /// Update primary commit op (from metadata in shipped entries).
    pub fn updatePrimaryCommit(self: *FollowerGuard, op: u64) void {
        self.primary_commit_op = @max(self.primary_commit_op, op);
    }

    /// Check if this node can accept writes.
    pub fn canWrite(self: *const FollowerGuard) bool {
        return self.role == .primary;
    }

    /// Check if this node is a follower.
    pub fn isFollower(self: *const FollowerGuard) bool {
        return self.role == .follower;
    }
};

/// Response metadata for follower reads.
/// Added to responses when reading from a follower region.
pub const FollowerReadMetadata = extern struct {
    /// Staleness of the read in nanoseconds.
    read_staleness_ns: u64,
    /// Local commit operation number.
    local_commit_op: u64,
    /// Primary commit operation number (if known).
    primary_commit_op: u64,
    /// Reserved for future use.
    _reserved: [8]u8 = .{0} ** 8,

    pub const size = 32;

    comptime {
        if (@sizeOf(FollowerReadMetadata) != size) {
            @compileError("FollowerReadMetadata size mismatch");
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ShipEntry checksum" {
    var entry = ShipEntry{
        .op = 42,
        .commit_timestamp_ns = 1704067200000000000,
        .body_size = 5,
        .primary_region_id = 1,
    };

    const body = "hello";
    entry.setChecksum(body);

    try std.testing.expect(entry.validChecksum(body));
    try std.testing.expect(!entry.validChecksum("world")); // Wrong body
    try std.testing.expect(entry.validMagic());
}

test "ShipEntry magic validation" {
    var valid_entry = ShipEntry{
        .op = 1,
        .commit_timestamp_ns = 0,
        .body_size = 0,
        .primary_region_id = 1,
    };
    try std.testing.expect(valid_entry.validMagic());

    var invalid_entry = valid_entry;
    invalid_entry.magic = .{ 'X', 'X', 'X', 'X' };
    try std.testing.expect(!invalid_entry.validMagic());
}

test "ShipQueue basic operations" {
    const allocator = std.testing.allocator;

    var queue = try ShipQueue.init(allocator, .{ .memory_max = 100 });
    defer queue.deinit();

    // Enqueue entries
    try queue.enqueue(1, 1000, 1, "body1");
    try queue.enqueue(2, 2000, 1, "body2");
    try queue.enqueue(3, 3000, 1, "body3");

    try std.testing.expectEqual(@as(u64, 3), queue.depth());
    try std.testing.expectEqual(@as(u64, 1), queue.stats.lowest_op);
    try std.testing.expectEqual(@as(u64, 3), queue.stats.highest_op);

    // Dequeue in FIFO order
    const entry1 = queue.dequeue().?;
    try std.testing.expectEqual(@as(u64, 1), entry1.header.op);
    queue.markShipped(entry1);

    const entry2 = queue.dequeue().?;
    try std.testing.expectEqual(@as(u64, 2), entry2.header.op);
    queue.markShipped(entry2);

    try std.testing.expectEqual(@as(u64, 1), queue.depth());
    try std.testing.expectEqual(@as(u64, 2), queue.stats.shipped_total);
}

test "ShipQueue overflow without spillover" {
    const allocator = std.testing.allocator;

    var queue = try ShipQueue.init(allocator, .{
        .memory_max = 3,
        .spillover_path = null, // No spillover
    });
    defer queue.deinit();

    // Fill queue
    try queue.enqueue(1, 1000, 1, "body1");
    try queue.enqueue(2, 2000, 1, "body2");
    try queue.enqueue(3, 3000, 1, "body3");

    // This should drop oldest entry
    try queue.enqueue(4, 4000, 1, "body4");

    try std.testing.expectEqual(@as(u64, 3), queue.depth());

    // Verify oldest was dropped
    const entry = queue.peek().?;
    try std.testing.expectEqual(@as(u64, 2), entry.header.op);
}

test "ShipQueue recoverFromDisk loads valid entries" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const spill_path = try std.fs.path.join(allocator, &.{ tmp_path, "spillover.bin" });
    defer allocator.free(spill_path);

    // Write a valid spillover entry.
    const body = "hello";
    var entry = ShipEntry{
        .op = 7,
        .commit_timestamp_ns = 1234,
        .body_size = body.len,
        .primary_region_id = 1,
    };
    entry.setChecksum(body);

    var spill_file = try std.fs.cwd().createFile(spill_path, .{ .truncate = true });
    defer spill_file.close();
    try spill_file.writeAll(std.mem.asBytes(&entry));
    try spill_file.writeAll(body);

    var queue = try ShipQueue.init(allocator, .{
        .memory_max = 1,
        .spillover_path = spill_path,
    });
    defer queue.deinit();

    const recovered = try queue.recoverFromDisk();
    try std.testing.expectEqual(@as(u64, 1), recovered);
    try std.testing.expectEqual(@as(u64, 1), queue.depth());

    const dequeued = queue.dequeue().?;
    defer queue.markShipped(dequeued);
    try std.testing.expectEqual(@as(u64, 7), dequeued.header.op);
    try std.testing.expectEqualStrings(body, dequeued.body);
}

test "ShipQueue recoverFromDisk rejects invalid headers" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const spill_path = try std.fs.path.join(allocator, &.{ tmp_path, "spillover.bin" });
    defer allocator.free(spill_path);

    var entry = ShipEntry{
        .op = 1,
        .commit_timestamp_ns = 1,
        .body_size = 0,
        .primary_region_id = 1,
    };
    entry.magic = .{ 'B', 'A', 'D', '!' };

    var spill_file = try std.fs.cwd().createFile(spill_path, .{ .truncate = true });
    defer spill_file.close();
    try spill_file.writeAll(std.mem.asBytes(&entry));

    var queue = try ShipQueue.init(allocator, .{
        .memory_max = 1,
        .spillover_path = spill_path,
    });
    defer queue.deinit();

    const recovered = try queue.recoverFromDisk();
    try std.testing.expectEqual(@as(u64, 0), recovered);
    try std.testing.expectEqual(@as(u64, 0), queue.depth());
}

test "ShipQueue recoverFromDisk respects memory limit" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const spill_path = try std.fs.path.join(allocator, &.{ tmp_path, "spillover.bin" });
    defer allocator.free(spill_path);

    const body = "hello";
    var entry = ShipEntry{
        .op = 1,
        .commit_timestamp_ns = 1234,
        .body_size = body.len,
        .primary_region_id = 1,
    };
    entry.setChecksum(body);

    var spill_file = try std.fs.cwd().createFile(spill_path, .{ .truncate = true });
    defer spill_file.close();
    try spill_file.writeAll(std.mem.asBytes(&entry));
    try spill_file.writeAll(body);

    entry.op = 2;
    entry.setChecksum(body);
    try spill_file.writeAll(std.mem.asBytes(&entry));
    try spill_file.writeAll(body);

    var queue = try ShipQueue.init(allocator, .{
        .memory_max = 1,
        .spillover_path = spill_path,
    });
    defer queue.deinit();

    const recovered = try queue.recoverFromDisk();
    try std.testing.expectEqual(@as(u64, 1), recovered);
    try std.testing.expectEqual(@as(u64, 1), queue.depth());

    _ = std.fs.cwd().statFile(spill_path) catch |err| {
        return err;
    };
}

test "RegionRole parsing" {
    try std.testing.expectEqual(RegionRole.primary, RegionRole.fromString("primary").?);
    try std.testing.expectEqual(RegionRole.follower, RegionRole.fromString("follower").?);
    try std.testing.expect(RegionRole.fromString("invalid") == null);
}

test "FollowerApplicator apply in order" {
    const allocator = std.testing.allocator;

    var applied_ops = std.ArrayList(u64).init(allocator);
    defer applied_ops.deinit();

    const ApplyFn = struct {
        fn apply(op: u64, _: []const u8) FollowerApplicator.ApplyError!void {
            // Can't access applied_ops from here in test, just validate
            _ = op;
        }
    };

    var applicator = FollowerApplicator.init(allocator, 1, ApplyFn.apply);

    // Apply entries in order
    var entry1 = ShipEntry{
        .op = 1,
        .commit_timestamp_ns = 1000,
        .body_size = 4,
        .primary_region_id = 1,
    };
    entry1.setChecksum("test");
    try applicator.apply(&entry1, "test");

    var entry2 = ShipEntry{
        .op = 2,
        .commit_timestamp_ns = 2000,
        .body_size = 4,
        .primary_region_id = 1,
    };
    entry2.setChecksum("test");
    try applicator.apply(&entry2, "test");

    try std.testing.expectEqual(@as(u64, 2), applicator.getCommitOp());
    try std.testing.expectEqual(@as(u64, 2), applicator.stats.applied_total);
}

test "FollowerApplicator reject out of order" {
    const allocator = std.testing.allocator;

    const ApplyFn = struct {
        fn apply(_: u64, _: []const u8) FollowerApplicator.ApplyError!void {}
    };

    var applicator = FollowerApplicator.init(allocator, 1, ApplyFn.apply);

    // Apply op 1
    var entry1 = ShipEntry{
        .op = 1,
        .commit_timestamp_ns = 1000,
        .body_size = 4,
        .primary_region_id = 1,
    };
    entry1.setChecksum("test");
    try applicator.apply(&entry1, "test");

    // Try to apply op 3 (skip op 2)
    var entry3 = ShipEntry{
        .op = 3,
        .commit_timestamp_ns = 3000,
        .body_size = 4,
        .primary_region_id = 1,
    };
    entry3.setChecksum("test");

    try std.testing.expectError(error.OutOfOrder, applicator.apply(&entry3, "test"));
    try std.testing.expectEqual(@as(u64, 1), applicator.stats.rejected_order);
}

test "FollowerGuard write rejection" {
    // Primary allows writes
    const primary_guard = FollowerGuard.init(.primary);
    try std.testing.expect(primary_guard.checkWrite() == null);
    try std.testing.expect(primary_guard.canWrite());
    try std.testing.expect(!primary_guard.isFollower());

    // Follower rejects writes
    const follower_guard = FollowerGuard.init(.follower);
    try std.testing.expectEqual(@as(u32, 213), follower_guard.checkWrite().?);
    try std.testing.expect(!follower_guard.canWrite());
    try std.testing.expect(follower_guard.isFollower());
}

test "FollowerGuard read freshness" {
    var guard = FollowerGuard.init(.follower);
    guard.local_commit_op = 100;
    guard.primary_commit_op = 150;

    // Read without freshness requirement - allowed
    try std.testing.expect(guard.checkRead(null) == null);

    // Read with satisfied freshness requirement
    try std.testing.expect(guard.checkRead(50) == null);
    try std.testing.expect(guard.checkRead(100) == null);

    // Read with unsatisfied freshness requirement
    try std.testing.expectEqual(@as(u32, 214), guard.checkRead(101).?);
    try std.testing.expectEqual(@as(u32, 214), guard.checkRead(150).?);

    // Lag calculation
    try std.testing.expectEqual(@as(u64, 50), guard.getLagOps());
}

test "FollowerGuard state updates" {
    var guard = FollowerGuard.init(.follower);

    // Initial state
    try std.testing.expectEqual(@as(u64, 0), guard.local_commit_op);
    try std.testing.expectEqual(@as(u64, 0), guard.primary_commit_op);

    // Update local commit
    guard.updateLocalCommit(42);
    try std.testing.expectEqual(@as(u64, 42), guard.local_commit_op);
    try std.testing.expect(guard.last_update_ns > 0);

    // Update primary commit
    guard.updatePrimaryCommit(100);
    try std.testing.expectEqual(@as(u64, 100), guard.primary_commit_op);

    // Primary commit should only increase
    guard.updatePrimaryCommit(50);
    try std.testing.expectEqual(@as(u64, 100), guard.primary_commit_op);
}

test "FollowerReadMetadata size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(FollowerReadMetadata));
}

test "DirectTcpTransport initialization" {
    const allocator = std.testing.allocator;
    var transport_obj = try DirectTcpTransport.init(allocator, "127.0.0.1", 5000, .{});
    defer transport_obj.deinit();

    try std.testing.expectEqualStrings("127.0.0.1", transport_obj.endpoint);
    try std.testing.expectEqual(@as(u16, 5000), transport_obj.port);
    try std.testing.expect(!transport_obj.connected);
    try std.testing.expect(transport_obj.stream == null);

    // Test transport interface
    const t = transport_obj.transport();
    try std.testing.expect(!t.isConnected());
}

test "S3RelayTransport initialization" {
    const allocator = std.testing.allocator;
    var transport_obj = try S3RelayTransport.init(allocator, .{
        .bucket = "my-replication-bucket",
        .prefix = "prod/replication",
        .region = "eu-west-1",
    });
    defer transport_obj.deinit();

    try std.testing.expectEqualStrings("my-replication-bucket", transport_obj.bucket);
    try std.testing.expectEqualStrings("prod/replication", transport_obj.prefix);
    try std.testing.expectEqualStrings("eu-west-1", transport_obj.region);
    try std.testing.expect(!transport_obj.connected);
}

test "S3RelayTransport connect and disconnect" {
    const allocator = std.testing.allocator;
    var transport_obj = try S3RelayTransport.init(allocator, .{
        .bucket = "test-bucket",
    });
    defer transport_obj.deinit();

    const t = transport_obj.transport();

    // Not connected initially
    try std.testing.expect(!t.isConnected());

    // Connect
    try t.connect();
    try std.testing.expect(t.isConnected());

    // Disconnect
    t.disconnect();
    try std.testing.expect(!t.isConnected());
}

test "S3RelayTransport ship simulated" {
    const allocator = std.testing.allocator;
    var transport_obj = try S3RelayTransport.init(allocator, .{
        .bucket = "test-bucket",
        .prefix = "test",
    });
    defer transport_obj.deinit();

    const t = transport_obj.transport();
    try t.connect();

    // Create test entry
    var entry = ShipEntry{
        .op = 42,
        .commit_timestamp_ns = 1000000000,
        .body_size = 5,
        .primary_region_id = 1,
    };
    entry.checksum = entry.calculateChecksum("HELLO");

    // Ship should succeed (simulated)
    try t.ship(&entry, "HELLO");

    // Check stats
    try std.testing.expectEqual(@as(u64, 1), transport_obj.objects_written);
    try std.testing.expectEqual(@as(u64, 69), transport_obj.bytes_uploaded); // 64 + 5
}
