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
    // Create modules for SDK files (used by integration tests)
    // ========================================================================

    // SDK module for integration tests
    const sdk_mod = b.createModule(.{
        .root_source_file = b.path("client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Types module for integration tests
    const types_mod = b.createModule(.{
        .root_source_file = b.path("types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Errors module for integration tests
    const errors_mod = b.createModule(.{
        .root_source_file = b.path("errors.zig"),
        .target = target,
        .optimize = optimize,
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

    // Roundtrip tests (simple smoke tests using inline data)
    const integration_test = b.addTest(.{
        .root_source_file = b.path("tests/integration/roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_test.root_module.addImport("sdk", sdk_mod);
    const run_integration_test = b.addRunArtifact(integration_test);

    // Fixture-based tests (comprehensive tests using Phase 11 JSON fixtures)
    const all_operations_test = b.addTest(.{
        .root_source_file = b.path("tests/integration/all_operations_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    all_operations_test.root_module.addImport("sdk", sdk_mod);
    const run_all_operations_test = b.addRunArtifact(all_operations_test);

    // Suppress unused variable warnings for modules used by SDK internally
    _ = types_mod;
    _ = errors_mod;

    const integration_test_step = b.step("test:integration", "Run integration tests (requires running server)");
    integration_test_step.dependOn(&run_integration_test.step);
    integration_test_step.dependOn(&run_all_operations_test.step);

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
    test_step.dependOn(&run_all_operations_test.step);

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
}
