// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! GDPR Consent Management System for ArcherDB (F-Compliance)
//!
//! Implements comprehensive consent management per GDPR requirements:
//! - Consent collection (freely given, specific, informed, unambiguous)
//! - Consent storage with full provenance
//! - Consent withdrawal with immediate effect
//! - Granular consent for different processing purposes
//! - Complete audit trail of all consent changes
//! - Consent validity checking and enforcement
//!
//! See: openspec/changes/add-geospatial-core/specs/compliance/spec.md
//!
//! Usage:
//! ```zig
//! var manager = ConsentManager.init(allocator, .{});
//! defer manager.deinit();
//!
//! // Record consent
//! try manager.recordConsent(entity_id, .location_tracking, .granted, "User accepted terms v2.1");
//!
//! // Check consent before processing
//! if (manager.hasValidConsent(entity_id, .location_tracking)) {
//!     // Process location data
//! }
//!
//! // Withdraw consent
//! try manager.withdrawConsent(entity_id, .location_tracking, "User requested opt-out");
//! ```

const std = @import("std");
const stdx = @import("stdx");
const mem = std.mem;
const Allocator = mem.Allocator;
const AutoHashMap = std.AutoHashMap;

/// Maximum consent records per entity.
pub const MAX_CONSENTS_PER_ENTITY: usize = 32;

/// Maximum audit log entries to retain in memory.
pub const MAX_AUDIT_ENTRIES: usize = 100_000;

/// Maximum length of consent notes/context.
pub const MAX_CONSENT_NOTES_LEN: usize = 512;

/// Maximum length of source identifier.
pub const MAX_SOURCE_LEN: usize = 128;

/// Consent purposes defined per GDPR Article 6 - lawful bases for processing.
/// Each purpose requires separate, granular consent.
pub const ConsentPurpose = enum(u8) {
    /// Location tracking - collecting and storing GPS coordinates.
    location_tracking = 0,
    /// Location analytics - analyzing movement patterns and behavior.
    location_analytics = 1,
    /// Third-party sharing - sharing location data with partners.
    third_party_sharing = 2,
    /// Marketing - using location for targeted marketing.
    marketing = 3,
    /// Research - using anonymized data for research purposes.
    research = 4,
    /// Emergency services - sharing location in emergencies.
    emergency_services = 5,
    /// Fleet management - employer tracking for fleet operations.
    fleet_management = 6,
    /// Historical archival - long-term storage of location history.
    historical_archival = 7,
    /// Cross-border transfer - transfer data outside EU/EEA.
    cross_border_transfer = 8,
    /// Automated decision making - AI/ML based on location.
    automated_decisions = 9,
    /// Profiling - creating location-based user profiles.
    profiling = 10,
    /// Child tracking - parental location monitoring.
    child_tracking = 11,

    /// Return human-readable description of the purpose.
    pub fn description(self: ConsentPurpose) []const u8 {
        return switch (self) {
            .location_tracking => "Collection and storage of GPS coordinates",
            .location_analytics => "Analysis of movement patterns and behavior",
            .third_party_sharing => "Sharing location data with third-party partners",
            .marketing => "Use of location for targeted marketing",
            .research => "Use of anonymized data for research purposes",
            .emergency_services => "Sharing location in emergency situations",
            .fleet_management => "Employer tracking for fleet operations",
            .historical_archival => "Long-term storage of location history",
            .cross_border_transfer => "Transfer of data outside EU/EEA",
            .automated_decisions => "AI/ML decisions based on location data",
            .profiling => "Creating location-based user profiles",
            .child_tracking => "Parental location monitoring of children",
        };
    }

    /// Return GDPR article reference.
    pub fn gdprReference(self: ConsentPurpose) []const u8 {
        return switch (self) {
            .location_tracking, .location_analytics => "Article 6(1)(a) - Consent",
            .third_party_sharing => "Article 6(1)(a) + Article 44-49",
            .marketing => "Article 6(1)(a) - Explicit consent",
            .research => "Article 6(1)(f) - Legitimate interest",
            .emergency_services => "Article 6(1)(d) - Vital interests",
            .fleet_management => "Article 6(1)(b) - Contract",
            .historical_archival => "Article 6(1)(a) + Article 17(3)(d)",
            .cross_border_transfer => "Article 44-49 - International transfers",
            .automated_decisions => "Article 22 - Automated decisions",
            .profiling => "Article 22 - Profiling",
            .child_tracking => "Article 8 - Child consent",
        };
    }

    /// Check if purpose requires explicit consent (vs legitimate interest).
    pub fn requiresExplicitConsent(self: ConsentPurpose) bool {
        return switch (self) {
            .location_tracking,
            .location_analytics,
            .third_party_sharing,
            .marketing,
            .historical_archival,
            .cross_border_transfer,
            .automated_decisions,
            .profiling,
            .child_tracking,
            => true,
            .research, .emergency_services, .fleet_management => false,
        };
    }
};

/// Consent status - current state of consent.
pub const ConsentStatus = enum(u8) {
    /// Consent has been granted.
    granted = 0,
    /// Consent has been withdrawn.
    withdrawn = 1,
    /// Consent is pending (requested but not confirmed).
    pending = 2,
    /// Consent expired (time-limited consent).
    expired = 3,
    /// Consent denied (user explicitly refused).
    denied = 4,
    /// Consent suspended (temporarily disabled).
    suspended = 5,

    /// Check if status allows data processing.
    pub fn allowsProcessing(self: ConsentStatus) bool {
        return self == .granted;
    }
};

/// Consent change event type for audit logging.
pub const ConsentEventType = enum(u8) {
    /// Initial consent granted.
    consent_granted = 0,
    /// Consent withdrawn.
    consent_withdrawn = 1,
    /// Consent renewed/refreshed.
    consent_renewed = 2,
    /// Consent expired automatically.
    consent_expired = 3,
    /// Consent scope changed.
    consent_modified = 4,
    /// Consent verification completed.
    consent_verified = 5,
    /// Consent denied by user.
    consent_denied = 6,
    /// Consent suspended.
    consent_suspended = 7,
    /// Consent reactivated from suspension.
    consent_reactivated = 8,
};

/// A single consent record for an entity-purpose pair.
pub const ConsentRecord = struct {
    /// Entity ID (user/data subject).
    entity_id: u128,
    /// Purpose of consent.
    purpose: ConsentPurpose,
    /// Current consent status.
    status: ConsentStatus,
    /// Timestamp when consent was first granted (Unix nanoseconds).
    granted_at: u64,
    /// Timestamp when consent was last modified.
    modified_at: u64,
    /// Timestamp when consent expires (0 = never expires).
    expires_at: u64,
    /// IP address hash (for verification, not stored raw for privacy).
    ip_hash: u64,
    /// Source of consent (e.g., "mobile_app_v2.1", "web_portal").
    source: [MAX_SOURCE_LEN]u8,
    /// Source string length.
    source_len: u8,
    /// Consent version (for tracking policy version).
    consent_version: u32,
    /// Whether double opt-in was completed.
    double_opt_in: bool,
    /// Whether consent was for child (requires parental verification).
    is_child_consent: bool,
    /// Parent/guardian entity_id if child consent.
    guardian_entity_id: u128,
    /// Notes/context for the consent.
    notes: [MAX_CONSENT_NOTES_LEN]u8,
    /// Notes string length.
    notes_len: u16,
    /// Reserved for future use.
    reserved: [32]u8,

    /// Initialize a new consent record.
    pub fn init(entity_id: u128, purpose: ConsentPurpose, status: ConsentStatus) ConsentRecord {
        const now = getCurrentTimestamp();
        return .{
            .entity_id = entity_id,
            .purpose = purpose,
            .status = status,
            .granted_at = if (status == .granted) now else 0,
            .modified_at = now,
            .expires_at = 0,
            .ip_hash = 0,
            .source = [_]u8{0} ** MAX_SOURCE_LEN,
            .source_len = 0,
            .consent_version = 1,
            .double_opt_in = false,
            .is_child_consent = false,
            .guardian_entity_id = 0,
            .notes = [_]u8{0} ** MAX_CONSENT_NOTES_LEN,
            .notes_len = 0,
            .reserved = [_]u8{0} ** 32,
        };
    }

    /// Set the source string.
    pub fn setSource(self: *ConsentRecord, src: []const u8) void {
        const len = @min(src.len, MAX_SOURCE_LEN - 1);
        stdx.copy_disjoint(.exact, u8, self.source[0..len], src[0..len]);
        self.source_len = @intCast(len);
    }

    /// Get the source as a slice.
    pub fn getSource(self: *const ConsentRecord) []const u8 {
        return self.source[0..self.source_len];
    }

    /// Set the notes string.
    pub fn setNotes(self: *ConsentRecord, note: []const u8) void {
        const len = @min(note.len, MAX_CONSENT_NOTES_LEN - 1);
        stdx.copy_disjoint(.exact, u8, self.notes[0..len], note[0..len]);
        self.notes_len = @intCast(len);
    }

    /// Get the notes as a slice.
    pub fn getNotes(self: *const ConsentRecord) []const u8 {
        return self.notes[0..self.notes_len];
    }

    /// Check if consent is currently valid.
    pub fn isValid(self: *const ConsentRecord) bool {
        if (!self.status.allowsProcessing()) return false;
        if (self.expires_at > 0) {
            const now = getCurrentTimestamp();
            if (now >= self.expires_at) return false;
        }
        return true;
    }

    /// Check if consent has expired.
    pub fn isExpired(self: *const ConsentRecord) bool {
        if (self.expires_at == 0) return false;
        const now = getCurrentTimestamp();
        return now >= self.expires_at;
    }
};

/// Audit log entry for consent changes.
pub const ConsentAuditEntry = struct {
    /// Unique audit entry ID.
    audit_id: u64,
    /// Entity ID affected.
    entity_id: u128,
    /// Purpose affected.
    purpose: ConsentPurpose,
    /// Type of consent event.
    event_type: ConsentEventType,
    /// Previous status (if applicable).
    previous_status: ConsentStatus,
    /// New status.
    new_status: ConsentStatus,
    /// Timestamp of the event.
    timestamp: u64,
    /// Actor who made the change (0 = system, entity_id = user, other = admin).
    actor_id: u128,
    /// Reason/notes for the change.
    reason: [256]u8,
    /// Reason string length.
    reason_len: u8,
    /// IP hash of actor (for verification).
    actor_ip_hash: u64,

    /// Initialize an audit entry.
    pub fn init(
        audit_id: u64,
        entity_id: u128,
        purpose: ConsentPurpose,
        event_type: ConsentEventType,
        previous_status: ConsentStatus,
        new_status: ConsentStatus,
    ) ConsentAuditEntry {
        return .{
            .audit_id = audit_id,
            .entity_id = entity_id,
            .purpose = purpose,
            .event_type = event_type,
            .previous_status = previous_status,
            .new_status = new_status,
            .timestamp = getCurrentTimestamp(),
            .actor_id = entity_id, // Default: user initiated
            .reason = [_]u8{0} ** 256,
            .reason_len = 0,
            .actor_ip_hash = 0,
        };
    }

    /// Set the reason string.
    pub fn setReason(self: *ConsentAuditEntry, rsn: []const u8) void {
        const len = @min(rsn.len, 255);
        stdx.copy_disjoint(.exact, u8, self.reason[0..len], rsn[0..len]);
        self.reason_len = @intCast(len);
    }

    /// Get the reason as a slice.
    pub fn getReason(self: *const ConsentAuditEntry) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

/// Entity consent state - all consents for a single entity.
pub const EntityConsents = struct {
    /// Entity ID.
    entity_id: u128,
    /// Array of consent records by purpose.
    consents: [12]?ConsentRecord,
    /// Count of active consents.
    active_count: u8,

    /// Initialize empty entity consents.
    pub fn init(entity_id: u128) EntityConsents {
        return .{
            .entity_id = entity_id,
            .consents = [_]?ConsentRecord{null} ** 12,
            .active_count = 0,
        };
    }

    /// Get consent for a specific purpose.
    pub fn getConsent(self: *const EntityConsents, purpose: ConsentPurpose) ?*const ConsentRecord {
        if (self.consents[@intFromEnum(purpose)]) |*record| {
            return record;
        }
        return null;
    }

    /// Set consent for a specific purpose.
    pub fn setConsent(self: *EntityConsents, record: ConsentRecord) void {
        const idx = @intFromEnum(record.purpose);
        const was_null = self.consents[idx] == null;
        self.consents[idx] = record;
        if (was_null) self.active_count += 1;
    }

    /// Check if entity has valid consent for purpose.
    pub fn hasValidConsent(self: *const EntityConsents, purpose: ConsentPurpose) bool {
        if (self.consents[@intFromEnum(purpose)]) |*record| {
            return record.isValid();
        }
        return false;
    }

    /// Withdraw all consents.
    pub fn withdrawAll(self: *EntityConsents) void {
        const now = getCurrentTimestamp();
        for (&self.consents) |*maybe_record| {
            if (maybe_record.*) |*record| {
                record.status = .withdrawn;
                record.modified_at = now;
            }
        }
    }
};

/// Configuration for consent manager.
pub const ConsentManagerConfig = struct {
    /// Whether to require double opt-in for all consents.
    require_double_opt_in: bool = false,
    /// Default consent expiration in seconds (0 = never).
    default_expiration_seconds: u64 = 0,
    /// Minimum age for consent without parental approval.
    minimum_consent_age: u8 = 16,
    /// Whether to auto-expire unverified consents.
    auto_expire_unverified: bool = true,
    /// Time limit for double opt-in verification (seconds).
    verification_timeout_seconds: u64 = 86400, // 24 hours
    /// Maximum audit entries to keep in memory.
    max_audit_entries: usize = MAX_AUDIT_ENTRIES,
};

/// Result of a consent operation.
pub const ConsentOperationResult = struct {
    /// Whether operation succeeded.
    success: bool,
    /// Error message if failed.
    error_message: [256]u8,
    /// Error message length.
    error_len: u8,
    /// Audit entry ID for this operation.
    audit_id: u64,
    /// Previous consent status (if applicable).
    previous_status: ?ConsentStatus,

    /// Create success result.
    pub fn ok(audit_id: u64, previous_status: ?ConsentStatus) ConsentOperationResult {
        return .{
            .success = true,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
            .audit_id = audit_id,
            .previous_status = previous_status,
        };
    }

    /// Create failure result.
    pub fn err(msg: []const u8) ConsentOperationResult {
        var result = ConsentOperationResult{
            .success = false,
            .error_message = [_]u8{0} ** 256,
            .error_len = 0,
            .audit_id = 0,
            .previous_status = null,
        };
        const len = @min(msg.len, 255);
        stdx.copy_disjoint(.exact, u8, result.error_message[0..len], msg[0..len]);
        result.error_len = @intCast(len);
        return result;
    }

    /// Get error message as slice.
    pub fn getError(self: *const ConsentOperationResult) []const u8 {
        return self.error_message[0..self.error_len];
    }
};

/// Statistics about consent status.
pub const ConsentStats = struct {
    /// Total entities with any consent records.
    total_entities: u64,
    /// Consents by status.
    by_status: [6]u64, // indexed by ConsentStatus
    /// Consents by purpose.
    by_purpose: [12]u64, // indexed by ConsentPurpose
    /// Total audit entries.
    total_audit_entries: u64,
    /// Consents granted in last 24h.
    granted_last_24h: u64,
    /// Consents withdrawn in last 24h.
    withdrawn_last_24h: u64,
    /// Pending verifications.
    pending_verifications: u64,
    /// Expired consents.
    expired_consents: u64,

    /// Initialize empty stats.
    pub fn init() ConsentStats {
        return .{
            .total_entities = 0,
            .by_status = [_]u64{0} ** 6,
            .by_purpose = [_]u64{0} ** 12,
            .total_audit_entries = 0,
            .granted_last_24h = 0,
            .withdrawn_last_24h = 0,
            .pending_verifications = 0,
            .expired_consents = 0,
        };
    }
};

/// GDPR Consent Manager - main API for consent management.
pub const ConsentManager = struct {
    /// Memory allocator.
    allocator: Allocator,
    /// Configuration.
    config: ConsentManagerConfig,
    /// Entity consent storage (entity_id -> EntityConsents).
    entity_consents: AutoHashMap(u128, EntityConsents),
    /// Audit log entries (circular buffer).
    audit_log: []ConsentAuditEntry,
    /// Current audit log write position.
    audit_write_pos: usize,
    /// Total audit entries ever written.
    audit_total: u64,
    /// Next audit ID.
    next_audit_id: u64,

    /// Initialize consent manager.
    pub fn init(allocator: Allocator, config: ConsentManagerConfig) !ConsentManager {
        const audit_log = try allocator.alloc(ConsentAuditEntry, config.max_audit_entries);
        @memset(audit_log, std.mem.zeroes(ConsentAuditEntry));

        return ConsentManager{
            .allocator = allocator,
            .config = config,
            .entity_consents = AutoHashMap(u128, EntityConsents).init(allocator),
            .audit_log = audit_log,
            .audit_write_pos = 0,
            .audit_total = 0,
            .next_audit_id = 1,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *ConsentManager) void {
        self.allocator.free(self.audit_log);
        self.entity_consents.deinit();
    }

    /// Record a consent grant or update.
    pub fn recordConsent(
        self: *ConsentManager,
        entity_id: u128,
        purpose: ConsentPurpose,
        status: ConsentStatus,
        notes: []const u8,
    ) ConsentOperationResult {
        // Validate child consent requirements
        if (purpose == .child_tracking and status == .granted) {
            if (self.config.require_double_opt_in) {
                // Child tracking requires verified parental consent
                const msg = "Child tracking requires parental consent";
                return ConsentOperationResult.err(msg);
            }
        }

        // Get or create entity consents
        var entity = self.entity_consents.get(entity_id) orelse EntityConsents.init(entity_id);

        // Get previous status for audit
        const previous_status: ?ConsentStatus = if (entity.getConsent(purpose)) |existing|
            existing.status
        else
            null;

        // Create new consent record
        var record = ConsentRecord.init(entity_id, purpose, status);
        record.setNotes(notes);

        // Set expiration if configured
        if (self.config.default_expiration_seconds > 0 and status == .granted) {
            const expiry_ns = self.config.default_expiration_seconds * 1_000_000_000;
            record.expires_at = getCurrentTimestamp() + expiry_ns;
        }

        // Handle double opt-in
        if (self.config.require_double_opt_in and status == .granted) {
            record.status = .pending;
            record.double_opt_in = false;
        }

        // Store the record
        entity.setConsent(record);
        self.entity_consents.put(entity_id, entity) catch {
            return ConsentOperationResult.err("Failed to store consent record");
        };

        // Create audit entry
        const event_type: ConsentEventType = if (previous_status == null)
            .consent_granted
        else if (status == .granted)
            .consent_renewed
        else
            .consent_modified;

        const audit_id = self.addAuditEntry(
            entity_id,
            purpose,
            event_type,
            previous_status orelse .pending,
            status,
            notes,
        );

        return ConsentOperationResult.ok(audit_id, previous_status);
    }

    /// Verify consent (complete double opt-in).
    pub fn verifyConsent(
        self: *ConsentManager,
        entity_id: u128,
        purpose: ConsentPurpose,
        verification_code: []const u8,
    ) ConsentOperationResult {
        _ = verification_code; // Verification code validation would be external

        var entity = self.entity_consents.get(entity_id) orelse {
            return ConsentOperationResult.err("Entity not found");
        };

        const idx = @intFromEnum(purpose);
        if (entity.consents[idx]) |*record| {
            if (record.status != .pending) {
                return ConsentOperationResult.err("Consent is not pending verification");
            }

            // Check verification timeout
            if (self.config.auto_expire_unverified) {
                const timeout_ns = self.config.verification_timeout_seconds * 1_000_000_000;
                if (getCurrentTimestamp() > record.modified_at + timeout_ns) {
                    record.status = .expired;
                    self.entity_consents.put(entity_id, entity) catch {};
                    return ConsentOperationResult.err("Verification timeout expired");
                }
            }

            const previous_status = record.status;
            record.status = .granted;
            record.double_opt_in = true;
            record.modified_at = getCurrentTimestamp();
            record.granted_at = getCurrentTimestamp();

            self.entity_consents.put(entity_id, entity) catch {
                return ConsentOperationResult.err("Failed to update consent record");
            };

            const audit_id = self.addAuditEntry(
                entity_id,
                purpose,
                .consent_verified,
                previous_status,
                .granted,
                "Double opt-in verified",
            );

            return ConsentOperationResult.ok(audit_id, previous_status);
        }

        return ConsentOperationResult.err("Consent record not found");
    }

    /// Withdraw consent for a specific purpose.
    pub fn withdrawConsent(
        self: *ConsentManager,
        entity_id: u128,
        purpose: ConsentPurpose,
        reason: []const u8,
    ) ConsentOperationResult {
        var entity = self.entity_consents.get(entity_id) orelse {
            return ConsentOperationResult.err("Entity not found");
        };

        const idx = @intFromEnum(purpose);
        if (entity.consents[idx]) |*record| {
            const previous_status = record.status;

            if (previous_status == .withdrawn) {
                return ConsentOperationResult.err("Consent already withdrawn");
            }

            record.status = .withdrawn;
            record.modified_at = getCurrentTimestamp();

            self.entity_consents.put(entity_id, entity) catch {
                return ConsentOperationResult.err("Failed to update consent record");
            };

            const audit_id = self.addAuditEntry(
                entity_id,
                purpose,
                .consent_withdrawn,
                previous_status,
                .withdrawn,
                reason,
            );

            return ConsentOperationResult.ok(audit_id, previous_status);
        }

        return ConsentOperationResult.err("Consent record not found");
    }

    /// Withdraw all consents for an entity (complete opt-out).
    pub fn withdrawAllConsents(
        self: *ConsentManager,
        entity_id: u128,
        reason: []const u8,
    ) ConsentOperationResult {
        var entity = self.entity_consents.get(entity_id) orelse {
            return ConsentOperationResult.err("Entity not found");
        };

        var any_withdrawn = false;
        var first_audit_id: u64 = 0;

        for (&entity.consents, 0..) |*maybe_record, idx| {
            if (maybe_record.*) |*record| {
                if (record.status != .withdrawn) {
                    const previous_status = record.status;
                    record.status = .withdrawn;
                    record.modified_at = getCurrentTimestamp();

                    const purpose: ConsentPurpose = @enumFromInt(idx);
                    const audit_id = self.addAuditEntry(
                        entity_id,
                        purpose,
                        .consent_withdrawn,
                        previous_status,
                        .withdrawn,
                        reason,
                    );

                    if (!any_withdrawn) {
                        first_audit_id = audit_id;
                        any_withdrawn = true;
                    }
                }
            }
        }

        if (!any_withdrawn) {
            return ConsentOperationResult.err("No active consents to withdraw");
        }

        self.entity_consents.put(entity_id, entity) catch {
            return ConsentOperationResult.err("Failed to update consent records");
        };

        return ConsentOperationResult.ok(first_audit_id, .granted);
    }

    /// Check if entity has valid consent for a purpose.
    pub fn hasValidConsent(self: *ConsentManager, entity_id: u128, purpose: ConsentPurpose) bool {
        const entity = self.entity_consents.get(entity_id) orelse return false;
        return entity.hasValidConsent(purpose);
    }

    /// Check consent and return detailed status.
    pub fn checkConsent(
        self: *ConsentManager,
        entity_id: u128,
        purpose: ConsentPurpose,
    ) ?*const ConsentRecord {
        const entity = self.entity_consents.get(entity_id) orelse return null;
        return entity.getConsent(purpose);
    }

    /// Get all consents for an entity.
    pub fn getEntityConsents(self: *ConsentManager, entity_id: u128) ?EntityConsents {
        return self.entity_consents.get(entity_id);
    }

    /// Expire stale consents (called periodically).
    pub fn expireStaleConsents(self: *ConsentManager) usize {
        var expired_count: usize = 0;
        const now = getCurrentTimestamp();

        var iter = self.entity_consents.iterator();
        while (iter.next()) |entry| {
            var entity = entry.value_ptr.*;
            var modified = false;

            for (&entity.consents, 0..) |*maybe_record, idx| {
                if (maybe_record.*) |*record| {
                    // Check expiration
                    const expired = record.expires_at > 0 and now >= record.expires_at;
                    if (expired and record.status == .granted) {
                        const previous_status = record.status;
                        record.status = .expired;
                        record.modified_at = now;
                        modified = true;
                        expired_count += 1;

                        const purpose: ConsentPurpose = @enumFromInt(idx);
                        _ = self.addAuditEntry(
                            record.entity_id,
                            purpose,
                            .consent_expired,
                            previous_status,
                            .expired,
                            "Consent expired automatically",
                        );
                    }

                    // Check verification timeout
                    if (record.status == .pending and self.config.auto_expire_unverified) {
                        const timeout_ns = self.config.verification_timeout_seconds * 1_000_000_000;
                        if (now > record.modified_at + timeout_ns) {
                            const previous_status = record.status;
                            record.status = .expired;
                            record.modified_at = now;
                            modified = true;
                            expired_count += 1;

                            const purpose: ConsentPurpose = @enumFromInt(idx);
                            _ = self.addAuditEntry(
                                record.entity_id,
                                purpose,
                                .consent_expired,
                                previous_status,
                                .expired,
                                "Verification timeout expired",
                            );
                        }
                    }
                }
            }

            if (modified) {
                self.entity_consents.put(entry.key_ptr.*, entity) catch {};
            }
        }

        return expired_count;
    }

    /// Get consent statistics.
    pub fn getStats(self: *ConsentManager) ConsentStats {
        var stats = ConsentStats.init();
        const now = getCurrentTimestamp();
        const day_ago = now -| (24 * 60 * 60 * 1_000_000_000);

        stats.total_entities = self.entity_consents.count();
        stats.total_audit_entries = self.audit_total;

        var iter = self.entity_consents.iterator();
        while (iter.next()) |entry| {
            const entity = entry.value_ptr.*;
            for (entity.consents, 0..) |maybe_record, idx| {
                if (maybe_record) |record| {
                    stats.by_status[@intFromEnum(record.status)] += 1;
                    stats.by_purpose[idx] += 1;

                    if (record.status == .pending) {
                        stats.pending_verifications += 1;
                    }
                    if (record.isExpired()) {
                        stats.expired_consents += 1;
                    }
                }
            }
        }

        // Count recent changes from audit log
        for (self.audit_log[0..@min(self.audit_write_pos, self.config.max_audit_entries)]) |entry| {
            if (entry.timestamp >= day_ago) {
                if (entry.event_type == .consent_granted) {
                    stats.granted_last_24h += 1;
                } else if (entry.event_type == .consent_withdrawn) {
                    stats.withdrawn_last_24h += 1;
                }
            }
        }

        return stats;
    }

    /// Get audit entries for an entity.
    pub fn getAuditHistory(
        self: *ConsentManager,
        entity_id: u128,
        buffer: []ConsentAuditEntry,
    ) usize {
        var count: usize = 0;
        const max_entries = @min(self.audit_write_pos, self.config.max_audit_entries);

        for (self.audit_log[0..max_entries]) |entry| {
            if (entry.entity_id == entity_id and count < buffer.len) {
                buffer[count] = entry;
                count += 1;
            }
        }

        return count;
    }

    /// Export all consents for an entity (for data portability).
    pub fn exportEntityData(
        self: *ConsentManager,
        entity_id: u128,
        allocator: Allocator,
    ) ![]u8 {
        const entity = self.entity_consents.get(entity_id) orelse {
            return error.EntityNotFound;
        };

        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();
        try writer.writeAll("# Consent Export for Entity\n\n");
        try writer.print("Entity ID: {x}\n", .{entity_id});
        try writer.print("Export Time: {}\n\n", .{getCurrentTimestamp()});

        try writer.writeAll("## Consent Records\n\n");
        for (entity.consents, 0..) |maybe_record, idx| {
            if (maybe_record) |record| {
                const purpose: ConsentPurpose = @enumFromInt(idx);
                try writer.print("### {s}\n", .{purpose.description()});
                try writer.print("- Status: {s}\n", .{@tagName(record.status)});
                try writer.print("- Granted: {}\n", .{record.granted_at});
                try writer.print("- Modified: {}\n", .{record.modified_at});
                if (record.expires_at > 0) {
                    try writer.print("- Expires: {}\n", .{record.expires_at});
                }
                try writer.print("- Source: {s}\n", .{record.getSource()});
                try writer.print("- Double Opt-In: {}\n", .{record.double_opt_in});
                if (record.notes_len > 0) {
                    try writer.print("- Notes: {s}\n", .{record.getNotes()});
                }
                try writer.writeAll("\n");
            }
        }

        // Add audit history
        try writer.writeAll("## Audit History\n\n");
        var audit_buffer: [100]ConsentAuditEntry = undefined;
        const audit_count = self.getAuditHistory(entity_id, &audit_buffer);
        for (audit_buffer[0..audit_count]) |entry| {
            try writer.print("- [{s}] {s}: {s} -> {s}\n", .{
                @tagName(entry.event_type),
                @tagName(entry.purpose),
                @tagName(entry.previous_status),
                @tagName(entry.new_status),
            });
            if (entry.reason_len > 0) {
                try writer.print("  Reason: {s}\n", .{entry.getReason()});
            }
        }

        return buffer.toOwnedSlice();
    }

    // Internal: Add audit entry.
    fn addAuditEntry(
        self: *ConsentManager,
        entity_id: u128,
        purpose: ConsentPurpose,
        event_type: ConsentEventType,
        previous_status: ConsentStatus,
        new_status: ConsentStatus,
        reason: []const u8,
    ) u64 {
        const audit_id = self.next_audit_id;
        self.next_audit_id += 1;

        var entry = ConsentAuditEntry.init(
            audit_id,
            entity_id,
            purpose,
            event_type,
            previous_status,
            new_status,
        );
        entry.setReason(reason);

        // Circular buffer write
        const idx = self.audit_write_pos % self.config.max_audit_entries;
        self.audit_log[idx] = entry;
        self.audit_write_pos += 1;
        self.audit_total += 1;

        return audit_id;
    }
};

/// Get current timestamp in nanoseconds.
fn getCurrentTimestamp() u64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Unit Tests
// ============================================================================

test "ConsentPurpose descriptions" {
    const testing = std.testing;

    try testing.expectEqualStrings(
        "Collection and storage of GPS coordinates",
        ConsentPurpose.location_tracking.description(),
    );
    try testing.expectEqualStrings(
        "Article 6(1)(a) - Consent",
        ConsentPurpose.location_tracking.gdprReference(),
    );
    try testing.expect(ConsentPurpose.location_tracking.requiresExplicitConsent());
    try testing.expect(!ConsentPurpose.emergency_services.requiresExplicitConsent());
}

test "ConsentStatus allows processing" {
    const testing = std.testing;

    try testing.expect(ConsentStatus.granted.allowsProcessing());
    try testing.expect(!ConsentStatus.withdrawn.allowsProcessing());
    try testing.expect(!ConsentStatus.pending.allowsProcessing());
    try testing.expect(!ConsentStatus.expired.allowsProcessing());
    try testing.expect(!ConsentStatus.denied.allowsProcessing());
    try testing.expect(!ConsentStatus.suspended.allowsProcessing());
}

test "ConsentRecord initialization and validity" {
    const testing = std.testing;

    var record = ConsentRecord.init(12345, .location_tracking, .granted);
    record.setSource("mobile_app_v2.1");
    record.setNotes("User accepted terms on signup");

    try testing.expectEqual(@as(u128, 12345), record.entity_id);
    try testing.expectEqual(ConsentPurpose.location_tracking, record.purpose);
    try testing.expectEqual(ConsentStatus.granted, record.status);
    try testing.expect(record.isValid());
    try testing.expect(!record.isExpired());
    try testing.expectEqualStrings("mobile_app_v2.1", record.getSource());
    try testing.expectEqualStrings("User accepted terms on signup", record.getNotes());
}

test "ConsentRecord expiration" {
    const testing = std.testing;

    var record = ConsentRecord.init(12345, .location_tracking, .granted);
    // Set expiration to past
    record.expires_at = 1; // 1 nanosecond since epoch (definitely past)

    try testing.expect(record.isExpired());
    try testing.expect(!record.isValid());
}

test "EntityConsents management" {
    const testing = std.testing;

    var entity = EntityConsents.init(12345);
    try testing.expectEqual(@as(u8, 0), entity.active_count);
    try testing.expect(!entity.hasValidConsent(.location_tracking));

    // Add consent
    const record = ConsentRecord.init(12345, .location_tracking, .granted);
    entity.setConsent(record);

    try testing.expectEqual(@as(u8, 1), entity.active_count);
    try testing.expect(entity.hasValidConsent(.location_tracking));
    try testing.expect(!entity.hasValidConsent(.marketing));

    // Withdraw all
    entity.withdrawAll();
    try testing.expect(!entity.hasValidConsent(.location_tracking));
}

test "ConsentManager basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ConsentManager.init(allocator, .{});
    defer manager.deinit();

    const entity_id: u128 = 0x123456789ABCDEF0;

    // Record consent
    const result = manager.recordConsent(
        entity_id,
        .location_tracking,
        .granted,
        "User accepted location tracking",
    );
    try testing.expect(result.success);
    try testing.expect(result.previous_status == null);

    // Check consent
    try testing.expect(manager.hasValidConsent(entity_id, .location_tracking));
    try testing.expect(!manager.hasValidConsent(entity_id, .marketing));

    // Get consent details
    const record = manager.checkConsent(entity_id, .location_tracking);
    try testing.expect(record != null);
    try testing.expectEqual(ConsentStatus.granted, record.?.status);
}

test "ConsentManager consent withdrawal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ConsentManager.init(allocator, .{});
    defer manager.deinit();

    const entity_id: u128 = 0xABCDEF0123456789;

    // Grant consent
    _ = manager.recordConsent(entity_id, .location_tracking, .granted, "Initial consent");
    try testing.expect(manager.hasValidConsent(entity_id, .location_tracking));

    // Withdraw consent
    const result = manager.withdrawConsent(
        entity_id,
        .location_tracking,
        "User requested opt-out",
    );
    try testing.expect(result.success);
    try testing.expectEqual(ConsentStatus.granted, result.previous_status.?);

    // Verify withdrawn
    try testing.expect(!manager.hasValidConsent(entity_id, .location_tracking));
    const record = manager.checkConsent(entity_id, .location_tracking);
    try testing.expectEqual(ConsentStatus.withdrawn, record.?.status);
}

test "ConsentManager withdraw all consents" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ConsentManager.init(allocator, .{});
    defer manager.deinit();

    const entity_id: u128 = 0x1111222233334444;

    // Grant multiple consents
    _ = manager.recordConsent(entity_id, .location_tracking, .granted, "Consent 1");
    _ = manager.recordConsent(entity_id, .location_analytics, .granted, "Consent 2");
    _ = manager.recordConsent(entity_id, .marketing, .granted, "Consent 3");

    try testing.expect(manager.hasValidConsent(entity_id, .location_tracking));
    try testing.expect(manager.hasValidConsent(entity_id, .location_analytics));
    try testing.expect(manager.hasValidConsent(entity_id, .marketing));

    // Withdraw all
    const result = manager.withdrawAllConsents(entity_id, "GDPR erasure request");
    try testing.expect(result.success);

    // All should be withdrawn
    try testing.expect(!manager.hasValidConsent(entity_id, .location_tracking));
    try testing.expect(!manager.hasValidConsent(entity_id, .location_analytics));
    try testing.expect(!manager.hasValidConsent(entity_id, .marketing));
}

test "ConsentManager audit history" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ConsentManager.init(allocator, .{});
    defer manager.deinit();

    const entity_id: u128 = 0x5555666677778888;

    // Perform operations
    _ = manager.recordConsent(entity_id, .location_tracking, .granted, "Grant");
    _ = manager.withdrawConsent(entity_id, .location_tracking, "Withdraw");

    // Get audit history
    var history: [10]ConsentAuditEntry = undefined;
    const count = manager.getAuditHistory(entity_id, &history);

    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(ConsentEventType.consent_granted, history[0].event_type);
    try testing.expectEqual(ConsentEventType.consent_withdrawn, history[1].event_type);
}

test "ConsentManager statistics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ConsentManager.init(allocator, .{});
    defer manager.deinit();

    // Create some consents
    _ = manager.recordConsent(0x1, .location_tracking, .granted, "");
    _ = manager.recordConsent(0x2, .location_tracking, .granted, "");
    _ = manager.recordConsent(0x3, .marketing, .withdrawn, "");

    const stats = manager.getStats();
    try testing.expectEqual(@as(u64, 3), stats.total_entities);
    try testing.expectEqual(@as(u64, 2), stats.by_status[@intFromEnum(ConsentStatus.granted)]);
    try testing.expectEqual(@as(u64, 1), stats.by_status[@intFromEnum(ConsentStatus.withdrawn)]);
}

test "ConsentManager with double opt-in" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ConsentManager.init(allocator, .{
        .require_double_opt_in = true,
    });
    defer manager.deinit();

    const entity_id: u128 = 0x9999AAAABBBBCCCC;

    // Record consent - should be pending
    _ = manager.recordConsent(entity_id, .location_tracking, .granted, "Initial request");

    // Should NOT be valid yet (pending verification)
    try testing.expect(!manager.hasValidConsent(entity_id, .location_tracking));

    const record = manager.checkConsent(entity_id, .location_tracking);
    try testing.expectEqual(ConsentStatus.pending, record.?.status);

    // Verify consent
    const result = manager.verifyConsent(entity_id, .location_tracking, "verification_code_123");
    try testing.expect(result.success);

    // Now should be valid
    try testing.expect(manager.hasValidConsent(entity_id, .location_tracking));
    const verified = manager.checkConsent(entity_id, .location_tracking);
    try testing.expectEqual(ConsentStatus.granted, verified.?.status);
    try testing.expect(verified.?.double_opt_in);
}

test "ConsentManager entity not found errors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ConsentManager.init(allocator, .{});
    defer manager.deinit();

    // Try operations on non-existent entity
    const result1 = manager.withdrawConsent(0x999, .location_tracking, "test");
    try testing.expect(!result1.success);
    try testing.expectEqualStrings("Entity not found", result1.getError());

    const result2 = manager.withdrawAllConsents(0x999, "test");
    try testing.expect(!result2.success);

    const result3 = manager.verifyConsent(0x999, .location_tracking, "code");
    try testing.expect(!result3.success);
}

test "ConsentAuditEntry initialization" {
    const testing = std.testing;

    var entry = ConsentAuditEntry.init(
        1,
        0x12345,
        .location_tracking,
        .consent_granted,
        .pending,
        .granted,
    );
    entry.setReason("User clicked accept button");

    try testing.expectEqual(@as(u64, 1), entry.audit_id);
    try testing.expectEqual(@as(u128, 0x12345), entry.entity_id);
    try testing.expectEqual(ConsentPurpose.location_tracking, entry.purpose);
    try testing.expectEqual(ConsentEventType.consent_granted, entry.event_type);
    try testing.expectEqual(ConsentStatus.pending, entry.previous_status);
    try testing.expectEqual(ConsentStatus.granted, entry.new_status);
    try testing.expectEqualStrings("User clicked accept button", entry.getReason());
}
