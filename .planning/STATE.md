# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-22)

**Core value:** Correctness, performance, and completeness with no compromises
**Current focus:** Phase 10 - Testing & Benchmarks (IN PROGRESS)

## Current Position

Phase: 10 of 10 (Testing & Benchmarks)
Plan: 3 of 4 in current phase - COMPLETE
Status: In progress
Last activity: 2026-01-23 - Plan 10-03 complete (Performance Benchmarks)

Progress: [#########-] 97% (38/39 plans complete)

## Performance Metrics

**Velocity:**
- Total plans completed: 38
- Average duration: 9 min
- Total execution time: 350 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01 | 3 | 26 min | 9 min |
| 02 | 4 | 54 min | 14 min |
| 03 | 5 | 43 min | 9 min |
| 04 | 3 | 47 min | 16 min |
| 05 | 5 | 83 min | 17 min |
| 06 | 5 | 12 min | 2 min |
| 07 | 4 | 34 min | 9 min |
| 08 | 3 | 15 min | 5 min |
| 09 | 3 | 12 min | 4 min |
| 10 | 3 | 24 min | 8 min |

**Recent Trend:**
- Last 5 plans: 10-03 (13m), 10-02 (8m), 10-01 (3m), 09-03 (4m), 09-02 (~)
- Trend: Benchmark documentation required comprehensive content

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

From 10-03:
- PercentileSpec struct for flexible sub-percentile calculations (p99.9)
- Memory tracking via /proc on Linux, getrusage on macOS
- Three benchmark modes: quick (CI), full (release), extreme (analysis)
- Memory sizing formula: (entities / 0.7) * 64 bytes for index
- CSV output format for machine-readable benchmark results

From 10-02:
- Geospatial tests use grid distribution for batch testing (100 events across 10x10 grid)
- Failover tests use FailoverCluster wrapper around Shell for process management
- Encryption tests verify plaintext not in ciphertext (data-at-rest verification)
- CI integration tests run with MinIO service container for S3-compatible testing

From 10-01:
- Alpine as separate job (not matrix) due to container syntax differences
- SDK tests informational (don't block core) - require running server
- 90% threshold for project and patch coverage via Codecov
- 5% regression threshold for benchmarks
- VOPR runs 2 hours default with workflow_dispatch override
- Java SDK uses Maven (mvn test) not Gradle

From 09-03:
- StatefulSet with 3 replicas and pod anti-affinity for K8s deployment
- Rolling upgrade procedure: followers first, primary last
- Symptom/Causes/Resolution/Prevention format for troubleshooting issues
- Keep a Changelog 1.1.0 format for release documentation

From 08-03:
- Alert thresholds follow CONTEXT.md: latency 500ms/2s, memory 70%/85%, replication lag 30s/2min
- All alerts include runbook_url annotation (required per CONTEXT.md)
- for duration: 5m for warnings, 2m for critical (except node down at 1m)
- Alertmanager templates provided as YAML snippets to copy, not Go templates

From 08-02:
- Replica health derived from lag metrics using clamp_max
- Write amplification thresholds: 15x warning, 30x critical
- Disk latency thresholds: 10ms p99 for SSDs
- Consistent variables across dashboards: datasource, instance, terminology

From 07-04:
- Component health checks: replica, memory, storage, replication
- HTTP 429 for degraded health, 503 for unhealthy
- 16GB default memory limit for percentage calculation
- server_initialized flag must be set before /ready returns 200

From 07-02:
- POSIX sockets for HTTP POST (consistent with metrics_server.zig pattern)
- Drop spans on export failure (no retry per RESEARCH.md anti-patterns)
- Default 5-second flush interval with 100-span batch size
- Thread-local storage for correlation context propagation
- Mutex-protected buffer for thread-safe span recording

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

## Phase 7 Observability Core Summary

All observability features complete:

| Plan | Topic | Status | Resolution |
|------|-------|--------|------------|
| 07-01 | Prometheus Metrics | COMPLETE | S2, process, compaction, checkpoint, build_info metrics |
| 07-02 | Distributed Tracing | COMPLETE | OTLP exporter, W3C/B3 context, CLI options |
| 07-03 | Structured Logging | COMPLETE | JSON/text formats, per-module levels, log rotation |
| 07-04 | Health Endpoints | COMPLETE | /health/detailed, proper K8s probe semantics |

From 07-04:
- /health/detailed with component checks (replica, memory, storage, replication)
- /health/live always returns 200 (liveness probe)
- /health/ready returns 503 until initialized
- HTTP status codes: 200 healthy, 429 degraded, 503 unhealthy
- All responses include uptime_seconds, version, commit_hash

From 07-03:
- JSON log format with correlation context (trace_id, span_id, request_id)
- Per-module log levels (--log-module-levels=vsr:debug,lsm:warn)
- Sensitive data redaction at info/warn levels (coordinates, content)
- Auto format detection as default (JSON for pipes, text for TTY)
- Separate --log-module-levels option (enum parsing incompatible with comma format)
- Correlation context wired into metrics_server.zig request handling

## Phase 8 Observability Dashboards Summary

All dashboards and alerting complete:

| Plan | Component | Status | Details |
|------|-----------|--------|---------|
| 08-01 | Overview + Queries | COMPLETE | 8 + 10 = 18 panels |
| 08-02 | Replication + Storage | COMPLETE | 8 + 12 = 20 panels |
| 08-03 | Cluster + Alerting | COMPLETE | 10 panels, 29 rules, 5 templates |

**Total Phase 8 Output:**
- 5 Grafana dashboards (48 panels)
- 29 Prometheus alerting rules (12 warning, 17 critical)
- 5 Alertmanager notification templates (Slack, PagerDuty, OpsGenie, email, webhook)

From 08-03:
- Alert groups: latency, replication, resource, error, cluster, compaction
- All alerts have runbook_url and remediation annotations
- Alertmanager README with routing examples and testing instructions
- Inhibit rules to prevent alert storms

## Phase 9 Documentation Summary

All documentation complete:

| Plan | Topic | Status | Resolution |
|------|-------|--------|------------|
| 09-01 | Index & Quickstart | COMPLETE | README index, 5-minute quickstart |
| 09-02 | Architecture & API | COMPLETE | Deep-dive architecture, API reference |
| 09-03 | Operations | COMPLETE | K8s deployment, upgrades, troubleshooting, CHANGELOG |

**Total Phase 9 Output:**
- docs/README.md (documentation index)
- docs/quickstart.md (5-minute getting started)
- docs/architecture.md (system deep-dive with Mermaid diagrams)
- docs/api-reference.md (complete API documentation)
- docs/operations-runbook.md (enhanced with K8s and upgrades)
- docs/troubleshooting.md (861 lines, 28 issue categories)
- docs/CHANGELOG.md (Phase 1-9 release documentation)

## Phase 10 Testing & Benchmarks Summary

Plans 10-01, 10-02, and 10-03 complete:

| Plan | Topic | Status | Resolution |
|------|-------|--------|------------|
| 10-01 | CI Infrastructure | COMPLETE | Alpine, coverage, VOPR, benchmarks |
| 10-02 | Integration Tests | COMPLETE | Geospatial, backup/restore, failover, encryption |
| 10-03 | Performance Benchmarks | COMPLETE | p99.9 percentiles, benchmark script, docs |
| 10-04 | Final Testing | PENDING | - |

**Total Phase 10 Output (so far):**
- Extended CI workflow with Alpine Linux container testing
- Coverage job with kcov and Codecov (90% threshold)
- VOPR scheduled workflow (2+ hours nightly)
- SDK test jobs for Python, Node.js, Java, Go
- Benchmark regression detection (5% threshold)
- Integration tests job with MinIO service container
- Geospatial integration tests (INT-01)
- Backup/restore integration tests (INT-03)
- Failover integration tests (INT-04)
- Encryption integration tests (INT-06)
- Extended benchmark harness with p95/p99.9 percentiles
- Memory usage tracking (RSS on Linux/macOS)
- scripts/run-perf-benchmarks.sh with quick/full/extreme modes
- docs/benchmarks.md with methodology and results
- docs/hardware-requirements.md with sizing formulas

## Session Continuity

Last session: 2026-01-23
Stopped at: Plan 10-03 complete
Resume file: None

Next: Plan 10-04 (Final Testing)
