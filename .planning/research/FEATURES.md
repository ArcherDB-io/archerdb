# Features Research: Performance & Scale

**Domain:** Enterprise geospatial database for fleet tracking/logistics
**Researched:** 2026-01-24
**Confidence:** MEDIUM (verified against competitor docs and industry patterns)

## Table Stakes (Must Have)

Features enterprise customers expect. Missing these = product not enterprise-ready.

### Memory & Storage Efficiency

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| **Data Compression** | Reduces storage costs 40-80%, required for large datasets | Medium | LSM-tree layer | LZ4 for hot data, Zstd for cold; Aerospike gates this behind enterprise license |
| **Tiered Storage** | Hot/cold data separation saves infrastructure costs | High | LSM compaction, storage layer | PostGIS users expect this; move old positions to cheaper storage |
| **Memory-mapped Index Scaling** | RAM index must handle 10M+ entities without OOM | Medium | RAM index layer | Current mmap mode is foundation; need sharded index or bloom filters |
| **Adaptive Compaction** | Reduces write amplification (can be 40x in naive LSM) | High | LSM compaction | RocksDB offers leveled/tiered/FIFO; recommend tiered for write-heavy geo workloads |

### Query Performance

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| **Query Result Caching** | 80%+ cache hit ratio expected for repeated queries | Medium | State machine layer | LRU with TTL invalidation; critical for dashboard refresh patterns |
| **Spatial Index Statistics** | Query planner needs cardinality estimates | Medium | S2 index layer | PostGIS ANALYZE equivalent; enables cost-based query optimization |
| **Batch Query API** | N+1 query pattern kills performance | Low | Already have batch UUID query | Extend to batch spatial queries (multiple polygons in one request) |
| **Prepared Queries** | Avoid re-parsing identical query patterns | Low | Client SDK layer | Tile38 doesn't have this; competitive advantage opportunity |

### Cluster Operations

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| **Read Replicas** | Scale reads without consensus overhead | High | VSR layer, replication | Enterprise expects 10x read scaling; eventual consistency acceptable |
| **Online Rebalancing** | Add nodes without downtime | High | Sharding layer | Azure PostgreSQL does this; must redistribute data in background |
| **Connection Pooling** | Prevents connection storms (each conn ~140KB in Tile38) | Medium | Client/server layer | pgbouncer-style pooling; 2-4x CPU cores is optimal pool size |
| **Automatic Failover** | RTO < 1 minute for mission-critical apps | Medium | VSR consensus | VSR already handles this; need monitoring/alerting integration |

### Observability

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| **Distributed Tracing** | Trace requests across shards/replicas | Medium | Metrics layer | OpenTelemetry integration; 75% of orgs now use it |
| **Query Performance Insights** | Identify slow queries, index usage | Low | Metrics layer | pg_stat_statements equivalent; track P50/P99 by query type |
| **Capacity Planning Metrics** | Predict when to scale | Low | Existing metrics | Entity count growth rate, storage utilization trends |

### Enterprise Data Management

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| **Bulk Import/Export** | Load millions of historical positions | Medium | State machine | CSV/GeoJSON bulk load; critical for migration from competitors |
| **Point-in-Time Recovery** | RPO < 1 hour for most enterprises | Medium | Backup/restore | Already have backup; need WAL-based PITR |
| **Cross-Region DR** | RTO < 15 minutes for Tier 1 workloads | High | Multi-region replication | Already have S3 replication; need automated failover orchestration |

---

## Differentiators (Competitive Advantage)

Features that set ArcherDB apart. Not expected, but highly valued.

### Real-Time Capabilities

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| **Real-Time Geofencing** | Push notifications on fence enter/exit | High | State machine, pub/sub | Tile38's killer feature; webhook + pub/sub delivery |
| **Live Query Subscriptions** | Stream query results as entities move | High | New subsystem | "Show me all vehicles in this polygon, updating live" |
| **Event Streaming Integration** | Native Kafka/Pulsar export | Medium | CDC layer | Beyond AMQP; enterprise wants Kafka compatibility |

### Performance Extremes

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| **Sub-millisecond Queries** | 100K+ QPS for dashboard workloads | Medium | Query caching, index | RAM index already achieves this for UUID; extend to spatial |
| **100M+ Entity Support** | 10x Tile38's typical deployment | High | Index sharding | PostgreSQL/PostGIS claims 100B traces/day; aim for 100M entities |
| **Zero-Copy Query Results** | Avoid serialization overhead | Medium | Protocol layer | Return memory-mapped results directly to client |

### Developer Experience

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| **Query Explain/Analyze** | Show query plan and execution stats | Medium | Query layer | PostGIS's EXPLAIN is beloved; show S2 cell coverage, index usage |
| **Geospatial Aggregations** | COUNT/AVG/SUM by region | Medium | State machine | "How many vehicles per S2 cell level 10?" |
| **Time-Series Queries** | Query historical trajectories efficiently | Medium | LSM layer | "Show entity X's path over last 24 hours" |

### Operational Excellence

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| **Adaptive Rate Limiting** | Protect cluster from query storms | Low | Connection layer | Auto-throttle expensive queries |
| **Query Cost Estimation** | Warn before expensive operations | Medium | Query planner | "This polygon covers 10M entities, proceed?" |
| **Hot Shard Detection** | Identify and rebalance hot spots | Medium | Sharding layer | Jump hash is good but some workloads have hot spots |

---

## Anti-Features (Explicitly Avoid)

Features that seem useful but aren't worth the complexity for this domain.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Full SQL Support** | Massive complexity; PostGIS already does this well | Keep simple query API; provide PostGIS export for complex analytics |
| **General-Purpose Secondary Indexes** | Scope creep; not needed for location tracking | Support entity_id + S2 cell indexes only; suggest external search for other patterns |
| **ACID Transactions Across Entities** | VSR gives per-entity linearizability; cross-entity adds huge complexity | Document that operations are per-entity atomic; suggest saga patterns for multi-entity |
| **Synchronous Multi-Region Writes** | Latency penalty is severe (100ms+ cross-region RTT) | Async replication with conflict resolution; accept eventual consistency for geo-distribution |
| **Complex Geospatial Functions** | ST_Buffer, ST_Union, etc. are compute-heavy | Delegate to PostGIS/GEOS for complex operations; focus on fast CRUD + simple queries |
| **In-Database Machine Learning** | Not core competency; adds massive surface area | Export to ML platforms; provide clean data pipelines |
| **Multi-Tenant Isolation at DB Level** | Operational nightmare; better solved at application layer | Provide tenant_id field support; let apps handle isolation |
| **Automatic Index Tuning** | Magic that often backfires | Provide good defaults + clear tuning docs instead |

---

## Competitor Analysis

### PostGIS

**Scale Features:**
- Connection pooling via pgbouncer/pgpool-II
- Table partitioning for time-series data
- Parallel query execution
- Materialized views for aggregation caching
- BRIN indexes for time-ordered data

**Performance Optimizations:**
- GiST spatial indexes (R-tree based)
- Query planner uses spatial statistics
- VACUUM/ANALYZE maintenance
- Shared buffers and work_mem tuning
- GEOS library for geometry operations (2025 release adds CGAL 3D functions)

**Enterprise Features:**
- Kubernetes-ready via Crunchy Data Operator
- High availability via Patroni
- Backups via pgBackRest
- Monitoring via pg_stat_monitor

**Weaknesses for Fleet Tracking:**
- Not optimized for high-frequency updates
- No native real-time geofencing
- Query latency varies (not predictable sub-ms)

*Sources: [Crunchy Data Blog](https://www.crunchydata.com/blog/postgis-performance-postgres-tuning), [Percona Blog](https://www.percona.com/blog/working-with-geospatial-data-postgis-makes-postgresql-enterprise-ready/)*

### Tile38

**Scale Features:**
- In-memory with disk persistence (AOF/RDB)
- Leader-follower replication
- Prometheus metrics export
- ~140KB memory per connection

**Performance Optimizations:**
- High-performance spatial indexing engine
- Real-time geofencing with webhooks
- Multiple object types (GeoJSON, Geohash, QuadKey)
- Redis RESP protocol (familiar, fast)

**Enterprise Features:**
- Built-in replication
- Webhook notifications for geofencing
- Pub/sub channels for events

**Weaknesses:**
- No sharding (single-node limit)
- No query planner/optimizer
- Limited aggregation capabilities
- No enterprise support tier

*Sources: [Tile38.com](https://tile38.com/), [Zepto Engineering Blog](https://blog.zeptonow.com/boosting-geospatial-performance-at-zepto-learnings-from-scaling-tile38-c31fd1b5ebc2)*

### Elasticsearch Geo

**Scale Features:**
- Horizontal scaling via sharding
- Index lifecycle management
- Searchable snapshots (tiered storage)
- Cross-cluster replication

**Performance Optimizations:**
- geo_point and geo_shape field types
- Distributed search across shards
- Query caching
- Filter context for geo queries

**Enterprise Features:**
- Elastic Cloud managed service
- Machine learning anomaly detection
- Alerting and notifications
- SIEM integration

**Weaknesses:**
- Geo-shape indexing is slow (known issue #22087)
- Not optimized for real-time updates
- Complex operational overhead
- High memory requirements

*Sources: [Elastic Docs](https://www.elastic.co/docs/deploy-manage/production-guidance/optimize-performance/search-speed), [Elastic Geospatial](https://www.elastic.co/geospatial)*

### Aerospike

**Scale Features:**
- Hybrid memory architecture (RAM index, SSD data)
- Linear horizontal scaling
- Cross-datacenter replication
- Up to 80% less infrastructure claimed

**Performance Optimizations:**
- Uses Google's S2 library internally (same as ArcherDB)
- Predictable low latency at scale
- Flash-optimized storage
- Server 6.3 boosted geo performance with latest S2 library

**Enterprise Features:**
- Enterprise feature keys (compression, All Flash)
- Strong consistency mode
- Active-active geo-replication

**Weaknesses:**
- Expensive enterprise licensing
- Limited geospatial query types vs PostGIS
- Steep learning curve

*Sources: [Aerospike Geo Docs](https://aerospike.com/docs/server/guide/data-types/geospatial), [Aerospike Blog](https://aerospike.com/blog/drone-nado-building-scalable-geospatial-applications-with-aerospike/)*

---

## Complexity Assessment

### Low Complexity (1-2 weeks each)

| Feature | Rationale |
|---------|-----------|
| Batch Spatial Queries | Extend existing batch UUID pattern |
| Query Performance Metrics | Add counters to existing metrics |
| Capacity Planning Metrics | Derive from existing metrics |
| Adaptive Rate Limiting | Simple token bucket at connection layer |
| Prepared Queries | Cache parsed query structures in client |

### Medium Complexity (2-4 weeks each)

| Feature | Rationale |
|---------|-----------|
| Data Compression | LZ4/Zstd integration in LSM blocks |
| Query Result Caching | LRU cache with TTL invalidation |
| Spatial Index Statistics | Cardinality estimation for S2 cells |
| Connection Pooling | Server-side pool management |
| Distributed Tracing | OpenTelemetry integration |
| Bulk Import/Export | Batch processing pipeline |
| Query Explain/Analyze | Surface internal query plan |
| Geospatial Aggregations | S2 cell-based grouping |
| Event Streaming (Kafka) | Kafka producer integration |

### High Complexity (4-8 weeks each)

| Feature | Rationale |
|---------|-----------|
| Tiered Storage | New storage tier abstraction, data movement |
| Adaptive Compaction | Multiple compaction strategies, heuristics |
| Read Replicas | New replica type, routing layer |
| Online Rebalancing | Background data redistribution |
| Real-Time Geofencing | New subsystem with pub/sub |
| Live Query Subscriptions | Streaming query infrastructure |
| 100M+ Entity Support | Index sharding, memory optimization |
| Cross-Region DR Automation | Failover orchestration |

---

## Feature Dependencies

```
Core Infrastructure (build first):
  Data Compression ──┬── Tiered Storage
                     └── Adaptive Compaction

Query Performance:
  Spatial Index Statistics ──> Query Result Caching ──> Query Cost Estimation
                                      │
                                      └──> Query Explain/Analyze

Cluster Scaling:
  Connection Pooling ──> Read Replicas ──> Online Rebalancing
                              │
                              └──> Hot Shard Detection

Real-Time Features:
  Event Streaming (Kafka) ──> Real-Time Geofencing ──> Live Query Subscriptions

Observability:
  Query Performance Metrics ──> Distributed Tracing ──> Capacity Planning
```

---

## MVP Performance Recommendation

**For enterprise readiness, prioritize:**

1. **Data Compression** (table stakes) - Immediate storage cost savings
2. **Query Result Caching** (table stakes) - 80%+ hit ratio for dashboards
3. **Connection Pooling** (table stakes) - Prevents connection storms
4. **Batch Spatial Queries** (table stakes) - Low effort, high value
5. **Query Performance Metrics** (table stakes) - Required for enterprise support

**Defer to post-MVP:**

- Real-Time Geofencing: High complexity, can use CDC + external service
- Tiered Storage: Important but not urgent for initial enterprise deals
- Live Query Subscriptions: Advanced feature, wait for customer demand
- 100M+ Entity Support: Optimize when customers hit 10M first

---

## Sources

### Competitor Documentation
- [PostGIS Performance Tuning](https://www.crunchydata.com/blog/postgis-performance-postgres-tuning)
- [PostGIS Indexing](https://www.crunchydata.com/blog/postgis-performance-indexing-and-explain)
- [Tile38 Official](https://tile38.com/)
- [Tile38 Geofencing](https://tile38.com/topics/geofencing)
- [Elasticsearch Geo Performance](https://discuss.elastic.co/t/geo-query-performance/109827)
- [Aerospike Geospatial](https://aerospike.com/docs/server/guide/data-types/geospatial)

### Performance Patterns
- [LSM Compaction Mechanisms](https://www.alibabacloud.com/blog/an-in-depth-discussion-on-the-lsm-compaction-mechanism_596780)
- [Connection Pooling Best Practices](https://www.cockroachlabs.com/blog/what-is-connection-pooling/)
- [Database Caching Patterns](https://docs.aws.amazon.com/whitepapers/latest/database-caching-strategies-using-redis/caching-patterns.html)
- [Tiered Storage Optimization](https://oceanbase.medium.com/data-compression-technology-explained-balance-between-costs-performance-e7330bca0d34)

### Scale & Architecture
- [PostgreSQL Real-time Position Tracking](https://www.alibabacloud.com/blog/postgresql-real-time-position-tracking-processing-100-billion-tracesday-with-a-single-server_597196)
- [Zepto Tile38 Scaling](https://blog.zeptonow.com/boosting-geospatial-performance-at-zepto-learnings-from-scaling-tile38-c31fd1b5ebc2)
- [Database Scaling Patterns](https://systemdr.substack.com/p/database-scaling-patterns-read-replicas)
- [Spatial Indexing in CockroachDB](https://www.cockroachlabs.com/blog/how-we-built-spatial-indexing/)

### Enterprise Requirements
- [Enterprise Database Features Guide](https://hevodata.com/learn/enterprise-database-features/)
- [Distributed Tracing Tools](https://signoz.io/blog/distributed-tracing-tools/)
- [RTO/RPO Best Practices](https://www.veeam.com/blog/recovery-time-recovery-point-objectives.html)
- [Fleet Management Requirements](https://www.simplyfleet.app/blog/fleet-management-requirements)

---

*Research completed: 2026-01-24*
