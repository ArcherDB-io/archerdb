// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Tracy profiler zone helpers.
//!
//! Provides ergonomic wrappers for Tracy profiling instrumentation. When Tracy
//! is not enabled (default builds), all functions compile to no-ops with zero
//! runtime overhead.
//!
//! ## Usage
//!
//! ```zig
//! const tracy = @import("testing/tracy_zones.zig");
//!
//! fn myFunction() void {
//!     const zone = tracy.zone(@src(), "my_function");
//!     defer zone.end();
//!     // ... function body ...
//! }
//! ```
//!
//! ## Building with Tracy
//!
//! Build with Tracy profiling enabled (on-demand mode):
//! ```bash
//! ./zig/zig build profile -Dtracy=true
//! ```
//!
//! ## Tracy Integration
//!
//! Full Tracy integration requires:
//! 1. Tracy sources from https://github.com/wolfpld/tracy
//! 2. TracyClient.cpp linked into the binary
//! 3. Tracy profiler GUI for visualization
//!
//! When Tracy is disabled, these helpers compile to no-ops with zero overhead.

const std = @import("std");
const builtin = @import("builtin");

/// Check if Tracy is enabled at compile time.
/// Tracy is enabled when TRACY_ENABLE is defined.
pub const tracy_enabled = @hasDecl(std.c, "TRACY_ENABLE") or
    builtin.mode == .Debug and false; // Placeholder for actual Tracy detection

/// Zone context for profiling. When Tracy is disabled, this is a no-op struct.
pub const Zone = struct {
    /// End the zone. Call this (or use defer) when leaving the profiled scope.
    pub inline fn end(_: Zone) void {
        // No-op when Tracy is disabled
        // When Tracy is enabled, this would call ___tracy_emit_zone_end
    }

    /// Add text annotation to the zone.
    pub inline fn text(_: Zone, _: []const u8) void {
        // No-op when Tracy is disabled
    }

    /// Set the zone name (runtime).
    pub inline fn name(_: Zone, _: []const u8) void {
        // No-op when Tracy is disabled
    }

    /// Add a numeric value to the zone.
    pub inline fn value(_: Zone, _: u64) void {
        // No-op when Tracy is disabled
    }

    /// Add a color to the zone.
    pub inline fn color(_: Zone, _: u32) void {
        // No-op when Tracy is disabled
    }
};

/// Create a named zone for profiling.
///
/// Example:
/// ```zig
/// fn processQuery(query: *Query) !void {
///     const z = tracy.zone(@src(), "process_query");
///     defer z.end();
///     // ... processing ...
/// }
/// ```
pub inline fn zone(_: std.builtin.SourceLocation, comptime _: []const u8) Zone {
    // No-op when Tracy is disabled
    // When Tracy is enabled, this would call ___tracy_emit_zone_begin
    return .{};
}

/// Create a zone with runtime name.
///
/// Use this when the zone name is determined at runtime.
pub inline fn zoneN(_: std.builtin.SourceLocation, _: []const u8) Zone {
    // No-op when Tracy is disabled
    return .{};
}

/// Frame marker for main loop iterations.
///
/// Call this at the end of each frame/iteration in the main loop
/// to help Tracy visualize frame timing.
pub inline fn frameMark() void {
    // No-op when Tracy is disabled
    // When Tracy is enabled, this would call ___tracy_emit_frame_mark
}

/// Named frame marker for multiple frame types.
///
/// Use this when you have multiple types of frames (e.g., render frame, logic frame).
pub inline fn frameMarkNamed(comptime _: []const u8) void {
    // No-op when Tracy is disabled
}

/// Log a message to Tracy timeline.
///
/// Messages appear in Tracy's message log and can be searched/filtered.
pub inline fn message(_: []const u8) void {
    // No-op when Tracy is disabled
    // When Tracy is enabled, this would call ___tracy_emit_message
}

/// Log a message with color to Tracy timeline.
pub inline fn messageColor(_: []const u8, _: u32) void {
    // No-op when Tracy is disabled
}

/// Allocator tracking - mark an allocation.
///
/// Use this to track memory allocations in Tracy.
pub inline fn allocN(_: ?*anyopaque, _: usize, comptime _: []const u8) void {
    // No-op when Tracy is disabled
}

/// Allocator tracking - mark a free.
pub inline fn freeN(_: ?*anyopaque, comptime _: []const u8) void {
    // No-op when Tracy is disabled
}

/// Plot a value on Tracy's plot view.
///
/// Useful for tracking metrics over time (e.g., queue depth, latency).
pub inline fn plot(comptime _: []const u8, _: f64) void {
    // No-op when Tracy is disabled
    // When Tracy is enabled, this would call ___tracy_emit_plot
}

/// Plot an integer value.
pub inline fn plotInt(comptime name: []const u8, val: i64) void {
    plot(name, @as(f64, @floatFromInt(val)));
}

// Pre-defined zone colors for consistency across the codebase.
// These follow a semantic coloring scheme for different subsystems.
pub const colors = struct {
    /// Query processing - green (success/go)
    pub const query: u32 = 0x00FF00;
    /// Storage operations - blue (data/persistent)
    pub const storage: u32 = 0x0000FF;
    /// Consensus/Raft - red (critical path)
    pub const consensus: u32 = 0xFF0000;
    /// Network I/O - yellow (caution/external)
    pub const network: u32 = 0xFFFF00;
    /// Index operations - magenta (structure)
    pub const index: u32 = 0xFF00FF;
    /// Memory operations - cyan (resources)
    pub const memory: u32 = 0x00FFFF;
    /// Geo/S2 operations - orange (spatial)
    pub const geo: u32 = 0xFF8800;
    /// Replication - purple (distributed)
    pub const replication: u32 = 0x8800FF;
};

// =============================================================================
// Tests
// =============================================================================

test "tracy zones are no-ops" {
    // Verify that Tracy zone operations compile and run without error
    // when Tracy is disabled (which is the default).
    const z = zone(@src(), "test_zone");
    z.text("test annotation");
    z.name("runtime name");
    z.value(42);
    z.color(colors.query);
    z.end();
}

test "frame markers are no-ops" {
    frameMark();
    frameMarkNamed("render");
}

test "messages are no-ops" {
    message("test message");
    messageColor("colored message", colors.network);
}

test "allocator tracking is no-op" {
    var buf: [64]u8 = undefined;
    allocN(&buf, buf.len, "test_alloc");
    freeN(&buf, "test_alloc");
}

test "plotting is no-op" {
    plot("test_metric", 3.14159);
    plotInt("test_counter", 42);
}
