# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-01)

**Core value:** Customers can deploy mission-critical geospatial workloads with confidence that their data is safe, queries are fast, and the service stays available during failures.
**Current focus:** Phase 18 - CI Integration & Documentation (Plan 2 of 2 complete - PHASE COMPLETE)

## Current Position

Phase: 18 of 18 (CI Integration & Documentation)
Plan: 2 of 2 in current phase
Status: Phase complete - Milestone v1.1 COMPLETE
Last activity: 2026-02-01 - Completed 18-02-PLAN.md (documentation suite)

Progress: [██████████] 100%

## Milestone History

| Milestone | Phases | Plans | Status | Shipped |
|-----------|--------|-------|--------|---------|
| v1 DBaaS Production Readiness | 1-10 | 46 | Complete | 2026-01-31 |
| v1.1 SDK Testing & Benchmarking | 11-18 | 18 | Complete | 2026-02-01 |

## Performance Metrics

**Velocity (v1.1):**
- Total plans completed: 18
- Average duration: 7 min
- Total execution time: 133 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 11 | 2/2 | 19 min | 10 min |
| 12 | 2/2 | 21 min | 11 min |
| 13 | 3/3 | 21 min | 7 min |
| 14 | 2/2 | 27 min | 14 min |
| 15 | 2/2 | 11 min | 6 min |
| 16 | 2/2 | 7 min | 4 min |
| 17 | 3/3 | 20 min | 7 min |
| 18 | 2/2 | 7 min | 4 min |

**Recent Trend:**
- Last 5 plans: 17-02 (5 min), 17-03 (7 min), 18-01 (3 min), 18-02 (4 min)
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
- [11-02]: Warmup iterations: Java 500 > Node 200 > Python/Go 100 > C 50 (JIT vs AOT)
- [11-02]: CI tiers: smoke <5min (every push), PR <15min, nightly 2h (2 AM UTC)
- [12-02]: Wire format uses nanodegrees (i64) for coordinate precision
- [12-02]: curl examples minified on single lines for copy-paste
- [13-01]: Wrap Phase 11 fixture_loader rather than duplicate in SDK tests
- [13-01]: Node.js tests spawn Python subprocess for cluster management
- [13-01]: One test class per operation with multiple test cases
- [13-02]: Use go replace directive for local SDK testing
- [13-02]: Mock client for Java compilation verification
- [13-02]: Fixture-based tests load from test_infrastructure/fixtures/v1/
- [13-03]: C tests use absolute path for fixtures (binary runs from build dir)
- [14-01]: Verify error CODES, not message text (per CONTEXT.md)
- [14-01]: SDK default is 5 retries; tests verify configurability to 3
- [14-01]: is_retryable() only covers distributed errors (2xx, 4xx)
- [14-02]: All 5 SDK runners created with run_operation interface
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
- [17-03]: EdgeCaseAPIClient wraps requests.Session for HTTP operations
- [17-03]: api_client fixture yields client connected to cluster leader
- [17-03]: Response parsing handles both list and dict JSON formats
- [18-01]: fail-fast: true for all CI tiers per CONTEXT.md
- [18-01]: Weekly benchmark schedule Sunday 2 AM UTC
- [18-01]: Regression threshold 110% (10% degradation)
- [18-01]: Larger runners: 4-cores (nightly), 8-cores (benchmark)
- [18-02]: Testing guide covers all 5 SDKs with unified structure
- [18-02]: CI tier documentation matches Phase 11 definitions
- [18-02]: Benchmark guide links to docs/BENCHMARKS.md for methodology
- [18-02]: SDK comparison shows code examples in all languages

### Pending Todos

- UAT: Verify all 5 SDKs pass 100% of operation tests (Phase 13)
- UAT: Run parity tests and verify 70 cells show 100% consistency (Phase 14)
- UAT: Run benchmark suite and verify performance targets met (Phase 15)
- UAT: Run topology tests on real cluster with `ARCHERDB_INTEGRATION=1` (Phase 16)
- UAT: Verify edge case tests pass (Phase 17)

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-02-01
Stopped at: Completed 18-02-PLAN.md (documentation suite - MILESTONE COMPLETE)
Resume file: None

**Next Action:** v1.1 SDK Testing & Benchmarking milestone complete. Run UAT tests or proceed to next milestone planning.
