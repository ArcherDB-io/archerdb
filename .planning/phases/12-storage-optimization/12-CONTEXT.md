# Phase 12: Storage Optimization - Context

**Gathered:** 2026-01-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Optimize LSM-tree storage for write-heavy geospatial workloads with compression and tuned compaction. Includes compression implementation, compaction strategy tuning, write amplification monitoring, and operator controls. Read replicas and sharding are separate phases.

</domain>

<decisions>
## Implementation Decisions

### Compression Strategy
- LZ4 algorithm (default fast level) — prioritizes decompression speed for latency-sensitive workloads
- Block-level compression — compress entire data blocks, works with existing LSM structure
- Compression on by default but configurable — operators can disable for edge cases via config

### Compaction Tuning
- Tiered compaction strategy as default — better write throughput for write-heavy geospatial workloads
- Latency-driven throttling — slow compaction when P99 query latency exceeds threshold
- Adaptive by default — auto-adjusts based on workload, operators can override if needed
- Dual trigger for adaptation: write throughput changes (>20% shift) AND space amplification threshold (>2x logical size)

### Metrics & Observability
- Both rolling window (1min, 5min, 1hr) and per-operation metrics — rolling by default, per-operation for debugging
- Alert on performance degradation: write amp spike, P99 latency breach, space amp threshold, plus critical conditions (disk full, compaction stall, corruption)
- Extend existing Prometheus/Grafana from Phase 11 + dedicated storage dashboard for deep dives
- Dual audience: operator view by default (actionable metrics), developer details via verbose/debug flags (per-level stats, bloom filter effectiveness, cache hits)

### Operator Controls
- Config file for defaults, runtime API for temporary overrides (revert on restart)
- Emergency mode: auto-enters on critical conditions (disk >95%, compaction stall), operator can also trigger manually
- Guardrails on overrides — operators can tune adaptive compaction but system prevents obviously bad settings (e.g., 0 compaction threads, compaction disabled while disk >90%)

### Claude's Discretion
- CLI surface for storage operations — decide based on existing ArcherDB CLI patterns
- Exact throttling thresholds and adaptation rates
- Emergency mode specific behaviors and recovery procedures
- Per-level compaction details and SSTable sizing

</decisions>

<specifics>
## Specific Ideas

- Latency-driven throttling should feel responsive — compaction backs off quickly when queries slow down, not after sustained degradation
- Adaptive compaction should "just work" for 90% of deployments — expert operators can tune, but defaults should be production-ready
- Storage dashboard should show at-a-glance health (green/yellow/red) with drill-down for details

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 12-storage-optimization*
*Context gathered: 2026-01-24*
