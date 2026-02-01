# Phase 11: Test Infrastructure Foundation - Context

**Gathered:** 2026-02-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Building reliable infrastructure to start/stop ArcherDB clusters programmatically (1/3/5/6 nodes), generate test data with various distribution patterns, create comprehensive shared test fixtures, and configure tiered CI execution (smoke/PR/nightly).

</domain>

<decisions>
## Implementation Decisions

### Server Harness Interface
- **API approach**: Both programmatic library AND CLI wrapper
  - Library for importing into test code (Python/Node/Go/Java/C/Zig)
  - CLI for manual testing and debugging
- **Port allocation**: Auto-allocate ports (find available ports automatically for parallel-safe execution)
- **Lifecycle visibility**: Expose all lifecycle events
  - Health checks (wait for cluster ready, check node health)
  - Leader election detection (identify leader, wait for election complete)
  - Log access (capture server logs for debugging failed tests)
- **Cleanup behavior**: Environment variable control
  - Default: Always cleanup (clean slate)
  - `PRESERVE_ON_FAILURE=1` to preserve clusters for local debugging
  - CI always cleans up (no env var override in CI)

### CI Tier Strategy
- **Smoke tests (<5 min)**: Fast validation catching obvious breaks
  - Build + unit tests (compilation, unit tests pass)
  - Single operation per SDK (one insert test per SDK - proves connectivity)
  - Single-node only (no multi-node - too slow)
- **PR tests (<15 min)**: Comprehensive PR validation
  - All operations in one SDK (full suite in Python - fastest)
  - Critical ops in all SDKs (insert/query/delete across all 6)
  - Error handling tests (connection failures, timeouts, validation)
- **Nightly full suite**: Complete validation
  - All operations in all SDKs (84 test matrix)
  - Multi-node testing (3/5/6 node clusters)
  - Benchmarks run nightly (performance baselines integrated)
- **Flaky test handling**: Fail fast (no retries)
  - Flaky tests must be fixed, not masked by retries
  - Forces test reliability improvement

### Test Fixtures Format
- **Comprehensiveness**: Exhaustive coverage
  - Every boundary condition documented
  - All error codes represented
  - Edge cases included (poles, anti-meridian, empty results)
- **Content structure**: Input + output pairs (golden files)
  - Request and expected response for contract testing
  - Enables cross-SDK parity validation
- **Organization**: By operation (14 separate files)
  - `insert.json`, `query-radius.json`, etc.
  - One file per operation for easy navigation
- **Versioning**: Version subdirectories + git history
  - `v1/insert.json`, `v2/insert.json` for protocol evolution
  - Git history tracks changes within versions
  - Enables compatibility testing across protocol versions

### Test Data Generation
- **City selection**: Both major metros AND geographic diversity
  - Top 10-20 global cities (NYC, London, Tokyo, etc.)
  - Geographic coverage across continents, timezones, hemispheres
  - Ensures edge cases (southern hemisphere, dateline crossing, etc.)
- **Concentration patterns**: Multiple datasets for different scenarios
  - Gaussian clusters (80% in city, 20% suburbs/edges)
  - Realistic density (match actual population maps)
  - Hotspot stress (95%+ extreme concentration for worst case)
- **Dataset sizes**: All sizes supported (parameterizable)
  - Small (100-1K events): Quick smoke tests, debugging
  - Medium (10K-100K): Realistic workload simulation
  - Large (1M+): Stress testing, benchmark validation
- **Randomness**: Test both deterministic and truly random
  - Deterministic (seeded RNG): Reproducible for debugging
  - Truly random: Catches edge cases, different data every run
  - Configurable via flag or parameter

### Claude's Discretion
- Exact harness implementation language (Python/Shell/Zig - whatever integrates best)
- Specific health check implementation (ping vs status vs custom)
- Log capture format and rotation strategy
- Fixture JSON schema details (as long as comprehensive and parseable)

</decisions>

<specifics>
## Specific Ideas

- CI tier design should prevent "works on my machine" - smoke tests gate PRs strictly
- Fail-fast on flaky tests forces reliability improvements rather than masking problems
- Exhaustive fixtures enable true cross-SDK parity validation (same input = same output across all 6 SDKs)
- Multiple concentration patterns stress different query patterns (uniform for joins, concentrated for hotspots)
- Version subdirectories critical for protocol evolution - can test backwards compatibility

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope

</deferred>

---

*Phase: 11-test-infrastructure-foundation*
*Context gathered: 2026-02-01*
