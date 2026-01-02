# Testing & Simulation Specification

**Reference Implementation:** https://github.com/tigerbeetle/tigerbeetle/tree/main/src/testing

This spec is based on TigerBeetle's VOPR (Viewstamped Operation Replication) deterministic simulator. Implementers MUST study:
- `src/simulator.zig` - Deterministic simulation framework with PRNG seed control
- `src/testing/storage.zig` - Simulated storage with comprehensive fault injection
- `src/testing/cluster.zig` - Multi-replica cluster simulation
- `src/vsr/replica.zig` - Property-based testing patterns and invariant checking

**Implementation approach:** TigerBeetle's simulator is the gold standard for distributed systems testing. Copy the architecture exactly - deterministic PRNG, fault injection enums, two-phase testing (safety then liveness), and seed-based replay.

---

## ADDED Requirements

### Requirement: Deterministic Simulator (VOPR-Style)

The system SHALL implement a deterministic simulator for exhaustive testing of distributed system behavior, inspired by TigerBeetle's VOPR (Viewstamped Operation Replayer).

#### Scenario: Deterministic PRNG seeding

- **WHEN** a simulation is started
- **THEN** a 64-bit seed SHALL initialize all randomness
- **AND** the same seed SHALL produce identical execution
- **AND** seeds SHALL be logged for reproduction

#### Scenario: Simulated time

- **WHEN** running in simulation mode
- **THEN** all time sources SHALL be virtualized
- **AND** `CLOCK_MONOTONIC` reads return simulated ticks
- **AND** time advances deterministically based on events

#### Scenario: Simulated I/O

- **WHEN** I/O operations are performed in simulation
- **THEN** they SHALL use in-memory storage
- **AND** io_uring operations SHALL be intercepted
- **AND** completion order is controlled by simulator

### Requirement: Fault Injection

The system SHALL support comprehensive fault injection for testing error handling and recovery.

#### Scenario: Storage faults

- **WHEN** storage faults are injected
- **THEN** the simulator SHALL support:
  - Read corruption (flip bits, return wrong data)
  - Write drops (silently discard writes)
  - Read/write latency (delay completions)
  - Crash during write (partial/torn writes)
  - Misdirected reads (return data from wrong offset)

#### Scenario: Network faults

- **WHEN** network faults are injected
- **THEN** the simulator SHALL support:
  - Message drops (configurable drop rate)
  - Message delays (variable latency)
  - Message reordering (out-of-order delivery)
  - Message duplication
  - Partition (isolate subsets of replicas)
  - Asymmetric partition (A→B works, B→A fails)

#### Scenario: Timing faults

- **WHEN** timing faults are injected
- **THEN** the simulator SHALL support:
  - Clock skew between replicas
  - Timeout variations
  - Scheduling reordering
  - Spurious wakeups

#### Scenario: Crash faults

- **WHEN** crash faults are injected
- **THEN** the simulator SHALL support:
  - Clean shutdown (graceful)
  - Hard crash (immediate termination)
  - Crash during state transition
  - Crash loop (repeated crashes)
  - Recovery after crash

### Requirement: Two-Phase Testing

The system SHALL use a two-phase testing approach: safety phase followed by liveness phase.

#### Scenario: Safety phase

- **WHEN** the safety phase runs
- **THEN** faults SHALL be injected aggressively
- **AND** cluster MAY become unavailable
- **AND** invariants SHALL be checked continuously
- **AND** no data corruption or inconsistency is tolerated

#### Scenario: Liveness phase

- **WHEN** the liveness phase runs
- **THEN** fault injection SHALL be disabled
- **AND** the cluster SHALL recover to healthy state
- **AND** all committed operations SHALL be durable
- **AND** new operations SHALL make progress

#### Scenario: Phase transition

- **WHEN** transitioning from safety to liveness
- **THEN** all pending faults SHALL be cleared
- **AND** network partitions SHALL be healed
- **AND** crashed replicas SHALL be restarted
- **AND** a timeout SHALL bound recovery time

### Requirement: State Verification

The system SHALL verify correctness through state machine invariants and cross-replica consistency.

#### Scenario: Invariant checking

- **WHEN** state changes occur
- **THEN** invariants SHALL be checked:
  - Hash chain integrity (prepares link correctly)
  - Monotonic commit numbers (never decrease)
  - View number consistency
  - Quorum intersection property
  - Operation uniqueness (no duplicate ops)

#### Scenario: Cross-replica consistency

- **WHEN** comparing replica states
- **THEN** committed state SHALL be identical
- **AND** `commit_min` across replicas SHALL match for same op
- **AND** client session tables SHALL be consistent
- **AND** LSM tree checksums SHALL match after sync

#### Scenario: Linearizability checking

- **WHEN** client operations complete
- **THEN** results SHALL be linearizable
- **AND** a linearization point SHALL exist for each op
- **AND** concurrent operations SHALL have consistent ordering

### Requirement: Workload Generation

The system SHALL generate realistic workloads for stress testing.

#### Scenario: Client simulation

- **WHEN** simulating clients
- **THEN** the simulator SHALL model:
  - Multiple concurrent clients
  - Request rate variation
  - Request size variation
  - Client crashes and reconnects
  - Duplicate request submission

#### Scenario: Geospatial workload patterns

- **WHEN** generating geospatial workloads
- **THEN** patterns SHALL include:
  - Random point insertions
  - Clustered insertions (hotspots)
  - Moving entity updates (trajectory patterns)
  - Spatial query bursts
  - Mixed read/write ratios

#### Scenario: Adversarial workloads

- **WHEN** generating adversarial workloads
- **THEN** patterns SHALL include:
  - Maximum batch sizes
  - Minimum batch sizes (1 event)
  - Rapid entity updates (same UUID)
  - Boundary conditions (edge of S2 cells)
  - Time edge cases (epoch boundaries)

### Requirement: Property-Based Testing

The system SHALL use property-based testing with coverage-guided fuzzing.

#### Scenario: Swarm testing

- **WHEN** swarm testing is configured
- **THEN** each run SHALL have random configuration:
  - Replica count (1, 3, 5)
  - Fault injection rates
  - Workload mix
  - Timing parameters
- **AND** this explores configuration space efficiently

#### Scenario: Shrinking

- **WHEN** a failure is found
- **THEN** the test case SHALL be minimized
- **AND** unnecessary operations removed
- **AND** minimal reproduction seed recorded

#### Scenario: Coverage tracking

- **WHEN** running property tests
- **THEN** code coverage SHALL be tracked
- **AND** rare code paths prioritized
- **AND** branch coverage guides generation

### Requirement: Regression Testing

The system SHALL maintain regression tests for known bug patterns.

#### Scenario: Seed regression suite

- **WHEN** a bug is found via simulation
- **THEN** its seed SHALL be added to regression suite
- **AND** CI SHALL run all regression seeds
- **AND** seeds are tagged with bug description

#### Scenario: Protocol edge cases

- **WHEN** testing protocol edge cases
- **THEN** specific scenarios SHALL include:
  - View change during checkpoint
  - State sync with concurrent compaction
  - Primary abdication under load
  - Split-brain recovery
  - Byzantine clock divergence

### Requirement: Performance Simulation

The system SHALL simulate performance characteristics under various conditions.

#### Scenario: Latency modeling

- **WHEN** simulating latency
- **THEN** I/O operations SHALL have configurable latency distributions
- **AND** network RTT SHALL be modeled per-link
- **AND** tail latencies SHALL be measurable

#### Scenario: Throughput limits

- **WHEN** simulating throughput
- **THEN** disk IOPS limits SHALL be enforced
- **AND** network bandwidth limits SHALL be enforced
- **AND** backpressure behavior SHALL be observable

#### Scenario: Resource exhaustion

- **WHEN** simulating resource limits
- **THEN** message pool exhaustion SHALL be testable
- **AND** disk space limits SHALL be testable
- **AND** connection limits SHALL be testable

### Requirement: Test Harness Infrastructure

The system SHALL provide infrastructure for running simulation tests efficiently.

#### Scenario: Parallel test execution

- **WHEN** running simulations
- **THEN** multiple seeds SHALL run in parallel
- **AND** each simulation is single-threaded (deterministic)
- **AND** CPU cores are utilized efficiently

#### Scenario: CI integration

- **WHEN** integrating with CI
- **THEN** simulation tests SHALL:
  - Run on every commit
  - Have configurable duration
  - Report seeds that fail
  - Track flakiness over time

#### Scenario: Logging and debugging

- **WHEN** debugging simulation failures
- **THEN** detailed logs SHALL be available:
  - All message sends/receives with timestamps
  - State transitions with before/after
  - Fault injection events
  - Client request/response pairs
- **AND** logs SHALL be reproducible from seed

### Requirement: Unit Test Patterns

The system SHALL follow TigerBeetle's unit test patterns for component testing.

#### Scenario: Comptime testing

- **WHEN** testing compile-time logic
- **THEN** `comptime` blocks SHALL verify:
  - Struct sizes and alignments
  - Constant calculations
  - Type constraints

#### Scenario: Fuzzing integration

- **WHEN** fuzzing is used
- **THEN** AFL/libFuzzer integration SHALL be supported
- **AND** crash inputs saved for reproduction
- **AND** coverage-guided mutation used

#### Scenario: Deterministic memory

- **WHEN** testing memory operations
- **THEN** FixedBufferAllocator SHALL be used
- **AND** allocation patterns are reproducible
- **AND** memory leaks are detectable

### Requirement: Integration Testing

The system SHALL support integration testing with real I/O paths.

#### Scenario: Local cluster testing

- **WHEN** running integration tests
- **THEN** a local cluster SHALL be startable
- **AND** real TCP connections used
- **AND** real file I/O used (tmpfs recommended)

#### Scenario: Client SDK testing

- **WHEN** testing client SDKs
- **THEN** tests SHALL verify:
  - Connection handling
  - Request/reply serialization
  - Timeout behavior
  - Retry logic

#### Scenario: Upgrade testing

- **WHEN** testing version upgrades
- **THEN** data file compatibility SHALL be verified
- **AND** rolling upgrade scenarios tested
- **AND** rollback scenarios tested

### Requirement: Chaos Engineering

The system SHALL support chaos engineering in production-like environments.

#### Scenario: Chaos monkey

- **WHEN** chaos testing is enabled
- **THEN** random faults SHALL be injected:
  - Kill random replica process
  - Block network port
  - Fill disk temporarily
  - Slow down I/O

#### Scenario: Gameday exercises

- **WHEN** conducting gameday exercises
- **THEN** runbooks SHALL be testable:
  - Primary failure recovery
  - Disk failure and replacement
  - Network partition healing
  - Full cluster restart

### Requirement: Geospatial-Specific Testing

The system SHALL include comprehensive test scenarios for geospatial operations.

#### Scenario: S2 cell calculation edge cases

- **WHEN** testing S2 cell computation
- **THEN** test cases SHALL include:
  - Exact pole coordinates (90°N, 90°S)
  - Anti-meridian crossing (±180°)
  - Equator/Prime Meridian intersection (0°, 0°)
  - Maximum valid coordinates (±90° lat, ±180° lon)
  - Minimum precision differences (1 nanodegree apart)
  - S2 cell face boundaries (where cells transition between cube faces)

#### Scenario: Radius query boundary conditions

- **WHEN** testing radius queries
- **THEN** test cases SHALL include:
  - Zero radius (point query)
  - Maximum radius (1,000 km)
  - Radius crossing pole
  - Radius crossing anti-meridian
  - Query centered at pole
  - Query result exactly at radius boundary (include/exclude test)
  - Overlapping radius with same entity at multiple timestamps

#### Scenario: Polygon query edge cases

- **WHEN** testing polygon queries
- **THEN** test cases SHALL include:
  - Minimum polygon (3 vertices - triangle)
  - Maximum polygon (10,000 vertices)
  - Concave polygons
  - Self-intersecting polygons (SHALL reject or correct)
  - Polygon crossing anti-meridian
  - Polygon containing a pole
  - Very thin "sliver" polygons (numerical precision test)
  - Clockwise vs counter-clockwise winding order

#### Scenario: Coordinate validation edge cases

- **WHEN** testing coordinate validation
- **THEN** test cases SHALL include:
  - Exactly ±90,000,000,000 nanodegrees latitude (boundary)
  - Exactly ±180,000,000,000 nanodegrees longitude (boundary)
  - One nanodegree beyond valid range (SHALL reject)
  - NaN-equivalent patterns in i64 (SHALL reject)
  - Altitude extremes (Mariana Trench to Everest + margin)

### Requirement: TTL Testing Scenarios

The system SHALL include comprehensive test scenarios for TTL expiration.

#### Scenario: TTL boundary conditions

- **WHEN** testing TTL expiration
- **THEN** test cases SHALL include:
  - TTL=0 (never expires)
  - TTL=1 second (minimum, rapid expiration)
  - TTL=maxInt(u32) (136 years, effectively infinite)
  - Event expiring during query execution
  - Event expiring during compaction
  - Event expiring during backup
  - Multiple events for same entity with different TTLs

#### Scenario: TTL clock edge cases

- **WHEN** testing TTL with clock variations
- **THEN** test cases SHALL include:
  - TTL calculation near u64 overflow
  - Imported events with old timestamps + TTL (already expired on import)
  - Clock skew between replicas affecting expiration order

### Requirement: Security Testing Scenarios

The system SHALL include test scenarios for security features.

#### Scenario: TLS edge cases

- **WHEN** testing TLS
- **THEN** test cases SHALL include:
  - Certificate expiring during active connection
  - Certificate rotation via SIGHUP during TLS handshake
  - Client with revoked certificate (if CRL/OCSP enabled)
  - Mismatched cluster ID in certificate
  - Self-signed certificate (SHALL reject in production mode)
  - Expired CA certificate

#### Scenario: Rate limiting validation

- **WHEN** testing rate limiting
- **THEN** test cases SHALL include:
  - Connection flood from single IP
  - Slow loris attack (slow request sending)
  - Large batch near message_size_max
  - Concurrent queries exceeding CPU budget

### Related Specifications

- See `specs/replication/spec.md` for VSR protocol to be tested (view changes, state sync)
- See `specs/storage-engine/spec.md` for storage fault injection targets (superblock, WAL, grid)
- See `specs/query-engine/spec.md` for query operations to be tested deterministically
- See `specs/hybrid-memory/spec.md` for index concurrency testing requirements
- See `specs/error-codes/spec.md` for error scenarios to test
- See `specs/observability/spec.md` for metrics to verify during simulation
