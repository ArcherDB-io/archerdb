# Replication - Dynamic Cluster Membership

## ADDED Requirements

### Requirement: Membership State Machine

The system SHALL support dynamic membership changes through a formal state machine.

#### Scenario: Membership states

- **WHEN** cluster membership is managed
- **THEN** the system SHALL support states:
  ```zig
  pub const MembershipState = enum {
      /// Normal operation with fixed membership
      stable,
      /// Transitioning with joint consensus
      joint,
  };
  ```

#### Scenario: Node roles

- **WHEN** a node participates in cluster
- **THEN** it SHALL have one of these roles:
  ```zig
  pub const NodeRole = enum {
      /// Receiving data but not voting
      learner,
      /// Caught up and voting
      follower,
      /// Running for primary
      candidate,
      /// Current leader
      primary,
  };
  ```

### Requirement: Joint Consensus

The system SHALL use joint consensus for safe membership transitions.

#### Scenario: Joint configuration

- **WHEN** membership change is initiated
- **THEN** the system SHALL:
  - Enter joint configuration (C_old ∪ C_new)
  - Require majority in BOTH old AND new configs for commits
  - Transition to new config only after joint config committed

#### Scenario: Quorum calculation in joint mode

- **WHEN** counting votes in joint configuration
- **THEN** the system SHALL:
  ```zig
  pub fn isQuorum(config: MembershipConfig, votes: []NodeId) bool {
      if (config.state == .joint) {
          // Need majority in BOTH old and new
          return hasMajority(config.old_members, votes) and
                 hasMajority(config.new_members, votes);
      } else {
          return hasMajority(config.members, votes);
      }
  }
  ```

#### Scenario: Single-node change limit

- **WHEN** requesting membership change
- **THEN** the system SHALL:
  - Allow only ONE node addition or removal at a time
  - Reject concurrent membership change requests
  - Return error: "Membership change already in progress"

### Requirement: Add Node Protocol

The system SHALL support adding nodes to a running cluster.

#### Scenario: Join as learner

- **WHEN** new node joins cluster
- **THEN** the system SHALL:
  1. Accept node as `learner`
  2. Stream log entries and state to learner
  3. Learner receives prepares but doesn't vote
- **AND** learner SHALL NOT affect cluster availability

#### Scenario: State transfer to learner

- **WHEN** learner is catching up
- **THEN** primary SHALL:
  - Stream committed log entries
  - Transfer grid blocks
  - Respect rate limit (default: 100MB/s)
- **AND** state transfer SHALL NOT block normal operations

#### Scenario: Learner promotion

- **WHEN** learner lag drops below threshold
- **THEN** the system SHALL:
  - Initiate joint consensus including learner
  - Promote learner to follower
  - Learner begins voting
- **AND** promotion threshold SHALL be configurable (default: 1000 entries)

#### Scenario: Add node completion

- **WHEN** joint configuration is committed
- **THEN** the system SHALL:
  - Transition to new stable configuration
  - Include new node in future quorum calculations
  - Log: "Node X added to cluster"

### Requirement: Remove Node Protocol

The system SHALL support removing nodes from a running cluster.

#### Scenario: Graceful departure

- **WHEN** node removal is requested
- **THEN** the leaving node SHALL:
  1. Stop accepting new client operations
  2. Complete in-flight operations (drain timeout: 30s)
  3. Participate in joint consensus
  4. Exit cleanly when new config committed

#### Scenario: Primary removal

- **WHEN** primary is being removed
- **THEN** the system SHALL:
  1. Trigger view change to elect new primary
  2. New primary initiates removal of old primary
  3. Continue with normal removal protocol

#### Scenario: Remove node completion

- **WHEN** joint configuration excluding node is committed
- **THEN** the system SHALL:
  - Transition to new stable configuration
  - Exclude removed node from quorum calculations
  - Signal removed node: "Safe to shut down"
  - Log: "Node X removed from cluster"

### Requirement: Membership CLI

The system SHALL provide CLI commands for membership management.

#### Scenario: Add node command

- **WHEN** operator adds node
- **THEN** CLI SHALL support:
  ```bash
  archerdb cluster add-node \
    --address=new-node.example.com:5001 \
    --data-dir=/data/archerdb

  # Output:
  # Adding node new-node.example.com:5001...
  # State transfer: 45% complete
  # State transfer: 100% complete
  # Promoting to follower...
  # Node added successfully.
  ```

#### Scenario: Remove node command

- **WHEN** operator removes node
- **THEN** CLI SHALL support:
  ```bash
  archerdb cluster remove-node --node-id=3

  # Output:
  # Removing node 3...
  # Draining operations...
  # Transitioning to new configuration...
  # Node removed successfully.
  ```

#### Scenario: Membership status

- **WHEN** operator checks status
- **THEN** CLI SHALL show:
  ```
  archerdb cluster status

  Membership: STABLE
  Nodes: 5
    0: node-0.example.com:5001 (PRIMARY)
    1: node-1.example.com:5001 (FOLLOWER)
    2: node-2.example.com:5001 (FOLLOWER)
    3: node-3.example.com:5001 (FOLLOWER)
    4: node-4.example.com:5001 (FOLLOWER)
  ```

### Requirement: Membership Metrics

The system SHALL expose metrics for membership changes.

#### Scenario: Membership state metric

- **WHEN** exposing cluster metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_cluster_membership_state Current membership state (0=stable, 1=joint)
  # TYPE archerdb_cluster_membership_state gauge
  archerdb_cluster_membership_state 0

  # HELP archerdb_cluster_nodes_total Total nodes in cluster
  # TYPE archerdb_cluster_nodes_total gauge
  archerdb_cluster_nodes_total 5
  ```

#### Scenario: State transfer metrics

- **WHEN** learner is catching up
- **THEN** the system SHALL expose:
  ```
  # HELP archerdb_state_transfer_progress Learner catch-up progress (0.0 to 1.0)
  # TYPE archerdb_state_transfer_progress gauge
  archerdb_state_transfer_progress{node="5"} 0.67

  # HELP archerdb_learner_lag_entries Learner lag in log entries
  # TYPE archerdb_learner_lag_entries gauge
  archerdb_learner_lag_entries{node="5"} 3500
  ```

#### Scenario: Membership change counter

- **WHEN** membership changes complete
- **THEN** the system SHALL expose:
  ```
  # HELP archerdb_membership_changes_total Total membership changes
  # TYPE archerdb_membership_changes_total counter
  archerdb_membership_changes_total{type="add"} 3
  archerdb_membership_changes_total{type="remove"} 1
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Membership State Machine | IMPLEMENTED | `src/vsr/membership.zig` - MembershipState, NodeRole enums |
| Joint Consensus | IMPLEMENTED | `src/vsr/membership.zig` - Joint quorum calculations |
| Add Node Protocol | IMPLEMENTED | `src/archerdb/cli.zig` - add-node command with learner promotion |
| Remove Node Protocol | IMPLEMENTED | `src/archerdb/cli.zig` - remove-node command with graceful drain |
| Membership CLI | IMPLEMENTED | `src/archerdb/cli.zig` - cluster add-node, remove-node, status |
| Membership Metrics | IMPLEMENTED | `src/archerdb/metrics.zig` - cluster membership metrics |

## Related Specifications

- See base `replication/spec.md` for VSR protocol
- See `configuration/spec.md` for CLI framework
- See `observability/spec.md` for metrics endpoint
