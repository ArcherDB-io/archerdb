# Project Context: ArcherDB

## Purpose

**ArcherDB is a high-performance geospatial database designed for real-time location tracking and spatial analytics, capable of storing and querying 1 billion+ location records with sub-millisecond latency.**

### Mission

To provide the fastest, most reliable geospatial database for applications requiring real-time location intelligence, enabling new categories of location-aware services that were previously impossible due to performance limitations of traditional GIS databases.

### Target Applications

- **Ride-sharing platforms** requiring real-time vehicle tracking
- **Logistics and fleet management** with live route optimization
- **IoT device monitoring** for asset tracking and predictive maintenance
- **Real-time geospatial analytics** for urban planning and traffic management
- **Location-based gaming** with massive concurrent player positioning
- **Emergency response systems** with instant location queries

### Success Metrics

- **Performance:** 1M events/sec write throughput, <500μs UUID lookups
- **Scale:** 1B entities per node, 5M events/sec cluster
- **Reliability:** 99.999% uptime, strong consistency guarantees
- **Adoption:** Production deployments at scale within 18 months

## Tech Stack

### Core Technologies

- **Language:** Zig (v0.12+) - Systems programming with memory safety and performance
- **Platform:** Linux/macOS/Windows - Cross-platform deployment support
- **Storage:** Direct I/O with io_uring (Linux), custom data structures
- **Networking:** Custom binary protocol over TCP with zero-copy messaging
- **Consensus:** Viewstamped Replication (VSR) for strong consistency
- **Indexing:** S2 spatial indexing with hybrid memory architecture

### Development Tools

- **Build System:** Zig build system with cross-compilation
- **Testing:** Deterministic simulation (VOPR-style) + integration testing
- **CI/CD:** GitHub Actions with multi-platform validation
- **Monitoring:** StatsD metrics with Prometheus integration
- **Documentation:** OpenSpec-driven specification and implementation

### Runtime Dependencies

- **Hardware:** AES-NI support (required), NVMe SSD, 128GB+ RAM
- **Operating System:** Linux 5.5+ (io_uring), macOS 12+, Windows Server 2022+
- **Network:** 10Gbps+ between replicas for optimal performance

## Project Conventions

### Code Style

- **Formatting:** `zig fmt` standard formatting (no custom rules)
- **Naming:** snake_case for functions/variables, PascalCase for types
- **Comments:** Comprehensive documentation with preconditions/postconditions
- **Imports:** Explicit imports only, no wildcard imports
- **Error Handling:** Zig's error unions with explicit error sets

### Architecture Patterns

- **Data-Oriented Design:** Cache-aligned structs, explicit memory layout
- **Static Allocation:** All memory allocated at startup, no runtime GC
- **Zero-Copy Operations:** Wire format = memory format for performance
- **State Machine Pattern:** Deterministic execution with clear state transitions
- **Intrusive Data Structures:** Zero-allocation linked lists and queues
- **Compile-Time Validation:** Size/alignment assertions and bounds checking

### Testing Strategy

- **Safety Testing:** VOPR deterministic simulation with comprehensive fault injection
- **Liveness Testing:** Real cluster testing with chaos engineering
- **Performance Testing:** Automated benchmarking with regression detection
- **Integration Testing:** End-to-end workflows with realistic data patterns
- **Property-Based Testing:** Generated test cases for edge conditions

### Git Workflow

- **Branching:** `main` for production, feature branches for development
- **Commits:** Atomic changes with descriptive messages following conventional commits
- **Pull Requests:** Required reviews, CI validation, specification compliance
- **Releases:** Semantic versioning with automated changelog generation
- **Tags:** Version tags with build metadata and compatibility information

## Domain Context

### Geospatial Data Characteristics

- **High Volume:** Billions of location updates per day
- **Real-Time:** Sub-second query requirements for live applications
- **Spatial Relationships:** Complex geometric operations (containment, intersection, proximity)
- **Temporal Aspects:** Time-windowed queries, historical analysis
- **Accuracy Requirements:** Nanodegree precision for global coverage
- **Update Patterns:** High-frequency updates from mobile devices

### Performance Requirements

- **Write Throughput:** 1M location events per second per node
- **Read Latency:** <500μs for entity lookups, <50ms for radius queries
- **Consistency:** Strong consistency across geographically distributed replicas
- **Durability:** Data survives multiple node failures and network partitions
- **Scalability:** Linear scaling with cluster size additions

### Operational Constraints

- **24/7 Availability:** Zero-downtime deployments and upgrades
- **Global Distribution:** Cross-region replication with low latency
- **Cost Efficiency:** Optimize for cloud deployment economics
- **Security:** End-to-end encryption, access control, audit trails
- **Compliance:** GDPR compliance for location data privacy

## Important Constraints

### Technical Constraints

- **Hardware Requirements:** AES-NI support (modern x86-64 CPUs only)
- **Memory Model:** Static allocation prevents dynamic memory growth
- **Network Model:** TCP-based protocol with custom framing
- **Storage Model:** Direct I/O requires sector-aligned operations
- **Time Model:** Monotonic timestamps with Byzantine clock synchronization

### Business Constraints

- **Open Source First:** Apache 2.0 licensing for community adoption
- **Self-Hosted Focus:** Designed for on-premise and private cloud deployment
- **Performance Over Features:** Prioritize speed over complex query capabilities
- **Operational Simplicity:** Minimize operational complexity for reliability

### Regulatory Constraints

- **Location Privacy:** GDPR compliance for personal location data
- **Data Residency:** Support for regional data sovereignty requirements
- **Audit Requirements:** Comprehensive logging for security compliance
- **Accuracy Disclosure:** Clear documentation of GPS accuracy limitations

## External Dependencies

### Runtime Dependencies

- **Operating System:** Linux 5.5+ (io_uring), macOS kqueue, Windows IOCP
- **Hardware:** x86-64 with AES-NI, NVMe storage, sufficient RAM
- **Network:** TCP connectivity between cluster nodes
- **Time Synchronization:** NTP or PTP for clock synchronization

### Development Dependencies

- **Zig Compiler:** Zig 0.12+ with standard library
- **Build Tools:** Git, CMake (for optional C interop)
- **Testing Tools:** Deterministic simulator, load generators
- **CI/CD:** GitHub Actions, Docker for testing

### Optional Dependencies

- **Monitoring:** Prometheus, Grafana, StatsD agents
- **Logging:** ELK stack, structured logging systems
- **Backup:** S3-compatible object storage
- **Client Libraries:** Language-specific package managers

## Implementation Priorities

### Phase 1: Core Foundation (Months 1-3)

1. Data structures and memory management
2. Basic storage engine with single-node operation
3. Simple query operations (UUID lookups)

### Phase 2: Distributed Systems (Months 4-6)

1. VSR consensus protocol implementation
2. Multi-node cluster support
3. Basic replication and failover

### Phase 3: Geospatial Features (Months 7-9)

1. S2 spatial indexing integration
2. Radius and polygon query support
3. Performance optimization and benchmarking

### Phase 4: Production Readiness (Months 10-12)

1. Monitoring and observability
2. Backup and restore capabilities
3. Client SDKs and documentation

## Success Criteria

### Technical Success

- All performance SLAs met in production testing
- Zero data loss in failure scenarios
- Successful cross-region deployment
- Client SDKs for 3+ major languages

### Business Success

- Production deployment by 3+ companies
- Community adoption with 100+ GitHub stars
- Performance benchmarks published and competitive
- Positive feedback on operational simplicity

### Community Success

- Active contribution from external developers
- Comprehensive documentation and examples
- Responsive issue tracking and support
- Clear roadmap and version planning
