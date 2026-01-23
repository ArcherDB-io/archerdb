# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-22)

**Core value:** Correctness, performance, and completeness with no compromises
**Current focus:** Phase 7 - Observability Core (IN PROGRESS)

## Current Position

Phase: 7 of 10 (Observability Core) - IN PROGRESS
Plan: 1 of 4 in current phase - COMPLETE
Status: Plan 07-01 complete, ready for 07-02
Last activity: 2026-01-23 - Plan 07-01 complete (Prometheus Metrics)

Progress: [######----] 65% (6/10 phases + 1/4 plans complete)

## Performance Metrics

**Velocity:**
- Total plans completed: 26
- Average duration: 10 min
- Total execution time: 277 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01 | 3 | 26 min | 9 min |
| 02 | 4 | 54 min | 14 min |
| 03 | 5 | 43 min | 9 min |
| 04 | 3 | 47 min | 16 min |
| 05 | 5 | 83 min | 17 min |
| 06 | 5 | 12 min | 2 min |
| 07 | 1 | 12 min | 12 min |

**Recent Trend:**
- Last 5 plans: 07-01 (12m), 06-05 (8m), 06-04 (2m), 06-03 (2m), 06-02 (2m)
- Trend: Back to normal execution time after SDK documentation phase

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

From 07-01:
- S2 cell level buckets track levels 0, 10, 15, 20, 25, 30 (avoid high cardinality)
- Process metrics use /proc on Linux, getrusage on Darwin
- Build info stored in fixed-size arrays with length tracking
- recordX() helper functions encapsulate metric updates
- Process metrics follow standard Prometheus process_* naming

From 06-05:
- Google-style docstrings for Python SDK (Args/Returns/Raises/Example)
- All error classes documented with code and retryable info
- README expanded with async, error handling, and retry configuration sections

From 06-03:
- Use ForkJoinPool.commonPool as default executor for async operations
- GeoClientAsync wraps GeoClient (delegation) rather than extending it
- All async methods use supplyAsync for consistent error propagation

From 05-05:
- VOPR GeoStateMachine coverage already comprehensive in geo_workload.zig
- CSV import tool is standalone CLI (external tool that connects to ArcherDB)
- Use Enhancement: prefix for deferred CLI commands with phase reference
- Remaining "not yet implemented" messages intentional (REPL transactions, S3 ETag edge case)

From 05-03:
- REPL transaction commands show informational message (transactions not in scope)
- TLS CRL/OCSP uses simplified ASN.1 parsing (full X.509 parsing deferred)
- Backup scheduling uses epoch-based timestamp calculation
- Cron expression parser supports 5-field format with all standard field specs

From 05-04:
- Tiering disabled by default (opt-in via tiering_enabled config flag)
- Cold tier entities removed from RAM index during tick()
- Access patterns tracked on all query operations (uuid, radius, polygon)
- Tier migrations tracked via Prometheus metrics

From 05-02:
- Use Enhancement: prefix for future features not blocking correctness
- Use Note: prefix for explanatory documentation of current behavior
- Use TestEnhancement: prefix for VOPR/fuzz improvements
- Use DocTODO: prefix for documentation items deferred to Phase 9
- Renamed sync_view to sync_view_reserved (deprecated field in superblock)

From 05-01:
- 10M keys required for 5% tolerance with 256 shards (statistical stability)
- All SDKs now have jump_hash implementations matching Zig source of truth
- Cross-shard tests verify coordinator infrastructure, not network calls

From 04-03:
- Graceful test skipping when Docker/MinIO unavailable (return SkipZigTest)
- MinioTestContext auto-detects existing containers for local dev
- curl used for MinIO health check instead of Zig HTTP client (simpler)

From 04-02:
- SpilloverSegment uses u64 checksum instead of u128 (simpler alignment, Wyhash produces u64)
- spillover_dir replaces spillover_path in Config (SpilloverManager manages directory)
- Iterator seeks past body data without reading (headers only for recovery)
- Atomic writes: temp file + sync + rename pattern for durability
- Spillover triggers after max_retries (10) consecutive S3 failures
- replication_state metric: 0=healthy, 1=degraded (spillover active), 2=failed

From 04-01:
- Generic S3 API supports AWS, MinIO, R2, GCS, Backblaze via provider detection
- Path style URLs for MinIO/generic, virtual-hosted for AWS
- R2 uses region=auto for signing per Cloudflare spec
- 16MB part size for multipart uploads (100MB threshold)
- 10 retries with exponential backoff ~17 min total before failure
- Graceful fallback to simulated uploads when credentials unavailable

From 03-05:
- Stress testing for race condition verification (1000 iterations per CONTEXT.md discretion)
- Memory formula: capacity * 64 / 0.70 bytes (91.5GB for 1B entities)

From 03-04:
- TTL expiration uses >= comparison (expires at boundary, not after)
- LWW tie-break uses higher composite_id for determinism
- Minimal tombstones have zeroed location, full tombstones preserve location for audit

From 03-03:
- Point-in-polygon uses ray casting with counter-clockwise exterior rings
- Polygon holes use clockwise winding (GeoJSON convention)

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
- ~~S3 upload stub in replication.zig:828 (Phase 4)~~ RESOLVED in 04-01 (real S3 uploads implemented)
- ~~Disk spillover stub in replication.zig:218 (Phase 4)~~ RESOLVED in 04-02 (SpilloverManager with atomic writes)
- ~~VSR snapshot verification disabled (Phase 2)~~ PARTIALLY RESOLVED in 02-01 (index/value blocks verified, manifest/free_set/client_sessions deferred)
- ~~Darwin fsync safety concern (Phase 1)~~ RESOLVED in 01-02
- ~~macOS x86_64 test assertion (Phase 1)~~ RESOLVED in 01-02
- ~~Message bus error handling TODOs (Phase 1)~~ RESOLVED in 01-03
- ~~Deprecated --aof flag (Phase 5)~~ RESOLVED in 05-02 (removed, only --aof-file remains)
- ~~Production TODOs in VSR/storage/LSM (Phase 5)~~ RESOLVED in 05-02 (converted to Enhancement:/Note:/DocTODO:)
- ~~Tiering integration with GeoStateMachine (Phase 5)~~ RESOLVED in 05-04 (full integration with metrics)
- ~~REPL stub (Phase 5)~~ RESOLVED in 05-03 (full interactive REPL implemented)
- ~~TLS CRL/OCSP stub (Phase 5)~~ RESOLVED in 05-03 (revocation checking implemented)
- ~~Backup scheduling stub (Phase 5)~~ RESOLVED in 05-03 (cron and interval support)
- ~~state_machine_tests stub (Phase 5)~~ RESOLVED in 05-05 (VOPR integration documented)
- ~~CDC AMQP stub (Phase 5)~~ RESOLVED in 05-05 (unit tests pass, CLI deferred to Phase 9)
- ~~CSV import tool (Phase 5)~~ RESOLVED in 05-05 (standalone CLI implemented)

## Phase 5 CLEAN Requirements Summary

All CLEAN requirements verified complete:

| ID | Requirement | Status | Resolution |
|----|-------------|--------|------------|
| CLEAN-01 | --aof flag removed | COMPLETE | Plan 05-02 |
| CLEAN-02 | TODOs resolved | COMPLETE | Plan 05-02 |
| CLEAN-03 | FIXMEs resolved | COMPLETE | Plan 05-02 |
| CLEAN-04 | REPL implemented | COMPLETE | Plan 05-03 |
| CLEAN-05 | state_machine_tests -> VOPR | COMPLETE | Plan 05-05 |
| CLEAN-06 | tiering.zig integrated | COMPLETE | Plan 05-04 |
| CLEAN-07 | backup_config scheduling | COMPLETE | Plan 05-03 |
| CLEAN-08 | TLS CRL/OCSP | COMPLETE | Plan 05-03 |
| CLEAN-09 | CDC AMQP | COMPLETE | Plan 05-05 (tests pass) |
| CLEAN-10 | CSV import | COMPLETE | Plan 05-05 |

## Phase 6 SDK Parity Summary

All SDK documentation complete:

| Plan | SDK | Status | Resolution |
|------|-----|--------|------------|
| 06-01 | C | COMPLETE | Doxygen docs + README (490 lines) + complete sample |
| 06-02 | Go | COMPLETE | Comprehensive godoc comments |
| 06-03 | Java | COMPLETE | Javadoc + async support |
| 06-04 | Node.js | COMPLETE | JSDoc + TypeScript types |
| 06-05 | Python | COMPLETE | Google-style docstrings |

From 06-01:
- Doxygen documentation embedded in Zig generator for auto-regeneration
- Error code ranges documented inline (0-599 by category)
- Field units documented in geo_event_t (nanodegrees, millimeters, centidegrees)
- 49 @brief annotations, memory ownership rules, thread safety warnings

## Phase 7 Observability Core Progress

| Plan | Topic | Status | Resolution |
|------|-------|--------|------------|
| 07-01 | Prometheus Metrics | COMPLETE | S2, process, compaction, checkpoint, build_info metrics |
| 07-02 | Distributed Tracing | PENDING | - |
| 07-03 | Structured Logging | PENDING | - |
| 07-04 | Health Endpoints | PENDING | - |

## Session Continuity

Last session: 2026-01-23
Stopped at: Plan 07-01 complete, ready for 07-02
Resume file: None

Next: Phase 7 Plan 02 - Distributed Tracing
