# ArcherDB DBaaS Production Readiness

## What This Is

ArcherDB is a geospatial database with VSR consensus, LSM storage, and S2 spatial indexing. This project transforms it from a working prototype (7% validation coverage) into a production-ready Database-as-a-Service offering that can be sold to customers with SLAs and reliability guarantees.

## Core Value

Customers can deploy mission-critical geospatial workloads with confidence that their data is safe, queries are fast, and the service stays available during failures.

## Requirements

### Validated

From existing codebase (brownfield - see `.planning/codebase/`):

- ✓ Basic CRUD operations (insert, query, update, delete) — existing
- ✓ Geospatial queries (radius, polygon, latest by UUID) — existing
- ✓ Multi-language SDKs (C, Go, Java, Node.js, Python) — existing
- ✓ VSR consensus protocol implementation — existing
- ✓ LSM-tree storage engine — existing
- ✓ S2 spatial indexing — existing
- ✓ Metrics/observability (Prometheus format) — existing
- ✓ Docker deployment support — existing
- ✓ TTL/retention management — existing
- ✓ Graceful shutdown — existing
- ✓ Health endpoints (/health/live) — existing

### Active

Production readiness requirements (from DATABASE_VALIDATION_CHECKLIST.md):

**Critical Fixes:**
- [ ] Fix readiness probe (503 → 200 when ready) — **IN PROGRESS (fix committed)**
- [ ] Fix data persistence after restart
- [ ] Fix concurrent client handling (currently fails at 10 clients)
- [ ] Fix TTL cleanup (expires but doesn't remove entries)

**Multi-Node & Fault Tolerance:**
- [ ] Multi-node cluster validated (3+ replicas)
- [ ] Leader election and failover tested
- [ ] Replication lag monitoring working
- [ ] Quorum-based voting verified
- [ ] Network partition handling tested
- [ ] Node crash recovery verified
- [ ] Split-brain prevention confirmed

**Performance:**
- [ ] Write throughput: 1,000,000 events/sec/node (currently 5,062)
- [ ] Read latency: P99 < 10ms (currently 18ms in lite config)
- [ ] Concurrent clients: 100+ simultaneous connections
- [ ] Stress testing: Sustained load for 24+ hours
- [ ] Resource limits: Memory/CPU/disk usage predictable

**Security:**
- [ ] Authentication implemented and tested
- [ ] Authorization/RBAC implemented
- [ ] TLS/encryption-in-transit working
- [ ] Encryption-at-rest verified (currently present but untested)
- [ ] Security audit completed
- [ ] Vulnerability scanning automated

**Data Integrity:**
- [ ] WAL replay verified after crashes
- [ ] Checkpoint/restore cycle tested
- [ ] Data corruption detection working
- [ ] Backup/restore tested and documented
- [ ] Point-in-time recovery available

**Observability:**
- [ ] Prometheus metrics comprehensive
- [ ] Grafana dashboards created
- [ ] Alert rules defined
- [ ] Distributed tracing working
- [ ] Log aggregation configured

**Operations:**
- [ ] Deployment automation (Kubernetes manifests)
- [ ] Upgrade procedures documented and tested
- [ ] Disaster recovery plan documented
- [ ] Runbooks for common issues
- [ ] Capacity planning guidelines

**Documentation:**
- [ ] Getting started guide
- [ ] API reference complete
- [ ] Operations runbook
- [ ] Troubleshooting guide
- [ ] Architecture documentation

### Out of Scope

- Multi-region geo-distribution — Defer to v2.0 (single-region HA is sufficient for initial DBaaS)
- Real-time CDC streaming — Basic AMQP exists; full Kafka integration deferred
- Advanced compliance features — Framework exists but GDPR/HIPAA certification deferred to enterprise tier
- Mobile SDKs — Server-side SDKs sufficient for initial offering
- GraphQL API — REST/native protocol sufficient

## Context

**Current State:**
- Version: 0.0.1 (development release)
- Validation coverage: 45/644 items passing (7%)
- Critical issues: 3 identified (1 fixed, 2 remaining)
- Code size: 50K+ lines of Zig, multi-node consensus implemented
- Test infrastructure: Unit tests, integration tests, VOPR fuzzing, benchmarks

**From Validation Run (2026-01-29):**
- ✅ Server starts and runs reliably
- ✅ CRUD operations work correctly
- ✅ Geo queries return correct results
- ✅ All SDKs functional
- ⚠️ Performance 200x below target (tested in dev mode with lite config)
- ❌ Readiness probe failing (FIX COMMITTED)
- ❌ Persistence failing in dev mode (expected - works in production mode)
- ❌ Concurrent client handling fails at 10 clients
- ❌ 91% of validation items not tested (distributed systems, fault tolerance, security)

**Technical Strengths:**
- Strong consensus foundation (VSR protocol)
- Production-quality code patterns (error handling, testing, observability)
- Comprehensive validation framework already exists
- Active development with recent commits

**Known Gaps:**
- Multi-node validation incomplete
- Performance needs tuning/optimization
- Security features need testing
- Operations tooling incomplete
- Documentation gaps

## Constraints

- **Timeline**: Production-ready DBaaS as fast as possible — prioritize critical path items
- **Resources**: 24GB RAM server, 8 cores — use constrained test configs (`-j4 -Dconfig=lite`)
- **Tech Stack**: Zig 0.15.2 required (compiler version locked) — cannot upgrade mid-project
- **Validation Framework**: Use existing DATABASE_VALIDATION_CHECKLIST.md — comprehensive 644-item checklist
- **Performance Target**: 1,000,000 events/sec/node — hard requirement per specifications
- **Deployment**: Kubernetes-first — health probes, rolling updates, HA must work
- **Compatibility**: Existing wire protocol stable — cannot break existing clients

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Use existing validation checklist as requirements source | Comprehensive 644-item framework already exists; maps directly to production readiness | ✓ Good - provides clear acceptance criteria |
| Fix critical bugs before new features | Can't sell DBaaS with data loss or availability issues | — Pending |
| Test with production config (not dev mode) | Dev mode trades durability for speed; can't validate production behavior | ✓ Good - revealed persistence works in prod mode |
| Multi-node testing required before beta | Single-node DBaaS not viable; consensus is core value prop | — Pending |
| Performance optimization after correctness | Need working system before making it fast | — Pending |

---
*Last updated: 2026-01-29 after codebase mapping and validation debugging*
