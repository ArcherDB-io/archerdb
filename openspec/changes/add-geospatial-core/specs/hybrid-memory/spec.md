# Hybrid Memory Architecture Specification

## ADDED Requirements

### Requirement: IndexEntry Size and Alignment

The system SHALL ensure the in-memory index entry layout matches the declared constants to prevent accidental layout drift and performance regressions.

#### Scenario: IndexEntry size validation

- **WHEN** `IndexEntry` is compiled
- **THEN** `@sizeOf(IndexEntry)` MUST equal `constants.index_entry_size` (64 bytes)
- **AND** `@alignOf(IndexEntry)` MUST be at least 16 bytes (for u128 alignment)
- **AND** the verification MUST live in the index module (to avoid import cycles in `src/constants.zig`)

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
- **AND** operator SHALL rebuild index with larger capacity or better hash function

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
- **AND** operators SHALL monitor checkpoint integrity to avoid 2-hour cold starts

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
- **AND** capacity MUST be configured using `capacity = ceil(expected_entities / 0.7)` at startup (as specified in Capacity calculation scenario above)
- **AND** operators SHALL provision for peak entity count, not average count

#### Scenario: Memory reclamation

- **WHEN** an entity is deleted (if supported)
- **THEN** index slot SHALL be marked as tombstone
- **AND** tombstones SHALL be reclaimed during index maintenance (rehash/rebuild), not LSM compaction
- **AND** slot can be reused for new entities

### Requirement: Index Sharding (Internal Concurrency)

The system SHALL support logical index sharding to reduce cache contention and enable parallel maintenance.

#### Scenario: Internal sharding
- **WHEN** initializing the primary index
- **THEN** it SHALL be partitioned into `shard_count` logical shards (default: 256)
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

#### Scenario: Tombstone statistics (if delete supported)

- **WHEN** tombstone stats are queried
- **THEN** the system SHALL report:
  - `tombstone_count: u64` - Current number of tombstones in index
  - `tombstone_ratio: f32` - tombstone_count / (entry_count + tombstone_count)
- **AND** metrics SHALL be exposed:
  ```
  # Number of tombstone slots in the index
  archerdb_index_tombstone_count gauge

  # Ratio of tombstones to total slots (0.0-1.0)
  archerdb_index_tombstone_ratio gauge
  ```
- **AND** alert thresholds SHALL be:
  - `tombstone_ratio > 0.1`: Warning - consider scheduling maintenance
  - `tombstone_ratio > 0.3`: Critical - index degradation, maintenance required
- **AND** high tombstone ratio indicates:
  - Increased probe lengths during lookup
  - Wasted memory (tombstones occupy slots)
  - Need for index rebuild/rehash

#### Scenario: Index maintenance trigger (tombstone cleanup)

- **WHEN** tombstone_ratio exceeds 0.3
- **THEN** the operator SHALL schedule index maintenance:
  1. During low-traffic window (recommended)
  2. Rolling restart of replicas (one at a time)
  3. Each replica rebuilds index on restart (tombstones reclaimed)
- **AND** the system does NOT automatically trigger maintenance in v1
- **AND** future versions MAY support online index rehash

#### Scenario: Checkpoint statistics

- **WHEN** checkpoint stats are queried
- **THEN** the system SHALL report:
  - `last_checkpoint_time: u64` - Timestamp of last checkpoint
  - `last_checkpoint_entries: u64` - Entries in last checkpoint
  - `checkpoint_duration_ns: u64` - Time taken for last checkpoint
  - `vsr_checkpoint_op: u64` - VSR checkpoint op recorded in index checkpoint
  - `vsr_commit_max: u64` - VSR commit_max recorded in index checkpoint

### Requirement: Hot-Warm-Cold Data Tiering (Future)

The system SHALL support tiered storage for cost optimization at extreme scale.

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

### Requirement: Thread-Safety and Concurrency Model

The system SHALL support concurrent read access with lock-free algorithms and explicit memory ordering guarantees.

#### Scenario: Index concurrency model

- **WHEN** multiple threads access the index
- **THEN** the system SHALL support:
  - **Multiple concurrent readers** (lookups)
  - **Single writer at a time** (upserts managed by VSR commit phase)
  - **Read-during-write safety** (readers see consistent snapshots)
- **AND** this model is based on VSR's single-threaded commit phase execution
- **AND** lookup operations from query prefetch phase are concurrent (across different VSR operations in pipeline)

#### Scenario: Atomic lookup operations

- **WHEN** `lookup(entity_id)` is called concurrently from multiple threads
- **THEN** the lookup SHALL:
  - Use atomic loads with `@atomicLoad(.Acquire)` semantics
  - Read the `IndexEntry` as a complete atomic unit (compiler guarantees 64-byte aligned reads)
  - Never observe torn writes (partial entity_id, partial latest_id)
  - Complete without blocking other lookups
- **AND** Zig's `@atomicLoad` ensures:
  - Memory ordering: Acquire semantics (reads after acquire see writes before release)
  - Atomicity: 64-byte aligned reads are atomic on x86-64 (within cache line)
- **AND** implementation SHALL use:
  ```zig
  const entry = @atomicLoad(*IndexEntry, entry_ptr, .Acquire);
  ```

#### Scenario: Atomic upsert operations

- **WHEN** `upsert(entity_id, latest_id, ttl_seconds)` is called
- **THEN** the upsert SHALL:
  - Be serialized through VSR commit phase (single-threaded state machine execution)
  - Use atomic stores with `@atomicStore(.Release)` semantics after modification
  - Use compare-and-swap (CAS) for conditional updates (LWW timestamp check)
  - Ensure memory ordering: Release semantics (writes before release visible after acquire)
- **AND** implementation SHALL use:
  ```zig
  // Inside VSR commit phase (single-threaded):
  if (new_timestamp > existing.timestamp) {
      var new_entry = IndexEntry{
          .entity_id = entity_id,
          .latest_id = latest_id,
          .ttl_seconds = ttl_seconds,
          // ...
      };
      @atomicStore(*IndexEntry, entry_ptr, new_entry, .Release);
  }
  ```

#### Scenario: Memory ordering guarantees

- **WHEN** an upsert completes on one thread
- **AND** a lookup executes on a different thread
- **THEN** the memory ordering guarantee SHALL be:
  - **Write (upsert):** `.Release` fence ensures all writes visible
  - **Read (lookup):** `.Acquire` fence ensures all writes before release are seen
  - **Visibility:** If lookup observes updated `entity_id`, it MUST observe updated `latest_id`
- **AND** this prevents:
  - Reordering of `entity_id` and `latest_id` writes
  - Torn reads (partial updates)
  - Stale reads after writes

#### Scenario: Cache coherence protocol

- **WHEN** multiple CPU cores access index entries
- **THEN** the system SHALL rely on x86-64 cache coherence (MESI protocol):
  - **Modified:** Core has exclusive write access, cache line dirty
  - **Exclusive:** Core has exclusive access, cache line clean
  - **Shared:** Multiple cores have read-only access
  - **Invalid:** Cache line is stale, must be reloaded
- **AND** 64-byte cache line alignment ensures:
  - Each `IndexEntry` is self-contained within one cache line
  - No false sharing between adjacent entries
  - Atomic cache line reads/writes

#### Scenario: False sharing prevention

- **WHEN** multiple threads update adjacent index entries
- **THEN** false sharing SHALL be prevented by:
  - 64-byte `IndexEntry` size matches cache line size
  - Entries are 64-byte aligned (@alignOf(IndexEntry) = 64)
  - No two entries share a cache line
- **AND** this ensures:
  - Updates to entry[i] do not invalidate cache line for entry[i+1]
  - Concurrent lookups on different entities do not cause cache thrashing

#### Scenario: Lock-free hash map traversal

- **WHEN** performing linear probing during lookup
- **THEN** the traversal SHALL be lock-free:
  - No mutexes or spinlocks acquired
  - Uses only atomic loads (@atomicLoad)
  - Bounded by `max_probe_length = 1024`
  - Can proceed concurrently with other lookups
- **AND** if entry is being updated during probe:
  - Lookup sees either old or new value (both valid)
  - No intermediate/torn state visible
  - LWW semantics ensure consistency

#### Scenario: Concurrent lookup performance

- **WHEN** N threads perform concurrent lookups
- **THEN** the system SHALL achieve:
  - Linear scalability up to N=16 threads (core count dependent)
  - No lock contention (lock-free reads)
  - Cache line bouncing only on actual conflicts (same entity_id)
  - Throughput: ~10M lookups/sec per 8-core node (assuming 64-byte entries, cache-resident)

#### Scenario: Read-during-write consistency

- **WHEN** a lookup executes while an upsert is in progress
- **THEN** the lookup SHALL observe:
  - Either the complete old entry (before upsert)
  - Or the complete new entry (after upsert)
  - Never a partially updated entry (torn read)
- **AND** this is guaranteed by:
  - Atomic 64-byte loads (@atomicLoad)
  - Release/Acquire memory ordering
  - x86-64 cache coherence

#### Scenario: Thundering herd prevention

- **WHEN** many threads lookup the same entity_id concurrently
- **THEN** the system SHALL:
  - Allow all lookups to proceed in parallel (no serialization)
  - Each lookup independently hashes and probes
  - Cache line sharing is acceptable (read-only access)
  - No thread blocks waiting for others

#### Scenario: ABA problem prevention

- **WHEN** using compare-and-swap (CAS) for upserts
- **THEN** the system SHALL prevent ABA problem by:
  - CAS is only used within single-threaded VSR commit phase
  - No concurrent CAS on same entry from multiple threads
  - Timestamp monotonicity provides natural version counter
- **AND** ABA cannot occur because:
  - Only one thread (VSR commit) modifies index
  - Readers never modify, so A→B→A transition impossible

#### Scenario: Consistency under crash

- **WHEN** the system crashes during index modification
- **THEN** consistency SHALL be maintained by:
  - Index checkpoint is independent of data file
  - VSR WAL (journal) is authoritative
  - On recovery: load checkpoint + replay WAL
  - Replayed operations are deterministic (same result)
- **AND** torn writes to index are acceptable:
  - WAL replay will reconstruct correct state
  - Checkpoint is best-effort (not mandatory for correctness)

### Requirement: Memory Barriers and Fences

The system SHALL use explicit memory barriers where atomic operations are insufficient.

#### Scenario: Store-Release barrier

- **WHEN** an upsert commits
- **THEN** a store-release barrier SHALL ensure:
  - All writes to `IndexEntry` fields are visible
  - No reordering of writes past the barrier
  - Implemented via `@atomicStore(.Release)`
- **AND** this guarantees subsequent reads on other threads see complete update

#### Scenario: Load-Acquire barrier

- **WHEN** a lookup reads an entry
- **THEN** a load-acquire barrier SHALL ensure:
  - All writes before the corresponding release are visible
  - No reordering of reads before the barrier
  - Implemented via `@atomicLoad(.Acquire)`
- **AND** this prevents reading stale data

#### Scenario: SeqCst for critical operations

- **WHEN** strict ordering is required (e.g., index metadata updates)
- **THEN** SeqCst (sequentially consistent) atomics MAY be used:
  - `@atomicStore(.SeqCst)` for writes
  - `@atomicLoad(.SeqCst)` for reads
- **AND** this provides total ordering across all threads (stronger than Acquire/Release)
- **AND** use sparingly (performance cost ~2-3x higher than Acquire/Release)

#### Scenario: Full memory fence

- **WHEN** a full memory fence is required (rare)
- **THEN** use `@fence(.SeqCst)` to ensure:
  - All memory operations before fence complete
  - All memory operations after fence start after fence
- **AND** this is typically NOT needed due to atomic operations with memory ordering

### Requirement: Thread-Local State

The system SHALL avoid shared mutable state where possible by using thread-local caches.

#### Scenario: Thread-local hash state

- **WHEN** computing hash(entity_id)
- **THEN** each thread MAY maintain thread-local hash state
- **AND** this avoids contention on shared hash state
- **AND** wyhash/xxhash3 are stateless (no TLS needed)

#### Scenario: Thread-local statistics

- **WHEN** tracking lookup/upsert counts
- **THEN** each thread SHALL maintain thread-local counters
- **AND** aggregate statistics computed by summing thread-local counters
- **AND** this avoids atomic increment overhead on hot path

### Requirement: Concurrency Edge Cases and Liveness

The system SHALL prevent concurrency edge cases including reader starvation, livelock, and priority inversion.

#### Scenario: Reader starvation prevention

- **WHEN** continuous upsert operations occur
- **THEN** the system SHALL ensure readers are not starved:
  - VSR commit phase is single-threaded (no writer parallelism)
  - Lookups from prefetch phase run concurrently (different VSR ops)
  - No lock contention between readers
  - Readers never wait for writers (lock-free reads)
- **AND** reader starvation CANNOT occur because:
  - No locks acquired by readers
  - Writers don't block readers
  - VSR pipeline ensures fairness across operations

#### Scenario: Writer starvation prevention

- **WHEN** continuous lookup operations occur
- **THEN** writers SHALL NOT be starved because:
  - VSR commit phase executes regardless of lookup load
  - Commit phase has dedicated thread (single-threaded state machine)
  - Lookups don't interfere with commit execution
  - No shared locks between commit and lookup
- **AND** write throughput is independent of read load

#### Scenario: Livelock prevention (CAS retry loops)

- **WHEN** using compare-and-swap (CAS) for conditional updates
- **THEN** the system SHALL prevent livelock:
  - CAS is only used within single-threaded VSR commit phase
  - No concurrent CAS from multiple threads (no retry contention)
  - If CAS was multi-threaded (hypothetical):
    - Max retry count: 3 attempts
    - Exponential backoff: 1μs, 2μs, 4μs
    - After max retries: yield to OS scheduler
- **AND** livelock CANNOT occur in current design (single-threaded commit)

#### Scenario: Priority inversion prevention

- **WHEN** multiple operations compete for resources
- **THEN** priority inversion SHALL be prevented by:
  - No locks held across I/O operations (lock-free design)
  - No priority-based scheduling (FIFO operation processing)
  - All operations have equal priority in VSR pipeline
- **AND** high-priority operations can't be blocked by low-priority operations

#### Scenario: Deadlock impossibility proof

- **WHEN** analyzing potential deadlocks
- **THEN** deadlocks are IMPOSSIBLE because:
  - **No locks:** Lock-free index design (atomic ops only)
  - **No circular wait:** Single-threaded commit phase (no threads waiting on each other)
  - **No hold-and-wait:** Operations complete atomically (no partial completion)
- **AND** this is verified by design (lock-free + single-threaded = no deadlock)

#### Scenario: Memory consistency under concurrent load

- **WHEN** N threads perform concurrent lookups during upsert
- **THEN** memory consistency SHALL be guaranteed:
  - All lookups see sequentially consistent state
  - Either all fields from old entry OR all fields from new entry
  - Never mixed state (partial old, partial new)
  - Guaranteed by:
    - 64-byte atomic loads (cache line atomicity)
    - Release/Acquire memory ordering
    - x86-64 cache coherence (MESI)

#### Scenario: Race condition: Concurrent lookup during upsert

- **GIVEN** thread A is upserting entity E
- **AND** thread B is looking up entity E concurrently
- **WHEN** both operations execute simultaneously
- **THEN** thread B SHALL observe:
  - **Case 1:** Old value (upsert hasn't completed)
  - **Case 2:** New value (upsert completed)
  - **Never:** Torn read (partial old, partial new)
- **AND** both outcomes are correct (eventual consistency)
- **AND** LWW semantics ensure convergence

#### Scenario: Race condition: Concurrent TTL expiration check

- **GIVEN** entity E exists with TTL expiring "right now"
- **AND** thread A checks expiration (finds expired, attempts remove)
- **AND** thread B upserts new value for E concurrently
- **WHEN** both operations race
- **THEN** the system SHALL:
  - Use conditional removal: `remove_if_id_matches(entity_id, expired_latest_id)`
  - If latest_id changed: removal fails (fresh data wins)
  - If latest_id matches: removal succeeds (expired data removed)
- **AND** this prevents removing fresh data (already specified, reinforced here)

#### Scenario: Memory model: Sequential consistency guarantee

- **WHEN** operations execute across multiple threads
- **THEN** the memory model SHALL provide sequential consistency:
  - There exists a total order of all operations
  - Each thread's operations appear in program order
  - All threads agree on the order of operations
- **AND** this is achieved via:
  - VSR commit phase serialization (total order)
  - Atomic operations with Acquire/Release ordering
  - x86-64 TSO (Total Store Order) memory model

#### Scenario: Concurrent index checkpoint and lookup

- **WHEN** background checkpoint task writes index pages
- **AND** concurrent lookups access the same pages
- **THEN** the system SHALL:
  - Checkpoint reads index entries atomically (@atomicLoad)
  - Lookups read index entries atomically (@atomicLoad)
  - No interference between checkpoint and lookup
  - Both can proceed concurrently
- **AND** checkpoint sees consistent snapshot (may be slightly stale)

#### Scenario: Liveness guarantee under concurrent load

- **WHEN** system is under maximum concurrent load
- **THEN** liveness SHALL be guaranteed:
  - All operations eventually complete (no infinite loops)
  - Bounded wait time: p99 latency < 10ms (index operations)
  - No operation can be delayed indefinitely
  - Progress guarantee: At least one thread makes progress
- **AND** this is ensured by lock-free algorithms (wait-free for readers)

### Requirement: Formal Concurrency Correctness Proof

The system SHALL provide formal reasoning about concurrency correctness properties to enable verification.

#### Scenario: Linearizability proof sketch

- **WHEN** proving index operations are linearizable
- **THEN** the proof SHALL establish:
  ```
  Linearizability Proof (Index Operations)
  ═══════════════════════════════════════

  Theorem: All index operations (lookup, upsert) are linearizable.

  Proof sketch:
  1. Sequential specification:
     - lookup(k) returns latest value for key k, or null
     - upsert(k,v) updates key k to value v (LWW if concurrent)

  2. Linearization points:
     - lookup: @atomicLoad of IndexEntry (single atomic operation)
     - upsert: @atomicStore of IndexEntry (single atomic operation)

  3. Real-time ordering:
     - If upsert(k,v1) completes before lookup(k) starts:
       → lookup MUST see v1 (or later value)
     - Guaranteed by Acquire/Release semantics

  4. Total order construction:
     - Order operations by their linearization points (atomic load/store)
     - x86-64 TSO memory model provides total order of stores
     - Acquire/Release fences ensure visibility

  5. Sequential consistency:
     - For any execution, there exists a sequential ordering
     - That respects program order within each thread
     - Matches observable behavior

  ∴ Index operations are linearizable. QED.
  ```

#### Scenario: Deadlock-freedom proof

- **WHEN** proving system is deadlock-free
- **THEN** the proof SHALL establish:
  ```
  Deadlock-Freedom Proof
  ═════════════════════

  Theorem: The system cannot deadlock.

  Proof by contradiction:
  Assume deadlock occurs (circular wait).

  For deadlock, need all 4 Coffman conditions:
  1. Mutual exclusion: Resources held exclusively
  2. Hold and wait: Thread holds R1, waits for R2
  3. No preemption: Resources can't be forcibly taken
  4. Circular wait: T1→T2→...→T1

  ArcherDB design violations:
  1. ✗ No locks (lock-free index, atomic operations only)
     → Mutual exclusion does NOT hold

  2. ✗ Single-threaded commit phase (no concurrent writers)
     → Hold-and-wait does NOT hold

  3. ✗ Operations complete atomically (no partial state)
     → No preemption is irrelevant (nothing to preempt)

  4. ✗ No threads waiting on each other
     → Circular wait CANNOT form

  Since condition 1 is violated (no locks), deadlock is impossible.

  ∴ System is deadlock-free. QED.
  ```

#### Scenario: Starvation-freedom proof

- **WHEN** proving system is starvation-free
- **THEN** the proof SHALL establish:
  ```
  Starvation-Freedom Proof
  ═══════════════════════

  Theorem: No operation starves (all eventually complete).

  Reader starvation:
  - Readers use lock-free atomic loads
  - No waiting for locks or other threads
  - Bounded probe length (max 1024 iterations)
  - ∴ Readers complete in O(1) time, cannot starve

  Writer starvation:
  - Writers execute in VSR commit phase (single-threaded)
  - VSR pipeline ensures FIFO ordering
  - No priority inversion (all ops equal priority)
  - Pipeline depth bounded (pipeline_max = 1024)
  - ∴ Writers complete within bounded time, cannot starve

  ∴ System is starvation-free. QED.
  ```

#### Scenario: Memory model correctness (TLA+ sketch)

- **WHEN** formally verifying memory model
- **THEN** a TLA+ specification sketch SHALL include:
  ```
  TLA+ Model Sketch (Index Concurrency)
  ═════════════════════════════════════

  MODULE IndexConcurrency

  VARIABLES
    index,          \* Map from entity_id to IndexEntry
    readers,        \* Set of active reader threads
    writer_state    \* VSR commit phase state

  Init ==
    /\ index = [e \in EntityID |-> NULL]
    /\ readers = {}
    /\ writer_state = "idle"

  ReadOperation(thread, entity_id) ==
    /\ thread \in readers
    /\ \E entry \in IndexEntry :
        entry = index[entity_id]  \* Atomic read
    /\ UNCHANGED <<index, writer_state>>

  WriteOperation(entity_id, new_value) ==
    /\ writer_state = "commit"  \* Only in commit phase
    /\ index' = [index EXCEPT ![entity_id] = new_value]
    /\ UNCHANGED <<readers, writer_state>>

  Invariants:
    TypeOK == index \in [EntityID -> IndexEntry \cup {NULL}]

    Linearizability ==
      \A op1, op2 \in Operations :
        RealTimeBefore(op1, op2) =>
          LinearizationOrder(op1, op2)

    NoTornReads ==
      \A thread \in readers :
        ReadValue(thread) \in {OldEntry, NewEntry}
        /\ ReadValue(thread) \notin PartialEntry

  THEOREM Spec => []Linearizability /\ []NoTornReads
  ```
- **AND** full TLA+ model would be developed during formal verification phase (if required)

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
  - **RAM:** 32GB (configure `max_entities` accordingly; ~250-300M entities practical with 64-byte index entries + OS headroom)
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

### Requirement: Memory-Mapped Index Fallback (Optional)

The system MAY support a memory-mapped index mode for deployments with limited RAM.

#### Scenario: Mmap index mode configuration

- **WHEN** configured with `--index-mode=mmap`
- **THEN** the index SHALL:
  - Memory-map the index file instead of loading into RAM
  - Rely on OS page cache for hot entries
  - Accept higher lookup latency (p99: 1-5ms vs <500μs)
  - Support larger datasets with less RAM (32GB sufficient for 1B entities)
- **AND** this mode trades latency for reduced RAM requirements

#### Scenario: Mmap index file format

- **WHEN** using mmap index mode
- **THEN** the index file format SHALL be:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                    MMAP INDEX FILE FORMAT                        │
  ├──────────┬───────────────────────────────────────────────────────┤
  │  Header  │ Magic (8B) + Version (4B) + Capacity (8B) + Count (8B)│
  │          │ + Load factor (4B) + Checksum (16B) + Reserved (16B)  │
  ├──────────┼───────────────────────────────────────────────────────┤
  │  Entries │ IndexEntry[0..capacity] (64 bytes each)               │
  │          │ Same layout as RAM index for compatibility            │
  └──────────┴───────────────────────────────────────────────────────┘
  ```
- **AND** file is pre-allocated to full capacity at startup
- **AND** entries are updated in-place with fsync on checkpoint

#### Scenario: Mmap index performance characteristics

- **WHEN** operating in mmap index mode
- **THEN** performance characteristics SHALL be:
  | Metric | RAM Index | Mmap Index (cold) | Mmap Index (warm) |
  |--------|-----------|-------------------|-------------------|
  | Lookup p50 | <100μs | 500μs-2ms | <200μs |
  | Lookup p99 | <500μs | 2-10ms | <1ms |
  | Upsert | <50μs | 100-500μs | <100μs |
  | RAM required (1B) | 96GB | ~4GB (cache) | ~32GB (cache) |
- **AND** performance depends heavily on working set locality
- **AND** sequential scans benefit from OS read-ahead

#### Scenario: Mmap index use cases

- **WHEN** selecting index mode
- **THEN** mmap mode is appropriate for:
  - Development and testing environments
  - Cost-sensitive deployments with latency tolerance
  - Cold data clusters with infrequent access
  - Deployments where 128GB RAM is cost-prohibitive
- **AND** RAM mode remains recommended for production with SLA requirements

#### Scenario: Mmap index limitations

- **WHEN** using mmap index mode
- **THEN** the following limitations SHALL apply:
  - Cannot meet <500μs p99 latency SLA
  - Higher variance in query latency
  - Sensitive to OS memory pressure
  - May experience page fault storms under load
- **AND** operators SHOULD provision adequate page cache (30-50% of index size)

#### Scenario: Mmap to RAM mode migration

- **WHEN** migrating from mmap to RAM mode
- **THEN** the operator SHALL:
  1. Stop the replica gracefully
  2. Update configuration: `--index-mode=ram`
  3. Ensure sufficient RAM is available (128GB for 1B entities)
  4. Start replica (index loads from checkpoint or rebuilds)
- **AND** migration requires downtime for the individual replica
- **AND** rolling migration across cluster maintains availability

### Related Specifications

- See `specs/data-model/spec.md` for IndexEntry structure and GeoEvent format
- See `specs/storage-engine/spec.md` for LSM storage and checkpoint coordination
- See `specs/query-engine/spec.md` for index lookup during queries
- See `specs/ttl-retention/spec.md` for lazy TTL expiration in index
- See `specs/constants/spec.md` for index_entry_size and capacity constants
- See `specs/memory-management/spec.md` for StaticAllocator and memory discipline
- See `specs/implementation-guide/spec.md` for linear probing hash map algorithm
