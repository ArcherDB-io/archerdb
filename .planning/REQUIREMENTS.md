# Requirements: ArcherDB v1.1 SDK Testing & Benchmarking

**Defined:** 2026-02-01
**Core Value:** Customers can deploy mission-critical geospatial workloads with confidence that their data is safe, queries are fast, and the service stays available during failures.

## v1.1 Requirements

Requirements for comprehensive SDK testing and benchmarking infrastructure.

### Test Infrastructure (INFRA)

- [ ] **INFRA-01**: Test harness can start/stop single-node ArcherDB clusters programmatically
- [ ] **INFRA-02**: Test harness can start/stop 3-node ArcherDB clusters programmatically
- [ ] **INFRA-03**: Test harness can start/stop 5-6 node ArcherDB clusters programmatically
- [ ] **INFRA-04**: Per-SDK warmup protocols defined (iteration counts for stable benchmarks)
- [ ] **INFRA-05**: CI smoke tests run in <5 minutes on every push
- [ ] **INFRA-06**: CI PR tests run in <15 minutes with single-node validation
- [ ] **INFRA-07**: CI nightly tests run full suite (multi-node, all patterns)
- [ ] **INFRA-08**: Shared test fixtures exist in JSON format for all 14 operations
- [ ] **INFRA-09**: Test data generator creates uniform distribution datasets
- [ ] **INFRA-10**: Test data generator creates city-concentrated distribution datasets

### SDK Development (SDK)

- [ ] **SDK-01**: Zig SDK exists in src/clients/zig/ with clean API
- [ ] **SDK-02**: Zig SDK implements all 14 operations
- [ ] **SDK-03**: Zig SDK has unit tests matching other SDKs
- [ ] **SDK-04**: Zig SDK documentation exists (README, examples)
- [ ] **SDK-05**: curl examples documented for all 14 operations
- [ ] **SDK-06**: Protocol documentation explains wire format for custom clients

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

- [ ] **ERR-01**: All SDKs handle connection failures gracefully
- [ ] **ERR-02**: All SDKs handle timeout errors consistently
- [ ] **ERR-03**: All SDKs handle invalid input validation errors
- [ ] **ERR-04**: All SDKs handle empty result sets correctly
- [ ] **ERR-05**: All SDKs handle server error codes (30+ codes) consistently
- [ ] **ERR-06**: All SDKs retry on transient failures with backoff
- [ ] **ERR-07**: All SDKs handle batch size limit errors

### Cross-SDK Parity (PARITY)

- [ ] **PARITY-01**: Parity matrix created (14 ops × 6 SDKs = 84 cells)
- [ ] **PARITY-02**: All SDKs return identical results for identical queries
- [ ] **PARITY-03**: All SDKs handle edge cases identically (poles, anti-meridian)
- [ ] **PARITY-04**: All SDKs report errors with consistent codes and messages
- [ ] **PARITY-05**: Known SDK limitations documented (workarounds, gaps)

### Benchmarking - Throughput (BENCH-T)

- [ ] **BENCH-T-01**: Single-node insert throughput measured (events/sec)
- [ ] **BENCH-T-02**: 3-node insert throughput measured (events/sec)
- [ ] **BENCH-T-03**: 5-node insert throughput measured (events/sec)
- [ ] **BENCH-T-04**: 6-node insert throughput measured (events/sec)
- [ ] **BENCH-T-05**: Throughput meets baseline: ≥770K events/sec (3-node)
- [ ] **BENCH-T-06**: Throughput goal: ≥1M events/sec (3-node, stretch)

### Benchmarking - Latency (BENCH-L)

- [ ] **BENCH-L-01**: Query latency P50/P95/P99 measured (single-node)
- [ ] **BENCH-L-02**: Query latency P50/P95/P99 measured (3-node)
- [ ] **BENCH-L-03**: Write latency P50/P95/P99 measured (single-node)
- [ ] **BENCH-L-04**: Write latency P50/P95/P99 measured (3-node)
- [ ] **BENCH-L-05**: Read latency meets target: P95 <1ms, P99 <10ms
- [ ] **BENCH-L-06**: Write latency meets target: P95 <10ms, P99 <50ms

### Benchmarking - Advanced (BENCH-A)

- [ ] **BENCH-A-01**: Scalability measured (1→3→5→6 nodes, linear goal)
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

- [ ] **EDGE-01**: Pole coordinates tested (lat = ±90 degrees)
- [ ] **EDGE-02**: Anti-meridian crossing tested (lon = ±180 degrees)
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
| (To be filled during roadmap creation) | | |

**Coverage:**
- v1.1 requirements: 76 total
- Mapped to phases: (pending roadmap)
- Unmapped: (pending roadmap)

---
*Requirements defined: 2026-02-01*
*Last updated: 2026-02-01 after initial definition*
