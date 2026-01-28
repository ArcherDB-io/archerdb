const std = @import("std");
const builtin = @import("builtin");
// NB: Don't import anything from `./src` to keep compile times low.

const assert = std.debug.assert;
const Query = std.Target.Query;

const VoprStateMachine = enum { testing, geo };
const VoprLog = enum { short, full };
const ConfigBase = enum { production, lite };
const IndexFormat = enum { standard, compact };

// ArcherDB binary requires certain CPU features and supports a closed set of CPUs. Here, we
// specify exactly which features the binary needs.
fn resolve_target(b: *std.Build, target_requested: ?[]const u8) !std.Build.ResolvedTarget {
    const target_host = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
    const target = target_requested orelse target_host;
    const triples = .{
        "aarch64-linux",
        "aarch64-macos",
        "x86_64-linux",
        "x86_64-macos",
    };
    const cpus = .{
        "baseline+aes+neon",
        "baseline+aes+neon",
        "x86_64_v3+aes",
        "x86_64_v3+aes",
    };

    const arch_os, const cpu = inline for (triples, cpus) |triple, cpu| {
        if (std.mem.eql(u8, target, triple)) break .{ triple, cpu };
    } else {
        std.log.err("unsupported target: '{s}'", .{target});
        return error.UnsupportedTarget;
    };
    const query = try Query.parse(.{
        .arch_os_abi = arch_os,
        .cpu_features = cpu,
    });
    return b.resolveTargetQuery(query);
}

const zig_version = std.SemanticVersion{
    .major = 0,
    .minor = 14,
    .patch = 1,
};

comptime {
    // Compare versions while allowing different pre/patch metadata.
    const zig_version_eq = zig_version.major == builtin.zig_version.major and
        zig_version.minor == builtin.zig_version.minor and
        (zig_version.patch == builtin.zig_version.patch);
    if (!zig_version_eq) {
        @compileError(std.fmt.comptimePrint(
            "unsupported zig version: expected {}, found {}",
            .{ zig_version, builtin.zig_version },
        ));
    }
}

pub fn build(b: *std.Build) !void {
    // A compile error stack trace of 10 is arbitrary in size but helps with debugging.
    b.reference_trace = 10;

    // Top-level steps you can invoke on the command line.
    const build_steps = .{
        .aof = b.step("aof", "Run ArcherDB AOF Utility"),
        .csv_import = b.step("csv_import", "Run CSV Import Tool"),
        .check = b.step("check", "Check if ArcherDB compiles"),
        .clients_c = b.step("clients:c", "Build C client library"),
        .clients_c_sample = b.step("clients:c:sample", "Build C client sample"),
        .clients_go = b.step("clients:go", "Build Go client shared library"),
        .clients_java = b.step("clients:java", "Build Java client shared library"),
        .clients_node = b.step("clients:node", "Build Node client shared library"),
        .clients_python = b.step("clients:python", "Build Python client library"),
        .docs = b.step("docs", "Build docs"),
        .fuzz = b.step("fuzz", "Run non-VOPR fuzzers"),
        .fuzz_build = b.step("fuzz:build", "Build non-VOPR fuzzers"),
        .run = b.step("run", "Run ArcherDB"),
        .ci = b.step("ci", "Run the full suite of CI checks"),
        .scripts = b.step("scripts", "Free form automation scripts"),
        .scripts_build = b.step("scripts:build", "Build automation scripts"),
        .vortex = b.step("vortex", "Full system tests with pluggable client drivers"),
        .vortex_build = b.step("vortex:build", "Build the Vortex"),
        .@"test" = b.step("test", "Run all tests"),
        .test_fmt = b.step("test:fmt", "Check formatting"),
        .test_integration = b.step("test:integration", "Run integration tests"),
        .test_integration_build = b.step("test:integration:build", "Build integration tests"),
        .test_unit = b.step("test:unit", "Run unit tests"),
        .test_unit_build = b.step("test:unit:build", "Build unit tests"),
        .test_integration_replication = b.step("test:integration:replication", "Run replication integration tests (requires Docker)"),
        .test_jni = b.step("test:jni", "Run Java JNI tests"),
        .vopr = b.step("vopr", "Run the VOPR"),
        .vopr_build = b.step("vopr:build", "Build the VOPR"),
        .profile = b.step("profile", "Build with profiling instrumentation (Tracy on-demand, frame pointers)"),
    };

    const mode = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // Build options passed with `-D` flags.
    const build_options = .{
        .target = b.option([]const u8, "target", "The CPU architecture and OS to build for"),
        .multiversion = b.option(
            []const u8,
            "multiversion",
            "Past version to include for upgrades (\"latest\" or \"x.y.z\")",
        ),
        .multiversion_file = b.option(
            []const u8,
            "multiversion-file",
            "Past version to include for upgrades (local binary file)",
        ),
        .config_verify = b.option(bool, "config_verify", "Enable extra assertions.") orelse
            // If `config_verify` isn't set, disable it for `release` builds; otherwise, enable it.
            (mode == .Debug),
        .config_aof_recovery = b.option(
            bool,
            "config-aof-recovery",
            "Enable AOF Recovery mode.",
        ) orelse false,
        .config_base = b.option(
            ConfigBase,
            "config",
            "Build configuration preset: 'production' (7+ GiB RAM) or 'lite' (~130 MiB RAM).",
        ),
        .config_release = b.option([]const u8, "config-release", "Release triple."),
        .config_release_client_min = b.option(
            []const u8,
            "config-release-client-min",
            "Minimum client release triple.",
        ),
        .emit_llvm_ir = b.option(bool, "emit-llvm-ir", "Emit LLVM IR (.ll file)") orelse false,
        .integration_past = b.option(
            []const u8,
            "integration-past",
            "Path to a previous ArcherDB binary for integration tests",
        ),
        // The "archerdb version" command includes the build-time commit hash.
        .git_commit = b.option(
            []const u8,
            "git-commit",
            "The git commit revision of the source code.",
        ) orelse std.mem.trimRight(u8, b.run(&.{ "git", "rev-parse", "--verify", "HEAD" }), "\n"),
        .vopr_state_machine = b.option(
            VoprStateMachine,
            "vopr-state-machine",
            "State machine.",
        ) orelse .geo,
        .vopr_log = b.option(
            VoprLog,
            "vopr-log",
            "Log only state transitions (short) or everything (full).",
        ) orelse .short,
        .llvm_objcopy = b.option(
            []const u8,
            "llvm-objcopy",
            "Use this llvm-objcopy instead of downloading one",
        ),
        .print_exe = b.option(
            bool,
            "print-exe",
            "Build tasks print the path of the executable",
        ) orelse false,
        .index_format = b.option(
            IndexFormat,
            "index-format",
            "RAM index format: 'standard' (64B, TTL) or 'compact' (32B, no TTL).",
        ) orelse .standard,
        .enable_tracy = b.option(
            bool,
            "tracy",
            "Enable Tracy profiler instrumentation (requires Tracy sources)",
        ) orelse false,
        .enable_profiling = b.option(
            bool,
            "profiling",
            "Enable profiling build (frame pointers, Tracy if available)",
        ) orelse false,
    };

    const target = try resolve_target(b, build_options.target);
    const stdx_module = b.addModule("stdx", .{ .root_source_file = b.path("src/stdx/stdx.zig") });

    // LZ4 compression library dependency
    const lz4_dep = b.dependency("lz4", .{
        .target = target,
        .optimize = mode,
    });

    assert(build_options.git_commit.len == 40);
    const vsr_options, const vsr_module = build_vsr_module(b, .{
        .stdx_module = stdx_module,
        .lz4_dep = lz4_dep,
        .git_commit = build_options.git_commit[0..40].*,
        .config_verify = build_options.config_verify,
        .config_release = build_options.config_release,
        .config_release_client_min = build_options.config_release_client_min,
        .config_aof_recovery = build_options.config_aof_recovery,
        .config_base = build_options.config_base,
        .index_format = build_options.index_format,
    });

    const arch_client_header = blk: {
        const arch_client_header_generator = b.addExecutable(.{
            .name = "arch_client_header",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/clients/c/arch_client_header.zig"),
                .target = b.graph.host,
            }),
        });
        arch_client_header_generator.root_module.addImport("vsr", vsr_module);
        arch_client_header_generator.root_module.addOptions("vsr_options", vsr_options);
        break :blk Generated.file(b, .{
            .generator = arch_client_header_generator,
            .path = "./src/clients/c/arch_client.h",
        });
    };

    // zig build check
    build_check(b, build_steps.check, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .lz4_dep = lz4_dep,
        .target = target,
        .mode = mode,
    });

    // zig build, zig build run
    build_archerdb(b, .{
        .run = build_steps.run,
        .install = b.getInstallStep(),
    }, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .lz4_dep = lz4_dep,
        .llvm_objcopy = build_options.llvm_objcopy,
        .target = target,
        .mode = mode,
        .emit_llvm_ir = build_options.emit_llvm_ir,
        .multiversion = build_options.multiversion,
        .multiversion_file = build_options.multiversion_file,
    });

    // zig build aof
    build_aof(b, build_steps.aof, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options,
        .target = target,
        .mode = mode,
    });

    // zig build csv_import
    build_csv_import(b, build_steps.csv_import, .{
        .target = target,
        .mode = mode,
    });

    // zig build test -- "test filter"
    try build_test(b, .{
        .test_unit = build_steps.test_unit,
        .test_unit_build = build_steps.test_unit_build,
        .test_integration = build_steps.test_integration,
        .test_integration_build = build_steps.test_integration_build,
        .test_fmt = build_steps.test_fmt,
        .@"test" = build_steps.@"test",
    }, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options,
        .llvm_objcopy = build_options.llvm_objcopy,
        .arch_client_header = arch_client_header,
        .lz4_dep = lz4_dep,
        .target = target,
        .mode = mode,
        .integration_past = build_options.integration_past,
    });

    // zig build test:jni
    try build_test_jni(b, build_steps.test_jni, .{
        .target = target,
        .mode = mode,
    });

    // zig build test:integration:replication
    build_test_integration_replication(b, build_steps.test_integration_replication, .{
        .stdx_module = stdx_module,
        .target = target,
        .mode = mode,
    });

    // zig build vopr -- 42
    build_vopr(b, .{
        .vopr_build = build_steps.vopr_build,
        .vopr_run = build_steps.vopr,
    }, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options,
        .lz4_dep = lz4_dep,
        .target = target,
        .mode = mode,
        .print_exe = build_options.print_exe,
        .vopr_state_machine = build_options.vopr_state_machine,
        .vopr_log = build_options.vopr_log,
    });

    // zig build fuzz -- --events-max=100 lsm_tree 123
    build_fuzz(b, .{
        .fuzz = build_steps.fuzz,
        .fuzz_build = build_steps.fuzz_build,
    }, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options,
        .lz4_dep = lz4_dep,
        .target = target,
        .mode = mode,
        .print_exe = build_options.print_exe,
    });

    // zig build scripts -- ci --language=java
    const scripts = build_scripts(b, .{
        .scripts = build_steps.scripts,
        .scripts_build = build_steps.scripts_build,
    }, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options,
        .target = target,
    });

    // zig build vortex
    build_vortex(b, .{
        .vortex_build = build_steps.vortex_build,
        .vortex_run = build_steps.vortex,
    }, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .lz4_dep = lz4_dep,
        .target = target,
        .mode = mode,
        .arch_client_header = arch_client_header.path,
        .print_exe = build_options.print_exe,
    });

    // zig build clients:$lang
    build_go_client(b, build_steps.clients_go, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .arch_client_header = arch_client_header.path,
        .mode = mode,
    });
    build_java_client(b, build_steps.clients_java, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .mode = mode,
    });
    build_node_client(b, build_steps.clients_node, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .mode = mode,
    });
    build_python_client(b, build_steps.clients_python, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .arch_client_header = arch_client_header.path,
        .mode = mode,
    });
    build_c_client(b, build_steps.clients_c, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .arch_client_header = arch_client_header,
        .mode = mode,
    });

    // zig build clients:c:sample
    build_clients_c_sample(b, build_steps.clients_c_sample, .{
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .target = target,
        .mode = mode,
    });

    // zig build docs
    build_steps.docs.dependOn(blk: {
        const nested_build = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        nested_build.setCwd(b.path("./src/docs_website/"));
        break :blk &nested_build.step;
    });

    // zig build profile
    // Profile build creates a release binary with frame pointers preserved for profiling.
    // When Tracy is enabled (-Dtracy=true), Tracy instrumentation is active.
    // On-demand mode means zero overhead unless Tracy profiler GUI is connected.
    build_profile(b, build_steps.profile, .{
        .stdx_module = stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .target = target,
        .enable_tracy = build_options.enable_tracy,
        .enable_profiling = build_options.enable_profiling,
    });

    // zig build ci
    build_ci(b, build_steps.ci, .{
        .scripts = scripts,
        .git_commit = build_options.git_commit,
    });
}

fn build_vsr_module(b: *std.Build, options: struct {
    stdx_module: *std.Build.Module,
    lz4_dep: *std.Build.Dependency,
    git_commit: [40]u8,
    config_verify: bool,
    config_release: ?[]const u8,
    config_release_client_min: ?[]const u8,
    config_aof_recovery: bool,
    config_base: ?ConfigBase = null,
    index_format: IndexFormat = .standard,
}) struct { *std.Build.Step.Options, *std.Build.Module } {
    // Ideally, we would return _just_ the module here, and keep options an implementation detail.
    // However, currently Zig makes it awkward to provide multiple entry points for a module:
    // https://ziggit.dev/t/suggested-project-layout-for-multiple-entry-point-for-zig-0-12/4219
    //
    // For this reason, we have to return options as well, so that other entry points can
    // essentially re-create identical module.
    const vsr_options = b.addOptions();
    vsr_options.addOption(?[40]u8, "git_commit", options.git_commit[0..40].*);
    vsr_options.addOption(bool, "config_verify", options.config_verify);
    vsr_options.addOption(?[]const u8, "release", options.config_release);
    vsr_options.addOption(
        ?[]const u8,
        "release_client_min",
        options.config_release_client_min,
    );
    vsr_options.addOption(bool, "config_aof_recovery", options.config_aof_recovery);
    // Pass config_base as string to avoid enum serialization issues
    const config_base_str: ?[]const u8 = if (options.config_base) |config_base|
        @tagName(config_base)
    else
        null;
    vsr_options.addOption(?[]const u8, "config_base", config_base_str);

    // Pass index_format as string for compile-time selection
    vsr_options.addOption([]const u8, "index_format", @tagName(options.index_format));

    const vsr_module = create_vsr_module(b, .{
        .stdx_module = options.stdx_module,
        .vsr_options = vsr_options,
        .lz4_dep = options.lz4_dep,
    });

    return .{ vsr_options, vsr_module };
}

fn create_vsr_module(
    b: *std.Build,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        lz4_dep: *std.Build.Dependency,
    },
) *std.Build.Module {
    const vsr_module = b.createModule(.{
        .root_source_file = b.path("src/vsr.zig"),
    });
    vsr_module.addImport("stdx", options.stdx_module);
    vsr_module.addOptions("vsr_options", options.vsr_options);

    // Add LZ4 include path for @cImport in compression.zig
    const lz4_artifact = options.lz4_dep.artifact("lz4");
    vsr_module.addIncludePath(lz4_artifact.getEmittedIncludeTree());
    vsr_module.linkLibrary(lz4_artifact);

    return vsr_module;
}

/// This is what is called by CI infrastructure, but you can also use it locally. In particular,
///
///     ./zig/zig build ci
///
/// is useful to run locally to get a set of somewhat comprehensive checks without needing many
/// external dependencies.
///
/// Various CI machines pass filters to select a subset of checks:
///
///     ./zig/zig build ci -- all
fn build_ci(
    b: *std.Build,
    step_ci: *std.Build.Step,
    options: struct {
        scripts: *std.Build.Step.Compile,
        git_commit: []const u8,
    },
) void {
    const CIMode = enum {
        smoke, // Quickly check formatting and such.
        @"test", // Main test suite, excluding VOPR and clients.
        fuzz, // Smoke tests for fuzzers and VOPR.
        aof, // Dedicated test for AOF, which is somewhat slow to run.

        clients, // Tests for all language clients below.
        go,
        java,
        node,
        python,

        devhub, // Things that run on known-good commit on main branch after merge.
        @"devhub-dry-run",
        amqp,
        default, // smoke + test + building Zig parts of clients.
        all,
    };

    const mode: CIMode = if (b.args) |args| mode: {
        if (args.len != 1) {
            step_ci.dependOn(&b.addFail("invalid CIMode").step);
            return;
        }
        if (std.meta.stringToEnum(CIMode, args[0])) |m| {
            break :mode m;
        } else {
            step_ci.dependOn(&b.addFail("invalid CIMode").step);
            return;
        }
    } else .default;

    const all = mode == .all;
    const default = all or mode == .default;

    if (default or mode == .smoke) {
        build_ci_step(b, step_ci, .{"test:fmt"});
        build_ci_step(b, step_ci, .{"check"});

        const build_docs = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        build_docs.has_side_effects = true;
        build_docs.cwd = b.path("./src/docs_website");
        step_ci.dependOn(&build_docs.step);
    }
    if (default or mode == .@"test") {
        build_ci_step(b, step_ci, .{"test"});
        build_ci_step(b, step_ci, .{ "fuzz", "--", "smoke" });
        build_ci_step(b, step_ci, .{"clients:c:sample"});
        build_ci_script(b, step_ci, options.scripts, &.{"--help"});
    }
    if (default or mode == .fuzz) {
        build_ci_step(b, step_ci, .{ "fuzz", "--", "smoke" });
        inline for (.{ "testing", "geo" }) |state_machine| {
            build_ci_step(b, step_ci, .{
                "vopr",
                "-Dvopr-state-machine=" ++ state_machine,
                "-Drelease",
                "--",
                options.git_commit,
            });
        }
    }
    if (default or mode == .amqp) {
        // Smoke test the AMQP integration.
        build_ci_script(b, step_ci, options.scripts, &.{"amqp"});
    }

    if (all or mode == .aof) {
        const aof = b.addSystemCommand(&.{"./.github/ci/test_aof.sh"});
        hide_stderr(aof);
        step_ci.dependOn(&aof.step);
    }
    inline for (&.{ CIMode.go, .java, .node, .python }) |language| {
        if (default or mode == .clients or mode == language) {
            // Client tests expect vortex to exist.
            build_ci_step(b, step_ci, .{"vortex:build"});
            build_ci_step(b, step_ci, .{"clients:" ++ @tagName(language)});
        }
        if (all or mode == .clients or mode == language) {
            build_ci_script(b, step_ci, options.scripts, &.{
                "ci",
                "--language=" ++ @tagName(language),
            });
        }
    }

    if (all or mode == .@"devhub-dry-run") {
        build_ci_script(b, step_ci, options.scripts, &.{
            "devhub",
            b.fmt("--sha={s}", .{options.git_commit}),
            "--skip-kcov",
        });
    }
    if (mode == .devhub) {
        build_ci_script(b, step_ci, options.scripts, &.{
            "devhub",
            b.fmt("--sha={s}", .{options.git_commit}),
        });
    }
}

fn build_ci_step(
    b: *std.Build,
    step_ci: *std.Build.Step,
    command: anytype,
) void {
    const argv = .{ b.graph.zig_exe, "build" } ++ command;
    const system_command = b.addSystemCommand(&argv);
    const name = std.mem.join(b.allocator, " ", &command) catch @panic("OOM");
    system_command.setName(name);
    hide_stderr(system_command);
    step_ci.dependOn(&system_command.step);
}

fn build_ci_script(
    b: *std.Build,
    step_ci: *std.Build.Step,
    scripts: *std.Build.Step.Compile,
    argv: []const []const u8,
) void {
    const run_artifact = b.addRunArtifact(scripts);
    run_artifact.addArgs(argv);
    run_artifact.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    hide_stderr(run_artifact);
    step_ci.dependOn(&run_artifact.step);
}

// Hide step's stderr unless it fails, to prevent zig build ci output being dominated by VOPR logs.
// Sadly, this requires "overriding" Build.Step.Run make function.
fn hide_stderr(run: *std.Build.Step.Run) void {
    const b = run.step.owner;

    run.addCheck(.{ .expect_term = .{ .Exited = 0 } });
    run.has_side_effects = true;

    const override = struct {
        var global_map: std.AutoHashMapUnmanaged(usize, std.Build.Step.MakeFn) = .{};

        fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
            const original = global_map.get(@intFromPtr(step)).?;
            try original(step, options);
            assert(step.result_error_msgs.items.len == 0);
            step.result_stderr = "";
        }
    };

    const original = run.step.makeFn;
    override.global_map.put(b.allocator, @intFromPtr(&run.step), original) catch @panic("OOM");
    run.step.makeFn = &override.make;
}

// Run an archerdb build without running codegen and waiting for llvm
// see <https://github.com/ziglang/zig/commit/5c0181841081170a118d8e50af2a09f5006f59e1>
// how it's supposed to work.
// In short, codegen only runs if zig build sees a dependency on the binary output of
// the step. So we duplicate the build definition so that it doesn't get polluted by
// b.installArtifact.
// TODO(zig): https://github.com/ziglang/zig/issues/18877
fn build_check(
    b: *std.Build,
    step_check: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        lz4_dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const archerdb = b.addExecutable(.{
        .name = "archerdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/archerdb/main.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    archerdb.root_module.addImport("stdx", options.stdx_module);
    archerdb.root_module.addImport("vsr", options.vsr_module);
    // Link LZ4 for block compression
    archerdb.linkLibrary(options.lz4_dep.artifact("lz4"));
    step_check.dependOn(&archerdb.step);
}

/// Build with profiling instrumentation enabled.
/// - Frame pointers preserved for accurate stack traces
/// - ReleaseFast optimization for representative performance
/// - Tracy instrumentation available when -Dtracy=true
fn build_profile(
    b: *std.Build,
    step_profile: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        target: std.Build.ResolvedTarget,
        enable_tracy: bool,
        enable_profiling: bool,
    },
) void {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/archerdb/main.zig"),
        .target = options.target,
        .optimize = .ReleaseFast, // Profile builds use ReleaseFast for representative perf
    });
    root_module.addImport("vsr", options.vsr_module);
    root_module.addOptions("vsr_options", options.vsr_options);

    // Preserve frame pointers for profiling stack traces
    root_module.omit_frame_pointer = false;

    const archerdb = b.addExecutable(.{
        .name = "archerdb-profile",
        .root_module = root_module,
    });

    // Define TRACY_ENABLE compile-time flag when Tracy is enabled
    if (options.enable_tracy) {
        // Note: Full Tracy integration requires TracyClient.cpp from Tracy sources.
        // The tracy_zones.zig helpers provide no-op fallbacks when Tracy is not linked.
        // To fully enable Tracy:
        // 1. Clone Tracy: git clone https://github.com/wolfpld/tracy
        // 2. Build with -Dtracy=true and link TracyClient.cpp
        archerdb.root_module.addCMacro("TRACY_ENABLE", "1");
        archerdb.root_module.addCMacro("TRACY_ON_DEMAND", "1");
    }

    const install = b.addInstallArtifact(archerdb, .{
        .dest_sub_path = "archerdb-profile",
    });
    step_profile.dependOn(&install.step);

    // Also install to root for convenience
    step_profile.dependOn(&b.addInstallFile(
        archerdb.getEmittedBin(),
        b.pathJoin(&.{ "../", "archerdb-profile" }),
    ).step);
}

fn build_archerdb(
    b: *std.Build,
    steps: struct {
        run: *std.Build.Step,
        install: *std.Build.Step,
    },
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        lz4_dep: *std.Build.Dependency,
        llvm_objcopy: ?[]const u8,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
        multiversion: ?[]const u8,
        multiversion_file: ?[]const u8,
        emit_llvm_ir: bool,
    },
) void {
    const multiversion_file: ?std.Build.LazyPath = if (options.multiversion_file) |path|
        .{ .cwd_relative = path }
    else if (options.multiversion) |version_past|
        download_release(b, version_past, options.target, options.mode)
    else
        null;

    const archerdb_bin = if (multiversion_file) |multiversion_lazy_path| bin: {
        assert(!options.emit_llvm_ir);
        break :bin build_archerdb_executable_multiversion(b, .{
            .stdx_module = options.stdx_module,
            .vsr_module = options.vsr_module,
            .vsr_options = options.vsr_options,
            .lz4_dep = options.lz4_dep,
            .llvm_objcopy = options.llvm_objcopy,
            .archerdb_previous = multiversion_lazy_path,
            .target = options.target,
            .mode = options.mode,
        });
    } else bin: {
        const archerdb_exe = build_archerdb_executable(b, .{
            .vsr_module = options.vsr_module,
            .vsr_options = options.vsr_options,
            .lz4_dep = options.lz4_dep,
            .target = options.target,
            .mode = options.mode,
        });
        if (options.emit_llvm_ir) {
            steps.install.dependOn(&b.addInstallBinFile(
                archerdb_exe.getEmittedLlvmIr(),
                "archerdb.ll",
            ).step);
        }
        break :bin archerdb_exe.getEmittedBin();
    };

    const out_filename = "archerdb";

    steps.install.dependOn(&b.addInstallBinFile(archerdb_bin, out_filename).step);
    // "zig build install" moves the server executable to the root folder:
    steps.install.dependOn(&b.addInstallFile(
        archerdb_bin,
        b.pathJoin(&.{ "../", out_filename }),
    ).step);

    const run_cmd = std.Build.Step.Run.create(b, b.fmt("run archerdb", .{}));
    run_cmd.addFileArg(archerdb_bin);
    if (b.args) |args| run_cmd.addArgs(args);
    steps.run.dependOn(&run_cmd.step);
}

fn build_archerdb_executable(b: *std.Build, options: struct {
    vsr_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
    lz4_dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
}) *std.Build.Step.Compile {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/archerdb/main.zig"),
        .target = options.target,
        .optimize = options.mode,
    });
    root_module.addImport("vsr", options.vsr_module);
    root_module.addOptions("vsr_options", options.vsr_options);
    if (options.mode == .ReleaseSafe) strip_root_module(root_module);

    const archerdb = b.addExecutable(.{
        .name = "archerdb",
        .root_module = root_module,
    });
    // Link LZ4 for block compression
    archerdb.linkLibrary(options.lz4_dep.artifact("lz4"));

    return archerdb;
}

fn build_archerdb_executable_multiversion(b: *std.Build, options: struct {
    stdx_module: *std.Build.Module,
    vsr_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
    lz4_dep: *std.Build.Dependency,
    llvm_objcopy: ?[]const u8,
    archerdb_previous: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
}) std.Build.LazyPath {
    // build_multiversion a custom step that would take care of packing several releases into one
    const build_multiversion_exe = b.addExecutable(.{
        .name = "build_multiversion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build_multiversion.zig"),
            // Enable aes extensions for vsr.checksum on the host.
            .target = resolve_target(b, null) catch @panic("unsupported host"),
        }),
    });
    build_multiversion_exe.root_module.addImport("stdx", options.stdx_module);
    // Ideally, we should pass `vsr_options` here at runtime. Making them comptime
    // parameters is inelegant, but practical!
    build_multiversion_exe.root_module.addOptions("vsr_options", options.vsr_options);

    const build_multiversion = b.addRunArtifact(build_multiversion_exe);
    if (options.llvm_objcopy) |path| {
        build_multiversion.addArg(b.fmt("--llvm-objcopy={s}", .{path}));
    } else {
        build_multiversion.addPrefixedFileArg(
            "--llvm-objcopy=",
            build_archerdb_executable_get_objcopy(b),
        );
    }
    if (options.target.result.os.tag == .macos) {
        build_multiversion.addArg("--target=macos");
        inline for (.{ "x86_64", "aarch64" }, .{ "x86-64", "aarch64" }) |arch, flag| {
            build_multiversion.addPrefixedFileArg(
                "--archerdb-current-" ++ flag ++ "=",
                build_archerdb_executable(b, .{
                    .vsr_module = options.vsr_module,
                    .vsr_options = options.vsr_options,
                    .lz4_dep = options.lz4_dep,
                    .target = resolve_target(b, arch ++ "-macos") catch unreachable,
                    .mode = options.mode,
                }).getEmittedBin(),
            );
        }
    } else {
        build_multiversion.addArg(b.fmt("--target={s}-{s}", .{
            @tagName(options.target.result.cpu.arch),
            @tagName(options.target.result.os.tag),
        }));
        build_multiversion.addPrefixedFileArg(
            "--archerdb-current=",
            build_archerdb_executable(b, .{
                .vsr_module = options.vsr_module,
                .vsr_options = options.vsr_options,
                .lz4_dep = options.lz4_dep,
                .target = options.target,
                .mode = options.mode,
            }).getEmittedBin(),
        );
    }

    if (options.mode == .Debug) {
        build_multiversion.addArg("--debug");
    }

    build_multiversion.addPrefixedFileArg("--archerdb-past=", options.archerdb_previous);
    build_multiversion.addArg(b.fmt(
        "--tmp={s}",
        .{b.cache_root.join(b.allocator, &.{"tmp"}) catch @panic("OOM")},
    ));
    return build_multiversion.addPrefixedOutputFileArg("--output=", "archerdb");
}

// Downloads a pre-build llvm-objcopy from <https://github.com/archerdb/dependencies>.
fn build_archerdb_executable_get_objcopy(b: *std.Build) std.Build.LazyPath {
    switch (b.graph.host.result.os.tag) {
        .linux => {
            switch (b.graph.host.result.cpu.arch) {
                .x86_64 => {
                    return fetch(b, .{
                        .url = "https://github.com/archerdb/dependencies/releases/download/" ++
                            "18.1.8/llvm-objcopy-x86_64-linux.zip",
                        .file_name = "llvm-objcopy",
                        .hash = "N-V-__8AAFCWcgAxBPUOMe_uJrFGfQ2Ri_SsbNp77pPYZdAe",
                    });
                },
                .aarch64 => {
                    return fetch(b, .{
                        .url = "https://github.com/archerdb/dependencies/releases/download/" ++
                            "18.1.8/llvm-objcopy-aarch64-linux.zip",
                        .file_name = "llvm-objcopy",
                        .hash = "N-V-__8AAIgJcQAG--KvT2zb1yNrlRtNEo3pW3aIgoppmbT-",
                    });
                },
                else => @panic("unsupported arch"),
            }
        },
        .macos => {
            // Both x86_64 and aarch64 macOS use the aarch64 binary.
            // On x86_64 hosts, Rosetta 2 translates it transparently.
            return fetch(b, .{
                .url = "https://github.com/archerdb/dependencies/releases/download/" ++
                    "18.1.8/llvm-objcopy-aarch64-macos.zip",
                .file_name = "llvm-objcopy",
                .hash = "N-V-__8AAFAsVgArdRpU50gjJhqaAUSXsTemKo2A9rCaewUV",
            });
        },
        else => @panic("unsupported host"),
    }
}

fn build_aof(
    b: *std.Build,
    step_aof: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const aof = b.addExecutable(.{
        .name = "aof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/aof.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    aof.root_module.addImport("stdx", options.stdx_module);
    aof.root_module.addOptions("vsr_options", options.vsr_options);
    const run_cmd = b.addRunArtifact(aof);
    if (b.args) |args| run_cmd.addArgs(args);
    step_aof.dependOn(&run_cmd.step);
}

fn build_csv_import(
    b: *std.Build,
    step_csv_import: *std.Build.Step,
    options: struct {
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const csv_import = b.addExecutable(.{
        .name = "csv_import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/csv_import.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    b.installArtifact(csv_import);
    const run_cmd = b.addRunArtifact(csv_import);
    if (b.args) |args| run_cmd.addArgs(args);
    step_csv_import.dependOn(&run_cmd.step);
}

fn build_test(
    b: *std.Build,
    steps: struct {
        test_unit: *std.Build.Step,
        test_unit_build: *std.Build.Step,
        test_integration: *std.Build.Step,
        test_integration_build: *std.Build.Step,
        test_fmt: *std.Build.Step,
        @"test": *std.Build.Step,
    },
    options: struct {
        llvm_objcopy: ?[]const u8,
        stdx_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        arch_client_header: *Generated,
        lz4_dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
        integration_past: ?[]const u8,
    },
) !void {
    const test_options = b.addOptions();
    // Benchmark run in two modes.
    // - ./zig/zig build test
    // - ./zig/zig build -Drelease test -- "benchmark: name"
    // The former uses small parameter values and is silent.
    // The latter is the real benchmark, which prints the output.
    test_options.addOption(bool, "benchmark", for (b.args orelse &.{}) |arg| {
        if (std.mem.indexOf(u8, arg, "benchmark") != null) break true;
    } else false);

    const stdx_unit_tests = b.addTest(.{
        .name = "test-stdx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stdx/stdx.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
        .filters = b.args orelse &.{},
    });
    const unit_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
        .filters = b.args orelse &.{},
    });
    unit_tests.root_module.addImport("stdx", options.stdx_module);
    unit_tests.root_module.addOptions("vsr_options", options.vsr_options);
    unit_tests.root_module.addOptions("test_options", test_options);

    // Link LZ4 compression library for compression module tests
    unit_tests.linkLibrary(options.lz4_dep.artifact("lz4"));

    steps.test_unit_build.dependOn(&b.addInstallArtifact(stdx_unit_tests, .{}).step);
    steps.test_unit_build.dependOn(&b.addInstallArtifact(unit_tests, .{}).step);

    const run_stdx_unit_tests = b.addRunArtifact(stdx_unit_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_stdx_unit_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    run_unit_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    if (b.args != null) { // Don't cache test results if running a specific test.
        run_stdx_unit_tests.has_side_effects = true;
        run_unit_tests.has_side_effects = true;
    }
    steps.test_unit.dependOn(&run_stdx_unit_tests.step);
    steps.test_unit.dependOn(&run_unit_tests.step);

    run_unit_tests.setCwd(b.path("."));

    build_test_integration(b, .{
        .test_integration = steps.test_integration,
        .test_integration_build = steps.test_integration_build,
    }, .{
        .arch_client_header = options.arch_client_header.path,
        .llvm_objcopy = options.llvm_objcopy,
        .stdx_module = options.stdx_module,
        .lz4_dep = options.lz4_dep,
        .target = options.target,
        .mode = options.mode,
        .integration_past = options.integration_past,
    });

    const run_fmt = b.addFmt(.{ .paths = &.{"."}, .check = true });
    steps.test_fmt.dependOn(&run_fmt.step);

    steps.@"test".dependOn(&run_stdx_unit_tests.step);
    steps.@"test".dependOn(&run_unit_tests.step);
    if (b.args == null) {
        steps.@"test".dependOn(steps.test_integration);
        steps.@"test".dependOn(steps.test_fmt);
    }
}

fn build_test_integration(
    b: *std.Build,
    steps: struct {
        test_integration: *std.Build.Step,
        test_integration_build: *std.Build.Step,
    },
    options: struct {
        arch_client_header: std.Build.LazyPath,
        llvm_objcopy: ?[]const u8,
        stdx_module: *std.Build.Module,
        lz4_dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
        integration_past: ?[]const u8,
    },
) void {
    // For integration tests, build an independent copy of ArcherDB with the lite config so
    // the test binary and server share the same message size limits.
    const vsr_options, const vsr_module = build_vsr_module(b, .{
        .stdx_module = options.stdx_module,
        .lz4_dep = options.lz4_dep,
        .git_commit = "a2c4e2db00000000000000000000000000a2c4e2".*, // ArcherDB-hash!
        .config_verify = true,
        .config_release = "65535.0.0",
        .config_release_client_min = "0.16.4",
        .config_aof_recovery = false,
        .config_base = .lite,
    });
    const archerdb_previous: ?std.Build.LazyPath = if (options.integration_past) |path|
        .{ .cwd_relative = path }
    else
        null;
    const skip_upgrade = archerdb_previous == null;
    const archerdb = if (archerdb_previous) |previous| blk: {
        break :blk build_archerdb_executable_multiversion(b, .{
            .stdx_module = options.stdx_module,
            .vsr_module = vsr_module,
            .vsr_options = vsr_options,
            .lz4_dep = options.lz4_dep,
            .llvm_objcopy = options.llvm_objcopy,
            .archerdb_previous = previous,
            .target = options.target,
            .mode = options.mode,
        });
    } else blk: {
        break :blk build_archerdb_executable(b, .{
            .vsr_module = vsr_module,
            .vsr_options = vsr_options,
            .lz4_dep = options.lz4_dep,
            .target = options.target,
            .mode = options.mode,
        }).getEmittedBin();
    };
    const archerdb_past = if (archerdb_previous) |previous| previous else archerdb;

    const vortex = build_vortex_executable(b, .{
        .arch_client_header = options.arch_client_header,
        .stdx_module = options.stdx_module,
        .vsr_module = vsr_module,
        .vsr_options = vsr_options,
        .lz4_dep = options.lz4_dep,
        .target = options.target,
        .mode = options.mode,
    });
    const vortex_artifact = b.addInstallArtifact(vortex, .{});

    const integration_tests_options = b.addOptions();
    integration_tests_options.addOptionPath("archerdb_exe", archerdb);
    integration_tests_options.addOptionPath("archerdb_exe_past", archerdb_past);
    integration_tests_options.addOption(bool, "skip_upgrade", skip_upgrade);
    integration_tests_options.addOptionPath("vortex_exe", vortex_artifact.emitted_bin.?);
    const integration_tests = b.addTest(.{
        .name = "test-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_tests.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
        .filters = b.args orelse &.{},
    });
    integration_tests.root_module.addImport("stdx", options.stdx_module);
    integration_tests.root_module.addOptions("vsr_options", vsr_options);
    integration_tests.root_module.addOptions("test_options", integration_tests_options);
    integration_tests.addIncludePath(options.arch_client_header.dirname());

    // Link LZ4 compression library for compression module tests
    integration_tests.linkLibrary(options.lz4_dep.artifact("lz4"));

    steps.test_integration_build.dependOn(&b.addInstallArtifact(integration_tests, .{}).step);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    if (b.args != null) { // Don't cache test results if running a specific test.
        run_integration_tests.has_side_effects = true;
    }
    run_integration_tests.has_side_effects = true;
    steps.test_integration.dependOn(&run_integration_tests.step);
}

fn build_test_jni(
    b: *std.Build,
    step_test_jni: *std.Build.Step,
    options: struct {
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) !void {
    const java_home = b.graph.env_map.get("JAVA_HOME") orelse {
        step_test_jni.dependOn(&b.addFail(
            "can't build jni tests tests, JAVA_HOME is not set",
        ).step);
        return;
    };

    // JNI test require JVM to be present, and are _not_ run as a part of `zig build test`.
    // We need libjvm.so both at build time and at a runtime, so use `FailStep` when that is not
    // available.
    const libjvm_path = b.pathJoin(&.{
        java_home,
        "/lib/server",
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/java/src/jni_tests.zig"),
            .target = options.target,
            // TODO(zig): The function `JNI_CreateJavaVM` tries to detect
            // the stack size and causes a SEGV that is handled by Zig's panic handler.
            // https://bugzilla.redhat.com/show_bug.cgi?id=1572811#c7
            //
            // The workaround is to run the tests in "ReleaseFast" mode.
            .optimize = options.mode,
        }),
    });
    tests.linkLibC();

    tests.linkSystemLibrary("jvm");
    tests.addLibraryPath(.{ .cwd_relative = libjvm_path });
    if (builtin.os.tag == .linux) {
        // On Linux, detects the abi by calling `ldd` to check if
        // the libjvm.so is linked against libc or musl.
        // It's reasonable to assume that ldd will be present.
        var exit_code: u8 = undefined;
        const stderr_behavior = .Ignore;
        const ldd_result = try b.runAllowFail(
            &.{ "ldd", b.pathJoin(&.{ libjvm_path, "libjvm.so" }) },
            &exit_code,
            stderr_behavior,
        );

        if (std.mem.indexOf(u8, ldd_result, "musl") != null) {
            tests.root_module.resolved_target.?.query.abi = .musl;
            tests.root_module.resolved_target.?.result.abi = .musl;
        } else if (std.mem.indexOf(u8, ldd_result, "libc") != null) {
            tests.root_module.resolved_target.?.query.abi = .gnu;
            tests.root_module.resolved_target.?.result.abi = .gnu;
        } else {
            std.log.err("{s}", .{ldd_result});
            return error.JavaAbiUnrecognized;
        }
    }

    switch (builtin.os.tag) {
        .macos => try b.graph.env_map.put("DYLD_LIBRARY_PATH", libjvm_path),
        .linux => try b.graph.env_map.put("LD_LIBRARY_PATH", libjvm_path),
        else => unreachable,
    }

    step_test_jni.dependOn(&b.addRunArtifact(tests).step);
}

fn build_test_integration_replication(
    b: *std.Build,
    step: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    // Replication integration tests (S3 upload with MinIO, disk spillover)
    // These tests require Docker to be available
    const replication_integration_tests = b.addTest(.{
        .name = "test-integration-replication",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/replication/integration_test.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
        .filters = b.args orelse &.{},
    });
    replication_integration_tests.root_module.addImport("stdx", options.stdx_module);

    const run_replication_tests = b.addRunArtifact(replication_integration_tests);
    if (b.args != null) {
        run_replication_tests.has_side_effects = true;
    }
    step.dependOn(&run_replication_tests.step);
}

fn build_vopr(
    b: *std.Build,
    steps: struct {
        vopr_build: *std.Build.Step,
        vopr_run: *std.Build.Step,
    },
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        lz4_dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
        print_exe: bool,
        vopr_state_machine: VoprStateMachine,
        vopr_log: VoprLog,
    },
) void {
    const vopr_options = b.addOptions();

    vopr_options.addOption(VoprStateMachine, "state_machine", options.vopr_state_machine);
    vopr_options.addOption(VoprLog, "log", options.vopr_log);

    const vopr = b.addExecutable(.{
        .name = "vopr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vopr.zig"),
            .target = options.target,
            // When running without a SEED, default to release.
            .optimize = if (b.args == null) .ReleaseSafe else options.mode,
        }),
    });
    vopr.stack_size = 4 * MiB;
    vopr.root_module.addImport("stdx", options.stdx_module);
    vopr.root_module.addOptions("vsr_options", options.vsr_options);
    vopr.root_module.addOptions("vsr_vopr_options", vopr_options);
    // Ensure that we get stack traces even in release builds.
    vopr.root_module.omit_frame_pointer = false;
    // Link LZ4 compression library
    vopr.linkLibrary(options.lz4_dep.artifact("lz4"));
    steps.vopr_build.dependOn(print_or_install(b, vopr, options.print_exe));

    const run_cmd = b.addRunArtifact(vopr);
    if (b.args) |args| run_cmd.addArgs(args);
    steps.vopr_run.dependOn(&run_cmd.step);
}

fn build_fuzz(
    b: *std.Build,
    steps: struct {
        fuzz: *std.Build.Step,
        fuzz_build: *std.Build.Step,
    },
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        lz4_dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
        print_exe: bool,
    },
) void {
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    fuzz_exe.stack_size = 4 * MiB;
    fuzz_exe.root_module.addImport("stdx", options.stdx_module);
    fuzz_exe.root_module.addOptions("vsr_options", options.vsr_options);
    fuzz_exe.root_module.omit_frame_pointer = false;
    fuzz_exe.linkLibC();
    {
        const lz4_artifact = options.lz4_dep.artifact("lz4");
        fuzz_exe.root_module.addIncludePath(lz4_artifact.getEmittedIncludeTree());
        fuzz_exe.linkLibrary(lz4_artifact);
    }
    steps.fuzz_build.dependOn(print_or_install(b, fuzz_exe, options.print_exe));

    const fuzz_run = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| fuzz_run.addArgs(args);
    steps.fuzz.dependOn(&fuzz_run.step);
}

fn build_scripts(
    b: *std.Build,
    steps: struct {
        scripts: *std.Build.Step,
        scripts_build: *std.Build.Step,
    },
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        target: std.Build.ResolvedTarget,
    },
) *std.Build.Step.Compile {
    const scripts_exe = b.addExecutable(.{
        .name = "scripts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scripts.zig"),
            .target = options.target,
            .optimize = .Debug,
        }),
    });
    scripts_exe.root_module.addImport("stdx", options.stdx_module);
    scripts_exe.root_module.addOptions("vsr_options", options.vsr_options);
    steps.scripts_build.dependOn(
        &b.addInstallArtifact(scripts_exe, .{}).step,
    );

    const scripts_run = b.addRunArtifact(scripts_exe);
    scripts_run.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    if (b.args) |args| scripts_run.addArgs(args);
    steps.scripts.dependOn(&scripts_run.step);

    return scripts_exe;
}

fn build_vortex(
    b: *std.Build,
    steps: struct {
        vortex_build: *std.Build.Step,
        vortex_run: *std.Build.Step,
    },
    options: struct {
        arch_client_header: std.Build.LazyPath,
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        lz4_dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
        print_exe: bool,
    },
) void {
    const vortex = build_vortex_executable(b, .{
        .arch_client_header = options.arch_client_header,
        .stdx_module = options.stdx_module,
        .vsr_module = options.vsr_module,
        .vsr_options = options.vsr_options,
        .lz4_dep = options.lz4_dep,
        .target = options.target,
        .mode = options.mode,
    });

    const install_step = print_or_install(b, vortex, options.print_exe);
    steps.vortex_build.dependOn(install_step);

    const run_cmd = b.addRunArtifact(vortex);
    if (b.args) |args| run_cmd.addArgs(args);
    steps.vortex_run.dependOn(&run_cmd.step);
}

fn build_vortex_executable(
    b: *std.Build,
    options: struct {
        arch_client_header: std.Build.LazyPath,
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        lz4_dep: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) *std.Build.Step.Compile {
    const arch_client = b.addLibrary(.{
        .name = "arch_client",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/archerdb/libarch_client.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    arch_client.linkLibC();
    arch_client.pie = true;
    arch_client.bundle_compiler_rt = true;
    arch_client.root_module.addImport("vsr", options.vsr_module);
    arch_client.root_module.addOptions("vsr_options", options.vsr_options);

    const archerdb = build_archerdb_executable(b, .{
        .vsr_module = options.vsr_module,
        .vsr_options = options.vsr_options,
        .lz4_dep = options.lz4_dep,
        .target = options.target,
        .mode = options.mode,
    });

    const vortex_options = b.addOptions();
    vortex_options.addOptionPath("archerdb_exe", archerdb.getEmittedBin());

    const vortex = b.addExecutable(.{
        .name = "vortex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vortex.zig"),
            .omit_frame_pointer = false,
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    vortex.root_module.addImport("stdx", options.stdx_module);
    vortex.linkLibC();
    vortex.linkLibrary(arch_client);
    vortex.addIncludePath(options.arch_client_header.dirname());
    vortex.root_module.addOptions("vsr_options", options.vsr_options);
    vortex.root_module.addOptions("vortex_options", vortex_options);
    return vortex;
}

// Zig cross-targets, Dotnet RID (Runtime Identifier), CPU features.
const platforms = .{
    .{ "x86_64-linux-gnu.2.27", "linux-x64", "x86_64_v3+aes" },
    .{ "x86_64-linux-musl", "linux-musl-x64", "x86_64_v3+aes" },
    .{ "x86_64-macos", "osx-x64", "x86_64_v3+aes" },
    .{ "aarch64-linux-gnu.2.27", "linux-arm64", "baseline+aes+neon" },
    .{ "aarch64-linux-musl", "linux-musl-arm64", "baseline+aes+neon" },
    .{ "aarch64-macos", "osx-arm64", "baseline+aes+neon" },
};

fn strip_glibc_version(triple: []const u8) []const u8 {
    if (std.mem.endsWith(u8, triple, "gnu.2.27")) {
        return triple[0 .. triple.len - ".2.27".len];
    }
    assert(std.mem.indexOf(u8, triple, "gnu") == null);
    return triple;
}

fn build_go_client(
    b: *std.Build,
    step_clients_go: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        arch_client_header: std.Build.LazyPath,
        mode: std.builtin.OptimizeMode,
    },
) void {
    // Updates the generated header file:
    const arch_client_header_copy = Generated.file_copy(b, .{
        .from = options.arch_client_header,
        .path = "./src/clients/go/pkg/native/arch_client.h",
    });

    const go_bindings_generator = b.addExecutable(.{
        .name = "go_bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/go/go_bindings.zig"),
            .target = b.graph.host,
        }),
    });
    go_bindings_generator.root_module.addImport("vsr", options.vsr_module);
    go_bindings_generator.root_module.addOptions("vsr_options", options.vsr_options);
    go_bindings_generator.step.dependOn(&arch_client_header_copy.step);
    const bindings = Generated.file(b, .{
        .generator = go_bindings_generator,
        .path = "./src/clients/go/pkg/types/bindings.go",
    });

    inline for (platforms) |platform| {
        // We don't need the linux-gnu builds.
        if (comptime std.mem.indexOf(u8, platform[0], "linux-gnu") != null) continue;

        const platform_name = if (comptime std.mem.eql(u8, platform[0], "x86_64-linux-musl"))
            "x86_64-linux"
        else if (comptime std.mem.eql(u8, platform[0], "aarch64-linux-musl"))
            "aarch64-linux"
        else
            platform[0];

        const query = Query.parse(.{
            .arch_os_abi = platform_name,
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(query);
        const lz4_dep = b.dependency("lz4", .{
            .target = resolved_target,
            .optimize = options.mode,
        });
        const vsr_module = create_vsr_module(b, .{
            .stdx_module = options.stdx_module,
            .vsr_options = options.vsr_options,
            .lz4_dep = lz4_dep,
        });

        const root_module = b.createModule(.{
            .root_source_file = b.path("src/archerdb/libarch_client.zig"),
            .target = resolved_target,
            .optimize = options.mode,
            .stack_protector = false,
        });
        root_module.addImport("vsr", vsr_module);
        root_module.addOptions("vsr_options", options.vsr_options);
        if (options.mode == .ReleaseSafe) strip_root_module(root_module);

        const lib = b.addLibrary(.{
            .name = "arch_client",
            .linkage = .static,
            .root_module = root_module,
        });
        lib.linkLibC();
        lib.pie = true;
        lib.bundle_compiler_rt = true;
        lib.step.dependOn(&bindings.step);

        const file_name: []const u8, const extension: []const u8 = cut: {
            assert(std.mem.count(u8, lib.out_lib_filename, ".") == 1);
            var it = std.mem.splitScalar(u8, lib.out_lib_filename, '.');
            defer assert(it.next() == null);
            break :cut .{ it.next().?, it.next().? };
        };

        // NB: New way to do lib.setOutputDir(). The ../ is important to escape zig-cache/.
        step_clients_go.dependOn(&b.addInstallFile(
            lib.getEmittedBin(),
            b.fmt("../src/clients/go/pkg/native/{s}_{s}.{s}", .{
                file_name,
                platform_name,
                extension,
            }),
        ).step);
    }
}

fn build_java_client(
    b: *std.Build,
    step_clients_java: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const java_bindings_generator = b.addExecutable(.{
        .name = "java_bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/java/java_bindings.zig"),
            .target = b.graph.host,
        }),
    });
    java_bindings_generator.root_module.addImport("vsr", options.vsr_module);
    java_bindings_generator.root_module.addOptions("vsr_options", options.vsr_options);
    const bindings = Generated.directory(b, .{
        .generator = java_bindings_generator,
        .path = "./src/clients/java/src/main/java/com/archerdb/",
    });

    inline for (platforms) |platform| {
        const query = Query.parse(.{
            .arch_os_abi = platform[0],
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(query);
        const lz4_dep = b.dependency("lz4", .{
            .target = resolved_target,
            .optimize = options.mode,
        });
        const vsr_module = create_vsr_module(b, .{
            .stdx_module = options.stdx_module,
            .vsr_options = options.vsr_options,
            .lz4_dep = lz4_dep,
        });

        const root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/java/src/client.zig"),
            .target = resolved_target,
            .optimize = options.mode,
        });
        root_module.addImport("vsr", vsr_module);
        root_module.addOptions("vsr_options", options.vsr_options);
        if (options.mode == .ReleaseSafe) strip_root_module(root_module);

        const lib = b.addLibrary(.{
            .name = "arch_jniclient",
            .linkage = .dynamic,
            .root_module = root_module,
        });
        lib.linkLibC();
        lib.step.dependOn(&bindings.step);

        // NB: New way to do lib.setOutputDir(). The ../ is important to escape zig-cache/.
        step_clients_java.dependOn(&b.addInstallFile(lib.getEmittedBin(), b.pathJoin(&.{
            "../src/clients/java/src/main/resources/lib/",
            strip_glibc_version(platform[0]),
            lib.out_filename,
        })).step);
    }
}

fn build_node_client(
    b: *std.Build,
    step_clients_node: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const node_bindings_generator = b.addExecutable(.{
        .name = "node_bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/node/node_bindings.zig"),
            .target = b.graph.host,
        }),
    });
    node_bindings_generator.root_module.addImport("vsr", options.vsr_module);
    node_bindings_generator.root_module.addOptions("vsr_options", options.vsr_options);
    const bindings = Generated.file(b, .{
        .generator = node_bindings_generator,
        .path = "./src/clients/node/src/bindings.ts",
    });

    // Run `npm install` to get access to node headers.
    const npm_install = b.addSystemCommand(&.{ "npm", "install" });
    npm_install.cwd = b.path("./src/clients/node");

    inline for (platforms) |platform| {
        const query = Query.parse(.{
            .arch_os_abi = platform[0],
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(query);
        const lz4_dep = b.dependency("lz4", .{
            .target = resolved_target,
            .optimize = options.mode,
        });
        const vsr_module = create_vsr_module(b, .{
            .stdx_module = options.stdx_module,
            .vsr_options = options.vsr_options,
            .lz4_dep = lz4_dep,
        });

        const root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/node/node.zig"),
            .target = resolved_target,
            .optimize = options.mode,
        });
        root_module.addImport("vsr", vsr_module);
        root_module.addOptions("vsr_options", options.vsr_options);
        if (options.mode == .ReleaseSafe) strip_root_module(root_module);

        const lib = b.addLibrary(.{
            .name = "arch_nodeclient",
            .linkage = .dynamic,
            .root_module = root_module,
        });
        lib.linkLibC();

        lib.step.dependOn(&npm_install.step);
        lib.addSystemIncludePath(b.path("src/clients/node/node_modules/node-api-headers/include"));
        lib.linker_allow_shlib_undefined = true;

        lib.step.dependOn(&bindings.step);
        step_clients_node.dependOn(&b.addInstallFile(lib.getEmittedBin(), b.pathJoin(&.{
            "../src/clients/node/dist/bin",
            strip_glibc_version(platform[0]),
            "/client.node",
        })).step);
    }
}

fn build_python_client(
    b: *std.Build,
    step_clients_python: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        arch_client_header: std.Build.LazyPath,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const python_bindings_generator = b.addExecutable(.{
        .name = "python_bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/python/python_bindings.zig"),
            .target = b.graph.host,
        }),
    });
    python_bindings_generator.root_module.addImport("vsr", options.vsr_module);
    python_bindings_generator.root_module.addOptions("vsr_options", options.vsr_options);
    const bindings = Generated.file(b, .{
        .generator = python_bindings_generator,
        .path = "./src/clients/python/src/archerdb/bindings.py",
    });

    inline for (platforms) |platform| {
        const query = Query.parse(.{
            .arch_os_abi = platform[0],
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(query);
        const lz4_dep = b.dependency("lz4", .{
            .target = resolved_target,
            .optimize = options.mode,
        });
        const vsr_module = create_vsr_module(b, .{
            .stdx_module = options.stdx_module,
            .vsr_options = options.vsr_options,
            .lz4_dep = lz4_dep,
        });

        const root_module = b.createModule(.{
            .root_source_file = b.path("src/archerdb/libarch_client.zig"),
            .target = resolved_target,
            .optimize = options.mode,
        });
        root_module.addImport("vsr", vsr_module);
        root_module.addOptions("vsr_options", options.vsr_options);
        if (options.mode == .ReleaseSafe) strip_root_module(root_module);

        const shared_lib = b.addLibrary(.{
            .name = "arch_client",
            .linkage = .dynamic,
            .root_module = root_module,
        });
        shared_lib.linkLibC();

        step_clients_python.dependOn(&b.addInstallFile(
            shared_lib.getEmittedBin(),
            b.pathJoin(&.{
                "../src/clients/python/src/archerdb/lib/",
                platform[0],
                shared_lib.out_filename,
            }),
        ).step);
    }

    step_clients_python.dependOn(&bindings.step);
}

fn build_c_client(
    b: *std.Build,
    step_clients_c: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        arch_client_header: *Generated,
        mode: std.builtin.OptimizeMode,
    },
) void {
    step_clients_c.dependOn(&options.arch_client_header.step);

    inline for (platforms) |platform| {
        const query = Query.parse(.{
            .arch_os_abi = platform[0],
            .cpu_features = platform[2],
        }) catch unreachable;
        const resolved_target = b.resolveTargetQuery(query);
        const lz4_dep = b.dependency("lz4", .{
            .target = resolved_target,
            .optimize = options.mode,
        });
        const vsr_module = create_vsr_module(b, .{
            .stdx_module = options.stdx_module,
            .vsr_options = options.vsr_options,
            .lz4_dep = lz4_dep,
        });

        const root_module = b.createModule(.{
            .root_source_file = b.path("src/archerdb/libarch_client.zig"),
            .target = resolved_target,
            .optimize = options.mode,
        });
        root_module.addImport("vsr", vsr_module);
        root_module.addOptions("vsr_options", options.vsr_options);
        if (options.mode == .ReleaseSafe) strip_root_module(root_module);

        const shared_lib = b.addLibrary(.{
            .name = "arch_client",
            .linkage = .dynamic,
            .root_module = root_module,
        });

        const static_lib = b.addLibrary(.{
            .name = "arch_client",
            .linkage = .static,
            .root_module = root_module,
        });
        static_lib.bundle_compiler_rt = true;
        static_lib.pie = true;

        for ([_]*std.Build.Step.Compile{ shared_lib, static_lib }) |lib| {
            lib.linkLibC();

            step_clients_c.dependOn(&b.addInstallFile(lib.getEmittedBin(), b.pathJoin(&.{
                "../src/clients/c/lib/",
                platform[0],
                lib.out_filename,
            })).step);
        }
    }
}

fn build_clients_c_sample(
    b: *std.Build,
    step_clients_c_sample: *std.Build.Step,
    options: struct {
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const static_lib = b.addLibrary(.{
        .name = "arch_client",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/archerdb/libarch_client.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    static_lib.linkLibC();
    static_lib.pie = true;
    static_lib.bundle_compiler_rt = true;
    static_lib.root_module.addImport("vsr", options.vsr_module);
    static_lib.root_module.addOptions("vsr_options", options.vsr_options);
    step_clients_c_sample.dependOn(&static_lib.step);

    const sample = b.addExecutable(.{
        .name = "c_sample",
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    sample.root_module.addCSourceFile(.{
        .file = b.path("src/clients/c/samples/main.c"),
    });
    sample.linkLibrary(static_lib);
    sample.linkLibC();

    const install_step = b.addInstallArtifact(sample, .{});
    step_clients_c_sample.dependOn(&install_step.step);
}

fn strip_root_module(root_module: *std.Build.Module) void {
    root_module.strip = true;
    // Ensure that we get stack traces even in release builds.
    root_module.omit_frame_pointer = false;
    root_module.unwind_tables = .none;
}

fn print_or_install(b: *std.Build, compile: *std.Build.Step.Compile, print: bool) *std.Build.Step {
    const PrintStep = struct {
        step: std.Build.Step,
        compile: *std.Build.Step.Compile,

        fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
            const print_step: *@This() = @fieldParentPtr("step", step);
            const path = print_step.compile.getEmittedBin().getPath2(step.owner, step);
            try std.io.getStdOut().writer().print("{s}\n", .{path});
        }
    };

    if (print) {
        const print_step = b.allocator.create(PrintStep) catch @panic("OOM");
        print_step.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "print exe",
                .owner = b,
                .makeFn = PrintStep.make,
            }),
            .compile = compile,
        };
        print_step.step.dependOn(&print_step.compile.step);
        return &print_step.step;
    } else {
        return &b.addInstallArtifact(compile, .{}).step;
    }
}

/// Code generation for files which must also be committed to the repository.
///
/// Runs the generator program to produce a file or a directory and copies the result to the
/// destination directory within the source tree.
///
/// On CI (when CI env var is set), the files are not updated, and merely checked for freshness.
const Generated = struct {
    step: std.Build.Step,
    path: std.Build.LazyPath,

    destination: []const u8,
    generated_file: std.Build.GeneratedFile,
    source: std.Build.LazyPath,
    mode: enum { file, directory },

    /// The `generator` program prints the file to stdout.
    pub fn file(b: *std.Build, options: struct {
        generator: *std.Build.Step.Compile,
        path: []const u8,
    }) *Generated {
        return create(b, options.path, .{
            .file = options.generator,
        });
    }

    pub fn file_copy(b: *std.Build, options: struct {
        from: std.Build.LazyPath,
        path: []const u8,
    }) *Generated {
        return create(b, options.path, .{
            .copy = options.from,
        });
    }

    /// The `generator` program creates several files in the output directory, which is passed in
    /// as an argument.
    ///
    /// NB: there's no check that there aren't extra file at the destination. In other words, this
    /// API can be used for mixing generated and hand-written files in a single directory.
    pub fn directory(b: *std.Build, options: struct {
        generator: *std.Build.Step.Compile,
        path: []const u8,
    }) *Generated {
        return create(b, options.path, .{
            .directory = options.generator,
        });
    }

    fn create(b: *std.Build, destination: []const u8, generator: union(enum) {
        file: *std.Build.Step.Compile,
        directory: *std.Build.Step.Compile,
        copy: std.Build.LazyPath,
    }) *Generated {
        assert(std.mem.startsWith(u8, destination, "./src"));
        const result = b.allocator.create(Generated) catch @panic("OOM");
        result.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("generate {s}", .{std.fs.path.basename(destination)}),
                .owner = b,
                .makeFn = make,
            }),
            .path = .{ .generated = .{ .file = &result.generated_file } },

            .destination = destination,
            .generated_file = .{ .step = &result.step },
            .source = switch (generator) {
                .file => |compile| b.addRunArtifact(compile).captureStdOut(),
                .directory => |compile| b.addRunArtifact(compile).addOutputDirectoryArg("out"),
                .copy => |lazy_path| lazy_path,
            },
            .mode = switch (generator) {
                .file, .copy => .file,
                .directory => .directory,
            },
        };
        result.source.addStepDependencies(&result.step);

        return result;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const b = step.owner;
        const generated: *Generated = @fieldParentPtr("step", step);
        const ci = try std.process.hasEnvVar(b.allocator, "CI");
        const source_path = generated.source.getPath2(b, step);

        if (ci) {
            const fresh = switch (generated.mode) {
                .file => file_fresh(b, source_path, generated.destination),
                .directory => directory_fresh(b, source_path, generated.destination),
            } catch |err| {
                return step.fail("unable to check '{s}': {s}", .{
                    generated.destination, @errorName(err),
                });
            };

            if (!fresh) {
                return step.fail("file '{s}' is outdated", .{
                    generated.destination,
                });
            }
            step.result_cached = true;
        } else {
            const prev = switch (generated.mode) {
                .file => file_update(b, source_path, generated.destination),
                .directory => directory_update(b, source_path, generated.destination),
            } catch |err| {
                return step.fail("unable to update '{s}': {s}", .{
                    generated.destination, @errorName(err),
                });
            };
            step.result_cached = prev == .fresh;
        }

        generated.generated_file.path = generated.destination;
    }

    fn file_fresh(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !bool {
        const want = try b.build_root.handle.readFileAlloc(
            b.allocator,
            source_path,
            std.math.maxInt(usize),
        );
        defer b.allocator.free(want);

        const got = b.build_root.handle.readFileAlloc(
            b.allocator,
            target_path,
            std.math.maxInt(usize),
        ) catch return false;
        defer b.allocator.free(got);

        return std.mem.eql(u8, want, got);
    }

    fn file_update(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !std.fs.Dir.PrevStatus {
        return std.fs.Dir.updateFile(
            b.build_root.handle,
            source_path,
            b.build_root.handle,
            target_path,
            .{},
        );
    }

    fn directory_fresh(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !bool {
        var source_dir = try b.build_root.handle.openDir(source_path, .{ .iterate = true });
        defer source_dir.close();

        var target_dir = b.build_root.handle.openDir(target_path, .{}) catch return false;
        defer target_dir.close();

        var source_iter = source_dir.iterate();
        while (try source_iter.next()) |entry| {
            assert(entry.kind == .file);
            const want = try source_dir.readFileAlloc(
                b.allocator,
                entry.name,
                std.math.maxInt(usize),
            );
            defer b.allocator.free(want);

            const got = target_dir.readFileAlloc(
                b.allocator,
                entry.name,
                std.math.maxInt(usize),
            ) catch return false;
            defer b.allocator.free(got);

            if (!std.mem.eql(u8, want, got)) return false;
        }

        return true;
    }

    fn directory_update(
        b: *std.Build,
        source_path: []const u8,
        target_path: []const u8,
    ) !std.fs.Dir.PrevStatus {
        var result: std.fs.Dir.PrevStatus = .fresh;
        var source_dir = try b.build_root.handle.openDir(source_path, .{ .iterate = true });
        defer source_dir.close();

        var target_dir = try b.build_root.handle.makeOpenPath(target_path, .{});
        defer target_dir.close();

        var source_iter = source_dir.iterate();
        while (try source_iter.next()) |entry| {
            assert(entry.kind == .file);
            const status = try std.fs.Dir.updateFile(
                source_dir,
                entry.name,
                target_dir,
                entry.name,
                .{},
            );
            if (status == .stale) result = .stale;
        }

        return result;
    }
};

fn download_release(
    b: *std.Build,
    version_or_latest: []const u8,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
) std.Build.LazyPath {
    const release_slug = if (std.mem.eql(u8, version_or_latest, "latest"))
        "latest/download"
    else
        b.fmt("download/{s}", .{version_or_latest});

    const arch = if (target.result.os.tag == .macos)
        "universal"
    else switch (target.result.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @panic("unsupported CPU"),
    };

    const os = switch (target.result.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => @panic("unsupported OS"),
    };

    const debug = switch (mode) {
        .ReleaseSafe => "",
        .Debug => "-debug",
        else => @panic("unsupported mode"),
    };

    const url = b.fmt(
        "https://github.com/archerdb/archerdb" ++
            "/releases/{s}/archerdb-{s}-{s}{s}.zip",
        .{ release_slug, arch, os, debug },
    );

    return fetch(b, .{
        .url = url,
        .file_name = "archerdb",
        .hash = null,
    });
}

// Use 'zig fetch' to download and unpack the specified URL, optionally verifying the checksum.
fn fetch(b: *std.Build, options: struct {
    url: []const u8,
    file_name: []const u8,
    hash: ?[]const u8,
}) std.Build.LazyPath {
    const copy_from_cache = b.addRunArtifact(b.addExecutable(.{
        .name = "copy-from-cache",
        .root_module = b.createModule(.{
            .root_source_file = b.addWriteFiles().add("main.zig",
                \\const builtin = @import("builtin");
                \\const std = @import("std");
                \\const assert = std.debug.assert;
                \\
                \\pub fn main() !void {
                \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                \\    const allocator = arena.allocator();
                \\    const args = try std.process.argsAlloc(allocator);
                \\    assert(args.len == 5 or args.len == 6);
                \\
                \\    const hash_and_newline = try std.fs.cwd().readFileAlloc(allocator, args[2], 128);
                \\    assert(hash_and_newline[hash_and_newline.len - 1] == '\n');
                \\    const hash = hash_and_newline[0 .. hash_and_newline.len - 1];
                \\    if (args.len == 6 and !std.mem.eql(u8, args[5], hash)) {
                \\        std.debug.panic(
                \\            \\bad hash
                \\            \\specified:  {s}
                \\            \\downloaded: {s}
                \\            \\
                \\        , .{ args[5], hash });
                \\    }
                \\
                \\    const source_path = try std.fs.path.join(allocator, &.{ args[1], hash, args[3] });
                \\    try std.fs.cwd().copyFile(
                \\        source_path,
                \\        std.fs.cwd(),
                \\        args[4],
                \\        .{},
                \\    );
                \\}
            ),
            .target = b.graph.host,
        }),
    }));
    copy_from_cache.addArg(
        b.graph.global_cache_root.join(b.allocator, &.{"p"}) catch @panic("OOM"),
    );
    copy_from_cache.addFileArg(
        b.addSystemCommand(&.{ b.graph.zig_exe, "fetch", options.url }).captureStdOut(),
    );
    copy_from_cache.addArg(options.file_name);
    const result = copy_from_cache.addOutputFileArg(options.file_name);
    if (options.hash) |hash| {
        copy_from_cache.addArg(hash);
    }
    return result;
}

const MiB = 1024 * 1024;
