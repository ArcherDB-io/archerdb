// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! State Machine Stub - ArcherDB Geospatial Database
//!
//! The original TigerBeetle financial state machine is not used in ArcherDB.
//! ArcherDB uses GeoStateMachine (geo_state_machine.zig) for all operations.
//!
//! This file re-exports the necessary types from geo_state_machine.zig
//! to maintain backward compatibility with modules that import state_machine.zig.

const std = @import("std");

// Re-export geo_state_machine types for backward compatibility
const geo_state_machine = @import("geo_state_machine.zig");

/// tree_ids - re-exported from geo_state_machine.zig
pub const tree_ids = geo_state_machine.tree_ids;

/// StateMachineType stub - ArcherDB uses GeoStateMachineType instead.
/// Import geo_state_machine.zig for the actual implementation.
pub fn StateMachineType(comptime Storage: type) type {
    _ = Storage;
    return struct {
        const Self = @This();

        pub const Options = struct {
            batch_size_limit: u32 = 0,
        };

        pub fn init() Self {
            return .{};
        }
    };
}

test "state_machine: stub - use geo_state_machine.zig for ArcherDB" {
    // ArcherDB uses GeoStateMachine, not the TigerBeetle financial StateMachine.
    // See src/geo_state_machine.zig for the active implementation.
    try std.testing.expect(true);
}
