# Failover & Resharding Procedures (F2.6.5)

**Status**: v1 Implementation Required
**Related Issues**: #146

## Overview

This document provides operational procedures for:
1. **Failover**: Handling node and shard failures
2. **Resharding**: Changing the number of shards

## Part 1: Failover Procedures

### Automatic Failover (Primary Failure)

VSR handles primary failure automatically:

```
┌─────────────────────────────────────────────────────────────┐
│ AUTOMATIC FAILOVER SEQUENCE                                 │
├─────────────────────────────────────────────────────────────┤
│ T+0s:   Primary stops responding                           │
│ T+5s:   Followers detect timeout                           │
│ T+6s:   VSR view change initiated                          │
│ T+7s:   New primary elected (highest log replica)          │
│ T+8s:   New primary accepts requests                       │
│ T+10s:  Clients reconnect to new primary                   │
└─────────────────────────────────────────────────────────────┘
```

**No operator intervention required.**

### Manual Failover (Planned Maintenance)

```bash
# Procedure: Graceful primary handoff for maintenance

# Step 1: Verify shard health
archerdb cluster status --shard 7
# Expected: 3/3 nodes healthy

# Step 2: Trigger graceful leadership transfer
archerdb cluster transfer-leadership --shard 7 --to node-22
# Waits for all pending operations to replicate

# Step 3: Verify new primary
archerdb cluster status --shard 7
# Expected: node-22 is primary

# Step 4: Perform maintenance on old primary
ssh node-21 "systemctl stop archerdb"
# ... maintenance ...
ssh node-21 "systemctl start archerdb"

# Step 5: Verify node rejoined
archerdb cluster status --shard 7
# Expected: 3/3 nodes healthy
```

### Node Replacement

```bash
# Procedure: Replace failed node with new node

# Step 1: Identify failed node
archerdb cluster status --shard 7
# Output: node-21 (FAILED), node-22 (healthy), node-23 (healthy)

# Step 2: Remove failed node from cluster config
archerdb cluster remove-node --shard 7 --node node-21
# Updates topology, notifies other nodes

# Step 3: Provision new node
# (infrastructure-specific: Terraform, Ansible, etc.)

# Step 4: Add new node to shard
archerdb cluster add-node --shard 7 --node node-42 --address "10.0.1.42:5000"
# New node begins state transfer from primary

# Step 5: Monitor state transfer
archerdb cluster recovery-status --shard 7
# Progress: 45% complete, ETA: 52 minutes

# Step 6: Verify completion
archerdb cluster status --shard 7
# Expected: 3/3 nodes healthy (node-42 replaced node-21)
```

### Shard Unavailable (Majority Failure)

```bash
# Procedure: Recover shard from majority failure

# WARNING: This may result in data loss if backup is stale!

# Step 1: Assess damage
archerdb cluster status --shard 7
# Output: node-21 (FAILED), node-22 (FAILED), node-23 (healthy)
# Status: SHARD UNAVAILABLE (no quorum)

# Step 2: Decision point
# Option A: Wait for nodes to recover (if possible)
# Option B: Force recover from single node (data loss risk)
# Option C: Restore from backup (data loss = time since backup)

# Option A: Wait for recovery
# Simply wait. When second node comes back, quorum restores automatically.

# Option B: Force recover (DANGEROUS)
archerdb cluster force-recover --shard 7 --from node-23 --confirm-data-loss
# Creates new 3-node cluster from single surviving node
# WARNING: Any operations not replicated to node-23 are LOST

# Option C: Restore from backup
archerdb cluster stop-shard --shard 7
archerdb backup restore --shard 7 --latest
archerdb cluster start-shard --shard 7
# Data loss = operations since last backup
```

### Network Partition

```bash
# Procedure: Diagnose and resolve network partition

# Step 1: Check network connectivity
archerdb cluster diagnose-network --shard 7
# Output:
#   node-21 → node-22: OK
#   node-21 → node-23: TIMEOUT
#   node-22 → node-23: TIMEOUT
# Diagnosis: node-23 is network partitioned

# Step 2: VSR behavior during partition
# - If node-23 was primary: view change occurs, new primary elected
# - If node-23 was replica: it falls behind, cannot commit

# Step 3: Resolve network issue
# (infrastructure-specific: check firewall, routes, etc.)

# Step 4: After network restored
archerdb cluster status --shard 7
# node-23 automatically catches up via state transfer
```

## Part 2: Resharding Procedures

### Pre-Resharding Checklist

```bash
# Before resharding, verify:
[ ] All shards healthy (archerdb cluster status)
[ ] Sufficient disk space on all nodes
[ ] Backup completed (archerdb backup create --cluster)
[ ] Maintenance window scheduled (for stop-the-world)
[ ] Client SDKs support new shard count
[ ] Monitoring in place for resharding metrics
```

### Stop-the-World Resharding (v2.0)

```bash
# Procedure: Double shard count from 16 to 32

# Step 1: Create backup
archerdb backup create --cluster --name "pre-resharding-backup"
# Waits for all shards to snapshot

# Step 2: Stop all writes
archerdb cluster set-mode --read-only
# Clients receive READ_ONLY errors for writes
# Reads continue working

# Step 3: Wait for replication to settle
archerdb cluster wait-quiescent
# Ensures all pending operations committed

# Step 4: Export shard data
archerdb resharding export --from 16 --output /data/resharding/
# Exports each shard's data to files

# Step 5: Deploy new shard topology
archerdb cluster reconfigure --shards 32
# Updates cluster config, starts new shard processes

# Step 6: Import data to new shards
archerdb resharding import --to 32 --input /data/resharding/
# Each entity rehashed to correct new shard

# Step 7: Verify data integrity
archerdb resharding verify --old-shards 16 --new-shards 32
# Compares entity counts, samples random entities

# Step 8: Resume writes
archerdb cluster set-mode --read-write

# Step 9: Update client configurations
# Clients must refresh topology to discover new shards

# Step 10: Monitor for issues
archerdb cluster status
# Watch for errors, latency spikes
```

### Data Movement During Resharding

When going from N to 2N shards:

```
Original Shard 0 (hash % 16 == 0):
- Entities where hash % 32 == 0  → Stay in new Shard 0
- Entities where hash % 32 == 16 → Move to new Shard 16

Original Shard 1 (hash % 16 == 1):
- Entities where hash % 32 == 1  → Stay in new Shard 1
- Entities where hash % 32 == 17 → Move to new Shard 17

... and so on
```

**Approximately 50% of data moves** when doubling shards.

### Resharding Time Estimates

| Current Data | 16→32 Shards | 32→64 Shards |
|--------------|--------------|--------------|
| 100M entities | ~10 minutes | ~10 minutes |
| 1B entities | ~90 minutes | ~90 minutes |
| 10B entities | ~15 hours | ~15 hours |

Factors:
- Network bandwidth (export/import)
- Disk I/O (reading/writing)
- CPU (rehashing entities)

### Online Resharding (v2.1+ Future)

Outline for future implementation:

```
Phase 1: Dual-Write Mode
- New shards created
- Writes go to both old and new shards
- Reads from old shards only

Phase 2: Background Migration
- Background process reads old shards
- Rehashes and writes to new shards
- Tracks migration progress per entity range

Phase 3: Cutover
- Verify all entities migrated
- Switch reads to new shards
- Disable writes to old shards

Phase 4: Cleanup
- Remove old shard data
- Decommission old shard processes
```

**Status**: Not implemented in v2.0

### Rollback Procedure

```bash
# If resharding fails, rollback to original configuration

# Step 1: Stop resharding
archerdb resharding abort
# Stops any in-progress import

# Step 2: Restore original topology
archerdb cluster reconfigure --shards 16
# Starts original shard configuration

# Step 3: Restore from backup (if needed)
archerdb backup restore --cluster --name "pre-resharding-backup"

# Step 4: Resume operations
archerdb cluster set-mode --read-write
```

## CLI Reference

### Cluster Management

```bash
# View cluster status
archerdb cluster status [--shard N] [--verbose]

# Node management
archerdb cluster add-node --shard N --node NAME --address HOST:PORT
archerdb cluster remove-node --shard N --node NAME
archerdb cluster transfer-leadership --shard N --to NODE

# Shard management
archerdb cluster stop-shard --shard N
archerdb cluster start-shard --shard N
archerdb cluster set-mode --read-only | --read-write

# Diagnostics
archerdb cluster diagnose-network --shard N
archerdb cluster recovery-status --shard N
archerdb cluster verify --shard N
```

### Resharding Commands

```bash
# Export/Import
archerdb resharding export --from N --output DIR
archerdb resharding import --to M --input DIR

# Control
archerdb resharding abort
archerdb resharding status

# Verification
archerdb resharding verify --old-shards N --new-shards M
```

### Backup Commands

```bash
# Create backups
archerdb backup create --shard N [--name NAME]
archerdb backup create --cluster [--name NAME]

# List backups
archerdb backup list [--shard N]

# Restore
archerdb backup restore --shard N --name NAME
archerdb backup restore --shard N --timestamp TIMESTAMP
archerdb backup restore --cluster --name NAME
```

## Runbook Checklist

### Daily Operations

- [ ] Verify all shards healthy: `archerdb cluster status`
- [ ] Check replica lag: `archerdb metrics | grep replica_lag`
- [ ] Verify backups running: `archerdb backup list | head`

### Weekly Operations

- [ ] Review backup retention: `archerdb backup list --all`
- [ ] Test backup restore: (on non-prod)
- [ ] Review capacity metrics: plan resharding if needed

### Incident Response

- [ ] Page received → Check `archerdb cluster status`
- [ ] Identify affected shard(s)
- [ ] Follow appropriate procedure above
- [ ] Verify recovery
- [ ] Update incident timeline
- [ ] Post-mortem if significant

## Monitoring Dashboards

### Recommended Panels

1. **Cluster Health**: Shard status heatmap
2. **Replica Lag**: Per-shard lag histogram
3. **Failover Events**: Timeline of leadership changes
4. **State Transfer Progress**: During recovery
5. **Resharding Progress**: During resharding operations
6. **Backup Status**: Age of latest backup per shard

### Alert Rules

```yaml
# Prometheus alerting rules (example)
groups:
  - name: archerdb_failover
    rules:
      - alert: ShardUnavailable
        expr: archerdb_shard_status == 0
        for: 1m
        labels:
          severity: critical

      - alert: HighReplicaLag
        expr: archerdb_shard_replica_lag_ops > 10000
        for: 5m
        labels:
          severity: warning

      - alert: FailoverOccurred
        expr: changes(archerdb_shard_primary_node[5m]) > 0
        labels:
          severity: info

      - alert: StaleBackup
        expr: time() - archerdb_shard_last_backup_timestamp > 3600
        labels:
          severity: warning
```


## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Automatic Failover | ✓ Complete | VSR handles via view change |
| Manual Failover | ✓ Complete | CLI `cluster transfer-leadership` |
| Node Replacement | ✓ Complete | CLI `cluster add-node/remove-node` |
| Stop-the-World Resharding | ✓ Complete | CLI `resharding` commands |
| Online Resharding | Deferred | v2.1+ (zero-downtime migration) |
| Monitoring Alerts | ✓ Complete | Prometheus alert rules defined |
