# Index Sharding Architecture (F2.6)

**Status**: v1 Implementation Required
**Version**: v1 Feature
**Related Issues**: #142, #143, #144, #145, #146, #518

## Overview

Index sharding enables ArcherDB to scale horizontally beyond single-node RAM capacity by partitioning the RAM index across multiple nodes. This is a v1 requirement for production deployments exceeding single-node capacity.

## Capacity Planning

| RAM Size | Max Entities | Use Case |
|----------|-------------|----------|
| 128 GB | ~1 billion | Standard deployment |
| 256 GB | ~2 billion | Large deployment |
| 512 GB | ~4 billion | Enterprise deployment |
| 1 TB | ~8 billion | Large enterprise |
| 2 TB | ~16 billion | Maximum single-node |

For deployments exceeding these limits, horizontal sharding is required.

## Horizontal Sharding Strategy

### Sharding Model

Entity-range sharding using consistent hashing on `entity_id`:

```
entity_id (u128) → murmur3_128() → shard_key (u64) → shard_bucket
```

### Shard Configuration

- **Shard count**: Powers of 2 (8, 16, 32, 64 shards recommended)
- **Bucket calculation**: `shard_bucket = shard_key % num_shards`
- **Minimum shards**: 8 (for reasonable distribution)
- **Maximum shards**: 256 (operational complexity limit)

### Example: 16-Shard Configuration

```
Shard 0:  entity_id where hash(entity_id) % 16 == 0
Shard 1:  entity_id where hash(entity_id) % 16 == 1
...
Shard 15: entity_id where hash(entity_id) % 16 == 15
```

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

## Query Routing

### UUID Lookup (Single Shard)

```
query_uuid(entity_id) → computeShardBucket(entity_id) → single shard
```

- **Complexity**: O(1) routing + O(1) lookup
- **Latency**: Single network hop
- **No aggregation needed**

### Radius Query (Fan-out)

```
query_radius(lat, lon, radius_m) → ALL shards → aggregate results
```

- **Complexity**: O(num_shards) routing + O(n) per shard
- **Latency**: Max(shard_latencies) + aggregation
- **Aggregation**: Client-side or coordinator-side merge

### Polygon Query (Fan-out)

```
query_polygon(polygon) → ALL shards → aggregate results
```

- **Same fan-out pattern as radius**
- **Results sorted/limited after aggregation**

### Query Routing Table

| Query Type | Shards Hit | Aggregation |
|------------|------------|-------------|
| UUID Lookup | 1 | None |
| Latest N by Entity | 1 | None |
| Radius | All | Merge & Sort |
| Polygon | All | Merge & Sort |
| Bounding Box | All | Merge & Sort |
| History by Entity | 1 | None |

## Per-Shard Replication

### Shard Architecture

Each shard operates as an independent VSR replica cluster:

```
Shard 0: [Node A, Node B, Node C] - 3-node cluster
Shard 1: [Node D, Node E, Node F] - 3-node cluster
...
```

### Replication Properties

- **Per-shard consensus**: Each shard runs independent VSR
- **Fault tolerance**: Each shard tolerates 1 node failure (3-node cluster)
- **Independent recovery**: Shard failure doesn't affect other shards
- **Write path**: Client → Shard Router → Shard Primary → Shard Replicas

### Recovery Scenarios

| Failure | Impact | Recovery |
|---------|--------|----------|
| Single node | One shard degraded | Automatic failover |
| Shard (all nodes) | Shard unavailable | Restore from backup |
| Network partition | Partial availability | VSR handles safely |

## Resharding Operations

### Resharding Triggers

1. **Capacity growth**: Need more shards for data growth
2. **Capacity reduction**: Consolidate underutilized shards
3. **Hot spot mitigation**: Rebalance for uneven access

### Resharding Strategies

#### Option A: Stop-the-World

1. Stop all writes
2. Snapshot all shards
3. Redistribute data to new shard configuration
4. Resume writes

**Pros**: Simple, deterministic
**Cons**: Downtime required

#### Option B: Online Migration

1. Create new shard configuration
2. Enable dual-write mode (old + new)
3. Background migration of existing data
4. Verify consistency
5. Cut over to new configuration
6. Remove old shards

**Pros**: Zero downtime
**Cons**: Complex, requires consistency verification

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

### Topology Service

- **Centralized**: Dedicated metadata cluster (e.g., etcd, ZooKeeper)
- **Embedded**: Gossip-based topology (like Cassandra)
- **v2 recommendation**: Start with embedded gossip for simplicity

## Failover & Recovery

### Node Failure

1. Detection: Heartbeat timeout (5 seconds)
2. Shard reassignment: Promote replica to primary
3. Replica replacement: Add new node to shard cluster
4. Data sync: New replica syncs from primary

### Resharding Procedure

1. Operator initiates via CLI: `archerdb resharding --to 32`
2. System validates new configuration
3. Creates migration plan
4. Executes migration (stop-the-world or online)
5. Verifies data integrity
6. Activates new configuration

## CLI Commands (v2)

```bash
# View shard topology
archerdb shards list

# Check shard health
archerdb shards status

# Initiate resharding
archerdb resharding --from 16 --to 32

# Manual shard rebalance
archerdb shards rebalance --shard 7

# Failover a shard
archerdb shards failover --shard 3 --to node-42
```

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

## Security Considerations

- **Shard isolation**: Each shard cluster can have independent encryption keys
- **Access control**: Shard-level ACLs possible
- **Audit logging**: Per-shard audit trails
- **Network security**: Inter-shard communication TLS encrypted

## Migration Path from v1 to v2

1. **Preparation** (v1.x):
   - Export data using backup/restore tools
   - Plan shard count based on data size

2. **Migration** (v2.0):
   - Deploy v2 cluster with target shard count
   - Import data with shard-aware import tool
   - Verify data integrity

3. **Cutover**:
   - Update client SDKs to v2
   - Switch traffic to v2 cluster
   - Decommission v1 cluster

## References

- [Cassandra Architecture](https://cassandra.apache.org/doc/latest/architecture/) - Similar sharding approach
- [Amazon DynamoDB Partitioning](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.Partitions.html) - Partition key distribution
- [ArcherDB Single-Node Design](https://docs.archerdb.com/) - Why v1 avoids sharding



## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Sharding Architecture | ✓ Complete | \`sharding.zig\` |
| Consistent Hashing | ✓ Complete | S2 cell-based routing |
| Query Routing | ✓ Complete | Parallel shard queries |
| Failover/Resharding | ✓ Complete | Auto-failover via VSR; manual resharding (online v2.1+) |
| Recovery/Replication | ✓ Complete | VSR per-shard |
