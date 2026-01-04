// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// Export control compliance checks for cryptographic and geospatial technology.
// Implements EAR/ITAR compliance verification per US export control regulations.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum description/note length.
pub const MAX_DESCRIPTION: usize = 512;

/// Maximum entity name length.
pub const MAX_ENTITY_NAME: usize = 128;

/// Country code length (ISO 3166-1 alpha-2).
pub const COUNTRY_CODE_LEN: usize = 2;

/// Export Control Classification Number categories.
pub const ECCNCategory = enum(u8) {
    /// Category 0: Nuclear Materials
    nuclear = 0,
    /// Category 1: Materials, Chemicals
    materials = 1,
    /// Category 2: Materials Processing
    processing = 2,
    /// Category 3: Electronics
    electronics = 3,
    /// Category 4: Computers
    computers = 4,
    /// Category 5: Telecommunications & Information Security
    telecommunications = 5,
    /// Category 6: Sensors and Lasers
    sensors = 6,
    /// Category 7: Navigation and Avionics
    navigation = 7,
    /// Category 8: Marine
    marine = 8,
    /// Category 9: Aerospace and Propulsion
    aerospace = 9,
    /// EAR99: No specific ECCN (mass market)
    ear99 = 99,
};

/// Encryption strength classification.
pub const EncryptionStrength = enum(u8) {
    /// No encryption.
    none = 0,
    /// Weak encryption (< 56 bits).
    weak = 1,
    /// Standard encryption (56-128 bits).
    standard = 2,
    /// Strong encryption (> 128 bits).
    strong = 3,
    /// Military grade (> 256 bits with additional controls).
    military = 4,
};

/// License requirement status.
pub const LicenseRequirement = enum(u8) {
    /// No license required (NLR).
    not_required = 0,
    /// License exception available.
    exception_available = 1,
    /// License required.
    required = 2,
    /// Prohibited - no license available.
    prohibited = 3,
    /// Requires review.
    requires_review = 4,
};

/// Sanction list type.
pub const SanctionListType = enum(u8) {
    /// OFAC Specially Designated Nationals (SDN).
    ofac_sdn = 0,
    /// Entity List (BIS).
    entity_list = 1,
    /// Denied Persons List.
    denied_persons = 2,
    /// Unverified List.
    unverified_list = 3,
    /// EU sanctions list.
    eu_sanctions = 4,
    /// UK sanctions list.
    uk_sanctions = 5,
    /// Comprehensive embargo.
    embargo = 6,
};

/// Data sensitivity classification for geospatial data.
pub const GeospatialSensitivity = enum(u8) {
    /// Public data (unrestricted).
    public = 0,
    /// Commercial data (standard restrictions).
    commercial = 1,
    /// Restricted data (requires license).
    restricted = 2,
    /// Controlled data (government only).
    controlled = 3,
    /// Classified data (security clearance required).
    classified = 4,
};

/// Dual-use classification.
pub const DualUseStatus = enum(u8) {
    /// Not dual-use.
    not_dual_use = 0,
    /// Potential dual-use.
    potential = 1,
    /// Confirmed dual-use.
    confirmed = 2,
    /// Military application.
    military = 3,
};

/// Export control check result.
pub const ExportCheckResult = struct {
    /// Whether export is permitted.
    permitted: bool,
    /// License requirement status.
    license_requirement: LicenseRequirement,
    /// Applicable ECCN category.
    eccn_category: ECCNCategory,
    /// Sanction list matches (bitmask).
    sanction_matches: u8,
    /// Restriction reason (if not permitted).
    restriction_reason: RestrictionReason,
    /// Required documentation (bitmask).
    required_documentation: u16,
    /// Review notes.
    notes: [MAX_DESCRIPTION]u8,
    /// Notes length.
    notes_len: u16,

    pub const RestrictionReason = enum(u8) {
        /// No restriction.
        none = 0,
        /// Sanctioned country.
        sanctioned_country = 1,
        /// Sanctioned entity.
        sanctioned_entity = 2,
        /// Encryption restrictions.
        encryption_restricted = 3,
        /// Dual-use restrictions.
        dual_use_restricted = 4,
        /// End-use concerns.
        end_use_concern = 5,
        /// Military application.
        military_application = 6,
        /// License denied.
        license_denied = 7,
        /// Embargo.
        embargo = 8,
    };

    /// Required documentation flags.
    pub const Documentation = struct {
        pub const end_user_certificate: u16 = 1 << 0;
        pub const license_application: u16 = 1 << 1;
        pub const classification_request: u16 = 1 << 2;
        pub const shipper_export_declaration: u16 = 1 << 3;
        pub const destination_control_statement: u16 = 1 << 4;
        pub const end_use_statement: u16 = 1 << 5;
        pub const technology_control_plan: u16 = 1 << 6;
        pub const deemed_export_verification: u16 = 1 << 7;
    };

    /// Initialize permitted result.
    pub fn permitted_result() ExportCheckResult {
        return .{
            .permitted = true,
            .license_requirement = .not_required,
            .eccn_category = .ear99,
            .sanction_matches = 0,
            .restriction_reason = .none,
            .required_documentation = 0,
            .notes = [_]u8{0} ** MAX_DESCRIPTION,
            .notes_len = 0,
        };
    }

    /// Initialize denied result.
    pub fn denied_result(reason: RestrictionReason) ExportCheckResult {
        return .{
            .permitted = false,
            .license_requirement = .prohibited,
            .eccn_category = .ear99,
            .sanction_matches = 0,
            .restriction_reason = reason,
            .required_documentation = 0,
            .notes = [_]u8{0} ** MAX_DESCRIPTION,
            .notes_len = 0,
        };
    }

    /// Set notes.
    pub fn setNotes(self: *ExportCheckResult, n: []const u8) void {
        const len = @min(n.len, MAX_DESCRIPTION);
        @memcpy(self.notes[0..len], n[0..len]);
        self.notes_len = @intCast(len);
    }
};

/// Country export control status.
pub const CountryStatus = struct {
    /// Country code (ISO 3166-1 alpha-2).
    country_code: [COUNTRY_CODE_LEN]u8,
    /// Country name.
    name: [64]u8,
    /// Name length.
    name_len: u8,
    /// Sanction status (bitmask of SanctionListType).
    sanction_status: u8,
    /// Embargo status.
    embargoed: bool,
    /// EAR country group.
    ear_group: EARCountryGroup,
    /// License requirement for encryption.
    encryption_license: LicenseRequirement,
    /// License requirement for geospatial tech.
    geospatial_license: LicenseRequirement,
    /// Is active in system.
    active: bool,

    /// EAR Country Groups.
    pub const EARCountryGroup = enum(u8) {
        /// Group A - Wassenaar, Australia Group, etc.
        group_a = 0,
        /// Group B - Most countries.
        group_b = 1,
        /// Group D - Countries of concern.
        group_d = 2,
        /// Group E - Terrorist-supporting states.
        group_e = 3,
        /// Not assigned.
        unassigned = 4,
    };

    /// Initialize country status.
    pub fn init(country_code: [2]u8, ear_group: EARCountryGroup) CountryStatus {
        return .{
            .country_code = country_code,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .sanction_status = 0,
            .embargoed = false,
            .ear_group = ear_group,
            .encryption_license = .not_required,
            .geospatial_license = .not_required,
            .active = true,
        };
    }

    /// Set name.
    pub fn setName(self: *CountryStatus, n: []const u8) void {
        const len = @min(n.len, 64);
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = @intCast(len);
    }

    /// Get name.
    pub fn getName(self: CountryStatus) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Check if on specific sanction list.
    pub fn isOnSanctionList(self: CountryStatus, list_type: SanctionListType) bool {
        return (self.sanction_status & (@as(u8, 1) << @intCast(@intFromEnum(list_type)))) != 0;
    }

    /// Add to sanction list.
    pub fn addToSanctionList(self: *CountryStatus, list_type: SanctionListType) void {
        self.sanction_status |= @as(u8, 1) << @intCast(@intFromEnum(list_type));
    }
};

/// Entity (organization/person) screening result.
pub const EntityScreening = struct {
    /// Entity identifier.
    entity_id: u128,
    /// Entity name.
    name: [MAX_ENTITY_NAME]u8,
    /// Name length.
    name_len: u8,
    /// Country code.
    country_code: [COUNTRY_CODE_LEN]u8,
    /// Sanction list matches (bitmask).
    list_matches: u8,
    /// Match confidence (0-100).
    confidence: u8,
    /// Screening timestamp.
    screened_at: u64,
    /// Is blocked.
    blocked: bool,
    /// Review required.
    requires_review: bool,

    /// Initialize screening result.
    pub fn init(entity_id: u128, country_code: [2]u8) EntityScreening {
        return .{
            .entity_id = entity_id,
            .name = [_]u8{0} ** MAX_ENTITY_NAME,
            .name_len = 0,
            .country_code = country_code,
            .list_matches = 0,
            .confidence = 0,
            .screened_at = getCurrentTimestamp(),
            .blocked = false,
            .requires_review = false,
        };
    }

    /// Set name.
    pub fn setName(self: *EntityScreening, n: []const u8) void {
        const len = @min(n.len, MAX_ENTITY_NAME);
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = @intCast(len);
    }

    /// Get name.
    pub fn getName(self: EntityScreening) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Check if on any list.
    pub fn isOnAnyList(self: EntityScreening) bool {
        return self.list_matches != 0;
    }

    /// Count list matches.
    pub fn countListMatches(self: EntityScreening) u8 {
        return @popCount(self.list_matches);
    }
};

/// Cryptographic feature classification.
pub const CryptoClassification = struct {
    /// Feature identifier.
    feature_id: u32,
    /// Feature name.
    name: [64]u8,
    /// Name length.
    name_len: u8,
    /// Algorithm used.
    algorithm: CryptoAlgorithm,
    /// Key length in bits.
    key_length_bits: u16,
    /// Encryption strength classification.
    strength: EncryptionStrength,
    /// ECCN classification.
    eccn: ECCNCategory,
    /// Is mass market eligible.
    mass_market_eligible: bool,
    /// License exception available.
    license_exception: LicenseException,
    /// Is publicly available source.
    publicly_available: bool,

    pub const CryptoAlgorithm = enum(u8) {
        /// No encryption.
        none = 0,
        /// AES (all key sizes).
        aes = 1,
        /// ChaCha20.
        chacha20 = 2,
        /// RSA.
        rsa = 3,
        /// Elliptic Curve (ECDSA, ECDH).
        elliptic_curve = 4,
        /// SHA family (hash, not encryption).
        sha = 5,
        /// TLS/SSL.
        tls = 6,
        /// Custom/proprietary.
        custom = 7,
    };

    pub const LicenseException = enum(u8) {
        /// No exception.
        none = 0,
        /// TSR - Technology and Software Unrestricted.
        tsr = 1,
        /// ENC - Encryption Commodities.
        enc = 2,
        /// Mass market (ENC-mass).
        mass_market = 3,
        /// STA - Strategic Trade Authorization.
        sta = 4,
    };

    /// Initialize classification.
    pub fn init(feature_id: u32, algorithm: CryptoAlgorithm, key_length: u16) CryptoClassification {
        var class = CryptoClassification{
            .feature_id = feature_id,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .algorithm = algorithm,
            .key_length_bits = key_length,
            .strength = .none,
            .eccn = .ear99,
            .mass_market_eligible = false,
            .license_exception = .none,
            .publicly_available = false,
        };
        class.classifyStrength();
        return class;
    }

    /// Set name.
    pub fn setName(self: *CryptoClassification, n: []const u8) void {
        const len = @min(n.len, 64);
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = @intCast(len);
    }

    /// Classify encryption strength based on key length.
    fn classifyStrength(self: *CryptoClassification) void {
        if (self.algorithm == .none or self.algorithm == .sha) {
            self.strength = .none;
            return;
        }

        if (self.key_length_bits < 56) {
            self.strength = .weak;
        } else if (self.key_length_bits <= 128) {
            self.strength = .standard;
        } else if (self.key_length_bits <= 256) {
            self.strength = .strong;
        } else {
            self.strength = .military;
        }
    }

    /// Determine if mass market eligible.
    pub fn checkMassMarketEligibility(self: *CryptoClassification) void {
        // AES-128/256 with publicly available source is typically mass market
        if (self.publicly_available and self.algorithm == .aes) {
            if (self.key_length_bits <= 256) {
                self.mass_market_eligible = true;
                self.license_exception = .mass_market;
            }
        }

        // TLS/SSL is generally mass market
        if (self.algorithm == .tls and self.publicly_available) {
            self.mass_market_eligible = true;
            self.license_exception = .mass_market;
        }
    }
};

/// Geospatial data classification.
pub const GeospatialClassification = struct {
    /// Classification identifier.
    classification_id: u32,
    /// Data type.
    data_type: GeospatialDataType,
    /// Sensitivity level.
    sensitivity: GeospatialSensitivity,
    /// Resolution in meters.
    resolution_meters: f32,
    /// Coverage area type.
    coverage: CoverageType,
    /// Dual-use status.
    dual_use: DualUseStatus,
    /// Export license requirement.
    license_requirement: LicenseRequirement,
    /// Is real-time data.
    real_time: bool,
    /// Contains infrastructure data.
    infrastructure: bool,

    pub const GeospatialDataType = enum(u8) {
        /// Point location data.
        point_location = 0,
        /// Track/route data.
        track_data = 1,
        /// Geofence boundaries.
        geofence = 2,
        /// Imagery/satellite data.
        imagery = 3,
        /// Terrain/elevation data.
        terrain = 4,
        /// Navigation data.
        navigation = 5,
        /// Infrastructure mapping.
        infrastructure_map = 6,
        /// Aggregated analytics.
        analytics = 7,
    };

    pub const CoverageType = enum(u8) {
        /// Single point.
        point = 0,
        /// Local area (< 100 km²).
        local = 1,
        /// Regional (100-10000 km²).
        regional = 2,
        /// National.
        national = 3,
        /// International.
        international = 4,
    };

    /// Initialize classification.
    pub fn init(classification_id: u32, data_type: GeospatialDataType) GeospatialClassification {
        return .{
            .classification_id = classification_id,
            .data_type = data_type,
            .sensitivity = .commercial,
            .resolution_meters = 10.0,
            .coverage = .local,
            .dual_use = .not_dual_use,
            .license_requirement = .not_required,
            .real_time = false,
            .infrastructure = false,
        };
    }

    /// Assess sensitivity based on characteristics.
    pub fn assessSensitivity(self: *GeospatialClassification) void {
        // High resolution imagery is more sensitive
        if (self.data_type == .imagery and self.resolution_meters < 1.0) {
            self.sensitivity = .restricted;
            self.dual_use = .potential;
        }

        // Infrastructure mapping is sensitive
        if (self.infrastructure or self.data_type == .infrastructure_map) {
            if (@intFromEnum(self.sensitivity) < @intFromEnum(GeospatialSensitivity.restricted)) {
                self.sensitivity = .restricted;
            }
        }

        // Real-time national/international coverage
        if (self.real_time and
            (@intFromEnum(self.coverage) >= @intFromEnum(CoverageType.national)))
        {
            self.dual_use = .potential;
        }

        // Navigation data for certain areas
        if (self.data_type == .navigation and self.dual_use != .not_dual_use) {
            self.license_requirement = .requires_review;
        }
    }
};

/// Export control compliance manager.
pub const ExportControlManager = struct {
    allocator: Allocator,
    /// Country status registry.
    countries: std.AutoHashMap([2]u8, CountryStatus),
    /// Entity screening results.
    entity_screenings: std.AutoHashMap(u128, EntityScreening),
    /// Crypto classifications.
    crypto_classifications: std.ArrayList(CryptoClassification),
    /// Geospatial classifications.
    geo_classifications: std.ArrayList(GeospatialClassification),
    /// Next feature ID.
    next_feature_id: u32,
    /// Next classification ID.
    next_classification_id: u32,
    /// Statistics.
    stats: Statistics,

    pub const Statistics = struct {
        exports_checked: u64 = 0,
        exports_permitted: u64 = 0,
        exports_denied: u64 = 0,
        entities_screened: u64 = 0,
        sanction_matches: u64 = 0,
    };

    /// Initialize export control manager.
    pub fn init(allocator: Allocator) !ExportControlManager {
        var manager = ExportControlManager{
            .allocator = allocator,
            .countries = std.AutoHashMap([2]u8, CountryStatus).init(allocator),
            .entity_screenings = std.AutoHashMap(u128, EntityScreening).init(allocator),
            .crypto_classifications = std.ArrayList(CryptoClassification).init(allocator),
            .geo_classifications = std.ArrayList(GeospatialClassification).init(allocator),
            .next_feature_id = 1,
            .next_classification_id = 1,
            .stats = .{},
        };

        // Initialize default country classifications
        try manager.initializeDefaultCountries();

        return manager;
    }

    /// Initialize default country classifications.
    fn initializeDefaultCountries(self: *ExportControlManager) !void {
        // Group A countries (generally no restrictions)
        const group_a = [_][2]u8{
            "AU".*, "AT".*, "BE".*, "CA".*, "CZ".*, "DK".*, "EE".*, "FI".*,
            "FR".*, "DE".*, "GR".*, "HU".*, "IS".*, "IE".*, "IT".*, "JP".*,
            "LV".*, "LT".*, "LU".*, "NL".*, "NZ".*, "NO".*, "PL".*, "PT".*,
            "SK".*, "SI".*, "ES".*, "SE".*, "CH".*, "GB".*, "KR".*,
        };

        for (group_a) |code| {
            var status = CountryStatus.init(code, .group_a);
            status.encryption_license = .not_required;
            status.geospatial_license = .not_required;
            try self.countries.put(code, status);
        }

        // Group D countries (elevated controls)
        const group_d = [_][2]u8{
            "CN".*, "RU".*, "BY".*, "VN".*, "MM".*,
        };

        for (group_d) |code| {
            var status = CountryStatus.init(code, .group_d);
            status.encryption_license = .required;
            status.geospatial_license = .required;
            try self.countries.put(code, status);
        }

        // Group E countries (embargo/sanctions)
        const group_e = [_][2]u8{
            "CU".*, "IR".*, "KP".*, "SY".*,
        };

        for (group_e) |code| {
            var status = CountryStatus.init(code, .group_e);
            status.embargoed = true;
            status.encryption_license = .prohibited;
            status.geospatial_license = .prohibited;
            status.addToSanctionList(.embargo);
            try self.countries.put(code, status);
        }
    }

    /// Deinitialize.
    pub fn deinit(self: *ExportControlManager) void {
        self.countries.deinit();
        self.entity_screenings.deinit();
        self.crypto_classifications.deinit();
        self.geo_classifications.deinit();
    }

    /// Check export eligibility for a destination.
    pub fn checkExport(
        self: *ExportControlManager,
        destination_country: [2]u8,
        recipient_id: u128,
        has_encryption: bool,
        encryption_strength: EncryptionStrength,
        has_geospatial: bool,
        geo_sensitivity: GeospatialSensitivity,
    ) ExportCheckResult {
        self.stats.exports_checked += 1;

        // Check country status
        const country = self.countries.get(destination_country) orelse {
            // Unknown country - requires review
            var result = ExportCheckResult.denied_result(.none);
            result.license_requirement = .requires_review;
            result.setNotes("Unknown destination country - manual review required");
            return result;
        };

        // Check embargo
        if (country.embargoed) {
            self.stats.exports_denied += 1;
            var result = ExportCheckResult.denied_result(.embargo);
            result.sanction_matches = country.sanction_status;
            result.setNotes("Comprehensive embargo in effect");
            return result;
        }

        // Check entity screening
        if (self.entity_screenings.get(recipient_id)) |screening| {
            if (screening.blocked) {
                self.stats.exports_denied += 1;
                var result = ExportCheckResult.denied_result(.sanctioned_entity);
                result.sanction_matches = screening.list_matches;
                result.setNotes("Recipient on sanctions list");
                return result;
            }
        }

        // Check encryption controls
        if (has_encryption) {
            const enc_result = self.checkEncryptionExport(country, encryption_strength);
            if (!enc_result.permitted) {
                self.stats.exports_denied += 1;
                return enc_result;
            }
        }

        // Check geospatial controls
        if (has_geospatial) {
            const geo_result = self.checkGeospatialExport(country, geo_sensitivity);
            if (!geo_result.permitted) {
                self.stats.exports_denied += 1;
                return geo_result;
            }
        }

        // Export permitted
        self.stats.exports_permitted += 1;
        var result = ExportCheckResult.permitted_result();

        // Determine documentation requirements based on country group
        if (country.ear_group == .group_d) {
            result.required_documentation |= ExportCheckResult.Documentation.end_user_certificate;
            result.required_documentation |= ExportCheckResult.Documentation.end_use_statement;
        }

        return result;
    }

    /// Check encryption-specific export controls.
    fn checkEncryptionExport(self: *ExportControlManager, country: CountryStatus, strength: EncryptionStrength) ExportCheckResult {
        _ = self;

        switch (country.encryption_license) {
            .not_required => {
                return ExportCheckResult.permitted_result();
            },
            .exception_available => {
                var result = ExportCheckResult.permitted_result();
                result.license_requirement = .exception_available;
                return result;
            },
            .required => {
                // Strong encryption to Group D requires license
                if (strength == .strong or strength == .military) {
                    var result = ExportCheckResult.denied_result(.encryption_restricted);
                    result.license_requirement = .required;
                    result.eccn_category = .telecommunications;
                    result.required_documentation |= ExportCheckResult.Documentation.license_application;
                    result.required_documentation |= ExportCheckResult.Documentation.classification_request;
                    result.setNotes("Strong encryption requires license for this destination");
                    return result;
                }
                // Standard encryption may be eligible for exception
                var result = ExportCheckResult.permitted_result();
                result.license_requirement = .exception_available;
                return result;
            },
            .prohibited => {
                var result = ExportCheckResult.denied_result(.encryption_restricted);
                result.setNotes("Encryption export prohibited to this destination");
                return result;
            },
            .requires_review => {
                var result = ExportCheckResult.denied_result(.none);
                result.license_requirement = .requires_review;
                result.setNotes("Encryption export requires manual review");
                return result;
            },
        }
    }

    /// Check geospatial-specific export controls.
    fn checkGeospatialExport(self: *ExportControlManager, country: CountryStatus, sensitivity: GeospatialSensitivity) ExportCheckResult {
        _ = self;

        switch (country.geospatial_license) {
            .not_required => {
                // Public/commercial data OK
                if (sensitivity == .public or sensitivity == .commercial) {
                    return ExportCheckResult.permitted_result();
                }
                // Restricted data may need documentation
                if (sensitivity == .restricted) {
                    var result = ExportCheckResult.permitted_result();
                    result.required_documentation |= ExportCheckResult.Documentation.end_use_statement;
                    return result;
                }
                // Controlled/classified not permitted
                var result = ExportCheckResult.denied_result(.dual_use_restricted);
                result.setNotes("Controlled geospatial data requires special authorization");
                return result;
            },
            .exception_available, .required => {
                if (sensitivity == .public) {
                    return ExportCheckResult.permitted_result();
                }
                var result = ExportCheckResult.denied_result(.dual_use_restricted);
                result.license_requirement = .required;
                result.eccn_category = .navigation;
                result.required_documentation |= ExportCheckResult.Documentation.license_application;
                result.setNotes("Geospatial data export requires license");
                return result;
            },
            .prohibited => {
                var result = ExportCheckResult.denied_result(.dual_use_restricted);
                result.setNotes("Geospatial export prohibited to this destination");
                return result;
            },
            .requires_review => {
                var result = ExportCheckResult.denied_result(.none);
                result.license_requirement = .requires_review;
                return result;
            },
        }
    }

    /// Screen an entity against sanction lists.
    pub fn screenEntity(
        self: *ExportControlManager,
        entity_id: u128,
        name: []const u8,
        country_code: [2]u8,
    ) !EntityScreening {
        var screening = EntityScreening.init(entity_id, country_code);
        screening.setName(name);

        self.stats.entities_screened += 1;

        // Check country sanctions
        if (self.countries.get(country_code)) |country| {
            if (country.embargoed) {
                screening.list_matches |= @as(u8, 1) << @intFromEnum(SanctionListType.embargo);
                screening.blocked = true;
                screening.confidence = 100;
            }
            if (country.sanction_status != 0) {
                screening.list_matches |= country.sanction_status;
                screening.requires_review = true;
            }
        }

        // In production, would integrate with OFAC SDN, Entity List, etc.
        // For now, flag high-risk indicators for review
        if (screening.list_matches != 0) {
            self.stats.sanction_matches += 1;
        }

        try self.entity_screenings.put(entity_id, screening);
        return screening;
    }

    /// Get entity screening result.
    pub fn getEntityScreening(self: *ExportControlManager, entity_id: u128) ?EntityScreening {
        return self.entity_screenings.get(entity_id);
    }

    /// Add crypto classification.
    pub fn addCryptoClassification(
        self: *ExportControlManager,
        algorithm: CryptoClassification.CryptoAlgorithm,
        key_length: u16,
        publicly_available: bool,
    ) !u32 {
        const feature_id = self.next_feature_id;
        var class = CryptoClassification.init(feature_id, algorithm, key_length);
        class.publicly_available = publicly_available;
        class.checkMassMarketEligibility();

        try self.crypto_classifications.append(class);
        self.next_feature_id += 1;

        return feature_id;
    }

    /// Add geospatial classification.
    pub fn addGeoClassification(
        self: *ExportControlManager,
        data_type: GeospatialClassification.GeospatialDataType,
        resolution: f32,
        real_time: bool,
        infrastructure: bool,
    ) !u32 {
        const classification_id = self.next_classification_id;
        var class = GeospatialClassification.init(classification_id, data_type);
        class.resolution_meters = resolution;
        class.real_time = real_time;
        class.infrastructure = infrastructure;
        class.assessSensitivity();

        try self.geo_classifications.append(class);
        self.next_classification_id += 1;

        return classification_id;
    }

    /// Get country status.
    pub fn getCountryStatus(self: *ExportControlManager, country_code: [2]u8) ?CountryStatus {
        return self.countries.get(country_code);
    }

    /// Update country status.
    pub fn updateCountryStatus(self: *ExportControlManager, status: CountryStatus) !void {
        try self.countries.put(status.country_code, status);
    }

    /// Get statistics.
    pub fn getStatistics(self: *ExportControlManager) Statistics {
        return self.stats;
    }

    /// Generate compliance summary.
    pub fn generateComplianceSummary(self: *ExportControlManager) ComplianceSummary {
        var crypto_count: u32 = 0;
        var mass_market_count: u32 = 0;

        for (self.crypto_classifications.items) |class| {
            crypto_count += 1;
            if (class.mass_market_eligible) mass_market_count += 1;
        }

        var geo_restricted: u32 = 0;
        for (self.geo_classifications.items) |class| {
            if (@intFromEnum(class.sensitivity) >= @intFromEnum(GeospatialSensitivity.restricted)) {
                geo_restricted += 1;
            }
        }

        return .{
            .exports_checked = self.stats.exports_checked,
            .exports_permitted = self.stats.exports_permitted,
            .exports_denied = self.stats.exports_denied,
            .approval_rate = if (self.stats.exports_checked > 0)
                @as(u8, @intCast((self.stats.exports_permitted * 100) / self.stats.exports_checked))
            else
                100,
            .entities_screened = self.stats.entities_screened,
            .sanction_matches = self.stats.sanction_matches,
            .crypto_features = crypto_count,
            .mass_market_crypto = mass_market_count,
            .geo_classifications = @intCast(self.geo_classifications.items.len),
            .geo_restricted = geo_restricted,
        };
    }

    pub const ComplianceSummary = struct {
        exports_checked: u64,
        exports_permitted: u64,
        exports_denied: u64,
        approval_rate: u8,
        entities_screened: u64,
        sanction_matches: u64,
        crypto_features: u32,
        mass_market_crypto: u32,
        geo_classifications: u32,
        geo_restricted: u32,
    };
};

/// Get current timestamp.
fn getCurrentTimestamp() u64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Unit Tests
// ============================================================================

test "CountryStatus sanction list management" {
    const testing = std.testing;

    var status = CountryStatus.init("IR".*, .group_e);
    status.addToSanctionList(.embargo);
    status.addToSanctionList(.ofac_sdn);

    try testing.expect(status.isOnSanctionList(.embargo));
    try testing.expect(status.isOnSanctionList(.ofac_sdn));
    try testing.expect(!status.isOnSanctionList(.entity_list));
}

test "EntityScreening initialization" {
    const testing = std.testing;

    var screening = EntityScreening.init(0x12345, "US".*);
    screening.setName("Test Corporation");
    screening.list_matches = 0;

    try testing.expect(!screening.isOnAnyList());
    try testing.expectEqual(@as(u8, 0), screening.countListMatches());

    screening.list_matches = 0x05; // Two lists
    try testing.expect(screening.isOnAnyList());
    try testing.expectEqual(@as(u8, 2), screening.countListMatches());
}

test "CryptoClassification strength classification" {
    const testing = std.testing;

    const weak = CryptoClassification.init(1, .aes, 40);
    try testing.expectEqual(EncryptionStrength.weak, weak.strength);

    const standard = CryptoClassification.init(2, .aes, 128);
    try testing.expectEqual(EncryptionStrength.standard, standard.strength);

    const strong = CryptoClassification.init(3, .aes, 256);
    try testing.expectEqual(EncryptionStrength.strong, strong.strength);
}

test "CryptoClassification mass market eligibility" {
    const testing = std.testing;

    var class = CryptoClassification.init(1, .aes, 256);
    class.publicly_available = true;
    class.checkMassMarketEligibility();

    try testing.expect(class.mass_market_eligible);
    try testing.expectEqual(CryptoClassification.LicenseException.mass_market, class.license_exception);
}

test "GeospatialClassification sensitivity assessment" {
    const testing = std.testing;

    var class = GeospatialClassification.init(1, .imagery);
    class.resolution_meters = 0.5; // High resolution
    class.assessSensitivity();

    try testing.expectEqual(GeospatialSensitivity.restricted, class.sensitivity);
    try testing.expectEqual(DualUseStatus.potential, class.dual_use);
}

test "GeospatialClassification infrastructure sensitivity" {
    const testing = std.testing;

    var class = GeospatialClassification.init(1, .infrastructure_map);
    class.assessSensitivity();

    try testing.expect(@intFromEnum(class.sensitivity) >= @intFromEnum(GeospatialSensitivity.restricted));
}

test "ExportControlManager initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ExportControlManager.init(allocator);
    defer manager.deinit();

    // Check Group A country
    const japan = manager.getCountryStatus("JP".*);
    try testing.expect(japan != null);
    try testing.expectEqual(CountryStatus.EARCountryGroup.group_a, japan.?.ear_group);
    try testing.expectEqual(LicenseRequirement.not_required, japan.?.encryption_license);

    // Check Group E country
    const iran = manager.getCountryStatus("IR".*);
    try testing.expect(iran != null);
    try testing.expect(iran.?.embargoed);
    try testing.expectEqual(LicenseRequirement.prohibited, iran.?.encryption_license);
}

test "ExportControlManager export to Group A country" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ExportControlManager.init(allocator);
    defer manager.deinit();

    const result = manager.checkExport(
        "JP".*,
        0x12345,
        true,
        .strong,
        true,
        .commercial,
    );

    try testing.expect(result.permitted);
    try testing.expectEqual(LicenseRequirement.not_required, result.license_requirement);
}

test "ExportControlManager export to embargoed country" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ExportControlManager.init(allocator);
    defer manager.deinit();

    const result = manager.checkExport(
        "KP".*,
        0x12345,
        false,
        .none,
        false,
        .public,
    );

    try testing.expect(!result.permitted);
    try testing.expectEqual(ExportCheckResult.RestrictionReason.embargo, result.restriction_reason);
}

test "ExportControlManager encryption to Group D country" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ExportControlManager.init(allocator);
    defer manager.deinit();

    const result = manager.checkExport(
        "CN".*,
        0x12345,
        true,
        .strong,
        false,
        .public,
    );

    try testing.expect(!result.permitted);
    try testing.expectEqual(ExportCheckResult.RestrictionReason.encryption_restricted, result.restriction_reason);
    try testing.expectEqual(LicenseRequirement.required, result.license_requirement);
}

test "ExportControlManager entity screening" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ExportControlManager.init(allocator);
    defer manager.deinit();

    // Screen entity in embargoed country
    const screening = try manager.screenEntity(0x12345, "Test Entity", "CU".*);
    try testing.expect(screening.blocked);
    try testing.expect(screening.isOnAnyList());

    // Check stats
    try testing.expectEqual(@as(u64, 1), manager.stats.entities_screened);
    try testing.expectEqual(@as(u64, 1), manager.stats.sanction_matches);
}

test "ExportControlManager crypto classification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ExportControlManager.init(allocator);
    defer manager.deinit();

    const feature_id = try manager.addCryptoClassification(.aes, 256, true);
    try testing.expectEqual(@as(u32, 1), feature_id);

    try testing.expectEqual(@as(usize, 1), manager.crypto_classifications.items.len);
    try testing.expect(manager.crypto_classifications.items[0].mass_market_eligible);
}

test "ExportControlManager geo classification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ExportControlManager.init(allocator);
    defer manager.deinit();

    const class_id = try manager.addGeoClassification(.imagery, 0.3, true, false);
    try testing.expectEqual(@as(u32, 1), class_id);

    try testing.expectEqual(@as(usize, 1), manager.geo_classifications.items.len);
    try testing.expectEqual(GeospatialSensitivity.restricted, manager.geo_classifications.items[0].sensitivity);
}

test "ExportControlManager compliance summary" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try ExportControlManager.init(allocator);
    defer manager.deinit();

    // Run some checks
    _ = manager.checkExport("JP".*, 0x1, true, .strong, false, .public);
    _ = manager.checkExport("KP".*, 0x2, false, .none, false, .public);
    _ = manager.checkExport("DE".*, 0x3, true, .standard, true, .commercial);

    const summary = manager.generateComplianceSummary();
    try testing.expectEqual(@as(u64, 3), summary.exports_checked);
    try testing.expectEqual(@as(u64, 2), summary.exports_permitted);
    try testing.expectEqual(@as(u64, 1), summary.exports_denied);
}
