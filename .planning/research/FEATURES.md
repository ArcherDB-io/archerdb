# Feature Research: SDK Testing & Benchmarking Suite

**Domain:** Comprehensive SDK Testing and Benchmarking for Distributed Geospatial Database
**Researched:** 2026-02-01
**Confidence:** HIGH (informed by existing codebase analysis, recent SDK testing results, and industry best practices)

## Feature Landscape

### Table Stakes (Users Expect These)

Features that any professional SDK test suite must have. Missing these means the test suite is incomplete and untrustworthy.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Operation Correctness Tests** | Every SDK operation must demonstrably work | LOW | 14 operations x 6 SDKs = 84 test cases minimum |
| **Cross-SDK Parity Matrix** | Users expect all SDKs to have identical behavior | MEDIUM | Test same scenarios across Python/Node/Go/Java/C, compare results |
| **Error Handling Tests** | All error codes must be properly surfaced | MEDIUM | 30+ error codes per docs/error-codes.md |
| **Empty Results Handling** | Queries returning zero results must not crash | LOW | Radius/polygon/UUID queries with no matches |
| **Input Validation Tests** | Invalid inputs must return clear errors | LOW | Out-of-range coordinates, malformed IDs, etc. |
| **Connection Lifecycle Tests** | Connect/disconnect/reconnect reliability | MEDIUM | Timeout handling, graceful shutdown |
| **Retry Behavior Tests** | SDK retry semantics must work correctly | MEDIUM | Per docs/sdk-retry-semantics.md |
| **Basic Latency Metrics** | p50/p95/p99 latency for each operation | MEDIUM | Industry-standard percentile reporting |
| **Basic Throughput Metrics** | Operations per second under load | MEDIUM | Essential for capacity planning |
| **CI Integration** | Tests must run automatically on every PR | LOW | Regression prevention |

### Differentiators (Competitive Advantage)

Features that distinguish a comprehensive test suite. Not required, but demonstrate maturity and thoroughness.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Multi-Topology Testing** | Validates cluster behavior across 1/3/5/6 node configurations | HIGH | Tests consensus, failover, replication |
| **Workload Pattern Testing** | Verifies performance under realistic patterns (hotspots, uniform, concentrated) | HIGH | Existing geo_workload.zig can be leveraged |
| **Chaos/Fault Injection** | Tests SDK behavior during network partitions, node failures | HIGH | Uses existing VOPR infrastructure |
| **Performance Regression Detection** | Automatic detection of performance degradation | MEDIUM | Existing baseline system in performance-baselines.md |
| **SDK Benchmark Parity** | Ensures no SDK is significantly slower than others | HIGH | Same workload across all SDKs |
| **Edge Case Fuzzing** | Systematic boundary condition testing | HIGH | Poles, anti-meridian, zero radius, max radius |
| **Concurrent Client Testing** | Tests SDK thread-safety and connection pooling | HIGH | Per SDK feature matrix (thread-safe = yes) |
| **Batch Size Optimization** | Tests to find optimal batch sizes for each SDK | MEDIUM | Current recommendation: 1000-8000 events |
| **Long-Running Stability** | Soak tests detecting memory leaks, resource exhaustion | HIGH | Hours-long test runs |
| **Historical Trend Analysis** | Track performance metrics over time | MEDIUM | Build on existing benchmark-ci.sh |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem valuable but create more problems than they solve.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **100% Code Coverage Target** | Completeness metric | Coverage != correctness; encourages trivial tests | Focus on operation coverage and edge cases |
| **Testing Internal SDK Implementation** | Deep verification | Couples tests to internals, breaks on refactors | Test via public API only |
| **Mocking the Database** | Faster tests | Misses real protocol/behavior issues | Use real lite-config cluster (~130MB RAM) |
| **Absolute Benchmark Numbers** | Marketing claims | Varies by hardware, misleads users | Use relative comparisons (PR vs main) |
| **Testing Every Error Code Combination** | Completeness | Combinatorial explosion | Test error categories, spot-check codes |
| **Real-Time Benchmark Dashboards** | Visibility | Maintenance burden, noise | On-demand comparison tools |
| **Testing Deprecated Operations** | Historical coverage | Maintains dead code paths | Remove deprecated ops from test matrix |
| **Cross-Language Performance Comparison** | "Best SDK" claims | Language differences are expected | Test each SDK against its own baseline |

## Feature Dependencies

```
[Operation Correctness Tests]
    |
    +--requires--> [Connection Lifecycle Tests]
    |
    +--enhances--> [Cross-SDK Parity Matrix]

[Multi-Topology Testing]
    |
    +--requires--> [Operation Correctness Tests]
    |
    +--requires--> [Cluster Infrastructure]

[Chaos/Fault Injection]
    |
    +--requires--> [Multi-Topology Testing]
    |
    +--requires--> [Connection Lifecycle Tests] (retry/reconnect behavior)

[Performance Regression Detection]
    |
    +--requires--> [Basic Latency Metrics]
    |
    +--requires--> [Basic Throughput Metrics]
    |
    +--requires--> [CI Integration]

[SDK Benchmark Parity]
    |
    +--requires--> [Basic Latency/Throughput Metrics]
    |
    +--conflicts--> [Absolute Benchmark Numbers] (avoid misleading claims)

[Edge Case Fuzzing]
    |
    +--enhances--> [Operation Correctness Tests]
    |
    +--leverages--> [Existing geo_workload.zig adversarial patterns]
```

### Dependency Notes

- **Operation Correctness requires Connection Lifecycle:** Cannot test operations without stable connections
- **Multi-Topology requires Correctness:** Must prove single-node works before testing clusters
- **Chaos requires Multi-Topology:** Fault injection only meaningful with multiple nodes
- **Regression Detection requires Metrics + CI:** Cannot detect regressions without baseline and automation
- **SDK Parity conflicts with Absolute Benchmarks:** Comparing SDKs to each other is valuable; claiming "X SDK is 10% faster" is misleading across different hardware

## Test Categories

### Category 1: Functional Correctness (P1)

Tests that verify each operation works correctly.

| Test Type | Operations Covered | Test Cases per SDK | Total |
|-----------|-------------------|-------------------|-------|
| CRUD Operations | insert, upsert, delete | 3 happy path + 6 edge cases | 54 |
| Query Operations | query_uuid, query_radius, query_polygon, query_latest, query_uuid_batch | 5 happy path + 15 edge cases | 120 |
| Cluster Operations | ping, status, topology | 3 happy path + 3 edge cases | 36 |
| TTL Operations | ttl_set, ttl_extend, ttl_clear | 3 happy path + 6 edge cases | 54 |
| **Subtotal** | | | 264 |

### Category 2: Edge Cases & Boundaries (P1)

Tests for boundary conditions identified in existing geo_workload.zig.

| Edge Case | Operations Affected | Priority |
|-----------|-------------------|----------|
| North/South Pole coordinates | All geo queries | HIGH |
| Anti-meridian crossing (+-180 lon) | query_radius, query_polygon | HIGH |
| Zero radius queries | query_radius | MEDIUM |
| Maximum radius (1000km) | query_radius | MEDIUM |
| Empty result sets | All queries | HIGH |
| Maximum batch size (10,000 events) | insert, upsert | HIGH |
| Empty batch | insert, upsert | MEDIUM |
| Single event batch | insert, upsert | LOW |
| Maximum polygon vertices | query_polygon | MEDIUM |
| Minimum polygon vertices (3) | query_polygon | MEDIUM |
| Concave polygons | query_polygon | HIGH |
| Zero entity ID | All operations | HIGH |
| Maximum timestamp | All operations | LOW |

### Category 3: Error Handling (P1)

Tests for proper error code surfacing per docs/error-codes.md.

| Error Category | Sample Codes | Test Count |
|----------------|--------------|------------|
| Protocol (1-99) | Message format, checksums | 5 |
| Validation (100-199) | Invalid coordinates, batch size | 10 |
| State (200-299) | Entity not found, cluster state | 8 |
| Resource (300-399) | Limits exceeded | 5 |
| Security (400-499) | Auth, encryption | 3 |
| Multi-region (213-218) | Follower read-only, replication | 6 |
| Sharding (220-224) | Shard routing, resharding | 5 |

### Category 4: Performance Benchmarks (P2)

Benchmarks per existing docs/benchmarks.md framework.

| Benchmark | Metrics | Threshold |
|-----------|---------|-----------|
| Insert Throughput | events/sec | >850K single client |
| UUID Lookup Latency | p50, p95, p99 | p99 <500us |
| Radius Query Latency | p50, p95, p99 | p99 <50ms (1-10km) |
| Polygon Query Latency | p50, p95, p99 | p99 <100ms |
| Batch Insert Latency | p50, p99 | p99 <10ms (1000 events) |
| Concurrent Client Scaling | throughput vs clients | 90%+ efficiency at 10 clients |

### Category 5: Cluster & Topology (P2)

Tests across different cluster configurations.

| Configuration | Test Focus |
|---------------|-----------|
| 1 node | Single-replica correctness, no topology discovery |
| 3 nodes | Basic consensus, leader election, topology discovery |
| 5 nodes | Larger consensus group, fault tolerance |
| 6 nodes | Maximum supported configuration |

### Category 6: SDK-Specific Validation (P2)

Tests for known SDK limitations per docs/SDK-LIMITATIONS-AND-WORKAROUNDS.md.

| SDK | Known Issues | Test Verification |
|-----|--------------|-------------------|
| Python | None major | Full coverage expected |
| Node.js | queryUuidBatch not implemented | Skip test, document |
| Go | queryUuidBatch not implemented | Skip test, document |
| Java | queryPolygon causes eviction (FIXED), ttl_extend incorrect | Verify fixes work |
| C | Sample code incomplete | Test core operations only |

## MVP Definition

### Launch With (v1)

Minimum viable test suite that provides confidence in SDK correctness.

- [x] **Operation Correctness for all 14 operations** - Already done per SDK-TESTING-FINAL-REPORT.md
- [ ] **Formalized test harness** - Convert ad-hoc test scripts to reusable framework
- [ ] **Cross-SDK parity verification** - Same test scenarios, compare results
- [ ] **Basic edge case coverage** - Empty results, invalid inputs, boundary coordinates
- [ ] **CI integration** - Run on every PR, fail on regression
- [ ] **Basic benchmark suite** - Latency p50/p95/p99 for core operations

### Add After Validation (v1.x)

Features to add once core test suite is stable.

- [ ] **Multi-topology testing** - Add when cluster management is mature
- [ ] **Performance regression detection** - Build on existing baseline system
- [ ] **Workload pattern testing** - Leverage existing geo_workload.zig
- [ ] **Long-running stability tests** - After resource usage is well understood

### Future Consideration (v2+)

Features to defer until test suite is battle-tested.

- [ ] **Chaos/fault injection** - Requires substantial VOPR integration work
- [ ] **SDK benchmark parity analysis** - Needs stable baseline across all SDKs
- [ ] **Historical trend analysis** - Requires long-term data collection

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Operation Correctness Tests | HIGH | LOW | **P1** |
| Cross-SDK Parity Matrix | HIGH | MEDIUM | **P1** |
| Error Handling Tests | HIGH | MEDIUM | **P1** |
| Empty Results Handling | HIGH | LOW | **P1** |
| Input Validation Tests | HIGH | LOW | **P1** |
| Basic Latency Metrics | HIGH | MEDIUM | **P1** |
| Basic Throughput Metrics | HIGH | MEDIUM | **P1** |
| CI Integration | HIGH | LOW | **P1** |
| Connection Lifecycle Tests | MEDIUM | MEDIUM | **P2** |
| Retry Behavior Tests | MEDIUM | MEDIUM | **P2** |
| Multi-Topology Testing | HIGH | HIGH | **P2** |
| Performance Regression Detection | HIGH | MEDIUM | **P2** |
| Edge Case Fuzzing | MEDIUM | HIGH | **P2** |
| SDK Benchmark Parity | MEDIUM | HIGH | **P3** |
| Chaos/Fault Injection | MEDIUM | HIGH | **P3** |
| Concurrent Client Testing | MEDIUM | HIGH | **P3** |
| Long-Running Stability | LOW | HIGH | **P3** |

**Priority key:**
- P1: Must have for milestone completion
- P2: Should have, add when time permits
- P3: Nice to have, future consideration

## Benchmark Metrics Specification

### Essential Metrics (Must Track)

| Metric | Description | Collection Method |
|--------|-------------|-------------------|
| **Throughput** | Operations per second | Total ops / wall clock time |
| **Latency p50** | Median response time | 50th percentile of sorted samples |
| **Latency p95** | 95th percentile | 5% worst-case experience |
| **Latency p99** | 99th percentile | Near worst-case, SLA target |
| **Error Rate** | Failed operations / total | Count errors, compute ratio |

### Advanced Metrics (Should Track)

| Metric | Description | Use Case |
|--------|-------------|----------|
| **Latency p99.9** | 99.9th percentile | Tail latency analysis |
| **Mean** | Average latency | Capacity planning per bench.zig |
| **Std Dev** | Latency variance | Consistency assessment |
| **95% Confidence Interval** | Statistical range | Significance testing |
| **Outliers Removed** | Samples excluded | Understanding data quality |

### Anti-Patterns to Avoid

| Anti-Pattern | Why Bad | Better Approach |
|--------------|---------|-----------------|
| **Reporting only averages** | Hides tail latency issues | Always report p95/p99 |
| **Too few samples** | Statistically meaningless | Minimum 30 runs per config |
| **No warmup period** | JIT/cache effects skew results | Discard first 10% of samples |
| **Fixed test duration** | May end mid-operation | Use operation count targets |
| **Comparing across hardware** | Different machines, different results | Compare PR vs main on same CI runner |
| **Synthetic workloads only** | Miss real usage patterns | Include workload pattern tests |

## Existing Assets to Leverage

### From Current Codebase

| Asset | Location | Reuse Potential |
|-------|----------|-----------------|
| SDK Test Scripts | docs/plans/2026-01-31-comprehensive-sdk-testing.md | HIGH - formalize into reusable framework |
| Geo Workload Generator | src/testing/geo_workload.zig | HIGH - adversarial patterns, workload simulation |
| Benchmark Harness | src/testing/bench.zig | HIGH - statistical analysis, CI integration |
| Performance Baselines | docs/testing/performance-baselines.md | HIGH - regression detection framework |
| Existing Benchmarks | docs/benchmarks.md | HIGH - target metrics defined |
| Error Codes | docs/error-codes.md | HIGH - comprehensive error handling tests |
| SDK Retry Semantics | docs/sdk-retry-semantics.md | HIGH - retry behavior test cases |

### From Recent Testing Work

| Asset | Status | Reuse Potential |
|-------|--------|-----------------|
| Python test script | Validated (93% pass) | Template for formal test harness |
| Node.js test script | Validated (86% pass) | Template for formal test harness |
| Go test script | Validated (93% pass) | Template for formal test harness |
| Java test script | Validated (71% pass) | Template for formal test harness |
| SDK operation matrix | Complete | Requirements baseline |
| Known limitations | Documented | Skip/expected-failure annotations |

## Test Environment Specifications

### Resource-Constrained Testing (Default)

Per CLAUDE.md recommendations:

| Profile | RAM | Cores | Use Case |
|---------|-----|-------|----------|
| Minimal | ~2GB | 2 | `-j2 -Dconfig=lite` - heavy server load |
| Constrained | ~4GB | 4 | `-j4 -Dconfig=lite` - normal development |
| Full | ~8GB+ | 8 | Default - CI or dedicated machine |

### Cluster Configurations for Testing

| Config | Command | RAM per Node | Total RAM |
|--------|---------|--------------|-----------|
| 1-node | `--replica-count=1` | ~130MB (lite) | ~130MB |
| 3-node | `--replica-count=3` | ~130MB (lite) | ~400MB |
| 5-node | `--replica-count=5` | ~130MB (lite) | ~650MB |
| 6-node | `--replica-count=6` | ~130MB (lite) | ~800MB |

## Sources

### Codebase Documentation (HIGH confidence)
- `/home/g/archerdb/docs/SDK-TESTING-FINAL-REPORT.md` - Recent comprehensive testing results
- `/home/g/archerdb/docs/SDK-COMPLETENESS-FINAL.md` - SDK operation matrix
- `/home/g/archerdb/docs/SDK-LIMITATIONS-AND-WORKAROUNDS.md` - Known SDK issues
- `/home/g/archerdb/docs/benchmarks.md` - Performance targets and methodology
- `/home/g/archerdb/docs/testing/performance-baselines.md` - Regression detection framework
- `/home/g/archerdb/docs/error-codes.md` - Error code reference
- `/home/g/archerdb/docs/sdk-retry-semantics.md` - Retry behavior specification
- `/home/g/archerdb/src/testing/geo_workload.zig` - Workload generator with edge cases
- `/home/g/archerdb/src/testing/bench.zig` - Benchmark harness

### External References (MEDIUM confidence)
- [A QA's Guide to Database Testing 2026](https://thectoclub.com/software-development/ultimate-guide-database-testing/) - Industry best practices
- [Azure SDK Guidelines](https://azure.github.io/azure-sdk/general_introduction.html) - Cross-language SDK consistency
- [Statistical Methods for Reliable Benchmarks](https://modulovalue.com/blog/statistical-methods-for-reliable-benchmarks/) - Percentile methodology
- [Chaos Mesh](https://deepwiki.com/chaos-mesh/chaos-mesh) - Fault injection patterns
- [Google Cloud Chaos Engineering](https://www.infoq.com/news/2025/11/google-chaos-engineering/) - Resilience testing framework

---
*Feature research for: SDK Testing & Benchmarking Suite*
*Researched: 2026-02-01*
