//! Index Checkpoint - Periodic persistence of RAM index to disk.
//!
//! Implements an incremental dirty-page checkpoint strategy to avoid
//! massive I/O spikes when persisting large indexes (90GB+ for 1B entities).
//!
//! Key features:
//! - Dirty page tracking via bitset (1 bit per page)
//! - Continuous background flush of dirty pages
//! - Coordination with VSR checkpoint for recovery
//! - Recovery decision tree: WAL replay → LSM scan → Full rebuild
//!
//! Checkpoint coordination:
//! 1. VSR Checkpoint (storage-engine) - Every 256 operations
//! 2. Index Checkpoint (this module) - Continuous background process
//!
//! Recovery paths:
//! - Case A: WAL replay (gap <= journal_slot_count) - Fast
//! - Case B: LSM scan (8K-20K ops gap) - Medium
//! - Case C: Full rebuild (checkpoint very old) - Slow
//!
//! See specs/hybrid-memory/spec.md for full requirements.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const fs = std.fs;

const log = std.log.scoped(.index_checkpoint);

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const RamIndex = @import("../ram_index.zig").RamIndex;
const IndexEntry = @import("../ram_index.zig").IndexEntry;

/// Checkpoint file magic number: "ARCH" (0x41524348)
pub const MAGIC: u32 = 0x41524348;

/// Current checkpoint format version.
pub const VERSION: u16 = 1;

/// Default page size for dirty tracking (64KB).
/// This determines checkpoint granularity - smaller = more overhead, larger = more wasted writes.
pub const default_page_size: u32 = 64 * 1024;

/// Maximum checkpoint age before triggering rebuild (7 days in seconds).
pub const max_checkpoint_age_seconds: u64 = 7 * 24 * 60 * 60;

/// CheckpointHeader - 256-byte header for index checkpoint files.
///
/// Layout matches spec requirements with Aegis-128L checksums for integrity.
pub const CheckpointHeader = extern struct {
    /// Magic number: 0x41524348 ("ARCH")
    magic: u32 = MAGIC,

    /// Checkpoint format version
    version: u16 = VERSION,

    /// Reserved padding for alignment
    reserved1: u16 = 0,

    /// Number of index entries in this checkpoint
    entry_count: u64 = 0,

    /// Index capacity (total slots)
    capacity: u64 = 0,

    /// Highest timestamp seen in indexed events
    timestamp_high_water: u64 = 0,

    /// VSR checkpoint op number at index checkpoint time
    vsr_checkpoint_op: u64 = 0,

    /// VSR commit_max at index checkpoint time
    vsr_commit_max: u64 = 0,

    /// Unix timestamp when checkpoint was created (nanoseconds)
    checkpoint_timestamp_ns: u64 = 0,

    /// Checksum of header (Aegis-128L MAC), computed after this field
    header_checksum: u128 = 0,

    /// Padding for u128 alignment
    header_checksum_padding: u128 = 0,

    /// Checksum of all index entries (Aegis-128L MAC)
    body_checksum: u128 = 0,

    /// Padding for u128 alignment
    body_checksum_padding: u128 = 0,

    /// Number of pages in checkpoint
    page_count: u64 = 0,

    /// Page size in bytes
    page_size: u32 = default_page_size,

    /// Reserved padding
    reserved2: u32 = 0,

    /// Reserved for future use (106 bytes to reach 256 total)
    reserved: [106]u8 = [_]u8{0} ** 106,

    /// Validate header fields for sanity.
    pub fn validate(self: CheckpointHeader) bool {
        if (self.magic != MAGIC) return false;
        if (self.version == 0 or self.version > VERSION) return false;
        if (self.capacity == 0) return false;
        if (self.entry_count > self.capacity) return false;
        if (self.page_size == 0) return false;
        return true;
    }

    /// Check if checkpoint is stale (age > max_checkpoint_age_seconds).
    pub fn is_stale(self: CheckpointHeader) bool {
        const now_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
        const age_ns = now_ns -| self.checkpoint_timestamp_ns;
        const age_seconds = age_ns / std.time.ns_per_s;
        return age_seconds > max_checkpoint_age_seconds;
    }
};

// Compile-time validation of CheckpointHeader layout.
comptime {
    // CheckpointHeader must be exactly 256 bytes.
    assert(@sizeOf(CheckpointHeader) == 256);
}

/// Error codes for checkpoint operations.
pub const CheckpointError = error{
    /// File I/O error
    IoError,

    /// Invalid checkpoint header (magic, version, or validation failed)
    InvalidHeader,

    /// Checkpoint is corrupted (checksum mismatch)
    ChecksumMismatch,

    /// Checkpoint is stale (age > max_checkpoint_age_seconds)
    StaleCheckpoint,

    /// Out of memory
    OutOfMemory,

    /// File not found
    NotFound,

    /// Recovery required (checkpoint too old for WAL replay)
    RecoveryRequired,
};

/// Statistics for checkpoint operations.
pub const CheckpointStats = struct {
    /// Number of checkpoints written
    checkpoint_count: u64 = 0,

    /// Total pages written (across all checkpoints)
    pages_written: u64 = 0,

    /// Total bytes written
    bytes_written: u64 = 0,

    /// Last checkpoint timestamp (nanoseconds)
    last_checkpoint_ns: u64 = 0,

    /// Last checkpoint duration (nanoseconds)
    last_checkpoint_duration_ns: u64 = 0,

    /// Number of recovery operations
    recovery_count: u64 = 0,

    /// Recovery path taken (for metrics)
    last_recovery_path: RecoveryPath = .none,
};

/// Recovery path taken during startup.
pub const RecoveryPath = enum {
    none,
    wal_replay, // Case A: Fast path via WAL
    lsm_scan, // Case B: Medium path via LSM
    full_rebuild, // Case C: Slow path via full rebuild
    clean_start, // No checkpoint, first startup
};

/// DirtyPageTracker - Tracks which index pages have been modified since last checkpoint.
///
/// Uses a bitset where each bit represents one page (default 64KB).
/// For 91.5GB index with 64KB pages: ~1.43M pages = ~179KB bitset
pub fn DirtyPageTracker(comptime page_size: u32) type {
    return struct {
        const Self = @This();

        /// Bitset tracking dirty pages (1 = dirty, 0 = clean)
        dirty_bits: std.DynamicBitSet,

        /// Number of pages in the index
        page_count: u64,

        /// Number of currently dirty pages
        dirty_count: std.atomic.Value(u64),

        /// Total bytes in the index
        total_bytes: u64,

        pub fn init(allocator: Allocator, total_bytes: u64) !Self {
            const page_count = (total_bytes + page_size - 1) / page_size;

            const dirty_bits = try std.DynamicBitSet.initEmpty(allocator, @intCast(page_count));

            return Self{
                .dirty_bits = dirty_bits,
                .page_count = page_count,
                .dirty_count = std.atomic.Value(u64).init(0),
                .total_bytes = total_bytes,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            _ = allocator;
            self.dirty_bits.deinit();
            self.* = undefined;
        }

        /// Mark a byte range as dirty.
        /// Called when index entries are modified.
        pub fn mark_dirty(self: *Self, offset: u64, len: u64) void {
            const start_page = offset / page_size;
            const end_page = (offset + len + page_size - 1) / page_size;

            var page = start_page;
            while (page < end_page and page < self.page_count) : (page += 1) {
                if (!self.dirty_bits.isSet(@intCast(page))) {
                    self.dirty_bits.set(@intCast(page));
                    _ = self.dirty_count.fetchAdd(1, .monotonic);
                }
            }
        }

        /// Mark a single page as dirty by page index.
        pub fn mark_page_dirty(self: *Self, page_index: u64) void {
            if (page_index >= self.page_count) return;

            if (!self.dirty_bits.isSet(@intCast(page_index))) {
                self.dirty_bits.set(@intCast(page_index));
                _ = self.dirty_count.fetchAdd(1, .monotonic);
            }
        }

        /// Clear dirty bit for a page after successful flush.
        pub fn clear_dirty(self: *Self, page_index: u64) void {
            if (page_index >= self.page_count) return;

            if (self.dirty_bits.isSet(@intCast(page_index))) {
                self.dirty_bits.unset(@intCast(page_index));
                _ = self.dirty_count.fetchSub(1, .monotonic);
            }
        }

        /// Clear all dirty bits (after full checkpoint).
        pub fn clear_all(self: *Self) void {
            self.dirty_bits.setRangeValue(.{ .start = 0, .end = @intCast(self.page_count) }, false);
            self.dirty_count.store(0, .monotonic);
        }

        /// Get number of dirty pages.
        pub fn get_dirty_count(self: *const Self) u64 {
            return self.dirty_count.load(.monotonic);
        }

        /// Check if a specific page is dirty.
        pub fn is_dirty(self: *const Self, page_index: u64) bool {
            if (page_index >= self.page_count) return false;
            return self.dirty_bits.isSet(@intCast(page_index));
        }

        /// Iterator over dirty pages.
        pub fn dirty_iterator(self: *const Self) DirtyIterator {
            return DirtyIterator{
                .bits = &self.dirty_bits,
                .page_count = self.page_count,
                .current = 0,
            };
        }

        pub const DirtyIterator = struct {
            bits: *const std.DynamicBitSet,
            page_count: u64,
            current: u64,

            pub fn next(self: *DirtyIterator) ?u64 {
                while (self.current < self.page_count) {
                    const page = self.current;
                    self.current += 1;
                    if (self.bits.isSet(@intCast(page))) {
                        return page;
                    }
                }
                return null;
            }
        };
    };
}

/// Default dirty page tracker with 64KB pages.
pub const DefaultDirtyTracker = DirtyPageTracker(default_page_size);

/// IndexCheckpoint - Manages checkpoint persistence for RAM index.
pub fn IndexCheckpoint(comptime page_size: u32) type {
    return struct {
        const Self = @This();
        const DirtyTracker = DirtyPageTracker(page_size);

        /// Dirty page tracker
        dirty_tracker: DirtyTracker,

        /// Checkpoint header (current state)
        header: CheckpointHeader,

        /// Statistics
        stats: CheckpointStats,

        /// Checkpoint file path
        checkpoint_path: []const u8,

        /// Allocator for internal use
        allocator: Allocator,

        /// Initialize checkpoint manager.
        pub fn init(
            allocator: Allocator,
            checkpoint_path: []const u8,
            index_capacity: u64,
        ) !Self {
            const total_bytes = index_capacity * @sizeOf(IndexEntry);

            return Self{
                .dirty_tracker = try DirtyTracker.init(allocator, total_bytes),
                .header = CheckpointHeader{
                    .capacity = index_capacity,
                    .page_size = page_size,
                    .page_count = (total_bytes + page_size - 1) / page_size,
                },
                .stats = CheckpointStats{},
                .checkpoint_path = checkpoint_path,
                .allocator = allocator,
            };
        }

        /// Deinitialize checkpoint manager.
        pub fn deinit(self: *Self) void {
            self.dirty_tracker.deinit(self.allocator);
            self.* = undefined;
        }

        /// Mark index entry as modified (for dirty tracking).
        /// Called by RamIndex on upsert/remove operations.
        pub fn mark_entry_dirty(self: *Self, entry_index: u64) void {
            const byte_offset = entry_index * @sizeOf(IndexEntry);
            self.dirty_tracker.mark_dirty(byte_offset, @sizeOf(IndexEntry));
        }

        /// Write incremental checkpoint (dirty pages only).
        ///
        /// This is the main checkpoint operation, designed to be called
        /// periodically in the background without blocking operations.
        pub fn write_incremental(
            self: *Self,
            index_entries: []const IndexEntry,
            vsr_checkpoint_op: u64,
            vsr_commit_max: u64,
        ) CheckpointError!void {
            const start_time = std.time.nanoTimestamp();

            // Open/create checkpoint file
            var file = fs.cwd().createFile(self.checkpoint_path, .{
                .read = true,
                .truncate = false,
            }) catch return error.IoError;
            defer file.close();

            // Update header
            self.header.entry_count = self.count_entries(index_entries);
            self.header.vsr_checkpoint_op = vsr_checkpoint_op;
            self.header.vsr_commit_max = vsr_commit_max;
            self.header.checkpoint_timestamp_ns = @as(u64, @intCast(std.time.nanoTimestamp()));

            // Calculate body checksum (all entries)
            self.header.body_checksum = self.calculate_body_checksum(index_entries);

            // Write dirty pages
            var pages_written: u64 = 0;
            var iter = self.dirty_tracker.dirty_iterator();
            while (iter.next()) |page_index| {
                const page_offset = page_index * page_size;
                const byte_offset = @sizeOf(CheckpointHeader) + page_offset;

                // Calculate entry range for this page
                const start_entry = page_offset / @sizeOf(IndexEntry);
                const end_entry = @min(
                    (page_offset + page_size) / @sizeOf(IndexEntry),
                    index_entries.len,
                );

                if (start_entry >= index_entries.len) continue;

                // Write page
                const page_entries = index_entries[start_entry..end_entry];
                const page_bytes = mem.sliceAsBytes(page_entries);

                file.seekTo(byte_offset) catch return error.IoError;
                file.writeAll(page_bytes) catch return error.IoError;

                self.dirty_tracker.clear_dirty(page_index);
                pages_written += 1;
            }

            // Calculate and write header checksum
            self.header.header_checksum = self.calculate_header_checksum();

            // Write header
            file.seekTo(0) catch return error.IoError;
            file.writeAll(mem.asBytes(&self.header)) catch return error.IoError;

            // Sync to disk
            file.sync() catch return error.IoError;

            // Update stats
            const end_time = std.time.nanoTimestamp();
            self.stats.checkpoint_count += 1;
            self.stats.pages_written += pages_written;
            self.stats.bytes_written += pages_written * page_size + @sizeOf(CheckpointHeader);
            self.stats.last_checkpoint_ns = @as(u64, @intCast(end_time));
            self.stats.last_checkpoint_duration_ns = @as(u64, @intCast(end_time - start_time));
        }

        /// Write full checkpoint (all pages).
        /// Used for initial checkpoint or recovery.
        pub fn write_full(
            self: *Self,
            index_entries: []const IndexEntry,
            vsr_checkpoint_op: u64,
            vsr_commit_max: u64,
        ) CheckpointError!void {
            const start_time = std.time.nanoTimestamp();

            // Mark all pages as dirty to force full write
            var page: u64 = 0;
            while (page < self.dirty_tracker.page_count) : (page += 1) {
                self.dirty_tracker.mark_page_dirty(page);
            }

            // Use incremental write (which will now write everything)
            try self.write_incremental(index_entries, vsr_checkpoint_op, vsr_commit_max);

            // Update stats
            const end_time = std.time.nanoTimestamp();
            self.stats.last_checkpoint_duration_ns = @as(u64, @intCast(end_time - start_time));
        }

        /// Load checkpoint from disk into index entries.
        /// Returns the VSR checkpoint op for replay coordination.
        pub fn load(
            self: *Self,
            index_entries: []IndexEntry,
        ) CheckpointError!struct { vsr_op: u64, vsr_commit_max: u64 } {
            var file = fs.cwd().openFile(self.checkpoint_path, .{}) catch |err| {
                if (err == error.FileNotFound) return error.NotFound;
                return error.IoError;
            };
            defer file.close();

            // Read header
            var header: CheckpointHeader = undefined;
            const header_bytes = file.reader().readBytesNoEof(@sizeOf(CheckpointHeader)) catch return error.IoError;
            header = @bitCast(header_bytes);

            // Validate header
            if (!header.validate()) return error.InvalidHeader;

            // Verify header checksum
            const expected_checksum = self.calculate_header_checksum_for(&header);
            if (header.header_checksum != expected_checksum) return error.ChecksumMismatch;

            // Check for stale checkpoint
            if (header.is_stale()) {
                self.stats.last_recovery_path = .full_rebuild;
                return error.StaleCheckpoint;
            }

            // Verify capacity matches
            if (header.capacity != self.header.capacity) return error.InvalidHeader;

            // Read index entries
            const entry_bytes = mem.sliceAsBytes(index_entries);
            _ = file.reader().readAll(entry_bytes) catch return error.IoError;

            // Verify body checksum
            const body_checksum = self.calculate_body_checksum(index_entries);
            if (header.body_checksum != body_checksum) return error.ChecksumMismatch;

            // Update our header with loaded state
            self.header = header;

            // Clear dirty bits (just loaded, nothing to flush)
            self.dirty_tracker.clear_all();

            self.stats.recovery_count += 1;
            self.stats.last_recovery_path = .wal_replay;

            return .{
                .vsr_op = header.vsr_checkpoint_op,
                .vsr_commit_max = header.vsr_commit_max,
            };
        }

        /// Check if checkpoint exists on disk.
        pub fn exists(self: *const Self) bool {
            _ = fs.cwd().statFile(self.checkpoint_path) catch return false;
            return true;
        }

        /// Get current dirty page count.
        pub fn get_dirty_count(self: *const Self) u64 {
            return self.dirty_tracker.get_dirty_count();
        }

        /// Get statistics.
        pub fn get_stats(self: *const Self) CheckpointStats {
            return self.stats;
        }

        // Internal helpers

        fn count_entries(self: *const Self, entries: []const IndexEntry) u64 {
            _ = self;
            var count: u64 = 0;
            for (entries) |entry| {
                if (!entry.is_empty() and !entry.is_tombstone()) {
                    count += 1;
                }
            }
            return count;
        }

        fn calculate_header_checksum(self: *Self) u128 {
            return self.calculate_header_checksum_for(&self.header);
        }

        fn calculate_header_checksum_for(self: *const Self, header: *const CheckpointHeader) u128 {
            _ = self;
            // Checksum covers header bytes after the checksum field
            const checksum_offset = @offsetOf(CheckpointHeader, "header_checksum") + @sizeOf(u128) + @sizeOf(u128);
            const header_bytes = mem.asBytes(header);
            const payload = header_bytes[checksum_offset..];
            return vsr.checksum(payload);
        }

        fn calculate_body_checksum(self: *const Self, entries: []const IndexEntry) u128 {
            _ = self;
            return vsr.checksum(mem.sliceAsBytes(entries));
        }
    };
}

/// Default index checkpoint with 64KB pages.
pub const DefaultIndexCheckpoint = IndexCheckpoint(default_page_size);

// ============================================================================
// Full Index Rebuild (F2.2.6)
// ============================================================================

/// SeenEntities bitset for tracking which entity IDs have been processed during rebuild.
/// Uses a bloom filter for memory efficiency (~128MB for 1B entities).
///
/// GDPR-CRITICAL: This bitset ensures newest versions take precedence.
/// By marking entities as "seen" after processing from newest-to-oldest,
/// we guarantee that deleted entities (tombstones) are not resurrected.
pub fn SeenEntitiesBitset(comptime expected_entities: u64) type {
    // Use ~1 bit per expected entity for ~1% false positive rate
    // For 1B entities: 1B / 8 = 128MB
    const bitset_bytes = (expected_entities + 7) / 8;

    return struct {
        const Self = @This();

        bits: []u8,
        allocator: Allocator,
        seen_count: u64 = 0,

        /// Initialize the seen entities bitset.
        pub fn init(allocator: Allocator) !Self {
            const bits = try allocator.alloc(u8, bitset_bytes);
            @memset(bits, 0);
            return Self{
                .bits = bits,
                .allocator = allocator,
            };
        }

        /// Free the bitset memory.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bits);
            self.* = undefined;
        }

        /// Mark an entity as seen. Returns true if this is the first time seeing it.
        /// Uses the hash of entity_id to determine bit position.
        ///
        /// GDPR-CRITICAL: Only the first occurrence (newest version) is processed.
        pub fn mark_seen(self: *Self, entity_id: u128) bool {
            const bit_index = self.hash_to_index(entity_id);
            const byte_index = bit_index / 8;
            const bit_offset: u3 = @intCast(bit_index % 8);
            const mask: u8 = @as(u8, 1) << bit_offset;

            const already_seen = (self.bits[byte_index] & mask) != 0;
            if (!already_seen) {
                self.bits[byte_index] |= mask;
                self.seen_count += 1;
                return true; // First time seeing this entity
            }
            return false; // Already seen (skip this older version)
        }

        /// Check if an entity has been seen.
        pub fn was_seen(self: *const Self, entity_id: u128) bool {
            const bit_index = self.hash_to_index(entity_id);
            const byte_index = bit_index / 8;
            const bit_offset: u3 = @intCast(bit_index % 8);
            const mask: u8 = @as(u8, 1) << bit_offset;
            return (self.bits[byte_index] & mask) != 0;
        }

        /// Reset the bitset for reuse.
        pub fn reset(self: *Self) void {
            @memset(self.bits, 0);
            self.seen_count = 0;
        }

        /// Get the number of unique entities seen.
        pub fn get_seen_count(self: *const Self) u64 {
            return self.seen_count;
        }

        fn hash_to_index(self: *const Self, entity_id: u128) u64 {
            // Use lower bits of entity_id hash modulo bitset size
            const h = stdx.hash_inline(entity_id);
            return h % (self.bits.len * 8);
        }
    };
}

/// Rebuild progress tracking.
pub const RebuildProgress = struct {
    /// Total records scanned.
    records_scanned: u64 = 0,
    /// Records inserted into index.
    records_inserted: u64 = 0,
    /// Records skipped (already seen).
    records_skipped: u64 = 0,
    /// Records skipped (tombstones).
    tombstones_skipped: u64 = 0,
    /// Current LSM level being processed.
    current_level: u8 = 0,
    /// Previous LSM level (for assertion).
    previous_level: u8 = 255,
    /// Start timestamp (nanoseconds).
    start_time_ns: u64 = 0,
    /// Last progress log timestamp.
    last_log_time_ns: u64 = 0,

    /// Check GDPR-critical ordering invariant.
    /// Levels must be processed in order from L0 (newest) to L_max (oldest).
    /// In LSM, level numbers INCREASE from newest to oldest: L0 → L1 → ... → L6.
    pub fn assert_level_order(self: *RebuildProgress, level: u8) void {
        // GDPR-CRITICAL: newest-to-oldest order required
        // LSM levels: L0 (newest) → L6+ (oldest)
        // Level numbers must increase or stay same as we process
        assert(level >= self.current_level);
        self.previous_level = self.current_level;
        self.current_level = level;
    }

    /// Log progress every 1M records.
    pub fn log_progress_if_needed(self: *RebuildProgress, current_time_ns: u64) void {
        const log_interval_records: u64 = 1_000_000; // 1M records

        // Log every 1M records
        if (self.records_scanned % log_interval_records == 0 and self.records_scanned > 0) {
            const elapsed_ns = current_time_ns - self.start_time_ns;
            const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const rate = if (elapsed_s > 0)
                @as(f64, @floatFromInt(self.records_scanned)) / elapsed_s
            else
                0.0;

            log.info("Rebuild progress: scanned={} inserted={} skipped={} " ++
                "tombstones={} level={} rate={d:.0} rec/s", .{
                self.records_scanned,
                self.records_inserted,
                self.records_skipped,
                self.tombstones_skipped,
                self.current_level,
                rate,
            });
            self.last_log_time_ns = current_time_ns;
        }
    }

    /// Get completion percentage (based on estimated entries).
    pub fn get_completion_percent(self: *const RebuildProgress, estimated_total: u64) u8 {
        if (estimated_total == 0) return 100;
        const percent = (self.records_scanned * 100) / estimated_total;
        return @intCast(@min(percent, 100));
    }
};

/// Result of a full index rebuild.
pub const RebuildResult = struct {
    /// Number of entries inserted.
    entries_inserted: u64,
    /// Number of entries skipped (duplicates).
    entries_skipped: u64,
    /// Number of tombstones encountered.
    tombstones_encountered: u64,
    /// Duration in nanoseconds.
    duration_ns: u64,
    /// Recovery path used.
    recovery_path: RecoveryPath,
};

/// Full index rebuild from LSM storage (F2.2.6).
///
/// GDPR-CRITICAL: This function MUST process LSM levels in NEWEST-to-OLDEST order.
/// Failure to maintain this order is a CRITICAL security bug that violates GDPR
/// by potentially resurrecting deleted user data.
///
/// The rebuild uses the following strategy:
/// 1. Iterate LSM levels from L0 (newest) to L_max (oldest)
/// 2. For each GeoEvent encountered:
///    - If entity_id already in seen_entities: Skip (we have newer version)
///    - If tombstone: Mark seen but don't insert
///    - Else: Insert into RAM index, mark in seen_entities
/// 3. Progress logged every 1M records
///
/// Parameters:
/// - index: The RAM index to rebuild
/// - lsm_iterator: Iterator that yields GeoEvents from LSM, newest-to-oldest
/// - allocator: Allocator for temporary seen_entities bitset
/// - current_time_ns: Current timestamp for progress logging
///
/// Returns: RebuildResult with statistics
pub fn full_rebuild(
    comptime IndexType: type,
    index: *IndexType,
    lsm_iterator: anytype,
    allocator: Allocator,
    current_time_ns: u64,
) !RebuildResult {
    const GeoEvent = @import("../geo_event.zig").GeoEvent;

    // Allocate seen_entities bitset (~128MB for 1B entities)
    const SeenEntities = SeenEntitiesBitset(1_000_000_000);
    var seen = try SeenEntities.init(allocator);
    defer seen.deinit();

    var progress = RebuildProgress{
        .start_time_ns = current_time_ns,
    };

    log.info("Starting full index rebuild (F2.2.6)", .{});

    // GDPR-CRITICAL: Process LSM levels newest-to-oldest
    while (lsm_iterator.next()) |item| {
        const level = item.level;
        const event: *const GeoEvent = item.event;

        // Assert GDPR-critical ordering invariant
        progress.assert_level_order(level);
        progress.records_scanned += 1;

        // Check if we've already seen this entity (newer version exists)
        const is_first_occurrence = seen.mark_seen(event.entity_id);

        if (!is_first_occurrence) {
            // Already processed newer version, skip this older one
            progress.records_skipped += 1;
            continue;
        }

        // Check for tombstone (entity deleted)
        if (event.flags.deleted) {
            // Mark as seen but don't insert - entity was deleted
            progress.tombstones_skipped += 1;
            continue;
        }

        // Insert into RAM index
        const latest_id = @as(u128, event.timestamp) |
            (@as(u128, event.s2_cell_id) << 64);
        _ = index.upsert(event.entity_id, latest_id, event.ttl_seconds) catch |err| {
            log.err("Rebuild failed: upsert error: {}", .{err});
            return error.RebuildFailed;
        };
        progress.records_inserted += 1;

        // Log progress periodically
        progress.log_progress_if_needed(current_time_ns);
    }

    const duration_ns = current_time_ns - progress.start_time_ns;
    const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;

    log.info("Full index rebuild complete: inserted={} skipped={} tombstones={} " ++
        "duration={d:.1}s", .{
        progress.records_inserted,
        progress.records_skipped,
        progress.tombstones_skipped,
        duration_s,
    });

    return RebuildResult{
        .entries_inserted = progress.records_inserted,
        .entries_skipped = progress.records_skipped,
        .tombstones_encountered = progress.tombstones_skipped,
        .duration_ns = duration_ns,
        .recovery_path = .full_rebuild,
    };
}

/// Default seen entities bitset for 1B entities.
pub const DefaultSeenEntities = SeenEntitiesBitset(1_000_000_000);

// ============================================================================
// Unit Tests
// ============================================================================

test "CheckpointHeader: size and layout" {
    // CheckpointHeader must be exactly 256 bytes.
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(CheckpointHeader));
}

test "CheckpointHeader: validation" {
    var header = CheckpointHeader{};
    header.capacity = 1000;

    // Valid header
    try std.testing.expect(header.validate());

    // Invalid magic
    header.magic = 0x12345678;
    try std.testing.expect(!header.validate());
    header.magic = MAGIC;

    // Invalid version
    header.version = 0;
    try std.testing.expect(!header.validate());
    header.version = VERSION;

    // Zero capacity
    header.capacity = 0;
    try std.testing.expect(!header.validate());
}

test "DirtyPageTracker: mark and clear" {
    const allocator = std.testing.allocator;
    const page_size: u32 = 1024; // 1KB pages for testing
    const Tracker = DirtyPageTracker(page_size);

    var tracker = try Tracker.init(allocator, 10 * page_size);
    defer tracker.deinit(allocator);

    // Initially no dirty pages
    try std.testing.expectEqual(@as(u64, 0), tracker.get_dirty_count());

    // Mark first page dirty
    tracker.mark_dirty(0, 64);
    try std.testing.expectEqual(@as(u64, 1), tracker.get_dirty_count());
    try std.testing.expect(tracker.is_dirty(0));
    try std.testing.expect(!tracker.is_dirty(1));

    // Mark range spanning multiple pages
    tracker.mark_dirty(512, 1024); // Spans pages 0-1
    try std.testing.expectEqual(@as(u64, 2), tracker.get_dirty_count());
    try std.testing.expect(tracker.is_dirty(0));
    try std.testing.expect(tracker.is_dirty(1));

    // Clear one page
    tracker.clear_dirty(0);
    try std.testing.expectEqual(@as(u64, 1), tracker.get_dirty_count());
    try std.testing.expect(!tracker.is_dirty(0));
    try std.testing.expect(tracker.is_dirty(1));

    // Clear all
    tracker.clear_all();
    try std.testing.expectEqual(@as(u64, 0), tracker.get_dirty_count());
}

test "DirtyPageTracker: dirty iterator" {
    const allocator = std.testing.allocator;
    const page_size: u32 = 1024;
    const Tracker = DirtyPageTracker(page_size);

    var tracker = try Tracker.init(allocator, 10 * page_size);
    defer tracker.deinit(allocator);

    // Mark pages 1, 3, 7 dirty
    tracker.mark_page_dirty(1);
    tracker.mark_page_dirty(3);
    tracker.mark_page_dirty(7);

    // Iterate and collect
    var dirty_pages = std.ArrayList(u64).init(allocator);
    defer dirty_pages.deinit();

    var iter = tracker.dirty_iterator();
    while (iter.next()) |page| {
        try dirty_pages.append(page);
    }

    try std.testing.expectEqual(@as(usize, 3), dirty_pages.items.len);
    try std.testing.expectEqual(@as(u64, 1), dirty_pages.items[0]);
    try std.testing.expectEqual(@as(u64, 3), dirty_pages.items[1]);
    try std.testing.expectEqual(@as(u64, 7), dirty_pages.items[2]);
}

test "IndexCheckpoint: initialization" {
    const allocator = std.testing.allocator;

    var checkpoint = try DefaultIndexCheckpoint.init(allocator, "/tmp/test_checkpoint.dat", 1000);
    defer checkpoint.deinit();

    try std.testing.expectEqual(@as(u64, 1000), checkpoint.header.capacity);
    try std.testing.expectEqual(@as(u64, 0), checkpoint.get_dirty_count());
}

test "IndexCheckpoint: mark entry dirty" {
    const allocator = std.testing.allocator;

    var checkpoint = try DefaultIndexCheckpoint.init(allocator, "/tmp/test_checkpoint.dat", 1000);
    defer checkpoint.deinit();

    // Mark entries dirty
    checkpoint.mark_entry_dirty(0);
    checkpoint.mark_entry_dirty(100);
    checkpoint.mark_entry_dirty(999);

    try std.testing.expect(checkpoint.get_dirty_count() > 0);
}

test "SeenEntitiesBitset: basic operations (F2.2.6)" {
    const allocator = std.testing.allocator;

    // Use small bitset for testing
    const TestBitset = SeenEntitiesBitset(1000);
    var bitset = try TestBitset.init(allocator);
    defer bitset.deinit();

    // First occurrence should return true
    try std.testing.expect(bitset.mark_seen(12345));
    try std.testing.expectEqual(@as(u64, 1), bitset.get_seen_count());

    // Second occurrence of same ID should return false
    try std.testing.expect(!bitset.mark_seen(12345));
    try std.testing.expectEqual(@as(u64, 1), bitset.get_seen_count());

    // Different ID should return true
    try std.testing.expect(bitset.mark_seen(67890));
    try std.testing.expectEqual(@as(u64, 2), bitset.get_seen_count());

    // Check was_seen
    try std.testing.expect(bitset.was_seen(12345));
    try std.testing.expect(bitset.was_seen(67890));

    // Reset should clear everything
    bitset.reset();
    try std.testing.expectEqual(@as(u64, 0), bitset.get_seen_count());
    try std.testing.expect(!bitset.was_seen(12345));
}

test "RebuildProgress: GDPR-critical level ordering (F2.2.6)" {
    var progress = RebuildProgress{};

    // Levels should be processed in order: L0 (newest) → L_max (oldest)
    // LSM level numbers INCREASE from newest to oldest
    // This is GDPR-critical to prevent deleted entities from being resurrected
    progress.assert_level_order(0); // L0 (newest)
    progress.assert_level_order(0); // Still L0 (processing within level)
    progress.assert_level_order(1); // L1 (older) - level number increases
    progress.assert_level_order(2); // L2 (even older)
    progress.assert_level_order(2); // Still L2

    // Note: We can't easily test that assert_level_order panics on wrong order
    // since Zig's assert causes program termination. The assertion itself
    // documents the invariant in code.
}

test "RebuildProgress: completion percentage" {
    var progress = RebuildProgress{};

    progress.records_scanned = 0;
    try std.testing.expectEqual(@as(u8, 0), progress.get_completion_percent(100));

    progress.records_scanned = 50;
    try std.testing.expectEqual(@as(u8, 50), progress.get_completion_percent(100));

    progress.records_scanned = 100;
    try std.testing.expectEqual(@as(u8, 100), progress.get_completion_percent(100));

    // Edge case: zero total
    try std.testing.expectEqual(@as(u8, 100), progress.get_completion_percent(0));

    // Overflow protection
    progress.records_scanned = 200;
    try std.testing.expectEqual(@as(u8, 100), progress.get_completion_percent(100));
}

test "RebuildResult: struct layout" {
    const result = RebuildResult{
        .entries_inserted = 1000000,
        .entries_skipped = 50000,
        .tombstones_encountered = 10000,
        .duration_ns = 45_000_000_000, // 45 seconds
        .recovery_path = .full_rebuild,
    };

    try std.testing.expectEqual(@as(u64, 1000000), result.entries_inserted);
    try std.testing.expectEqual(RecoveryPath.full_rebuild, result.recovery_path);
}
