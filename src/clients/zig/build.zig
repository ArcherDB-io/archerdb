// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! ArcherDB Zig SDK Build Configuration
//!
//! Build targets:
//!   - Library: Static library for linking into applications
//!   - test:unit: Unit tests (no server required)
//!   - test:integration: Integration tests (requires running server)
//!   - test: All tests
//!
//! Usage:
//!   zig build                     # Build library
//!   zig build test:unit           # Run unit tests
//!   zig build test:integration    # Run integration tests (requires server)
//!   zig build test                # Run all tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Create modules for SDK files
    // ========================================================================

    const types_mod = b.createModule(.{
        .root_source_file = b.path("types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const errors_mod = b.createModule(.{
        .root_source_file = b.path("errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    const json_mod = b.createModule(.{
        .root_source_file = b.path("json.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "errors", .module = errors_mod },
        },
    });

    const http_mod = b.createModule(.{
        .root_source_file = b.path("http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errors", .module = errors_mod },
        },
    });

    const client_mod = b.createModule(.{
        .root_source_file = b.path("client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "errors", .module = errors_mod },
            .{ .name = "json", .module = json_mod },
            .{ .name = "http", .module = http_mod },
        },
    });

    // ========================================================================
    // Static Library
    // ========================================================================

    const lib = b.addStaticLibrary(.{
        .name = "archerdb-zig",
        .root_source_file = b.path("client.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // ========================================================================
    // Module for external use
    // ========================================================================

    _ = b.addModule("archerdb-zig", .{
        .root_source_file = b.path("client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Unit Tests
    // ========================================================================

    // Types tests - standalone
    const types_test = b.addTest(.{
        .root_source_file = b.path("types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_types_test = b.addRunArtifact(types_test);

    // Errors tests - standalone
    const errors_test = b.addTest(.{
        .root_source_file = b.path("errors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_errors_test = b.addRunArtifact(errors_test);

    // JSON tests - standalone (has internal tests)
    const json_test = b.addTest(.{
        .root_source_file = b.path("json.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_json_test = b.addRunArtifact(json_test);

    // HTTP tests - standalone (has internal tests)
    const http_test = b.addTest(.{
        .root_source_file = b.path("http.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_http_test = b.addRunArtifact(http_test);

    // Client tests - standalone (has internal tests)
    const client_test = b.addTest(.{
        .root_source_file = b.path("client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_client_test = b.addRunArtifact(client_test);

    // Unit test step
    const unit_test_step = b.step("test:unit", "Run unit tests");
    unit_test_step.dependOn(&run_types_test.step);
    unit_test_step.dependOn(&run_errors_test.step);
    unit_test_step.dependOn(&run_json_test.step);
    unit_test_step.dependOn(&run_http_test.step);
    unit_test_step.dependOn(&run_client_test.step);

    // ========================================================================
    // Integration Tests
    // ========================================================================

    const integration_test = b.addTest(.{
        .root_source_file = b.path("tests/integration/roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_integration_test = b.addRunArtifact(integration_test);

    const integration_test_step = b.step("test:integration", "Run integration tests (requires running server)");
    integration_test_step.dependOn(&run_integration_test.step);

    // ========================================================================
    // All Tests
    // ========================================================================

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_types_test.step);
    test_step.dependOn(&run_errors_test.step);
    test_step.dependOn(&run_json_test.step);
    test_step.dependOn(&run_http_test.step);
    test_step.dependOn(&run_client_test.step);
    test_step.dependOn(&run_integration_test.step);

    // ========================================================================
    // Check (compile only)
    // ========================================================================

    const check_step = b.step("check", "Check if the code compiles");

    // Check main library
    const lib_check = b.addStaticLibrary(.{
        .name = "archerdb-zig-check",
        .root_source_file = b.path("client.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_step.dependOn(&lib_check.step);

    // Use the client module check (includes all dependencies)
    _ = client_mod;
}
