# System Interfaces Specification

## ADDED Requirements

### Requirement: State Machine Interface

The system SHALL define a clear interface between the VSR replication layer and the query engine state machine.

#### Scenario: State machine function signatures

- **WHEN** VSR invokes the state machine
- **THEN** the following interface SHALL be implemented:
  ```zig
  pub const StateMachine = struct {
      /// Validate operation without executing (before consensus)
      /// Returns: true if valid, false if invalid
      pub fn input_valid(
          self: *StateMachine,
          operation: Operation,
          body: []const u8,
      ) bool;

      /// Prepare operation (primary only, before consensus)
      /// Assigns timestamps and calculates deltas
      /// Returns: timestamp delta for this operation
      pub fn prepare(
          self: *StateMachine,
          operation: Operation,
          body: []const u8,
      ) u64;

      /// Prefetch data needed for execution (after consensus, before execute)
      /// Loads data into cache asynchronously
      /// callback: invoked when prefetch complete
      pub fn prefetch(
          self: *StateMachine,
          callback: *const fn (completion: *Completion) void,
          op: u64,
          operation: Operation,
          body: []const u8,
      ) void;

      /// Execute operation deterministically (after consensus + prefetch)
      /// All replicas MUST produce identical output
      /// output: buffer to write response (from MessagePool)
      /// Returns: bytes written to output
      pub fn commit(
          self: *StateMachine,
          client: u128,
          op: u64,
          timestamp: u64,
          operation: Operation,
          body: []const u8,
          output: []u8,
      ) usize;
  };
  ```

#### Scenario: Operation enum definition

- **WHEN** defining operations
- **THEN** the following SHALL be defined:
  ```zig
  pub const Operation = enum(u16) {
      insert_events = 0x01,
      upsert_events = 0x02,
      delete_entities = 0x03,  // GDPR right to erasure
      query_uuid = 0x10,
      query_radius = 0x11,
      query_polygon = 0x12,
      query_uuid_batch = 0x13,
      ping = 0x20,
      get_status = 0x21,
      cleanup_expired = 0x30,  // TTL cleanup operation
  };
  ```

#### Scenario: Buffer ownership semantics

- **WHEN** state machine functions are called
- **THEN** buffer ownership SHALL be:
  - `body`: Owned by VSR, read-only for state machine, valid until function returns
  - `output`: Owned by VSR, write-only for state machine, valid until function returns
  - State machine MUST NOT retain pointers to these buffers

### Requirement: Primary Index Interface

The system SHALL define a clear interface between the query engine and the hybrid memory index.

#### Scenario: Index function signatures

- **WHEN** query engine accesses the index
- **THEN** the following interface SHALL be implemented:
  ```zig
  pub const PrimaryIndex = struct {
      /// Initialize index with pre-allocated capacity
      pub fn init(allocator: Allocator, capacity: u64) !PrimaryIndex;

      /// Lookup entity by UUID (O(1) hash lookup)
      /// Returns: IndexEntry if found, null if not found
      pub fn lookup(
          self: *const PrimaryIndex,
          entity_id: u128,
      ) ?IndexEntry;

      /// Insert or update entity (LWW semantics)
      /// If entity exists and new_timestamp <= old_timestamp, no-op
      /// Returns: true if inserted/updated, false if timestamp too old
      pub fn upsert(
          self: *PrimaryIndex,
          entity_id: u128,
          file_offset: u64,
          timestamp: u64,
          ttl_seconds: u32,
      ) !bool;

      /// Delete entity from index (GDPR compliance)
      /// Returns: true if deleted, false if not found
      pub fn delete(
          self: *PrimaryIndex,
          entity_id: u128,
      ) bool;

      /// Get statistics for monitoring
      pub fn stats(self: *const PrimaryIndex) IndexStats;

      /// Cleanup resources
      pub fn deinit(self: *PrimaryIndex) void;
  };

  pub const IndexEntry = struct {
      entity_id: u128,
      file_offset: u64,
      timestamp: u64,
      ttl_seconds: u32,  // For expiration checking
      reserved: u32,     // Alignment padding
  };  // 40 bytes total

  pub const IndexStats = struct {
      entry_count: u64,
      capacity: u64,
      load_factor: f32,
      collision_count: u64,
      avg_probe_length: f32,
  };
  ```

#### Scenario: Thread safety

- **WHEN** multiple operations access the index concurrently
- **THEN** the index SHALL provide:
  - Lock-free reads (optimistic concurrent reads)
  - Synchronized writes (only one writer at a time via replica commit ordering)
  - No readers are blocked by writers (RCU-style semantics)

### Requirement: Storage Interface

The system SHALL define a clear interface between the query engine and storage engine.

#### Scenario: Storage function signatures

- **WHEN** query engine reads/writes data
- **THEN** the following interface SHALL be implemented:
  ```zig
  pub const Storage = struct {
      /// Read exactly one GeoEvent from disk
      /// Synchronous read (blocks until complete)
      /// Returns: error if read fails or checksum invalid
      pub fn read_event(
          self: *Storage,
          file_offset: u64,
          event: *GeoEvent,
      ) !void;

      /// Read multiple GeoEvents (range scan)
      /// Asynchronous read with callback
      pub fn read_events_async(
          self: *Storage,
          callback: *const fn (completion: *Completion) void,
          start_offset: u64,
          count: u32,
          output_buffer: []GeoEvent,
      ) void;

      /// Write batch of events (append-only)
      /// Returns: file offset where batch was written
      pub fn write_events(
          self: *Storage,
          events: []const GeoEvent,
      ) !u64;

      /// Sync data to disk (fsync)
      pub fn sync(self: *Storage) !void;
  };
  ```

#### Scenario: Async completion

- **WHEN** async operations complete
- **THEN** the completion callback SHALL be invoked with:
  ```zig
  pub const Completion = struct {
      /// User-provided context
      context: *anyopaque,

      /// Operation result (error or success)
      result: StorageError!void,

      /// Number of events successfully read (for read_events_async)
      events_read: u32,
  };
  ```

### Requirement: S2 Geometry Interface

The system SHALL define a clear interface to S2 spatial indexing functions.

#### Scenario: S2 function signatures

- **WHEN** query engine uses S2 functions
- **THEN** the following interface SHALL be implemented:
  ```zig
  pub const S2 = struct {
      /// Convert lat/lon to S2 cell ID
      pub fn lat_lon_to_cell_id(
          lat_nano: i64,
          lon_nano: i64,
          level: u8,
      ) u64;

      /// Convert S2 cell ID back to lat/lon (cell center)
      pub fn cell_id_to_lat_lon(
          cell_id: u64,
      ) struct { lat_nano: i64, lon_nano: i64 };

      /// Get parent cell (one level up)
      pub fn get_parent(cell_id: u64) u64;

      /// Get child cells (one level down)
      pub fn get_children(cell_id: u64) [4]u64;

      /// Cover polygon with cells (RegionCoverer)
      /// Returns: fixed-size array of cell ranges (bounded by s2_max_cells)
      /// Uses static allocation - no runtime memory allocation
      pub fn cover_polygon(
          vertices: []const LatLon,
          min_level: u8,
          max_level: u8,
      ) ![16]CellRange;  // Fixed size = s2_max_cells constant

      /// Cover circle (radius query)
      /// Returns: fixed-size array of cell ranges (bounded by s2_max_cells)
      /// Uses static allocation - no runtime memory allocation
      pub fn cover_cap(
          center_lat_nano: i64,
          center_lon_nano: i64,
          radius_mm: u32,
          min_level: u8,
          max_level: u8,
      ) ![16]CellRange;  // Fixed size = s2_max_cells constant

      /// Test if point is inside polygon (post-filter)
      pub fn point_in_polygon(
          point: LatLon,
          polygon: []const LatLon,
      ) bool;

      /// Calculate great-circle distance (Haversine)
      /// Returns: distance in millimeters
      pub fn distance(
          lat1_nano: i64,
          lon1_nano: i64,
          lat2_nano: i64,
          lon2_nano: i64,
      ) u64;
  };

  pub const LatLon = struct {
      lat_nano: i64,
      lon_nano: i64,
  };

  pub const CellRange = struct {
      start: u64, // Inclusive
      end: u64,   // Exclusive
  };
  ```

### Requirement: Message Bus Interface

The system SHALL define a clear interface between I/O subsystem and VSR.

#### Scenario: Message bus function signatures

- **WHEN** VSR sends/receives messages
- **THEN** the following interface SHALL be implemented:
  ```zig
  pub const MessageBus = struct {
      /// Send message to a specific replica or client
      /// Returns immediately (async send)
      pub fn send(
          self: *MessageBus,
          connection_id: u32,
          message: *Message,
      ) void;

      /// Register callback for incoming messages
      pub fn on_message(
          self: *MessageBus,
          callback: *const fn (
              connection_id: u32,
              message: *const Message,
          ) void,
      ) void;

      /// Register callback for connection events
      pub fn on_connection_event(
          self: *MessageBus,
          callback: *const fn (
              connection_id: u32,
              event: ConnectionEvent,
          ) void,
      ) void;
  };

  pub const ConnectionEvent = enum {
      connected,
      disconnected,
      error_occurred,
  };
  ```

#### Scenario: Message ownership

- **WHEN** messages are sent/received
- **THEN** ownership SHALL be:
  - Sender acquires message from MessagePool
  - Sender passes ownership to MessageBus via send()
  - MessageBus releases message after send complete
  - Receiver gets read-only access to message in callback
  - Receiver MUST NOT retain message pointer after callback returns

### Requirement: Error Propagation

The system SHALL define how errors propagate through the system layers.

#### Scenario: Error types per layer

- **WHEN** errors occur
- **THEN** they SHALL be categorized by layer:
  ```zig
  pub const ClientProtocolError = error{
      InvalidOperation,
      InvalidDataSize,
      ChecksumMismatch,
      TooMuchData,
      SessionExpired,
      Timeout,
  };

  pub const QueryEngineError = error{
      InvalidCoordinates,
      PolygonTooComplex,
      QueryResultTooLarge,
      InvalidS2Cell,
      RadiusTooLarge,
      EntityNotFound,
      IndexCapacityExceeded,
  };

  pub const StorageError = error{
      DiskReadFailed,
      DiskWriteFailed,
      ChecksumMismatch,
      OutOfSpace,
      CorruptData,
  };

  pub const ReplicationError = error{
      ClusterUnavailable,
      ViewChangeInProgress,
      ReplicaLagging,
      NotPrimary,
  };
  ```

#### Scenario: Error conversion strategy

- **WHEN** an error occurs in a lower layer
- **THEN** it SHALL be converted to appropriate higher-layer error:
  - **Storage checksum mismatch** → PANIC (data corruption is unrecoverable)
  - **Storage read I/O error** → Retry 3 times, then return `timeout` to client
  - **Storage write I/O error** → Retry 3 times, then return `timeout` to client
  - **Storage disk full** → Return `out_of_space` (operational alert)
  - **Index capacity exceeded** → Return `index_capacity_exceeded` (client error)
  - **Index degraded** → Log alert, continue operation, return error on affected operation
  - **View change in progress** → Return `view_change_in_progress` (client retries)
  - **Not primary** → Return `not_primary` with primary_id hint (client redirects)
  - **Quorum lost** → Return `cluster_unavailable` (client backs off)

#### Scenario: Panic vs error return

- **WHEN** deciding between panic and error return
- **THEN** the system SHALL:
  - **PANIC** for data corruption (checksum mismatch, invalid state) - safety first
  - **RETURN ERROR** for transient failures (I/O errors, timeouts) - recoverable
  - **RETURN ERROR** for client errors (invalid input, capacity limits) - user fixable
- **AND** panics trigger process restart and cluster failover
- **AND** errors are returned to client for handling

### Requirement: Buffer Pool Interface

The system SHALL define how buffers are acquired and released.

#### Scenario: Buffer pool function signatures

- **WHEN** operations need temporary buffers
- **THEN** the following interface SHALL be used:
  ```zig
  pub const MessagePool = struct {
      /// Acquire message buffer from pool
      /// Blocks if pool exhausted (bounded wait)
      pub fn acquire(self: *MessagePool) *Message;

      /// Release message back to pool
      /// Decrements reference count, returns to pool when zero
      pub fn release(self: *MessagePool, message: *Message) void;

      /// Increment reference count (multiple owners)
      pub fn ref(self: *MessagePool, message: *Message) void;

      /// Get pool statistics
      pub fn stats(self: *const MessagePool) PoolStats;
  };

  pub const PoolStats = struct {
      total_messages: u32,
      available_messages: u32,
      in_use_messages: u32,
      peak_usage: u32,
      acquire_wait_count: u64,
  };
  ```

#### Scenario: Reference counting

- **WHEN** a message is shared between multiple subsystems
- **THEN** reference counting SHALL be used:
  - Initial acquire() sets ref_count = 1
  - ref() increments ref_count
  - release() decrements ref_count
  - When ref_count reaches 0, message returns to pool

### Requirement: Timestamp Interface

The system SHALL define how timestamps are managed across the system.

#### Scenario: Timestamp source

- **WHEN** timestamps are needed
- **THEN** they SHALL come from:
  ```zig
  pub const Clock = struct {
      /// Get current monotonic timestamp (nanoseconds)
      /// Uses CLOCK_MONOTONIC on Linux
      pub fn now_monotonic() u64;

      /// Get wall clock timestamp (nanoseconds since epoch)
      /// Uses synchronized cluster time (Marzullo's algorithm)
      pub fn now_synchronized() u64;

      /// Convert monotonic to wall clock (for logging)
      pub fn monotonic_to_wall(mono: u64) u64;
  };
  ```

#### Scenario: Timestamp usage

- **WHEN** components need timestamps
- **THEN** they SHALL use:
  - `now_monotonic()` for timeouts, intervals, deltas (always increasing)
  - `now_synchronized()` for GeoEvent timestamps (cluster-wide comparable)
  - State machine uses VSR-assigned timestamps (not current time)

### Requirement: Configuration Interface

The system SHALL define how configuration is accessed.

#### Scenario: Configuration structure

- **WHEN** components need configuration
- **THEN** they SHALL access via:
  ```zig
  pub const Config = struct {
      // From constants.zig (compile-time)
      message_size_max: u32,
      batch_events_max: u32,
      checkpoint_interval: u32,
      // ... all constants

      // From command line / config file (runtime)
      replica_id: u8,
      replica_count: u8,
      quorum_replication: u8,
      quorum_view_change: u8,
      replica_addresses: []const std.net.Address,
      tls_required: bool,
      tls_cert_path: ?[]const u8,
      tls_key_path: ?[]const u8,
      tls_ca_path: ?[]const u8,
      log_level: LogLevel,
      log_format: LogFormat,
      data_file_path: []const u8,
      metrics_port: u16,
  };
  ```

#### Scenario: Configuration validation

- **WHEN** configuration is loaded
- **THEN** it SHALL be validated:
  - Flexible Paxos: quorum_replication + quorum_view_change > replica_count
  - Replica ID: 0 <= replica_id < replica_count
  - TLS: if tls_required, all cert paths must be valid
  - File paths: data_file_path must exist (or parent dir writable)
