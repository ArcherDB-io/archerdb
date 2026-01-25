# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-24)

**Core value:** Correctness, performance, and completeness with no compromises
**Current focus:** v2.0 Performance & Scale - Phase 14 complete, Phase 15 next

## Current Position

Phase: 15 of 16 (Cluster & Consensus)
Plan: 4 of 6 in current phase (15-01, 15-02, 15-03, 15-04 complete)
Status: In progress
Last activity: 2026-01-25 - Completed 15-03-PLAN.md (Load Shedding)

Progress: [████████░░] 83% (v2.0: 31/35 requirements)

## v1.0 Summary

**Shipped:** 2026-01-23
**Phases:** 1-10 (39 plans)
**Requirements:** 234 satisfied

See `.planning/MILESTONES.md` for full milestone record.
See `.planning/milestones/v1.0-ROADMAP.md` for archived roadmap details.
See `.planning/milestones/v1.0-REQUIREMENTS.md` for archived requirements.

## Performance Metrics

**Velocity:**
- Total plans completed: 25 (v2.0)
- Average duration: ~6min
- Total execution time: ~144min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 11 | 5 | ~27min | ~5min |
| 12 | 9 | ~49min | ~5min |
| 13 | 5 | ~31min | ~6min |
| 14 | 6 | ~37min | ~6min |

**Recent Trend:**
- Last 5 plans: 14-02, 14-03, 14-04, 14-05, 14-06
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
- Cuckoo hashing with two hash functions for O(1) guaranteed lookup (13-01)
- hash2 uses bit rotation (67 bits) plus different constant for hash independence (13-01)
- max_displacement=10000 for bounded worst-case insertion (13-01)
- 50% target load factor for reliable cuckoo insertion (13-01)
- Single-slot cuckoo (no buckets) for simplicity while guaranteeing O(1) lookup (13-01)
- Split u128 keys into high/low u64 halves for SIMD (u128 too wide for most SIMD registers) (13-02)
- Batch size of 4 keys (64 bytes = one cache line) for SIMD operations (13-02)
- @Vector(4, u64) pattern for portable SIMD across AVX2/SSE/NEON (13-02)
- Per-operation counters vs lazy update: counters increment per lookup/insert, gauges lazy-update on scrape (13-03)
- Unconditional Prometheus recording: metrics recorded regardless of track_stats option (13-03)
- Displacement count as proxy for insert cost via probe_count (13-03)
- 50% load factor for RAM estimation matches cuckoo implementation (13-04)
- Linux /proc/meminfo parsing with MemFree fallback for older kernels (13-04)
- macOS 80% of hw.memsize as available memory estimate (13-04)
- Default 10% headroom for validated init, capped at 50% max (13-04)
- Load factor thresholds for cuckoo hashing: 50% optimal, 70% warning, 80% critical (13-05)
- Commented out insert_failures_total alert (metric not implemented) for future use (13-05)

Phase 14 decisions:
- Write-through invalidation for query result cache on any mutation (14-01)
- Generation-based cache invalidation for O(1) invalidate-all (14-01)
- CachedResult padded to 4096 bytes (power of 2) for SetAssociativeCacheType (14-01)
- Standard Prometheus latency buckets (100us to 1s) for consistent dashboard queries (14-03)
- EMA with alpha=0.1 for smooth averaging of S2 covering cell counts (14-03)
- Per-phase timing (parse/plan/execute/serialize) for bottleneck identification (14-03)
- Integer scaling for fractional gauges: x1000 for load factor, x100 for cell counts (14-03)
- Integer-only hash keys (nanodegrees, millimeters) for covering cache key stability (14-02)
- 512 entries default covering cache size (fewer unique regions than point queries) (14-02)
- No write-invalidation for covering cache - coverings are geometry-determined (14-02)
- Graceful degradation for covering cache allocation failure (14-02)

### Pending Todos

None.

### Blockers/Concerns

**Known limitations carried forward:**
- ~90 TODOs remain in infrastructure code (Zig language limitations)
- Antimeridian polygon queries require splitting at 180 meridian
- Snapshot verification for manifest/free_set/client_sessions is future work
- Pre-existing flaky tests in ram_index.zig (concurrent/resize stress tests)

## Session Continuity

Last session: 2026-01-25
Stopped at: Completed 15-03-PLAN.md (Load Shedding)
Resume file: None

---
*Updated: 2026-01-25 — Completed 15-03 Load Shedding: composite signal overload detection with hard cutoff and Prometheus metrics*

Phase 14 decisions (continued):
- 4096 bytes per cache entry (power of 2 for SetAssociativeCacheType) (14-01)
- 1024 entries default cache size (14-01)
- Generation-based write-invalidation (O(1) invalidation vs per-entry tracking) (14-01)
- Optional cache with graceful degradation (queries work without cache) (14-01)
- Session-scoped prepared query lifecycle (PostgreSQL semantics) (14-05)
- Maximum 32 prepared queries per session (bounded memory) (14-05)
- Parameter type validation at prepare time (early error detection) (14-05)
- Execution statistics per prepared query (count, duration tracking) (14-05)
- DynamoDB-style partial success for batch queries (14-04)
- Variable-length request format: header + entries + filters (14-04)
- BatchQueryExecutor generic type to avoid circular imports (14-04)
- max_queries_per_batch = 100 (bounded for response size) (14-04)
- Dashboard in observability/grafana/dashboards/ for existing infrastructure compatibility (14-06)
- Alerts in observability/prometheus/rules/ for consistency (14-06)
- 10s dashboard refresh rate for query workload patterns (14-06)
- Cache hit ratio thresholds: 80%+ green (target), 60-80% yellow, <60% red (14-06)
- RAM index load factor thresholds: <50% green, 50-70% yellow, >70% red (cuckoo optimal) (14-06)

Phase 15 decisions:
- Cloud profile: 500ms heartbeat, 2000ms election (4x heartbeat for aggressive detection) (15-02)
- Datacenter profile: 100ms heartbeat, 500ms election (5x heartbeat for fast failover) (15-02)
- Custom profile starts from cloud defaults, allows selective overrides (15-02)
- Jitter default 20% (+/- 20% variation) to prevent thundering herd (15-02)
- Saturating arithmetic for jitter bounds to prevent overflow (15-02)
- Q1 + Q2 > N invariant enforced at validation time, not construction time (15-04)
- fast_commit falls back to classic for N < 3 (can't meaningfully reduce Q2) (15-04)
- strong_leader uses Q1=N, Q2=1 for maximum commit speed at election availability cost (15-04)
- Fault tolerance helpers (phase1FaultTolerance, phase2FaultTolerance) for operational insight (15-04)
- Composite signal weighting: equal (0.34/0.33/0.33) for queue depth, latency P99, memory pressure (15-03)
- Hard cutoff shedding: below threshold accept all, at or above reject all (15-03)
- Threshold guardrails: min 0.5, max 0.95 to prevent disabling protection (15-03)
- Retry-After exponential: base * (1 + overage * 10), capped at max_retry_ms (15-03)
- Shed score scaled 0-100 for Prometheus integer gauges (15-03)
