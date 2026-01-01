# Change: Add Core Geospatial Database Functionality

## Why

ArcherDB needs to become a high-performance geospatial database capable of storing and querying 1 billion+ location records with sub-millisecond latency. Traditional GIS databases (PostGIS, etc.) sacrifice performance for flexibility by using variable-length records and complex indexing. By adopting TigerBeetle-style fixed-size structs, cache-aligned memory layouts, and its proven distributed systems patterns, we can achieve significantly higher throughput for real-time location tracking, ride-sharing, logistics, and IoT applications.

This proposal has been significantly enhanced based on a thorough analysis of the TigerBeetle codebase, incorporating its battle-tested patterns for memory management, I/O, storage, and consensus replication.

## Implementation Reference

**CRITICAL:** This proposal is based on TigerBeetle's proven architecture and implementation patterns. The **authoritative source** for all borrowed patterns is:

**TigerBeetle Repository:** https://github.com/tigerbeetle/tigerbeetle

Implementers MUST reference the actual TigerBeetle codebase for:
- VSR protocol implementation (`src/vsr/`)
- Memory management patterns (`src/stdx.zig`, allocators)
- Storage engine design (`src/lsm/`, `src/storage.zig`)
- I/O subsystem (`src/io/`)
- Message handling (`src/message_pool.zig`)
- Testing/simulation (`src/testing/`, `src/simulator.zig`)
- Data structures (intrusive lists, ring buffers, etc.)

**When in doubt, consult TigerBeetle's source code - it is the reference implementation.**

---

## Competitive Analysis

### Market Position and Differentiation

ArcherDB occupies a unique position in the geospatial database market by combining TigerBeetle's financial-grade performance with spatial indexing capabilities. Traditional geospatial databases sacrifice performance for flexibility, while high-performance databases lack geospatial features.

#### Performance Comparison

| Database | Write Throughput | Read Latency (UUID) | Spatial Queries | Data Model | License |
|----------|------------------|-------------------|-----------------|------------|---------|
| **ArcherDB** | **1M events/sec** | **<500μs** | **S2-native** | **Fixed-size structs** | **Apache 2.0** |
| PostGIS | ~10K events/sec | ~10ms | Excellent | Variable rows | PostgreSQL |
| MongoDB Atlas | ~100K events/sec | ~5ms | Good (GeoJSON) | Documents | SSPL |
| CockroachDB | ~50K events/sec | ~10ms | Basic | Rows | BSL → Apache 2.0 |
| TigerBeetle | **1M tx/sec** | **<500μs** | None | Fixed-size structs | Apache 2.0 |

#### Key Differentiators

1. **Performance Leadership**: 10-100x higher throughput than traditional geospatial databases
2. **TigerBeetle Heritage**: Inherits battle-tested distributed systems architecture
3. **Fixed-Point Precision**: Deterministic geospatial calculations across replicas
4. **Cost Efficiency**: Hybrid memory architecture reduces storage costs by 60%
5. **Real-Time Capabilities**: Sub-millisecond queries enable live geospatial applications

### Target Markets and Use Cases

#### Primary Markets
- **Ride-sharing & Logistics**: Real-time vehicle tracking, route optimization, fleet management
- **IoT & Telematics**: Massive-scale device monitoring with geospatial analytics
- **Real-time Analytics**: Live geospatial dashboards, proximity alerts, spatial aggregations
- **Location-based Gaming**: High-concurrency player positioning and matchmaking
- **Smart Cities**: Traffic management, emergency response, urban planning

#### Competitive Advantages
- **Performance**: Handles 1B+ entities with sub-millisecond queries
- **Scale**: Linear scaling to 5M events/sec across clusters
- **Reliability**: 99.999% uptime with automatic failover
- **Cost**: 60% lower TCO than traditional geospatial databases
- **Developer Experience**: Simple deployment, comprehensive tooling

### Market Size and Opportunity

#### Total Addressable Market
- **Geospatial Database Market**: $5B+ (2024)
- **Real-time Location Services**: $40B+ (2024)
- **IoT Data Management**: $15B+ (2024)
- **ArcherDB Addressable Segment**: High-performance geospatial (20% of market = $1B+)

#### Growth Drivers
- **IoT Explosion**: 30B+ connected devices by 2025 requiring location tracking
- **Real-time Applications**: Demand for sub-second geospatial queries
- **Cloud Migration**: Cost pressures driving high-performance alternatives
- **5G Adoption**: Enabling real-time location-based services at scale

### Go-to-Market Strategy

#### Phase 1: Technical Validation (Months 1-6)
- Open source release with comprehensive documentation
- Performance benchmarks against PostGIS, MongoDB
- Early adopter program for ride-sharing and logistics companies

#### Phase 2: Market Penetration (Months 7-18)
- Commercial support offerings and enterprise features
- Cloud marketplace listings (AWS, GCP, Azure)
- Partnership with GIS software vendors and cloud providers

#### Phase 3: Market Leadership (Year 2+)
- Industry standard for high-performance geospatial
- Comprehensive ecosystem of tools and integrations
- Global adoption across target markets

### Risk Mitigation

#### Technical Risks
- **S2 Integration Complexity**: Mitigated by comprehensive testing and TigerBeetle-style validation
- **Performance Targets**: Conservative estimates based on TigerBeetle benchmarks
- **Distributed Systems Complexity**: Leverages proven VSR protocol and architecture

#### Market Risks
- **Adoption Resistance**: Addressed through performance demonstrations and cost analysis
- **Competition**: Differentiated by unique performance/cost combination
- **Standards Compliance**: Full support for GeoJSON, OGC standards

#### Execution Risks
- **Team Expertise**: Core team with distributed systems and geospatial experience
- **Funding Requirements**: Bootstrapped with clear path to commercial revenue
- **Community Building**: Open source approach ensures community adoption

## What Changes

### New Capabilities

- **Data Model**: 128-byte cache-aligned `GeoEvent` struct with `extern struct` layout, fixed-point coordinates (no floats), `packed struct` flags, and reserved fields pattern
- **Storage Engine**: TigerBeetle-style data file zones (Superblock, WAL Headers, WAL Prepares, Client Replies, Grid), LSM tree with manifest log, Free Set with reservation system, Aegis-128L MAC checksums
- **Query Engine**: Three-phase execution model (prepare, prefetch, commit), multi-batch processing, S2-based spatial indexing with skip-scan optimization
- **Replication**: Full Viewstamped Replication (VSR) with Flexible Paxos quorums, view changes, state sync, client sessions, and Byzantine clock synchronization
- **Memory Management**: StaticAllocator (init/static/deinit phases), MessagePool with reference counting, intrusive data structures, compile-time memory calculations
- **I/O Subsystem**: io_uring integration, zero-copy messaging, message bus with connection state machine, platform abstraction (Linux/macOS/Windows)
- **Testing & Simulation**: VOPR-style deterministic simulator, fault injection (storage, network, timing, crash), two-phase testing (safety then liveness), property-based testing
- **Hybrid Memory**: Aerospike-style index-on-RAM architecture with data on SSD, LWW upserts, index checkpointing, cold start rebuild

### Architecture Summary

| Component | Storage | Purpose |
|-----------|---------|---------|
| Superblock Zone | 4/6/8 redundant copies | VSR state, checkpoint metadata, hash-chained for integrity |
| WAL (Headers + Prepares) | Dual-ring circular buffer | Crash recovery, hash-chained prepares for linearizability |
| Client Replies Zone | `clients_max * message_size_max` | Cached responses for idempotency |
| Grid Zone (LSM) | Unbounded | Block storage for LSM tree, manifest log, geo data |
| RAM Pointer Index | ~92GB for 1B entities | UUID -> latest composite ID mapping for O(1) entity lookups |

### Key Design Decisions

1. **Space-Major ID**: `[S2 Cell ID (u64) | Timestamp (u64)]` - optimized for "where + when" queries
2. **Fixed-Point Coordinates**: Nanodegrees (i64) instead of floats for deterministic equality across replicas
3. **VSR Consensus**: Full Viewstamped Replication with Flexible Paxos quorums for strong consistency
4. **Three-Phase Execution**: Prepare (timestamp assignment) -> Prefetch (async I/O) -> Commit (deterministic execution)
5. **Static Memory Allocation**: All memory allocated at startup, panic if runtime allocation attempted
6. **io_uring Integration**: Linux 5.5+ async I/O with zero-copy fast path
7. **Aegis-128L Checksums**: AES-NI accelerated MAC for all data integrity (requires hardware support)
8. **VOPR-Style Testing**: Deterministic simulation with fault injection for exhaustive distributed systems testing

## Impact

- **Affected specs**: None (new capabilities)
- **New spec files** (32 total):
  - `specs/api-versioning/spec.md` - Protocol and format versioning policy
  - `specs/implementation-guide/spec.md` - **CRITICAL**: TigerBeetle reference implementation mapping, file-by-file guide, attribution requirements
  - `specs/data-model/spec.md` - GeoEvent structure (with TTL field), block headers, ID generation
  - `specs/storage-engine/spec.md` - Data file zones, LSM tree, checkpoints (→ TigerBeetle `src/storage.zig`)
  - `specs/query-engine/spec.md` - Three-phase execution, spatial queries, performance SLAs
  - `specs/replication/spec.md` - Full VSR protocol specification (→ TigerBeetle `src/vsr/`)
  - `specs/memory-management/spec.md` - Static allocation, pools, intrusive structures (→ TigerBeetle `src/stdx.zig`)
  - `specs/io-subsystem/spec.md` - io_uring, message bus, TCP configuration (→ TigerBeetle `src/io/`)
  - `specs/testing-simulation/spec.md` - VOPR simulator, fault injection (→ TigerBeetle `src/testing/`)
  - `specs/hybrid-memory/spec.md` - Index-on-RAM (64-byte entries), checkpointing/rebuild, capacity limits, hardware requirements
  - `specs/client-protocol/spec.md` - Custom binary protocol, SDK requirements, error codes
  - `specs/client-sdk/spec.md` - Cross-language SDK behavior and semantics
  - `specs/security/spec.md` - mTLS authentication, certificate management, audit logging
  - `specs/observability/spec.md` - Prometheus metrics, structured logging, health checks
  - `specs/constants/spec.md` - Central constants (checkpoint_interval=256, s2_level=30, batch_max=10K)
  - `specs/interfaces/spec.md` - Inter-component interfaces (state machine, index, storage, S2, etc.)
  - `specs/ttl-retention/spec.md` - Per-entry TTL, lazy expiration, cleanup API, compaction-based garbage collection
  - `specs/backup-restore/spec.md` - S3 backup, point-in-time restore, RPO<1min/RTO~20min
  - `specs/client-retry/spec.md` - Automatic retry, exponential backoff, primary discovery, idempotency
  - `specs/configuration/spec.md` - Configuration file/flags and validation
  - `specs/performance-validation/spec.md` - Benchmark and performance validation methodology
  - `specs/profiling/spec.md` - Profiling hooks and tooling expectations
  - `specs/developer-tools/spec.md` - Developer CLI and testdata generators
  - `specs/data-portability/spec.md` - Export/import formats and migration support
  - `specs/ci-cd/spec.md` - Build, test, and reproducibility requirements
  - `specs/compliance/spec.md` - Compliance and audit considerations
  - `specs/licensing/spec.md` - Licensing policy and attribution requirements
  - `specs/commercial/spec.md` - Commercial/enterprise strategy (non-technical)
  - `specs/community/spec.md` - Community strategy (non-technical)
  - `specs/risk-management/spec.md` - Risk register and mitigations
  - `specs/success-metrics/spec.md` - Success criteria and KPIs
  - `specs/team-resources/spec.md` - Resourcing, roadmap, and execution planning
- **Affected code**:
  - `src/main.zig` - CLI commands for database operations
  - New files: `src/geo_event.zig`, `src/storage/`, `src/lsm/`, `src/vsr/`, `src/io/`, `src/query/`
- **Dependencies**:
  - S2 core implementation (pure Zig); pinned reference implementation may be used for tooling-only golden vectors
  - io_uring (Linux 5.5+), kqueue (macOS), IOCP (Windows)
  - AES-NI hardware acceleration (required)
- **Breaking changes**: None (greenfield implementation)

## Decisions Made

All open questions have been answered. See `DECISIONS.md` for complete Architecture Decision Record.

**Summary:**
- **Client Protocol:** Custom binary (like TigerBeetle) with official SDKs for Zig, Java, Go, Python, Node.js
- **Security:** mTLS authentication, all-or-nothing authorization
- **Observability:** Prometheus metrics + structured logging (Zig std.log)
- **Cluster:** Static membership, support 3/5/6 replicas
- **S2 Integration:** Pure Zig core implementation (no C++ in core; tooling may use a pinned reference)
- **H3 Support:** Deferred to v2+ (S2 only for MVP)
- **Subscriptions:** Deferred to v2+ (polling only)
- **Performance:** 1M events/sec per node, <500μs UUID lookups, <3s failover
- **Limits:** 1B entities per node, 5M events/sec cluster, 81k result sets (message-size bounded)
