// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Signal Handler for TLS Certificate Reload (F5.4.3)
//!
//! This module provides SIGHUP signal handling for certificate reload.
//! When SIGHUP is received, it sets a flag that the main loop checks
//! to trigger TLS certificate reload.
//!
//! Per security/spec.md:
//! - SIGHUP triggers certificate reload from configured paths
//! - Gracefully transitions to new certificates
//! - Existing connections unaffected (use old certificates until close)
//! - New connections use new certificates immediately
//!
//! Usage:
//! ```zig
//! const signal_handler = @import("signal_handler.zig");
//!
//! // At startup
//! signal_handler.install();
//!
//! // In main loop
//! if (signal_handler.shouldReloadCertificates()) {
//!     tls_config.reload() catch |err| {
//!         // Handle reload failure
//!     };
//! }
//! ```

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.signal_handler);

/// Atomic flag indicating SIGHUP was received and certificates should be reloaded.
/// Set by signal handler, cleared by main loop after reload attempt.
pub var reload_certificates_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Signal action for SIGHUP.
const sighup_action = posix.Sigaction{
    .handler = .{ .handler = sighupHandler },
    .mask = posix.empty_sigset,
    .flags = 0,
};

/// SIGHUP signal handler.
/// Sets the reload flag - actual reload happens in main loop.
/// Signal handlers must be async-signal-safe, so we only set an atomic flag.
fn sighupHandler(_: i32) callconv(.c) void {
    reload_certificates_flag.store(true, .release);
    // Note: We cannot log here as logging is not async-signal-safe.
    // The main loop will log when it processes the reload.
}

/// Install the SIGHUP signal handler.
/// Call once at startup before the main loop.
pub fn install() void {
    posix.sigaction(posix.SIG.HUP, &sighup_action, null);
    log.info("SIGHUP handler installed for certificate reload", .{});
}

/// Check if certificate reload was requested (via SIGHUP).
/// Returns true once per SIGHUP signal - the flag is atomically cleared.
pub fn shouldReloadCertificates() bool {
    // Atomically check and clear the flag
    return reload_certificates_flag.swap(false, .acq_rel);
}

/// Reset the reload flag without processing.
/// Useful for error recovery or testing.
pub fn clearReloadFlag() void {
    reload_certificates_flag.store(false, .release);
}

/// Check if reload is pending without clearing.
/// Useful for status checks.
pub fn isReloadPending() bool {
    return reload_certificates_flag.load(.acquire);
}

// =============================================================================
// Tests
// =============================================================================

test "signal_handler: flag initially false" {
    // Reset to known state
    clearReloadFlag();
    try std.testing.expect(!isReloadPending());
    try std.testing.expect(!shouldReloadCertificates());
}

test "signal_handler: shouldReloadCertificates clears flag" {
    // Manually set the flag (simulating SIGHUP)
    reload_certificates_flag.store(true, .release);

    try std.testing.expect(isReloadPending());
    try std.testing.expect(shouldReloadCertificates());
    // Flag should now be cleared
    try std.testing.expect(!isReloadPending());
    try std.testing.expect(!shouldReloadCertificates());
}

test "signal_handler: clearReloadFlag resets" {
    reload_certificates_flag.store(true, .release);
    try std.testing.expect(isReloadPending());

    clearReloadFlag();
    try std.testing.expect(!isReloadPending());
}
