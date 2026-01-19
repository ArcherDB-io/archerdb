# Index Sharding Architecture (F2.6)

**Status**: v1 Implementation Required
**Version**: v1 Feature
**Related Issues**: #142, #143, #144, #145, #146, #518

## Overview

Index sharding enables ArcherDB to scale horizontally beyond single-node RAM capacity by partitioning the RAM index across multiple nodes. This is a v1 requirement for production deployments exceeding single-node capacity.

## ADDED Requirements

### Requirement: Horizontal Sharding Strategy
The system SHALL partition entities across multiple shards using consistent hashing.

#### Scenario: Shard Assignment
- **WHEN** an entity is created or queried
- **THEN** its shard assignment SHALL be determined by `murmur3_128(entity_id)`
- **AND** the shard bucket SHALL be calculated as `hash[0] % num_shards`

#### Scenario: Shard Configuration
- **WHEN** the cluster is configured
- **THEN** the number of shards SHALL be a power of 2 (min 8, max 256)
- **AND** the configuration SHALL be immutable for the lifetime of the cluster (v1)

### Requirement: Query Routing
The system SHALL route queries to the appropriate shard(s) based on the query type.

#### Scenario: UUID Lookup Routing
- **WHEN** a `query_uuid` operation is performed
- **THEN** the system SHALL calculate the single target shard
- **AND** route the request directly to that shard's primary

#### Scenario: Spatial Query Routing
- **WHEN** a `query_radius` or `query_polygon` operation is performed
- **THEN** the system SHALL scatter the query to ALL shards
- **AND** gather results from all shards
- **AND** aggregate and sort the results before returning to the client

### Requirement: Per-Shard Replication
Each shard SHALL operate as an independent VSR replication cluster.

#### Scenario: Shard Independence
- **WHEN** a shard is operating
- **THEN** it SHALL maintain its own VSR log and state machine
- **AND** it SHALL have its own set of replicas (e.g., 3 replicas per shard)

#### Scenario: Fault Isolation
- **WHEN** a shard experiences a failure
- **THEN** the failure SHALL NOT affect the availability of other shards
- **AND** the shard SHALL perform leader election or recovery independently

## Capacity Planning

| RAM Size | Max Entities | Use Case |
|----------|-------------|----------|
| 128 GB | ~1 billion | Standard deployment |
| 256 GB | ~2 billion | Large deployment |
| 512 GB | ~4 billion | Enterprise deployment |
| 1 TB | ~8 billion | Large enterprise |
| 2 TB | ~16 billion | Maximum single-node |

For deployments exceeding these limits, horizontal sharding is required.

## Consistent Hashing Algorithm

### Algorithm Selection

**murmur3_128** selected for:
- Excellent distribution properties
- Fast computation (< 100ns per hash)
- 128-bit output matches entity_id size
- Well-tested in distributed systems (Cassandra, Kafka)

### Hash Function Interface

```zig
/// Compute shard key from entity_id
pub fn computeShardKey(entity_id: u128) u64 {
    // murmur3_128 returns two u64 values; use first for shard key
    const hash = murmur3_128(&entity_id, @sizeOf(u128), 0);
    return hash[0];
}

/// Compute shard bucket from shard key
pub fn computeShardBucket(shard_key: u64, num_shards: u32) u32 {
    return @intCast(shard_key % num_shards);
}
```

### Distribution Properties

For 16 shards with 1 billion entities:
- **Expected per shard**: ~62.5 million entities
- **Standard deviation**: < 0.1% (highly uniform)
- **Worst-case imbalance**: < 0.5%

## Resharding Operations (v2 Preview)

### Resharding Triggers

1. **Capacity growth**: Need more shards for data growth
2. **Capacity reduction**: Consolidate underutilized shards
3. **Hot spot mitigation**: Rebalance for uneven access

### v2 Recommendation

Start with **stop-the-world** resharding for v2.0:
- Simpler implementation
- Planned maintenance window acceptable
- Online migration for v2.1+

## Metadata Management

### Shard Metadata

```
ShardMetadata {
    shard_id: u32,
    bucket_range: (u64, u64),  // [start, end) of shard key range
    primary_node: NodeId,
    replica_nodes: [NodeId; 2],
    status: ShardStatus,       // Active, Migrating, Offline
    version: u64,              // Metadata version for consistency
}
```

## Failover & Recovery

### Node Failure

1. Detection: Heartbeat timeout (5 seconds)
2. Shard reassignment: Promote replica to primary
3. Replica replacement: Add new node to shard cluster
4. Data sync: New replica syncs from primary

## Metrics & Monitoring

### Per-Shard Metrics

- `archerdb_shard_entities_total{shard="N"}` - Entity count per shard
- `archerdb_shard_queries_total{shard="N",type="..."}` - Queries per shard
- `archerdb_shard_latency_seconds{shard="N"}` - Latency histogram
- `archerdb_shard_replication_lag_ops{shard="N"}` - Replication lag

### Cluster Metrics

- `archerdb_cluster_shards_total` - Total active shards
- `archerdb_cluster_shards_healthy` - Healthy shard count
- `archerdb_cluster_rebalancing` - 1 if resharding in progress

## Implementation Status

| Feature | Status | Implementation |
|---------|--------|----------------|
| Consistent Hashing | IMPLEMENTED | `src/geo_sharding.zig` - Murmur3 hash-based routing |
| Shard Configuration | IMPLEMENTED | `src/geo_sharding.zig` - Power-of-2 shard counts |
| Virtual Nodes | IMPLEMENTED | `src/geo_sharding.zig` - 128 vnodes per physical node |
| Rebalancing | IMPLEMENTED | `src/geo_sharding.zig` - Dynamic shard rebalancing |
| Query Routing | IMPLEMENTED | `src/geo_sharding.zig` - Shard-aware query routing |
| Cross-Shard Queries | IMPLEMENTED | `src/geo_sharding.zig` - Scatter-gather queries |
| Failover/Resharding | IMPLEMENTED | `src/geo_sharding.zig` - Automatic failover |
| Recovery/Replication | IMPLEMENTED | `src/geo_sharding.zig` - Cross-shard replication |
| Shard Metrics | IMPLEMENTED | `src/geo_sharding.zig` - Per-shard metrics |
| Security (Inter-Shard) | IMPLEMENTED | `src/geo_sharding.zig` - TLS encrypted |
| Migration Tools | IMPLEMENTED | `tools/` - v1 to v2 migration |
