# Phase 1: Critical Bug Fixes - Context

**Gathered:** 2026-01-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Fix four blocking bugs that prevent production deployment:
1. Readiness probe returns 503 (should return 200 within 30 seconds)
2. Data doesn't persist across server restarts in production config
3. Server fails handling 100 concurrent clients (currently fails at 10)
4. TTL cleanup removes 0 entries (should remove expired entries)

This phase is purely bug fixes - making existing functionality work correctly. No new features or capabilities.

</domain>

<decisions>
## Implementation Decisions

### Debugging approach
- **Method flexibility:** Claude decides per bug whether to write tests first or debug live system first
- **Logging:** Add comprehensive, detailed logging that stays in codebase for future debugging (not temporary)
- **Reproduction scripts:** Create standalone reproduction scripts for all 4 bugs
- **TTL investigation:** Check existing tests first (before implementation) to understand if tests are inadequate or implementation diverged

### Testing strategy
- **Test coverage:** Unit + integration + end-to-end tests for each bug fix
- **Regression tests:** Every bug fix must include a regression test to prevent recurrence
- **Concurrency threshold:** Test beyond 100 clients (stress test to find new breaking points, not just meet minimum)
- **Test configuration:** Run tests in both dev mode AND production config to catch config-specific bugs
- **Resource constraints:** Follow CLAUDE.md guidelines (use `-j4 -Dconfig=lite` for constrained testing)

### Verification methods
- **Readiness probe:** Both automated tests AND manual verification (curl endpoint)
- **Persistence verification:** Stress test approach - write large dataset, restart, verify full dataset intact
- **Full validation:** Re-run entire DATABASE_VALIDATION_CHECKLIST.md after each fix to catch regressions immediately
- **Done criteria:** Tests pass AND Phase 1 success criteria met (e.g., actually handle 100+ concurrent clients, not just stop failing at 10)

### Fix sequencing
- **Order:** Fix readiness probe and persistence FIRST (they block testing), then concurrent clients and TTL cleanup in any order
- **Commits:** One atomic commit per bug fix (4 separate commits) for clean history
- **New bugs discovered:** Fix immediately if found during Phase 1 work (expand scope to include blocking/critical issues)
- **Cleanup:** Opportunistic refactoring allowed - if code touched is clearly messy, clean it up

### Claude's Discretion
- Choosing test-first vs debug-first per bug based on efficiency
- Specific logging implementation details
- Exact concurrency level to test beyond 100
- When to run which parts of validation checklist
- Assessment of whether newly-discovered bugs are blocking/critical

</decisions>

<specifics>
## Specific Ideas

- Use reproduction scripts to validate fixes reliably - should fail before fix, pass after
- Comprehensive logging means future debugging is easier (worth the upfront investment)
- Stress testing concurrency beyond 100 helps find the next breaking point proactively
- Testing in both dev and production configs prevents "works on my machine" issues
- Running full validation after each fix catches regressions early (fail fast principle)

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope (fixing existing bugs only).

</deferred>

---

*Phase: 01-critical-bug-fixes*
*Context gathered: 2026-01-29*
