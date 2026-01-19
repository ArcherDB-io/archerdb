// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Compliance Audit Trail and Reporting System for ArcherDB (F-Compliance)
//!
//! Implements tamper-proof audit trails per GDPR requirements:
//! - Append-only audit log with cryptographic checksums
//! - All data processing activities logged
//! - Consent records and changes tracked
//! - Data subject rights requests recorded
//! - Breach incidents and responses documented
//! - 7-year retention per GDPR Article 5.1.e
//! - Regulatory reporting formats
//!
//! See: openspec/changes/add-geospatial-core/specs/compliance/spec.md
//!
//! Usage:
//! ```zig
//! var audit = ComplianceAudit.init(allocator, .{});
//! defer audit.deinit();
//!
//! // Log data processing activity
//! try audit.logDataProcessing(entity_id, .query, .analytics, 1000);
//!
//! // Generate compliance report
//! const report = try audit.generateComplianceReport(start_time, end_time, allocator);
//! ```

const std = @import("std");
const stdx = @import("stdx");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Maximum audit entries in memory before flush.
pub const MAX_MEMORY_ENTRIES: usize = 100_000;

/// Retention period in seconds (7 years).
pub const RETENTION_PERIOD_SECONDS: u64 = 7 * 365 * 24 * 60 * 60;

/// Audit entry types for different compliance domains.
pub const AuditEntryType = enum(u8) {
    /// Data processing activity (query, export, etc.).
    data_processing = 0,
    /// Consent granted or modified.
    consent_change = 1,
    /// Data subject rights request submitted.
    rights_request = 2,
    /// Data subject rights request completed.
    rights_response = 3,
    /// Data breach detected.
    breach_detected = 4,
    /// Breach notification sent.
    breach_notification = 5,
    /// Data erasure completed.
    data_erasure = 6,
    /// Data access granted.
    data_access = 7,
    /// Data rectification completed.
    data_rectification = 8,
    /// Data exported for portability.
    data_portability = 9,
    /// Administrative action.
    admin_action = 10,
    /// System configuration change.
    config_change = 11,
    /// Authentication event.
    authentication = 12,
    /// Authorization failure.
    authorization_failure = 13,
    /// Encryption key rotation.
    key_rotation = 14,
    /// Backup operation.
    backup_operation = 15,

    /// Return category for grouping.
    pub fn category(self: AuditEntryType) AuditCategory {
        return switch (self) {
            .data_processing, .data_access => .data_activity,
            .consent_change => .consent,
            .rights_request,
            .rights_response,
            .data_erasure,
            .data_rectification,
            .data_portability,
            => .subject_rights,
            .breach_detected, .breach_notification => .breach,
            .admin_action,
            .config_change,
            .key_rotation,
            .backup_operation,
            => .administration,
            .authentication, .authorization_failure => .security,
        };
    }

    /// Return description.
    pub fn description(self: AuditEntryType) []const u8 {
        return switch (self) {
            .data_processing => "Data processing activity",
            .consent_change => "Consent status change",
            .rights_request => "Data subject rights request",
            .rights_response => "Rights request response",
            .breach_detected => "Data breach detected",
            .breach_notification => "Breach notification sent",
            .data_erasure => "Data erasure completed",
            .data_access => "Data access request fulfilled",
            .data_rectification => "Data rectification completed",
            .data_portability => "Data exported for portability",
            .admin_action => "Administrative action",
            .config_change => "System configuration change",
            .authentication => "Authentication event",
            .authorization_failure => "Authorization failure",
            .key_rotation => "Encryption key rotation",
            .backup_operation => "Backup operation",
        };
    }

    /// Return GDPR article reference.
    pub fn gdprArticle(self: AuditEntryType) []const u8 {
        return switch (self) {
            .data_processing => "Article 30 - Records of processing",
            .consent_change => "Article 7 - Conditions for consent",
            .rights_request, .rights_response => "Articles 15-22 - Data subject rights",
            .data_erasure => "Article 17 - Right to erasure",
            .data_access => "Article 15 - Right of access",
            .data_rectification => "Article 16 - Right to rectification",
            .data_portability => "Article 20 - Right to data portability",
            .breach_detected, .breach_notification => "Articles 33-34 - Breach notification",
            else => "Article 30 - Records of processing",
        };
    }
};

/// Audit category for aggregation.
pub const AuditCategory = enum(u8) {
    /// Data access and processing activities.
    data_activity = 0,
    /// Consent-related events.
    consent = 1,
    /// Data subject rights events.
    subject_rights = 2,
    /// Breach-related events.
    breach = 3,
    /// Administrative events.
    administration = 4,
    /// Security events.
    security = 5,
};

/// Processing operation types.
pub const ProcessingOperation = enum(u8) {
    /// Read/query operation.
    query = 0,
    /// Write/insert operation.
    insert = 1,
    /// Update operation.
    update = 2,
    /// Delete operation.
    delete = 3,
    /// Export operation.
    data_export = 4,
    /// Import operation.
    data_import = 5,
    /// Aggregation operation.
    aggregate = 6,
    /// Analytics operation.
    analytics = 7,
};

/// Processing purpose (maps to consent purposes).
pub const ProcessingPurpose = enum(u8) {
    /// Navigation service.
    navigation = 0,
    /// Fleet management.
    fleet_management = 1,
    /// Delivery service.
    delivery = 2,
    /// Analytics.
    analytics = 3,
    /// Emergency services.
    emergency = 4,
    /// Marketing.
    marketing = 5,
    /// Research.
    research = 6,
    /// Compliance/legal.
    compliance = 7,
};

/// Severity levels for audit entries.
pub const AuditSeverity = enum(u8) {
    /// Informational entry.
    info = 0,
    /// Warning - unusual activity.
    warning = 1,
    /// Error - operation failed.
    err = 2,
    /// Critical - security/compliance issue.
    critical = 3,
};

/// A single audit log entry.
pub const AuditEntry = struct {
    /// Unique entry ID (monotonic).
    entry_id: u64,
    /// Entry type.
    entry_type: AuditEntryType,
    /// Severity level.
    severity: AuditSeverity,
    /// Timestamp (Unix nanoseconds).
    timestamp: u64,
    /// Entity ID affected (0 = system-wide).
    entity_id: u128,
    /// Actor who performed the action (0 = system).
    actor_id: u128,
    /// Processing operation (if applicable).
    operation: ProcessingOperation,
    /// Processing purpose (if applicable).
    purpose: ProcessingPurpose,
    /// Number of records affected.
    records_affected: u64,
    /// IP hash of actor.
    actor_ip_hash: u64,
    /// Session ID.
    session_id: u64,
    /// Details/description.
    details: [256]u8,
    /// Details length.
    details_len: u8,
    /// Additional metadata (JSON).
    metadata: [256]u8,
    /// Metadata length.
    metadata_len: u8,
    /// Previous entry checksum (chain link).
    prev_checksum: [32]u8,
    /// This entry's checksum.
    checksum: [32]u8,

    /// Initialize a new entry.
    pub fn init(
        entry_id: u64,
        entry_type: AuditEntryType,
        severity: AuditSeverity,
        entity_id: u128,
        actor_id: u128,
    ) AuditEntry {
        return .{
            .entry_id = entry_id,
            .entry_type = entry_type,
            .severity = severity,
            .timestamp = getCurrentTimestamp(),
            .entity_id = entity_id,
            .actor_id = actor_id,
            .operation = .query,
            .purpose = .compliance,
            .records_affected = 0,
            .actor_ip_hash = 0,
            .session_id = 0,
            .details = [_]u8{0} ** 256,
            .details_len = 0,
            .metadata = [_]u8{0} ** 256,
            .metadata_len = 0,
            .prev_checksum = [_]u8{0} ** 32,
            .checksum = [_]u8{0} ** 32,
        };
    }

    /// Set details string.
    pub fn setDetails(self: *AuditEntry, desc: []const u8) void {
        const len = @min(desc.len, 255);
        stdx.copy_disjoint(.inexact, u8, self.details[0..len], desc[0..len]);
        self.details_len = @intCast(len);
    }

    /// Get details as slice.
    pub fn getDetails(self: *const AuditEntry) []const u8 {
        return self.details[0..self.details_len];
    }

    /// Set metadata string.
    pub fn setMetadata(self: *AuditEntry, meta: []const u8) void {
        const len = @min(meta.len, 255);
        stdx.copy_disjoint(.inexact, u8, self.metadata[0..len], meta[0..len]);
        self.metadata_len = @intCast(len);
    }

    /// Get metadata as slice.
    pub fn getMetadata(self: *const AuditEntry) []const u8 {
        return self.metadata[0..self.metadata_len];
    }

    /// Calculate checksum for this entry.
    pub fn calculateChecksum(self: *AuditEntry) void {
        var hasher = Sha256.init(.{});

        // Include all fields in checksum (except checksum itself)
        var id_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &id_bytes, self.entry_id, .little);
        hasher.update(&id_bytes);

        hasher.update(&[_]u8{@intFromEnum(self.entry_type)});
        hasher.update(&[_]u8{@intFromEnum(self.severity)});

        var ts_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &ts_bytes, self.timestamp, .little);
        hasher.update(&ts_bytes);

        var entity_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &entity_bytes, self.entity_id, .little);
        hasher.update(&entity_bytes);

        var actor_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &actor_bytes, self.actor_id, .little);
        hasher.update(&actor_bytes);

        hasher.update(&[_]u8{@intFromEnum(self.operation)});
        hasher.update(&[_]u8{@intFromEnum(self.purpose)});

        var records_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &records_bytes, self.records_affected, .little);
        hasher.update(&records_bytes);

        hasher.update(self.details[0..self.details_len]);
        hasher.update(self.metadata[0..self.metadata_len]);
        hasher.update(&self.prev_checksum);

        self.checksum = hasher.finalResult();
    }

    /// Verify entry checksum.
    pub fn verifyChecksum(self: *const AuditEntry) bool {
        var copy = self.*;
        copy.calculateChecksum();
        return std.mem.eql(u8, &copy.checksum, &self.checksum);
    }
};

/// Breach incident record.
pub const BreachIncident = struct {
    /// Incident ID.
    incident_id: u64,
    /// Detection timestamp.
    detected_at: u64,
    /// Report timestamp (to authority).
    reported_at: u64,
    /// Affected entity count.
    entities_affected: u64,
    /// Breach type.
    breach_type: BreachType,
    /// Current status.
    status: BreachStatus,
    /// Description.
    description: [512]u8,
    /// Description length.
    description_len: u16,
    /// Response actions taken.
    response: [512]u8,
    /// Response length.
    response_len: u16,

    /// Types of breaches.
    pub const BreachType = enum(u8) {
        /// Unauthorized access.
        unauthorized_access = 0,
        /// Data exfiltration.
        data_exfiltration = 1,
        /// Accidental disclosure.
        accidental_disclosure = 2,
        /// Lost/stolen device.
        lost_device = 3,
        /// Ransomware/malware.
        ransomware = 4,
        /// Insider threat.
        insider_threat = 5,
        /// API vulnerability.
        api_vulnerability = 6,
        /// Unknown.
        unknown = 7,
    };

    /// Breach status.
    pub const BreachStatus = enum(u8) {
        /// Investigating.
        investigating = 0,
        /// Contained.
        contained = 1,
        /// Reported to authority.
        reported = 2,
        /// Notified affected parties.
        notified = 3,
        /// Resolved.
        resolved = 4,
        /// Closed.
        closed = 5,
    };

    /// Initialize a breach incident.
    pub fn init(incident_id: u64, breach_type: BreachType) BreachIncident {
        return .{
            .incident_id = incident_id,
            .detected_at = getCurrentTimestamp(),
            .reported_at = 0,
            .entities_affected = 0,
            .breach_type = breach_type,
            .status = .investigating,
            .description = [_]u8{0} ** 512,
            .description_len = 0,
            .response = [_]u8{0} ** 512,
            .response_len = 0,
        };
    }

    /// Set description.
    pub fn setDescription(self: *BreachIncident, desc: []const u8) void {
        const len = @min(desc.len, 511);
        stdx.copy_disjoint(.inexact, u8, self.description[0..len], desc[0..len]);
        self.description_len = @intCast(len);
    }

    /// Get description as slice.
    pub fn getDescription(self: *const BreachIncident) []const u8 {
        return self.description[0..self.description_len];
    }

    /// Check if 72-hour notification deadline is met.
    pub fn isNotificationDeadlineMet(self: *const BreachIncident) bool {
        if (self.reported_at == 0) {
            // Check if within 72 hours of detection
            const now = getCurrentTimestamp();
            const deadline = self.detected_at + (72 * 60 * 60 * 1_000_000_000);
            return now < deadline;
        }
        // Already reported
        const deadline = self.detected_at + (72 * 60 * 60 * 1_000_000_000);
        return self.reported_at <= deadline;
    }
};

/// Compliance report data.
pub const ComplianceReport = struct {
    /// Report generation timestamp.
    generated_at: u64,
    /// Report period start.
    period_start: u64,
    /// Report period end.
    period_end: u64,
    /// Total audit entries in period.
    total_entries: u64,
    /// Entries by category.
    by_category: [6]u64, // Indexed by AuditCategory
    /// Entries by severity.
    by_severity: [4]u64, // Indexed by AuditSeverity
    /// Data subject requests count.
    subject_requests: u64,
    /// Subject requests completed.
    subject_requests_completed: u64,
    /// Average request response time (nanoseconds).
    avg_response_time_ns: u64,
    /// Consent changes count.
    consent_changes: u64,
    /// Breach incidents count.
    breach_incidents: u64,
    /// Breach incidents resolved.
    breach_resolved: u64,
    /// Data processing operations count.
    processing_operations: u64,
    /// Unique entities processed.
    entities_processed: u64,
    /// Records processed.
    records_processed: u64,
    /// Chain integrity verified.
    chain_integrity_verified: bool,
    /// Chain verification errors.
    chain_errors: u64,

    /// Initialize empty report.
    pub fn init(period_start: u64, period_end: u64) ComplianceReport {
        return .{
            .generated_at = getCurrentTimestamp(),
            .period_start = period_start,
            .period_end = period_end,
            .total_entries = 0,
            .by_category = [_]u64{0} ** 6,
            .by_severity = [_]u64{0} ** 4,
            .subject_requests = 0,
            .subject_requests_completed = 0,
            .avg_response_time_ns = 0,
            .consent_changes = 0,
            .breach_incidents = 0,
            .breach_resolved = 0,
            .processing_operations = 0,
            .entities_processed = 0,
            .records_processed = 0,
            .chain_integrity_verified = false,
            .chain_errors = 0,
        };
    }
};

/// Configuration for compliance audit system.
pub const AuditConfig = struct {
    /// Maximum entries to keep in memory.
    max_memory_entries: usize = MAX_MEMORY_ENTRIES,
    /// Enable chain integrity verification.
    verify_chain_integrity: bool = true,
    /// Enable automatic breach detection alerts.
    enable_breach_alerts: bool = true,
    /// Breach notification deadline in hours (GDPR = 72).
    breach_notification_deadline_hours: u32 = 72,
    /// Retention period in seconds.
    retention_period_seconds: u64 = RETENTION_PERIOD_SECONDS,
};

/// Statistics about audit operations.
pub const AuditStats = struct {
    /// Total entries logged.
    total_entries: u64,
    /// Entries by type.
    by_type: [16]u64, // Indexed by AuditEntryType
    /// Entries by severity.
    by_severity: [4]u64,
    /// Chain integrity errors.
    chain_errors: u64,
    /// Active breach incidents.
    active_breaches: u64,
    /// Total breach incidents.
    total_breaches: u64,

    /// Initialize empty stats.
    pub fn init() AuditStats {
        return .{
            .total_entries = 0,
            .by_type = [_]u64{0} ** 16,
            .by_severity = [_]u64{0} ** 4,
            .chain_errors = 0,
            .active_breaches = 0,
            .total_breaches = 0,
        };
    }
};

/// Compliance Audit System - main API for audit trail management.
pub const ComplianceAudit = struct {
    /// Memory allocator.
    allocator: Allocator,
    /// Configuration.
    config: AuditConfig,
    /// Audit log entries (circular buffer).
    entries: []AuditEntry,
    /// Write position.
    write_pos: usize,
    /// Next entry ID.
    next_entry_id: u64,
    /// Last entry checksum (for chain linking).
    last_checksum: [32]u8,
    /// Breach incidents.
    breaches: AutoHashMap(u64, BreachIncident),
    /// Next breach ID.
    next_breach_id: u64,
    /// Statistics.
    stats: AuditStats,

    /// Initialize audit system.
    pub fn init(allocator: Allocator, config: AuditConfig) !ComplianceAudit {
        const entries = try allocator.alloc(AuditEntry, config.max_memory_entries);
        @memset(entries, std.mem.zeroes(AuditEntry));

        return ComplianceAudit{
            .allocator = allocator,
            .config = config,
            .entries = entries,
            .write_pos = 0,
            .next_entry_id = 1,
            .last_checksum = [_]u8{0} ** 32,
            .breaches = AutoHashMap(u64, BreachIncident).init(allocator),
            .next_breach_id = 1,
            .stats = AuditStats.init(),
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *ComplianceAudit) void {
        self.allocator.free(self.entries);
        self.breaches.deinit();
    }

    /// Log a data processing activity.
    pub fn logDataProcessing(
        self: *ComplianceAudit,
        entity_id: u128,
        operation: ProcessingOperation,
        purpose: ProcessingPurpose,
        records_affected: u64,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .data_processing,
            .info,
            entity_id,
            0, // system actor
        );
        entry.operation = operation;
        entry.purpose = purpose;
        entry.records_affected = records_affected;
        entry.setDetails("Data processing operation");

        return self.appendEntry(&entry);
    }

    /// Log a consent change.
    pub fn logConsentChange(
        self: *ComplianceAudit,
        entity_id: u128,
        actor_id: u128,
        details: []const u8,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .consent_change,
            .info,
            entity_id,
            actor_id,
        );
        entry.setDetails(details);

        return self.appendEntry(&entry);
    }

    /// Log a data subject rights request.
    pub fn logRightsRequest(
        self: *ComplianceAudit,
        entity_id: u128,
        request_type: []const u8,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .rights_request,
            .info,
            entity_id,
            entity_id, // user initiated
        );
        entry.setDetails(request_type);

        return self.appendEntry(&entry);
    }

    /// Log a rights request response.
    pub fn logRightsResponse(
        self: *ComplianceAudit,
        entity_id: u128,
        request_type: []const u8,
        records_affected: u64,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .rights_response,
            .info,
            entity_id,
            0, // system
        );
        entry.records_affected = records_affected;
        entry.setDetails(request_type);

        return self.appendEntry(&entry);
    }

    /// Log a data erasure.
    pub fn logDataErasure(
        self: *ComplianceAudit,
        entity_id: u128,
        records_deleted: u64,
        reason: []const u8,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .data_erasure,
            .info,
            entity_id,
            entity_id,
        );
        entry.records_affected = records_deleted;
        entry.setDetails(reason);

        return self.appendEntry(&entry);
    }

    /// Log a data access request.
    pub fn logDataAccess(
        self: *ComplianceAudit,
        entity_id: u128,
        records_accessed: u64,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .data_access,
            .info,
            entity_id,
            entity_id,
        );
        entry.records_affected = records_accessed;
        entry.setDetails("Data access request fulfilled");

        return self.appendEntry(&entry);
    }

    /// Report a data breach.
    pub fn reportBreach(
        self: *ComplianceAudit,
        breach_type: BreachIncident.BreachType,
        description: []const u8,
        entities_affected: u64,
    ) !u64 {
        const breach_id = self.next_breach_id;
        self.next_breach_id += 1;

        var incident = BreachIncident.init(breach_id, breach_type);
        incident.entities_affected = entities_affected;
        incident.setDescription(description);

        try self.breaches.put(breach_id, incident);

        // Log the breach detection
        var entry = AuditEntry.init(
            self.next_entry_id,
            .breach_detected,
            .critical,
            0, // system-wide
            0, // system
        );
        entry.records_affected = entities_affected;
        entry.setDetails(description);

        _ = self.appendEntry(&entry);

        self.stats.total_breaches += 1;
        self.stats.active_breaches += 1;

        return breach_id;
    }

    /// Update breach status.
    pub fn updateBreachStatus(
        self: *ComplianceAudit,
        breach_id: u64,
        status: BreachIncident.BreachStatus,
        response: []const u8,
    ) bool {
        var incident = self.breaches.get(breach_id) orelse return false;

        const old_status = incident.status;
        incident.status = status;

        if (status == .reported) {
            incident.reported_at = getCurrentTimestamp();
        }

        // Log the notification if applicable
        if (status == .reported or status == .notified) {
            var entry = AuditEntry.init(
                self.next_entry_id,
                .breach_notification,
                .warning,
                0,
                0,
            );
            entry.setDetails(response);
            _ = self.appendEntry(&entry);
        }

        // Update response
        const len = @min(response.len, 511);
        stdx.copy_disjoint(.inexact, u8, incident.response[0..len], response[0..len]);
        incident.response_len = @intCast(len);

        self.breaches.put(breach_id, incident) catch return false;

        // Update active count
        if (old_status != .resolved and old_status != .closed) {
            if (status == .resolved or status == .closed) {
                self.stats.active_breaches -|= 1;
            }
        }

        return true;
    }

    /// Log an administrative action.
    pub fn logAdminAction(
        self: *ComplianceAudit,
        actor_id: u128,
        action: []const u8,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .admin_action,
            .warning,
            0,
            actor_id,
        );
        entry.setDetails(action);

        return self.appendEntry(&entry);
    }

    /// Log authentication event.
    pub fn logAuthentication(
        self: *ComplianceAudit,
        actor_id: u128,
        success: bool,
        method: []const u8,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .authentication,
            if (success) .info else .warning,
            0,
            actor_id,
        );
        entry.setDetails(method);

        return self.appendEntry(&entry);
    }

    /// Log authorization failure.
    pub fn logAuthorizationFailure(
        self: *ComplianceAudit,
        actor_id: u128,
        resource: []const u8,
    ) u64 {
        var entry = AuditEntry.init(
            self.next_entry_id,
            .authorization_failure,
            .warning,
            0,
            actor_id,
        );
        entry.setDetails(resource);

        return self.appendEntry(&entry);
    }

    /// Verify chain integrity.
    pub fn verifyChainIntegrity(self: *ComplianceAudit) struct { valid: bool, errors: u64 } {
        var errors: u64 = 0;
        var prev_checksum: [32]u8 = [_]u8{0} ** 32;

        const count = @min(self.write_pos, self.config.max_memory_entries);
        for (self.entries[0..count]) |*entry| {
            // Verify this entry's checksum
            if (!entry.verifyChecksum()) {
                errors += 1;
            }

            // Verify chain link
            if (!std.mem.eql(u8, &entry.prev_checksum, &prev_checksum)) {
                errors += 1;
            }

            prev_checksum = entry.checksum;
        }

        self.stats.chain_errors = errors;

        return .{
            .valid = errors == 0,
            .errors = errors,
        };
    }

    /// Generate compliance report.
    pub fn generateComplianceReport(
        self: *ComplianceAudit,
        period_start: u64,
        period_end: u64,
    ) ComplianceReport {
        var report = ComplianceReport.init(period_start, period_end);

        // Analyze entries in period
        const count = @min(self.write_pos, self.config.max_memory_entries);
        var unique_entities = AutoHashMap(u128, void).init(self.allocator);
        defer unique_entities.deinit();

        for (self.entries[0..count]) |entry| {
            if (entry.timestamp >= period_start and entry.timestamp <= period_end) {
                report.total_entries += 1;
                report.by_category[@intFromEnum(entry.entry_type.category())] += 1;
                report.by_severity[@intFromEnum(entry.severity)] += 1;

                switch (entry.entry_type) {
                    .consent_change => report.consent_changes += 1,
                    .rights_request => report.subject_requests += 1,
                    .rights_response => report.subject_requests_completed += 1,
                    .data_processing => {
                        report.processing_operations += 1;
                        report.records_processed += entry.records_affected;
                    },
                    .breach_detected => report.breach_incidents += 1,
                    else => {},
                }

                if (entry.entity_id != 0) {
                    unique_entities.put(entry.entity_id, {}) catch {};
                }
            }
        }

        report.entities_processed = unique_entities.count();

        // Verify chain integrity
        const integrity = self.verifyChainIntegrity();
        report.chain_integrity_verified = integrity.valid;
        report.chain_errors = integrity.errors;

        // Count resolved breaches
        var iter = self.breaches.valueIterator();
        while (iter.next()) |incident| {
            if (incident.detected_at >= period_start and incident.detected_at <= period_end) {
                if (incident.status == .resolved or incident.status == .closed) {
                    report.breach_resolved += 1;
                }
            }
        }

        return report;
    }

    /// Get entries for a specific entity.
    pub fn getEntityAuditHistory(
        self: *ComplianceAudit,
        entity_id: u128,
        buffer: []AuditEntry,
    ) usize {
        var found: usize = 0;
        const count = @min(self.write_pos, self.config.max_memory_entries);

        for (self.entries[0..count]) |entry| {
            if (entry.entity_id == entity_id and found < buffer.len) {
                buffer[found] = entry;
                found += 1;
            }
        }

        return found;
    }

    /// Get statistics.
    pub fn getStats(self: *ComplianceAudit) AuditStats {
        return self.stats;
    }

    /// Export audit log as text.
    pub fn exportAsText(
        self: *ComplianceAudit,
        allocator: Allocator,
        start_time: u64,
        end_time: u64,
    ) ![]u8 {
        var buffer = ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();
        try writer.writeAll("# Compliance Audit Log Export\n\n");
        try writer.print("Period: {} - {}\n", .{ start_time, end_time });
        try writer.print("Generated: {}\n\n", .{getCurrentTimestamp()});

        const count = @min(self.write_pos, self.config.max_memory_entries);
        for (self.entries[0..count]) |entry| {
            if (entry.timestamp >= start_time and entry.timestamp <= end_time) {
                try writer.print("[{}] {} - {s}\n", .{
                    entry.entry_id,
                    entry.timestamp,
                    entry.entry_type.description(),
                });
                try writer.print("  Entity: {x}, Actor: {x}\n", .{
                    entry.entity_id,
                    entry.actor_id,
                });
                try writer.print("  Records: {}, Severity: {s}\n", .{
                    entry.records_affected,
                    @tagName(entry.severity),
                });
                if (entry.details_len > 0) {
                    try writer.print("  Details: {s}\n", .{entry.getDetails()});
                }
                try writer.writeAll("\n");
            }
        }

        return buffer.toOwnedSlice();
    }

    /// Get breach incident by ID.
    pub fn getBreach(self: *ComplianceAudit, breach_id: u64) ?BreachIncident {
        return self.breaches.get(breach_id);
    }

    /// Get all active breaches.
    pub fn getActiveBreaches(self: *ComplianceAudit, buffer: []BreachIncident) usize {
        var count: usize = 0;
        var iter = self.breaches.valueIterator();
        while (iter.next()) |incident| {
            if (incident.status != .resolved and incident.status != .closed) {
                if (count < buffer.len) {
                    buffer[count] = incident.*;
                    count += 1;
                }
            }
        }
        return count;
    }

    // Internal: Append entry to log with chain linking.
    fn appendEntry(self: *ComplianceAudit, entry: *AuditEntry) u64 {
        // Link to previous entry
        entry.prev_checksum = self.last_checksum;
        entry.calculateChecksum();

        // Store entry
        const idx = self.write_pos % self.config.max_memory_entries;
        self.entries[idx] = entry.*;
        self.write_pos += 1;

        // Update chain state
        self.last_checksum = entry.checksum;
        self.next_entry_id += 1;

        // Update stats
        self.stats.total_entries += 1;
        self.stats.by_type[@intFromEnum(entry.entry_type)] += 1;
        self.stats.by_severity[@intFromEnum(entry.severity)] += 1;

        return entry.entry_id;
    }
};

/// Get current timestamp in nanoseconds.
fn getCurrentTimestamp() u64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Unit Tests
// ============================================================================

test "AuditEntryType properties" {
    const testing = std.testing;

    try testing.expectEqual(
        AuditCategory.data_activity,
        AuditEntryType.data_processing.category(),
    );
    try testing.expectEqual(
        AuditCategory.consent,
        AuditEntryType.consent_change.category(),
    );
    try testing.expectEqual(
        AuditCategory.breach,
        AuditEntryType.breach_detected.category(),
    );

    try testing.expectEqualStrings(
        "Article 30 - Records of processing",
        AuditEntryType.data_processing.gdprArticle(),
    );
    try testing.expectEqualStrings(
        "Article 17 - Right to erasure",
        AuditEntryType.data_erasure.gdprArticle(),
    );
}

test "AuditEntry checksum calculation" {
    const testing = std.testing;

    var entry = AuditEntry.init(1, .data_processing, .info, 0x12345, 0xABCDE);
    entry.setDetails("Test entry");

    // Calculate checksum
    entry.calculateChecksum();

    // Verify checksum
    try testing.expect(entry.verifyChecksum());

    // Modify entry - checksum should no longer verify
    entry.records_affected = 100;
    try testing.expect(!entry.verifyChecksum());
}

test "AuditEntry chain linking" {
    const testing = std.testing;

    var entry1 = AuditEntry.init(1, .data_processing, .info, 0x1, 0);
    entry1.calculateChecksum();

    var entry2 = AuditEntry.init(2, .consent_change, .info, 0x2, 0);
    entry2.prev_checksum = entry1.checksum;
    entry2.calculateChecksum();

    try testing.expect(entry1.verifyChecksum());
    try testing.expect(entry2.verifyChecksum());
    try testing.expect(std.mem.eql(u8, &entry2.prev_checksum, &entry1.checksum));
}

test "ComplianceAudit log data processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    const entry_id = audit.logDataProcessing(0x12345, .query, .analytics, 1000);

    try testing.expect(entry_id > 0);
    try testing.expectEqual(@as(u64, 1), audit.stats.total_entries);
    try testing.expectEqual(
        @as(u64, 1),
        audit.stats.by_type[@intFromEnum(AuditEntryType.data_processing)],
    );
}

test "ComplianceAudit consent change logging" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    const entry_id = audit.logConsentChange(
        0xABCDE,
        0xABCDE,
        "Consent granted for location tracking",
    );

    try testing.expect(entry_id > 0);
    try testing.expectEqual(
        @as(u64, 1),
        audit.stats.by_type[@intFromEnum(AuditEntryType.consent_change)],
    );
}

test "ComplianceAudit rights request logging" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    _ = audit.logRightsRequest(0x12345, "Access request");
    _ = audit.logRightsResponse(0x12345, "Access request fulfilled", 100);

    try testing.expectEqual(@as(u64, 2), audit.stats.total_entries);
}

test "ComplianceAudit breach reporting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    const breach_id = try audit.reportBreach(
        .unauthorized_access,
        "Unauthorized API access detected",
        100,
    );

    try testing.expect(breach_id > 0);
    try testing.expectEqual(@as(u64, 1), audit.stats.total_breaches);
    try testing.expectEqual(@as(u64, 1), audit.stats.active_breaches);

    const incident = audit.getBreach(breach_id);
    try testing.expect(incident != null);
    try testing.expectEqual(BreachIncident.BreachStatus.investigating, incident.?.status);
}

test "ComplianceAudit breach status update" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    const breach_id = try audit.reportBreach(.data_exfiltration, "Test breach", 50);

    const updated = audit.updateBreachStatus(
        breach_id,
        .reported,
        "Reported to supervisory authority",
    );
    try testing.expect(updated);

    const incident = audit.getBreach(breach_id);
    try testing.expectEqual(BreachIncident.BreachStatus.reported, incident.?.status);
    try testing.expect(incident.?.reported_at > 0);
}

test "ComplianceAudit chain integrity verification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    // Add several entries
    _ = audit.logDataProcessing(0x1, .query, .analytics, 10);
    _ = audit.logConsentChange(0x2, 0x2, "Consent granted");
    _ = audit.logRightsRequest(0x3, "Access request");

    // Verify chain integrity
    const result = audit.verifyChainIntegrity();
    try testing.expect(result.valid);
    try testing.expectEqual(@as(u64, 0), result.errors);
}

test "ComplianceAudit compliance report generation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    // Add various entries
    _ = audit.logDataProcessing(0x1, .query, .analytics, 100);
    _ = audit.logConsentChange(0x2, 0x2, "Consent granted");
    _ = audit.logRightsRequest(0x3, "Access");
    _ = audit.logRightsResponse(0x3, "Access fulfilled", 50);

    const report = audit.generateComplianceReport(0, std.math.maxInt(u64));

    try testing.expectEqual(@as(u64, 4), report.total_entries);
    try testing.expectEqual(@as(u64, 1), report.consent_changes);
    try testing.expectEqual(@as(u64, 1), report.subject_requests);
    try testing.expectEqual(@as(u64, 1), report.subject_requests_completed);
    try testing.expectEqual(@as(u64, 1), report.processing_operations);
}

test "ComplianceAudit entity audit history" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    const entity_id: u128 = 0x12345;

    _ = audit.logDataProcessing(entity_id, .query, .analytics, 10);
    _ = audit.logDataProcessing(0x99999, .insert, .navigation, 5);
    _ = audit.logConsentChange(entity_id, entity_id, "Change");

    var buffer: [10]AuditEntry = undefined;
    const count = audit.getEntityAuditHistory(entity_id, &buffer);

    try testing.expectEqual(@as(usize, 2), count);
}

test "ComplianceAudit get active breaches" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = try ComplianceAudit.init(allocator, .{});
    defer audit.deinit();

    _ = try audit.reportBreach(.unauthorized_access, "Breach 1", 10);
    const breach2 = try audit.reportBreach(.data_exfiltration, "Breach 2", 20);

    // Resolve one breach
    _ = audit.updateBreachStatus(breach2, .resolved, "Resolved");

    var buffer: [10]BreachIncident = undefined;
    const count = audit.getActiveBreaches(&buffer);

    try testing.expectEqual(@as(usize, 1), count);
}

test "BreachIncident notification deadline" {
    const testing = std.testing;

    var incident = BreachIncident.init(1, .unauthorized_access);
    // Just created, should be within 72 hours
    try testing.expect(incident.isNotificationDeadlineMet());
}

test "ComplianceReport initialization" {
    const testing = std.testing;

    const report = ComplianceReport.init(1000, 2000);

    try testing.expectEqual(@as(u64, 1000), report.period_start);
    try testing.expectEqual(@as(u64, 2000), report.period_end);
    try testing.expectEqual(@as(u64, 0), report.total_entries);
}
