# Pitfalls Research: Performance & Scale

**Project:** ArcherDB Performance & Scale Milestone
**Researched:** 2026-01-24
**Focus:** Common mistakes when optimizing distributed databases for performance and scale
**Confidence:** HIGH (cross-verified with multiple sources)

---

## Measurement Pitfalls

Mistakes in profiling and benchmarking that lead to wasted effort or misleading results.

### Pitfall 1: Optimizing the Wrong Bottleneck

**What goes wrong:** Team spends months optimizing a component that contributes minimally to overall latency. Example: Rewriting hot path in assembly while the actual bottleneck is cross-region network dependencies.

**Why it happens:** Intuition about performance is frequently wrong. Developers assume they know where bottlenecks are without profiling. Studies show programmers often guess incorrectly about which code sections consume the most resources.

**Consequences:**
- Months of wasted engineering effort
- Negligible performance improvement
- Opportunity cost of not fixing the actual bottleneck
- Increased code complexity for no benefit

**Warning signs:**
- No profiling data to support optimization targets
- Decisions based on "this looks slow" rather than measurements
- Optimizing code that runs infrequently
- Micro-optimizations before macro-architecture is proven

**Prevention:**
1. Profile first, optimize second - always
2. Use flame graphs and execution profiles to identify actual hotspots
3. Measure end-to-end latency breakdown (network, disk, CPU, memory)
4. For ArcherDB specifically: instrument VSR consensus round-trip, LSM compaction, S2 cell covering calculation separately

**Phase application:** Must be addressed in Phase 1 (Measurement Infrastructure) before any optimization work begins.

### Pitfall 2: Benchmark Gaming

**What goes wrong:** Optimizations that only help synthetic benchmarks but not real-world workloads. The system performs well on published benchmarks but disappoints users.

**Why it happens:** Benchmarks become proxies for success. Teams optimize specifically for benchmark scenarios while neglecting realistic usage patterns.

**Consequences:**
- Misleading performance claims
- Customer dissatisfaction when production performance doesn't match benchmarks
- Technical debt from benchmark-specific code paths
- Loss of trust and credibility

**Warning signs:**
- Different code paths for "benchmark mode" vs normal operation
- Optimizations that assume uniform data distribution
- Tests that don't include realistic data sizes or query patterns
- P50 looks great, but P99 is terrible

**Prevention:**
1. Use production-representative workloads for all benchmarks
2. Test with realistic data distributions (hotspots, skew)
3. Measure tail latencies (P95, P99, P99.9), not just averages
4. Include mixed read/write workloads, not just pure reads or writes
5. For ArcherDB: Test with geospatial clustering (real-world location data clusters, not uniform random)

**Phase application:** Establish baseline benchmarks in Phase 1 with explicit "no benchmark gaming" policy.

### Pitfall 3: Ignoring Tail Latencies

**What goes wrong:** Focus on P50/average latency while P99 is 10-100x worse. Users experience terrible outlier performance.

**Why it happens:** Average/median metrics hide tail behavior. A single slow request in a distributed system can cause fan-out amplification.

**Consequences:**
- User-facing timeouts on seemingly simple operations
- SLA violations despite "good" average metrics
- Cascading failures when slow requests accumulate

**Warning signs:**
- Only reporting average or P50 metrics
- Large variance in latency measurements
- Users reporting "random" slow requests
- P99/P50 ratio > 10x

**Prevention:**
1. Track and report P50, P90, P95, P99, P99.9 for all operations
2. Set alerts on tail latencies, not just averages
3. For ArcherDB: Monitor S2 query cell covering time (can vary wildly by query shape), LSM compaction impact on read latency

**Phase application:** Build comprehensive latency histograms into measurement infrastructure from the start.

### Pitfall 4: Testing on Wrong Scale

**What goes wrong:** Optimizations validated at 1GB work differently at 1TB. Extrapolation from small-scale tests fails.

**Why it happens:** Testing at full scale is expensive and slow. Teams assume linear scaling or use extrapolation that doesn't account for hardware factors.

**Consequences:**
- Optimizations that work perfectly at test scale fail in production
- O(n) becomes O(n log n) or worse at scale
- Memory patterns that fit in cache at test scale cause cache thrashing at production scale

**Warning signs:**
- All tests run on local development machines
- Test datasets fit entirely in memory
- No tests beyond CI/CD's resource limits
- Linear extrapolation of performance results

**Prevention:**
1. Test at multiple scales (10x, 100x, production-scale if possible)
2. Use scaled-down tests for CI, but periodically run full-scale tests
3. Account for memory hierarchy: L1/L2/L3 cache, RAM, SSD, network
4. For ArcherDB: Test with S2 indexes spanning billions of cells, LSM trees with terabytes of data

**Phase application:** Include scale testing checkpoints throughout all optimization phases.

---

## Optimization Pitfalls

Common mistakes in the optimization work itself.

### Pitfall 5: Premature Optimization

**What goes wrong:** Optimizing code before understanding if it matters. Adding complexity for marginal gains in non-critical paths.

**Why it happens:** The famous Knuth quote: "Premature optimization is the root of all evil (or at least most of it) in programming." Developers instinctively want to make code "fast" even when it's not a bottleneck.

**Consequences:**
- Code becomes harder to understand and maintain
- Bugs introduced in "optimized" code
- Time wasted on improvements that don't matter
- Harder to make changes later

**Warning signs:**
- Optimization work without profiling data to justify it
- "This could be slow someday" reasoning
- Micro-optimizations in code that runs once per request
- Assembly or unsafe code for non-critical paths

**Prevention:**
1. Require profiling data before approving optimization work
2. Focus on the critical 3% of code that matters (per Knuth)
3. For ArcherDB: Profile before optimizing - VSR message serialization, S2 cell encoding, LSM block compression

**Phase application:** Gate all optimization work on measurement data.

### Pitfall 6: LSM-Tree Compaction Strategy Mismatch

**What goes wrong:** Using the wrong compaction strategy for the workload. Leveled compaction on write-heavy workloads causes 40x write amplification.

**Why it happens:** Default configurations are designed for general use cases. ArcherDB's geospatial workload may have different characteristics than typical key-value stores.

**Consequences:**
- Massive write amplification (up to 40x in worst cases)
- Excessive SSD wear and reduced hardware lifetime
- CPU bound on compaction instead of serving queries
- Latency spikes during compaction

**Warning signs:**
- Write throughput far below theoretical disk limits
- High CPU usage on background compaction threads
- Latency correlates with compaction activity
- SSD health degrading faster than expected

**Prevention:**
1. Choose compaction strategy based on workload profile:
   - Leveled: read-heavy, point lookups
   - Tiered/Size-tiered: write-heavy, range scans
   - FIFO: time-series with TTL
2. Monitor write amplification ratio continuously
3. For ArcherDB: Geospatial inserts are append-heavy - consider tiered compaction for geo_events table

**Phase application:** Review and benchmark compaction strategies early in storage optimization phase.

### Pitfall 7: Over-Indexing

**What goes wrong:** Creating too many indexes to speed up reads, but destroying write performance. Every insert updates N indexes.

**Why it happens:** Indexes make queries fast, so "more indexes = faster" seems logical. But each index adds write overhead.

**Consequences:**
- Write latency increases linearly with index count
- Storage bloat from index structures
- Compaction overhead multiplied by index count
- Memory pressure from index metadata

**Warning signs:**
- Insert/update latency scales with index count
- Write throughput drops as more indexes are added
- Index storage exceeds primary data storage
- 10+ milliseconds overhead per write per index

**Prevention:**
1. Audit all indexes for actual query usage
2. Use composite indexes instead of multiple single-column indexes
3. Consider covering indexes to avoid table lookups
4. For ArcherDB: S2 index is essential, but avoid adding indexes "just in case"

**Phase application:** Audit existing indexes before adding new ones in index optimization phase.

### Pitfall 8: Cache Inconsistency Under Load

**What goes wrong:** Cache layer works correctly under normal load but produces stale data under high load or network partitions.

**Why it happens:** Cache invalidation is fundamentally hard. Race conditions, network delays, and partition handling create edge cases that only appear at scale.

**Consequences:**
- Stale reads that violate application invariants
- Data corruption when stale data is used for writes
- Customer-visible bugs that are hard to reproduce
- Loss of trust in data accuracy

**Warning signs:**
- Intermittent data inconsistencies reported by users
- Issues only appear under high load
- Problems correlate with network hiccups
- Tests pass but production has issues

**Prevention:**
1. Design cache invalidation with network partition handling
2. Use versioning or vector clocks for cache entries
3. Implement bounded staleness guarantees
4. For ArcherDB: RAM index invalidation must be synchronized with LSM commits - verify under VSR view changes

**Phase application:** Include cache consistency testing in every phase that touches caching.

### Pitfall 9: Batching Backfires

**What goes wrong:** Batching operations for efficiency causes latency spikes when batches accumulate.

**Why it happens:** Batching amortizes per-operation overhead. But if batch triggers are based on count, large batches can cause latency spikes.

**Consequences:**
- Latency spikes at batch boundaries
- Unpredictable response times
- P99 far exceeds P50

**Warning signs:**
- Periodic latency spikes at regular intervals
- Throughput looks good but tail latencies are terrible
- Latency histogram shows bimodal distribution

**Prevention:**
1. Use both size and time limits for batching
2. Set maximum batch latency, not just size
3. Monitor batch wait times separately from processing times
4. For ArcherDB: VSR batching must balance throughput vs. latency

**Phase application:** Review batching parameters in consensus and storage optimization phases.

---

## Distributed System Pitfalls

Scale-specific failure modes that emerge in distributed deployments.

### Pitfall 10: Cascading Failure from Overload

**What goes wrong:** One replica becomes slow, load shifts to others, they become slow, system collapses.

**Why it happens:** Load balancers redirect from slow replicas. Without backpressure, remaining replicas inherit the load and also become overwhelmed. Positive feedback loop.

**Consequences:**
- Complete system outage from partial failure
- Recovery requires manual intervention
- Extended downtime while load drains

**Warning signs:**
- One replica CPU/memory spike followed by others
- Load balancer health checks show cascading failures
- Client retry storms visible in logs
- System doesn't recover even after initial cause resolves

**Prevention:**
1. Implement load shedding - reject requests when overloaded
2. Use circuit breakers between services
3. Rate limit client requests
4. Implement randomized exponential backoff for retries
5. For ArcherDB: Coordinate client retries with VSR view changes

**Phase application:** Build in load shedding and circuit breakers in scalability hardening phase.

### Pitfall 11: Hot Partition/Hot Key

**What goes wrong:** Data skew causes one shard/partition to receive disproportionate load. One shard becomes the bottleneck.

**Why it happens:** Real-world data isn't uniformly distributed. Popular entities, geographic clustering, or temporal patterns create hotspots.

**Consequences:**
- One shard at capacity while others idle
- Horizontal scaling doesn't help
- Latency for hot partition users much worse than others

**Warning signs:**
- Large variance in per-shard metrics
- One shard consistently at resource limits
- Adding shards doesn't improve performance for some users
- Geographic or entity-based performance complaints

**Prevention:**
1. Monitor per-shard metrics, not just aggregates
2. Use composite sharding keys to distribute hot entities
3. Implement shard splitting for detected hotspots
4. For ArcherDB: Geospatial data clusters by location - consider geo-aware sharding to prevent entire cities on one shard

**Phase application:** Critical for sharding optimization phase.

### Pitfall 12: Consensus Bottleneck at Scale

**What goes wrong:** Leader-based consensus (VSR/Raft/Paxos) becomes bottleneck as cluster grows. Leader's network bandwidth limits system throughput.

**Why it happens:** All writes go through leader. Leader must send data to all followers. Leader's outgoing bandwidth = system's write bandwidth limit.

**Consequences:**
- Write throughput doesn't scale with cluster size
- Leader becomes single point of performance bottleneck
- Cluster grows but performance doesn't

**Warning signs:**
- Leader NIC saturated before CPU or disk
- Adding replicas decreases throughput
- Leader change temporarily improves then degrades performance
- Asymmetric resource usage (leader vs. followers)

**Prevention:**
1. Limit cluster size (3-5 replicas for consensus groups)
2. Use sharding to distribute write load
3. Consider witness/observer replicas for reads
4. Implement leader offloading (followers serve reads)
5. For ArcherDB: VSR cluster size vs. throughput tradeoff must be documented

**Phase application:** Address in consensus optimization phase with clear guidance on cluster sizing.

### Pitfall 13: View Change Storm

**What goes wrong:** Network instability causes repeated view changes. System spends more time electing leaders than serving requests.

**Why it happens:** Aggressive failure detection settings. Network jitter interpreted as failures. Multiple nodes try to become leader simultaneously.

**Consequences:**
- Extended unavailability during "stable" network conditions
- Log spam from view change attempts
- Client timeouts during view changes
- Wasted resources on election attempts

**Warning signs:**
- Frequent view change log messages
- Availability metrics show regular dips
- Leader changes correlate with network latency spikes
- Split vote scenarios in logs

**Prevention:**
1. Tune election timeouts conservatively
2. Use randomized election delays to prevent split votes
3. Implement stable leader detection before triggering change
4. For ArcherDB: Test VSR behavior under network latency jitter, tune timeouts accordingly

**Phase application:** Include in consensus optimization phase with specific timeout tuning.

### Pitfall 14: State Transfer Overwhelm

**What goes wrong:** New/recovered replica requesting full state transfer overwhelms leader or network.

**Why it happens:** State transfer is expensive. If multiple replicas recover simultaneously or state is very large, it can saturate network or leader.

**Consequences:**
- Leader performance degradation during replica recovery
- Cascading failures if leader becomes overloaded
- Extended recovery time

**Warning signs:**
- Performance dips correlate with replica restarts
- Large network traffic spikes during recovery
- Recovery taking hours instead of minutes

**Prevention:**
1. Implement incremental state transfer
2. Rate limit state transfer bandwidth
3. Use checkpoints to reduce transfer size
4. Allow state transfer from followers, not just leader
5. For ArcherDB: VSR recovery should stream from checkpoint, not full log replay

**Phase application:** Address in recovery optimization within consensus phase.

---

## Code Quality Pitfalls

Maintainability and correctness concerns when optimizing.

### Pitfall 15: Optimization Introduces Bugs

**What goes wrong:** Performance optimization introduces correctness bugs. System is faster but occasionally produces wrong results.

**Why it happens:** Optimizations add complexity. Edge cases missed. Fast path assumes invariants that slow path enforced. Research shows database systems have many optimization bugs.

**Consequences:**
- Silent data corruption
- Hard-to-reproduce bugs
- Customer trust destroyed
- Expensive debugging and remediation

**Warning signs:**
- Test suite doesn't cover optimized code paths
- Optimization changes assumptions about input data
- "This should always be true" comments without assertions
- Optimization bypasses validation for speed

**Prevention:**
1. Maintain identical test coverage for optimized and unoptimized paths
2. Use property-based testing to find edge cases
3. Implement differential testing (compare optimized vs. unoptimized results)
4. For ArcherDB: Use VOPR (deterministic simulation) to test optimized code paths

**Phase application:** Every optimization phase must include correctness testing.

### Pitfall 16: Complexity Explosion

**What goes wrong:** Each optimization adds complexity. After 10 optimizations, code is unmaintainable. Future changes become high-risk.

**Why it happens:** Each optimization seems justified individually. Cumulative complexity not tracked. "Tech debt" accumulated for performance.

**Consequences:**
- Development velocity decreases over time
- New team members can't understand code
- Bugs in "optimized" code hard to fix
- Fear of touching optimized sections

**Warning signs:**
- Functions grow to hundreds of lines
- Multiple special cases and branches
- Comments explaining "why this is weird"
- Team avoids touching certain files

**Prevention:**
1. Set complexity budget - track cyclomatic complexity
2. Require optimization code review by non-author
3. Document optimization rationale and invariants
4. Prefer algorithmic improvements over micro-optimizations
5. For ArcherDB: Zig comptime optimizations are preferred over runtime branches

**Phase application:** Code review gates for all optimization PRs with complexity tracking.

### Pitfall 17: Allocator Misuse in Zig

**What goes wrong:** Wrong allocator choice causes performance issues or memory problems. GeneralPurposeAllocator used in hot path.

**Why it happens:** Zig's explicit allocator model requires conscious choices. Default choices may not be optimal for specific use cases.

**Consequences:**
- Memory allocation overhead in critical paths
- Memory fragmentation over time
- OOM from allocator overhead
- Unpredictable latency from allocation

**Warning signs:**
- Profiler shows time in allocator functions
- Memory usage higher than data size would suggest
- Latency spikes correlate with allocation patterns
- Memory not returned to OS after data deleted

**Prevention:**
1. Use arena allocators for request-scoped data
2. Use FixedBufferAllocator or pool allocators for hot paths
3. Use SmpAllocator or c_allocator for multi-threaded production
4. Profile allocator overhead specifically
5. For ArcherDB: Review allocator choices in request handling paths

**Phase application:** Include allocator audit in memory optimization phase.

### Pitfall 18: S2 Cell Covering Over-Computation

**What goes wrong:** S2 cell covering computed repeatedly for the same query pattern. Expensive calculation done redundantly.

**Why it happens:** S2 cell covering is non-trivial computation. If not cached or memoized, repeated queries pay full cost.

**Consequences:**
- CPU-bound on cell covering instead of data access
- Increased query latency
- Wasted computation

**Warning signs:**
- Profiler shows time in S2 covering functions
- Query latency doesn't improve with caching
- CPU usage high even with small result sets

**Prevention:**
1. Cache cell coverings for repeated query patterns
2. Use appropriate s2_max_cells settings (8-12 is usually sufficient)
3. Pre-compute coverings for common query shapes
4. For ArcherDB: Consider covering cache for frequent radius query sizes

**Phase application:** Address in geospatial optimization phase.

---

## Prevention Strategies

Consolidated strategies to avoid pitfalls across all phases.

### Strategy 1: Measurement-First Culture

**Principle:** No optimization without measurement data to justify it.

**Implementation:**
- Require profiling results in optimization PR descriptions
- Track baseline metrics before any optimization work
- Alert on performance regressions in CI/CD
- Use 3-5 run averaging to handle variance

**Tools:**
- Flame graphs for CPU profiling
- Latency histograms with percentiles
- Per-operation metrics
- A/B testing framework for optimization validation

### Strategy 2: Correctness Guards

**Principle:** Every optimization must be proven correct, not just fast.

**Implementation:**
- Differential testing: compare optimized vs. unoptimized results
- Property-based testing for edge cases
- VOPR simulation for distributed behavior
- Fuzz testing for input handling

**Checkpoints:**
- Optimization PR requires test coverage report
- CI runs both optimized and unoptimized paths
- Performance tests also verify correctness

### Strategy 3: Incremental Delivery

**Principle:** Ship optimizations incrementally with rollback capability.

**Implementation:**
- Feature flags for optimization code paths
- Staged rollout (canary deployments)
- Automatic rollback on regression detection
- Version both optimized and baseline code

**Benefits:**
- Can quickly disable problematic optimizations
- Production validation before full rollout
- Lower risk per change

### Strategy 4: Complexity Budget

**Principle:** Track and limit code complexity added by optimizations.

**Implementation:**
- Measure cyclomatic complexity before/after
- Set per-file and per-function complexity limits
- Require refactoring if optimization exceeds budget
- Document optimization rationale in code comments

**Metrics:**
- Lines of code change
- Branch count increase
- New special cases added
- Abstraction violations

### Strategy 5: Scale Testing Checkpoints

**Principle:** Validate at multiple scales, not just development scale.

**Implementation:**
- Unit tests: small scale, fast feedback
- Integration tests: medium scale, realistic scenarios
- Performance tests: production scale, periodic
- Chaos testing: failure modes at scale

**For ArcherDB:**
- Test with 1GB, 100GB, 1TB data sizes
- Test with 10K, 100K, 1M concurrent entities
- Test with 3, 5, 7 replica clusters
- Test with realistic geographic distribution

---

## Warning Signs Summary

Quick reference for early detection of pitfalls.

| Category | Warning Sign | Immediate Action |
|----------|--------------|------------------|
| Measurement | No profiling data for optimization | Stop, profile first |
| Measurement | P99/P50 ratio > 10x | Investigate tail latency causes |
| Measurement | Latency variance > 50% | Check for external factors |
| LSM | Write amplification > 20x | Review compaction strategy |
| LSM | Compaction CPU > 50% | Reduce compaction aggressiveness |
| Cache | Intermittent stale reads | Audit invalidation logic |
| Cache | Issues only under load | Test race conditions |
| Distributed | One replica overloaded | Check load balancing, add shedding |
| Distributed | Frequent view changes | Tune election timeouts |
| Distributed | Recovery takes hours | Implement incremental transfer |
| Code | Function > 200 lines | Refactor before adding more |
| Code | "This is weird" comments | Document or simplify |
| Zig | Allocator in profiler | Use arena/pool allocators |
| S2 | CPU in covering functions | Cache coverings |

---

## Phase-Specific Warnings

| Phase | Likely Pitfall | Mitigation |
|-------|---------------|------------|
| Measurement & Profiling | Wrong metrics | Track full latency distribution |
| LSM Optimization | Compaction mismatch | Benchmark strategies for workload |
| Consensus Optimization | View change tuning | Conservative timeouts, randomization |
| Index Optimization | Over-indexing | Audit actual query patterns |
| Memory Optimization | Allocator misuse | Profile allocator overhead |
| Geospatial Optimization | S2 over-computation | Cache cell coverings |
| Caching Layer | Invalidation races | Test under partition |
| Sharding | Hot partitions | Monitor per-shard metrics |
| Load Testing | Benchmark gaming | Use production-like workloads |

---

## Sources

### Distributed Database Optimization
- [Distributed Database Performance Tuning Best Practices](https://daily.dev/blog/distributed-database-performance-tuning-10-best-practices)
- [Common Mistakes Designing High-Load Database Architecture](https://aerospike.com/blog/common-mistakes-designing-a-high-load-database-architecture/)
- [CockroachDB Tips for Distributed SQL](https://www.cockroachlabs.com/blog/oreilly-tips-distributed-sql-database/)

### LSM-Tree and Write Amplification
- [Strategies to Minimize Write Amplification](https://medium.com/@tusharmalhotra_81114/strategies-to-minimize-write-amplification-in-databases-e28a9939f34c)
- [TiKV B-Tree vs LSM-Tree](https://tikv.org/deep-dive/key-value-engine/b-tree-vs-lsm/)
- [ScyllaDB Write-Heavy Workloads](https://www.scylladb.com/2025/02/04/real-time-write-heavy-workloads-considerations-tips/)
- [Towards Flexibility and Robustness of LSM Trees](https://link.springer.com/article/10.1007/s00778-023-00826-9)

### Distributed Consensus
- [Viewstamped Replication Revisited](http://pmg.csail.mit.edu/papers/vr-revisited.pdf)
- [Paxos vs Raft Analysis](https://arxiv.org/pdf/2004.05074)
- [Google SRE Distributed Consensus](https://sre.google/sre-book/managing-critical-state/)
- [Implementing Viewstamped Replication Protocol](https://distributed-computing-musings.com/2023/10/implementing-viewstamped-replication-protocol/)

### Cache Invalidation
- [Cache Made Consistent - Facebook Engineering](https://engineering.fb.com/2022/06/08/core-infra/cache-made-consistent/)
- [Why Cache Invalidation is Hard](https://newsletter.scalablethread.com/p/why-cache-invalidation-is-hard)
- [Solving Distributed Cache Invalidation](https://www.milanjovanovic.tech/blog/solving-the-distributed-cache-invalidation-problem-with-redis-and-hybridcache)

### Cascading Failures
- [Google SRE Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/)
- [How to Avoid Cascading Failures - InfoQ](https://www.infoq.com/articles/anatomy-cascading-failure/)
- [AWS Minimizing Correlated Failures](https://aws.amazon.com/builders-library/minimizing-correlated-failures-in-distributed-systems/)
- [How Distributed Systems Fail](https://robertovitillo.com/how-distributed-systems-fail/)

### S2 Geometry Indexing
- [S2 Cell Hierarchy Documentation](https://s2geometry.io/devguide/s2cell_hierarchy.html)
- [CockroachDB Spatial Indexes](https://www.cockroachlabs.com/docs/stable/spatial-indexes)
- [BigQuery Spatial Clustering Best Practices](https://cloud.google.com/blog/products/data-analytics/best-practices-for-spatial-clustering-in-bigquery)

### Performance Testing and Regression
- [Integrating Performance Testing into CI/CD](https://devops.com/integrating-performance-testing-into-ci-cd-a-practical-framework/)
- [BrowserStack CI/CD Regression Challenges](https://www.browserstack.com/guide/regression-test-cicd-challenges)
- [Detecting Optimization Bugs in Database Engines](https://www.manuelrigger.at/preprints/NoREC.pdf)

### Premature Optimization
- [Why Premature Optimization is Evil - GeeksforGeeks](https://www.geeksforgeeks.org/software-engineering/premature-optimization/)
- [ACM Ubiquity - Fallacy of Premature Optimization](https://ubiquity.acm.org/article.cfm?id=1513451)
- [ACM Queue - Performance Anti-Patterns](https://queue.acm.org/detail.cfm?id=1117403)

### Zig Memory Management
- [Zig Guide - Allocators](https://zig.guide/standard-library/allocators/)
- [Zig Patterns - Gotta Alloc Fast](https://zig.news/xq/cool-zig-patterns-gotta-alloc-fast-23h)
- [Leveraging Zig's Allocators](https://www.openmymind.net/Leveraging-Zigs-Allocators/)

---

*Pitfalls research completed: 2026-01-24*
