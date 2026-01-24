---
phase: 11-measurement-profiling
plan: 01
subsystem: profiling
tags: [perf, flamegraph, cpu-profiling, hardware-counters, linux-perf]

# Dependency graph
requires: []
provides:
  - Flame graph generation script (scripts/flamegraph.sh)
  - Hardware counter profiling script (scripts/profile.sh)
  - Profiling documentation (docs/profiling.md)
affects: [11-02, 11-03, 11-04, 11-05]

# Tech tracking
tech-stack:
  added: [linux-perf, FlameGraph]
  patterns: [perf record --call-graph dwarf, perf stat with derived metrics]

key-files:
  created:
    - scripts/flamegraph.sh
    - scripts/profile.sh
  modified:
    - docs/profiling.md

key-decisions:
  - "Use --call-graph dwarf for complete stack traces"
  - "99Hz default sampling to avoid lockstep sampling"
  - "JSON output mode for CI integration"

patterns-established:
  - "CLI helper scripts: argument parsing pattern from run-perf-benchmarks.sh"
  - "Profiling workflow: build release, profile, analyze, optimize"

# Metrics
duration: 5min
completed: 2026-01-24
---

# Phase 11 Plan 01: CPU Profiling Infrastructure Summary

**Linux perf integration with flame graph generation, hardware counter profiling, and comprehensive developer documentation**

## Performance

- **Duration:** 5 min
- **Started:** 2026-01-24T05:54:17Z
- **Completed:** 2026-01-24T05:59:12Z
- **Tasks:** 3/3
- **Files modified:** 3

## Accomplishments

- Flame graph generation wrapper script wrapping Linux perf and FlameGraph tools
- Hardware counter profiling script with IPC, cache miss rate, and branch miss rate calculations
- Comprehensive profiling documentation with prerequisites, workflows, and troubleshooting

## Task Commits

Each task was committed atomically:

1. **Task 1: Create flame graph helper script** - `1c49034` (feat)
2. **Task 2: Create CPU profiling helper script** - `eeca518` (feat)
3. **Task 3: Create profiling documentation** - `1c8f29f` (docs)

## Files Created/Modified

- `scripts/flamegraph.sh` - Flame graph generation wrapping perf record and FlameGraph scripts
- `scripts/profile.sh` - Hardware counter profiling with perf stat and derived metrics
- `docs/profiling.md` - Developer documentation with quick start, workflows, and troubleshooting

## Decisions Made

- **--call-graph dwarf**: Used dwarf unwind for complete stack traces (frame pointers already preserved in build.zig)
- **99Hz default sampling**: Avoids lockstep sampling patterns that can skew results
- **JSON output mode**: Added to profile.sh for CI integration and automated analysis
- **Auto-detect FlameGraph location**: Checks FLAMEGRAPH_DIR env, tools/FlameGraph, and /usr/share/FlameGraph

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required. Users need to:
1. Install perf (`apt install linux-perf`)
2. Clone FlameGraph scripts (`git clone https://github.com/brendangregg/FlameGraph.git tools/FlameGraph`)

## Next Phase Readiness

- CPU profiling infrastructure complete
- Ready for POOP A/B benchmarking integration (Plan 11-02)
- Scripts ready for use in performance optimization workflow

---
*Phase: 11-measurement-profiling*
*Completed: 2026-01-24*
