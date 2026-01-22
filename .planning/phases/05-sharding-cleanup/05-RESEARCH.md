# Phase 5: Sharding & Cleanup - Research

**Researched:** 2026-01-22
**Domain:** Distributed sharding verification, technical debt resolution, stub implementation
**Confidence:** HIGH

## Summary

This phase combines two major workstreams: (1) verifying ArcherDB's existing sharding implementation meets correctness guarantees, and (2) resolving all technical debt including 174 TODO/FIXME markers and implementing 7 stub modules. The codebase already has a well-implemented sharding system with jump consistent hash, consistent hash ring, and spatial sharding - the work is verification and testing rather than new implementation.

The technical debt cleanup is substantial but straightforward. The REPL has partial infrastructure (terminal handling, parser, completion) but lacks the main interactive loop and client connection. Tiering has a complete implementation that needs LSM integration. AMQP client exists with full protocol support. TLS config exists but CRL/OCSP checking is stubbed. Backup config is complete but scheduling logic needs implementation.

**Primary recommendation:** Focus verification effort on golden test vectors for jump hash cross-SDK parity. Prioritize FIXMEs (treat as bugs), then resolve TODOs category by category. Implement stubs by extending existing infrastructure rather than building from scratch.

## Standard Stack

The established libraries/tools for this domain:

### Core (Already in Codebase)

| Component | Location | Status | Why Standard |
|-----------|----------|--------|--------------|
| Jump Hash | `src/sharding.zig` | Complete | Google's algorithm, O(1) memory, optimal 1/(N+1) movement |
| Consistent Hash Ring | `src/sharding.zig` | Complete | Virtual node approach with 150 vnodes/shard |
| Spatial Sharding | `src/sharding.zig` | Complete | S2 cell-based locality for geo queries |
| AMQP Client | `src/cdc/amqp.zig` | Complete | Full AMQP 0.9.1 protocol, RabbitMQ compatible |
| Tiering Manager | `src/tiering.zig` | Complete | Hot/warm/cold with promotion/demotion |
| TLS Config | `src/archerdb/tls_config.zig` | Partial | PEM loading complete, CRL/OCSP stubbed |
| Backup Config | `src/archerdb/backup_config.zig` | Partial | Config types complete, scheduling stubbed |
| REPL Infrastructure | `src/repl/` | Partial | Terminal, parser, completion exist |

### Supporting (For Implementation)

| Library | Purpose | When to Use |
|---------|---------|-------------|
| Zig std.time | Cron-like scheduling | Backup scheduling intervals |
| Zig std.crypto | Certificate parsing | CRL/OCSP implementation |
| Zig std.http.Client | HTTP requests | CRL download, OCSP stapling |
| Zig std.json | Protobuf alternative | CDC message format (JSON option) |

### No External Dependencies Needed

The CONTEXT.md specifies implementing all integrations including external dependencies, but the existing codebase already has:
- HTTP client via IO interface
- Protocol encoding/decoding infrastructure
- Async I/O patterns used throughout

## Architecture Patterns

### Existing Sharding Architecture (Verify, Don't Modify)

```
src/
├── sharding.zig           # All sharding strategies unified
│   ├── computeShardKey()  # MurmurHash3-inspired 128->64 bit
│   ├── jumpHash()         # Google's jump consistent hash
│   ├── ConsistentHashRing # Virtual node ring (150 vnodes)
│   ├── computeSpatialShard()  # S2 cell-based
│   └── EntityLookupIndex  # Entity->cell mapping for spatial
```

### REPL Architecture (Extend Existing)

```
src/
├── repl.zig               # Main stub - needs full implementation
├── repl/
│   ├── terminal.zig       # Terminal handling (exists)
│   ├── parser.zig         # Command parser (exists)
│   └── completion.zig     # Tab completion (exists)
```

**Pattern: Complete the REPL by**:
1. Add client connection to MessageBus
2. Implement command execution loop in repl.zig
3. Add admin commands (cluster status, metrics)
4. Add debug commands (inspect, dump state)

### Tiering Integration Pattern

```
src/
├── tiering.zig            # TieringManager (exists, complete)
└── Integration points:
    ├── forest.zig         # Track entity access
    ├── groove.zig         # Apply tier decisions
    └── ram_index.zig      # Hot/warm in RAM, cold on disk
```

**Pattern: Integrate tiering by**:
1. Hook `recordAccess()` into query path
2. Hook `recordInsert()` into insert path
3. Call `tick()` periodically for demotions
4. Respect `isInRamIndex()` for query routing

### Backup Scheduling Pattern

Per CONTEXT.md: Support both cron syntax and simple intervals.

```zig
pub const BackupSchedule = union(enum) {
    /// Simple interval: "every 1h", "every 30m"
    interval: struct {
        value: u64,
        unit: enum { seconds, minutes, hours, days },
    },
    /// Cron expression: "0 2 * * *" (daily at 2am)
    cron: CronExpression,
};

pub const CronExpression = struct {
    minute: FieldSpec,      // 0-59
    hour: FieldSpec,        // 0-23
    day_of_month: FieldSpec, // 1-31
    month: FieldSpec,       // 1-12
    day_of_week: FieldSpec, // 0-6
};
```

### Anti-Patterns to Avoid

- **Don't change hash algorithms:** Verify existing, don't replace
- **Don't create new file structures:** Extend existing modules
- **Don't add external cron libraries:** Implement minimal cron parser inline
- **Don't defer TODOs to issues:** Per CONTEXT.md, resolve all now

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Terminal handling | Raw ANSI codes | `src/repl/terminal.zig` | Already handles escape sequences, cursor |
| Command parsing | Ad-hoc string ops | `src/repl/parser.zig` | Full SQL-like parser exists |
| Tab completion | Simple prefix match | `src/repl/completion.zig` | Keyword completion exists |
| AMQP protocol | New wire protocol | `src/cdc/amqp.zig` | Full 0.9.1 client exists |
| Hash distribution | Custom algorithm | `src/sharding.zig` | jumpHash verified correct |
| Priority queues | Manual heap | `std.PriorityQueue` | Used in tiering already |

**Key insight:** Most "stub" modules have substantial infrastructure - the work is integration and completion, not greenfield implementation.

## Common Pitfalls

### Pitfall 1: Changing Hash Algorithm Behavior

**What goes wrong:** Modifying jump hash implementation breaks cross-SDK compatibility
**Why it happens:** Trying to "improve" the algorithm or fix perceived issues
**How to avoid:** Verify with golden vectors, NEVER modify the core algorithm
**Warning signs:** Any changes to `jumpHash()` or `computeShardKey()`

### Pitfall 2: TODO Resolution Inconsistency

**What goes wrong:** Different handling of similar TODOs creates inconsistent behavior
**Why it happens:** Not categorizing TODOs before resolution
**How to avoid:**
1. Categorize all 174 markers first
2. Define resolution strategy per category
3. Apply consistently
**Warning signs:** Ad-hoc fixes without pattern recognition

### Pitfall 3: CRL/OCSP Fail Policy Mismatch

**What goes wrong:** Production uses fail-open when security requires fail-closed
**Why it happens:** Default configuration doesn't match deployment context
**How to avoid:** Per CONTEXT.md, make fail policy operator-configurable per environment
**Warning signs:** Hardcoded fail policy

### Pitfall 4: Forgetting VOPR Integration for State Machine Tests

**What goes wrong:** Creating standalone tests instead of extending VOPR fuzzer
**Why it happens:** Standalone tests seem simpler
**How to avoid:** Per CONTEXT.md decision, extend VOPR to cover state machine edge cases
**Warning signs:** New test files instead of VOPR extensions

### Pitfall 5: Client-Side vs Server-Side Aggregation Confusion

**What goes wrong:** Implementing aggregation in server when it should be client-side
**Why it happens:** Seems more efficient to aggregate on server
**How to avoid:** Per CONTEXT.md, return per-shard results, client combines (more transparent)
**Warning signs:** Server-side merge logic for cross-shard queries

## Code Examples

Verified patterns from the existing codebase:

### Jump Hash Verification Pattern

```zig
// Source: src/sharding.zig (existing implementation)
// Golden vector test pattern for cross-SDK verification
test "jumpHash known values - cross-SDK compatibility" {
    // These values MUST match all SDK implementations
    const golden_vectors = [_]struct { key: u64, buckets: u32, expected: u32 }{
        .{ .key = 0, .buckets = 1, .expected = 0 },
        .{ .key = 0, .buckets = 10, .expected = 0 },
        .{ .key = 0xDEADBEEF, .buckets = 16, .expected = /* compute once, verify all SDKs */ },
        .{ .key = 0xCAFEBABE, .buckets = 100, .expected = /* compute once, verify all SDKs */ },
        // Add vectors for boundary conditions
    };

    for (golden_vectors) |v| {
        try std.testing.expectEqual(v.expected, jumpHash(v.key, v.buckets));
    }
}
```

### Distribution Tolerance Test Pattern

```zig
// Per CONTEXT.md: +/-5% variance (strict: each shard within 5% of ideal)
test "jumpHash distribution tolerance" {
    const num_shards: u32 = 16;
    const num_keys: u32 = 160_000; // 10,000 per shard expected
    var counts: [256]u32 = .{0} ** 256;

    var prng = std.Random.DefaultPrng.init(12345);
    for (0..num_keys) |_| {
        const key = prng.random().int(u64);
        counts[jumpHash(key, num_shards)] += 1;
    }

    const expected = num_keys / num_shards;
    const tolerance = expected / 20; // 5% = 1/20

    for (counts[0..num_shards]) |count| {
        const diff = if (count > expected) count - expected else expected - count;
        try std.testing.expect(diff <= tolerance);
    }
}
```

### REPL Command Execution Pattern

```zig
// Pattern for extending src/repl.zig
pub fn executeCommand(self: *Repl, result: parser.ParseResult) !void {
    switch (result) {
        .status => try self.showClusterStatus(),
        .insert => |args| try self.executeInsert(args),
        .query_uuid => |args| try self.executeQueryUuid(args),
        .query_radius => |args| try self.executeQueryRadius(args),
        // ... other commands
    }
}

fn showClusterStatus(self: *Repl) !void {
    // Admin command: cluster status, replication lag, metrics
    const status = self.client.getClusterStatus();
    try self.terminal.print("Cluster: {d} replicas\n", .{status.replica_count});
    try self.terminal.print("Primary: replica-{d}\n", .{status.primary_id});
    try self.terminal.print("Replication lag: {d}ms\n", .{status.lag_ms});
}
```

### CRL/OCSP Configuration Pattern

```zig
// Per CONTEXT.md: Configurable fail policy per environment
pub const RevocationConfig = struct {
    mode: RevocationCheckMode,
    crl_path: ?[]const u8 = null,
    crl_refresh_interval_secs: u32 = 3600,
    ocsp_responder_url: ?[]const u8 = null,
    ocsp_timeout_secs: u32 = 5,
    /// Operator chooses fail-closed (secure) or fail-open (available)
    failure_mode: RevocationFailureMode = .fail_closed,
};

pub fn checkRevocation(self: *TlsConfig, cert: Certificate) !RevocationStatus {
    const result = switch (self.revocation.mode) {
        .disabled => return .valid,
        .crl => try self.checkCrl(cert),
        .ocsp => try self.checkOcsp(cert),
        .both => self.checkCrl(cert) catch try self.checkOcsp(cert),
    };

    if (result == .unknown) {
        return switch (self.revocation.failure_mode) {
            .fail_closed => error.RevocationUnknown,
            .fail_open => {
                log.warn("revocation check failed, allowing connection (fail-open)", .{});
                return .valid;
            },
        };
    }
    return result;
}
```

### Backup Schedule Pattern

```zig
// Per CONTEXT.md: Both cron syntax and simple intervals
pub fn parseSchedule(spec: []const u8) !BackupSchedule {
    // Try simple interval first: "every 1h", "every 30m", "every 1d"
    if (std.mem.startsWith(u8, spec, "every ")) {
        const interval_str = spec["every ".len..];
        return parseInterval(interval_str);
    }

    // Otherwise treat as cron expression
    return .{ .cron = try CronExpression.parse(spec) };
}

pub fn nextRunTime(self: BackupSchedule, from: i64) i64 {
    return switch (self) {
        .interval => |i| from + i.toNanoseconds(),
        .cron => |c| c.nextTime(from),
    };
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Modulo sharding | Jump consistent hash | 2014 (Google paper) | Optimal 1/(N+1) movement on resize |
| CRL-only revocation | OCSP stapling preferred | ~2015 | Lower latency, better availability |
| --aof flag | --aof-file with path | Already deprecated | Clearer semantics, will be removed |
| Standalone state machine tests | VOPR fuzzer integration | This phase | Better coverage through fuzzing |

**Deprecated/outdated:**
- `--aof` flag: Deprecated, use `--aof-file` instead (CLEAN-01 removes it)
- Standalone state machine tests: Integrate into VOPR per CONTEXT.md decision

## Open Questions

Things that couldn't be fully resolved:

1. **Golden vector source of truth**
   - What we know: Jump hash algorithm is deterministic, implementations exist in Go, Python, Java
   - What's unclear: Which SDK implementation should be canonical?
   - Recommendation: Use reference values from Google's original paper/implementation, test all SDKs match

2. **CRL download mechanism**
   - What we know: Need HTTP client, Zig has std.http.Client
   - What's unclear: Certificate chain parsing for distribution point extraction
   - Recommendation: Start with configurable CRL path, add AIA extension parsing later

3. **VOPR extension scope**
   - What we know: Per CONTEXT.md, extend VOPR to cover state machine edge cases
   - What's unclear: Exact edge cases to cover
   - Recommendation: Review existing VOPR scenarios, identify gaps in GeoStateMachine coverage

## Sources

### Primary (HIGH confidence)

- `/home/g/archerdb/src/sharding.zig` - Examined complete implementation
- `/home/g/archerdb/src/tiering.zig` - Complete TieringManager with tests
- `/home/g/archerdb/src/cdc/amqp.zig` - Full AMQP 0.9.1 client implementation
- `/home/g/archerdb/src/archerdb/tls_config.zig` - TLS config with revocation stubs
- `/home/g/archerdb/src/archerdb/backup_config.zig` - Backup config types
- `/home/g/archerdb/src/repl/*.zig` - REPL infrastructure (terminal, parser, completion)
- `/home/g/archerdb/src/vopr.zig` - VOPR fuzzer structure

### Secondary (MEDIUM confidence)

- [GitHub: lithammer/go-jump-consistent-hash](https://github.com/lithammer/go-jump-consistent-hash) - Reference implementation with test vectors
- [AMQP 0-9-1 Protocol Specification | RabbitMQ](https://www.rabbitmq.com/amqp-0-9-1-protocol) - Official protocol specification
- [Snowflake OCSP Documentation](https://docs.snowflake.com/en/user-guide/ocsp) - Fail-open/fail-closed patterns
- [DigiCert: OCSP, CRL and Revoked SSL Certificates](https://knowledge.digicert.com/general-information/ocsp-crl-revoked-ssl-certificates) - CRL vs OCSP comparison

### Tertiary (LOW confidence)

- [Ziggit: Cron library for Zig](https://ziggit.dev/t/cron-library-for-zig/777) - External cron library (not using, implementing inline)

## Metadata

**Confidence breakdown:**
- Sharding verification: HIGH - Examined complete implementation, algorithm well-documented
- TODO resolution: HIGH - Counted markers, categorization clear
- REPL implementation: HIGH - Substantial infrastructure exists
- Tiering integration: HIGH - Complete implementation, needs hookup
- CRL/OCSP: MEDIUM - Config exists, HTTP client integration unclear
- Backup scheduling: MEDIUM - Config exists, cron parsing needs implementation
- VOPR extension: MEDIUM - Structure understood, scope unclear

**Research date:** 2026-01-22
**Valid until:** 60 days (stable domain, internal codebase focus)
