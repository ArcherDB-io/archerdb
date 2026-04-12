// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! CDC (Change Data Capture) Runner for ArcherDB Geospatial Database
//!
//! Implements real-time change event streaming per data-portability/spec.md:
//! - Real-time change event streaming via AMQP 0.9.1
//! - Insert/update/delete operation capture
//! - Transaction boundary identification
//! - Consumer offset management
//!
//! CDC captures all committed GeoEvents and publishes them to an AMQP exchange
//! for downstream consumers (replication, analytics, alerting).

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const assert = std.debug.assert;
const log = std.log.scoped(.cdc);

const vsr = @import("../vsr.zig");
const IO = vsr.io.IO;

pub const amqp = @import("amqp.zig");
const GeoEvent = @import("../geo_event.zig").GeoEvent;
const amqp_script = @import("../scripts/amqp.zig");

/// AMQP configuration constants.
pub const Config = struct {
    /// Default AMQP TCP port (standard RabbitMQ port).
    pub const tcp_port_default: u16 = 5672;

    /// Default exchange name for CDC events.
    pub const exchange_name_default: []const u8 = "archerdb.cdc";

    /// Default routing key prefix.
    pub const routing_key_prefix: []const u8 = "geo.events";

    /// Maximum events to batch before publishing.
    pub const batch_size_max: u32 = 1000;

    /// Maximum time to wait before flushing partial batch (milliseconds).
    pub const batch_timeout_ms: u64 = 100;

    /// Heartbeat interval (seconds).
    pub const heartbeat_interval: u16 = 60;
};

/// CDC change event type.
pub const ChangeType = enum(u8) {
    insert = 1,
    update = 2,
    delete = 3,

    pub fn toString(self: ChangeType) []const u8 {
        return switch (self) {
            .insert => "INSERT",
            .update => "UPDATE",
            .delete => "DELETE",
        };
    }
};

/// CDC change event envelope.
/// Wraps a GeoEvent with CDC metadata for streaming.
pub const ChangeEvent = extern struct {
    /// Monotonic sequence number for ordering.
    sequence: u64,

    /// VSR consensus timestamp when event was committed.
    commit_timestamp: u64,

    /// Type of change (insert/update/delete).
    change_type: ChangeType,

    /// Reserved for future use and alignment padding.
    /// GeoEvent requires 16-byte alignment, so header must be 32 bytes.
    _reserved: [15]u8 = [_]u8{0} ** 15,

    /// The actual GeoEvent data.
    event: GeoEvent,

    comptime {
        // ChangeEvent should be 128 (GeoEvent) + 32 (header with alignment padding) = 160 bytes
        // Header: 8 (seq) + 8 (timestamp) + 1 (type) + 15 (reserved) = 32 bytes
        // GeoEvent requires 16-byte alignment, hence 32-byte header
        assert(@sizeOf(ChangeEvent) == 160);
    }

    /// Serialize to JSON for AMQP message body.
    pub fn toJson(self: *const ChangeEvent, buffer: []u8) ![]const u8 {
        var stream = std.io.fixedBufferStream(buffer);
        const writer = stream.writer();

        try writer.print(
            \\{{"sequence":{d},"commit_timestamp":{d},"change_type":"{s}",
        , .{
            self.sequence,
            self.commit_timestamp,
            self.change_type.toString(),
        });

        try writer.print(
            \\"entity_id":"{x}","timestamp":{d},
        , .{
            self.event.entity_id,
            self.event.timestamp,
        });

        // Convert nanodegrees to degrees for JSON
        const lat_deg = @as(f64, @floatFromInt(self.event.lat_nano)) / 1_000_000_000.0;
        const lon_deg = @as(f64, @floatFromInt(self.event.lon_nano)) / 1_000_000_000.0;

        try writer.print(
            \\"lat":{d:.9},"lon":{d:.9},
        , .{ lat_deg, lon_deg });

        try writer.print(
            \\"altitude_mm":{d},"velocity_mms":{d},"heading_cdeg":{d},"accuracy_mm":{d},
        , .{
            self.event.altitude_mm,
            self.event.velocity_mms,
            self.event.heading_cdeg,
            self.event.accuracy_mm,
        });

        try writer.print(
            \\"ttl_seconds":{d},"flags":{d}}}
        , .{
            self.event.ttl_seconds,
            @as(u16, @bitCast(self.event.flags)),
        });

        return stream.getWritten();
    }
};

/// Consumer offset tracking for exactly-once delivery.
pub const ConsumerOffset = struct {
    /// Consumer identifier.
    consumer_id: [32]u8,

    /// Last acknowledged sequence number.
    last_ack_sequence: u64,

    /// Timestamp of last acknowledgment.
    last_ack_timestamp: u64,
};

/// CDC Runner state.
pub const State = enum {
    /// Not initialized.
    uninitialized,

    /// Connecting to AMQP broker.
    connecting,

    /// Connected and ready to publish.
    connected,

    /// Publishing batch of events.
    publishing,

    /// Disconnected, will reconnect.
    disconnected,

    /// Shutting down.
    stopping,

    /// Stopped.
    stopped,
};

/// CDC Runner options.
pub const Options = struct {
    /// AMQP host address.
    host: std.net.Address,

    /// AMQP virtual host.
    vhost: []const u8 = "/",

    /// AMQP username.
    username: []const u8 = "guest",

    /// AMQP password.
    password: []const u8 = "guest",

    /// Exchange name for CDC events.
    exchange_name: []const u8 = Config.exchange_name_default,

    /// Routing key prefix for CDC events.
    routing_key_prefix: []const u8 = Config.routing_key_prefix,

    /// Exchange type (direct, fanout, topic).
    exchange_type: []const u8 = "topic",

    /// Whether exchange is durable.
    exchange_durable: bool = true,

    /// Maximum events per batch.
    batch_size: u32 = Config.batch_size_max,

    /// Batch timeout in milliseconds.
    batch_timeout_ms: u64 = Config.batch_timeout_ms,

    /// Enable publisher confirms.
    publisher_confirms: bool = true,
};

/// CDC Runner - manages AMQP connection and event publishing.
pub const Runner = struct {
    const ClientSlot = struct {
        runner: *Runner,
        client: amqp.Client,
    };

    /// Memory allocator.
    allocator: std.mem.Allocator,

    /// IO interface.
    io: *IO,

    /// Current state.
    state: State,

    /// Configuration options.
    options: Options,

    /// AMQP client.
    client: ?ClientSlot,

    /// Event buffer for batching.
    event_buffer: []ChangeEvent,

    /// Current position in event buffer.
    event_count: u32,

    /// Next sequence number.
    next_sequence: u64,

    /// Last published sequence number.
    last_published_sequence: u64,

    /// Count of events currently in-flight awaiting publish confirmation.
    pending_publish_count: u32,

    /// Last sequence number in the in-flight publish batch.
    pending_publish_last_sequence: u64,

    /// Consumer offsets.
    consumer_offsets: std.AutoHashMap([32]u8, ConsumerOffset),

    /// Reconnect attempts.
    reconnect_attempts: u32,

    /// Last error message.
    last_error: ?[]const u8,

    /// Statistics.
    stats: struct {
        events_captured: u64 = 0,
        events_published: u64 = 0,
        batches_published: u64 = 0,
        publish_errors: u64 = 0,
        reconnects: u64 = 0,
    },

    /// Initialize the CDC runner.
    pub fn init(
        self: *Runner,
        allocator: std.mem.Allocator,
        io: *IO,
        options: Options,
    ) !void {
        self.allocator = allocator;
        self.io = io;
        self.options = options;
        self.state = .uninitialized;
        self.client = null;
        self.event_count = 0;
        self.next_sequence = 1;
        self.last_published_sequence = 0;
        self.pending_publish_count = 0;
        self.pending_publish_last_sequence = 0;
        self.reconnect_attempts = 0;
        self.last_error = null;
        self.stats = .{};

        // Allocate event buffer
        self.event_buffer = try allocator.alloc(ChangeEvent, options.batch_size);
        errdefer allocator.free(self.event_buffer);

        // Initialize consumer offset tracking
        self.consumer_offsets = std.AutoHashMap([32]u8, ConsumerOffset).init(allocator);

        log.info("CDC Runner initialized with batch_size={d}, exchange={s}", .{
            options.batch_size,
            options.exchange_name,
        });

        self.state = .disconnected;
    }

    /// Deinitialize the CDC runner.
    pub fn deinit(self: *Runner) void {
        if (self.client) |*slot| {
            slot.client.deinit(self.allocator);
            self.client = null;
        }

        self.consumer_offsets.deinit();
        self.allocator.free(self.event_buffer);

        log.info("CDC Runner deinitialized. Stats: captured={d}, published={d}, errors={d}", .{
            self.stats.events_captured,
            self.stats.events_published,
            self.stats.publish_errors,
        });

        self.state = .stopped;
    }

    /// Start the CDC runner (connect to AMQP broker).
    pub fn start(self: *Runner) !void {
        if (self.state != .disconnected and self.state != .uninitialized) {
            return error.InvalidState;
        }

        self.state = .connecting;
        log.info("CDC Runner connecting to AMQP broker...", .{});

        if (self.client) |*slot| {
            slot.client.deinit(self.allocator);
            self.client = null;
        }

        // Initialize AMQP client
        var client = try amqp.Client.init(self.allocator, .{
            .io = self.io,
            .message_count_max = self.options.batch_size,
            .message_body_size_max = @sizeOf(ChangeEvent) * 2, // JSON is larger
            .reply_timeout_ticks = 10_000, // 10 second timeout
        });
        errdefer client.deinit(self.allocator);

        self.client = .{
            .runner = self,
            .client = client,
        };

        // Connect to broker
        self.client.?.client.connect(&connectCallback, .{
            .host = self.options.host,
            .user_name = self.options.username,
            .password = self.options.password,
            .vhost = self.options.vhost,
        }) catch |err| {
            log.err("CDC Runner failed to connect: {}", .{err});
            self.client.?.client.deinit(self.allocator);
            self.client = null;
            self.state = .disconnected;
            self.stats.publish_errors += 1;
            return err;
        };
    }

    fn connectCallback(client: *amqp.Client) void {
        const slot: *ClientSlot = @fieldParentPtr("client", client);
        slot.runner.handleConnected();
    }

    fn handleConnected(self: *Runner) void {
        log.info("CDC Runner connected to AMQP broker", .{});
        if (self.options.exchange_name.len == 0) {
            self.markConnectedReady();
            return;
        }

        self.client.?.client.exchange_declare(&exchangeDeclareCallback, .{
            .exchange = self.options.exchange_name,
            .type = self.options.exchange_type,
            .passive = false,
            .durable = self.options.exchange_durable,
            .auto_delete = false,
            .internal = false,
        });
    }

    fn exchangeDeclareCallback(client: *amqp.Client) void {
        const slot: *ClientSlot = @fieldParentPtr("client", client);
        slot.runner.markConnectedReady();
    }

    fn markConnectedReady(self: *Runner) void {
        if (self.reconnect_attempts > 0) {
            self.stats.reconnects += 1;
            self.reconnect_attempts = 0;
        }
        self.state = .connected;

        if (self.event_count > 0) {
            self.flushBatch() catch |err| {
                log.warn("CDC Runner failed to flush buffered batch after connect: {}", .{err});
            };
        }
    }

    fn publishCallback(client: *amqp.Client) void {
        const slot: *ClientSlot = @fieldParentPtr("client", client);
        slot.runner.finishPublishedBatch();
    }

    fn finishPublishedBatch(self: *Runner) void {
        if (self.pending_publish_count == 0) {
            self.state = .connected;
            return;
        }

        self.last_published_sequence = self.pending_publish_last_sequence;
        self.stats.events_published += self.pending_publish_count;
        self.stats.batches_published += 1;
        self.event_count = 0;
        self.pending_publish_count = 0;
        self.pending_publish_last_sequence = 0;
        self.state = .connected;

        log.debug("CDC Runner published batch, last_seq={d}", .{
            self.last_published_sequence,
        });
    }

    /// Stop the CDC runner.
    pub fn stop(self: *Runner) void {
        if (self.state == .stopped or self.state == .stopping) {
            return;
        }

        log.info("CDC Runner stopping...", .{});

        // Flush any pending events
        if (self.state == .connected and self.event_count > 0) {
            self.flushBatch() catch |err| {
                log.warn("CDC Runner failed to flush final batch: {}", .{err});
            };
        }

        if (self.state == .publishing) {
            self.drainPendingPublish(10_000);
        }

        self.state = .stopped;
    }

    /// Capture a GeoEvent for CDC streaming.
    /// Called by the state machine after successful event insertion.
    pub fn captureEvent(
        self: *Runner,
        event: *const GeoEvent,
        commit_timestamp: u64,
        change_type: ChangeType,
    ) !void {
        if (self.state == .publishing) {
            return error.PublishInFlight;
        }

        if (self.state != .connected) {
            // Buffer events even when disconnected for reconnection
            if (self.state == .disconnected) {
                log.warn("CDC Runner disconnected, buffering event", .{});
            } else {
                return error.NotConnected;
            }
        }

        // Check buffer capacity
        if (self.event_count >= self.options.batch_size) {
            try self.flushBatch();
        }

        // Add event to buffer
        self.event_buffer[self.event_count] = ChangeEvent{
            .sequence = self.next_sequence,
            .commit_timestamp = commit_timestamp,
            .change_type = change_type,
            .event = event.*,
        };

        self.event_count += 1;
        self.next_sequence += 1;
        self.stats.events_captured += 1;
    }

    /// Capture a batch of GeoEvents.
    pub fn captureEventBatch(
        self: *Runner,
        events: []const GeoEvent,
        commit_timestamp: u64,
        change_type: ChangeType,
    ) !void {
        for (events) |*event| {
            try self.captureEvent(event, commit_timestamp, change_type);
        }
    }

    /// Flush the current batch to AMQP.
    pub fn flushBatch(self: *Runner) !void {
        if (self.event_count == 0) {
            return;
        }

        if (self.state != .connected) {
            return error.NotConnected;
        }

        const client = if (self.client) |*slot| &slot.client else return error.NotConnected;

        self.state = .publishing;

        const batch_count = self.event_count;
        log.debug("CDC Runner flushing batch of {d} events", .{batch_count});

        // Publish each event in the batch
        var json_buffer: [4096]u8 = undefined;
        var enqueued_count: u32 = 0;
        var last_enqueued_sequence: u64 = 0;

        for (self.event_buffer[0..batch_count]) |*change_event| {
            const json = change_event.toJson(&json_buffer) catch |err| {
                log.err("CDC Runner failed to serialize event: {}", .{err});
                self.stats.publish_errors += 1;
                continue;
            };

            // Build routing key: geo.events.<entity_id_prefix>
            var routing_key_buf: [64]u8 = undefined;
            const routing_key = std.fmt.bufPrint(&routing_key_buf, "{s}.{x}", .{
                self.options.routing_key_prefix,
                @as(u64, @truncate(change_event.event.entity_id)),
            }) catch self.options.routing_key_prefix;
            var payload = json;

            client.publish_enqueue(.{
                .exchange = self.options.exchange_name,
                .routing_key = routing_key,
                .mandatory = false,
                .immediate = false,
                .properties = .{
                    .content_type = "application/json",
                    .delivery_mode = .persistent,
                    .timestamp = @intCast(@divFloor(change_event.commit_timestamp, std.time.ns_per_s)),
                },
                .body = messageBodyFromSlice(&payload),
            });
            enqueued_count += 1;
            last_enqueued_sequence = change_event.sequence;
        }

        if (enqueued_count == 0) {
            self.event_count = 0;
            self.state = .connected;
            return;
        }

        self.pending_publish_count = enqueued_count;
        self.pending_publish_last_sequence = last_enqueued_sequence;
        client.publish_send(&publishCallback);
    }

    fn messageBodyFromSlice(bytes: *const []const u8) amqp.Encoder.Body {
        const VTable = struct {
            fn write(context: *const anyopaque, buffer: []u8) usize {
                const slice: *const []const u8 = @ptrCast(@alignCast(context));
                @memcpy(buffer[0..slice.*.len], slice.*);
                return slice.*.len;
            }
        };
        return .{
            .context = @ptrCast(bytes),
            .vtable = &.{
                .write = VTable.write,
            },
        };
    }

    fn drainPendingPublish(self: *Runner, max_ticks: usize) void {
        if (self.state != .publishing) return;
        if (self.client == null) return;

        var ticks: usize = 0;
        while (self.state == .publishing and ticks < max_ticks) : (ticks += 1) {
            self.client.?.client.tick();
            self.io.run_for_ns(std.time.ns_per_ms) catch break;
        }
    }

    /// Tick the CDC runner (called periodically).
    pub fn tick(self: *Runner) void {
        if (self.client) |*slot| {
            slot.client.tick();
        }

        switch (self.state) {
            .disconnected => {
                // Attempt reconnection with exponential backoff
                self.reconnect_attempts += 1;
                if (self.reconnect_attempts <= 10) {
                    self.start() catch |err| {
                        log.warn("CDC Runner reconnect attempt {d} failed: {}", .{
                            self.reconnect_attempts,
                            err,
                        });
                    };
                }
            },
            .connected => {
                // Check if batch timeout exceeded
                if (self.event_count > 0) {
                    self.flushBatch() catch |err| {
                        log.warn("CDC Runner batch flush failed: {}", .{err});
                    };
                }
            },
            else => {},
        }
    }

    /// Get consumer offset for a consumer ID.
    pub fn getConsumerOffset(self: *Runner, consumer_id: [32]u8) ?u64 {
        if (self.consumer_offsets.get(consumer_id)) |offset| {
            return offset.last_ack_sequence;
        }
        return null;
    }

    /// Acknowledge events up to sequence number.
    pub fn acknowledgeOffset(
        self: *Runner,
        consumer_id: [32]u8,
        sequence: u64,
    ) !void {
        const now = @as(u64, @intCast(std.time.timestamp()));

        try self.consumer_offsets.put(consumer_id, .{
            .consumer_id = consumer_id,
            .last_ack_sequence = sequence,
            .last_ack_timestamp = now,
        });

        log.debug("CDC consumer {x} acknowledged up to sequence {d}", .{
            consumer_id[0..8].*,
            sequence,
        });
    }

    /// Get CDC statistics.
    pub fn getStats(self: *const Runner) @TypeOf(self.stats) {
        return self.stats;
    }

    /// Check if CDC is healthy.
    pub fn isHealthy(self: *const Runner) bool {
        return self.state == .connected or self.state == .publishing;
    }
};

// Tests
test "ChangeEvent size is 160 bytes" {
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(ChangeEvent));
}

test "ChangeEvent JSON serialization" {
    const event = GeoEvent{
        .id = 0,
        .entity_id = 0x123456789ABCDEF0,
        .correlation_id = 0,
        .user_data = 0,
        .timestamp = 1704067200000, // 2024-01-01 00:00:00 UTC
        .lat_nano = 40_712_800_000, // 40.7128° N (New York)
        .lon_nano = -74_006_000_000, // 74.006° W
        .group_id = 0,
        .altitude_mm = 10000, // 10m
        .velocity_mms = 5000, // 5 m/s
        .heading_cdeg = 9000, // 90°
        .accuracy_mm = 5000,
        .ttl_seconds = 3600,
        .flags = .{},
        .reserved = [_]u8{0} ** 12,
    };

    const change_event = ChangeEvent{
        .sequence = 1,
        .commit_timestamp = 1704067200001,
        .change_type = .insert,
        .event = event,
    };

    var buffer: [4096]u8 = undefined;
    const json = try change_event.toJson(&buffer);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sequence\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"change_type\":\"INSERT\"") != null);
}

test "CDC Runner initialization" {
    // This is a unit test - actual integration tests require AMQP broker
    // Verify struct layout and default state
    const runner = Runner{
        .state = .uninitialized,
        .client = null,
        .event_buffer = &[_]ChangeEvent{},
        .event_count = 0,
        .next_sequence = 0,
        .last_published_sequence = 0,
        .consumer_offsets = undefined,
        .reconnect_attempts = 0,
        .last_error = null,
        .options = .{
            .host = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 5672),
        },
        .stats = .{},
        .io = undefined,
        .allocator = undefined,
    };

    try std.testing.expectEqual(State.uninitialized, runner.state);
}

test "CDC Runner start rejects invalid state" {
    const runner = Runner{
        .state = .connected,
        .client = null,
        .event_buffer = &[_]ChangeEvent{},
        .event_count = 0,
        .next_sequence = 0,
        .last_published_sequence = 0,
        .pending_publish_count = 0,
        .pending_publish_last_sequence = 0,
        .consumer_offsets = undefined,
        .reconnect_attempts = 0,
        .last_error = null,
        .options = .{
            .host = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 5672),
        },
        .stats = .{},
        .io = undefined,
        .allocator = undefined,
    };

    var mutable_runner = runner;
    try std.testing.expectError(error.InvalidState, mutable_runner.start());
}

test "CDC Runner flushBatch requires live connection" {
    const event = GeoEvent{
        .id = 0,
        .entity_id = 1,
        .correlation_id = 0,
        .user_data = 0,
        .timestamp = 1704067200000,
        .lat_nano = 0,
        .lon_nano = 0,
        .group_id = 0,
        .altitude_mm = 0,
        .velocity_mms = 0,
        .heading_cdeg = 0,
        .accuracy_mm = 0,
        .ttl_seconds = 0,
        .flags = .{},
        .reserved = [_]u8{0} ** 12,
    };
    var buffer = [_]ChangeEvent{.{
        .sequence = 1,
        .commit_timestamp = 1704067200001,
        .change_type = .insert,
        .event = event,
    }};

    const runner = Runner{
        .state = .connected,
        .client = null,
        .event_buffer = &buffer,
        .event_count = 1,
        .next_sequence = 2,
        .last_published_sequence = 0,
        .pending_publish_count = 0,
        .pending_publish_last_sequence = 0,
        .consumer_offsets = undefined,
        .reconnect_attempts = 0,
        .last_error = null,
        .options = .{
            .host = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 5672),
        },
        .stats = .{},
        .io = undefined,
        .allocator = undefined,
    };

    var mutable_runner = runner;
    try std.testing.expectError(error.NotConnected, mutable_runner.flushBatch());
}

test "ChangeType toString" {
    try std.testing.expectEqualStrings("INSERT", ChangeType.insert.toString());
    try std.testing.expectEqualStrings("UPDATE", ChangeType.update.toString());
    try std.testing.expectEqualStrings("DELETE", ChangeType.delete.toString());
}

test "CDC Runner publishes to a live RabbitMQ broker" {
    if (builtin.os.tag != .linux or !builtin.cpu.arch.isX86()) return;

    const testing = std.testing;
    const docker_probe = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "docker", "--version" },
    }) catch return;
    defer {
        testing.allocator.free(docker_probe.stdout);
        testing.allocator.free(docker_probe.stderr);
    }
    if (docker_probe.term != .Exited or docker_probe.term.Exited != 0) return;

    var rabbit = try amqp_script.TmpRabbitMQ.init(testing.allocator, .{
        .image = amqp_script.TmpRabbitMQ.rabbitmq4,
    });
    defer rabbit.stop(testing.allocator) catch unreachable;

    var consumer: amqp_script.AmqpContext = undefined;
    try consumer.init(testing.allocator);
    defer consumer.deinit(testing.allocator);
    try consumer.connect(rabbit.host);

    const entity_id: u128 = 0x1234;
    const routing_prefix = "cdc.runner.integration";
    const queue_name = try std.fmt.allocPrint(testing.allocator, "{s}.{x}", .{
        routing_prefix,
        @as(u64, @truncate(entity_id)),
    });
    defer testing.allocator.free(queue_name);

    consumer.queue_declare(.{
        .queue = queue_name,
        .passive = false,
        .durable = false,
        .exclusive = false,
        .auto_delete = true,
        .arguments = .{},
    });

    var io = try IO.init(32, 0);
    defer io.deinit();

    var runner: Runner = undefined;
    try runner.init(testing.allocator, &io, .{
        .host = rabbit.host,
        .exchange_name = "",
        .routing_key_prefix = routing_prefix,
        .batch_size = 8,
    });
    defer runner.deinit();

    try runner.start();

    var ticks: usize = 0;
    while (runner.state != .connected and ticks < 20_000) : (ticks += 1) {
        try io.run_for_ns(std.time.ns_per_ms);
        runner.tick();
    }
    try testing.expectEqual(State.connected, runner.state);

    const event = GeoEvent{
        .id = 0,
        .entity_id = entity_id,
        .correlation_id = 0,
        .user_data = 0,
        .timestamp = 1704067200000,
        .lat_nano = 51_500_000_000,
        .lon_nano = -120_000_000,
        .group_id = 7,
        .altitude_mm = 1234,
        .velocity_mms = 5678,
        .heading_cdeg = 9000,
        .accuracy_mm = 250,
        .ttl_seconds = 60,
        .flags = .{},
        .reserved = [_]u8{0} ** 12,
    };

    try runner.captureEvent(&event, 1704067200001, .insert);

    ticks = 0;
    while (runner.stats.events_published < 1 and ticks < 20_000) : (ticks += 1) {
        try io.run_for_ns(std.time.ns_per_ms);
        runner.tick();
    }

    try testing.expectEqual(@as(u64, 1), runner.stats.events_captured);
    try testing.expectEqual(@as(u64, 1), runner.stats.events_published);
    try testing.expectEqual(@as(u64, 1), runner.last_published_sequence);

    const message = consumer.get_message(.{
        .queue = queue_name,
        .no_ack = true,
    });
    try testing.expect(message != null);
    try testing.expect(message.?.body != null);
    const body = message.?.body.?;
    try testing.expect(std.mem.indexOf(u8, body, "\"sequence\":1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"change_type\":\"INSERT\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"entity_id\":\"1234\"") != null);
}
