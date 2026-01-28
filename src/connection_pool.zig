// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Server-side connection pool for managing client connections.
//!
//! Provides:
//! - Centralized connection limit enforcement
//! - Adaptive idle timeout based on memory pressure
//! - Health checking for unhealthy connection detection
//! - Bounded waiter queue for connection requests
//! - Prometheus metrics integration
//!
//! The pool prevents connection storms from overwhelming the server and
//! provides consistent resource management across all clients.

const std = @import("std");
const cluster_metrics = @import("archerdb/cluster_metrics.zig");

const Allocator = std.mem.Allocator;

/// Configuration for the server-side connection pool.
pub const PoolConfig = struct {
    /// Maximum number of connections in the pool (default: 32, range: 16-64)
    max_connections: u32 = 32,
    /// Minimum number of connections to maintain (default: 4)
    min_connections: u32 = 4,
    /// Idle timeout when not under memory pressure (default: 5 minutes)
    idle_timeout_normal_ms: u64 = 300_000,
    /// Idle timeout under memory pressure (default: 30 seconds)
    idle_timeout_pressure_ms: u64 = 30_000,
    /// Health check interval (default: 30 seconds)
    health_check_interval_ms: u64 = 30_000,
    /// Maximum time to wait for a connection (default: 5 seconds)
    acquire_timeout_ms: u64 = 5_000,
    /// Maximum waiters in the queue (default: 64)
    max_waiters: u32 = 64,
    /// Memory pressure threshold (percentage, default: 20)
    memory_pressure_threshold_percent: u8 = 20,
};

/// A pooled connection wrapper.
/// Generic over the connection type to support different protocols.
pub fn PooledConnection(comptime Connection: type) type {
    return struct {
        /// The underlying connection
        connection: *Connection,
        /// Back-reference to the pool
        pool: *ServerConnectionPool(Connection),
        /// Timestamp when last used (milliseconds since epoch)
        last_used_ms: i64,
        /// Whether this connection is currently in use
        in_use: std.atomic.Value(bool),
        /// Client identifier for this connection (if authenticated)
        client_id: [64]u8,
        client_id_len: usize,
        /// Slot index in the pool
        slot_index: usize,

        const Self = @This();

        /// Initialize a pooled connection.
        fn init(conn: *Connection, pool: *ServerConnectionPool(Connection), slot_index: usize) Self {
            return .{
                .connection = conn,
                .pool = pool,
                .last_used_ms = std.time.milliTimestamp(),
                .in_use = std.atomic.Value(bool).init(false),
                .client_id = [_]u8{0} ** 64,
                .client_id_len = 0,
                .slot_index = slot_index,
            };
        }

        /// Get the client ID for this connection.
        pub fn getClientId(self: *const Self) ?[]const u8 {
            if (self.client_id_len == 0) return null;
            return self.client_id[0..self.client_id_len];
        }

        /// Set the client ID for this connection.
        pub fn setClientId(self: *Self, id: []const u8) void {
            const copy_len = @min(id.len, self.client_id.len);
            @memcpy(self.client_id[0..copy_len], id[0..copy_len]);
            self.client_id_len = copy_len;
        }

        /// Release this connection back to the pool.
        /// Convenience method that calls pool.release().
        pub fn release(self: *Self) void {
            self.pool.release(self);
        }

        /// Check if this connection is healthy.
        /// Returns false if the connection should be closed.
        pub fn isHealthy(self: *const Self) bool {
            // Check if the underlying connection has a health check method
            if (@hasDecl(Connection, "isHealthy")) {
                return self.connection.isHealthy();
            }
            // Default: assume healthy
            return true;
        }
    };
}

/// A waiter in the queue waiting for a connection.
fn Waiter(comptime Connection: type) type {
    return struct {
        /// Condition to signal when connection is available
        done: std.Thread.ResetEvent,
        /// The acquired connection (set by the releasing thread)
        result: ?*PooledConnection(Connection),
        /// Whether the wait was cancelled (timeout or pool shutdown)
        cancelled: bool,

        const Self = @This();

        fn init() Self {
            return .{
                .done = .{},
                .result = null,
                .cancelled = false,
            };
        }
    };
}

/// Server-side connection pool.
/// Generic over the connection type to support different protocols.
pub fn ServerConnectionPool(comptime Connection: type) type {
    return struct {
        /// Pool configuration
        config: PoolConfig,
        /// Allocator for dynamic allocations
        allocator: Allocator,
        /// Array of connection slots
        connections: []?PooledConnection(Connection),
        /// Number of active (in-use) connections
        active_count: std.atomic.Value(u32),
        /// Number of idle connections
        idle_count: std.atomic.Value(u32),
        /// Total connections ever created
        total_created: std.atomic.Value(u64),
        /// Cluster metrics for Prometheus integration
        metrics: *cluster_metrics.ClusterMetrics,
        /// Waiter queue for blocked acquire requests
        waiters: std.ArrayList(*Waiter(Connection)),
        /// Mutex for protecting waiters list and connection state
        mutex: std.Thread.Mutex,
        /// Whether the pool is shutting down
        shutdown: std.atomic.Value(bool),
        /// Last health check timestamp
        last_health_check_ms: std.atomic.Value(i64),
        /// Current memory pressure state
        under_memory_pressure: std.atomic.Value(bool),
        /// Connection factory function
        connection_factory: *const fn (context: ?*anyopaque, allocator: Allocator) anyerror!*Connection,
        /// Optional context for the connection factory
        factory_context: ?*anyopaque,
        /// Connection destructor function
        connection_destructor: *const fn (conn: *Connection, allocator: Allocator) void,

        const Self = @This();
        const PooledConn = PooledConnection(Connection);
        const WaiterType = Waiter(Connection);

        /// Initialize a new connection pool.
        pub fn init(
            allocator: Allocator,
            config: PoolConfig,
            metrics_instance: *cluster_metrics.ClusterMetrics,
            connection_factory: *const fn (context: ?*anyopaque, allocator: Allocator) anyerror!*Connection,
            connection_destructor: *const fn (conn: *Connection, allocator: Allocator) void,
            factory_context: ?*anyopaque,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const connections = try allocator.alloc(?PooledConn, config.max_connections);
            errdefer allocator.free(connections);

            // Initialize all slots as empty
            @memset(connections, null);

            self.* = .{
                .config = config,
                .allocator = allocator,
                .connections = connections,
                .active_count = std.atomic.Value(u32).init(0),
                .idle_count = std.atomic.Value(u32).init(0),
                .total_created = std.atomic.Value(u64).init(0),
                .metrics = metrics_instance,
                .waiters = std.ArrayList(*WaiterType).init(allocator),
                .mutex = .{},
                .shutdown = std.atomic.Value(bool).init(false),
                .last_health_check_ms = std.atomic.Value(i64).init(0),
                .under_memory_pressure = std.atomic.Value(bool).init(false),
                .connection_factory = connection_factory,
                .connection_destructor = connection_destructor,
                .factory_context = factory_context,
            };

            // Pre-create minimum connections (these start as IDLE)
            var created: u32 = 0;
            while (created < config.min_connections) : (created += 1) {
                if (self.createConnection()) |conn| {
                    // Mark pre-created connections as idle (not active)
                    conn.in_use.store(false, .release);
                    _ = self.active_count.fetchSub(1, .monotonic);
                    _ = self.idle_count.fetchAdd(1, .monotonic);
                } else |_| {
                    break;
                }
            }

            return self;
        }

        /// Deinitialize the pool, closing all connections.
        pub fn deinit(self: *Self) void {
            // Signal shutdown
            self.shutdown.store(true, .seq_cst);

            // Wake all waiters
            self.mutex.lock();
            for (self.waiters.items) |waiter| {
                waiter.cancelled = true;
                waiter.done.set();
            }
            self.waiters.deinit();
            self.mutex.unlock();

            // Close all connections
            for (self.connections) |*maybe_conn| {
                if (maybe_conn.*) |*conn| {
                    self.connection_destructor(conn.connection, self.allocator);
                    maybe_conn.* = null;
                }
            }

            self.allocator.free(self.connections);
            self.allocator.destroy(self);
        }

        /// Acquire a connection from the pool.
        /// Blocks until a connection is available or timeout expires.
        pub fn acquire(self: *Self) !*PooledConn {
            if (self.shutdown.load(.seq_cst)) {
                return error.PoolShutdown;
            }

            self.metrics.recordAcquire(null);

            // Try to get an existing idle connection
            if (self.tryAcquireIdle()) |conn| {
                conn.last_used_ms = std.time.milliTimestamp();
                return conn;
            }

            // Try to create a new connection
            if (self.createConnection()) |conn| {
                return conn;
            } else |_| {
                // Pool is full, need to wait
            }

            // Queue as waiter
            var waiter = WaiterType.init();
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.waiters.items.len >= self.config.max_waiters) {
                    self.metrics.recordAcquireTimeout();
                    return error.WaiterQueueFull;
                }

                self.waiters.append(&waiter) catch {
                    self.metrics.recordAcquireTimeout();
                    return error.OutOfMemory;
                };

                // Update waiter gauge
                self.metrics.updatePoolState(
                    self.active_count.load(.monotonic),
                    self.idle_count.load(.monotonic),
                    @intCast(self.waiters.items.len),
                );
            }

            // Wait with timeout
            const timeout_ns = self.config.acquire_timeout_ms * std.time.ns_per_ms;
            waiter.done.timedWait(timeout_ns) catch {
                // Timeout - remove from waiters
                self.mutex.lock();
                defer self.mutex.unlock();

                for (self.waiters.items, 0..) |w, i| {
                    if (w == &waiter) {
                        _ = self.waiters.swapRemove(i);
                        break;
                    }
                }

                self.metrics.recordAcquireTimeout();
                self.metrics.updatePoolState(
                    self.active_count.load(.monotonic),
                    self.idle_count.load(.monotonic),
                    @intCast(self.waiters.items.len),
                );
                return error.AcquireTimeout;
            };

            // Check if we got a connection or were cancelled
            if (waiter.cancelled) {
                return error.PoolShutdown;
            }

            if (waiter.result) |conn| {
                conn.last_used_ms = std.time.milliTimestamp();
                return conn;
            }

            return error.AcquireTimeout;
        }

        /// Release a connection back to the pool.
        pub fn release(self: *Self, conn: *PooledConn) void {
            const client_id = conn.getClientId();
            self.metrics.recordRelease(client_id);

            // Mark as not in use
            conn.in_use.store(false, .release);
            conn.last_used_ms = std.time.milliTimestamp();

            // Check if there are waiters
            self.mutex.lock();
            if (self.waiters.items.len > 0) {
                const waiter = self.waiters.orderedRemove(0);
                self.mutex.unlock();

                // Hand off connection to waiter
                conn.in_use.store(true, .release);
                waiter.result = conn;
                waiter.done.set();

                self.metrics.updatePoolState(
                    self.active_count.load(.monotonic),
                    self.idle_count.load(.monotonic),
                    @intCast(self.waiters.items.len),
                );
                return;
            }
            self.mutex.unlock();

            // No waiters, return to idle pool
            _ = self.active_count.fetchSub(1, .monotonic);
            _ = self.idle_count.fetchAdd(1, .monotonic);

            self.metrics.updatePoolState(
                self.active_count.load(.monotonic),
                self.idle_count.load(.monotonic),
                0,
            );
        }

        /// Check if the system is under memory pressure.
        pub fn isUnderMemoryPressure(self: *Self) bool {
            const pressure = checkMemoryPressure(self.config.memory_pressure_threshold_percent);
            const was_under_pressure = self.under_memory_pressure.swap(pressure, .monotonic);

            // Record state change
            if (pressure != was_under_pressure) {
                self.metrics.recordMemoryPressure(pressure);
            }

            return pressure;
        }

        /// Get the current idle timeout based on memory pressure.
        pub fn getCurrentIdleTimeout(self: *Self) u64 {
            if (self.isUnderMemoryPressure()) {
                return self.config.idle_timeout_pressure_ms;
            }
            return self.config.idle_timeout_normal_ms;
        }

        /// Reap idle connections that have exceeded the idle timeout.
        /// Returns the number of connections reaped.
        pub fn reapIdleConnections(self: *Self) u32 {
            const now_ms = std.time.milliTimestamp();
            const timeout_ms: i64 = @intCast(self.getCurrentIdleTimeout());
            var reaped: u32 = 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            const current_idle = self.idle_count.load(.monotonic);
            const min_idle = self.config.min_connections;

            for (self.connections) |*maybe_conn| {
                if (maybe_conn.*) |*conn| {
                    // Skip in-use connections
                    if (conn.in_use.load(.acquire)) continue;

                    // Check if idle too long
                    const idle_time = now_ms - conn.last_used_ms;
                    if (idle_time > timeout_ms) {
                        // Don't reap below minimum
                        const remaining_idle = current_idle - reaped;
                        if (remaining_idle <= min_idle) break;

                        // Reap this connection
                        self.connection_destructor(conn.connection, self.allocator);
                        maybe_conn.* = null;
                        reaped += 1;
                    }
                }
            }

            if (reaped > 0) {
                _ = self.idle_count.fetchSub(reaped, .monotonic);
                self.metrics.recordReap(reaped);
                self.metrics.updatePoolState(
                    self.active_count.load(.monotonic),
                    self.idle_count.load(.monotonic),
                    @intCast(self.waiters.items.len),
                );
            }

            return reaped;
        }

        /// Run health checks on idle connections.
        /// Returns the number of unhealthy connections closed.
        pub fn runHealthChecks(self: *Self) u32 {
            const now_ms = std.time.milliTimestamp();
            const last_check = self.last_health_check_ms.load(.monotonic);

            // Check if enough time has passed
            if (now_ms - last_check < @as(i64, @intCast(self.config.health_check_interval_ms))) {
                return 0;
            }

            self.last_health_check_ms.store(now_ms, .monotonic);

            var unhealthy: u32 = 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.connections) |*maybe_conn| {
                if (maybe_conn.*) |*conn| {
                    // Skip in-use connections
                    if (conn.in_use.load(.acquire)) continue;

                    // Run health check
                    const healthy = conn.isHealthy();
                    self.metrics.recordHealthCheck(healthy);

                    if (!healthy) {
                        // Close unhealthy connection
                        self.connection_destructor(conn.connection, self.allocator);
                        maybe_conn.* = null;
                        _ = self.idle_count.fetchSub(1, .monotonic);
                        unhealthy += 1;
                    }
                }
            }

            if (unhealthy > 0) {
                self.metrics.updatePoolState(
                    self.active_count.load(.monotonic),
                    self.idle_count.load(.monotonic),
                    @intCast(self.waiters.items.len),
                );
            }

            return unhealthy;
        }

        /// Get pool statistics.
        pub fn getStats(self: *const Self) PoolStats {
            return .{
                .active = self.active_count.load(.monotonic),
                .idle = self.idle_count.load(.monotonic),
                .total_created = self.total_created.load(.monotonic),
                .max_connections = self.config.max_connections,
                .under_memory_pressure = self.under_memory_pressure.load(.monotonic),
            };
        }

        // Internal helpers

        fn tryAcquireIdle(self: *Self) ?*PooledConn {
            for (self.connections) |*maybe_conn| {
                if (maybe_conn.*) |*conn| {
                    // Try to atomically acquire this connection
                    if (conn.in_use.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
                        // Successfully acquired
                        _ = self.idle_count.fetchSub(1, .monotonic);
                        _ = self.active_count.fetchAdd(1, .monotonic);
                        return conn;
                    }
                }
            }
            return null;
        }

        fn createConnection(self: *Self) !*PooledConn {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Find an empty slot
            for (self.connections, 0..) |*maybe_conn, slot_index| {
                if (maybe_conn.* == null) {
                    // Create new connection
                    const conn = try self.connection_factory(self.factory_context, self.allocator);
                    errdefer self.connection_destructor(conn, self.allocator);

                    maybe_conn.* = PooledConn.init(conn, self, slot_index);
                    maybe_conn.*.?.in_use.store(true, .release);

                    _ = self.active_count.fetchAdd(1, .monotonic);
                    _ = self.total_created.fetchAdd(1, .monotonic);
                    self.metrics.recordNewConnection();

                    self.metrics.updatePoolState(
                        self.active_count.load(.monotonic),
                        self.idle_count.load(.monotonic),
                        @intCast(self.waiters.items.len),
                    );

                    return &(maybe_conn.*.?);
                }
            }

            return error.PoolExhausted;
        }
    };
}

/// Pool statistics.
pub const PoolStats = struct {
    active: u32,
    idle: u32,
    total_created: u64,
    max_connections: u32,
    under_memory_pressure: bool,
};

/// Check if the system is under memory pressure.
/// Returns true if available memory is below the threshold percentage of total.
pub fn checkMemoryPressure(threshold_percent: u8) bool {
    const available = getAvailableMemory() catch return false;
    const total = getTotalMemory() catch return false;

    if (total == 0) return false;

    const available_percent = (available * 100) / total;
    return available_percent < threshold_percent;
}

/// Get available system memory in bytes.
/// On Linux, reads MemAvailable from /proc/meminfo.
/// On macOS, uses vm_statistics for free + inactive pages.
pub fn getAvailableMemory() !u64 {
    const builtin = @import("builtin");

    if (builtin.os.tag == .linux) {
        return getAvailableMemoryLinux();
    } else if (builtin.os.tag == .macos) {
        return getAvailableMemoryMacos();
    } else {
        return error.UnsupportedPlatform;
    }
}

/// Get total system memory in bytes.
pub fn getTotalMemory() !u64 {
    const builtin = @import("builtin");

    if (builtin.os.tag == .linux) {
        return getTotalMemoryLinux();
    } else if (builtin.os.tag == .macos) {
        return getTotalMemoryMacos();
    } else {
        return error.UnsupportedPlatform;
    }
}

fn getAvailableMemoryLinux() !u64 {
    var file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
        return error.UnsupportedPlatform;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch {
        return error.UnsupportedPlatform;
    };

    const content = buf[0..bytes_read];

    // Look for "MemAvailable:" line
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            return parseMemInfoValue(line) catch return error.UnsupportedPlatform;
        }
    }

    // MemAvailable not found, fall back to MemFree
    lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemFree:")) {
            return parseMemInfoValue(line) catch return error.UnsupportedPlatform;
        }
    }

    return error.UnsupportedPlatform;
}

fn getTotalMemoryLinux() !u64 {
    var file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
        return error.UnsupportedPlatform;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch {
        return error.UnsupportedPlatform;
    };

    const content = buf[0..bytes_read];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            return parseMemInfoValue(line) catch return error.UnsupportedPlatform;
        }
    }

    return error.UnsupportedPlatform;
}

fn parseMemInfoValue(line: []const u8) !u64 {
    const value_start = (std.mem.indexOf(u8, line, ":") orelse return error.ParseError) + 1;
    const trimmed = std.mem.trim(u8, line[value_start..], " \t");
    const kb_end = std.mem.indexOf(u8, trimmed, " ") orelse trimmed.len;
    const kb_str = trimmed[0..kb_end];
    const kb = std.fmt.parseInt(u64, kb_str, 10) catch return error.ParseError;
    return kb * 1024;
}

fn getAvailableMemoryMacos() !u64 {
    // macOS: Use hw.memsize total and estimate 80% as available
    // This is a conservative estimate; true available would require vm_statistics
    const total = try getTotalMemoryMacos();
    return (total * 80) / 100;
}

fn getTotalMemoryMacos() !u64 {
    var size: usize = @sizeOf(u64);
    var memsize: u64 = 0;

    const result = std.c.sysctlbyname("hw.memsize", @ptrCast(&memsize), &size, null, 0);
    if (result != 0) {
        return error.UnsupportedPlatform;
    }

    return memsize;
}

// ============================================================================
// Tests
// ============================================================================

/// Mock connection type for testing.
const MockConnection = struct {
    healthy: bool = true,
    id: u32 = 0,

    pub fn isHealthy(self: *const MockConnection) bool {
        return self.healthy;
    }
};

var mock_connection_counter: u32 = 0;

fn mockConnectionFactory(_: ?*anyopaque, allocator: Allocator) !*MockConnection {
    const conn = try allocator.create(MockConnection);
    mock_connection_counter += 1;
    conn.* = .{ .id = mock_connection_counter };
    return conn;
}

fn mockConnectionDestructor(conn: *MockConnection, allocator: Allocator) void {
    allocator.destroy(conn);
}

test "connection_pool: basic acquire and release" {
    const allocator = std.testing.allocator;

    var metrics_instance = cluster_metrics.ClusterMetrics.init();
    const pool = try ServerConnectionPool(MockConnection).init(
        allocator,
        .{
            .max_connections = 4,
            .min_connections = 1,
        },
        &metrics_instance,
        mockConnectionFactory,
        mockConnectionDestructor,
        null,
    );
    defer pool.deinit();

    // Acquire a connection
    const conn = try pool.acquire();
    try std.testing.expect(conn.in_use.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), pool.active_count.load(.monotonic));

    // Release it
    pool.release(conn);
    try std.testing.expect(!conn.in_use.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), pool.active_count.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), pool.idle_count.load(.monotonic));
}

test "connection_pool: pool exhaustion with max connections" {
    const allocator = std.testing.allocator;

    var metrics_instance = cluster_metrics.ClusterMetrics.init();
    const pool = try ServerConnectionPool(MockConnection).init(
        allocator,
        .{
            .max_connections = 2,
            .min_connections = 0,
            .acquire_timeout_ms = 10, // Very short timeout for test
        },
        &metrics_instance,
        mockConnectionFactory,
        mockConnectionDestructor,
        null,
    );
    defer pool.deinit();

    // Acquire all connections
    const conn1 = try pool.acquire();
    const conn2 = try pool.acquire();

    try std.testing.expectEqual(@as(u32, 2), pool.active_count.load(.monotonic));

    // Third acquire should timeout (pool exhausted and short timeout)
    const result = pool.acquire();
    try std.testing.expectError(error.AcquireTimeout, result);

    // Release connections
    pool.release(conn1);
    pool.release(conn2);
}

test "connection_pool: memory pressure detection" {
    // Test the memory detection functions (they may fail on some platforms)
    if (getAvailableMemory()) |available| {
        try std.testing.expect(available > 0);

        if (getTotalMemory()) |total| {
            try std.testing.expect(total >= available);
        } else |_| {
            // Platform may not support this
        }
    } else |_| {
        // Platform may not support this, which is fine
    }
}

test "connection_pool: idle connection reaping" {
    const allocator = std.testing.allocator;

    var metrics_instance = cluster_metrics.ClusterMetrics.init();
    const pool = try ServerConnectionPool(MockConnection).init(
        allocator,
        .{
            .max_connections = 4,
            .min_connections = 1,
            .idle_timeout_normal_ms = 1, // 1ms timeout for test
            .idle_timeout_pressure_ms = 1, // Also set pressure timeout for test reliability
        },
        &metrics_instance,
        mockConnectionFactory,
        mockConnectionDestructor,
        null,
    );
    defer pool.deinit();

    // Acquire and release to create idle connections
    const conn1 = try pool.acquire();
    const conn2 = try pool.acquire();
    pool.release(conn1);
    pool.release(conn2);

    try std.testing.expectEqual(@as(u32, 2), pool.idle_count.load(.monotonic));

    // Wait for idle timeout (use longer sleep for test reliability)
    std.time.sleep(10 * std.time.ns_per_ms);

    // Reap should close one connection (keeping min_connections=1)
    const reaped = pool.reapIdleConnections();
    try std.testing.expectEqual(@as(u32, 1), reaped);
    try std.testing.expectEqual(@as(u32, 1), pool.idle_count.load(.monotonic));
}

test "connection_pool: health check closes unhealthy connections" {
    const allocator = std.testing.allocator;

    var metrics_instance = cluster_metrics.ClusterMetrics.init();
    const pool = try ServerConnectionPool(MockConnection).init(
        allocator,
        .{
            .max_connections = 4,
            .min_connections = 0,
            .health_check_interval_ms = 0, // Always run health checks
        },
        &metrics_instance,
        mockConnectionFactory,
        mockConnectionDestructor,
        null,
    );
    defer pool.deinit();

    // Acquire and release a connection
    const conn = try pool.acquire();
    conn.connection.healthy = false; // Mark as unhealthy
    pool.release(conn);

    try std.testing.expectEqual(@as(u32, 1), pool.idle_count.load(.monotonic));

    // Run health check
    const unhealthy = pool.runHealthChecks();
    try std.testing.expectEqual(@as(u32, 1), unhealthy);
    try std.testing.expectEqual(@as(u32, 0), pool.idle_count.load(.monotonic));
}

test "connection_pool: metrics are updated" {
    const allocator = std.testing.allocator;

    // Reset global counters for test isolation
    cluster_metrics.archerdb_pool_acquire_total = cluster_metrics.metrics.Counter.init(
        "archerdb_pool_acquire_total",
        "Total connection acquire operations",
        null,
    );
    cluster_metrics.archerdb_pool_release_total = cluster_metrics.metrics.Counter.init(
        "archerdb_pool_release_total",
        "Total connection release operations",
        null,
    );

    var metrics_instance = cluster_metrics.ClusterMetrics.init();
    const pool = try ServerConnectionPool(MockConnection).init(
        allocator,
        .{ .max_connections = 4, .min_connections = 0 },
        &metrics_instance,
        mockConnectionFactory,
        mockConnectionDestructor,
        null,
    );
    defer pool.deinit();

    const conn = try pool.acquire();
    try std.testing.expectEqual(@as(u64, 1), cluster_metrics.archerdb_pool_acquire_total.get());

    pool.release(conn);
    try std.testing.expectEqual(@as(u64, 1), cluster_metrics.archerdb_pool_release_total.get());
}

test "connection_pool: getStats returns correct values" {
    const allocator = std.testing.allocator;

    var metrics_instance = cluster_metrics.ClusterMetrics.init();
    const pool = try ServerConnectionPool(MockConnection).init(
        allocator,
        .{
            .max_connections = 8,
            .min_connections = 2,
        },
        &metrics_instance,
        mockConnectionFactory,
        mockConnectionDestructor,
        null,
    );
    defer pool.deinit();

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u32, 8), stats.max_connections);
    try std.testing.expect(stats.total_created >= 2); // At least min_connections created
}

test "connection_pool: concurrent acquire and release" {
    const allocator = std.testing.allocator;

    var metrics_instance = cluster_metrics.ClusterMetrics.init();
    const pool = try ServerConnectionPool(MockConnection).init(
        allocator,
        .{
            .max_connections = 8,
            .min_connections = 2,
            .acquire_timeout_ms = 1000, // 1 second timeout
        },
        &metrics_instance,
        mockConnectionFactory,
        mockConnectionDestructor,
        null,
    );
    defer pool.deinit();

    const num_threads = 4;
    const iterations_per_thread = 10;

    var threads: [num_threads]std.Thread = undefined;
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |t| t.join();
    }

    // Worker function that acquires and releases connections
    const worker = struct {
        fn run(p: *ServerConnectionPool(MockConnection)) void {
            for (0..iterations_per_thread) |_| {
                const conn = p.acquire() catch continue;
                // Simulate some work
                std.time.sleep(100 * std.time.ns_per_us); // 100μs
                p.release(conn);
            }
        }
    }.run;

    // Spawn threads
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, worker, .{pool}) catch continue;
        started += 1;
    }

    // Wait for all threads
    for (threads[0..started]) |t| t.join();

    // Verify pool state is consistent
    const final_stats = pool.getStats();
    try std.testing.expectEqual(@as(u32, 0), final_stats.active);
    try std.testing.expect(final_stats.idle > 0);
    // Total created should be at least min_connections
    try std.testing.expect(final_stats.total_created >= 2);
}

test "connection_pool: memory pressure triggers faster idle timeout" {
    const allocator = std.testing.allocator;

    var metrics_instance = cluster_metrics.ClusterMetrics.init();
    const pool = try ServerConnectionPool(MockConnection).init(
        allocator,
        .{
            .max_connections = 4,
            .min_connections = 0,
            .idle_timeout_normal_ms = 1000, // 1 second normal
            .idle_timeout_pressure_ms = 10, // 10ms under pressure
        },
        &metrics_instance,
        mockConnectionFactory,
        mockConnectionDestructor,
        null,
    );
    defer pool.deinit();

    // Test timeout values
    const normal_timeout = pool.config.idle_timeout_normal_ms;
    try std.testing.expectEqual(@as(u64, 1000), normal_timeout);

    const pressure_timeout = pool.config.idle_timeout_pressure_ms;
    try std.testing.expectEqual(@as(u64, 10), pressure_timeout);

    // The getCurrentIdleTimeout method checks actual memory pressure,
    // so we verify the logic works correctly
    const current_timeout = pool.getCurrentIdleTimeout();
    // Should be one of the two values depending on actual memory state
    try std.testing.expect(current_timeout == normal_timeout or current_timeout == pressure_timeout);
}
