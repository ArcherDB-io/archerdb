// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// International data transfer safeguards per GDPR Chapter V.
// Implements transfer mechanisms, data residency controls, and compliance documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum description/justification length.
pub const MAX_DESCRIPTION: usize = 1024;

/// Maximum country code length (ISO 3166-1 alpha-2).
pub const COUNTRY_CODE_LEN: usize = 2;

/// Maximum region code length.
pub const REGION_CODE_LEN: usize = 8;

/// Data transfer adequacy status (per EU Commission).
pub const AdequacyStatus = enum(u8) {
    /// Country has EU adequacy decision.
    adequate = 0,
    /// Country lacks adequacy decision.
    not_adequate = 1,
    /// Partial adequacy (specific sectors).
    partial = 2,
    /// Adequacy under review.
    under_review = 3,
    /// Unknown/not assessed.
    unknown = 4,
};

/// Transfer mechanism type (GDPR Article 46).
pub const TransferMechanism = enum(u8) {
    /// EU Commission adequacy decision (Article 45).
    adequacy_decision = 0,
    /// Standard Contractual Clauses (Article 46(2)(c)).
    standard_contractual_clauses = 1,
    /// Binding Corporate Rules (Article 46(2)(b)).
    binding_corporate_rules = 2,
    /// Approved certification mechanism (Article 46(2)(f)).
    certification = 3,
    /// Approved code of conduct (Article 46(2)(e)).
    code_of_conduct = 4,
    /// Ad hoc contractual clauses (Article 46(3)(a)).
    ad_hoc_clauses = 5,
    /// Explicit consent (Article 49(1)(a)).
    explicit_consent = 6,
    /// Contract performance (Article 49(1)(b)).
    contract_performance = 7,
    /// Public interest (Article 49(1)(d)).
    public_interest = 8,
    /// Legal claims (Article 49(1)(e)).
    legal_claims = 9,
    /// Vital interests (Article 49(1)(f)).
    vital_interests = 10,
    /// Public register (Article 49(1)(g)).
    public_register = 11,
};

/// Data residency requirement level.
pub const ResidencyRequirement = enum(u8) {
    /// No residency requirement.
    none = 0,
    /// Soft preference for local storage.
    preferred = 1,
    /// Required for sensitive data only.
    sensitive_only = 2,
    /// Required for all data.
    required = 3,
    /// Strict - no replication outside region.
    strict = 4,
    /// Legal mandate - enforced by law.
    legal_mandate = 5,
};

/// Transfer restriction reason.
pub const TransferRestriction = enum(u8) {
    /// No restriction.
    none = 0,
    /// No adequate safeguards.
    no_safeguards = 1,
    /// Data residency violation.
    residency_violation = 2,
    /// Missing consent for transfer.
    missing_consent = 3,
    /// Recipient not approved.
    recipient_not_approved = 4,
    /// Sensitive data category.
    sensitive_data = 5,
    /// Legal prohibition.
    legal_prohibition = 6,
    /// Transfer assessment required.
    assessment_required = 7,
};

/// Geographic region definition.
pub const GeoRegion = struct {
    /// Region identifier.
    region_id: u32,
    /// Region code (e.g., "EU", "US", "APAC").
    code: [REGION_CODE_LEN]u8,
    /// Code length.
    code_len: u8,
    /// Region name.
    name: [64]u8,
    /// Name length.
    name_len: u8,
    /// Adequacy status.
    adequacy_status: AdequacyStatus,
    /// Data residency requirement.
    residency_requirement: ResidencyRequirement,
    /// Member countries (bitmask or list reference).
    member_countries: u64,
    /// Is EU/EEA region.
    is_eu_eea: bool,
    /// Is active.
    active: bool,

    /// Well-known region identifiers.
    pub const WellKnown = struct {
        pub const eu: u32 = 1;
        pub const eea: u32 = 2;
        pub const uk: u32 = 3;
        pub const us: u32 = 4;
        pub const canada: u32 = 5;
        pub const japan: u32 = 6;
        pub const australia: u32 = 7;
        pub const new_zealand: u32 = 8;
        pub const switzerland: u32 = 9;
        pub const israel: u32 = 10;
        pub const south_korea: u32 = 11;
        pub const argentina: u32 = 12;
    };

    /// Initialize region.
    pub fn init(region_id: u32, code: []const u8, adequacy: AdequacyStatus) GeoRegion {
        var r = GeoRegion{
            .region_id = region_id,
            .code = [_]u8{0} ** REGION_CODE_LEN,
            .code_len = 0,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .adequacy_status = adequacy,
            .residency_requirement = .none,
            .member_countries = 0,
            .is_eu_eea = false,
            .active = true,
        };
        const len = @min(code.len, REGION_CODE_LEN);
        @memcpy(r.code[0..len], code[0..len]);
        r.code_len = @intCast(len);
        return r;
    }

    /// Set name.
    pub fn setName(self: *GeoRegion, n: []const u8) void {
        const len = @min(n.len, 64);
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = @intCast(len);
    }

    /// Get code.
    pub fn getCode(self: GeoRegion) []const u8 {
        return self.code[0..self.code_len];
    }

    /// Get name.
    pub fn getName(self: GeoRegion) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Transfer recipient (third party or internal entity).
pub const TransferRecipient = struct {
    /// Recipient identifier.
    recipient_id: u128,
    /// Organization name.
    name: [128]u8,
    /// Name length.
    name_len: u8,
    /// Country code (ISO 3166-1 alpha-2).
    country_code: [COUNTRY_CODE_LEN]u8,
    /// Region ID.
    region_id: u32,
    /// Recipient type.
    recipient_type: RecipientType,
    /// Approved transfer mechanisms.
    approved_mechanisms: u16,
    /// Active SCCs.
    has_scc: bool,
    /// SCC version/reference.
    scc_reference: [32]u8,
    /// SCC reference length.
    scc_ref_len: u8,
    /// BCR approved.
    has_bcr: bool,
    /// Certification status.
    certified: bool,
    /// Last verification date.
    last_verified: u64,
    /// Is approved recipient.
    approved: bool,

    pub const RecipientType = enum(u8) {
        /// Internal group entity.
        internal = 0,
        /// Processor (data processing agreement).
        processor = 1,
        /// Controller.
        controller = 2,
        /// Joint controller.
        joint_controller = 3,
        /// Sub-processor.
        sub_processor = 4,
    };

    /// Initialize recipient.
    pub fn init(recipient_id: u128, country_code: [2]u8, recipient_type: RecipientType) TransferRecipient {
        return .{
            .recipient_id = recipient_id,
            .name = [_]u8{0} ** 128,
            .name_len = 0,
            .country_code = country_code,
            .region_id = 0,
            .recipient_type = recipient_type,
            .approved_mechanisms = 0,
            .has_scc = false,
            .scc_reference = [_]u8{0} ** 32,
            .scc_ref_len = 0,
            .has_bcr = false,
            .certified = false,
            .last_verified = 0,
            .approved = false,
        };
    }

    /// Set name.
    pub fn setName(self: *TransferRecipient, n: []const u8) void {
        const len = @min(n.len, 128);
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = @intCast(len);
    }

    /// Get name.
    pub fn getName(self: TransferRecipient) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Add approved mechanism.
    pub fn addApprovedMechanism(self: *TransferRecipient, mechanism: TransferMechanism) void {
        self.approved_mechanisms |= @as(u16, 1) << @intCast(@intFromEnum(mechanism));
    }

    /// Check if mechanism is approved.
    pub fn hasMechanism(self: TransferRecipient, mechanism: TransferMechanism) bool {
        const shift: u4 = @intCast(@intFromEnum(mechanism));
        return (self.approved_mechanisms & (@as(u16, 1) << shift)) != 0;
    }

    /// Set SCC reference.
    pub fn setSCCReference(self: *TransferRecipient, reference: []const u8) void {
        const len = @min(reference.len, 32);
        @memcpy(self.scc_reference[0..len], reference[0..len]);
        self.scc_ref_len = @intCast(len);
        self.has_scc = true;
    }
};

/// Data transfer record.
pub const DataTransfer = struct {
    /// Transfer identifier.
    transfer_id: u64,
    /// Source region ID.
    source_region: u32,
    /// Destination region ID.
    destination_region: u32,
    /// Recipient ID.
    recipient_id: u128,
    /// Transfer mechanism used.
    mechanism: TransferMechanism,
    /// Data categories transferred (bitmask).
    data_categories: u16,
    /// Number of records transferred.
    record_count: u64,
    /// Transfer timestamp.
    transferred_at: u64,
    /// Transfer status.
    status: TransferStatus,
    /// Purpose of transfer.
    purpose: [MAX_DESCRIPTION]u8,
    /// Purpose length.
    purpose_len: u16,
    /// Legal basis reference.
    legal_basis: [64]u8,
    /// Legal basis length.
    legal_basis_len: u8,

    pub const TransferStatus = enum(u8) {
        /// Transfer pending approval.
        pending = 0,
        /// Transfer approved.
        approved = 1,
        /// Transfer completed.
        completed = 2,
        /// Transfer blocked.
        blocked = 3,
        /// Transfer failed.
        failed = 4,
        /// Transfer cancelled.
        cancelled = 5,
    };

    /// Data category flags.
    pub const DataCategory = struct {
        pub const location: u16 = 1 << 0;
        pub const identity: u16 = 1 << 1;
        pub const movement_history: u16 = 1 << 2;
        pub const speed_data: u16 = 1 << 3;
        pub const route_data: u16 = 1 << 4;
        pub const dwell_time: u16 = 1 << 5;
        pub const poi_visits: u16 = 1 << 6;
        pub const device_data: u16 = 1 << 7;
    };

    /// Initialize transfer record.
    pub fn init(transfer_id: u64, source: u32, destination: u32, recipient_id: u128) DataTransfer {
        return .{
            .transfer_id = transfer_id,
            .source_region = source,
            .destination_region = destination,
            .recipient_id = recipient_id,
            .mechanism = .standard_contractual_clauses,
            .data_categories = 0,
            .record_count = 0,
            .transferred_at = 0,
            .status = .pending,
            .purpose = [_]u8{0} ** MAX_DESCRIPTION,
            .purpose_len = 0,
            .legal_basis = [_]u8{0} ** 64,
            .legal_basis_len = 0,
        };
    }

    /// Set purpose.
    pub fn setPurpose(self: *DataTransfer, p: []const u8) void {
        const len = @min(p.len, MAX_DESCRIPTION);
        @memcpy(self.purpose[0..len], p[0..len]);
        self.purpose_len = @intCast(len);
    }

    /// Get purpose.
    pub fn getPurpose(self: DataTransfer) []const u8 {
        return self.purpose[0..self.purpose_len];
    }

    /// Set legal basis.
    pub fn setLegalBasis(self: *DataTransfer, basis: []const u8) void {
        const len = @min(basis.len, 64);
        @memcpy(self.legal_basis[0..len], basis[0..len]);
        self.legal_basis_len = @intCast(len);
    }

    /// Mark completed.
    pub fn complete(self: *DataTransfer) void {
        self.status = .completed;
        self.transferred_at = getCurrentTimestamp();
    }

    /// Block transfer.
    pub fn block(self: *DataTransfer) void {
        self.status = .blocked;
    }
};

/// Data residency policy for an entity.
pub const ResidencyPolicy = struct {
    /// Policy identifier.
    policy_id: u32,
    /// Entity ID this applies to.
    entity_id: u128,
    /// Required region ID.
    required_region: u32,
    /// Residency level.
    residency_level: ResidencyRequirement,
    /// Allow replication to these regions (bitmask).
    allowed_replication_regions: u64,
    /// Block replication to these regions (bitmask).
    blocked_regions: u64,
    /// Effective date.
    effective_from: u64,
    /// Expiry date (0 for no expiry).
    expires_at: u64,
    /// Is active.
    active: bool,
    /// Justification for policy.
    justification: [MAX_DESCRIPTION]u8,
    /// Justification length.
    justification_len: u16,

    /// Initialize policy.
    pub fn init(policy_id: u32, entity_id: u128, required_region: u32) ResidencyPolicy {
        return .{
            .policy_id = policy_id,
            .entity_id = entity_id,
            .required_region = required_region,
            .residency_level = .required,
            .allowed_replication_regions = 0,
            .blocked_regions = 0,
            .effective_from = getCurrentTimestamp(),
            .expires_at = 0,
            .active = true,
            .justification = [_]u8{0} ** MAX_DESCRIPTION,
            .justification_len = 0,
        };
    }

    /// Allow replication to region.
    pub fn allowReplication(self: *ResidencyPolicy, region_id: u32) void {
        if (region_id < 64) {
            self.allowed_replication_regions |= @as(u64, 1) << @intCast(region_id);
        }
    }

    /// Block replication to region.
    pub fn blockRegion(self: *ResidencyPolicy, region_id: u32) void {
        if (region_id < 64) {
            self.blocked_regions |= @as(u64, 1) << @intCast(region_id);
        }
    }

    /// Check if replication allowed.
    pub fn isReplicationAllowed(self: ResidencyPolicy, region_id: u32) bool {
        if (region_id >= 64) return false;
        const mask = @as(u64, 1) << @intCast(region_id);
        if ((self.blocked_regions & mask) != 0) return false;
        if (self.residency_level == .strict) {
            return region_id == self.required_region;
        }
        if (self.allowed_replication_regions == 0) return true; // No restrictions
        return (self.allowed_replication_regions & mask) != 0;
    }

    /// Set justification.
    pub fn setJustification(self: *ResidencyPolicy, j: []const u8) void {
        const len = @min(j.len, MAX_DESCRIPTION);
        @memcpy(self.justification[0..len], j[0..len]);
        self.justification_len = @intCast(len);
    }
};

/// Transfer Impact Assessment (supplementary measure per Schrems II).
pub const TransferImpactAssessment = struct {
    /// Assessment identifier.
    assessment_id: u64,
    /// Recipient ID being assessed.
    recipient_id: u128,
    /// Destination country code.
    country_code: [COUNTRY_CODE_LEN]u8,
    /// Assessment date.
    assessed_at: u64,
    /// Legal framework assessment.
    legal_framework_score: u8,
    /// Government access risk.
    government_access_risk: RiskLevel,
    /// Supplementary measures required.
    supplementary_measures_required: bool,
    /// Supplementary measures implemented.
    measures_implemented: u16,
    /// Assessment conclusion.
    conclusion: AssessmentConclusion,
    /// Next review date.
    next_review: u64,
    /// Assessor ID.
    assessor_id: u128,

    pub const RiskLevel = enum(u8) {
        low = 0,
        medium = 1,
        high = 2,
        prohibitive = 3,
    };

    pub const AssessmentConclusion = enum(u8) {
        /// Transfer permitted without additional measures.
        permitted = 0,
        /// Transfer permitted with supplementary measures.
        permitted_with_measures = 1,
        /// Transfer requires strong measures.
        requires_strong_measures = 2,
        /// Transfer should be suspended.
        suspend_transfer = 3,
        /// Transfer prohibited.
        prohibited = 4,
    };

    /// Supplementary measure flags.
    pub const SupplementaryMeasure = struct {
        pub const encryption_in_transit: u16 = 1 << 0;
        pub const encryption_at_rest: u16 = 1 << 1;
        pub const pseudonymization: u16 = 1 << 2;
        pub const split_processing: u16 = 1 << 3;
        pub const contractual_warranties: u16 = 1 << 4;
        pub const audit_rights: u16 = 1 << 5;
        pub const transparency_reporting: u16 = 1 << 6;
        pub const data_minimization: u16 = 1 << 7;
    };

    /// Initialize assessment.
    pub fn init(assessment_id: u64, recipient_id: u128, country_code: [2]u8) TransferImpactAssessment {
        return .{
            .assessment_id = assessment_id,
            .recipient_id = recipient_id,
            .country_code = country_code,
            .assessed_at = getCurrentTimestamp(),
            .legal_framework_score = 0,
            .government_access_risk = .low,
            .supplementary_measures_required = false,
            .measures_implemented = 0,
            .conclusion = .permitted,
            .next_review = getCurrentTimestamp() + (365 * 24 * 60 * 60 * 1_000_000_000),
            .assessor_id = 0,
        };
    }

    /// Add implemented measure.
    pub fn addMeasure(self: *TransferImpactAssessment, measure: u16) void {
        self.measures_implemented |= measure;
    }

    /// Check if measure implemented.
    pub fn hasMeasure(self: TransferImpactAssessment, measure: u16) bool {
        return (self.measures_implemented & measure) != 0;
    }

    /// Count implemented measures.
    pub fn countMeasures(self: TransferImpactAssessment) u8 {
        return @popCount(self.measures_implemented);
    }
};

/// International data transfer management system.
pub const DataTransferManager = struct {
    allocator: Allocator,
    /// Registered regions.
    regions: std.AutoHashMap(u32, GeoRegion),
    /// Registered recipients.
    recipients: std.AutoHashMap(u128, TransferRecipient),
    /// Transfer records.
    transfers: std.ArrayList(DataTransfer),
    /// Residency policies.
    residency_policies: std.ArrayList(ResidencyPolicy),
    /// Transfer impact assessments.
    impact_assessments: std.AutoHashMap(u128, TransferImpactAssessment),
    /// Default EU region ID.
    default_eu_region: u32,
    /// Next transfer ID.
    next_transfer_id: u64,
    /// Next policy ID.
    next_policy_id: u32,
    /// Next assessment ID.
    next_assessment_id: u64,
    /// Statistics.
    stats: Statistics,

    pub const Statistics = struct {
        total_transfers: u64 = 0,
        transfers_approved: u64 = 0,
        transfers_blocked: u64 = 0,
        recipients_registered: u64 = 0,
        assessments_performed: u64 = 0,
    };

    /// Initialize transfer manager.
    pub fn init(allocator: Allocator) !DataTransferManager {
        var manager = DataTransferManager{
            .allocator = allocator,
            .regions = std.AutoHashMap(u32, GeoRegion).init(allocator),
            .recipients = std.AutoHashMap(u128, TransferRecipient).init(allocator),
            .transfers = std.ArrayList(DataTransfer).init(allocator),
            .residency_policies = std.ArrayList(ResidencyPolicy).init(allocator),
            .impact_assessments = std.AutoHashMap(u128, TransferImpactAssessment).init(allocator),
            .default_eu_region = GeoRegion.WellKnown.eu,
            .next_transfer_id = 1,
            .next_policy_id = 1,
            .next_assessment_id = 1,
            .stats = .{},
        };

        // Initialize well-known regions with adequacy status
        try manager.initializeDefaultRegions();

        return manager;
    }

    /// Initialize default regions.
    fn initializeDefaultRegions(self: *DataTransferManager) !void {
        // EU - adequate by definition
        var eu = GeoRegion.init(GeoRegion.WellKnown.eu, "EU", .adequate);
        eu.setName("European Union");
        eu.is_eu_eea = true;
        try self.regions.put(eu.region_id, eu);

        // EEA - adequate
        var eea = GeoRegion.init(GeoRegion.WellKnown.eea, "EEA", .adequate);
        eea.setName("European Economic Area");
        eea.is_eu_eea = true;
        try self.regions.put(eea.region_id, eea);

        // UK - adequacy decision
        var uk = GeoRegion.init(GeoRegion.WellKnown.uk, "UK", .adequate);
        uk.setName("United Kingdom");
        try self.regions.put(uk.region_id, uk);

        // US - no general adequacy
        var us = GeoRegion.init(GeoRegion.WellKnown.us, "US", .partial);
        us.setName("United States");
        try self.regions.put(us.region_id, us);

        // Canada - adequate (commercial orgs under PIPEDA)
        var canada = GeoRegion.init(GeoRegion.WellKnown.canada, "CA", .adequate);
        canada.setName("Canada");
        try self.regions.put(canada.region_id, canada);

        // Japan - adequate
        var japan = GeoRegion.init(GeoRegion.WellKnown.japan, "JP", .adequate);
        japan.setName("Japan");
        try self.regions.put(japan.region_id, japan);

        // South Korea - adequate
        var korea = GeoRegion.init(GeoRegion.WellKnown.south_korea, "KR", .adequate);
        korea.setName("South Korea");
        try self.regions.put(korea.region_id, korea);

        // Australia - not adequate
        var australia = GeoRegion.init(GeoRegion.WellKnown.australia, "AU", .not_adequate);
        australia.setName("Australia");
        try self.regions.put(australia.region_id, australia);
    }

    /// Deinitialize.
    pub fn deinit(self: *DataTransferManager) void {
        self.regions.deinit();
        self.recipients.deinit();
        self.transfers.deinit();
        self.residency_policies.deinit();
        self.impact_assessments.deinit();
    }

    /// Register a transfer recipient.
    pub fn registerRecipient(self: *DataTransferManager, recipient: TransferRecipient) !void {
        try self.recipients.put(recipient.recipient_id, recipient);
        self.stats.recipients_registered += 1;
    }

    /// Get recipient by ID.
    pub fn getRecipient(self: *DataTransferManager, recipient_id: u128) ?*TransferRecipient {
        return self.recipients.getPtr(recipient_id);
    }

    /// Add custom region.
    pub fn addRegion(self: *DataTransferManager, region: GeoRegion) !void {
        try self.regions.put(region.region_id, region);
    }

    /// Get region by ID.
    pub fn getRegion(self: *DataTransferManager, region_id: u32) ?GeoRegion {
        return self.regions.get(region_id);
    }

    /// Validate transfer and determine restriction.
    pub fn validateTransfer(
        self: *DataTransferManager,
        source_region: u32,
        destination_region: u32,
        recipient_id: u128,
        data_categories: u16,
    ) TransferValidation {
        // Check if destination region exists
        const dest_region = self.regions.get(destination_region) orelse {
            return .{ .allowed = false, .restriction = .assessment_required, .mechanism = null };
        };

        // Intra-EU transfers always allowed
        const source = self.regions.get(source_region);
        if (source != null and source.?.is_eu_eea and dest_region.is_eu_eea) {
            return .{ .allowed = true, .restriction = .none, .mechanism = null };
        }

        // Check recipient approval
        const recipient = self.recipients.get(recipient_id) orelse {
            return .{ .allowed = false, .restriction = .recipient_not_approved, .mechanism = null };
        };

        if (!recipient.approved) {
            return .{ .allowed = false, .restriction = .recipient_not_approved, .mechanism = null };
        }

        // Check adequacy
        if (dest_region.adequacy_status == .adequate) {
            return .{ .allowed = true, .restriction = .none, .mechanism = .adequacy_decision };
        }

        // Check for SCCs
        if (recipient.has_scc) {
            return .{ .allowed = true, .restriction = .none, .mechanism = .standard_contractual_clauses };
        }

        // Check for BCRs
        if (recipient.has_bcr) {
            return .{ .allowed = true, .restriction = .none, .mechanism = .binding_corporate_rules };
        }

        // Check if any mechanism is approved
        if (recipient.approved_mechanisms != 0) {
            // Return first approved mechanism
            var i: u4 = 0;
            while (i < 12) : (i += 1) {
                if (recipient.hasMechanism(@enumFromInt(i))) {
                    return .{ .allowed = true, .restriction = .none, .mechanism = @enumFromInt(i) };
                }
            }
        }

        // Check sensitive data
        if (data_categories & DataTransfer.DataCategory.movement_history != 0 or
            data_categories & DataTransfer.DataCategory.dwell_time != 0)
        {
            return .{ .allowed = false, .restriction = .sensitive_data, .mechanism = null };
        }

        return .{ .allowed = false, .restriction = .no_safeguards, .mechanism = null };
    }

    pub const TransferValidation = struct {
        allowed: bool,
        restriction: TransferRestriction,
        mechanism: ?TransferMechanism,
    };

    /// Create and record a data transfer.
    pub fn createTransfer(
        self: *DataTransferManager,
        source_region: u32,
        destination_region: u32,
        recipient_id: u128,
        data_categories: u16,
        record_count: u64,
        purpose: []const u8,
    ) !TransferResult {
        // Validate transfer
        const validation = self.validateTransfer(source_region, destination_region, recipient_id, data_categories);

        const transfer_id = self.next_transfer_id;
        var transfer = DataTransfer.init(transfer_id, source_region, destination_region, recipient_id);
        transfer.data_categories = data_categories;
        transfer.record_count = record_count;
        transfer.setPurpose(purpose);

        if (validation.allowed) {
            transfer.mechanism = validation.mechanism orelse .standard_contractual_clauses;
            transfer.status = .approved;
            self.stats.transfers_approved += 1;
        } else {
            transfer.status = .blocked;
            self.stats.transfers_blocked += 1;
        }

        try self.transfers.append(transfer);
        self.next_transfer_id += 1;
        self.stats.total_transfers += 1;

        return .{
            .transfer_id = transfer_id,
            .allowed = validation.allowed,
            .restriction = validation.restriction,
            .mechanism = validation.mechanism,
        };
    }

    pub const TransferResult = struct {
        transfer_id: u64,
        allowed: bool,
        restriction: TransferRestriction,
        mechanism: ?TransferMechanism,
    };

    /// Complete a transfer.
    pub fn completeTransfer(self: *DataTransferManager, transfer_id: u64) bool {
        for (self.transfers.items) |*transfer| {
            if (transfer.transfer_id == transfer_id) {
                if (transfer.status == .approved) {
                    transfer.complete();
                    return true;
                }
                return false;
            }
        }
        return false;
    }

    /// Add residency policy.
    pub fn addResidencyPolicy(
        self: *DataTransferManager,
        entity_id: u128,
        required_region: u32,
        level: ResidencyRequirement,
    ) !u32 {
        const policy_id = self.next_policy_id;
        var policy = ResidencyPolicy.init(policy_id, entity_id, required_region);
        policy.residency_level = level;

        try self.residency_policies.append(policy);
        self.next_policy_id += 1;

        return policy_id;
    }

    /// Check residency compliance for entity.
    pub fn checkResidencyCompliance(self: *DataTransferManager, entity_id: u128, current_region: u32) bool {
        for (self.residency_policies.items) |policy| {
            if (policy.entity_id == entity_id and policy.active) {
                if (policy.residency_level == .strict or policy.residency_level == .legal_mandate) {
                    return current_region == policy.required_region;
                }
                return policy.isReplicationAllowed(current_region);
            }
        }
        return true; // No policy = compliant
    }

    /// Perform transfer impact assessment.
    pub fn performImpactAssessment(
        self: *DataTransferManager,
        recipient_id: u128,
        country_code: [2]u8,
        legal_framework_score: u8,
        government_access_risk: TransferImpactAssessment.RiskLevel,
        assessor_id: u128,
    ) !u64 {
        const assessment_id = self.next_assessment_id;
        var assessment = TransferImpactAssessment.init(assessment_id, recipient_id, country_code);
        assessment.legal_framework_score = legal_framework_score;
        assessment.government_access_risk = government_access_risk;
        assessment.assessor_id = assessor_id;

        // Determine conclusion based on risk
        if (government_access_risk == .prohibitive) {
            assessment.conclusion = .prohibited;
        } else if (government_access_risk == .high) {
            assessment.conclusion = .requires_strong_measures;
            assessment.supplementary_measures_required = true;
        } else if (legal_framework_score < 50) {
            assessment.conclusion = .permitted_with_measures;
            assessment.supplementary_measures_required = true;
        } else {
            assessment.conclusion = .permitted;
        }

        try self.impact_assessments.put(recipient_id, assessment);
        self.next_assessment_id += 1;
        self.stats.assessments_performed += 1;

        return assessment_id;
    }

    /// Get impact assessment for recipient.
    pub fn getImpactAssessment(self: *DataTransferManager, recipient_id: u128) ?TransferImpactAssessment {
        return self.impact_assessments.get(recipient_id);
    }

    /// Get transfers by recipient.
    pub fn getTransfersByRecipient(self: *DataTransferManager, recipient_id: u128, buffer: []DataTransfer) usize {
        var count: usize = 0;
        for (self.transfers.items) |transfer| {
            if (transfer.recipient_id == recipient_id and count < buffer.len) {
                buffer[count] = transfer;
                count += 1;
            }
        }
        return count;
    }

    /// Get statistics.
    pub fn getStatistics(self: *DataTransferManager) Statistics {
        return self.stats;
    }

    /// Generate transfer compliance report.
    pub fn generateComplianceReport(self: *DataTransferManager) ComplianceReport {
        var by_mechanism = [_]u64{0} ** 12;
        var cross_border: u64 = 0;
        var intra_eu: u64 = 0;

        for (self.transfers.items) |transfer| {
            if (transfer.status == .completed or transfer.status == .approved) {
                by_mechanism[@intFromEnum(transfer.mechanism)] += 1;

                const src = self.regions.get(transfer.source_region);
                const dest = self.regions.get(transfer.destination_region);
                if (src != null and dest != null) {
                    if (src.?.is_eu_eea and dest.?.is_eu_eea) {
                        intra_eu += 1;
                    } else {
                        cross_border += 1;
                    }
                }
            }
        }

        return .{
            .total_transfers = self.stats.total_transfers,
            .approved_transfers = self.stats.transfers_approved,
            .blocked_transfers = self.stats.transfers_blocked,
            .intra_eu_transfers = intra_eu,
            .cross_border_transfers = cross_border,
            .transfers_by_scc = by_mechanism[@intFromEnum(TransferMechanism.standard_contractual_clauses)],
            .transfers_by_bcr = by_mechanism[@intFromEnum(TransferMechanism.binding_corporate_rules)],
            .transfers_by_adequacy = by_mechanism[@intFromEnum(TransferMechanism.adequacy_decision)],
            .assessments_performed = self.stats.assessments_performed,
        };
    }

    pub const ComplianceReport = struct {
        total_transfers: u64,
        approved_transfers: u64,
        blocked_transfers: u64,
        intra_eu_transfers: u64,
        cross_border_transfers: u64,
        transfers_by_scc: u64,
        transfers_by_bcr: u64,
        transfers_by_adequacy: u64,
        assessments_performed: u64,
    };
};

/// Get current timestamp.
fn getCurrentTimestamp() u64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Unit Tests
// ============================================================================

test "GeoRegion initialization" {
    const testing = std.testing;

    var region = GeoRegion.init(1, "EU", .adequate);
    region.setName("European Union");
    region.is_eu_eea = true;

    try testing.expectEqualStrings("EU", region.getCode());
    try testing.expectEqualStrings("European Union", region.getName());
    try testing.expect(region.is_eu_eea);
    try testing.expectEqual(AdequacyStatus.adequate, region.adequacy_status);
}

test "TransferRecipient mechanism management" {
    const testing = std.testing;

    var recipient = TransferRecipient.init(0x12345, "US".*, .processor);
    recipient.setName("US Data Processor Inc.");

    recipient.addApprovedMechanism(.standard_contractual_clauses);
    recipient.addApprovedMechanism(.certification);

    try testing.expect(recipient.hasMechanism(.standard_contractual_clauses));
    try testing.expect(recipient.hasMechanism(.certification));
    try testing.expect(!recipient.hasMechanism(.binding_corporate_rules));
}

test "TransferRecipient SCC reference" {
    const testing = std.testing;

    var recipient = TransferRecipient.init(0x12345, "JP".*, .controller);
    recipient.setSCCReference("SCC-2021-v2.0-JP");

    try testing.expect(recipient.has_scc);
    try testing.expectEqual(@as(u8, 16), recipient.scc_ref_len);
}

test "DataTransfer lifecycle" {
    const testing = std.testing;

    var transfer = DataTransfer.init(1, GeoRegion.WellKnown.eu, GeoRegion.WellKnown.us, 0x12345);
    transfer.setPurpose("Analytics data processing");
    transfer.data_categories = DataTransfer.DataCategory.location | DataTransfer.DataCategory.movement_history;
    transfer.record_count = 1000;

    try testing.expectEqual(DataTransfer.TransferStatus.pending, transfer.status);

    transfer.status = .approved;
    transfer.complete();

    try testing.expectEqual(DataTransfer.TransferStatus.completed, transfer.status);
    try testing.expect(transfer.transferred_at > 0);
}

test "ResidencyPolicy replication control" {
    const testing = std.testing;

    var policy = ResidencyPolicy.init(1, 0x12345, GeoRegion.WellKnown.eu);
    policy.residency_level = .required;
    policy.allowReplication(GeoRegion.WellKnown.eea);
    policy.allowReplication(GeoRegion.WellKnown.uk);
    policy.blockRegion(GeoRegion.WellKnown.us);

    try testing.expect(policy.isReplicationAllowed(GeoRegion.WellKnown.eea));
    try testing.expect(policy.isReplicationAllowed(GeoRegion.WellKnown.uk));
    try testing.expect(!policy.isReplicationAllowed(GeoRegion.WellKnown.us));
}

test "ResidencyPolicy strict mode" {
    const testing = std.testing;

    var policy = ResidencyPolicy.init(1, 0x12345, GeoRegion.WellKnown.eu);
    policy.residency_level = .strict;

    try testing.expect(policy.isReplicationAllowed(GeoRegion.WellKnown.eu));
    try testing.expect(!policy.isReplicationAllowed(GeoRegion.WellKnown.eea));
    try testing.expect(!policy.isReplicationAllowed(GeoRegion.WellKnown.uk));
}

test "TransferImpactAssessment measures" {
    const testing = std.testing;

    var assessment = TransferImpactAssessment.init(1, 0x12345, "US".*);
    assessment.addMeasure(TransferImpactAssessment.SupplementaryMeasure.encryption_in_transit);
    assessment.addMeasure(TransferImpactAssessment.SupplementaryMeasure.encryption_at_rest);
    assessment.addMeasure(TransferImpactAssessment.SupplementaryMeasure.pseudonymization);

    try testing.expect(assessment.hasMeasure(TransferImpactAssessment.SupplementaryMeasure.encryption_in_transit));
    try testing.expect(assessment.hasMeasure(TransferImpactAssessment.SupplementaryMeasure.pseudonymization));
    try testing.expectEqual(@as(u8, 3), assessment.countMeasures());
}

test "DataTransferManager initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DataTransferManager.init(allocator);
    defer manager.deinit();

    // Check default regions
    const eu = manager.getRegion(GeoRegion.WellKnown.eu);
    try testing.expect(eu != null);
    try testing.expectEqual(AdequacyStatus.adequate, eu.?.adequacy_status);

    const us = manager.getRegion(GeoRegion.WellKnown.us);
    try testing.expect(us != null);
    try testing.expectEqual(AdequacyStatus.partial, us.?.adequacy_status);
}

test "DataTransferManager intra-EU transfer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DataTransferManager.init(allocator);
    defer manager.deinit();

    // Intra-EU transfers should always be allowed
    const validation = manager.validateTransfer(
        GeoRegion.WellKnown.eu,
        GeoRegion.WellKnown.eea,
        0x12345,
        DataTransfer.DataCategory.location,
    );

    try testing.expect(validation.allowed);
    try testing.expectEqual(TransferRestriction.none, validation.restriction);
}

test "DataTransferManager cross-border transfer validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DataTransferManager.init(allocator);
    defer manager.deinit();

    // Register recipient with SCCs
    var recipient = TransferRecipient.init(0x12345, "AU".*, .processor);
    recipient.setName("Australian Processor");
    recipient.has_scc = true;
    recipient.approved = true;
    try manager.registerRecipient(recipient);

    const validation = manager.validateTransfer(
        GeoRegion.WellKnown.eu,
        GeoRegion.WellKnown.australia,
        0x12345,
        DataTransfer.DataCategory.location,
    );

    try testing.expect(validation.allowed);
    try testing.expectEqual(TransferMechanism.standard_contractual_clauses, validation.mechanism.?);
}

test "DataTransferManager blocked transfer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DataTransferManager.init(allocator);
    defer manager.deinit();

    // Register unapproved recipient
    var recipient = TransferRecipient.init(0x99999, "XX".*, .processor);
    recipient.approved = false;
    try manager.registerRecipient(recipient);

    const validation = manager.validateTransfer(
        GeoRegion.WellKnown.eu,
        GeoRegion.WellKnown.australia,
        0x99999,
        DataTransfer.DataCategory.location,
    );

    try testing.expect(!validation.allowed);
    try testing.expectEqual(TransferRestriction.recipient_not_approved, validation.restriction);
}

test "DataTransferManager create transfer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DataTransferManager.init(allocator);
    defer manager.deinit();

    // Register approved recipient
    var recipient = TransferRecipient.init(0x12345, "JP".*, .processor);
    recipient.approved = true;
    try manager.registerRecipient(recipient);

    const result = try manager.createTransfer(
        GeoRegion.WellKnown.eu,
        GeoRegion.WellKnown.japan,
        0x12345,
        DataTransfer.DataCategory.location,
        500,
        "Fleet analytics",
    );

    try testing.expect(result.allowed);
    try testing.expectEqual(@as(u64, 1), result.transfer_id);

    try testing.expectEqual(@as(u64, 1), manager.stats.transfers_approved);
}

test "DataTransferManager impact assessment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DataTransferManager.init(allocator);
    defer manager.deinit();

    const assessment_id = try manager.performImpactAssessment(
        0x12345,
        "US".*,
        45,
        .medium,
        0x99999,
    );

    try testing.expectEqual(@as(u64, 1), assessment_id);

    const assessment = manager.getImpactAssessment(0x12345);
    try testing.expect(assessment != null);
    try testing.expect(assessment.?.supplementary_measures_required);
}

test "DataTransferManager compliance report" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DataTransferManager.init(allocator);
    defer manager.deinit();

    // Register approved recipient with SCCs
    var recipient = TransferRecipient.init(0x12345, "CA".*, .processor);
    recipient.approved = true;
    recipient.has_scc = true;
    try manager.registerRecipient(recipient);

    // Create some transfers
    _ = try manager.createTransfer(GeoRegion.WellKnown.eu, GeoRegion.WellKnown.canada, 0x12345, DataTransfer.DataCategory.location, 100, "Test 1");
    _ = try manager.createTransfer(GeoRegion.WellKnown.eu, GeoRegion.WellKnown.canada, 0x12345, DataTransfer.DataCategory.location, 200, "Test 2");

    const report = manager.generateComplianceReport();
    try testing.expectEqual(@as(u64, 2), report.total_transfers);
    try testing.expectEqual(@as(u64, 2), report.approved_transfers);
}
