# Roadmap: ArcherDB Completion

## Overview

This roadmap completes ArcherDB from working prototype to world-class reference implementation. Starting with platform cleanup and foundation fixes, progressing through feature completion (replication, encryption, sharding), SDK parity across all five languages, full observability stack, comprehensive documentation, and ending with testing and benchmarks. Every requirement ships before release.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Platform Foundation** - Remove Windows, fix Darwin/macOS, stabilize message bus
- [x] **Phase 2: VSR & Storage** - Fix VSR issues, verify durability, verify encryption
- [x] **Phase 3: Core Geospatial** - Verify S2 indexing, queries, entity operations, RAM index
- [x] **Phase 4: Replication** - Implement S3 backend, disk spillover, replication metrics
- [ ] **Phase 5: Sharding & Cleanup** - Verify sharding, resolve all TODOs/FIXMEs, remove stubs
- [ ] **Phase 6: SDK Parity** - Complete all 5 SDKs to feature and quality parity
- [ ] **Phase 7: Observability Core** - Metrics completion, tracing, structured logging, health endpoints
- [ ] **Phase 8: Observability Dashboards** - Grafana dashboards, alerting rules
- [ ] **Phase 9: Documentation** - API reference, architecture deep-dive, operations runbook
- [ ] **Phase 10: Testing & Benchmarks** - CI completion, integration tests, performance benchmarks

## Phase Details

### Phase 1: Platform Foundation
**Goal**: Platform support is clean and correct - Windows removed, Darwin/macOS fully working, message bus error handling complete
**Depends on**: Nothing (first phase)
**Requirements**: PLAT-01, PLAT-02, PLAT-03, PLAT-04, PLAT-05, PLAT-06, PLAT-07, PLAT-08, MBUS-01, MBUS-02, MBUS-03, MBUS-04, MBUS-05, MBUS-06
**Success Criteria** (what must be TRUE):
  1. Windows support code removed from io/windows.zig, build.zig, and documentation
  2. macOS x86_64 test assertion fixed (build.zig:811 issue resolved)
  3. Darwin fsync correctly uses F_FULLFSYNC with safe fallback behavior
  4. All message bus error conditions documented with clear fatal/recoverable classification
  5. Message bus connection state transitions tested and peer eviction logic verified
**Plans**: 3 plans

Plans:
- [x] 01-01-PLAN.md - Windows removal (io, build, source files)
- [x] 01-02-PLAN.md - Darwin/macOS fixes (F_FULLFSYNC, x86_64 assertion)
- [x] 01-03-PLAN.md - Message bus error handling

### Phase 2: VSR & Storage
**Goal**: Consensus and storage layers are verified correct - VSR fixes applied, durability guarantees solid, encryption verified
**Depends on**: Phase 1
**Requirements**: VSR-01, VSR-02, VSR-03, VSR-04, VSR-05, VSR-06, VSR-07, VSR-08, VSR-09, DUR-01, DUR-02, DUR-03, DUR-04, DUR-05, DUR-06, DUR-07, DUR-08, LSM-01, LSM-02, LSM-03, LSM-04, LSM-05, LSM-06, LSM-07, LSM-08, ENC-01, ENC-02, ENC-03, ENC-04, ENC-05, ENC-06, ENC-07
**Success Criteria** (what must be TRUE):
  1. VSR snapshot verification enabled and passing
  2. VSR deprecated message types removed (deprecated_12, deprecated_21, deprecated_22, deprecated_23)
  3. Recovery from checkpoint and WAL replay verified correct
  4. LSM compaction tuning parameters optimized (constants.zig)
  5. Both AES-256-GCM and Aegis-256 encryption verified, key rotation documented
**Plans**: 4 plans

Plans:
- [x] 02-01-PLAN.md - VSR protocol fixes (deprecated messages, snapshot verification, journal assertion)
- [x] 02-02-PLAN.md - Durability verification (VOPR extension, WAL/checkpoint recovery, power-loss tests)
- [x] 02-03-PLAN.md - LSM optimization (tuning, benchmarks, documentation)
- [x] 02-04-PLAN.md - Encryption verification (NIST vectors, key rotation, threat model)

### Phase 3: Core Geospatial
**Goal**: All geospatial operations verified correct - S2 indexing, radius/polygon queries, entity operations, RAM index all working perfectly
**Depends on**: Phase 2
**Requirements**: S2-01, S2-02, S2-03, S2-04, S2-05, S2-06, S2-07, S2-08, RAD-01, RAD-02, RAD-03, RAD-04, RAD-05, RAD-06, RAD-07, RAD-08, POLY-01, POLY-02, POLY-03, POLY-04, POLY-05, POLY-06, POLY-07, POLY-08, POLY-09, ENT-01, ENT-02, ENT-03, ENT-04, ENT-05, ENT-06, ENT-07, ENT-08, ENT-09, ENT-10, RAM-01, RAM-02, RAM-03, RAM-04, RAM-05, RAM-06, RAM-07, RAM-08
**Success Criteria** (what must be TRUE):
  1. S2 cell computations match Google S2 reference implementation
  2. Radius queries return all points within distance and none outside (great-circle distance)
  3. Polygon queries handle convex, concave, holes, and antimeridian crossing correctly
  4. Entity insert/upsert/delete/query all work with proper tombstone handling
  5. RAM index provides O(1) lookup with verified race condition handling (line 1859)
**Plans**: 5 plans

Plans:
- [x] 03-01-PLAN.md - S2 indexing verification (golden vectors from Google S2, determinism)
- [x] 03-02-PLAN.md - Radius query verification (Haversine, edge cases, property tests)
- [x] 03-03-PLAN.md - Polygon query verification (convex, concave, holes, antimeridian)
- [x] 03-04-PLAN.md - Entity operations verification (insert, upsert, delete, tombstones, TTL)
- [x] 03-05-PLAN.md - RAM index verification (O(1) lookup, race condition, checkpoint)

### Phase 4: Replication
**Goal**: Cross-region replication fully implemented - S3 backend working with all providers, disk spillover prevents data loss
**Depends on**: Phase 2
**Requirements**: REPL-01, REPL-02, REPL-03, REPL-04, REPL-05, REPL-06, REPL-07, REPL-08, REPL-09, REPL-10, REPL-11
**Success Criteria** (what must be TRUE):
  1. S3RelayTransport uploads data to actual S3 (not simulated logging)
  2. S3 backend works with AWS, MinIO, R2, GCS, and Backblaze via generic S3 API
  3. Disk spillover writes to disk when memory queue fills and recovers on restart
  4. Replication lag exposed via metrics
  5. Integration tests verify S3 upload with MinIO and disk spillover recovery
**Plans**: 3 plans

Plans:
- [x] 04-01-PLAN.md - S3 backend implementation (SigV4, S3 client, provider adaptations, retry logic)
- [x] 04-02-PLAN.md - Disk spillover implementation (SpilloverManager, atomic writes, metrics)
- [x] 04-03-PLAN.md - Replication integration tests (MinIO, spillover recovery, end-to-end)

### Phase 5: Sharding & Cleanup
**Goal**: Sharding verified correct, all tech debt resolved - TODOs/FIXMEs addressed, stubs implemented or removed
**Depends on**: Phase 3, Phase 4
**Requirements**: SHARD-01, SHARD-02, SHARD-03, SHARD-04, SHARD-05, SHARD-06, CLEAN-01, CLEAN-02, CLEAN-03, CLEAN-04, CLEAN-05, CLEAN-06, CLEAN-07, CLEAN-08, CLEAN-09, CLEAN-10
**Success Criteria** (what must be TRUE):
  1. Consistent hashing distributes entities evenly, jump hash matches across all client versions
  2. Cross-shard queries fan out and aggregate correctly
  3. Deprecated --aof flag removed
  4. All 181 TODO comments resolved or converted to tracking issues
  5. All stubs implemented: REPL, state_machine_tests, tiering.zig, backup_config.zig, TLS CRL/OCSP, CDC AMQP, CSV import
**Plans**: TBD

Plans:
- [ ] 05-01: Sharding verification
- [ ] 05-02: Code cleanup - TODOs and FIXMEs
- [ ] 05-03: Stub implementation

### Phase 6: SDK Parity
**Goal**: All five SDKs at feature and quality parity - same operations, same error handling, same documentation, same test coverage
**Depends on**: Phase 3
**Requirements**: SDKC-01, SDKC-02, SDKC-03, SDKC-04, SDKC-05, SDKC-06, SDKC-07, SDKG-01, SDKG-02, SDKG-03, SDKG-04, SDKG-05, SDKG-06, SDKG-07, SDKG-08, SDKJ-01, SDKJ-02, SDKJ-03, SDKJ-04, SDKJ-05, SDKJ-06, SDKJ-07, SDKJ-08, SDKJ-09, SDKN-01, SDKN-02, SDKN-03, SDKN-04, SDKN-05, SDKN-06, SDKN-07, SDKN-08, SDKN-09, SDKP-01, SDKP-02, SDKP-03, SDKP-04, SDKP-05, SDKP-06, SDKP-07, SDKP-08, SDKP-09
**Success Criteria** (what must be TRUE):
  1. All geospatial operations available in all 5 SDKs (C, Go, Java, Node.js, Python)
  2. All error codes properly mapped in each SDK (exceptions, typed errors, status codes)
  3. Documentation complete in each SDK (header comments, godoc, javadoc, TSDoc, docstrings)
  4. Async support where idiomatic (CompletableFuture, Promise, asyncio, Context)
  5. Test coverage complete with sample code for all operations in each SDK
**Plans**: TBD

Plans:
- [ ] 06-01: C SDK completion
- [ ] 06-02: Go SDK completion
- [ ] 06-03: Java SDK completion
- [ ] 06-04: Node.js SDK completion
- [ ] 06-05: Python SDK completion

### Phase 7: Observability Core
**Goal**: Full observability stack operational - comprehensive metrics, distributed tracing, structured logging, health endpoints
**Depends on**: Phase 5
**Requirements**: MET-01, MET-02, MET-03, MET-04, MET-05, MET-06, MET-07, MET-08, MET-09, TRACE-01, TRACE-02, TRACE-03, TRACE-04, TRACE-05, TRACE-06, TRACE-07, LOG-01, LOG-02, LOG-03, LOG-04, LOG-05, HEALTH-01, HEALTH-02, HEALTH-03, HEALTH-04, HEALTH-05
**Success Criteria** (what must be TRUE):
  1. Prometheus metrics for all operations with latency histograms (p50, p95, p99)
  2. OpenTelemetry tracing with spans for insert, query, compaction, replication
  3. Structured JSON logging with correlation IDs and runtime-configurable log levels
  4. Health endpoints (/health, /ready, /live) report replica and storage status
  5. Sensitive data redacted from logs, log rotation supported
**Plans**: TBD

Plans:
- [ ] 07-01: Metrics completion
- [ ] 07-02: OpenTelemetry tracing
- [ ] 07-03: Structured logging
- [ ] 07-04: Health endpoints

### Phase 8: Observability Dashboards
**Goal**: Production-ready monitoring - Grafana dashboards showing everything operators need, alerting rules for proactive response
**Depends on**: Phase 7
**Requirements**: DASH-01, DASH-02, DASH-03, DASH-04, DASH-05, DASH-06, DASH-07, DASH-08, DASH-09
**Success Criteria** (what must be TRUE):
  1. Grafana dashboard template shows query latency, throughput, replication lag, cluster health
  2. Prometheus alerting rules configured for resource exhaustion (proactive)
  3. Alerts configured for replication lag exceeding threshold
  4. Alerts configured for error rate spikes
  5. Dashboards and alerts documented with installation instructions
**Plans**: TBD

Plans:
- [ ] 08-01: Grafana dashboard creation
- [ ] 08-02: Alerting rules

### Phase 9: Documentation
**Goal**: Documentation complete for users and operators - API reference, architecture deep-dive, operations runbook
**Depends on**: Phase 6, Phase 8
**Requirements**: AREF-01, AREF-02, AREF-03, AREF-04, AREF-05, ARCH-01, ARCH-02, ARCH-03, ARCH-04, ARCH-05, ARCH-06, ARCH-07, OPS-01, OPS-02, OPS-03, OPS-04, OPS-05, OPS-06, OPS-07, OPS-08
**Success Criteria** (what must be TRUE):
  1. API reference documents all operations, request/response formats, error codes, wire protocol
  2. Architecture documentation explains VSR, LSM-tree, S2 indexing, RAM index, sharding, replication
  3. Operations runbook covers single-node, cluster, and Kubernetes deployment
  4. Backup, restore, disaster recovery, and upgrade procedures documented
  5. Troubleshooting guide covers common issues with resolution steps
**Plans**: TBD

Plans:
- [ ] 09-01: API reference
- [ ] 09-02: Architecture documentation
- [ ] 09-03: Operations runbook

### Phase 10: Testing & Benchmarks
**Goal**: Testing complete and benchmarks published - CI on all platforms, integration tests, performance benchmarks vs competitors
**Depends on**: Phase 9
**Requirements**: CI-01, CI-02, CI-03, CI-04, CI-05, CI-06, CI-07, INT-01, INT-02, INT-03, INT-04, INT-05, INT-06, PERF-01, PERF-02, PERF-03, PERF-04, PERF-05, PERF-06, PERF-07, PERF-08, PERF-09, BENCH-01, BENCH-02, BENCH-03, BENCH-04, BENCH-05, BENCH-06, BENCH-07
**Success Criteria** (what must be TRUE):
  1. CI runs on Linux and macOS with VOPR fuzzer and test coverage reports
  2. Integration tests cover all geospatial operations, replication, backup/restore, failover, all SDKs
  3. Performance benchmarks for insert throughput, radius/polygon/UUID query latency, batch queries
  4. Published benchmarks vs PostGIS, Redis/Tile38, Elasticsearch Geo, Aerospike
  5. Minimum and recommended hardware requirements documented for different scales
**Plans**: TBD

Plans:
- [ ] 10-01: CI completion
- [ ] 10-02: Integration tests
- [ ] 10-03: Performance benchmarks
- [ ] 10-04: Competitor benchmarks

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Platform Foundation | 3/3 | Complete | 2026-01-22 |
| 2. VSR & Storage | 4/4 | Complete | 2026-01-22 |
| 3. Core Geospatial | 5/5 | Complete | 2026-01-22 |
| 4. Replication | 3/3 | Complete | 2026-01-22 |
| 5. Sharding & Cleanup | 0/3 | Not started | - |
| 6. SDK Parity | 0/5 | Not started | - |
| 7. Observability Core | 0/4 | Not started | - |
| 8. Observability Dashboards | 0/2 | Not started | - |
| 9. Documentation | 0/3 | Not started | - |
| 10. Testing & Benchmarks | 0/4 | Not started | - |

---
*Roadmap created: 2026-01-22*
*Phase 1 planned: 2026-01-22*
*Phase 1 complete: 2026-01-22*
*Phase 2 planned: 2026-01-22*
*Phase 2 complete: 2026-01-22*
*Phase 3 planned: 2026-01-22*
*Phase 3 complete: 2026-01-22*
*Phase 4 planned: 2026-01-22*
*Phase 4 complete: 2026-01-22*
*Total requirements: 234 | All mapped*
