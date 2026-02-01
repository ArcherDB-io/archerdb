# Phase 13: SDK Operation Test Suite - Context

**Gathered:** 2026-02-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Validate all 6 SDKs (Python, Node.js, Go, Java, C, Zig) for correctness across all 14 operations against a running ArcherDB server. This phase focuses on **functional correctness** — ensuring each SDK can successfully perform every operation with correct results. Error handling, cross-SDK parity validation, and performance benchmarking are separate phases (14, 15).

</domain>

<decisions>
## Implementation Decisions

### Test Organization Strategy
- **File structure:** Claude's discretion — choose most maintainable structure
- **Test data:** Hybrid approach — common cases use shared JSON fixtures from Phase 11 (`tests/fixtures/*.json`), SDK-specific edge cases use inline data
- **Test grouping:** Claude's discretion — organize based on debuggability and CI reporting needs
- **Test orchestration:** Unified test runner script (`tests/run_sdk_tests.sh` or similar) that runs all SDK tests with consistent reporting

### Test Execution Flow
- **SDK execution order:** Sequential — run Python tests, then Node, then Go, etc. (easier to debug, acceptable speed)
- **Server lifecycle:** Server per SDK — each SDK test suite starts/stops its own server for clean isolation
- **Data cleanup:** Fresh database per test — clear all data before each test function for maximum isolation
- **Failure handling:** Fail fast — stop entire test suite on first failure for faster feedback on critical breaks

### Success Verification Approach
- **Result verification:** Exact JSON matching — response JSON must match expected output byte-for-byte
- **Geometric validation:** Triple verification strategy:
  1. Known ground truth — fixtures have pre-computed expected results
  2. Reference implementation comparison — verify against known-good SDK
  3. Geometric assertions — verify properties (e.g., all points ARE within radius)
- **Test output detail:** Verbose with diffs — show expected vs actual with highlighted differences on any mismatch
- **Timestamp handling:** Range checks — verify timestamps are within reasonable range (e.g., within 1 second of test time)

### Test Coverage Decisions
- **Operation coverage:** Full matrix (84 tests) — all 6 SDKs test all 14 operations for comprehensive validation
- **SDK limitations policy:** **NO LIMITATIONS ALLOWED** — if an SDK cannot perform an operation, fix the SDK, the server code, or whatever is necessary. Solutions MUST be complete and consistent. No skips, no workarounds, no fake passes. 100% pass rate is non-negotiable.
- **Test scenarios:** Comprehensive — multiple test cases per operation covering common usage patterns (small/large radius, bbox crossing meridian, polygon edge cases, etc.)
- **CI tier tagging:** All tests are smoke tier — run all 84 tests on every commit

### Claude's Discretion
- Exact test file organization structure
- Test naming conventions
- How to group operations within tests for optimal CI reporting
- Specific diff formatting for verbose output

</decisions>

<specifics>
## Specific Ideas

None — discussion focused on structural decisions. Standard SDK testing approaches are appropriate.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope. Error handling (Phase 14), parity validation (Phase 14), and performance benchmarking (Phase 15) are already planned as separate phases.

</deferred>

---

*Phase: 13-sdk-operation-test-suite*
*Context gathered: 2026-02-01*
