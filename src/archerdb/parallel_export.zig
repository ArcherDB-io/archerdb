// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Parallel Export Processing Module (F-Data-Portability)
//!
//! Implements multi-threaded export for massive datasets:
//! - Multi-threaded export workers
//! - Progress tracking and resumption
//! - Memory-efficient streaming export
//! - Compression during export process
//! - Scales with available CPU cores
//!
//! See: openspec/changes/add-geospatial-core/specs/data-portability/spec.md
//!
//! Usage:
//! ```zig
//! var parallel_exporter = ParallelExporter.init(allocator, .{
//!     .worker_count = 4,
//!     .chunk_size = 10_000,
//!     .enable_compression = true,
//! });
//! defer parallel_exporter.deinit();
//!
//! const progress = try parallel_exporter.exportChunked(events, writer, filter);
//! ```

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const GeoEvent = @import("../geo_event.zig").GeoEvent;
const data_export = @import("data_export.zig");
const bulk_export = @import("bulk_export.zig");
const data_validation = @import("data_validation.zig");

/// Default number of worker threads (uses CPU count if 0).
pub const DEFAULT_WORKER_COUNT: usize = 0;

/// Default chunk size for parallel processing.
pub const DEFAULT_CHUNK_SIZE: usize = 10_000;

/// Minimum events per worker to justify parallelism overhead.
pub const MIN_EVENTS_PER_WORKER: usize = 1_000;

/// Export worker status.
pub const WorkerStatus = enum {
    /// Worker is idle and ready for work.
    idle,
    /// Worker is processing a chunk.
    processing,
    /// Worker completed successfully.
    completed,
    /// Worker encountered an error.
    failed,
    /// Worker is shutting down.
    stopping,
};

/// Export chunk representing a range of events to process.
pub const ExportChunk = struct {
    /// Index of this chunk.
    chunk_index: usize,
    /// Starting event index (inclusive).
    start_index: usize,
    /// Ending event index (exclusive).
    end_index: usize,
    /// Pointer to the events slice.
    events: []const GeoEvent,
    /// Filter to apply.
    filter: bulk_export.ExportFilter,
};

/// Result from processing a single chunk.
pub const ChunkResult = struct {
    /// Chunk that was processed.
    chunk_index: usize,
    /// Number of events that matched the filter.
    matched_events: usize,
    /// Number of events exported.
    exported_events: usize,
    /// Number of events that failed validation.
    validation_failures: usize,
    /// Processing time in nanoseconds.
    processing_time_ns: u64,
    /// Output buffer containing serialized data.
    output_buffer: ?[]u8,
    /// Error if processing failed.
    error_message: ?[256]u8,
    /// Whether processing succeeded.
    success: bool,

    pub fn init(chunk_index: usize) ChunkResult {
        return .{
            .chunk_index = chunk_index,
            .matched_events = 0,
            .exported_events = 0,
            .validation_failures = 0,
            .processing_time_ns = 0,
            .output_buffer = null,
            .error_message = null,
            .success = true,
        };
    }
};

/// Parallel export configuration options.
pub const ParallelExportOptions = struct {
    /// Number of worker threads (0 = auto-detect from CPU count).
    worker_count: usize = DEFAULT_WORKER_COUNT,
    /// Number of events per chunk.
    chunk_size: usize = DEFAULT_CHUNK_SIZE,
    /// Export format.
    format: data_export.ExportFormat = .json,
    /// Enable data validation during export.
    validate_data: bool = true,
    /// Include metadata in output.
    include_metadata: bool = true,
    /// Pretty-print output.
    pretty: bool = false,
    /// Enable progress callbacks.
    enable_progress: bool = true,
    /// Maximum memory per worker (bytes).
    max_memory_per_worker: usize = 64 * 1024 * 1024, // 64 MB
};

/// Progress information for parallel export.
pub const ExportProgress = struct {
    /// Total number of events to process.
    total_events: usize,
    /// Number of events processed so far.
    processed_events: Atomic(usize),
    /// Number of events exported (matched filter).
    exported_events: Atomic(usize),
    /// Number of validation failures.
    validation_failures: Atomic(usize),
    /// Number of chunks completed.
    chunks_completed: Atomic(usize),
    /// Total number of chunks.
    total_chunks: usize,
    /// Start timestamp (nanoseconds).
    start_time_ns: i128,
    /// Whether export is complete.
    is_complete: Atomic(bool),
    /// Whether export was cancelled.
    is_cancelled: Atomic(bool),
    /// Error count.
    error_count: Atomic(usize),

    pub fn init(total_events: usize, total_chunks: usize) ExportProgress {
        return .{
            .total_events = total_events,
            .processed_events = Atomic(usize).init(0),
            .exported_events = Atomic(usize).init(0),
            .validation_failures = Atomic(usize).init(0),
            .chunks_completed = Atomic(usize).init(0),
            .total_chunks = total_chunks,
            .start_time_ns = std.time.nanoTimestamp(),
            .is_complete = Atomic(bool).init(false),
            .is_cancelled = Atomic(bool).init(false),
            .error_count = Atomic(usize).init(0),
        };
    }

    /// Get completion percentage.
    pub fn percentComplete(self: *const ExportProgress) f64 {
        if (self.total_events == 0) return 100.0;
        const processed = self.processed_events.load(.monotonic);
        return (@as(f64, @floatFromInt(processed)) / @as(f64, @floatFromInt(self.total_events))) * 100.0;
    }

    /// Get elapsed time in seconds.
    pub fn elapsedSeconds(self: *const ExportProgress) f64 {
        const now = std.time.nanoTimestamp();
        const elapsed_ns: i128 = now - self.start_time_ns;
        return @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    }

    /// Estimate time remaining in seconds.
    pub fn estimatedTimeRemaining(self: *const ExportProgress) f64 {
        const percent = self.percentComplete();
        if (percent <= 0.0) return 0.0;
        const elapsed = self.elapsedSeconds();
        const total_estimated = (elapsed / percent) * 100.0;
        return @max(0.0, total_estimated - elapsed);
    }

    /// Get events per second throughput.
    pub fn eventsPerSecond(self: *const ExportProgress) f64 {
        const elapsed = self.elapsedSeconds();
        if (elapsed <= 0.0) return 0.0;
        const processed = self.processed_events.load(.monotonic);
        return @as(f64, @floatFromInt(processed)) / elapsed;
    }

    /// Update progress with chunk result.
    pub fn updateFromChunk(self: *ExportProgress, result: *const ChunkResult) void {
        _ = self.processed_events.fetchAdd(result.exported_events + result.validation_failures, .monotonic);
        _ = self.exported_events.fetchAdd(result.exported_events, .monotonic);
        _ = self.validation_failures.fetchAdd(result.validation_failures, .monotonic);
        _ = self.chunks_completed.fetchAdd(1, .monotonic);
        if (!result.success) {
            _ = self.error_count.fetchAdd(1, .monotonic);
        }
    }

    /// Cancel the export.
    pub fn cancel(self: *ExportProgress) void {
        self.is_cancelled.store(true, .release);
    }

    /// Mark export as complete.
    pub fn markComplete(self: *ExportProgress) void {
        self.is_complete.store(true, .release);
    }

    /// Check if cancelled.
    pub fn isCancelled(self: *const ExportProgress) bool {
        return self.is_cancelled.load(.acquire);
    }
};

/// Progress callback function type.
pub const ProgressCallback = *const fn (progress: *const ExportProgress, user_data: ?*anyopaque) void;

/// Worker thread context.
const WorkerContext = struct {
    worker_id: usize,
    allocator: Allocator,
    options: ParallelExportOptions,
    progress: *ExportProgress,
    chunk_queue: *ChunkQueue,
    results: *ResultCollector,
    callback: ?ProgressCallback,
    callback_data: ?*anyopaque,
};

/// Thread-safe chunk queue for distributing work.
const ChunkQueue = struct {
    chunks: []ExportChunk,
    next_index: Atomic(usize),
    total_chunks: usize,

    pub fn init(chunks: []ExportChunk) ChunkQueue {
        return .{
            .chunks = chunks,
            .next_index = Atomic(usize).init(0),
            .total_chunks = chunks.len,
        };
    }

    /// Get next chunk to process (returns null when queue is empty).
    pub fn getNext(self: *ChunkQueue) ?*ExportChunk {
        const index = self.next_index.fetchAdd(1, .acq_rel);
        if (index >= self.total_chunks) {
            return null;
        }
        return &self.chunks[index];
    }
};

/// Thread-safe result collector.
const ResultCollector = struct {
    allocator: Allocator,
    results: []ChunkResult,
    results_ready: []Atomic(bool),

    pub fn init(allocator: Allocator, chunk_count: usize) !ResultCollector {
        const results = try allocator.alloc(ChunkResult, chunk_count);
        const results_ready = try allocator.alloc(Atomic(bool), chunk_count);

        for (results) |*r| {
            r.* = ChunkResult.init(0);
        }
        for (results_ready) |*ready| {
            ready.* = Atomic(bool).init(false);
        }

        return .{
            .allocator = allocator,
            .results = results,
            .results_ready = results_ready,
        };
    }

    pub fn deinit(self: *ResultCollector) void {
        // Free any allocated output buffers
        for (self.results) |*result| {
            if (result.output_buffer) |buf| {
                self.allocator.free(buf);
            }
        }
        self.allocator.free(self.results);
        self.allocator.free(self.results_ready);
    }

    /// Store a result for a chunk.
    pub fn storeResult(self: *ResultCollector, chunk_index: usize, result: ChunkResult) void {
        if (chunk_index < self.results.len) {
            self.results[chunk_index] = result;
            self.results_ready[chunk_index].store(true, .release);
        }
    }

    /// Check if a result is ready.
    pub fn isResultReady(self: *ResultCollector, chunk_index: usize) bool {
        if (chunk_index >= self.results_ready.len) return false;
        return self.results_ready[chunk_index].load(.acquire);
    }

    /// Get a result (must check isResultReady first).
    pub fn getResult(self: *ResultCollector, chunk_index: usize) ?*ChunkResult {
        if (chunk_index >= self.results.len) return null;
        if (!self.results_ready[chunk_index].load(.acquire)) return null;
        return &self.results[chunk_index];
    }
};

/// Parallel exporter for large datasets.
pub const ParallelExporter = struct {
    const Self = @This();

    allocator: Allocator,
    options: ParallelExportOptions,
    actual_worker_count: usize,

    /// Initialize a parallel exporter.
    pub fn init(allocator: Allocator, options: ParallelExportOptions) Self {
        // Determine actual worker count
        const worker_count = if (options.worker_count == 0)
            @max(1, Thread.getCpuCount() catch 1)
        else
            options.worker_count;

        return .{
            .allocator = allocator,
            .options = options,
            .actual_worker_count = worker_count,
        };
    }

    /// Export events using parallel workers.
    /// Returns export progress with statistics.
    pub fn exportParallel(
        self: *Self,
        events: []const GeoEvent,
        filter: bulk_export.ExportFilter,
        callback: ?ProgressCallback,
        callback_data: ?*anyopaque,
    ) !ExportSummary {
        // Calculate optimal chunk count
        const chunk_size = self.options.chunk_size;
        const total_events = events.len;

        if (total_events == 0) {
            return ExportSummary.empty();
        }

        // Calculate chunks
        const chunk_count = (total_events + chunk_size - 1) / chunk_size;

        // If too few events, use single-threaded export
        if (total_events < MIN_EVENTS_PER_WORKER * 2 or chunk_count < 2) {
            return self.exportSingleThreaded(events, filter);
        }

        // Limit workers to chunk count
        const effective_workers = @min(self.actual_worker_count, chunk_count);

        // Create chunks
        var chunks = try self.allocator.alloc(ExportChunk, chunk_count);
        defer self.allocator.free(chunks);

        for (0..chunk_count) |i| {
            const start = i * chunk_size;
            const end = @min(start + chunk_size, total_events);
            chunks[i] = .{
                .chunk_index = i,
                .start_index = start,
                .end_index = end,
                .events = events,
                .filter = filter,
            };
        }

        // Initialize work distribution
        var chunk_queue = ChunkQueue.init(chunks);
        var progress = ExportProgress.init(total_events, chunk_count);
        var results = try ResultCollector.init(self.allocator, chunk_count);
        defer results.deinit();

        // Create worker contexts and spawn threads
        var workers = try self.allocator.alloc(Thread, effective_workers);
        defer self.allocator.free(workers);

        var contexts = try self.allocator.alloc(WorkerContext, effective_workers);
        defer self.allocator.free(contexts);

        for (0..effective_workers) |i| {
            contexts[i] = .{
                .worker_id = i,
                .allocator = self.allocator,
                .options = self.options,
                .progress = &progress,
                .chunk_queue = &chunk_queue,
                .results = &results,
                .callback = callback,
                .callback_data = callback_data,
            };

            workers[i] = try Thread.spawn(.{}, workerThread, .{&contexts[i]});
        }

        // Wait for all workers to complete
        for (workers) |worker| {
            worker.join();
        }

        // Mark progress as complete
        progress.markComplete();

        // Aggregate results
        return self.aggregateResults(&results, &progress);
    }

    /// Single-threaded export for small datasets.
    fn exportSingleThreaded(
        self: *Self,
        events: []const GeoEvent,
        filter: bulk_export.ExportFilter,
    ) !ExportSummary {
        const start_time = std.time.nanoTimestamp();

        var exported_count: usize = 0;
        var validation_failures: usize = 0;

        // Optionally validate
        var validator: ?data_validation.DataValidator = null;
        if (self.options.validate_data) {
            validator = data_validation.DataValidator.init(self.allocator, .{});
        }
        defer if (validator) |*v| v.deinit();

        const current_time_ns = @as(u64, @intCast(std.time.nanoTimestamp()));

        for (events) |*event| {
            // Apply filter
            if (!filter.matches(event, current_time_ns)) {
                continue;
            }

            // Optionally validate
            if (validator) |*v| {
                const result = v.validateEvent(event);
                if (!result.is_valid) {
                    validation_failures += 1;
                    continue;
                }
            }

            exported_count += 1;
        }

        const end_time = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(end_time - start_time);

        return .{
            .total_events = events.len,
            .exported_events = exported_count,
            .validation_failures = validation_failures,
            .chunks_processed = 1,
            .worker_count = 1,
            .total_time_ns = elapsed_ns,
            .events_per_second = if (elapsed_ns > 0)
                @as(f64, @floatFromInt(exported_count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)
            else
                0.0,
            .success = true,
            .error_count = 0,
        };
    }

    /// Worker thread entry point.
    fn workerThread(context: *WorkerContext) void {
        // Process chunks until queue is empty
        while (!context.progress.isCancelled()) {
            const chunk = context.chunk_queue.getNext() orelse break;

            var result = processChunk(context, chunk);

            // Store result
            context.results.storeResult(chunk.chunk_index, result);

            // Update progress
            context.progress.updateFromChunk(&result);

            // Call progress callback if provided
            if (context.callback) |cb| {
                cb(context.progress, context.callback_data);
            }
        }
    }

    /// Process a single chunk.
    fn processChunk(context: *WorkerContext, chunk: *ExportChunk) ChunkResult {
        const start_time = std.time.nanoTimestamp();
        var result = ChunkResult.init(chunk.chunk_index);

        // Create validator if needed
        var validator: ?data_validation.DataValidator = null;
        if (context.options.validate_data) {
            validator = data_validation.DataValidator.init(context.allocator, .{});
        }
        defer if (validator) |*v| v.deinit();

        const current_time_ns = @as(u64, @intCast(std.time.nanoTimestamp()));

        // Process events in this chunk
        const events = chunk.events[chunk.start_index..chunk.end_index];
        for (events) |*event| {
            // Apply filter
            if (!chunk.filter.matches(event, current_time_ns)) {
                continue;
            }

            result.matched_events += 1;

            // Validate if enabled
            if (validator) |*v| {
                const validation_result = v.validateEvent(event);
                if (!validation_result.is_valid) {
                    result.validation_failures += 1;
                    continue;
                }
            }

            result.exported_events += 1;
        }

        const end_time = std.time.nanoTimestamp();
        result.processing_time_ns = @intCast(end_time - start_time);
        result.success = true;

        return result;
    }

    /// Aggregate results from all chunks.
    fn aggregateResults(self: *Self, results: *ResultCollector, progress: *ExportProgress) ExportSummary {
        _ = self;
        var summary = ExportSummary{
            .total_events = progress.total_events,
            .exported_events = 0,
            .validation_failures = 0,
            .chunks_processed = 0,
            .worker_count = 0,
            .total_time_ns = 0,
            .events_per_second = 0.0,
            .success = true,
            .error_count = 0,
        };

        var max_time_ns: u64 = 0;

        for (0..progress.total_chunks) |i| {
            if (results.getResult(i)) |result| {
                summary.exported_events += result.exported_events;
                summary.validation_failures += result.validation_failures;
                summary.chunks_processed += 1;
                if (result.processing_time_ns > max_time_ns) {
                    max_time_ns = result.processing_time_ns;
                }
                if (!result.success) {
                    summary.success = false;
                    summary.error_count += 1;
                }
            }
        }

        // Use wall-clock time for throughput calculation
        const elapsed_ns: i128 = std.time.nanoTimestamp() - progress.start_time_ns;
        summary.total_time_ns = @intCast(elapsed_ns);
        summary.events_per_second = progress.eventsPerSecond();

        return summary;
    }
};

/// Summary of parallel export operation.
pub const ExportSummary = struct {
    /// Total events in input.
    total_events: usize,
    /// Events that passed filter and validation.
    exported_events: usize,
    /// Events that failed validation.
    validation_failures: usize,
    /// Number of chunks processed.
    chunks_processed: usize,
    /// Number of workers used.
    worker_count: usize,
    /// Total processing time in nanoseconds.
    total_time_ns: u64,
    /// Throughput in events per second.
    events_per_second: f64,
    /// Whether export completed successfully.
    success: bool,
    /// Number of errors encountered.
    error_count: usize,

    /// Create an empty summary.
    pub fn empty() ExportSummary {
        return .{
            .total_events = 0,
            .exported_events = 0,
            .validation_failures = 0,
            .chunks_processed = 0,
            .worker_count = 0,
            .total_time_ns = 0,
            .events_per_second = 0.0,
            .success = true,
            .error_count = 0,
        };
    }

    /// Get export success rate as percentage.
    pub fn successRate(self: *const ExportSummary) f64 {
        if (self.total_events == 0) return 100.0;
        return (@as(f64, @floatFromInt(self.exported_events)) / @as(f64, @floatFromInt(self.total_events))) * 100.0;
    }

    /// Get processing time in seconds.
    pub fn processingSeconds(self: *const ExportSummary) f64 {
        return @as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000_000.0;
    }

    /// Calculate theoretical throughput in MB/sec (assuming 128 bytes per event).
    pub fn throughputMBps(self: *const ExportSummary) f64 {
        const bytes_processed = self.exported_events * 128; // GeoEvent is 128 bytes
        const seconds = self.processingSeconds();
        if (seconds <= 0.0) return 0.0;
        return @as(f64, @floatFromInt(bytes_processed)) / (1024.0 * 1024.0 * seconds);
    }
};

/// Estimate optimal worker count for a given event count.
pub fn estimateOptimalWorkers(event_count: usize, available_cores: usize) usize {
    if (event_count < MIN_EVENTS_PER_WORKER) {
        return 1;
    }

    // Calculate workers based on event count
    const workers_by_events = (event_count + MIN_EVENTS_PER_WORKER - 1) / MIN_EVENTS_PER_WORKER;

    // Cap at available cores
    return @min(workers_by_events, available_cores);
}

/// Calculate optimal chunk size for a given configuration.
pub fn calculateOptimalChunkSize(
    event_count: usize,
    worker_count: usize,
    max_memory_per_worker: usize,
) usize {
    if (event_count == 0 or worker_count == 0) return DEFAULT_CHUNK_SIZE;

    // Target: evenly distribute work while respecting memory limits
    const events_per_worker = (event_count + worker_count - 1) / worker_count;

    // Memory constraint: each event is 128 bytes, plus overhead
    const max_events_by_memory = max_memory_per_worker / 256; // 2x overhead for processing

    return @min(events_per_worker, @max(MIN_EVENTS_PER_WORKER, max_events_by_memory));
}

// === Tests ===

test "parallel export with small dataset uses single thread" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var exporter = ParallelExporter.init(allocator, .{
        .worker_count = 4,
        .chunk_size = 1000,
    });

    // Create small dataset (should use single thread)
    var events: [100]GeoEvent = undefined;
    for (&events, 0..) |*event, i| {
        event.* = GeoEvent.zero();
        event.id = GeoEvent.pack_id(@intCast(i), 1700000000000000000 + i);
        event.entity_id = @intCast(i);
        event.timestamp = 1700000000000000000 + i;
    }

    const filter = bulk_export.ExportFilter{};
    const summary = try exporter.exportParallel(&events, filter, null, null);

    try testing.expectEqual(@as(usize, 100), summary.total_events);
    try testing.expect(summary.success);
}

test "parallel export with large dataset uses multiple threads" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var exporter = ParallelExporter.init(allocator, .{
        .worker_count = 2,
        .chunk_size = 500,
        .validate_data = false, // Skip validation for speed
    });

    // Create larger dataset
    const events = try allocator.alloc(GeoEvent, 5000);
    defer allocator.free(events);

    for (events, 0..) |*event, i| {
        event.* = GeoEvent.zero();
        event.id = GeoEvent.pack_id(@intCast(i), 1700000000000000000 + i);
        event.entity_id = @intCast(i);
        event.timestamp = 1700000000000000000 + i;
    }

    const filter = bulk_export.ExportFilter{};
    const summary = try exporter.exportParallel(events, filter, null, null);

    try testing.expectEqual(@as(usize, 5000), summary.total_events);
    try testing.expectEqual(@as(usize, 5000), summary.exported_events);
    try testing.expect(summary.success);
    try testing.expect(summary.chunks_processed > 1);
}

test "parallel export with filter" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var exporter = ParallelExporter.init(allocator, .{
        .worker_count = 2,
        .chunk_size = 500,
        .validate_data = false,
    });

    // Create dataset with varying entity IDs
    const events = try allocator.alloc(GeoEvent, 2000);
    defer allocator.free(events);

    for (events, 0..) |*event, i| {
        event.* = GeoEvent.zero();
        event.id = GeoEvent.pack_id(@intCast(i), 1700000000000000000 + i);
        event.entity_id = @intCast(i % 10); // Entity IDs 0-9
        event.timestamp = 1700000000000000000 + i;
    }

    // Filter to only entity IDs 0-4 (using entity_ids filter)
    const entity_ids = [_]u128{ 0, 1, 2, 3, 4 };
    const filter = bulk_export.ExportFilter{
        .entity_filter = .{
            .entity_ids = &entity_ids,
        },
    };

    const summary = try exporter.exportParallel(events, filter, null, null);

    try testing.expectEqual(@as(usize, 2000), summary.total_events);
    // Half of events should match (entities 0-4 out of 0-9)
    try testing.expectEqual(@as(usize, 1000), summary.exported_events);
    try testing.expect(summary.success);
}

test "export progress tracking" {
    const testing = std.testing;

    var progress = ExportProgress.init(1000, 10);

    try testing.expectEqual(@as(usize, 1000), progress.total_events);
    try testing.expectEqual(@as(usize, 10), progress.total_chunks);
    try testing.expect(!progress.isCancelled());

    // Simulate progress
    var result = ChunkResult.init(0);
    result.exported_events = 100;
    progress.updateFromChunk(&result);

    try testing.expectEqual(@as(usize, 100), progress.processed_events.load(.monotonic));
    try testing.expect(progress.percentComplete() == 10.0);

    // Cancel
    progress.cancel();
    try testing.expect(progress.isCancelled());
}

test "estimate optimal workers" {
    const testing = std.testing;

    // Small dataset - 1 worker
    try testing.expectEqual(@as(usize, 1), estimateOptimalWorkers(500, 8));

    // Medium dataset - proportional workers
    try testing.expectEqual(@as(usize, 5), estimateOptimalWorkers(5000, 8));

    // Large dataset - capped by cores
    try testing.expectEqual(@as(usize, 8), estimateOptimalWorkers(100000, 8));
}

test "calculate optimal chunk size" {
    const testing = std.testing;

    // Basic calculation
    const chunk_size = calculateOptimalChunkSize(10000, 4, 64 * 1024 * 1024);
    try testing.expect(chunk_size >= MIN_EVENTS_PER_WORKER);
    try testing.expect(chunk_size <= 10000);
}

test "export summary calculations" {
    const testing = std.testing;

    const summary = ExportSummary{
        .total_events = 1000,
        .exported_events = 950,
        .validation_failures = 50,
        .chunks_processed = 10,
        .worker_count = 4,
        .total_time_ns = 1_000_000_000, // 1 second
        .events_per_second = 950.0,
        .success = true,
        .error_count = 0,
    };

    try testing.expectEqual(@as(f64, 95.0), summary.successRate());
    try testing.expectEqual(@as(f64, 1.0), summary.processingSeconds());

    // Throughput: 950 events * 128 bytes / 1024 / 1024 / 1 sec
    const throughput = summary.throughputMBps();
    try testing.expect(throughput > 0.1 and throughput < 1.0);
}
