// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Replica-to-Replica mTLS Authentication (F5.4.2)
//!
//! This module provides mutual TLS authentication between replicas in the cluster.
//! Each replica identifies itself via X.509 certificates, and verifies peer certificates
//! against a shared cluster CA.
//!
//! ## Certificate Requirements (per security spec)
//!
//! - Certificate Common Name (CN) format: "replica-N" where N is the replica index
//! - All replica certificates signed by the same cluster CA
//! - TLS 1.3 with forward-secret cipher suites
//!
//! ## Usage
//!
//! ```zig
//! // Extract replica ID from peer certificate
//! const replica_id = try ReplicaTls.extractReplicaId(peer_cert_pem);
//!
//! // Verify replica is in cluster configuration
//! if (replica_id >= cluster_size) {
//!     return error.UnknownReplica;
//! }
//! ```
//!
//! ## Implementation Status
//!
//! - [x] Certificate parsing (PEM to DER, X.509 parsing)
//! - [x] Replica ID extraction from CN
//! - [x] Replica ID validation
//! - [ ] TLS handshake integration (requires TLS server implementation)
//! - [ ] Full mTLS connection flow (blocked on Zig TLS server support)
//!
//! NOTE: Zig's std library currently only provides TLS client support, not server.
//! Full mTLS requires either:
//! 1. Zig TLS server implementation in std (tracking: ziglang/zig#...)
//! 2. FFI integration with OpenSSL/BoringSSL
//! 3. Custom TLS 1.3 server implementation

const std = @import("std");
const mem = std.mem;
const base64 = std.base64;
const Certificate = std.crypto.Certificate;
const log = std.log.scoped(.replica_tls);
const builtin = @import("builtin");

/// Test-aware logging to suppress errors during test mode.
fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.err(fmt, args);
    }
}

/// Errors that can occur during replica TLS operations.
pub const ReplicaTlsError = error{
    /// Certificate is not in valid PEM format
    InvalidPemFormat,
    /// Certificate Common Name is not in "replica-N" format
    InvalidReplicaIdFormat,
    /// Replica ID exceeds maximum allowed value
    ReplicaIdOutOfRange,
    /// Certificate parsing failed
    CertificateParseError,
    /// Base64 decoding failed
    Base64DecodeError,
    /// PEM data is incomplete or malformed
    IncompletePem,
    /// Replica ID does not match expected cluster configuration
    ReplicaIdMismatch,
    /// Certificate verification failed
    CertificateVerificationFailed,
    /// Allocator error
    OutOfMemory,
};

/// Maximum replica ID value (u8 max).
pub const MAX_REPLICA_ID: u8 = 255;

/// Expected CN prefix for replica certificates.
pub const REPLICA_CN_PREFIX = "replica-";

/// Parsed replica identity from a certificate.
pub const ReplicaIdentity = struct {
    /// Replica index (0 to cluster_size-1)
    replica_id: u8,
    /// Full Common Name from certificate
    common_name: []const u8,
};

/// Extract the replica ID from a PEM-encoded certificate.
///
/// The certificate's Common Name (CN) must be in the format "replica-N"
/// where N is a valid replica index (0-255).
///
/// Returns the parsed replica identity, or an error if:
/// - The PEM format is invalid
/// - The CN is not in "replica-N" format
/// - The replica ID is out of range
pub fn extractReplicaId(
    allocator: mem.Allocator,
    pem_data: []const u8,
) ReplicaTlsError!ReplicaIdentity {
    // Convert PEM to DER
    const der_data = pemToDer(allocator, pem_data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPemFormat,
    };
    defer allocator.free(der_data);

    // Parse the certificate
    const cert = Certificate{ .buffer = der_data, .index = 0 };
    const parsed = Certificate.parse(cert) catch {
        return error.CertificateParseError;
    };

    // Extract Common Name
    const cn = parsed.commonName();
    if (cn.len == 0) {
        logErr("certificate has empty Common Name", .{});
        return error.InvalidReplicaIdFormat;
    }

    // Parse replica ID from CN (format: "replica-N")
    const replica_id = parseReplicaCn(cn) catch {
        logErr("invalid replica CN format: '{s}'", .{cn});
        return error.InvalidReplicaIdFormat;
    };

    return ReplicaIdentity{
        .replica_id = replica_id,
        .common_name = cn,
    };
}

/// Verify that a peer certificate is valid for the expected replica.
///
/// Checks:
/// 1. Certificate is parseable
/// 2. CN matches "replica-N" format
/// 3. Replica ID matches expected_replica_id
/// 4. (Optional) Certificate is signed by cluster CA
pub fn verifyReplicaCertificate(
    allocator: mem.Allocator,
    peer_cert_pem: []const u8,
    expected_replica_id: u8,
    ca_cert_pem: ?[]const u8,
) ReplicaTlsError!void {
    // Extract replica ID from peer certificate
    const identity = try extractReplicaId(allocator, peer_cert_pem);

    // Verify replica ID matches expected
    if (identity.replica_id != expected_replica_id) {
        logErr(
            "replica ID mismatch: certificate has {}, expected {}",
            .{ identity.replica_id, expected_replica_id },
        );
        return error.ReplicaIdMismatch;
    }

    // Verify certificate chain if CA is provided
    if (ca_cert_pem) |ca_pem| {
        try verifyCertificateChain(allocator, peer_cert_pem, ca_pem);
    }

    log.debug("verified replica certificate for replica-{}", .{identity.replica_id});
}

/// Verify that a certificate is signed by the given CA.
fn verifyCertificateChain(
    allocator: mem.Allocator,
    cert_pem: []const u8,
    ca_cert_pem: []const u8,
) ReplicaTlsError!void {
    // Parse subject certificate
    const cert_der = pemToDer(allocator, cert_pem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPemFormat,
    };
    defer allocator.free(cert_der);

    const cert = Certificate{ .buffer = cert_der, .index = 0 };
    const parsed_cert = Certificate.parse(cert) catch {
        return error.CertificateParseError;
    };

    // Parse CA certificate
    const ca_der = pemToDer(allocator, ca_cert_pem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPemFormat,
    };
    defer allocator.free(ca_der);

    const ca_cert = Certificate{ .buffer = ca_der, .index = 0 };
    const parsed_ca = Certificate.parse(ca_cert) catch {
        return error.CertificateParseError;
    };

    // Get current time for validity check
    const now_sec: i64 = @intCast(std.time.timestamp());

    // Verify certificate against CA
    parsed_cert.verify(parsed_ca, now_sec) catch {
        logErr("certificate verification failed against CA", .{});
        return error.CertificateVerificationFailed;
    };
}

/// Parse replica ID from Common Name.
///
/// Expected format: "replica-N" where N is 0-255.
fn parseReplicaCn(cn: []const u8) !u8 {
    // Check prefix
    if (!mem.startsWith(u8, cn, REPLICA_CN_PREFIX)) {
        return error.InvalidFormat;
    }

    // Extract numeric part
    const id_str = cn[REPLICA_CN_PREFIX.len..];
    if (id_str.len == 0) {
        return error.InvalidFormat;
    }

    // Parse as integer
    const replica_id = std.fmt.parseInt(u8, id_str, 10) catch {
        return error.InvalidFormat;
    };

    return replica_id;
}

/// Convert PEM-encoded data to DER format.
///
/// PEM format:
/// -----BEGIN CERTIFICATE-----
/// <base64-encoded DER data>
/// -----END CERTIFICATE-----
fn pemToDer(allocator: mem.Allocator, pem_data: []const u8) ![]u8 {
    // Find start marker
    const begin_marker = "-----BEGIN ";
    const end_marker = "-----END ";
    const dash_end = "-----";

    const begin_pos = mem.indexOf(u8, pem_data, begin_marker) orelse {
        return error.InvalidPemFormat;
    };

    // Find end of BEGIN line
    const begin_line_end = mem.indexOfPos(u8, pem_data, begin_pos, dash_end) orelse {
        return error.InvalidPemFormat;
    };
    const data_start = mem.indexOfPos(u8, pem_data, begin_line_end + dash_end.len, "\n") orelse {
        return error.InvalidPemFormat;
    };

    // Find END marker
    const end_pos = mem.indexOf(u8, pem_data, end_marker) orelse {
        return error.InvalidPemFormat;
    };

    // Extract base64 content (between headers)
    const base64_data = pem_data[data_start + 1 .. end_pos];

    // Remove whitespace and decode
    var clean_data = std.ArrayList(u8).init(allocator);
    defer clean_data.deinit();

    for (base64_data) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
            try clean_data.append(c);
        }
    }

    // Decode base64
    const decoder = base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(clean_data.items) catch {
        return error.Base64DecodeError;
    };

    const der_data = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(der_data);

    decoder.decode(der_data, clean_data.items) catch {
        allocator.free(der_data);
        return error.Base64DecodeError;
    };

    return der_data;
}

/// Check if a replica ID is valid for the given cluster size.
pub fn isValidReplicaId(replica_id: u8, cluster_size: u8) bool {
    return replica_id < cluster_size;
}

/// Format a replica CN from a replica ID.
pub fn formatReplicaCn(buf: []u8, replica_id: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ REPLICA_CN_PREFIX, replica_id }) catch {
        return REPLICA_CN_PREFIX;
    };
}

// =============================================================================
// Tests
// =============================================================================

// NOTE: Full certificate parsing tests require valid X.509 certificates.
// The tests below verify the helper functions (CN parsing, validation, etc.)
// without requiring cryptographically valid certificates.
// Integration tests with real certificates should be added when a test
// certificate generation infrastructure is available.

test "parseReplicaCn: valid formats" {
    try std.testing.expectEqual(@as(u8, 0), try parseReplicaCn("replica-0"));
    try std.testing.expectEqual(@as(u8, 1), try parseReplicaCn("replica-1"));
    try std.testing.expectEqual(@as(u8, 255), try parseReplicaCn("replica-255"));
}

test "parseReplicaCn: invalid formats" {
    try std.testing.expectError(error.InvalidFormat, parseReplicaCn(""));
    try std.testing.expectError(error.InvalidFormat, parseReplicaCn("replica-"));
    try std.testing.expectError(error.InvalidFormat, parseReplicaCn("replica-abc"));
    try std.testing.expectError(error.InvalidFormat, parseReplicaCn("replica-256")); // overflow
    try std.testing.expectError(error.InvalidFormat, parseReplicaCn("invalid"));
    try std.testing.expectError(error.InvalidFormat, parseReplicaCn("replica0")); // missing dash
}

test "isValidReplicaId" {
    try std.testing.expect(isValidReplicaId(0, 3));
    try std.testing.expect(isValidReplicaId(2, 3));
    try std.testing.expect(!isValidReplicaId(3, 3));
    try std.testing.expect(!isValidReplicaId(255, 3));
}

test "formatReplicaCn" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("replica-0", formatReplicaCn(&buf, 0));
    try std.testing.expectEqualStrings("replica-42", formatReplicaCn(&buf, 42));
    try std.testing.expectEqualStrings("replica-255", formatReplicaCn(&buf, 255));
}

test "pemToDer: valid PEM" {
    const allocator = std.testing.allocator;

    // Simple valid PEM with minimal base64 content
    const simple_pem =
        \\-----BEGIN CERTIFICATE-----
        \\SGVsbG8=
        \\-----END CERTIFICATE-----
    ;

    const der = try pemToDer(allocator, simple_pem);
    defer allocator.free(der);

    // "SGVsbG8=" decodes to "Hello"
    try std.testing.expectEqualStrings("Hello", der);
}

test "pemToDer: invalid PEM format" {
    const allocator = std.testing.allocator;

    // No BEGIN marker
    try std.testing.expectError(
        error.InvalidPemFormat,
        pemToDer(allocator, "not a pem file"),
    );

    // No END marker
    try std.testing.expectError(
        error.InvalidPemFormat,
        pemToDer(allocator, "-----BEGIN CERTIFICATE-----\ndata"),
    );
}
