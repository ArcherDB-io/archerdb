const std = @import("std");
const assert = std.debug.assert;

const generator_id = "tools/s2_golden_gen/main.zig";
const generator_version = "v1";

const go_ref_module = "github.com/golang/geo";
const go_ref_dir = "tools/s2_golden_gen/reference/go_s2_ref";

const tmp_dir_path = ".zig-cache/s2_golden_gen";
const tmp_input_path = tmp_dir_path ++ "/input.tsv";
const tmp_output_path = tmp_dir_path ++ "/output.tsv";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var out_path: ?[]const u8 = null;
    var seed: u64 = 1;
    var random_count: u32 = 1024;
    var levels_csv: []const u8 = "0,1,5,10,15,18,30";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out_path = args[i];
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--random")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            random_count = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--levels")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            levels_csv = args[i];
        } else if (std.mem.eql(u8, a, "--help")) {
            try usage();
            return;
        } else {
            return error.InvalidArgs;
        }
    }

    const outp = out_path orelse return error.InvalidArgs;

    const go_ref_version = try readGoRefVersion(allocator);
    defer allocator.free(go_ref_version);

    const levels = try parseLevelsCsv(allocator, levels_csv);
    defer allocator.free(levels);

    const vectors = try buildVectors(allocator, seed, random_count, levels);
    defer allocator.free(vectors);

    try generateWithGoReference(allocator, vectors);
    try writeFinalOutput(allocator, outp, seed, random_count, levels_csv, go_ref_version);
}

const Coord = struct {
    lat_nano: i64,
    lon_nano: i64,
};

const Vector = struct {
    lat_nano: i64,
    lon_nano: i64,
    level: u8,
};

const SplitMix64 = struct {
    state: u64,

    pub fn init(seed: u64) SplitMix64 {
        return .{ .state = seed };
    }

    pub fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
};

fn parseLevelsCsv(allocator: std.mem.Allocator, csv: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;

        const level = try std.fmt.parseInt(u8, part, 10);
        if (level > 30) return error.InvalidLevel;
        try list.append(allocator, level);
    }
    if (list.items.len == 0) return error.InvalidLevel;

    std.sort.pdq(u8, list.items, {}, struct {
        fn lessThan(_: void, a: u8, b: u8) bool {
            return a < b;
        }
    }.lessThan);

    // De-dup levels.
    var out_len: usize = 0;
    for (list.items) |lvl| {
        if (out_len == 0 or list.items[out_len - 1] != lvl) {
            list.items[out_len] = lvl;
            out_len += 1;
        }
    }
    list.shrinkAndFree(allocator, out_len);

    return try list.toOwnedSlice(allocator);
}

fn buildVectors(
    allocator: std.mem.Allocator,
    seed: u64,
    random_count: u32,
    levels: []const u8,
) ![]Vector {
    const edge_coords = [_]Coord{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 0, .lon_nano = 180_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = -180_000_000_000 },
        .{ .lat_nano = 90_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = -90_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 89_999_999_999, .lon_nano = 0 },
        .{ .lat_nano = -89_999_999_999, .lon_nano = 0 },
        .{ .lat_nano = 0, .lon_nano = 179_999_999_999 },
        .{ .lat_nano = 0, .lon_nano = -179_999_999_999 },
        .{ .lat_nano = 45_000_000_000, .lon_nano = 45_000_000_000 },
        .{ .lat_nano = -45_000_000_000, .lon_nano = -45_000_000_000 },
    };

    var coord_set = std.AutoHashMap(Coord, void).init(allocator);
    defer coord_set.deinit();

    var coords: std.ArrayList(Coord) = .empty;
    defer coords.deinit(allocator);

    for (edge_coords) |c| {
        try coord_set.put(c, {});
        try coords.append(allocator, c);
    }

    var rng = SplitMix64.init(seed);

    const lat_min: i64 = -90_000_000_000;
    const lat_max: i64 = 90_000_000_000;
    const lon_min: i64 = -180_000_000_000;
    const lon_max: i64 = 180_000_000_000;

    while (coords.items.len < edge_coords.len + @as(usize, random_count)) {
        const lat = randI64Range(&rng, lat_min, lat_max);
        const lon = randI64Range(&rng, lon_min, lon_max);
        const c = Coord{ .lat_nano = lat, .lon_nano = lon };
        if (coord_set.contains(c)) continue;
        try coord_set.put(c, {});
        try coords.append(allocator, c);
    }

    var vectors: std.ArrayList(Vector) = .empty;
    errdefer vectors.deinit(allocator);

    for (coords.items) |c| {
        for (levels) |lvl| {
            try vectors.append(allocator, .{
                .lat_nano = c.lat_nano,
                .lon_nano = c.lon_nano,
                .level = lvl,
            });
        }
    }

    std.sort.pdq(Vector, vectors.items, {}, struct {
        fn lessThan(_: void, a: Vector, b: Vector) bool {
            if (a.level != b.level) return a.level < b.level;
            if (a.lat_nano != b.lat_nano) return a.lat_nano < b.lat_nano;
            return a.lon_nano < b.lon_nano;
        }
    }.lessThan);

    // Assert uniqueness.
    var j: usize = 1;
    while (j < vectors.items.len) : (j += 1) {
        const prev = vectors.items[j - 1];
        const cur = vectors.items[j];
        const is_dup = prev.level == cur.level and
            prev.lat_nano == cur.lat_nano and prev.lon_nano == cur.lon_nano;
        if (is_dup) {
            return error.DuplicateVector;
        }
    }

    return try vectors.toOwnedSlice(allocator);
}

fn randI64Range(rng: *SplitMix64, min: i64, max: i64) i64 {
    assert(min <= max);
    const span = @as(u64, @intCast(max - min)) + 1;
    const v = rng.next() % span;
    return min + @as(i64, @intCast(v));
}

fn readGoRefVersion(allocator: std.mem.Allocator) ![]u8 {
    const gomod_path = go_ref_dir ++ "/go.mod";
    const gomod = try std.fs.cwd().readFileAlloc(allocator, gomod_path, 64 * 1024);
    defer allocator.free(gomod);

    var it = std.mem.splitScalar(u8, gomod, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        // Match either:
        //   require github.com/golang/geo vX
        // or inside a require (...) block:
        //   github.com/golang/geo vX
        if (std.mem.indexOf(u8, line, go_ref_module) == null) continue;

        var tok = std.mem.tokenizeAny(u8, line, " \t");
        while (tok.next()) |t| {
            if (std.mem.eql(u8, t, go_ref_module)) {
                const ver = tok.next() orelse return error.ReferenceVersionNotFound;
                return try allocator.dupe(u8, ver);
            }
        }
    }
    return error.ReferenceVersionNotFound;
}

fn generateWithGoReference(allocator: std.mem.Allocator, vectors: []const Vector) !void {
    try std.fs.cwd().makePath(tmp_dir_path);
    const go_cache_path = tmp_dir_path ++ "/go-build-cache";
    try std.fs.cwd().makePath(go_cache_path);
    try writeInputFile(tmp_input_path, vectors);

    const cwd_abs = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_abs);
    const input_abs = try std.fs.path.join(allocator, &.{ cwd_abs, tmp_input_path });
    defer allocator.free(input_abs);
    const output_abs = try std.fs.path.join(allocator, &.{ cwd_abs, tmp_output_path });
    defer allocator.free(output_abs);
    const go_cache_abs = try std.fs.path.join(allocator, &.{ cwd_abs, go_cache_path });
    defer allocator.free(go_cache_abs);

    var child = std.process.Child.init(
        &.{
            "go",
            "run",
            "-mod=vendor",
            ".",
            "--in",
            input_abs,
            "--out",
            output_abs,
        },
        allocator,
    );
    child.cwd = go_ref_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("GOCACHE", go_cache_abs);
    child.env_map = &env_map;

    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ReferenceGeneratorFailed,
        else => return error.ReferenceGeneratorFailed,
    }

    const out_stat = try std.fs.cwd().statFile(tmp_output_path);
    if (out_stat.size == 0) return error.ReferenceGeneratorFailed;
}

fn writeInputFile(path: []const u8, vectors: []const Vector) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(&buf);
    const w = &file_writer.interface;

    try w.writeAll("lat_nano\tlon_nano\tlevel\n");
    for (vectors) |v| {
        try w.print("{d}\t{d}\t{d}\n", .{ v.lat_nano, v.lon_nano, v.level });
    }
    try w.flush();
}

fn writeFinalOutput(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    seed: u64,
    random_count: u32,
    levels_csv: []const u8,
    go_ref_version: []const u8,
) !void {
    var cwd = std.fs.cwd();

    if (std.fs.path.dirname(out_path)) |parent| {
        cwd.makePath(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var out_file = try cwd.createFile(out_path, .{ .truncate = true });
    defer out_file.close();

    var buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(&buf);
    const w = &out_writer.interface;

    try w.print("# generator: {s} {s}\n", .{ generator_id, generator_version });
    try w.print("# reference: {s}@{s}\n", .{ go_ref_module, go_ref_version });
    try w.print("# seed: {d}\n", .{seed});
    try w.print("# random: {d}\n", .{random_count});
    try w.print("# levels: {s}\n", .{levels_csv});
    try w.writeAll("lat_nano\tlon_nano\tlevel\tcell_id_hex\n");

    const data = try cwd.readFileAlloc(allocator, tmp_output_path, 8 * 1024 * 1024);
    defer allocator.free(data);
    try w.writeAll(data);
    try w.flush();
}

fn usage() !void {
    try std.fs.File.stdout().writeAll(
        "Usage:\n" ++
            "  zig run tools/s2_golden_gen/main.zig -- \\\n" ++
            "    --out testdata/s2/golden_vectors_v1.tsv \\\n" ++
            "    --seed 1 --random 1024 --levels 0,1,5,10,15,18,30\n",
    );
}
