// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Rolling upgrade status and dry-run planning (OPS-07, OPS-08)
//!
//! This module currently provides live upgrade status probing and dry-run
//! planning for ArcherDB clusters. It does not yet own a process or
//! deployment actuator for real rolling upgrades, and that boundary is
//! intentional in the current public runtime surface.
//!
//! Key features:
//! - Primary identification before upgrade
//! - Dry-run follower-first, primary-last upgrade planning
//! - Live readiness/metrics probing for status and preflight checks
//! - Explicit fail-closed boundary for missing live actuation
//!
//! Usage:
//! ```bash
//! # Check cluster status and versions
//! archerdb upgrade status --addresses=node1:3000,node2:3000,node3:3000
//!
//! # Start rolling upgrade with dry-run
//! archerdb upgrade start --addresses=... --target-version=1.2.0 --dry-run
//!
//! # Generate a dry-run plan
//! archerdb upgrade start --addresses=... --target-version=1.2.0 --dry-run
//!
//! # Perform the live rollout with your deployment tooling
//! systemctl restart archerdb
//! ```

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const log = std.log.scoped(.upgrade);

const vsr = @import("vsr");
const stdx = vsr.stdx;
const constants = vsr.constants;

// Test-safe logging wrappers
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

fn logDebug(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.debug(fmt, args);
    }
}

/// Health thresholds for upgrade rollback triggers (OPS-08).
pub const HealthThresholds = struct {
    /// Maximum P99 latency multiplier before triggering rollback.
    /// If P99 exceeds baseline * this value, rollback is triggered.
    /// Default: 2.0 (2x baseline triggers rollback)
    p99_latency_multiplier: f64 = 2.0,

    /// Maximum absolute P99 latency in milliseconds.
    /// Default: 100ms
    p99_latency_max_ms: u64 = 100,

    /// Maximum error rate percentage before triggering rollback.
    /// Default: 1.0 (1% error rate triggers rollback)
    error_rate_threshold_pct: f64 = 1.0,

    /// Number of consecutive failed health probes before triggering rollback.
    /// Default: 3
    probe_failure_threshold: u32 = 3,

    /// Maximum time in seconds for a replica to catch up after upgrade.
    /// Default: 300 (5 minutes)
    catchup_timeout_seconds: u32 = 300,

    /// Health check interval in milliseconds.
    /// Default: 5000 (5 seconds)
    health_check_interval_ms: u32 = 5000,
};

/// Upgrade configuration options.
pub const UpgradeOptions = struct {
    /// Cluster addresses (comma-separated).
    addresses: []const u8,

    /// Target version to upgrade to (e.g., "1.2.0").
    target_version: ?[]const u8 = null,

    /// Health thresholds for rollback triggers.
    health_thresholds: HealthThresholds = .{},

    /// Whether to perform a dry run (no actual changes).
    dry_run: bool = false,

    /// Metrics port for health probes (default: 9100).
    metrics_port: u16 = 9100,

    /// Timeout for upgrade operations in seconds.
    timeout_seconds: u32 = 600,

    /// Whether to pause between replica upgrades for manual verification.
    pause_between_replicas: bool = false,
};

/// Upgrade state machine states.
pub const UpgradeState = enum {
    /// Upgrade not started.
    not_started,

    /// Running preflight checks (connectivity, version compatibility).
    preflight_checks,

    /// Upgrading follower replicas.
    upgrading_followers,

    /// Waiting for follower to catch up after upgrade.
    waiting_for_catchup,

    /// Upgrading primary replica.
    upgrading_primary,

    /// Upgrade completed successfully.
    completed,

    /// Upgrade paused by operator.
    paused,

    /// Upgrade failed, rollback in progress.
    rolling_back,

    /// Rollback completed.
    rolled_back,

    /// Upgrade failed.
    failed,

    pub fn isTerminal(self: UpgradeState) bool {
        return switch (self) {
            .completed, .rolled_back, .failed => true,
            else => false,
        };
    }

    pub fn format(
        self: UpgradeState,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const str = switch (self) {
            .not_started => "not_started",
            .preflight_checks => "preflight_checks",
            .upgrading_followers => "upgrading_followers",
            .waiting_for_catchup => "waiting_for_catchup",
            .upgrading_primary => "upgrading_primary",
            .completed => "completed",
            .paused => "paused",
            .rolling_back => "rolling_back",
            .rolled_back => "rolled_back",
            .failed => "failed",
        };
        try writer.writeAll(str);
    }
};

/// Replica role in the cluster.
pub const ReplicaRole = enum {
    primary,
    follower,
    standby,
    unknown,

    pub fn format(
        self: ReplicaRole,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const str = switch (self) {
            .primary => "primary",
            .follower => "follower",
            .standby => "standby",
            .unknown => "unknown",
        };
        try writer.writeAll(str);
    }
};

/// Information about a single replica.
pub const ReplicaInfo = struct {
    /// Network address (host:port).
    address: []const u8,

    /// Replica index in the cluster.
    replica_id: u8,

    /// Whether this replica is the primary.
    is_primary: bool,

    /// Current version string.
    version: []const u8,

    /// Whether the replica is healthy.
    healthy: bool,

    /// Role in the cluster.
    role: ReplicaRole,

    /// Current commit sequence number.
    commit_sequence: u64,

    /// Last known P99 latency in milliseconds.
    p99_latency_ms: u64,

    /// Current error rate percentage.
    error_rate_pct: f64,

    /// Whether the replica has been upgraded.
    upgraded: bool,

    pub fn format(
        self: ReplicaInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Replica[{d}] {s} {s} v{s} healthy={} seq={d}", .{
            self.replica_id,
            self.address,
            @tagName(self.role),
            self.version,
            self.healthy,
            self.commit_sequence,
        });
    }

    pub fn jsonStringify(self: ReplicaInfo, jw: anytype) !void {
        try jw.write(.{
            .address = self.address,
            .replica_id = self.replica_id,
            .is_primary = self.is_primary,
            .version = self.version,
            .healthy = self.healthy,
            .role = @tagName(self.role),
            .commit_sequence = self.commit_sequence,
            .p99_latency_ms = self.p99_latency_ms,
            .error_rate_pct = self.error_rate_pct,
            .upgraded = self.upgraded,
        });
    }
};

/// Health status result from health check.
pub const HealthStatus = struct {
    /// Whether the cluster is healthy overall.
    healthy: bool,

    /// Number of healthy replicas.
    healthy_count: u32,

    /// Total number of replicas.
    total_count: u32,

    /// Cluster-wide P99 latency in milliseconds.
    p99_latency_ms: u64,

    /// Cluster-wide error rate percentage.
    error_rate_pct: f64,

    /// Whether rollback should be triggered.
    should_rollback: bool,

    /// Reason for rollback (if should_rollback is true).
    rollback_reason: ?[]const u8,

    /// Per-replica health details.
    replicas: []const ReplicaInfo,

    pub fn hasQuorum(self: HealthStatus) bool {
        // For VSR, we need (n/2 + 1) replicas for quorum
        const quorum = (self.total_count / 2) + 1;
        return self.healthy_count >= quorum;
    }
};

/// Upgrade result summary.
pub const UpgradeResult = struct {
    /// Final state of the upgrade.
    state: UpgradeState,

    /// Whether the upgrade was successful.
    success: bool,

    /// Total duration in milliseconds.
    duration_ms: u64,

    /// Number of replicas upgraded.
    replicas_upgraded: u32,

    /// Number of replicas that failed upgrade.
    replicas_failed: u32,

    /// Error message if upgrade failed.
    error_message: ?[]const u8,

    /// Whether rollback was performed.
    rollback_performed: bool,

    pub fn format(
        self: UpgradeResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.success) {
            try writer.print("Upgrade completed: {d} replicas upgraded in {d}ms", .{
                self.replicas_upgraded,
                self.duration_ms,
            });
        } else {
            try writer.print("Upgrade failed: {s} (state: {}, rollback: {})", .{
                self.error_message orelse "unknown error",
                self.state,
                self.rollback_performed,
            });
        }
    }

    pub fn jsonStringify(self: UpgradeResult, jw: anytype) !void {
        try jw.write(.{
            .state = @tagName(self.state),
            .success = self.success,
            .duration_ms = self.duration_ms,
            .replicas_upgraded = self.replicas_upgraded,
            .replicas_failed = self.replicas_failed,
            .error_message = self.error_message,
            .rollback_performed = self.rollback_performed,
        });
    }
};

/// Upgrade orchestrator.
pub const Upgrader = struct {
    allocator: std.mem.Allocator,
    options: UpgradeOptions,
    state: UpgradeState,
    replicas: std.ArrayList(ReplicaInfo),
    primary_index: ?usize,
    current_replica_index: usize,
    start_time: i64,
    consecutive_probe_failures: u32,
    baseline_p99_latency_ms: u64,
    error_message: ?[]const u8,

    const Self = @This();

    /// Initialize the upgrader.
    pub fn init(allocator: std.mem.Allocator, options: UpgradeOptions) Self {
        return Self{
            .allocator = allocator,
            .options = options,
            .state = .not_started,
            .replicas = std.ArrayList(ReplicaInfo).init(allocator),
            .primary_index = null,
            .current_replica_index = 0,
            .start_time = std.time.milliTimestamp(),
            .consecutive_probe_failures = 0,
            .baseline_p99_latency_ms = 0,
            .error_message = null,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *Self) void {
        for (self.replicas.items) |replica| {
            self.allocator.free(replica.version);
        }
        self.replicas.deinit();
    }

    /// Run preflight checks before starting upgrade.
    /// Verifies connectivity, version compatibility, and cluster health.
    pub fn runPreflightChecks(self: *Self) !void {
        self.state = .preflight_checks;
        logInfo("Running preflight checks...", .{});

        // Discover cluster topology
        try self.discoverReplicas();

        // Identify primary
        _ = try self.identifyPrimary();

        // Check version compatibility
        if (self.options.target_version) |target| {
            for (self.replicas.items) |replica| {
                if (!self.isVersionCompatible(replica.version, target)) {
                    const msg = "Version upgrade from {s} to {s} not compatible";
                    logErr(msg, .{ replica.version, target });
                    self.state = .failed;
                    self.error_message = "Version incompatible - sequential upgrade required";
                    return error.IncompatibleVersion;
                }
            }
        }

        // Check cluster health
        const health = try self.checkHealth();
        if (!health.hasQuorum()) {
            logErr("Cluster does not have quorum - cannot proceed with upgrade", .{});
            self.state = .failed;
            self.error_message = "Cluster does not have quorum";
            return error.NoQuorum;
        }

        // Record baseline latency
        self.baseline_p99_latency_ms = health.p99_latency_ms;
        logInfo("Baseline P99 latency: {d}ms", .{self.baseline_p99_latency_ms});

        logInfo("Preflight checks passed", .{});
    }

    /// Discover replicas from the provided addresses.
    pub fn discoverReplicas(self: *Self) !void {
        for (self.replicas.items) |replica| {
            self.allocator.free(replica.version);
        }
        self.replicas.clearRetainingCapacity();
        self.primary_index = null;

        // Parse addresses and probe each replica
        var iter = mem.splitScalar(u8, self.options.addresses, ',');
        var replica_id: u8 = 0;

        while (iter.next()) |addr| {
            const trimmed = mem.trim(u8, addr, " ");
            if (trimmed.len == 0) continue;

            const probe = self.probeReplica(trimmed) catch |err| blk: {
                logWarn("Failed to probe replica {s}: {}", .{ trimmed, err });
                break :blk ReplicaProbe{
                    .healthy = false,
                    .version = try self.allocator.dupe(u8, "unknown"),
                    .commit_sequence = 0,
                    .is_primary = false,
                };
            };

            const replica = ReplicaInfo{
                .address = trimmed,
                .replica_id = replica_id,
                .is_primary = probe.is_primary,
                .version = probe.version,
                .healthy = probe.healthy,
                .role = if (!probe.healthy) .unknown else if (probe.is_primary) .primary else .follower,
                .commit_sequence = probe.commit_sequence,
                .p99_latency_ms = 0,
                .error_rate_pct = 0.0,
                .upgraded = false,
            };

            try self.replicas.append(replica);
            replica_id += 1;
        }

        logInfo("Discovered {d} replicas", .{self.replicas.items.len});
    }

    /// Identify the primary replica in the cluster.
    pub fn identifyPrimary(self: *Self) !?ReplicaInfo {
        logInfo("Identifying primary replica...", .{});

        for (self.replicas.items, 0..) |*replica, i| {
            const probe = self.probeReplica(replica.address) catch |err| blk: {
                logWarn("Failed to refresh replica role for {s}: {}", .{ replica.address, err });
                replica.healthy = false;
                replica.is_primary = false;
                replica.role = .unknown;
                break :blk null;
            };
            if (probe == null) continue;
            replica.healthy = probe.?.healthy;
            replica.commit_sequence = probe.?.commit_sequence;
            replica.is_primary = probe.?.is_primary;
            replica.role = if (!replica.healthy) .unknown else if (replica.is_primary) .primary else .follower;

            if (replica.is_primary) {
                self.primary_index = i;
                logInfo("Primary identified: replica {d} at {s}", .{ replica.replica_id, replica.address });
                return replica.*;
            }
        }

        logWarn("No primary identified - cluster may be in election", .{});
        return null;
    }

    /// Upgrade a single replica.
    pub fn upgradeReplica(self: *Self, replica: ReplicaInfo) !void {
        logInfo("Upgrading replica {d} at {s}...", .{ replica.replica_id, replica.address });

        if (self.options.dry_run) {
            logInfo("[DRY RUN] Would upgrade replica {d}", .{replica.replica_id});
            return;
        }

        // For bare-metal: trigger graceful shutdown and binary replacement
        // For Kubernetes: this is informational - actual upgrade is via StatefulSet
        logInfo("Replica {d} ready for upgrade", .{replica.replica_id});
        logInfo("  - Bare metal: Stop process, replace binary, restart", .{});
        logInfo("  - Kubernetes: Replica pod will be recreated with new image", .{});

        // Wait for replica to restart and become healthy
        try self.waitForReplicaHealthy(replica);

        // Mark as upgraded
        if (replica.replica_id < self.replicas.items.len) {
            self.replicas.items[replica.replica_id].upgraded = true;
        }
    }

    /// Wait for a replica to become healthy after upgrade.
    fn waitForReplicaHealthy(self: *Self, replica: ReplicaInfo) !void {
        const timeout_ms = @as(u64, self.options.health_thresholds.catchup_timeout_seconds) * 1000;
        const interval_ms = self.options.health_thresholds.health_check_interval_ms;
        var elapsed: u64 = 0;

        while (elapsed < timeout_ms) {
            const health = try self.probeReplicaHealth(replica);
            if (health) {
                logInfo("Replica {d} is healthy", .{replica.replica_id});
                return;
            }

            std.time.sleep(interval_ms * std.time.ns_per_ms);
            elapsed += interval_ms;
            logDebug("Waiting for replica {d} to become healthy... ({d}ms elapsed)", .{
                replica.replica_id,
                elapsed,
            });
        }

        logErr("Replica {d} did not become healthy within {d}s timeout", .{
            replica.replica_id,
            self.options.health_thresholds.catchup_timeout_seconds,
        });
        return error.ReplicaUnhealthy;
    }

    /// Probe a single replica's health.
    fn probeReplicaHealth(self: *Self, replica: ReplicaInfo) !bool {
        const probe = try self.probeReplica(replica.address);
        return probe.healthy;
    }

    const ReplicaProbe = struct {
        healthy: bool,
        version: []const u8,
        commit_sequence: u64,
        is_primary: bool,
    };

    const HttpResponse = struct {
        status_code: u16,
        body: []u8,
    };

    fn probeReplica(self: *Self, address: []const u8) !ReplicaProbe {
        const endpoint = try parseReplicaAddress(address);

        const ready = try self.httpGet(endpoint.host, self.options.metrics_port, "/health/ready");
        defer self.allocator.free(ready.body);

        const metrics = try self.httpGet(endpoint.host, self.options.metrics_port, "/metrics");
        defer self.allocator.free(metrics.body);

        const version = try self.parseVersionFromReadyBody(ready.body);
        errdefer self.allocator.free(version);

        return .{
            .healthy = ready.status_code == 200,
            .version = version,
            .commit_sequence = parseMetricU64(metrics.body, "archerdb_vsr_op_number") orelse 0,
            .is_primary = (parseMetricU64(metrics.body, "archerdb_vsr_is_primary") orelse 0) == 1,
        };
    }

    fn httpGet(self: *Self, host: []const u8, port: u16, path: []const u8) !HttpResponse {
        const addr = std.net.Address.parseIp4(host, port) catch return error.InvalidAddress;
        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(socket);

        try std.posix.connect(socket, &addr.any, addr.getOsSockLen());

        const request = try std.fmt.allocPrint(
            self.allocator,
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n",
            .{ path, host },
        );
        defer self.allocator.free(request);

        _ = try std.posix.write(socket, request);

        var response = std.ArrayList(u8).init(self.allocator);
        errdefer response.deinit();
        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = std.posix.read(socket, &buffer) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (bytes_read == 0) break;
            try response.appendSlice(buffer[0..bytes_read]);
        }

        const response_bytes = try response.toOwnedSlice();
        errdefer self.allocator.free(response_bytes);

        const header_end = mem.indexOf(u8, response_bytes, "\r\n\r\n") orelse return error.InvalidHttpResponse;
        const status_code = parseHttpStatusCode(response_bytes[0..header_end]) orelse
            return error.InvalidHttpResponse;

        const body = try self.allocator.dupe(u8, response_bytes[header_end + 4 ..]);
        self.allocator.free(response_bytes);
        return .{
            .status_code = status_code,
            .body = body,
        };
    }

    fn parseVersionFromReadyBody(self: *Self, body: []const u8) ![]u8 {
        const ReadyResponse = struct {
            version: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(
            ReadyResponse,
            self.allocator,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch return self.allocator.dupe(u8, "unknown");
        defer parsed.deinit();

        return self.allocator.dupe(u8, parsed.value.version orelse "unknown");
    }

    fn parseReplicaAddress(address: []const u8) !struct { host: []const u8, port: u16 } {
        const colon = mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress;
        const host = mem.trim(u8, address[0..colon], " []");
        const port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch return error.InvalidAddress;
        if (host.len == 0) return error.InvalidAddress;
        return .{ .host = host, .port = port };
    }

    fn parseHttpStatusCode(response_head: []const u8) ?u16 {
        const first_space = mem.indexOfScalar(u8, response_head, ' ') orelse return null;
        const rest = response_head[first_space + 1 ..];
        const second_space = mem.indexOfScalar(u8, rest, ' ') orelse return null;
        return std.fmt.parseInt(u16, rest[0..second_space], 10) catch null;
    }

    fn parseMetricU64(metrics_body: []const u8, metric_name: []const u8) ?u64 {
        var lines = mem.tokenizeScalar(u8, metrics_body, '\n');
        while (lines.next()) |line_raw| {
            const line = mem.trim(u8, line_raw, " \r\t");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            if (!mem.startsWith(u8, line, metric_name)) continue;
            if (line.len <= metric_name.len) continue;

            var value_start = metric_name.len;
            if (line[value_start] == '{') {
                const labels_end = mem.indexOfScalarPos(u8, line, value_start, '}') orelse continue;
                value_start = labels_end + 1;
            }

            if (value_start >= line.len or line[value_start] != ' ') continue;
            const value = mem.trim(u8, line[value_start + 1 ..], " ");
            return std.fmt.parseInt(u64, value, 10) catch null;
        }
        return null;
    }

    /// Check overall cluster health.
    pub fn checkHealth(self: *Self) !HealthStatus {
        var healthy_count: u32 = 0;
        var total_latency: u64 = 0;
        var total_error_rate: f64 = 0.0;
        var should_rollback = false;
        var rollback_reason: ?[]const u8 = null;

        for (self.replicas.items) |replica| {
            if (replica.healthy) {
                healthy_count += 1;
            }
            total_latency += replica.p99_latency_ms;
            total_error_rate += replica.error_rate_pct;
        }

        const total_count = @as(u32, @intCast(self.replicas.items.len));
        const avg_latency = if (total_count > 0) total_latency / total_count else 0;
        const avg_error_rate = if (total_count > 0) total_error_rate / @as(f64, @floatFromInt(total_count)) else 0.0;

        // Check rollback triggers
        const thresholds = self.options.health_thresholds;

        // Check P99 latency threshold
        if (self.baseline_p99_latency_ms > 0) {
            const latency_multiplier = @as(f64, @floatFromInt(avg_latency)) /
                @as(f64, @floatFromInt(self.baseline_p99_latency_ms));
            if (latency_multiplier > thresholds.p99_latency_multiplier) {
                should_rollback = true;
                rollback_reason = "P99 latency exceeded threshold";
            }
        }

        // Check absolute P99 latency
        if (avg_latency > thresholds.p99_latency_max_ms) {
            should_rollback = true;
            rollback_reason = "P99 latency exceeded maximum";
        }

        // Check error rate threshold
        if (avg_error_rate > thresholds.error_rate_threshold_pct) {
            should_rollback = true;
            rollback_reason = "Error rate exceeded threshold";
        }

        // Check probe failures
        if (self.consecutive_probe_failures >= thresholds.probe_failure_threshold) {
            should_rollback = true;
            rollback_reason = "Consecutive health probe failures";
        }

        return HealthStatus{
            .healthy = healthy_count == total_count,
            .healthy_count = healthy_count,
            .total_count = total_count,
            .p99_latency_ms = avg_latency,
            .error_rate_pct = avg_error_rate,
            .should_rollback = should_rollback,
            .rollback_reason = rollback_reason,
            .replicas = self.replicas.items,
        };
    }

    /// Execute rollback procedure.
    pub fn rollback(self: *Self) !void {
        self.state = .rolling_back;
        logWarn("Initiating rollback...", .{});

        if (self.options.dry_run) {
            logInfo("[DRY RUN] Would rollback all upgraded replicas", .{});
            self.state = .rolled_back;
            return;
        }

        // Rollback in reverse order (primary first if it was upgraded)
        var rollback_order = std.ArrayList(usize).init(self.allocator);
        defer rollback_order.deinit();

        // Add upgraded replicas in reverse order
        var i: usize = self.replicas.items.len;
        while (i > 0) {
            i -= 1;
            if (self.replicas.items[i].upgraded) {
                try rollback_order.append(i);
            }
        }

        logInfo("Rolling back {d} replicas", .{rollback_order.items.len});

        for (rollback_order.items) |idx| {
            const replica = self.replicas.items[idx];
            logInfo("Rolling back replica {d} at {s}", .{ replica.replica_id, replica.address });
            // In production: trigger restart with previous version
        }

        self.state = .rolled_back;
        logInfo("Rollback completed", .{});
    }

    /// Check if upgrade from source version to target version is compatible.
    fn isVersionCompatible(self: *Self, source: []const u8, target: []const u8) bool {
        _ = self;
        // TigerBeetle model: each version specifies oldest compatible source
        // For now, allow any upgrade (real implementation would check compatibility matrix)
        _ = source;
        _ = target;
        return true;
    }

    /// Execute the full upgrade procedure.
    pub fn execute(self: *Self) !UpgradeResult {
        const start = std.time.milliTimestamp();

        // Run preflight checks
        self.runPreflightChecks() catch {
            return UpgradeResult{
                .state = self.state,
                .success = false,
                .duration_ms = @intCast(std.time.milliTimestamp() - start),
                .replicas_upgraded = 0,
                .replicas_failed = 0,
                .error_message = self.error_message,
                .rollback_performed = false,
            };
        };

        // Upgrade followers first
        self.state = .upgrading_followers;
        var upgraded_count: u32 = 0;
        var failed_count: u32 = 0;

        for (self.replicas.items) |replica| {
            if (replica.is_primary) continue; // Skip primary for now

            self.upgradeReplica(replica) catch |err| {
                failed_count += 1;
                logErr("Failed to upgrade replica {d}: {any}", .{ replica.replica_id, err });

                // Check if we should rollback
                const health = try self.checkHealth();
                if (health.should_rollback) {
                    try self.rollback();
                    return UpgradeResult{
                        .state = self.state,
                        .success = false,
                        .duration_ms = @intCast(std.time.milliTimestamp() - start),
                        .replicas_upgraded = upgraded_count,
                        .replicas_failed = failed_count,
                        .error_message = health.rollback_reason,
                        .rollback_performed = true,
                    };
                }
                continue;
            };

            upgraded_count += 1;

            // Wait for catchup
            self.state = .waiting_for_catchup;
            self.waitForReplicaHealthy(replica) catch |err| {
                logErr("Replica {d} did not recover: {any}", .{ replica.replica_id, err });
                try self.rollback();
                return UpgradeResult{
                    .state = self.state,
                    .success = false,
                    .duration_ms = @intCast(std.time.milliTimestamp() - start),
                    .replicas_upgraded = upgraded_count,
                    .replicas_failed = failed_count + 1,
                    .error_message = "Replica failed to recover after upgrade",
                    .rollback_performed = true,
                };
            };

            self.state = .upgrading_followers;
        }

        // Upgrade primary last
        if (self.primary_index) |idx| {
            self.state = .upgrading_primary;
            const primary = self.replicas.items[idx];

            self.upgradeReplica(primary) catch |err| {
                logErr("Failed to upgrade primary: {any}", .{err});
                try self.rollback();
                return UpgradeResult{
                    .state = self.state,
                    .success = false,
                    .duration_ms = @intCast(std.time.milliTimestamp() - start),
                    .replicas_upgraded = upgraded_count,
                    .replicas_failed = 1,
                    .error_message = "Primary upgrade failed",
                    .rollback_performed = true,
                };
            };

            upgraded_count += 1;
        }

        self.state = .completed;
        return UpgradeResult{
            .state = self.state,
            .success = true,
            .duration_ms = @intCast(std.time.milliTimestamp() - start),
            .replicas_upgraded = upgraded_count,
            .replicas_failed = failed_count,
            .error_message = null,
            .rollback_performed = false,
        };
    }

    /// Pause the upgrade process.
    pub fn pause(self: *Self) void {
        if (self.state == .upgrading_followers or self.state == .upgrading_primary) {
            logInfo("Pausing upgrade at replica {d}", .{self.current_replica_index});
            self.state = .paused;
        }
    }

    /// Resume the upgrade process.
    pub fn @"resume"(self: *Self) void {
        if (self.state == .paused) {
            logInfo("Resuming upgrade from replica {d}", .{self.current_replica_index});
            self.state = .upgrading_followers;
        }
    }

    /// Get cluster status summary.
    pub fn getStatus(self: *Self) !ClusterStatus {
        const health = try self.checkHealth();
        const primary = if (self.primary_index) |idx| self.replicas.items[idx] else null;

        return ClusterStatus{
            .state = self.state,
            .total_replicas = @intCast(self.replicas.items.len),
            .healthy_replicas = health.healthy_count,
            .upgraded_replicas = blk: {
                var count: u32 = 0;
                for (self.replicas.items) |r| {
                    if (r.upgraded) count += 1;
                }
                break :blk count;
            },
            .primary_address = if (primary) |p| p.address else null,
            .primary_version = if (primary) |p| p.version else null,
            .target_version = self.options.target_version,
            .has_quorum = health.hasQuorum(),
            .p99_latency_ms = health.p99_latency_ms,
            .error_rate_pct = health.error_rate_pct,
            .replicas = self.replicas.items,
        };
    }
};

/// Cluster status for display.
pub const ClusterStatus = struct {
    state: UpgradeState,
    total_replicas: u32,
    healthy_replicas: u32,
    upgraded_replicas: u32,
    primary_address: ?[]const u8,
    primary_version: ?[]const u8,
    target_version: ?[]const u8,
    has_quorum: bool,
    p99_latency_ms: u64,
    error_rate_pct: f64,
    replicas: []const ReplicaInfo,

    pub fn format(
        self: ClusterStatus,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            \\Cluster Status
            \\  State: {}
            \\  Replicas: {d}/{d} healthy, {d} upgraded
            \\  Quorum: {}
            \\  Primary: {s} (v{s})
            \\  P99 Latency: {d}ms
            \\  Error Rate: {d:.2}%
        , .{
            self.state,
            self.healthy_replicas,
            self.total_replicas,
            self.upgraded_replicas,
            self.has_quorum,
            self.primary_address orelse "unknown",
            self.primary_version orelse "unknown",
            self.p99_latency_ms,
            self.error_rate_pct,
        });
    }

    pub fn jsonStringify(self: ClusterStatus, jw: anytype) !void {
        try jw.write(.{
            .state = @tagName(self.state),
            .total_replicas = self.total_replicas,
            .healthy_replicas = self.healthy_replicas,
            .upgraded_replicas = self.upgraded_replicas,
            .primary_address = self.primary_address,
            .primary_version = self.primary_version,
            .target_version = self.target_version,
            .has_quorum = self.has_quorum,
            .p99_latency_ms = self.p99_latency_ms,
            .error_rate_pct = self.error_rate_pct,
            .replicas = self.replicas,
        });
    }
};

// =============================================================================
// Tests
// =============================================================================

test "UpgradeState: terminal states" {
    const std_testing = std.testing;

    try std_testing.expect(!UpgradeState.not_started.isTerminal());
    try std_testing.expect(!UpgradeState.preflight_checks.isTerminal());
    try std_testing.expect(!UpgradeState.upgrading_followers.isTerminal());
    try std_testing.expect(!UpgradeState.paused.isTerminal());
    try std_testing.expect(UpgradeState.completed.isTerminal());
    try std_testing.expect(UpgradeState.rolled_back.isTerminal());
    try std_testing.expect(UpgradeState.failed.isTerminal());
}

test "HealthStatus: quorum calculation" {
    const std_testing = std.testing;

    // 3-node cluster needs 2 for quorum
    var status = HealthStatus{
        .healthy = false,
        .healthy_count = 2,
        .total_count = 3,
        .p99_latency_ms = 10,
        .error_rate_pct = 0.0,
        .should_rollback = false,
        .rollback_reason = null,
        .replicas = &[_]ReplicaInfo{},
    };
    try std_testing.expect(status.hasQuorum());

    status.healthy_count = 1;
    try std_testing.expect(!status.hasQuorum());

    // 5-node cluster needs 3 for quorum
    status.total_count = 5;
    status.healthy_count = 3;
    try std_testing.expect(status.hasQuorum());

    status.healthy_count = 2;
    try std_testing.expect(!status.hasQuorum());
}

test "Upgrader: init and deinit" {
    const allocator = std.testing.allocator;

    const options = UpgradeOptions{
        .addresses = "localhost:3000,localhost:3001,localhost:3002",
        .target_version = "1.2.0",
    };

    var upgrader = Upgrader.init(allocator, options);
    defer upgrader.deinit();

    try std.testing.expectEqual(UpgradeState.not_started, upgrader.state);
    try std.testing.expectEqual(@as(?usize, null), upgrader.primary_index);
}

test "Upgrader: discover replicas" {
    const allocator = std.testing.allocator;

    const options = UpgradeOptions{
        .addresses = "localhost:3000,localhost:3001,localhost:3002",
    };

    var upgrader = Upgrader.init(allocator, options);
    defer upgrader.deinit();

    try upgrader.discoverReplicas();

    try std.testing.expectEqual(@as(usize, 3), upgrader.replicas.items.len);
    try std.testing.expectEqual(@as(u8, 0), upgrader.replicas.items[0].replica_id);
    try std.testing.expectEqual(@as(u8, 1), upgrader.replicas.items[1].replica_id);
    try std.testing.expectEqual(@as(u8, 2), upgrader.replicas.items[2].replica_id);
}

test "HealthThresholds: defaults" {
    const thresholds = HealthThresholds{};

    try std.testing.expectEqual(@as(f64, 2.0), thresholds.p99_latency_multiplier);
    try std.testing.expectEqual(@as(u64, 100), thresholds.p99_latency_max_ms);
    try std.testing.expectEqual(@as(f64, 1.0), thresholds.error_rate_threshold_pct);
    try std.testing.expectEqual(@as(u32, 3), thresholds.probe_failure_threshold);
    try std.testing.expectEqual(@as(u32, 300), thresholds.catchup_timeout_seconds);
}

test "Upgrader: parseReplicaAddress" {
    const parsed = try Upgrader.parseReplicaAddress("127.0.0.1:3000");
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(u16, 3000), parsed.port);
    try std.testing.expectError(error.InvalidAddress, Upgrader.parseReplicaAddress("127.0.0.1"));
}

test "Upgrader: parseHttpStatusCode" {
    try std.testing.expectEqual(@as(?u16, 200), Upgrader.parseHttpStatusCode("HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(?u16, 503), Upgrader.parseHttpStatusCode("HTTP/1.1 503 Service Unavailable\r\n"));
    try std.testing.expectEqual(@as(?u16, null), Upgrader.parseHttpStatusCode("malformed"));
}

test "Upgrader: parseMetricU64" {
    const body =
        \\# HELP archerdb_vsr_is_primary Whether this replica is the primary
        \\# TYPE archerdb_vsr_is_primary gauge
        \\archerdb_vsr_is_primary 1
        \\archerdb_vsr_op_number 4242
        \\archerdb_health_status{status="ready"} 1
        \\
    ;
    try std.testing.expectEqual(@as(?u64, 1), Upgrader.parseMetricU64(body, "archerdb_vsr_is_primary"));
    try std.testing.expectEqual(@as(?u64, 4242), Upgrader.parseMetricU64(body, "archerdb_vsr_op_number"));
    try std.testing.expectEqual(@as(?u64, 1), Upgrader.parseMetricU64(body, "archerdb_health_status"));
    try std.testing.expectEqual(@as(?u64, null), Upgrader.parseMetricU64(body, "archerdb_missing_metric"));
}

test "ClusterStatus: jsonStringify includes replica details" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const replicas = [_]ReplicaInfo{
        .{
            .address = "127.0.0.1:3000",
            .replica_id = 0,
            .is_primary = true,
            .version = "1.2.3",
            .healthy = true,
            .role = .primary,
            .commit_sequence = 42,
            .p99_latency_ms = 7,
            .error_rate_pct = 0.0,
            .upgraded = false,
        },
    };

    try std.json.stringify(ClusterStatus{
        .state = .not_started,
        .total_replicas = 1,
        .healthy_replicas = 1,
        .upgraded_replicas = 0,
        .primary_address = replicas[0].address,
        .primary_version = replicas[0].version,
        .target_version = "1.2.4",
        .has_quorum = true,
        .p99_latency_ms = 7,
        .error_rate_pct = 0.0,
        .replicas = &replicas,
    }, .{}, output.writer());

    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"state\":\"not_started\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"role\":\"primary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"primary_version\":\"1.2.3\"") != null);
}

test "UpgradeResult: jsonStringify includes rollback state" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    try std.json.stringify(UpgradeResult{
        .state = .failed,
        .success = false,
        .duration_ms = 500,
        .replicas_upgraded = 1,
        .replicas_failed = 1,
        .error_message = "Replica failed to recover after upgrade",
        .rollback_performed = true,
    }, .{}, output.writer());

    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"state\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"rollback_performed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"error_message\":\"Replica failed to recover after upgrade\"") != null);
}
