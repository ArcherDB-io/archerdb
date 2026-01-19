// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// Automated breach notification system implementing GDPR Articles 33-34.
// Provides breach detection, assessment, and notification delivery.

const std = @import("std");
const stdx = @import("stdx");
const Allocator = std.mem.Allocator;
const compliance_audit = @import("compliance_audit.zig");
const BreachIncident = compliance_audit.BreachIncident;
const AuditSeverity = compliance_audit.AuditSeverity;

/// GDPR notification deadline in nanoseconds (72 hours).
pub const AUTHORITY_NOTIFICATION_DEADLINE_NS: u64 = 72 * 60 * 60 * 1_000_000_000;

/// Maximum delay for user notification (48 hours recommended).
pub const USER_NOTIFICATION_DEADLINE_NS: u64 = 48 * 60 * 60 * 1_000_000_000;

/// Maximum notification content length.
pub const MAX_NOTIFICATION_CONTENT: usize = 8192;

/// Maximum recipients per notification.
pub const MAX_RECIPIENTS: usize = 1000;

/// Maximum contact info length.
pub const MAX_CONTACT_INFO: usize = 256;

/// Notification recipient type.
pub const RecipientType = enum(u8) {
    /// Supervisory authority (GDPR Article 33).
    supervisory_authority = 0,
    /// Affected data subject (GDPR Article 34).
    data_subject = 1,
    /// Data Protection Officer.
    dpo = 2,
    /// Internal security team.
    security_team = 3,
    /// Legal counsel.
    legal = 4,
    /// Executive management.
    management = 5,
    /// External incident response.
    incident_response = 6,
    /// Law enforcement (if required).
    law_enforcement = 7,
};

/// Notification delivery status.
pub const DeliveryStatus = enum(u8) {
    /// Notification pending.
    pending = 0,
    /// Notification queued for delivery.
    queued = 1,
    /// Notification sent, awaiting confirmation.
    sent = 2,
    /// Delivery confirmed.
    delivered = 3,
    /// Delivery failed.
    failed = 4,
    /// Recipient acknowledged.
    acknowledged = 5,
    /// Notification cancelled.
    cancelled = 6,
    /// Retry scheduled.
    retry_scheduled = 7,
};

/// Notification delivery channel.
pub const DeliveryChannel = enum(u8) {
    /// Email notification.
    email = 0,
    /// SMS notification.
    sms = 1,
    /// Push notification.
    push = 2,
    /// Postal mail (registered).
    postal = 3,
    /// In-app notification.
    in_app = 4,
    /// Phone call.
    phone = 5,
    /// Secure portal message.
    portal = 6,
    /// Official regulatory submission.
    regulatory_portal = 7,
};

/// Breach detection type.
pub const DetectionType = enum(u8) {
    /// Automated anomaly detection.
    anomaly_detection = 0,
    /// Access pattern violation.
    access_pattern = 1,
    /// Data exfiltration detected.
    exfiltration = 2,
    /// Unauthorized data exposure.
    data_exposure = 3,
    /// Failed authentication spike.
    auth_failure_spike = 4,
    /// Privilege escalation attempt.
    privilege_escalation = 5,
    /// External report received.
    external_report = 6,
    /// Manual discovery.
    manual = 7,
};

/// Breach assessment result.
pub const AssessmentResult = struct {
    /// Risk level (0-100).
    risk_score: u8,
    /// Number of affected individuals.
    affected_count: u64,
    /// Whether supervisory authority notification required.
    authority_notification_required: bool,
    /// Whether individual notification required.
    individual_notification_required: bool,
    /// Estimated impact severity.
    impact_severity: AuditSeverity,
    /// Data categories affected (bitmask).
    affected_data_categories: u16,
    /// Geographic regions affected (bitmask).
    affected_regions: u32,
    /// Assessment timestamp.
    assessed_at: u64,
    /// Assessor ID.
    assessor_id: u128,

    /// Data categories bitmask values.
    pub const DataCategory = struct {
        pub const location: u16 = 1 << 0;
        pub const identity: u16 = 1 << 1;
        pub const financial: u16 = 1 << 2;
        pub const health: u16 = 1 << 3;
        pub const biometric: u16 = 1 << 4;
        pub const communications: u16 = 1 << 5;
        pub const behavioral: u16 = 1 << 6;
        pub const credentials: u16 = 1 << 7;
    };

    /// Geographic regions bitmask values.
    pub const Region = struct {
        pub const eu: u32 = 1 << 0;
        pub const uk: u32 = 1 << 1;
        pub const us: u32 = 1 << 2;
        pub const canada: u32 = 1 << 3;
        pub const australia: u32 = 1 << 4;
        pub const japan: u32 = 1 << 5;
        pub const brazil: u32 = 1 << 6;
        pub const other: u32 = 1 << 7;
    };
};

/// Notification recipient.
pub const NotificationRecipient = struct {
    /// Recipient ID.
    recipient_id: u128,
    /// Recipient type.
    recipient_type: RecipientType,
    /// Preferred delivery channel.
    preferred_channel: DeliveryChannel,
    /// Contact info (email, phone, etc.).
    contact_info: [MAX_CONTACT_INFO]u8,
    /// Contact info length.
    contact_info_len: u16,
    /// Language preference (ISO 639-1).
    language: [2]u8,
    /// Whether recipient is active.
    active: bool,
    /// Creation timestamp.
    created_at: u64,

    /// Initialize recipient.
    pub fn init(
        recipient_id: u128,
        recipient_type: RecipientType,
        channel: DeliveryChannel,
    ) NotificationRecipient {
        return .{
            .recipient_id = recipient_id,
            .recipient_type = recipient_type,
            .preferred_channel = channel,
            .contact_info = [_]u8{0} ** MAX_CONTACT_INFO,
            .contact_info_len = 0,
            .language = "en".*,
            .active = true,
            .created_at = @intCast(std.time.nanoTimestamp()),
        };
    }

    /// Set contact info.
    pub fn setContactInfo(self: *NotificationRecipient, info: []const u8) void {
        const len = @min(info.len, MAX_CONTACT_INFO);
        stdx.copy_left(.inexact, u8, self.contact_info[0..len], info[0..len]);
        if (len < self.contact_info.len) {
            @memset(self.contact_info[len..], 0);
        }
        self.contact_info_len = @intCast(len);
    }

    /// Get contact info.
    pub fn getContactInfo(self: *const NotificationRecipient) []const u8 {
        return self.contact_info[0..self.contact_info_len];
    }
};

/// Breach notification record.
pub const BreachNotification = struct {
    /// Notification ID.
    notification_id: u64,
    /// Associated breach ID.
    breach_id: u64,
    /// Recipient ID.
    recipient_id: u128,
    /// Recipient type.
    recipient_type: RecipientType,
    /// Delivery channel used.
    channel: DeliveryChannel,
    /// Current delivery status.
    status: DeliveryStatus,
    /// Notification content.
    content: [MAX_NOTIFICATION_CONTENT]u8,
    /// Content length.
    content_len: u16,
    /// Creation timestamp.
    created_at: u64,
    /// Sent timestamp (0 if not sent).
    sent_at: u64,
    /// Delivery confirmation timestamp.
    delivered_at: u64,
    /// Acknowledgment timestamp.
    acknowledged_at: u64,
    /// Retry count.
    retry_count: u8,
    /// Last error code.
    last_error: u32,

    /// Initialize notification.
    pub fn init(
        notification_id: u64,
        breach_id: u64,
        recipient_id: u128,
        recipient_type: RecipientType,
    ) BreachNotification {
        return .{
            .notification_id = notification_id,
            .breach_id = breach_id,
            .recipient_id = recipient_id,
            .recipient_type = recipient_type,
            .channel = .email,
            .status = .pending,
            .content = [_]u8{0} ** MAX_NOTIFICATION_CONTENT,
            .content_len = 0,
            .created_at = @intCast(std.time.nanoTimestamp()),
            .sent_at = 0,
            .delivered_at = 0,
            .acknowledged_at = 0,
            .retry_count = 0,
            .last_error = 0,
        };
    }

    /// Set notification content.
    pub fn setContent(self: *BreachNotification, content_data: []const u8) void {
        const len = @min(content_data.len, MAX_NOTIFICATION_CONTENT);
        stdx.copy_disjoint(.inexact, u8, self.content[0..len], content_data[0..len]);
        self.content_len = @intCast(len);
    }

    /// Get notification content.
    pub fn getContent(self: BreachNotification) []const u8 {
        return self.content[0..self.content_len];
    }

    /// Mark as sent.
    pub fn markSent(self: *BreachNotification) void {
        self.status = .sent;
        self.sent_at = @intCast(std.time.nanoTimestamp());
    }

    /// Mark as delivered.
    pub fn markDelivered(self: *BreachNotification) void {
        self.status = .delivered;
        self.delivered_at = @intCast(std.time.nanoTimestamp());
    }

    /// Mark as acknowledged.
    pub fn markAcknowledged(self: *BreachNotification) void {
        self.status = .acknowledged;
        self.acknowledged_at = @intCast(std.time.nanoTimestamp());
    }

    /// Mark as failed.
    pub fn markFailed(self: *BreachNotification, error_code: u32) void {
        self.status = .failed;
        self.last_error = error_code;
        self.retry_count += 1;
    }

    /// Check if notification is overdue for authority.
    pub fn isAuthorityOverdue(self: BreachNotification, breach_detected_at: u64) bool {
        if (self.recipient_type != .supervisory_authority) return false;
        const now: u64 = @intCast(std.time.nanoTimestamp());
        return (now - breach_detected_at) > AUTHORITY_NOTIFICATION_DEADLINE_NS and
            self.status != .delivered and self.status != .acknowledged;
    }

    /// Check if notification is overdue for users.
    pub fn isUserOverdue(self: BreachNotification, breach_detected_at: u64) bool {
        if (self.recipient_type != .data_subject) return false;
        const now: u64 = @intCast(std.time.nanoTimestamp());
        return (now - breach_detected_at) > USER_NOTIFICATION_DEADLINE_NS and
            self.status != .delivered and self.status != .acknowledged;
    }
};

/// Access pattern for anomaly detection.
pub const AccessPattern = struct {
    /// Entity ID being monitored.
    entity_id: u128,
    /// Time window start.
    window_start: u64,
    /// Time window end.
    window_end: u64,
    /// Number of accesses in window.
    access_count: u32,
    /// Number of unique accessors.
    unique_accessors: u16,
    /// Number of failed attempts.
    failed_attempts: u16,
    /// Average access interval (nanoseconds).
    avg_interval_ns: u64,
    /// Data volume accessed (bytes).
    data_volume: u64,
    /// Geographic locations accessed from.
    geo_locations: u8,

    /// Check if pattern is anomalous.
    pub fn isAnomalous(self: AccessPattern, config: AnomalyConfig) bool {
        // Check access count threshold
        if (self.access_count > config.max_accesses_per_window) return true;

        // Check unique accessors threshold
        if (self.unique_accessors > config.max_unique_accessors) return true;

        // Check failed attempts threshold
        if (self.failed_attempts > config.max_failed_attempts) return true;

        // Check data volume threshold
        if (self.data_volume > config.max_data_volume) return true;

        // Check geographic spread
        if (self.geo_locations > config.max_geo_locations) return true;

        return false;
    }
};

/// Anomaly detection configuration.
pub const AnomalyConfig = struct {
    /// Maximum accesses per time window.
    max_accesses_per_window: u32 = 1000,
    /// Maximum unique accessors.
    max_unique_accessors: u16 = 10,
    /// Maximum failed attempts.
    max_failed_attempts: u16 = 5,
    /// Maximum data volume (bytes).
    max_data_volume: u64 = 100 * 1024 * 1024, // 100 MB
    /// Maximum geographic locations.
    max_geo_locations: u8 = 3,
    /// Monitoring window duration (nanoseconds).
    window_duration_ns: u64 = 60 * 60 * 1_000_000_000, // 1 hour
    /// Exfiltration threshold (bytes/second).
    exfiltration_threshold: u64 = 10 * 1024 * 1024, // 10 MB/s
    /// Alert on first anomaly.
    alert_on_first: bool = true,
};

/// Notification template.
pub const NotificationTemplate = struct {
    /// Template ID.
    template_id: u32,
    /// Template type.
    template_type: TemplateType,
    /// Language (ISO 639-1).
    language: [2]u8,
    /// Template content.
    content: [MAX_NOTIFICATION_CONTENT]u8,
    /// Content length.
    content_len: u16,

    pub const TemplateType = enum(u8) {
        /// Authority notification (GDPR Article 33).
        authority_initial = 0,
        /// Authority follow-up.
        authority_followup = 1,
        /// Individual notification (GDPR Article 34).
        individual_initial = 2,
        /// Individual follow-up.
        individual_followup = 3,
        /// DPO notification.
        dpo_alert = 4,
        /// Internal security alert.
        security_alert = 5,
        /// Management notification.
        management_briefing = 6,
        /// Incident closure.
        incident_closure = 7,
    };

    /// Initialize template.
    pub fn init(
        template_id: u32,
        template_type: TemplateType,
        language: [2]u8,
    ) NotificationTemplate {
        return .{
            .template_id = template_id,
            .template_type = template_type,
            .language = language,
            .content = [_]u8{0} ** MAX_NOTIFICATION_CONTENT,
            .content_len = 0,
        };
    }

    /// Set template content.
    pub fn setContent(self: *NotificationTemplate, content_data: []const u8) void {
        const len = @min(content_data.len, MAX_NOTIFICATION_CONTENT);
        stdx.copy_disjoint(.inexact, u8, self.content[0..len], content_data[0..len]);
        self.content_len = @intCast(len);
    }

    /// Get template content.
    pub fn getContent(self: NotificationTemplate) []const u8 {
        return self.content[0..self.content_len];
    }
};

/// Breach notification system.
pub const BreachNotificationSystem = struct {
    allocator: Allocator,
    /// Notification records.
    notifications: std.ArrayList(BreachNotification),
    /// Registered recipients.
    recipients: std.AutoHashMap(u128, NotificationRecipient),
    /// Notification templates.
    templates: std.AutoHashMap(u32, NotificationTemplate),
    /// Access patterns for monitoring.
    access_patterns: std.AutoHashMap(u128, AccessPattern),
    /// Anomaly detection configuration.
    anomaly_config: AnomalyConfig,
    /// Next notification ID.
    next_notification_id: u64,
    /// Next template ID.
    next_template_id: u32,
    /// Statistics.
    stats: Statistics,

    pub const Statistics = struct {
        notifications_sent: u64 = 0,
        notifications_delivered: u64 = 0,
        notifications_failed: u64 = 0,
        notifications_acknowledged: u64 = 0,
        breaches_detected: u64 = 0,
        anomalies_detected: u64 = 0,
        authority_notifications_overdue: u64 = 0,
        user_notifications_overdue: u64 = 0,
    };

    /// Initialize breach notification system.
    pub fn init(allocator: Allocator, config: AnomalyConfig) !BreachNotificationSystem {
        return .{
            .allocator = allocator,
            .notifications = std.ArrayList(BreachNotification).init(allocator),
            .recipients = std.AutoHashMap(u128, NotificationRecipient).init(allocator),
            .templates = std.AutoHashMap(u32, NotificationTemplate).init(allocator),
            .access_patterns = std.AutoHashMap(u128, AccessPattern).init(allocator),
            .anomaly_config = config,
            .next_notification_id = 1,
            .next_template_id = 1,
            .stats = .{},
        };
    }

    /// Deinitialize.
    pub fn deinit(self: *BreachNotificationSystem) void {
        self.notifications.deinit();
        self.recipients.deinit();
        self.templates.deinit();
        self.access_patterns.deinit();
    }

    /// Register a notification recipient.
    pub fn registerRecipient(
        self: *BreachNotificationSystem,
        recipient: NotificationRecipient,
    ) !void {
        try self.recipients.put(recipient.recipient_id, recipient);
    }

    /// Unregister a recipient.
    pub fn unregisterRecipient(self: *BreachNotificationSystem, recipient_id: u128) bool {
        return self.recipients.remove(recipient_id);
    }

    /// Get recipient by ID.
    pub fn getRecipient(
        self: *BreachNotificationSystem,
        recipient_id: u128,
    ) ?NotificationRecipient {
        return self.recipients.get(recipient_id);
    }

    /// Add notification template.
    pub fn addTemplate(self: *BreachNotificationSystem, template: NotificationTemplate) !u32 {
        const template_id = self.next_template_id;
        var t = template;
        t.template_id = template_id;
        try self.templates.put(template_id, t);
        self.next_template_id += 1;
        return template_id;
    }

    /// Get template by ID.
    pub fn getTemplate(self: *BreachNotificationSystem, template_id: u32) ?NotificationTemplate {
        return self.templates.get(template_id);
    }

    /// Record access pattern for monitoring.
    pub fn recordAccessPattern(
        self: *BreachNotificationSystem,
        pattern: AccessPattern,
    ) !?DetectionType {
        try self.access_patterns.put(pattern.entity_id, pattern);

        // Check for anomalies
        if (pattern.isAnomalous(self.anomaly_config)) {
            self.stats.anomalies_detected += 1;

            // Determine detection type
            if (pattern.failed_attempts > self.anomaly_config.max_failed_attempts) {
                return .auth_failure_spike;
            }
            if (pattern.data_volume > self.anomaly_config.max_data_volume) {
                return .exfiltration;
            }
            if (pattern.geo_locations > self.anomaly_config.max_geo_locations) {
                return .access_pattern;
            }
            return .anomaly_detection;
        }

        return null;
    }

    /// Assess breach and determine notification requirements.
    pub fn assessBreach(
        self: *BreachNotificationSystem,
        breach: BreachIncident,
        affected_count: u64,
        data_categories: u16,
        regions: u32,
        assessor_id: u128,
    ) AssessmentResult {
        _ = self;

        // Calculate risk score based on factors
        var risk_score: u16 = 0;

        // Breach type factor (0-40 points based on type severity)
        risk_score += switch (breach.breach_type) {
            .unauthorized_access => 25,
            .data_exfiltration => 40,
            .accidental_disclosure => 15,
            .lost_device => 20,
            .ransomware => 35,
            .insider_threat => 30,
            .api_vulnerability => 25,
            .unknown => 20,
        };

        // Affected count factor (0-30 points)
        if (affected_count > 100000) {
            risk_score += 30;
        } else if (affected_count > 10000) {
            risk_score += 25;
        } else if (affected_count > 1000) {
            risk_score += 20;
        } else if (affected_count > 100) {
            risk_score += 15;
        } else if (affected_count > 10) {
            risk_score += 10;
        } else {
            risk_score += 5;
        }

        // Data sensitivity factor (0-30 points)
        var data_score: u16 = 0;
        if (data_categories & AssessmentResult.DataCategory.biometric != 0) data_score += 10;
        if (data_categories & AssessmentResult.DataCategory.health != 0) data_score += 8;
        if (data_categories & AssessmentResult.DataCategory.financial != 0) data_score += 7;
        if (data_categories & AssessmentResult.DataCategory.credentials != 0) data_score += 10;
        if (data_categories & AssessmentResult.DataCategory.location != 0) data_score += 6;
        if (data_categories & AssessmentResult.DataCategory.identity != 0) data_score += 5;
        risk_score += @min(data_score, 30);

        const final_score: u8 = @intCast(@min(risk_score, 100));

        // Determine notification requirements per GDPR
        // Article 33: Authority notification unless breach unlikely to result in risk
        const authority_required = final_score >= 20 or affected_count > 0;

        // Article 34: Individual notification when high risk to rights/freedoms
        const biometric = (data_categories & AssessmentResult.DataCategory.biometric) != 0;
        const credentials = (data_categories & AssessmentResult.DataCategory.credentials) != 0;
        const individual_required = final_score >= 50 or biometric or credentials;

        // Derive severity from risk score
        const derived_severity: AuditSeverity = if (final_score >= 75)
            .critical
        else if (final_score >= 50)
            .warning
        else
            .info;

        return .{
            .risk_score = final_score,
            .affected_count = affected_count,
            .authority_notification_required = authority_required,
            .individual_notification_required = individual_required,
            .impact_severity = derived_severity,
            .affected_data_categories = data_categories,
            .affected_regions = regions,
            .assessed_at = @intCast(std.time.nanoTimestamp()),
            .assessor_id = assessor_id,
        };
    }

    /// Create notification for breach.
    pub fn createNotification(
        self: *BreachNotificationSystem,
        breach_id: u64,
        recipient_id: u128,
        recipient_type: RecipientType,
        content: []const u8,
    ) !u64 {
        const notification_id = self.next_notification_id;
        var notification = BreachNotification.init(
            notification_id,
            breach_id,
            recipient_id,
            recipient_type,
        );
        notification.setContent(content);

        // Set channel from recipient if registered
        if (self.recipients.get(recipient_id)) |recipient| {
            notification.channel = recipient.preferred_channel;
        }

        try self.notifications.append(notification);
        self.next_notification_id += 1;

        return notification_id;
    }

    /// Create notifications for all affected entities.
    pub fn createBulkNotifications(
        self: *BreachNotificationSystem,
        breach_id: u64,
        affected_entities: []const u128,
        content: []const u8,
    ) !u64 {
        var count: u64 = 0;
        for (affected_entities) |entity_id| {
            _ = try self.createNotification(breach_id, entity_id, .data_subject, content);
            count += 1;
        }
        return count;
    }

    /// Mark notification as sent.
    pub fn markNotificationSent(self: *BreachNotificationSystem, notification_id: u64) bool {
        for (self.notifications.items) |*notification| {
            if (notification.notification_id == notification_id) {
                notification.markSent();
                self.stats.notifications_sent += 1;
                return true;
            }
        }
        return false;
    }

    /// Mark notification as delivered.
    pub fn markNotificationDelivered(self: *BreachNotificationSystem, notification_id: u64) bool {
        for (self.notifications.items) |*notification| {
            if (notification.notification_id == notification_id) {
                notification.markDelivered();
                self.stats.notifications_delivered += 1;
                return true;
            }
        }
        return false;
    }

    /// Mark notification as acknowledged.
    pub fn markNotificationAcknowledged(
        self: *BreachNotificationSystem,
        notification_id: u64,
    ) bool {
        for (self.notifications.items) |*notification| {
            if (notification.notification_id == notification_id) {
                notification.markAcknowledged();
                self.stats.notifications_acknowledged += 1;
                return true;
            }
        }
        return false;
    }

    /// Mark notification as failed.
    pub fn markNotificationFailed(
        self: *BreachNotificationSystem,
        notification_id: u64,
        error_code: u32,
    ) bool {
        for (self.notifications.items) |*notification| {
            if (notification.notification_id == notification_id) {
                notification.markFailed(error_code);
                self.stats.notifications_failed += 1;
                return true;
            }
        }
        return false;
    }

    /// Get pending notifications.
    pub fn getPendingNotifications(
        self: *BreachNotificationSystem,
        buffer: []BreachNotification,
    ) usize {
        var count: usize = 0;
        for (self.notifications.items) |notification| {
            if (notification.status == .pending or
                notification.status == .retry_scheduled)
            {
                if (count < buffer.len) {
                    buffer[count] = notification;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Get notifications by breach ID.
    pub fn getBreachNotifications(
        self: *BreachNotificationSystem,
        breach_id: u64,
        buffer: []BreachNotification,
    ) usize {
        var count: usize = 0;
        for (self.notifications.items) |notification| {
            if (notification.breach_id == breach_id) {
                if (count < buffer.len) {
                    buffer[count] = notification;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Check for overdue notifications.
    pub fn checkOverdueNotifications(
        self: *BreachNotificationSystem,
        breach_detected_at: u64,
    ) OverdueReport {
        var report = OverdueReport{};

        for (self.notifications.items) |notification| {
            if (notification.isAuthorityOverdue(breach_detected_at)) {
                report.authority_overdue += 1;
            }
            if (notification.isUserOverdue(breach_detected_at)) {
                report.user_overdue += 1;
            }
        }

        self.stats.authority_notifications_overdue = report.authority_overdue;
        self.stats.user_notifications_overdue = report.user_overdue;

        return report;
    }

    pub const OverdueReport = struct {
        authority_overdue: u64 = 0,
        user_overdue: u64 = 0,
    };

    /// Generate notification content from template.
    pub fn generateNotificationContent(
        self: *BreachNotificationSystem,
        template_type: NotificationTemplate.TemplateType,
        language: [2]u8,
        breach: BreachIncident,
        assessment: AssessmentResult,
        buffer: []u8,
    ) usize {
        // Find matching template
        var template_content: ?[]const u8 = null;
        var iter = self.templates.iterator();
        while (iter.next()) |entry| {
            const type_match = entry.value_ptr.template_type == template_type;
            const lang_match = std.mem.eql(u8, &entry.value_ptr.language, &language);
            if (type_match and lang_match) {
                template_content = entry.value_ptr.getContent();
                break;
            }
        }

        // Generate default content if no template found
        if (template_content == null) {
            return generateDefaultContent(breach, assessment, buffer);
        }

        // For now, return template as-is (in production, would substitute variables)
        const content = template_content.?;
        const len = @min(content.len, buffer.len);
        stdx.copy_disjoint(.inexact, u8, buffer[0..len], content[0..len]);
        return len;
    }

    /// Generate default notification content.
    fn generateDefaultContent(
        breach: BreachIncident,
        assessment: AssessmentResult,
        buffer: []u8,
    ) usize {
        _ = breach;
        _ = assessment;
        const default_msg =
            "SECURITY NOTICE: A data breach affecting your information has been detected. " ++
            "We are taking immediate steps to address this incident. " ++
            "For more information, please contact our Data Protection Officer.";
        const len = @min(default_msg.len, buffer.len);
        stdx.copy_disjoint(.inexact, u8, buffer[0..len], default_msg[0..len]);
        return len;
    }

    /// Get system statistics.
    pub fn getStatistics(self: *BreachNotificationSystem) Statistics {
        return self.stats;
    }

    /// Generate compliance report summary.
    pub fn generateComplianceReport(self: *BreachNotificationSystem) ComplianceReportSummary {
        var authority_count: u64 = 0;
        var authority_on_time: u64 = 0;
        var individual_count: u64 = 0;
        var individual_on_time: u64 = 0;

        for (self.notifications.items) |notification| {
            switch (notification.recipient_type) {
                .supervisory_authority => {
                    authority_count += 1;
                    if (notification.status == .delivered or notification.status == .acknowledged) {
                        authority_on_time += 1;
                    }
                },
                .data_subject => {
                    individual_count += 1;
                    if (notification.status == .delivered or notification.status == .acknowledged) {
                        individual_on_time += 1;
                    }
                },
                else => {},
            }
        }

        return .{
            .total_notifications = @intCast(self.notifications.items.len),
            .authority_notifications = authority_count,
            .authority_compliance_rate = if (authority_count > 0)
                @as(u8, @intCast((authority_on_time * 100) / authority_count))
            else
                100,
            .individual_notifications = individual_count,
            .individual_compliance_rate = if (individual_count > 0)
                @as(u8, @intCast((individual_on_time * 100) / individual_count))
            else
                100,
            .pending_notifications = self.stats.notifications_sent -
                self.stats.notifications_delivered,
            .failed_notifications = self.stats.notifications_failed,
        };
    }

    pub const ComplianceReportSummary = struct {
        total_notifications: u64,
        authority_notifications: u64,
        authority_compliance_rate: u8,
        individual_notifications: u64,
        individual_compliance_rate: u8,
        pending_notifications: u64,
        failed_notifications: u64,
    };
};

// ============================================================================
// Unit Tests
// ============================================================================

test "NotificationRecipient initialization" {
    const testing = std.testing;

    var recipient = NotificationRecipient.init(0x12345, .supervisory_authority, .regulatory_portal);
    try testing.expectEqual(@as(u128, 0x12345), recipient.recipient_id);
    try testing.expectEqual(RecipientType.supervisory_authority, recipient.recipient_type);
    try testing.expectEqual(DeliveryChannel.regulatory_portal, recipient.preferred_channel);
    try testing.expect(recipient.active);

    recipient.setContactInfo("dpa@example.gov");
    try testing.expectEqual(@as(u16, 15), recipient.contact_info_len);
    try testing.expectEqualStrings("dpa@example.gov", recipient.getContactInfo());
}

test "BreachNotification lifecycle" {
    const testing = std.testing;

    var notification = BreachNotification.init(1, 100, 0x12345, .data_subject);
    try testing.expectEqual(DeliveryStatus.pending, notification.status);
    try testing.expectEqual(@as(u64, 0), notification.sent_at);

    notification.markSent();
    try testing.expectEqual(DeliveryStatus.sent, notification.status);
    try testing.expect(notification.sent_at > 0);

    notification.markDelivered();
    try testing.expectEqual(DeliveryStatus.delivered, notification.status);
    try testing.expect(notification.delivered_at > 0);

    notification.markAcknowledged();
    try testing.expectEqual(DeliveryStatus.acknowledged, notification.status);
    try testing.expect(notification.acknowledged_at > 0);
}

test "BreachNotification failure handling" {
    const testing = std.testing;

    var notification = BreachNotification.init(1, 100, 0x12345, .data_subject);
    notification.markFailed(500);
    try testing.expectEqual(DeliveryStatus.failed, notification.status);
    try testing.expectEqual(@as(u32, 500), notification.last_error);
    try testing.expectEqual(@as(u8, 1), notification.retry_count);

    notification.markFailed(503);
    try testing.expectEqual(@as(u8, 2), notification.retry_count);
}

test "AccessPattern anomaly detection" {
    const testing = std.testing;

    const config = AnomalyConfig{
        .max_accesses_per_window = 1000,
        .max_failed_attempts = 5,
        .max_data_volume = 100 * 1024 * 1024,
    };

    const normal_pattern = AccessPattern{
        .entity_id = 0x12345,
        .window_start = 0,
        .window_end = 0,
        .access_count = 100,
        .unique_accessors = 2,
        .failed_attempts = 1,
        .avg_interval_ns = 0,
        .data_volume = 1024 * 1024,
        .geo_locations = 1,
    };

    try testing.expect(!normal_pattern.isAnomalous(config));

    const anomalous_pattern = AccessPattern{
        .entity_id = 0x12345,
        .window_start = 0,
        .window_end = 0,
        .access_count = 5000, // Exceeds threshold
        .unique_accessors = 2,
        .failed_attempts = 10, // Exceeds threshold
        .avg_interval_ns = 0,
        .data_volume = 1024 * 1024,
        .geo_locations = 1,
    };

    try testing.expect(anomalous_pattern.isAnomalous(config));
}

test "BreachNotificationSystem initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    try testing.expectEqual(@as(u64, 1), system.next_notification_id);
    try testing.expectEqual(@as(u64, 0), system.stats.notifications_sent);
}

test "BreachNotificationSystem recipient management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    var recipient = NotificationRecipient.init(0x12345, .dpo, .email);
    recipient.setContactInfo("dpo@company.com");

    try system.registerRecipient(recipient);

    const retrieved = system.getRecipient(0x12345);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("dpo@company.com", retrieved.?.getContactInfo());

    try testing.expect(system.unregisterRecipient(0x12345));
    try testing.expect(system.getRecipient(0x12345) == null);
}

test "BreachNotificationSystem notification creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    const notification_id = try system.createNotification(
        100,
        0x12345,
        .supervisory_authority,
        "Breach notification content",
    );

    try testing.expectEqual(@as(u64, 1), notification_id);

    var buffer: [10]BreachNotification = undefined;
    const count = system.getBreachNotifications(100, &buffer);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("Breach notification content", buffer[0].getContent());
}

test "BreachNotificationSystem bulk notifications" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    const entities = [_]u128{ 0x1, 0x2, 0x3, 0x4, 0x5 };
    const count = try system.createBulkNotifications(100, &entities, "Affected user notification");

    try testing.expectEqual(@as(u64, 5), count);

    var buffer: [10]BreachNotification = undefined;
    const retrieved = system.getPendingNotifications(&buffer);
    try testing.expectEqual(@as(usize, 5), retrieved);
}

test "BreachNotificationSystem notification status tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    const notification_id = try system.createNotification(100, 0x12345, .data_subject, "Test");

    try testing.expect(system.markNotificationSent(notification_id));
    try testing.expectEqual(@as(u64, 1), system.stats.notifications_sent);

    try testing.expect(system.markNotificationDelivered(notification_id));
    try testing.expectEqual(@as(u64, 1), system.stats.notifications_delivered);

    try testing.expect(system.markNotificationAcknowledged(notification_id));
    try testing.expectEqual(@as(u64, 1), system.stats.notifications_acknowledged);
}

test "BreachNotificationSystem breach assessment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    var breach = BreachIncident.init(1, .unauthorized_access);
    breach.entities_affected = 1000;

    const assessment = system.assessBreach(
        breach,
        1000,
        AssessmentResult.DataCategory.location | AssessmentResult.DataCategory.identity,
        AssessmentResult.Region.eu,
        0x99999,
    );

    try testing.expect(assessment.risk_score > 0);
    try testing.expect(assessment.authority_notification_required);
    try testing.expectEqual(@as(u64, 1000), assessment.affected_count);
}

test "BreachNotificationSystem high risk assessment triggers individual notification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    var breach = BreachIncident.init(1, .data_exfiltration);
    breach.entities_affected = 100000;

    // Include biometric data - should trigger individual notification
    const assessment = system.assessBreach(
        breach,
        100000,
        AssessmentResult.DataCategory.biometric | AssessmentResult.DataCategory.credentials,
        AssessmentResult.Region.eu | AssessmentResult.Region.us,
        0x99999,
    );

    try testing.expect(assessment.individual_notification_required);
    try testing.expect(assessment.risk_score >= 50);
}

test "BreachNotificationSystem anomaly detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{
        .max_failed_attempts = 5,
    });
    defer system.deinit();

    // Normal pattern - no anomaly
    const normal = AccessPattern{
        .entity_id = 0x12345,
        .window_start = 0,
        .window_end = 0,
        .access_count = 10,
        .unique_accessors = 1,
        .failed_attempts = 2,
        .avg_interval_ns = 0,
        .data_volume = 1024,
        .geo_locations = 1,
    };

    const normal_result = try system.recordAccessPattern(normal);
    try testing.expect(normal_result == null);

    // Anomalous pattern - should detect
    const anomalous = AccessPattern{
        .entity_id = 0x67890,
        .window_start = 0,
        .window_end = 0,
        .access_count = 10,
        .unique_accessors = 1,
        .failed_attempts = 10, // Exceeds threshold
        .avg_interval_ns = 0,
        .data_volume = 1024,
        .geo_locations = 1,
    };

    const anomaly_result = try system.recordAccessPattern(anomalous);
    try testing.expect(anomaly_result != null);
    try testing.expectEqual(DetectionType.auth_failure_spike, anomaly_result.?);
    try testing.expectEqual(@as(u64, 1), system.stats.anomalies_detected);
}

test "BreachNotificationSystem compliance report" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    // Create authority notification
    const auth_id = try system.createNotification(
        100,
        0x1,
        .supervisory_authority,
        "Authority notice",
    );
    _ = try system.createNotification(100, 0x2, .data_subject, "User notice 1");
    _ = try system.createNotification(100, 0x3, .data_subject, "User notice 2");

    // Mark authority as delivered
    _ = system.markNotificationSent(auth_id);
    _ = system.markNotificationDelivered(auth_id);

    const report = system.generateComplianceReport();
    try testing.expectEqual(@as(u64, 3), report.total_notifications);
    try testing.expectEqual(@as(u64, 1), report.authority_notifications);
    try testing.expectEqual(@as(u8, 100), report.authority_compliance_rate);
    try testing.expectEqual(@as(u64, 2), report.individual_notifications);
}

test "NotificationTemplate management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var system = try BreachNotificationSystem.init(allocator, .{});
    defer system.deinit();

    var template = NotificationTemplate.init(0, .authority_initial, "en".*);
    template.setContent("Dear Authority, we report a data breach...");

    const template_id = try system.addTemplate(template);
    try testing.expectEqual(@as(u32, 1), template_id);

    const retrieved = system.getTemplate(template_id);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(
        "Dear Authority, we report a data breach...",
        retrieved.?.getContent(),
    );
}
