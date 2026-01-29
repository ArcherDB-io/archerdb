---
phase: 01-critical-bug-fixes
plan: 03
subsystem: database
tags: [ttl, cleanup, expiration, cache-invalidation, python-sdk]

# Dependency graph
requires:
  - phase: 01-01
    provides: Test infrastructure and readiness/persistence validation
  - phase: 01-02
    provides: Lite config with 32KB message_size_max
provides:
  - TTL cleanup removes expired entries (entries_scanned > 0, entries_removed > 0)
  - Python SDK cleanup_expired() sends actual requests to server
  - Query result cache invalidated when entries are removed
  - TTL cleanup test script for validation
affects: [02-performance, testing-infrastructure, client-sdks]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Query result cache invalidation on data mutation (write/delete/cleanup)"
    - "Rebuild client libraries with matching config before testing"

key-files:
  created: []
  modified:
    - scripts/test-ttl-cleanup.sh
    - src/clients/python/src/archerdb/_native.py
    - src/clients/python/src/archerdb/client.py
    - src/geo_state_machine.zig
    - src/tidy.zig

key-decisions:
  - "Root cause was two-fold: Python SDK stub + missing cache invalidation"
  - "Client libraries must be rebuilt with matching config (lite vs production)"
  - "Cache invalidation added to cleanup_expired on entries_removed > 0"

patterns-established:
  - "Query result cache must be invalidated on any data mutation"
  - "Test scripts should rebuild client libraries to ensure config match"

# Metrics
duration: 14min
completed: 2026-01-29
---

# Phase 01 Plan 03: TTL Cleanup Bug Fix Summary

**Python SDK cleanup_expired implemented, query cache invalidation added - entries_scanned=10000, entries_removed=1 verified**

## Performance

- **Duration:** 14 min
- **Started:** 2026-01-29T07:16:44Z
- **Completed:** 2026-01-29T07:31:32Z
- **Tasks:** 3 (investigation + fix + validation merged into single commit)
- **Files modified:** 5

## Accomplishments

- Identified root cause: Python SDK cleanup_expired() was returning stub (0,0) instead of sending actual requests
- Fixed Python SDK to properly send CLEANUP_EXPIRED operation and parse response
- Added query result cache invalidation in execute_cleanup_expired when entries are removed
- Updated test script to rebuild client libraries with matching config
- Verified: entries_scanned=10000, entries_removed=1, query returns None after cleanup

## Task Commits

The investigation, fix, and validation were completed as a single atomic commit due to their interdependence:

1. **Fix: TTL cleanup** - `50dc812` (fix)
   - Python SDK stub replaced with actual implementation
   - Cache invalidation added to geo_state_machine.zig
   - Test script updated to rebuild client libraries
   - Tidy allowlist updated for test-concurrent-clients.sh

## Files Created/Modified

- `src/clients/python/src/archerdb/_native.py` - Added cleanup_expired method implementation
- `src/clients/python/src/archerdb/client.py` - Use native cleanup_expired instead of stub
- `src/geo_state_machine.zig` - Cache invalidation after TTL cleanup removes entries
- `scripts/test-ttl-cleanup.sh` - Rebuild client libs, improved output messages
- `src/tidy.zig` - Register test-concurrent-clients.sh in executable allowlist

## Decisions Made

1. **Two-fold root cause:** The original CRIT-04 bug was actually caused by two separate issues:
   - Python SDK had stub implementation returning (0, 0)
   - After rebuilding with correct config, entity still queryable due to missing cache invalidation

2. **Client library config match:** Client libraries (Python, etc.) must be compiled with the same config as the server. Mismatch between lite (32KB) and production (10 MiB) message_size_max causes silent failures.

3. **Cache invalidation pattern:** Query result cache must be invalidated whenever data changes - added to cleanup_expired following the same pattern as insert/delete operations.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Query cache invalidation after cleanup**
- **Found during:** Task 2 (Fix TTL cleanup bug)
- **Issue:** After cleanup removed entry, query still returned data from cache
- **Fix:** Added `result_cache.invalidateAll()` in execute_cleanup_expired when entries_removed > 0
- **Files modified:** src/geo_state_machine.zig
- **Verification:** Query returns None after cleanup
- **Committed in:** 50dc812

**2. [Rule 3 - Blocking] Tidy test failure for test-concurrent-clients.sh**
- **Found during:** Task 3 (Run unit tests)
- **Issue:** test-concurrent-clients.sh not in executable allowlist
- **Fix:** Added to executable_files in tidy.zig
- **Files modified:** src/tidy.zig
- **Verification:** Tidy permissions test passes
- **Committed in:** 50dc812

---

**Total deviations:** 2 auto-fixed (1 missing critical, 1 blocking)
**Impact on plan:** Both auto-fixes necessary for correctness. No scope creep.

## Issues Encountered

1. **Initial panic in client:** First test run panicked due to batch_size_limit assertion. This was caused by client library being compiled with production config (10 MiB) while server used lite config (32 KB). Fixed by rebuilding client library.

2. **Known test failure:** vsr.replica_test.test.Cluster:smoke fails due to 32KB block_size assumption in test infrastructure (documented in 01-02).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- CRIT-04 (TTL Cleanup) is now fixed
- All four critical bugs from Phase 1 are resolved:
  - CRIT-01: Readiness probe returns 200 within 2 seconds
  - CRIT-02: Data persistence works across restarts
  - CRIT-03: Concurrent clients (64) supported in lite config
  - CRIT-04: TTL cleanup removes expired entries
- Phase 1 is ready for completion
- Ready to proceed with Phase 2 (Performance)

### Notes for Future Work

- Consider adding cleanup_expired implementation to Node.js SDK (currently stubbed)
- Consider adding cleanup_expired implementation to Java SDK
- Test infrastructure (Cluster:smoke) needs update for 32KB block_size

---
*Phase: 01-critical-bug-fixes*
*Completed: 2026-01-29*
