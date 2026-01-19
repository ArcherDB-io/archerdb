# Change: Dynamic Cluster Membership

Add and remove nodes from running cluster without downtime.

## Status: Draft

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design
- [tasks.md](tasks.md) - Implementation tasks (~43 hours)

## Spec Deltas

- [specs/replication/spec.md](specs/replication/spec.md) - Membership protocol, CLI, metrics

## Summary

Enables online cluster scaling:

```bash
# Add a new node
archerdb cluster add-node --address=new-node:5001

# Remove a node
archerdb cluster remove-node --node-id=3
```

## How It Works

### Add Node Flow

```
1. New node joins as LEARNER (non-voting)
2. Primary streams log/state to learner
3. When caught up, promote to FOLLOWER
4. Enter joint consensus (old ∪ new)
5. Commit new configuration
```

### Remove Node Flow

```
1. Leaving node stops accepting new ops
2. Drain in-flight operations
3. If primary, trigger view change first
4. Enter joint consensus (old \ removed)
5. Commit new configuration
6. Signal safe to shut down
```

## Joint Consensus

Safe membership transitions require majority in BOTH old and new configurations:

```
Old: [A, B, C]
New: [A, B, C, D]
Joint: Need majority(A,B,C) AND majority(A,B,C,D)
       = 2 AND 3 = at least 3 votes with A, B, or C present
```

## Key Design Decisions

1. **Joint consensus**: Raft-style safe transitions
2. **Single-node changes**: One addition/removal at a time
3. **Learner state**: New nodes don't vote until caught up
4. **Graceful departure**: Drain before leaving

## Metrics

```
archerdb_cluster_membership_state 0        # 0=stable, 1=joint
archerdb_cluster_nodes_total 5
archerdb_state_transfer_progress{node="5"} 0.67
archerdb_membership_changes_total{type="add"} 3
```
