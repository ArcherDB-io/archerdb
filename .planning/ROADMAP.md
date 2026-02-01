# Roadmap: ArcherDB v1.1 SDK Testing & Benchmarking

## Overview

This milestone delivers comprehensive SDK testing and benchmarking infrastructure for ArcherDB. Starting from the v1.0 production-ready foundation, we build test infrastructure, create the Zig SDK, validate all 6 SDKs across all 14 operations, establish cross-SDK parity, formalize benchmarking with statistical rigor, test multi-node topologies, and integrate everything into CI with proper documentation.

## Milestones

- **v1.0 DBaaS Production Readiness** - Phases 1-10 (shipped 2026-01-31)
- **v1.1 SDK Testing & Benchmarking** - Phases 11-18 (in progress)

## Phases

**Phase Numbering:**
- Integer phases (11, 12, 13): Planned milestone work
- Decimal phases (12.1, 12.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 11: Test Infrastructure Foundation** - Server harness, CI tiers, shared fixtures, data generators
- [x] **Phase 12: Zig SDK & Protocol Documentation** - Create Zig SDK, protocol docs, curl examples
- [x] **Phase 13: SDK Operation Test Suite** - All 14 operations tested across all 6 SDKs
- [x] **Phase 14: Error Handling & Cross-SDK Parity** - Error handling consistency, parity matrix
- [ ] **Phase 15: Benchmark Framework** - Throughput and latency benchmarking with percentiles
- [ ] **Phase 16: Multi-Topology Testing** - Tests across 1/3/5/6 node clusters with failover
- [ ] **Phase 17: Edge Cases & Advanced Benchmarking** - Edge cases, regression detection, historical tracking
- [ ] **Phase 18: CI Integration & Documentation** - Automated CI pipelines, comprehensive docs

## Phase Details

### Phase 11: Test Infrastructure Foundation
**Goal**: Reliable test infrastructure enables consistent SDK testing and benchmarking
**Depends on**: v1.0 complete (Phase 10)
**Requirements**: INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-05, INFRA-06, INFRA-07, INFRA-08, INFRA-09, INFRA-10
**Success Criteria** (what must be TRUE):
  1. Test script can start a single-node cluster, run a health check, and stop it cleanly
  2. Test script can start a 3-node cluster with automatic leader election and stop all nodes
  3. Test script can start 5-6 node clusters for topology testing
  4. Shared JSON test fixtures exist with canonical test data for all 14 operations
  5. Test data generators can produce both uniform and city-concentrated datasets
**Plans**: 2 plans

Plans:
- [x] 11-01-PLAN.md — Python cluster harness, port allocation, data generators
- [x] 11-02-PLAN.md — CI tier workflows, JSON fixtures for 14 operations, warmup protocols
**Completed**: 2026-02-01

### Phase 12: Zig SDK & Protocol Documentation
**Goal**: Zig SDK and protocol documentation enable native client development and raw API access
**Depends on**: Phase 11 (test infrastructure needed for SDK validation)
**Requirements**: SDK-01, SDK-02, SDK-03, SDK-04, SDK-05, SDK-06
**Success Criteria** (what must be TRUE):
  1. Zig SDK in src/clients/zig/ compiles and provides clean API for all 14 operations
  2. Zig SDK unit tests pass with same coverage as other SDKs
  3. curl examples demonstrate all 14 operations against running server
  4. Protocol documentation explains wire format enabling custom client implementation
**Plans**: 2 plans

Plans:
- [x] 12-01-PLAN.md — Zig SDK core: types, errors, HTTP client, all 14 operations, unit tests, README
- [x] 12-02-PLAN.md — Protocol wire format docs, curl cookbook with all 14 operations
**Completed**: 2026-02-01

### Phase 13: SDK Operation Test Suite
**Goal**: All 6 SDKs validated for correctness across all 14 operations
**Depends on**: Phase 12 (Zig SDK must exist to test it)
**Requirements**: OP-01, OP-02, OP-03, OP-04, OP-05, OP-06, OP-07, OP-08, OP-09, OP-10, OP-11, OP-12, OP-13, OP-14, OP-15, OP-16, OP-17, OP-18, OP-19, OP-20
**Success Criteria** (what must be TRUE):
  1. Python SDK passes all 14 operation tests with 100% pass rate
  2. Node.js SDK passes all 14 operation tests with 100% pass rate
  3. Go SDK passes all 14 operation tests with 100% pass rate
  4. Java SDK passes all 14 operation tests with 100% pass rate
  5. C SDK passes all 14 operation tests with 100% pass rate
  6. Zig SDK passes all 14 operation tests with 100% pass rate
**Plans**: 3 plans

Plans:
- [x] 13-01-PLAN.md — Test runner infrastructure, Python SDK tests, Node.js SDK tests
- [x] 13-02-PLAN.md — Go SDK tests, Java SDK tests
- [x] 13-03-PLAN.md — C SDK tests, Zig SDK tests
**Completed**: 2026-02-01

### Phase 14: Error Handling & Cross-SDK Parity
**Goal**: All SDKs handle errors consistently and produce identical results
**Depends on**: Phase 13 (operation correctness must be established first)
**Requirements**: ERR-01, ERR-02, ERR-03, ERR-04, ERR-05, ERR-06, ERR-07, PARITY-01, PARITY-02, PARITY-03, PARITY-04, PARITY-05
**Success Criteria** (what must be TRUE):
  1. All SDKs handle connection failures, timeouts, and server errors gracefully
  2. All SDKs return identical results for identical queries (parity verified)
  3. All SDKs handle edge cases identically (poles, anti-meridian, empty results)
  4. Parity matrix (14 ops x 6 SDKs = 84 cells) shows 100% consistency
  5. SDK limitations documented with workarounds where applicable
**Plans**: 2 plans

Plans:
- [x] 14-01-PLAN.md — Error handling tests (ERR-01 to ERR-07) for connection, timeout, validation, empty results, retry, batch limits
- [x] 14-02-PLAN.md — Cross-SDK parity verification with geographic edge cases, parity matrix, limitation documentation
**Completed**: 2026-02-01

### Phase 15: Benchmark Framework
**Goal**: Performance benchmarking with statistical rigor and percentile reporting
**Depends on**: Phase 14 (correctness and parity must be established before benchmarking)
**Requirements**: BENCH-T-01, BENCH-T-02, BENCH-T-03, BENCH-T-04, BENCH-T-05, BENCH-T-06, BENCH-L-01, BENCH-L-02, BENCH-L-03, BENCH-L-04, BENCH-L-05, BENCH-L-06
**Success Criteria** (what must be TRUE):
  1. Throughput measured across 1/3/5/6 node configurations with events/sec reporting
  2. Latency P50/P95/P99 measured for both reads and writes
  3. 3-node throughput meets baseline: >=770K events/sec
  4. Read latency meets target: P95 <1ms, P99 <10ms
  5. Write latency meets target: P95 <10ms, P99 <50ms
**Plans**: 2 plans

Plans:
- [ ] 15-01-PLAN.md — Benchmark core framework: config, executor, stats, histogram, reporter, CLI
- [ ] 15-02-PLAN.md — Throughput and latency workloads, orchestrator, regression detection, docs/BENCHMARKS.md

### Phase 16: Multi-Topology Testing
**Goal**: All operations verified across cluster configurations with failover handling
**Depends on**: Phase 15 (single-node benchmarks must work before multi-node)
**Requirements**: TOPO-01, TOPO-02, TOPO-03, TOPO-04, TOPO-05, TOPO-06, TOPO-07
**Success Criteria** (what must be TRUE):
  1. All operation tests pass on single-node, 3-node, 5-node, and 6-node clusters
  2. Leader failover tested with automatic recovery verified
  3. Network partition handling tested (split-brain scenarios)
  4. Topology query returns accurate cluster state after reconfiguration
**Plans**: TBD

Plans:
- [ ] 16-01: Multi-topology operation validation
- [ ] 16-02: Failover and partition testing

### Phase 17: Edge Cases & Advanced Benchmarking
**Goal**: Edge case coverage and automated regression detection with historical tracking
**Depends on**: Phase 16 (multi-node must work before advanced scenarios)
**Requirements**: EDGE-01, EDGE-02, EDGE-03, EDGE-04, EDGE-05, EDGE-06, EDGE-07, EDGE-08, BENCH-A-01, BENCH-A-02, BENCH-A-03, BENCH-A-04, BENCH-A-05, BENCH-A-06, BENCH-A-07
**Success Criteria** (what must be TRUE):
  1. Geometric edge cases tested: poles (lat=+/-90), anti-meridian (lon=+/-180), concave polygons
  2. Scale tested: 10K batch inserts, 100K+ events, TTL expiration verified
  3. Adversarial patterns from geo_workload.zig tested
  4. Scalability measured across node counts with regression detection automated
  5. Performance dashboard visualizes trends with historical tracking
**Plans**: TBD

Plans:
- [ ] 17-01: Geometric and scale edge cases
- [ ] 17-02: Advanced benchmarking and regression detection

### Phase 18: CI Integration & Documentation
**Goal**: Automated CI pipelines and comprehensive documentation enable ongoing quality
**Depends on**: Phase 17 (all tests must exist before CI integration)
**Requirements**: CI-01, CI-02, CI-03, CI-04, CI-05, CI-06, DOCS-01, DOCS-02, DOCS-03, DOCS-04, DOCS-05, DOCS-06
**Success Criteria** (what must be TRUE):
  1. SDK tests run automatically on every PR with smoke tests gating merges (<5 min)
  2. Nightly full suite runs multi-node tests across all patterns
  3. Weekly benchmark suite runs on dedicated hardware with clear reporting
  4. Test suite README explains how to run tests locally
  5. Benchmark guide, curl examples, protocol docs, and SDK comparison matrix published
**Plans**: TBD

Plans:
- [ ] 18-01: CI pipeline configuration
- [ ] 18-02: Documentation suite

## Progress

**Execution Order:**
Phases execute in numeric order: 11 -> 11.1 -> 11.2 -> 12 -> 12.1 -> 13 -> ...

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 11. Test Infrastructure | v1.1 | 2/2 | Complete | 2026-02-01 |
| 12. Zig SDK & Protocol | v1.1 | 2/2 | Complete | 2026-02-01 |
| 13. SDK Operation Tests | v1.1 | 3/3 | Complete (needs UAT) | 2026-02-01 |
| 14. Error Handling & Parity | v1.1 | 2/2 | Complete (needs UAT) | 2026-02-01 |
| 15. Benchmark Framework | v1.1 | 0/2 | Planned | - |
| 16. Multi-Topology Testing | v1.1 | 0/2 | Not started | - |
| 17. Edge Cases & Advanced | v1.1 | 0/2 | Not started | - |
| 18. CI & Documentation | v1.1 | 0/2 | Not started | - |

---
*Roadmap created: 2026-02-01*
*Last updated: 2026-02-01 (Phase 15 planned)*
