// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Micro benchmarking harness.
//!
//! Goals:
//! - relative (comparative) benchmarking,
//! - manual checks when refactoring/optimizing/upgrading compiler,
//! - no benchmark bitrot.
//!
//! Non-goals:
//! - absolute benchmarking.
//!
//! If you run
//!     $ ./zig/zig build test
//! the benchmarks are run in "test" mode which uses small inputs, finishes quickly, and doesn't
//! print anything to stdout.
//!
//! If you run
//!     $ ./zig/zig build -Drelease test -- "benchmark: binary search"
//! the benchmark is run for real, with a large input, longer runtime, and results on stderr.
//! The `benchmark` in the test name is the secret code to unlock benchmarking code.

test "benchmark: API tutorial" { // `benchmark:` in the name is important!
    var bench: Bench = .init();
    defer bench.deinit();

    // Parameters are named, and have two default values.
    // The small value is used in tests, to prevent bitrot.
    // The large value is the canonical when running benchmark "for real".
    // You can pass custom values via env variables:
    //    $ a=92 ./zig/zig build test -- "benchmark: tutorial"
    const a = bench.parameter("a", 1, 1_000);
    const b = bench.parameter("b", 2, 2_000);

    bench.start(); // Built-in timer.
    const c = a + b;
    const elapsed = bench.stop();

    // Always print a "hash" of the run:
    // - to prevent compiler from optimizing the code away,
    // - to prevent YOU from "optimizing" the code by changing semantics.
    bench.report("hash: {}", .{c});
    // Print the time, and any other metrics you find important.
    bench.report("elapsed: {}", .{elapsed});

    // NB: print as little as possible, because humans read slowly.
    // It's the job of benchmark author to optimize for conciseness.

    // You can compile individual benchmark  via
    //   ./zig/zig build test:unit:build -- "benchmark: binary search"
    // and use the resulting binary with perf/hyperfine/poop.
}

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const Duration = stdx.Duration;
const Instant = stdx.Instant;
const TimeOS = @import("../time.zig").TimeOS;

const seed_benchmark: u64 = 42;

const mode: enum { smoke, benchmark } =
    // See build.zig for how this is ultimately determined.
    if (@import("test_options").benchmark) .benchmark else .smoke;

seed: u64,
time: TimeOS = .{},
instant_start: ?Instant = null,

const Bench = @This();

pub fn init() Bench {
    return .{
        // Benchmarks require a fixed seed for reproducibility; smoke mode uses a random seed.
        .seed = if (mode == .benchmark) seed_benchmark else std.testing.random_seed,
    };
}

pub fn deinit(bench: *Bench) void {
    assert(bench.instant_start == null);
    bench.* = undefined;
}

pub fn parameter(
    b: *const Bench,
    comptime name: []const u8,
    value_smoke: u64,
    value_benchmark: u64,
) u64 {
    assert(value_smoke < value_benchmark);
    const value = parameter_fallible(name, value_smoke, value_benchmark) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => @panic("invalid benchmark parameter value"),
    };
    b.report("{s}={}", .{ name, value });
    return value;
}

fn parameter_fallible(
    comptime name: []const u8,
    value_smoke: u64,
    value_benchmark: u64,
) std.fmt.ParseIntError!u64 {
    assert(value_smoke < value_benchmark);
    return switch (mode) {
        .smoke => value_smoke,
        .benchmark => std.process.parseEnvVarInt(name, u64, 10) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return value_benchmark,
            else => |e| return e,
        },
    };
}

pub fn start(bench: *Bench) void {
    assert(bench.instant_start == null);
    defer assert(bench.instant_start != null);

    bench.instant_start = bench.time.time().monotonic();
}

pub fn stop(bench: *Bench) Duration {
    assert(bench.instant_start != null);
    defer assert(bench.instant_start == null);

    const instant_stop = bench.time.time().monotonic();
    const elapsed = instant_stop.duration_since(bench.instant_start.?);
    bench.instant_start = null;
    return elapsed;
}

// Sort the durations and return the third-fastest sample (discarding the two fastest outliers)
// to get a more stable estimate, assuming benchmark timings are roughly log-normal.
// E.g. see https://lemire.me/blog/2018/01/16/microbenchmarking-calls-for-idealized-conditions/
pub fn estimate(bench: *const Bench, durations: []Duration) Duration {
    assert(durations.len >= 8); // Ensure that we have enough samples to get a meaningful result.
    _ = bench;
    std.sort.block(stdx.Duration, durations, {}, stdx.Duration.sort.asc);
    return durations[2];
}

pub fn report(_: *const Bench, comptime fmt: []const u8, args: anytype) void {
    switch (mode) {
        .smoke => {},
        .benchmark => std.debug.print(fmt ++ "\n", args),
    }
}

/// Run benchmark multiple times and return statistical result
pub fn runWithStatistics(
    bench: *Bench,
    comptime runs: usize,
    comptime func: fn (*Bench) Duration,
) StatisticalResult {
    var durations: [runs]Duration = undefined;
    for (&durations) |*d| {
        d.* = func(bench);
    }
    return computeStatistics(&durations);
}

/// Statistical analysis result for benchmark runs
pub const StatisticalResult = struct {
    mean_ns: f64,
    std_dev_ns: f64,
    confidence_interval_95: struct { lower_ns: f64, upper_ns: f64 },
    min_ns: f64,
    max_ns: f64,
    p50_ns: f64,
    p99_ns: f64,
    samples: usize,
    outliers_removed: usize,

    /// Format as human-readable output
    pub fn format(self: *const @This(), writer: anytype) !void {
        try writer.print(
            \\mean={d:.3}ms (+/- {d:.3}ms)
            \\95% CI: [{d:.3}ms, {d:.3}ms]
            \\P50={d:.3}ms P99={d:.3}ms min={d:.3}ms max={d:.3}ms
            \\samples={d} (outliers removed: {d})
        , .{
            self.mean_ns / 1e6, self.std_dev_ns / 1e6,
            self.confidence_interval_95.lower_ns / 1e6,
            self.confidence_interval_95.upper_ns / 1e6,
            self.p50_ns / 1e6, self.p99_ns / 1e6,
            self.min_ns / 1e6, self.max_ns / 1e6,
            self.samples, self.outliers_removed,
        });
    }

    /// Compare with baseline, return true if regression detected
    /// Regression if current mean > baseline mean + 2 * baseline stddev
    pub fn isRegression(self: *const @This(), baseline: *const @This()) bool {
        const threshold = baseline.mean_ns + 2.0 * baseline.std_dev_ns;
        return self.mean_ns > threshold;
    }

    /// Format comparison with baseline
    pub fn formatComparison(self: *const @This(), baseline: *const @This(), writer: anytype) !void {
        const delta_percent = ((self.mean_ns - baseline.mean_ns) / baseline.mean_ns) * 100.0;
        const verdict: []const u8 = if (self.isRegression(baseline))
            "REGRESSION"
        else if (delta_percent < -5.0)
            "IMPROVEMENT"
        else
            "NO CHANGE";
        try writer.print("{s}: {d:.1}% ({d:.3}ms -> {d:.3}ms)\n", .{
            verdict, delta_percent, baseline.mean_ns / 1e6, self.mean_ns / 1e6,
        });
    }
};

/// Compute statistical analysis from duration samples
pub fn computeStatistics(durations: []const Duration) StatisticalResult {
    const max_samples = 256;
    var samples: [max_samples]f64 = undefined;
    const n = @min(durations.len, max_samples);

    // Convert to nanoseconds array
    for (durations[0..n], 0..) |d, i| {
        samples[i] = @floatFromInt(d.total_ns());
    }

    // Sort for percentiles
    std.sort.block(f64, samples[0..n], {}, std.sort.asc(f64));

    // Remove outliers using IQR method
    const q1_idx = n / 4;
    const q3_idx = (n * 3) / 4;
    const iqr = samples[q3_idx] - samples[q1_idx];
    const lower_bound = samples[q1_idx] - 1.5 * iqr;
    const upper_bound = samples[q3_idx] + 1.5 * iqr;

    var filtered: [max_samples]f64 = undefined;
    var filtered_count: usize = 0;
    var outliers: usize = 0;
    for (samples[0..n]) |s| {
        if (s >= lower_bound and s <= upper_bound) {
            filtered[filtered_count] = s;
            filtered_count += 1;
        } else {
            outliers += 1;
        }
    }

    // Edge case: if all samples are outliers, use all samples
    if (filtered_count == 0) {
        for (samples[0..n], 0..) |s, i| {
            filtered[i] = s;
        }
        filtered_count = n;
        outliers = 0;
    }

    // Compute mean
    var sum: f64 = 0;
    for (filtered[0..filtered_count]) |s| sum += s;
    const mean = sum / @as(f64, @floatFromInt(filtered_count));

    // Compute standard deviation
    var variance_sum: f64 = 0;
    for (filtered[0..filtered_count]) |s| {
        const diff = s - mean;
        variance_sum += diff * diff;
    }
    const std_dev = @sqrt(variance_sum / @as(f64, @floatFromInt(filtered_count)));

    // Standard error and 95% confidence interval (z=1.96)
    const se = std_dev / @sqrt(@as(f64, @floatFromInt(filtered_count)));

    return .{
        .mean_ns = mean,
        .std_dev_ns = std_dev,
        .confidence_interval_95 = .{
            .lower_ns = mean - 1.96 * se,
            .upper_ns = mean + 1.96 * se,
        },
        .min_ns = filtered[0],
        .max_ns = filtered[filtered_count - 1],
        .p50_ns = filtered[filtered_count / 2],
        .p99_ns = filtered[@min((filtered_count * 99) / 100, filtered_count - 1)],
        .samples = filtered_count,
        .outliers_removed = outliers,
    };
}
