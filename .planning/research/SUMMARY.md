# Project Research Summary

**Project:** SDK Testing & Benchmarking Suite
**Domain:** Multi-Language SDK Testing Infrastructure for Distributed Geospatial Database
**Researched:** 2026-02-01
**Confidence:** HIGH

## Executive Summary

ArcherDB has 5 SDKs (Python, Node.js, Go, Java, C) that require comprehensive testing and benchmarking infrastructure. Recent testing revealed significant gaps: operation coverage ranges from 50% (C) to 93% (Python/Go), cross-SDK behavioral inconsistencies exist, and benchmarking lacks statistical rigor. Industry best practices for SDK testing emphasize three critical pillars: (1) cross-SDK contract testing with shared test specifications, (2) multi-tier test execution balancing fast feedback with comprehensive coverage, and (3) statistically sound benchmarking with proper warmup, percentile reporting, and regression detection.

The recommended approach builds on ArcherDB's existing infrastructure (pytest for Python, JUnit for Java, GitHub Actions for CI) while adding centralized integration tests in `tests/sdk/` for cross-SDK scenarios and a dedicated `benchmarks/` directory for performance regression tracking. The architecture uses matrix-based parallel execution to test all SDKs simultaneously, shared JSON test fixtures to ensure behavioral consistency, and tiered test execution (smoke tests on every push, SDK tests on PRs, multi-node tests nightly) to balance speed with coverage.

Key risks include benchmark noise on cloud CI runners (mitigate with relative benchmarking and statistical thresholds), flaky tests from timing dependencies (use polling with exponential backoff, not hardcoded sleeps), and cross-SDK drift (enforce contract testing with shared specifications). The existing github-action-benchmark integration and performance-baselines.md provide a foundation for regression detection, requiring only formalization of warmup protocols and percentile reporting standards.

## Key Findings

### Recommended Stack

Industry-standard testing frameworks are already in use and appropriate for the task. The stack emphasizes language-native tooling for SDK-specific tests combined with language-agnostic formats (JSON/YAML) for cross-SDK compatibility verification.

**Core technologies:**
- **pytest + pytest-benchmark (Python):** Already in use, de facto standard, excellent for both correctness and microbenchmarking with built-in percentile reporting
- **JUnit 5 + JMH (Java):** Already in use, JMH is OpenJDK standard for microbenchmarking with proper JVM warmup handling
- **Go testing (stdlib) + built-in benchmarks:** No additional dependencies, native `-bench` support with automatic warmup
- **Node.js Test Runner or Vitest (Node):** Built-in test runner since Node 18 for zero dependencies, or Vitest for faster execution and better TypeScript support
- **github-action-benchmark (CI):** Already configured in ci.yml, tracks historical performance, alerts on regressions
- **Shared JSON test fixtures:** For cross-SDK contract testing, ensuring all SDKs exhibit identical behavior on same inputs

**Critical additions needed:**
- **JMH (Java benchmarking):** Currently missing, essential for proper JVM warmup (10K+ iterations required)
- **k6 (load testing):** Language-agnostic load testing with Grafana integration for system-level benchmarks

### Expected Features

Research identified 9 table stakes features (minimum for a trustworthy SDK test suite), 10 competitive differentiators (demonstrate maturity), and 7 anti-features to avoid (commonly requested but problematic).

**Must have (table stakes):**
- Operation correctness tests for all 14 operations across 5 SDKs (70 test cases minimum)
- Cross-SDK parity matrix ensuring identical behavior across all SDKs
- Error handling tests for all 30+ error codes per docs/error-codes.md
- Empty results handling (queries returning zero results must not crash)
- Input validation tests (invalid coordinates, malformed IDs, etc.)
- Basic latency metrics (p50/p95/p99 percentile reporting)
- Basic throughput metrics (operations per second under load)
- CI integration running on every PR to prevent regressions

**Should have (competitive):**
- Multi-topology testing across 1/3/5/6 node configurations to validate consensus and failover
- Performance regression detection using existing baseline system in performance-baselines.md
- Workload pattern testing (hotspots, uniform, concentrated distributions) leveraging geo_workload.zig
- Edge case fuzzing (poles, anti-meridian, zero/max radius, concave polygons)
- SDK benchmark parity ensuring no SDK is significantly slower without justification

**Defer (v2+):**
- Chaos/fault injection testing (requires substantial VOPR integration work)
- Long-running stability tests (hours-long soak tests detecting memory leaks)
- Historical trend analysis (requires long-term data collection infrastructure)

**Anti-features to avoid:**
- 100% code coverage targets (coverage != correctness, encourages trivial tests)
- Mocking the database (misses real protocol/behavior issues; use lite-config ~130MB RAM instead)
- Absolute benchmark numbers (varies by hardware; use relative PR vs main comparisons)
- Testing internal SDK implementation (couples tests to internals, breaks on refactors)

### Architecture Approach

The architecture follows a four-layer design: (1) CI/CD layer with tiered execution policies, (2) test orchestration layer with shared fixtures and scenarios, (3) SDK-specific test layer using language-native tooling, and (4) test infrastructure layer managing server harness and data generation.

**Major components:**
1. **SDK-specific tests in `src/clients/*/tests/`** — Each SDK maintains unit and integration tests using idiomatic tooling (pytest, Jest, go test, JUnit), allowing SDK maintainers to work independently
2. **Centralized integration tests in `tests/sdk/`** — Cross-SDK scenarios, shared fixtures (`canonical-events.json`), and compatibility tests ensuring behavioral consistency across SDKs
3. **Benchmark suite in `benchmarks/`** — Isolated from tests to enable different execution policies; runs on dedicated hardware or scheduled times with standardized result collection
4. **Server harness abstraction in `tests/sdk/harness/`** — Reusable start/stop/health-check scripts supporting 1/3/6 node configurations with environment variable configuration
5. **Matrix-based parallel execution** — GitHub Actions matrix strategy runs all SDK tests simultaneously, reducing total CI time from sequential ~30 minutes to parallel ~8 minutes

**Key patterns:**
- **Tiered test execution:** Smoke (every push, 5 min), PR (SDK tests on single node, 15 min), Nightly (multi-node comprehensive, 1-2 hours)
- **Shared test fixtures:** JSON test cases in `src/clients/test-data/` consumed by all SDKs for cross-SDK contract verification
- **Relative benchmarking:** Compare PR vs main on same hardware in same run to reduce CI noise impact
- **Statistical thresholds:** 5% throughput degradation = fail, 25% P99 latency degradation = fail (per performance-baselines.md)

### Critical Pitfalls

Research identified 10 critical pitfalls from industry experience and academic studies, with specific prevention strategies for each.

1. **Insufficient Benchmark Warmup** — Benchmarks report artificially slow results because JIT compilation, connection pools, and caches haven't warmed. **Prevention:** SDK-specific warmup protocols (Java: 10K+ iterations, Go: 1K, Python: 100); measure until variance <5% before starting measurement; track warmup separately.

2. **Cross-SDK Behavioral Inconsistency** — Same operation returns different results across SDKs; already observed (Python 93% pass rate, C 50%). **Prevention:** Single source of truth with golden test files; contract testing with identical test vectors across all SDKs; cross-SDK test matrix.

3. **Flaky Tests from Timing Dependencies** — Tests pass locally but fail in CI intermittently; research shows flaky tests waste 6-8 hours weekly. **Prevention:** Eliminate hardcoded sleeps; use polling with exponential backoff; CI-specific timeouts (2x local); deterministic result sorting.

4. **Benchmark Noise Masking Real Regressions** — Cloud CI shows 20-50% variance; real 10% regression invisible in noise. **Prevention:** Dedicated benchmark hardware; relative benchmarking (PR vs main in same run); statistical thresholds allowing 5% throughput / 25% P99 variance; change-point detection algorithms.

5. **Testing Single-Node When Production is Multi-Node** — All tests pass on 1-node but fail in production clusters; topology queries already documented to fail on single-node. **Prevention:** Tiered strategy (unit tests: 1-node, integration: 3-node minimum, system: 5-6 nodes); network fault injection; leader failover tests.

6. **Incomplete Mock Coverage Leading to False Confidence** — Tests pass with mocks but fail with real services; mocks don't represent edge cases. **Prevention:** Contract-based mocks generated from API specs; record/replay real responses; explicit error injection (timeouts, rate limits, auth failures); integration test layer with real server.

7. **Ignoring Tail Latencies (P99/P99.9)** — Averages look good but 1% of users have terrible experience; SLA violations occur. **Prevention:** Always report percentiles (P50, P95, P99, P99.9); don't discard outliers; histogram visualization; SLA-based testing.

8. **Coordinated Omission in Throughput Measurement** — Benchmark shows 100K ops/sec but system sustains only 10K in production; load generator waits for responses hiding backpressure. **Prevention:** Open-loop load generation (send at fixed rate regardless of response); use wrk2/Gatling open model; request timestamping; Little's Law validation.

9. **Test Data Not Representative of Production** — Tests use 1K entities, production has 1M; indexes behave differently at scale. **Prevention:** Scale-appropriate test data (quick: 1K, full: 100K, scale: 1M+); realistic distributions (geographic hotspots from geo_workload.zig); edge case inclusion; anonymized production data patterns.

10. **Missing Regression Detection Baseline** — Performance changed but no one knows if better or worse; slow degradation goes unnoticed. **Prevention:** Store historical results with git SHA/timestamp/environment; automated CI comparison (ArcherDB has this via github-action-benchmark); clear baseline update process; trend visualization.

## Implications for Roadmap

Based on research, the project naturally decomposes into 5 phases following dependency order: infrastructure foundation, SDK test development, benchmarking formalization, multi-node testing, and advanced scenarios.

### Phase 1: Test Infrastructure Foundation
**Rationale:** Must establish reusable infrastructure before writing tests; avoids flaky tests (Pitfall #3) and enables consistent server management
**Delivers:** Server harness scripts, environment variable configuration, warmup protocols, tiered CI structure
**Addresses:** Connection lifecycle tests, retry behavior tests, CI integration (table stakes features)
**Avoids:** Flaky tests from timing dependencies (Pitfall #3), hardcoded timeouts/addresses
**Research flag:** Standard patterns — server management is well-documented (skip research-phase)

### Phase 2: SDK Test Suite Development
**Rationale:** Builds on infrastructure; focuses on correctness before performance; enables cross-SDK parity detection early
**Delivers:** Operation correctness tests (14 ops x 5 SDKs), error handling tests (30+ error codes), shared JSON test fixtures, cross-SDK parity matrix
**Addresses:** Operation correctness, cross-SDK parity, error handling, input validation (4 table stakes features)
**Uses:** pytest, JUnit 5, Go testing, Node test runner, shared canonical-events.json
**Implements:** SDK-specific test layer + centralized integration tests
**Avoids:** Cross-SDK behavioral inconsistency (Pitfall #2), test data not representative of production (Pitfall #9)
**Research flag:** Needs research — error code coverage requires mapping docs/error-codes.md to test scenarios

### Phase 3: Benchmark Framework Formalization
**Rationale:** Correctness proven by Phase 2; now measure performance with statistical rigor
**Delivers:** Benchmark runners per SDK, percentile reporting (P50/P95/P99/P99.9), warmup validation, regression detection automation, baseline management
**Addresses:** Basic latency metrics, basic throughput metrics, performance regression detection (2 table stakes + 1 differentiator)
**Uses:** pytest-benchmark, JMH, go test -bench
**Implements:** Benchmark suite in `benchmarks/` with standardized result collection
**Avoids:** Insufficient warmup (Pitfall #1), ignoring tail latencies (Pitfall #7), coordinated omission (Pitfall #8), benchmark noise (Pitfall #4), missing baselines (Pitfall #10)
**Research flag:** Standard patterns — benchmarking methodology well-established in docs/benchmarks.md

### Phase 4: Multi-Node and Topology Testing
**Rationale:** Single-node correctness proven; now test distributed behavior (consensus, failover, replication)
**Delivers:** Tests for 3/5/6 node clusters, topology discovery tests, leader failover scenarios, replication lag tests
**Addresses:** Multi-topology testing, cluster operations tests (1 table stakes + 1 differentiator)
**Uses:** Existing cluster configuration support, topology endpoints
**Implements:** Multi-node test scenarios in `tests/sdk/integration/`
**Avoids:** Testing single-node when production is multi-node (Pitfall #5)
**Research flag:** Needs research — consensus edge cases and failover timing may require VOPR documentation review

### Phase 5: Advanced Testing and Edge Cases
**Rationale:** Core functionality proven; now add edge case coverage and advanced scenarios
**Delivers:** Edge case fuzzing (poles, anti-meridian, concave polygons), workload pattern testing (hotspots), SDK benchmark parity analysis, long-running stability tests
**Addresses:** Edge case fuzzing, workload pattern testing, SDK benchmark parity (differentiators)
**Uses:** geo_workload.zig adversarial patterns, k6 for load testing
**Implements:** Scenario-based testing in `tests/sdk/shared/scenarios/`
**Avoids:** Test data not representative of production (Pitfall #9)
**Research flag:** Standard patterns — geo_workload.zig already provides edge case generation patterns

### Phase Ordering Rationale

- **Infrastructure first (Phase 1):** Tests cannot be reliable without consistent server management and environment configuration; prevents flaky tests that plague later phases
- **Correctness before performance (Phases 2 then 3):** No point benchmarking incorrect behavior; SDK parity must be established before comparing performance across SDKs
- **Single-node before multi-node (Phases 2-3 then 4):** Must prove basic operations work before adding distributed system complexity; mirrors ArcherDB's own testing strategy
- **Table stakes before differentiators:** Phase 1-3 deliver all 9 table stakes features; Phases 4-5 add competitive differentiators
- **Leverage existing assets:** Phase 2 formalizes existing test scripts from SDK-TESTING-FINAL-REPORT.md; Phase 3 builds on existing benchmark.yml and performance-baselines.md; Phase 5 reuses geo_workload.zig

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2 (SDK Test Suite):** Error code coverage requires comprehensive mapping of docs/error-codes.md to reproducible test scenarios; may need protocol-level understanding
- **Phase 4 (Multi-Node Testing):** Distributed failure modes (split-brain, partial partition, leader failover timing) may require VOPR documentation review for realistic scenarios

Phases with standard patterns (skip research-phase):
- **Phase 1 (Infrastructure):** Server management, CI configuration, environment variables are well-documented in CLAUDE.md and existing scripts
- **Phase 3 (Benchmarking):** Methodology comprehensively documented in docs/benchmarks.md and docs/testing/performance-baselines.md
- **Phase 5 (Edge Cases):** geo_workload.zig already provides adversarial pattern generation; pattern is reusable

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All technologies verified in use or official docs; pytest/JUnit/Go testing already working; JMH well-documented |
| Features | HIGH | Table stakes derived from SDK-TESTING-FINAL-REPORT.md real testing experience; differentiators from industry best practices |
| Architecture | HIGH | Builds on existing monorepo structure; patterns verified in CockroachDB/Aerospike testing; matrix builds already in ci.yml |
| Pitfalls | HIGH | 10 pitfalls sourced from academic research (USENIX, ACM), industry case studies, and ArcherDB's own discovered issues |

**Overall confidence:** HIGH

All research validated against ArcherDB's existing codebase, official documentation, and recent search results. Recommended technologies are either already in use (pytest, JUnit, Go testing, github-action-benchmark) or industry-standard for their language (JMH for Java). Architecture patterns match existing infrastructure (monorepo, GitHub Actions, matrix builds). Pitfalls include several already observed in ArcherDB testing (cross-SDK inconsistency, single-node limitations).

### Gaps to Address

Research is comprehensive for the intended scope. Minor gaps to validate during implementation:

- **JVM warmup iteration count:** Research suggests 10K+ iterations for Java benchmarks; validate this is sufficient for ArcherDB's specific operations (may need empirical tuning to observe <5% variance)
- **CI runner consistency:** GitHub Actions runners show high variance; may need to experiment with larger runners or self-hosted runners if relative benchmarking doesn't sufficiently reduce noise
- **Edge case completeness:** geo_workload.zig provides adversarial patterns; verify it covers all geometric edge cases relevant to ArcherDB (poles, anti-meridian, concave polygons) or extend if needed
- **C SDK testing scope:** Current C SDK is sample code with 50% operation coverage; clarify whether to bring to parity with other SDKs or accept limited scope

## Sources

### Primary (HIGH confidence)
- `/home/g/archerdb/docs/SDK-TESTING-FINAL-REPORT.md` — Recent comprehensive testing results showing 50-93% pass rates across SDKs
- `/home/g/archerdb/docs/SDK-COMPLETENESS-FINAL.md` — Complete SDK operation matrix (14 operations x 5 SDKs)
- `/home/g/archerdb/docs/benchmarks.md` — Established benchmark methodology and target metrics
- `/home/g/archerdb/docs/testing/performance-baselines.md` — Regression detection framework with 5% throughput / 25% P99 thresholds
- `/home/g/archerdb/docs/error-codes.md` — 30+ error codes requiring test coverage
- `/home/g/archerdb/src/testing/geo_workload.zig` — Existing adversarial workload generator with edge cases
- `/home/g/archerdb/.github/workflows/ci.yml` — Existing matrix builds and github-action-benchmark integration
- [pytest-benchmark documentation](https://pytest-benchmark.readthedocs.io/) — Official docs, verified 2026-02-01
- [JMH OpenJDK](https://openjdk.org/projects/code-tools/jmh/) — Official Java microbenchmarking docs
- [Go testing package](https://pkg.go.dev/testing) — Official stdlib documentation

### Secondary (MEDIUM confidence)
- [CockroachDB Performance Testing Methodology](https://www.cockroachlabs.com/blog/database-testing-performance-under-adversity/) — Real-world database benchmarking patterns
- [Aerospike Database Benchmarking Best Practices](https://aerospike.com/blog/best-practices-for-database-benchmarking/) — Synthetic vs real benchmarks
- [Common Pitfalls in Database Performance Testing (PDF)](https://hannes.muehleisen.org/publications/DBTEST2018-performance-testing.pdf) — Academic research on benchmark methodology
- [ACM Survey of Flaky Tests](https://dl.acm.org/doi/fullHtml/10.1145/3476105) — Research showing 6-8 hour weekly cost
- [USENIX JVM Warmup Study](https://www.usenix.org/system/files/conference/osdi16/osdi16-lion.pdf) — Empirical JIT compiler warmup requirements

### Tertiary (LOW confidence)
- [Continuous Testing Benchmark Report 2025](https://testgrid.io/blog/continuous-testing-trends-2025/) — Industry trends, marketing-focused
- [Cloud CI Benchmark Reliability Analysis](https://bheisler.github.io/post/benchmarking-in-the-cloud/) — Blog post on CI noise, needs validation

---
*Research completed: 2026-02-01*
*Ready for roadmap: yes*
