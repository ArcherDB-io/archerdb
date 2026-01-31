# Roadmap: ArcherDB DBaaS Production Readiness

## Overview

This roadmap transforms ArcherDB from a working prototype (7% validation coverage) into a production-ready Database-as-a-Service. The critical path starts with fixing blocking bugs, validating multi-node consensus (the core value proposition), then systematically building confidence through data integrity verification, fault tolerance testing, performance optimization, security hardening, and operational tooling. Each phase delivers observable, testable capabilities that compound toward customer-ready SLAs.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3...): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Critical Bug Fixes** - Fix blocking bugs that prevent production use
- [x] **Phase 2: Multi-Node Validation** - Validate consensus and replication across 3+ replicas
- [x] **Phase 3: Data Integrity** - Verify durability, crash recovery, and backup/restore
- [x] **Phase 4: Fault Tolerance** - Test resilience to failures and adverse conditions
- [x] **Phase 5: Performance Optimization** - Achieve throughput and latency targets
- [x] **Phase 6: Security Hardening** - Security skip decisions documented for local-only deployment
- [x] **Phase 7: Observability** - Enable comprehensive monitoring and alerting
- [ ] **Phase 8: Operations Tooling** - Production deployment and management capabilities
- [ ] **Phase 9: Testing Infrastructure** - Comprehensive validation and regression testing
- [ ] **Phase 10: Documentation** - Customer-facing guides and operational runbooks

## Phase Details

### Phase 1: Critical Bug Fixes
**Goal**: All blocking bugs fixed; server operates correctly in production config
**Depends on**: Nothing (first phase)
**Requirements**: CRIT-01, CRIT-02, CRIT-03, CRIT-04
**Success Criteria** (what must be TRUE):
  1. Server /health/ready returns 200 within 30 seconds of startup
  2. Data persists across server restarts in production config (not dev mode)
  3. Server handles 100 concurrent clients without failures
  4. TTL cleanup removes expired entries from storage (count > 0)
**Plans**: 3 plans in 2 waves

Plans:
- [x] 01-01-PLAN.md - Fix readiness probe and data persistence (Wave 1)
- [x] 01-02-PLAN.md - Fix concurrent client handling (Wave 2)
- [x] 01-03-PLAN.md - Fix TTL cleanup (Wave 2)

### Phase 2: Multi-Node Validation
**Goal**: 3-node cluster operates correctly with consensus, replication, and failover
**Depends on**: Phase 1
**Requirements**: MULTI-01, MULTI-02, MULTI-03, MULTI-04, MULTI-05, MULTI-06, MULTI-07
**Success Criteria** (what must be TRUE):
  1. 3-node cluster starts, achieves consensus, and replicates writes to all nodes
  2. Primary failure triggers leader election completing within 5 seconds
  3. Failed replica rejoins cluster and catches up to current state
  4. Network partition does not cause split-brain or data divergence
  5. Cluster continues operating after losing f replicas (f = 1 for 3-node)
**Plans**: 4 plans in 3 waves

Plans:
- [x] 02-01-PLAN.md - Consensus, election, and recovery tests (MULTI-01, 02, 03) (Wave 1)
- [x] 02-02-PLAN.md - Quorum, partition, and fault tolerance tests (MULTI-04, 05, 06) (Wave 1)
- [x] 02-03-PLAN.md - Reconfiguration test and multi-seed validation (MULTI-07) (Wave 2)
- [x] 02-04-PLAN.md - Verification report and phase sign-off (Wave 3)

### Phase 3: Data Integrity
**Goal**: Data survives crashes, restores correctly, and maintains consistency
**Depends on**: Phase 2
**Requirements**: DATA-01, DATA-02, DATA-03, DATA-04, DATA-05, DATA-06, DATA-07, DATA-08, DATA-09
**Success Criteria** (what must be TRUE):
  1. WAL replay after crash restores exact state (no lost or duplicate operations)
  2. Checkpoint/restore cycle preserves all data with zero corruption
  3. Checksums detect injected data corruption (bit flips caught)
  4. Concurrent writes from multiple clients don't corrupt data
  5. Backup creates restorable snapshot; restore recovers full state
**Plans**: 5 plans in 4 waves

Plans:
- [x] 03-01-PLAN.md - WAL replay, checkpoint/restore, torn write tests (DATA-01, DATA-02, DATA-06) (Wave 1)
- [x] 03-02-PLAN.md - Checksum corruption detection tests (DATA-03) (Wave 2)
- [x] 03-03-PLAN.md - Consistency and concurrency tests (DATA-04, DATA-05) (Wave 3)
- [x] 03-04-PLAN.md - Backup/restore and PITR tests (DATA-07, DATA-08, DATA-09) (Wave 1)
- [x] 03-05-PLAN.md - Verification report and phase sign-off (Wave 4)

### Phase 4: Fault Tolerance
**Goal**: System survives hardware and network failures without data loss
**Depends on**: Phase 2, Phase 3
**Requirements**: FAULT-01, FAULT-02, FAULT-03, FAULT-04, FAULT-05, FAULT-06, FAULT-07, FAULT-08
**Success Criteria** (what must be TRUE):
  1. Process crash (SIGKILL) followed by restart loses no committed data
  2. Disk read errors are handled gracefully (retry or failover)
  3. Full disk rejects writes but remains available for reads
  4. Network latency spikes and packet loss don't cause data corruption
  5. Recovery from crash completes within 60 seconds
**Plans**: 5 plans in 3 waves

Plans:
- [x] 04-01-PLAN.md - Process crash and power loss tests (FAULT-01, FAULT-02, FAULT-07) (Wave 1)
- [x] 04-02-PLAN.md - Disk error handling tests (FAULT-03, FAULT-04) (Wave 1)
- [x] 04-03-PLAN.md - Network fault injection tests (FAULT-05, FAULT-06) (Wave 1)
- [x] 04-04-PLAN.md - Recovery timing validation (FAULT-08) (Wave 2)
- [x] 04-05-PLAN.md - Verification report and phase sign-off (Wave 3)

### Phase 5: Performance Optimization
**Goal**: Achieve performance targets for production workloads
**Depends on**: Phase 1
**Requirements**: PERF-01, PERF-02, PERF-03, PERF-04, PERF-05, PERF-06, PERF-07, PERF-08, PERF-09, PERF-10
**Success Criteria** (what must be TRUE):
  1. Write throughput >= 100,000 events/sec/node (interim target; 1M is final)
  2. Read latency P99 < 10ms for point queries
  3. Spatial query (radius) P99 < 50ms for typical workloads
  4. System sustains load for 24 hours without degradation
  5. Memory and CPU usage stay within configured limits under load
**Plans**: 5 plans in 4 waves

Plans:
- [x] 05-01-PLAN.md — Baseline profiling and bottleneck identification (Wave 1)
- [x] 05-02-PLAN.md — Write path optimization (Wave 2)
- [x] 05-03-PLAN.md — Read path optimization (Wave 2)
- [x] 05-04-PLAN.md — Endurance validation and stability testing (Wave 3)
- [x] 05-05-PLAN.md — Phase verification and sign-off (Wave 4)

### Phase 6: Security Hardening
**Goal**: Security skip decisions documented with risk acknowledgment for local-only deployment
**Depends on**: Phase 1
**Requirements**: SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, SEC-06, SEC-07, SEC-08, SEC-09, SEC-10
**Success Criteria** (what must be TRUE):
  1. All SEC requirements marked SKIPPED with documented rationale
  2. Assumptions for safe local-only deployment are recorded
  3. Existing security infrastructure is inventoried (encryption, TLS, audit)
  4. Risk acknowledgment documents implications of skipped security
  5. Phase verification report confirms scope decision documentation complete
**Plans**: 1 plan in 1 wave

Plans:
- [x] 06-01-PLAN.md — Skip documentation and phase verification (Wave 1)

### Phase 7: Observability
**Goal**: Comprehensive monitoring, alerting, and debugging capabilities
**Depends on**: Phase 2
**Requirements**: OBS-01, OBS-02, OBS-03, OBS-04, OBS-05, OBS-06, OBS-07, OBS-08
**Success Criteria** (what must be TRUE):
  1. Prometheus metrics endpoint exports all key performance indicators
  2. Grafana dashboard shows cluster health, throughput, and latency
  3. Alerts fire for critical conditions (node down, high latency, low disk)
  4. Structured logs include trace IDs for request correlation
  5. Resource usage (CPU, memory, disk) is tracked and exportable
**Plans**: 5 plans in 3 waves

Plans:
- [x] 07-01-PLAN.md — Metrics enhancement and short trace IDs (Wave 1)
- [x] 07-02-PLAN.md — Alert rules for latency and disk (Wave 1)
- [x] 07-03-PLAN.md — Unified overview dashboard (Wave 1)
- [x] 07-04-PLAN.md — Log level toggle and client metrics (Wave 2)
- [x] 07-05-PLAN.md — Phase verification and sign-off (Wave 3)

### Phase 8: Operations Tooling
**Goal**: Production deployment, upgrade, and disaster recovery capabilities
**Depends on**: Phase 2, Phase 7
**Requirements**: OPS-01, OPS-02, OPS-03, OPS-04, OPS-05, OPS-06, OPS-07, OPS-08, OPS-09, OPS-10
**Success Criteria** (what must be TRUE):
  1. Kubernetes manifests deploy working 3-node cluster
  2. Rolling updates complete without downtime or data loss
  3. Online backup runs without impacting client traffic
  4. Disaster recovery plan documented and tested
  5. Upgrade from version N to N+1 tested and documented
**Plans**: TBD

Plans:
- [ ] 08-01: Kubernetes deployment manifests
- [ ] 08-02: Rolling update and health probe integration
- [ ] 08-03: Online backup and incremental backup
- [ ] 08-04: Disaster recovery procedures
- [ ] 08-05: Upgrade and rollback procedures

### Phase 9: Testing Infrastructure
**Goal**: Comprehensive test coverage ensuring ongoing reliability
**Depends on**: Phase 1
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04, TEST-05, TEST-06, TEST-07, TEST-08
**Success Criteria** (what must be TRUE):
  1. Unit tests pass 100% with no flaky tests
  2. VOPR fuzzing runs 10+ seeds clean (no assertion failures)
  3. Chaos tests (kill nodes, partition network) pass consistently
  4. Multi-node end-to-end tests cover all client operations
  5. Performance regression tests detect throughput/latency degradation
**Plans**: TBD

Plans:
- [ ] 09-01: Unit and integration test cleanup
- [ ] 09-02: VOPR fuzzing validation
- [ ] 09-03: Chaos and stress testing
- [ ] 09-04: Multi-node end-to-end tests
- [ ] 09-05: Performance regression tests

### Phase 10: Documentation
**Goal**: Customers and operators can successfully use and manage ArcherDB
**Depends on**: Phase 5, Phase 6, Phase 8
**Requirements**: DOCS-01, DOCS-02, DOCS-03, DOCS-04, DOCS-05, DOCS-06, DOCS-07, DOCS-08
**Success Criteria** (what must be TRUE):
  1. Getting started guide enables first query in under 10 minutes
  2. API reference documents all operations with examples
  3. Operations runbook covers deployment, backup, upgrade, and recovery
  4. Troubleshooting guide addresses common issues with solutions
  5. SDK documentation covers all supported languages
**Plans**: TBD

Plans:
- [ ] 10-01: Getting started guide
- [ ] 10-02: API reference
- [ ] 10-03: Operations runbook
- [ ] 10-04: Troubleshooting and architecture docs

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10

Note: Phases 5, 6, and 9 can partially parallelize with earlier phases after Phase 1 completes.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Critical Bug Fixes | 3/3 | Complete | 2026-01-29 |
| 2. Multi-Node Validation | 4/4 | Complete | 2026-01-29 |
| 3. Data Integrity | 5/5 | Complete | 2026-01-29 |
| 4. Fault Tolerance | 5/5 | Complete | 2026-01-30 |
| 5. Performance Optimization | 5/5 | Complete | 2026-01-30 |
| 6. Security Hardening | 1/1 | Complete | 2026-01-31 |
| 7. Observability | 5/5 | Complete | 2026-01-31 |
| 8. Operations Tooling | 0/5 | Not started | - |
| 9. Testing Infrastructure | 0/5 | Not started | - |
| 10. Documentation | 0/4 | Not started | - |

---
*Roadmap created: 2026-01-29*
*Phase 1 planned: 2026-01-29*
*Phase 2 planned: 2026-01-29*
*Phase 3 planned: 2026-01-29*
*Phase 4 planned: 2026-01-30*
*Phase 7 planned: 2026-01-31*
*Total requirements: 82 v1 requirements mapped to 10 phases*
*Depth: comprehensive*
