// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! State Machine Tests Stub - ArcherDB Geospatial Database
//!
//! The original ArcherDB state machine tests are not applicable to ArcherDB's
//! geospatial-only implementation. ArcherDB uses GeoStateMachine for all operations.
//!
//! For geospatial operation tests, see:
//! - src/geo_state_machine.zig (inline tests)
//! - src/ram_index.zig (RAM index tests)
//! - src/ttl.zig (TTL tests)
//! - src/post_filter.zig (query filter tests)

const std = @import("std");
const testing = std.testing;

test "state_machine_tests: stub - geospatial tests are in geo_state_machine.zig" {
    // ArcherDB uses GeoStateMachine, not the legacy state machine.
    // Geospatial operation tests are in src/geo_state_machine.zig and related files.
    try testing.expect(true);
}
