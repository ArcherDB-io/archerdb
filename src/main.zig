const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");

pub fn main() void {
    var args = std.process.args();
    _ = args.skip(); // skip program name

    const cmd = args.next() orelse {
        print_usage();
        return;
    };

    if (std.mem.eql(u8, cmd, "version")) {
        const verbose = if (args.next()) |arg|
            std.mem.eql(u8, arg, "--verbose")
        else
            false;
        command_version(verbose);
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
    }
}

fn print_usage() void {
    std.debug.print(
        \\Usage: archerdb <command>
        \\
        \\Commands:
        \\  version [--verbose]  Print version information
        \\
    , .{});
}

fn command_version(verbose: bool) void {
    const v = constants.semver;
    std.debug.print("ArcherDB version {d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    if (v.build) |build| {
        std.debug.print("+{s}", .{build});
    }
    std.debug.print("\n", .{});

    if (verbose) {
        std.debug.print("\nbuild.mode: {s}\n", .{@tagName(builtin.mode)});
        std.debug.print("build.zig_version: {s}\n", .{builtin.zig_version_string});
    }
}

test "basic" {
    // Placeholder test
}
