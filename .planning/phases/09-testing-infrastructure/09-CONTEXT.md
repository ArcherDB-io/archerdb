# Phase 9: Testing Infrastructure - Context

**Gathered:** 2026-01-31
**Status:** Ready for planning

<domain>
## Phase Boundary

Comprehensive test coverage ensuring ongoing reliability. Unit tests pass 100% with no flaky tests, VOPR fuzzing runs 10+ seeds clean, chaos tests pass consistently, multi-node E2E tests cover all client operations, and performance regression tests detect degradation.

</domain>

<decisions>
## Implementation Decisions

### Test Organization
- Follow Zig and TigerBeetle conventions for test location and structure
- Tests live alongside source code per Zig standard practice
- Category labeling follows TigerBeetle patterns (Claude to determine exact approach)
- Test filtering granularity determined by zig test --filter capabilities

### Flakiness Handling
- Any intermittent failure = flaky test (zero tolerance definition)
- Immediate fix required when flaky test discovered — no quarantine, no skip, block merges
- Timing assertions use tick-based approach (already established in phases 2-4)
- Fixed seeds for deterministic reproducibility (pattern established: seed 42)

### CI Integration
- Full test suite runs on every PR (comprehensive coverage prioritized)
- Chaos and VOPR tests run on every PR (catches issues early)
- Maximum CI time: 60 minutes acceptable
- Matrix strategy: split test categories across parallel CI runners

### Regression Thresholds
- Throughput: Alert if drops more than 5% from baseline (tight threshold)
- Latency: Alert if P99 increases more than 25% from baseline (P99 > 1.25x)
- Baselines: Locked at each release, compare against known-good version
- Block policy: Performance regressions block merge (must fix or justify)

### Claude's Discretion
- Test manifest format (whether to create explicit mapping or rely on self-documenting tests)
- Exact test filtering implementation based on zig test capabilities
- Seed policy implementation details (already using fixed seed 42 pattern)
- Tick-based timing implementation (follow existing patterns from phases 2-4)

</decisions>

<specifics>
## Specific Ideas

- "Follow the zig convention" and "Follow the zig and tigerbeetle convention" — tests should feel native to the Zig ecosystem and consistent with TigerBeetle patterns
- Strict no-flakiness policy reflects deterministic testing philosophy already in codebase
- 5% throughput threshold accounts for observed 5% CV in benchmarks (STATE.md)
- Release-based baselines provide stable comparison points for regression detection

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 09-testing-infrastructure*
*Context gathered: 2026-01-31*
