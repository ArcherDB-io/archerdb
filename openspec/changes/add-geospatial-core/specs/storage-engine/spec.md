# Storage Engine Specification

**Reference Implementation:** https://github.com/tigerbeetle/tigerbeetle/blob/main/src/storage.zig

This spec is based on TigerBeetle's data file layout and LSM tree design. Implementers MUST study:
- `src/storage.zig` - Data file zones, superblock, grid, free set
- `src/lsm/` - LSM tree implementation (manifest, compaction, table memory)
- `src/vsr/superblock.zig` - Superblock structure with hash-chaining
- `src/vsr/free_set.zig` - Block allocation with shard-based bitsets

**Implementation approach:** Use TigerBeetle's storage patterns directly. The data file zones, LSM structure, and free set algorithms are domain-agnostic and can be reused as-is.

---

## ADDED Requirements

### Requirement: Data File Zone Layout

The system SHALL organize the data file into distinct zones matching TigerBeetle's layout for crash recovery and efficient access patterns.

#### Scenario: Zone ordering

- **WHEN** a data file is formatted
- **THEN** zones SHALL be laid out in order:
  1. Superblock Zone (multiple redundant copies)
  2. WAL Headers Zone (journal slot headers)
  3. WAL Prepares Zone (journal slot bodies)
  4. Client Replies Zone (cached client responses)
  5. Grid Padding (alignment to block_size)
  6. Grid Zone (LSM tree blocks, unbounded)

#### Scenario: Minimum data file size

- **WHEN** calculating minimum viable file size
- **THEN** `data_file_size_min = superblock_zone_size + journal_size + client_replies_size + grid_padding_size`
- **AND** this SHALL be validated before opening

### Requirement: Superblock Structure

The system SHALL maintain multiple redundant copies of the superblock for crash recovery using quorum reads.

#### Scenario: Superblock copies

- **WHEN** the superblock is written
- **THEN** it SHALL be written to 4, 6, or 8 redundant copy locations
- **AND** each copy SHALL be sector-aligned (4096 bytes minimum)
- **AND** copy count MUST be even for flexible quorum reads

#### Scenario: Superblock header fields

- **WHEN** a SuperBlockHeader is defined
- **THEN** it SHALL contain:
  - `checksum: u128` - Aegis-128L MAC of remaining header
  - `checksum_padding: u128` - Reserved for u256
  - `copy: u16` - Copy number (prevents misdirected quorum reads)
  - `version: u16` - Format version for upgrades
  - `sequence: u64` - Monotonic sequence for crash recovery
  - `cluster: u128` - Cluster ID (safety check)
  - `parent: u128` - Checksum of previous superblock (hash chain)
  - `parent_padding: u128` - Reserved for u256
  - `vsr_state: VSRState` - Full VSR protocol state
  - `checkpoint_state: CheckpointState` - LSM checkpoint metadata

#### Scenario: Hash-chained superblocks

- **WHEN** writing a new superblock
- **THEN** `parent` field SHALL contain checksum of previous superblock
- **AND** this creates a hash chain for integrity verification
- **AND** sequence number SHALL be strictly monotonically increasing

#### Scenario: Quorum reads

- **WHEN** reading the superblock on startup
- **THEN** all copies SHALL be read
- **AND** the copy with highest valid sequence SHALL be selected
- **AND** `copy` field prevents accidentally using wrong copy in quorum

#### Scenario: Complete superblock loss (catastrophic failure)

- **WHEN** all superblock copies are corrupted or unreadable
- **THEN** the system SHALL:
  - Refuse to start (cannot determine VSR state)
  - Log critical error: "FATAL: All superblock copies corrupted - unrecoverable"
  - Return exit code indicating unrecoverable state
  - **Operator MUST restore from backup** (S3 or other external backup)
  - This is an UNRECOVERABLE state without external backup
  - Data file is intact but cannot be used without superblock metadata
- **AND** prevention: monitor superblock integrity proactively

### Requirement: Write-Ahead Log (WAL)

The system SHALL maintain a circular WAL with separate rings for headers and prepares to enable efficient crash recovery.

#### Scenario: Dual-ring WAL structure

- **WHEN** the WAL is organized
- **THEN** it SHALL have two separate circular buffers:
  - `wal_headers`: Ring of Prepare headers (redundant, for recovery)
  - `wal_prepares`: Ring of full Prepare messages (sector-aligned)

#### Scenario: Journal slot sizing

- **WHEN** calculating journal sizes
- **THEN** `journal_size_headers = journal_slot_count * @sizeOf(Header.Prepare)`
- **AND** `journal_size_prepares = journal_slot_count * message_size_max`
- **AND** total `journal_size = journal_size_headers + journal_size_prepares`

#### Scenario: Slot addressing

- **WHEN** accessing a journal slot
- **THEN** header offset = `sector_floor(slot_index * @sizeOf(Header))`
- **AND** prepare offset = `message_size_max * slot_index`

#### Scenario: Circular wraparound

- **WHEN** the journal is full
- **THEN** committed entries MAY be overwritten
- **AND** uncommitted entries SHALL be protected by checkpoint constraints
- **AND** `journal_slot_count` MUST support `pipeline_max + 2 * checkpoint_interval`

### Requirement: Grid Block Storage

The system SHALL provide abstract block-based storage for the LSM tree with caching and repair capabilities.

#### Scenario: Block identification

- **WHEN** a block is stored in the grid
- **THEN** it SHALL be identified by `BlockReference`:
  - `address: u64` - Block address (1-based, 0 is sentinel/null)
  - `checksum: u128` - Aegis-128L MAC of block

#### Scenario: Block sizing

- **WHEN** configuring block size
- **THEN** `block_size` SHALL be 64KB (default) or configurable
- **AND** `block_size` MUST be a multiple of `sector_size` (4096)
- **AND** `block_size` MUST be ≤ `message_size_max`

#### Scenario: Block cache

- **WHEN** the grid is initialized
- **THEN** it SHALL include a set-associative cache:
  - Key: block address (u64)
  - Value: block pointer
  - 16-way set-associative (configurable)
  - Coherency tracking for checkpoint visibility

#### Scenario: Read/Write IOPS limits

- **WHEN** grid I/O is performed
- **THEN** concurrent reads SHALL be bounded by `grid_iops_read_max`
- **AND** concurrent writes SHALL be bounded by `grid_iops_write_max`
- **AND** operations SHALL be queued when limits reached

### Requirement: Checksum Algorithm

The system SHALL use Aegis-128L MAC for all integrity checksums, requiring AES-NI hardware acceleration.

#### Scenario: Checksum computation

- **WHEN** computing a checksum
- **THEN** Aegis-128L MAC SHALL be used (AES-128 based AEAD in MAC mode)
- **AND** key SHALL be all zeros (specialized AEAD as checksum)
- **AND** output SHALL be u128 (128-bit)

#### Scenario: Hardware requirement

- **WHEN** the system starts
- **THEN** AES-NI support SHALL be verified at compile time
- **AND** systems without AES-NI SHALL fail to compile

#### Scenario: Dual checksums per block

- **WHEN** a block is written
- **THEN** header checksum SHALL cover header bytes after checksum field
- **AND** body checksum SHALL cover entire body separately
- **AND** both checksums enable detecting which part is corrupted

### Requirement: Free Set Management

The system SHALL track acquired vs. free blocks using bitsets with a reservation system for deterministic allocation.

#### Scenario: Free set structure

- **WHEN** tracking block allocation
- **THEN** the FreeSet SHALL maintain:
  - `blocks_acquired: DynamicBitSet` - 1 = acquired, 0 = free
  - `blocks_released: DynamicBitSet` - 1 = released in current checkpoint
  - `index: DynamicBitSet` - 1 = shard full (fast lookup)

#### Scenario: Shard-based organization

- **WHEN** organizing the free set
- **THEN** blocks SHALL be grouped into shards of 4096 bits
- **AND** index bit indicates if any block in shard is free
- **AND** shard size matches 8 cache lines × 64 bits

#### Scenario: Reservation lifecycle

- **WHEN** allocating blocks
- **THEN** the lifecycle SHALL be:
  1. **Reserve**: Deterministically reserve N blocks before concurrent work
  2. **Acquire**: Concurrent jobs acquire only from their reservation
  3. **Forfeit**: Jobs return unused reserved blocks
  4. **Reclaim**: Released blocks only reusable after checkpoint is durable

#### Scenario: Checkpoint release

- **WHEN** blocks are released
- **THEN** they SHALL be marked in `blocks_released`
- **AND** they SHALL NOT be reused until next checkpoint is durable
- **AND** this ensures durability before block reuse

#### Scenario: Free set exhaustion handling

- **WHEN** free blocks fall below critical thresholds
- **THEN** the system SHALL implement backpressure:
  1. **Warning threshold (10% free)**:
     - Log warning: "Free set below 10% - consider increasing data file size"
     - Increment metric: `archerdb_free_set_low_warning_total`
  2. **Critical threshold (5% free)**:
     - Reject new write batches with error `out_of_space`
     - Allow compaction to continue (it frees blocks)
     - Log error: "Free set critical - writes suspended until compaction frees space"
  3. **Emergency threshold (2% free)**:
     - Force immediate compaction of oldest levels
     - Enter read-only mode if compaction cannot free space
     - Log critical: "Free set exhausted - emergency compaction initiated"
- **AND** metric `archerdb_free_set_available_blocks` tracks current availability
- **AND** this prevents deadlock where writes fill disk before compaction can reclaim

### Requirement: LSM Tree Structure

The system SHALL implement a Log-Structured Merge Tree with configurable levels and growth factor.

#### Scenario: LSM configuration

- **WHEN** configuring the LSM tree
- **THEN** configurable parameters SHALL include:
  - `lsm_levels`: Number of levels (default: 7, range: 0-63)
  - `lsm_growth_factor`: Tables per level multiplier (default: 8, must be >1)
  - `lsm_compaction_ops`: Prepares per in-memory table (default: 32)

#### Scenario: Level capacity

- **WHEN** calculating level capacity
- **THEN** level i can hold up to `growth_factor^(i+1)` tables
- **AND** level 0 is the in-memory mutable table

#### Scenario: Table structure

- **WHEN** a table is written
- **THEN** it SHALL consist of:
  - 1 Index Block (checksums, keys, addresses of value blocks)
  - N Value Blocks (actual key-value pairs)
- **AND** `block_count_max = 1 + value_block_count_max`

### Requirement: Manifest Log

The system SHALL maintain a durable manifest log tracking all LSM table metadata.

#### Scenario: Manifest entries

- **WHEN** tables are created or deleted
- **THEN** manifest entries SHALL record:
  - Table creation (snapshot_min)
  - Table deletion (snapshot_max)
  - Table metadata (level, key range, block references)

#### Scenario: Manifest blocks

- **WHEN** manifest entries accumulate
- **THEN** they SHALL be batched into manifest blocks
- **AND** blocks form a linked list via checksums
- **AND** oldest/newest block addresses stored in checkpoint state

### Requirement: Compaction

The system SHALL perform background compaction to merge tables and reclaim space.

#### Scenario: Compaction selection

- **WHEN** compaction is triggered
- **THEN** select table from level A and overlapping tables from level B
- **AND** if ranges disjoint, move table without merge
- **AND** if overlapping, sort-merge and write to level B

#### Scenario: Compaction I/O bounds

- **WHEN** compaction runs
- **THEN** input tables max = `1 + lsm_growth_factor`
- **AND** read IOPS max = 18 (16 value + 2 index blocks)
- **AND** write IOPS max = 17 (16 value + 1 index blocks)

#### Scenario: Snapshot visibility

- **WHEN** compaction completes
- **THEN** old tables get `snapshot_max` set (hidden from queries)
- **AND** new tables inserted with current `snapshot_min`
- **AND** manifest updated durably

#### Scenario: Tombstone handling during compaction

- **WHEN** compaction reads an event with `flags.deleted = true` (tombstone)
- **THEN** the system SHALL:
  1. Check if the tombstone has been replicated to all living events (no older version exists)
  2. If tombstone is the latest for this entity AND older events are compacted out: discard tombstone
  3. If older events may still exist in lower levels: copy tombstone forward
  4. Keep tombstone until a full compaction pass has propagated it to all levels
- **AND** tombstones are NOT backed up to S3 (GDPR compliance)
- **AND** metrics SHALL track `archerdb_compaction_tombstones_removed_total`

#### Scenario: Expired event handling during compaction

- **WHEN** compaction reads an event with expired TTL (current_time >= timestamp + ttl_seconds)
- **THEN** the system SHALL:
  1. Discard the event (do not copy forward)
  2. If this was the latest event for the entity: entity effectively disappears
  3. RAM index cleanup occurs lazily on lookup or via background cleanup
- **AND** metrics SHALL track `archerdb_compaction_events_expired_total`

### Requirement: Compaction Trigger Policy

The system SHALL define clear policies for when compaction is triggered.

#### Scenario: Level-based compaction trigger

- **WHEN** monitoring LSM levels for compaction
- **THEN** compaction SHALL be triggered when:
  - Level 0 has more than `lsm_l0_compaction_trigger` tables (default: 4)
  - Level N (N > 0) has more than `growth_factor^(N+1)` tables
- **AND** higher priority for Level 0 (affects write latency)
- **AND** lower levels compact during idle time

#### Scenario: Size-based compaction trigger

- **WHEN** a level's total size exceeds threshold
- **THEN** compaction MAY be triggered:
  - Level size threshold: `level_size_base × growth_factor^level`
  - Default `level_size_base`: 64MB (1024 blocks × 64KB)
- **AND** this ensures balanced distribution across levels

#### Scenario: Time-based compaction trigger

- **WHEN** no compaction has occurred for `compaction_idle_timeout` (default: 60 seconds)
- **AND** there are tables eligible for compaction
- **THEN** background compaction SHALL run
- **AND** this ensures steady-state cleanup even under low write load

#### Scenario: Compaction priority ordering

- **WHEN** multiple compaction candidates exist
- **THEN** priority SHALL be:
  1. Level 0 (highest priority - blocks writes when full)
  2. Levels with tombstone density > 50%
  3. Levels exceeding size threshold
  4. Levels exceeding table count
  5. Oldest uncompacted tables (age-based tiebreaker)

#### Scenario: Compaction throttling under write pressure

- **WHEN** write rate exceeds compaction rate
- **THEN** the system SHALL:
  - Allow Level 0 to grow up to `lsm_l0_slowdown_trigger` tables (default: 8)
  - Begin slowing writes (add latency) above slowdown trigger
  - Stop accepting writes at `lsm_l0_stop_trigger` tables (default: 12)
  - Log warning: "Write stall - compaction cannot keep up"
- **AND** this prevents unbounded Level 0 growth

### Requirement: Checkpoint State

The system SHALL maintain checkpoint metadata in the superblock for crash recovery.

#### Scenario: Checkpoint fields

- **WHEN** a checkpoint is taken
- **THEN** CheckpointState SHALL record:
  - `header: Header.Prepare` - Last committed prepare
  - `free_set_*`: Checksums, addresses, sizes for acquired/released blocks
  - `client_sessions_*`: Client session cache metadata
  - `manifest_*`: Oldest/newest manifest block addresses and count
  - `storage_size: u64` - Total allocated storage

#### Scenario: Checkpoint durability ordering (CRITICAL SAFETY INVARIANT)

- **WHEN** a checkpoint becomes durable
- **THEN** operations SHALL occur in STRICT ORDER:
  1. Complete all grid writes (LSM tables, manifest, free set)
  2. Issue fsync() to ensure grid writes are durable
  3. Wait for fsync() to complete
  4. **ONLY THEN** write new superblock with CheckpointState
  5. fsync() superblock write
  6. Mark checkpoint as durable
  7. Released blocks may now be reclaimed
- **AND** superblock write MUST be the ABSOLUTE LAST operation
- **AND** violation of this ordering causes data corruption on crash
- **AND** this is a SAFETY INVARIANT that MUST be enforced
- **AND** if superblock is written before grid writes complete:
  - Crash recovery will use new checkpoint state
  - But grid blocks may be incomplete
  - Results in DATA CORRUPTION (unrecoverable)

### Requirement: Disk Full Error Handling

The system SHALL gracefully handle disk full conditions without data corruption.

#### Scenario: Disk full during write

- **WHEN** a write operation fails with ENOSPC (disk full)
- **THEN** the system SHALL:
  - Fail the current operation with error `out_of_space`
  - NOT corrupt existing data (partial writes are rolled back)
  - Log critical alert: "Disk full - immediate operator intervention required"
  - Continue serving read queries from existing data
  - Reject all write operations until space is available

#### Scenario: Disk full during compaction

- **WHEN** LSM compaction fails due to disk full
- **THEN** the system SHALL:
  - Abort compaction (keep old tables)
  - NOT delete source tables
  - Log critical alert
  - Retry compaction after space becomes available

#### Scenario: Disk full during checkpoint

- **WHEN** checkpoint write fails due to disk full
- **THEN** the system SHALL:
  - Keep previous checkpoint valid
  - Log critical alert
  - Cluster remains available (other replicas continue)
  - Affected replica enters degraded state
  - Operator must free space or replace replica

### Requirement: Direct I/O

The system SHALL use Direct I/O with O_DSYNC for consistent durability semantics.

#### Scenario: File open flags

- **WHEN** opening the data file
- **THEN** flags SHALL include:
  - `O_DIRECT` - Bypass kernel page cache
  - `O_DSYNC` - Ensure data durability on write completion
  - `O_CLOEXEC` - Close on exec

#### Scenario: Alignment requirements

- **WHEN** performing Direct I/O
- **THEN** all buffers MUST be sector-aligned (4096 bytes)
- **AND** all I/O sizes MUST be multiples of sector_size
- **AND** all file offsets MUST be sector-aligned

#### Scenario: Block device support

- **WHEN** using a block device instead of file
- **THEN** `O_EXCL` SHALL be used for advisory exclusive lock
- **AND** Direct I/O is always supported on block devices

### Requirement: Write Amplification Budget

The system SHALL document expected write amplification to enable capacity planning and SSD wear estimation.

#### Scenario: Write amplification formula

- **WHEN** calculating write amplification (WA)
- **THEN** WA is defined as:
  ```
  Write Amplification = total_bytes_written_to_disk / application_bytes_written

  For leveled LSM with growth_factor=8 and lsm_levels=7:

  Theoretical worst-case WA:
  - Each byte may be compacted at each level transition
  - WA_max = 1 + growth_factor × (levels - 1) = 1 + 8 × 6 = 49

  Practical steady-state WA:
  - Not all data reaches deepest levels
  - Typical WA = 1 + (growth_factor / 2) × (avg_level_depth)
  - For balanced workload: WA ≈ 10-20

  Components:
  - Initial write to Level 0: 1×
  - L0→L1 compaction: ~8× (growth_factor)
  - L1→L2 compaction: ~8× (amortized across tables)
  - Deeper levels: progressively less frequent
  ```

#### Scenario: Write amplification targets

- **WHEN** setting performance expectations
- **THEN** WA targets SHALL be:
  ```
  | Workload Pattern        | Expected WA | Notes                              |
  |-------------------------|-------------|------------------------------------|
  | Write-heavy (append)    | 8-15        | Data ages out via TTL              |
  | Mixed read/write        | 12-20       | Typical production workload        |
  | Update-heavy (LWW)      | 15-25       | Same entities updated frequently   |
  | Delete-heavy (GDPR)     | 20-30       | Tombstones propagate through levels|
  ```
- **AND** these are estimates based on TigerBeetle-style leveled compaction

#### Scenario: SSD wear calculation

- **WHEN** estimating SSD lifespan
- **THEN** calculation SHALL be:
  ```
  Daily write volume = events_per_day × 128 bytes × WA
  SSD lifespan = TBW_rating / (daily_write_volume × 365)

  Example:
  - 100M events/day = 12.8 GB raw data
  - With WA=15: 192 GB/day written to SSD
  - Samsung PM9A3 7.68TB (17,520 TBW rating)
  - Lifespan: 17,520 TB / (192 GB × 365) ≈ 250 years

  Example (heavy workload):
  - 1B events/day = 128 GB raw data
  - With WA=20: 2.56 TB/day written to SSD
  - Samsung PM9A3 7.68TB (17,520 TBW rating)
  - Lifespan: 17,520 TB / (2.56 TB × 365) ≈ 18.7 years
  ```
- **AND** enterprise SSDs are recommended for production workloads
- **AND** monitor `archerdb_storage_bytes_written_total` for actual WA measurement

#### Scenario: Write amplification monitoring

- **WHEN** monitoring write amplification
- **THEN** the following metrics SHALL be exposed:
  ```
  # Total bytes written by application
  archerdb_lsm_user_bytes_written_total counter

  # Total bytes written to disk (including compaction)
  archerdb_lsm_disk_bytes_written_total counter

  # Current write amplification (sliding window)
  archerdb_lsm_write_amplification gauge

  # Compaction bytes read/written per level
  archerdb_lsm_compaction_bytes_read_total{level="N"} counter
  archerdb_lsm_compaction_bytes_written_total{level="N"} counter
  ```

#### Scenario: Write amplification reduction strategies

- **WHEN** WA exceeds acceptable thresholds
- **THEN** operators MAY consider:
  1. **Increase growth_factor**: Higher growth = fewer levels = lower WA, but more space amplification
  2. **Shorter TTLs**: Expired data doesn't need compaction propagation
  3. **Batch updates**: Same entity updated in same batch = single write
  4. **Time-partitioned sharding**: Old data compacts independently
- **AND** these are trade-offs (no free lunch)

### Requirement: Skip-Scan Optimization

The system SHALL maintain min/max ID metadata in block headers to enable skipping irrelevant blocks during range scans.

#### Scenario: Min/Max tracking

- **WHEN** a data block is written
- **THEN** the header SHALL contain `min_id` and `max_id` of all records
- **AND** these SHALL be the actual minimum and maximum composite IDs

#### Scenario: Block skipping logic

- **WHEN** scanning for IDs in range [start, end]
- **AND** a block's `max_id < start` OR `min_id > end`
- **THEN** the block body SHALL NOT be read
- **AND** the scan SHALL proceed to the next block
- **AND** only the 256-byte header is needed for this decision
