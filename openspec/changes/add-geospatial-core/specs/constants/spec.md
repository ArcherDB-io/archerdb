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
  ```

### Requirement: VSR and Replication Constants

The system SHALL define constants for the VSR consensus protocol.

#### Scenario: Journal and checkpoint constants

- **WHEN** defining VSR constants
- **THEN** the following SHALL be defined:
  ```zig
  /// Number of slots in the journal (WAL ring buffer)
  pub const journal_slot_count = 1024;

  /// Operations between checkpoints (CRITICAL: referenced everywhere)
  /// Must satisfy: journal_slot_count >= pipeline_max + 2 * checkpoint_interval
  pub const checkpoint_interval = 256;

  /// Maximum operations in pipeline (in-flight operations)
  pub const pipeline_max = 256;

  /// Verify journal sizing
  comptime {
      assert(journal_slot_count >= pipeline_max + 2 * checkpoint_interval);
      // 1024 >= 256 + 2 * 256 = 768 ✓
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
  pub const client_sessions_max = 128;

  /// Maximum concurrent grid read IOPS (bounds disk read parallelism)
  pub const grid_iops_read_max = 128;

  /// Maximum concurrent grid write IOPS (bounds disk write parallelism)
  pub const grid_iops_write_max = 64;

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

  /// Minimum S2 cell level for covering
  pub const s2_min_level = 10;

  /// Maximum S2 cell level for covering
  pub const s2_max_level = s2_cell_level;
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

  /// Index entry size (includes ttl_seconds field)
  pub const index_entry_size = 40; // bytes

  /// Index memory requirement (40 bytes per slot)
  pub const index_memory_bytes = index_capacity * index_entry_size; // ~57.2GB

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
  /// Ping interval for liveness detection (aggressive for <3s failover)
  pub const ping_interval_ms = 250; // 250ms

  /// Ping timeout (missed pings before view change)
  pub const ping_timeout_count = 4; // 4 missed = 1 second

  /// View change timeout
  pub const view_change_timeout_ms = 2000; // 2 seconds

  /// Client operation timeout (default)
  pub const client_timeout_default_ms = 5000; // 5 seconds

  /// Index checkpoint interval (time-based)
  pub const index_checkpoint_interval_ms = 60_000; // 1 minute
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
  pub const ram_gb_recommended = 64;
  pub const ram_gb_high_perf = 128;

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

      // Verify ping timeout achieves <3s failover target
      const failover_detection_ms = ping_interval_ms * ping_timeout_count;
      const failover_total_ms = failover_detection_ms + view_change_timeout_ms;
      assert(failover_total_ms <= 3000); // <3s target

      // NEW: Verify superblock_copies is even (required for quorum reads)
      assert(superblock_copies % 2 == 0);

      // NEW: Verify S2 cell level is in valid range
      assert(s2_cell_level >= 1 and s2_cell_level <= 30);

      // NEW: Verify index entry size matches struct (catch struct changes)
      assert(@sizeOf(IndexEntry) == index_entry_size);

      // NEW: Verify message size is sector-aligned for Direct I/O
      assert(message_size_max % sector_size == 0);

      // NEW: Verify query results fit in message
      const max_result_bytes = query_result_max * geo_event_size;
      assert(max_result_bytes + 1024 < message_body_size_max); // 1024 = overhead
  }
  ```

### Requirement: Configuration Override

The system SHALL allow runtime configuration to override select constants while maintaining safety invariants.

#### Scenario: Format-time configuration

- **WHEN** formatting a new cluster
- **THEN** the following MAY be configured:
  - `replica_count` (3, 5, or 6)
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
