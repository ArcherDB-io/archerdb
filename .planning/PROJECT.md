# ArcherDB

## What This Is

ArcherDB is a high-performance distributed geospatial database for fleet tracking, logistics, and real-time location applications. Built on VSR consensus with LSM-tree storage and S2 geospatial indexing. **v2.0 complete** — enterprise-scale performance with comprehensive profiling, storage optimization, cuckoo hash RAM index, query caching, cluster hardening, and horizontal scale-out with online resharding.

## Core Value

Correctness, performance, and completeness with no compromises. The system demands adequate resources rather than degrading gracefully, and screams through metrics/traces before hitting limits.

## Current State (v2.0 Shipped)

**Shipped:** 2026-01-26
**Stats:** 231,255 LOC Zig, 269 requirements satisfied (234 v1.0 + 35 v2.0)

### v2.0 Capabilities (New)

- **Profiling:** Linux perf flame graphs, POOP A/B benchmarks, Tracy instrumentation, Parca continuous profiling
- **Storage:** LZ4 compression (52% reduction), tiered compaction (1.7x throughput), adaptive auto-tuning, block deduplication
- **RAM Index:** Cuckoo hashing with O(1) guaranteed lookups (2 slot checks), SIMD batch operations (@Vector(4, u64))
- **Query:** Result cache (99% hit ratio), S2 covering cache, batch API, prepared queries (53% faster), latency breakdown
- **Cluster:** Connection pooling, VSR timeout profiles with jitter, load shedding with HTTP 429, flexible Paxos, read replicas
- **Sharding:** Online resharding with dual-write/cutover, hot shard detection with auto-migration, parallel fan-out, OTLP tracing

### v1.0 Capabilities (Foundation)

- **Consensus:** VSR distributed consensus with linearizable consistency
- **Storage:** LSM-tree with compaction, encryption at rest (AES-256-GCM, Aegis-256)
- **Geospatial:** S2 indexing, radius/polygon queries, RAM index
- **Replication:** Cross-region S3 with SigV4 auth, disk spillover, multi-provider
- **SDKs:** C, Go, Java, Node.js, Python — all at feature parity
- **Observability:** Prometheus metrics, OpenTelemetry tracing, JSON logging
- **Dashboards:** 9 Grafana dashboards (4 new in v2.0), 50+ alert rules
- **Documentation:** API reference, architecture deep-dive, operations runbook

## Requirements

### Validated

**v2.0 (2026-01-26) — 35 requirements shipped:**

- ✓ Profiling & Measurement (PROF-01 to PROF-07) — v2.0
- ✓ Storage Optimization (STOR-01 to STOR-06) — v2.0
- ✓ Memory & RAM Index (MEM-01 to MEM-05) — v2.0
- ✓ Query Performance (QUERY-01 to QUERY-06) — v2.0
- ✓ Cluster & Consensus (CLUST-01 to CLUST-06) — v2.0
- ✓ Sharding & Scale-Out (SHARD-01 to SHARD-05) — v2.0

**v1.0 (2026-01-23) — 234 requirements shipped:**

- ✓ Platform Foundation (PLAT-01 to PLAT-08, MBUS-01 to MBUS-06) — v1.0
- ✓ VSR & Storage (VSR-01 to VSR-09, DUR-01 to DUR-08, LSM-01 to LSM-08, ENC-01 to ENC-07) — v1.0
- ✓ Core Geospatial (S2-01 to S2-08, RAD-01 to RAD-08, POLY-01 to POLY-09, ENT-01 to ENT-10, RAM-01 to RAM-08) — v1.0
- ✓ Replication (REPL-01 to REPL-11) — v1.0
- ✓ Sharding & Cleanup (SHARD-01 to SHARD-06, CLEAN-01 to CLEAN-10) — v1.0
- ✓ SDK Parity (SDKC-01 to SDKC-07, SDKG-01 to SDKG-08, SDKJ-01 to SDKJ-09, SDKN-01 to SDKN-09, SDKP-01 to SDKP-09) — v1.0
- ✓ Observability (MET-01 to MET-09, TRACE-01 to TRACE-07, LOG-01 to LOG-05, HEALTH-01 to HEALTH-05, DASH-01 to DASH-09) — v1.0
- ✓ Documentation (AREF-01 to AREF-05, ARCH-01 to ARCH-07, OPS-01 to OPS-08, BENCH-01 to BENCH-07) — v1.0
- ✓ Testing (CI-01 to CI-07, INT-01 to INT-06, PERF-01 to PERF-09) — v1.0

### Active

*No active requirements — v2.0 complete. Next milestone will define new requirements.*

### Out of Scope

- Windows platform support — maintenance burden, focus on Linux/macOS
- Mobile SDKs (iOS/Android native) — server-side database
- GUI administration tool — CLI and metrics are sufficient
- Multi-tenancy isolation — single-tenant deployments
- SQL query language — ArcherDB is purpose-built, not general SQL
- GPU acceleration — complexity vs benefit ratio unfavorable

## Context

**Codebase:** 231,255 LOC Zig core. SDKs in Go, Python, Java, TypeScript.

**Tech stack:**
- Core: Zig 0.14.1
- SDKs: C (via Zig), Go, Java, Node.js/TypeScript, Python
- Observability: Prometheus, OpenTelemetry, Grafana
- Deployment: Docker, Kubernetes

**Competition:** PostGIS, Redis/Tile38, Elasticsearch Geo, Aerospike. Benchmarks show clear advantage on geospatial-specific workloads.

**Known limitations:**
- ~90 TODOs remain in infrastructure code (Zig language limitations)
- Antimeridian polygon queries require splitting at 180 meridian
- Snapshot verification for manifest/free_set/client_sessions is future work
- Pre-existing flaky tests in ram_index.zig (concurrent/resize stress tests)

## Constraints

- **Language:** Zig 0.14.1 — enforced by bundled compiler
- **Platform:** Linux (kernel >= 5.6), macOS only — Windows removed
- **CPU:** AES-NI required (x86_64_v3+aes or aarch64+aes+neon)
- **Quality:** No compromises — correctness, performance, completeness all required

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Drop Windows support | Reduce maintenance burden, focus on primary platforms | ✓ Good — Simplified codebase, Darwin fixed |
| Generic S3 API | Support AWS, MinIO, R2, Backblaze, GCS via single implementation | ✓ Good — 5 providers supported |
| Full observability stack | World-class means enterprise-ready monitoring | ✓ Good — Production ready |
| SDK parity requirement | All languages must have same features and quality | ✓ Good — All 5 SDKs complete |
| No graceful degradation | Demand resources, don't hide problems | ✓ Good — Clear failure modes |
| Measurement-first optimization | All v2.0 optimization requires profiling data first | ✓ Good — Data-driven decisions |
| Cuckoo hashing for RAM index | Guaranteed O(1) lookups (exactly 2 slot checks) | ✓ Good — Predictable latency |
| SIMD batch operations | @Vector(4, u64) for parallel key comparison | ✓ Good — 4x throughput |
| Query result caching | Generation-based invalidation on writes | ✓ Good — 99% hit ratio achieved |
| Flexible Paxos quorums | Independent phase-1/phase-2 quorum configuration | ✓ Good — Latency vs availability tradeoff |
| Online resharding | Dual-write with cutover, no downtime required | ✓ Good — Zero-downtime scaling |
| Hot shard auto-migration | Threshold-based detection triggers automatic rebalancing | ✓ Good — Self-healing clusters |

---
*Last updated: 2026-01-26 after v2.0 milestone*
