// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! ETL Tool Integration Module (F-Data-Portability)
//!
//! Provides integration infrastructure for ETL tools and analytics platforms:
//! - Webhook notifications for data changes
//! - Bulk loading interfaces
//! - Metadata API for schema discovery
//! - Connector interfaces for Spark/Kafka/Elasticsearch
//! - Query result streaming
//!
//! See: openspec/changes/add-geospatial-core/specs/data-portability/spec.md
//!
//! Usage:
//! ```zig
//! var registry = WebhookRegistry.init(allocator);
//! defer registry.deinit();
//!
//! try registry.register(.{
//!     .url = "https://example.com/webhook",
//!     .events = .{ .insert = true, .update = true },
//! });
//!
//! // Notify on data changes
//! try registry.notify(.insert, event);
//! ```

const std = @import("std");
const stdx = @import("stdx");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Current API version for schema discovery.
pub const API_VERSION = "1.0.0";

/// Schema version for GeoEvent structure.
pub const SCHEMA_VERSION = "1.0.0";

// ============================================================================
// Webhook Notifications
// ============================================================================

/// Webhook event types.
pub const WebhookEventType = enum {
    /// New event inserted.
    insert,
    /// Event updated.
    update,
    /// Event deleted.
    delete,
    /// Bulk operation completed.
    bulk_complete,
    /// Schema changed.
    schema_change,
    /// System health alert.
    health_alert,
};

/// Webhook event filters.
pub const WebhookEventFilter = struct {
    /// Notify on insert events.
    insert: bool = true,
    /// Notify on update events.
    update: bool = true,
    /// Notify on delete events.
    delete: bool = true,
    /// Notify on bulk completion.
    bulk_complete: bool = false,
    /// Notify on schema changes.
    schema_change: bool = false,
    /// Notify on health alerts.
    health_alert: bool = false,

    /// Check if an event type matches the filter.
    pub fn matches(self: WebhookEventFilter, event_type: WebhookEventType) bool {
        return switch (event_type) {
            .insert => self.insert,
            .update => self.update,
            .delete => self.delete,
            .bulk_complete => self.bulk_complete,
            .schema_change => self.schema_change,
            .health_alert => self.health_alert,
        };
    }

    /// Filter for all events.
    pub fn all() WebhookEventFilter {
        return .{
            .insert = true,
            .update = true,
            .delete = true,
            .bulk_complete = true,
            .schema_change = true,
            .health_alert = true,
        };
    }

    /// Filter for data events only.
    pub fn dataOnly() WebhookEventFilter {
        return .{
            .insert = true,
            .update = true,
            .delete = true,
            .bulk_complete = false,
            .schema_change = false,
            .health_alert = false,
        };
    }
};

/// Webhook configuration.
pub const WebhookConfig = struct {
    /// Webhook endpoint URL.
    url: [512]u8 = [_]u8{0} ** 512,
    /// URL length.
    url_len: u16 = 0,
    /// Authentication header (e.g., "Bearer token").
    auth_header: [256]u8 = [_]u8{0} ** 256,
    /// Auth header length.
    auth_header_len: u16 = 0,
    /// Event filter.
    events: WebhookEventFilter = .{},
    /// Entity filter (0 = all entities).
    entity_filter: u128 = 0,
    /// Group filter (0 = all groups).
    group_filter: u64 = 0,
    /// Maximum retries on failure.
    max_retries: u8 = 3,
    /// Retry delay in milliseconds.
    retry_delay_ms: u32 = 1000,
    /// Timeout in milliseconds.
    timeout_ms: u32 = 30000,
    /// Whether webhook is active.
    active: bool = true,

    /// Set URL.
    pub fn setUrl(self: *WebhookConfig, url: []const u8) void {
        const len = @min(url.len, 511);
        stdx.copy_disjoint(.exact, u8, self.url[0..len], url[0..len]);
        self.url_len = @intCast(len);
    }

    /// Get URL as slice.
    pub fn getUrl(self: *const WebhookConfig) []const u8 {
        return self.url[0..self.url_len];
    }

    /// Set authentication header.
    pub fn setAuthHeader(self: *WebhookConfig, header: []const u8) void {
        const len = @min(header.len, 255);
        stdx.copy_disjoint(.exact, u8, self.auth_header[0..len], header[0..len]);
        self.auth_header_len = @intCast(len);
    }

    /// Get auth header as slice.
    pub fn getAuthHeader(self: *const WebhookConfig) []const u8 {
        return self.auth_header[0..self.auth_header_len];
    }
};

/// Webhook notification payload.
pub const WebhookPayload = struct {
    /// Event type.
    event_type: WebhookEventType,
    /// Timestamp of the event.
    timestamp_ns: u64,
    /// Entity ID (if applicable).
    entity_id: ?u128,
    /// Event data (JSON serialized).
    data: ?[]const u8,
    /// Batch size (for bulk events).
    batch_size: ?usize,
    /// Correlation ID for tracking.
    correlation_id: [36]u8 = [_]u8{0} ** 36,
    /// Correlation ID length.
    correlation_id_len: u8 = 0,

    /// Set correlation ID.
    pub fn setCorrelationId(self: *WebhookPayload, id: []const u8) void {
        const len = @min(id.len, 35);
        stdx.copy_disjoint(.exact, u8, self.correlation_id[0..len], id[0..len]);
        self.correlation_id_len = @intCast(len);
    }
};

/// Webhook delivery status.
pub const DeliveryStatus = enum {
    /// Successfully delivered.
    delivered,
    /// Pending retry.
    pending,
    /// Failed after all retries.
    failed,
    /// Webhook disabled.
    disabled,
};

/// Result of webhook delivery attempt.
pub const DeliveryResult = struct {
    /// Delivery status.
    status: DeliveryStatus,
    /// HTTP status code (if delivered).
    http_status: ?u16,
    /// Retry count.
    retry_count: u8,
    /// Error message (if failed).
    error_message: ?[256]u8 = null,
    /// Delivery time in nanoseconds.
    delivery_time_ns: u64,
};

/// Webhook registry for managing webhook subscriptions.
pub const WebhookRegistry = struct {
    const MAX_WEBHOOKS = 100;

    allocator: Allocator,
    webhooks: std.ArrayList(WebhookConfig),

    /// Initialize webhook registry.
    pub fn init(allocator: Allocator) WebhookRegistry {
        return .{
            .allocator = allocator,
            .webhooks = std.ArrayList(WebhookConfig).init(allocator),
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *WebhookRegistry) void {
        self.webhooks.deinit();
    }

    /// Register a new webhook.
    pub fn register(self: *WebhookRegistry, config: WebhookConfig) !usize {
        if (self.webhooks.items.len >= MAX_WEBHOOKS) {
            return error.TooManyWebhooks;
        }
        try self.webhooks.append(config);
        return self.webhooks.items.len - 1;
    }

    /// Unregister a webhook by index.
    pub fn unregister(self: *WebhookRegistry, index: usize) void {
        if (index < self.webhooks.items.len) {
            _ = self.webhooks.orderedRemove(index);
        }
    }

    /// Get webhook count.
    pub fn count(self: *const WebhookRegistry) usize {
        return self.webhooks.items.len;
    }

    /// Get webhooks matching an event type.
    pub fn getMatchingWebhooks(
        self: *const WebhookRegistry,
        event_type: WebhookEventType,
    ) []WebhookConfig {
        // Returns all webhooks that match the event type (caller can filter further)
        var matching = std.ArrayList(WebhookConfig).init(self.allocator);
        for (self.webhooks.items) |webhook| {
            if (webhook.active and webhook.events.matches(event_type)) {
                matching.append(webhook) catch continue;
            }
        }
        return matching.toOwnedSlice() catch &[_]WebhookConfig{};
    }

    /// Create a notification payload for an event.
    pub fn createPayload(
        self: *const WebhookRegistry,
        event_type: WebhookEventType,
        entity_id: ?u128,
        data: ?[]const u8,
    ) WebhookPayload {
        _ = self;
        return .{
            .event_type = event_type,
            .timestamp_ns = @intCast(std.time.nanoTimestamp()),
            .entity_id = entity_id,
            .data = data,
            .batch_size = null,
        };
    }
};

// ============================================================================
// Bulk Loading Interface
// ============================================================================

/// Bulk load operation type.
pub const BulkOperation = enum {
    /// Insert new records.
    insert,
    /// Update existing records.
    upsert,
    /// Replace all data.
    replace,
    /// Delete matching records.
    delete,
};

/// Bulk load options.
pub const BulkLoadOptions = struct {
    /// Operation type.
    operation: BulkOperation = .upsert,
    /// Batch size for processing.
    batch_size: usize = 10_000,
    /// Whether to validate data.
    validate: bool = true,
    /// Whether to skip invalid records.
    skip_invalid: bool = false,
    /// Whether to use parallel processing.
    parallel: bool = true,
    /// Worker count for parallel processing.
    worker_count: usize = 0, // 0 = auto
    /// Transaction mode.
    transaction_mode: TransactionMode = .batch,
    /// Progress callback interval (events).
    progress_interval: usize = 1000,
};

/// Transaction mode for bulk operations.
pub const TransactionMode = enum {
    /// Single transaction for entire load.
    single,
    /// Transaction per batch.
    batch,
    /// No transactions (fastest, least safe).
    none,
};

/// Bulk load progress information.
pub const BulkLoadProgress = struct {
    /// Total records to process.
    total_records: usize,
    /// Records processed so far.
    processed_records: usize,
    /// Records inserted.
    inserted_records: usize,
    /// Records updated.
    updated_records: usize,
    /// Records deleted.
    deleted_records: usize,
    /// Records skipped (validation failures).
    skipped_records: usize,
    /// Current batch number.
    current_batch: usize,
    /// Total batches.
    total_batches: usize,
    /// Start time (nanoseconds).
    start_time_ns: i128,
    /// Current throughput (records/sec).
    throughput: f64,

    /// Calculate completion percentage.
    pub fn percentComplete(self: *const BulkLoadProgress) f64 {
        if (self.total_records == 0) return 100.0;
        const processed = @as(f64, @floatFromInt(self.processed_records));
        const total = @as(f64, @floatFromInt(self.total_records));
        return (processed / total) * 100.0;
    }

    /// Calculate estimated time remaining.
    pub fn estimatedTimeRemainingSeconds(self: *const BulkLoadProgress) f64 {
        if (self.throughput <= 0.0) return 0.0;
        const remaining = self.total_records - self.processed_records;
        return @as(f64, @floatFromInt(remaining)) / self.throughput;
    }
};

/// Result of bulk load operation.
pub const BulkLoadResult = struct {
    /// Whether operation succeeded.
    success: bool,
    /// Progress at completion.
    progress: BulkLoadProgress,
    /// Error message if failed.
    error_message: ?[256]u8 = null,
    /// Duration in nanoseconds.
    duration_ns: u64,
    /// Final throughput (records/sec).
    final_throughput: f64,
};

/// Bulk loader interface for high-throughput data loading.
pub const BulkLoader = struct {
    allocator: Allocator,
    options: BulkLoadOptions,
    progress: BulkLoadProgress,

    /// Initialize bulk loader.
    pub fn init(allocator: Allocator, options: BulkLoadOptions) BulkLoader {
        return .{
            .allocator = allocator,
            .options = options,
            .progress = .{
                .total_records = 0,
                .processed_records = 0,
                .inserted_records = 0,
                .updated_records = 0,
                .deleted_records = 0,
                .skipped_records = 0,
                .current_batch = 0,
                .total_batches = 0,
                .start_time_ns = std.time.nanoTimestamp(),
                .throughput = 0.0,
            },
        };
    }

    /// Prepare for bulk loading.
    pub fn prepare(self: *BulkLoader, total_records: usize) void {
        self.progress.total_records = total_records;
        const divisor = self.options.batch_size;
        self.progress.total_batches = (total_records + divisor - 1) / divisor;
        self.progress.start_time_ns = std.time.nanoTimestamp();
    }

    /// Update progress after processing a batch.
    pub fn updateProgress(
        self: *BulkLoader,
        batch_size: usize,
        inserted: usize,
        updated: usize,
        skipped: usize,
    ) void {
        self.progress.processed_records += batch_size;
        self.progress.inserted_records += inserted;
        self.progress.updated_records += updated;
        self.progress.skipped_records += skipped;
        self.progress.current_batch += 1;

        // Calculate throughput
        const elapsed_ns: i128 = std.time.nanoTimestamp() - self.progress.start_time_ns;
        const elapsed_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        if (elapsed_secs > 0.0) {
            const processed = self.progress.processed_records;
            self.progress.throughput = @as(f64, @floatFromInt(processed)) / elapsed_secs;
        }
    }

    /// Get current progress.
    pub fn getProgress(self: *const BulkLoader) BulkLoadProgress {
        return self.progress;
    }

    /// Complete the bulk load and return result.
    pub fn complete(self: *BulkLoader) BulkLoadResult {
        const elapsed_ns: i128 = std.time.nanoTimestamp() - self.progress.start_time_ns;
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

        return .{
            .success = self.progress.skipped_records == 0 or self.options.skip_invalid,
            .progress = self.progress,
            .duration_ns = @intCast(elapsed_ns),
            .final_throughput = if (elapsed_seconds > 0.0)
                @as(f64, @floatFromInt(self.progress.processed_records)) / elapsed_seconds
            else
                0.0,
        };
    }
};

// ============================================================================
// Metadata API for Schema Discovery
// ============================================================================

/// Field data type.
pub const FieldType = enum {
    /// 128-bit unsigned integer.
    u128_type,
    /// 64-bit unsigned integer.
    u64_type,
    /// 64-bit signed integer.
    i64_type,
    /// 32-bit signed integer.
    i32_type,
    /// 32-bit unsigned integer.
    u32_type,
    /// 16-bit unsigned integer.
    u16_type,
    /// Boolean.
    bool_type,
    /// Byte array.
    bytes_type,
    /// Packed flags.
    flags_type,
};

/// Field descriptor for schema.
pub const FieldDescriptor = struct {
    /// Field name.
    name: [64]u8 = [_]u8{0} ** 64,
    /// Name length.
    name_len: u8 = 0,
    /// Field type.
    field_type: FieldType,
    /// Whether field is nullable.
    nullable: bool,
    /// Whether field is part of primary key.
    primary_key: bool,
    /// Whether field is indexed.
    indexed: bool,
    /// Field description.
    description: [256]u8 = [_]u8{0} ** 256,
    /// Description length.
    description_len: u8 = 0,
    /// Default value (as string).
    default_value: ?[64]u8 = null,
    /// Minimum value (for numeric fields).
    min_value: ?i64 = null,
    /// Maximum value (for numeric fields).
    max_value: ?i64 = null,

    /// Set field name.
    pub fn setName(self: *FieldDescriptor, name: []const u8) void {
        const len = @min(name.len, 63);
        stdx.copy_disjoint(.exact, u8, self.name[0..len], name[0..len]);
        self.name_len = @intCast(len);
    }

    /// Get field name.
    pub fn getName(self: *const FieldDescriptor) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Set description.
    pub fn setDescription(self: *FieldDescriptor, desc: []const u8) void {
        const len = @min(desc.len, 255);
        stdx.copy_disjoint(.exact, u8, self.description[0..len], desc[0..len]);
        self.description_len = @intCast(len);
    }
};

/// Schema descriptor.
pub const SchemaDescriptor = struct {
    /// Schema name.
    name: [64]u8 = [_]u8{0} ** 64,
    /// Name length.
    name_len: u8 = 0,
    /// Schema version.
    version: [16]u8 = [_]u8{0} ** 16,
    /// Version length.
    version_len: u8 = 0,
    /// Number of fields.
    field_count: usize = 0,
    /// Record size in bytes.
    record_size: usize = 128, // GeoEvent is 128 bytes
    /// Whether schema supports soft deletes.
    supports_soft_delete: bool = true,
    /// Whether schema supports TTL.
    supports_ttl: bool = true,

    /// Set schema name.
    pub fn setName(self: *SchemaDescriptor, name: []const u8) void {
        const len = @min(name.len, 63);
        stdx.copy_disjoint(.exact, u8, self.name[0..len], name[0..len]);
        self.name_len = @intCast(len);
    }

    /// Set version.
    pub fn setVersion(self: *SchemaDescriptor, version: []const u8) void {
        const len = @min(version.len, 15);
        stdx.copy_disjoint(.exact, u8, self.version[0..len], version[0..len]);
        self.version_len = @intCast(len);
    }
};

/// Get GeoEvent schema descriptor.
pub fn getGeoEventSchema() SchemaDescriptor {
    var schema = SchemaDescriptor{
        .field_count = 14,
        .record_size = 128,
        .supports_soft_delete = true,
        .supports_ttl = true,
    };
    schema.setName("GeoEvent");
    schema.setVersion(SCHEMA_VERSION);
    return schema;
}

/// Get GeoEvent field descriptors.
pub fn getGeoEventFields() [14]FieldDescriptor {
    var fields: [14]FieldDescriptor = undefined;

    // id field
    fields[0] = FieldDescriptor{
        .field_type = .u128_type,
        .nullable = false,
        .primary_key = true,
        .indexed = true,
    };
    fields[0].setName("id");
    fields[0].setDescription("Composite key: [S2 Cell ID (upper 64) | Timestamp (lower 64)]");

    // entity_id field
    fields[1] = FieldDescriptor{
        .field_type = .u128_type,
        .nullable = false,
        .primary_key = false,
        .indexed = true,
    };
    fields[1].setName("entity_id");
    fields[1].setDescription("UUID identifying the moving entity");

    // correlation_id field
    fields[2] = FieldDescriptor{
        .field_type = .u128_type,
        .nullable = true,
        .primary_key = false,
        .indexed = true,
    };
    fields[2].setName("correlation_id");
    fields[2].setDescription("UUID for trip/session/job correlation");

    // user_data field
    fields[3] = FieldDescriptor{
        .field_type = .u128_type,
        .nullable = true,
        .primary_key = false,
        .indexed = false,
    };
    fields[3].setName("user_data");
    fields[3].setDescription("Opaque application metadata");

    // lat_nano field
    fields[4] = FieldDescriptor{
        .field_type = .i64_type,
        .nullable = false,
        .primary_key = false,
        .indexed = false,
        .min_value = -90_000_000_000,
        .max_value = 90_000_000_000,
    };
    fields[4].setName("lat_nano");
    fields[4].setDescription("Latitude in nanodegrees");

    // lon_nano field
    fields[5] = FieldDescriptor{
        .field_type = .i64_type,
        .nullable = false,
        .primary_key = false,
        .indexed = false,
        .min_value = -180_000_000_000,
        .max_value = 180_000_000_000,
    };
    fields[5].setName("lon_nano");
    fields[5].setDescription("Longitude in nanodegrees");

    // group_id field
    fields[6] = FieldDescriptor{
        .field_type = .u64_type,
        .nullable = true,
        .primary_key = false,
        .indexed = true,
    };
    fields[6].setName("group_id");
    fields[6].setDescription("Fleet/region grouping identifier");

    // timestamp field
    fields[7] = FieldDescriptor{
        .field_type = .u64_type,
        .nullable = false,
        .primary_key = false,
        .indexed = true,
    };
    fields[7].setName("timestamp");
    fields[7].setDescription("Event timestamp in nanoseconds since Unix epoch");

    // altitude_mm field
    fields[8] = FieldDescriptor{
        .field_type = .i32_type,
        .nullable = true,
        .primary_key = false,
        .indexed = false,
    };
    fields[8].setName("altitude_mm");
    fields[8].setDescription("Altitude in millimeters above WGS84 ellipsoid");

    // velocity_mms field
    fields[9] = FieldDescriptor{
        .field_type = .u32_type,
        .nullable = true,
        .primary_key = false,
        .indexed = false,
    };
    fields[9].setName("velocity_mms");
    fields[9].setDescription("Speed in millimeters per second");

    // ttl_seconds field
    fields[10] = FieldDescriptor{
        .field_type = .u32_type,
        .nullable = true,
        .primary_key = false,
        .indexed = false,
    };
    fields[10].setName("ttl_seconds");
    fields[10].setDescription("Time-to-live in seconds (0 = never expires)");

    // accuracy_mm field
    fields[11] = FieldDescriptor{
        .field_type = .u32_type,
        .nullable = true,
        .primary_key = false,
        .indexed = false,
    };
    fields[11].setName("accuracy_mm");
    fields[11].setDescription("GPS accuracy radius in millimeters");

    // heading_cdeg field
    fields[12] = FieldDescriptor{
        .field_type = .u16_type,
        .nullable = true,
        .primary_key = false,
        .indexed = false,
        .min_value = 0,
        .max_value = 36000,
    };
    fields[12].setName("heading_cdeg");
    fields[12].setDescription("Heading in centidegrees (0-36000)");

    // flags field
    fields[13] = FieldDescriptor{
        .field_type = .flags_type,
        .nullable = false,
        .primary_key = false,
        .indexed = false,
    };
    fields[13].setName("flags");
    fields[13].setDescription("Packed status flags");

    return fields;
}

// ============================================================================
// Connector Interfaces
// ============================================================================

/// Connector type.
pub const ConnectorType = enum {
    /// Apache Spark connector.
    spark,
    /// Apache Kafka connector.
    kafka,
    /// Elasticsearch connector.
    elasticsearch,
    /// Generic JDBC connector.
    jdbc,
    /// Generic REST connector.
    rest,
    /// Custom connector.
    custom,
};

/// Connector configuration.
pub const ConnectorConfig = struct {
    /// Connector type.
    connector_type: ConnectorType,
    /// Connection string.
    connection_string: [512]u8 = [_]u8{0} ** 512,
    /// Connection string length.
    connection_string_len: u16 = 0,
    /// Batch size.
    batch_size: usize = 1000,
    /// Timeout in milliseconds.
    timeout_ms: u32 = 30000,
    /// Whether to use compression.
    use_compression: bool = true,
    /// Whether to use SSL/TLS.
    use_ssl: bool = true,
    /// Maximum concurrent connections.
    max_connections: u16 = 10,

    /// Set connection string.
    pub fn setConnectionString(self: *ConnectorConfig, conn: []const u8) void {
        const len = @min(conn.len, 511);
        stdx.copy_disjoint(.exact, u8, self.connection_string[0..len], conn[0..len]);
        self.connection_string_len = @intCast(len);
    }

    /// Get connection string.
    pub fn getConnectionString(self: *const ConnectorConfig) []const u8 {
        return self.connection_string[0..self.connection_string_len];
    }
};

/// Spark-specific configuration.
pub const SparkConfig = struct {
    /// Base connector config.
    base: ConnectorConfig,
    /// Partition count.
    partitions: u16 = 4,
    /// Read batch size.
    read_batch_size: usize = 100_000,
    /// Write batch size.
    write_batch_size: usize = 10_000,
    /// Enable pushdown predicates.
    enable_pushdown: bool = true,
};

/// Kafka-specific configuration.
pub const KafkaConfig = struct {
    /// Base connector config.
    base: ConnectorConfig,
    /// Topic name.
    topic: [128]u8 = [_]u8{0} ** 128,
    /// Topic length.
    topic_len: u8 = 0,
    /// Consumer group.
    consumer_group: [64]u8 = [_]u8{0} ** 64,
    /// Consumer group length.
    consumer_group_len: u8 = 0,
    /// Start from earliest offset.
    from_earliest: bool = false,
    /// Commit interval in milliseconds.
    commit_interval_ms: u32 = 1000,

    /// Set topic.
    pub fn setTopic(self: *KafkaConfig, topic: []const u8) void {
        const len = @min(topic.len, 127);
        stdx.copy_disjoint(.exact, u8, self.topic[0..len], topic[0..len]);
        self.topic_len = @intCast(len);
    }

    /// Set consumer group.
    pub fn setConsumerGroup(self: *KafkaConfig, group: []const u8) void {
        const len = @min(group.len, 63);
        stdx.copy_disjoint(.exact, u8, self.consumer_group[0..len], group[0..len]);
        self.consumer_group_len = @intCast(len);
    }
};

/// Elasticsearch-specific configuration.
pub const ElasticsearchConfig = struct {
    /// Base connector config.
    base: ConnectorConfig,
    /// Index name.
    index_name: [128]u8 = [_]u8{0} ** 128,
    /// Index name length.
    index_name_len: u8 = 0,
    /// Refresh interval.
    refresh_interval: [16]u8 = [_]u8{0} ** 16,
    /// Refresh interval length.
    refresh_interval_len: u8 = 0,
    /// Number of shards.
    shards: u16 = 3,
    /// Number of replicas.
    replicas: u16 = 1,

    /// Set index name.
    pub fn setIndexName(self: *ElasticsearchConfig, name: []const u8) void {
        const len = @min(name.len, 127);
        stdx.copy_disjoint(.exact, u8, self.index_name[0..len], name[0..len]);
        self.index_name_len = @intCast(len);
    }
};

/// Connector status.
pub const ConnectorStatus = enum {
    /// Not connected.
    disconnected,
    /// Connecting.
    connecting,
    /// Connected and ready.
    connected,
    /// Connection error.
    error_state,
    /// Reconnecting after error.
    reconnecting,
};

/// Connector statistics.
pub const ConnectorStats = struct {
    /// Records sent.
    records_sent: usize = 0,
    /// Records received.
    records_received: usize = 0,
    /// Bytes sent.
    bytes_sent: usize = 0,
    /// Bytes received.
    bytes_received: usize = 0,
    /// Errors encountered.
    errors: usize = 0,
    /// Last activity timestamp.
    last_activity_ns: u64 = 0,
    /// Average latency (nanoseconds).
    avg_latency_ns: u64 = 0,
};

// ============================================================================
// Tests
// ============================================================================

test "webhook event filter" {
    const testing = std.testing;

    const filter = WebhookEventFilter.dataOnly();
    try testing.expect(filter.matches(.insert));
    try testing.expect(filter.matches(.update));
    try testing.expect(filter.matches(.delete));
    try testing.expect(!filter.matches(.bulk_complete));
    try testing.expect(!filter.matches(.schema_change));
}

test "webhook registry" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = WebhookRegistry.init(allocator);
    defer registry.deinit();

    var config = WebhookConfig{};
    config.setUrl("https://example.com/webhook");
    config.events = WebhookEventFilter.dataOnly();

    const idx = try registry.register(config);
    try testing.expectEqual(@as(usize, 0), idx);
    try testing.expectEqual(@as(usize, 1), registry.count());
}

test "bulk loader progress" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loader = BulkLoader.init(allocator, .{
        .batch_size = 1000,
    });

    loader.prepare(10000);
    try testing.expectEqual(@as(usize, 10), loader.progress.total_batches);

    loader.updateProgress(1000, 950, 50, 0);
    try testing.expectEqual(@as(usize, 1000), loader.progress.processed_records);
    try testing.expectEqual(@as(f64, 10.0), loader.progress.percentComplete());
}

test "schema discovery" {
    const testing = std.testing;

    const schema = getGeoEventSchema();
    try testing.expectEqual(@as(usize, 14), schema.field_count);
    try testing.expectEqual(@as(usize, 128), schema.record_size);

    const fields = getGeoEventFields();
    try testing.expect(std.mem.eql(u8, fields[0].getName(), "id"));
    try testing.expect(fields[0].primary_key);
    try testing.expect(std.mem.eql(u8, fields[4].getName(), "lat_nano"));
    try testing.expectEqual(@as(i64, -90_000_000_000), fields[4].min_value.?);
}

test "connector configuration" {
    const testing = std.testing;

    var config = ConnectorConfig{
        .connector_type = .kafka,
        .batch_size = 5000,
    };
    config.setConnectionString("kafka://localhost:9092");

    try testing.expect(std.mem.eql(u8, config.getConnectionString(), "kafka://localhost:9092"));
    try testing.expectEqual(@as(usize, 5000), config.batch_size);
}

test "kafka configuration" {
    const testing = std.testing;

    var config = KafkaConfig{
        .base = .{
            .connector_type = .kafka,
        },
        .from_earliest = true,
    };
    config.setTopic("geoevent-topic");
    config.setConsumerGroup("archerdb-consumer");

    const topic = config.topic[0..config.topic_len];
    const consumer = config.consumer_group[0..config.consumer_group_len];
    try testing.expect(std.mem.eql(u8, topic, "geoevent-topic"));
    try testing.expect(std.mem.eql(u8, consumer, "archerdb-consumer"));
}

test "elasticsearch configuration" {
    const testing = std.testing;

    var config = ElasticsearchConfig{
        .base = .{
            .connector_type = .elasticsearch,
        },
        .shards = 5,
        .replicas = 2,
    };
    config.setIndexName("geoevents");

    try testing.expect(std.mem.eql(u8, config.index_name[0..config.index_name_len], "geoevents"));
    try testing.expectEqual(@as(u16, 5), config.shards);
}
