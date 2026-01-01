# Replication Specification (VSR - Viewstamped Replication)

**Reference Implementation:** https://github.com/tigerbeetle/tigerbeetle/tree/main/src/vsr

This spec is based on TigerBeetle's Viewstamped Replication (VSR) protocol. Implementers MUST study TigerBeetle's actual VSR code:
- `src/vsr/replica.zig` - Core replica state machine and protocol logic
- `src/vsr/journal.zig` - WAL (journal) with hash-chained prepares
- `src/vsr/clock.zig` - Byzantine clock synchronization (Marzullo's algorithm)
- `src/vsr/client_sessions.zig` - Client session management for idempotency

**Implementation approach:** Adapt TigerBeetle's VSR to operate on GeoEvent instead of Account/Transfer structs. The protocol logic remains identical.

---

## ADDED Requirements

### Requirement: VSR Protocol Core

The system SHALL implement Viewstamped Replication (VSR) with Flexible Paxos quorums for consensus-based state machine replication.

#### Scenario: Cluster configuration

- **WHEN** a cluster is configured
- **THEN** it SHALL support 1-6 active replicas plus 0-4 standby replicas
- **AND** replica count SHOULD be odd for majority-style quorums (1, 3, 5)
- **AND** even replica counts (e.g., 6) MAY be used, but quorum settings MUST be explicitly validated (Flexible Paxos intersection rule)
- **AND** cluster_id (u128) SHALL uniquely identify the cluster

#### Scenario: Flexible Paxos quorums

- **WHEN** quorums are configured
- **THEN** `quorum_replication + quorum_view_change > replica_count` MUST hold
- **AND** `quorum_replication` can be < majority for lower latency
- **AND** `quorum_view_change` can be > majority for safety
- **AND** quorum intersection property ensures consistency

#### Scenario: Primary selection

- **WHEN** determining the primary for a view
- **THEN** `primary_index = view % replica_count`
- **AND** this is deterministic and known to all replicas

### Requirement: Message Protocol

The system SHALL use a fixed 256-byte message header with dual checksums for all VSR protocol messages.

#### Scenario: Message header structure

- **WHEN** a message header is created
- **THEN** it SHALL contain:
  - `checksum: u128` - Aegis-128L MAC of header (after this field)
  - `checksum_padding: u128` - Reserved for u256
  - `checksum_body: u128` - Aegis-128L MAC of body
  - `checksum_body_padding: u128` - Reserved for u256
  - `nonce_reserved: u128` - Reserved for AEAD
  - `cluster: u128` - Cluster identifier
  - `size: u32` - Total message size
  - `epoch: u32` - Cluster epoch
  - `view: u32` - Current view number
  - `command: Command` - Protocol command type
  - `replica: u8` - Sending replica index

#### Scenario: Protocol commands

- **WHEN** the protocol operates
- **THEN** it SHALL support these commands:
  - `ping/pong` - Liveness and clock sync
  - `request` - Client request
  - `prepare` - Primary broadcasts operation
  - `prepare_ok` - Backup confirms prepare
  - `commit` - Primary broadcasts commit point
  - `reply` - Response to client
  - `start_view_change` - Initiates view change
  - `do_view_change` - View change state transfer
  - `start_view` - New primary starts view
  - `request_headers/headers` - Log repair
  - `request_prepare` - Prepare body repair
  - `request_blocks/block` - Grid block repair

### Requirement: Prepare Replication

The system SHALL replicate operations using hash-chained prepares for linearizability.

#### Scenario: Prepare message structure

- **WHEN** a Prepare message is created
- **THEN** it SHALL contain:
  - `parent: u128` - Checksum of previous prepare (hash chain)
  - `client: u128` - Client ID
  - `request: u64` - Client request number
  - `op: u64` - Operation number (monotonic)
  - `commit: u64` - Primary's commit point
  - `timestamp: u64` - Assigned timestamp
  - `operation: Operation` - Operation type
  - `checkpoint_id: u128` - Checkpoint when prepare was created

#### Scenario: Hash chain verification

- **WHEN** a prepare is received
- **THEN** `prepare.parent` MUST equal checksum of prepare at `op - 1`
- **AND** if hash chain breaks in same view, replica SHALL panic
- **AND** hash chain ensures linearizability and fork detection

#### Scenario: PrepareOk response

- **WHEN** a backup durably stores a prepare
- **THEN** it SHALL send PrepareOk containing:
  - `parent: u128` - Same as prepare.parent
  - `prepare_checksum: u128` - Checksum of the prepare
  - `op: u64` - Operation number confirmed
  - `commit_min: u64` - Backup's commit point

#### Scenario: Quorum completion

- **WHEN** primary receives `quorum_replication` PrepareOk messages
- **THEN** the prepare is considered replicated
- **AND** primary MAY advance commit point
- **AND** primary broadcasts Commit message

### Requirement: View Changes

The system SHALL handle primary failures through view changes with state transfer.

#### Scenario: View change trigger

- **WHEN** a backup's `normal_heartbeat_timeout` expires
- **THEN** it SHALL send StartViewChange to all replicas
- **AND** increment its view number
- **AND** transition to view_change status

#### Scenario: StartViewChange quorum

- **WHEN** a replica receives `quorum_view_change` StartViewChange messages
- **THEN** it SHALL send DoViewChange to the new primary
- **AND** stop pipeline processing

#### Scenario: DoViewChange message

- **WHEN** sending DoViewChange
- **THEN** it SHALL contain:
  - `present_bitset` - Which prepares replica has
  - `nack_bitset` - Which prepares replica definitely lacks
  - `op` - Highest operation number
  - `commit_min` - Highest committed operation
  - `checkpoint_op` - Latest checkpoint operation
  - `log_view` - Last view where replica was primary or received StartView
  - View suffix headers for log reconstruction

#### Scenario: Primary log selection (CTRL Protocol)

- **WHEN** new primary receives `quorum_view_change` DoViewChange messages
- **THEN** it SHALL select the log with:
  1. Largest `log_view`
  2. Then largest `op`
- **AND** for uncommitted entries, use present/nack bitsets to decide:
  - If quorum nacks an entry → truncate
  - If quorum doesn't nack → keep and attempt repair

#### Scenario: StartView broadcast

- **WHEN** new primary has reconstructed the log
- **THEN** it SHALL broadcast StartView to all replicas
- **AND** StartView contains the canonical log suffix
- **AND** backups replace their log suffix with primary's version
- **AND** all replicas transition to normal status

### Requirement: View Change Sequence Diagram

The system SHALL follow the view change protocol as illustrated.

#### Scenario: View change sequence (mermaid)

- **WHEN** documenting view change flow
- **THEN** the following sequence diagram SHALL apply:
  ```mermaid
  sequenceDiagram
      autonumber
      participant R0 as Replica 0 (Old Primary)
      participant R1 as Replica 1 (New Primary)
      participant R2 as Replica 2 (Backup)

      Note over R0,R2: PHASE 1: Failure Detection
      R0-xR1: Ping timeout (Primary unresponsive)
      R0-xR2: Ping timeout

      Note over R0,R2: PHASE 2: StartViewChange
      R1->>R1: Increment view, enter view_change status
      R1->>R2: StartViewChange(view=2)
      R2->>R2: Increment view, enter view_change status
      R2->>R1: StartViewChange(view=2)

      Note over R1,R2: Quorum reached (2/3 replicas)

      Note over R0,R2: PHASE 3: DoViewChange
      R1->>R1: Send DoViewChange to self (new primary)
      R2->>R1: DoViewChange(view=2, log_view=1, op=100, commit=98)

      Note over R1: PHASE 4: Log Selection (CTRL Protocol)
      R1->>R1: Select log with highest (log_view, op)
      R1->>R1: Check present/nack bitsets
      R1->>R1: Truncate if quorum nacks entry
      R1->>R1: Keep and repair if not nacked

      Note over R0,R2: PHASE 5: StartView
      R1->>R2: StartView(view=2, canonical_log_suffix)
      R1->>R0: StartView(view=2, canonical_log_suffix)
      R2->>R2: Replace log suffix, enter normal status
      R0->>R0: Replace log suffix, enter normal status

      Note over R0,R2: PHASE 6: Resume Operations
      R1->>R1: Resume as new primary
      R1->>R2: Prepare(view=2, op=101, ...)
      R2->>R1: PrepareOk(view=2, op=101)
  ```

#### Scenario: View change timing breakdown

- **WHEN** analyzing view change latency
- **THEN** the timing breakdown SHALL be:
  ```
  VIEW CHANGE TIMING BREAKDOWN (Target: < 3 seconds total)
  ═════════════════════════════════════════════════════════

  Phase                        │ Duration    │ Notes
  ─────────────────────────────┼─────────────┼─────────────────────────
  Failure detection            │ 200-500ms   │ 2-3 missed pings
  StartViewChange collection   │ 50-200ms    │ Network RTT + processing
  DoViewChange collection      │ 50-200ms    │ Network RTT + processing
  Log selection (CTRL)         │ 10-50ms     │ CPU-bound, fast
  StartView broadcast          │ 50-200ms    │ Network RTT
  Resume operations            │ 10-50ms     │ Pipeline restart
  ─────────────────────────────┼─────────────┼─────────────────────────
  TOTAL                        │ 370-1200ms  │ p99 target: < 2s

  Worst-case additions:
  - Log repair needed: +100-500ms (fetch missing prepares)
  - Cross-region: +200-500ms RTT overhead
  - Heavy load: +100-200ms queue draining
  ```

### Requirement: Checkpoint Coordination Sequence Diagram

The system SHALL coordinate index checkpoints with the VSR commit pipeline.

#### Scenario: Checkpoint coordination sequence (mermaid)

- **WHEN** documenting checkpoint coordination
- **THEN** the following sequence diagram SHALL apply:
  ```mermaid
  sequenceDiagram
      autonumber
      participant VSR as VSR Replica
      participant SM as State Machine
      participant Idx as RAM Index
      participant Chk as Checkpoint Writer
      participant LSM as LSM Storage

      Note over VSR,LSM: Normal operation: ops 1-1000
      loop Every operation
          VSR->>SM: commit(op, timestamp, body)
          SM->>Idx: upsert(entity_id, latest_id, ttl)
          Idx->>Idx: Mark page dirty in bitset
          SM->>LSM: write(event_batch)
      end

      Note over VSR,LSM: Checkpoint trigger at op 1000
      VSR->>VSR: op 1000 = checkpoint_interval
      VSR->>SM: prepare_checkpoint()
      SM->>Idx: checkpoint.start()

      Note over Idx,Chk: Incremental checkpoint
      Idx->>Chk: get_dirty_pages()
      Chk->>Chk: Snapshot dirty bitset
      Idx->>Idx: Clear dirty bitset (new epoch)

      par Background checkpoint write
          Chk->>LSM: write_checkpoint_header(op=1000, hash)
          loop For each dirty page
              Chk->>LSM: write_page(page_num, data)
          end
          Chk->>LSM: fsync()
          Chk->>VSR: checkpoint_complete(op=1000)
      and Continue operations (ops 1001+)
          VSR->>SM: commit(op=1001, ...)
          SM->>Idx: upsert(...) // marks new dirty pages
      end

      Note over VSR,LSM: Checkpoint completion
      VSR->>VSR: update superblock.checkpoint_op = 1000
      VSR->>VSR: Can now recycle WAL slots < 1000
  ```

#### Scenario: Checkpoint backpressure sequence

- **WHEN** checkpoint falls behind WAL head
- **THEN** the following sequence SHALL occur:
  ```mermaid
  sequenceDiagram
      autonumber
      participant C as Client
      participant P as Primary
      participant Idx as Index Checkpoint
      participant WAL as WAL (8192 slots)

      Note over C,WAL: Normal: checkpoint at op 1000, WAL head at 5000
      C->>P: insert_events(batch)
      P->>P: Check: WAL_head - checkpoint_op < threshold
      P->>WAL: Prepare(op=5001)

      Note over C,WAL: Backpressure: checkpoint stuck at 1000, WAL at 7000
      C->>P: insert_events(batch)
      P->>P: Check: 7000 - 1000 = 6000 > 6144 (75% threshold)
      P->>P: Apply backpressure delay

      Note over Idx: Checkpoint writer is slow/stuck
      Idx--xIdx: I/O bottleneck or large dirty set

      Note over C,WAL: Critical: WAL about to wrap
      C->>P: insert_events(batch)
      P->>P: Check: 8000 - 1000 = 7000 > 8192 - 256
      P->>C: Error: checkpoint_lag_backpressure (209)

      Note over C,WAL: Recovery: checkpoint catches up
      Idx->>P: checkpoint_complete(op=5000)
      P->>P: Update checkpoint_op = 5000
      C->>P: insert_events(batch)
      P->>WAL: Prepare(op=8001) // OK, gap is now 3001
  ```

### Requirement: Commit Pipeline

The system SHALL process commits through a staged pipeline for deterministic execution.

#### Scenario: Pipeline stages

- **WHEN** a prepare is committed
- **THEN** it SHALL pass through stages:
  1. `idle` - Waiting for next commit
  2. `check_prepare` - Verify prepare exists
  3. `prefetch` - Load data from LSM (async I/O)
  4. `reply_setup` - Ensure client reply slot writable
  5. `execute` - Run state machine
  6. `compact` - LSM compaction (if needed)
  7. `checkpoint_data` - Persist LSM state
  8. `checkpoint_superblock` - Update superblock

#### Scenario: Deterministic execution

- **WHEN** executing a committed prepare
- **THEN** `state_machine.commit()` SHALL receive only:
  - `client: u128` - From prepare
  - `op: u64` - From prepare
  - `timestamp: u64` - From prepare (not system clock!)
  - `operation: Operation` - From prepare
  - `body: []u8` - From prepare
- **AND** all replicas MUST produce identical state changes

### Requirement: Client Sessions

The system SHALL track client sessions for request idempotency and duplicate detection.

#### Scenario: Session registration

- **WHEN** a client first connects
- **THEN** it SHALL send a `register` request
- **AND** the cluster assigns a unique session number
- **AND** session number = commit op number of registration

#### Scenario: Session table structure

- **WHEN** tracking client sessions
- **THEN** the system SHALL maintain for each client:
  - `client_id: u128` - Client identifier
  - `session: u64` - Session number
  - `request: u64` - Latest request number
  - `header: Header.Reply` - Latest reply header

#### Scenario: Duplicate detection

- **WHEN** a request arrives with `request <= stored_request`
- **THEN** the cached reply SHALL be returned
- **AND** the request SHALL NOT be re-executed

#### Scenario: Deterministic LRU eviction

- **WHEN** client session table is full (`client_sessions_max` reached)
- **THEN** the client with lowest `last_request_op` number SHALL be evicted
- **AND** `last_request_op` is the op number when client last sent a request
- **AND** this implements LRU (Least Recently Used) eviction policy
- **AND** idle clients are evicted first (fair policy)
- **AND** active clients are protected regardless of session age
- **AND** eviction is deterministic across all replicas (same op ordering)

### Requirement: State Synchronization

The system SHALL support two modes of catching up: WAL repair and state sync.

#### Scenario: WAL repair mode

- **WHEN** a replica lags by < 1 checkpoint
- **THEN** it SHALL request missing headers via `request_headers`
- **AND** request missing prepare bodies via `request_prepare`
- **AND** replay the log to catch up

#### Scenario: State sync mode

- **WHEN** a replica lags by >= 1 checkpoint
- **THEN** it SHALL:
  1. Cancel in-progress commit work
  2. Cancel grid I/O
  3. Download entire checkpoint (LSM state)
  4. Replace local checkpoint
  5. Resume from new checkpoint

#### Scenario: Sync trigger detection

- **WHEN** receiving StartView or commit
- **THEN** check if `op_checkpoint_next() + checkpoint_interval <= commit_max`
- **AND** if true, trigger state sync instead of WAL repair

#### Scenario: State sync duration SLA

- **WHEN** a replica performs state sync
- **THEN** sync duration SHALL be bounded by:
  ```
  state_sync_time = download_time + apply_time

  Where:
  - download_time = checkpoint_size / network_bandwidth
  - apply_time = checkpoint_size / disk_write_speed + index_rebuild_time

  Example for 10GB checkpoint on 10Gbps network + 3GB/s disk:
  - Download: 10GB / 1.25GB/s = ~8 seconds
  - Apply: 10GB / 3GB/s = ~3.3 seconds
  - Index rebuild: ~5 seconds (for 100M entries)
  - **Total: ~17 seconds**

  Example for 100GB checkpoint (1B entities, worst case):
  - Download: 100GB / 1.25GB/s = ~80 seconds
  - Apply: 100GB / 3GB/s = ~33 seconds
  - Index rebuild: ~45 seconds (for 1B entries)
  - **Total: ~2.5 minutes**
  ```
- **AND** during state sync, replica cannot serve requests
- **AND** cluster remains available (other replicas serve traffic)
- **AND** operators should monitor:
  - `archerdb_vsr_state_sync_duration_seconds`: Histogram of state sync time
  - `archerdb_vsr_view_changes_total`: Count of view changes
  - `archerdb_vsr_view_change_duration_seconds`: Histogram of time to complete view change
  - `archerdb_vsr_quorum_available`: Gauge (1 = quorum, 0 = no quorum)
  - `archerdb_vsr_replica_lag_ops`: Gauge per replica

### Requirement: Checkpoint-Gated Admission Control

The system SHALL prevent WAL wrapping by throttling client requests if the background index checkpoint falls behind.

#### Scenario: Checkpoint backpressure
- **WHEN** the current WAL head is approaching the oldest un-checkpointed operation
- **AND** `wal_head - index_checkpoint_op > (journal_slot_count * 0.75)` (e.g., > 6144 slots)
- **THEN** the primary SHALL apply exponential backpressure to client requests
- **AND** if gap reaches `journal_slot_count - pipeline_max`, the primary SHALL HALT new operations
- **AND** return `checkpoint_lag_backpressure` (209) error to clients
- **AND** this ensures the WAL never overwrites operations that haven't been persisted to the index checkpoint.

### Requirement: Clock Synchronization

The system SHALL implement Byzantine-fault-tolerant clock synchronization using Marzullo's algorithm.

#### Scenario: Clock model

- **WHEN** modeling clocks
- **THEN** each replica's clock is an interval `[time - error, time + error]`
- **AND** replicas exchange timestamps via ping/pong messages
- **AND** round-trip time is used to estimate error

#### Scenario: Marzullo's algorithm

- **WHEN** computing cluster time
- **THEN** find smallest error margin where quorum of clocks intersect
- **AND** detect and reject outlier/malfunctioning clocks
- **AND** take max with previous timestamp (monotonicity)

#### Scenario: Timestamp assignment

- **WHEN** primary assigns timestamps
- **THEN** it SHALL use `max(cluster_time, previous_timestamp)`
- **AND** `previous_timestamp` SHALL be initialized to the highest timestamp in the canonical log during view change
- **AND** timestamps are only assigned by the primary
- **AND** backups receive timestamp via prepare message

#### Scenario: Clock synchronization failure

- **WHEN** Marzullo's algorithm cannot find a quorum intersection
- **THEN** the system SHALL:
  1. Detect: No time interval where >= quorum_replication clocks agree
  2. Log critical alert: "Clock synchronization failed - no quorum intersection"
  3. Primary behavior:
     - Continue using `max(local_clock + max_drift_tolerance, previous_timestamp + 1)`
     - Incrementing by 1ns ensures strict monotonicity even if local clock is stalled or behind
     - Increment metric: `archerdb_clock_sync_failures_total`
     - Log each affected timestamp assignment
  4. The system continues operating with degraded clock accuracy
  5. Operations remain linearizable (timestamps still monotonic)
- **AND** this is a DEGRADED state requiring operator intervention
- **AND** operator should investigate: NTP misconfiguration, hardware clock drift, network partitions

#### Scenario: Clock outlier detection

- **WHEN** a single replica's clock diverges by > `clock_drift_max` (default: 10 seconds)
- **THEN** the system SHALL:
  1. Mark that replica as clock-outlier
  2. Exclude its clock samples from Marzullo's algorithm
  3. Log warning: "Replica N clock drift exceeds threshold"
  4. Increment metric: `archerdb_clock_outlier_detections_total{replica="N"}`
  5. Continue operating with remaining quorum
- **AND** clock returns to acceptable range automatically resumes participation

#### Scenario: Complete clock failure (all clocks divergent)

- **WHEN** no quorum can be formed even with outlier exclusion
- **AND** condition persists for > `clock_failure_timeout` (default: 60 seconds)
- **THEN** the system SHALL:
  1. Enter "clock-degraded" state
  2. Use primary's local clock only (best-effort timestamps)
  3. Log critical alert: "CRITICAL: All clocks divergent - timestamps may be inaccurate"
  4. Continue accepting writes (availability over perfect timestamps)
  5. Set cluster health status to "degraded"
- **AND** this is an EMERGENCY state - cluster continues but timestamps may drift
- **AND** operator MUST fix clock synchronization (NTP, PTP) immediately

### Requirement: Network Partition Behavior

The system SHALL handle network partitions safely to prevent split-brain scenarios.

#### Scenario: Primary in minority partition

- **WHEN** network partition occurs
- **AND** the primary is in the minority partition (cannot reach quorum)
- **THEN** the primary SHALL:
  1. Continue attempting to replicate (messages will time out)
  2. After `view_change_timeout` (default: 2 seconds, ~3 seconds total failover) without quorum responses:
     - Recognize it cannot commit new operations
     - Return `cluster_unavailable` to clients
     - Continue trying to reach replicas
  3. If partition heals, resume normal operation
  4. If majority partition elects new primary:
     - Old primary's prepare_timestamp may be ahead
     - New primary uses CTRL protocol to reconcile
     - Old primary steps down when it sees higher view number
- **AND** no writes can commit without quorum (safety preserved)

#### Scenario: Client in minority partition

- **WHEN** a client is partitioned from the majority
- **AND** it can reach the old primary (also in minority)
- **THEN** the client SHALL:
  1. Receive `cluster_unavailable` on write attempts
  2. Retry with exponential backoff
  3. Eventually time out and try other replica addresses
- **AND** if client has stale replica addresses, operations fail safely

#### Scenario: Partition detection by replicas

- **WHEN** a replica stops receiving heartbeats from > (replica_count - quorum)
- **THEN** it SHALL:
  1. Recognize potential partition
  2. Log warning: "Possible network partition - heartbeat failures exceed threshold"
  3. If this replica is primary and cannot reach quorum: stop accepting new operations
  4. Backups initiate view change if primary seems unreachable and quorum exists

#### Scenario: Partition healing

- **WHEN** network partition heals
- **THEN** the system SHALL:
  1. Old primary sees messages from new primary with higher view
  2. Old primary transitions to backup state for new view
  3. State sync occurs (CTRL protocol reconciles any divergence)
  4. Clients reconnect to new primary
  5. System returns to normal operation
- **AND** no data loss occurs (only committed operations survive)
- **AND** uncommitted operations on old primary are discarded

### Requirement: Repair Mechanisms

The system SHALL support repair of missing or corrupted data through protocol messages.

#### Scenario: Header repair

- **WHEN** a replica detects missing headers
- **THEN** it SHALL send `request_headers(op_min, op_max)`
- **AND** any replica with those headers responds
- **AND** repairs are verified via hash chain

#### Scenario: Prepare repair

- **WHEN** a replica has header but missing body
- **THEN** it SHALL send `request_prepare(op)`
- **AND** checksum in header verifies body integrity

#### Scenario: Grid block repair

- **WHEN** LSM block is missing or corrupted
- **THEN** it SHALL send `request_blocks(addresses[])`
- **AND** other replicas respond with block data
- **AND** block checksum verifies integrity

#### Scenario: Repair budget

- **WHEN** performing repairs
- **THEN** concurrent repair requests SHALL be bounded
- **AND** exponential backoff on timeout
- **AND** prevents repair feedback loops

### Requirement: Standby Nodes

The system SHALL support non-voting standby nodes for read scaling and zero-downtime upgrades.

#### Scenario: Standby behavior

- **WHEN** a node is configured as standby
- **THEN** `replica_index >= replica_count`
- **AND** standbys receive and replicate prepares
- **AND** standbys never send PrepareOk
- **AND** standbys do not participate in view changes

#### Scenario: Standby promotion

- **WHEN** promoting a standby to active
- **THEN** cluster reconfiguration is required
- **AND** standby must have complete state
- **AND** no data loss occurs during promotion

### Requirement: Primary Abdication

The system SHALL handle primary backpressure through voluntary abdication.

#### Scenario: Abdication trigger

- **WHEN** primary's prepares are not getting quorum
- **THEN** primary sets `primary_abdicating = true`
- **AND** primary stops sending commit heartbeats
- **AND** backups' heartbeat timeout triggers view change

#### Scenario: Backpressure detection

- **WHEN** prepare timeout expires without quorum
- **THEN** this indicates network partition or overload
- **AND** abdication allows faster failover

### Requirement: VSR State Persistence

The system SHALL persist VSR protocol state in the superblock for crash recovery.

#### Scenario: VSRState fields

- **WHEN** persisting VSR state
- **THEN** VSRState SHALL contain:
  - `checkpoint: CheckpointState` - Checkpoint metadata
  - `replica_id: u128` - This replica's identifier
  - `members: Members` - Cluster membership configuration
  - `commit_max: u64` - Maximum committed operation
  - `commit_timestamp_max: u64` - Timestamp of latest committed operation (for monotonicity)
  - `sync_op_min/max: u64` - State sync tracking
  - `log_view: u32` - Last normal view
  - `view: u32` - Current view
  - `replica_count: u8` - Active replica count

#### Scenario: Recovery from crash

- **WHEN** replica restarts after crash
- **THEN** it SHALL load VSRState from superblock
- **AND** replay WAL from checkpoint to reconstruct state
- **AND** rejoin cluster at recorded view

### Requirement: Protocol Invariants

The system SHALL maintain critical invariants for safety.

#### Scenario: View invariant

- **WHEN** checking view numbers
- **THEN** `replica.view >= replica.log_view` always
- **AND** `replica.view == replica.log_view` when status is normal

#### Scenario: Operation invariant

- **WHEN** checking operation numbers
- **THEN** `replica.op` always exists in journal
- **AND** `replica.op >= replica.op_checkpoint`
- **AND** `replica.op >= replica.commit_min`

#### Scenario: Commit invariant

- **WHEN** checking commit numbers
- **THEN** `replica.commit_min >= replica.op_checkpoint`
- **AND** `replica.commit_max >= replica.commit_min`
- **AND** both only increase monotonically (safety)

#### Scenario: Checkpoint durability

- **WHEN** managing the journal
- **THEN** entries at `op < op_checkpoint` MAY be overwritten
- **AND** uncommitted entries are protected by checkpoint interval
- **AND** `journal_slot_count >= pipeline_max + 2 * checkpoint_interval`

### Requirement: Replica Addition Procedure

The system SHALL support adding new replicas to an existing cluster for capacity expansion or replacement.

#### Scenario: Adding a new replica

- **WHEN** adding a new replica to an existing cluster
- **THEN** the operator SHALL follow this procedure:
  1. **Preparation**:
     - Provision new server with required hardware
     - Install same ArcherDB version as existing cluster
     - Ensure network connectivity to all existing replicas
     - Generate TLS certificates signed by cluster CA
  2. **Format new replica**:
     ```
     archerdb format \
       --cluster=<existing-cluster-id> \
       --replica=<new-index> \
       --replica-count=<new-total> \
       --data-file=/path/to/data.archerdb
     ```
  3. **Update cluster configuration** (all replicas):
     - Update `--addresses` to include new replica
     - Update `--replica-count` to new total
     - This requires restart of each existing replica (rolling)
  4. **Start new replica**:
     - New replica starts in state sync mode
     - Downloads checkpoint from existing replicas
     - Joins cluster as backup
  5. **Verification**:
     - Verify new replica shows in `archerdb status`
     - Verify replication lag is minimal
     - Verify cluster health metrics

#### Scenario: Adding replica timing

- **WHEN** adding a replica
- **THEN** expected duration is:
  - Configuration update (rolling restart): ~3 minutes for 5 replicas
  - State sync for new replica: depends on data size (see State sync duration SLA)
  - Total: ~5-10 minutes for typical cluster
- **AND** cluster remains available throughout (quorum maintained)

#### Scenario: Reconfiguration constraints

- **WHEN** changing cluster membership
- **THEN** the following constraints SHALL apply:
  - Only ONE membership change at a time
  - Quorum must be maintained throughout
  - New replica_count must be 1, 3, 5, or 6
  - Cannot add AND remove replicas simultaneously
- **AND** these constraints ensure safety during reconfiguration

### Requirement: Replica Removal Procedure

The system SHALL support removing replicas from a cluster for decommissioning or replacement.

#### Scenario: Removing a backup replica

- **WHEN** removing a backup replica
- **THEN** the operator SHALL follow this procedure:
  1. **Pre-removal checks**:
     - Verify replica to remove is NOT the primary
     - Verify cluster will maintain quorum after removal
     - Verify other replicas are healthy
  2. **Stop the replica**:
     - Send SIGTERM for graceful shutdown
     - Wait for replica to exit
  3. **Update cluster configuration** (remaining replicas):
     - Update `--addresses` to remove the replica
     - Update `--replica-count` to new total
     - Rolling restart of remaining replicas
  4. **Cleanup**:
     - Optionally delete data file from removed node
     - Update monitoring/alerting configuration
  5. **Verification**:
     - Verify `archerdb status` shows new cluster size
     - Verify cluster health
     - Verify removed replica no longer receives traffic

#### Scenario: Removing the primary replica

- **WHEN** the replica to remove is currently the primary
- **THEN** the operator SHALL:
  1. Trigger view change by stopping the primary (SIGTERM)
  2. Wait for new primary election (~3 seconds)
  3. Proceed with removal procedure as for backup
- **AND** brief write unavailability occurs during view change

#### Scenario: Emergency replica removal

- **WHEN** a replica has failed catastrophically (hardware failure)
- **AND** cannot be gracefully stopped
- **THEN** the operator SHALL:
  1. Verify cluster still has quorum without failed replica
  2. Update configuration on remaining replicas
  3. Rolling restart remaining replicas
  4. Failed replica is automatically excluded from quorum
- **AND** cluster continues operating (assuming quorum)

### Requirement: Cross-AZ Deployment Performance

The system SHALL document realistic throughput and latency targets for cross-availability-zone deployments.

#### Scenario: Cross-AZ latency impact on commit

- **WHEN** deploying 3 replicas across 3 availability zones
- **THEN** commit latency SHALL be:
  ```
  commit_latency = 2 × cross_az_rtt + local_processing

  Where cross_az_rtt by cloud provider (typical):
  - AWS (same region): 1-2ms
  - GCP (same region): 1-3ms
  - Azure (same region): 1-2ms

  Example (AWS, 3-AZ deployment):
  - Cross-AZ RTT: ~1.5ms
  - Local processing: ~0.5ms
  - commit_latency = 2 × 1.5ms + 0.5ms = ~3.5ms
  - **Achievable write throughput: ~285 writes/sec (sequential)**
  ```
- **AND** with batching (10,000 events/batch), effective throughput is 2.85M events/sec
- **AND** this assumes quorum_replication=2 (primary + 1 backup)

#### Scenario: Same-AZ deployment comparison

- **WHEN** deploying 3 replicas in same availability zone
- **THEN** commit latency SHALL be:
  ```
  Same-AZ RTT: ~0.1-0.2ms
  commit_latency = 2 × 0.15ms + 0.5ms = ~0.8ms
  Achievable write throughput: ~1,250 writes/sec (sequential)
  ```
- **AND** same-AZ sacrifices zone redundancy for lower latency
- **AND** single AZ failure loses all replicas

#### Scenario: Hybrid deployment (2+1)

- **WHEN** deploying 2 replicas in primary AZ + 1 in secondary AZ
- **THEN** with quorum_replication=2:
  - Both quorum replicas can be in same AZ
  - commit_latency = same-AZ latency (~0.8ms)
  - Cross-AZ replica receives asynchronously
  - **Warning**: Primary AZ failure loses quorum (cluster unavailable)
- **AND** this trades availability for latency
- **AND** NOT recommended for production (quorum requires cross-AZ)

#### Scenario: Network bandwidth for cross-AZ replication

- **WHEN** calculating cross-AZ bandwidth requirements
- **THEN** requirements SHALL be:
  ```
  Per-replica bandwidth:
  - Prepare messages: events/sec × 128 bytes × 2 (prepare + prepare_ok)
  - At 100K events/sec: ~25 MB/s per replica link
  - At 1M events/sec: ~250 MB/s per replica link

  Cross-AZ bandwidth costs (approximate):
  - AWS: $0.01/GB cross-AZ transfer
  - At 1M events/sec: ~22 TB/day = ~$220/day per replica link
  - With 3 replicas: ~$440/day cross-AZ transfer cost
  ```
- **AND** operators SHOULD factor bandwidth costs into deployment planning
- **AND** same-AZ deployment eliminates cross-AZ transfer costs

#### Scenario: Recommended deployment configurations

- **WHEN** choosing deployment configuration
- **THEN** the following recommendations SHALL apply:
  ```
  Production (high availability):
  - 3 replicas across 3 AZs
  - quorum_replication=2, quorum_view_change=2
  - Expected write latency: 3-5ms
  - Tolerates: 1 AZ failure, 1 replica failure

  Production (low latency):
  - 5 replicas across 3 AZs (2+2+1 distribution)
  - quorum_replication=3, quorum_view_change=3
  - Expected write latency: 3-5ms (need 2 same-AZ for quorum)
  - Tolerates: 1 AZ failure with full availability

  Development/Testing:
  - 1 replica (no replication)
  - Expected write latency: <1ms
  - Tolerates: nothing (single point of failure)
  ```

#### Scenario: Throughput targets summary

- **WHEN** setting performance expectations
- **THEN** achievable throughput targets SHALL be:
  ```
  | Deployment      | Write Latency | Batched Throughput | Sequential Throughput |
  |-----------------|---------------|--------------------|-----------------------|
  | Same-AZ (3)     | ~1ms          | 10M events/sec     | 1,000 writes/sec      |
  | Cross-AZ (3)    | ~4ms          | 2.5M events/sec    | 250 writes/sec        |
  | Cross-Region    | ~50-100ms     | 100K events/sec    | 10-20 writes/sec      |
  ```
- **AND** "batched throughput" assumes 10,000 events per batch
- **AND** "sequential throughput" is individual writes waiting for commit
- **AND** cross-region deployment is NOT recommended (use async replication)

### Requirement: Cross-Region Replication (v2 - OUT OF SCOPE)

Cross-region replication is NOT included in v1 scope due to complexity. This section documents the v1 disaster recovery strategy and planned v2 features.

#### Scenario: v1 disaster recovery strategy

- **WHEN** operating ArcherDB v1 with cross-region durability requirements
- **THEN** operators SHALL use S3/GCS backup for disaster recovery:
  ```
  v1 DR Architecture:
  ┌─────────────────────────────────────┐
  │           Primary Region            │
  │  ┌─────┐  ┌─────┐  ┌─────┐         │
  │  │ R1  │  │ R2  │  │ R3  │         │
  │  └──┬──┘  └──┬──┘  └──┬──┘         │
  │     │        │        │            │
  │     └────────┼────────┘            │
  │              │                     │
  │       ┌──────▼──────┐              │
  │       │  S3 Backup  │──────────────┼──► Cross-Region
  │       └─────────────┘              │    S3 Replication
  └─────────────────────────────────────┘
  ```
- **AND** RPO (Recovery Point Objective) = backup frequency (default: 60 seconds)
- **AND** RTO (Recovery Time Objective) = restore time + index rebuild (see ttl-retention spec)
- **AND** S3 cross-region replication provides geographic durability

#### Scenario: v1 DR recovery procedure

- **WHEN** primary region becomes unavailable
- **THEN** recovery procedure SHALL be:
  1. Provision new cluster in DR region
  2. Restore from latest S3 backup: `archerdb restore --from-s3=s3://backup-bucket`
  3. Update DNS/load balancer to point to DR region
  4. Accept that transactions since last backup are lost (RPO)
- **AND** estimated RTO for 1B entities: 60-90 minutes (see ttl-retention RTO targets)

#### Scenario: v2 planned features (informational)

- **WHEN** planning v2 cross-region features
- **THEN** the following are under consideration:
  1. **Async log shipping**: Primary region ships committed prepares to follower region
  2. **Read-only followers**: Cross-region replicas that serve read queries only
  3. **Geo-sharding**: Partition entities by geography for multi-region writes
  4. **Active-active**: Conflict resolution for concurrent writes (complex)
- **AND** these features will be specified in a separate v2 proposal
- **AND** v1 users should plan around S3 backup DR

#### Scenario: Why cross-region VSR is not supported

- **WHEN** evaluating cross-region synchronous replication
- **THEN** it is NOT supported because:
  1. Cross-region latency (50-200ms) makes quorum commits slow
  2. Network partitions between regions cause frequent view changes
  3. VSR assumes same-region latency for liveness detection
  4. Write throughput would be limited to ~10-50 sequential ops/sec
- **AND** async replication (v2) is the correct approach for cross-region

### Requirement: Replica Replacement Procedure

The system SHALL support replacing a failed replica with a new one.

#### Scenario: Replace failed replica

- **WHEN** a replica has permanently failed
- **THEN** the operator SHALL follow this procedure:
  1. **Remove failed replica** (if not already done):
     - Follow Emergency Replica Removal if needed
  2. **Provision replacement**:
     - Same hardware requirements as failed replica
     - Same replica index as failed replica
  3. **Bootstrap replacement**:
     - If data file intact: copy to new hardware, start
     - If data file lost: format new, let it state sync
  4. **Update configuration**:
     - Update `--addresses` with new IP (same replica index)
     - Rolling restart if IP changed
  5. **Verification**:
     - Verify replacement has synced completely
     - Verify cluster health restored

#### Scenario: Replace with data recovery

- **WHEN** replacing replica AND data file can be recovered
- **THEN** recovery is faster:
  - Copy data file to new hardware
  - Start replica (it will replay WAL to catch up)
  - Catch-up time: seconds to minutes (WAL replay only)
- **AND** this is preferred when disk is recoverable

#### Scenario: Replace without data

- **WHEN** replacing replica AND data file is unrecoverable
- **THEN** full state sync is required:
  - Format new replica with same cluster ID
  - Start replica (triggers full state sync)
  - Sync time: minutes (full checkpoint download)
- **AND** cluster remains available during sync
