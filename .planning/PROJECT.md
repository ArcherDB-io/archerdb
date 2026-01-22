# ArcherDB Completion

## What This Is

ArcherDB is a high-performance distributed geospatial database for fleet tracking, logistics, and real-time location applications. Built on VSR consensus with LSM-tree storage and S2 geospatial indexing. This project completes the implementation to world-class reference quality — every stub implemented, every SDK polished, every platform supported to production grade.

## Core Value

Correctness, performance, and completeness with no compromises. The system demands adequate resources rather than degrading gracefully, and screams through metrics/traces before hitting limits.

## Requirements

### Validated

<!-- Existing capabilities inferred from codebase -->

- ✓ VSR distributed consensus protocol — existing
- ✓ LSM-tree storage engine with compaction — existing
- ✓ S2 geospatial indexing — existing
- ✓ RAM entity index with TTL — existing
- ✓ GeoEvent operations (insert, upsert, delete, query) — existing
- ✓ Radius and polygon geospatial queries — existing
- ✓ UUID and batch UUID queries — existing
- ✓ Latest events query — existing
- ✓ Encryption at rest (AES-256-GCM, Aegis-256) — existing
- ✓ Prometheus metrics — existing
- ✓ CDC via AMQP — existing
- ✓ Sharding with consistent hashing — existing
- ✓ Multi-language SDKs (C, Go, Java, Node.js, Python) — existing
- ✓ Docker/Kubernetes deployment — existing
- ✓ Checkpoint/snapshot persistence — existing
- ✓ Write-ahead log durability — existing

### Active

<!-- What we're building to reach world-class reference quality -->

**Core Completion:**
- [ ] S3 replication backend (currently stubbed) — generic S3 API with AWS/MinIO/R2/GCS support
- [ ] Disk spillover for ShipQueue (currently placeholder) — prevent data loss during replication lag
- [ ] Complete all TODO markers in message bus error handling
- [ ] Enable snapshot verification (currently disabled)
- [ ] Resolve all FIXME/TODO comments to highest standard
- [ ] Remove deprecated message types after compatibility period
- [ ] Remove deprecated --aof flag

**Platform:**
- [ ] Remove Windows support code (focus Linux/macOS)
- [ ] Investigate and fix macOS x86_64 test assertion
- [ ] Fix Darwin fsync safety (F_FULLFSYNC fallback)
- [ ] Resolve multiversion deprecated architectures

**SDKs (all must reach feature AND quality parity):**
- [ ] Audit all 5 SDKs for feature parity
- [ ] Audit all 5 SDKs for error handling consistency
- [ ] Audit all 5 SDKs for documentation completeness
- [ ] Audit all 5 SDKs for test coverage
- [ ] Add missing operations to any SDK that lacks them

**Observability:**
- [ ] OpenTelemetry distributed tracing
- [ ] Structured JSON logging with correlation IDs
- [ ] Health endpoints (/health, /ready, /live)
- [ ] Pre-built Grafana dashboard templates
- [ ] Proactive alerting rules for resource exhaustion

**Documentation:**
- [ ] Complete API reference (every operation, every SDK)
- [ ] Architecture deep-dive (VSR, LSM, S2 internals)
- [ ] Operations runbook (deployment, scaling, backup, DR)
- [ ] Published benchmarks vs PostGIS, Redis/Tile38, Elasticsearch, Aerospike, Valkey, ScyllaDB

**Testing:**
- [ ] Full CI on Linux and macOS
- [ ] 100% test coverage for new features
- [ ] VOPR fuzzer runs in CI
- [ ] Integration tests for S3 replication
- [ ] Integration tests for disk spillover

**Performance:**
- [ ] Benchmark all operations
- [ ] Identify and optimize any bottlenecks
- [ ] LSM compaction tuning (constants.zig TODO)
- [ ] Document resource requirements

### Out of Scope

- Windows platform support — maintenance burden, focus on Linux/macOS
- Mobile SDKs (iOS/Android native) — server-side database
- GUI administration tool — CLI and metrics are sufficient
- Multi-tenancy isolation — single-tenant deployments

## Context

**Existing codebase:** 277 Zig source files, 12k+ line replica.zig, 5k+ line geo_state_machine.zig. Substantial existing functionality that needs completion rather than rewrite.

**Tech debt from CONCERNS.md:**
- S3 upload simulated with logging only
- Disk spillover uses placeholder/drops entries
- Multiple TODO/FIXME markers in critical paths
- Platform-specific workarounds (Darwin fsync, Windows sockets)

**Competition:** PostGIS, Redis/Tile38, Elasticsearch Geo, Aerospike, Valkey, ScyllaDB. Must demonstrate clear advantage on geospatial-specific workloads.

## Constraints

- **Language**: Zig 0.14.1 — enforced by bundled compiler
- **Platform**: Linux (kernel >= 5.6), macOS only — Windows dropped
- **CPU**: AES-NI required (x86_64_v3+aes or aarch64+aes+neon)
- **Quality**: No compromises — correctness, performance, completeness all required
- **Timeline**: Until it's done right — quality over speed

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Drop Windows support | Reduce maintenance burden, focus on primary platforms | — Pending |
| Generic S3 API | Support AWS, MinIO, R2, Backblaze, GCS via single implementation | — Pending |
| Full observability stack | World-class means enterprise-ready monitoring | — Pending |
| SDK parity requirement | All languages must have same features and quality | — Pending |
| No graceful degradation | Demand resources, don't hide problems | — Pending |

---
*Last updated: 2026-01-22 after initialization*
