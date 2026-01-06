// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! REPL Parser Stub - ArcherDB Geospatial Database
//!
//! The REPL was designed for TigerBeetle financial operations.
//! ArcherDB uses client SDKs for all geospatial operations.
//!
//! This file is preserved as a stub to maintain the module structure.

const std = @import("std");

pub const Parser = struct {
    pub const Error = error{
        NotImplemented,
    };

    pub const Operation = enum {
        none,
        help,
    };

    pub const Result = union(enum) {
        none,
        help,
    };

    input: []const u8 = "",

    pub fn parse(self: *Parser) Error!Result {
        _ = self;
        return error.NotImplemented;
    }
};

test "parser: stub - REPL not implemented for ArcherDB" {
    // ArcherDB uses client SDKs, not the TigerBeetle REPL.
    try std.testing.expect(true);
}
