// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! CDC Runner Stub - ArcherDB Geospatial Database
//!
//! The Change Data Capture (CDC) feature is not yet implemented for ArcherDB's
//! geospatial operations. The original TigerBeetle CDC was for financial
//! change events.
//!
//! ArcherDB will implement geospatial event streaming in a future release.
//! For real-time event streaming, use the client SDKs with polling queries.

const std = @import("std");

/// AMQP configuration constants stub.
pub const amqp = struct {
    /// Default AMQP TCP port (standard RabbitMQ port).
    pub const tcp_port_default: u16 = 5672;
};

pub const Runner = struct {
    const Self = @This();

    /// Initialize the CDC runner (stub - returns error).
    pub fn init(
        self: *Self,
        allocator: std.mem.Allocator,
        time: anytype,
        options: anytype,
    ) !void {
        _ = self;
        _ = allocator;
        _ = time;
        _ = options;

        std.log.err(
            \\
            \\ArcherDB CDC (Change Data Capture) - Not Yet Implemented
            \\============================================================
            \\
            \\The AMQP/CDC feature is not yet implemented for ArcherDB's
            \\geospatial operations.
            \\
            \\For real-time event streaming, use the client SDKs with:
            \\  - query_latest: Poll for most recent events
            \\  - query_uuid: Track specific entities
            \\  - query_radius: Monitor geographic areas
            \\
            \\For more information: https://archerdb.io/docs
            \\
        , .{});

        return error.NotImplemented;
    }

    /// Deinitialize the CDC runner (stub).
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Tick the CDC runner (stub).
    pub fn tick(self: *Self) void {
        _ = self;
    }
};
