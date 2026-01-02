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
  - **TigerBeetle version:** 0.15.6 (pinned; see `openspec/changes/add-geospatial-core/DECISIONS.md`)
  - **Commit reference:** `c0178117c4de45a403cda40667e3d608a681f484` (pinned; see `openspec/changes/add-geospatial-core/DECISIONS.md`)
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
- **THEN** the team SHALL:
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

The system SHALL maintain communication with TigerBeetle team during implementation.

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

The system SHALL distinguish between TigerBeetle-borrowed patterns (marked with `// From TigerBeetle:` comments) and geospatial-specific implementations (marked with `// ArcherDB-specific:`).

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

### Requirement: Algorithm Pseudocode for Complex Implementations

The system SHALL provide detailed algorithm pseudocode for complex operations to guide implementation.

#### Scenario: Marzullo's Clock Synchronization Algorithm

- **WHEN** implementing Byzantine clock synchronization
- **THEN** use this algorithm:
  ```
  Marzullo's Algorithm (Byzantine Clock Sync)
  ══════════════════════════════════════════════

  Input: Clock samples from N replicas (via ping/pong)
  Output: Consensus time interval or Byzantine detection error

  Step 1: Collect samples
    For each replica i:
      local_time[i] = replica i's reported time
      rtt[i] = round-trip time to replica i
      lower[i] = local_time[i] - (rtt[i] / 2)  // Earliest possible time
      upper[i] = local_time[i] + (rtt[i] / 2)  // Latest possible time

  Step 2: Build interval array
    intervals = []
    For each replica i:
      intervals.append((lower[i], +1))  // Interval start, increment
      intervals.append((upper[i], -1))  // Interval end, decrement
    intervals.sort()  // Sort by timestamp

  Step 3: Find best interval (maximum overlap)
    best_count = 0
    best_start = 0
    best_end = 0
    current_count = 0

    For each (timestamp, delta) in intervals:
      current_count += delta
      if current_count > best_count:
        best_count = current_count
        best_start = timestamp
        best_end = next interval start (or current if last)

  Step 4: Byzantine detection
    f = floor((N - 1) / 3)  // Max Byzantine replicas tolerated
    required_honest = f + 1  // Need at least f+1 consistent replicas

    if best_count < required_honest:
      return ERROR: "Byzantine clock skew detected"
      // Fewer than f+1 replicas have consistent clocks

  Step 5: Select consensus time
    consensus_time = (best_start + best_end) / 2  // Midpoint of intersection
    return consensus_time

  Example (3 replicas, f=0, need 1 consistent):
    Replica 0: [1000-10, 1000+10] = [990, 1010]
    Replica 1: [1005-5,  1005+5]  = [1000, 1010]
    Replica 2: [1100-10, 1100+10] = [1090, 1110]

    Intervals: [(990,+1), (1000,+1), (1010,-1), (1010,-1), (1090,+1), (1110,-1)]
    Sorted:    [(990,+1), (1000,+1), (1010,-1), (1010,-1), (1090,+1), (1110,-1)]

    Counts: 1, 2, 1, 0, 1, 0
    Best: count=2 at [1000, 1010]
    Consensus: (1000 + 1010) / 2 = 1005

    Result: Replicas 0 and 1 agree, replica 2 is outlier (Byzantine or lagging)
  ```
- **AND** TigerBeetle implementation: `src/vsr/clock.zig`

#### Scenario: S2 RegionCoverer Algorithm

- **WHEN** implementing S2 region covering for radius/polygon queries
- **THEN** use this algorithm:
  ```
  S2 RegionCoverer Algorithm (Polygon → Cell Ranges)
  ══════════════════════════════════════════════════

  Input: Polygon or Circle (Cap), min_level, max_level, max_cells
  Output: List of S2 cell ID ranges covering the region

  Step 1: Initialize covering
    covering = []
    initial_cells = get_covering_cells(region, min_level)

  Step 2: Recursive subdivision
    For each cell in initial_cells:
      if cell_level == max_level or covering.len >= max_cells:
        covering.append(cell)  // Use this cell as-is
      else if cell completely contains region:
        covering.append(cell)  // No need to subdivide
      else if cell intersects region:
        children = cell.get_children()  // 4 child cells
        For each child in children:
          if child intersects region:
            covering.append(child)  // Add intersecting children

  Step 3: Convert cells to ID ranges
    ranges = []
    For each cell in covering:
      cell_id = cell.to_id()
      range_start = cell_id
      range_end = cell_id + cell_id_range_size(cell.level)
      ranges.append((range_start, range_end))

  Step 4: Optimize ranges (merge adjacent)
    ranges.sort()  // Sort by range_start
    merged = []
    current = ranges[0]

    For each range in ranges[1..]:
      if range.start == current.end + 1:  // Adjacent
        current.end = range.end  // Merge
      else:
        merged.append(current)
        current = range
    merged.append(current)

    return merged

  Example (100m radius query):
    Center: (37.7749°N, 122.4194°W)  // San Francisco
    Radius: 100 meters
    min_level: 16, max_level: 18, max_cells: 8

    Initial cells at level 16: 1 cell (covers ~240m × 240m)
    Subdivide to level 18: 16 cells possible, pick 8 that intersect circle

    Result: 8 cell ranges covering the 100m radius
    Each range scans level-30 data within that level-18 cell
  ```
- **AND** pure Zig S2 implementation required (no C++ bindings in core)

#### Scenario: LSM Compaction Selection Algorithm

- **WHEN** implementing LSM tree compaction
- **THEN** use TigerBeetle's selection algorithm:
  ```
  LSM Compaction Selection (Leveled Compaction)
  ═══════════════════════════════════════════════

  Input: LSM tree state (tables per level), compaction budget
  Output: Tables to compact, or none if no work needed

  Step 1: Check L0 pressure (special case)
    if L0.table_count >= compaction_trigger_l0 (e.g., 8 tables):
      return compact_l0_to_l1(L0.tables)

  Step 2: Scan levels for size ratio violations
    For level L in [1..max_level-1]:
      size_L = sum(table.size for table in level[L])
      size_L_plus_1 = sum(table.size for table in level[L+1])
      target_ratio = lsm_growth_factor (e.g., 8)

      if size_L * target_ratio > size_L_plus_1:
        // Level L is too large relative to L+1
        return compact_level_to_next(L, L+1)

  Step 3: No compaction needed
    return None

  Step 4: Execute compaction (selected level L → L+1)
    input_tables = level[L].tables + overlapping_tables(level[L+1])
    output_tables = sort_merge(input_tables)  // K-way merge

    For each output_table:
      Write to grid (allocate blocks from free_set)
      Add to level[L+1]

    Remove input_tables from level[L] and level[L+1]
    Update manifest log

  Example (7-level LSM, growth factor = 8):
    L0: 10 MB (8 tables × 1.25 MB)  → Exceeds trigger, compact to L1
    L1: 80 MB (target)
    L2: 640 MB (target)
    L3: 5.1 GB (target)
    L4: 40.9 GB (target)
    L5: 327 GB (target)
    L6: 2.6 TB (unbounded, final level)
  ```
- **AND** TigerBeetle implementation: `src/lsm/compaction.zig`

#### Scenario: Hash-Chained Prepare Validation

- **WHEN** implementing prepare validation in VSR
- **THEN** use this algorithm:
  ```
  Hash-Chained Prepare Validation
  ═════════════════════════════════

  Input: New prepare message at op=N
  Output: Valid or PANIC (safety critical)

  Step 1: Locate previous prepare
    prev_op = N - 1
    prev_prepare = journal.get(prev_op)

    if prev_prepare == null:
      if prev_op < journal.start_op:
        // Normal: prepare is before WAL window
        return SKIP_VALIDATION
      else:
        PANIC("Gap in journal - missing prepare at op={}", prev_op)

  Step 2: Compute expected parent
    expected_parent = checksum(prev_prepare)

  Step 3: Verify hash chain
    if prepare.parent != expected_parent:
      if prepare.view > prev_prepare.view:
        // Acceptable: view change occurred
        return SKIP_VALIDATION
      else:
        // Same view, hash mismatch = FORK detected
        PANIC("Hash chain break at op={}, view={}", N, prepare.view)

  Step 4: Accept prepare
    return VALID

  Why this matters:
  - Hash chain prevents Byzantine primary from forking
  - If primary sends prepare A to replica 1 and prepare B to replica 2 (same op):
    - Next prepare (op+1) can only chain to either A or B
    - Whichever replica gets prepare with wrong parent detects fork
    - Fork triggers immediate view change (Byzantine primary detected)
  ```
- **AND** TigerBeetle implementation: `src/vsr/journal.zig:verify_hash_chain()`

#### Scenario: Linear Probing Hash Map Algorithm

- **WHEN** implementing the RAM index hash map
- **THEN** use this algorithm:
  ```
  Linear Probing Hash Map (Lock-Free Lookups)
  ═══════════════════════════════════════════

  Structure:
    entries: [*]IndexEntry  // Array of N slots (pre-allocated)
    capacity: u64           // N slots
    load_factor: f32        // Target: 0.70

  Lookup(entity_id) -> ?IndexEntry:
    slot = hash(entity_id) % capacity
    probe_count = 0

    while probe_count < max_probe_length (1024):
      entry = @atomicLoad(*IndexEntry, &entries[slot], .Acquire)

      if entry.entity_id == 0:
        return null  // Empty slot, not found

      if entry.entity_id == entity_id:
        return entry  // Found

      // Collision, continue probing
      slot = (slot + 1) % capacity
      probe_count += 1

    return null  // Probe limit exceeded, not found

  Upsert(entity_id, latest_id, ttl_seconds):
    slot = hash(entity_id) % capacity
    probe_count = 0

    while probe_count < max_probe_length (1024):
      entry = @atomicLoad(*IndexEntry, &entries[slot], .Acquire)

      if entry.entity_id == 0:
        // Empty slot, insert new
        new_entry = IndexEntry{
          .entity_id = entity_id,
          .latest_id = latest_id,
          .ttl_seconds = ttl_seconds,
          // ...
        }
        @atomicStore(*IndexEntry, &entries[slot], new_entry, .Release)
        return OK

      if entry.entity_id == entity_id:
        // Found, check LWW
        new_ts = @as(u64, @truncate(latest_id))
        old_ts = @as(u64, @truncate(entry.latest_id))

        if new_ts > old_ts:
          // New write wins
          entry.latest_id = latest_id
          entry.ttl_seconds = ttl_seconds
          @atomicStore(*IndexEntry, &entries[slot], entry, .Release)
        // else: old write wins, ignore new
        return OK

      // Different entity, probe next
      slot = (slot + 1) % capacity
      probe_count += 1

    return ERROR: index_degraded  // Probe limit exceeded

  Why linear probing?
  - Cache-friendly (sequential memory access)
  - Simple (no pointer chasing like chaining)
  - Good performance at load factor < 0.7
  - Bounded probe length prevents infinite loops
  ```

#### Scenario: Free Set Block Allocation Algorithm

- **WHEN** implementing grid block allocation
- **THEN** use TigerBeetle's free set algorithm:
  ```
  Free Set Block Allocation (Reservation System)
  ══════════════════════════════════════════════

  Structure:
    shards: [4096]Shard  // 4096 shards × 4096 bits = 16M blocks
    Shard = BitSet(4096 bits)

  Reserve(count: u64) -> ?ReservationID:
    // Reserve 'count' blocks for future allocation
    shard_id = current_shard  // Round-robin or random
    reservation_id = generate_reservation_id()

    blocks_reserved = 0
    while blocks_reserved < count:
      if shard[shard_id].has_free_blocks():
        block_addr = shard[shard_id].find_first_free()
        shard[shard_id].mark_reserved(block_addr, reservation_id)
        blocks_reserved += 1
      else:
        shard_id = (shard_id + 1) % 4096  // Try next shard
        if shard_id == current_shard:
          return ERROR: disk_full  // Wrapped around, no space

    return reservation_id

  Acquire(reservation_id, block_index) -> BlockAddress:
    // Convert reservation to actual block address
    block = find_reserved_block(reservation_id, block_index)
    shard[block.shard_id].mark_acquired(block.addr)
    return block.addr

  Forfeit(reservation_id):
    // Cancel reservation, return blocks to free pool
    blocks = find_all_reserved_blocks(reservation_id)
    For each block in blocks:
      shard[block.shard_id].mark_free(block.addr)

  Why sharded design?
  - Reduces contention (4096 independent shard locks)
  - Enables parallel compaction (each shard independent)
  - Bounded search time per shard (4096 bits = 64 u64 words)
  ```
- **AND** TigerBeetle implementation: `src/vsr/free_set.zig`

#### Scenario: Flexible Paxos Quorum Validation

- **WHEN** validating quorum configuration
- **THEN** use this validation algorithm:
  ```
  Flexible Paxos Quorum Validation
  ═══════════════════════════════

  Input: replica_count, quorum_replication, quorum_view_change
  Output: Valid or ERROR with explanation

  Step 1: Bounds check
    if quorum_replication < 1 or quorum_replication > replica_count:
      return ERROR: "quorum_replication out of bounds"

    if quorum_view_change < 1 or quorum_view_change > replica_count:
      return ERROR: "quorum_view_change out of bounds"

  Step 2: Intersection property (CRITICAL)
    if quorum_replication + quorum_view_change <= replica_count:
      return ERROR: "Quorum intersection property violated"
      // Explanation: No guarantee that replication quorum and
      // view change quorum share at least one replica

  Step 3: Single replica special case
    if replica_count == 1:
      if quorum_replication != 1 or quorum_view_change != 1:
        return ERROR: "Single replica requires both quorums = 1"

  Step 4: Accept configuration
    return VALID

  Examples:
    replica_count=3, quorum_replication=2, quorum_view_change=2
    → 2 + 2 = 4 > 3 ✅ VALID (intersection guaranteed)

    replica_count=5, quorum_replication=3, quorum_view_change=3
    → 3 + 3 = 6 > 5 ✅ VALID (classic majority)

    replica_count=4, quorum_replication=2, quorum_view_change=2
    → 2 + 2 = 4 NOT > 4 ❌ INVALID (no intersection guaranteed)

    replica_count=4, quorum_replication=2, quorum_view_change=3
    → 2 + 3 = 5 > 4 ✅ VALID (Flexible Paxos: faster replication, slower view change)
  ```

#### Scenario: Checkpoint Quorum Read Algorithm

- **WHEN** implementing superblock/checkpoint quorum reads
- **THEN** use this algorithm:
  ```
  Checkpoint Quorum Read (Superblock Recovery)
  ═══════════════════════════════════════════

  Input: superblock_copies (4, 6, or 8), copy_size
  Output: Valid superblock with highest sequence, or PANIC

  Step 1: Read all copies
    copies = []
    For copy_index in 0..superblock_copies:
      offset = copy_index * copy_size
      copy = read_from_disk(offset, copy_size)
      copies.append(copy)

  Step 2: Validate checksums
    valid_copies = []
    For each copy in copies:
      if verify_checksum(copy.checksum, copy.data):
        if copy.copy_index == actual_index:  // Prevent misdirection
          valid_copies.append(copy)

  Step 3: Find highest sequence
    if valid_copies.len == 0:
      PANIC("All superblock copies corrupted - unrecoverable")

    best_copy = valid_copies[0]
    For each copy in valid_copies[1..]:
      if copy.sequence > best_copy.sequence:
        best_copy = copy

  Step 4: Return best copy
    return best_copy

  Why quorum reads?
  - Superblock stores critical VSR state (view, op, commit_max)
  - Torn write during checkpoint may corrupt one copy
  - Multiple copies (4-8) ensure at least one survives
  - Sequence number enables selecting latest valid copy
  - Copy index prevents accidentally using wrong copy slot
  ```
- **AND** TigerBeetle implementation: `src/vsr/superblock.zig:read_quorum()`

#### Scenario: CTRL Protocol Algorithm (View Change Log Selection)

- **WHEN** implementing view change log selection
- **THEN** use this CTRL algorithm:
  ```
  CTRL Protocol (Canonical Replicated Truncation Log)
  ═══════════════════════════════════════════════════

  Input: DoViewChange messages from quorum_view_change replicas
  Output: Canonical log suffix to broadcast in StartView

  Step 1: Collect log states
    log_states = []
    For each DoViewChange msg in quorum:
      log_states.append({
        replica: msg.replica,
        op: msg.op,  // Highest op this replica has
        commit_min: msg.commit_min,  // Highest committed op
        present_bitset: msg.present_bitset,  // Which ops it has
        nack_bitset: msg.nack_bitset,  // Which ops it lacks
      })

  Step 2: Select replica with highest op
    primary_log = log_states[0]
    For each log_state in log_states[1..]:
      if log_state.op > primary_log.op:
        primary_log = log_state

  Step 3: Build canonical log suffix
    canonical_log = []
    For op in [commit_min+1 .. primary_log.op]:
      # Find which replicas have this op
      replicas_with_op = []
      For each log_state in log_states:
        if log_state.present_bitset.is_set(op):
          replicas_with_op.append(log_state.replica)

      if replicas_with_op.len > 0:
        # At least one replica has it - include in canonical log
        # Request prepare from any replica that has it
        canonical_log.append(op)

  Step 4: Fill gaps
    For each op in canonical_log:
      if not local_journal.has(op):
        request_prepare(op, from_replica=replicas_with_op[0])

  Step 5: Broadcast StartView
    start_view.log_suffix = canonical_log
    broadcast_to_all_replicas(start_view)

  Why CTRL is needed:
  - After view change, replicas may have different log suffixes
  - Need to agree on ONE canonical log to continue
  - CTRL selects log with most progress (highest op)
  - Fills gaps by requesting prepares from replicas that have them
  - Ensures all replicas converge to identical log
  ```
- **AND** TigerBeetle implementation: `src/vsr/replica.zig:on_do_view_change()`

#### Scenario: S2 Cell Hierarchy Traversal Algorithm

- **WHEN** implementing S2 cell parent/child navigation
- **THEN** use this algorithm:
  ```
  S2 Cell Hierarchy Traversal (Parent/Child Navigation)
  ═══════════════════════════════════════════════════

  S2 cell ID encoding (64-bit):
  - Bits 0-2: Face (0-5, six cube faces)
  - Bits 3-62: Hilbert curve position (2 bits per level, 30 levels)
  - Bit 63: Unused

  Get Parent (move up one level):
    parent_id(cell_id, current_level):
      if current_level == 0:
        return cell_id  // Already at root, no parent

      # Truncate last 2 bits (remove one level)
      shift = 2 * (30 - current_level + 1)
      parent = cell_id >> 2
      return parent

  Get Children (move down one level):
    children_ids(cell_id, current_level):
      if current_level == 30:
        return []  // Already at leaf, no children

      children = []
      For child_index in [0, 1, 2, 3]:  // 4 children per cell
        child = (cell_id << 2) | child_index
        children.append(child)
      return children

  Get Level from Cell ID:
    level(cell_id):
      # Count trailing zero pairs
      zeros = count_trailing_zeros(cell_id)
      level = 30 - (zeros / 2)
      return level

  Example:
    Cell at level 28 (2 levels from leaf):
      cell_id: 0b...101100 (trailing 4 bits = 2 levels of zeros)
      level: 30 - (4/2) = 28

    Parent (level 27):
      parent_id = cell_id >> 2  // Truncate 2 bits
      parent_id: 0b...1011

    Children (level 29):
      child_0: (cell_id << 2) | 0b00 = 0b...10110000
      child_1: (cell_id << 2) | 0b01 = 0b...10110001
      child_2: (cell_id << 2) | 0b10 = 0b...10110010
      child_3: (cell_id << 2) | 0b11 = 0b...10110011
  ```
- **AND** pure Zig S2 implementation must maintain this bit structure

#### Scenario: Skip-Scan Optimization Algorithm (Block Min/Max)

- **WHEN** implementing spatial range scans with skip-scan optimization
- **THEN** use this algorithm:
  ```
  Skip-Scan with Block Min/Max (Range Query Optimization)
  ══════════════════════════════════════════════════════

  Input: query_range [start_id, end_id], LSM table blocks
  Output: GeoEvents matching range (filtered efficiently)

  Step 1: Iterate blocks
    results = []
    For each block in table.blocks:
      header = block.header  // 256-byte header with min_id, max_id

      # Skip-scan decision (using header only, no body read)
      if header.max_id < query_range.start:
        continue  // Block entirely before range, skip

      if header.min_id > query_range.end:
        continue  // Block entirely after range, skip

      # Block intersects range, must read body
      body = read_block_body(block.address)

      # Scan events in block
      For event in body.events[0..header.count]:
        if event.id >= query_range.start and event.id <= query_range.end:
          results.append(event)

    return results

  Performance analysis:
  - Without skip-scan: Read 1000 blocks × 64KB = 64MB
  - With skip-scan (10% match): Read 100 blocks × 64KB = 6.4MB
  - Savings: 90% I/O reduction for selective queries

  Example (radius query, ~5% of data in range):
    Total blocks: 10,000
    Blocks scanned (headers): 10,000 (sequential read, fast)
    Blocks skipped: 9,500 (header.min_id > end OR header.max_id < start)
    Blocks read (bodies): 500 (intersect range)
    I/O saved: 95% reduction (9,500 × 64KB not read)

  Header read cost: 256 bytes × 10,000 = 2.5MB (negligible)
  Body read cost: 64KB × 500 = 32MB (reduced from 640MB)
  ```
- **AND** skip-scan is critical for spatial query performance

### Requirement: Cross-Spec Dependency Matrix

The system SHALL provide explicit dependency relationships between specifications to guide implementation order.

#### Scenario: Specification dependency table

- **WHEN** planning implementation sequence
- **THEN** the following dependency matrix SHALL guide execution:

```
┌──────────────────────┬─────────────────────────────┬─────────────────────────────┐
│ Specification        │ Depends On (Prerequisites) │ Provides To (Consumers)     │
├──────────────────────┼─────────────────────────────┼─────────────────────────────┤
│ constants            │ (none)                      │ All specs                   │
│ data-model           │ constants                   │ query-engine, storage       │
│ error-codes          │ (none)                      │ All specs                   │
│ interfaces           │ data-model, error-codes     │ All implementation specs    │
├──────────────────────┼─────────────────────────────┼─────────────────────────────┤
│ memory-management    │ constants                   │ All specs (StaticAllocator) │
│ io-subsystem         │ memory-management           │ storage, replication        │
│ storage-engine       │ io-subsystem, data-model    │ query-engine, replication   │
│ hybrid-memory        │ data-model, constants       │ query-engine                │
├──────────────────────┼─────────────────────────────┼─────────────────────────────┤
│ replication          │ storage-engine, io          │ query-engine                │
│ query-engine         │ storage, hybrid-memory      │ client-protocol             │
│ client-protocol      │ query-engine, error-codes   │ client-sdk, security        │
│ client-sdk           │ client-protocol             │ (user applications)         │
├──────────────────────┼─────────────────────────────┼─────────────────────────────┤
│ security             │ client-protocol, io         │ (all runtime components)    │
│ observability        │ query-engine, storage       │ commercial (cost tracking)  │
│ ttl-retention        │ data-model, query-engine    │ storage (compaction)        │
│ backup-restore       │ storage-engine              │ (disaster recovery)         │
├──────────────────────┼─────────────────────────────┼─────────────────────────────┤
│ testing-simulation   │ All core specs              │ (validation)                │
│ configuration        │ All core specs              │ (runtime config)            │
│ ci-cd                │ testing, configuration      │ (build/deploy)              │
│ licensing            │ (none)                      │ (legal compliance)          │
└──────────────────────┴─────────────────────────────┴─────────────────────────────┘
```

#### Scenario: Critical dependency paths

- **WHEN** implementing features end-to-end
- **THEN** these critical paths SHALL be followed:

**Path 1: Write Operation (Insert Event)**
```
constants → data-model → query-engine (input_valid, prepare, commit)
         ↓              ↓
         ↓              → hybrid-memory (upsert index)
         ↓              ↓
         ↓              → storage-engine (LSM write)
         ↓              ↓
         → replication (VSR consensus)
```

**Path 2: Read Operation (UUID Lookup)**
```
constants → client-protocol → query-engine (prefetch, commit)
                           ↓
                           → hybrid-memory (lookup)
                           ↓
                           → storage-engine (fetch by ID)
```

**Path 3: TTL Expiration (Cleanup)**
```
data-model (ttl_seconds) → query-engine (expiration check)
                        ↓
                        → ttl-retention (cleanup operation)
                        ↓
                        → storage-engine (LSM compaction)
                        ↓
                        → hybrid-memory (index removal)
```

#### Scenario: Circular dependency prevention

- **WHEN** designing specifications
- **THEN** the following patterns SHALL prevent circular dependencies:
  - **Interfaces spec**: Defines contracts, no implementation → Breaks cycles
  - **Constants spec**: Pure data, no logic → Foundation for all
  - **Error codes spec**: Enums only → Universal reference
  - **Query-engine uses storage via interface**: Not direct import
  - **Storage uses query-engine via callback**: Inversion of control

#### Scenario: Implementation phase ordering

- **WHEN** implementing in phases
- **THEN** phases SHALL respect dependencies:

```
PHASE 0 (Foundation):
  constants → data-model → error-codes → interfaces
  └─ No dependencies, can be done in parallel

PHASE 1 (Core Infrastructure):
  memory-management → io-subsystem → storage-engine
  └─ Sequential: each phase depends on previous

PHASE 2 (Indexing & Replication):
  hybrid-memory + replication (can be parallel)
  └─ Both depend on storage-engine

PHASE 3 (Query & Protocol):
  query-engine → client-protocol → client-sdk
  └─ Sequential: protocol depends on query, SDK depends on protocol

PHASE 4 (Cross-Cutting):
  security + observability + ttl-retention (parallel)
  └─ All depend on core stack being complete

PHASE 5 (Operations):
  testing-simulation + configuration + ci-cd (parallel)
  └─ Validation layer on top of everything
```

### Related Specifications

- See `specs/replication/spec.md` for complete VSR protocol (Marzullo's, Flexible Paxos, CTRL)
- See `specs/storage-engine/spec.md` for Free Set and LSM implementation details
- See `specs/query-engine/spec.md` for S2 RegionCoverer usage in queries
- See `specs/hybrid-memory/spec.md` for linear probing hash map implementation
- See `specs/constants/spec.md` for algorithm configuration parameters
