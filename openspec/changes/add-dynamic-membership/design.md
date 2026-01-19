# Design: Dynamic Cluster Membership

## Context

VSR (Viewstamped Replication) supports reconfiguration through view changes. ArcherDB's VSR implementation can be extended to support dynamic membership following the Raft-style joint consensus approach.

## Goals / Non-Goals

### Goals

1. **Online membership changes**: Add/remove without downtime
2. **Safety**: No data loss during transitions
3. **Liveness**: System continues serving requests

### Non-Goals

1. **Automatic scaling**: Manual trigger only
2. **Shard changes**: Focus on replica membership
3. **Cross-datacenter**: Same-region clusters

## Decisions

### Decision 1: Joint Consensus for Membership Changes

**Choice**: Use joint consensus (Raft-style) for safe transitions.

**Rationale**:
- Proven correct (Raft paper, Ongaro 2014)
- No "danger zone" where either old or new config could decide
- Clean state machine transitions

**Implementation**:
```
Phase 1: C_old → C_old,new (joint configuration)
  - Decisions require majority in BOTH old AND new configs
  - Safe: overlapping majorities prevent split-brain

Phase 2: C_old,new → C_new (final configuration)
  - Old-only nodes can be decommissioned
  - System operates on new configuration
```

### Decision 2: Single-Node Changes Only

**Choice**: Allow only one node addition or removal at a time.

**Rationale**:
- Simplifies correctness reasoning
- Prevents quorum violations
- Easier to implement and test

**Implementation**:
```zig
pub const MembershipChange = union(enum) {
    add_node: NodeConfig,
    remove_node: NodeId,
};

// Reject if change already in progress
pub fn proposeMembershipChange(change: MembershipChange) !void {
    if (self.membership_change_in_progress) {
        return error.MembershipChangeInProgress;
    }
    // ...
}
```

### Decision 3: Learner State for New Nodes

**Choice**: New nodes start as non-voting "learners" until caught up.

**Rationale**:
- Prevents slow nodes from blocking consensus
- Allows catch-up without affecting availability
- Learner can be promoted when ready

**Implementation**:
```
Node States:
  - LEARNER: Receives data, doesn't vote
  - FOLLOWER: Caught up, participates in votes
  - CANDIDATE: Running for primary (existing)
  - PRIMARY: Current leader (existing)

Add Node Flow:
  1. New node starts as LEARNER
  2. Receives log/state from primary
  3. When caught up (lag < threshold), promote to FOLLOWER
  4. Cluster enters joint consensus with new FOLLOWER
  5. Complete transition to new config
```

### Decision 4: Graceful Departure for Removed Nodes

**Choice**: Removed nodes transfer leadership and drain before leaving.

**Rationale**:
- Minimizes disruption
- Ensures no in-flight operations lost
- Clean handoff

**Implementation**:
```
Remove Node Flow:
  1. If removed node is primary, trigger view change
  2. Enter joint consensus excluding node
  3. Removed node stops accepting new operations
  4. Drain in-flight operations (timeout: 30s)
  5. Complete transition to new config
  6. Removed node can be shut down
```

## Architecture

### Membership States

```
                                ┌─────────────┐
                                │   STABLE    │
                                │  (normal)   │
                                └──────┬──────┘
                                       │
                      add/remove node request
                                       │
                                       ▼
                                ┌─────────────┐
                                │   JOINT     │
                                │ (C_old,new) │
                                └──────┬──────┘
                                       │
                      joint config committed
                                       │
                                       ▼
                                ┌─────────────┐
                                │   STABLE    │
                                │   (C_new)   │
                                └─────────────┘
```

### Add Node Flow

```
    New Node              Primary              Cluster
        │                    │                    │
        │ 1. Join request    │                    │
        │───────────────────>│                    │
        │                    │                    │
        │ 2. Accept as learner                    │
        │<───────────────────│                    │
        │                    │                    │
        │ 3. Stream state    │                    │
        │<═══════════════════│                    │
        │                    │                    │
        │ 4. Caught up       │                    │
        │───────────────────>│                    │
        │                    │                    │
        │                    │ 5. Joint config    │
        │                    │───────────────────>│
        │                    │                    │
        │ 6. Now FOLLOWER    │                    │
        │<───────────────────│                    │
        │                    │                    │
        │                    │ 7. New config      │
        │                    │───────────────────>│
```

### Remove Node Flow

```
    Leaving Node          Primary              Cluster
        │                    │                    │
        │ 1. Remove request  │                    │
        │<───────────────────│                    │
        │                    │                    │
        │ 2. Stop new ops    │                    │
        │<───────────────────│                    │
        │                    │                    │
        │                    │ 3. Joint config    │
        │                    │───────────────────>│
        │                    │                    │
        │ 4. Drain ops       │                    │
        │═══════════════════>│                    │
        │                    │                    │
        │                    │ 5. New config      │
        │                    │───────────────────>│
        │                    │                    │
        │ 6. Shutdown OK     │                    │
        │<───────────────────│                    │
```

## Configuration

### CLI Commands

```bash
# Add a new node
archerdb cluster add-node \
  --address=new-node.example.com:5001 \
  --data-dir=/data/archerdb

# Remove a node
archerdb cluster remove-node \
  --node-id=3

# Check membership status
archerdb cluster status
# Output:
# Membership: STABLE
# Nodes:
#   0: node-0.example.com:5001 (PRIMARY)
#   1: node-1.example.com:5001 (FOLLOWER)
#   2: node-2.example.com:5001 (FOLLOWER)

# During transition
# Membership: JOINT (adding node 3)
# Progress: 67% caught up
```

### Tuning Parameters

```zig
pub const MembershipConfig = struct {
    /// Max log lag before learner can be promoted (entries)
    learner_catchup_threshold: u64 = 1000,

    /// Timeout for membership change (ms)
    membership_change_timeout_ms: u64 = 300_000,

    /// Drain timeout for leaving nodes (ms)
    drain_timeout_ms: u64 = 30_000,

    /// State transfer rate limit (bytes/sec)
    state_transfer_rate_limit: u64 = 100_000_000,
};
```

## Trade-Offs

### Single vs Multi-Node Changes

| Aspect | Single | Multi-Node |
|--------|--------|------------|
| Safety | Easier to prove | Complex |
| Speed | Slower (sequential) | Faster |
| Implementation | Simpler | Much harder |
| Recovery | Straightforward | Complex |

**Chose single**: Safety and simplicity outweigh speed.

## Validation Plan

### Unit Tests

1. **State machine transitions**: All states reachable correctly
2. **Quorum calculations**: Joint consensus math correct
3. **Learner promotion**: Catch-up detection accurate

### Integration Tests

1. **Add node**: New node joins and receives data
2. **Remove node**: Node leaves without data loss
3. **Primary removal**: Leadership transfers correctly
4. **Failure during change**: Rollback works

### Chaos Tests

1. **Kill node during add**: System recovers
2. **Network partition during change**: No split-brain
3. **Multiple rapid changes**: Serialization works
