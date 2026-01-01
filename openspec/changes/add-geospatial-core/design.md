# Design: Geospatial Core Architecture

## Context

We are building a high-performance geospatial database inspired by TigerBeetle's data-oriented design principles and battle-tested distributed systems patterns.

### TigerBeetle as Reference Implementation

**IMPORTANT:** All patterns described in this design document are derived from TigerBeetle's actual implementation.

**Primary Reference:** https://github.com/tigerbeetle/tigerbeetle

**Key files to study:**
- `src/vsr/replica.zig` - VSR protocol state machine
- `src/vsr/journal.zig` - WAL (journal) implementation
- `src/vsr/superblock.zig` - Superblock with quorum reads
- `src/vsr/clock.zig` - Byzantine clock synchronization (Marzullo's algorithm)
- `src/lsm/` - LSM tree implementation (manifest, compaction, tables)
- `src/storage.zig` - Data file zones, grid, free set
- `src/io/` - io_uring integration, message bus
- `src/message_pool.zig` - Message pooling with reference counting
- `src/stdx.zig` - Memory utilities, intrusive data structures
- `src/testing/` - VOPR simulator, fault injection
- `src/constants.zig` - Compile-time configuration

**Implementation Strategy:**
1. Study TigerBeetle's implementation for each component
2. Adapt patterns to geospatial domain (replace Account/Transfer with GeoEvent)
3. Preserve TigerBeetle's safety guarantees and performance optimizations
4. When specification is ambiguous, TigerBeetle's code is authoritative

**Do NOT reinvent patterns that TigerBeetle has already proven. Reuse and adapt.**

--- The system must handle 1 billion+ location records with support for:

- **Radius queries**: Find entities within X meters of a point
- **Polygon queries**: Find entities within an arbitrary geopolygon
- **UUID lookups**: Get the latest location of a specific entity
- **Time range filters**: Optional filtering by timestamp on any spatial query
- **Strong consistency**: VSR consensus ensures linearizable operations across replicas

Target hardware: Cluster of 3-5 nodes, each with 128GB+ RAM, NVMe SSD (1TB+), AES-NI support.

## Goals / Non-Goals

### Goals

- Sub-millisecond UUID lookups
- Sequential scan performance for spatial range queries (leveraging CPU prefetcher)
- 128-byte cache-aligned records for optimal memory bandwidth
- Deterministic behavior (no floating-point comparison issues)
- Support 1 billion records on a single node
- **Strong consistency via VSR (Viewstamped Replication)**
- Automatic failover with view changes
- Zero runtime memory allocation (static allocation discipline)
- Comprehensive fault injection testing (VOPR-style)

### Non-Goals

- Variable-length payloads (use external sidecar database for metadata)
- Sub-meter precision (nanodegree precision is ~0.1mm, far exceeds GPS accuracy)
- Non-AES-NI hardware support (Aegis-128L requires it)
- More than 6 active replicas (Flexible Paxos limitation)

## Decisions

### Decision 1: 128-byte GeoEvent Struct (TigerBeetle Pattern)

**What**: Fixed-size, cache-aligned record format using `extern struct` with explicit layout.

**Why**:
- Fits exactly in 2 x86 cache lines or 1 ARM cache line
- Enables zero-copy networking and disk I/O
- Allows pointer arithmetic for random access: `offset = index * 128`
- Prevents memory fragmentation
- `extern struct` guarantees no padding/reordering

**Structure**:
```zig
pub const GeoEvent = extern struct {
    id: u128,              // [S2 Cell (64) | Timestamp (64)]
    entity_id: u128,       // UUID for "who"
    correlation_id: u128,  // UUID for "what trip/session"
    lat_nano: i64,         // Latitude in nanodegrees
    lon_nano: i64,         // Longitude in nanodegrees
    altitude_mm: i32,      // Altitude in millimeters
    velocity_mms: u32,     // Speed in mm/s
    heading_cdeg: u16,     // Direction in centidegrees (0-36000)
    accuracy_mm: u16,      // GPS accuracy radius
    flags: GeoEventFlags,  // packed struct(u16) with padding bits
    reserved: [2]u8,       // Padding for alignment
    group_id: u64,         // Fleet/region grouping
    reserved2: [24]u8,     // Future expansion, init to zero

    comptime {
        assert(@sizeOf(GeoEvent) == 128);
        assert(@alignOf(GeoEvent) == 16);
        stdx.no_padding(GeoEvent);  // Verify no implicit padding
    }
};
```

**Alternatives considered**:
- 64-byte struct: Cannot fit required fields (UUIDs alone = 48 bytes)
- Variable-size: Destroys cache locality and requires length prefixes

### Decision 2: Space-Major Composite ID

**What**: Primary key format `[S2 Cell ID (u64) | Timestamp (u64)]`.

**Why**:
- Query pattern is "find entities in area, optionally filter by time"
- Sorting by S2 Cell creates spatial locality in memory (nearby points are nearby in RAM)
- Time is secondary sort, so history of a location is contiguous
- Range queries become simple integer comparisons

**Alternatives considered**:
- Time-Major `[Time | S2]`: Better for global replay, worse for spatial queries
- Interleaved (Z-order mixing bits): Equal performance for space/time but fragments range queries

### Decision 3: S2 over H3 for Spatial Indexing

**What**: Use a pure Zig port of the Google S2 library for spatial cell IDs.

**Why**:
- Perfect hierarchy via bit-shifting (parent = truncate 2 bits)
- Hilbert curve creates contiguous integer ranges for bounding boxes
- Used by production systems (MongoDB, CockroachDB)
- 64-bit cell ID fits naturally in our composite key
- **Pure Zig Port**: Ensures bit-for-bit identical results across all platforms, preventing replica divergence that could occur with C/C++ math library variations.

**Alternatives considered**:
- H3 (Uber): Better for hexagonal smoothing/analytics, but imperfect hierarchy
- Geohash: Older, less precise, edge discontinuities

### Decision 4: Fixed-Point Coordinates (No Floats)

**What**: Store lat/lon as nanodegrees (i64), altitude/velocity as millimeters.

**Why**:
- Floats cause non-deterministic behavior across CPU architectures
- All replicas MUST produce identical state for VSR consensus
- Integers compress better (delta encoding)
- Unambiguous units

**Conversion**:
```zig
lat_nano = @intFromFloat(lat_float * 1_000_000_000);
lat_float = @as(f64, @floatFromInt(lat_nano)) / 1_000_000_000.0;
```

### Decision 5: Aerospike-Style Hybrid Memory Architecture

**What**: Primary index resides entirely in RAM while data records are stored on SSD.

**Why**:
- Storing full 128-byte structs in RAM for 1B records = 128GB (too expensive)
- Storing 64-byte index entries (cache-line aligned) = ~91.5GB (requires 128GB RAM server)
- NVMe random read latency (~100μs) is acceptable for point queries
- Sequential scans for range queries leverage full disk bandwidth

**Index Entry Structure**:
```zig
const IndexEntry = struct {
    entity_id: u128,    // Key: UUID of the entity
    latest_id: u128,    // Value: Composite ID [S2 Cell (u64) | Timestamp (u64)]
    ttl_seconds: u32,   // TTL for expiration checks
    reserved: u32,      // Alignment padding
    padding: [24]u8,    // Reserved for future extensions (64 bytes total)
};  // 64 bytes (Cache Line Aligned)
```

**Key Properties**:
- O(1) lookup via hash map with open addressing
- LWW (Last-Write-Wins) for out-of-order GPS packet handling
- Index checkpoint + VSR journal replay for crash recovery
- Full rebuild by scanning persisted GeoEvents if checkpoint is corrupt
- **128GB RAM**: Recommended for 1B entities to ensure consistent latency and OS headroom.

### Decision 6: Viewstamped Replication (VSR) with Flexible Paxos

**What**: Full VSR consensus protocol for strong consistency, not async replication.

**Why**:
- Strong consistency guarantees (linearizability)
- Automatic failover via view changes
- Client sessions ensure exactly-once semantics
- Flexible Paxos allows tuning latency vs. availability
- Battle-tested in TigerBeetle's financial accounting system

**Key Properties**:
- `quorum_replication + quorum_view_change > replica_count` (intersection)
- Primary selected deterministically: `primary_index = view % replica_count`
- Hash-chained prepares detect forks
- CTRL protocol for uncommitted entry handling during view change

**Tradeoff**: Higher write latency (quorum wait) vs async replication, but strong consistency is worth it for a database.

### Decision 7: Three-Phase Execution Model

**What**: All operations pass through prepare -> prefetch -> commit phases.

**Why**:
- **Prepare**: Primary assigns timestamps before consensus (only primary executes)
- **Prefetch**: Async I/O loads required data into cache (reduces commit latency)
- **Commit**: Deterministic execution after consensus (all replicas produce same result)

**Flow**:
```
Client Request
    -> Primary: prepare(op, body) -> timestamp assigned
    -> Consensus: replicate to quorum
    -> All Replicas: prefetch(op) -> async I/O
    -> All Replicas: commit(op, timestamp, body) -> execute
    -> Client Reply
```

### Decision 8: 256-byte Block Headers with Dual Checksums

**What**: All blocks (messages, grid blocks) use 256-byte headers with Aegis-128L MAC.

**Why**:
- `checksum` covers header (after checksum field)
- `checksum_body` covers body separately
- Enables detecting which part is corrupted
- Header contains min_id/max_id for skip-scan optimization

**Block Header Structure**:
```zig
pub const BlockHeader = extern struct {
    checksum: u128,           // Aegis-128L MAC of header
    checksum_padding: u128,   // Reserved for u256
    checksum_body: u128,      // Aegis-128L MAC of body
    checksum_body_padding: u128,
    // ... additional fields
    min_id: u128,             // Lowest ID in block
    max_id: u128,             // Highest ID in block
    // ...
    comptime { assert(@sizeOf(BlockHeader) == 256); }
};
```

### Decision 9: Data File Zone Layout (TigerBeetle Pattern)

**What**: Single data file organized into distinct zones.

**Layout**:
```
[Superblock Zone] - 4/6/8 redundant copies, hash-chained
[WAL Headers]     - Ring buffer of prepare headers
[WAL Prepares]    - Ring buffer of full prepare messages
[Client Replies]  - Cached responses for idempotency
[Grid Padding]    - Alignment to block_size
[Grid Zone]       - LSM tree blocks, unbounded
```

**Why**:
- Single file simplifies operations (no filesystem coordination)
- Zones enable efficient crash recovery
- Superblock redundancy survives partial corruption
- WAL dual-ring separates headers (recovery) from bodies (consensus)

### Decision 10: Static Memory Allocation (TigerBeetle Pattern)

**What**: All memory allocated at startup, runtime allocations cause panic.

**StaticAllocator States**:
- `init`: Allow alloc/resize during startup
- `static`: Disallow all allocations (production runtime)
- `deinit`: Allow free during shutdown

**Why**:
- No OOM during production operation
- Predictable memory usage
- No allocation latency spikes
- Forces explicit capacity planning

**Key Patterns**:
- MessagePool with reference counting
- Intrusive linked lists (no node allocation)
- BoundedArray with compile-time capacity
- NodePool with bitset tracking

### Decision 11: io_uring Integration (Linux)

**What**: Use io_uring for all async I/O on Linux with zero-copy fast path.

**Why**:
- Batched syscalls reduce context switch overhead
- Zero-copy for single-message receive path
- Completion-based model integrates with event loop
- `send_now()` optimization: try sync send before async

**Platform Abstraction**:
- Linux: io_uring (primary, optimized)
- macOS: kqueue (development)
- Windows: IOCP (production)

### Decision 12: VOPR-Style Testing

**What**: Deterministic simulator with comprehensive fault injection.

**Why**:
- Distributed systems bugs are hard to reproduce
- Deterministic replay from seed enables debugging
- Two-phase testing: aggressive faults (safety), then recovery (liveness)
- Covers edge cases impossible to hit in production

**Fault Types**:
- Storage: corruption, drops, latency, torn writes
- Network: drops, delays, reordering, partitions
- Timing: clock skew, timeouts
- Crash: clean, hard, during transitions

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| VSR complexity | Follow TigerBeetle's proven implementation patterns |
| AES-NI requirement | All modern x86-64 CPUs have it; document requirement |
| S2 library dependency | Use Zig C interop or port core algorithms |
| Static allocation limits | Calculate capacity at compile time, validate |
| io_uring Linux 5.5+ | Fallback to epoll on older kernels |

## Migration Plan

Not applicable - greenfield implementation.

## Implementation Order

1. **Core Types**: GeoEvent, BlockHeader, constants
2. **Storage Engine**: Data file zones, superblock, WAL
3. **Memory Management**: StaticAllocator, MessagePool, pools
4. **I/O Subsystem**: io_uring wrapper, message bus
5. **LSM Tree**: Tables, compaction, manifest
6. **VSR Protocol**: Replica, primary, view changes
7. **Query Engine**: Three-phase execution, S2 integration
8. **Testing**: VOPR simulator, fault injection
9. **Client SDK**: Binary protocol, session management

## Open Questions

1. **Client Protocol**: Custom binary (like TigerBeetle) or gRPC?
2. **S2 Integration**: C bindings or Zig port of core algorithms?
3. **Cluster Configuration**: Support reconfiguration or fixed membership?
4. **Monitoring**: Metrics export format (Prometheus, StatsD)?
