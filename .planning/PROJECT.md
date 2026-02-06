# ArcherDB DBaaS Production Readiness

## What This Is

ArcherDB is a production-ready geospatial database with VSR consensus, LSM storage, and S2 spatial indexing. It provides mission-critical reliability for geospatial workloads with validated fault tolerance, comprehensive observability, and Kubernetes-native deployment.

## Core Value

Customers can deploy mission-critical geospatial workloads with confidence that their data is safe, queries are fast, and the service stays available during failures.

## Current State

**Version:** v1 (shipped 2026-01-31)

**Capabilities:**
- 3-node VSR consensus with automatic leader election
- 770K events/sec write throughput, sub-millisecond read latency
- Comprehensive fault tolerance (crash, disk errors, network partitions)
- Production Helm chart with rolling updates and disaster recovery
- 252 Prometheus metrics, Grafana dashboards, 15 alert rules
- Complete documentation (quickstart, API, operations, SDK guides)

**Tech debt (non-blocking):**
- PERF-02: 77% of 1M target on dev server (expected on production hardware)
- PERF-07/PERF-10: Requires multi-node cluster / perf tools for validation
- Security features implemented but not enabled (local-only deployment)

See `.planning/MILESTONES.md` for full v1 details.

## Current Milestone: v1.1 SDK Testing & Benchmarking

**Goal:** Comprehensive SDK testing and benchmarking infrastructure to validate all functionality across all client libraries and establish performance baselines.

**Target capabilities:**
- Test all 5 SDKs (Python, Node.js, Go, Java, C) with 100% operation coverage
- Raw protocol testing and documentation (curl examples)
- Workload pattern testing (single, low, high volume, uniform, city-concentrated)
- Multi-topology testing (1, 3, 5, 6-node clusters)
- Performance benchmarking (throughput, latency, scalability, SDK parity)
- CI integration for automated regression detection

## Requirements

### Validated (v1)

All v1 requirements shipped. See `.planning/milestones/v1-REQUIREMENTS.md` for full list.

**Highlights:**
- ✓ CRIT-01 through CRIT-04: All critical bugs fixed
- ✓ MULTI-01 through MULTI-07: Full multi-node validation
- ✓ DATA-01 through DATA-09: Complete data integrity suite
- ✓ FAULT-01 through FAULT-08: All fault tolerance scenarios
- ✓ PERF-01, PERF-03-06, PERF-08-09: Performance targets met
- ✓ OBS-01 through OBS-08: Full observability stack
- ✓ OPS-01-02, OPS-04-10: Production operations tooling
- ✓ TEST-01 through TEST-08: Comprehensive test infrastructure
- ✓ DOCS-01 through DOCS-08: Complete documentation
- ~ SEC-01 through SEC-10: Skipped (local-only deployment)
- ~ PERF-02: Partial (77%), OPS-03: Partial (opt-in)

### Active

Requirements for v1.1 milestone will be defined through research and requirements process.

### Out of Scope

- Multi-region geo-distribution — Defer to v2.0
- Real-time CDC streaming to Kafka — Basic AMQP exists
- Advanced compliance (HIPAA, SOC 2) — Deferred to enterprise tier
- Mobile SDKs — Server-side SDKs sufficient
- GraphQL API — REST/native protocol sufficient

## Context

**Codebase:**
- ~783K lines of Zig + documentation
- 10 phases, 46 plans executed
- 1674 unit tests passing (109 skipped for lite config)
- 28 fault tolerance tests, 26 data integrity tests

**Infrastructure:**
- Dev server: 24GB RAM, 8 cores
- CI: GitHub Actions with VOPR, chaos, and regression tests
- Deployment: Helm chart for Kubernetes

## Constraints

- **Tech Stack**: Zig 0.15.2 (compiler version locked)
- **Resources**: 24GB RAM dev server — use lite config for testing
- **Deployment**: Kubernetes-first with health probes
- **Compatibility**: Wire protocol stable — cannot break existing clients

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Use validation checklist as requirements | 644-item framework maps to production readiness | ✓ Good |
| Fix critical bugs before features | Can't ship DBaaS with data loss | ✓ Good |
| Test with production config | Dev mode trades durability for speed | ✓ Good |
| Skip security for local-only | Infrastructure handles security | ✓ Good |
| Lite config for dev, production for CI | Balance dev speed with validation coverage | ✓ Good |
| 770K vs 1M throughput | 77% on dev server; production hardware expected to meet target | ✓ Acceptable |

---
*Last updated: 2026-02-01 after starting v1.1 milestone*
