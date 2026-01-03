# VSR (Viewstamped Replication) Understanding

This document captures our understanding of TigerBeetle's VSR implementation, which
ArcherDB inherits. This knowledge is critical for F1 (state machine replacement) and
F4 (VOPR hardening).

## 1. Replica Structure Overview

The `Replica` struct in `src/vsr/replica.zig` is the core consensus engine. Key fields:

### Cluster Configuration
```
cluster: u128              - Cluster identifier
replica_count: u8          - Number of active replicas
standby_count: u8          - Number of standby nodes
replica: u8                - This replica's index
quorum_replication: u8     - Quorum size for replication
quorum_view_change: u8     - Quorum size for view changes
```

### Protocol State
```
view: u32                  - Current view number
log_view: u32              - Latest view where replica became primary/backup
status: Status             - {normal, view_change, recovering, recovering_head}
op: u64                    - Latest prepared operation number
commit_min: u64            - Latest committed operation (locally executed)
commit_max: u64            - Latest committed operation (cluster-wide)
```

### Persistent Storage
```
journal: Journal           - Hash-chained log of prepares (WAL)
superblock: SuperBlock     - Durable VSR state, LSM root
client_sessions            - Current client session state
client_replies             - Latest reply per client
grid: Grid                 - LSM tree storage
```

## 2. Message Flow

### The Core Replication Loop

```
                           ┌──────────────────────────────┐
                           │         Primary              │
                           │                              │
  Client ──Request──►      │  1. Create PREPARE           │
                           │     (op, checksum, parent)   │
                           │                              │
                           │  2. Send to all replicas     │
                           └──────────┬───────────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
         ┌─────────┐            ┌─────────┐            ┌─────────┐
         │Replica 0│            │Replica 1│            │Replica 2│
         │(Primary)│            │(Backup) │            │(Backup) │
         └────┬────┘            └────┬────┘            └────┬────┘
              │                      │                      │
              │   ◄───PREPARE_OK─────┤                      │
              │   ◄───PREPARE_OK─────┼──────────────────────┤
              │                      │                      │
              │  3. Quorum reached   │                      │
              │     (commit_pipeline)│                      │
              │                      │                      │
              │──────COMMIT──────────►                      │
              │                      │                      │
              │  4. Execute on       │  5. Execute on       │
              │     state machine    │     state machine    │
              │                      │                      │
              │──────Reply───────────────────────────────────► Client
```

### PREPARE Message
- Sent by: Primary → All replicas
- Contains: op, commit, view, parent checksum, client ID, operation type, body
- Purpose: Replicate operation before committing

### PREPARE_OK Message
- Sent by: All replicas → Primary
- Contains: prepare_checksum, op, commit_min, parent
- Purpose: Acknowledge prepare receipt

### COMMIT Message
- Sent by: Primary → Backups (heartbeat)
- Contains: commit number, commit_checksum, checkpoint_op
- Purpose: Advance commit_max, detect primary liveness

## 3. View Changes

### Status Transitions
```
                    ┌─────────────┐
                    │  recovering │ (startup)
                    └──────┬──────┘
                           │ journal replay complete
                           ▼
   timeout         ┌─────────────┐
 ─────────────────►│   normal    │◄──────────────────
                   └──────┬──────┘                  │
                          │ heartbeat timeout       │ received START_VIEW
                          ▼                         │
                   ┌─────────────┐                  │
                   │ view_change │──────────────────┘
                   └─────────────┘
```

### View Change Protocol

1. **START_VIEW_CHANGE (SVC)**: Broadcast to all replicas, wait for quorum
2. **DO_VIEW_CHANGE (DVC)**: New primary collects from quorum
3. **START_VIEW (SV)**: New primary broadcasts to confirm new view

### Quorums
- `quorum_replication`: Majority required for prepare ack
- `quorum_view_change`: Majority required for view change
- Both prevent split-brain scenarios

## 4. State Machine Interface

### Contract Methods
```zig
StateMachine {
    fn open()       // Initialize and load state
    fn commit()     // Apply operation, return reply
    fn compact()    // Run LSM compaction
    fn checkpoint() // Persist state to grid
}
```

### Commit Stages (Primary)
```
idle → start → check_prepare → prefetch →
stall → reply_setup → execute →
checkpoint_durable → compact → checkpoint_data →
checkpoint_superblock → idle
```

### Replica Events to State Machine
```zig
ReplicaEvent = union(enum) {
    message_sent,
    state_machine_opened,
    committed: { prepare, reply },
    compaction_completed,
    checkpoint_commenced,
    checkpoint_completed,
    sync_stage_changed,
    client_evicted,
}
```

## 5. Checkpoint Sequence

Checkpointing persists state durably so the journal can be truncated. The sequence
ensures crash recovery correctness.

### Checkpoint Flow (grid → fsync → superblock → fsync)

```
┌─────────────────────────────────────────────────────────────────────┐
│  1. GRID WRITE PHASE                                                │
│     - State machine writes data to grid blocks                      │
│     - LSM compaction flushes SSTables                               │
│     - Client replies persisted                                      │
│     - All writes accumulated in write buffer                        │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  2. GRID FSYNC                                                      │
│     - fsync() on grid file                                          │
│     - Ensures all data blocks durable before superblock update      │
│     - Critical: superblock must not point to non-durable data       │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  3. SUPERBLOCK WRITE                                                │
│     - Write new superblock with:                                    │
│       • checkpoint_id (monotonic)                                   │
│       • vsr_state (view, commit, etc.)                              │
│       • free_set_checksum                                           │
│       • client_sessions_checksum                                    │
│       • storage_size                                                │
│     - Superblock is written to multiple reserved sectors            │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  4. SUPERBLOCK FSYNC                                                │
│     - fsync() on superblock sectors                                 │
│     - Only after this is checkpoint durable                         │
│     - Journal can now truncate up to checkpoint_op                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Checkpoint Triggers
- Every `vsr_checkpoint_ops` operations (configurable)
- After compaction completes
- Before state sync to peer

### Recovery from Checkpoint
1. Read superblock, verify integrity
2. Load state machine from checkpoint_id
3. Replay journal from checkpoint_op + 1
4. Resume normal operation

### Superblock Format (src/vsr/superblock.zig)
```zig
SuperBlockHeader {
    checksum: u128,           // Self-integrity
    copy: u8,                 // Which copy (redundancy)
    version: u16,             // Format version
    cluster: u128,            // Cluster ID
    storage_size: u64,        // Total storage
    storage_size_max: u64,    // Max allowed
    sequence: u64,            // Monotonic counter
    checkpoint: Checkpoint,   // Current checkpoint state
    vsr_state: VSRState,      // Consensus state
}
```

## 6. Patterns to Reuse in ArcherDB

### Keep Verbatim
- **View change protocol**: Robust, well-tested
- **Quorum logic**: Safety-critical
- **Hash chain verification**: Integrity guarantee
- **Checkpoint coordination**: Complex, working
- **Repair mechanisms**: Journal, grid, state sync
- **Client session management**: Deduplication

### Modify for GeoEvent
- **State machine implementation**: Replace Account/Transfer with GeoEvent
- **Prefetch/commit logic**: Adapt for GeoEvent operations
- **Reply format**: GeoEvent query results

### New in ArcherDB
- **S2 spatial index integration**: In state machine
- **TTL expiration**: Background worker + commit integration
- **Radius queries**: New operation type

## 6. Key Invariants

1. **Op ordering**: `op` strictly increases, hash chain enforces order
2. **Commit safety**: Only commit after `quorum_replication` acks
3. **View monotonicity**: `view >= log_view >= view_durable`
4. **Checkpoint bounds**: Checkpoints every `vsr_checkpoint_ops`
5. **Primary uniqueness**: One primary per view (deterministic selection)

## 7. File Organization

```
src/vsr/
├── replica.zig          - Main consensus engine
├── replica_format.zig   - Superblock format
├── journal.zig          - WAL implementation
├── superblock.zig       - Durable state management
├── clock.zig            - Logical clocks
├── free_set.zig         - Block allocation
├── grid_scrubber.zig    - Background verification
├── message_header.zig   - Protocol messages
├── multi_batch.zig      - Request batching
└── routing.zig          - Message routing
```

## 8. VOPR Relevance (F4)

VOPR (Viewstamped Replication Protocol) testing uses deterministic simulation:

- **Fault injection**: Network partitions, crashes, message drops
- **Deterministic replay**: Same seed = same execution
- **State verification**: Check all replicas converge

For ArcherDB's GeoEvent state machine, we'll need:
- GeoEvent-specific operation generators
- S2 determinism validation
- TTL expiration testing under faults

## References

- TigerBeetle VSR Documentation: https://github.com/tigerbeetle/tigerbeetle
- Viewstamped Replication Revisited: https://pmg.csail.mit.edu/papers/vr-revisited.pdf
- ArcherDB Spec: `openspec/changes/add-geospatial-core/`
