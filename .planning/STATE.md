# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-24)

**Core value:** Correctness, performance, and completeness with no compromises
**Current focus:** v2.0 Performance & Scale - Phase 16 planning

## Current Position

Phase: 16 of 16 (Sharding & Scale-Out)
Plan: 6 of 6 in current phase
Status: Phase complete
Last activity: 2026-01-25 - Completed 16-06-PLAN.md

Progress: [██████████] 100% (plans: 83/83)

## v1.0 Summary

**Shipped:** 2026-01-23
**Phases:** 1-10 (39 plans)
**Requirements:** 234 satisfied

See `.planning/MILESTONES.md` for full milestone record.
See `.planning/milestones/v1.0-ROADMAP.md` for archived roadmap details.
See `.planning/milestones/v1.0-REQUIREMENTS.md` for archived requirements.

## Performance Metrics

**Velocity:**
- Total plans completed: 34 (v2.0)
- Average duration: ~6min
- Total execution time: ~218min

**Recent Trend:**
- Last 5 plans: 16-01, 16-03, 16-04, 16-05, 16-06
- Trend: ~6min per plan

*Updated after each plan completion*

## Accumulated Context

### Decisions

Key decisions from v1.0 logged in PROJECT.md. Earlier phase decisions are captured in phase summaries.

v2.0 decisions:
- Measurement-first approach: All optimization work requires profiling data
- Phase order follows dependency/risk: low-risk measurement -> medium-risk storage/memory -> high-risk consensus/sharding
- Breaking changes grouped in Phase 16 for coordinated v2.0 release
- Hot shard scoring normalized to load_shedding thresholds for consistent weighting (16-01)
- Rebalance gauges model cooldown decay for active move slots (16-01)
- Default fan-out policy uses all for uuid_batch and majority for radius/polygon/latest (16-03)
- Online resharding control requests are routed through the metrics server to trigger runtime ticks (16-05)

Phase 15 decisions:
- Generic ServerConnectionPool function over connection type for protocol flexibility (15-01)
- 20% memory threshold for pressure detection (available < 20% of total) (15-01)
- Bounded waiter queue (64 max) instead of unbounded queue (15-01)
- Top-10 client tracking with LRU eviction to avoid cardinality explosion (15-01)
- Memory detection via /proc/meminfo (Linux) and hw.memsize sysctl (macOS) (15-01)
- Cloud profile: 500ms heartbeat, 2000ms election (4x heartbeat for aggressive detection) (15-02)
- Datacenter profile: 100ms heartbeat, 500ms election (5x heartbeat for fast failover) (15-02)
- Custom profile starts from cloud defaults, allows selective overrides (15-02)
- Jitter default 20% (+/- 20% variation) to prevent thundering herd (15-02)
- Saturating arithmetic for jitter bounds to prevent overflow (15-02)
- Replica timeouts use jittered profile values with ceil-to-ticks conversion (15-10)
- Q1 + Q2 > N invariant enforced at validation time, not construction time (15-04)
- Quorum presets allow phase-1/phase-2 overrides while enforcing Q1+Q2>N (15-10)
- fast_commit falls back to classic for N < 3 (can't meaningfully reduce Q2) (15-04)
- strong_leader uses Q1=N, Q2=1 for maximum commit speed at election availability cost (15-04)
- Fault tolerance helpers (phase1FaultTolerance, phase2FaultTolerance) for operational insight (15-04)
- Composite signal weighting: equal (0.34/0.33/0.33) for queue depth, latency P99, memory pressure (15-03)
- Hard cutoff shedding: below threshold accept all, at or above reject all (15-03)
- Threshold guardrails: min 0.5, max 0.95 to prevent disabling protection (15-03)
- Retry-After exponential: base * (1 + overage * 10), capped at max_retry_ms (15-03)
- Shed score scaled 0-100 for Prometheus integer gauges (15-03)
- Replica health fields stored as atomics for thread-safe routing updates (15-05)
- Per-replica routing metrics tracked within constants.replicas_max slots (15-05)
- Partition outbound replica connection slots from pooled accept slots via client_pool_offset (15-07)

### Blockers/Concerns

**Known limitations carried forward:**
- ~90 TODOs remain in infrastructure code (Zig language limitations)
- Antimeridian polygon queries require splitting at 180 meridian
- Snapshot verification for manifest/free_set/client_sessions is future work
- Pre-existing flaky tests in ram_index.zig (concurrent/resize stress tests)

## Session Continuity

Last session: 2026-01-25 22:39 UTC
Stopped at: Completed 16-06-PLAN.md
Resume file: None

---
*Updated: 2026-01-25 — Completed 16-06 coordinator fan-out tracing activation*
