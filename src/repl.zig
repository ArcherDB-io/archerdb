// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// REPL Stub - ArcherDB Geospatial Database
//
// The interactive REPL is not yet implemented for ArcherDB's geospatial operations.
// Use the client SDKs (Python, Go, Java, Node.js, Rust) to interact with the database.
//
// Example operations available via SDKs:
//   - insert_events: Insert geospatial events
//   - upsert_events: Upsert geospatial events
//   - delete_entities: Delete entities by ID
//   - query_uuid: Query events by entity UUID
//   - query_radius: Query events within a radius
//   - query_polygon: Query events within a polygon
//   - query_latest: Query most recent events globally

const std = @import("std");
const vsr = @import("vsr.zig");
const IO = vsr.io.IO;
const Time = vsr.time.Time;

pub fn ReplType(comptime MessageBus: type) type {
    _ = MessageBus;

    return struct {
        pub fn init(
            gpa: std.mem.Allocator,
            io: *IO,
            time: Time,
            options: anytype,
        ) !@This() {
            _ = gpa;
            _ = io;
            _ = time;
            _ = options;
            return .{};
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            _ = self;
            _ = gpa;
        }

        pub fn run(self: *@This(), statements: []const u8) !void {
            _ = self;
            _ = statements;

            const stderr = std.io.getStdErr().writer();
            try stderr.print(
                \\
                \\ArcherDB REPL - Geospatial Database
                \\====================================
                \\
                \\The interactive REPL is not yet implemented for ArcherDB.
                \\
                \\Use the client SDKs to interact with the database:
                \\  - Python: pip install archerdb
                \\  - Go: go get github.com/archerdb-io/archerdb/go
                \\  - Java: Maven/Gradle dependency
                \\  - Node.js: npm install archerdb
                \\  - Rust: cargo add archerdb
                \\
                \\Available operations:
                \\  insert_events   - Insert geospatial events
                \\  upsert_events   - Upsert geospatial events
                \\  delete_entities - Delete entities by ID
                \\  query_uuid      - Query by entity UUID
                \\  query_radius    - Query within radius
                \\  query_polygon   - Query within polygon
                \\  query_latest    - Query most recent events
                \\
                \\For more information, see: https://archerdb.io/docs
                \\
            , .{});
        }
    };
}
