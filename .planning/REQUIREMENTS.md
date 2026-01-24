# Requirements: ArcherDB v2.0 Performance & Scale

**Defined:** 2026-01-24
**Core Value:** Correctness, performance, and completeness with no compromises

## v2.0 Requirements

Requirements for enterprise-scale performance. Each maps to roadmap phases.

### Profiling & Measurement

- [ ] **PROF-01**: CPU profiling with Linux perf integration (frame pointers preserved)
- [ ] **PROF-02**: POOP benchmarking for Zig A/B comparisons with hardware counters
- [ ] **PROF-03**: Memory allocation tracking via DebugAllocator in test builds
- [ ] **PROF-04**: Latency histograms per operation type (P50/P99/P999)
- [ ] **PROF-05**: Benchmark harness for reproducible performance tests
- [ ] **PROF-06**: Tracy real-time instrumentation with on-demand mode
- [ ] **PROF-07**: Continuous profiling infrastructure (Parca/eBPF)

### Storage Optimization

- [ ] **STOR-01**: Data compression for values (LZ4 for speed, Zstd for ratio)
- [ ] **STOR-02**: Tiered compaction strategy for write-heavy workloads
- [ ] **STOR-03**: Write amplification monitoring and metrics
- [ ] **STOR-04**: Compaction throttling to prevent I/O spikes
- [ ] **STOR-05**: Adaptive compaction (auto-tune based on workload patterns)
- [ ] **STOR-06**: Block-level deduplication for repeated values

### Memory & RAM Index

- [ ] **MEM-01**: Compact index format (32B entries, 50% memory reduction)
- [ ] **MEM-02**: Allocator audit and optimization for hot paths
- [ ] **MEM-03**: Memory usage metrics and reporting
- [ ] **MEM-04**: SIMD-accelerated index probes for lookup performance
- [ ] **MEM-05**: Memory-mapped tiering for cold data offload

### Query Performance

- [ ] **QUERY-01**: Query result caching (in-memory, configurable TTL)
- [ ] **QUERY-02**: Batch query API for multiple operations per request
- [ ] **QUERY-03**: S2 cell covering cache (reuse expensive computations)
- [ ] **QUERY-04**: Query latency breakdown (parse, plan, execute, serialize)
- [ ] **QUERY-05**: Spatial index statistics for query planning
- [ ] **QUERY-06**: Prepared query compilation for repeated patterns

### Cluster & Consensus

- [ ] **CLUST-01**: Connection pooling for client connections
- [ ] **CLUST-02**: VSR timeout tuning with randomized jitter
- [ ] **CLUST-03**: Load shedding and circuit breakers for overload protection
- [ ] **CLUST-04**: Cluster health metrics and dashboard
- [ ] **CLUST-05**: Flexible Paxos configuration (reduced quorum for latency)
- [ ] **CLUST-06**: Read replicas with async replication for read scaling

### Sharding & Scale-Out

- [ ] **SHARD-01**: Shard rebalancing metrics and visibility
- [ ] **SHARD-02**: Cross-shard query optimization (parallel fan-out)
- [ ] **SHARD-03**: Distributed tracing for full request path visibility
- [ ] **SHARD-04**: Online resharding (add/remove shards without downtime) [BREAKING]
- [ ] **SHARD-05**: Hot shard detection and automatic migration

## Future Requirements

Deferred to v2.1 or later.

### Real-Time Features

- **RT-01**: Real-time geofencing with webhook notifications
- **RT-02**: Live query subscriptions (streaming updates)
- **RT-03**: Event sourcing for location history

### Advanced Analytics

- **ANLYT-01**: Historical trajectory analysis
- **ANLYT-02**: Predictive location queries (ETA, next position)
- **ANLYT-03**: Aggregation queries (count, density heatmaps)

## Out of Scope

Explicitly excluded from v2.0.

| Feature | Reason |
|---------|--------|
| Multi-tenancy isolation | Architectural change beyond performance scope |
| SQL query language | ArcherDB is purpose-built, not general SQL |
| GPU acceleration | Complexity vs benefit ratio unfavorable |
| Automatic sharding | Manual control preferred for v2.0 |
| Cross-datacenter replication | S3 replication already handles this |

## Traceability

Which phases cover which requirements.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PROF-01 | Phase 11 | Pending |
| PROF-02 | Phase 11 | Pending |
| PROF-03 | Phase 11 | Pending |
| PROF-04 | Phase 11 | Pending |
| PROF-05 | Phase 11 | Pending |
| PROF-06 | Phase 11 | Pending |
| PROF-07 | Phase 11 | Pending |
| STOR-01 | Phase 12 | Pending |
| STOR-02 | Phase 12 | Pending |
| STOR-03 | Phase 12 | Pending |
| STOR-04 | Phase 12 | Pending |
| STOR-05 | Phase 12 | Pending |
| STOR-06 | Phase 12 | Pending |
| MEM-01 | Phase 13 | Pending |
| MEM-02 | Phase 13 | Pending |
| MEM-03 | Phase 13 | Pending |
| MEM-04 | Phase 13 | Pending |
| MEM-05 | Phase 13 | Pending |
| QUERY-01 | Phase 14 | Pending |
| QUERY-02 | Phase 14 | Pending |
| QUERY-03 | Phase 14 | Pending |
| QUERY-04 | Phase 14 | Pending |
| QUERY-05 | Phase 14 | Pending |
| QUERY-06 | Phase 14 | Pending |
| CLUST-01 | Phase 15 | Pending |
| CLUST-02 | Phase 15 | Pending |
| CLUST-03 | Phase 15 | Pending |
| CLUST-04 | Phase 15 | Pending |
| CLUST-05 | Phase 15 | Pending |
| CLUST-06 | Phase 15 | Pending |
| SHARD-01 | Phase 16 | Pending |
| SHARD-02 | Phase 16 | Pending |
| SHARD-03 | Phase 16 | Pending |
| SHARD-04 | Phase 16 | Pending |
| SHARD-05 | Phase 16 | Pending |

**Coverage:**
- v2.0 requirements: 35 total
- Mapped to phases: 35
- Unmapped: 0

---
*Requirements defined: 2026-01-24*
*Last updated: 2026-01-24 after roadmap creation*
