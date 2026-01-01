# Hybrid Memory Architecture Specification

## ADDED Requirements

### Requirement: Aerospike-Style Index-on-RAM Architecture

The system SHALL implement a hybrid memory architecture where the primary index resides entirely in RAM while data records are stored on SSD, enabling O(1) lookups with minimal memory footprint.

#### Scenario: Architecture overview

- **WHEN** the system is configured
- **THEN** it SHALL maintain two tiers:
  - **RAM Tier**: Primary index mapping `entity_id -> record_location`
  - **SSD Tier**: Full 128-byte GeoEvent records in append-only log
- **AND** index lookups SHALL be pure RAM operations (no disk I/O)
- **AND** data retrieval SHALL require exactly one disk read

#### Scenario: Memory efficiency

- **WHEN** storing 1 billion entities
- **THEN** RAM usage calculation SHALL be:
  - Index entry size: 40 bytes (includes ttl_seconds field)
  - Target load factor: 0.70
  - Required capacity: 1B / 0.70 = ~1.43 billion slots
  - Base RAM usage: 1.43B × 40 bytes = ~57.2GB
  - **Recommended RAM: 80-96GB** (includes headroom for:)
    - Hash table performance degradation near capacity
    - Memory fragmentation overhead
    - Operating system buffers
    - Query result buffers (~1GB)
    - Grid cache (~4-16GB)
  - **Minimum RAM: 64GB** (for testing/development only, NOT production)
- **AND** SSD usage SHALL be approximately 128GB (1B entities × 128 bytes/event)
- **AND** this is ~2x more memory-efficient than storing full records in RAM (128GB vs 64GB)
- **WARNING**: 64GB is the absolute minimum for 1B entities. Production deployments should use 96GB+ to avoid performance degradation at high load factors.

### Requirement: Index Entry Structure

The system SHALL use a compact index entry format optimized for cache efficiency and LWW conflict resolution.

#### Scenario: Index entry fields

- **WHEN** an index entry is defined
- **THEN** it SHALL contain:
  ```
  IndexEntry (40 bytes):
  ├─ entity_id: u128      # Key: UUID of the entity
  ├─ file_offset: u64     # Value: Byte offset in data file
  ├─ timestamp: u64       # For LWW conflict resolution
  ├─ ttl_seconds: u32     # For expiration checking (0 = never expires)
  ├─ reserved: u32        # Padding to 8-byte boundary
  ```
- **AND** entries SHALL be 8-byte aligned for cache efficiency
- **AND** total size is 40 bytes (fits within a single 64-byte cache line on x86)

#### Scenario: Alternative compact entry

- **WHEN** memory is constrained
- **THEN** a 24-byte entry MAY be used:
  ```
  CompactIndexEntry (24 bytes):
  ├─ entity_id: u128      # Key: UUID of the entity
  ├─ file_offset: u48     # 256TB addressable (packed)
  ├─ timestamp_delta: u16 # Delta from base timestamp
  ```
- **AND** this reduces RAM usage to ~32GB for 1B entities

### Requirement: Primary Index Implementation

The system SHALL implement the primary index as a hash map optimized for concurrent read access.

#### Scenario: Hash map structure

- **WHEN** the index is initialized
- **THEN** it SHALL use open addressing with linear probing
- **AND** load factor SHALL be maintained below 0.7
- **AND** capacity SHALL be pre-allocated at startup (no runtime resize)

#### Scenario: Hash function

- **WHEN** hashing entity_id (u128)
- **THEN** the system SHALL use wyhash or xxhash3
- **AND** hash quality SHALL be verified for UUID distribution
- **AND** collision rate SHALL be monitored

#### Scenario: Capacity calculation

- **WHEN** calculating index capacity
- **THEN** `capacity = ceil(expected_entities / 0.7)`
- **AND** capacity SHALL be rounded to power of 2 for fast modulo
- **AND** this is calculated at compile time from configuration

#### Scenario: Memory layout

- **WHEN** laying out index memory
- **THEN** entries SHALL be stored in contiguous array
- **AND** array SHALL be page-aligned for huge page support
- **AND** NUMA-aware allocation SHOULD be used on multi-socket systems

### Requirement: Last-Write-Wins (LWW) Upsert

The system SHALL handle concurrent updates using Last-Write-Wins semantics based on timestamps.

#### Scenario: Upsert operation

- **WHEN** `upsert(entity_id, offset, timestamp, ttl_seconds)` is called
- **THEN** the system SHALL:
  1. Compute hash slot for entity_id
  2. If slot empty: insert new entry
  3. If slot occupied with same entity_id:
     - If `new_timestamp > existing_timestamp`: update offset, timestamp, and ttl_seconds
     - Else: ignore (existing record is newer)
  4. If slot occupied with different entity_id: probe next slot (linear probing)

### Requirement: Maximum Probe Length Limit

The system SHALL enforce a maximum probe length to prevent infinite loops and performance degradation.

#### Scenario: Probe length bound

- **WHEN** performing linear probing during lookup or insert
- **THEN** the system SHALL enforce `max_probe_length = 1024` slots
- **AND** if probe length exceeds this limit during lookup, return null (not found)
- **AND** if probe length exceeds this limit during insert, return error `index_degraded`
- **AND** `index_degraded` error SHALL trigger operational alert
- **AND** operator should rebuild index with larger capacity or better hash function

#### Scenario: Probe length monitoring

- **WHEN** tracking index performance
- **THEN** the system SHALL monitor:
  - `avg_probe_length: f32` - Average probes per operation
  - `max_probe_length_seen: u32` - Maximum probes encountered
  - `probe_limit_hits: u64` - Count of operations that hit the 1024 limit
- **AND** if `avg_probe_length > 10`, log warning (hash function degrading)
- **AND** if `probe_limit_hits > 0`, log critical alert (index needs rebuild)

#### Scenario: Out-of-order handling

- **WHEN** GPS packets arrive out of order
- **THEN** older packets SHALL be written to disk (for history)
- **AND** RAM index SHALL NOT be updated (keeps latest)
- **AND** this preserves full history while serving latest location

#### Scenario: Deterministic conflict resolution

- **WHEN** timestamps are equal (rare)
- **THEN** the record with higher composite ID SHALL win
- **AND** this ensures all replicas converge to same state

### Requirement: Index Checkpointing

The system SHALL periodically checkpoint the RAM index to disk for crash recovery. This is SEPARATE from VSR checkpoints.

**IMPORTANT:** There are TWO checkpoint mechanisms that must be coordinated:
1. **VSR Checkpoint** (storage-engine) - Every 256 operations, persists LSM state + superblock
2. **Index Checkpoint** (hybrid-memory) - Every 60 seconds, persists RAM index to disk

#### Scenario: Checkpoint coordination

- **WHEN** index checkpoint is written
- **THEN** it SHALL record correlation with VSR checkpoint:
  - `vsr_checkpoint_op: u64` - The VSR checkpoint op number at index checkpoint time
  - `vsr_commit_max: u64` - The commit_max at index checkpoint time
- **AND** on recovery, the system SHALL:
  1. Load VSR checkpoint first (authoritative state)
  2. Load index checkpoint
  3. If `index.vsr_checkpoint_op > vsr.checkpoint_op`:
     - Index is AHEAD of VSR state (VSR checkpoint was lost/corrupted)
     - Discard index checkpoint, rebuild from data file
  4. If `index.vsr_checkpoint_op <= vsr.checkpoint_op`:
     - Index is valid, replay WAL from `index.wal_position` to current
- **AND** this ensures index never references data that VSR hasn't persisted

#### Scenario: Index checkpoint trigger (time-based)

- **WHEN** index checkpointing is triggered
- **THEN** it SHALL occur:
  - Every 60 seconds (time-based, NOT operation-based)
  - During graceful shutdown
  - On explicit admin command
- **AND** checkpointing SHALL NOT block normal operations
- **AND** this is INDEPENDENT of VSR checkpoint timing (every 256 ops)

#### Scenario: Non-blocking checkpoint mechanism

- **WHEN** index checkpoint runs concurrently with operations
- **THEN** the system SHALL use a snapshot-based approach:
  1. **Snapshot phase** (< 1ms): Atomically capture index metadata (entry count, high-water timestamp, WAL position)
  2. **Scan phase** (milliseconds to seconds): Iterate through index entries sequentially
  3. **Write phase**: Write captured entries to temp file, call `fsync()` on temp file
  4. **Finalize phase**: Atomic rename temp file to final location, `fsync()` parent directory
- **AND** fsync ensures data is durable before rename makes checkpoint visible
- **AND** WAL position is captured at snapshot phase start (conservative - ensures no data loss)
- **AND** concurrent lookups continue normally during all phases
- **AND** concurrent upserts continue normally:
  - Entries modified AFTER snapshot may appear in checkpoint (acceptable - LWW ensures correctness)
  - Entries modified AFTER snapshot may NOT appear (acceptable - WAL replay covers them)
  - No locking required - eventual consistency within checkpoint interval
- **AND** this is safe because:
  - WAL position recorded at snapshot time ensures replay covers any missed entries
  - Checkpoint is a "best effort" snapshot, not a transaction boundary
  - Recovery always replays WAL from checkpoint position forward

#### Scenario: Checkpoint duration SLA

- **WHEN** checkpoint runs on a 1B entity index (~57GB)
- **THEN** duration SHALL be bounded by sequential write speed:
  ```
  checkpoint_duration = index_size / disk_write_speed
  Example: 57GB / 3GB/s = ~19 seconds
  ```
- **AND** checkpoint runs in background (does not block operations)
- **AND** if checkpoint takes longer than interval (60s), next checkpoint is skipped
- **AND** log warning: "Checkpoint taking longer than interval - consider faster disk"

#### Scenario: Checkpoint format

- **WHEN** writing a checkpoint
- **THEN** the format SHALL be:
  ```
  IndexCheckpoint:
  ├─ header (256 bytes):
  │   ├─ magic: u32               # 0x41524348 ("ARCH")
  │   ├─ version: u16
  │   ├─ entry_count: u64
  │   ├─ timestamp_high_water: u64
  │   ├─ wal_position: u64        # Position in WAL at checkpoint time
  │   ├─ vsr_checkpoint_op: u64   # VSR checkpoint op for coordination
  │   ├─ vsr_commit_max: u64      # VSR commit_max for validation
  │   ├─ header_checksum: u128    # Aegis-128L of header (after this field)
  │   ├─ body_checksum: u128      # Aegis-128L of all entries
  │   └─ padding
  └─ entries (N x 40 bytes):      # IndexEntry is 40 bytes
      ├─ IndexEntry[0]
      ├─ IndexEntry[1]
      └─ ...

  On checkpoint load:
  1. Verify header_checksum
  2. Verify body_checksum covers all entries
  3. If either fails: log error, trigger full index rebuild from WAL
  ```

#### Scenario: Checkpoint atomicity

- **WHEN** writing checkpoint to disk
- **THEN** it SHALL be written to a temporary file first
- **AND** then atomically renamed to final location
- **AND** previous checkpoint SHALL be kept until new one is verified
- **AND** this ensures crash-safe checkpoint updates

#### Scenario: Incremental checkpoint

- **WHEN** full checkpoint is too expensive
- **THEN** incremental checkpoints MAY be used:
  - Track dirty entries since last checkpoint
  - Write only changed entries with position markers
  - Merge incrementals during recovery
- **AND** this reduces checkpoint I/O for large indexes

### Requirement: Cold Start Index Rebuild

The system SHALL rebuild the RAM index from the data log on cold start if checkpoint is missing or corrupt.

#### Scenario: Rebuild trigger

- **WHEN** the system starts
- **THEN** it SHALL:
  1. Attempt to load latest valid checkpoint
  2. If checkpoint valid: load and replay WAL from checkpoint position
  3. If checkpoint missing/corrupt: full rebuild from data log

#### Scenario: Full rebuild process

- **WHEN** performing full index rebuild
- **THEN** the system SHALL:
  1. Scan data log sequentially from beginning
  2. For each GeoEvent: `upsert(entity_id, offset, timestamp)`
  3. LWW ensures only latest location per entity is indexed
  4. Log progress every 1M records
- **AND** rebuild SHALL use sequential I/O for maximum throughput

#### Scenario: Rebuild performance with SLA

- **WHEN** rebuilding from 128GB data file (1B entities)
- **THEN** rebuild time SHALL be bounded by disk sequential read speed
- **AND** at 3GB/s NVMe speed, rebuild takes ~45 seconds
- **AND** this is acceptable for cold start scenarios

#### Scenario: Large data file rebuild SLA

- **WHEN** rebuilding from 16TB data file (maximum capacity)
- **THEN** cold start without valid checkpoint SHALL take:
  - Sequential read time: 16TB / 3GB/s = ~5,333 seconds = ~89 minutes
  - Index insertion overhead: ~20-30 minutes
  - **Total: ~2 hours for complete cold start**
- **AND** this is the WORST CASE (checkpoint corrupted)
- **AND** normal cold start with valid checkpoint: < 5 minutes (checkpoint + partial WAL replay)
- **AND** operators should monitor checkpoint integrity to avoid 2-hour cold starts

#### Scenario: Partial replay

- **WHEN** checkpoint is valid but stale
- **THEN** the system SHALL:
  1. Load checkpoint into RAM
  2. Seek to `wal_position` in data log
  3. Replay only records after checkpoint
- **AND** this minimizes cold start time

### Requirement: Index Memory Management

The system SHALL manage index memory according to static allocation discipline.

#### Scenario: Pre-allocation

- **WHEN** the index is initialized
- **THEN** all memory SHALL be allocated upfront
- **AND** `index_memory = capacity * sizeof(IndexEntry)`
- **AND** this memory is part of StaticAllocator's init phase

#### Scenario: No runtime growth

- **WHEN** index reaches capacity
- **THEN** the system SHALL reject new entities
- **AND** error `index_capacity_exceeded` SHALL be returned
- **AND** capacity MUST be configured appropriately at startup

#### Scenario: Memory reclamation

- **WHEN** an entity is deleted (if supported)
- **THEN** index slot SHALL be marked as tombstone
- **AND** tombstones SHALL be reclaimed during compaction
- **AND** slot can be reused for new entities

### Requirement: Index Sharding (Future Scale-Out)

The system SHALL support optional index sharding for distributed deployments.

#### Scenario: Shard key

- **WHEN** sharding is enabled
- **THEN** `shard_id = hash(entity_id) % shard_count`
- **AND** each shard is an independent index instance
- **AND** queries route to appropriate shard

#### Scenario: Single-node sharding

- **WHEN** running on single node with multiple cores
- **THEN** sharding reduces lock contention
- **AND** each shard can be pinned to a CPU core
- **AND** this improves concurrent lookup throughput

#### Scenario: Multi-node sharding

- **WHEN** scaling beyond single node
- **THEN** shards can be distributed across nodes
- **AND** each node owns a subset of shards
- **AND** VSR replication applies per-shard

### Requirement: Secondary Index Support

The system SHALL support optional secondary indexes for non-primary-key lookups.

#### Scenario: Spatial secondary index

- **WHEN** spatial queries are frequent
- **THEN** an S2 cell -> entity_id mapping MAY be maintained
- **AND** this is stored in Grid zone (not RAM)
- **AND** enables efficient "find all entities in cell" queries

#### Scenario: Time-based secondary index

- **WHEN** time-range queries on specific entities are needed
- **THEN** an entity_id -> [timestamps] mapping MAY be maintained
- **AND** this enables "history of entity X" queries
- **AND** stored in Grid zone with LSM structure

#### Scenario: Secondary index consistency

- **WHEN** secondary indexes are maintained
- **THEN** they SHALL be updated atomically with primary index
- **AND** this occurs during commit phase (after consensus)
- **AND** crash recovery rebuilds secondary indexes from primary data

### Requirement: Index Statistics and Monitoring

The system SHALL track index statistics for monitoring and capacity planning.

#### Scenario: Basic statistics

- **WHEN** statistics are queried
- **THEN** the system SHALL report:
  - `entry_count: u64` - Current number of indexed entities
  - `capacity: u64` - Maximum entries
  - `load_factor: f32` - entry_count / capacity
  - `memory_bytes: u64` - RAM used by index

#### Scenario: Performance statistics

- **WHEN** performance stats are queried
- **THEN** the system SHALL report:
  - `lookup_count: u64` - Total lookups
  - `lookup_hit_count: u64` - Successful lookups
  - `upsert_count: u64` - Total upserts
  - `collision_count: u64` - Hash collisions encountered
  - `avg_probe_length: f32` - Average probes per lookup

#### Scenario: Checkpoint statistics

- **WHEN** checkpoint stats are queried
- **THEN** the system SHALL report:
  - `last_checkpoint_time: u64` - Timestamp of last checkpoint
  - `last_checkpoint_entries: u64` - Entries in last checkpoint
  - `checkpoint_duration_ns: u64` - Time taken for last checkpoint
  - `wal_position: u64` - WAL position at last checkpoint

### Requirement: Hot-Warm-Cold Data Tiering (Future)

The system MAY support tiered storage for cost optimization at extreme scale.

#### Scenario: Tier definitions

- **WHEN** tiering is enabled
- **THEN** tiers SHALL be:
  - **Hot**: RAM index + NVMe SSD (recent/active entities)
  - **Warm**: RAM index + SATA SSD (less active entities)
  - **Cold**: No RAM index, disk-only (archived entities)

#### Scenario: Tier promotion/demotion

- **WHEN** access patterns change
- **THEN** entities MAY be promoted/demoted between tiers
- **AND** promotion: load into RAM index on access
- **AND** demotion: evict from RAM index after inactivity timeout

#### Scenario: Cold tier queries

- **WHEN** querying cold tier entities
- **THEN** a full scan or secondary index lookup is required
- **AND** latency is higher (acceptable for historical queries)
- **AND** this enables cost-effective long-term retention

### Requirement: Entity and Capacity Limits

The system SHALL enforce hard limits on entity counts and storage capacity.

#### Scenario: Maximum entities per node

- **WHEN** configuring the system
- **THEN** the maximum SHALL be 1 billion entities per node
- **AND** this is limited by RAM index capacity (~64GB at 40 bytes/entry with TTL field)
- **AND** exceeding this requires scaling to multiple nodes or sharding

#### Scenario: Index capacity calculation

- **WHEN** calculating index capacity
- **THEN** the formula SHALL be:
  ```
  capacity = (max_entities / load_factor_target)
  where load_factor_target = 0.70

  Example for 1B entities:
  capacity = 1,000,000,000 / 0.70 = ~1,428,571,428 slots
  memory = 1,428,571,428 × 40 bytes = ~57.2GB (rounded to 64GB for safety)
  ```
- **AND** IndexEntry is EXACTLY 40 bytes (see Index Entry Structure requirement above)

#### Scenario: Data file size limit

- **WHEN** storing events on disk
- **THEN** the maximum data file size SHALL be 16TB
- **AND** this is limited by u64 offset addressing
- **AND** at 128 bytes/event, this allows ~137 billion events
- **AND** with 1B entities and LWW semantics, this allows ~137 updates per entity on average

#### Scenario: Cluster-wide capacity

- **WHEN** calculating total cluster capacity
- **THEN** maximum entities SHALL be `node_count × 1_billion`
- **AND** for a 5-node cluster: 5 billion entities tracked
- **AND** each node maintains independent index (no cross-node lookups)

#### Scenario: Capacity exhaustion handling

- **WHEN** index capacity is exhausted
- **THEN** the system SHALL:
  - Reject new entity inserts with error `index_capacity_exceeded`
  - Continue accepting updates to existing entities (upserts)
  - Log warning when load factor exceeds 0.80
  - Log critical alert when load factor exceeds 0.90

#### Scenario: Capacity planning

- **WHEN** planning deployment capacity
- **THEN** operators SHALL:
  - Configure `max_entities` at format time based on expected scale
  - Pre-allocate index memory: `max_entities / 0.70 × 40 bytes` (IndexEntry is 40 bytes with TTL)
  - Reserve disk space: `expected_total_events × 128 bytes`
  - Plan for ~10-20% overhead for superblock, WAL, LSM metadata

### Requirement: Hardware Requirements

The system SHALL specify minimum and recommended hardware for meeting performance SLAs.

#### Scenario: Minimum hardware

- **WHEN** deploying for development or small-scale production
- **THEN** minimum hardware SHALL be:
  - **CPU:** 8 cores, x86-64 with AES-NI
  - **RAM:** 32GB (supports ~500M entities)
  - **Disk:** 500GB NVMe SSD (>2GB/s sequential, <200μs latency)
  - **Network:** 1Gbps

#### Scenario: Recommended hardware (1B entities)

- **WHEN** deploying for 1 billion entity scale
- **THEN** recommended hardware SHALL be:
  - **CPU:** 16+ cores, x86-64 with AES-NI (AVX2 preferred)
  - **RAM:** 64-128GB (48GB for index + 16-80GB for caching)
  - **Disk:** 1TB+ NVMe SSD (>3GB/s sequential, <100μs latency)
  - **Network:** 10Gbps between replicas (same region)

#### Scenario: High-performance hardware

- **WHEN** targeting maximum throughput (1M+ events/sec)
- **THEN** high-performance hardware SHALL be:
  - **CPU:** 32+ cores, latest x86-64 (Intel Sapphire Rapids or AMD Zen 4)
  - **RAM:** 128-256GB (ECC recommended)
  - **Disk:** 2TB+ NVMe Gen4/Gen5 (>5GB/s, Optane or high-endurance)
  - **Network:** 25-100Gbps (for cross-region replication)
