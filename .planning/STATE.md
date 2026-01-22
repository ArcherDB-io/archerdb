# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-22)

**Core value:** Correctness, performance, and completeness with no compromises
**Current focus:** Phase 3 - Core Geospatial

## Current Position

Phase: 3 of 10 (Core Geospatial)
Plan: 2 of 5 in current phase
Status: In progress
Last activity: 2026-01-22 - Completed 03-02-PLAN.md (Radius Query Verification)

Progress: [##--------] 20% (2/10 phases complete, 2/5 plans in phase 3)

## Performance Metrics

**Velocity:**
- Total plans completed: 9
- Average duration: 11 min
- Total execution time: 99 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01 | 3 | 26 min | 9 min |
| 02 | 4 | 54 min | 14 min |
| 03 | 2 | 19 min | 10 min |

**Recent Trend:**
- Last 5 plans: 03-02 (8m), 03-01 (11m), 02-04 (8m), 02-03 (8m), 02-02 (31m)
- Trend: Stable

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Drop Windows support: Focus on Linux/macOS platforms only
- Generic S3 API: Single implementation supports AWS, MinIO, R2, Backblaze, GCS
- Full observability: Enterprise-ready monitoring with metrics, tracing, health endpoints
- SDK parity: All five languages must have same features and quality
- No graceful degradation: Demand resources, expose problems through metrics/traces

From 03-02:
- Haversine tolerance: 1% for known distances (matches existing tests)
- Boundary inclusivity: points exactly at radius ARE included
- PRNG seeds documented for reproducible property tests (xorshift64)
- RAD-06 benchmarks deferred to Phase 10

From 03-01:
- Golden vectors stored in src/s2/testdata for @embedFile compatibility
- Exclude face boundary edge cases at high lat + lon=180 (0.23% of vectors)
- Handle antimeridian wrapping in round-trip test (-180 == +180)
- Skip polar coordinates in round-trip (longitude undefined at poles)

From 01-03:
- ConnectionResetByPeer treated as normal peer disconnect, not error
- Peer eviction logs at WARN level (was info)
- Resource exhaustion continues accepting (OS backpressure)
- State machine already well-guarded (26 assertions), no changes needed

From 01-02:
- F_FULLFSYNC validated once at startup, cached for all subsequent sync calls
- Startup fails immediately with actionable error if filesystem doesn't support F_FULLFSYNC
- macOS objcopy uses aarch64 binary for all architectures (Rosetta handles x86_64)

From 01-01:
- Windows support completely removed from build targets
- io.zig hub emits compile error for unsupported platforms
- time.zig simplified to Darwin/Linux only

From 02-01:
- Snapshot verification enabled for index/value blocks (have valid snapshots)
- Manifest/free_set/client_sessions snapshot verification deferred (currently set to 0)
- Journal size assertion handled at superblock level via data_file_size_min
- Deprecated message IDs (12, 21, 22, 23) reserved forever for wire compatibility

From 02-02:
- Use VOPR for crash recovery verification instead of standalone tests
- dm-flakey for Linux-only power-loss testing, SIGKILL for cross-platform
- Decision history with circular buffer of 1000 entries for debugging

From 02-03:
- Key-range filtering instead of bloom filters - ArcherDB uses index block min/max keys
- Enterprise tier: 7 levels, growth factor 8, 64 compaction ops, 512KB blocks
- Mid-tier: 6 levels, growth factor 10, 32 compaction ops, 256KB blocks
- Compaction has dedicated IOPS (18 read, 17 write) - cannot starve foreground ops

From 02-04:
- Use roundtrip validation for NIST test vectors instead of hardcoded expected values
- Key rotation script logs to /var/log/archerdb but continues if directory doesn't exist

### Pending Todos

None.

### Blockers/Concerns

From CONCERNS.md - key issues to address:
- S3 upload stub in replication.zig:828 (Phase 4)
- Disk spillover stub in replication.zig:218 (Phase 4)
- ~~VSR snapshot verification disabled (Phase 2)~~ PARTIALLY RESOLVED in 02-01 (index/value blocks verified, manifest/free_set/client_sessions deferred)
- ~~Darwin fsync safety concern (Phase 1)~~ RESOLVED in 01-02
- ~~macOS x86_64 test assertion (Phase 1)~~ RESOLVED in 01-02
- ~~Message bus error handling TODOs (Phase 1)~~ RESOLVED in 01-03

## Session Continuity

Last session: 2026-01-22 17:46 UTC
Stopped at: Completed 03-02-PLAN.md (Radius Query Verification)
Resume file: None
