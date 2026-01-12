# Per-Shard Recovery & Replication (F2.6.4)

**Status**: v1 Implementation Required
**Related Issues**: #145

## Overview

In a sharded ArcherDB deployment, each shard operates as an independent VSR (Viewstamped Replication) cluster. This document describes the recovery and replication architecture for each shard.

## Shard Replication Model

### Shard Topology

Each shard consists of a 3-node VSR replica cluster:

```
Shard N:
┌─────────────────────────────────────────────────────┐
│  ┌─────────┐    ┌─────────┐    ┌─────────┐        │
│  │ Primary │───>│ Replica │    │ Replica │        │
│  │ (Node A)│<───│ (Node B)│───>│ (Node C)│        │
│  └─────────┘    └─────────┘    └─────────┘        │
│       │              │              │             │
│       └──────────────┴──────────────┘             │
│                  VSR Consensus                     │
└─────────────────────────────────────────────────────┘
```

### Replication Properties

| Property | Value | Rationale |
|----------|-------|-----------|
| Replica count | 3 | Tolerates 1 failure |
| Quorum size | 2 | Majority of 3 |
| Consistency | Linearizable | VSR guarantee |
| Replication | Synchronous | Strong consistency |

## VSR Consensus per Shard

### Write Path

1. Client sends write to shard primary
2. Primary assigns operation number
3. Primary replicates to followers
4. Quorum (2/3) acknowledges
5. Primary commits and responds

```
Client ──> Primary (Shard N)
              │
              ├──> Replica 1: prepare(op=42, data=...)
              │         │
              │         └──> ack(op=42)
              │
              ├──> Replica 2: prepare(op=42, data=...)
              │         │
              │         └──> ack(op=42)
              │
              └──> commit(op=42) ──> Client: success
```

### Read Path

1. Client sends read to primary (strong consistency)
2. Or: Client sends read to any replica (eventual consistency)

**Default**: Strong consistency reads from primary

## Failure Scenarios

### Single Node Failure

**Impact**: Shard remains available (2/3 nodes)

**Recovery**:
1. Failure detected via heartbeat timeout (5s)
2. Remaining 2 nodes continue operating
3. Failed node recovers or is replaced
4. Recovering node syncs from primary

```
Time 0: [Primary, Replica1, Replica2] - healthy
Time 5: [Primary, Replica1, ----    ] - Replica2 fails
Time 6: Continue operating with quorum of 2
Time X: [Primary, Replica1, NewNode ] - replacement added
Time Y: NewNode catches up via state transfer
```

### Primary Failure

**Impact**: Brief unavailability during failover (~1-5s)

**Recovery**:
1. Followers detect primary timeout
2. Followers elect new primary (VSR view change)
3. New primary syncs uncommitted operations
4. Shard resumes accepting requests

```
Time 0: [Primary*, Replica1, Replica2]
Time 5: [--------, Replica1, Replica2] - Primary fails
Time 6: VSR view change begins
Time 7: [--------, Primary*, Replica2] - Replica1 elected primary
Time 8: Resume operations
```

### Majority Failure (2+ nodes)

**Impact**: Shard unavailable

**Recovery**:
1. Cannot form quorum - shard offline
2. Manual intervention required
3. Options:
   a. Wait for nodes to recover
   b. Restore from backup
   c. Accept data loss (last resort)

### Full Shard Loss

**Impact**: Shard data lost

**Recovery**:
1. Deploy new 3-node cluster
2. Restore from latest backup
3. Replay WAL from backup point
4. Rejoin cluster topology

## State Transfer

### When State Transfer Occurs

1. New node joining shard
2. Node recovering from extended downtime
3. Node data corruption detected

### State Transfer Protocol

```
Recovering Node                    Primary
      │                               │
      │──> request_state_snapshot ───>│
      │                               │
      │<── snapshot_metadata ─────────│
      │                               │
      │<── snapshot_chunk(0/N) ───────│
      │<── snapshot_chunk(1/N) ───────│
      │<── ...                        │
      │<── snapshot_chunk(N/N) ───────│
      │                               │
      │──> ack_snapshot ─────────────>│
      │                               │
      │<── replay_log(from_op=X) ─────│
      │                               │
      │──> ready ────────────────────>│
```

### State Transfer Components

1. **RAM Index Snapshot**: Serialized index entries
2. **LSM Tree Snapshot**: SSTable files + manifest
3. **WAL Replay**: Operations since snapshot

### Transfer Performance

| Component | Size (1B entities) | Transfer Time (1Gbps) |
|-----------|-------------------|-----------------------|
| RAM Index | ~128 GB | ~17 minutes |
| LSM Tree | ~500 GB (estimate) | ~70 minutes |
| WAL Replay | Variable | Depends on lag |

**Total estimated recovery**: 90-120 minutes for 1B entities

## Backup & Restore

### Per-Shard Backup

Each shard backs up independently:

```
┌──────────────────────────────────────────────────────────────┐
│ Shard 0 Backup        Shard 1 Backup        Shard N Backup  │
│ ┌─────────────┐       ┌─────────────┐       ┌─────────────┐ │
│ │ snapshot_0  │       │ snapshot_1  │       │ snapshot_N  │ │
│ │ wal_0       │       │ wal_1       │       │ wal_N       │ │
│ └─────────────┘       └─────────────┘       └─────────────┘ │
│        │                    │                     │         │
│        └────────────────────┴─────────────────────┘         │
│                           │                                  │
│                    Object Storage                            │
└──────────────────────────────────────────────────────────────┘
```

### Backup Schedule

| Type | Frequency | Retention |
|------|-----------|-----------|
| Incremental | Every 15 minutes | 24 hours |
| Full | Daily | 7 days |
| Archive | Weekly | 90 days |

### Point-in-Time Recovery

```bash
# List available recovery points for shard 7
archerdb backup list --shard 7

# Restore shard 7 to specific point
archerdb backup restore --shard 7 --timestamp "2024-01-15T10:30:00Z"
```

## Cross-Shard Considerations

### Independent Recovery

- Each shard recovers independently
- No cross-shard coordination required
- Different shards may be at different points

### Cluster-Wide Backup

For consistent cluster-wide backup:

1. Pause writes to all shards
2. Snapshot all shards simultaneously
3. Resume writes
4. Store snapshot set with cluster-wide timestamp

### Resharding During Recovery

**Avoid**: Do not reshard while any shard is recovering

## Health Monitoring

### Per-Shard Health Checks

```
archerdb_shard_status{shard="N"} = 1  # healthy
                                = 0  # unhealthy

archerdb_shard_primary{shard="N",node="A"} = 1
archerdb_shard_replica_lag_ops{shard="N",node="B"}
archerdb_shard_last_commit_timestamp{shard="N"}
```

### Alerting Thresholds

| Metric | Warning | Critical |
|--------|---------|----------|
| Replica lag | > 1000 ops | > 10000 ops |
| Node unavailable | 1 node | 2+ nodes |
| State transfer duration | > 60 min | > 120 min |
| Backup age | > 30 min | > 60 min |

## Recovery Procedures

### Procedure 1: Single Node Recovery

```bash
# 1. Identify failed node
archerdb cluster status --shard 7

# 2. Remove failed node from cluster
archerdb cluster remove-node --shard 7 --node node-21

# 3. Add replacement node
archerdb cluster add-node --shard 7 --node node-42

# 4. Monitor state transfer progress
archerdb cluster recovery-status --shard 7
```

### Procedure 2: Shard Restore from Backup

```bash
# 1. Stop shard (if running)
archerdb cluster stop-shard --shard 7

# 2. Clear shard data
archerdb cluster clear-shard --shard 7 --confirm

# 3. Restore from backup
archerdb backup restore --shard 7 --latest

# 4. Start shard
archerdb cluster start-shard --shard 7

# 5. Verify data integrity
archerdb cluster verify --shard 7
```

### Procedure 3: Full Cluster Recovery

```bash
# 1. Deploy fresh cluster
archerdb cluster init --shards 16

# 2. Restore all shards from cluster backup
archerdb backup restore-cluster --backup-id "cluster-20240115-103000"

# 3. Verify each shard
for shard in $(seq 0 15); do
    archerdb cluster verify --shard $shard
done

# 4. Update clients with new topology
archerdb cluster publish-topology
```

## Testing Requirements

### Chaos Testing

1. **Kill primary**: Verify automatic failover
2. **Kill replica**: Verify continued operation
3. **Network partition**: Verify split-brain prevention
4. **Slow replica**: Verify degraded mode operation

### Recovery Testing

1. **State transfer**: Verify correctness after sync
2. **Backup restore**: Verify data integrity
3. **Point-in-time recovery**: Verify timestamp accuracy
4. **Cross-shard consistency**: Verify after partial recovery

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| VSR View Change | ✓ Complete | `src/vsr.zig` start_view_change, do_view_change |
| State Transfer Protocol | ✓ Complete | VSR state sync in `vsr.zig` |
| Incremental Backup | ✓ Complete | `backup_coordinator.zig`, `backup_queue.zig` |
| Backup Restore Tooling | ✓ Complete | `restore.zig` |
| Health Monitoring | ✓ Complete | `metrics.zig`, `metrics_server.zig` |
| Recovery CLI Commands | ✓ Complete | `cli.zig` cluster commands |
| Chaos Test Suite | ✓ Complete | `testing/` simulation tests |
| Recovery Documentation | ✓ Complete | This spec serves as runbook |
