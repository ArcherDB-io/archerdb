# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-24)

**Core value:** Correctness, performance, and completeness with no compromises
**Current focus:** v2.0 Performance & Scale - Phase 13 (Memory & RAM Index) in progress

## Current Position

Phase: 13 of 16 (Memory & RAM Index)
Plan: 03 of 05 in current phase (13-02 and 13-03 complete, wave 1 done)
Status: In progress - wave 1 complete
Last activity: 2026-01-24 - Completed 13-02-PLAN.md (SIMD Batch Lookup)

Progress: [█████░░░░░] 54% (v2.0: 15/35 requirements)

## v1.0 Summary

**Shipped:** 2026-01-23
**Phases:** 1-10 (39 plans)
**Requirements:** 234 satisfied

See `.planning/MILESTONES.md` for full milestone record.
See `.planning/milestones/v1.0-ROADMAP.md` for archived roadmap details.
See `.planning/milestones/v1.0-REQUIREMENTS.md` for archived requirements.

## Performance Metrics

**Velocity:**
- Total plans completed: 15 (v2.0)
- Average duration: ~6min
- Total execution time: ~87min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 11 | 5 | ~27min | ~5min |
| 12 | 9 | ~49min | ~5min |
| 13 | 4 | ~26min | ~7min |

**Recent Trend:**
- Last 5 plans: 12-11, 13-01, 13-02, 13-03, 13-02 (simd)
- Trend: ~6min per plan

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
- XxHash64 from Zig stdlib for block deduplication (no external dependency) (12-07)
- Per-level bounded dedup index with LRU eviction (64 MiB default per level) (12-07)
- Module-level dedup exports for compaction integration flexibility (12-07)
- Decompress at read callback for transparent block handling (12-03)
- In-memory header update after decompression for downstream compatibility (12-03)
- Grid buffer as source for decompression (avoid extra allocation) (12-03)
- Dual trigger for adaptive compaction: write throughput change AND space amp required (12-06)
- EMA smoothing (alpha=0.1) for workload statistics (12-06)
- Workload classification: 70% threshold for write/read heavy, 30% for scan heavy (12-06)
- Guardrails: L0 trigger 2-20, compaction threads 1-4 (12-06)
- Adaptive compaction enabled by default (just works philosophy) (12-06)
- Operator overrides take precedence over adaptive values (12-06)
- Health status calculation: composite score from write amp + space amp + throttle state (12-08)
- Write amplification thresholds: <3 green, 3-5 yellow, >5 red (12-08)
- Space amplification thresholds: <2 green, 2-3 yellow, >3 red (12-08)
- 17 alert rules covering write amp, latency, space amp, disk, compaction, compression, emergency (12-08)
- Alert severity mapping: info (informational), warning (degradation), critical (action required) (12-08)
- Fallback estimation mode when archerdb binary unavailable for CI flexibility (12-10)
- zlib compression as proxy for zstd in estimation mode (12-10)
- Theoretical LSM-tree model for compaction estimation without runtime (12-10)
- Integration test patterns simulate workload shifts via sample() calls with varying op mixes (12-11)

Phase 13 decisions:
- Split u128 keys into high/low u64 halves for SIMD (u128 too wide for most SIMD registers) (13-02)
- Batch size of 4 keys (64 bytes = one cache line) for SIMD operations (13-02)
- @Vector(4, u64) pattern for portable SIMD across AVX2/SSE/NEON (13-02)
- Per-operation counters vs lazy update: counters increment per lookup/insert, gauges lazy-update on scrape (13-03)
- Unconditional Prometheus recording: metrics recorded regardless of track_stats option (13-03)
- Displacement count as proxy for insert cost via probe_count (13-03)

### Pending Todos

None.

### Blockers/Concerns

**Known limitations carried forward:**
- ~90 TODOs remain in infrastructure code (Zig language limitations)
- Antimeridian polygon queries require splitting at 180 meridian
- Snapshot verification for manifest/free_set/client_sessions is future work
- Pre-existing flaky tests in ram_index.zig (concurrent/resize stress tests)

## Session Continuity

Last session: 2026-01-24
Stopped at: Completed 13-02-PLAN.md (SIMD Batch Lookup)
Resume file: None

---
*Updated: 2026-01-24 — Phase 13 wave 1 complete (13-01, 13-02, 13-03). SIMD batch lookup added.*
