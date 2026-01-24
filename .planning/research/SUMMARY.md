# Project Research Summary

**Project:** ArcherDB v2.0 Performance & Scale
**Domain:** Enterprise distributed geospatial database optimization
**Researched:** 2026-01-24
**Confidence:** HIGH

## Executive Summary

ArcherDB v2.0 Performance & Scale is an optimization milestone targeting enterprise readiness through profiling, tuning, and scale-out improvements. The research reveals that ArcherDB already has solid foundations (VSR consensus, LSM-tree storage, S2 indexing, io_uring I/O), but lacks the measurement infrastructure and tuning necessary to reach enterprise-scale targets (100M+ entities, sub-millisecond queries, 10x read scaling).

The recommended approach is measurement-first: build comprehensive profiling infrastructure before any optimization work. Focus on well-understood optimization spaces (LSM compaction tuning, RAM index memory optimization, cache sizing) before tackling higher-risk areas (consensus tuning, online resharding). Leverage existing instrumentation (trace.zig, StatsD metrics, benchmark harness) and add external profiling tools (Linux perf, Tracy, POOP). The architecture supports these optimizations through clear integration points in VSR replica loop, LSM compaction scheduler, and grid cache.

The key risk is premature optimization without measurement data, which research shows leads to months of wasted effort on the wrong bottlenecks. Secondary risks include LSM compaction strategy mismatch (40x write amplification), cache invalidation races under load, and cascading failures from overload. All are mitigated by following measurement-first culture, correctness testing gates, and incremental delivery with rollback capability.

## Key Findings

### Recommended Stack

ArcherDB has strong existing infrastructure that should be leveraged, plus targeted additions for deeper analysis. The stack focuses on complementing existing trace.zig/StatsD metrics with external profiling tools that provide hardware counter access and real-time visualization.

**Core profiling tools (must have):**
- **Linux perf**: CPU profiling and flamegraphs — native hardware counters, minimal overhead, verified working with Zig's frame pointer preservation
- **POOP (Andrew Kelley)**: A/B benchmark comparison — Zig-native, reports 5 hardware counters alongside timing, better than hyperfine for Zig code
- **Zig DebugAllocator**: Memory leak detection — built-in stdlib, zero dependencies, tracks allocations/frees
- **hyperfine**: Statistical CLI benchmarking — cross-platform, handles warmup/outliers, CI integration

**Deeper analysis tools (should have):**
- **Tracy (ztracy)**: Real-time instrumentation visualization — on-demand mode is production-safe, complements trace.zig
- **Valgrind Massif**: Heap profiling — detailed allocation sites, works with c_allocator
- **Grafana + Prometheus**: Production monitoring — ArcherDB already emits StatsD, just needs visualization layer

**Deferred tools:**
- **Parca**: eBPF continuous profiling — only needed if Tracy on-demand mode is insufficient
- **Bencher**: Continuous benchmark tracking — nice for CI but not essential for initial work

**Confidence:** HIGH for must-have tools (verified in codebase), MEDIUM for Tracy integration (zig-gamedev/ztracy verified but not tested with ArcherDB)

### Expected Features

Enterprise customers have clear expectations for performance and scale capabilities. The research identified table stakes features (missing these = not enterprise-ready) versus competitive differentiators.

**Must have (table stakes):**
- **Data Compression** — 40-80% storage cost reduction, LZ4 for hot data / Zstd for cold
- **Query Result Caching** — 80%+ cache hit ratio expected for dashboard refresh patterns
- **Connection Pooling** — Prevents connection storms (each conn ~140KB per Tile38)
- **Batch Query API** — N+1 query pattern kills performance
- **Query Performance Metrics** — Track P50/P99 by query type, required for enterprise support
- **Read Replicas** — 10x read scaling without consensus overhead
- **Distributed Tracing** — OpenTelemetry integration, 75% of orgs now use it
- **Bulk Import/Export** — Load millions of historical positions for migrations

**Should have (competitive advantage):**
- **Sub-millisecond Queries** — 100K+ QPS for dashboard workloads, RAM index already achieves this for UUID lookups
- **Query Explain/Analyze** — PostGIS's EXPLAIN is beloved, show S2 cell coverage and index usage
- **Adaptive Rate Limiting** — Protect cluster from query storms
- **Hot Shard Detection** — Identify and rebalance hot spots, geospatial data clusters by location

**Defer (v2+):**
- **Real-Time Geofencing** — Tile38's killer feature but high complexity, use CDC + external service for now
- **Tiered Storage** — Important but not urgent for initial enterprise deals
- **100M+ Entity Support** — Optimize when customers hit 10M first
- **Live Query Subscriptions** — Advanced feature, wait for customer demand

**Anti-features (explicitly avoid):**
- Full SQL support (PostGIS already exists)
- General-purpose secondary indexes (scope creep)
- ACID transactions across entities (VSR gives per-entity linearizability, cross-entity adds huge complexity)
- Synchronous multi-region writes (100ms+ latency penalty)

**Complexity assessment:** Most table stakes are Medium complexity (2-4 weeks each). Connection pooling, batch queries, and metrics are Low complexity (1-2 weeks). Read replicas and distributed tracing are High complexity (4-8 weeks).

### Architecture Approach

ArcherDB's architecture provides clear integration points for optimization. The 148K LOC codebase is well-structured with consensus (VSR), storage (LSM-tree), indexing (RAM + S2), caching (grid), and sharding layers.

**Major components and optimization vectors:**

1. **VSR Consensus Layer** (src/vsr/replica.zig)
   - Tuning: pipeline_prepare_queue_max (8 -> 128), Flexible Paxos quorum reduction, tick_ms frequency
   - Metrics already present via archerdb_metrics.Registry
   - Risk: HIGH for consensus changes, defer until other optimizations measured

2. **LSM-tree Storage** (src/lsm/compaction.zig)
   - Current: tiered compaction, growth_factor=8, lsm_levels=7
   - Write amplification: ~24x for default config
   - Optimization: parallel compaction, adaptive scheduling, TTL-aware compaction priority
   - Risk: MEDIUM, well-understood optimization space

3. **RAM Index** (src/ram_index.zig)
   - Current: 64B IndexEntry or 32B CompactIndexEntry, target_load_factor=0.70
   - Memory for 1B entities: ~91.5GB (standard) or ~45.7GB (compact)
   - Optimization: SIMD probe comparison, improve online rehash, auto-select compact format
   - Risk: MEDIUM, clear implementation with online rehash existing

4. **Grid Cache** (src/vsr/grid.zig)
   - Current: 16-way set-associative, CLOCK eviction
   - Optimization: cache sizing (recommend 4GB+ for enterprise), prefetching during scan
   - Risk: LOW, standard cache patterns

5. **Sharding** (src/sharding.zig)
   - Current: jump hash (O(1) memory, O(log N) compute), fixed shard count at creation
   - Optimization: online resharding (breaking change), spatial sharding for query locality
   - Risk: HIGH for online resharding, complex dual-write coordination

6. **Replication** (src/replication.zig)
   - Current: async log shipping to follower regions
   - Optimization: read replica routing, faster follower catch-up
   - Risk: MEDIUM, async replication exists but read routing not implemented

**Suggested build order:**
1. Profiling Infrastructure → 2. LSM Compaction Tuning → 3. RAM Index Optimization → 4. Grid Cache Tuning → 5. VSR Consensus Tuning → 6. Sharding & Scale-out

**Breaking changes considered:**
- **Online Resharding** (HIGH impact): Add shard_epoch to superblock, dual-write period, background migration
- **Compact Index Format Default** (MEDIUM impact): Default new clusters to 32B entries (50% memory reduction)
- **Flexible Paxos Quorum** (LOW impact): Config change only, allow quorum_replication < majority

### Critical Pitfalls

Research identified 18 pitfalls across measurement, optimization, distributed systems, and code quality. Top 5 by severity:

1. **Optimizing the Wrong Bottleneck** — Spending months on non-critical paths without profiling data. Prevention: Profile first with flame graphs, measure end-to-end latency breakdown (network, disk, CPU, memory), instrument VSR/LSM/S2 separately. Phase: Must address in Phase 1 before any optimization.

2. **LSM Compaction Strategy Mismatch** — Using leveled compaction on write-heavy workloads causes 40x write amplification. Prevention: Choose strategy based on workload (tiered for write-heavy geo inserts), monitor write amplification continuously. Phase: Review in Phase 2 (storage optimization).

3. **Cascading Failure from Overload** — One slow replica causes load shift, overwhelming others in positive feedback loop. Prevention: Implement load shedding (reject when overloaded), circuit breakers, rate limiting, coordinate retries with VSR view changes. Phase: Build into Phase 5 (scalability).

4. **Cache Invalidation Races** — Cache works under normal load but produces stale data under high load or partitions. Prevention: Design invalidation with partition handling, verify RAM index invalidation synchronized with LSM commits under VSR view changes. Phase: Test in every phase touching caching.

5. **Premature Optimization** — Adding complexity before understanding if it matters. Prevention: Require profiling data for all optimization PRs, focus on critical 3% of code, profile VSR serialization, S2 encoding, LSM compression before optimizing. Phase: Gate all work on measurement.

**Additional critical pitfalls:**
- **Tail Latencies Ignored** (P99/P50 ratio > 10x) — Track P50/P90/P95/P99/P99.9, monitor S2 covering time variance
- **Hot Partitions** — Geospatial data clusters by location, monitor per-shard metrics, consider geo-aware sharding
- **View Change Storm** — Tune election timeouts conservatively, test VSR under network latency jitter
- **S2 Over-Computation** — Cache cell coverings for repeated query patterns, use s2_max_cells=8-12

**Prevention strategies:**
- Measurement-first culture: No optimization without profiling data
- Correctness guards: Differential testing, VOPR simulation, fuzz testing
- Incremental delivery: Feature flags, staged rollout, automatic rollback
- Complexity budget: Track cyclomatic complexity before/after
- Scale testing checkpoints: 1GB / 100GB / 1TB data sizes

## Implications for Roadmap

Based on combined research, recommend 6-phase structure following dependency order from low-risk/high-value to high-risk/high-complexity.

### Phase 1: Measurement & Profiling Infrastructure

**Rationale:** Cannot optimize without measurement. All research sources emphasize "profile first, optimize second." This is the foundation for all subsequent phases.

**Delivers:**
- Profiling framework (src/testing/profiler.zig) with wall-clock timing, CPU counters, memory tracking, I/O stats
- Latency histograms in metrics layer (P50/P90/P95/P99/P99.9)
- Timing hooks in replica tick loop
- Integration with Linux perf, POOP, hyperfine
- Baseline benchmarks with "no gaming" policy

**Addresses features:**
- Query Performance Metrics (table stakes)
- Foundation for all other optimizations

**Avoids pitfalls:**
- Optimizing the Wrong Bottleneck
- Premature Optimization
- Ignoring Tail Latencies
- Testing on Wrong Scale

**Risk:** LOW — Pure measurement, no performance changes
**Effort:** 1-2 weeks
**Research needed:** No (tools well-documented)

### Phase 2: LSM-Tree Storage Optimization

**Rationale:** LSM compaction directly impacts write throughput. Well-understood optimization space with clear integration points in src/lsm/compaction.zig.

**Delivers:**
- Document enterprise/mid-tier/lite presets in src/config.zig
- Tunable compaction parameters via CLI flags
- Parallel tree compaction for multiple trees
- TTL-aware compaction priority
- Write amplification monitoring

**Addresses features:**
- Data Compression (table stakes, LZ4/Zstd integration)
- Foundation for tiered storage (deferred to v2+)

**Uses stack:**
- Existing LSM infrastructure
- Valgrind Massif for heap profiling
- perf for compaction CPU analysis

**Avoids pitfalls:**
- LSM Compaction Strategy Mismatch
- Write amplification > 20x
- Benchmark Gaming (test with realistic geo workloads)

**Risk:** MEDIUM — Compaction changes need validation
**Effort:** 3-4 weeks
**Research needed:** No (RocksDB patterns well-documented)

### Phase 3: RAM Index & Memory Optimization

**Rationale:** Memory efficiency critical for 100M+ entity support. RAM index is O(1) but probe length and format matter at scale.

**Delivers:**
- SIMD hash comparison for probe acceleration (optional)
- Improved online rehash (reduce blocking)
- Auto-select compact format (32B entries for 50% memory reduction)
- Memory usage reporting and tracking
- Allocator audit for hot paths

**Addresses features:**
- 100M+ Entity Support foundation (deferred full feature)
- Memory efficiency for enterprise scale

**Uses stack:**
- Zig DebugAllocator for leak detection
- Valgrind Massif for heap analysis
- Arena/pool allocator patterns

**Avoids pitfalls:**
- Allocator Misuse in Zig
- Testing on Wrong Scale (test with 1B entity memory footprint)

**Risk:** MEDIUM — Online rehash complexity
**Effort:** 2-3 weeks
**Research needed:** No (clear implementation in ram_index.zig)

### Phase 4: Query Performance & Caching

**Rationale:** 80%+ cache hit ratio expected for enterprise dashboards. Quick wins available (batch queries, result caching) before complex distributed features.

**Delivers:**
- Query result caching with LRU + TTL invalidation
- Batch spatial queries (extend existing batch UUID pattern)
- Query performance insights (pg_stat_statements equivalent)
- S2 cell covering cache for repeated patterns
- Grid cache tuning and hit/miss metrics

**Addresses features:**
- Query Result Caching (table stakes)
- Batch Query API (table stakes)
- Sub-millisecond Queries (competitive advantage)
- Query Explain/Analyze foundation

**Uses stack:**
- Existing grid cache infrastructure
- Tracy for cache hit analysis
- perf for S2 covering profiling

**Avoids pitfalls:**
- S2 Cell Covering Over-Computation
- Cache Inconsistency Under Load (test invalidation during VSR view changes)

**Risk:** MEDIUM — Cache invalidation correctness
**Effort:** 3-4 weeks
**Research needed:** Partial (cache invalidation patterns for distributed system)

### Phase 5: Consensus & Cluster Optimization

**Rationale:** VSR changes are highest risk. Defer until other optimizations measured and validated. Focus on connection pooling (low-risk) before consensus tuning (high-risk).

**Delivers:**
- Connection pooling (server-side, pgbouncer-style)
- Flexible Paxos analysis and tuning
- Pipeline depth experiments (pipeline_prepare_queue_max)
- Tick frequency tuning for latency
- Load shedding and adaptive rate limiting

**Addresses features:**
- Connection Pooling (table stakes)
- Adaptive Rate Limiting (competitive advantage)
- Automatic Failover monitoring (table stakes, VSR already handles)

**Uses stack:**
- Existing VSR infrastructure
- Tracy for replica timing
- Grafana + Prometheus for production monitoring

**Avoids pitfalls:**
- View Change Storm (conservative timeouts, randomization)
- Cascading Failure from Overload (load shedding, circuit breakers)
- Consensus Bottleneck at Scale (document cluster sizing limits)

**Risk:** HIGH for consensus tuning — Extensive testing required
**Effort:** 4-6 weeks
**Research needed:** Yes (Flexible Paxos validation, timeout tuning experiments)

### Phase 6: Sharding, Replication & Scale-Out

**Rationale:** Scale-out features only pursued after single-node performance optimized. Online resharding is breaking change, coordinate with v2.0 major version.

**Delivers:**
- Read replica routing (route reads to backups)
- Online resharding protocol (dual-write, background migration)
- Hot shard detection and monitoring
- Distributed tracing (OpenTelemetry integration)
- Bulk import/export for migrations

**Addresses features:**
- Read Replicas (table stakes, 10x read scaling)
- Distributed Tracing (table stakes)
- Hot Shard Detection (competitive advantage)
- Bulk Import/Export (table stakes)

**Uses stack:**
- Existing sharding and replication infrastructure
- Grafana stack for distributed monitoring
- Jaeger/OpenTelemetry for tracing (optional)

**Implements architecture:**
- Online resharding (breaking change, add shard_epoch to superblock)
- Read routing from src/replication.zig

**Avoids pitfalls:**
- Hot Partition/Hot Key (per-shard metrics, geo-aware sharding consideration)
- State Transfer Overwhelm (rate limit, checkpoint-based recovery)
- Complexity Explosion (feature flags for rollback)

**Risk:** HIGH — Breaking changes, dual-write coordination
**Effort:** 6-8 weeks
**Research needed:** Yes (online resharding protocols, OpenTelemetry integration)

### Phase Ordering Rationale

**Dependency-driven:**
- Measurement (Phase 1) must precede all optimization (validates efforts)
- LSM/memory (Phases 2-3) are independent single-node optimizations (can parallelize)
- Caching (Phase 4) depends on query patterns from Phases 2-3
- Consensus (Phase 5) highest risk, needs all prior phases validated first
- Scale-out (Phase 6) requires stable single-node performance foundation

**Risk-ordered:**
- Low-risk measurement first → medium-risk storage/memory → high-risk consensus/sharding
- Breaking changes (online resharding, compact index default) grouped in Phase 6 for v2.0 coordination

**Value-ordered:**
- Quick wins (metrics, compression, batch queries) in early phases
- Complex features (read replicas, distributed tracing) deferred until foundations solid

### Research Flags

**Phases likely needing deeper research during planning:**

- **Phase 4 (Query/Caching):** Cache invalidation patterns for distributed systems — sparse ArcherDB-specific guidance, need VSR-aware invalidation research
- **Phase 5 (Consensus):** Flexible Paxos validation — theoretical benefits documented, need empirical validation for ArcherDB's VSR implementation
- **Phase 6 (Scale-out):** Online resharding protocols — complex coordination, research dual-write patterns and migration strategies

**Phases with standard patterns (skip research-phase):**

- **Phase 1 (Measurement):** Well-documented profiling tools, clear integration
- **Phase 2 (LSM):** RocksDB compaction strategies well-researched, direct application to ArcherDB
- **Phase 3 (Memory):** Zig allocator patterns established, ram_index.zig implementation clear

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Profiling tools verified (perf, POOP, hyperfine), Tracy integration documented via zig-gamedev/ztracy |
| Features | MEDIUM | Table stakes verified against PostGIS/Tile38 docs, complexity estimates based on similar systems |
| Architecture | HIGH | Clear integration points in codebase, existing infrastructure supports optimizations |
| Pitfalls | HIGH | Cross-verified with multiple distributed systems sources (Google SRE, AWS, academic papers) |

**Overall confidence:** HIGH

The research is grounded in ArcherDB's existing codebase (verified ARCHITECTURE.md, constants.zig, config.zig) and cross-referenced with authoritative sources (Google SRE, LSM-tree research, VSR papers). Feature priorities validated against competitor documentation (PostGIS, Tile38, Elasticsearch Geo, Aerospike). Pitfalls sourced from production experience reports and academic studies on database optimization bugs.

### Gaps to Address

**During planning:**
- **Flexible Paxos validation:** Theoretical benefits documented, but empirical validation needed for ArcherDB's specific VSR implementation. Plan experiments during Phase 5.
- **Cache invalidation specifics:** General patterns understood, but VSR view change interaction needs design work. Research during Phase 4 planning.
- **Online resharding coordination:** Multiple approaches exist (dual-write, stop-the-world, shadow shard), need to select and validate for ArcherDB's architecture. Deep dive during Phase 6 planning.

**During execution:**
- **Scale testing infrastructure:** Need production-scale test environment (1TB data, 100M entities) for Phases 3-6. Budget and provision early.
- **Benchmark workload diversity:** Ensure realistic geospatial query patterns (not uniform random), avoid benchmark gaming. Define during Phase 1.
- **Breaking change coordination:** Phases 2-6 include potential breaking changes (compact index default, online resharding protocol). Coordinate with v2.0 release plan.

## Sources

### Primary Sources (HIGH confidence)

**Codebase Analysis:**
- /home/g/archerdb/.planning/codebase/ARCHITECTURE.md — ArcherDB architecture documentation
- /home/g/archerdb/src/constants.zig — Configuration constants and tuning parameters
- /home/g/archerdb/src/config.zig — Config presets and allocator choices
- /home/g/archerdb/docs/lsm-tuning.md — LSM compaction tuning guide
- /home/g/archerdb/src/vsr/replica.zig — VSR consensus implementation
- /home/g/archerdb/src/lsm/compaction.zig — LSM compaction scheduler
- /home/g/archerdb/src/ram_index.zig — RAM index implementation with online rehash

**Official Documentation:**
- [Zig profiling on Apple Silicon](https://blog.bugsiki.dev/posts/zig-profilers/) — Tracy/perf integration
- [zig-gamedev/ztracy](https://github.com/zig-gamedev/ztracy) — Zig Tracy bindings
- [andrewrk/poop](https://github.com/andrewrk/poop) — Official Zig benchmarking tool
- [Linux perf Examples (Brendan Gregg)](https://www.brendangregg.com/perf.html) — Comprehensive perf guide
- [Valgrind Manual - Massif](https://valgrind.org/docs/manual/ms-manual.html) — Heap profiling
- [Viewstamped Replication Revisited](http://pmg.csail.mit.edu/papers/vr-revisited.pdf) — VSR paper

**Competitor Analysis:**
- [PostGIS Performance Tuning (Crunchy Data)](https://www.crunchydata.com/blog/postgis-performance-postgres-tuning)
- [Tile38 Official](https://tile38.com/) — Real-time geofencing patterns
- [Elastic Geospatial Docs](https://www.elastic.co/geospatial) — Elasticsearch geo features
- [Aerospike Geospatial](https://aerospike.com/docs/server/guide/data-types/geospatial) — S2 library usage

### Secondary Sources (MEDIUM confidence)

**LSM-Tree Optimization:**
- [LSM Compaction Mechanisms (AlibabaCloud)](https://www.alibabacloud.com/blog/an-in-depth-discussion-on-the-lsm-compaction-mechanism_596780)
- [Strategies to Minimize Write Amplification](https://medium.com/@tusharmalhotra_81114/strategies-to-minimize-write-amplification-in-databases-e28a9939f34c)
- [TiKV B-Tree vs LSM-Tree](https://tikv.org/deep-dive/key-value-engine/b-tree-vs-lsm/)
- [ScyllaDB Write-Heavy Workloads](https://www.scylladb.com/2025/02/04/real-time-write-heavy-workloads-considerations-tips/)

**Distributed Systems Pitfalls:**
- [Google SRE - Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/)
- [AWS - Minimizing Correlated Failures](https://aws.amazon.com/builders-library/minimizing-correlated-failures-in-distributed-systems/)
- [Facebook - Cache Made Consistent](https://engineering.fb.com/2022/06/08/core-infra/cache-made-consistent/)
- [Paxos vs Raft Analysis](https://arxiv.org/pdf/2004.05074)

**Performance Testing:**
- [Detecting Optimization Bugs in Database Engines](https://www.manuelrigger.at/preprints/NoREC.pdf)
- [ACM Queue - Performance Anti-Patterns](https://queue.acm.org/detail.cfm?id=1117403)
- [Integrating Performance Testing into CI/CD](https://devops.com/integrating-performance-testing-into-ci-cd-a-practical-framework/)

**Zig-Specific:**
- [Zig Guide - Allocators](https://zig.guide/standard-library/allocators/)
- [Cool Zig Patterns - Gotta Alloc Fast](https://zig.news/xq/cool-zig-patterns-gotta-alloc-fast-23h)
- [Leveraging Zig's Allocators](https://www.openmymind.net/Leveraging-Zigs-Allocators/)

### Tertiary Sources (for validation)

**S2 Geometry:**
- [S2 Cell Hierarchy Documentation](https://s2geometry.io/devguide/s2cell_hierarchy.html)
- [CockroachDB Spatial Indexes](https://www.cockroachlabs.com/docs/stable/spatial-indexes)
- [BigQuery Spatial Clustering Best Practices](https://cloud.google.com/blog/products/data-analytics/best-practices-for-spatial-clustering-in-bigquery)

**Enterprise Database Requirements:**
- [Enterprise Database Features Guide](https://hevodata.com/learn/enterprise-database-features/)
- [Fleet Management Requirements](https://www.simplyfleet.app/blog/fleet-management-requirements)
- [RTO/RPO Best Practices](https://www.veeam.com/blog/recovery-time-recovery-point-objectives.html)

---

*Research completed: 2026-01-24*
*Ready for roadmap: yes*
