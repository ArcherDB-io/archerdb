# Phase 1: Critical Bug Fixes - Research

**Researched:** 2026-01-29
**Domain:** Zig-based database bug fixing (readiness probe, persistence, concurrency, TTL cleanup)
**Confidence:** HIGH

## Summary

This phase addresses four critical bugs blocking production deployment of ArcherDB, a Zig-based geospatial database built on ViewStamped Replication (VSR). The research investigated each bug's root cause through code analysis and validation results.

Key findings:
1. **Readiness probe (503)**: The `/health/ready` endpoint only returns 200 after `replica.status == .normal`. The server sets `server_initialized = true` when the replica reaches normal status, but this may not happen within 30 seconds depending on recovery state.
2. **Persistence failure**: Tests ran with `--development` flag (visible in validation logs). In dev mode, data persistence behavior differs. The validation script checked persistence after restart but found entities were not persisted.
3. **Concurrency limit**: The lite config sets `clients_max = 7`. Production config allows `clients_max = 64`. Testing with 100+ clients requires either production config or increasing the lite config limit.
4. **TTL cleanup scanning 0 entries**: The cleanup operation `scan_expired_batch()` starts from `cleanup_scanner.position` (initialized to 0). The scan found `entries_scanned=0, entries_removed=0`, suggesting either the index was empty or the scan position logic has a bug.

**Primary recommendation:** Fix each bug by addressing its root cause: ensure proper initialization timing for readiness, verify persistence config, adjust clients_max for concurrency testing, and debug TTL scanner position logic.

## Standard Stack

This is a Zig codebase with existing infrastructure - no external libraries to add.

### Core
| Component | Version | Purpose | Notes |
|-----------|---------|---------|-------|
| Zig | 0.13+ | Language | Already in use, bundled in `./zig/` |
| VSR | N/A | Replication | ViewStamped Replication, internal |
| io_uring | N/A | I/O | Linux async I/O, internal |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `./zig/zig build` | Build system | All compilation |
| `-Dconfig=lite` | Constrained testing | Development/testing |
| `-Dconfig=production` | Full testing | Production validation |

### Test Commands
```bash
# Constrained build (recommended for this server)
./zig/zig build -j4 -Dconfig=lite check

# Constrained unit tests
./zig/zig build -j4 -Dconfig=lite test:unit

# Run specific test filter
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "ttl"
```

## Architecture Patterns

### Bug Fix Pattern
```
1. Create reproduction script (fails before fix)
2. Add comprehensive logging
3. Investigate root cause
4. Implement fix
5. Write regression test
6. Verify reproduction script passes
7. Run full validation checklist
8. Commit atomically
```

### Key Source Files by Bug

**Bug 1 - Readiness Probe:**
```
src/archerdb/metrics_server.zig  # handleHealthReady(), server_initialized
src/archerdb/main.zig            # markInitialized() call, replica.status check
src/vsr/replica.zig              # replica status transitions
```

**Bug 2 - Persistence:**
```
src/archerdb/cli.zig             # --development flag handling
src/vsr/superblock.zig           # Superblock persistence
src/storage.zig                  # Storage layer
src/archerdb/main.zig            # Development mode logic
```

**Bug 3 - Concurrency:**
```
src/config.zig                   # clients_max configuration
src/constants.zig                # clients_max usage
src/connection_pool.zig          # Connection pool management
src/coordinator.zig              # max_connections setting (10000)
```

**Bug 4 - TTL Cleanup:**
```
src/ttl.zig                      # CleanupScanner, is_expired()
src/ram_index.zig                # scan_expired_batch()
src/geo_state_machine.zig        # execute_cleanup_expired()
```

### Reproduction Script Pattern
```python
#!/usr/bin/env python3
"""Reproduction script for [BUG_NAME]

Expected behavior BEFORE fix: [fails with ...]
Expected behavior AFTER fix: [succeeds with ...]
"""
import archerdb
# ... test code that demonstrates the bug
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| TTL expiration checks | Custom time logic | `ttl.is_expired()` | Already handles overflow protection |
| Health response format | Custom JSON | Existing `handleHealthReady()` | Consistent with other endpoints |
| Connection limiting | Custom limits | `connection_pool.PoolConfig` | Already has adaptive timeouts |
| Cleanup scanning | Custom iterator | `ram_index.scan_expired_batch()` | Atomic reads, proper wraparound |

**Key insight:** All four bugs are in existing code paths, not missing implementations. The fixes involve correcting timing, configuration, or logic - not building new systems.

## Common Pitfalls

### Pitfall 1: Testing with Wrong Config
**What goes wrong:** Tests pass in lite mode but fail in production, or vice versa
**Why it happens:** Lite config has `clients_max=7`, production has `clients_max=64`
**How to avoid:** Run tests in BOTH configs per CONTEXT.md decision
**Warning signs:** Concurrency tests passing with < 10 clients but failing at 100+

### Pitfall 2: Dev vs Production Persistence
**What goes wrong:** Data persists in dev mode but not production (or vice versa)
**Why it happens:** `--development` flag changes Direct I/O behavior and possibly WAL handling
**How to avoid:** Test WITHOUT `--development` flag for persistence validation
**Warning signs:** Validation logs showing `"multiversioning: upgrades disabled for development"`

### Pitfall 3: Replica Status Timing
**What goes wrong:** Readiness probe returns 503 even after server is "up"
**Why it happens:** `replica.status == .normal` may take time due to recovery/view change
**How to avoid:** Understand VSR status transitions: recovering -> recovering_head -> normal
**Warning signs:** `"status":"initializing"` in health response after extended uptime

### Pitfall 4: TTL Cleanup Position Reset
**What goes wrong:** Cleanup reports 0 entries scanned despite having data
**Why it happens:** `cleanup_scanner.position` starts at 0, may not align with actual entries
**How to avoid:** Check if `position >= capacity` edge case is handled
**Warning signs:** `entries_scanned=0` when index has entries

### Pitfall 5: Resource Exhaustion During Testing
**What goes wrong:** OOM kills or test hangs on constrained server
**Why it happens:** Default build uses full resources (~8GB+ RAM)
**How to avoid:** Always use `-j4 -Dconfig=lite` per CLAUDE.md
**Warning signs:** System slowdown, zig process killed

## Code Examples

### Health Ready Check (from metrics_server.zig)
```zig
// Source: src/archerdb/metrics_server.zig:1056
fn handleHealthReady(client_fd: posix.socket_t) !void {
    // Must be initialized first (returns 503 until initialization complete)
    if (!server_initialized) {
        // Returns 503 Service Unavailable
        try sendResponse(client_fd, .service_unavailable, "application/json", body);
        return;
    }

    const state = replica_state;
    if (state.isReady()) {
        try sendResponse(client_fd, .ok, "application/json", body);
    } else {
        try sendResponse(client_fd, .service_unavailable, "application/json", body);
    }
}
```

### Initialization Trigger (from main.zig)
```zig
// Source: src/archerdb/main.zig:1108-1113
// Mark server as initialized once replica reaches normal status
if (!server_marked_initialized and replica.status == .normal) {
    metrics_server.markInitialized();
    server_marked_initialized = true;
}
```

### TTL Cleanup Scanner (from ram_index.zig)
```zig
// Source: src/ram_index.zig:2465-2522
pub fn scan_expired_batch(
    self: *@This(),
    start_position: u64,
    batch_size: u64,
    current_time_ns: u64,
) ScanExpiredResult {
    // Start position, wrapped to valid range.
    var position = if (start_position >= self.capacity) 0 else start_position;

    while (entries_scanned < effective_batch) {
        const entry = @as(*volatile Entry, @ptrCast(entry_ptr)).*;

        // Skip empty slots and tombstones.
        if (!entry.is_empty() and !entry.is_tombstone()) {
            const expiration = ttl.is_entry_expired(entry, current_time_ns);
            if (expiration.expired) {
                const remove_result = self.remove_if_id_matches(...);
                if (remove_result.removed) entries_removed += 1;
            }
        }
        // ...
    }
}
```

### Config Clients Max (from config.zig)
```zig
// Source: src/config.zig:661-662
// Lite config
.cluster = .{
    .clients_max = 4 + 3,  // = 7 max clients!
    // ...
}

// Source: src/config.zig:492-494
// Production config
.cluster = .{
    .clients_max = 64,
    // ...
}
```

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| Single config | Lite vs Production configs | Must test both |
| Sync I/O | io_uring async I/O | Better performance |
| Simple health check | Two-phase (initialized + replica ready) | More robust |

**Key understanding:**
- VSR replicas have multiple status states: `.normal`, `.view_change`, `.recovering`, `.recovering_head`
- Only `.normal` status means "ready to serve"
- The lite config is intentionally restricted for testing on constrained systems

## Open Questions

### Question 1: Exact Cause of TTL entries_scanned=0
- **What we know:** The cleanup_expired operation returned `entries_scanned=0, entries_removed=0`
- **What's unclear:** Was the index empty at scan time? Is there a position initialization bug?
- **Recommendation:** Add logging to trace `cleanup_scanner.position` and `ram_index.get_stats()` before/after scan

### Question 2: Replica Recovery Timing
- **What we know:** Server marks initialized when `replica.status == .normal`
- **What's unclear:** How long does recovery take? What blocks the transition?
- **Recommendation:** Add timing logs around replica status transitions, check superblock/WAL recovery

### Question 3: Persistence in Production Config
- **What we know:** Validation ran with `--development` flag
- **What's unclear:** Does production config (without `--development`) persist correctly?
- **Recommendation:** Re-run persistence test without `--development`, with proper data file

## Bug-Specific Investigation Findings

### Bug 1: Readiness Probe Returns 503

**Root Cause Analysis:**
1. `server_initialized` is set to `true` only when `replica.status == .normal` (main.zig:1110-1112)
2. The replica status check happens in the tick loop after replica initialization
3. If the replica is in `.recovering` or `.recovering_head` status, initialization never happens
4. The validation showed status remained "initializing" after 10 seconds

**Likely Fix Areas:**
- Check why replica doesn't reach `.normal` status quickly
- Verify single-node cluster enters normal status immediately (no consensus needed)
- May need to adjust initialization timing or add logging to debug recovery path

### Bug 2: Data Doesn't Persist After Restart

**Root Cause Analysis:**
1. Validation ran with `--development` flag (visible in server logs)
2. Development mode disables direct I/O: `direct_io = false` in lite config
3. The restart_check.py script found `RESTART_ENTITY2 False None None`
4. Server logs show `"Running in standalone mode (replica_count=1)"`

**Likely Fix Areas:**
- Test without `--development` flag
- Verify data file is being written (check `data.archerdb` size)
- Check if checkpoint/superblock is persisted on shutdown
- May be related to WAL journal not being flushed

### Bug 3: Concurrent Client Handling Fails at 10

**Root Cause Analysis:**
1. Lite config has `clients_max = 7` (config.zig:662)
2. Production config has `clients_max = 64` (config.zig:493)
3. The connection_pool has separate `max_connections = 32` default (connection_pool.zig:23)
4. Testing 100 concurrent clients with lite config will fail at ~7 clients

**Likely Fix Areas:**
- Test with production config OR increase lite config `clients_max`
- Verify connection pool limits vs clients_max interaction
- Check if coordinator's `max_connections: u32 = 10000` is being used

### Bug 4: TTL Cleanup Removes 0 Entries

**Root Cause Analysis:**
1. Smoke test shows: `CLEANUP_RESULT CleanupResult(entries_scanned=0, entries_removed=0)`
2. But also shows: `LATEST_AFTER_TTL_EXCEPTION [210] Entity has expired due to TTL`
3. This means lazy expiration (on lookup) works, but background cleanup doesn't
4. The scan starts at `cleanup_scanner.position` which initializes to 0
5. `scan_expired_batch` wraps position if `>= capacity`

**Likely Fix Areas:**
- Check if RAM index is actually populated when cleanup runs
- Verify the consensus timestamp passed to cleanup is appropriate
- Check if entries are in a different data structure (LSM vs RAM index)
- The TTL entity was created, expired, but cleanup found nothing - timing issue?

## Sources

### Primary (HIGH confidence)
- `src/archerdb/metrics_server.zig` - Readiness probe implementation
- `src/archerdb/main.zig` - Server initialization and tick loop
- `src/config.zig` - Configuration values (clients_max, etc.)
- `src/ram_index.zig` - TTL cleanup scanner implementation
- `src/ttl.zig` - TTL types and expiration logic
- `validation-results/2026-01-29/*` - Validation evidence

### Secondary (MEDIUM confidence)
- `DATABASE_VALIDATION_CHECKLIST.md` - Documented failures and evidence
- `01-CONTEXT.md` - User decisions and constraints

## Metadata

**Confidence breakdown:**
- Readiness probe: HIGH - Code path clearly shows the logic
- Persistence: MEDIUM - Need to verify dev vs production behavior
- Concurrency: HIGH - Config values are explicit (clients_max=7 in lite)
- TTL cleanup: MEDIUM - Scan logic looks correct, need runtime debugging

**Research date:** 2026-01-29
**Valid until:** 2026-02-28 (stable codebase, bug-fix focus)
