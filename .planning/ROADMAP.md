# Roadmap: ArcherDB v2.0 Performance & Scale

## Overview

ArcherDB v2.0 transforms the production-ready v1.0 into an enterprise-scale database. The roadmap follows a measurement-first philosophy: build comprehensive profiling infrastructure before any optimization work, then proceed through storage, memory, query, consensus, and scale-out optimizations in dependency order. Breaking changes (online resharding, compact index format) are grouped in the final phase for v2.0 coordination.

## Milestones

- v1.0 Shipped (Phases 1-10) - See `.planning/milestones/v1.0-ROADMAP.md`
- **v2.0 Performance & Scale** (Phases 11-16) - Complete (2026-01-25)

## Phases

**Phase Numbering:**
- Integer phases (11, 12, 13...): Planned milestone work
- Decimal phases (11.1, 11.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 11: Measurement & Profiling Infrastructure** - Build profiling foundation before any optimization
- [x] **Phase 12: Storage Optimization** - LSM compaction tuning for write throughput
- [x] **Phase 13: Memory & RAM Index** - Memory efficiency for 100M+ entity support
- [x] **Phase 14: Query Performance** - Caching and batch operations for enterprise dashboards
- [x] **Phase 15: Cluster & Consensus** - Connection pooling, load shedding, consensus tuning
- [x] **Phase 16: Sharding & Scale-Out** - Read replicas, distributed tracing, online resharding

## Phase Details

### Phase 11: Measurement & Profiling Infrastructure
**Goal**: Establish comprehensive profiling infrastructure so all subsequent optimization work is data-driven
**Depends on**: Nothing (first phase of v2.0)
**Requirements**: PROF-01, PROF-02, PROF-03, PROF-04, PROF-05, PROF-06, PROF-07
**Success Criteria** (what must be TRUE):
  1. Developer can generate CPU flame graphs from any ArcherDB workload using Linux perf
  2. Developer can run A/B benchmarks with hardware counter comparison using POOP
  3. Memory allocations are tracked and reported in test builds via DebugAllocator
  4. Latency histograms (P50/P90/P99/P999) are available per operation type in metrics
  5. Benchmark harness produces reproducible performance results with statistical analysis
**Plans**: 5 plans in 2 waves

Plans:
- [x] 11-01-PLAN.md — CPU profiling with Linux perf and FlameGraph scripts
- [x] 11-02-PLAN.md — POOP A/B benchmarking with hardware counters
- [x] 11-03-PLAN.md — Memory allocation tracking and extended latency histograms
- [x] 11-04-PLAN.md — Statistical benchmark harness and CI integration
- [x] 11-05-PLAN.md — Tracy instrumentation and Parca continuous profiling

### Phase 12: Storage Optimization
**Goal**: Optimize LSM-tree storage for write-heavy geospatial workloads with compression and tuned compaction
**Depends on**: Phase 11 (profiling data needed to validate optimizations)
**Requirements**: STOR-01, STOR-02, STOR-03, STOR-04, STOR-05, STOR-06
**Success Criteria** (what must be TRUE):
  1. Data compression reduces storage footprint by 40-60% for typical geospatial workloads
  2. Write amplification is monitored and exposed in metrics dashboard
  3. Compaction throttling prevents I/O spikes from impacting query latency
  4. Tiered compaction strategy demonstrates improved write throughput in benchmarks
  5. Adaptive compaction auto-tunes based on workload patterns without manual intervention
**Plans**: 11 plans in 2 waves (8 core + 3 gap closure)

Plans:
- [x] 12-01-PLAN.md — LZ4 compression for value blocks
- [x] 12-02-PLAN.md — Write amplification metrics and monitoring
- [x] 12-03-PLAN.md — Compression integration into read/write paths
- [x] 12-04-PLAN.md — Compaction throttling with predictive control
- [x] 12-05-PLAN.md — Tiered compaction strategy implementation
- [x] 12-06-PLAN.md — Adaptive compaction with workload detection
- [x] 12-07-PLAN.md — Block deduplication with XxHash64
- [x] 12-08-PLAN.md — Storage dashboards and alerting rules
- [x] 12-09-PLAN.md — [GAP CLOSURE] Wire state machine to adaptive tracking
- [x] 12-10-PLAN.md — [GAP CLOSURE] Storage optimization benchmarks
- [x] 12-11-PLAN.md — [GAP CLOSURE] Adaptive compaction integration tests

### Phase 13: Memory & RAM Index
**Goal**: Optimize RAM index for extreme performance at 100M+ entity scale with cuckoo hashing and SIMD
**Depends on**: Phase 11 (profiling data needed)
**Requirements**: MEM-01 (modified), MEM-02, MEM-03, MEM-04, MEM-05 (modified)
**Success Criteria** (what must be TRUE):
  1. Cuckoo hashing provides guaranteed O(1) lookups (exactly 2 slot checks)
  2. Memory usage metrics are exposed in Prometheus for monitoring and alerting
  3. SIMD-accelerated batch lookups demonstrate measurable performance improvement
  4. RAM estimation validates memory before allocation with fail-fast on insufficient memory
  5. Grafana dashboard and Prometheus alerts provide visibility into RAM index health
**Plans**: 5 plans in 2 waves

Plans:
- [x] 13-01-PLAN.md — Cuckoo hash table with two hash functions
- [x] 13-02-PLAN.md — SIMD-accelerated key comparison for batch lookups
- [x] 13-03-PLAN.md — Prometheus metrics for RAM index memory
- [x] 13-04-PLAN.md — RAM estimation and fail-fast validation
- [x] 13-05-PLAN.md — Grafana dashboard and Prometheus alerts

### Phase 14: Query Performance
**Goal**: Achieve 80%+ cache hit ratio for dashboard workloads with sub-millisecond cached queries
**Depends on**: Phase 11 (profiling), Phase 12 (storage), Phase 13 (memory)
**Requirements**: QUERY-01, QUERY-02, QUERY-03, QUERY-04, QUERY-05, QUERY-06
**Success Criteria** (what must be TRUE):
  1. Query result cache achieves 80%+ hit ratio for repeated dashboard queries
  2. Batch query API processes multiple operations in single request with reduced overhead
  3. S2 cell covering cache eliminates redundant computation for repeated spatial patterns
  4. Query latency breakdown shows parse/plan/execute/serialize times in metrics
  5. Prepared queries demonstrate measurable performance improvement for repeated patterns
**Plans**: 6 plans in 3 waves

Plans:
- [x] 14-01-PLAN.md — Query result cache with write-invalidation
- [x] 14-02-PLAN.md — S2 cell covering cache for spatial queries
- [x] 14-03-PLAN.md — Query latency breakdown metrics and spatial stats
- [x] 14-04-PLAN.md — Batch query API with partial success handling
- [x] 14-05-PLAN.md — Prepared query compilation (session-scoped)
- [x] 14-06-PLAN.md — Query performance dashboard and alerts

### Phase 15: Cluster & Consensus
**Goal**: Harden cluster for enterprise scale with connection pooling, load shedding, and consensus tuning
**Depends on**: Phases 11-14 (single-node optimization complete before cluster changes)
**Requirements**: CLUST-01, CLUST-02, CLUST-03, CLUST-04, CLUST-05, CLUST-06
**Success Criteria** (what must be TRUE):
  1. Connection pooling prevents connection storms and reduces per-connection memory overhead
  2. VSR timeout tuning with jitter reduces unnecessary view changes under network variance
  3. Load shedding rejects requests under overload before cascading failure occurs
  4. Cluster health dashboard shows replica status, replication lag, and consensus metrics
  5. Read replicas serve read queries without consensus overhead, achieving 10x read scaling
**Plans**: 11 plans in 5 waves (6 core + 5 gap closure)

Plans:
- [x] 15-01-PLAN.md — Server-side connection pooling with adaptive reaping
- [x] 15-02-PLAN.md — VSR timeout profiles (cloud/datacenter) with jitter
- [x] 15-03-PLAN.md — Load shedding with composite signal and guardrails
- [x] 15-04-PLAN.md — Flexible Paxos quorum configuration
- [x] 15-05-PLAN.md — Read replica routing with automatic classification
- [x] 15-06-PLAN.md — Cluster health dashboard and alerting rules
- [x] 15-07-PLAN.md — [GAP CLOSURE] Connection pool integration + registry export
- [x] 15-08-PLAN.md — [GAP CLOSURE] Load shedding request pipeline wiring
- [x] 15-09-PLAN.md — [GAP CLOSURE] Read replica routing activation
- [x] 15-10-PLAN.md — [GAP CLOSURE] Timeout profiles + quorum wiring
- [x] 15-11-PLAN.md — [GAP CLOSURE] HTTP overload responses with Retry-After

### Phase 16: Sharding & Scale-Out
**Goal**: Enable horizontal scale-out with online resharding and full request path visibility
**Depends on**: Phase 15 (cluster stability required before sharding changes)
**Requirements**: SHARD-01, SHARD-02, SHARD-03, SHARD-04, SHARD-05
**Success Criteria** (what must be TRUE):
  1. Shard rebalancing metrics show migration progress and completion status
  2. Cross-shard queries execute in parallel with optimized fan-out and result aggregation
  3. Distributed tracing shows full request path across all shards via OpenTelemetry
  4. Online resharding adds/removes shards without application downtime [BREAKING]
  5. Hot shard detection identifies imbalanced shards and triggers rebalancing alerts
**Plans**: 6 plans in 2 waves

Plans:
- [x] 16-01-PLAN.md — Shard rebalancing metrics + hot shard alerts
- [x] 16-02-PLAN.md — Online resharding controller + topology notifications
- [x] 16-03-PLAN.md — Parallel fan-out queries with partial failure policy
- [x] 16-04-PLAN.md — OTel span links + coordinator tracing
- [x] 16-05-PLAN.md — Online resharding runtime wiring
- [x] 16-06-PLAN.md — Coordinator fan-out execution + OTLP export

## Progress

**Execution Order:**
Phases execute in numeric order: 11 -> 11.x -> 12 -> 12.x -> ... -> 16

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 11. Measurement & Profiling | 5/5 | ✓ Complete | 2026-01-24 |
| 12. Storage Optimization | 11/11 | ✓ Complete | 2026-01-24 |
| 13. Memory & RAM Index | 5/5 | ✓ Complete | 2026-01-24 |
| 14. Query Performance | 6/6 | ✓ Complete | 2026-01-25 |
| 15. Cluster & Consensus | 11/11 | ✓ Complete | 2026-01-25 |
| 16. Sharding & Scale-Out | 6/6 | ✓ Complete | 2026-01-25 |

## Requirement Coverage

| Category | Requirements | Phase | Count |
|----------|--------------|-------|-------|
| Profiling & Measurement | PROF-01 to PROF-07 | Phase 11 | 7 |
| Storage Optimization | STOR-01 to STOR-06 | Phase 12 | 6 |
| Memory & RAM Index | MEM-01 to MEM-05 | Phase 13 | 5 |
| Query Performance | QUERY-01 to QUERY-06 | Phase 14 | 6 |
| Cluster & Consensus | CLUST-01 to CLUST-06 | Phase 15 | 6 |
| Sharding & Scale-Out | SHARD-01 to SHARD-05 | Phase 16 | 5 |

**Total:** 35/35 requirements mapped (100% coverage)

---
*Roadmap created: 2026-01-24*
*Last updated: 2026-01-25 — Phase 16 complete (6/6 plans complete)*
