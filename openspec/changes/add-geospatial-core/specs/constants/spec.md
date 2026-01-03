# Constants and Configuration Specification

## ADDED Requirements

### Requirement: Central Constants Definition

The system SHALL define all critical constants in a central location to ensure consistency across all components.

#### Scenario: Constants file location

- **WHEN** implementing the system
- **THEN** all constants SHALL be defined in `src/constants.zig`
- **AND** this file SHALL be imported by all other modules
- **AND** constants SHALL use compile-time evaluation (`comptime`)

### Requirement: Core Size Constants

The system SHALL define fundamental size constants for memory layout and protocol compatibility.

#### Scenario: Structure sizes

- **WHEN** defining structure sizes
- **THEN** the following SHALL be defined:
  ```zig
  /// Size of GeoEvent struct (cache-aligned)
  pub const geo_event_size = 128;

  /// Size of BlockHeader struct
  pub const block_header_size = 256;

  /// Size of VSR message header
  pub const message_header_size = 256;

  /// Disk sector size (for O_DIRECT)
  pub const sector_size = 4096;
  ```

#### Scenario: Message size limits

- **WHEN** defining message limits
- **THEN** the following SHALL be defined:
  ```zig
  /// Maximum total message size (header + body)
  pub const message_size_max = 10 * 1024 * 1024; // 10MB

  /// Maximum events per batch (fits in message with overhead)
  /// Calculation: (message_size_max - message_header_size - 1024 safety margin) / geo_event_size
  /// = (10,485,760 - 256 - 1024) / 128 = 81,920
  /// BUT: Limited to 10,000 for practical memory management
  pub const batch_events_max = 10_000;

  /// Maximum message body size
  pub const message_body_size_max = message_size_max - message_header_size;
  ```

#### Scenario: Consistency check

- **WHEN** the system compiles
- **THEN** it SHALL verify:
  ```zig
  comptime {
      // Verify batch fits in message
      const batch_size = batch_events_max * geo_event_size;
      assert(batch_size < message_body_size_max);
  }
  ```

### Requirement: Storage Constants

The system SHALL define storage-related constants for data file organization.

#### Scenario: Block and grid constants

- **WHEN** defining storage constants
- **THEN** the following SHALL be defined:
  ```zig
  /// Grid block size (for LSM tree blocks)
  pub const block_size = 64 * 1024; // 64KB

  /// Number of GeoEvents per block (for skip-scan)
  /// Each block has a 256-byte header, so usable space = block_size - block_header_size
  pub const events_per_block = (block_size - block_header_size) / geo_event_size; // 510 events

  /// Superblock redundancy (must be even for quorum reads)
  pub const superblock_copies = 6;

  /// Superblock size (sector-aligned)
  pub const superblock_size = 4096;
  ```

#### Scenario: LSM tree constants

- **WHEN** defining LSM constants
- **THEN** the following SHALL be defined:
  ```zig
  /// Number of LSM tree levels
  pub const lsm_levels = 7;

  /// Growth factor between levels
  pub const lsm_growth_factor = 8;

  /// Operations before in-memory table flush
  pub const lsm_compaction_ops = 32;

  /// Base size threshold for Level 0 compaction trigger
  /// Formula: level triggers at level_size_base × lsm_growth_factor^level
  /// 64MB = 1024 blocks × 64KB per block
  pub const level_size_base = 64 * 1024 * 1024; // 64MB

  /// Maximum value blocks per LSM table
  /// Each table = 1 index block + N value blocks
  /// With 1024 total blocks per table (64MB): value_block_count_max = 1023
  pub const value_block_count_max = 1023;

  /// Level 0 compaction trigger (number of L0 tables before compaction starts)
  pub const lsm_l0_compaction_trigger = 4;

  /// Level 0 slowdown trigger (begin adding write latency)
  pub const lsm_l0_slowdown_trigger = 8;

  /// Level 0 stop trigger (halt writes until compaction catches up)
  pub const lsm_l0_stop_trigger = 12;

  /// Idle compaction timeout (trigger background compaction during low load)
  pub const compaction_idle_timeout_ms = 60_000; // 60 seconds

  /// Minimum operations retained in compaction history
  /// Used to ensure recovery window >= checkpoint_interval
  /// Formula: minimum 2× checkpoint_interval to allow recovery during compaction
  /// At 1M events/sec, 60s checkpoint interval = 60M events retained
  /// Conservative: ~20,000 operations minimum between compaction cycles
  pub const compaction_retention_ops = 20_000;
  ```

### Requirement: VSR and Replication Constants

The system SHALL define constants for the VSR consensus protocol.

#### Scenario: Journal and checkpoint constants

- **WHEN** defining VSR constants
- **THEN** the following SHALL be defined:
  ```zig
  /// Number of slots in the journal (WAL ring buffer)
  /// MUST be large enough to hold history between checkpoints (60s index checkpoint)
  ///
  /// FORMULA: journal_slot_count >= (checkpoint_interval_seconds × throughput_events_per_sec) / avg_ops_per_slot
  ///
  /// ARCHERDDB CALCULATION (TARGET: 1M events/sec):
  /// - Target throughput: 1M events/sec = 100 batches/sec (10K events/batch)
  /// - Checkpoint interval: 60 seconds = 60M events between checkpoints
  /// - TigerBeetle baseline: ~1666 ops/sec per slot → needs 60,000 slots for safety margin
  /// - ArcherDB actual ops_per_slot unknown until F0.2.7 empirical validation
  /// - Current conservative estimate: 8192 slots = ~81 seconds @ 100 batches/sec
  ///   (assumes ~12,250 events per slot; if actual is lower, FAIL condition)
  ///
  /// CRITICAL VALIDATION REQUIRED (F0.2.7 task, Week 0-1):
  /// The actual ops_per_slot for ArcherDB must be measured empirically at peak 1M ops/sec.
  /// This is BLOCKING - if F0.2.7 FAILS, architecture cannot proceed.
  /// Steps:
  /// 1. Run steady-state load test: 1M events/sec for 5 minutes
  /// 2. Measure: max_journal_slots_occupied = peak concurrent slots in use
  /// 3. Calculate: actual_ops_per_slot = 1M / max_journal_slots_occupied
  /// 4. Decision tree:
  ///    a) If actual_ops_per_slot ≥ 12,250: PASS - 8192 slots sufficient, margin good
  ///    b) If 6,125 ≤ actual_ops_per_slot < 12,250: MARGINAL - 8192 adequate but no margin
  ///    c) If actual_ops_per_slot < 6,125: FAIL - recalculate: journal_slot_count = 60M / actual_ops_per_slot
  ///       For example, if actual = 5000, need 12,000 slots (requires ~120GB WAL disk)
  ///
  /// WAL DISK USAGE CLARIFICATION:
  /// - Headers ring: 8192 * 256 bytes = ~2MB (negligible)
  /// - Prepares ring: 8192 * message_size_max = 8192 * 10MB = ~82GB
  /// - This 82GB is REQUIRED for the WAL to function correctly at peak load
  /// - If disk space is constrained:
  ///   - Reduce message_size_max to 1MB (still allows ~7,800 events/batch)
  ///   - This reduces WAL prepares to ~8GB
  ///   - OR reduce journal_slot_count (sacrifices recovery window)
  /// - Production recommendation: 100GB+ NVMe with 82GB WAL + LSM data
  pub const journal_slot_count = 8192;

  /// Operations between checkpoints (CRITICAL: referenced everywhere)
  /// Must satisfy: journal_slot_count >= pipeline_max + 2 * checkpoint_interval
  pub const checkpoint_interval = 256;

  /// Maximum operations in pipeline (in-flight operations)
  pub const pipeline_max = 256;

  /// Verify journal sizing
  comptime {
      assert(journal_slot_count >= pipeline_max + 2 * checkpoint_interval);
      // 8192 >= 256 + 2 * 256 = 768 ✓
  }
  ```

#### Scenario: Cluster configuration constants

- **WHEN** defining cluster constants
- **THEN** the following SHALL be defined:
  ```zig
  /// Maximum number of replicas (active)
  pub const replicas_max = 6;

  /// Maximum number of standby replicas
  pub const standbys_max = 4;

  /// Maximum client connections per replica
  pub const clients_max = 10_000;

  /// Maximum client sessions tracked for idempotency (VSR client session table)
  /// Distinct from clients_max: sessions persist across connections for deduplication
  pub const client_sessions_max = 10_000;

  /// Maximum concurrent grid read IOPS (bounds disk read parallelism)
  pub const grid_iops_read_max = 128;

  /// Maximum concurrent grid write IOPS (bounds disk write parallelism)
  pub const grid_iops_write_max = 64;

  /// Maximum messages in the message pool
  /// Calculation: pipeline_max * 2 + clients_max + (replica_count * 2) + margin
  /// Conservative: 10,000 clients + 1,000 for internal ops = 11,000
  pub const messages_max = 11_000;

  /// CLARIFICATION: MessagePool does NOT allocate messages_max * message_size_max memory!
  /// Following TigerBeetle's pattern:
  /// - MessagePool allocates messages_max * message_header_size for headers
  /// - Body buffers are allocated from a separate buffer pool or on-demand
  /// - message_size_max is a VALIDATION limit, not an allocation size
  /// - Actual RAM for MessagePool: ~11,000 * 256 bytes (headers) + body buffer pool
  /// - Body buffer pool: configurable, typically ~1GB for concurrent I/O

  /// Default quorum settings (for 5-node cluster)
  /// User can override at format time
  pub const quorum_replication_default = 3;
  pub const quorum_view_change_default = 3;
  ```

### Requirement: Spatial Indexing Constants

The system SHALL define constants for S2 spatial indexing.

#### Scenario: S2 configuration

- **WHEN** defining S2 constants
- **THEN** the following SHALL be defined:
  ```zig
  /// S2 cell level for indexing (CRITICAL: must be consistent)
  /// Level 30 = ~0.5cm² cell size
  pub const s2_cell_level = 30;

  /// Maximum cells in S2 RegionCoverer result
  /// Higher = more precise covering, more scan ranges
  pub const s2_max_cells = 16;

  /// Minimum S2 cell level for query covering (coarse cell ranges)
  pub const s2_cover_min_level = 10;

  /// Maximum S2 cell level for query covering (cap for RegionCoverer)
  /// Note: storage indexing uses s2_cell_level=30, but covering is capped for performance.
  pub const s2_cover_max_level = 18;

  /// Covering max-level slack relative to selected min_level
  pub const s2_cover_level_slack = 4;

  /// S2 scratch buffer size for polygon covering
  /// S2 RegionCoverer requires working memory for complex polygons.
  /// 1MB is sufficient for 10k vertices.
  pub const s2_scratch_size = 1 * 1024 * 1024; // 1MB

  /// S2 scratch buffer pool size
  /// Matches max_concurrent_queries to allow parallel decomposition
  pub const s2_scratch_pool_size = 100;

  /// Maximum concurrent spatial queries (radius, polygon)
  /// Limits memory usage: max_concurrent_queries × message_size_max = 1GB
  /// UUID lookups are NOT subject to this limit (O(1) memory)
  pub const max_concurrent_queries = 100;

  /// Query queue depth before rejecting with too_many_queries
  pub const query_queue_max = 1000;
  ```

### Requirement: Query Limits

The system SHALL define limits for query operations.

#### Scenario: Result set limits

- **WHEN** defining query limits
- **THEN** the following SHALL be defined:
  ```zig
  /// Maximum query result size (must fit in message_size_max)
  /// Calculation: (10MB - 256 header - 64 overhead) / 128 bytes = 81,917
  /// Conservative: 81,000 events × 128 = 10,368,000 bytes + overhead = 10.37MB
  pub const query_result_max = 81_000;

  /// Maximum polygon vertices
  pub const polygon_vertices_max = 10_000;

  /// Maximum radius (in meters)
  pub const radius_max_meters = 1_000_000; // 1000 km

  /// Convert to millimeters for internal use
  pub const radius_max_mm = radius_max_meters * 1000;
  ```

### Requirement: Capacity Limits

The system SHALL define capacity limits for the entire system.

#### Scenario: Entity and storage limits

- **WHEN** defining capacity limits
- **THEN** the following SHALL be defined:
  ```zig
  /// Maximum entities per node (limited by RAM index)
  pub const entities_max_per_node = 1_000_000_000; // 1 billion

  /// Index load factor target
  pub const index_load_factor = 0.70;

  /// Index capacity (slots allocated)
  pub const index_capacity = @divFloor(entities_max_per_node * 100, 70); // ~1.43B slots

  /// Index entry size (includes ttl_seconds field + padding for alignment)
  pub const index_entry_size = 64; // bytes (Cache Line Aligned)

  /// Index memory requirement (64 bytes per slot)
  pub const index_memory_bytes = index_capacity * index_entry_size; // ~91.5GB

  /// Number of logical shards for index partitioning
  /// shard_id = hash(entity_id) % shard_count
  /// Reduces cache line contention during high-throughput upserts
  pub const shard_count = 256;

  /// Maximum data file size (u64 offset limit)
  pub const data_file_size_max = 16 * 1024 * 1024 * 1024 * 1024; // 16TB

  /// Maximum events storable
  pub const events_max_total = data_file_size_max / geo_event_size; // ~137B events
  ```

### Requirement: Timing Constants

The system SHALL define timing constants for heartbeats and timeouts.

#### Scenario: Heartbeat and timeout configuration

- **WHEN** defining timing constants
- **THEN** the following SHALL be defined:
  ```zig
  /// Ping interval for liveness detection (aggressive for ≤3s failover)
  pub const ping_interval_ms = 250; // 250ms

  /// Ping timeout (missed pings before view change)
  pub const ping_timeout_count = 4; // 4 missed = 1 second

  /// View change timeout
  pub const view_change_timeout_ms = 2000; // 2 seconds

  /// Client operation timeout (default)
  pub const client_timeout_default_ms = 5000; // 5 seconds

  /// Index checkpoint interval (time-based)
  pub const index_checkpoint_interval_ms = 60_000; // 1 minute

  /// Backup mandatory mode halt timeout (default: 1 hour)
  /// If writes are halted waiting for backup for longer than this,
  /// system switches to best-effort mode to restore availability
  pub const backup_mandatory_halt_timeout_ms = 3_600_000; // 1 hour

  /// Backup queue soft limit (begin write backpressure)
  pub const backup_queue_soft_limit = 50;

  /// Backup queue capacity (normal operating limit)
  pub const backup_queue_capacity = 100;

  /// Backup queue hard limit (apply strong backpressure or release without backup)
  /// In best-effort mode: 200 blocks before backpressure
  /// In mandatory mode: uses backup_queue_capacity (100) as hard limit
  pub const backup_queue_hard_limit = 200;

  /// Session timeout (inactive sessions may be evicted)
  pub const session_timeout_ms = 60_000; // 1 minute

  /// Maximum clock drift before marking replica as outlier
  /// Used in Marzullo's algorithm for clock synchronization
  /// Replicas with drift > clock_drift_max are excluded from clock samples
  pub const clock_drift_max_ms = 10_000; // 10 seconds

  /// Clock failure timeout (all clocks divergent condition)
  /// If no quorum can be formed even with outlier exclusion for this duration
  pub const clock_failure_timeout_ms = 60_000; // 60 seconds

  /// Normal heartbeat timeout (derived: ping_interval_ms * ping_timeout_count)
  /// When this expires on a backup, it triggers view change
  pub const normal_heartbeat_timeout_ms = ping_interval_ms * ping_timeout_count; // 1000ms
  ```

### Requirement: Hardware Assumptions

The system SHALL document hardware assumptions for performance targets.

#### Scenario: Expected hardware characteristics

- **WHEN** defining hardware assumptions
- **THEN** the following SHALL be documented:
  ```zig
  /// Expected CPU characteristics
  pub const cpu_cores_min = 8;
  pub const cpu_cores_recommended = 16;
  pub const cpu_cores_high_perf = 32;

  /// Expected memory characteristics
  pub const ram_gb_min = 32;
  pub const ram_gb_recommended = 128; // Upgraded for 64-byte aligned index
  pub const ram_gb_high_perf = 256;

  /// Expected disk characteristics (for performance claims)
  pub const disk_sequential_read_gbps = 3; // 3 GB/s
  pub const disk_random_read_latency_us = 100; // 100 μs
  pub const disk_size_min_gb = 500;
  pub const disk_size_recommended_tb = 1;

  /// Expected network characteristics
  pub const network_bandwidth_gbps_min = 1;
  pub const network_bandwidth_gbps_recommended = 10;
  pub const network_latency_same_region_ms = 2; // 2ms same region
  pub const network_latency_cross_az_ms = 10; // 10ms cross-AZ
  ```

### Requirement: Compile-Time Validation

The system SHALL validate all constants at compile time to prevent invalid configurations.

#### Scenario: Constant relationships

- **WHEN** compiling the system
- **THEN** the following validations SHALL occur:
  ```zig
  comptime {
      // Verify batch fits in message
      assert(batch_events_max * geo_event_size < message_body_size_max);

      // Verify journal sizing
      assert(journal_slot_count >= pipeline_max + 2 * checkpoint_interval);

      // Verify block alignment
      assert(block_size % sector_size == 0);
      // Note: events_per_block = (block_size - block_header_size) / geo_event_size
      // This accounts for the 256-byte BlockHeader
      assert(geo_event_size * events_per_block + block_header_size == block_size);

      // Verify quorum intersection (Flexible Paxos)
      // Note: Cannot validate at comptime because replica_count is runtime configurable.
      // Runtime validation: quorum_replication + quorum_view_change > replica_count
      // Example for 5 nodes: 3 + 3 > 5 ✓
      // The defaults (3, 3) work for 3-5 replicas. 6-replica clusters need adjustment.
      // Comptime check: defaults work for minimum production cluster (3 replicas)
      assert(quorum_replication_default + quorum_view_change_default > 3); // min cluster

      // Verify index capacity calculation
      const expected_index_capacity = @divFloor(entities_max_per_node * 100, @as(u64, @intFromFloat(index_load_factor * 100)));
      assert(index_capacity >= expected_index_capacity);

      // Verify ping timeout achieves ≤3s failover target
      const failover_detection_ms = ping_interval_ms * ping_timeout_count;
      const failover_total_ms = failover_detection_ms + view_change_timeout_ms;
      assert(failover_total_ms <= 3000); // ≤3s target (exactly 3s with current values)

      // NEW: Verify superblock_copies is even (required for quorum reads)
      assert(superblock_copies % 2 == 0);

      // NEW: Verify S2 cell level is in valid range
      assert(s2_cell_level >= 1 and s2_cell_level <= 30);

      // NEW: Verify message size is sector-aligned for Direct I/O
      assert(message_size_max % sector_size == 0);

      // NEW: Verify query results fit in message
      const max_result_bytes = query_result_max * geo_event_size;
      assert(max_result_bytes + 1024 < message_body_size_max); // 1024 = overhead

      // Verify LSM table structure: 1 index block + value blocks = level_size_base
      assert(level_size_base == (1 + value_block_count_max) * block_size);

      // Verify LSM configuration ranges
      assert(lsm_levels >= 1 and lsm_levels <= 63);
      assert(lsm_growth_factor > 1);
      assert(lsm_compaction_ops > 0);

      // Verify Level 0 trigger ordering: compaction < slowdown < stop
      assert(lsm_l0_compaction_trigger < lsm_l0_slowdown_trigger);
      assert(lsm_l0_slowdown_trigger < lsm_l0_stop_trigger);

      // Verify backup queue limit ordering: soft < capacity < hard
      assert(backup_queue_soft_limit < backup_queue_capacity);
      assert(backup_queue_capacity < backup_queue_hard_limit);

      // Verify S2 cell level hierarchy (query covering <= storage level)
      assert(s2_cover_max_level <= s2_cell_level);
      assert(s2_cover_min_level < s2_cover_max_level);

      // Verify shard count is power of 2 (efficient modulo via bitmask)
      assert(shard_count > 0 and (shard_count & (shard_count - 1)) == 0);

      // Verify heartbeat timeout derivation is consistent
      assert(normal_heartbeat_timeout_ms == ping_interval_ms * ping_timeout_count);

      // Verify clock failure timeout > clock drift threshold
      assert(clock_failure_timeout_ms > clock_drift_max_ms);
  }
  ```

### Requirement: Configuration Override

The system SHALL allow runtime configuration to override select constants while maintaining safety invariants.

#### Scenario: Format-time configuration

- **WHEN** formatting a new cluster
- **THEN** the following MAY be configured:
  - `replica_count` (1, 3, 5, or 6)
  - `quorum_replication` (must satisfy Flexible Paxos)
  - `quorum_view_change` (must satisfy Flexible Paxos)
  - `entities_max` (must not exceed `entities_max_per_node`)

#### Scenario: Runtime configuration

- **WHEN** starting a replica
- **THEN** the following MAY be configured:
  - `client_timeout_ms` (per-client timeout override)
  - `ping_interval_ms` (network-dependent tuning)
  - `log_level` (debug, info, warn, error)
  - `tls_required` (true/false)

#### Scenario: Immutable configuration

- **WHEN** configuration is set
- **THEN** the following SHALL NOT be changeable after format:
  - `geo_event_size` (breaks disk format)
  - `block_size` (breaks disk format)
  - `s2_cell_level` (breaks spatial indexing)
  - `journal_slot_count` (breaks disk format)

### Related Specifications

- See `specs/data-model/spec.md` for GeoEvent and BlockHeader size requirements (geo_event_size, block_header_size)
- See `specs/storage-engine/spec.md` for block_size, sector_size, and journal_slot_count usage
- See `specs/replication/spec.md` for quorum configuration and Flexible Paxos intersection property
- See `specs/query-engine/spec.md` for batch_events_max, query_result_max, and s2_cover_max_level
- See `specs/hybrid-memory/spec.md` for index_entry_size, index_capacity, and shard_count
- See `specs/memory-management/spec.md` for clients_max, pipeline_max usage in pool sizing
