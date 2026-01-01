# Hybrid Memory Architecture Specification

## ADDED Requirements

### Requirement: Aerospike-Style Index-on-RAM Architecture

The system SHALL implement a hybrid memory architecture where the primary index resides entirely in RAM while data records are stored on SSD, enabling O(1) lookups with minimal memory footprint.

#### Scenario: Architecture overview

- **WHEN** the system is configured
- **THEN** it SHALL maintain two tiers:
  - **RAM Tier**: Primary index mapping `entity_id -> latest GeoEvent ID (u128)`
  - **SSD Tier**: Full 128-byte GeoEvent records stored in the storage engine (LSM/Grid)
- **AND** index lookups SHALL be pure RAM operations (no disk I/O)
- **AND** data retrieval SHALL be performed by composite-ID lookup in the storage engine
- **AND** lookup performance SHOULD be optimized via block cache and prefetch (see storage-engine + query-engine)

#### Scenario: Memory efficiency

- **WHEN** storing 1 billion entities
- **THEN** RAM usage calculation SHALL be:
  - Index entry size: 64 bytes (Cache Line Aligned)
  - Target load factor: 0.70
  - Required capacity: 1B / 0.70 = ~1.43 billion slots
  - Base RAM usage: 1.43B × 64 bytes = ~91.5GB
  - **Recommended RAM: 128GB** (includes headroom for:)
    - Hash table performance degradation near capacity
    - Memory fragmentation overhead
    - Operating system buffers
    - Query result buffers (~1GB)
    - Grid cache (~4-16GB)
 - **Minimum RAM: 96GB** (for testing/development only, NOT production)
- **AND** SSD usage for "latest value only" is approximately 128GB (1B entities × 128 bytes/event)
- **AND** historical retention multiplies SSD usage by updates-per-entity (see ttl-retention)
- **AND** this maintains O(1) cache line access (1 line fetch per probe) unlike 40-byte entries which cause 62.5% split-loads
- **WARNING**: 128GB is the recommended RAM for 1B entities to ensure consistent latency.

### Requirement: Index Entry Structure

The system SHALL use a 64-byte aligned index entry format optimized for CPU cache efficiency and SIMD operations.

#### Scenario: Index entry fields

- **WHEN** an index entry is defined
- **THEN** it SHALL contain:
  ```
  IndexEntry (64 bytes - 1 Cache Line):
  ├─ entity_id: u128      # 16 bytes (Key)
  ├─ latest_id: u128      # 16 bytes (Value: Composite ID)
  ├─ ttl_seconds: u32     # 4 bytes
  ├─ reserved: u32        # 4 bytes (Padding)
  ├─ padding: [24]u8      # 24 bytes (Reserved for flags/tags/generations)
  ```
- **AND** entries SHALL be 64-byte aligned
- **AND** this ensures `entry[i]` never straddles two cache lines
- **AND** allows for future extensions (tags, secondary IDs, dirty bits) without breaking alignment

#### Scenario: Alternative compact entry (deferred)

- **WHEN** memory is constrained
- **THEN** a compact entry format MAY be designed in a future version
- **AND** v1 uses the fixed 64-byte IndexEntry for performance determinism

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
- **AND** capacity is NOT required to be power of 2 (wyhash provides good distribution)
- **AND** if power-of-2 is preferred for fast modulo, use next power of 2:
  - 1B entities / 0.7 = 1.43B slots → round up to 2^31 = 2.147B slots
  - Memory increases from 91.5GB to 137GB
  - Effective load factor decreases from 0.7 to 0.47
- **AND** this is calculated at compile time from configuration
- **RECOMMENDATION**: Use exact capacity (1.43B) for memory efficiency; modern CPUs handle
  non-power-of-2 modulo efficiently via compiler optimization (multiply by reciprocal)

#### Scenario: Memory layout and Huge Pages

- **WHEN** laying out index memory
- **THEN** entries SHALL be stored in contiguous array
- **AND** array SHALL be page-aligned for huge page support
- **AND** system MUST use Huge Pages (Transparent Huge Pages or Explicit) for the primary index
- **AND** this reduces TLB misses for random access in the 90GB+ index structure
- **AND** NUMA-aware allocation SHOULD be used on multi-socket systems

### Requirement: Last-Write-Wins (LWW) Upsert

The system SHALL handle concurrent updates using Last-Write-Wins semantics based on timestamps.

#### Scenario: Upsert operation

- **WHEN** `upsert(entity_id, latest_id, ttl_seconds)` is called
- **THEN** the system SHALL:
  1. Compute hash slot for entity_id
  2. If slot empty: insert new entry
  3. If slot occupied with same entity_id:
     - Compute timestamps from IDs:
       - `new_timestamp = @as(u64, @truncate(latest_id))`
       - `existing_timestamp = @as(u64, @truncate(existing.latest_id))`
     - If `new_timestamp > existing_timestamp`: update latest_id and ttl_seconds
     - If `new_timestamp < existing_timestamp`: ignore (existing record is newer)
     - If timestamps equal: the entry with higher `latest_id` wins (deterministic tie-break)
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

The system SHALL periodically checkpoint the RAM index to disk using an incremental dirty-page strategy to avoid I/O saturation.

**IMPORTANT:** There are TWO checkpoint mechanisms that must be coordinated:
1. **VSR Checkpoint** (storage-engine) - Every 256 operations, persists LSM state + superblock
2. **Index Checkpoint** (hybrid-memory) - Continuous background process, persists RAM index to disk

#### Scenario: Incremental checkpointing via dirty tracking

- **WHEN** the index is modified
- **THEN** the system SHALL track dirty pages:
  - Divide index into fixed-size pages (e.g., 64KB or 1MB)
  - Maintain a `dirty_pages: DynamicBitSet`
  - Mark page dirty on upsert/delete
- **AND** a background task SHALL continuously flush dirty pages to disk:
  - Scan bitset for dirty pages
  - Write dirty pages to the index checkpoint file
  - Clear dirty bits after write confirms
  - Update checkpoint metadata (max_op, commit_max) atomically
- **AND** this "trickle" checkpointing prevents massive I/O spikes (writing 90GB+ at once)
- **AND** typical churn (1M ops/sec = ~0.1% index change/sec) fits easily within disk bandwidth

#### Scenario: Checkpoint coordination

- **WHEN** index checkpoint metadata is updated
- **THEN** it SHALL record correlation with VSR checkpoint:
  - `vsr_checkpoint_op: u64` - The VSR checkpoint op number at index checkpoint time
  - `vsr_commit_max: u64` - The commit_max at index checkpoint time
- **AND** on recovery, the system SHALL:
  1. Load VSR checkpoint first (authoritative state)
  2. Load index checkpoint
  3. **Replay Strategy**:
     - If `index.vsr_checkpoint_op` is close to `vsr.checkpoint_op` (within WAL retention):
       - Replay VSR prepares from `index.vsr_checkpoint_op + 1` from the **WAL** (Journal)
     - If WAL has wrapped (gap > 80s):
       - Replay from **LSM** (Data File) if possible (slower) OR
       - Trigger full index rebuild
- **AND** increasing `journal_slot_count` to 8192 ensures WAL covers the 60s checkpoint interval

#### Scenario: Checkpoint duration SLA

- **WHEN** running incremental checkpoint
- **THEN** it SHALL NOT block operations
- **AND** it SHALL keep up with write rate
- **AND** assuming 1M writes/sec (64MB/sec index churn):
  - Disk write rate required: >64MB/s (trivial for NVMe)
  - Write amplification is low (only dirty pages written)

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
  │   ├─ vsr_checkpoint_op: u64   # VSR checkpoint op for coordination
  │   ├─ vsr_commit_max: u64      # VSR commit_max for validation
  │   ├─ header_checksum: u128    # Aegis-128L of header (after this field)
  │   ├─ body_checksum: u128      # Aegis-128L of all entries (merkle root or similar)
  │   └─ padding
  └─ pages (Sparse/Incremental):
      ├─ Page[0] (64KB)
      ├─ ...
  ```

### Requirement: Cold Start Index Rebuild

The system SHALL rebuild the RAM index from persisted GeoEvents on cold start if checkpoint is missing or corrupt.

#### Scenario: Rebuild trigger

- **WHEN** the system starts
- **THEN** it SHALL:
  1. Attempt to load latest valid checkpoint
  2. If checkpoint valid: load and replay VSR prepares from `index.vsr_checkpoint_op` from WAL
  3. If WAL missing required ops (gap > WAL retention): attempt scan from LSM
  4. If all else fails: full rebuild by scanning persisted GeoEvents

#### Scenario: Full rebuild process

- **WHEN** performing full index rebuild
- **THEN** the system SHALL:
  1. Use **LSM-Aware Rebuild** strategy (Newest-to-Oldest):
     - Iterate LSM levels from L0 (newest) to L_max (oldest).
     - Maintain a temporary `seen_entities` bitset/filter (approx 128MB for 1B entities).
  2. For each GeoEvent encountered:
     - If `entity_id` is already in `seen_entities`: Skip (we already have the latest version).
     - If `event.flags.deleted = true`: Mark in `seen_entities` (entity is deleted), do NOT insert.
     - Else: Insert into RAM index (`upsert`), Mark in `seen_entities`.
  3. This ensures tombstones correctly hide older versions without requiring deletions from the index.
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
- **AND** tombstones SHALL be reclaimed during index maintenance (rehash/rebuild), not LSM compaction
- **AND** slot can be reused for new entities

### Requirement: Index Sharding (Internal Concurrency)

The system SHALL support logical index sharding to reduce cache contention and enable parallel maintenance.

#### Scenario: Internal sharding
- **WHEN** initializing the primary index
- **THEN** it SHALL be partitioned into `shard_count` logical shards (e.g., 256)
- **AND** `shard_id = hash(entity_id) % shard_count`
- **AND** each shard maintains its own lock (if multi-threaded) or simply logical separation
- **AND** this reduces cache line contention during high-throughput upserts
- **AND** it enables parallel processing for background tasks (e.g., checkpoint scanning)

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
  - `vsr_checkpoint_op: u64` - VSR checkpoint op recorded in index checkpoint
  - `vsr_commit_max: u64` - VSR commit_max recorded in index checkpoint

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
- **AND** this is limited by RAM index capacity (~91.5GB at 64 bytes/entry with 0.7 load factor)
- **AND** exceeding this requires scaling to multiple nodes or sharding

#### Scenario: Index capacity calculation

- **WHEN** calculating index capacity
- **THEN** the formula SHALL be:
  ```
  capacity = (max_entities / load_factor_target)
  where load_factor_target = 0.70

  Example for 1B entities:
  capacity = 1,000,000,000 / 0.70 = ~1,428,571,428 slots
  memory = 1,428,571,428 × 64 bytes = ~91.5GB (rounded to 96GB/128GB)
  ```
- **AND** IndexEntry is EXACTLY 64 bytes (see Index Entry Structure requirement above)

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
  - Pre-allocate index memory: `max_entities / 0.70 × 64 bytes` (IndexEntry is 64 bytes with padding)
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
  - **RAM:** 128GB (96GB for index + 32GB for caching/OS)
  - **Disk:** 1TB+ NVMe SSD (>3GB/s sequential, <100μs latency)
  - **Network:** 10Gbps between replicas (same region)

#### Scenario: High-performance hardware

- **WHEN** targeting maximum throughput (1M+ events/sec)
- **THEN** high-performance hardware SHALL be:
  - **CPU:** 32+ cores, latest x86-64 (Intel Sapphire Rapids or AMD Zen 4)
  - **RAM:** 256GB (ECC recommended)
  - **Disk:** 2TB+ NVMe Gen4/Gen5 (>5GB/s, Optane or high-endurance)
  - **Network:** 25-100Gbps (for cross-region replication)
