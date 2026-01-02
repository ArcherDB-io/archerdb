# Implementation Guide Specification

**Primary Reference:** https://github.com/tigerbeetle/tigerbeetle

---

## ADDED Requirements

### Requirement: TigerBeetle as Reference Implementation

The system SHALL use TigerBeetle's actual source code as the authoritative reference for all borrowed patterns and implementations.

#### Scenario: Implementation methodology

- **WHEN** implementing any component described in these specifications
- **THEN** implementers SHALL:
  1. Read the corresponding TigerBeetle source code files (listed below)
  2. Understand the pattern as implemented by TigerBeetle
  3. Adapt the pattern to ArcherDB's geospatial domain
  4. Preserve TigerBeetle's safety guarantees and optimizations
  5. When specification is ambiguous, TigerBeetle's code is authoritative

#### Scenario: Pattern reuse philosophy

- **WHEN** encountering implementation decisions
- **THEN** the priority SHALL be:
  1. **First:** Check if TigerBeetle has solved this problem
  2. **If yes:** Reuse TigerBeetle's solution (adapt domain types)
  3. **If no:** Design new solution following TigerBeetle's principles
  4. **Never:** Reinvent patterns that TigerBeetle has proven

### Requirement: TigerBeetle File Reference Map

The system SHALL document which TigerBeetle files correspond to each ArcherDB component.

#### Scenario: VSR Replication (specs/replication/spec.md)

- **WHEN** implementing VSR replication
- **THEN** study these TigerBeetle files:
  ```
  src/vsr/replica.zig              → Core VSR state machine
  src/vsr/journal.zig              → WAL with hash-chained prepares
  src/vsr/clock.zig                → Marzullo's algorithm (clock sync)
  src/vsr/client_sessions.zig      → Session management for idempotency
  src/vsr/commit_stage.zig         → Pipeline stages (prepare/prefetch/commit)
  ```
- **AND** preserve the exact protocol message flow
- **AND** adapt state_machine interface to GeoEvent operations

#### Scenario: Storage Engine (specs/storage-engine/spec.md)

- **WHEN** implementing storage engine
- **THEN** study these TigerBeetle files:
  ```
  src/storage.zig                  → Data file zones, superblock, grid
  src/vsr/superblock.zig           → Superblock structure with hash-chaining
  src/vsr/free_set.zig             → Block allocation with bitsets
  src/lsm/manifest_log.zig         → LSM manifest log
  src/lsm/table.zig                → LSM table structure (index + value blocks)
  src/lsm/compaction.zig           → Compaction selection and sort-merge
  ```
- **AND** reuse data file zone layout exactly
- **AND** adapt LSM to store GeoEvent instead of Account/Transfer

#### Scenario: Memory Management (specs/memory-management/spec.md)

- **WHEN** implementing memory management
- **THEN** study these TigerBeetle files:
  ```
  src/stdx.zig                     → Intrusive data structures, utilities
  src/message_pool.zig             → Message pooling with reference counting
  src/lsm/node_pool.zig            → NodePool with bitset tracking
  src/lsm/table_memory.zig         → TableMemory (mutable/immutable tables)
  ```
- **AND** copy StaticAllocator discipline exactly (init/static/deinit states)
- **AND** use intrusive linked lists (QueueType, StackType) for zero allocation

#### Scenario: I/O Subsystem (specs/io-subsystem/spec.md)

- **WHEN** implementing I/O subsystem
- **THEN** study these TigerBeetle files:
  ```
  src/io/linux.zig                 → io_uring integration, completion handling
  src/io/darwin.zig                → macOS kqueue fallback
  src/io/windows.zig               → Windows IOCP implementation
  src/message_bus.zig              → Connection state machine, TCP config
  ```
- **AND** reuse io_uring submission/completion patterns
- **AND** copy zero-copy optimization (single-message fast path)
- **AND** use identical TCP configuration (nodelay, keepalive, buffer sizing)

#### Scenario: Testing & Simulation (specs/testing-simulation/spec.md)

- **WHEN** implementing VOPR simulator
- **THEN** study these TigerBeetle files:
  ```
  src/simulator.zig                → Deterministic simulation framework
  src/testing/storage.zig          → Storage fault injection
  src/testing/cluster.zig          → Multi-replica simulation
  src/testing/state_machine.zig    → State machine wrapper for testing
  src/vsr/replica_test.zig         → Property-based test examples
  ```
- **AND** copy deterministic PRNG seeding strategy
- **AND** reuse fault injection enums (Storage/Network/Timing faults)
- **AND** implement two-phase testing (safety then liveness)

#### Scenario: Query Engine (specs/query-engine/spec.md)

- **WHEN** implementing state machine
- **THEN** study these TigerBeetle files:
  ```
  src/state_machine.zig            → StateMachine interface (input_valid, prepare, prefetch, commit)
  src/tigerbeetle.zig              → State machine for Account/Transfer operations
  ```
- **AND** implement identical three-phase model
- **AND** replace Account/Transfer with GeoEvent/SpatialQuery operations
- **AND** preserve deterministic timestamp assignment

#### Scenario: Data Model (specs/data-model/spec.md)

- **WHEN** implementing data structures
- **THEN** study these TigerBeetle files:
  ```
  src/tigerbeetle.zig              → Account and Transfer struct definitions (128-byte examples)
  src/stdx.zig                     → no_padding() verification utility
  ```
- **AND** use extern struct with explicit layout
- **AND** add comptime size/alignment assertions
- **AND** follow field ordering (largest alignment first)

### Requirement: TigerBeetle Version Compatibility

The system SHALL document which TigerBeetle version the patterns are based on.

#### Scenario: Reference version

- **WHEN** implementing from TigerBeetle patterns
- **THEN** the reference version SHALL be:
  - **TigerBeetle version:** 0.15.x series (current stable as of 2025)
  - **Commit reference:** Latest main branch commit at implementation start
  - **Repository:** https://github.com/tigerbeetle/tigerbeetle
- **AND** document specific commit SHA in implementation code comments

#### Scenario: Pattern evolution

- **WHEN** TigerBeetle releases improvements
- **THEN** ArcherDB MAY adopt them:
  - Monitor TigerBeetle releases for performance/safety improvements
  - Backport applicable patterns to ArcherDB
  - Test thoroughly before production deployment
  - Document TigerBeetle version in release notes

### Requirement: Code Comments Referencing TigerBeetle

The system SHALL include code comments referencing specific TigerBeetle files for complex implementations.

#### Scenario: VSR implementation comments

- **WHEN** implementing VSR protocol logic
- **THEN** code comments SHALL reference TigerBeetle:
  ```zig
  // Based on TigerBeetle src/vsr/replica.zig:send_prepare_ok()
  // See: https://github.com/tigerbeetle/tigerbeetle/blob/main/src/vsr/replica.zig
  fn send_prepare_ok(self: *Replica, prepare: *const Header) void {
      // ... implementation ...
  }
  ```

#### Scenario: Attribution in complex algorithms

- **WHEN** implementing TigerBeetle algorithms
- **THEN** code comments SHALL attribute:
  - Marzullo's algorithm: `// Based on TigerBeetle src/vsr/clock.zig`
  - Hash-chained prepares: `// Based on TigerBeetle src/vsr/journal.zig`
  - CTRL protocol: `// Based on TigerBeetle CTRL view change optimization`
  - Free set: `// Based on TigerBeetle src/vsr/free_set.zig`

### Requirement: Domain Adaptation Documentation

The system SHALL document how TigerBeetle patterns are adapted to the geospatial domain.

#### Scenario: Type substitution

- **WHEN** adapting TigerBeetle patterns
- **THEN** document type substitutions:
  ```
  TigerBeetle         →  ArcherDB
  ────────────────────────────────────
  Account (128B)      →  GeoEvent (128B)
  Transfer (128B)     →  (none - we only have events)
  account_id          →  entity_id
  ledger              →  group_id
  pending/posted      →  ttl/expiration flags
  debit/credit        →  lat/lon coordinates
  user_data           →  user_data (same)
  ```

#### Scenario: Business logic replacement

- **WHEN** replacing TigerBeetle's financial logic
- **THEN** document the substitution:
  ```
  TigerBeetle Financial Logic  →  ArcherDB Geospatial Logic
  ────────────────────────────────────────────────────────────
  Double-entry bookkeeping     →  Last-write-wins (LWW) upserts
  Debit = Credit invariant     →  Spatial validity (lat/lon ranges)
  Pending/Posted transfers     →  TTL expiration
  Account balance              →  Latest location (RAM index)
  Transfer history             →  Movement history (spatial log)
  ```

### Requirement: TigerBeetle License Compliance

The system SHALL comply with TigerBeetle's Apache 2.0 license when borrowing code.

#### Scenario: License attribution

- **WHEN** code is directly adapted from TigerBeetle
- **THEN** file headers SHALL include:
  ```zig
  // Portions adapted from TigerBeetle (Apache 2.0 License)
  // Original: https://github.com/tigerbeetle/tigerbeetle
  // Copyright TigerBeetle, Inc.
  // Modifications for ArcherDB geospatial database
  ```

#### Scenario: Original work

- **WHEN** implementing new geospatial-specific code
- **THEN** standard ArcherDB license applies:
  ```zig
  // Copyright ArcherDB Project
  // Geospatial extensions to TigerBeetle patterns
  ```

### Requirement: Divergence Documentation

The system SHALL document any intentional divergences from TigerBeetle's patterns.

#### Scenario: Divergence justification

- **WHEN** deviating from TigerBeetle's implementation
- **THEN** code comments SHALL explain:
  - What differs from TigerBeetle
  - Why the divergence is necessary
  - What risks it introduces
  - How safety is maintained

**Example:**
```zig
// DIVERGENCE from TigerBeetle: Added ttl_seconds field to GeoEvent
// TigerBeetle: Account/Transfer have no TTL (financial records never expire)
// ArcherDB: Location data expires (configurable per-event TTL)
// Risk: Additional validation needed during compaction
// Safety: Lazy expiration checks + background cleanup task
```

### Requirement: Community Contribution

The system SHALL contribute improvements back to TigerBeetle when applicable.

#### Scenario: Upstream contributions

- **WHEN** ArcherDB discovers bugs or improvements in borrowed TigerBeetle patterns
- **THEN** the team SHOULD:
  - Report bugs to TigerBeetle project
  - Contribute fixes upstream if applicable
  - Share performance optimizations discovered
  - Collaborate on shared infrastructure

#### Scenario: Geospatial-specific patterns

- **WHEN** ArcherDB develops geospatial-specific patterns
- **THEN** these SHALL remain ArcherDB-specific:
  - S2 integration (not relevant to TigerBeetle)
  - Spatial query engine (domain-specific)
  - TTL/expiration (financial ledgers don't need this)

### Requirement: TigerBeetle Team Consultation

The system SHOULD maintain communication with TigerBeetle team during implementation.

#### Scenario: Design validation

- **WHEN** adapting complex TigerBeetle patterns
- **THEN** consider consulting TigerBeetle team:
  - VSR protocol implementation questions
  - Performance optimization techniques
  - Correctness verification
  - Distributed systems edge cases

#### Scenario: Attribution and credit

- **WHEN** releasing ArcherDB
- **THEN** documentation SHALL:
  - Credit TigerBeetle as foundational architecture
  - Link to TigerBeetle project prominently
  - Acknowledge TigerBeetle team's work
  - Encourage users to support TigerBeetle project

### Requirement: Implementation Priority Based on TigerBeetle Complexity

The system SHALL prioritize implementing proven TigerBeetle patterns before custom geospatial features.

#### Scenario: Implementation order

- **WHEN** planning implementation sequence
- **THEN** implement in this order:
  1. **Core Types** (GeoEvent, BlockHeader) - Low risk, TigerBeetle pattern
  2. **Memory Management** (StaticAllocator, pools) - Critical foundation, copy TigerBeetle
  3. **Storage Engine** (data file, superblock) - Reuse TigerBeetle exactly
  4. **I/O Subsystem** (io_uring) - Reuse TigerBeetle exactly
  5. **VSR Protocol** (replica, view changes) - Most complex, follow TigerBeetle precisely
  6. **Query Engine** (state machine) - Adapt TigerBeetle's StateMachine interface
  7. **S2 Integration** (NEW - geospatial-specific) - After foundation stable
  8. **Spatial Queries** (NEW - geospatial-specific) - After S2 works
  9. **TTL/Backup** (NEW - ArcherDB features) - After core proven
  10. **Client SDKs** (adapt TigerBeetle client patterns) - Final layer

#### Scenario: Risk mitigation

- **WHEN** implementing high-risk components
- **THEN** TigerBeetle's proven patterns SHALL be used:
  - **VSR consensus:** Copy TigerBeetle's protocol exactly (proven correct)
  - **Storage corruption detection:** Use Aegis-128L checksums like TigerBeetle
  - **Memory safety:** Use StaticAllocator discipline exactly
  - **Testing:** Use VOPR simulator pattern before any custom tests

### Requirement: TigerBeetle Debugging Techniques

The system SHALL adopt TigerBeetle's debugging and verification techniques.

#### Scenario: Assertions and invariants

- **WHEN** implementing critical code paths
- **THEN** use TigerBeetle's assertion patterns:
  ```zig
  // Based on TigerBeetle's extensive use of assert()
  assert(self.status == .normal);
  assert(self.view >= self.log_view);
  assert(prepare.header.checksum == self.calculate_checksum(prepare));
  ```
- **AND** assertions remain enabled in production (like TigerBeetle)
- **AND** assertion failures cause immediate panic (fail-fast)

#### Scenario: Comptime verification

- **WHEN** defining data structures
- **THEN** use comptime checks like TigerBeetle:
  ```zig
  comptime {
      assert(@sizeOf(GeoEvent) == 128);
      assert(@alignOf(GeoEvent) == 16);
      stdx.no_padding(GeoEvent);  // From TigerBeetle's stdx.zig
  }
  ```

#### Scenario: Logging patterns

- **WHEN** adding log statements
- **THEN** follow TigerBeetle's patterns:
  - Use std.log with structured fields
  - Log state transitions explicitly
  - Include view/op numbers in VSR logs
  - Log timing information for performance debugging

### Requirement: TigerBeetle Constants Reuse

The system SHALL reuse TigerBeetle's constant naming conventions and values where applicable.

#### Scenario: Constant naming

- **WHEN** defining constants
- **THEN** use TigerBeetle's naming pattern:
  ```zig
  // TigerBeetle naming style (from src/constants.zig)
  // NOTE: ArcherDB values differ - see constants/spec.md for authoritative values
  // Example: ArcherDB uses journal_slot_count = 8192 (not 1024) for 60s checkpoint support
  pub const message_size_max = 10 * 1024 * 1024;  // Same as TigerBeetle
  pub const journal_slot_count = 8192;             // ArcherDB: 8192 (TigerBeetle: 1024)
  pub const pipeline_max = 256;                    // Same as TigerBeetle
  pub const checkpoint_interval = 256;             // Same as TigerBeetle
  ```
- **AND** use snake_case with descriptive suffixes
- **AND** include comments explaining derivation

#### Scenario: Derived constants

- **WHEN** constants depend on TigerBeetle values
- **THEN** document the relationship:
  ```zig
  // Based on TigerBeetle's block_size = 64KB
  pub const block_size = 64 * 1024;
  pub const block_header_size = 256; // BlockHeader at start of each block

  // Derived from TigerBeetle's events_per_block pattern
  // Accounts for 256-byte BlockHeader
  pub const events_per_block = (block_size - block_header_size) / geo_event_size; // 510 events
  ```

### Requirement: TigerBeetle Testing Patterns

The system SHALL adopt TigerBeetle's testing methodology.

#### Scenario: Simulator-based testing

- **WHEN** testing distributed system behavior
- **THEN** use TigerBeetle's approach:
  - Deterministic simulation with PRNG seed
  - Fault injection at multiple layers
  - Two-phase testing (safety properties first, liveness second)
  - Seed-based replay for bug reproduction
  - State machine invariant checking

#### Scenario: Fuzzing strategy

- **WHEN** fuzzing the system
- **THEN** follow TigerBeetle's patterns:
  - Generate random but valid operation sequences
  - Inject faults deterministically
  - Verify state machine invariants after each operation
  - Save failing seeds for regression tests

### Requirement: Performance Optimization Patterns

The system SHALL adopt TigerBeetle's performance optimization techniques.

#### Scenario: Cache alignment

- **WHEN** defining data structures
- **THEN** follow TigerBeetle's alignment strategy:
  - Align structures to cache line boundaries (64 or 128 bytes)
  - Use `align(N)` attribute explicitly
  - Pack fields to minimize padding
  - Verify with `stdx.no_padding()`

#### Scenario: Zero-copy techniques

- **WHEN** implementing message handling
- **THEN** use TigerBeetle's zero-copy patterns:
  - Wire format = memory format (extern struct)
  - @ptrCast for buffer reinterpretation
  - Pre-allocated MessagePool (no runtime malloc)
  - Reference counting for shared messages

#### Scenario: Batching

- **WHEN** implementing operations
- **THEN** follow TigerBeetle's batching approach:
  - Batch-only API (refuse single operations)
  - Multi-batch encoding (amortize consensus cost)
  - Trailer-based batch metadata
  - Deterministic timestamp distribution across batches

### Requirement: Safety and Correctness Patterns

The system SHALL adopt TigerBeetle's safety-critical programming practices.

#### Scenario: Error handling

- **WHEN** handling errors
- **THEN** follow TigerBeetle's patterns:
  - Use Zig's error unions (`!Type`)
  - Explicit error handling (no try-catch, check every error)
  - Fail-fast on assertions (don't mask bugs)
  - Log errors with context before panicking

#### Scenario: Undefined behavior prevention

- **WHEN** writing code
- **THEN** avoid undefined behavior like TigerBeetle:
  - No uninitialized memory reads
  - No out-of-bounds array access
  - No integer overflow (check explicitly)
  - Use `-OReleaseSafe` in production (keep runtime checks)

### Requirement: Documentation Style

The system SHALL adopt TigerBeetle's documentation style for code comments.

#### Scenario: Function documentation

- **WHEN** documenting functions
- **THEN** use TigerBeetle's style:
  ```zig
  /// Prepare operation (primary only, before consensus).
  /// Assigns timestamps and calculates deltas.
  /// Asserts:
  ///   - operation is valid
  ///   - body size matches expected format
  /// Returns: timestamp delta for this operation
  pub fn prepare(self: *StateMachine, operation: Operation, body: []const u8) u64 {
      assert(self.status == .normal);
      // ...
  }
  ```
- **AND** document preconditions (assertions)
- **AND** document postconditions (what changes)
- **AND** reference TigerBeetle source for complex algorithms

### Requirement: Build and Deployment Patterns

The system SHALL adopt TigerBeetle's build system patterns where applicable.

#### Scenario: Build configuration

- **WHEN** setting up build system
- **THEN** reference TigerBeetle's approach:
  - Single `build.zig` for entire project
  - Compile-time configuration (no runtime ifdefs)
  - Cross-compilation support (Linux/macOS/Windows)
  - Static linking where possible

#### Scenario: Release optimization levels

- **WHEN** building for production
- **THEN** use TigerBeetle's optimization strategy:
  - `-OReleaseSafe` (default) - keep runtime safety checks
  - NOT `-OReleaseFast` (removes bounds checking)
  - Enable LTO (Link-Time Optimization)
  - Enable PGO (Profile-Guided Optimization) for hot paths

### Requirement: Open Questions Resolution via TigerBeetle

The system SHALL resolve specification ambiguities by consulting TigerBeetle's implementation.

#### Scenario: Specification ambiguity

- **WHEN** a specification is unclear or ambiguous
- **THEN** the resolution process SHALL be:
  1. Check if TigerBeetle has solved this problem
  2. Read TigerBeetle's code for that component
  3. Understand how TigerBeetle handles it
  4. Adopt TigerBeetle's approach (unless geospatial-specific)
  5. Document the decision with TigerBeetle reference

#### Scenario: Implementation detail omission

- **WHEN** specification omits implementation details
- **THEN** implementers SHALL:
  - NOT make assumptions
  - NOT invent custom solutions
  - Study TigerBeetle's handling of similar cases
  - Follow TigerBeetle's pattern
  - Propose specification update if detail is critical

**Example:** Specification doesn't detail exact PrepareOk quorum tracking → Study `src/vsr/replica.zig:on_prepare_ok()` → Implement same bitfield approach.

### Requirement: Geospatial-Specific Implementation Guidance

The system SHALL clearly distinguish between TigerBeetle-borrowed patterns and geospatial-specific implementations.

#### Scenario: S2 Geometry Library (NEW - Not from TigerBeetle)

- **WHEN** implementing S2 spatial indexing
- **THEN** this is NEW code (not from TigerBeetle):
  - Study S2 geometry papers and Go reference implementation
  - Port core algorithms to Zig (lat/lon ↔ cell_id, Hilbert curve, RegionCoverer)
  - Follow Zig style but NOT TigerBeetle style (different domain)
  - Test extensively (this is custom code without TigerBeetle's battle-testing)

#### Scenario: Hybrid Memory Index (PARTIALLY from TigerBeetle)

- **WHEN** implementing RAM index
- **THEN** this combines patterns:
  - **From TigerBeetle:** Hash map structure, static allocation, no resizing
  - **Custom:** LWW conflict resolution (TigerBeetle doesn't have this)
  - **Custom:** TTL expiration checks (TigerBeetle doesn't have this)
  - **Custom:** Index checkpointing (TigerBeetle's state is deterministically reproducible)

**Guideline:** Borrowed foundation + custom features. Test custom features more heavily.

### Requirement: Version Tracking

The system SHALL track which ArcherDB version corresponds to which TigerBeetle version.

#### Scenario: Release notes

- **WHEN** releasing ArcherDB versions
- **THEN** release notes SHALL include:
  ```markdown
  ## ArcherDB v0.1.0

  Based on TigerBeetle v0.15.3 (commit: abc123...)

  ### TigerBeetle Patterns Used:
  - VSR consensus protocol
  - LSM storage engine
  - Static memory allocation
  - VOPR testing framework

  ### ArcherDB Extensions:
  - S2 spatial indexing
  - Per-entry TTL
  - S3 backup/restore
  ```

#### Scenario: Dependency tracking

- **WHEN** updating TigerBeetle reference version
- **THEN** document in CHANGELOG:
  - Which TigerBeetle version we tracked
  - What changed in TigerBeetle
  - What we adopted from the update
  - What we didn't adopt (and why)
