# Architecture

**Analysis Date:** 2026-01-29

## Pattern Overview

**Overall:** Viewstamped Replication (VSR) consensus-based distributed geospatial database with LSM-tree storage and deterministic state machine replication.

**Key Characteristics:**
- **Consensus Protocol**: VSR (Viewstamped Replication) for strong linearizable consistency across replicas
- **State Machine Replication**: Deterministic geospatial state machine executed identically on all replicas
- **Storage Engine**: LSM-tree optimized for append-heavy geospatial workloads with tiered levels
- **Spatial Indexing**: Google S2 geometry library for efficient radius and polygon queries
- **In-Memory Index**: RAM-resident entity index for sub-microsecond latest-position lookups
- **Durability**: Multi-level persistence including write-ahead logging (journal) and grid storage with checksums

## Layers

**Consensus & Replication (`src/vsr/`):**
- Purpose: Ensure all replicas agree on operation order and maintain linearizable consistency
- Location: `src/vsr/replica.zig` (core replica state machine), `src/vsr/client.zig` (client protocol), `src/vsr/flexible_paxos.zig` (Flexible Paxos voting)
- Contains: Replica coordination, prepare/commit phases, view changes, client session management, message routing
- Depends on: Message bus, storage, grid, journal
- Used by: State machine, clients, persistence layer

**State Machine (`src/geo_state_machine.zig`, `src/archerdb.zig`):**
- Purpose: Execute geospatial operations deterministically in response to replicated log entries
- Location: `src/geo_state_machine.zig` (core logic), `src/archerdb.zig` (type definitions)
- Contains: GeoEvent insertion/querying, TTL expiration, entity deletion (GDPR compliance), topology discovery
- Depends on: LSM forest, RAM index, S2 spatial index, validation logic
- Used by: Replica consensus layer, clients

**Storage Engine (`src/lsm/`):**
- Purpose: Provide durable, sorted storage optimized for geospatial data with efficient range scans
- Location: `src/lsm/tree.zig` (LSM tree structure), `src/lsm/forest.zig` (multi-tree collection), `src/lsm/groove.zig` (per-tree state)
- Contains: Mutable/immutable table management, compaction (multiple strategies), manifest log, compression (LZ4), schema definition
- Depends on: Grid storage, manifest, compaction strategies
- Used by: State machine, persistent storage

**Spatial Indexing (`src/s2_index.zig`, `src/s2/`):**
- Purpose: Enable efficient spatial queries (radius, polygon) using Hilbert curve ordering
- Location: `src/s2_index.zig` (main index), `src/s2/` (S2 geometry library)
- Contains: S2 cell covering, spatial range lookups, polygon intersection tests
- Depends on: S2 library (vendored), LSM tree
- Used by: State machine for radius/polygon queries

**RAM Index (`src/ram_index.zig`):**
- Purpose: Provide O(1) latest-position lookups in memory for sub-microsecond query performance
- Location: `src/ram_index.zig` (RAM index implementation), `src/index/checkpoint.zig` (checkpoint coordination)
- Contains: Hash table of entity IDs to latest positions, TTL integration, memory-mapped mode support, checkpoint/restore
- Depends on: Allocation, TTL module
- Used by: State machine for latest entity position queries

**Persistence & Durability (`src/vsr/grid.zig`, `src/vsr/journal.zig`, `src/vsr/superblock.zig`):**
- Purpose: Ensure data survives failures through redundancy and checksums
- Location: `src/vsr/grid.zig` (block grid), `src/vsr/journal.zig` (write-ahead log), `src/vsr/superblock.zig` (metadata)
- Contains: Grid block allocation, journal entry sequencing, superblock versioning, checksum streams, free set tracking
- Depends on: I/O abstraction, storage backend
- Used by: Replica, state machine, compaction

**Message Bus & Communication (`src/message_bus.zig`, `src/message_pool.zig`):**
- Purpose: Manage message routing between replicas and clients with connection pooling
- Location: `src/message_bus.zig` (routing and protocol handling), `src/message_pool.zig` (message allocation)
- Contains: TCP/UDP message dispatch, connection management, message framing and checksums
- Depends on: I/O subsystem
- Used by: Replica consensus, client protocol

**I/O Abstraction (`src/io.zig`, `src/io/linux.zig`, `src/io/darwin.zig`):**
- Purpose: Platform-independent async I/O interface (io_uring on Linux, kevent on macOS)
- Location: `src/io.zig` (common interface), `src/io/linux.zig` (Linux io_uring), `src/io/darwin.zig` (macOS kevent)
- Contains: File operations, network operations, timer management, platform-specific optimizations
- Depends on: OS APIs
- Used by: Grid, journal, message bus, storage

**CLI & Server (`src/archerdb/cli.zig`, `src/archerdb/main.zig`):**
- Purpose: Command-line interface for server startup, data formatting, and operations
- Location: `src/archerdb/cli.zig` (command parsing), `src/archerdb/main.zig` (server entry point)
- Contains: Subcommands (format, start, inspect, aof), flag parsing, configuration loading
- Depends on: Replica, storage, observability
- Used by: Binary entry point

## Data Flow

**Insert GeoEvent Operation:**

1. Client sends `insert_events` request to primary replica
2. Replica (VSR layer) assigns operation number and broadcasts Prepare message to all backups
3. Backups acknowledge with Prepare OK (quorum reached after 2 acknowledgments)
4. Primary commits operation (now durable - survives any single replica failure)
5. State machine executes operation:
   - Validates GeoEvent (timestamp, coordinates, entity UUID)
   - Updates RAM index with latest position
   - Inserts tombstone or event into LSM mutable table (in-memory)
   - Updates S2 spatial index entries
   - Increments metrics
6. Mutable table fills; immutable table is flushed to disk (grid storage) once it reaches size limit
7. LSM compaction runs continuously to reorganize levels and optimize range queries
8. State persisted across checkpoints: RAM index checkpoint, LSM manifest, superblock
9. Client receives reply with operation number and result

**Query Radius or Polygon:**

1. Client sends radius/polygon query request to any replica (can read from backup)
2. State machine executes on that replica:
   - S2 library computes cell covering for radius/polygon
   - LSM range scan looks up GeoEvents in cell ranges
   - Post-filter validates actual distances/containment
   - RAM index provides latest position confirmations
   - Results accumulated and returned
3. Client receives consistent snapshot of matching entities

**State Management:**
- **Consensus Guarantee**: All replicas apply operations in identical order via VSR - ensures deterministic state
- **Crash Recovery**: On restart, replica reads superblock to find last checkpoint, then applies journal entries from checkpoint onwards
- **View Change**: If primary fails, backups elect new primary within seconds using DoViewChange protocol; new primary uses quorum recovery to find highest committed operations
- **Compaction**: Runs asynchronously in background; doesn't block client requests; creates new levels with older data

## Key Abstractions

**GeoEvent:**
- Purpose: Represents a location update event for an entity at a point in time
- Examples: `src/geo_event.zig`, `src/archerdb.zig` (GeoEvent type definition)
- Pattern: Extern struct with fixed 32-byte layout (no padding) for wire/storage efficiency; contains entity UUID, timestamp, coordinates (lat/long as S2 cell), flags (deleted, duplicate)

**Operation:**
- Purpose: Encapsulates client-requested work (insert, query, delete, TTL) with serialization
- Examples: `src/geo_state_machine.zig` (Operation enum with variants), `src/vsr/message_header.zig` (operation encoding)
- Pattern: Enum with separate request/response types; serialized in message payloads

**Message (VSR Protocol):**
- Purpose: Carries consensus protocol messages between replicas and clients
- Examples: `src/message_pool.zig` (message pool management), `src/message_bus.zig` (routing), `src/vsr/message_header.zig` (header structure)
- Pattern: Fixed-size headers with variable-length bodies; checksummed; released back to pool after processing

**Table (LSM):**
- Purpose: Sorted collection of key-value pairs within a level
- Examples: `src/lsm/table.zig`, `src/lsm/manifest_level.zig` (table metadata)
- Pattern: Memtable in memory or TableMemory; disk table loaded on demand; organized by level (L0=newest, L_max=oldest)

**Manifest (LSM):**
- Purpose: Persistent metadata tracking which tables exist at each level
- Examples: `src/lsm/manifest.zig`, `src/lsm/manifest_log.zig` (manifest log durability)
- Pattern: In-memory manifest validated against manifest log; persisted after each compaction; enables recovery

**Forest:**
- Purpose: Container for all LSM trees in the database (per-table in multi-table schema)
- Examples: `src/lsm/forest.zig`, `src/lsm/groove.zig` (per-tree groove)
- Pattern: Holds collection of trees (grooves); coordinates compaction across trees; maintains forest-wide manifest

**Replica:**
- Purpose: Core consensus participant managing state, journal, and consensus protocol
- Examples: `src/vsr/replica.zig` (main implementation)
- Pattern: Type-parameterized on StateMachine, MessageBus, Storage, AOF; holds reference to grid, superblock, forest, client sessions

## Entry Points

**Server (`src/archerdb/main.zig`):**
- Location: `src/archerdb/main.zig` (pub fn main)
- Triggers: Binary execution with command-line arguments
- Responsibilities: Parse CLI, initialize IO, create replica, event loop, graceful shutdown

**CLI Commands (`src/archerdb/cli.zig`):**
- Location: `src/archerdb/cli.zig` (subcommand parsing)
- Triggers: `./archerdb format`, `./archerdb start`, `./archerdb inspect`, `./archerdb aof`
- Responsibilities: Validate arguments, delegate to appropriate handler function

**Client Request (`src/vsr/client.zig`):**
- Location: `src/vsr/client.zig` (ClientType)
- Triggers: Client sends request message on socket
- Responsibilities: Serialize/deserialize operations, manage client session, retry logic

**VOPR (Deterministic Testing) (`src/vopr.zig`):**
- Location: `src/vopr.zig` (pub fn main)
- Triggers: `./zig/zig build vopr -- [seed]`
- Responsibilities: Run deterministic simulation of replica cluster with fault injection

## Error Handling

**Strategy:** All errors explicitly encoded in operation results; no panics in hot paths.

**Patterns:**
- **Operation Results**: Each operation returns a result struct with status code (ok, exists, not_found, etc.) - see `src/error_codes.zig`
- **Validation Errors**: GeoEvent validation occurs in state machine; invalid events return error status
- **IO Errors**: Grid reads/writes may fail; retried with exponential backoff; replica tracks repair budget
- **Consensus Errors**: View change initiates if primary becomes unavailable; quorum recovery finds highest committed operations
- **Resource Exhaustion**: RAM index overflow, grid free set depletion cause throttling and load shedding

## Cross-Cutting Concerns

**Logging:**
- Approach: Structured logging via `std.log` module; scoped by component (e.g., `.replica`, `.state_machine`, `.lsm`)
- Levels: Error, warn, info, debug; runtime configurable via `--log-level` CLI flag
- Format: Text (default) or JSON via `--log-format` flag; file or stdout

**Validation:**
- Approach: GeoEvent validation in state machine prefetch phase; coordinate/timestamp bounds checking; UUID validation
- Components: `src/geo_state_machine.zig` (prefetch validates operations), `src/geo_event.zig` (GeoEvent structure validation)

**Authentication:**
- Approach: Client session identification via UUID; no separate auth mechanism (clients trusted at network level)
- Components: `src/vsr/client_sessions.zig` (session tracking), `src/vsr/client.zig` (session management)

**Encryption:**
- Approach: TLS for transport encryption; at-rest encryption via XORing with per-block cipher key
- Components: `src/encryption.zig` (cipher primitives), message bus TLS handshake

**Observability:**
- Approach: Prometheus metrics, distributed tracing (Tracy profiler integration), structured logs
- Components: `src/archerdb/metrics.zig`, `src/archerdb/cluster_metrics.zig`, `src/trace.zig`

---

*Architecture analysis: 2026-01-29*
