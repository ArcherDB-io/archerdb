---
phase: 11-test-infrastructure-foundation
plan: 02
subsystem: testing
tags: [json-fixtures, ci-workflows, github-actions, warmup-protocols, cross-sdk-parity]

# Dependency graph
requires:
  - phase: 11-01
    provides: test infrastructure harness and data generators
provides:
  - 14 JSON test fixtures for all ArcherDB operations
  - Tiered CI workflows (smoke <5min, PR <15min, nightly)
  - Per-SDK warmup protocols for stable benchmarks
  - Fixture loader utility for SDK tests
  - CI workflow validation script
affects: [12-python-sdk, 13-node-sdk, 14-go-sdk, 15-java-sdk, 16-c-sdk, benchmark-harness]

# Tech tracking
tech-stack:
  added: [pyyaml]
  patterns: [golden-file-testing, ci-tier-tagging, warmup-protocol-pattern]

key-files:
  created:
    - test_infrastructure/fixtures/v1/*.json
    - test_infrastructure/fixtures/fixture_loader.py
    - test_infrastructure/ci/warmup_protocols.json
    - test_infrastructure/ci/warmup_loader.py
    - test_infrastructure/ci/validate_workflows.py
    - .github/workflows/sdk-smoke.yml
    - .github/workflows/sdk-pr.yml
    - .github/workflows/sdk-nightly.yml
  modified: []

key-decisions:
  - "Used underscore directory (test_infrastructure/) to match 11-01 existing structure"
  - "14 fixtures organized by operation with smoke/pr/nightly tags per CONTEXT.md"
  - "Warmup iterations: Java 500 > Node 200 > Python/Go 100 > C 50 (JIT characteristics)"
  - "Nightly runs at 2 AM UTC with 1/3/5 node matrix"

patterns-established:
  - "Fixture format: operation, version, cases[] with tags for CI tier filtering"
  - "CI tier tags: smoke (connectivity), pr (full suite), nightly (stress/multi-node)"
  - "SDK warmup: protocol JSON + loader utility pattern for benchmark stability"

# Metrics
duration: 11min
completed: 2026-02-01
---

# Phase 11 Plan 02: CI Tier Workflows and Test Fixtures Summary

**JSON test fixtures for all 14 operations with hotspot stress tests, tiered CI workflows (<5min smoke, <15min PR, nightly full), and per-SDK warmup protocols for stable benchmarks**

## Performance

- **Duration:** 11 min
- **Started:** 2026-02-01T05:46:36Z
- **Completed:** 2026-02-01T05:57:26Z
- **Tasks:** 3
- **Files modified:** 24

## Accomplishments
- Created comprehensive JSON fixtures for all 14 ArcherDB operations (79 test cases total)
- Configured tiered CI workflows enforcing strict time budgets per CONTEXT.md
- Defined per-SDK warmup protocols accounting for JIT vs native compilation characteristics
- Built fixture loader and validation utilities enabling cross-SDK parity testing

## Task Commits

Each task was committed atomically:

1. **Task 1: Create JSON test fixtures for all 14 operations** - `95f71a6` (feat)
2. **Task 2: Configure tiered CI workflows and warmup protocols** - `c86bd61` (feat)
3. **Task 3: Validate CI workflows and fixture loading** - `9c51120` (feat)

## Files Created/Modified

**Fixtures (14 files):**
- `test_infrastructure/fixtures/v1/insert.json` - Insert operation with hotspot batch (14 cases)
- `test_infrastructure/fixtures/v1/upsert.json` - Upsert with update vs create (4 cases)
- `test_infrastructure/fixtures/v1/delete.json` - Delete with not-found handling (4 cases)
- `test_infrastructure/fixtures/v1/query-uuid.json` - UUID lookup (4 cases)
- `test_infrastructure/fixtures/v1/query-uuid-batch.json` - Batch UUID lookup (5 cases)
- `test_infrastructure/fixtures/v1/query-radius.json` - Radius query with hotspot (10 cases)
- `test_infrastructure/fixtures/v1/query-polygon.json` - Polygon query with hotspot (9 cases)
- `test_infrastructure/fixtures/v1/query-latest.json` - Latest events query (5 cases)
- `test_infrastructure/fixtures/v1/ping.json` - Connectivity check (2 cases)
- `test_infrastructure/fixtures/v1/status.json` - Server status (3 cases)
- `test_infrastructure/fixtures/v1/ttl-set.json` - Set TTL (5 cases)
- `test_infrastructure/fixtures/v1/ttl-extend.json` - Extend TTL (4 cases)
- `test_infrastructure/fixtures/v1/ttl-clear.json` - Clear TTL (4 cases)
- `test_infrastructure/fixtures/v1/topology.json` - Cluster topology (6 cases)
- `test_infrastructure/fixtures/README.md` - Usage documentation

**CI Workflows:**
- `.github/workflows/sdk-smoke.yml` - 5 min smoke tests on every push
- `.github/workflows/sdk-pr.yml` - 15 min PR tests with SDK matrix
- `.github/workflows/sdk-nightly.yml` - 2h nightly with 1/3/5 node matrix

**Warmup & Validation:**
- `test_infrastructure/ci/warmup_protocols.json` - Per-SDK iteration counts
- `test_infrastructure/ci/warmup_loader.py` - Protocol loader utility
- `test_infrastructure/ci/validate_workflows.py` - Workflow validation
- `test_infrastructure/ci/__init__.py` - CI module exports
- `test_infrastructure/fixtures/fixture_loader.py` - Fixture loader utility
- `test_infrastructure/fixtures/__init__.py` - Fixtures module exports

## Decisions Made

1. **Directory naming**: Used `test_infrastructure/` (underscore) to maintain consistency with 11-01 existing structure, even though plan specified hyphenated path
2. **Fixture tag distribution**: 14 smoke, 31 PR, 34 nightly - smoke tests basic connectivity, PR covers error handling, nightly handles stress/boundary
3. **Warmup iteration scaling**: Java 500 > Node 200 > Python/Go 100 > C 50 based on JIT vs AOT compilation characteristics
4. **Hotspot stress tests**: Added to insert, query-radius, query-polygon fixtures (95%+ concentration at Times Square coordinates)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Path inconsistency with existing 11-01 structure**
- **Found during:** Task 1 (fixture creation)
- **Issue:** Plan specified `test-infrastructure/` (hyphen) but 11-01 already created `test_infrastructure/` (underscore)
- **Fix:** Used underscore path to maintain consistency, moved files accordingly
- **Files modified:** All fixture and CI files in test_infrastructure/
- **Verification:** Import paths work, git history clean
- **Committed in:** 95f71a6 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Path adjustment necessary for module imports to work. No scope creep.

## Issues Encountered
- Directory naming mismatch between plan and existing 11-01 structure - resolved by adopting existing convention

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Fixtures ready for SDK integration tests (Phase 12-17)
- CI workflows ready for SDK test matrices
- Warmup protocols ready for benchmark harness integration
- Fixture loader provides consistent API for all 5 SDKs

---
*Phase: 11-test-infrastructure-foundation*
*Completed: 2026-02-01*
