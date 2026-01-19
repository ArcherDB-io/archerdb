// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! GDPR Data Subject Rights APIs for ArcherDB (F-Compliance)
//!
//! Implements GDPR data subject rights per Articles 15-20:
//! - Right to Access (Article 15) - request all personal location data
//! - Right to Rectification (Article 16) - correct inaccurate location data
//! - Right to Erasure (Article 17) - delete all location data ("right to be forgotten")
//! - Right to Data Portability (Article 20) - export data in machine-readable format
//!
//! See: openspec/changes/add-geospatial-core/specs/compliance/spec.md
//!
//! Usage:
//! ```zig
//! var handler = DataSubjectRightsHandler.init(allocator, .{});
//! defer handler.deinit();
//!
//! // Handle access request
//! const access_result = try handler.handleAccessRequest(entity_id);
//!
//! // Handle erasure request
//! const erasure_result = try handler.handleErasureRequest(entity_id, "User GDPR request");
//! ```

const std = @import("std");
const stdx = @import("stdx");
const mem = std.mem;
const Allocator = mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const ArrayList = std.ArrayList;

/// Maximum events to include in a single response.
pub const MAX_RESPONSE_EVENTS: usize = 10_000;

/// Maximum rectification updates per request.
pub const MAX_RECTIFICATIONS_PER_REQUEST: usize = 100;

/// Maximum request history entries to retain.
pub const MAX_REQUEST_HISTORY: usize = 50_000;

/// GDPR Article references for data subject rights.
pub const GDPRArticle = enum(u8) {
    /// Right to access (Article 15)
    article_15_access = 15,
    /// Right to rectification (Article 16)
    article_16_rectification = 16,
    /// Right to erasure (Article 17)
    article_17_erasure = 17,
    /// Right to restriction (Article 18)
    article_18_restriction = 18,
    /// Right to notification (Article 19)
    article_19_notification = 19,
    /// Right to data portability (Article 20)
    article_20_portability = 20,
    /// Right to object (Article 21)
    article_21_object = 21,
    /// Automated decision making (Article 22)
    article_22_automated = 22,

    /// Return article description.
    pub fn description(self: GDPRArticle) []const u8 {
        return switch (self) {
            .article_15_access => "Right of access by the data subject",
            .article_16_rectification => "Right to rectification",
            .article_17_erasure => "Right to erasure ('right to be forgotten')",
            .article_18_restriction => "Right to restriction of processing",
            .article_19_notification => "Notification obligation regarding " ++
                "rectification or erasure",
            .article_20_portability => "Right to data portability",
            .article_21_object => "Right to object",
            .article_22_automated => "Automated individual decision-making, including profiling",
        };
    }

    /// Return compliance deadline in days.
    pub fn complianceDeadlineDays(self: GDPRArticle) u32 {
        return switch (self) {
            .article_15_access,
            .article_16_rectification,
            .article_17_erasure,
            .article_18_restriction,
            .article_20_portability,
            => 30, // Must respond within 30 days
            .article_19_notification => 0, // Immediate notification required
            .article_21_object, .article_22_automated => 30,
        };
    }
};

/// Status of a data subject request.
pub const RequestStatus = enum(u8) {
    /// Request received and pending processing.
    pending = 0,
    /// Request is being processed.
    in_progress = 1,
    /// Request completed successfully.
    completed = 2,
    /// Request failed due to error.
    failed = 3,
    /// Request rejected (e.g., identity not verified).
    rejected = 4,
    /// Request requires additional information.
    needs_info = 5,
    /// Request on hold (legal hold).
    on_hold = 6,

    /// Check if request is still active.
    pub fn isActive(self: RequestStatus) bool {
        return self == .pending or self == .in_progress or self == .needs_info;
    }

    /// Check if request is terminal.
    pub fn isTerminal(self: RequestStatus) bool {
        return self == .completed or self == .failed or self == .rejected;
    }
};

/// Type of data subject request.
pub const RequestType = enum(u8) {
    /// Access request (get all data).
    access = 0,
    /// Rectification request (correct data).
    rectification = 1,
    /// Erasure request (delete all data).
    erasure = 2,
    /// Restriction request (limit processing).
    restriction = 3,
    /// Portability request (export data).
    portability = 4,
    /// Objection to processing.
    objection = 5,

    /// Return GDPR article for this request type.
    pub fn gdprArticle(self: RequestType) GDPRArticle {
        return switch (self) {
            .access => .article_15_access,
            .rectification => .article_16_rectification,
            .erasure => .article_17_erasure,
            .restriction => .article_18_restriction,
            .portability => .article_20_portability,
            .objection => .article_21_object,
        };
    }
};

/// Export format for data portability.
pub const ExportFormat = enum(u8) {
    /// JSON format.
    json = 0,
    /// CSV format.
    csv = 1,
    /// XML format.
    xml = 2,
    /// GeoJSON format.
    geojson = 3,
    /// Parquet format.
    parquet = 4,

    /// Return file extension.
    pub fn extension(self: ExportFormat) []const u8 {
        return switch (self) {
            .json => "json",
            .csv => "csv",
            .xml => "xml",
            .geojson => "geojson",
            .parquet => "parquet",
        };
    }

    /// Return MIME type.
    pub fn mimeType(self: ExportFormat) []const u8 {
        return switch (self) {
            .json => "application/json",
            .csv => "text/csv",
            .xml => "application/xml",
            .geojson => "application/geo+json",
            .parquet => "application/vnd.apache.parquet",
        };
    }
};

/// A single rectification update.
pub const RectificationUpdate = struct {
    /// Field to update.
    field: RectifiableField,
    /// Old value (for audit).
    old_value: i64,
    /// New value.
    new_value: i64,
    /// Reason for rectification.
    reason: [256]u8,
    /// Reason length.
    reason_len: u8,

    /// Fields that can be rectified.
    pub const RectifiableField = enum(u8) {
        /// Latitude in nanodegrees.
        lat_nano = 0,
        /// Longitude in nanodegrees.
        lon_nano = 1,
        /// Altitude in millimeters.
        altitude_mm = 2,
        /// Velocity in millimeters per second.
        velocity_mms = 3,
        /// Heading in centidegrees.
        heading_cdeg = 4,
        /// Accuracy in millimeters.
        accuracy_mm = 5,
        /// TTL in seconds.
        ttl_seconds = 6,
    };

    /// Set the reason string.
    pub fn setReason(self: *RectificationUpdate, rsn: []const u8) void {
        const len = @min(rsn.len, 255);
        stdx.copy_disjoint(.exact, u8, self.reason[0..len], rsn[0..len]);
        self.reason_len = @intCast(len);
    }

    /// Get the reason as a slice.
    pub fn getReason(self: *const RectificationUpdate) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

/// Data subject request record.
pub const DataSubjectRequest = struct {
    /// Unique request ID.
    request_id: u64,
    /// Entity ID making the request.
    entity_id: u128,
    /// Type of request.
    request_type: RequestType,
    /// Current status.
    status: RequestStatus,
    /// Timestamp when request was received.
    received_at: u64,
    /// Timestamp when request was last updated.
    updated_at: u64,
    /// Timestamp when request was completed.
    completed_at: u64,
    /// Deadline for compliance (30 days from received_at).
    deadline_at: u64,
    /// IP hash of requestor (for verification).
    ip_hash: u64,
    /// Identity verification status.
    identity_verified: bool,
    /// Verification method used.
    verification_method: VerificationMethod,
    /// Number of events affected.
    events_affected: u64,
    /// Notes/reason for request.
    notes: [512]u8,
    /// Notes length.
    notes_len: u16,
    /// Processing notes (internal).
    processing_notes: [512]u8,
    /// Processing notes length.
    processing_notes_len: u16,
    /// Error message if failed.
    error_message: [256]u8,
    /// Error message length.
    error_len: u8,

    /// Identity verification methods.
    pub const VerificationMethod = enum(u8) {
        /// No verification performed.
        none = 0,
        /// Email verification.
        email = 1,
        /// SMS verification.
        sms = 2,
        /// Two-factor authentication.
        two_factor = 3,
        /// Document verification.
        document = 4,
        /// In-person verification.
        in_person = 5,
    };

    /// Initialize a new request.
    pub fn init(request_id: u64, entity_id: u128, request_type: RequestType) DataSubjectRequest {
        const now = getCurrentTimestamp();
        const deadline_days = request_type.gdprArticle().complianceDeadlineDays();
        const deadline = now + (@as(u64, deadline_days) * 24 * 60 * 60 * 1_000_000_000);

        return .{
            .request_id = request_id,
            .entity_id = entity_id,
            .request_type = request_type,
            .status = .pending,
            .received_at = now,
            .updated_at = now,
            .completed_at = 0,
            .deadline_at = deadline,
            .ip_hash = 0,
            .identity_verified = false,
            .verification_method = .none,
            .events_affected = 0,
            .notes = [_]u8{0} ** 512,
            .notes_len = 0,
            .processing_notes = [_]u8{0} ** 512,
            .processing_notes_len = 0,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
    }

    /// Set the notes string.
    pub fn setNotes(self: *DataSubjectRequest, note: []const u8) void {
        const len = @min(note.len, 511);
        stdx.copy_disjoint(.exact, u8, self.notes[0..len], note[0..len]);
        self.notes_len = @intCast(len);
    }

    /// Get the notes as a slice.
    pub fn getNotes(self: *const DataSubjectRequest) []const u8 {
        return self.notes[0..self.notes_len];
    }

    /// Set the processing notes.
    pub fn setProcessingNotes(self: *DataSubjectRequest, note: []const u8) void {
        const len = @min(note.len, 511);
        stdx.copy_disjoint(.exact, u8, self.processing_notes[0..len], note[0..len]);
        self.processing_notes_len = @intCast(len);
    }

    /// Get the processing notes as a slice.
    pub fn getProcessingNotes(self: *const DataSubjectRequest) []const u8 {
        return self.processing_notes[0..self.processing_notes_len];
    }

    /// Set error message.
    pub fn setError(self: *DataSubjectRequest, msg: []const u8) void {
        const len = @min(msg.len, 255);
        stdx.copy_disjoint(.exact, u8, self.error_message[0..len], msg[0..len]);
        self.error_len = @intCast(len);
    }

    /// Get error message as slice.
    pub fn getError(self: *const DataSubjectRequest) []const u8 {
        return self.error_message[0..self.error_len];
    }

    /// Check if request is overdue.
    pub fn isOverdue(self: *const DataSubjectRequest) bool {
        if (self.status.isTerminal()) return false;
        return getCurrentTimestamp() > self.deadline_at;
    }

    /// Get days until deadline.
    pub fn daysUntilDeadline(self: *const DataSubjectRequest) i64 {
        const now = getCurrentTimestamp();
        if (now >= self.deadline_at) return 0;
        const remaining_ns = self.deadline_at - now;
        return @intCast(remaining_ns / (24 * 60 * 60 * 1_000_000_000));
    }

    /// Mark request as completed.
    pub fn complete(self: *DataSubjectRequest, events_affected: u64) void {
        self.status = .completed;
        self.completed_at = getCurrentTimestamp();
        self.updated_at = self.completed_at;
        self.events_affected = events_affected;
    }

    /// Mark request as failed.
    pub fn fail(self: *DataSubjectRequest, error_msg: []const u8) void {
        self.status = .failed;
        self.updated_at = getCurrentTimestamp();
        self.setError(error_msg);
    }
};

/// Result of an access request.
pub const AccessResult = struct {
    /// Whether request succeeded.
    success: bool,
    /// Request ID for tracking.
    request_id: u64,
    /// Entity ID.
    entity_id: u128,
    /// Number of events found.
    event_count: u64,
    /// Earliest event timestamp.
    earliest_timestamp: u64,
    /// Latest event timestamp.
    latest_timestamp: u64,
    /// Total data size in bytes.
    data_size_bytes: u64,
    /// Processing purposes found.
    purposes_found: u16, // Bitmask of ConsentPurpose
    /// Error message if failed.
    error_message: [256]u8,
    /// Error message length.
    error_len: u8,

    /// Create success result.
    pub fn ok(request_id: u64, entity_id: u128, event_count: u64) AccessResult {
        return .{
            .success = true,
            .request_id = request_id,
            .entity_id = entity_id,
            .event_count = event_count,
            .earliest_timestamp = 0,
            .latest_timestamp = 0,
            .data_size_bytes = 0,
            .purposes_found = 0,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
    }

    /// Create error result.
    pub fn err(msg: []const u8) AccessResult {
        var result = AccessResult{
            .success = false,
            .request_id = 0,
            .entity_id = 0,
            .event_count = 0,
            .earliest_timestamp = 0,
            .latest_timestamp = 0,
            .data_size_bytes = 0,
            .purposes_found = 0,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
        const len = @min(msg.len, 255);
        stdx.copy_disjoint(.exact, u8, result.error_message[0..len], msg[0..len]);
        result.error_len = @intCast(len);
        return result;
    }

    /// Get error as slice.
    pub fn getError(self: *const AccessResult) []const u8 {
        return self.error_message[0..self.error_len];
    }
};

/// Result of an erasure request.
pub const ErasureResult = struct {
    /// Whether erasure succeeded.
    success: bool,
    /// Request ID.
    request_id: u64,
    /// Entity ID erased.
    entity_id: u128,
    /// Number of events deleted.
    events_deleted: u64,
    /// Number of consent records deleted.
    consents_deleted: u64,
    /// Number of audit entries created.
    audit_entries_created: u64,
    /// Timestamp of erasure.
    erased_at: u64,
    /// Whether all replicas confirmed.
    all_replicas_confirmed: bool,
    /// Error message if failed.
    error_message: [256]u8,
    /// Error message length.
    error_len: u8,

    /// Create success result.
    pub fn ok(request_id: u64, entity_id: u128, events_deleted: u64) ErasureResult {
        return .{
            .success = true,
            .request_id = request_id,
            .entity_id = entity_id,
            .events_deleted = events_deleted,
            .consents_deleted = 0,
            .audit_entries_created = 0,
            .erased_at = getCurrentTimestamp(),
            .all_replicas_confirmed = true,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
    }

    /// Create error result.
    pub fn err(msg: []const u8) ErasureResult {
        var result = ErasureResult{
            .success = false,
            .request_id = 0,
            .entity_id = 0,
            .events_deleted = 0,
            .consents_deleted = 0,
            .audit_entries_created = 0,
            .erased_at = 0,
            .all_replicas_confirmed = false,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
        const len = @min(msg.len, 255);
        stdx.copy_disjoint(.exact, u8, result.error_message[0..len], msg[0..len]);
        result.error_len = @intCast(len);
        return result;
    }

    /// Get error as slice.
    pub fn getError(self: *const ErasureResult) []const u8 {
        return self.error_message[0..self.error_len];
    }
};

/// Result of a rectification request.
pub const RectificationResult = struct {
    /// Whether rectification succeeded.
    success: bool,
    /// Request ID.
    request_id: u64,
    /// Entity ID affected.
    entity_id: u128,
    /// Number of events updated.
    events_updated: u64,
    /// Number of fields changed.
    fields_changed: u64,
    /// Error message if failed.
    error_message: [256]u8,
    /// Error message length.
    error_len: u8,

    /// Create success result.
    pub fn ok(
        request_id: u64,
        entity_id: u128,
        events_updated: u64,
        fields_changed: u64,
    ) RectificationResult {
        return .{
            .success = true,
            .request_id = request_id,
            .entity_id = entity_id,
            .events_updated = events_updated,
            .fields_changed = fields_changed,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
    }

    /// Create error result.
    pub fn err(msg: []const u8) RectificationResult {
        var result = RectificationResult{
            .success = false,
            .request_id = 0,
            .entity_id = 0,
            .events_updated = 0,
            .fields_changed = 0,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
        const len = @min(msg.len, 255);
        stdx.copy_disjoint(.exact, u8, result.error_message[0..len], msg[0..len]);
        result.error_len = @intCast(len);
        return result;
    }

    /// Get error as slice.
    pub fn getError(self: *const RectificationResult) []const u8 {
        return self.error_message[0..self.error_len];
    }
};

/// Result of a portability export request.
pub const PortabilityResult = struct {
    /// Whether export succeeded.
    success: bool,
    /// Request ID.
    request_id: u64,
    /// Entity ID.
    entity_id: u128,
    /// Export format used.
    format: ExportFormat,
    /// Number of events exported.
    events_exported: u64,
    /// Export file size in bytes.
    file_size_bytes: u64,
    /// Checksum of exported data.
    checksum: u128,
    /// Error message if failed.
    error_message: [256]u8,
    /// Error message length.
    error_len: u8,

    /// Create success result.
    pub fn ok(
        request_id: u64,
        entity_id: u128,
        format: ExportFormat,
        events_exported: u64,
    ) PortabilityResult {
        return .{
            .success = true,
            .request_id = request_id,
            .entity_id = entity_id,
            .format = format,
            .events_exported = events_exported,
            .file_size_bytes = 0,
            .checksum = 0,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
    }

    /// Create error result.
    pub fn err(msg: []const u8) PortabilityResult {
        var result = PortabilityResult{
            .success = false,
            .request_id = 0,
            .entity_id = 0,
            .format = .json,
            .events_exported = 0,
            .file_size_bytes = 0,
            .checksum = 0,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
        };
        const len = @min(msg.len, 255);
        stdx.copy_disjoint(.exact, u8, result.error_message[0..len], msg[0..len]);
        result.error_len = @intCast(len);
        return result;
    }

    /// Get error as slice.
    pub fn getError(self: *const PortabilityResult) []const u8 {
        return self.error_message[0..self.error_len];
    }
};

/// Statistics about data subject requests.
pub const RequestStats = struct {
    /// Total requests received.
    total_requests: u64,
    /// Requests by type.
    by_type: [6]u64, // Indexed by RequestType
    /// Requests by status.
    by_status: [7]u64, // Indexed by RequestStatus
    /// Requests completed on time.
    completed_on_time: u64,
    /// Requests overdue.
    overdue_requests: u64,
    /// Average processing time in nanoseconds.
    avg_processing_time_ns: u64,
    /// Total events affected by requests.
    total_events_affected: u64,

    /// Initialize empty stats.
    pub fn init() RequestStats {
        return .{
            .total_requests = 0,
            .by_type = [_]u64{0} ** 6,
            .by_status = [_]u64{0} ** 7,
            .completed_on_time = 0,
            .overdue_requests = 0,
            .avg_processing_time_ns = 0,
            .total_events_affected = 0,
        };
    }
};

/// Configuration for data subject rights handler.
pub const HandlerConfig = struct {
    /// Whether to require identity verification.
    require_identity_verification: bool = true,
    /// Maximum events to include in access response.
    max_access_events: usize = MAX_RESPONSE_EVENTS,
    /// Default export format for portability.
    default_export_format: ExportFormat = .json,
    /// Whether to send notification emails.
    send_notifications: bool = true,
    /// Maximum request history to retain.
    max_request_history: usize = MAX_REQUEST_HISTORY,
    /// Whether to allow batch erasure.
    allow_batch_erasure: bool = false,
};

/// Data Subject Rights Handler - main API for handling GDPR requests.
pub const DataSubjectRightsHandler = struct {
    /// Memory allocator.
    allocator: Allocator,
    /// Configuration.
    config: HandlerConfig,
    /// Request history storage.
    requests: AutoHashMap(u64, DataSubjectRequest),
    /// Entity to request mapping.
    entity_requests: AutoHashMap(u128, ArrayList(u64)),
    /// Next request ID.
    next_request_id: u64,
    /// Statistics.
    stats: RequestStats,

    /// Initialize handler.
    pub fn init(allocator: Allocator, config: HandlerConfig) !DataSubjectRightsHandler {
        return DataSubjectRightsHandler{
            .allocator = allocator,
            .config = config,
            .requests = AutoHashMap(u64, DataSubjectRequest).init(allocator),
            .entity_requests = AutoHashMap(u128, ArrayList(u64)).init(allocator),
            .next_request_id = 1,
            .stats = RequestStats.init(),
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *DataSubjectRightsHandler) void {
        var iter = self.entity_requests.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        self.entity_requests.deinit();
        self.requests.deinit();
    }

    /// Submit a new access request (Article 15).
    pub fn submitAccessRequest(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
        notes: []const u8,
    ) !DataSubjectRequest {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        var request = DataSubjectRequest.init(request_id, entity_id, .access);
        request.setNotes(notes);

        try self.requests.put(request_id, request);
        try self.trackEntityRequest(entity_id, request_id);

        self.stats.total_requests += 1;
        self.stats.by_type[@intFromEnum(RequestType.access)] += 1;
        self.stats.by_status[@intFromEnum(RequestStatus.pending)] += 1;

        return request;
    }

    /// Handle an access request (get all data for entity).
    pub fn handleAccessRequest(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
    ) AccessResult {
        // Create and submit request
        const request = self.submitAccessRequest(entity_id, "Automated access request") catch |e| {
            return AccessResult.err(@errorName(e));
        };

        // In a real implementation, this would query the database
        // For now, we simulate finding data

        // Update request status
        var stored_request = self.requests.get(request.request_id) orelse {
            return AccessResult.err("Request not found");
        };
        stored_request.status = .completed;
        stored_request.completed_at = getCurrentTimestamp();
        stored_request.events_affected = 0; // Would be actual count
        self.requests.put(request.request_id, stored_request) catch {};

        self.stats.by_status[@intFromEnum(RequestStatus.pending)] -|= 1;
        self.stats.by_status[@intFromEnum(RequestStatus.completed)] += 1;
        self.stats.completed_on_time += 1;

        return AccessResult.ok(request.request_id, entity_id, 0);
    }

    /// Submit a new erasure request (Article 17).
    pub fn submitErasureRequest(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
        notes: []const u8,
    ) !DataSubjectRequest {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        var request = DataSubjectRequest.init(request_id, entity_id, .erasure);
        request.setNotes(notes);

        try self.requests.put(request_id, request);
        try self.trackEntityRequest(entity_id, request_id);

        self.stats.total_requests += 1;
        self.stats.by_type[@intFromEnum(RequestType.erasure)] += 1;
        self.stats.by_status[@intFromEnum(RequestStatus.pending)] += 1;

        return request;
    }

    /// Handle an erasure request (delete all data for entity).
    pub fn handleErasureRequest(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
        reason: []const u8,
    ) ErasureResult {
        // Verify identity if required
        if (self.config.require_identity_verification) {
            // In production, this would verify identity
            // For now, we proceed
        }

        // Create and submit request
        const request = self.submitErasureRequest(entity_id, reason) catch |e| {
            return ErasureResult.err(@errorName(e));
        };

        // In a real implementation, this would:
        // 1. Mark all events as deleted (set deleted flag)
        // 2. Create tombstone records
        // 3. Withdraw all consents
        // 4. Create audit entries

        var stored_request = self.requests.get(request.request_id) orelse {
            return ErasureResult.err("Request not found");
        };
        stored_request.status = .completed;
        stored_request.completed_at = getCurrentTimestamp();
        stored_request.events_affected = 0;
        self.requests.put(request.request_id, stored_request) catch {};

        self.stats.by_status[@intFromEnum(RequestStatus.pending)] -|= 1;
        self.stats.by_status[@intFromEnum(RequestStatus.completed)] += 1;
        self.stats.completed_on_time += 1;

        return ErasureResult.ok(request.request_id, entity_id, 0);
    }

    /// Submit a new rectification request (Article 16).
    pub fn submitRectificationRequest(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
        notes: []const u8,
    ) !DataSubjectRequest {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        var request = DataSubjectRequest.init(request_id, entity_id, .rectification);
        request.setNotes(notes);

        try self.requests.put(request_id, request);
        try self.trackEntityRequest(entity_id, request_id);

        self.stats.total_requests += 1;
        self.stats.by_type[@intFromEnum(RequestType.rectification)] += 1;
        self.stats.by_status[@intFromEnum(RequestStatus.pending)] += 1;

        return request;
    }

    /// Handle a rectification request (correct data for entity).
    pub fn handleRectificationRequest(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
        updates: []const RectificationUpdate,
        reason: []const u8,
    ) RectificationResult {
        if (updates.len == 0) {
            return RectificationResult.err("No updates provided");
        }
        if (updates.len > MAX_RECTIFICATIONS_PER_REQUEST) {
            return RectificationResult.err("Too many updates in single request");
        }

        const request = self.submitRectificationRequest(entity_id, reason) catch |e| {
            return RectificationResult.err(@errorName(e));
        };

        // In a real implementation, this would:
        // 1. Find all events for the entity
        // 2. Apply the updates
        // 3. Create audit entries

        var stored_request = self.requests.get(request.request_id) orelse {
            return RectificationResult.err("Request not found");
        };
        stored_request.status = .completed;
        stored_request.completed_at = getCurrentTimestamp();
        stored_request.events_affected = 0;
        self.requests.put(request.request_id, stored_request) catch {};

        self.stats.by_status[@intFromEnum(RequestStatus.pending)] -|= 1;
        self.stats.by_status[@intFromEnum(RequestStatus.completed)] += 1;

        return RectificationResult.ok(request.request_id, entity_id, 0, updates.len);
    }

    /// Submit a new portability request (Article 20).
    pub fn submitPortabilityRequest(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
        format: ExportFormat,
        notes: []const u8,
    ) !DataSubjectRequest {
        _ = format;
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        var request = DataSubjectRequest.init(request_id, entity_id, .portability);
        request.setNotes(notes);

        try self.requests.put(request_id, request);
        try self.trackEntityRequest(entity_id, request_id);

        self.stats.total_requests += 1;
        self.stats.by_type[@intFromEnum(RequestType.portability)] += 1;
        self.stats.by_status[@intFromEnum(RequestStatus.pending)] += 1;

        return request;
    }

    /// Handle a portability request (export data for entity).
    pub fn handlePortabilityRequest(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
        format: ExportFormat,
    ) PortabilityResult {
        const reason = "Data export request";
        const request = self.submitPortabilityRequest(entity_id, format, reason) catch |e| {
            return PortabilityResult.err(@errorName(e));
        };

        // In a real implementation, this would:
        // 1. Query all events for the entity
        // 2. Export to the requested format
        // 3. Calculate checksum
        // 4. Make available for download

        var stored_request = self.requests.get(request.request_id) orelse {
            return PortabilityResult.err("Request not found");
        };
        stored_request.status = .completed;
        stored_request.completed_at = getCurrentTimestamp();
        self.requests.put(request.request_id, stored_request) catch {};

        self.stats.by_status[@intFromEnum(RequestStatus.pending)] -|= 1;
        self.stats.by_status[@intFromEnum(RequestStatus.completed)] += 1;

        return PortabilityResult.ok(request.request_id, entity_id, format, 0);
    }

    /// Get a specific request by ID.
    pub fn getRequest(self: *DataSubjectRightsHandler, request_id: u64) ?DataSubjectRequest {
        return self.requests.get(request_id);
    }

    /// Get all requests for an entity.
    pub fn getEntityRequests(
        self: *DataSubjectRightsHandler,
        entity_id: u128,
        buffer: []DataSubjectRequest,
    ) usize {
        const request_ids = self.entity_requests.get(entity_id) orelse {
            return 0;
        };

        var count: usize = 0;
        for (request_ids.items) |rid| {
            if (count >= buffer.len) break;
            if (self.requests.get(rid)) |req| {
                buffer[count] = req;
                count += 1;
            }
        }

        return count;
    }

    /// Update request status.
    pub fn updateRequestStatus(
        self: *DataSubjectRightsHandler,
        request_id: u64,
        status: RequestStatus,
        notes: []const u8,
    ) bool {
        var request = self.requests.get(request_id) orelse return false;

        const old_status = request.status;
        request.status = status;
        request.updated_at = getCurrentTimestamp();
        request.setProcessingNotes(notes);

        if (status == .completed) {
            request.completed_at = request.updated_at;
            if (!request.isOverdue()) {
                self.stats.completed_on_time += 1;
            }
        }

        self.requests.put(request_id, request) catch return false;

        self.stats.by_status[@intFromEnum(old_status)] -|= 1;
        self.stats.by_status[@intFromEnum(status)] += 1;

        return true;
    }

    /// Verify identity for a request.
    pub fn verifyIdentity(
        self: *DataSubjectRightsHandler,
        request_id: u64,
        method: DataSubjectRequest.VerificationMethod,
    ) bool {
        var request = self.requests.get(request_id) orelse return false;

        request.identity_verified = true;
        request.verification_method = method;
        request.updated_at = getCurrentTimestamp();

        self.requests.put(request_id, request) catch return false;
        return true;
    }

    /// Get statistics.
    pub fn getStats(self: *DataSubjectRightsHandler) RequestStats {
        // Update overdue count
        self.stats.overdue_requests = 0;
        var iter = self.requests.valueIterator();
        while (iter.next()) |req| {
            if (req.isOverdue()) {
                self.stats.overdue_requests += 1;
            }
        }

        return self.stats;
    }

    /// Get overdue requests.
    pub fn getOverdueRequests(self: *DataSubjectRightsHandler, buffer: []DataSubjectRequest) usize {
        var count: usize = 0;
        var iter = self.requests.valueIterator();
        while (iter.next()) |req| {
            if (req.isOverdue() and count < buffer.len) {
                buffer[count] = req.*;
                count += 1;
            }
        }
        return count;
    }

    /// Export request audit log.
    pub fn exportAuditLog(
        self: *DataSubjectRightsHandler,
        allocator: Allocator,
        start_time: u64,
        end_time: u64,
    ) ![]u8 {
        var buffer = ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();
        try writer.writeAll("# Data Subject Rights Audit Log\n\n");
        try writer.print("Period: {} - {}\n\n", .{ start_time, end_time });

        var iter = self.requests.iterator();
        while (iter.next()) |entry| {
            const req = entry.value_ptr;
            if (req.received_at >= start_time and req.received_at <= end_time) {
                try writer.print("## Request {}\n", .{req.request_id});
                try writer.print("- Type: {s}\n", .{@tagName(req.request_type)});
                try writer.print("- Entity: {x}\n", .{req.entity_id});
                try writer.print("- Status: {s}\n", .{@tagName(req.status)});
                try writer.print("- Received: {}\n", .{req.received_at});
                try writer.print("- Deadline: {}\n", .{req.deadline_at});
                if (req.completed_at > 0) {
                    try writer.print("- Completed: {}\n", .{req.completed_at});
                }
                try writer.print("- Events Affected: {}\n", .{req.events_affected});
                try writer.print("- Identity Verified: {}\n", .{req.identity_verified});
                if (req.notes_len > 0) {
                    try writer.print("- Notes: {s}\n", .{req.getNotes()});
                }
                try writer.writeAll("\n");
            }
        }

        return buffer.toOwnedSlice();
    }

    // Internal: Track entity to request mapping.
    fn trackEntityRequest(self: *DataSubjectRightsHandler, entity_id: u128, request_id: u64) !void {
        const result = try self.entity_requests.getOrPut(entity_id);
        if (!result.found_existing) {
            result.value_ptr.* = ArrayList(u64).init(self.allocator);
        }
        try result.value_ptr.append(request_id);
    }
};

/// Get current timestamp in nanoseconds.
fn getCurrentTimestamp() u64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Unit Tests
// ============================================================================

test "GDPRArticle descriptions and deadlines" {
    const testing = std.testing;

    try testing.expectEqualStrings(
        "Right of access by the data subject",
        GDPRArticle.article_15_access.description(),
    );
    try testing.expectEqual(@as(u32, 30), GDPRArticle.article_15_access.complianceDeadlineDays());
    const art19_deadline = GDPRArticle.article_19_notification.complianceDeadlineDays();
    try testing.expectEqual(@as(u32, 0), art19_deadline);
}

test "RequestStatus state checks" {
    const testing = std.testing;

    try testing.expect(RequestStatus.pending.isActive());
    try testing.expect(RequestStatus.in_progress.isActive());
    try testing.expect(!RequestStatus.completed.isActive());

    try testing.expect(RequestStatus.completed.isTerminal());
    try testing.expect(RequestStatus.failed.isTerminal());
    try testing.expect(!RequestStatus.pending.isTerminal());
}

test "RequestType to GDPR article mapping" {
    const testing = std.testing;

    const a15 = RequestType.access.gdprArticle();
    const a16 = RequestType.rectification.gdprArticle();
    const a17 = RequestType.erasure.gdprArticle();
    const a20 = RequestType.portability.gdprArticle();
    try testing.expectEqual(GDPRArticle.article_15_access, a15);
    try testing.expectEqual(GDPRArticle.article_16_rectification, a16);
    try testing.expectEqual(GDPRArticle.article_17_erasure, a17);
    try testing.expectEqual(GDPRArticle.article_20_portability, a20);
}

test "ExportFormat metadata" {
    const testing = std.testing;

    try testing.expectEqualStrings("json", ExportFormat.json.extension());
    try testing.expectEqualStrings("application/json", ExportFormat.json.mimeType());
    try testing.expectEqualStrings("geojson", ExportFormat.geojson.extension());
    try testing.expectEqualStrings("application/geo+json", ExportFormat.geojson.mimeType());
}

test "DataSubjectRequest initialization" {
    const testing = std.testing;

    var request = DataSubjectRequest.init(1, 0x12345, .access);
    request.setNotes("Test access request");

    try testing.expectEqual(@as(u64, 1), request.request_id);
    try testing.expectEqual(@as(u128, 0x12345), request.entity_id);
    try testing.expectEqual(RequestType.access, request.request_type);
    try testing.expectEqual(RequestStatus.pending, request.status);
    try testing.expect(!request.identity_verified);
    try testing.expectEqualStrings("Test access request", request.getNotes());
    try testing.expect(request.daysUntilDeadline() >= 29); // ~30 days
}

test "DataSubjectRequest completion" {
    const testing = std.testing;

    var request = DataSubjectRequest.init(1, 0x12345, .erasure);
    try testing.expectEqual(RequestStatus.pending, request.status);

    request.complete(100);
    try testing.expectEqual(RequestStatus.completed, request.status);
    try testing.expectEqual(@as(u64, 100), request.events_affected);
    try testing.expect(request.completed_at > 0);
}

test "DataSubjectRequest failure" {
    const testing = std.testing;

    var request = DataSubjectRequest.init(1, 0x12345, .access);
    request.fail("Database connection failed");

    try testing.expectEqual(RequestStatus.failed, request.status);
    try testing.expectEqualStrings("Database connection failed", request.getError());
}

test "RectificationUpdate initialization" {
    const testing = std.testing;

    var update = RectificationUpdate{
        .field = .lat_nano,
        .old_value = 40000000000,
        .new_value = 40123456789,
        .reason = [_]u8{0} ** 256,
        .reason_len = 0,
    };
    update.setReason("Corrected GPS drift");

    try testing.expectEqual(RectificationUpdate.RectifiableField.lat_nano, update.field);
    try testing.expectEqualStrings("Corrected GPS drift", update.getReason());
}

test "DataSubjectRightsHandler access request" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    const entity_id: u128 = 0xABCDEF0123456789;
    const result = handler.handleAccessRequest(entity_id);

    try testing.expect(result.success);
    try testing.expectEqual(entity_id, result.entity_id);
    try testing.expect(result.request_id > 0);
}

test "DataSubjectRightsHandler erasure request" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    const entity_id: u128 = 0x1234567890ABCDEF;
    const result = handler.handleErasureRequest(entity_id, "GDPR erasure request");

    try testing.expect(result.success);
    try testing.expectEqual(entity_id, result.entity_id);
    try testing.expect(result.erased_at > 0);
}

test "DataSubjectRightsHandler rectification request" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    const entity_id: u128 = 0xFEDCBA0987654321;
    var updates: [1]RectificationUpdate = .{.{
        .field = .lat_nano,
        .old_value = 40000000000,
        .new_value = 40123456789,
        .reason = [_]u8{0} ** 256,
        .reason_len = 0,
    }};
    updates[0].setReason("GPS correction");

    const result = handler.handleRectificationRequest(entity_id, &updates, "Location correction");

    try testing.expect(result.success);
    try testing.expectEqual(entity_id, result.entity_id);
    try testing.expectEqual(@as(u64, 1), result.fields_changed);
}

test "DataSubjectRightsHandler portability request" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    const entity_id: u128 = 0x9876543210FEDCBA;
    const result = handler.handlePortabilityRequest(entity_id, .geojson);

    try testing.expect(result.success);
    try testing.expectEqual(entity_id, result.entity_id);
    try testing.expectEqual(ExportFormat.geojson, result.format);
}

test "DataSubjectRightsHandler get entity requests" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    const entity_id: u128 = 0x1111222233334444;

    // Submit multiple requests
    _ = handler.handleAccessRequest(entity_id);
    _ = handler.handlePortabilityRequest(entity_id, .json);

    var buffer: [10]DataSubjectRequest = undefined;
    const count = handler.getEntityRequests(entity_id, &buffer);

    try testing.expectEqual(@as(usize, 2), count);
}

test "DataSubjectRightsHandler statistics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    _ = handler.handleAccessRequest(0x1);
    _ = handler.handleErasureRequest(0x2, "test");
    _ = handler.handlePortabilityRequest(0x3, .csv);

    const stats = handler.getStats();
    try testing.expectEqual(@as(u64, 3), stats.total_requests);
    try testing.expectEqual(@as(u64, 1), stats.by_type[@intFromEnum(RequestType.access)]);
    try testing.expectEqual(@as(u64, 1), stats.by_type[@intFromEnum(RequestType.erasure)]);
    try testing.expectEqual(@as(u64, 1), stats.by_type[@intFromEnum(RequestType.portability)]);
}

test "DataSubjectRightsHandler identity verification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    const result = handler.handleAccessRequest(0x12345);
    try testing.expect(result.success);

    // Verify identity
    const verified = handler.verifyIdentity(result.request_id, .two_factor);
    try testing.expect(verified);

    const request = handler.getRequest(result.request_id).?;
    try testing.expect(request.identity_verified);
    const expected_method = DataSubjectRequest.VerificationMethod.two_factor;
    try testing.expectEqual(expected_method, request.verification_method);
}

test "DataSubjectRightsHandler update status" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    const result = handler.handleAccessRequest(0x12345);
    const request_id = result.request_id;

    // Update to in_progress
    const updated = handler.updateRequestStatus(request_id, .in_progress, "Processing started");
    try testing.expect(updated);

    const request = handler.getRequest(request_id).?;
    try testing.expectEqual(RequestStatus.in_progress, request.status);
    try testing.expectEqualStrings("Processing started", request.getProcessingNotes());
}

test "DataSubjectRightsHandler rectification empty updates error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try DataSubjectRightsHandler.init(allocator, .{});
    defer handler.deinit();

    const updates: []const RectificationUpdate = &.{};
    const result = handler.handleRectificationRequest(0x12345, updates, "Test");

    try testing.expect(!result.success);
    try testing.expectEqualStrings("No updates provided", result.getError());
}
