# Implementation Tasks: Dynamic Cluster Membership

## Phase 1: Core Protocol

### Task 1.1: Define membership state machine
- **File**: `src/vsr/membership.zig` (new)
- **Changes**:
  - Define `MembershipState` enum (stable, joint)
  - Define `NodeRole` enum (learner, follower, candidate, primary)
  - Define `MembershipConfig` struct
  - State transition logic
- **Validation**: State machine compiles
- **Estimated effort**: 2 hours

### Task 1.2: Implement joint consensus quorum
- **File**: `src/vsr/membership.zig`
- **Changes**:
  - Calculate quorum for joint configuration
  - Require majority in both old AND new
  - Update vote counting logic
- **Validation**: Quorum calculations correct
- **Estimated effort**: 2 hours

### Task 1.3: Integrate membership with VSR
- **File**: `src/vsr/replica.zig`
- **Changes**:
  - Add membership state to replica
  - Check membership in vote handling
  - Include membership in view change
- **Validation**: VSR works with membership
- **Estimated effort**: 3 hours

## Phase 2: Add Node

### Task 2.1: Implement learner state
- **File**: `src/vsr/replica.zig`
- **Changes**:
  - Learner receives prepare messages
  - Learner doesn't vote
  - Track learner catch-up progress
- **Validation**: Learner receives data
- **Estimated effort**: 2 hours

### Task 2.2: Implement state transfer to learner
- **File**: `src/vsr/replica.zig`
- **Changes**:
  - Stream log entries to learner
  - Transfer grid blocks
  - Rate limiting
- **Validation**: Learner catches up
- **Estimated effort**: 3 hours

### Task 2.3: Implement learner promotion
- **File**: `src/vsr/membership.zig`
- **Changes**:
  - Detect when learner is caught up
  - Trigger joint consensus with new node
  - Promote learner to follower
- **Validation**: Learner becomes follower
- **Estimated effort**: 2 hours

### Task 2.4: Complete add node transition
- **File**: `src/vsr/membership.zig`
- **Changes**:
  - Commit joint configuration
  - Transition to new stable config
  - Update cluster metadata
- **Validation**: Node fully added
- **Estimated effort**: 2 hours

## Phase 3: Remove Node

### Task 3.1: Implement graceful departure
- **File**: `src/vsr/membership.zig`
- **Changes**:
  - Mark node as leaving
  - Stop accepting new operations on leaving node
  - Drain in-flight operations
- **Validation**: Clean drain
- **Estimated effort**: 2 hours

### Task 3.2: Handle primary removal
- **File**: `src/vsr/replica.zig`
- **Changes**:
  - Trigger view change if primary leaving
  - Elect new primary from remaining nodes
  - Then proceed with removal
- **Validation**: Leadership transfers
- **Estimated effort**: 2 hours

### Task 3.3: Complete remove node transition
- **File**: `src/vsr/membership.zig`
- **Changes**:
  - Commit joint configuration excluding node
  - Transition to new stable config
  - Signal removed node to shut down
- **Validation**: Node cleanly removed
- **Estimated effort**: 2 hours

## Phase 4: CLI Integration

### Task 4.1: Add cluster add-node command
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Parse add-node command
  - Validate node address
  - Send join request
  - Monitor progress
- **Validation**: CLI works
- **Estimated effort**: 1.5 hours

### Task 4.2: Add cluster remove-node command
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Parse remove-node command
  - Validate node ID
  - Send removal request
  - Monitor progress
- **Validation**: CLI works
- **Estimated effort**: 1.5 hours

### Task 4.3: Update cluster status command
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Show membership state
  - Show node roles
  - Show catch-up progress
- **Validation**: Status accurate
- **Estimated effort**: 1 hour

## Phase 5: Metrics & Observability

### Task 5.1: Add membership metrics
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - `archerdb_cluster_membership_state` gauge
  - `archerdb_cluster_nodes_total` gauge
  - `archerdb_cluster_learners_total` gauge
  - `archerdb_membership_changes_total` counter
- **Validation**: Metrics visible
- **Estimated effort**: 30 minutes

### Task 5.2: Add state transfer metrics
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - `archerdb_state_transfer_bytes_total` counter
  - `archerdb_state_transfer_progress` gauge
  - `archerdb_learner_lag_entries` gauge
- **Validation**: Progress trackable
- **Estimated effort**: 30 minutes

### Task 5.3: Add membership logging
- **File**: `src/vsr/membership.zig`
- **Changes**:
  - Log membership state changes
  - Log learner progress
  - Log node additions/removals
- **Validation**: Clear audit trail
- **Estimated effort**: 30 minutes

## Phase 6: Testing

### Task 6.1: Unit tests for membership
- **File**: `src/vsr/membership.zig` (test section)
- **Tests**:
  - State machine transitions
  - Joint consensus quorum
  - Learner promotion logic
- **Validation**: All tests pass
- **Estimated effort**: 3 hours

### Task 6.2: Integration tests for add node
- **File**: Integration test suite
- **Tests**:
  - Add node to 3-node cluster
  - Verify data replication
  - Verify node participates in votes
- **Validation**: All tests pass
- **Estimated effort**: 3 hours

### Task 6.3: Integration tests for remove node
- **File**: Integration test suite
- **Tests**:
  - Remove follower from cluster
  - Remove primary (triggers view change)
  - Verify no data loss
- **Validation**: All tests pass
- **Estimated effort**: 3 hours

### Task 6.4: Chaos tests
- **File**: Chaos test suite
- **Tests**:
  - Kill node during add
  - Network partition during change
  - Concurrent membership requests
- **Validation**: System recovers
- **Estimated effort**: 4 hours

## Phase 7: Documentation

### Task 7.1: Operations guide
- **File**: Documentation
- **Changes**:
  - How to add/remove nodes
  - Capacity planning for changes
  - Troubleshooting membership issues
- **Validation**: Guide complete
- **Estimated effort**: 2 hours

### Task 7.2: Update CLI help
- **File**: CLI help text
- **Changes**:
  - Document add-node command
  - Document remove-node command
  - Examples
- **Validation**: Help accurate
- **Estimated effort**: 30 minutes

## Dependencies

- Phase 2 depends on Phase 1
- Phase 3 depends on Phase 1
- Phases 4-7 depend on Phases 2 and 3

## Estimated Total Effort

- **Core Protocol**: 7 hours
- **Add Node**: 9 hours
- **Remove Node**: 6 hours
- **CLI Integration**: 4 hours
- **Metrics**: 1.5 hours
- **Testing**: 13 hours
- **Documentation**: 2.5 hours
- **Total**: ~43 hours (~5-6 working days)

## Verification Checklist

- [x] Joint consensus quorum calculates correctly (hasQuorum in src/vsr/membership.zig)
- [x] Learner role defined, canVote returns false (NodeRole in src/vsr/membership.zig)
- [x] Learner caught-up detection (isLearnerCaughtUp in src/vsr/membership.zig)
- [x] Add node as learner (addLearner in src/vsr/membership.zig)
- [x] Learner promotion triggers joint consensus (promoteLearner in src/vsr/membership.zig)
- [x] Remove node drains cleanly (beginNodeRemoval in src/vsr/membership.zig)
- [x] State transitions implemented (beginTransition, completeTransition, abortTransition)
- [x] Unit tests pass (12 tests in src/vsr/membership.zig)
- [x] VSR replica integration (membership_config field, initMembershipConfig, hasReplicationQuorum, beginAddLearner, beginRemoveNode in replica.zig:6897-6962)
- [x] Primary removal triggers view change (membershipRequiresViewChange checks primary status, beginRemoveNode logs view change requirement)
- [x] CLI commands work (add-node, remove-node, status in cli.zig:752, main.zig:443)
- [x] Metrics track progress (src/archerdb/metrics.zig: membership_* metrics, wired to src/vsr/membership.zig)
- [ ] Chaos tests pass
- [ ] Documentation complete
