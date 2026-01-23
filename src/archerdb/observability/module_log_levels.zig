// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Per-module log level configuration.
//!
//! Provides fine-grained control over log output by allowing different log levels
//! for different subsystems. This enables verbose debugging of specific modules
//! (e.g., VSR consensus) while keeping other modules at info level.
//!
//! CLI format: `--log-level=info,vsr:debug,lsm:warn`
//! - First value is the default level for all modules
//! - Additional module:level pairs override specific modules
//!
//! Example:
//!
//!     var levels = ModuleLogLevels.init(allocator);
//!     defer levels.deinit();
//!
//!     try levels.parseOverrides("info,vsr:debug,replica:debug,lsm:warn");
//!
//!     if (levels.shouldLog(.replica, .debug)) {
//!         // This will log because replica is set to debug
//!     }
//!
//!     if (levels.shouldLog(.grid, .debug)) {
//!         // This will NOT log because grid uses default (info)
//!     }

const std = @import("std");
const assert = std.debug.assert;

/// Per-module log level configuration.
///
/// Stores a default log level and optional per-module overrides.
/// Module names are matched against the scope names used in std.log.scoped().
pub const ModuleLogLevels = struct {
    /// Default log level for modules without explicit overrides.
    default: std.log.Level = .info,
    /// Per-module level overrides.
    overrides: std.StringHashMap(std.log.Level),
    /// Allocator for override storage.
    allocator: std.mem.Allocator,

    /// Initialize a new ModuleLogLevels with default settings.
    pub fn init(allocator: std.mem.Allocator) ModuleLogLevels {
        return .{
            .default = .info,
            .overrides = std.StringHashMap(std.log.Level).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *ModuleLogLevels) void {
        // Free the stored module name keys
        var it = self.overrides.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.overrides.deinit();
    }

    /// Parse log level specification from CLI format.
    ///
    /// Format: "level[,module:level,...]"
    /// Examples:
    ///   - "info"
    ///   - "info,vsr:debug"
    ///   - "warn,vsr:debug,lsm:info,replica:debug"
    ///
    /// Returns error if format is invalid.
    pub fn parseOverrides(self: *ModuleLogLevels, spec: []const u8) !void {
        var it = std.mem.splitScalar(u8, spec, ',');
        var first = true;

        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOf(u8, trimmed, ":")) |colon| {
                // Module:level pair
                const module = trimmed[0..colon];
                const level_str = trimmed[colon + 1 ..];
                const level = parseLevel(level_str) orelse return error.InvalidLogLevel;

                // Allocate a copy of the module name for storage
                const module_copy = try self.allocator.dupe(u8, module);
                errdefer self.allocator.free(module_copy);

                // If key already exists, free the old one
                if (self.overrides.fetchRemove(module_copy)) |removed| {
                    self.allocator.free(removed.key);
                }

                try self.overrides.put(module_copy, level);
            } else if (first) {
                // First entry without colon is the default level
                const level = parseLevel(trimmed) orelse return error.InvalidLogLevel;
                self.default = level;
                first = false;
            } else {
                // Subsequent entries must have colon
                return error.InvalidLogLevelFormat;
            }
        }
    }

    /// Check if a log message with the given scope and level should be logged.
    ///
    /// The scope is typically an enum literal like .vsr, .replica, .lsm, etc.
    /// Messages are logged if their level is <= the configured level for that scope.
    pub fn shouldLog(
        self: *const ModuleLogLevels,
        comptime scope: @Type(.EnumLiteral),
        level: std.log.Level,
    ) bool {
        const scope_name = comptime if (scope == .default) "default" else @tagName(scope);
        return self.shouldLogByName(scope_name, level);
    }

    /// Check if a log message with the given scope name and level should be logged.
    ///
    /// Runtime version that takes scope name as a string.
    pub fn shouldLogByName(
        self: *const ModuleLogLevels,
        scope_name: []const u8,
        level: std.log.Level,
    ) bool {
        const configured_level = self.overrides.get(scope_name) orelse self.default;
        return @intFromEnum(level) <= @intFromEnum(configured_level);
    }

    /// Set the log level for a specific module at runtime.
    ///
    /// This allows dynamic reconfiguration (e.g., via admin endpoint).
    pub fn setModuleLevel(self: *ModuleLogLevels, module: []const u8, level: std.log.Level) !void {
        // Check if we already have an entry for this module
        if (self.overrides.getKey(module)) |existing_key| {
            // Update the level in place
            self.overrides.putAssumeCapacity(existing_key, level);
        } else {
            // Allocate new key
            const module_copy = try self.allocator.dupe(u8, module);
            errdefer self.allocator.free(module_copy);
            try self.overrides.put(module_copy, level);
        }
    }

    /// Get the configured log level for a specific module.
    ///
    /// Returns the module-specific override if set, otherwise the default.
    pub fn getModuleLevel(self: *const ModuleLogLevels, module: []const u8) std.log.Level {
        return self.overrides.get(module) orelse self.default;
    }

    /// Get the default log level.
    pub fn getDefault(self: *const ModuleLogLevels) std.log.Level {
        return self.default;
    }

    /// Set the default log level.
    pub fn setDefault(self: *ModuleLogLevels, level: std.log.Level) void {
        self.default = level;
    }

    /// List all configured overrides.
    pub fn listOverrides(self: *const ModuleLogLevels) std.StringHashMap(std.log.Level).Iterator {
        return self.overrides.iterator();
    }
};

/// Parse a log level string to std.log.Level.
fn parseLevel(str: []const u8) ?std.log.Level {
    const lower = std.ascii.lowerString(&[_]u8{0} ** 8, str);
    const level_str = lower[0..@min(str.len, 8)];

    if (std.mem.eql(u8, level_str[0..@min(3, str.len)], "err")) return .err;
    if (std.mem.eql(u8, level_str[0..@min(5, str.len)], "error")) return .err;
    if (std.mem.eql(u8, level_str[0..@min(4, str.len)], "warn")) return .warn;
    if (std.mem.eql(u8, level_str[0..@min(7, str.len)], "warning")) return .warn;
    if (std.mem.eql(u8, level_str[0..@min(4, str.len)], "info")) return .info;
    if (std.mem.eql(u8, level_str[0..@min(5, str.len)], "debug")) return .debug;

    return null;
}

// =============================================================================
// Global instance for runtime configuration
// =============================================================================

/// Global module log levels instance.
/// Set via setGlobalModuleLogLevels() during initialization.
var global_module_log_levels: ?*ModuleLogLevels = null;

/// Set the global module log levels instance.
///
/// Call during startup with the parsed CLI configuration.
/// Pass null to disable per-module filtering.
pub fn setGlobalModuleLogLevels(levels: ?*ModuleLogLevels) void {
    global_module_log_levels = levels;
}

/// Get the global module log levels instance.
///
/// Returns null if not configured.
pub fn getGlobalModuleLogLevels() ?*const ModuleLogLevels {
    return global_module_log_levels;
}

/// Check if a message should be logged based on global module configuration.
///
/// If no global configuration is set, always returns true.
pub fn shouldLogGlobal(comptime scope: @Type(.EnumLiteral), level: std.log.Level) bool {
    if (global_module_log_levels) |levels| {
        return levels.shouldLog(scope, level);
    }
    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "parseLevel" {
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLevel("err"));
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLevel("error"));
    try std.testing.expectEqual(@as(?std.log.Level, .warn), parseLevel("warn"));
    try std.testing.expectEqual(@as(?std.log.Level, .warn), parseLevel("warning"));
    try std.testing.expectEqual(@as(?std.log.Level, .info), parseLevel("info"));
    try std.testing.expectEqual(@as(?std.log.Level, .debug), parseLevel("debug"));
    try std.testing.expectEqual(@as(?std.log.Level, null), parseLevel("invalid"));
    try std.testing.expectEqual(@as(?std.log.Level, null), parseLevel(""));
}

test "ModuleLogLevels: default only" {
    var levels = ModuleLogLevels.init(std.testing.allocator);
    defer levels.deinit();

    try levels.parseOverrides("debug");

    try std.testing.expectEqual(std.log.Level.debug, levels.default);
    try std.testing.expect(levels.shouldLog(.vsr, .debug));
    try std.testing.expect(levels.shouldLog(.replica, .info));
}

test "ModuleLogLevels: with overrides" {
    var levels = ModuleLogLevels.init(std.testing.allocator);
    defer levels.deinit();

    try levels.parseOverrides("info,vsr:debug,lsm:warn");

    try std.testing.expectEqual(std.log.Level.info, levels.default);
    try std.testing.expectEqual(std.log.Level.debug, levels.getModuleLevel("vsr"));
    try std.testing.expectEqual(std.log.Level.warn, levels.getModuleLevel("lsm"));
    try std.testing.expectEqual(std.log.Level.info, levels.getModuleLevel("grid"));

    // vsr allows debug
    try std.testing.expect(levels.shouldLogByName("vsr", .debug));
    try std.testing.expect(levels.shouldLogByName("vsr", .info));

    // lsm only allows warn and err
    try std.testing.expect(levels.shouldLogByName("lsm", .warn));
    try std.testing.expect(levels.shouldLogByName("lsm", .err));
    try std.testing.expect(!levels.shouldLogByName("lsm", .info));
    try std.testing.expect(!levels.shouldLogByName("lsm", .debug));

    // grid uses default (info)
    try std.testing.expect(levels.shouldLogByName("grid", .info));
    try std.testing.expect(!levels.shouldLogByName("grid", .debug));
}

test "ModuleLogLevels: runtime modification" {
    var levels = ModuleLogLevels.init(std.testing.allocator);
    defer levels.deinit();

    try levels.parseOverrides("info");
    try std.testing.expect(!levels.shouldLogByName("vsr", .debug));

    try levels.setModuleLevel("vsr", .debug);
    try std.testing.expect(levels.shouldLogByName("vsr", .debug));

    // Update existing
    try levels.setModuleLevel("vsr", .warn);
    try std.testing.expect(!levels.shouldLogByName("vsr", .info));
    try std.testing.expect(levels.shouldLogByName("vsr", .warn));
}

test "ModuleLogLevels: invalid format" {
    var levels = ModuleLogLevels.init(std.testing.allocator);
    defer levels.deinit();

    // Invalid level
    try std.testing.expectError(error.InvalidLogLevel, levels.parseOverrides("invalid"));

    // Missing colon in subsequent entries
    try std.testing.expectError(error.InvalidLogLevelFormat, levels.parseOverrides("info,vsr"));
}

test "ModuleLogLevels: empty and whitespace" {
    var levels = ModuleLogLevels.init(std.testing.allocator);
    defer levels.deinit();

    try levels.parseOverrides("info, vsr:debug ,  lsm:warn  ");

    try std.testing.expectEqual(std.log.Level.info, levels.default);
    try std.testing.expectEqual(std.log.Level.debug, levels.getModuleLevel("vsr"));
    try std.testing.expectEqual(std.log.Level.warn, levels.getModuleLevel("lsm"));
}

test "ModuleLogLevels: shouldLog comptime scope" {
    var levels = ModuleLogLevels.init(std.testing.allocator);
    defer levels.deinit();

    try levels.parseOverrides("warn");

    // comptime scope test
    try std.testing.expect(levels.shouldLog(.default, .warn));
    try std.testing.expect(levels.shouldLog(.default, .err));
    try std.testing.expect(!levels.shouldLog(.default, .info));
}

test "global module log levels" {
    var levels = ModuleLogLevels.init(std.testing.allocator);
    defer levels.deinit();

    try levels.parseOverrides("info,vsr:debug");

    // Initially no global config
    try std.testing.expect(shouldLogGlobal(.vsr, .debug));

    // Set global config
    setGlobalModuleLogLevels(&levels);
    defer setGlobalModuleLogLevels(null);

    try std.testing.expect(shouldLogGlobal(.vsr, .debug));
    try std.testing.expect(!shouldLogGlobal(.grid, .debug));
}
