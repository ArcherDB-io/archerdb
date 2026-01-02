# Tasks: Add Geospatial Core

## CRITICAL: Implementation Strategy - Fork TigerBeetle

> **DO NOT BUILD FROM SCRATCH.** This project SHALL be implemented by forking TigerBeetle.
> See `specs/implementation-guide/spec.md` for complete rationale and instructions.

### Fork Strategy Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    TIGERBEETLE FORK STRATEGY                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   KEEP (~70%)              REPLACE (~20%)           ADD (~10%)              │
│   ─────────────            ──────────────           ────────────            │
│   ✅ src/vsr/*             🔄 src/tigerbeetle.zig   ➕ src/ram_index.zig    │
│   ✅ src/lsm/*             🔄 src/state_machine.zig ➕ src/s2/*             │
│   ✅ src/io/*              🔄 src/clients/*         ➕ src/s2_index.zig     │
│   ✅ src/storage.zig       🔄 Account → GeoEvent    ➕ src/ttl.zig          │
│   ✅ src/message_pool.zig  🔄 Transfer → Query      ➕ Golden vector tests  │
│   ✅ src/simulator.zig                                                       │
│   ✅ src/stdx.zig                                                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase F0: Fork & Foundation (Weeks 1-6)

**Goal:** Fork TigerBeetle, establish development environment, team ramp-up

### F0.1 Repository Setup
- [ ] F0.1.1 Fork TigerBeetle: `git clone https://github.com/tigerbeetle/tigerbeetle.git archerdb`
- [ ] F0.1.2 Rename project references (tigerbeetle → archerdb)
- [ ] F0.1.3 Verify build: `zig build` succeeds
- [ ] F0.1.4 Run existing tests: `zig build test` passes
- [ ] F0.1.5 Run VOPR simulator: `zig build vopr` works
- [ ] F0.1.6 Set up CI/CD pipeline for forked repository
- [ ] F0.1.7 Document all modifications in CHANGELOG.md

### F0.2 Team Ramp-Up (CRITICAL - Do Not Skip)
- [ ] F0.2.1 All engineers read `src/vsr/replica.zig` thoroughly
- [ ] F0.2.2 All engineers can explain VSR message flow (Prepare → PrepareOk → Commit)
- [ ] F0.2.3 All engineers can describe checkpoint sequence (grid → fsync → superblock → fsync)
- [ ] F0.2.4 All engineers understand state machine interface (prepare/prefetch/commit)
- [ ] F0.2.5 Document team's understanding in internal wiki
- [ ] F0.2.6 Identify TigerBeetle patterns that will be reused verbatim

### F0.3 GeoEvent Struct Definition
- [ ] F0.3.1 Create `src/geo_event.zig` with 128-byte `GeoEvent` extern struct
- [ ] F0.3.2 Match TigerBeetle's Account struct size (128 bytes) for compatibility
- [ ] F0.3.3 Add comptime assertions: `@sizeOf == 128`, `@alignOf == 16`, `no_padding()`
- [ ] F0.3.4 Define `GeoEventFlags` as packed struct(u32)
- [ ] F0.3.5 Implement `pack_id(s2_cell, timestamp) -> u128` helper
- [ ] F0.3.6 Write comptime layout tests

**Exit Criteria:**
- [ ] `zig build` succeeds with renamed entry points
- [ ] All team members pass VSR knowledge check
- [ ] GeoEvent struct compiles with correct layout

---

## Phase F1: State Machine Replacement (Weeks 7-14)

**Goal:** Replace TigerBeetle's Account/Transfer state machine with GeoEvent

### F1.1 State Machine Core
- [ ] F1.1.1 Create `src/archerdb.zig` (copy structure from `src/tigerbeetle.zig`)
- [ ] F1.1.2 Create `src/geo_state_machine.zig` implementing StateMachine interface
- [ ] F1.1.3 Implement `prepare()` for GeoEvent validation
- [ ] F1.1.4 Implement `prefetch()` for async I/O (initially empty)
- [ ] F1.1.5 Implement `commit()` for deterministic execution
- [ ] F1.1.6 Implement `compact()` for checkpoint integration
- [ ] F1.1.7 Implement `open()` for recovery

### F1.2 Operation Enum Modification
- [ ] F1.2.1 Modify Operation enum in message header:
  ```zig
  upsert_events = 128,    // was: create_accounts
  query_uuid = 129,       // was: create_transfers
  query_uuid_batch = 130, // was: lookup_accounts
  query_radius = 131,     // was: lookup_transfers
  query_polygon = 132,    // NEW
  query_latest = 133,     // NEW
  delete_entity = 134,    // NEW (GDPR)
  ```
- [ ] F1.2.2 Update all switch statements handling operations
- [ ] F1.2.3 Update client protocol documentation

### F1.3 Single-Node Verification
- [ ] F1.3.1 Single-node writes work (GeoEvent → LSM)
- [ ] F1.3.2 UUID lookup returns correct data
- [ ] F1.3.3 Existing TigerBeetle tests adapted and passing
- [ ] F1.3.4 Basic client SDK (Zig) can connect and execute operations

**Exit Criteria:**
- [ ] Can write and read GeoEvents on single node
- [ ] State machine passes adapted TigerBeetle tests

---

## Phase F2: RAM Index Integration (Weeks 15-20)

**Goal:** Add O(1) entity lookup index (Aerospike pattern)

### F2.1 RAM Index Implementation
- [ ] F2.1.1 Create `src/ram_index.zig` (NEW FILE - not in TigerBeetle)
- [ ] F2.1.2 Define 64-byte `IndexEntry` extern struct (cache-line aligned)
- [ ] F2.1.3 Implement Robin Hood hashing with linear probing
- [ ] F2.1.4 Pre-allocate index at startup (no runtime resize)
- [ ] F2.1.5 Implement `lookup(entity_id) -> ?IndexEntry` O(1)
- [ ] F2.1.6 Implement `upsert(entity_id, event)` with LWW semantics
- [ ] F2.1.7 Handle out-of-order timestamps correctly

### F2.2 Index Checkpointing
- [ ] F2.2.1 Create `src/index/checkpoint.zig`
- [ ] F2.2.2 Implement dirty page tracking with bitset
- [ ] F2.2.3 Integrate checkpoint with superblock sequence
- [ ] F2.2.4 Implement incremental checkpoint (only dirty pages)
- [ ] F2.2.5 Implement checkpoint loading on startup
- [ ] F2.2.6 Implement full index rebuild fallback (scan LSM newest→oldest)

### F2.3 Index Statistics & Monitoring
- [ ] F2.3.1 Add `entry_count`, `load_factor`, `collision_count` stats
- [ ] F2.3.2 Add `tombstone_count`, `tombstone_ratio` (if delete supported)
- [ ] F2.3.3 Expose index metrics to Prometheus endpoint
- [ ] F2.3.4 Add alert thresholds for tombstone ratio

**Exit Criteria:**
- [ ] UUID lookups complete in <500μs p99
- [ ] Index survives crash/restart via checkpoint
- [ ] Tombstone monitoring working

---

## Phase F3: S2 Geometry Integration (Weeks 21-26)

**Goal:** Add spatial indexing for radius/polygon queries

### F3.1 S2 Library Integration
- [ ] F3.1.1 Evaluate S2 options: pure Zig port vs C++ FFI vs Rust FFI
- [ ] F3.1.2 Create `src/s2/` directory structure
- [ ] F3.1.3 Implement `lat_lon_to_cell_id(lat, lon, level) -> u64`
- [ ] F3.1.4 Implement `cell_id_to_lat_lon(cell_id) -> (lat, lon)`
- [ ] F3.1.5 Implement `RegionCoverer` for polygon → cell ranges
- [ ] F3.1.6 Implement `Cap` covering for radius queries

### F3.2 Determinism Validation (CRITICAL)
- [ ] F3.2.1 Create `tools/s2_golden_gen/` using reference S2 implementation
- [ ] F3.2.2 Generate `testdata/s2/golden_vectors_v1.tsv` (1000+ test cases)
- [ ] F3.2.3 Implement golden vector validation in CI
- [ ] F3.2.4 Verify bit-exact results across all replicas
- [ ] F3.2.5 Document floating-point handling strategy

### F3.3 Spatial Query Implementation
- [ ] F3.3.1 Create `src/s2_index.zig` for spatial lookups
- [ ] F3.3.2 Implement radius query (S2 Cap covering + LSM scan)
- [ ] F3.3.3 Implement polygon query (S2 RegionCoverer + LSM scan)
- [ ] F3.3.4 Implement skip-scan with block header min/max filtering
- [ ] F3.3.5 Implement post-filter for precise geometry tests
- [ ] F3.3.6 Create scratch buffer pool for S2 polygon operations

**Exit Criteria:**
- [ ] Golden vector tests pass (deterministic S2)
- [ ] Radius query returns correct results
- [ ] Polygon query returns correct results
- [ ] All replicas produce identical query results

---

## Phase F4: Replication Testing (Weeks 27-32)

**Goal:** Verify distributed correctness with VOPR simulator

### F4.1 VOPR Adaptation
- [ ] F4.1.1 Adapt VOPR simulator for GeoEvent operations
- [ ] F4.1.2 Create GeoEvent workload generators (random, clustered, adversarial)
- [ ] F4.1.3 Add spatial query operations to VOPR test scenarios
- [ ] F4.1.4 Implement S2 determinism checks in VOPR invariants

### F4.2 Cluster Testing
- [ ] F4.2.1 Test 3-replica cluster with GeoEvent operations
- [ ] F4.2.2 Test 5-replica cluster with GeoEvent operations
- [ ] F4.2.3 Test view change scenarios (primary failure)
- [ ] F4.2.4 Test network partition scenarios
- [ ] F4.2.5 Test crash recovery scenarios
- [ ] F4.2.6 Test state sync for lagging replicas

### F4.3 Safety Verification
- [ ] F4.3.1 Run VOPR with 1M+ operations - no invariant violations
- [ ] F4.3.2 Run VOPR with 10M+ operations - no invariant violations
- [ ] F4.3.3 Verify linearizability of all operations
- [ ] F4.3.4 Verify index consistency across replicas after view changes

**Exit Criteria:**
- [ ] VOPR passes 10M+ operations with no safety violations
- [ ] View change completes in <3 seconds
- [ ] All replicas converge to identical state

---

## Phase F5: Production Hardening (Weeks 33-38)

**Goal:** Complete production readiness

### F5.1 Performance Validation
- [ ] F5.1.1 Benchmark write throughput (target: 1M events/sec per node)
- [ ] F5.1.2 Benchmark UUID lookup latency (target: <500μs p99)
- [ ] F5.1.3 Benchmark radius query (target: <50ms p99)
- [ ] F5.1.4 Benchmark polygon query (target: <100ms p99)
- [ ] F5.1.5 Memory usage validation at 1M, 10M, 100M, 1B entities
- [ ] F5.1.6 Verify replication lag <10ms same region

### F5.2 Observability
- [ ] F5.2.1 Prometheus metrics endpoint working
- [ ] F5.2.2 All VSR metrics exposed (TigerBeetle's + index metrics)
- [ ] F5.2.3 Structured logging implemented
- [ ] F5.2.4 Health check endpoints (`/health/live`, `/health/ready`)
- [ ] F5.2.5 Grafana dashboard created

### F5.3 Client SDKs
- [ ] F5.3.1 Zig SDK complete (reference implementation)
- [ ] F5.3.2 Java SDK skeleton
- [ ] F5.3.3 Go SDK skeleton
- [ ] F5.3.4 Python SDK skeleton
- [ ] F5.3.5 Node.js SDK skeleton
- [ ] F5.3.6 Cross-language wire format compatibility tests

### F5.4 Security
- [ ] F5.4.1 mTLS for client connections (reuse TigerBeetle's implementation)
- [ ] F5.4.2 mTLS for replica-to-replica connections
- [ ] F5.4.3 Certificate reload via SIGHUP
- [ ] F5.4.4 Security audit completed

### F5.5 Documentation & Operations
- [ ] F5.5.1 Getting started guide
- [ ] F5.5.2 Operations runbook
- [ ] F5.5.3 Disaster recovery procedures
- [ ] F5.5.4 Capacity planning guide
- [ ] F5.5.5 TigerBeetle attribution documented (Apache 2.0 requirement)

**Exit Criteria:**
- [ ] All performance targets met
- [ ] Security review passed
- [ ] Documentation complete
- [ ] Ready for beta deployment

---

## Component Mapping: TigerBeetle → ArcherDB

| TigerBeetle File | Action | ArcherDB File | Notes |
|------------------|--------|---------------|-------|
| `src/tigerbeetle.zig` | REPLACE | `src/archerdb.zig` | GeoEvent state machine |
| `src/state_machine.zig` | REPLACE | `src/geo_state_machine.zig` | Geospatial operations |
| `src/vsr/replica.zig` | KEEP | `src/vsr/replica.zig` | DO NOT MODIFY |
| `src/vsr/journal.zig` | KEEP | `src/vsr/journal.zig` | DO NOT MODIFY |
| `src/vsr/clock.zig` | KEEP | `src/vsr/clock.zig` | DO NOT MODIFY |
| `src/vsr/superblock.zig` | KEEP | `src/vsr/superblock.zig` | Minor: add index checkpoint |
| `src/vsr/free_set.zig` | KEEP | `src/vsr/free_set.zig` | DO NOT MODIFY |
| `src/vsr/client_sessions.zig` | KEEP | `src/vsr/client_sessions.zig` | DO NOT MODIFY |
| `src/lsm/*.zig` | KEEP | `src/lsm/*.zig` | Adapt for GeoEvent |
| `src/storage.zig` | KEEP | `src/storage.zig` | DO NOT MODIFY |
| `src/io/linux.zig` | KEEP | `src/io/linux.zig` | DO NOT MODIFY |
| `src/message_pool.zig` | KEEP | `src/message_pool.zig` | DO NOT MODIFY |
| `src/simulator.zig` | KEEP | `src/simulator.zig` | Adapt test scenarios |
| `src/stdx.zig` | KEEP | `src/stdx.zig` | DO NOT MODIFY |
| N/A | ADD | `src/ram_index.zig` | O(1) entity lookup |
| N/A | ADD | `src/s2/*.zig` | S2 geometry library |
| N/A | ADD | `src/s2_index.zig` | Spatial index |
| N/A | ADD | `src/ttl.zig` | TTL tracking |
| `src/clients/*` | REPLACE | `src/clients/*` | New API, keep connection logic |

---

## Original Tasks (Reference - Build From Scratch)

The following sections contain the original detailed task breakdown. These remain useful
as a reference for WHAT needs to be implemented, but the HOW is now "adapt from TigerBeetle"
rather than "build from scratch."

---

## 1. Core Types & Constants

- [ ] 1.1 Update `src/constants.zig` with all compile-time configuration
  - sector_size, block_size, message_size_max
  - journal_slot_count (8192), checkpoint_interval, pipeline_max
  - lsm_levels, lsm_growth_factor, lsm_compaction_ops
  - clients_max, replicas_max (6 active + 4 standby)
  - s2_scratch_size (1MB), s2_scratch_pool_size (100)
  - index_entry_size (64 bytes - cache line aligned)
- [ ] 1.2 Create `src/geo_event.zig` with 128-byte `GeoEvent` extern struct
- [ ] 1.3 Add comptime assertions: @sizeOf == 128, @alignOf == 16, no_padding()
- [ ] 1.4 Create `GeoEventFlags` as packed struct(u16) with padding bits
- [ ] 1.5 Create 256-byte `BlockHeader` extern struct with dual checksums
- [ ] 1.6 Implement `pack_id(s2_cell, timestamp) -> u128` helper
- [ ] 1.7 Implement coordinate conversion (nanodegrees <-> float)
- [ ] 1.8 Write comptime tests for struct layout (including u32 accuracy_mm)
- [ ] 1.9 Implement `ScratchBufferPool` for concurrent S2 operations
- [ ] 1.10 Add `partial_result` handling to `MultiBatchExecutor`

## 2. Memory Management

- [ ] 2.1 Create `src/memory/static_allocator.zig` with init/static/deinit states
- [ ] 2.2 Implement state transition functions and panic on invalid operations
- [ ] 2.3 Create `src/memory/message_pool.zig` with reference counting
- [ ] 2.4 Implement intrusive QueueType(T) and StackType(T)
- [ ] 2.5 Implement RingBufferType with compile-time and runtime capacity options
- [ ] 2.6 Create NodePool with bitset tracking for manifest nodes
- [ ] 2.7 Implement BoundedArrayType(T, capacity) with comptime bounds
- [ ] 2.8 Create CountingAllocator wrapper for memory usage tracking
- [ ] 2.9 Write tests for all memory structures

## 3. Hybrid Memory (Index-on-RAM)

- [ ] 3.1 Create `src/index/primary_index.zig` with hash map structure
- [ ] 3.2 Define IndexEntry struct (64 bytes: entity_id + latest_id + ttl_seconds + reserved + padding)
- [ ] 3.3 Implement open addressing with linear probing
- [ ] 3.4 Pre-allocate index capacity at startup (no runtime resize, requires 128GB RAM for 1B entities)
- [ ] 3.5 Implement `lookup(entity_id) -> ?IndexEntry` O(1) lookup
- [ ] 3.6 Implement `upsert(entity_id, latest_id, ttl_seconds)` with LWW semantics (timestamp derived from latest_id)
- [ ] 3.7 Handle out-of-order timestamps (older records don't update index)
- [ ] 3.8 Create `src/index/checkpoint.zig` for incremental persistence
- [ ] 3.9 Implement incremental checkpoint format (header + sparse page array)
- [ ] 3.10 Implement dirty page tracking with bitset
- [ ] 3.11 Implement background "trickle" checkpointing task
- [ ] 3.12 Implement checkpoint loading and VSR coordination on startup
- [ ] 3.13 Implement **LSM-Aware Rebuild** strategy (scan newest to oldest with bitset)
- [ ] 3.14 Implement full index rebuild fallback (if new strategy fails)
- [ ] 3.15 Implement partial replay (checkpoint + WAL tail)
- [ ] 3.16 Add index statistics (entry_count, load_factor, collision_count)
- [ ] 3.17 Write tests for LWW ordering and checkpoint/rebuild

## 4. Checksums & Integrity

- [ ] 4.1 Create `src/checksum.zig` with Aegis-128L MAC implementation
- [ ] 4.2 Add comptime check for AES-NI support
- [ ] 4.3 Implement header checksum computation
- [ ] 4.4 Implement body checksum computation
- [ ] 4.5 Implement sticky checksum caching for repeated validation
- [ ] 4.6 Write tests including known-answer tests

## 5. I/O Subsystem

- [ ] 5.1 Create `src/io/ring.zig` with io_uring wrapper (Linux)
- [ ] 5.2 Implement SQE batching and CQE processing
- [ ] 5.3 Implement completion callbacks with user context
- [ ] 5.4 Add timeout support using CLOCK_MONOTONIC
- [ ] 5.5 Create `src/io/message_bus.zig` with connection state machine
- [ ] 5.6 Implement zero-copy fast path for single messages
- [ ] 5.7 Implement send_now() optimization (sync before async)
- [ ] 5.8 Add TCP configuration (TCP_NODELAY, keepalive, buffer sizing)
- [ ] 5.9 Create platform abstraction for macOS (kqueue) fallback
- [ ] 5.10 Write I/O integration tests

## 6. Storage Engine - Data File

- [ ] 6.1 Create `src/storage/data_file.zig` with zone layout
- [ ] 6.2 Implement superblock structure with 4/6/8 redundant copies
- [ ] 6.3 Implement hash-chained superblock writes with sequence numbers
- [ ] 6.4 Implement quorum read for superblock recovery
- [ ] 6.5 Create dual-ring WAL (headers + prepares)
- [ ] 6.6 Implement journal slot addressing and circular wraparound (8192 slots)
- [ ] 6.7 Implement client replies zone
- [ ] 6.8 Add Direct I/O with O_DIRECT and O_DSYNC flags
- [ ] 6.9 Implement sector alignment validation for all I/O
- [ ] 6.10 Write data file format tests

## 7. Storage Engine - Grid & LSM

- [ ] 7.1 Create `src/storage/grid.zig` with block-based storage
- [ ] 7.2 Implement BlockReference (address + checksum)
- [ ] 7.3 Create set-associative block cache (16-way default)
- [ ] 7.4 Implement read/write IOPS limiting
- [ ] 7.5 Create `src/storage/free_set.zig` with bitset tracking
- [ ] 7.6 Implement shard-based organization (4096-bit shards)
- [ ] 7.7 Implement reservation lifecycle (reserve, acquire, forfeit, reclaim)
- [ ] 7.8 Create `src/lsm/table.zig` with index block + value blocks
- [ ] 7.9 Implement table memory for mutable/immutable tables
- [ ] 7.10 Create `src/lsm/manifest.zig` for table metadata log
- [ ] 7.11 Implement compaction selection and sort-merge
- [ ] 7.12 Write LSM integration tests

## 8. VSR Protocol - Core

- [ ] 8.1 Create `src/vsr/message.zig` with 256-byte protocol header
- [ ] 8.2 Define all protocol commands (prepare, prepare_ok, commit, etc.)
- [ ] 8.3 Create `src/vsr/replica.zig` with status state machine
- [ ] 8.4 Implement Flexible Paxos quorum calculations
- [ ] 8.5 Implement hash-chained prepares (parent checksum linking)
- [ ] 8.6 Implement PrepareOk response and quorum tracking
- [ ] 8.7 Implement Commit message broadcast
- [ ] 8.8 Add ping/pong for liveness and clock sync

## 9. VSR Protocol - View Changes

- [ ] 9.1 Implement StartViewChange message and timeout trigger
- [ ] 9.2 Implement DoViewChange with present/nack bitsets
- [ ] 9.3 Implement CTRL protocol for log selection
- [ ] 9.4 Implement StartView broadcast with canonical log suffix
- [ ] 9.5 Implement primary abdication under backpressure
- [ ] 9.6 Write view change scenario tests

## 10. VSR Protocol - State & Recovery

- [ ] 10.1 Create `src/vsr/client_sessions.zig` for idempotency
- [ ] 10.2 Implement session registration and duplicate detection
- [ ] 10.3 Implement deterministic session eviction
- [ ] 10.4 Implement WAL repair (request_headers, request_prepare)
- [ ] 10.5 Implement state sync for lagging replicas
- [ ] 10.6 Implement grid block repair (request_blocks)
- [ ] 10.7 Create `src/vsr/clock.zig` with Marzullo's algorithm
- [ ] 10.8 Implement VSRState persistence in superblock
- [ ] 10.9 Write recovery scenario tests

## 11. VSR Protocol - Commit Pipeline

- [ ] 11.1 Create commit pipeline stages (idle through checkpoint)
- [ ] 11.2 Implement check_prepare stage
- [ ] 11.3 Implement prefetch stage with async I/O
- [ ] 11.4 Implement reply_setup stage
- [ ] 11.5 Implement execute stage with state machine
- [ ] 11.6 Implement compact stage for LSM
- [ ] 11.7 Implement checkpoint stages (data + superblock)
- [ ] 11.8 Write pipeline integration tests

## 12. S2 Integration

- [ ] 12.1 Evaluate S2 options and memory requirements
- [ ] 12.2 Implement `tools/s2_golden_gen/main.zig` to generate `testdata/s2/golden_vectors_v1.tsv` using an independent, pinned reference S2 implementation (tooling-only)
- [ ] 12.3 Implement pure Zig lat_lon_to_cell_id(lat, lon, level) -> u64
- [ ] 12.4 Implement/integrate cell_id_to_lat_lon(cell_id) -> (lat, lon)
- [ ] 12.5 Implement/integrate RegionCoverer for polygon -> cell ranges
- [ ] 12.6 Implement/integrate Cap covering for radius queries
- [ ] 12.7 Create scratch buffer pool for S2 polygon operations
- [ ] 12.8 Write tests validating cell hierarchy and memory usage

## 13. Query Engine

- [ ] 13.1 Create `src/query/state_machine.zig` with three-phase model
- [ ] 13.2 Implement input_valid() for batch validation
- [ ] 13.3 Implement prepare() for timestamp assignment
- [ ] 13.4 Implement prefetch() with async I/O for data loading
- [ ] 13.5 Implement commit() for deterministic execution
- [ ] 13.6 Create multi-batch encoding/decoding with trailer
- [ ] 13.7 Implement UUID lookup query (uses hybrid memory index)
- [ ] 13.8 Implement radius query with S2 Cap covering (using scratch buffer)
- [ ] 13.9 Implement polygon query with S2 RegionCoverer (using scratch buffer)
- [ ] 13.10 Implement skip-scan with block header min/max filtering
- [ ] 13.11 Implement post-filter for precise geometry tests
- [ ] 13.12 Write query integration tests

## 14. Testing & Simulation

- [ ] 14.1 Create `src/testing/simulator.zig` with deterministic PRNG
- [ ] 14.2 Implement simulated time (virtualized CLOCK_MONOTONIC)
- [ ] 14.3 Implement simulated I/O (in-memory storage)
- [ ] 14.4 Create fault injection for storage (corruption, drops, latency)
- [ ] 14.5 Create fault injection for network (drops, partitions, reorder)
- [ ] 14.6 Create fault injection for timing (skew, spurious wakeups)
- [ ] 14.7 Create fault injection for crashes
- [ ] 14.8 Implement two-phase testing (safety then liveness)
- [ ] 14.9 Implement state verification and invariant checking
- [ ] 14.10 Create workload generators (random, clustered, adversarial)
- [ ] 14.11 Implement seed regression suite
- [ ] 14.12 Write simulator integration tests

## 15. Client Protocol & SDKs

- [ ] 15.1 Define binary message framing format (256-byte header + body)
- [ ] 15.2 Implement operation codes enum (insert, query_uuid, query_radius, etc.)
- [ ] 15.3 Implement request/response pattern with client sessions
- [ ] 15.4 Create Zig SDK (reference implementation)
- [ ] 15.5 Implement connection pooling and automatic reconnection
- [ ] 15.6 Add batch encoding/decoding helpers
- [ ] 15.7 Create Java SDK skeleton
- [ ] 15.8 Create Go SDK skeleton
- [ ] 15.9 Create Python SDK skeleton
- [ ] 15.10 Create Node.js SDK skeleton
- [ ] 15.11 Write cross-language integration tests (wire format compatibility)

## 16. Security (mTLS)

- [ ] 16.1 Integrate TLS library (Zig standard library TLS or BoringSSL)
- [ ] 16.2 Implement certificate loading (PEM format, PKCS#8 keys)
- [ ] 16.3 Add mTLS handshake for client connections
- [ ] 16.4 Add mTLS for replica-to-replica connections
- [ ] 16.5 Implement certificate validation (expiration, CA verification)
- [ ] 16.6 Add `--tls-required` configuration flag
- [ ] 16.7 Implement cluster ID verification (prevent misdirected messages)
- [ ] 16.8 Add authentication audit logging
- [ ] 16.9 Implement SIGHUP certificate reload
- [ ] 16.10 Write security integration tests

## 17. Observability

- [ ] 17.1 Create HTTP server for Prometheus metrics endpoint (port 9091)
- [ ] 17.2 Implement metrics collection (counters, gauges, histograms)
- [ ] 17.3 Add write metrics (ops/sec, latency, throughput)
- [ ] 17.4 Add read metrics (query types, latencies, result sizes)
- [ ] 17.5 Add VSR metrics (view, op_num, replication lag, quorum status)
- [ ] 17.6 Add resource metrics (memory, disk, I/O)
- [ ] 17.7 Add LSM metrics (tables, compactions)
- [ ] 17.8 Add error metrics (by error type)
- [ ] 17.9 Implement structured logging (JSON and text formats)
- [ ] 17.10 Add `--log-format` and `--log-level` configuration
- [ ] 17.11 Implement log rotation
- [ ] 17.12 Add `/health/live` and `/health/ready` endpoints
- [ ] 17.13 Write Grafana dashboard JSON (example monitoring)

## 18. CLI Integration

- [ ] 18.1 Add `archerdb format` command to initialize data file
- [ ] 18.2 Add `archerdb start` command to launch replica
- [ ] 18.3 Add cluster configuration (replica addresses, quorum settings)
- [ ] 18.4 Add TLS configuration (certificate paths, --tls-required flag)
- [ ] 18.5 Add `archerdb status` command showing cluster state
- [ ] 18.6 Add `archerdb benchmark` command for performance testing
- [ ] 18.7 Update help text and documentation

## 19. Validation & Benchmarks

- [ ] 19.1 Run VOPR simulator with 10M+ operations
- [ ] 19.2 Benchmark write throughput (target: 1M events/sec per node)
- [ ] 19.3 Benchmark UUID lookup latency (target: <500μs p99)
- [ ] 19.4 Benchmark radius query with 1M records in area (target: <50ms p99)
- [ ] 19.5 Benchmark polygon query (target: <100ms p99)
- [ ] 19.6 Test view change failover latency (target: <3s)
- [ ] 19.7 Test state sync with lagging replica
- [ ] 19.8 Memory usage validation at 1M, 10M, 100M, 1B records
- [ ] 19.9 Crash recovery and data integrity verification
- [ ] 19.10 Test all TigerBeetle optimizations for failover
- [ ] 19.11 Validate replication lag (target: <10ms same region)

## Dependencies

```
1.x Core Types (no deps)
    |
    v
2.x Memory Management --> 4.x Checksums
    |                         |
    +---> 3.x Hybrid Memory   |
    |         |               |
    v         v               v
5.x I/O Subsystem ---------> 6.x Storage (Data File)
    |                         |
    v                         v
    +----------------------> 7.x Storage (Grid/LSM)
                              |
12.x S2 Integration           |
    |                         |
    v                         v
8.x-11.x VSR Protocol <------ +
    |
    v
13.x Query Engine (uses 3.x Hybrid Memory for lookups)
    |
    +---> 15.x Client Protocol (depends on query engine operations)
    |         |
    |         +---> 16.x Security (mTLS wraps client protocol)
    |
    +---> 17.x Observability (metrics for all components)
    |
    v
14.x Testing & Simulation
    |
    v
18.x CLI Integration
    |
    v
19.x Validation
    |
    v
20.x Deployment
    |
    v
21.x CI/CD
    |
    v
22.x Monitoring
    |
    v
23.x Configuration
    |
    v
24.x API Versioning
    |
    v
25.x Health Checks
    |
    v
26.x Licensing & Legal (no deps)
    |
    v
27.x Compliance & Privacy (depends on core security)
    |
    +---> 28.x Data Portability (depends on query engine)
    |         |
    |         +---> 29.x Developer Tools (depends on all core systems)
    |
    +---> 30.x Commercial Features (depends on core functionality)
    |
    +---> 31.x Community & Ecosystem (depends on documentation)
    |
    v
32.x Performance Profiling (depends on observability foundation)
    |
    v
33.x Team Resources & Planning (no deps - resource planning)
    |
    v
34.x Risk Management & Mitigation (depends on project foundation)
    |
    v
35.x Performance Validation Methodology (depends on performance profiling)
    |
    v
36.x Success Metrics & KPIs (depends on all systems operational)
```

## Parallelizable Work

- 1.x and 12.x can be done in parallel (structs and S2 are independent)
- 2.x, 3.x, and 4.x can be done in parallel after 1.x
- 5.x and 6.x can be partially parallelized
- 8.x, 9.x, 10.x, 11.x (VSR) depend on earlier phases but can have parallel sub-work
- 15.x (Client Protocol), 16.x (Security), 17.x (Observability) can be done in parallel after 13.x
- 14.x (testing) can start once core VSR is in place
- SDK skeletons (15.7-15.10) can be developed in parallel

---

## Implementation Phases

The implementation SHALL proceed in ordered phases with explicit entry/exit criteria.

### Phase 0: Foundation (Tasks 1.x, 2.x, 4.x)
**Entry Criteria:** Repository initialized, Zig toolchain installed
**Exit Criteria:** All struct layouts compile, comptime tests pass, memory allocators work

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 0: FOUNDATION                                              │
├─────────────────────────────────────────────────────────────────┤
│ Parallel Track A       │ Parallel Track B      │ Duration      │
├─────────────────────────┼───────────────────────┼───────────────┤
│ 1.1-1.8 Core Types     │ 4.1-4.6 Checksums    │ Week 1        │
│ 2.1-2.9 Memory Mgmt    │ 12.1-12.2 S2 Setup   │ Week 2        │
└─────────────────────────┴───────────────────────┴───────────────┘

Exit Gate:
- [ ] GeoEvent: @sizeOf == 128, @alignOf == 16
- [ ] BlockHeader: @sizeOf == 256, dual checksum verified
- [ ] Aegis-128L: Known-answer tests pass
- [ ] StaticAllocator: State machine transitions verified
```

### Phase 1: Storage Layer (Tasks 5.x, 6.x, 7.x)
**Entry Criteria:** Phase 0 complete
**Exit Criteria:** Data file can be formatted, written, and read; LSM tables functional

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 1: STORAGE LAYER                                           │
├─────────────────────────────────────────────────────────────────┤
│ Sequential             │ Depends On            │ Duration      │
├─────────────────────────┼───────────────────────┼───────────────┤
│ 5.1-5.5 I/O Ring       │ Phase 0              │ Week 3        │
│ 6.1-6.10 Data File     │ 5.x                  │ Week 4        │
│ 7.1-7.12 Grid & LSM    │ 6.x                  │ Week 5-6      │
└─────────────────────────┴───────────────────────┴───────────────┘

Exit Gate:
- [ ] io_uring: 100K IOPS on NVMe benchmark
- [ ] Superblock: 4-copy redundant write verified
- [ ] WAL: 8192 slots circular write verified
- [ ] LSM: Compaction L0→L1 works correctly
```

### Phase 2: Consensus Protocol (Tasks 8.x, 9.x, 10.x, 11.x)
**Entry Criteria:** Phase 1 complete
**Exit Criteria:** 3-node cluster can reach consensus, view changes work

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 2: CONSENSUS PROTOCOL                                      │
├─────────────────────────────────────────────────────────────────┤
│ Sequential             │ Depends On            │ Duration      │
├─────────────────────────┼───────────────────────┼───────────────┤
│ 8.1-8.8 VSR Core       │ Phase 1              │ Week 7-8      │
│ 9.1-9.6 View Changes   │ 8.x                  │ Week 9        │
│ 10.1-10.9 State Sync   │ 9.x                  │ Week 10       │
│ 11.1-11.8 Pipeline     │ 10.x                 │ Week 11       │
└─────────────────────────┴───────────────────────┴───────────────┘

Exit Gate:
- [ ] 3-node: Prepare/PrepareOk/Commit cycle works
- [ ] View change: Primary failure triggers view change < 3s
- [ ] State sync: Lagging replica catches up via checkpoint
- [ ] Pipeline: Commit stages execute deterministically
```

### Phase 3: Index & Query (Tasks 3.x, 12.x, 13.x)
**Entry Criteria:** Phase 2 complete
**Exit Criteria:** UUID lookup works, radius/polygon queries return correct results

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 3: INDEX & QUERY                                           │
├─────────────────────────────────────────────────────────────────┤
│ Parallel Track A       │ Parallel Track B      │ Duration      │
├─────────────────────────┼───────────────────────┼───────────────┤
│ 3.1-3.17 Hybrid Memory │ 12.3-12.8 S2 Impl    │ Week 12-13    │
│ 13.1-13.6 State Machine│ 13.7-13.12 Queries   │ Week 14-15    │
└─────────────────────────┴───────────────────────┴───────────────┘

Exit Gate:
- [ ] Index: O(1) lookup latency < 500μs p99
- [ ] S2: Golden vector tests pass (deterministic)
- [ ] Radius query: Post-filter ratio < 2.0
- [ ] Polygon query: Self-intersection detection works
```

### Phase 4: Client Interface (Tasks 15.x, 16.x, 17.x, 18.x)
**Entry Criteria:** Phase 3 complete
**Exit Criteria:** Client can connect, authenticate, and execute all operations

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 4: CLIENT INTERFACE                                        │
├─────────────────────────────────────────────────────────────────┤
│ Parallel Track A       │ Parallel Track B      │ Duration      │
├─────────────────────────┼───────────────────────┼───────────────┤
│ 15.1-15.6 Protocol     │ 16.1-16.10 Security  │ Week 16-17    │
│ 17.1-17.13 Observability│ 18.1-18.7 CLI       │ Week 18       │
└─────────────────────────┴───────────────────────┴───────────────┘

Exit Gate:
- [ ] Protocol: Zig SDK can execute all operations
- [ ] TLS: mTLS handshake verified
- [ ] Metrics: Prometheus endpoint returns valid metrics
- [ ] CLI: `archerdb format` and `archerdb start` work
```

### Phase 5: Testing & Validation (Tasks 14.x, 19.x)
**Entry Criteria:** Phase 4 complete
**Exit Criteria:** VOPR simulator passes 10M+ ops, performance targets met

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 5: TESTING & VALIDATION                                    │
├─────────────────────────────────────────────────────────────────┤
│ Sequential             │ Depends On            │ Duration      │
├─────────────────────────┼───────────────────────┼───────────────┤
│ 14.1-14.12 Simulator   │ Phase 4              │ Week 19-20    │
│ 19.1-19.11 Benchmarks  │ 14.x                 │ Week 21-22    │
└─────────────────────────┴───────────────────────┴───────────────┘

Exit Gate:
- [ ] VOPR: 10M+ operations with no invariant violations
- [ ] Write: 1M events/sec per node achieved
- [ ] Lookup: < 500μs p99 verified
- [ ] Failover: < 3s view change verified
```

### Phase 6: Production Readiness (Tasks 20.x-36.x)
**Entry Criteria:** Phase 5 complete
**Exit Criteria:** Production deployment checklist complete

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 6: PRODUCTION READINESS                                    │
├─────────────────────────────────────────────────────────────────┤
│ Parallel Tracks        │ Priority              │ Duration      │
├─────────────────────────┼───────────────────────┼───────────────┤
│ 26.x Licensing         │ High (legal blocker) │ Week 23       │
│ 27.x Compliance        │ High (GDPR)          │ Week 23-24    │
│ 28.x-31.x Ecosystem    │ Medium               │ Week 24-26    │
│ 32.x-36.x Operations   │ Medium               │ Week 25-26    │
└─────────────────────────┴───────────────────────┴───────────────┘

Exit Gate:
- [ ] Licensing: Apache 2.0 headers in all files
- [ ] GDPR: Right to erasure verified end-to-end
- [ ] Docs: Getting started guide tested
- [ ] Ops: Runbook covers common failure scenarios
```

---

## Requirement Traceability Matrix

Cross-reference between specifications and implementation tasks.

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        REQUIREMENT TRACEABILITY MATRIX                               │
├───────────────────────────────┬─────────────────────────┬───────────────────────────┤
│ Specification                 │ Key Requirements        │ Implementation Tasks      │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ data-model/spec.md            │ GeoEvent (128 bytes)    │ 1.2, 1.3, 1.4             │
│                               │ Composite ID (u128)     │ 1.6                       │
│                               │ Nanodegree coords       │ 1.7, 1.8                  │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ storage-engine/spec.md        │ Superblock (4-copy)     │ 6.2, 6.3, 6.4             │
│                               │ WAL (8192 slots)        │ 6.5, 6.6                  │
│                               │ LSM Tree                │ 7.8, 7.9, 7.10, 7.11      │
│                               │ Grid/Block Cache        │ 7.1, 7.2, 7.3             │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ hybrid-memory/spec.md         │ RAM Index (64B entry)   │ 3.1, 3.2, 3.3, 3.4        │
│                               │ LWW Semantics           │ 3.6, 3.7                  │
│                               │ Incremental Checkpoint  │ 3.8, 3.9, 3.10, 3.11      │
│                               │ LSM-Aware Rebuild       │ 3.13, 3.14                │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ replication/spec.md           │ VSR Core                │ 8.1-8.8                   │
│                               │ View Changes            │ 9.1-9.6                   │
│                               │ State Sync              │ 10.5, 10.6                │
│                               │ Client Sessions         │ 10.1-10.4                 │
│                               │ Commit Pipeline         │ 11.1-11.8                 │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ query-engine/spec.md          │ Three-Phase Model       │ 13.1-13.5                 │
│                               │ S2 Integration          │ 12.3-12.8                 │
│                               │ UUID Lookup             │ 13.7                      │
│                               │ Radius Query            │ 13.8                      │
│                               │ Polygon Query           │ 13.9                      │
│                               │ Post-Filter             │ 13.11                     │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ client-protocol/spec.md       │ Binary Protocol         │ 15.1, 15.2                │
│                               │ 256B Header             │ 8.1                       │
│                               │ Batch Operations        │ 15.6                      │
│                               │ Rate Limiting           │ (implemented in 13.x)     │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ security/spec.md              │ mTLS                    │ 16.1-16.7                 │
│                               │ Certificate Reload      │ 16.9                      │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ observability/spec.md         │ Prometheus Metrics      │ 17.1-17.8                 │
│                               │ Structured Logging      │ 17.9-17.11                │
│                               │ Health Endpoints        │ 17.12                     │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ ttl-retention/spec.md         │ TTL on GeoEvent         │ 1.2 (flags), 13.x         │
│                               │ Lazy Expiration         │ 3.5, 3.6                  │
│                               │ Compaction Cleanup      │ 7.11                      │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ testing-simulation/spec.md    │ VOPR Simulator          │ 14.1-14.3                 │
│                               │ Fault Injection         │ 14.4-14.7                 │
│                               │ Two-Phase Testing       │ 14.8                      │
│                               │ Workload Generators     │ 14.10                     │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ compliance/spec.md            │ GDPR Right to Erasure   │ 27.2 (delete_entities)    │
│                               │ Audit Trails            │ 27.8                      │
├───────────────────────────────┼─────────────────────────┼───────────────────────────┤
│ configuration/spec.md         │ CLI-Only Config         │ 18.1-18.7                 │
│                               │ Single-Tenant           │ (architectural decision)  │
└───────────────────────────────┴─────────────────────────┴───────────────────────────┘
```

---

## Critical Path

The minimum set of tasks required for a functional system.

```
CRITICAL PATH (Minimum Viable Product)
══════════════════════════════════════

Week 1-2:   1.2→1.3→1.6 (GeoEvent struct, composite ID)
            ↓
Week 3-4:   4.1→5.1→6.1→6.2→6.5 (Checksum, I/O, Data File)
            ↓
Week 5-6:   7.8→7.9→7.11 (LSM tables, compaction)
            ↓
Week 7-9:   8.1→8.5→8.6→8.7→9.1→9.4 (VSR prepare/commit, view change)
            ↓
Week 10-11: 11.1→11.5 (Commit pipeline, execute stage)
            ↓
Week 12-14: 3.1→3.5→3.6→12.3→13.7→13.8 (Index, S2, queries)
            ↓
Week 15-16: 15.1→15.2→18.1→18.2 (Protocol, CLI)
            ↓
Week 17-18: 14.1→14.8→19.2→19.3 (Simulator, benchmarks)

MVP Deliverable: Single-tenant cluster with insert, lookup, radius query
```

---

## 26.x Licensing and Legal Implementation
- [ ] 26.1 Implement Apache 2.0 license headers in all source files
- [ ] 26.2 Create CONTRIBUTING.md with CLA requirements
- [ ] 26.3 Set up contributor license agreement process
- [ ] 26.4 Document TigerBeetle attribution requirements
- [ ] 26.5 Implement license compliance checking in CI/CD
- [ ] 26.6 Create TRADEMARK.md and branding guidelines
- [ ] 26.7 Set up patent strategy and documentation
- [ ] 26.8 Implement export control compliance checks

## 27.x Compliance and Privacy Implementation
- [ ] 27.1 Implement GDPR consent management system
- [ ] 27.2 Add data subject rights APIs (access, rectification, erasure, portability)
- [ ] 27.3 Implement privacy by design data minimization
- [ ] 27.4 Add location data encryption at rest and in transit
- [ ] 27.5 Create data protection impact assessment framework
- [ ] 27.6 Implement international data transfer safeguards
- [ ] 27.7 Add automated breach notification system
- [ ] 27.8 Implement compliance audit trails and reporting

## 28.x Data Portability Implementation
- [ ] 28.1 Implement JSON/GeoJSON export formats
- [ ] 28.2 Add CSV import/export capabilities
- [ ] 28.3 Create bulk data export with range filtering
- [ ] 28.4 Implement parallel export processing
- [ ] 28.5 Add data validation and quality assurance
- [ ] 28.6 Create incremental data loading (delta sync)
- [ ] 28.7 Implement ETL tool integrations
- [ ] 28.8 Add data transformation pipeline

## 29.x Developer Tools Implementation
- [ ] 29.1 Create local development cluster setup script
- [ ] 29.2 Implement runtime debugging capabilities
- [ ] 29.3 Add query performance debugging tools
- [ ] 29.4 Create load testing and simulation framework
- [ ] 29.5 Implement development data management tools
- [ ] 29.6 Add monitoring dashboards for development
- [ ] 29.7 Create API exploration and testing interfaces
- [ ] 29.8 Implement code quality and coverage tools

## 30.x Commercial Features Implementation
- [ ] 30.1 Implement cost-optimized storage tiering
- [ ] 30.2 Add resource usage metering and tracking
- [ ] 30.3 Create cost monitoring and alerting
- [ ] 30.4 Implement commercial licensing model
- [ ] 30.5 Add enterprise features and support tiers
- [ ] 30.6 Create pricing model and billing integration
- [ ] 30.7 Implement marketplace integration
- [ ] 30.8 Add financial compliance and reporting

## 31.x Community and Ecosystem Implementation
- [ ] 31.1 Set up community governance structures
- [ ] 31.2 Create comprehensive documentation platform
- [ ] 31.3 Implement third-party integration APIs
- [ ] 31.4 Set up community communication channels
- [ ] 31.5 Create event and conference participation plan
- [ ] 31.6 Establish partnership and collaboration framework
- [ ] 31.7 Implement community growth metrics and analytics
- [ ] 31.8 Add diversity and inclusion initiatives

## 32.x Performance Profiling Implementation
- [ ] 32.1 Implement runtime CPU and memory profiling
- [ ] 32.2 Add query performance analysis tools
- [ ] 32.3 Create system performance diagnostics
- [ ] 32.4 Implement distributed tracing
- [ ] 32.5 Add performance benchmarking suite
- [ ] 32.6 Create profiling data monitoring integration
- [ ] 32.7 Implement diagnostic data collection
- [ ] 32.8 Add performance debugging and optimization tools

## 33.x Team Resources & Planning Implementation
- [ ] 33.1 Define team composition for each development phase
- [ ] 33.2 Create resource planning and budgeting framework
- [ ] 33.3 Establish hiring and training strategies
- [ ] 33.4 Implement team productivity and velocity tracking
- [ ] 33.5 Create remote work and collaboration guidelines
- [ ] 33.6 Develop team health and sustainability programs
- [ ] 33.7 Set up knowledge continuity and succession planning
- [ ] 33.8 Establish vendor and contractor management processes

## 34.x Risk Management & Mitigation Implementation
- [ ] 34.1 Create comprehensive risk assessment framework
- [ ] 34.2 Implement technical risk mitigation strategies
- [ ] 34.3 Develop business risk mitigation plans
- [ ] 34.4 Establish team and execution risk management
- [ ] 34.5 Create operational risk mitigation procedures
- [ ] 34.6 Implement external risk monitoring and response
- [ ] 34.7 Develop risk quantification and prioritization system
- [ ] 34.8 Create contingency planning and crisis response procedures

## 35.x Performance Validation Methodology Implementation
- [ ] 35.1 Establish performance validation framework and standards
- [ ] 35.2 Implement latency performance validation procedures
- [ ] 35.3 Create throughput performance validation methods
- [ ] 35.4 Develop scalability validation testing procedures
- [ ] 35.5 Implement benchmarking methodology and standards
- [ ] 35.6 Create performance regression testing automation
- [ ] 35.7 Develop hardware-specific validation procedures
- [ ] 35.8 Implement workload characterization and testing

## 36.x Success Metrics & KPIs Implementation
- [ ] 36.1 Define technical success metrics and KPIs
- [ ] 36.2 Establish business success metrics and KPIs
- [ ] 36.3 Create community success metrics and KPIs
- [ ] 36.4 Implement development velocity and productivity metrics
- [ ] 36.5 Develop operational success metrics and KPIs
- [ ] 36.6 Create customer success metrics and KPIs
- [ ] 36.7 Establish innovation and learning metrics
- [ ] 36.8 Implement financial success metrics and KPIs
