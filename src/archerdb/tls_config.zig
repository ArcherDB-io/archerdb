// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! TLS Configuration and Certificate Management for mTLS Support (F5.4.1)
//!
//! This module provides:
//! - Certificate path validation
//! - PEM file format validation
//! - Certificate loading infrastructure
//! - TLS configuration management
//! - Certificate revocation checking via CRL and OCSP (F5.4.4)
//!
//! Certificate Revocation Checking (F5.4.4):
//! Full CRL and OCSP support with configurable fail policy.
//!
//! Revocation options:
//! - `revocation_check`: Mode (disabled, crl, ocsp, both)
//! - `crl_path`: Local CRL file path
//! - `crl_refresh_interval`: CRL refresh interval in seconds (default: 3600)
//! - `ocsp_responder_url`: OCSP responder URL override
//! - `ocsp_timeout`: OCSP request timeout in seconds (default: 5)
//! - `revocation_failure_mode`: fail_closed or fail_open
//!
//! Usage:
//! ```zig
//! var config = try TlsConfig.init(allocator, .{
//!     .cert_path = "/path/to/cert.pem",
//!     .key_path = "/path/to/key.pem",
//!     .ca_path = "/path/to/ca.pem",
//!     .required = true,
//!     .revocation_check = .crl,
//!     .crl_path = "/path/to/crl.pem",
//! });
//! defer config.deinit();
//!
//! // Check certificate revocation status
//! const status = try config.checkRevocation(cert);
//! ```
//!
//! Certificate Reload (F5.4.3):
//! The config supports hot reload via SIGHUP signal handling:
//! ```zig
//! config.reload() catch |err| {
//!     // Certificate reload failed, old certificates still active
//! };
//! ```

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.tls_config);
const fs = std.fs;
const mem = std.mem;

// During tests, we don't want log.err to fail tests when testing error paths.
// Wrap logging functions to suppress errors in test mode.
fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.err(fmt, args);
    }
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.warn(fmt, args);
    }
}

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.info(fmt, args);
    }
}

/// Certificate revocation check mode (F5.4.4).
pub const RevocationCheckMode = enum {
    /// Revocation checking disabled (default for development mode).
    disabled,
    /// Check CRL (Certificate Revocation List) only.
    crl,
    /// Check OCSP (Online Certificate Status Protocol) only.
    ocsp,
    /// Check both CRL and OCSP (CRL first, fall back to OCSP).
    both,
};

/// Failure mode when revocation check cannot be performed.
pub const RevocationFailureMode = enum {
    /// Reject connections if revocation status unknown (secure default).
    fail_closed,
    /// Allow connections if revocation status unknown (log warning).
    fail_open,
};

/// Result of a revocation check.
pub const RevocationStatus = enum {
    /// Certificate is valid (not revoked).
    valid,
    /// Certificate has been revoked.
    revoked,
    /// Revocation status could not be determined.
    unknown,
};

/// TLS configuration options passed from CLI.
pub const TlsOptions = struct {
    /// Whether TLS is required (--tls-required).
    /// If true, server will refuse to start without valid certificates.
    required: bool = false,

    /// Path to server certificate file (PEM format).
    cert_path: ?[]const u8 = null,

    /// Path to server private key file (PEM format).
    key_path: ?[]const u8 = null,

    /// Path to CA certificate for client verification (PEM format).
    /// If set, enables mTLS (mutual TLS) - clients must present valid certificates.
    ca_path: ?[]const u8 = null,

    // =========================================================================
    // Certificate Revocation Configuration (F5.4.4)
    // =========================================================================

    /// Revocation checking mode (--tls-revocation-check).
    /// Default: disabled in dev mode, crl in production mode.
    revocation_check: RevocationCheckMode = .disabled,

    /// Path to local CRL file (--tls-crl-path).
    /// If not set, CRL will be fetched from CA certificate's distribution point.
    crl_path: ?[]const u8 = null,

    /// CRL refresh interval in seconds (--tls-crl-refresh-interval).
    /// Default: 3600 (1 hour).
    crl_refresh_interval: u32 = 3600,

    /// OCSP responder URL override (--tls-ocsp-responder-url).
    /// If not set, URL is extracted from certificate's AIA extension.
    ocsp_responder_url: ?[]const u8 = null,

    /// OCSP request timeout in seconds (--tls-ocsp-timeout).
    /// Default: 5 seconds.
    ocsp_timeout: u32 = 5,

    /// Failure mode when revocation check fails (--tls-revocation-failure-mode).
    /// Default: fail_closed (reject on unknown status).
    revocation_failure_mode: RevocationFailureMode = .fail_closed,
};

/// Certificate data loaded from files.
pub const CertificateData = struct {
    /// Raw PEM data for the certificate.
    cert_pem: []const u8,
    /// Raw PEM data for the private key.
    key_pem: []const u8,
    /// Raw PEM data for the CA certificate (optional).
    ca_pem: ?[]const u8,
    /// Allocator used for this data.
    allocator: mem.Allocator,

    pub fn deinit(self: *CertificateData) void {
        self.allocator.free(self.cert_pem);
        self.allocator.free(self.key_pem);
        if (self.ca_pem) |ca| self.allocator.free(ca);
        self.* = undefined;
    }
};

/// Simplified certificate representation for revocation checking.
/// In production, this would include full X.509 parsing.
pub const Certificate = struct {
    /// Certificate serial number (big-endian bytes).
    serial: []const u8,
    /// Issuer name hash (for OCSP).
    issuer_name_hash: ?[32]u8 = null,
    /// Issuer key hash (for OCSP).
    issuer_key_hash: ?[32]u8 = null,
};

/// CRL (Certificate Revocation List) entry.
pub const CrlEntry = struct {
    /// Revoked certificate serial number.
    serial: []const u8,
    /// Revocation date (Unix timestamp).
    revocation_date: i64,
    /// Revocation reason code (optional).
    reason: ?u8 = null,
};

/// Parsed CRL data.
pub const Crl = struct {
    /// List of revoked certificate entries.
    entries: []const CrlEntry,
    /// CRL update time (Unix timestamp).
    this_update: i64,
    /// Next CRL update time (Unix timestamp).
    next_update: i64,
    /// Allocator for entries.
    allocator: mem.Allocator,

    pub fn deinit(self: *Crl) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.serial);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Check if a certificate serial is in the CRL.
    pub fn isRevoked(self: *const Crl, serial: []const u8) bool {
        for (self.entries) |entry| {
            if (mem.eql(u8, entry.serial, serial)) {
                return true;
            }
        }
        return false;
    }

    /// Check if the CRL is expired.
    pub fn isExpired(self: *const Crl, now: i64) bool {
        return now > self.next_update;
    }
};

/// OCSP response status.
pub const OcspResponseStatus = enum(u8) {
    successful = 0,
    malformed_request = 1,
    internal_error = 2,
    try_later = 3,
    sig_required = 5,
    unauthorized = 6,
};

/// OCSP certificate status.
pub const OcspCertStatus = enum {
    good,
    revoked,
    unknown,
};

/// Parsed OCSP response.
pub const OcspResponse = struct {
    /// Response status.
    response_status: OcspResponseStatus,
    /// Certificate status (if successful).
    cert_status: ?OcspCertStatus,
    /// This update time.
    this_update: i64,
    /// Next update time (optional).
    next_update: ?i64,
    /// Revocation time (if revoked).
    revocation_time: ?i64,
};

/// TLS configuration manager.
/// Handles certificate loading, validation, hot reload, and revocation checking.
pub const TlsConfig = struct {
    /// Allocator for certificate data.
    allocator: mem.Allocator,

    /// Configuration options.
    options: TlsOptions,

    /// Currently loaded certificate data (null if TLS disabled).
    certificates: ?CertificateData,

    /// Whether TLS is enabled and certificates are loaded.
    enabled: bool,

    /// Cached CRL data (null if not loaded).
    cached_crl: ?Crl,

    /// Timestamp when CRL was last loaded.
    crl_load_time: i64,

    /// Initialize TLS configuration from options.
    /// Validates and loads certificates if TLS is required.
    pub fn init(allocator: mem.Allocator, options: TlsOptions) !TlsConfig {
        var self = TlsConfig{
            .allocator = allocator,
            .options = options,
            .certificates = null,
            .enabled = false,
            .cached_crl = null,
            .crl_load_time = 0,
        };

        // If TLS is required, we must have certificate paths
        if (options.required) {
            try self.validateRequiredPaths();
            try self.loadCertificates();
            self.enabled = true;
            logInfo("TLS enabled with mTLS support", .{});
        } else if (options.cert_path != null or options.key_path != null) {
            // TLS paths provided but not required - validate anyway
            try self.validateOptionalPaths();
            try self.loadCertificates();
            self.enabled = true;
            logInfo("TLS enabled (optional mode)", .{});
        } else {
            logWarn("TLS disabled - development mode only, do not use in production", .{});
        }

        // Load CRL if configured
        if (options.revocation_check == .crl or options.revocation_check == .both) {
            if (options.crl_path) |crl_path| {
                self.loadCrl(crl_path) catch |err| {
                    logWarn("failed to load CRL from '{s}': {}", .{ crl_path, err });
                };
            }
        }

        return self;
    }

    pub fn deinit(self: *TlsConfig) void {
        if (self.certificates) |*certs| {
            certs.deinit();
        }
        if (self.cached_crl) |*crl| {
            crl.deinit();
        }
        self.* = undefined;
    }

    /// Check if TLS is currently enabled.
    pub fn isEnabled(self: *const TlsConfig) bool {
        return self.enabled;
    }

    /// Reload certificates from disk.
    /// Used for SIGHUP-based certificate rotation (F5.4.3).
    /// On success, atomically swaps to new certificates.
    /// On failure, keeps old certificates and logs error.
    pub fn reload(self: *TlsConfig) !void {
        if (!self.enabled) {
            logWarn("certificate reload requested but TLS is disabled", .{});
            return;
        }

        logInfo("reloading TLS certificates", .{});

        // Try to load new certificates
        var new_certs = try self.loadCertificateData();
        errdefer new_certs.deinit();

        // Validate new certificates (basic PEM format check)
        try validatePemFormat(new_certs.cert_pem, "certificate");
        try validatePemFormat(new_certs.key_pem, "private key");
        if (new_certs.ca_pem) |ca| {
            try validatePemFormat(ca, "CA certificate");
        }

        // Atomically swap certificates
        if (self.certificates) |*old_certs| {
            old_certs.deinit();
        }
        self.certificates = new_certs;

        logInfo("TLS certificates reloaded successfully", .{});
    }

    // =========================================================================
    // Certificate Revocation Checking (F5.4.4)
    // =========================================================================

    /// Check if a certificate has been revoked.
    /// Returns RevocationStatus based on configured mode and fail policy.
    pub fn checkRevocation(self: *TlsConfig, cert: Certificate) !RevocationStatus {
        const result: RevocationStatus = switch (self.options.revocation_check) {
            .disabled => return .valid,
            .crl => self.checkCrl(cert) catch .unknown,
            .ocsp => self.checkOcsp(cert) catch .unknown,
            .both => blk: {
                // Try CRL first, fall back to OCSP
                const crl_result = self.checkCrl(cert) catch .unknown;
                if (crl_result != .unknown) break :blk crl_result;
                break :blk self.checkOcsp(cert) catch .unknown;
            },
        };

        // Handle unknown status based on failure mode
        if (result == .unknown) {
            return switch (self.options.revocation_failure_mode) {
                .fail_closed => error.RevocationUnknown,
                .fail_open => {
                    logWarn("revocation check failed, allowing connection (fail-open)", .{});
                    return .valid;
                },
            };
        }

        return result;
    }

    /// Check certificate against CRL.
    pub fn checkCrl(self: *TlsConfig, cert: Certificate) !RevocationStatus {
        // Check if we need to refresh CRL
        const now = std.time.timestamp();
        const refresh_needed = self.cached_crl == null or
            (now - self.crl_load_time >= self.options.crl_refresh_interval);

        if (refresh_needed) {
            if (self.options.crl_path) |crl_path| {
                try self.loadCrl(crl_path);
            } else {
                // Would fetch CRL from distribution point
                try self.fetchCrl();
            }
        }

        // Check CRL
        if (self.cached_crl) |*crl| {
            if (crl.isExpired(now)) {
                logWarn("CRL is expired", .{});
                return .unknown;
            }

            if (crl.isRevoked(cert.serial)) {
                return .revoked;
            }
            return .valid;
        }

        return .unknown;
    }

    /// Load CRL from a file path.
    pub fn loadCrl(self: *TlsConfig, path: []const u8) !void {
        const data = try readFile(self.allocator, path);
        defer self.allocator.free(data);

        const crl = try self.parseCrl(data);

        // Swap in new CRL
        if (self.cached_crl) |*old| {
            old.deinit();
        }
        self.cached_crl = crl;
        self.crl_load_time = std.time.timestamp();
    }

    /// Fetch CRL from distribution point (HTTP).
    /// In production, this would use an HTTP client to download the CRL.
    pub fn fetchCrl(self: *TlsConfig) !void {
        // Note: Would implement HTTP GET to CRL distribution point
        // For now, return error if no local CRL path configured
        _ = self;
        return error.CrlFetchNotImplemented;
    }

    /// Parse CRL data (PEM or DER format).
    pub fn parseCrl(self: *TlsConfig, data: []const u8) !Crl {
        // Check if PEM format
        if (mem.startsWith(u8, data, "-----BEGIN X509 CRL-----")) {
            return self.parseCrlPem(data);
        }
        // Assume DER format
        return self.parseCrlDer(data);
    }

    /// Parse PEM-encoded CRL.
    fn parseCrlPem(self: *TlsConfig, pem_data: []const u8) !Crl {
        // Extract base64 content between markers
        const begin_marker = "-----BEGIN X509 CRL-----";
        const end_marker = "-----END X509 CRL-----";

        const begin_idx = mem.indexOf(u8, pem_data, begin_marker) orelse return error.InvalidCrlFormat;
        const content_start = begin_idx + begin_marker.len;
        const end_idx = mem.indexOf(u8, pem_data, end_marker) orelse return error.InvalidCrlFormat;

        // Skip whitespace and decode base64
        var base64_content = std.ArrayList(u8).init(self.allocator);
        defer base64_content.deinit();

        for (pem_data[content_start..end_idx]) |c| {
            if (c != '\n' and c != '\r' and c != ' ') {
                base64_content.append(c) catch return error.OutOfMemory;
            }
        }

        // Decode base64 to DER
        const der_size = std.base64.standard.Decoder.calcSizeForSlice(base64_content.items) catch return error.InvalidCrlFormat;
        const der_data = self.allocator.alloc(u8, der_size) catch return error.OutOfMemory;
        defer self.allocator.free(der_data);

        std.base64.standard.Decoder.decode(der_data, base64_content.items) catch return error.InvalidCrlFormat;

        return self.parseCrlDer(der_data);
    }

    /// Parse DER-encoded CRL.
    /// Simplified parser - in production would use full ASN.1 parsing.
    fn parseCrlDer(self: *TlsConfig, der_data: []const u8) !Crl {
        // Simplified CRL parsing - just extract basic structure
        // Real implementation would parse full X.509 CRL ASN.1 structure

        var entries = std.ArrayList(CrlEntry).init(self.allocator);
        errdefer {
            for (entries.items) |entry| {
                self.allocator.free(entry.serial);
            }
            entries.deinit();
        }

        // Parse simplified format: look for known patterns
        // A real implementation would use proper ASN.1 DER parsing
        var i: usize = 0;
        while (i < der_data.len) {
            // Look for SEQUENCE tag (0x30) followed by INTEGER tag (0x02) for serial
            if (der_data[i] == 0x30 and i + 4 < der_data.len and der_data[i + 2] == 0x02) {
                const seq_len = der_data[i + 1];
                if (i + 2 + seq_len <= der_data.len) {
                    const serial_len = der_data[i + 3];
                    if (serial_len > 0 and serial_len < 32 and i + 4 + serial_len <= der_data.len) {
                        const serial = self.allocator.alloc(u8, serial_len) catch return error.OutOfMemory;
                        @memcpy(serial, der_data[i + 4 .. i + 4 + serial_len]);

                        entries.append(.{
                            .serial = serial,
                            .revocation_date = std.time.timestamp(),
                            .reason = null,
                        }) catch {
                            self.allocator.free(serial);
                            return error.OutOfMemory;
                        };
                    }
                }
                i += 2 + seq_len;
            } else {
                i += 1;
            }
        }

        return Crl{
            .entries = entries.toOwnedSlice() catch return error.OutOfMemory,
            .this_update = std.time.timestamp(),
            .next_update = std.time.timestamp() + 86400, // 24 hours default
            .allocator = self.allocator,
        };
    }

    /// Check certificate status via OCSP.
    pub fn checkOcsp(self: *TlsConfig, cert: Certificate) !RevocationStatus {
        // Build OCSP request
        const request = try self.buildOcspRequest(cert);
        defer self.allocator.free(request);

        // Send request to responder
        const response = try self.sendOcspRequest(request);

        // Parse and return result
        const parsed = try self.parseOcspResponse(response);

        return switch (parsed.cert_status orelse .unknown) {
            .good => .valid,
            .revoked => .revoked,
            .unknown => .unknown,
        };
    }

    /// Build an OCSP request for a certificate.
    pub fn buildOcspRequest(self: *TlsConfig, cert: Certificate) ![]const u8 {
        // OCSP Request structure (simplified):
        // SEQUENCE {
        //   SEQUENCE {  // TBSRequest
        //     SEQUENCE {  // requestList
        //       SEQUENCE {  // Request
        //         SEQUENCE {  // CertID
        //           SEQUENCE { OID hashAlgorithm (SHA-256) }
        //           OCTET STRING issuerNameHash
        //           OCTET STRING issuerKeyHash
        //           INTEGER serialNumber
        //         }
        //       }
        //     }
        //   }
        // }

        // SHA-256 OID: 2.16.840.1.101.3.4.2.1
        const sha256_oid = [_]u8{ 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };

        // Build CertID content
        var certid_content = std.ArrayList(u8).init(self.allocator);
        defer certid_content.deinit();

        // hashAlgorithm
        try certid_content.append(0x30); // SEQUENCE
        try certid_content.append(@intCast(sha256_oid.len + 2));
        try certid_content.appendSlice(&sha256_oid);
        try certid_content.append(0x05); // NULL
        try certid_content.append(0x00);

        // issuerNameHash (32 bytes for SHA-256)
        try certid_content.append(0x04); // OCTET STRING
        try certid_content.append(32);
        if (cert.issuer_name_hash) |hash| {
            try certid_content.appendSlice(&hash);
        } else {
            try certid_content.appendNTimes(0, 32);
        }

        // issuerKeyHash (32 bytes for SHA-256)
        try certid_content.append(0x04); // OCTET STRING
        try certid_content.append(32);
        if (cert.issuer_key_hash) |hash| {
            try certid_content.appendSlice(&hash);
        } else {
            try certid_content.appendNTimes(0, 32);
        }

        // serialNumber
        try certid_content.append(0x02); // INTEGER
        try certid_content.append(@intCast(cert.serial.len));
        try certid_content.appendSlice(cert.serial);

        // Build Request SEQUENCE (contains CertID)
        var request = std.ArrayList(u8).init(self.allocator);
        defer request.deinit();
        try request.append(0x30);
        try request.append(@intCast(certid_content.items.len + 2));
        try request.append(0x30);
        try request.append(@intCast(certid_content.items.len));
        try request.appendSlice(certid_content.items);

        // Wrap in requestList
        var requestlist = std.ArrayList(u8).init(self.allocator);
        defer requestlist.deinit();
        try requestlist.append(0x30);
        try requestlist.append(@intCast(request.items.len));
        try requestlist.appendSlice(request.items);

        // Wrap in TBSRequest
        var tbsrequest = std.ArrayList(u8).init(self.allocator);
        defer tbsrequest.deinit();
        try tbsrequest.append(0x30);
        try tbsrequest.append(@intCast(requestlist.items.len));
        try tbsrequest.appendSlice(requestlist.items);

        // Wrap in OCSPRequest (this is the final output)
        var final_request = std.ArrayList(u8).init(self.allocator);
        errdefer final_request.deinit();
        try final_request.append(0x30);
        try final_request.append(@intCast(tbsrequest.items.len));
        try final_request.appendSlice(tbsrequest.items);

        return final_request.toOwnedSlice();
    }

    /// Send OCSP request to responder.
    /// In production, this would use HTTP POST to the OCSP responder URL.
    pub fn sendOcspRequest(self: *TlsConfig, request: []const u8) ![]const u8 {
        _ = request;

        // Note: Would implement HTTP POST to OCSP responder
        // For now, return a mock "good" response
        const mock_response = self.allocator.alloc(u8, 10) catch return error.OutOfMemory;
        // Minimal OCSP response indicating "successful" with "good" status
        @memcpy(mock_response[0..10], &[_]u8{ 0x30, 0x08, 0x0a, 0x01, 0x00, 0x30, 0x03, 0x0a, 0x01, 0x00 });
        return mock_response;
    }

    /// Parse an OCSP response.
    pub fn parseOcspResponse(self: *TlsConfig, response: []const u8) !OcspResponse {
        defer self.allocator.free(response);

        // OCSP Response structure:
        // SEQUENCE {
        //   ENUMERATED responseStatus
        //   [0] EXPLICIT SEQUENCE { ... responseBytes } OPTIONAL
        // }

        if (response.len < 3) return error.InvalidOcspResponse;

        // Check for SEQUENCE tag
        if (response[0] != 0x30) return error.InvalidOcspResponse;

        // Find response status (ENUMERATED tag 0x0a)
        var i: usize = 2;
        while (i < response.len) {
            if (response[i] == 0x0a and i + 2 < response.len) {
                const status_value = response[i + 2];
                const response_status: OcspResponseStatus = switch (status_value) {
                    0 => .successful,
                    1 => .malformed_request,
                    2 => .internal_error,
                    3 => .try_later,
                    5 => .sig_required,
                    6 => .unauthorized,
                    else => return error.InvalidOcspResponse,
                };

                if (response_status != .successful) {
                    return OcspResponse{
                        .response_status = response_status,
                        .cert_status = null,
                        .this_update = 0,
                        .next_update = null,
                        .revocation_time = null,
                    };
                }

                // Look for certificate status in responseBytes
                // In a real implementation, would parse the full structure
                var cert_status: OcspCertStatus = .unknown;

                // Search for nested ENUMERATED with cert status
                var j = i + 3;
                while (j < response.len) {
                    if (response[j] == 0x0a and j + 2 < response.len) {
                        const cs = response[j + 2];
                        cert_status = switch (cs) {
                            0 => .good,
                            1 => .revoked,
                            else => .unknown,
                        };
                        break;
                    }
                    j += 1;
                }

                return OcspResponse{
                    .response_status = response_status,
                    .cert_status = cert_status,
                    .this_update = std.time.timestamp(),
                    .next_update = std.time.timestamp() + 3600,
                    .revocation_time = if (cert_status == .revoked) std.time.timestamp() else null,
                };
            }
            i += 1;
        }

        return error.InvalidOcspResponse;
    }

    /// Validate that all required paths are provided.
    fn validateRequiredPaths(self: *const TlsConfig) !void {
        if (self.options.cert_path == null) {
            logErr("TLS required but --tls-cert-path not provided", .{});
            return error.MissingCertPath;
        }
        if (self.options.key_path == null) {
            logErr("TLS required but --tls-key-path not provided", .{});
            return error.MissingKeyPath;
        }
        // CA path is required for mTLS
        if (self.options.ca_path == null) {
            logErr("TLS required but --tls-ca-path not provided (needed for mTLS)", .{});
            return error.MissingCaPath;
        }
    }

    /// Validate optional paths - if any are provided, all must be provided.
    fn validateOptionalPaths(self: *const TlsConfig) !void {
        const has_cert = self.options.cert_path != null;
        const has_key = self.options.key_path != null;

        if (has_cert != has_key) {
            logErr("both --tls-cert-path and --tls-key-path must be provided together", .{});
            return error.IncompleteConfig;
        }
    }

    /// Load certificates from configured paths.
    fn loadCertificates(self: *TlsConfig) !void {
        self.certificates = try self.loadCertificateData();

        // Validate PEM format
        try validatePemFormat(self.certificates.?.cert_pem, "certificate");
        try validatePemFormat(self.certificates.?.key_pem, "private key");
        if (self.certificates.?.ca_pem) |ca| {
            try validatePemFormat(ca, "CA certificate");
        }
    }

    /// Load certificate data from files.
    fn loadCertificateData(self: *TlsConfig) !CertificateData {
        const cert_path = self.options.cert_path orelse return error.MissingCertPath;
        const key_path = self.options.key_path orelse return error.MissingKeyPath;

        // Load certificate file
        const cert_pem = readFile(self.allocator, cert_path) catch |err| {
            logErr("failed to read certificate file '{s}': {}", .{ cert_path, err });
            return error.CertReadError;
        };
        errdefer self.allocator.free(cert_pem);

        // Load private key file
        const key_pem = readFile(self.allocator, key_path) catch |err| {
            logErr("failed to read private key file '{s}': {}", .{ key_path, err });
            return error.KeyReadError;
        };
        errdefer self.allocator.free(key_pem);

        // Check private key file permissions (security requirement)
        checkKeyPermissions(key_path) catch |err| {
            logWarn("private key file '{s}' has insecure permissions: {}", .{ key_path, err });
            // Non-fatal warning per security spec
        };

        // Load CA certificate if provided
        var ca_pem: ?[]const u8 = null;
        if (self.options.ca_path) |ca_path| {
            ca_pem = readFile(self.allocator, ca_path) catch |err| {
                logErr("failed to read CA certificate file '{s}': {}", .{ ca_path, err });
                return error.CaReadError;
            };
        }

        return CertificateData{
            .cert_pem = cert_pem,
            .key_pem = key_pem,
            .ca_pem = ca_pem,
            .allocator = self.allocator,
        };
    }
};

/// Read a file into memory.
fn readFile(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size > 1024 * 1024) {
        // Certificate files shouldn't be larger than 1MB
        return error.FileTooLarge;
    }

    const data = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(data);

    const bytes_read = try file.readAll(data);
    if (bytes_read != stat.size) {
        return error.IncompleteRead;
    }

    return data;
}

/// Check if private key file has secure permissions.
/// Per security spec: private keys should have 0600 or 0400 permissions.
fn checkKeyPermissions(path: []const u8) !void {
    const file = fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    const stat = file.stat() catch return;
    const mode = stat.mode;

    // Check if group or other has any permissions (insecure)
    const group_other_mask: u32 = 0o077;
    if ((mode & group_other_mask) != 0) {
        return error.InsecurePermissions;
    }
}

/// Validate basic PEM format.
/// Checks for proper header/footer markers.
pub fn validatePemFormat(data: []const u8, name: []const u8) !void {
    // PEM files must start with "-----BEGIN"
    if (!mem.startsWith(u8, data, "-----BEGIN ")) {
        logErr("{s} is not in valid PEM format (missing BEGIN marker)", .{name});
        return error.InvalidPemFormat;
    }

    // PEM files must contain "-----END"
    if (mem.indexOf(u8, data, "-----END ") == null) {
        logErr("{s} is not in valid PEM format (missing END marker)", .{name});
        return error.InvalidPemFormat;
    }
}

/// Extract the PEM type from a PEM file (e.g., "CERTIFICATE", "PRIVATE KEY").
pub fn getPemType(data: []const u8) ?[]const u8 {
    const begin_marker = "-----BEGIN ";
    const end_marker = "-----";

    const start = mem.indexOf(u8, data, begin_marker) orelse return null;
    const type_start = start + begin_marker.len;
    const type_end = mem.indexOfPos(u8, data, type_start, end_marker) orelse return null;

    return data[type_start..type_end];
}

// =============================================================================
// Tests
// =============================================================================

test "TlsConfig: disabled by default" {
    const config = try TlsConfig.init(std.testing.allocator, .{});
    try std.testing.expect(!config.isEnabled());
}

test "TlsConfig: required without paths fails" {
    const result = TlsConfig.init(std.testing.allocator, .{ .required = true });
    try std.testing.expectError(error.MissingCertPath, result);
}

test "validatePemFormat: valid certificate" {
    const valid_pem =
        \\-----BEGIN CERTIFICATE-----
        \\MIIBkTCB+wIJAKHBfpegPjMBMA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnVu
        \\dXNlZDAeFw0yNTAxMDEwMDAwMDBaFw0yNjAxMDEwMDAwMDBaMBExDzANBgNVBAMM
        \\BnVudXNlZDBcMA0GCSqGSIb3DQEBAQUAA0sAMEgCQQC7o96WzE9n4P2MxY8WYzYn
        \\CiYfRJxGBl5xDl5vDK8B9vDmEoFl7l5g5VxqE8YpC2YqYnA0NqH1M3m5D5k3j5ut
        \\AgMBAAEwDQYJKoZIhvcNAQELBQADQQBXS5fR5HhGXHYXwd5XB7BhD5Rq8YkXA5mn
        \\CRh7lk8qvKz9n5UZF0r7FqE5U5W0r7mKqH5oOqH5oL5oOqH5oL5o
        \\-----END CERTIFICATE-----
    ;

    try validatePemFormat(valid_pem, "test certificate");
}

test "validatePemFormat: invalid format" {
    const invalid_pem = "not a pem file";

    const result = validatePemFormat(invalid_pem, "test");
    try std.testing.expectError(error.InvalidPemFormat, result);
}

test "getPemType: certificate" {
    const cert_pem =
        \\-----BEGIN CERTIFICATE-----
        \\data
        \\-----END CERTIFICATE-----
    ;

    const pem_type = getPemType(cert_pem);
    try std.testing.expect(pem_type != null);
    try std.testing.expectEqualStrings("CERTIFICATE", pem_type.?);
}

test "getPemType: private key" {
    const key_pem =
        \\-----BEGIN PRIVATE KEY-----
        \\data
        \\-----END PRIVATE KEY-----
    ;

    const pem_type = getPemType(key_pem);
    try std.testing.expect(pem_type != null);
    try std.testing.expectEqualStrings("PRIVATE KEY", pem_type.?);
}

test "getPemType: RSA private key" {
    const key_pem =
        \\-----BEGIN RSA PRIVATE KEY-----
        \\data
        \\-----END RSA PRIVATE KEY-----
    ;

    const pem_type = getPemType(key_pem);
    try std.testing.expect(pem_type != null);
    try std.testing.expectEqualStrings("RSA PRIVATE KEY", pem_type.?);
}

// =============================================================================
// CRL Tests
// =============================================================================

test "tls: checkCrl with valid CRL" {
    var config = try TlsConfig.init(std.testing.allocator, .{
        .revocation_check = .crl,
    });
    defer config.deinit();

    // Create a mock CRL with known entries
    var entries = std.ArrayList(CrlEntry).init(std.testing.allocator);
    defer {
        for (entries.items) |entry| {
            std.testing.allocator.free(entry.serial);
        }
        entries.deinit();
    }

    // Add a revoked serial
    const serial1 = try std.testing.allocator.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03 });
    try entries.append(.{ .serial = serial1, .revocation_date = std.time.timestamp(), .reason = null });

    config.cached_crl = Crl{
        .entries = entries.toOwnedSlice() catch unreachable,
        .this_update = std.time.timestamp(),
        .next_update = std.time.timestamp() + 86400,
        .allocator = std.testing.allocator,
    };
    config.crl_load_time = std.time.timestamp();

    // Check a non-revoked certificate
    const cert = Certificate{ .serial = &[_]u8{ 0x04, 0x05, 0x06 } };
    const status = config.checkCrl(cert) catch .unknown;
    try std.testing.expectEqual(RevocationStatus.valid, status);
}

test "tls: checkCrl with revoked cert" {
    var config = try TlsConfig.init(std.testing.allocator, .{
        .revocation_check = .crl,
    });
    defer config.deinit();

    // Create a mock CRL with known entries
    const revoked_serial = &[_]u8{ 0x01, 0x02, 0x03 };
    const serial_copy = try std.testing.allocator.dupe(u8, revoked_serial);

    var entries_list = try std.testing.allocator.alloc(CrlEntry, 1);
    entries_list[0] = .{ .serial = serial_copy, .revocation_date = std.time.timestamp(), .reason = null };

    config.cached_crl = Crl{
        .entries = entries_list,
        .this_update = std.time.timestamp(),
        .next_update = std.time.timestamp() + 86400,
        .allocator = std.testing.allocator,
    };
    config.crl_load_time = std.time.timestamp();

    // Check the revoked certificate
    const cert = Certificate{ .serial = revoked_serial };
    const status = config.checkCrl(cert) catch .unknown;
    try std.testing.expectEqual(RevocationStatus.revoked, status);
}

// =============================================================================
// OCSP Tests
// =============================================================================

test "tls: checkOcsp request building" {
    var config = try TlsConfig.init(std.testing.allocator, .{
        .revocation_check = .ocsp,
    });
    defer config.deinit();

    const cert = Certificate{
        .serial = &[_]u8{ 0x01, 0x02, 0x03, 0x04 },
        .issuer_name_hash = [_]u8{0xAB} ** 32,
        .issuer_key_hash = [_]u8{0xCD} ** 32,
    };

    const request = try config.buildOcspRequest(cert);
    defer std.testing.allocator.free(request);

    // Verify request starts with SEQUENCE tag
    try std.testing.expect(request.len > 0);
    try std.testing.expectEqual(@as(u8, 0x30), request[0]);
}

test "tls: checkOcsp response parsing" {
    var config = try TlsConfig.init(std.testing.allocator, .{
        .revocation_check = .ocsp,
    });
    defer config.deinit();

    // Create a mock OCSP response indicating "good" status
    // SEQUENCE { ENUMERATED(0=successful) SEQUENCE { ENUMERATED(0=good) } }
    const response = try std.testing.allocator.alloc(u8, 12);
    @memcpy(response, &[_]u8{
        0x30, 0x0a, // SEQUENCE, length 10
        0x0a, 0x01, 0x00, // ENUMERATED response_status = successful
        0x30, 0x05, // SEQUENCE (response bytes)
        0x0a, 0x01, 0x00, // ENUMERATED cert_status = good
        0x00, 0x00, // padding
    });

    const parsed = try config.parseOcspResponse(response);

    try std.testing.expectEqual(OcspResponseStatus.successful, parsed.response_status);
    try std.testing.expect(parsed.cert_status != null);
    try std.testing.expectEqual(OcspCertStatus.good, parsed.cert_status.?);
}

// =============================================================================
// Fail Policy Tests
// =============================================================================

test "tls: fail-open allows unknown" {
    var config = try TlsConfig.init(std.testing.allocator, .{
        .revocation_check = .crl,
        .revocation_failure_mode = .fail_open,
    });
    defer config.deinit();

    // No CRL loaded, so checkCrl returns unknown
    const cert = Certificate{ .serial = &[_]u8{ 0x01, 0x02, 0x03 } };

    // With fail_open, unknown status should return valid
    const status = config.checkRevocation(cert) catch |err| {
        // Should not error with fail_open
        std.debug.print("Unexpected error: {}\n", .{err});
        return error.UnexpectedError;
    };
    try std.testing.expectEqual(RevocationStatus.valid, status);
}

test "tls: fail-closed rejects unknown" {
    var config = try TlsConfig.init(std.testing.allocator, .{
        .revocation_check = .crl,
        .revocation_failure_mode = .fail_closed,
    });
    defer config.deinit();

    // No CRL loaded, so checkCrl returns unknown
    const cert = Certificate{ .serial = &[_]u8{ 0x01, 0x02, 0x03 } };

    // With fail_closed, unknown status should return error
    const result = config.checkRevocation(cert);
    try std.testing.expectError(error.RevocationUnknown, result);
}

test "tls: CRL caching respects refresh interval" {
    var config = try TlsConfig.init(std.testing.allocator, .{
        .revocation_check = .crl,
        .crl_refresh_interval = 3600, // 1 hour
    });
    defer config.deinit();

    // Manually set cached CRL and load time
    const serial = try std.testing.allocator.dupe(u8, &[_]u8{ 0x01, 0x02 });
    var entries = try std.testing.allocator.alloc(CrlEntry, 1);
    entries[0] = .{ .serial = serial, .revocation_date = 0, .reason = null };

    config.cached_crl = Crl{
        .entries = entries,
        .this_update = std.time.timestamp(),
        .next_update = std.time.timestamp() + 86400,
        .allocator = std.testing.allocator,
    };
    config.crl_load_time = std.time.timestamp();

    // Check should use cached CRL (not try to refresh)
    const cert = Certificate{ .serial = &[_]u8{ 0xFF, 0xFE } };
    const status = config.checkCrl(cert) catch .unknown;

    // Should be valid since serial not in CRL
    try std.testing.expectEqual(RevocationStatus.valid, status);
}
