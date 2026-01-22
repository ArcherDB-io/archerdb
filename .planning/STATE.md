# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-22)

**Core value:** Correctness, performance, and completeness with no compromises
**Current focus:** Phase 2 - VSR & Storage

## Current Position

Phase: 2 of 10 (VSR & Storage)
Plan: 2 of 4 in current phase
Status: In progress
Last activity: 2026-01-22 - Completed 02-02-PLAN.md (Durability Verification)

Progress: [██--------] 17% (5/29 plans complete)

## Performance Metrics

**Velocity:**
- Total plans completed: 5
- Average duration: 11 min
- Total execution time: 64 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01 | 3 | 26 min | 9 min |
| 02 | 2 | 38 min | 19 min |

**Recent Trend:**
- Last 5 plans: 02-02 (31m), 02-01 (7m), 01-03 (6m), 01-02 (5m), 01-01 (15m)
- Trend: Stable (02-02 longer due to comprehensive VOPR verification runs)

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

Last session: 2026-01-22
Stopped at: Completed 02-02-PLAN.md (Durability Verification)
Resume file: None
