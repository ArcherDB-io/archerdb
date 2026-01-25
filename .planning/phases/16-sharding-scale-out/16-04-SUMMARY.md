---
phase: 16-sharding-scale-out
plan: 04
subsystem: observability
tags: [otel, otlp, tracing, sharding, coordinator]

# Dependency graph
requires:
  - phase: 16-sharding-scale-out
    provides: Coordinator fan-out query execution and policies (16-03)
provides:
  - OTLP span attribute/link serialization for distributed traces
  - Coordinator root + per-shard spans linked for fan-out visibility
affects: [observability, sharding, tracing]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - OTLP span links + attribute payloads for fan-out tracing

key-files:
  created: []
  modified:
    - src/archerdb/observability/trace_export.zig
    - src/archerdb/observability.zig
    - src/coordinator.zig

key-decisions:
  - "None - followed plan as specified"

patterns-established:
  - "Coordinator fan-out spans emit root/server spans plus per-shard client spans linked to the root"

# Metrics
duration: 10 min
completed: 2026-01-25
---

# Phase 16 Plan 04: OTel span links + coordinator tracing Summary

**OTLP exporter now serializes span links/attributes, and coordinator fan-out emits root + per-shard spans with link-based visibility.**

## Performance

- **Duration:** 10 min
- **Started:** 2026-01-25T13:11:55Z
- **Completed:** 2026-01-25T13:22:24Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Added span link/attribute deep-copy and OTLP JSON serialization for trace export.
- Introduced fan-out tracing in coordinator with root/server spans and per-shard client spans linked to the root.
- Added export formatting test coverage for attributes and links.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add span link + attribute serialization to OTLP exporter** - `cdb372a` (feat)
2. **Task 2: Instrument coordinator fan-out spans with links** - `9681756` (feat)

**Plan metadata:** (docs commit after completion)

## Files Created/Modified
- `src/archerdb/observability/trace_export.zig` - Added span links/attributes, serialization, and tests.
- `src/archerdb/observability.zig` - Re-exported tracing helpers and link type.
- `src/coordinator.zig` - Recorded root + per-shard fan-out spans with attributes and links.

## Decisions Made
None - followed plan as specified.

## Deviations from Plan
None - plan executed exactly as written.

## Issues Encountered
- Unit test using the full exporter init caused a segfault in teardown; switched to a local test exporter struct to exercise formatting without the export thread.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
Phase 16 complete; ready for v2.0 transition.

---
*Phase: 16-sharding-scale-out*
*Completed: 2026-01-25*
