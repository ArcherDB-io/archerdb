# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-01)

**Core value:** Customers can deploy mission-critical geospatial workloads with confidence that their data is safe, queries are fast, and the service stays available during failures.
**Current focus:** Phase 17 - Edge Cases & Advanced Benchmarks (Plan 2 of 2 complete)

## Current Position

Phase: 17 of 18 (Edge Cases & Advanced Benchmarks)
Plan: 2 of 2 in current phase
Status: Phase complete
Last activity: 2026-02-01 - Completed 17-02-PLAN.md (advanced benchmarks)

Progress: [███████░░░] 53%

## Milestone History

| Milestone | Phases | Plans | Status | Shipped |
|-----------|--------|-------|--------|---------|
| v1 DBaaS Production Readiness | 1-10 | 46 | Complete | 2026-01-31 |
| v1.1 SDK Testing & Benchmarking | 11-18 | 17 | In progress | - |

## Performance Metrics

**Velocity (v1.1):**
- Total plans completed: 15
- Average duration: 8 min
- Total execution time: 119 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 11 | 2/2 | 19 min | 10 min |
| 12 | 2/2 | 21 min | 11 min |
| 13 | 3/3 | 21 min | 7 min |
| 14 | 2/2 | 27 min | 14 min |
| 15 | 2/2 | 11 min | 6 min |
| 16 | 2/2 | 7 min | 4 min |
| 17 | 2/2 | 13 min | 7 min |

**Recent Trend:**
- Last 5 plans: 16-01 (4 min), 16-02 (3 min), 17-01 (8 min), 17-02 (5 min)
- Trend: Consistent fast execution

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [v1.1 Init]: Use comprehensive depth (8 phases) for 94 requirements
- [v1.1 Init]: Start phase numbering at 11 (continuing from v1.0)
- [11-01]: Auto-detect leader via region role metric (archerdb_region_info role=primary)
- [11-01]: Use seeded RNG for entity_id generation (reproducibility)
- [11-01]: Use underscore naming (test_infrastructure) for Python module compatibility
- [11-02]: Fixture tag distribution: 14 smoke, 31 PR, 34 nightly
- [11-02]: Warmup iterations: Java 500 > Node 200 > Python/Go 100 > C/Zig 50 (JIT vs AOT)
- [11-02]: CI tiers: smoke <5min (every push), PR <15min, nightly 2h (2 AM UTC)
- [12-02]: Wire format uses nanodegrees (i64) for coordinate precision
- [12-02]: curl examples minified on single lines for copy-paste
- [12-01]: Zig SDK uses error.X syntax for switch matching
- [12-01]: Zig SDK uses request.response.status for HTTP status
- [13-01]: Wrap Phase 11 fixture_loader rather than duplicate in SDK tests
- [13-01]: Node.js tests spawn Python subprocess for cluster management
- [13-01]: One test class per operation with multiple test cases
- [13-02]: Use go replace directive for local SDK testing
- [13-02]: Mock client for Java compilation verification
- [13-02]: Fixture-based tests load from test_infrastructure/fixtures/v1/
- [13-03]: C tests use absolute path for fixtures (binary runs from build dir)
- [13-03]: Zig tests use sdk module import (Zig 0.14+ requirement)
- [14-01]: Verify error CODES, not message text (per CONTEXT.md)
- [14-01]: SDK default is 5 retries; tests verify configurability to 3
- [14-01]: is_retryable() only covers distributed errors (2xx, 4xx)
- [14-02]: All 6 SDK runners created with run_operation interface
- [14-02]: Edge case fixtures: 33 test cases for polar/antimeridian/equator
- [14-02]: Parity documentation in 4 locations per CONTEXT.md
- [15-01]: Use scipy.stats.t.interval for confidence intervals
- [15-01]: Use Welch's t-test (equal_var=False) for regression detection
- [15-01]: HDR histogram fallback to sorted-array when unavailable
- [15-01]: Performance targets: 770K events/sec, read P95<1ms, write P95<10ms
- [15-02]: Fresh cluster per benchmark run (isolated measurements)
- [15-02]: MixedWorkload uses read_ratio (0.8 = 80% reads, 20% writes)
- [15-02]: Regression threshold 10% for change detection
- [16-01]: Use subprocess.terminate()/kill() for clean signal handling
- [16-01]: NetworkPartitioner uses iptables INPUT chain DROP rules
- [16-01]: ConsistencyChecker uses tenacity retry for eventual consistency
- [16-01]: Recovery SLA targets: 3-node <10s, 5-node <15s, 6-node <20s
- [16-02]: Parametrize 14 operations x 4 topologies for comprehensive coverage
- [16-02]: Auto-setup test data for operations that require existing entities
- [16-02]: ARCHERDB_INTEGRATION=1 gates topology integration tests
- [17-01]: Edge case fixtures: 33 cases for polar/antimeridian/equator
- [17-01]: GeographicEdgeCaseGenerator uses boundary conditions systematically
- [17-02]: Scaling factor = (throughput_N / throughput_1) / N
- [17-02]: Linear scaling defined as factor 0.8-1.2
- [17-02]: SDK parity threshold 20% of mean latency
- [17-02]: City-concentrated uses Gaussian with std_dev = radius/3

### Pending Todos

- UAT: Verify all 6 SDKs pass 100% of operation tests (Phase 13)
- UAT: Run parity tests and verify 84 cells show 100% consistency (Phase 14)
- UAT: Run benchmark suite and verify performance targets met (Phase 15)
- UAT: Run topology tests on real cluster with `ARCHERDB_INTEGRATION=1` (Phase 16)
- UAT: Verify edge case tests pass (Phase 17)

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-02-01
Stopped at: Completed 17-02-PLAN.md (advanced benchmarks - Phase 17 complete)
Resume file: None

**Next Action:** Execute `/gsd:execute-phase 18` for documentation phase
