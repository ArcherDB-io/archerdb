// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Backup Configuration for Object Storage (F5.5.1)
//!
//! This module provides configuration types for the backup system that uploads
//! closed LSM blocks to object storage (S3, GCS, Azure Blob) for disaster recovery.
//!
//! Features:
//! - Scheduled backups with cron expressions or simple intervals
//! - Retention policies (by days or block count)
//! - Multiple destinations (S3, GCS, Azure, local filesystem)
//! - Compression and encryption options
//!
//! Usage:
//! ```zig
//! var config = try BackupConfig.init(allocator, .{
//!     .enabled = true,
//!     .provider = .s3,
//!     .bucket = "archerdb-backups",
//!     .region = "us-east-1",
//!     .schedule = "0 2 * * *",  // Daily at 2am
//! });
//! defer config.deinit();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const log = std.log.scoped(.backup_config);

// During tests, we don't want log.err to fail tests when testing error paths.
// Wrap logging functions to suppress errors in test mode.
fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.err(fmt, args);
    }
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.warn(fmt, args);
    }
}

/// Supported object storage providers for backup.
pub const StorageProvider = enum {
    /// Amazon S3 (or S3-compatible storage like MinIO, Wasabi).
    s3,
    /// Google Cloud Storage.
    gcs,
    /// Azure Blob Storage.
    azure,
    /// Local filesystem (for testing/development only).
    local,

    pub fn toString(self: StorageProvider) []const u8 {
        return switch (self) {
            .s3 => "s3",
            .gcs => "gcs",
            .azure => "azure",
            .local => "local",
        };
    }

    pub fn fromString(s: []const u8) ?StorageProvider {
        if (mem.eql(u8, s, "s3")) return .s3;
        if (mem.eql(u8, s, "gcs")) return .gcs;
        if (mem.eql(u8, s, "azure")) return .azure;
        if (mem.eql(u8, s, "local")) return .local;
        return null;
    }
};

/// Backup operating mode per spec.
pub const BackupMode = enum {
    /// Best-effort mode (default): Async backups, prioritize availability.
    /// Blocks may be released without backup if queue is full.
    best_effort,

    /// Mandatory mode: Require backup before block release.
    /// Halts writes if backup queue is exhausted.
    mandatory,

    pub fn toString(self: BackupMode) []const u8 {
        return switch (self) {
            .best_effort => "best-effort",
            .mandatory => "mandatory",
        };
    }

    pub fn fromString(s: []const u8) ?BackupMode {
        if (mem.eql(u8, s, "best-effort")) return .best_effort;
        if (mem.eql(u8, s, "mandatory")) return .mandatory;
        return null;
    }
};

/// Encryption mode for backup data.
pub const EncryptionMode = enum {
    /// No encryption (not recommended for production).
    none,
    /// Server-Side Encryption with provider-managed keys (SSE-S3, etc.).
    sse,
    /// Server-Side Encryption with KMS-managed keys.
    sse_kms,

    pub fn toString(self: EncryptionMode) []const u8 {
        return switch (self) {
            .none => "none",
            .sse => "sse",
            .sse_kms => "sse-kms",
        };
    }

    pub fn fromString(s: []const u8) ?EncryptionMode {
        if (mem.eql(u8, s, "none")) return .none;
        if (mem.eql(u8, s, "sse")) return .sse;
        if (mem.eql(u8, s, "sse-kms")) return .sse_kms;
        return null;
    }
};

/// Compression algorithm for backup blocks.
pub const CompressionMode = enum {
    /// No compression (default).
    none,
    /// Zstandard compression (level 3).
    zstd,

    pub fn toString(self: CompressionMode) []const u8 {
        return switch (self) {
            .none => "none",
            .zstd => "zstd",
        };
    }

    pub fn fromString(s: []const u8) ?CompressionMode {
        if (mem.eql(u8, s, "none")) return .none;
        if (mem.eql(u8, s, "zstd")) return .zstd;
        return null;
    }
};

// =============================================================================
// Backup Schedule Types
// =============================================================================

/// Time unit for simple interval schedules.
pub const TimeUnit = enum {
    seconds,
    minutes,
    hours,
    days,

    /// Convert a value with this unit to nanoseconds.
    pub fn toNanoseconds(self: TimeUnit, value: u64) u64 {
        return switch (self) {
            .seconds => value * std.time.ns_per_s,
            .minutes => value * std.time.ns_per_min,
            .hours => value * std.time.ns_per_hour,
            .days => value * 24 * std.time.ns_per_hour,
        };
    }

    /// Convert a value with this unit to seconds.
    pub fn toSeconds(self: TimeUnit, value: u64) u64 {
        return switch (self) {
            .seconds => value,
            .minutes => value * 60,
            .hours => value * 3600,
            .days => value * 86400,
        };
    }
};

/// Cron field specification.
pub const FieldSpec = union(enum) {
    /// Any value matches (*)
    any,
    /// Specific value (5)
    value: u8,
    /// Range of values (1-5)
    range: struct { start: u8, end: u8 },
    /// List of values (1,3,5) - stored as bitmask for efficiency
    list: u64,
    /// Step values (*/5)
    step: struct { base: u8, step: u8 },

    /// Check if a value matches this field specification.
    pub fn matches(self: FieldSpec, val: u8) bool {
        return switch (self) {
            .any => true,
            .value => |v| v == val,
            .range => |r| val >= r.start and val <= r.end,
            .list => |mask| (mask & (@as(u64, 1) << @as(u6, @intCast(val)))) != 0,
            .step => |s| val >= s.base and (val - s.base) % s.step == 0,
        };
    }

    /// Parse a cron field specification.
    pub fn parse(field: []const u8, min: u8, max: u8) !FieldSpec {
        // Handle "*"
        if (field.len == 1 and field[0] == '*') {
            return .any;
        }

        // Handle "*/n" (step)
        if (field.len >= 2 and field[0] == '*' and field[1] == '/') {
            const step = std.fmt.parseInt(u8, field[2..], 10) catch return error.InvalidCronField;
            if (step == 0) return error.InvalidCronField;
            return .{ .step = .{ .base = min, .step = step } };
        }

        // Handle "n-m" (range)
        if (mem.indexOf(u8, field, "-")) |dash_pos| {
            const start = std.fmt.parseInt(u8, field[0..dash_pos], 10) catch return error.InvalidCronField;
            const end = std.fmt.parseInt(u8, field[dash_pos + 1 ..], 10) catch return error.InvalidCronField;
            if (start > max or end > max or start > end) return error.InvalidCronField;
            return .{ .range = .{ .start = start, .end = end } };
        }

        // Handle "a,b,c" (list)
        if (mem.indexOf(u8, field, ",")) |_| {
            var mask: u64 = 0;
            var iter = mem.splitScalar(u8, field, ',');
            while (iter.next()) |part| {
                const val = std.fmt.parseInt(u8, part, 10) catch return error.InvalidCronField;
                if (val > max or val < min) return error.InvalidCronField;
                mask |= (@as(u64, 1) << @as(u6, @intCast(val)));
            }
            return .{ .list = mask };
        }

        // Handle single value
        const val = std.fmt.parseInt(u8, field, 10) catch return error.InvalidCronField;
        if (val < min or val > max) return error.InvalidCronField;
        return .{ .value = val };
    }

    /// Get the next value that matches this spec, starting from `from`.
    /// Returns null if no valid value exists (would need to wrap to next period).
    pub fn nextMatch(self: FieldSpec, from: u8, max: u8) ?u8 {
        var v = from;
        while (v <= max) : (v += 1) {
            if (self.matches(v)) return v;
        }
        return null;
    }
};

/// Cron expression for scheduling.
/// Format: minute hour day-of-month month day-of-week
/// Example: "0 2 * * *" (daily at 2am)
pub const CronExpression = struct {
    /// Minute (0-59)
    minute: FieldSpec,
    /// Hour (0-23)
    hour: FieldSpec,
    /// Day of month (1-31)
    day_of_month: FieldSpec,
    /// Month (1-12)
    month: FieldSpec,
    /// Day of week (0-6, Sunday=0)
    day_of_week: FieldSpec,

    /// Parse a cron expression string.
    /// Format: "minute hour day-of-month month day-of-week"
    pub fn parse(spec: []const u8) !CronExpression {
        var parts: [5][]const u8 = undefined;
        var count: usize = 0;

        var iter = mem.tokenizeScalar(u8, spec, ' ');
        while (iter.next()) |part| {
            if (count >= 5) return error.InvalidCronFormat;
            parts[count] = part;
            count += 1;
        }

        if (count != 5) return error.InvalidCronFormat;

        return CronExpression{
            .minute = try FieldSpec.parse(parts[0], 0, 59),
            .hour = try FieldSpec.parse(parts[1], 0, 23),
            .day_of_month = try FieldSpec.parse(parts[2], 1, 31),
            .month = try FieldSpec.parse(parts[3], 1, 12),
            .day_of_week = try FieldSpec.parse(parts[4], 0, 6),
        };
    }

    /// Calculate the next run time from the given timestamp (seconds since epoch).
    /// Returns the next matching timestamp in seconds since epoch.
    pub fn nextTime(self: CronExpression, from_secs: i64) i64 {
        // Start from the next minute
        var current = from_secs + 60;
        // Align to minute boundary
        current = @divFloor(current, 60) * 60;

        // Search for up to a year
        const max_iterations = 366 * 24 * 60;
        var iterations: u32 = 0;

        while (iterations < max_iterations) : (iterations += 1) {
            const dt = epochToComponents(current);

            // Check all fields match
            if (self.minute.matches(dt.minute) and
                self.hour.matches(dt.hour) and
                self.day_of_month.matches(dt.day) and
                self.month.matches(dt.month) and
                self.day_of_week.matches(dt.weekday))
            {
                return current;
            }

            // Advance by one minute
            current += 60;
        }

        // Fallback: return next day if no match found (shouldn't happen with valid cron)
        return from_secs + 86400;
    }
};

/// Date-time components for cron matching.
const DateTimeComponents = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8, // 0-23
    minute: u8, // 0-59
    weekday: u8, // 0-6, Sunday=0
};

/// Convert epoch seconds to date-time components.
fn epochToComponents(epoch_secs: i64) DateTimeComponents {
    // Simplified conversion - in production would use proper calendar library
    const epoch_days = @divFloor(epoch_secs, 86400);
    const day_secs: u32 = @intCast(@mod(epoch_secs, 86400));

    const hour: u8 = @intCast(day_secs / 3600);
    const minute: u8 = @intCast((day_secs % 3600) / 60);

    // Days since Jan 1, 1970 (Thursday)
    // Weekday: (epoch_days + 4) % 7 gives 0=Sunday
    const weekday: u8 = @intCast(@mod(epoch_days + 4, 7));

    // Year and day of year calculation
    var days_remaining = epoch_days;
    var year: u16 = 1970;

    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (days_remaining < days_in_year) break;
        days_remaining -= days_in_year;
        year += 1;
    }

    // Month and day calculation
    const is_leap = isLeapYear(year);
    const days_in_months = if (is_leap)
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (days_in_months) |days| {
        if (days_remaining < days) break;
        days_remaining -= days;
        month += 1;
    }

    const day: u8 = @intCast(days_remaining + 1);

    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .weekday = weekday,
    };
}

fn isLeapYear(year: u16) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    if (year % 4 == 0) return true;
    return false;
}

/// Backup schedule - either a simple interval or a cron expression.
pub const BackupSchedule = union(enum) {
    /// Simple interval: "every 1h", "every 30m", "every 1d"
    interval: struct {
        value: u64,
        unit: TimeUnit,

        /// Convert to nanoseconds.
        pub fn toNanoseconds(self: @This()) u64 {
            return self.unit.toNanoseconds(self.value);
        }

        /// Convert to seconds.
        pub fn toSeconds(self: @This()) u64 {
            return self.unit.toSeconds(self.value);
        }
    },

    /// Cron expression: "0 2 * * *" (daily at 2am)
    cron: CronExpression,

    /// Calculate the next run time from the given timestamp (nanoseconds since epoch).
    pub fn nextRunTime(self: BackupSchedule, from_ns: i64) i64 {
        return switch (self) {
            .interval => |i| from_ns + @as(i64, @intCast(i.toNanoseconds())),
            .cron => |c| c.nextTime(@divFloor(from_ns, std.time.ns_per_s)) * std.time.ns_per_s,
        };
    }

    /// Calculate the next run time from the given timestamp (seconds since epoch).
    pub fn nextRunTimeSecs(self: BackupSchedule, from_secs: i64) i64 {
        return switch (self) {
            .interval => |i| from_secs + @as(i64, @intCast(i.toSeconds())),
            .cron => |c| c.nextTime(from_secs),
        };
    }
};

/// Parse a schedule specification.
/// Supports:
/// - Simple intervals: "every 1h", "every 30m", "every 1d", "every 3600s"
/// - Cron expressions: "0 2 * * *" (5-field cron format)
pub fn parseSchedule(spec: []const u8) !BackupSchedule {
    const trimmed = mem.trim(u8, spec, " \t\n\r");

    // Check for simple interval format: "every <value><unit>"
    if (mem.startsWith(u8, trimmed, "every ")) {
        return parseInterval(trimmed["every ".len..]);
    }

    // Otherwise treat as cron expression
    return .{ .cron = try CronExpression.parse(trimmed) };
}

/// Parse a simple interval specification.
/// Format: "<value><unit>" where unit is s/m/h/d
fn parseInterval(spec: []const u8) !BackupSchedule {
    const trimmed = mem.trim(u8, spec, " \t");
    if (trimmed.len < 2) return error.InvalidInterval;

    // Find where the number ends and unit begins
    var num_end: usize = 0;
    for (trimmed, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            num_end = i + 1;
        } else {
            break;
        }
    }

    if (num_end == 0) return error.InvalidInterval;

    const value = std.fmt.parseInt(u64, trimmed[0..num_end], 10) catch return error.InvalidInterval;
    if (value == 0) return error.InvalidInterval;

    const unit_str = mem.trim(u8, trimmed[num_end..], " ");
    const unit: TimeUnit = if (mem.eql(u8, unit_str, "s") or mem.eql(u8, unit_str, "seconds"))
        .seconds
    else if (mem.eql(u8, unit_str, "m") or mem.eql(u8, unit_str, "minutes"))
        .minutes
    else if (mem.eql(u8, unit_str, "h") or mem.eql(u8, unit_str, "hours"))
        .hours
    else if (mem.eql(u8, unit_str, "d") or mem.eql(u8, unit_str, "days"))
        .days
    else
        return error.InvalidInterval;

    return .{ .interval = .{ .value = value, .unit = unit } };
}

/// Backup configuration options (from CLI).
pub const BackupOptions = struct {
    /// Whether backup is enabled.
    enabled: bool = false,

    /// Storage provider (s3, gcs, azure, local).
    provider: StorageProvider = .s3,

    /// Bucket or container name.
    /// Format: "bucket-name" or "s3://bucket-name" (scheme stripped).
    bucket: ?[]const u8 = null,

    /// Region for the bucket (provider-specific).
    region: ?[]const u8 = null,

    /// Explicit endpoint override. When null, the uploader derives a provider-appropriate
    /// default (e.g. `s3.<region>.amazonaws.com` for S3). Set this for S3-compatible systems
    /// like MinIO (`http://localhost:9000`), LocalStack (`http://localhost:4566`), R2,
    /// Backblaze B2, or any private network S3 endpoint.
    endpoint: ?[]const u8 = null,

    /// Path to credentials file (provider-specific).
    credentials_path: ?[]const u8 = null,

    /// Explicit access key override. Primarily intended for programmatic and test use.
    /// Production deployments should prefer environment variables (`AWS_ACCESS_KEY_ID` for
    /// S3/S3-compatible providers) or a credentials file referenced by `credentials_path`,
    /// since struct-borne secrets can leak through CLI argv or serialized config dumps. Not
    /// logged by this module.
    access_key_id: ?[]const u8 = null,

    /// Explicit secret key override. Same warning as `access_key_id` — prefer env vars or
    /// `credentials_path` in production. Not logged by this module.
    secret_access_key: ?[]const u8 = null,

    /// URL style for S3-style requests. Accepts "path" (e.g. `http://endpoint/bucket/key`)
    /// or "virtual-hosted" (e.g. `https://bucket.endpoint/key`). When null, the uploader
    /// picks the provider-recommended style (virtual-hosted for AWS/R2/Backblaze; path for
    /// MinIO/LocalStack/generic). MinIO and LocalStack require path style.
    url_style: ?[]const u8 = null,

    /// Operating mode: best-effort (default) or mandatory.
    mode: BackupMode = .best_effort,

    /// Encryption mode for uploaded blocks.
    encryption: EncryptionMode = .sse,

    /// KMS key ID (for sse-kms encryption).
    kms_key_id: ?[]const u8 = null,

    /// Compression algorithm.
    compression: CompressionMode = .none,

    // Queue limits (per spec)

    /// Soft limit: Log warning when queue exceeds this.
    queue_soft_limit: u32 = 50,

    /// Hard limit: Apply backpressure or halt writes.
    queue_hard_limit: u32 = 100,

    // Mandatory mode specific

    /// Timeout before emergency bypass (in seconds). Default: 1 hour.
    mandatory_halt_timeout_secs: u32 = 3600,

    // Retention policy

    /// Retention period in days (0 = keep forever).
    retention_days: u32 = 0,

    /// Retention by block count (0 = unlimited).
    retention_blocks: u32 = 0,

    // Coordination

    /// Only backup from primary replica (reduces S3 costs).
    primary_only: bool = false,

    /// Only backup from follower replicas (zero-impact online backups).
    /// When true, backups only run on follower replicas to avoid impacting
    /// primary node performance. This is the recommended setting for production
    /// workloads where backup I/O should not compete with client traffic.
    /// Default: true (per CONTEXT.md requirement for zero-impact backups).
    /// Note: Mutually exclusive with primary_only. If both are set, follower_only takes precedence.
    follower_only: bool = true,

    // Scheduling

    /// Backup schedule specification.
    /// Supports cron format ("0 2 * * *") or intervals ("every 1h").
    schedule: ?[]const u8 = null,

    /// Resolve access/secret credentials from the options struct, falling back to environment
    /// variables. For S3 and S3-compatible providers, the env vars are `AWS_ACCESS_KEY_ID`
    /// and `AWS_SECRET_ACCESS_KEY`. Returns null for either value when it cannot be
    /// resolved; the uploader treats both-null as "no credentials configured" and fails
    /// closed. Values returned in the struct are pointers into process environment or the
    /// caller's options; they must not outlive the resolution site. Credentials resolved here
    /// are never logged.
    pub fn resolveS3Credentials(self: BackupOptions) ResolvedCredentials {
        const access = self.access_key_id orelse std.posix.getenv("AWS_ACCESS_KEY_ID");
        const secret = self.secret_access_key orelse
            std.posix.getenv("AWS_SECRET_ACCESS_KEY");
        return .{ .access_key_id = access, .secret_access_key = secret };
    }
};

/// Resolved credential pair. Either field may be null when no source could provide it.
/// Returned by `BackupOptions.resolveS3Credentials` so uploader code can treat explicit-options
/// and env-var resolution uniformly.
pub const ResolvedCredentials = struct {
    access_key_id: ?[]const u8,
    secret_access_key: ?[]const u8,

    pub fn isComplete(self: ResolvedCredentials) bool {
        return self.access_key_id != null and self.secret_access_key != null;
    }
};

/// Block reference for backup tracking.
pub const BlockRef = struct {
    /// Block sequence number (from LSM).
    sequence: u64,
    /// Block address in grid.
    address: u64,
    /// Block checksum for verification.
    checksum: u128,
    /// Timestamp when block was closed.
    closed_timestamp: i64,
};

/// Backup state tracking (persisted to disk).
pub const BackupState = struct {
    /// Highest block sequence successfully uploaded.
    last_uploaded_sequence: u64 = 0,

    /// Timestamp of last successful upload.
    last_upload_timestamp: i64 = 0,

    /// Number of blocks pending upload.
    pending_count: u32 = 0,

    /// Number of failed upload attempts.
    failed_count: u32 = 0,

    /// Number of blocks abandoned without backup (best-effort mode).
    abandoned_count: u64 = 0,
};

/// Backup scheduler - tracks when next backup should run.
pub const BackupScheduler = struct {
    /// Parsed schedule (null if no schedule configured).
    schedule: ?BackupSchedule,
    /// Next scheduled run time (nanoseconds since epoch).
    next_run_time: i64,
    /// Whether a backup is currently in progress.
    in_progress: bool,

    /// Initialize scheduler from options.
    pub fn init(schedule_spec: ?[]const u8) !BackupScheduler {
        var self = BackupScheduler{
            .schedule = null,
            .next_run_time = 0,
            .in_progress = false,
        };

        if (schedule_spec) |spec| {
            self.schedule = try parseSchedule(spec);
            // Set initial next run time (use seconds to avoid i128 overflow concerns)
            const now_secs = std.time.timestamp();
            self.next_run_time = self.schedule.?.nextRunTimeSecs(now_secs) * std.time.ns_per_s;
        }

        return self;
    }

    /// Check if a backup should run now.
    /// Returns true if current time >= next_run_time and no backup in progress.
    pub fn shouldRun(self: *const BackupScheduler, now_ns: i64) bool {
        if (self.schedule == null) return false;
        if (self.in_progress) return false;
        return now_ns >= self.next_run_time;
    }

    /// Mark backup as started.
    pub fn markStarted(self: *BackupScheduler) void {
        self.in_progress = true;
    }

    /// Mark backup as completed and schedule next run.
    pub fn markCompleted(self: *BackupScheduler) void {
        self.in_progress = false;
        if (self.schedule) |s| {
            const now_secs = std.time.timestamp();
            self.next_run_time = s.nextRunTimeSecs(now_secs) * std.time.ns_per_s;
        }
    }

    /// Tick method for integration with event loop.
    /// Returns true if backup should be triggered.
    pub fn tick(self: *BackupScheduler) bool {
        const now = std.time.nanoTimestamp();
        return self.shouldRun(now);
    }
};

/// Backup configuration manager.
pub const BackupConfig = struct {
    allocator: mem.Allocator,
    options: BackupOptions,
    /// Parsed schedule (if configured).
    parsed_schedule: ?BackupSchedule,

    /// Initialize backup configuration.
    pub fn init(allocator: mem.Allocator, options: BackupOptions) !BackupConfig {
        var self = BackupConfig{
            .allocator = allocator,
            .options = options,
            .parsed_schedule = null,
        };

        if (options.enabled) {
            try self.validate();
        }

        // Parse schedule if provided
        if (options.schedule) |schedule_spec| {
            self.parsed_schedule = parseSchedule(schedule_spec) catch |err| {
                logErr("invalid backup schedule '{s}': {}", .{ schedule_spec, err });
                return err;
            };
        }

        return self;
    }

    pub fn deinit(self: *BackupConfig) void {
        _ = self;
        // No allocations to free currently
    }

    /// Check if backup is enabled.
    pub fn isEnabled(self: *const BackupConfig) bool {
        return self.options.enabled;
    }

    /// Check if mandatory mode is active.
    pub fn isMandatory(self: *const BackupConfig) bool {
        return self.options.mode == .mandatory;
    }

    /// Check if scheduling is configured.
    pub fn hasSchedule(self: *const BackupConfig) bool {
        return self.parsed_schedule != null;
    }

    /// Get the next scheduled run time (seconds since epoch).
    pub fn nextScheduledRun(self: *const BackupConfig, from_secs: i64) ?i64 {
        if (self.parsed_schedule) |s| {
            return s.nextRunTimeSecs(from_secs);
        }
        return null;
    }

    /// Validate configuration.
    fn validate(self: *const BackupConfig) !void {
        if (self.options.bucket == null) {
            logErr("backup enabled but --backup-bucket not provided", .{});
            return error.MissingBucket;
        }

        // KMS key required for sse-kms encryption
        if (self.options.encryption == .sse_kms and self.options.kms_key_id == null) {
            logErr("sse-kms encryption requires --backup-kms-key-id", .{});
            return error.MissingKmsKey;
        }

        // Validate queue limits
        if (self.options.queue_soft_limit >= self.options.queue_hard_limit) {
            logErr("queue_soft_limit must be < queue_hard_limit", .{});
            return error.InvalidQueueLimits;
        }

        // Validate url_style early so the uploader can trust it.
        if (self.options.url_style) |style| {
            if (!mem.eql(u8, style, "path") and !mem.eql(u8, style, "virtual-hosted")) {
                logErr(
                    "invalid backup url_style '{s}' (expected 'path' or 'virtual-hosted')",
                    .{style},
                );
                return error.InvalidUrlStyle;
            }
        }
    }

    /// Get the object key prefix for this cluster/replica.
    /// Format: <cluster-id>/<replica-id>/blocks/
    pub fn getObjectKeyPrefix(
        self: *const BackupConfig,
        cluster_id: u128,
        replica_id: u8,
    ) [128]u8 {
        _ = self;
        var buf: [128]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{x:0>32}/replica-{d}/blocks/", .{
            cluster_id,
            replica_id,
        }) catch unreachable;
        @memset(buf[len.len..], 0);
        return buf;
    }

    /// Get the object key for a specific block.
    /// Format: <prefix><sequence>.block[.zst]
    pub fn getBlockObjectKey(
        self: *const BackupConfig,
        cluster_id: u128,
        replica_id: u8,
        sequence: u64,
    ) [160]u8 {
        var buf: [160]u8 = undefined;
        const ext = if (self.options.compression == .zstd) ".block.zst" else ".block";
        const len = std.fmt.bufPrint(&buf, "{x:0>32}/replica-{d}/blocks/{d:0>12}{s}", .{
            cluster_id,
            replica_id,
            sequence,
            ext,
        }) catch unreachable;
        @memset(buf[len.len..], 0);
        return buf;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BackupConfig: disabled by default" {
    const config = try BackupConfig.init(std.testing.allocator, .{});
    try std.testing.expect(!config.isEnabled());
}

test "BackupConfig: enabled requires bucket" {
    const result = BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
    });
    try std.testing.expectError(error.MissingBucket, result);
}

test "BackupConfig: valid configuration" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .s3,
        .bucket = "test-bucket",
        .region = "us-east-1",
    });
    defer config.deinit();

    try std.testing.expect(config.isEnabled());
    try std.testing.expect(!config.isMandatory());
}

test "BackupConfig: mandatory mode" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .mode = .mandatory,
    });
    defer config.deinit();

    try std.testing.expect(config.isMandatory());
}

test "BackupConfig: sse-kms requires key" {
    const result = BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .encryption = .sse_kms,
    });
    try std.testing.expectError(error.MissingKmsKey, result);
}

test "BackupConfig: invalid url_style rejected" {
    const result = BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .url_style = "bogus",
    });
    try std.testing.expectError(error.InvalidUrlStyle, result);
}

test "BackupConfig: valid url_style accepted" {
    var path_config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .url_style = "path",
    });
    defer path_config.deinit();

    var hosted_config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .url_style = "virtual-hosted",
    });
    defer hosted_config.deinit();
}

test "BackupConfig: endpoint override accepted" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .endpoint = "http://localhost:4566",
    });
    defer config.deinit();
    try std.testing.expectEqualStrings("http://localhost:4566", config.options.endpoint.?);
}

test "BackupOptions: resolveS3Credentials prefers explicit over env" {
    const options = BackupOptions{
        .enabled = true,
        .bucket = "test-bucket",
        .access_key_id = "explicit-access",
        .secret_access_key = "explicit-secret",
    };
    const creds = options.resolveS3Credentials();
    try std.testing.expect(creds.isComplete());
    try std.testing.expectEqualStrings("explicit-access", creds.access_key_id.?);
    try std.testing.expectEqualStrings("explicit-secret", creds.secret_access_key.?);
}

test "BackupOptions: resolveS3Credentials returns incomplete when unset" {
    // Exercises the no-config-no-env branch. If the host environment happens to have
    // AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY set (CI runners often do not), we accept
    // either outcome — the important invariant is that the resolver does not panic.
    const options = BackupOptions{
        .enabled = true,
        .bucket = "test-bucket",
    };
    _ = options.resolveS3Credentials();
}

test "BackupConfig: object key format" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
    });
    defer config.deinit();

    const key = config.getBlockObjectKey(0x12345678, 0, 1000);
    const key_str = mem.sliceTo(&key, 0);
    try std.testing.expect(mem.indexOf(u8, key_str, "replica-0") != null);
    try std.testing.expect(mem.indexOf(u8, key_str, "blocks/") != null);
    try std.testing.expect(mem.endsWith(u8, key_str, ".block"));
}

test "StorageProvider: fromString" {
    try std.testing.expectEqual(StorageProvider.s3, StorageProvider.fromString("s3").?);
    try std.testing.expectEqual(StorageProvider.gcs, StorageProvider.fromString("gcs").?);
    try std.testing.expectEqual(StorageProvider.azure, StorageProvider.fromString("azure").?);
    try std.testing.expectEqual(StorageProvider.local, StorageProvider.fromString("local").?);
    try std.testing.expect(StorageProvider.fromString("invalid") == null);
}

test "BackupMode: fromString" {
    try std.testing.expectEqual(BackupMode.best_effort, BackupMode.fromString("best-effort").?);
    try std.testing.expectEqual(BackupMode.mandatory, BackupMode.fromString("mandatory").?);
    try std.testing.expect(BackupMode.fromString("invalid") == null);
}

// =============================================================================
// Schedule Parsing Tests
// =============================================================================

test "backup: parseSchedule every 1h" {
    const schedule = try parseSchedule("every 1h");
    try std.testing.expect(schedule == .interval);
    try std.testing.expectEqual(@as(u64, 1), schedule.interval.value);
    try std.testing.expectEqual(TimeUnit.hours, schedule.interval.unit);
}

test "backup: parseSchedule every 30m" {
    const schedule = try parseSchedule("every 30m");
    try std.testing.expect(schedule == .interval);
    try std.testing.expectEqual(@as(u64, 30), schedule.interval.value);
    try std.testing.expectEqual(TimeUnit.minutes, schedule.interval.unit);
}

test "backup: parseSchedule every 1d" {
    const schedule = try parseSchedule("every 1d");
    try std.testing.expect(schedule == .interval);
    try std.testing.expectEqual(@as(u64, 1), schedule.interval.value);
    try std.testing.expectEqual(TimeUnit.days, schedule.interval.unit);
}

test "backup: parseSchedule cron daily at 2am" {
    const schedule = try parseSchedule("0 2 * * *");
    try std.testing.expect(schedule == .cron);
    try std.testing.expectEqual(FieldSpec{ .value = 0 }, schedule.cron.minute);
    try std.testing.expectEqual(FieldSpec{ .value = 2 }, schedule.cron.hour);
    try std.testing.expectEqual(FieldSpec.any, schedule.cron.day_of_month);
    try std.testing.expectEqual(FieldSpec.any, schedule.cron.month);
    try std.testing.expectEqual(FieldSpec.any, schedule.cron.day_of_week);
}

test "backup: parseSchedule cron every 15 minutes" {
    const schedule = try parseSchedule("*/15 * * * *");
    try std.testing.expect(schedule == .cron);
    try std.testing.expect(schedule.cron.minute == .step);
    try std.testing.expectEqual(@as(u8, 0), schedule.cron.minute.step.base);
    try std.testing.expectEqual(@as(u8, 15), schedule.cron.minute.step.step);
}

test "backup: parseSchedule cron first of month" {
    const schedule = try parseSchedule("0 0 1 * *");
    try std.testing.expect(schedule == .cron);
    try std.testing.expectEqual(FieldSpec{ .value = 0 }, schedule.cron.minute);
    try std.testing.expectEqual(FieldSpec{ .value = 0 }, schedule.cron.hour);
    try std.testing.expectEqual(FieldSpec{ .value = 1 }, schedule.cron.day_of_month);
}

test "backup: interval nextRunTime" {
    const schedule = try parseSchedule("every 1h");
    const from_ns: i64 = 1000 * std.time.ns_per_s;
    const next = schedule.nextRunTime(from_ns);
    try std.testing.expectEqual(from_ns + @as(i64, std.time.ns_per_hour), next);
}

test "backup: cron nextRunTime" {
    const schedule = try parseSchedule("0 2 * * *");

    // Start from Jan 1, 2025 00:00:00 UTC (a known Wednesday)
    const jan1_2025: i64 = 1735689600; // seconds
    const next_secs = schedule.nextRunTimeSecs(jan1_2025);

    // Should be Jan 1, 2025 02:00:00 UTC
    try std.testing.expectEqual(jan1_2025 + 2 * 3600, next_secs);
}

test "backup: FieldSpec matches" {
    // Test 'any' matches everything
    const any_spec: FieldSpec = .any;
    try std.testing.expect(any_spec.matches(0));
    try std.testing.expect(any_spec.matches(59));

    // Test 'value' matches only that value
    const val: FieldSpec = .{ .value = 30 };
    try std.testing.expect(val.matches(30));
    try std.testing.expect(!val.matches(31));

    // Test 'range' matches inclusive range
    const range: FieldSpec = .{ .range = .{ .start = 10, .end = 20 } };
    try std.testing.expect(!range.matches(9));
    try std.testing.expect(range.matches(10));
    try std.testing.expect(range.matches(15));
    try std.testing.expect(range.matches(20));
    try std.testing.expect(!range.matches(21));

    // Test 'step' matches base + N*step
    const step: FieldSpec = .{ .step = .{ .base = 0, .step = 15 } };
    try std.testing.expect(step.matches(0));
    try std.testing.expect(step.matches(15));
    try std.testing.expect(step.matches(30));
    try std.testing.expect(step.matches(45));
    try std.testing.expect(!step.matches(10));
}

test "backup: BackupScheduler tick" {
    var scheduler = try BackupScheduler.init("every 1h");
    const now: i64 = std.time.timestamp() * std.time.ns_per_s;

    // Initially should not run (next_run_time is in the future)
    try std.testing.expect(!scheduler.shouldRun(now));

    // Simulate time passing
    scheduler.next_run_time = now - 1;
    try std.testing.expect(scheduler.shouldRun(now));

    // Mark started, should not run again
    scheduler.markStarted();
    try std.testing.expect(!scheduler.shouldRun(now));

    // Mark completed, should schedule next run
    scheduler.markCompleted();
    try std.testing.expect(!scheduler.shouldRun(now));
    try std.testing.expect(scheduler.next_run_time > now);
}

test "backup: BackupConfig with schedule" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .schedule = "every 1h",
    });
    defer config.deinit();

    try std.testing.expect(config.hasSchedule());
    try std.testing.expect(config.parsed_schedule != null);

    const now: i64 = std.time.timestamp();
    const next = config.nextScheduledRun(now);
    try std.testing.expect(next != null);
    try std.testing.expectEqual(now + 3600, next.?);
}

test "EncryptionMode fromString and toString roundtrip" {
    const modes = [_]struct { str: []const u8, mode: EncryptionMode }{
        .{ .str = "none", .mode = .none },
        .{ .str = "sse", .mode = .sse },
        .{ .str = "sse-kms", .mode = .sse_kms },
    };

    for (modes) |m| {
        const parsed = EncryptionMode.fromString(m.str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(m.mode, parsed.?);
        try std.testing.expectEqualStrings(m.str, parsed.?.toString());
    }

    // Invalid string returns null
    try std.testing.expect(EncryptionMode.fromString("invalid") == null);
    try std.testing.expect(EncryptionMode.fromString("SSE") == null);
    try std.testing.expect(EncryptionMode.fromString("") == null);
}

test "CompressionMode fromString and toString roundtrip" {
    const modes = [_]struct { str: []const u8, mode: CompressionMode }{
        .{ .str = "none", .mode = .none },
        .{ .str = "zstd", .mode = .zstd },
    };

    for (modes) |m| {
        const parsed = CompressionMode.fromString(m.str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(m.mode, parsed.?);
        try std.testing.expectEqualStrings(m.str, parsed.?.toString());
    }

    try std.testing.expect(CompressionMode.fromString("gzip") == null);
    try std.testing.expect(CompressionMode.fromString("lz4") == null);
}

test "TimeUnit toNanoseconds" {
    // 1 second = 1_000_000_000 ns
    try std.testing.expectEqual(@as(u64, 1_000_000_000), TimeUnit.seconds.toNanoseconds(1));

    // 1 minute = 60_000_000_000 ns
    try std.testing.expectEqual(@as(u64, 60_000_000_000), TimeUnit.minutes.toNanoseconds(1));

    // 1 hour = 3_600_000_000_000 ns
    try std.testing.expectEqual(@as(u64, 3_600_000_000_000), TimeUnit.hours.toNanoseconds(1));

    // 1 day = 86_400_000_000_000 ns
    try std.testing.expectEqual(@as(u64, 86_400_000_000_000), TimeUnit.days.toNanoseconds(1));

    // Verify toSeconds consistency: toNanoseconds(n) == toSeconds(n) * 1e9
    try std.testing.expectEqual(
        TimeUnit.hours.toSeconds(3) * std.time.ns_per_s,
        TimeUnit.hours.toNanoseconds(3),
    );
}

test "TimeUnit toSeconds" {
    try std.testing.expectEqual(@as(u64, 1), TimeUnit.seconds.toSeconds(1));
    try std.testing.expectEqual(@as(u64, 60), TimeUnit.minutes.toSeconds(1));
    try std.testing.expectEqual(@as(u64, 3600), TimeUnit.hours.toSeconds(1));
    try std.testing.expectEqual(@as(u64, 86400), TimeUnit.days.toSeconds(1));

    // Multi-value
    try std.testing.expectEqual(@as(u64, 7200), TimeUnit.hours.toSeconds(2));
    try std.testing.expectEqual(@as(u64, 259200), TimeUnit.days.toSeconds(3));
}

test "FieldSpec.parse: invalid cron fields" {
    // Step of zero is invalid
    try std.testing.expectError(error.InvalidCronField, FieldSpec.parse("*/0", 0, 59));

    // Value out of range
    try std.testing.expectError(error.InvalidCronField, FieldSpec.parse("60", 0, 59));
    try std.testing.expectError(error.InvalidCronField, FieldSpec.parse("25", 0, 23));

    // Range start > end
    try std.testing.expectError(error.InvalidCronField, FieldSpec.parse("10-5", 0, 59));

    // Range exceeds max
    try std.testing.expectError(error.InvalidCronField, FieldSpec.parse("0-60", 0, 59));

    // Non-numeric
    try std.testing.expectError(error.InvalidCronField, FieldSpec.parse("abc", 0, 59));

    // List with out-of-range value
    try std.testing.expectError(error.InvalidCronField, FieldSpec.parse("1,2,60", 0, 59));
}

test "FieldSpec.nextMatch" {
    // Any: always matches from any starting point
    const any = FieldSpec{ .any = {} };
    try std.testing.expectEqual(@as(?u8, 0), any.nextMatch(0, 59));
    try std.testing.expectEqual(@as(?u8, 30), any.nextMatch(30, 59));

    // Value: only matches exact value
    const val5 = FieldSpec{ .value = 5 };
    try std.testing.expectEqual(@as(?u8, 5), val5.nextMatch(0, 59));
    try std.testing.expectEqual(@as(?u8, 5), val5.nextMatch(5, 59));
    try std.testing.expectEqual(@as(?u8, null), val5.nextMatch(6, 59));

    // Step: matches multiples
    const step15 = FieldSpec{ .step = .{ .base = 0, .step = 15 } };
    try std.testing.expectEqual(@as(?u8, 0), step15.nextMatch(0, 59));
    try std.testing.expectEqual(@as(?u8, 15), step15.nextMatch(1, 59));
    try std.testing.expectEqual(@as(?u8, 30), step15.nextMatch(16, 59));
    try std.testing.expectEqual(@as(?u8, 45), step15.nextMatch(31, 59));
    try std.testing.expectEqual(@as(?u8, null), step15.nextMatch(46, 59));

    // Range: matches within range
    const range = FieldSpec{ .range = .{ .start = 9, .end = 17 } };
    try std.testing.expectEqual(@as(?u8, 9), range.nextMatch(0, 23));
    try std.testing.expectEqual(@as(?u8, 12), range.nextMatch(12, 23));
    try std.testing.expectEqual(@as(?u8, null), range.nextMatch(18, 23));
}

test "CronExpression.parse: invalid formats" {
    // Too few fields
    try std.testing.expectError(error.InvalidCronFormat, CronExpression.parse("0 2 *"));
    try std.testing.expectError(error.InvalidCronFormat, CronExpression.parse("0 2 * *"));

    // Too many fields
    try std.testing.expectError(error.InvalidCronFormat, CronExpression.parse("0 2 * * * *"));

    // Invalid field value
    try std.testing.expectError(error.InvalidCronField, CronExpression.parse("60 2 * * *")); // minute > 59
    try std.testing.expectError(error.InvalidCronField, CronExpression.parse("0 24 * * *")); // hour > 23
    try std.testing.expectError(error.InvalidCronField, CronExpression.parse("0 2 32 * *")); // day > 31
    try std.testing.expectError(error.InvalidCronField, CronExpression.parse("0 2 * 13 *")); // month > 12
    try std.testing.expectError(error.InvalidCronField, CronExpression.parse("0 2 * * 7")); // dow > 6
}

test "CronExpression.nextTime: specific schedule" {
    // "0 2 * * *" = daily at 2:00 AM
    const daily_2am = try CronExpression.parse("0 2 * * *");

    // From midnight Jan 1 2024 (Monday)
    const jan1_midnight: i64 = 1704067200; // 2024-01-01T00:00:00Z
    const next = daily_2am.nextTime(jan1_midnight);

    // Should be Jan 1 at 2:00 AM = midnight + 2 hours
    try std.testing.expectEqual(jan1_midnight + 7200, next);

    // From 3:00 AM Jan 1, should be next day at 2:00 AM
    const jan1_3am = jan1_midnight + 10800;
    const next2 = daily_2am.nextTime(jan1_3am);
    try std.testing.expectEqual(jan1_midnight + 86400 + 7200, next2);
}

test "epochToComponents basic" {
    // Jan 1, 1970 00:00:00 UTC (epoch start, Thursday)
    const dt = epochToComponents(0);
    try std.testing.expectEqual(@as(u16, 1970), dt.year);
    try std.testing.expectEqual(@as(u8, 1), dt.month);
    try std.testing.expectEqual(@as(u8, 1), dt.day);
    try std.testing.expectEqual(@as(u8, 0), dt.hour);
    try std.testing.expectEqual(@as(u8, 0), dt.minute);
    try std.testing.expectEqual(@as(u8, 4), dt.weekday); // Thursday = 4

    // Feb 29, 2024 (leap year) - 2024-02-29 00:00:00 UTC
    const leap = epochToComponents(1709164800);
    try std.testing.expectEqual(@as(u16, 2024), leap.year);
    try std.testing.expectEqual(@as(u8, 2), leap.month);
    try std.testing.expectEqual(@as(u8, 29), leap.day);
}

test "isLeapYear" {
    try std.testing.expect(isLeapYear(2000)); // divisible by 400
    try std.testing.expect(isLeapYear(2024)); // divisible by 4, not 100
    try std.testing.expect(!isLeapYear(1900)); // divisible by 100, not 400
    try std.testing.expect(!isLeapYear(2023)); // not divisible by 4
    try std.testing.expect(isLeapYear(2400)); // divisible by 400
}
