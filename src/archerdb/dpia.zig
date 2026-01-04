// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// Data Protection Impact Assessment (DPIA) framework per GDPR Article 35.
// Provides risk assessment, necessity evaluation, and compliance documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// DPIA review period in nanoseconds (1 year).
pub const ANNUAL_REVIEW_PERIOD_NS: u64 = 365 * 24 * 60 * 60 * 1_000_000_000;

/// Maximum description length.
pub const MAX_DESCRIPTION: usize = 2048;

/// Maximum mitigation measure description.
pub const MAX_MITIGATION: usize = 1024;

/// Maximum number of risk factors per assessment.
pub const MAX_RISK_FACTORS: usize = 32;

/// Maximum number of mitigations per assessment.
pub const MAX_MITIGATIONS: usize = 32;

/// Processing activity type for location data.
pub const ProcessingType = enum(u8) {
    /// Real-time location tracking.
    realtime_tracking = 0,
    /// Historical location analysis.
    historical_analysis = 1,
    /// Location-based profiling.
    location_profiling = 2,
    /// Geofence monitoring.
    geofence_monitoring = 3,
    /// Movement pattern analysis.
    movement_patterns = 4,
    /// Cross-device location linking.
    cross_device_linking = 5,
    /// Location-based advertising.
    location_advertising = 6,
    /// Emergency location services.
    emergency_services = 7,
    /// Fleet/asset tracking.
    fleet_tracking = 8,
    /// Research/analytics (anonymized).
    research_analytics = 9,
    /// Third-party data sharing.
    third_party_sharing = 10,
    /// Automated decision making.
    automated_decisions = 11,
};

/// Risk severity level.
pub const RiskSeverity = enum(u8) {
    /// Minimal risk to rights/freedoms.
    low = 0,
    /// Moderate risk requiring mitigation.
    medium = 1,
    /// Significant risk to rights/freedoms.
    high = 2,
    /// Severe risk requiring consultation.
    critical = 3,

    /// Get numeric weight for calculations.
    pub fn weight(self: RiskSeverity) u8 {
        return switch (self) {
            .low => 1,
            .medium => 2,
            .high => 3,
            .critical => 4,
        };
    }
};

/// Risk likelihood.
pub const RiskLikelihood = enum(u8) {
    /// Unlikely to occur.
    unlikely = 0,
    /// Possible but not expected.
    possible = 1,
    /// Likely to occur.
    likely = 2,
    /// Almost certain to occur.
    certain = 3,

    /// Get numeric weight for calculations.
    pub fn weight(self: RiskLikelihood) u8 {
        return switch (self) {
            .unlikely => 1,
            .possible => 2,
            .likely => 3,
            .certain => 4,
        };
    }
};

/// High-risk indicator flags.
pub const HighRiskIndicator = struct {
    /// Large-scale systematic monitoring.
    pub const large_scale_monitoring: u16 = 1 << 0;
    /// Sensitive data revealing private life.
    pub const sensitive_data: u16 = 1 << 1;
    /// Automated decision-making.
    pub const automated_decisions: u16 = 1 << 2;
    /// Cross-border data transfers.
    pub const cross_border_transfer: u16 = 1 << 3;
    /// Invisible processing (user unaware).
    pub const invisible_processing: u16 = 1 << 4;
    /// Vulnerable data subjects (children).
    pub const vulnerable_subjects: u16 = 1 << 5;
    /// Innovative technology use.
    pub const innovative_technology: u16 = 1 << 6;
    /// Processing prevents exercising rights.
    pub const prevents_rights: u16 = 1 << 7;
    /// Combination of datasets.
    pub const dataset_combination: u16 = 1 << 8;
    /// Evaluation/scoring of individuals.
    pub const evaluation_scoring: u16 = 1 << 9;
};

/// Legal basis for processing.
pub const LegalBasis = enum(u8) {
    /// Explicit consent (Article 6(1)(a)).
    consent = 0,
    /// Contractual necessity (Article 6(1)(b)).
    contract = 1,
    /// Legal obligation (Article 6(1)(c)).
    legal_obligation = 2,
    /// Vital interests (Article 6(1)(d)).
    vital_interests = 3,
    /// Public interest (Article 6(1)(e)).
    public_interest = 4,
    /// Legitimate interests (Article 6(1)(f)).
    legitimate_interests = 5,
};

/// Necessity assessment result.
pub const NecessityAssessment = struct {
    /// Legal basis for processing.
    legal_basis: LegalBasis,
    /// Purpose is clearly defined.
    purpose_defined: bool,
    /// Processing is necessary for purpose.
    processing_necessary: bool,
    /// Less intrusive alternatives considered.
    alternatives_considered: bool,
    /// Data minimization applied.
    data_minimized: bool,
    /// Proportionate to purpose.
    proportionate: bool,
    /// Assessment score (0-100).
    score: u8,
    /// Assessment timestamp.
    assessed_at: u64,
    /// Assessor identifier.
    assessor_id: u128,

    /// Check if necessity is satisfied.
    pub fn isSatisfied(self: NecessityAssessment) bool {
        return self.purpose_defined and
            self.processing_necessary and
            self.alternatives_considered and
            self.data_minimized and
            self.proportionate and
            self.score >= 60;
    }
};

/// Risk factor identified in assessment.
pub const RiskFactor = struct {
    /// Risk factor identifier.
    factor_id: u32,
    /// Category of risk.
    category: RiskCategory,
    /// Description of the risk.
    description: [MAX_DESCRIPTION]u8,
    /// Description length.
    description_len: u16,
    /// Severity level.
    severity: RiskSeverity,
    /// Likelihood of occurrence.
    likelihood: RiskLikelihood,
    /// Affected data subject groups (bitmask).
    affected_groups: u16,
    /// Whether risk has been mitigated.
    mitigated: bool,
    /// Associated mitigation IDs.
    mitigation_ids: [4]u32,
    /// Number of associated mitigations.
    mitigation_count: u8,

    pub const RiskCategory = enum(u8) {
        /// Risk to data confidentiality.
        confidentiality = 0,
        /// Risk to data integrity.
        integrity = 1,
        /// Risk to data availability.
        availability = 2,
        /// Risk to individual privacy.
        privacy = 3,
        /// Risk to individual freedom.
        freedom = 4,
        /// Risk of discrimination.
        discrimination = 5,
        /// Risk of financial harm.
        financial = 6,
        /// Risk of reputational harm.
        reputational = 7,
        /// Risk of physical harm.
        physical = 8,
        /// Risk to autonomy.
        autonomy = 9,
    };

    /// Data subject groups bitmask.
    pub const AffectedGroup = struct {
        pub const general_public: u16 = 1 << 0;
        pub const employees: u16 = 1 << 1;
        pub const customers: u16 = 1 << 2;
        pub const children: u16 = 1 << 3;
        pub const vulnerable: u16 = 1 << 4;
        pub const patients: u16 = 1 << 5;
        pub const students: u16 = 1 << 6;
    };

    /// Initialize risk factor.
    pub fn init(factor_id: u32, category: RiskCategory, severity: RiskSeverity, likelihood: RiskLikelihood) RiskFactor {
        return .{
            .factor_id = factor_id,
            .category = category,
            .description = [_]u8{0} ** MAX_DESCRIPTION,
            .description_len = 0,
            .severity = severity,
            .likelihood = likelihood,
            .affected_groups = 0,
            .mitigated = false,
            .mitigation_ids = [_]u32{0} ** 4,
            .mitigation_count = 0,
        };
    }

    /// Set description.
    pub fn setDescription(self: *RiskFactor, desc: []const u8) void {
        const len = @min(desc.len, MAX_DESCRIPTION);
        @memcpy(self.description[0..len], desc[0..len]);
        self.description_len = @intCast(len);
    }

    /// Get description.
    pub fn getDescription(self: RiskFactor) []const u8 {
        return self.description[0..self.description_len];
    }

    /// Calculate risk score (severity * likelihood).
    pub fn riskScore(self: RiskFactor) u8 {
        return self.severity.weight() * self.likelihood.weight();
    }

    /// Add mitigation reference.
    pub fn addMitigation(self: *RiskFactor, mitigation_id: u32) bool {
        if (self.mitigation_count >= 4) return false;
        self.mitigation_ids[self.mitigation_count] = mitigation_id;
        self.mitigation_count += 1;
        return true;
    }
};

/// Mitigation measure.
pub const MitigationMeasure = struct {
    /// Mitigation identifier.
    mitigation_id: u32,
    /// Type of mitigation.
    mitigation_type: MitigationType,
    /// Description of the measure.
    description: [MAX_MITIGATION]u8,
    /// Description length.
    description_len: u16,
    /// Implementation status.
    status: ImplementationStatus,
    /// Effectiveness rating (0-100).
    effectiveness: u8,
    /// Implementation cost estimate.
    cost_estimate: CostLevel,
    /// Responsible party identifier.
    responsible_party: u128,
    /// Target implementation date.
    target_date: u64,
    /// Actual implementation date.
    implemented_at: u64,

    pub const MitigationType = enum(u8) {
        /// Technical security measure.
        technical_security = 0,
        /// Organizational policy.
        organizational_policy = 1,
        /// Data minimization.
        data_minimization = 2,
        /// Pseudonymization.
        pseudonymization = 3,
        /// Encryption.
        encryption = 4,
        /// Access control.
        access_control = 5,
        /// Audit logging.
        audit_logging = 6,
        /// Consent mechanism.
        consent_mechanism = 7,
        /// Transparency measure.
        transparency = 8,
        /// Data retention limit.
        retention_limit = 9,
        /// Staff training.
        staff_training = 10,
        /// Third party contract.
        third_party_contract = 11,
    };

    pub const ImplementationStatus = enum(u8) {
        /// Not started.
        planned = 0,
        /// In progress.
        in_progress = 1,
        /// Implemented.
        implemented = 2,
        /// Verified effective.
        verified = 3,
        /// Needs improvement.
        needs_improvement = 4,
    };

    pub const CostLevel = enum(u8) {
        /// Minimal cost.
        minimal = 0,
        /// Low cost.
        low = 1,
        /// Medium cost.
        medium = 2,
        /// High cost.
        high = 3,
        /// Very high cost.
        very_high = 4,
    };

    /// Initialize mitigation measure.
    pub fn init(mitigation_id: u32, mitigation_type: MitigationType) MitigationMeasure {
        return .{
            .mitigation_id = mitigation_id,
            .mitigation_type = mitigation_type,
            .description = [_]u8{0} ** MAX_MITIGATION,
            .description_len = 0,
            .status = .planned,
            .effectiveness = 0,
            .cost_estimate = .medium,
            .responsible_party = 0,
            .target_date = 0,
            .implemented_at = 0,
        };
    }

    /// Set description.
    pub fn setDescription(self: *MitigationMeasure, desc: []const u8) void {
        const len = @min(desc.len, MAX_MITIGATION);
        @memcpy(self.description[0..len], desc[0..len]);
        self.description_len = @intCast(len);
    }

    /// Get description.
    pub fn getDescription(self: MitigationMeasure) []const u8 {
        return self.description[0..self.description_len];
    }

    /// Mark as implemented.
    pub fn markImplemented(self: *MitigationMeasure) void {
        self.status = .implemented;
        self.implemented_at = getCurrentTimestamp();
    }

    /// Mark as verified.
    pub fn markVerified(self: *MitigationMeasure, effectiveness_rating: u8) void {
        self.status = .verified;
        self.effectiveness = effectiveness_rating;
    }
};

/// Data Protection Impact Assessment.
pub const DPIA = struct {
    /// Assessment identifier.
    assessment_id: u64,
    /// Project/system being assessed.
    project_id: u128,
    /// Processing type.
    processing_type: ProcessingType,
    /// High-risk indicators (bitmask).
    high_risk_indicators: u16,
    /// Assessment status.
    status: AssessmentStatus,
    /// Creation timestamp.
    created_at: u64,
    /// Last review timestamp.
    last_reviewed: u64,
    /// Next review due date.
    next_review_due: u64,
    /// Overall risk level.
    overall_risk: RiskSeverity,
    /// Necessity assessment.
    necessity: NecessityAssessment,
    /// DPO consultation required.
    dpo_consultation_required: bool,
    /// DPO consultation completed.
    dpo_consulted: bool,
    /// Supervisory authority consultation required.
    authority_consultation_required: bool,
    /// Supervisory authority consulted.
    authority_consulted: bool,
    /// Assessment approved.
    approved: bool,
    /// Approver identifier.
    approver_id: u128,
    /// Approval timestamp.
    approved_at: u64,
    /// Description of processing.
    description: [MAX_DESCRIPTION]u8,
    /// Description length.
    description_len: u16,

    pub const AssessmentStatus = enum(u8) {
        /// Initial draft.
        draft = 0,
        /// Under review.
        in_review = 1,
        /// Pending DPO consultation.
        pending_dpo = 2,
        /// Pending authority consultation.
        pending_authority = 3,
        /// Approved.
        approved = 4,
        /// Rejected.
        rejected = 5,
        /// Review required.
        review_required = 6,
        /// Superseded by new version.
        superseded = 7,
    };

    /// Initialize DPIA.
    pub fn init(assessment_id: u64, project_id: u128, processing_type: ProcessingType) DPIA {
        const now = getCurrentTimestamp();
        return .{
            .assessment_id = assessment_id,
            .project_id = project_id,
            .processing_type = processing_type,
            .high_risk_indicators = 0,
            .status = .draft,
            .created_at = now,
            .last_reviewed = now,
            .next_review_due = now + ANNUAL_REVIEW_PERIOD_NS,
            .overall_risk = .low,
            .necessity = .{
                .legal_basis = .consent,
                .purpose_defined = false,
                .processing_necessary = false,
                .alternatives_considered = false,
                .data_minimized = false,
                .proportionate = false,
                .score = 0,
                .assessed_at = 0,
                .assessor_id = 0,
            },
            .dpo_consultation_required = false,
            .dpo_consulted = false,
            .authority_consultation_required = false,
            .authority_consulted = false,
            .approved = false,
            .approver_id = 0,
            .approved_at = 0,
            .description = [_]u8{0} ** MAX_DESCRIPTION,
            .description_len = 0,
        };
    }

    /// Set description.
    pub fn setDescription(self: *DPIA, desc: []const u8) void {
        const len = @min(desc.len, MAX_DESCRIPTION);
        @memcpy(self.description[0..len], desc[0..len]);
        self.description_len = @intCast(len);
    }

    /// Get description.
    pub fn getDescription(self: DPIA) []const u8 {
        return self.description[0..self.description_len];
    }

    /// Check if DPIA is due for review.
    pub fn isReviewDue(self: DPIA) bool {
        return getCurrentTimestamp() >= self.next_review_due;
    }

    /// Set high-risk indicator.
    pub fn setHighRiskIndicator(self: *DPIA, indicator: u16) void {
        self.high_risk_indicators |= indicator;
        self.updateConsultationRequirements();
    }

    /// Check high-risk indicator.
    pub fn hasHighRiskIndicator(self: DPIA, indicator: u16) bool {
        return (self.high_risk_indicators & indicator) != 0;
    }

    /// Count high-risk indicators.
    pub fn countHighRiskIndicators(self: DPIA) u8 {
        return @popCount(self.high_risk_indicators);
    }

    /// Update consultation requirements based on risk.
    fn updateConsultationRequirements(self: *DPIA) void {
        // DPO consultation always required for location data
        self.dpo_consultation_required = true;

        // Authority consultation if high residual risk
        if (self.countHighRiskIndicators() >= 3 or
            self.overall_risk == .critical)
        {
            self.authority_consultation_required = true;
        }
    }

    /// Complete DPO consultation.
    pub fn completeDPOConsultation(self: *DPIA) void {
        self.dpo_consulted = true;
        if (self.status == .pending_dpo) {
            if (self.authority_consultation_required and !self.authority_consulted) {
                self.status = .pending_authority;
            } else {
                self.status = .in_review;
            }
        }
    }

    /// Complete authority consultation.
    pub fn completeAuthorityConsultation(self: *DPIA) void {
        self.authority_consulted = true;
        if (self.status == .pending_authority) {
            self.status = .in_review;
        }
    }

    /// Approve the DPIA.
    pub fn approve(self: *DPIA, approver_id: u128) bool {
        // Check prerequisites
        if (self.dpo_consultation_required and !self.dpo_consulted) return false;
        if (self.authority_consultation_required and !self.authority_consulted) return false;
        if (!self.necessity.isSatisfied()) return false;

        self.approved = true;
        self.approver_id = approver_id;
        self.approved_at = getCurrentTimestamp();
        self.status = .approved;
        return true;
    }

    /// Reject the DPIA.
    pub fn reject(self: *DPIA) void {
        self.status = .rejected;
        self.approved = false;
    }

    /// Mark for review.
    pub fn markForReview(self: *DPIA) void {
        self.status = .review_required;
        self.last_reviewed = getCurrentTimestamp();
    }

    /// Update necessity assessment.
    pub fn setNecessityAssessment(self: *DPIA, assessment: NecessityAssessment) void {
        self.necessity = assessment;
    }
};

/// DPIA management system.
pub const DPIAManager = struct {
    allocator: Allocator,
    /// Active DPIAs.
    assessments: std.AutoHashMap(u64, DPIA),
    /// Risk factors by assessment.
    risk_factors: std.AutoHashMap(u64, std.ArrayList(RiskFactor)),
    /// Mitigations by assessment.
    mitigations: std.AutoHashMap(u64, std.ArrayList(MitigationMeasure)),
    /// Next assessment ID.
    next_assessment_id: u64,
    /// Next risk factor ID.
    next_factor_id: u32,
    /// Next mitigation ID.
    next_mitigation_id: u32,
    /// Statistics.
    stats: Statistics,

    pub const Statistics = struct {
        total_assessments: u64 = 0,
        approved_assessments: u64 = 0,
        pending_review: u64 = 0,
        high_risk_assessments: u64 = 0,
        risk_factors_identified: u64 = 0,
        mitigations_implemented: u64 = 0,
    };

    /// Initialize DPIA manager.
    pub fn init(allocator: Allocator) !DPIAManager {
        return .{
            .allocator = allocator,
            .assessments = std.AutoHashMap(u64, DPIA).init(allocator),
            .risk_factors = std.AutoHashMap(u64, std.ArrayList(RiskFactor)).init(allocator),
            .mitigations = std.AutoHashMap(u64, std.ArrayList(MitigationMeasure)).init(allocator),
            .next_assessment_id = 1,
            .next_factor_id = 1,
            .next_mitigation_id = 1,
            .stats = .{},
        };
    }

    /// Deinitialize.
    pub fn deinit(self: *DPIAManager) void {
        var factor_iter = self.risk_factors.valueIterator();
        while (factor_iter.next()) |list| {
            list.deinit();
        }
        self.risk_factors.deinit();

        var mit_iter = self.mitigations.valueIterator();
        while (mit_iter.next()) |list| {
            list.deinit();
        }
        self.mitigations.deinit();

        self.assessments.deinit();
    }

    /// Create new DPIA.
    pub fn createDPIA(
        self: *DPIAManager,
        project_id: u128,
        processing_type: ProcessingType,
    ) !u64 {
        const assessment_id = self.next_assessment_id;
        var dpia = DPIA.init(assessment_id, project_id, processing_type);

        // Location data is inherently high-risk
        dpia.setHighRiskIndicator(HighRiskIndicator.sensitive_data);
        if (processing_type == .realtime_tracking or processing_type == .geofence_monitoring) {
            dpia.setHighRiskIndicator(HighRiskIndicator.large_scale_monitoring);
        }
        if (processing_type == .automated_decisions) {
            dpia.setHighRiskIndicator(HighRiskIndicator.automated_decisions);
        }
        if (processing_type == .third_party_sharing) {
            dpia.setHighRiskIndicator(HighRiskIndicator.cross_border_transfer);
        }

        try self.assessments.put(assessment_id, dpia);
        try self.risk_factors.put(assessment_id, std.ArrayList(RiskFactor).init(self.allocator));
        try self.mitigations.put(assessment_id, std.ArrayList(MitigationMeasure).init(self.allocator));

        self.next_assessment_id += 1;
        self.stats.total_assessments += 1;

        return assessment_id;
    }

    /// Get DPIA by ID.
    pub fn getDPIA(self: *DPIAManager, assessment_id: u64) ?*DPIA {
        return self.assessments.getPtr(assessment_id);
    }

    /// Add risk factor to DPIA.
    pub fn addRiskFactor(
        self: *DPIAManager,
        assessment_id: u64,
        category: RiskFactor.RiskCategory,
        severity: RiskSeverity,
        likelihood: RiskLikelihood,
        description: []const u8,
    ) !u32 {
        const factors = self.risk_factors.getPtr(assessment_id) orelse return error.AssessmentNotFound;

        const factor_id = self.next_factor_id;
        var factor = RiskFactor.init(factor_id, category, severity, likelihood);
        factor.setDescription(description);

        try factors.append(factor);
        self.next_factor_id += 1;
        self.stats.risk_factors_identified += 1;

        // Update DPIA overall risk
        if (self.assessments.getPtr(assessment_id)) |dpia| {
            self.updateOverallRisk(dpia, factors.items);
        }

        return factor_id;
    }

    /// Add mitigation measure to DPIA.
    pub fn addMitigation(
        self: *DPIAManager,
        assessment_id: u64,
        mitigation_type: MitigationMeasure.MitigationType,
        description: []const u8,
    ) !u32 {
        const mits = self.mitigations.getPtr(assessment_id) orelse return error.AssessmentNotFound;

        const mitigation_id = self.next_mitigation_id;
        var mitigation = MitigationMeasure.init(mitigation_id, mitigation_type);
        mitigation.setDescription(description);

        try mits.append(mitigation);
        self.next_mitigation_id += 1;

        return mitigation_id;
    }

    /// Link mitigation to risk factor.
    pub fn linkMitigationToRisk(
        self: *DPIAManager,
        assessment_id: u64,
        factor_id: u32,
        mitigation_id: u32,
    ) !bool {
        const factors = self.risk_factors.getPtr(assessment_id) orelse return error.AssessmentNotFound;

        for (factors.items) |*factor| {
            if (factor.factor_id == factor_id) {
                return factor.addMitigation(mitigation_id);
            }
        }
        return false;
    }

    /// Mark mitigation as implemented.
    pub fn implementMitigation(
        self: *DPIAManager,
        assessment_id: u64,
        mitigation_id: u32,
    ) !bool {
        const mits = self.mitigations.getPtr(assessment_id) orelse return error.AssessmentNotFound;

        for (mits.items) |*mit| {
            if (mit.mitigation_id == mitigation_id) {
                mit.markImplemented();
                self.stats.mitigations_implemented += 1;
                return true;
            }
        }
        return false;
    }

    /// Update overall risk based on factors.
    fn updateOverallRisk(self: *DPIAManager, dpia: *DPIA, factors: []const RiskFactor) void {
        if (factors.len == 0) {
            dpia.overall_risk = .low;
            return;
        }

        var max_score: u8 = 0;
        var unmitigated_high: u8 = 0;

        for (factors) |factor| {
            const score = factor.riskScore();
            if (score > max_score) max_score = score;
            if (!factor.mitigated and factor.severity == .high) {
                unmitigated_high += 1;
            }
            if (!factor.mitigated and factor.severity == .critical) {
                unmitigated_high += 2;
            }
        }

        // Determine overall risk
        if (max_score >= 12 or unmitigated_high >= 3) {
            dpia.overall_risk = .critical;
            dpia.authority_consultation_required = true;
        } else if (max_score >= 9 or unmitigated_high >= 2) {
            dpia.overall_risk = .high;
            self.stats.high_risk_assessments += 1;
        } else if (max_score >= 6) {
            dpia.overall_risk = .medium;
        } else {
            dpia.overall_risk = .low;
        }
    }

    /// Perform necessity assessment.
    pub fn assessNecessity(
        self: *DPIAManager,
        assessment_id: u64,
        legal_basis: LegalBasis,
        purpose_defined: bool,
        processing_necessary: bool,
        alternatives_considered: bool,
        data_minimized: bool,
        proportionate: bool,
        assessor_id: u128,
    ) !void {
        const dpia = self.assessments.getPtr(assessment_id) orelse return error.AssessmentNotFound;

        var score: u16 = 0;
        if (purpose_defined) score += 20;
        if (processing_necessary) score += 20;
        if (alternatives_considered) score += 20;
        if (data_minimized) score += 20;
        if (proportionate) score += 20;

        dpia.necessity = .{
            .legal_basis = legal_basis,
            .purpose_defined = purpose_defined,
            .processing_necessary = processing_necessary,
            .alternatives_considered = alternatives_considered,
            .data_minimized = data_minimized,
            .proportionate = proportionate,
            .score = @intCast(score),
            .assessed_at = getCurrentTimestamp(),
            .assessor_id = assessor_id,
        };
    }

    /// Get DPIAs due for review.
    pub fn getDPIAsDueForReview(self: *DPIAManager, buffer: []DPIA) usize {
        var count: usize = 0;
        var iter = self.assessments.valueIterator();
        while (iter.next()) |dpia| {
            if (dpia.isReviewDue() and count < buffer.len) {
                buffer[count] = dpia.*;
                count += 1;
            }
        }
        self.stats.pending_review = count;
        return count;
    }

    /// Get risk factors for DPIA.
    pub fn getRiskFactors(self: *DPIAManager, assessment_id: u64) ?[]RiskFactor {
        const factors = self.risk_factors.get(assessment_id) orelse return null;
        return factors.items;
    }

    /// Get mitigations for DPIA.
    pub fn getMitigations(self: *DPIAManager, assessment_id: u64) ?[]MitigationMeasure {
        const mits = self.mitigations.get(assessment_id) orelse return null;
        return mits.items;
    }

    /// Generate DPIA summary report.
    pub fn generateSummary(self: *DPIAManager, assessment_id: u64) ?DPIASummary {
        const dpia = self.assessments.get(assessment_id) orelse return null;
        const factors = self.risk_factors.get(assessment_id) orelse return null;
        const mits = self.mitigations.get(assessment_id) orelse return null;

        var total_risk_score: u32 = 0;
        var unmitigated_risks: u8 = 0;
        var critical_risks: u8 = 0;

        for (factors.items) |factor| {
            total_risk_score += factor.riskScore();
            if (!factor.mitigated) unmitigated_risks += 1;
            if (factor.severity == .critical) critical_risks += 1;
        }

        var implemented_mitigations: u8 = 0;
        for (mits.items) |mit| {
            if (mit.status == .implemented or mit.status == .verified) {
                implemented_mitigations += 1;
            }
        }

        return .{
            .assessment_id = assessment_id,
            .status = dpia.status,
            .overall_risk = dpia.overall_risk,
            .high_risk_indicator_count = dpia.countHighRiskIndicators(),
            .total_risk_factors = @intCast(factors.items.len),
            .unmitigated_risks = unmitigated_risks,
            .critical_risks = critical_risks,
            .average_risk_score = if (factors.items.len > 0)
                @intCast(total_risk_score / @as(u32, @intCast(factors.items.len)))
            else
                0,
            .total_mitigations = @intCast(mits.items.len),
            .implemented_mitigations = implemented_mitigations,
            .necessity_satisfied = dpia.necessity.isSatisfied(),
            .dpo_consulted = dpia.dpo_consulted,
            .authority_consulted = dpia.authority_consulted,
            .approved = dpia.approved,
            .review_due = dpia.isReviewDue(),
        };
    }

    pub const DPIASummary = struct {
        assessment_id: u64,
        status: DPIA.AssessmentStatus,
        overall_risk: RiskSeverity,
        high_risk_indicator_count: u8,
        total_risk_factors: u8,
        unmitigated_risks: u8,
        critical_risks: u8,
        average_risk_score: u8,
        total_mitigations: u8,
        implemented_mitigations: u8,
        necessity_satisfied: bool,
        dpo_consulted: bool,
        authority_consulted: bool,
        approved: bool,
        review_due: bool,
    };

    /// Get statistics.
    pub fn getStatistics(self: *DPIAManager) Statistics {
        return self.stats;
    }

    /// Approve DPIA.
    pub fn approveDPIA(self: *DPIAManager, assessment_id: u64, approver_id: u128) !bool {
        const dpia = self.assessments.getPtr(assessment_id) orelse return error.AssessmentNotFound;
        if (dpia.approve(approver_id)) {
            self.stats.approved_assessments += 1;
            return true;
        }
        return false;
    }
};

/// Get current timestamp.
fn getCurrentTimestamp() u64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Unit Tests
// ============================================================================

test "RiskFactor initialization and scoring" {
    const testing = std.testing;

    var factor = RiskFactor.init(1, .privacy, .high, .likely);
    factor.setDescription("User location can be tracked continuously");

    try testing.expectEqual(@as(u8, 9), factor.riskScore()); // 3 * 3
    try testing.expectEqualStrings("User location can be tracked continuously", factor.getDescription());
}

test "RiskFactor mitigation linking" {
    const testing = std.testing;

    var factor = RiskFactor.init(1, .confidentiality, .medium, .possible);
    try testing.expect(factor.addMitigation(100));
    try testing.expect(factor.addMitigation(101));
    try testing.expect(factor.addMitigation(102));
    try testing.expect(factor.addMitigation(103));
    try testing.expect(!factor.addMitigation(104)); // Should fail - max 4

    try testing.expectEqual(@as(u8, 4), factor.mitigation_count);
}

test "MitigationMeasure lifecycle" {
    const testing = std.testing;

    var mitigation = MitigationMeasure.init(1, .encryption);
    mitigation.setDescription("AES-256 encryption for location data at rest");

    try testing.expectEqual(MitigationMeasure.ImplementationStatus.planned, mitigation.status);

    mitigation.markImplemented();
    try testing.expectEqual(MitigationMeasure.ImplementationStatus.implemented, mitigation.status);
    try testing.expect(mitigation.implemented_at > 0);

    mitigation.markVerified(85);
    try testing.expectEqual(MitigationMeasure.ImplementationStatus.verified, mitigation.status);
    try testing.expectEqual(@as(u8, 85), mitigation.effectiveness);
}

test "DPIA initialization and high-risk indicators" {
    const testing = std.testing;

    var dpia = DPIA.init(1, 0x12345, .realtime_tracking);

    try testing.expectEqual(DPIA.AssessmentStatus.draft, dpia.status);
    try testing.expect(dpia.next_review_due > dpia.created_at);

    dpia.setHighRiskIndicator(HighRiskIndicator.large_scale_monitoring);
    dpia.setHighRiskIndicator(HighRiskIndicator.automated_decisions);

    try testing.expect(dpia.hasHighRiskIndicator(HighRiskIndicator.large_scale_monitoring));
    try testing.expect(dpia.hasHighRiskIndicator(HighRiskIndicator.automated_decisions));
    try testing.expect(!dpia.hasHighRiskIndicator(HighRiskIndicator.vulnerable_subjects));

    try testing.expectEqual(@as(u8, 2), dpia.countHighRiskIndicators());
}

test "NecessityAssessment satisfaction" {
    const testing = std.testing;

    const insufficient = NecessityAssessment{
        .legal_basis = .consent,
        .purpose_defined = true,
        .processing_necessary = false, // Missing
        .alternatives_considered = true,
        .data_minimized = true,
        .proportionate = true,
        .score = 80,
        .assessed_at = 0,
        .assessor_id = 0,
    };

    try testing.expect(!insufficient.isSatisfied());

    const sufficient = NecessityAssessment{
        .legal_basis = .legitimate_interests,
        .purpose_defined = true,
        .processing_necessary = true,
        .alternatives_considered = true,
        .data_minimized = true,
        .proportionate = true,
        .score = 100,
        .assessed_at = 0,
        .assessor_id = 0,
    };

    try testing.expect(sufficient.isSatisfied());
}

test "DPIAManager creation and DPIA workflow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DPIAManager.init(allocator);
    defer manager.deinit();

    const dpia_id = try manager.createDPIA(0x12345, .fleet_tracking);
    try testing.expectEqual(@as(u64, 1), dpia_id);

    const dpia = manager.getDPIA(dpia_id);
    try testing.expect(dpia != null);
    try testing.expect(dpia.?.dpo_consultation_required);
}

test "DPIAManager risk factor management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DPIAManager.init(allocator);
    defer manager.deinit();

    const dpia_id = try manager.createDPIA(0x12345, .movement_patterns);

    const factor_id = try manager.addRiskFactor(
        dpia_id,
        .privacy,
        .high,
        .likely,
        "Movement patterns reveal personal habits",
    );

    try testing.expectEqual(@as(u32, 1), factor_id);

    const factors = manager.getRiskFactors(dpia_id);
    try testing.expect(factors != null);
    try testing.expectEqual(@as(usize, 1), factors.?.len);
}

test "DPIAManager mitigation workflow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DPIAManager.init(allocator);
    defer manager.deinit();

    const dpia_id = try manager.createDPIA(0x12345, .location_profiling);

    const factor_id = try manager.addRiskFactor(
        dpia_id,
        .discrimination,
        .high,
        .possible,
        "Location data could enable discriminatory profiling",
    );

    const mit_id = try manager.addMitigation(
        dpia_id,
        .pseudonymization,
        "Pseudonymize location data before profiling",
    );

    const linked = try manager.linkMitigationToRisk(dpia_id, factor_id, mit_id);
    try testing.expect(linked);

    const implemented = try manager.implementMitigation(dpia_id, mit_id);
    try testing.expect(implemented);

    try testing.expectEqual(@as(u64, 1), manager.stats.mitigations_implemented);
}

test "DPIAManager necessity assessment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DPIAManager.init(allocator);
    defer manager.deinit();

    const dpia_id = try manager.createDPIA(0x12345, .emergency_services);

    try manager.assessNecessity(
        dpia_id,
        .vital_interests,
        true,
        true,
        true,
        true,
        true,
        0x99999,
    );

    const dpia = manager.getDPIA(dpia_id);
    try testing.expect(dpia != null);
    try testing.expect(dpia.?.necessity.isSatisfied());
    try testing.expectEqual(@as(u8, 100), dpia.?.necessity.score);
}

test "DPIAManager approval workflow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DPIAManager.init(allocator);
    defer manager.deinit();

    const dpia_id = try manager.createDPIA(0x12345, .research_analytics);

    // Set up necessity assessment
    try manager.assessNecessity(
        dpia_id,
        .legitimate_interests,
        true,
        true,
        true,
        true,
        true,
        0x99999,
    );

    // Complete DPO consultation
    if (manager.getDPIA(dpia_id)) |dpia| {
        dpia.completeDPOConsultation();
    }

    // Try to approve
    const approved = try manager.approveDPIA(dpia_id, 0xABCDE);
    try testing.expect(approved);

    const dpia = manager.getDPIA(dpia_id);
    try testing.expect(dpia.?.approved);
    try testing.expectEqual(DPIA.AssessmentStatus.approved, dpia.?.status);
}

test "DPIAManager summary generation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DPIAManager.init(allocator);
    defer manager.deinit();

    const dpia_id = try manager.createDPIA(0x12345, .location_advertising);

    _ = try manager.addRiskFactor(dpia_id, .privacy, .high, .likely, "User tracking");
    _ = try manager.addRiskFactor(dpia_id, .autonomy, .medium, .possible, "Behavioral manipulation");

    const mit_id = try manager.addMitigation(dpia_id, .consent_mechanism, "Explicit opt-in");
    _ = try manager.implementMitigation(dpia_id, mit_id);

    const summary = manager.generateSummary(dpia_id);
    try testing.expect(summary != null);
    try testing.expectEqual(@as(u8, 2), summary.?.total_risk_factors);
    try testing.expectEqual(@as(u8, 1), summary.?.total_mitigations);
    try testing.expectEqual(@as(u8, 1), summary.?.implemented_mitigations);
}

test "DPIA consultation requirements" {
    const testing = std.testing;

    var dpia = DPIA.init(1, 0x12345, .cross_device_linking);

    // Set multiple high-risk indicators
    dpia.setHighRiskIndicator(HighRiskIndicator.large_scale_monitoring);
    dpia.setHighRiskIndicator(HighRiskIndicator.cross_border_transfer);
    dpia.setHighRiskIndicator(HighRiskIndicator.dataset_combination);

    try testing.expect(dpia.dpo_consultation_required);
    try testing.expect(dpia.authority_consultation_required);
}

test "High-risk indicator detection for processing types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try DPIAManager.init(allocator);
    defer manager.deinit();

    // Automated decisions should set the indicator
    const id1 = try manager.createDPIA(0x1, .automated_decisions);
    const dpia1 = manager.getDPIA(id1);
    try testing.expect(dpia1.?.hasHighRiskIndicator(HighRiskIndicator.automated_decisions));

    // Third party sharing should set cross-border indicator
    const id2 = try manager.createDPIA(0x2, .third_party_sharing);
    const dpia2 = manager.getDPIA(id2);
    try testing.expect(dpia2.?.hasHighRiskIndicator(HighRiskIndicator.cross_border_transfer));
}
