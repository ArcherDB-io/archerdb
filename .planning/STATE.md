# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-24)

**Core value:** Correctness, performance, and completeness with no compromises
**Current focus:** v2.0 Performance & Scale - Phase 12 Storage Optimization in progress

## Current Position

Phase: 12 of 16 (Storage Optimization)
Plan: 5 of 8 in current phase
Status: In progress
Last activity: 2026-01-24 - Completed 12-04-PLAN.md (Latency-Driven Compaction Throttling)

Progress: [████░░░░░░] 34% (v2.0: 12/35 requirements)

## v1.0 Summary

**Shipped:** 2026-01-23
**Phases:** 1-10 (39 plans)
**Requirements:** 234 satisfied

See `.planning/MILESTONES.md` for full milestone record.
See `.planning/milestones/v1.0-ROADMAP.md` for archived roadmap details.
See `.planning/milestones/v1.0-REQUIREMENTS.md` for archived requirements.

## Performance Metrics

**Velocity:**
- Total plans completed: 7 (v2.0)
- Average duration: ~5min
- Total execution time: ~39min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 11 | 5 | ~27min | ~5min |
| 12 | 5 | ~27min | ~5min |

**Recent Trend:**
- Last 5 plans: 11-05, 12-01, 12-02, 12-03, 12-05
- Trend: ~5-6min per plan

*Updated after each plan completion*

## Accumulated Context

### Decisions

Key decisions from v1.0 logged in PROJECT.md.

v2.0 decisions:
- Measurement-first approach: All optimization work requires profiling data
- Phase order follows dependency/risk: low-risk measurement -> medium-risk storage/memory -> high-risk consensus/sharding
- Breaking changes grouped in Phase 16 for coordinated v2.0 release

Phase 11 decisions:
- --call-graph dwarf for complete stack traces with perf
- 99Hz default sampling to avoid lockstep patterns
- JSON output mode for CI integration in profiling scripts
- POOP over hyperfine for hardware counter access (cycles, cache misses, branches)
- 5% threshold for statistical significance in A/B comparisons
- Tracy on-demand mode for zero overhead when profiler not connected
- No-op fallback design for Tracy zones (compile to nothing when disabled)
- Semantic color scheme for subsystems (query=green, storage=blue, etc)
- Parca via eBPF for production continuous profiling (<1% overhead)
- Profile builds use ReleaseFast with frame pointers
- Simple allocator wrapper pattern over direct DebugAllocator embedding (11-03)
- ExtendedStats struct outside HistogramType for reusability (11-03)
- IQR method for outlier removal in statistical analysis (11-04)
- 2 stddev threshold for regression detection (11-04)
- Artifact-based baseline storage for CI benchmarks (11-04)

Phase 12 decisions:
- 90% compression threshold: Only compress if savings exceed 10% (12-01)
- CompressionType stored as u8 with 4-bit enum for future expansion (12-01)
- Index blocks stay uncompressed for fast key lookups (12-01)
- Scale ratios by 100 or 1000 for Gauge i64 precision (12-02)
- Array of atomics per level using constants.lsm_levels (12-02)
- Rolling window metrics: 1min, 5min, 1hr standard observability windows (12-02)
- Tiered as default compaction strategy for write-heavy geospatial workloads (12-05)
- Size ratio 2.0x for balanced write amplification trigger (12-05)
- 200% space amplification threshold before forced compaction (12-05)
- 10 max sorted runs per level to bound read amplification (12-05)
- prefer_partial_compaction=true for better tail latency (12-05)
- TiKV-style predictive throttling with pending bytes as primary signal (12-04)
- Reactive P99 fallback (50/100ms thresholds) for cases where pending bytes is insufficient (12-04)
- Hysteresis (10ms) and 3 consecutive good checks required to prevent oscillation (12-04)

### Pending Todos

None.

### Blockers/Concerns

None.

**Known limitations carried forward:**
- ~90 TODOs remain in infrastructure code (Zig language limitations)
- Antimeridian polygon queries require splitting at 180 meridian
- Snapshot verification for manifest/free_set/client_sessions is future work

## Session Continuity

Last session: 2026-01-24
Stopped at: Completed 12-04-PLAN.md (Latency-Driven Compaction Throttling)
Resume file: None

---
*Updated: 2026-01-24 — Phase 12 plan 04 complete (latency-driven compaction throttling)*
