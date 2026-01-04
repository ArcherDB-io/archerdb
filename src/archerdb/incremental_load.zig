// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Incremental Data Loading Module (F-Data-Portability)
//!
//! Provides delta sync capabilities for incremental loading of location data:
//! - Last-modified timestamp filtering
//! - Change detection mechanisms
//! - Conflict resolution strategies
//! - Partial update capabilities
//! - Rollback on loading failures
//!
//! Target: >50K events/sec for near-real-time synchronization.
//!
//! See: openspec/changes/add-geospatial-core/specs/data-portability/spec.md
//!
//! Usage:
//! ```zig
//! var loader = IncrementalLoader.init(allocator, .{
//!     .last_sync_timestamp = checkpoint_timestamp,
//!     .conflict_resolution = .source_wins,
//! });
//! defer loader.deinit();
//!
//! const result = try loader.loadDelta(new_events, existing_events);
//! if (result.has_conflicts) {
//!     // Handle conflicts
//! }
//! ```

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const GeoEvent = @import("../geo_event.zig").GeoEvent;
const data_validation = @import("data_validation.zig");

/// Minimum throughput target: 50K events/sec.
pub const MIN_THROUGHPUT_EVENTS_PER_SEC: usize = 50_000;

/// Change operation types.
pub const ChangeOperation = enum {
    /// New event to insert.
    insert,
    /// Update to existing event.
    update,
    /// Delete existing event.
    delete,
    /// No change (event unchanged).
    unchanged,
};

/// Conflict resolution strategy.
pub const ConflictResolution = enum {
    /// Source (incoming) data always wins.
    source_wins,
    /// Target (existing) data always wins.
    target_wins,
    /// Most recent timestamp wins.
    latest_wins,
    /// Merge fields with source priority.
    merge_source_priority,
    /// Merge fields with target priority.
    merge_target_priority,
    /// Reject conflicting updates (requires manual resolution).
    reject,
};

/// A single change record representing a delta.
pub const ChangeRecord = struct {
    /// The operation type.
    operation: ChangeOperation,
    /// The event data (for insert/update).
    event: ?GeoEvent,
    /// Entity ID being modified.
    entity_id: u128,
    /// Timestamp of the change.
    timestamp_ns: u64,
    /// Whether this change had a conflict.
    had_conflict: bool = false,
    /// Previous value (for update/delete, if captured).
    previous_event: ?GeoEvent = null,
};

/// Result of detecting changes between two datasets.
pub const ChangeSet = struct {
    /// New events to insert.
    inserts: []ChangeRecord,
    /// Events to update.
    updates: []ChangeRecord,
    /// Events to delete.
    deletes: []ChangeRecord,
    /// Conflicts detected.
    conflicts: []ConflictRecord,
    /// Total changes detected.
    total_changes: usize,
    /// Processing time in nanoseconds.
    processing_time_ns: u64,

    pub fn deinit(self: *ChangeSet, allocator: Allocator) void {
        allocator.free(self.inserts);
        allocator.free(self.updates);
        allocator.free(self.deletes);
        allocator.free(self.conflicts);
    }
};

/// A conflict between source and target data.
pub const ConflictRecord = struct {
    /// Entity ID of the conflicting event.
    entity_id: u128,
    /// Source (incoming) event.
    source_event: GeoEvent,
    /// Target (existing) event.
    target_event: GeoEvent,
    /// How the conflict was resolved.
    resolution: ConflictResolution,
    /// The resolved event (after applying resolution).
    resolved_event: ?GeoEvent,
    /// Reason for the conflict.
    reason: ConflictReason,
};

/// Reason for a conflict.
pub const ConflictReason = enum {
    /// Both modified the same entity.
    concurrent_modification,
    /// Source has older timestamp than target.
    stale_update,
    /// Source deleted an event that target modified.
    delete_modify_conflict,
    /// Schema or data type mismatch.
    schema_mismatch,
    /// Business rule violation.
    business_rule_violation,
};

/// Load checkpoint for resumable operations.
pub const LoadCheckpoint = struct {
    /// Last successfully synced timestamp.
    last_sync_timestamp_ns: u64,
    /// Number of events processed in last batch.
    events_processed: usize,
    /// Number of events remaining (if known).
    events_remaining: ?usize,
    /// Offset for pagination.
    offset: usize,
    /// Checkpoint creation time.
    checkpoint_time_ns: u64,
    /// Any error message from previous run.
    error_message: ?[256]u8 = null,
    /// Whether last run completed successfully.
    completed_successfully: bool,

    /// Create a new checkpoint.
    pub fn create(timestamp_ns: u64) LoadCheckpoint {
        return .{
            .last_sync_timestamp_ns = timestamp_ns,
            .events_processed = 0,
            .events_remaining = null,
            .offset = 0,
            .checkpoint_time_ns = @intCast(std.time.nanoTimestamp()),
            .completed_successfully = true,
        };
    }

    /// Update checkpoint after processing.
    pub fn update(self: *LoadCheckpoint, events_processed: usize, new_timestamp: u64) void {
        self.events_processed += events_processed;
        if (new_timestamp > self.last_sync_timestamp_ns) {
            self.last_sync_timestamp_ns = new_timestamp;
        }
        self.checkpoint_time_ns = @intCast(std.time.nanoTimestamp());
    }
};

/// Incremental loading options.
pub const IncrementalLoadOptions = struct {
    /// Last sync timestamp for filtering.
    last_sync_timestamp_ns: u64 = 0,
    /// Conflict resolution strategy.
    conflict_resolution: ConflictResolution = .latest_wins,
    /// Whether to validate data during load.
    validate_data: bool = true,
    /// Maximum batch size for processing.
    batch_size: usize = 10_000,
    /// Whether to capture previous values for updates.
    capture_previous_values: bool = false,
    /// Whether to allow partial updates on failure.
    allow_partial_updates: bool = true,
    /// Maximum conflicts before aborting.
    max_conflicts: usize = 1000,
};

/// Statistics for incremental load operation.
pub const LoadStatistics = struct {
    /// Total events in source.
    source_events: usize = 0,
    /// Events filtered by timestamp.
    filtered_events: usize = 0,
    /// New events inserted.
    inserted_events: usize = 0,
    /// Events updated.
    updated_events: usize = 0,
    /// Events deleted.
    deleted_events: usize = 0,
    /// Unchanged events (skipped).
    unchanged_events: usize = 0,
    /// Conflicts detected.
    conflicts_detected: usize = 0,
    /// Conflicts resolved automatically.
    conflicts_resolved: usize = 0,
    /// Validation failures.
    validation_failures: usize = 0,
    /// Processing time in nanoseconds.
    processing_time_ns: u64 = 0,
    /// Events per second throughput.
    events_per_second: f64 = 0.0,

    /// Calculate throughput.
    pub fn calculateThroughput(self: *LoadStatistics) void {
        if (self.processing_time_ns > 0) {
            const total_processed = self.inserted_events + self.updated_events + self.deleted_events;
            const seconds = @as(f64, @floatFromInt(self.processing_time_ns)) / 1_000_000_000.0;
            self.events_per_second = @as(f64, @floatFromInt(total_processed)) / seconds;
        }
    }

    /// Check if throughput meets target.
    pub fn meetsTargetThroughput(self: *const LoadStatistics) bool {
        return self.events_per_second >= @as(f64, @floatFromInt(MIN_THROUGHPUT_EVENTS_PER_SEC));
    }
};

/// Result of an incremental load operation.
pub const LoadResult = struct {
    /// Whether the load succeeded.
    success: bool,
    /// Statistics about the load.
    statistics: LoadStatistics,
    /// Updated checkpoint.
    checkpoint: LoadCheckpoint,
    /// Error message if failed.
    error_message: ?[256]u8 = null,
    /// Unresolved conflicts (if any).
    unresolved_conflicts: []ConflictRecord,
    /// Events that failed validation.
    validation_failures: []const GeoEvent,

    pub fn deinit(self: *LoadResult, allocator: Allocator) void {
        if (self.unresolved_conflicts.len > 0) {
            allocator.free(self.unresolved_conflicts);
        }
        if (self.validation_failures.len > 0) {
            allocator.free(self.validation_failures);
        }
    }
};

/// Incremental loader for delta sync operations.
pub const IncrementalLoader = struct {
    const Self = @This();

    allocator: Allocator,
    options: IncrementalLoadOptions,
    checkpoint: LoadCheckpoint,
    validator: ?data_validation.DataValidator,

    // Index for fast entity lookup
    entity_index: std.AutoHashMap(u128, usize),

    /// Initialize an incremental loader.
    pub fn init(allocator: Allocator, options: IncrementalLoadOptions) Self {
        return .{
            .allocator = allocator,
            .options = options,
            .checkpoint = LoadCheckpoint.create(options.last_sync_timestamp_ns),
            .validator = if (options.validate_data)
                data_validation.DataValidator.init(allocator, .{})
            else
                null,
            .entity_index = std.AutoHashMap(u128, usize).init(allocator),
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *Self) void {
        if (self.validator) |*v| {
            v.deinit();
        }
        self.entity_index.deinit();
    }

    /// Reset the loader state.
    pub fn reset(self: *Self) void {
        self.checkpoint = LoadCheckpoint.create(self.options.last_sync_timestamp_ns);
        self.entity_index.clearRetainingCapacity();
        if (self.validator) |*v| {
            v.reset();
        }
    }

    /// Detect changes between source and target datasets.
    pub fn detectChanges(
        self: *Self,
        source_events: []const GeoEvent,
        target_events: []const GeoEvent,
    ) !ChangeSet {
        const start_time = std.time.nanoTimestamp();

        // Build index of target events by entity_id
        self.entity_index.clearRetainingCapacity();
        for (target_events, 0..) |*event, i| {
            try self.entity_index.put(event.entity_id, i);
        }

        var inserts = std.ArrayList(ChangeRecord).init(self.allocator);
        var updates = std.ArrayList(ChangeRecord).init(self.allocator);
        var conflicts = std.ArrayList(ConflictRecord).init(self.allocator);
        errdefer {
            inserts.deinit();
            updates.deinit();
            conflicts.deinit();
        }

        // Process source events
        for (source_events) |*source_event| {
            // Filter by timestamp
            if (source_event.timestamp < self.options.last_sync_timestamp_ns) {
                continue;
            }

            if (self.entity_index.get(source_event.entity_id)) |target_idx| {
                // Event exists in target - check for update
                const target_event = &target_events[target_idx];

                if (self.hasChanged(source_event, target_event)) {
                    // Check for conflict
                    if (self.isConflict(source_event, target_event)) {
                        const conflict = try self.resolveConflict(source_event, target_event);
                        try conflicts.append(conflict);

                        if (conflict.resolved_event) |resolved| {
                            try updates.append(.{
                                .operation = .update,
                                .event = resolved,
                                .entity_id = source_event.entity_id,
                                .timestamp_ns = source_event.timestamp,
                                .had_conflict = true,
                                .previous_event = if (self.options.capture_previous_values) target_event.* else null,
                            });
                        }
                    } else {
                        // No conflict, straightforward update
                        try updates.append(.{
                            .operation = .update,
                            .event = source_event.*,
                            .entity_id = source_event.entity_id,
                            .timestamp_ns = source_event.timestamp,
                            .previous_event = if (self.options.capture_previous_values) target_event.* else null,
                        });
                    }
                }
            } else {
                // New event - insert
                try inserts.append(.{
                    .operation = .insert,
                    .event = source_event.*,
                    .entity_id = source_event.entity_id,
                    .timestamp_ns = source_event.timestamp,
                });
            }
        }

        const end_time = std.time.nanoTimestamp();

        return .{
            .inserts = try inserts.toOwnedSlice(),
            .updates = try updates.toOwnedSlice(),
            .deletes = &[_]ChangeRecord{}, // Delete detection requires explicit delete markers
            .conflicts = try conflicts.toOwnedSlice(),
            .total_changes = inserts.items.len + updates.items.len,
            .processing_time_ns = @intCast(end_time - start_time),
        };
    }

    /// Load delta changes from source events.
    pub fn loadDelta(
        self: *Self,
        source_events: []const GeoEvent,
        target_events: []const GeoEvent,
    ) !LoadResult {
        const start_time = std.time.nanoTimestamp();
        var stats = LoadStatistics{
            .source_events = source_events.len,
        };

        var unresolved_conflicts = std.ArrayList(ConflictRecord).init(self.allocator);
        var validation_failures = std.ArrayList(GeoEvent).init(self.allocator);
        errdefer {
            unresolved_conflicts.deinit();
            validation_failures.deinit();
        }

        // Detect changes
        var changeset = try self.detectChanges(source_events, target_events);
        defer changeset.deinit(self.allocator);

        // Validate if enabled
        if (self.validator) |*validator| {
            for (changeset.inserts) |*change| {
                if (change.event) |*event| {
                    const result = validator.validateEvent(event);
                    if (!result.is_valid) {
                        stats.validation_failures += 1;
                        try validation_failures.append(event.*);
                        change.operation = .unchanged; // Mark as skipped
                    }
                }
            }
            for (changeset.updates) |*change| {
                if (change.event) |*event| {
                    const result = validator.validateEvent(event);
                    if (!result.is_valid) {
                        stats.validation_failures += 1;
                        try validation_failures.append(event.*);
                        change.operation = .unchanged;
                    }
                }
            }
        }

        // Count operations
        for (changeset.inserts) |change| {
            if (change.operation == .insert) {
                stats.inserted_events += 1;
            }
        }
        for (changeset.updates) |change| {
            if (change.operation == .update) {
                stats.updated_events += 1;
            }
        }

        stats.conflicts_detected = changeset.conflicts.len;

        // Identify unresolved conflicts
        for (changeset.conflicts) |conflict| {
            if (conflict.resolved_event == null) {
                try unresolved_conflicts.append(conflict);
            } else {
                stats.conflicts_resolved += 1;
            }
        }

        stats.filtered_events = stats.source_events - (stats.inserted_events + stats.updated_events + stats.validation_failures);

        const end_time = std.time.nanoTimestamp();
        stats.processing_time_ns = @intCast(end_time - start_time);
        stats.calculateThroughput();

        // Update checkpoint
        var max_timestamp = self.checkpoint.last_sync_timestamp_ns;
        for (changeset.inserts) |change| {
            if (change.timestamp_ns > max_timestamp) {
                max_timestamp = change.timestamp_ns;
            }
        }
        for (changeset.updates) |change| {
            if (change.timestamp_ns > max_timestamp) {
                max_timestamp = change.timestamp_ns;
            }
        }

        self.checkpoint.update(stats.inserted_events + stats.updated_events, max_timestamp);

        const success = unresolved_conflicts.items.len == 0 and
            (self.options.allow_partial_updates or stats.validation_failures == 0);

        return .{
            .success = success,
            .statistics = stats,
            .checkpoint = self.checkpoint,
            .unresolved_conflicts = try unresolved_conflicts.toOwnedSlice(),
            .validation_failures = try validation_failures.toOwnedSlice(),
        };
    }

    /// Filter events by timestamp (returns events after last sync).
    pub fn filterByTimestamp(self: *const Self, events: []const GeoEvent) ![]const GeoEvent {
        var filtered = std.ArrayList(GeoEvent).init(self.allocator);
        errdefer filtered.deinit();

        for (events) |event| {
            if (event.timestamp >= self.options.last_sync_timestamp_ns) {
                try filtered.append(event);
            }
        }

        return filtered.toOwnedSlice();
    }

    /// Check if two events represent a change.
    fn hasChanged(self: *const Self, source: *const GeoEvent, target: *const GeoEvent) bool {
        _ = self;
        // Compare key fields
        if (source.timestamp != target.timestamp) return true;
        if (source.lat_nano != target.lat_nano) return true;
        if (source.lon_nano != target.lon_nano) return true;
        if (source.altitude_mm != target.altitude_mm) return true;
        if (source.velocity_mms != target.velocity_mms) return true;
        if (source.heading_cdeg != target.heading_cdeg) return true;
        if (source.accuracy_mm != target.accuracy_mm) return true;
        if (@as(u16, @bitCast(source.flags)) != @as(u16, @bitCast(target.flags))) return true;
        if (source.ttl_seconds != target.ttl_seconds) return true;
        if (source.correlation_id != target.correlation_id) return true;
        if (source.group_id != target.group_id) return true;
        if (source.user_data != target.user_data) return true;

        return false;
    }

    /// Check if there's a conflict between source and target.
    fn isConflict(self: *const Self, source: *const GeoEvent, target: *const GeoEvent) bool {
        // Conflict if target was modified after our last sync
        if (target.timestamp > self.options.last_sync_timestamp_ns) {
            // Both have been modified since last sync
            if (source.timestamp > self.options.last_sync_timestamp_ns) {
                return true;
            }
        }
        return false;
    }

    /// Resolve a conflict between source and target events.
    fn resolveConflict(self: *Self, source: *const GeoEvent, target: *const GeoEvent) !ConflictRecord {
        const resolution = self.options.conflict_resolution;

        var resolved: ?GeoEvent = null;

        switch (resolution) {
            .source_wins => {
                resolved = source.*;
            },
            .target_wins => {
                resolved = target.*;
            },
            .latest_wins => {
                resolved = if (source.timestamp >= target.timestamp) source.* else target.*;
            },
            .merge_source_priority => {
                resolved = try self.mergeEvents(source, target, true);
            },
            .merge_target_priority => {
                resolved = try self.mergeEvents(source, target, false);
            },
            .reject => {
                resolved = null; // Leave unresolved
            },
        }

        return .{
            .entity_id = source.entity_id,
            .source_event = source.*,
            .target_event = target.*,
            .resolution = resolution,
            .resolved_event = resolved,
            .reason = .concurrent_modification,
        };
    }

    /// Merge two events with priority.
    fn mergeEvents(self: *Self, source: *const GeoEvent, target: *const GeoEvent, source_priority: bool) !GeoEvent {
        _ = self;
        // Start with priority event and fill in from other
        var merged = if (source_priority) source.* else target.*;
        const other = if (source_priority) target else source;

        // Merge non-zero fields from other if primary has zero
        if (merged.correlation_id == 0 and other.correlation_id != 0) {
            merged.correlation_id = other.correlation_id;
        }
        if (merged.altitude_mm == 0 and other.altitude_mm != 0) {
            merged.altitude_mm = other.altitude_mm;
        }
        if (merged.velocity_mms == 0 and other.velocity_mms != 0) {
            merged.velocity_mms = other.velocity_mms;
        }
        if (merged.heading_cdeg == 0 and other.heading_cdeg != 0) {
            merged.heading_cdeg = other.heading_cdeg;
        }
        if (merged.accuracy_mm == 0 and other.accuracy_mm != 0) {
            merged.accuracy_mm = other.accuracy_mm;
        }
        if (merged.ttl_seconds == 0 and other.ttl_seconds != 0) {
            merged.ttl_seconds = other.ttl_seconds;
        }
        if (merged.group_id == 0 and other.group_id != 0) {
            merged.group_id = other.group_id;
        }
        if (merged.user_data == 0 and other.user_data != 0) {
            merged.user_data = other.user_data;
        }

        // Use latest timestamp
        merged.timestamp = @max(source.timestamp, target.timestamp);

        return merged;
    }

    /// Get current checkpoint.
    pub fn getCheckpoint(self: *const Self) LoadCheckpoint {
        return self.checkpoint;
    }

    /// Set checkpoint for resumption.
    pub fn setCheckpoint(self: *Self, checkpoint: LoadCheckpoint) void {
        self.checkpoint = checkpoint;
        self.options.last_sync_timestamp_ns = checkpoint.last_sync_timestamp_ns;
    }
};

/// Quick delta detection - returns count of changes.
pub fn countChanges(
    source_events: []const GeoEvent,
    target_events: []const GeoEvent,
    last_sync_timestamp: u64,
) !usize {
    var loader = IncrementalLoader.init(std.heap.page_allocator, .{
        .last_sync_timestamp_ns = last_sync_timestamp,
        .validate_data = false,
    });
    defer loader.deinit();

    var changeset = try loader.detectChanges(source_events, target_events);
    defer changeset.deinit(std.heap.page_allocator);

    return changeset.total_changes;
}

// === Tests ===

test "detect new inserts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = IncrementalLoader.init(allocator, .{
        .last_sync_timestamp_ns = 0,
        .validate_data = false,
    });
    defer loader.deinit();

    // Source has new events
    var source_events: [2]GeoEvent = undefined;
    source_events[0] = GeoEvent.zero();
    source_events[0].entity_id = 1;
    source_events[0].timestamp = 1000;
    source_events[1] = GeoEvent.zero();
    source_events[1].entity_id = 2;
    source_events[1].timestamp = 2000;

    // Target is empty
    const target_events: []const GeoEvent = &[_]GeoEvent{};

    var changeset = try loader.detectChanges(&source_events, target_events);
    defer changeset.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), changeset.inserts.len);
    try testing.expectEqual(@as(usize, 0), changeset.updates.len);
    try testing.expectEqual(@as(usize, 0), changeset.conflicts.len);
}

test "detect updates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = IncrementalLoader.init(allocator, .{
        .last_sync_timestamp_ns = 0,
        .validate_data = false,
    });
    defer loader.deinit();

    // Source has updated event
    var source_events: [1]GeoEvent = undefined;
    source_events[0] = GeoEvent.zero();
    source_events[0].entity_id = 1;
    source_events[0].timestamp = 2000;
    source_events[0].lat_nano = 1000; // Changed

    // Target has old version
    var target_events: [1]GeoEvent = undefined;
    target_events[0] = GeoEvent.zero();
    target_events[0].entity_id = 1;
    target_events[0].timestamp = 1000;
    target_events[0].lat_nano = 500;

    var changeset = try loader.detectChanges(&source_events, &target_events);
    defer changeset.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), changeset.inserts.len);
    try testing.expectEqual(@as(usize, 1), changeset.updates.len);
}

test "filter by timestamp" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = IncrementalLoader.init(allocator, .{
        .last_sync_timestamp_ns = 1500,
        .validate_data = false,
    });
    defer loader.deinit();

    // Events with various timestamps
    var events: [3]GeoEvent = undefined;
    events[0] = GeoEvent.zero();
    events[0].entity_id = 1;
    events[0].timestamp = 1000; // Before sync - should be filtered
    events[1] = GeoEvent.zero();
    events[1].entity_id = 2;
    events[1].timestamp = 2000; // After sync - should pass
    events[2] = GeoEvent.zero();
    events[2].entity_id = 3;
    events[2].timestamp = 3000; // After sync - should pass

    const filtered = try loader.filterByTimestamp(&events);
    defer allocator.free(filtered);

    try testing.expectEqual(@as(usize, 2), filtered.len);
}

test "conflict detection and resolution - source wins" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = IncrementalLoader.init(allocator, .{
        .last_sync_timestamp_ns = 500,
        .conflict_resolution = .source_wins,
        .validate_data = false,
    });
    defer loader.deinit();

    // Source modified after last sync
    var source_events: [1]GeoEvent = undefined;
    source_events[0] = GeoEvent.zero();
    source_events[0].entity_id = 1;
    source_events[0].timestamp = 1000;
    source_events[0].lat_nano = 100;

    // Target also modified after last sync - conflict!
    var target_events: [1]GeoEvent = undefined;
    target_events[0] = GeoEvent.zero();
    target_events[0].entity_id = 1;
    target_events[0].timestamp = 800;
    target_events[0].lat_nano = 200;

    var changeset = try loader.detectChanges(&source_events, &target_events);
    defer changeset.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), changeset.conflicts.len);
    try testing.expectEqual(ConflictResolution.source_wins, changeset.conflicts[0].resolution);
    try testing.expect(changeset.conflicts[0].resolved_event != null);
    try testing.expectEqual(@as(i64, 100), changeset.conflicts[0].resolved_event.?.lat_nano);
}

test "conflict detection and resolution - latest wins" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = IncrementalLoader.init(allocator, .{
        .last_sync_timestamp_ns = 500,
        .conflict_resolution = .latest_wins,
        .validate_data = false,
    });
    defer loader.deinit();

    // Source has older timestamp
    var source_events: [1]GeoEvent = undefined;
    source_events[0] = GeoEvent.zero();
    source_events[0].entity_id = 1;
    source_events[0].timestamp = 800;
    source_events[0].lat_nano = 100;

    // Target has newer timestamp - should win
    var target_events: [1]GeoEvent = undefined;
    target_events[0] = GeoEvent.zero();
    target_events[0].entity_id = 1;
    target_events[0].timestamp = 1000;
    target_events[0].lat_nano = 200;

    var changeset = try loader.detectChanges(&source_events, &target_events);
    defer changeset.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), changeset.conflicts.len);
    try testing.expect(changeset.conflicts[0].resolved_event != null);
    // Target wins because it has later timestamp
    try testing.expectEqual(@as(i64, 200), changeset.conflicts[0].resolved_event.?.lat_nano);
}

test "load delta with statistics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = IncrementalLoader.init(allocator, .{
        .last_sync_timestamp_ns = 0,
        .validate_data = false,
    });
    defer loader.deinit();

    // Source with mix of new and updated events
    var source_events: [3]GeoEvent = undefined;
    source_events[0] = GeoEvent.zero();
    source_events[0].entity_id = 1;
    source_events[0].timestamp = 1000;
    source_events[0].id = GeoEvent.pack_id(1, 1000);
    source_events[1] = GeoEvent.zero();
    source_events[1].entity_id = 2;
    source_events[1].timestamp = 2000;
    source_events[1].id = GeoEvent.pack_id(2, 2000);
    source_events[1].lat_nano = 500; // Modified
    source_events[2] = GeoEvent.zero();
    source_events[2].entity_id = 3;
    source_events[2].timestamp = 3000;
    source_events[2].id = GeoEvent.pack_id(3, 3000);

    // Target with one existing event
    var target_events: [1]GeoEvent = undefined;
    target_events[0] = GeoEvent.zero();
    target_events[0].entity_id = 2;
    target_events[0].timestamp = 1500;
    target_events[0].id = GeoEvent.pack_id(2, 1500);
    target_events[0].lat_nano = 100;

    var result = try loader.loadDelta(&source_events, &target_events);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 3), result.statistics.source_events);
    try testing.expectEqual(@as(usize, 2), result.statistics.inserted_events);
    try testing.expectEqual(@as(usize, 1), result.statistics.updated_events);
}

test "checkpoint update" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = IncrementalLoader.init(allocator, .{
        .last_sync_timestamp_ns = 1000,
        .validate_data = false,
    });
    defer loader.deinit();

    // Load events
    var source_events: [2]GeoEvent = undefined;
    source_events[0] = GeoEvent.zero();
    source_events[0].entity_id = 1;
    source_events[0].timestamp = 2000;
    source_events[0].id = GeoEvent.pack_id(1, 2000);
    source_events[1] = GeoEvent.zero();
    source_events[1].entity_id = 2;
    source_events[1].timestamp = 3000;
    source_events[1].id = GeoEvent.pack_id(2, 3000);

    const target_events: []const GeoEvent = &[_]GeoEvent{};

    var result = try loader.loadDelta(&source_events, target_events);
    defer result.deinit(allocator);

    // Checkpoint should be updated to latest timestamp
    try testing.expectEqual(@as(u64, 3000), result.checkpoint.last_sync_timestamp_ns);
    try testing.expectEqual(@as(usize, 2), result.checkpoint.events_processed);
}

test "merge events with source priority" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = IncrementalLoader.init(allocator, .{
        .last_sync_timestamp_ns = 500,
        .conflict_resolution = .merge_source_priority,
        .validate_data = false,
    });
    defer loader.deinit();

    // Source has some fields
    var source = GeoEvent.zero();
    source.entity_id = 1;
    source.timestamp = 1000;
    source.lat_nano = 100;
    source.lon_nano = 200;
    source.altitude_mm = 0; // Missing

    // Target has other fields
    var target = GeoEvent.zero();
    target.entity_id = 1;
    target.timestamp = 800;
    target.lat_nano = 50;
    target.lon_nano = 100;
    target.altitude_mm = 500; // Has altitude

    const merged = try loader.mergeEvents(&source, &target, true);

    // Source fields should be used (source_priority = true)
    try testing.expectEqual(@as(i64, 100), merged.lat_nano);
    try testing.expectEqual(@as(i64, 200), merged.lon_nano);
    // Target altitude should be merged in since source is 0
    try testing.expectEqual(@as(i32, 500), merged.altitude_mm);
    // Latest timestamp
    try testing.expectEqual(@as(u64, 1000), merged.timestamp);
}
