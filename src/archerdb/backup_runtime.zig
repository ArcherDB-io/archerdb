// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
const log = std.log.scoped(.backup_runtime);

const vsr = @import("vsr");
const constants = vsr.constants;
const archerdb_metrics = vsr.archerdb_metrics;

const backup_config = vsr.backup_config;
const backup_queue = vsr.backup_queue;
const backup_coordinator = vsr.backup_coordinator;
const backup_state = vsr.backup_state;
const schema = vsr.lsm.schema;
const checkpoint_artifact = vsr.checkpoint_artifact;

const BackupConfig = backup_config.BackupConfig;
const BackupOptions = backup_config.BackupOptions;
const BackupQueue = backup_queue.BackupQueue;
const BackupCoordinator = backup_coordinator.BackupCoordinator;
const BackupStateManager = backup_state.BackupStateManager;
const BlockRef = backup_config.BlockRef;

fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.err(fmt, args);
    }
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.warn(fmt, args);
    }
}

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.info(fmt, args);
    }
}

pub const BackupRuntime = struct {
    allocator: mem.Allocator,
    config: BackupConfig,
    queue: BackupQueue,
    coordinator: BackupCoordinator,
    state_manager: BackupStateManager,
    known_blocks: std.AutoHashMap(BlockIdentity, void),
    captured_checkpoint_blocks: std.ArrayList(BufferedCheckpointBlock),
    pending_checkpoint_artifacts: std.ArrayList(checkpoint_artifact.DurableCheckpointArtifact),
    local_prefix_path: []u8,
    next_sequence: u64,
    pending_scan: bool = true,
    scan_retry_deadline_ns: i128 = 0,
    scan_retry_attempts: u8 = 0,
    last_checkpoint_timestamp: i64 = 0,
    checkpoint_events_seen: u64 = 0,
    scans_completed: u64 = 0,
    blocks_enqueued_total: u64 = 0,

    const BlockIdentity = struct {
        address: u64,
        checksum: u128,
    };

    const BufferedCheckpointBlock = struct {
        identity: BlockIdentity,
        bytes: []u8,
    };

    const LocalMetadata = struct {
        sequence: u64,
        address: u64,
        checksum: u128,
        closed_timestamp: i64,
    };

    const BlockBuffer = [constants.block_size]u8;

    pub const InitOptions = struct {
        data_file_path: []const u8,
        cluster_id: u128,
        replica_id: u8,
        replica_count: u8,
        initial_view: u32,
        backup_options: BackupOptions,
    };

    pub fn init(allocator: mem.Allocator, options: InitOptions) !BackupRuntime {
        var config = try BackupConfig.init(allocator, options.backup_options);
        errdefer config.deinit();

        if (!config.isEnabled()) return error.BackupDisabled;
        if (config.options.provider != .local) return error.UnsupportedBackupProvider;
        if (config.options.mode == .mandatory) {
            return error.UnsupportedBackupMode;
        }
        if (config.options.compression != .none) {
            return error.UnsupportedBackupCompression;
        }

        const state_dir = fs.path.dirname(options.data_file_path) orelse ".";
        var state_manager = try BackupStateManager.init(allocator, .{
            .data_dir = state_dir,
            .cluster_id = options.cluster_id,
            .replica_id = options.replica_id,
        });
        errdefer state_manager.deinit();

        var queue = BackupQueue.init(allocator, .{
            .mode = config.options.mode,
            .soft_limit = config.options.queue_soft_limit,
            .hard_limit = config.options.queue_hard_limit,
            .mandatory_halt_timeout_secs = config.options.mandatory_halt_timeout_secs,
        });
        errdefer queue.deinit();

        const follower_only = if (options.replica_count == 1)
            false
        else
            !options.backup_options.primary_only;
        const coordinator = BackupCoordinator.init(.{
            .primary_only = options.backup_options.primary_only and options.replica_count > 1,
            .follower_only = follower_only,
            .replica_count = options.replica_count,
            .replica_id = options.replica_id,
            .initial_view = options.initial_view,
        });

        const local_prefix_path = try buildLocalPrefixPath(
            allocator,
            config.options.bucket.?,
            options.cluster_id,
            options.replica_id,
        );
        errdefer allocator.free(local_prefix_path);

        try makePath(local_prefix_path);

        var self = BackupRuntime{
            .allocator = allocator,
            .config = config,
            .queue = queue,
            .coordinator = coordinator,
            .state_manager = state_manager,
            .known_blocks = std.AutoHashMap(BlockIdentity, void).init(allocator),
            .captured_checkpoint_blocks = std.ArrayList(BufferedCheckpointBlock).init(allocator),
            .pending_checkpoint_artifacts = std.ArrayList(
                checkpoint_artifact.DurableCheckpointArtifact,
            ).init(allocator),
            .local_prefix_path = local_prefix_path,
            .next_sequence = 1,
            .last_checkpoint_timestamp = std.time.timestamp(),
        };
        errdefer {
            self.pending_checkpoint_artifacts.deinit();
            self.captured_checkpoint_blocks.deinit();
            self.known_blocks.deinit();
        }

        const state = self.state_manager.getState();
        var last_sequence = state.last_uploaded_sequence;
        var last_timestamp = state.last_upload_timestamp;
        try self.loadExistingLocalMetadata(&last_sequence, &last_timestamp);
        self.coordinator.setIncrementalState(last_sequence, last_timestamp);
        self.next_sequence = last_sequence + 1;

        if (self.config.options.encryption != .none) {
            logWarn(
                "backup provider=local ignores server-side encryption setting ({s})",
                .{self.config.options.encryption.toString()},
            );
        }

        self.updateMetrics();
        return self;
    }

    pub fn deinit(self: *BackupRuntime) void {
        self.state_manager.persist() catch {};
        self.allocator.free(self.local_prefix_path);
        self.clearCapturedCheckpointBlocks();
        self.captured_checkpoint_blocks.deinit();
        self.pending_checkpoint_artifacts.deinit();
        self.known_blocks.deinit();
        self.state_manager.deinit();
        self.queue.deinit();
        self.config.deinit();
    }

    pub fn captureCheckpoint(self: *BackupRuntime, replica: anytype) !void {
        self.clearCapturedCheckpointBlocks();
        try self.captureCheckpointTrailerBlocks(
            "free_set_acquired",
            &replica.grid.free_set_checkpoint_blocks_acquired,
        );
        try self.captureCheckpointTrailerBlocks(
            "free_set_released",
            &replica.grid.free_set_checkpoint_blocks_released,
        );
        try self.captureCheckpointTrailerBlocks(
            "client_sessions",
            &replica.client_sessions_checkpoint,
        );

        self.checkpoint_events_seen += 1;
        self.pending_scan = true;
        self.scan_retry_deadline_ns = 0;
        self.scan_retry_attempts = 0;
        self.last_checkpoint_timestamp = std.time.timestamp();
        logInfo(
            "checkpoint captured (events_seen={} known_blocks={} pending={} captured_blocks={})",
            .{
                self.checkpoint_events_seen,
                self.known_blocks.count(),
                self.queue.getStats().pending_count,
                self.captured_checkpoint_blocks.items.len,
            },
        );
    }

    pub fn tick(self: *BackupRuntime, replica: anytype, storage: anytype) void {
        if (replica.view != self.coordinator.view) {
            self.coordinator.onViewChange(replica.view);
        }

        if (self.pending_scan and
            self.coordinator.shouldBackup() and
            std.time.nanoTimestamp() >= self.scan_retry_deadline_ns)
        {
            self.scanDurableBlocks(replica, storage) catch |err| {
                if (self.transientScanError(err) and self.scan_retry_attempts < 5) {
                    self.scan_retry_attempts += 1;
                    self.scan_retry_deadline_ns = std.time.nanoTimestamp() +
                        std.time.ns_per_s;
                    logWarn(
                        "backup scan transient failure (attempt={} err={}), retrying",
                        .{ self.scan_retry_attempts, err },
                    );
                } else {
                    logErr("backup scan failed: {}", .{err});
                    // Avoid a tight retry loop on persistent scan failures; the next checkpoint
                    // capture will trigger a fresh scan attempt.
                    self.pending_scan = false;
                }
            };
        }

        if (self.coordinator.shouldBackup()) {
            self.processQueue(replica, storage.fd) catch |err| {
                logErr("backup upload loop failed: {}", .{err});
            };
        }

        self.flushCompletedCheckpointArtifacts() catch |err| {
            logErr("checkpoint artifact flush failed: {}", .{err});
        };

        self.updateMetrics();
    }

    fn scanDurableBlocks(self: *BackupRuntime, replica: anytype, storage: anytype) !void {
        const queue_before = self.queue.getStats().pending_count;
        const known_before = self.known_blocks.count();
        const sequence_min = self.next_sequence;
        const scan_timestamp = if (self.last_checkpoint_timestamp > 0)
            self.last_checkpoint_timestamp
        else
            std.time.timestamp();

        try self.walkTrailerChain(
            replica,
            storage.fd,
            replica.superblock.working.free_set_reference(.blocks_acquired),
            .free_set,
            scan_timestamp,
        );
        try self.walkTrailerChain(
            replica,
            storage.fd,
            replica.superblock.working.free_set_reference(.blocks_released),
            .free_set,
            scan_timestamp,
        );
        try self.walkTrailerChain(
            replica,
            storage.fd,
            replica.superblock.working.client_sessions_reference(),
            .client_sessions,
            scan_timestamp,
        );
        try self.walkManifestCheckpoint(
            storage.fd,
            replica.superblock.working.manifest_references(),
            scan_timestamp,
        );

        const sequence_max = self.next_sequence -| 1;
        const block_count = if (sequence_max >= sequence_min)
            sequence_max - sequence_min + 1
        else
            0;
        const artifact_sequence_min = if (block_count == 0) sequence_max else sequence_min;
        try self.pending_checkpoint_artifacts.append(
            checkpoint_artifact.DurableCheckpointArtifact.fromWorkingHeader(
                replica.superblock.working,
                replica.replica,
                artifact_sequence_min,
                sequence_max,
                block_count,
                scan_timestamp,
            ),
        );

        self.pending_scan = false;
        self.scan_retry_deadline_ns = 0;
        self.scan_retry_attempts = 0;
        self.scans_completed += 1;
        logInfo(
            "durable scan complete (scan={} op_checkpoint={} queue={}=>{} known={}=>{} enqueued_total={})",
            .{
                self.scans_completed,
                replica.superblock.working.vsr_state.checkpoint.header.op,
                queue_before,
                self.queue.getStats().pending_count,
                known_before,
                self.known_blocks.count(),
                self.blocks_enqueued_total,
            },
        );
    }

    fn walkTrailerChain(
        self: *BackupRuntime,
        replica: anytype,
        fd: std.posix.fd_t,
        reference: vsr.SuperBlockTrailerReference,
        expected_type: schema.BlockType,
        closed_timestamp: i64,
    ) !void {
        if (reference.empty()) return;

        var block_reference: ?vsr.BlockReference = .{
            .address = reference.last_block_address,
            .checksum = reference.last_block_checksum,
        };

        while (block_reference) |current| {
            var block: BlockBuffer align(constants.sector_size) = undefined;
            _ = self.readGridBlockWithReplica(
                replica,
                fd,
                current.address,
                current.checksum,
                expected_type,
                &block,
            ) catch |err| {
                logErr(
                    "failed to read trailer block type={s} address={} checksum={x}: {}",
                    .{ @tagName(expected_type), current.address, current.checksum, err },
                );
                return err;
            };
            try self.enqueueBlockRef(current.address, current.checksum, closed_timestamp);
            block_reference = schema.TrailerNode.previous(&block);
        }
    }

    fn walkManifestCheckpoint(
        self: *BackupRuntime,
        fd: std.posix.fd_t,
        references: vsr.SuperBlockManifestReferences,
        closed_timestamp: i64,
    ) !void {
        if (references.empty()) return;

        var seen_tables = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen_tables.deinit();

        var live_tables = std.ArrayList(schema.ManifestNode.TableInfo).init(self.allocator);
        defer live_tables.deinit();

        var block_reference = vsr.BlockReference{
            .address = references.newest_address,
            .checksum = references.newest_checksum,
        };

        while (true) {
            var manifest_block: BlockBuffer align(constants.sector_size) = undefined;
            _ = readGridBlock(
                fd,
                block_reference.address,
                block_reference.checksum,
                .manifest,
                &manifest_block,
            ) catch |err| {
                logErr(
                    "failed to read manifest block address={} checksum={x}: {}",
                    .{ block_reference.address, block_reference.checksum, err },
                );
                return err;
            };
            try self.enqueueBlockRef(
                block_reference.address,
                block_reference.checksum,
                closed_timestamp,
            );

            const manifest_node = schema.ManifestNode.from(&manifest_block);
            const tables = manifest_node.tables_const(&manifest_block);

            var entry = tables.len;
            while (entry > 0) {
                entry -= 1;
                const table = tables[entry];
                const gop = try seen_tables.getOrPut(table.address);
                if (gop.found_existing) continue;
                gop.value_ptr.* = {};

                if (table.label.event != .remove) {
                    try live_tables.append(table);
                }
            }

            if (block_reference.address == references.oldest_address) {
                if (block_reference.checksum != references.oldest_checksum) {
                    return error.InvalidManifestChain;
                }
                break;
            }

            const previous = schema.ManifestNode.previous(&manifest_block) orelse
                return error.InvalidManifestChain;
            block_reference = .{
                .address = previous.address,
                .checksum = previous.checksum,
            };
        }

        for (live_tables.items) |table| {
            try self.enqueueBlockRef(table.address, table.checksum, closed_timestamp);

            var index_block: BlockBuffer align(constants.sector_size) = undefined;
            _ = readGridBlock(fd, table.address, table.checksum, .index, &index_block) catch |err| {
                logErr(
                    "failed to read table index block address={} checksum={x} value_count={}: {}",
                    .{ table.address, table.checksum, table.value_count, err },
                );
                return err;
            };

            const index = schema.TableIndex.from(&index_block);
            const value_addresses = index.value_addresses_used(&index_block);
            const value_checksums = index.value_checksums_used(&index_block);
            assert(value_addresses.len == value_checksums.len);

            for (value_addresses, value_checksums) |value_address, value_checksum| {
                try self.enqueueBlockRef(
                    value_address,
                    value_checksum.value,
                    closed_timestamp,
                );
            }
        }
    }

    fn enqueueBlockRef(
        self: *BackupRuntime,
        address: u64,
        checksum: u128,
        closed_timestamp: i64,
    ) !void {
        const identity = BlockIdentity{
            .address = address,
            .checksum = checksum,
        };
        if (self.known_blocks.contains(identity)) return;

        const sequence = self.next_sequence;
        self.next_sequence += 1;

        const block_ref: BlockRef = .{
            .sequence = sequence,
            .address = address,
            .checksum = checksum,
            .closed_timestamp = closed_timestamp,
        };

        switch (self.queue.enqueue(block_ref)) {
            .queued, .queued_over_soft_limit => {
                self.coordinator.recordQueued();
                self.state_manager.incrementPending();
                self.known_blocks.put(identity, {}) catch {
                    _ = self.queue.discard(sequence) catch {};
                    self.state_manager.decrementPending();
                    return error.OutOfMemory;
                };
                self.blocks_enqueued_total += 1;
            },
            .abandoned => {
                self.state_manager.incrementAbandoned();
                archerdb_metrics.Registry.recordBackupBlockAbandoned();
            },
            .blocked => {
                logWarn("backup queue blocked on block sequence {}", .{sequence});
            },
        }
    }

    fn processQueue(self: *BackupRuntime, replica: anytype, fd: std.posix.fd_t) !void {
        var processed: usize = 0;
        while (processed < 4) : (processed += 1) {
            const pending = self.queue.dequeue() orelse break;
            const block = pending.block;
            const identity = BlockIdentity{
                .address = block.address,
                .checksum = block.checksum,
            };

            const started_ns = std.time.nanoTimestamp();
            self.uploadLocalBlock(replica, fd, block) catch |err| {
                archerdb_metrics.Registry.recordBackupFailure();
                self.state_manager.incrementFailed();

                const retry = self.queue.markFailed(block.sequence) catch false;
                if (!retry) {
                    _ = self.queue.discard(block.sequence) catch {};
                    self.state_manager.decrementPending();
                    _ = self.known_blocks.remove(identity);
                }

                logWarn("backup upload failed for address={} sequence={} err={}", .{
                    block.address,
                    block.sequence,
                    err,
                });
                continue;
            };

            try self.queue.markUploaded(block.sequence);
            try self.state_manager.markUploaded(block.sequence);
            self.coordinator.recordBackedUp(block.sequence, block.closed_timestamp);

            const finished_ns = std.time.nanoTimestamp();
            const latency_ns: u64 = @intCast(@max(finished_ns - started_ns, 0));
            const timestamp: u64 = @intCast(@max(std.time.timestamp(), 0));
            archerdb_metrics.Registry.recordBackupBlockUploaded(latency_ns, timestamp);
        }
    }

    fn flushCompletedCheckpointArtifacts(self: *BackupRuntime) !void {
        var index: usize = 0;
        while (index < self.pending_checkpoint_artifacts.items.len) {
            const artifact = self.pending_checkpoint_artifacts.items[index];
            const uploaded_sequence = self.state_manager.getState().last_uploaded_sequence;
            if (artifact.block_count > 0 and uploaded_sequence < artifact.sequence_max) {
                index += 1;
                continue;
            }

            try self.writeLocalCheckpointArtifact(artifact);
            _ = self.pending_checkpoint_artifacts.swapRemove(index);
        }
    }

    fn writeLocalCheckpointArtifact(
        self: *BackupRuntime,
        artifact: checkpoint_artifact.DurableCheckpointArtifact,
    ) !void {
        const file_name = try artifact.fileName(self.allocator);
        defer self.allocator.free(file_name);

        const file_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.local_prefix_path, file_name },
        );
        defer self.allocator.free(file_path);

        const contents = try artifact.encodeKeyValue(self.allocator);
        defer self.allocator.free(contents);

        try writeFileAtomic(file_path, contents);
    }

    fn uploadLocalBlock(
        self: *BackupRuntime,
        replica: anytype,
        fd: std.posix.fd_t,
        block: BlockRef,
    ) !void {
        var block_buffer: BlockBuffer align(constants.sector_size) = undefined;
        const header = try self.readGridBlockWithReplica(
            replica,
            fd,
            block.address,
            block.checksum,
            null,
            &block_buffer,
        );

        const block_name = try std.fmt.allocPrint(
            self.allocator,
            "{d:0>12}.block",
            .{block.sequence},
        );
        defer self.allocator.free(block_name);

        const block_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.local_prefix_path, block_name },
        );
        defer self.allocator.free(block_path);

        const ts_path = try std.fmt.allocPrint(self.allocator, "{s}.ts", .{block_path});
        defer self.allocator.free(ts_path);

        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}.meta", .{block_path});
        defer self.allocator.free(meta_path);

        try writeFile(block_path, block_buffer[0..header.size]);

        var ts_buf: [64]u8 = undefined;
        const ts_text = try std.fmt.bufPrint(&ts_buf, "{d}\n", .{block.closed_timestamp});
        try writeFile(ts_path, ts_text);

        const meta_text = try std.fmt.allocPrint(
            self.allocator,
            "sequence={d}\naddress={d}\nchecksum={x:0>32}\nclosed_timestamp={d}\n",
            .{ block.sequence, block.address, block.checksum, block.closed_timestamp },
        );
        defer self.allocator.free(meta_text);
        try writeFile(meta_path, meta_text);
    }

    fn loadExistingLocalMetadata(
        self: *BackupRuntime,
        last_sequence: *u64,
        last_timestamp: *i64,
    ) !void {
        var dir = openDir(self.local_prefix_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".meta")) continue;
            const contents = try dir.readFileAlloc(self.allocator, entry.name, 4096);
            defer self.allocator.free(contents);

            const meta = try parseLocalMetadata(contents);
            try self.known_blocks.put(.{
                .address = meta.address,
                .checksum = meta.checksum,
            }, {});
            last_sequence.* = @max(last_sequence.*, meta.sequence);
            last_timestamp.* = @max(last_timestamp.*, meta.closed_timestamp);
        }
    }

    fn updateMetrics(self: *BackupRuntime) void {
        const pending = self.queue.getStats().pending_count;

        var oldest_timestamp: i64 = 0;
        for (self.queue.pending.items) |upload| {
            if (oldest_timestamp == 0 or upload.block.closed_timestamp < oldest_timestamp) {
                oldest_timestamp = upload.block.closed_timestamp;
            }
        }

        const now = std.time.timestamp();
        const oldest_age_seconds: u64 = if (oldest_timestamp <= 0 or now <= oldest_timestamp)
            0
        else
            @intCast(now - oldest_timestamp);

        archerdb_metrics.Registry.updateBackupLag(pending, oldest_age_seconds);
    }

    fn transientScanError(self: *const BackupRuntime, err: anyerror) bool {
        _ = self;
        return switch (err) {
            error.EndOfStream,
            error.InvalidBlockHeader,
            error.InvalidBlockSize,
            error.InvalidBlockChecksum,
            error.InvalidBlockBodyChecksum,
            error.MismatchedBlockChecksum,
            error.UnexpectedBlockType,
            => true,
            else => false,
        };
    }

    fn clearCapturedCheckpointBlocks(self: *BackupRuntime) void {
        for (self.captured_checkpoint_blocks.items) |captured| {
            self.allocator.free(captured.bytes);
        }
        self.captured_checkpoint_blocks.clearRetainingCapacity();
    }

    fn captureCheckpointTrailerBlocks(
        self: *BackupRuntime,
        comptime label: []const u8,
        trailer: anytype,
    ) !void {
        const block_count = trailer.block_count();
        logInfo("{s} trailer capture: block_count={} size={}", .{
            label,
            block_count,
            trailer.size,
        });
        var i: u32 = 0;
        while (i < block_count) : (i += 1) {
            const bytes = try self.allocator.alignedAlloc(
                u8,
                constants.sector_size,
                constants.block_size,
            );
            errdefer self.allocator.free(bytes);

            @memcpy(bytes, trailer.blocks[i][0..]);
            try self.captured_checkpoint_blocks.append(.{
                .identity = .{
                    .address = trailer.block_addresses[i],
                    .checksum = trailer.block_checksums[i],
                },
                .bytes = bytes,
            });
            logInfo(
                "{s} trailer block[{}]: address={} checksum={x}",
                .{ label, i, trailer.block_addresses[i], trailer.block_checksums[i] },
            );
        }
    }

    fn readGridBlockWithReplica(
        self: *BackupRuntime,
        replica: anytype,
        fd: std.posix.fd_t,
        address: u64,
        checksum: u128,
        expected_type: ?schema.BlockType,
        block: *align(constants.sector_size) BackupRuntime.BlockBuffer,
    ) !vsr.Header.Block {
        if (replica.grid.read_block_from_cache(address, checksum, .{ .coherent = false })) |cached| {
            @memcpy(block, cached[0..constants.block_size]);
            return validateGridBlockBytes(address, checksum, expected_type, block);
        }
        if (self.findCapturedCheckpointBlock(address, checksum, expected_type, block)) |header| {
            logInfo(
                "using captured checkpoint block for address={} checksum={x}",
                .{ address, checksum },
            );
            return header;
        }
        return readGridBlock(fd, address, checksum, expected_type, block);
    }

    fn findCapturedCheckpointBlock(
        self: *BackupRuntime,
        address: u64,
        checksum: u128,
        expected_type: ?schema.BlockType,
        block: *align(constants.sector_size) BackupRuntime.BlockBuffer,
    ) ?vsr.Header.Block {
        for (self.captured_checkpoint_blocks.items) |captured| {
            if (captured.identity.address != address or captured.identity.checksum != checksum) {
                continue;
            }

            @memcpy(block, captured.bytes[0..constants.block_size]);
            return validateGridBlockBytes(address, checksum, expected_type, block) catch null;
        }
        return null;
    }
};

fn buildLocalPrefixPath(
    allocator: mem.Allocator,
    bucket: []const u8,
    cluster_id: u128,
    replica_id: u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{x:0>32}/replica-{d}/blocks",
        .{ bucket, cluster_id, replica_id },
    );
}

fn makePath(path: []const u8) !void {
    if (fs.path.isAbsolute(path)) {
        var root = try fs.openDirAbsolute("/", .{});
        defer root.close();
        try root.makePath(mem.trimLeft(u8, path, "/"));
    } else {
        try fs.cwd().makePath(path);
    }
}

fn openDir(path: []const u8, args: fs.Dir.OpenDirOptions) !fs.Dir {
    if (fs.path.isAbsolute(path)) {
        return fs.openDirAbsolute(path, args);
    }
    return fs.cwd().openDir(path, args);
}

fn createFile(path: []const u8) !fs.File {
    if (fs.path.isAbsolute(path)) {
        return fs.createFileAbsolute(path, .{ .truncate = true });
    }
    return fs.cwd().createFile(path, .{ .truncate = true });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const parent = fs.path.dirname(path) orelse ".";
    try makePath(parent);

    const file = try createFile(path);
    defer file.close();
    try file.writeAll(data);
    try file.sync();
}

fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{path});
    defer std.heap.page_allocator.free(tmp_path);

    const parent = fs.path.dirname(path) orelse ".";
    try makePath(parent);

    const file = try createFile(tmp_path);
    defer file.close();
    try file.writeAll(data);
    try file.sync();
    try fs.cwd().rename(tmp_path, path);
}

fn parseLocalMetadata(contents: []const u8) !BackupRuntime.LocalMetadata {
    var sequence: ?u64 = null;
    var address: ?u64 = null;
    var checksum: ?u128 = null;
    var closed_timestamp: i64 = 0;

    var lines = mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = mem.trim(u8, line[0..eq], " \t");
        const value = mem.trim(u8, line[eq + 1 ..], " \t");

        if (mem.eql(u8, key, "sequence")) {
            sequence = try std.fmt.parseInt(u64, value, 10);
        } else if (mem.eql(u8, key, "address")) {
            address = try std.fmt.parseInt(u64, value, 10);
        } else if (mem.eql(u8, key, "checksum")) {
            checksum = try std.fmt.parseInt(u128, value, 16);
        } else if (mem.eql(u8, key, "closed_timestamp")) {
            closed_timestamp = try std.fmt.parseInt(i64, value, 10);
        }
    }

    return .{
        .sequence = sequence orelse return error.InvalidMetadata,
        .address = address orelse return error.InvalidMetadata,
        .checksum = checksum orelse return error.InvalidMetadata,
        .closed_timestamp = closed_timestamp,
    };
}

fn readGridBytes(fd: std.posix.fd_t, address: u64, buffer: []u8) !void {
    assert(buffer.len % constants.sector_size == 0);

    const offset = vsr.Zone.offset(.grid, (address - 1) * constants.block_size);
    var total: usize = 0;
    while (total < buffer.len) {
        const bytes_read = try std.posix.pread(fd, buffer[total..], @intCast(offset + total));
        if (bytes_read == 0) return error.EndOfStream;
        total += bytes_read;
    }
}

fn readGridBlock(
    fd: std.posix.fd_t,
    address: u64,
    checksum: u128,
    expected_type: ?schema.BlockType,
    block: *align(constants.sector_size) BackupRuntime.BlockBuffer,
) !vsr.Header.Block {
    try readGridBytes(fd, address, block[0..]);

    return validateGridBlockBytes(address, checksum, expected_type, block);
}

fn validateGridBlockBytes(
    address: u64,
    checksum: u128,
    expected_type: ?schema.BlockType,
    block: *align(constants.sector_size) BackupRuntime.BlockBuffer,
) !vsr.Header.Block {

    var header: vsr.Header.Block = undefined;
    @memcpy(mem.asBytes(&header), block[0..@sizeOf(vsr.Header)]);
    if (header.command != .block or header.address != address) {
        return error.InvalidBlockHeader;
    }
    if (header.size < @sizeOf(vsr.Header) or header.size > constants.block_size) {
        return error.InvalidBlockSize;
    }
    if (!header.valid_checksum()) return error.InvalidBlockChecksum;
    if (header.checksum != checksum) return error.MismatchedBlockChecksum;
    if (expected_type) |block_type| {
        if (header.block_type != block_type) return error.UnexpectedBlockType;
    }
    if (!header.valid_checksum_body(block[@sizeOf(vsr.Header)..header.size])) {
        return error.InvalidBlockBodyChecksum;
    }
    return header;
}

test "BackupRuntime: parseLocalMetadata" {
    const meta =
        \\sequence=17
        \\address=99
        \\checksum=000000000000000000000000deadbeef
        \\closed_timestamp=1704067200
        \\
    ;

    const parsed = try parseLocalMetadata(meta);
    try std.testing.expectEqual(@as(u64, 17), parsed.sequence);
    try std.testing.expectEqual(@as(u64, 99), parsed.address);
    try std.testing.expectEqual(@as(u128, 0xdeadbeef), parsed.checksum);
    try std.testing.expectEqual(@as(i64, 1704067200), parsed.closed_timestamp);
}

test "BackupRuntime: init loads existing local metadata" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const bucket_path = try std.fmt.allocPrint(allocator, "{s}/backup", .{tmp_path});
    defer allocator.free(bucket_path);

    const prefix_path = try buildLocalPrefixPath(allocator, bucket_path, 0xabc, 0);
    defer allocator.free(prefix_path);
    try makePath(prefix_path);

    const meta_path = try std.fmt.allocPrint(
        allocator,
        "{s}/000000000123.block.meta",
        .{prefix_path},
    );
    defer allocator.free(meta_path);
    try writeFile(
        meta_path,
        "sequence=123\naddress=44\nchecksum=00000000000000000000000000c0ffee\nclosed_timestamp=1704067200\n",
    );

    const data_file_path = try std.fmt.allocPrint(allocator, "{s}/data.archerdb", .{tmp_path});
    defer allocator.free(data_file_path);
    try writeFile(data_file_path, "");

    var runtime = try BackupRuntime.init(allocator, .{
        .data_file_path = data_file_path,
        .cluster_id = 0xabc,
        .replica_id = 0,
        .replica_count = 1,
        .initial_view = 0,
        .backup_options = .{
            .enabled = true,
            .provider = .local,
            .bucket = bucket_path,
        },
    });
    defer runtime.deinit();

    try std.testing.expectEqual(@as(u64, 124), runtime.next_sequence);
    try std.testing.expect(runtime.known_blocks.contains(.{
        .address = 44,
        .checksum = 0xc0ffee,
    }));
}

test "BackupRuntime: local backup artifacts restore round-trip" {
    const allocator = std.testing.allocator;

    const FakeReplica = struct {
        grid: Grid = .{},

        const Grid = struct {
            fn read_block_from_cache(
                _: *@This(),
                address: u64,
                checksum: u128,
                options: struct { coherent: bool },
            ) ?vsr.grid.BlockPtrConst {
                _ = address;
                _ = checksum;
                _ = options;
                return null;
            }
        };
    };

    const BlockSpec = struct {
        sequence: u64,
        address: u64,
        body: []const u8,
        closed_timestamp: i64,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const bucket_path = try std.fmt.allocPrint(allocator, "{s}/backup", .{tmp_path});
    defer allocator.free(bucket_path);

    const data_file_path = try std.fmt.allocPrint(allocator, "{s}/data.archerdb", .{tmp_path});
    defer allocator.free(data_file_path);

    const dest_data_file_path = try std.fmt.allocPrint(allocator, "{s}/restored.archerdb", .{tmp_path});
    defer allocator.free(dest_data_file_path);

    var data_file = try tmp.dir.createFile("data.archerdb", .{
        .read = true,
        .truncate = true,
    });
    defer data_file.close();

    var runtime = try BackupRuntime.init(allocator, .{
        .data_file_path = data_file_path,
        .cluster_id = 0xabc,
        .replica_id = 0,
        .replica_count = 1,
        .initial_view = 0,
        .backup_options = .{
            .enabled = true,
            .provider = .local,
            .bucket = bucket_path,
        },
    });
    defer runtime.deinit();

    var fake_replica = FakeReplica{};

    const specs = [_]BlockSpec{
        .{
            .sequence = 1,
            .address = 1,
            .body = "first-block-payload",
            .closed_timestamp = 1704067200,
        },
        .{
            .sequence = 2,
            .address = 2,
            .body = "second-block-payload",
            .closed_timestamp = 1704067260,
        },
    };

    var expected_output = std.ArrayList(u8).init(allocator);
    defer expected_output.deinit();

    for (specs) |spec| {
        var header = std.mem.zeroInit(vsr.Header.Block, .{
            .cluster = 1,
            .size = @sizeOf(vsr.Header) + spec.body.len,
            .release = vsr.Release.minimum,
            .command = .block,
            .metadata_bytes = [_]u8{0} ** vsr.Header.Block.metadata_size,
            .address = spec.address,
            .snapshot = 0,
            .block_type = .free_set,
        });
        header.set_checksum_body(spec.body);
        header.set_checksum();

        var disk_block: BackupRuntime.BlockBuffer align(constants.sector_size) =
            [_]u8{0} ** constants.block_size;
        @memcpy(disk_block[0..@sizeOf(vsr.Header)], std.mem.asBytes(&header));
        @memcpy(
            disk_block[@sizeOf(vsr.Header) .. @sizeOf(vsr.Header) + spec.body.len],
            spec.body,
        );

        const offset = vsr.Zone.offset(.grid, (spec.address - 1) * constants.block_size);
        try data_file.pwriteAll(&disk_block, offset);
        try expected_output.appendSlice(disk_block[0..header.size]);

        try runtime.uploadLocalBlock(&fake_replica, data_file.handle, .{
            .sequence = spec.sequence,
            .address = spec.address,
            .checksum = header.checksum,
            .closed_timestamp = spec.closed_timestamp,
        });
    }

    const source_url = try std.fmt.allocPrint(
        allocator,
        "file://{s}",
        .{runtime.local_prefix_path},
    );
    defer allocator.free(source_url);

    var manager = try vsr.restore.RestoreManager.init(allocator, .{
        .source_url = source_url,
        .dest_data_file = dest_data_file_path,
        .point_in_time = .latest,
        .verify_checksums = true,
    });
    defer manager.deinit();

    const stats = try manager.execute();
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(@as(u64, specs.len), stats.blocks_available);
    try std.testing.expectEqual(@as(u64, specs.len), stats.blocks_downloaded);
    try std.testing.expectEqual(@as(u64, specs.len), stats.blocks_verified);
    try std.testing.expectEqual(@as(u64, specs.len), stats.blocks_written);
    try std.testing.expectEqual(@as(u64, 2), stats.max_sequence_restored);

    const restored_bytes = try tmp.dir.readFileAlloc(
        allocator,
        "restored.archerdb",
        expected_output.items.len + 1,
    );
    defer allocator.free(restored_bytes);

    try std.testing.expectEqualSlices(u8, expected_output.items, restored_bytes);
}
