# ArcherDB

## What This Is

ArcherDB is a high-performance distributed geospatial database for fleet tracking, logistics, and real-time location applications. Built on VSR consensus with LSM-tree storage and S2 geospatial indexing. **v1.0 complete** — world-class reference implementation with production-grade platform support, cross-region S3 replication, 5-language SDK parity, full observability stack, and comprehensive documentation.

## Core Value

Correctness, performance, and completeness with no compromises. The system demands adequate resources rather than degrading gracefully, and screams through metrics/traces before hitting limits.

## Current State (v1.0 Shipped)

**Shipped:** 2026-01-23
**Stats:** 148,058 LOC, 2,861 files, 234 requirements satisfied

### Capabilities

- **Consensus:** VSR distributed consensus with linearizable consistency
- **Storage:** LSM-tree with compaction, encryption at rest (AES-256-GCM, Aegis-256)
- **Geospatial:** S2 indexing, radius/polygon queries, RAM index with O(1) lookup
- **Replication:** Cross-region S3 with SigV4 auth, disk spillover, multi-provider (AWS/MinIO/R2/GCS/Backblaze)
- **Sharding:** Jump hash with cross-shard query fan-out
- **SDKs:** C, Go, Java, Node.js, Python — all at feature parity with complete documentation
- **Observability:** Prometheus metrics, OpenTelemetry tracing, JSON logging, health endpoints
- **Dashboards:** 5 Grafana dashboards, 29 Prometheus alerting rules
- **Documentation:** API reference, architecture deep-dive, operations runbook, troubleshooting guide
- **Testing:** CI on Linux/macOS, VOPR fuzzer, competitor benchmarks

## Requirements

### Validated

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

*No active requirements — milestone complete. Next milestone will define new requirements.*

### Out of Scope

- Windows platform support — maintenance burden, focus on Linux/macOS
- Mobile SDKs (iOS/Android native) — server-side database
- GUI administration tool — CLI and metrics are sufficient
- Multi-tenancy isolation — single-tenant deployments

## Context

**Codebase:** 148,058 LOC across Zig, Go, Python, Java, TypeScript. 277 Zig source files in core.

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

---
*Last updated: 2026-01-23 after v1.0 milestone*
