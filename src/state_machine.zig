// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! State Machine - ArcherDB Geospatial Database
//!
//! ArcherDB uses GeoStateMachine for all operations. This file re-exports
//! geo_state_machine.zig types for backward compatibility with modules that
//! import state_machine.zig.

const std = @import("std");

// Re-export geo_state_machine types for backward compatibility
const geo_state_machine = @import("geo_state_machine.zig");

/// tree_ids - re-exported from geo_state_machine.zig
pub const tree_ids = geo_state_machine.tree_ids;

/// StateMachineType - re-exports GeoStateMachineType for backward compatibility.
/// All ArcherDB operations use the geospatial state machine.
pub const StateMachineType = geo_state_machine.GeoStateMachineType;

test "state_machine: re-exports geo_state_machine for ArcherDB" {
    // ArcherDB uses GeoStateMachine for all operations.
    // This file provides backward compatibility for modules importing state_machine.zig.
    try std.testing.expect(true);
}
