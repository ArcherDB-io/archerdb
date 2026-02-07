// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Build configuration for C SDK operation tests
//!
//! This uses the Zig build system to compile C code and link against
//! the ArcherDB C SDK library.
//!
//! Build:
//!   cd tests/sdk_tests/c && ../../../zig/zig build
//!
//! Run:
//!   ARCHERDB_INTEGRATION=1 ./zig-out/bin/test_all_operations

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the test executable
    const exe = b.addExecutable(.{
        .name = "test_all_operations",
        .target = target,
        .optimize = optimize,
    });

    // Add C source files
    exe.addCSourceFiles(.{
        .files = &.{
            "test_all_operations.c",
            "fixture_adapter.c",
        },
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            "-D_GNU_SOURCE", // For pthread
        },
    });

    // Link against the C SDK static library
    // The C SDK is built as part of the main ArcherDB build
    // Library is in src/clients/c/lib/<target>/
    const lib_subdir: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => switch (target.result.os.tag) {
            .macos => "aarch64-macos",
            .linux => "aarch64-linux-gnu.2.27",
            else => "aarch64-linux-gnu.2.27",
        },
        .x86_64 => switch (target.result.os.tag) {
            .macos => "x86_64-macos",
            .linux => "x86_64-linux-gnu.2.27",
            else => "x86_64-linux-gnu.2.27",
        },
        else => "x86_64-linux-gnu.2.27",
    };
    const lib_path = b.fmt(
        "../../../src/clients/c/lib/{s}",
        .{lib_subdir},
    );
    exe.addLibraryPath(.{ .cwd_relative = lib_path });
    exe.linkSystemLibrary("arch_client");

    // Also need to link Zig runtime libraries
    exe.linkLibC();

    // Add include paths
    exe.addIncludePath(.{ .cwd_relative = "../../../src/clients/c" });

    // System libraries for threading and networking
    if (target.result.os.tag == .linux) {
        exe.linkSystemLibrary("pthread");
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Environment for integration tests
    run_cmd.setEnvironmentVariable("ARCHERDB_INTEGRATION", "1");

    const run_step = b.step("test", "Run C SDK operation tests");
    run_step.dependOn(&run_cmd.step);

    // Check step (compile only)
    const check_step = b.step("check", "Check if C code compiles");
    check_step.dependOn(&exe.step);
}
