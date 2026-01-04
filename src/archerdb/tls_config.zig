// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! TLS Configuration and Certificate Management for mTLS Support (F5.4.1)
//!
//! This module provides:
//! - Certificate path validation
//! - PEM file format validation
//! - Certificate loading infrastructure
//! - TLS configuration management
//!
//! Usage:
//! ```zig
//! var config = try TlsConfig.init(allocator, .{
//!     .cert_path = "/path/to/cert.pem",
//!     .key_path = "/path/to/key.pem",
//!     .ca_path = "/path/to/ca.pem",
//!     .required = true,
//! });
//! defer config.deinit();
//!
//! if (config.isEnabled()) {
//!     // TLS is configured and certificates are valid
//! }
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
const log = std.log.scoped(.tls_config);
const fs = std.fs;
const mem = std.mem;

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

/// TLS configuration manager.
/// Handles certificate loading, validation, and hot reload.
pub const TlsConfig = struct {
    /// Allocator for certificate data.
    allocator: mem.Allocator,

    /// Configuration options.
    options: TlsOptions,

    /// Currently loaded certificate data (null if TLS disabled).
    certificates: ?CertificateData,

    /// Whether TLS is enabled and certificates are loaded.
    enabled: bool,

    /// Initialize TLS configuration from options.
    /// Validates and loads certificates if TLS is required.
    pub fn init(allocator: mem.Allocator, options: TlsOptions) !TlsConfig {
        var self = TlsConfig{
            .allocator = allocator,
            .options = options,
            .certificates = null,
            .enabled = false,
        };

        // If TLS is required, we must have certificate paths
        if (options.required) {
            try self.validateRequiredPaths();
            try self.loadCertificates();
            self.enabled = true;
            log.info("TLS enabled with mTLS support", .{});
        } else if (options.cert_path != null or options.key_path != null) {
            // TLS paths provided but not required - validate anyway
            try self.validateOptionalPaths();
            try self.loadCertificates();
            self.enabled = true;
            log.info("TLS enabled (optional mode)", .{});
        } else {
            log.warn("TLS disabled - development mode only, do not use in production", .{});
        }

        return self;
    }

    pub fn deinit(self: *TlsConfig) void {
        if (self.certificates) |*certs| {
            certs.deinit();
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
            log.warn("certificate reload requested but TLS is disabled", .{});
            return;
        }

        log.info("reloading TLS certificates", .{});

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

        log.info("TLS certificates reloaded successfully", .{});
    }

    /// Validate that all required paths are provided.
    fn validateRequiredPaths(self: *const TlsConfig) !void {
        if (self.options.cert_path == null) {
            log.err("TLS required but --tls-cert-path not provided", .{});
            return error.MissingCertPath;
        }
        if (self.options.key_path == null) {
            log.err("TLS required but --tls-key-path not provided", .{});
            return error.MissingKeyPath;
        }
        // CA path is required for mTLS
        if (self.options.ca_path == null) {
            log.err("TLS required but --tls-ca-path not provided (needed for mTLS)", .{});
            return error.MissingCaPath;
        }
    }

    /// Validate optional paths - if any are provided, all must be provided.
    fn validateOptionalPaths(self: *const TlsConfig) !void {
        const has_cert = self.options.cert_path != null;
        const has_key = self.options.key_path != null;

        if (has_cert != has_key) {
            log.err("both --tls-cert-path and --tls-key-path must be provided together", .{});
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
            log.err("failed to read certificate file '{s}': {}", .{ cert_path, err });
            return error.CertReadError;
        };
        errdefer self.allocator.free(cert_pem);

        // Load private key file
        const key_pem = readFile(self.allocator, key_path) catch |err| {
            log.err("failed to read private key file '{s}': {}", .{ key_path, err });
            return error.KeyReadError;
        };
        errdefer self.allocator.free(key_pem);

        // Check private key file permissions (security requirement)
        checkKeyPermissions(key_path) catch |err| {
            log.warn("private key file '{s}' has insecure permissions: {}", .{ key_path, err });
            // Non-fatal warning per security spec
        };

        // Load CA certificate if provided
        var ca_pem: ?[]const u8 = null;
        if (self.options.ca_path) |ca_path| {
            ca_pem = readFile(self.allocator, ca_path) catch |err| {
                log.err("failed to read CA certificate file '{s}': {}", .{ ca_path, err });
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
fn validatePemFormat(data: []const u8, name: []const u8) !void {
    // PEM files must start with "-----BEGIN"
    if (!mem.startsWith(u8, data, "-----BEGIN ")) {
        log.err("{s} is not in valid PEM format (missing BEGIN marker)", .{name});
        return error.InvalidPemFormat;
    }

    // PEM files must contain "-----END"
    if (mem.indexOf(u8, data, "-----END ") == null) {
        log.err("{s} is not in valid PEM format (missing END marker)", .{name});
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
