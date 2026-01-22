# Architecture

**Analysis Date:** 2026-01-22

## Pattern Overview

**Overall:** Replicated state machine with consensus (Viewstamped Replication) + LSM-tree storage + geospatial extensions

**Key Characteristics:**
- Distributed consensus via VSR (Viewstamped Replication) protocol for strong consistency
- LSM-tree storage engine optimized for append-heavy geospatial workloads
- Three-phase operation execution: prepare (timestamp), prefetch (async I/O), commit (deterministic)
- Geospatial-specific state machine with S2 indexing and RAM entity index
- Client/server architecture with multi-language SDK support

## Layers

**VSR Consensus Layer:**
- Purpose: Distributed consensus and replication protocol
- Location: `src/vsr/`
- Contains: Replica state machine, client sessions, journal, message passing, membership
- Depends on: Storage layer, I/O layer, message bus
- Used by: State machine layer, client SDKs
- Key files: `src/vsr/replica.zig`, `src/vsr/client.zig`, `src/vsr/journal.zig`

**State Machine Layer:**
- Purpose: Geospatial operation execution and business logic
- Location: `src/geo_state_machine.zig`, `src/archerdb.zig`
- Contains: GeoEvent operations (insert, query, delete), operation dispatch, result handling
- Depends on: LSM storage, RAM index, S2 index, TTL management
- Used by: VSR replica (commit pipeline)
- Key abstractions: `GeoStateMachineType`, `Operation` enum, three-phase execution model

**Storage Layer:**
- Purpose: Persistent LSM-tree storage and grid-based block management
- Location: `src/lsm/`, `src/vsr/grid.zig`, `src/storage.zig`
- Contains: Forest (multi-tree LSM), compaction, manifest, free set, checkpoint/snapshot
- Depends on: I/O layer, platform storage primitives
- Used by: State machine (via Forest grooves)
- Key files: `src/lsm/forest.zig`, `src/lsm/tree.zig`, `src/vsr/grid.zig`

**Indexing Layer:**
- Purpose: Fast geospatial and entity lookups
- Location: `src/ram_index.zig`, `src/s2_index.zig`
- Contains: In-memory entity index (latest positions), S2 spatial index for geoqueries
- Depends on: S2 geometry library
- Used by: State machine for query operations
- Pattern: RAM index for O(1) entity lookups, S2 cells for spatial partitioning

**I/O Layer:**
- Purpose: Platform-specific async I/O operations
- Location: `src/io.zig`, `src/io/`
- Contains: Platform abstractions (linux, darwin, windows), direct I/O, async operations
- Depends on: OS system calls (io_uring on Linux, kqueue on Darwin)
- Used by: Storage, message bus, network transport

**Client SDK Layer:**
- Purpose: Language-specific client libraries
- Location: `src/clients/`
- Contains: C, Go, Java, Node.js, Python SDKs
- Depends on: C client core (`src/clients/c/arch_client.zig`)
- Used by: External applications
- Pattern: Zig C client as foundation, native bindings for other languages

**Messaging/RPC Layer:**
- Purpose: Network communication between replicas and clients
- Location: `src/message_bus.zig`, `src/message_pool.zig`, `src/message_buffer.zig`
- Contains: Message routing, pooling, serialization
- Depends on: I/O layer
- Used by: VSR replica, client

## Data Flow

**Write Path (Insert/Upsert GeoEvent):**

1. Client SDK sends request to any replica
2. Replica receives via MessageBus → routes to primary if not primary
3. Primary executes prepare() → assigns timestamp (primary-only, before consensus)
4. VSR consensus: primary broadcasts prepare → collects quorum → commits
5. State machine prefetch() → loads required LSM data into cache (async)
6. State machine commit() → applies changes (deterministic, post-consensus):
   - Update RAM index with latest position
   - Insert tombstone if upserting (marks old versions)
   - Generate LSM tree mutations
7. Forest.grooves.geo_events.insert() → LSM tree append
8. Reply sent to client via MessageBus

**Read Path (Geospatial Query):**

1. Client sends query (radius, polygon, UUID, latest)
2. For UUID query: RAM index lookup (O(1)) → return if found
3. For spatial query: S2 index determines cell ranges
4. Forest scan: LSM tree range scan across relevant S2 cells
5. Post-filter: geometric containment check, TTL filtering
6. Results aggregated and returned (up to limit)

**Compaction Flow:**

1. Triggered every `lsm_compaction_ops` commits
2. CompactionPipeline selects levels and tables
3. K-way merge of overlapping tables
4. Tombstone elimination (via `should_copy_forward()` logic)
5. New table blocks written to grid
6. Manifest updated with new table metadata
7. Old blocks added to free set for reclamation

**Checkpoint Flow:**

1. Triggered every `vsr_checkpoint_ops` commits
2. SuperBlock checkpoint commenced
3. Parallel checkpoint of: AOF, state machine, client sessions/replies, grid
4. RAM index serialized to checkpoint blocks
5. Forest manifest checkpoint
6. SuperBlock updated with checkpoint metadata
7. Checkpoint committed to quorum of replicas

## Key Abstractions

**GeoEvent:**
- Purpose: Core geospatial event record
- Examples: `src/geo_event.zig`
- Pattern: Extern struct (128 bytes), entity_id + lat/lon + timestamp + metadata + flags

**Operation:**
- Purpose: Enum of all supported operations
- Examples: `src/archerdb.zig` (Operation enum)
- Pattern: Typed dispatch with `EventType()` and `ResultType()` comptime functions

**Forest/Groove:**
- Purpose: LSM-tree collection abstraction
- Examples: `src/lsm/forest.zig`, `src/lsm/groove.zig`
- Pattern: Forest contains multiple Grooves (object trees + indexes), comptime-configured

**Replica:**
- Purpose: VSR consensus participant
- Examples: `src/vsr/replica.zig`
- Pattern: State machine with Status enum (normal, view_change, recovering), commit pipeline

**MessageBus:**
- Purpose: Network transport abstraction
- Examples: `src/message_bus.zig`
- Pattern: Async message passing with pools and buffers

## Entry Points

**Server (Replica):**
- Location: `src/archerdb/main.zig`
- Triggers: `./archerdb start` or `./archerdb format`
- Responsibilities: Parse CLI, initialize replica, start event loop, handle signals

**Client SDK (C):**
- Location: `src/clients/c/arch_client.zig`, `src/clients/c/arch_client_exports.zig`
- Triggers: Application calls `arch_init()` from C/FFI
- Responsibilities: Initialize client context, manage packet lifecycle, handle callbacks

**Testing/Simulation (VOPR):**
- Location: `src/vopr.zig`
- Triggers: `./zig/zig build vopr`
- Responsibilities: Deterministic simulation, fault injection, correctness testing

**Build System:**
- Location: `build.zig`
- Triggers: `./zig/zig build`
- Responsibilities: Compile all targets, run tests, generate client libraries

## Error Handling

**Strategy:** Explicit error codes + state machine error enums + panic on invariant violations

**Patterns:**
- State machine returns `StateError` enum for operation failures (NOT_FOUND, INVALID_TIMESTAMP, etc.)
- VSR consensus uses assertions for invariant violations (should never happen in correct code)
- I/O operations return error unions (`!void`, `!usize`)
- Client SDKs expose error codes via status enums

**Error propagation:**
- State machine commit() returns results with embedded error status
- VSR replica panics on protocol violations (safety over liveness)
- Client SDK callbacks receive status codes

## Cross-Cutting Concerns

**Logging:**
- Scoped loggers via `std.log.scoped(.name)`
- Runtime log level control
- Structured JSON or text format
- Rotating log files in production

**Validation:**
- Comptime checks via `comptime assert()`
- Runtime validation in state machine prepare()
- GeoEvent field validation (lat/lon ranges, timestamp ordering)
- Checksum validation for messages and blocks

**Authentication:**
- Client sessions managed by VSR replica
- TLS/encryption via `src/encryption.zig`, `src/archerdb/tls_config.zig`
- Session eviction for LRU cleanup

**Metrics:**
- Prometheus-compatible metrics via `src/archerdb/metrics.zig`
- Per-operation counters, latency histograms
- StatsD export support
- Deletion/tombstone metrics for GDPR compliance

**Sharding:**
- Consistent hashing via `src/sharding.zig`
- Entity ID → shard bucket mapping
- Coordinator/proxy for fan-out queries (`src/coordinator.zig`)

**Replication:**
- Async multi-region replication via `src/replication.zig`
- WAL shipping from primary to followers
- Eventual consistency for follower regions

---

*Architecture analysis: 2026-01-22*
