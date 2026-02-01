# Requirements: ArcherDB v1.1 SDK Testing & Benchmarking

**Defined:** 2026-02-01
**Core Value:** Customers can deploy mission-critical geospatial workloads with confidence that their data is safe, queries are fast, and the service stays available during failures.

## v1.1 Requirements

Requirements for comprehensive SDK testing and benchmarking infrastructure.

### Test Infrastructure (INFRA)

- [x] **INFRA-01**: Test harness can start/stop single-node ArcherDB clusters programmatically
- [x] **INFRA-02**: Test harness can start/stop 3-node ArcherDB clusters programmatically
- [x] **INFRA-03**: Test harness can start/stop 5-6 node ArcherDB clusters programmatically
- [x] **INFRA-04**: Per-SDK warmup protocols defined (iteration counts for stable benchmarks)
- [x] **INFRA-05**: CI smoke tests run in <5 minutes on every push
- [x] **INFRA-06**: CI PR tests run in <15 minutes with single-node validation
- [x] **INFRA-07**: CI nightly tests run full suite (multi-node, all patterns)
- [x] **INFRA-08**: Shared test fixtures exist in JSON format for all 14 operations
- [x] **INFRA-09**: Test data generator creates uniform distribution datasets
- [x] **INFRA-10**: Test data generator creates city-concentrated distribution datasets

### SDK Development (SDK)

- [x] **SDK-01**: Zig SDK exists in src/clients/zig/ with clean API
- [x] **SDK-02**: Zig SDK implements all 14 operations
- [x] **SDK-03**: Zig SDK has unit tests matching other SDKs
- [x] **SDK-04**: Zig SDK documentation exists (README, examples)
- [x] **SDK-05**: curl examples documented for all 14 operations
- [x] **SDK-06**: Protocol documentation explains wire format for custom clients

### Operation Correctness (OP)

- [ ] **OP-01**: Python SDK passes all 14 operation tests
- [ ] **OP-02**: Node.js SDK passes all 14 operation tests
- [ ] **OP-03**: Go SDK passes all 14 operation tests
- [ ] **OP-04**: Java SDK passes all 14 operation tests
- [ ] **OP-05**: C SDK passes all 14 operation tests
- [ ] **OP-06**: Zig SDK passes all 14 operation tests
- [ ] **OP-07**: Insert (single + batch) tested across all SDKs
- [ ] **OP-08**: Upsert (single + batch) tested across all SDKs
- [ ] **OP-09**: Delete entities tested across all SDKs
- [ ] **OP-10**: Query by UUID (single + batch) tested across all SDKs
- [ ] **OP-11**: Query by radius tested across all SDKs
- [ ] **OP-12**: Query by polygon tested across all SDKs
- [ ] **OP-13**: Query latest tested across all SDKs
- [ ] **OP-14**: Set TTL tested across all SDKs
- [ ] **OP-15**: Extend TTL tested across all SDKs
- [ ] **OP-16**: Clear TTL tested across all SDKs
- [ ] **OP-17**: Cleanup expired tested across all SDKs
- [ ] **OP-18**: Ping tested across all SDKs
- [ ] **OP-19**: Get status tested across all SDKs
- [ ] **OP-20**: Get topology tested across all SDKs

### Error Handling (ERR)

- [x] **ERR-01**: All SDKs handle connection failures gracefully
- [x] **ERR-02**: All SDKs handle timeout errors consistently
- [x] **ERR-03**: All SDKs handle invalid input validation errors
- [x] **ERR-04**: All SDKs handle empty result sets correctly
- [x] **ERR-05**: All SDKs handle server error codes (30+ codes) consistently
- [x] **ERR-06**: All SDKs retry on transient failures with backoff
- [x] **ERR-07**: All SDKs handle batch size limit errors

### Cross-SDK Parity (PARITY)

- [x] **PARITY-01**: Parity matrix created (14 ops x 6 SDKs = 84 cells)
- [x] **PARITY-02**: All SDKs return identical results for identical queries
- [x] **PARITY-03**: All SDKs handle edge cases identically (poles, anti-meridian)
- [x] **PARITY-04**: All SDKs report errors with consistent codes and messages
- [x] **PARITY-05**: Known SDK limitations documented (workarounds, gaps)

### Benchmarking - Throughput (BENCH-T)

- [x] **BENCH-T-01**: Single-node insert throughput measured (events/sec)
- [x] **BENCH-T-02**: 3-node insert throughput measured (events/sec)
- [x] **BENCH-T-03**: 5-node insert throughput measured (events/sec)
- [x] **BENCH-T-04**: 6-node insert throughput measured (events/sec)
- [x] **BENCH-T-05**: Throughput meets baseline: >=770K events/sec (3-node)
- [x] **BENCH-T-06**: Throughput goal: >=1M events/sec (3-node, stretch)

### Benchmarking - Latency (BENCH-L)

- [x] **BENCH-L-01**: Query latency P50/P95/P99 measured (single-node)
- [x] **BENCH-L-02**: Query latency P50/P95/P99 measured (3-node)
- [x] **BENCH-L-03**: Write latency P50/P95/P99 measured (single-node)
- [x] **BENCH-L-04**: Write latency P50/P95/P99 measured (3-node)
- [x] **BENCH-L-05**: Read latency meets target: P95 <1ms, P99 <10ms
- [x] **BENCH-L-06**: Write latency meets target: P95 <10ms, P99 <50ms

### Benchmarking - Advanced (BENCH-A)

- [ ] **BENCH-A-01**: Scalability measured (1->3->5->6 nodes, linear goal)
- [ ] **BENCH-A-02**: SDK parity measured (all SDKs within 20% of each other)
- [ ] **BENCH-A-03**: Uniform workload pattern benchmarked
- [ ] **BENCH-A-04**: City-concentrated workload pattern benchmarked
- [ ] **BENCH-A-05**: Regression detection automated (compare vs baselines)
- [ ] **BENCH-A-06**: Performance tracking stores historical results
- [ ] **BENCH-A-07**: Performance dashboard visualizes trends

### Multi-Topology Testing (TOPO)

- [ ] **TOPO-01**: All operation tests pass on single-node cluster
- [ ] **TOPO-02**: All operation tests pass on 3-node cluster
- [ ] **TOPO-03**: All operation tests pass on 5-node cluster
- [ ] **TOPO-04**: All operation tests pass on 6-node cluster
- [ ] **TOPO-05**: Leader failover tested (automatic recovery verified)
- [ ] **TOPO-06**: Network partition tested (split-brain handling verified)
- [ ] **TOPO-07**: Topology query returns correct cluster state

### Edge Cases & Validation (EDGE)

- [ ] **EDGE-01**: Pole coordinates tested (lat = +/-90 degrees)
- [ ] **EDGE-02**: Anti-meridian crossing tested (lon = +/-180 degrees)
- [ ] **EDGE-03**: Concave polygon queries tested
- [ ] **EDGE-04**: Large batch tested (10K entities in single batch)
- [ ] **EDGE-05**: High volume tested (100K+ events inserted)
- [ ] **EDGE-06**: TTL expiration verified (events expire after TTL)
- [ ] **EDGE-07**: Empty query results handled correctly
- [ ] **EDGE-08**: Adversarial patterns tested (leverage geo_workload.zig)

### CI Integration (CI)

- [ ] **CI-01**: SDK tests run automatically on PRs
- [ ] **CI-02**: Smoke tests gate PR merges (<5 min)
- [ ] **CI-03**: Nightly full suite runs (multi-node, all patterns)
- [ ] **CI-04**: Benchmark suite runs weekly (dedicated hardware)
- [ ] **CI-05**: Flaky test retry policy implemented
- [ ] **CI-06**: Test results reported clearly (pass/fail, metrics)

### Documentation (DOCS)

- [ ] **DOCS-01**: Test suite README explains how to run tests
- [ ] **DOCS-02**: Benchmark guide explains how to run benchmarks
- [ ] **DOCS-03**: curl examples demonstrate all 14 operations
- [ ] **DOCS-04**: Protocol documentation enables custom client development
- [ ] **DOCS-05**: SDK comparison matrix shows feature parity
- [ ] **DOCS-06**: Performance baselines documented (throughput, latency)

## Out of Scope

| Feature | Reason |
|---------|--------|
| 100% code coverage | Testing behavior, not implementation details |
| Cross-language performance parity | Each SDK has language-specific characteristics; 20% variance acceptable |
| Real-time continuous benchmarking | Weekly benchmark suite sufficient; continuous too expensive |
| Mobile SDK testing | No mobile SDKs exist in v1; defer to future |
| GraphQL API testing | No GraphQL API exists; out of scope per PROJECT.md |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | Phase 11 | Complete |
| INFRA-02 | Phase 11 | Complete |
| INFRA-03 | Phase 11 | Complete |
| INFRA-04 | Phase 11 | Complete |
| INFRA-05 | Phase 11 | Complete |
| INFRA-06 | Phase 11 | Complete |
| INFRA-07 | Phase 11 | Complete |
| INFRA-08 | Phase 11 | Complete |
| INFRA-09 | Phase 11 | Complete |
| INFRA-10 | Phase 11 | Complete |
| SDK-01 | Phase 12 | Pending |
| SDK-02 | Phase 12 | Pending |
| SDK-03 | Phase 12 | Pending |
| SDK-04 | Phase 12 | Pending |
| SDK-05 | Phase 12 | Pending |
| SDK-06 | Phase 12 | Pending |
| OP-01 | Phase 13 | Pending |
| OP-02 | Phase 13 | Pending |
| OP-03 | Phase 13 | Pending |
| OP-04 | Phase 13 | Pending |
| OP-05 | Phase 13 | Pending |
| OP-06 | Phase 13 | Pending |
| OP-07 | Phase 13 | Pending |
| OP-08 | Phase 13 | Pending |
| OP-09 | Phase 13 | Pending |
| OP-10 | Phase 13 | Pending |
| OP-11 | Phase 13 | Pending |
| OP-12 | Phase 13 | Pending |
| OP-13 | Phase 13 | Pending |
| OP-14 | Phase 13 | Pending |
| OP-15 | Phase 13 | Pending |
| OP-16 | Phase 13 | Pending |
| OP-17 | Phase 13 | Pending |
| OP-18 | Phase 13 | Pending |
| OP-19 | Phase 13 | Pending |
| OP-20 | Phase 13 | Pending |
| ERR-01 | Phase 14 | Pending |
| ERR-02 | Phase 14 | Pending |
| ERR-03 | Phase 14 | Pending |
| ERR-04 | Phase 14 | Pending |
| ERR-05 | Phase 14 | Pending |
| ERR-06 | Phase 14 | Pending |
| ERR-07 | Phase 14 | Pending |
| PARITY-01 | Phase 14 | Pending |
| PARITY-02 | Phase 14 | Pending |
| PARITY-03 | Phase 14 | Pending |
| PARITY-04 | Phase 14 | Pending |
| PARITY-05 | Phase 14 | Pending |
| BENCH-T-01 | Phase 15 | Pending |
| BENCH-T-02 | Phase 15 | Pending |
| BENCH-T-03 | Phase 15 | Pending |
| BENCH-T-04 | Phase 15 | Pending |
| BENCH-T-05 | Phase 15 | Pending |
| BENCH-T-06 | Phase 15 | Pending |
| BENCH-L-01 | Phase 15 | Pending |
| BENCH-L-02 | Phase 15 | Pending |
| BENCH-L-03 | Phase 15 | Pending |
| BENCH-L-04 | Phase 15 | Pending |
| BENCH-L-05 | Phase 15 | Pending |
| BENCH-L-06 | Phase 15 | Pending |
| TOPO-01 | Phase 16 | Complete |
| TOPO-02 | Phase 16 | Complete |
| TOPO-03 | Phase 16 | Complete |
| TOPO-04 | Phase 16 | Complete |
| TOPO-05 | Phase 16 | Complete |
| TOPO-06 | Phase 16 | Complete |
| TOPO-07 | Phase 16 | Complete |
| EDGE-01 | Phase 17 | Pending |
| EDGE-02 | Phase 17 | Pending |
| EDGE-03 | Phase 17 | Pending |
| EDGE-04 | Phase 17 | Pending |
| EDGE-05 | Phase 17 | Pending |
| EDGE-06 | Phase 17 | Pending |
| EDGE-07 | Phase 17 | Pending |
| EDGE-08 | Phase 17 | Pending |
| BENCH-A-01 | Phase 17 | Pending |
| BENCH-A-02 | Phase 17 | Pending |
| BENCH-A-03 | Phase 17 | Pending |
| BENCH-A-04 | Phase 17 | Pending |
| BENCH-A-05 | Phase 17 | Pending |
| BENCH-A-06 | Phase 17 | Pending |
| BENCH-A-07 | Phase 17 | Pending |
| CI-01 | Phase 18 | Pending |
| CI-02 | Phase 18 | Pending |
| CI-03 | Phase 18 | Pending |
| CI-04 | Phase 18 | Pending |
| CI-05 | Phase 18 | Pending |
| CI-06 | Phase 18 | Pending |
| DOCS-01 | Phase 18 | Pending |
| DOCS-02 | Phase 18 | Pending |
| DOCS-03 | Phase 18 | Pending |
| DOCS-04 | Phase 18 | Pending |
| DOCS-05 | Phase 18 | Pending |
| DOCS-06 | Phase 18 | Pending |

**Coverage:**
- v1.1 requirements: 94 total
- Mapped to phases: 94/94
- Unmapped: 0

---
*Requirements defined: 2026-02-01*
*Last updated: 2026-02-01 after roadmap creation*
