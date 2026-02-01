# Phase 18: CI Integration & Documentation - Context

**Gathered:** 2026-02-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Automated CI pipelines that run smoke tests on every push, full PR validation, and nightly comprehensive suites. Weekly benchmark automation with regression detection. Comprehensive documentation suite covering SDK usage, testing guide, benchmark guide, protocol/curl examples, and SDK comparison matrix.

</domain>

<decisions>
## Implementation Decisions

### CI Pipeline Structure
- **Platform:** GitHub Actions (workflow files in .github/workflows/)
- **Organization:** Separate workflow files for each tier (smoke.yml, pr-full.yml, nightly.yml)
- **Triggers:**
  - Smoke: Every push to main
  - PR full: On pull_request events
  - Nightly: Scheduled cron at 2 AM UTC
- **Hardware:** GitHub hosted runners
  - Smoke/PR: ubuntu-latest (2 cores, 7GB)
  - Nightly: ubuntu-latest-4-cores for heavier multi-node tests

### Test Execution Strategy
- **Parallelization:** Matrix strategy per SDK - all 6 SDKs run in parallel jobs
- **Failure handling:** Always fail-fast - stop immediately on first test failure in all tiers
- **Artifacts:** Upload test reports (JUnit XML) + coverage data as GitHub artifacts for all runs
- **Flaky tests:** No retries - tests fail immediately, use `@pytest.mark.flaky` or equivalent to track known flakes separately

### Documentation Organization
- **Code example depth:** Comprehensive - show each operation in all 6 SDKs (Python, Node, Go, Java, C, Zig)
- **SDK comparison:** Yes - include feature parity matrix table showing which SDKs support which features, link to Phase 14 parity docs
- **Versioning:** No versioning yet - single doc set for v1.1 only, defer versioning until v2.0 breaking changes

### Benchmark Automation
- **Schedule:** Weekly Sunday 2 AM UTC (consistent timing, off-peak hours)
- **Hardware:** GitHub hosted ubuntu-latest-8-cores (simpler than self-hosted, acceptable noise for trend tracking)
- **Result storage:** GitHub artifacts + commit JSON to benchmarks/history/YYYY-MM-DD.json in repo
- **Regression alerts:** Comment on commit with regression details + fail workflow (visible and blocks automation)

### Claude's Discretion
- Documentation file structure (single docs/ directory vs distributed in-tree)
- Exact workflow job dependencies and caching strategies
- Artifact retention policies
- CI optimization (caching, dependency installation)

</decisions>

<specifics>
## Specific Ideas

- Align with Phase 11 CI tier definitions (smoke <5min, PR <15min, nightly 2h)
- Reference Phase 14 parity matrix for SDK comparison documentation
- Use Phase 15 regression threshold (10%) for benchmark alerting
- Build on Phase 12 curl examples and Phase 17 historical tracking

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope

</deferred>

---

*Phase: 18-ci-documentation*
*Context gathered: 2026-02-01*
