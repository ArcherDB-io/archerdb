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

#### Scenario: S2 Reference Implementation and Test Vectors

- **WHEN** developing the Zig S2 implementation
- **THEN** the following reference sources SHALL be used:
  ```
  PRIMARY REFERENCE: Google S2 Geometry Library (C++)
  Repository: https://github.com/google/s2geometry
  Version: Pin to specific tagged release (e.g., v0.10.0)

  SECONDARY REFERENCE: Go S2 Library
  Repository: https://github.com/golang/geo
  Path: s2/

  WHY THESE REFERENCES:
  - C++ is the original, authoritative implementation
  - Go port is well-tested and easier to read than C++
  - Both produce identical results for same inputs
  ```
- **AND** test vectors SHALL be extracted from reference implementations
- **AND** bit-for-bit compatibility is REQUIRED for consensus safety

#### Scenario: S2 Test Vector Generation

- **WHEN** creating S2 test vectors
- **THEN** the following process SHALL be used:
  1. **Create test vector generator** (tooling, not core):
     ```
     tools/s2_golden_gen/
     ├── main.go           # Uses golang/geo/s2
     ├── generate.go       # Generates test cases
     └── README.md         # Documents vector format
     ```
  2. **Generate comprehensive test vectors**:
     ```
     testdata/s2/
     ├── cell_id_vectors.tsv        # lat,lon,level → cell_id
     ├── cell_bounds_vectors.tsv    # cell_id → lat_lo,lon_lo,lat_hi,lon_hi
     ├── hilbert_curve_vectors.tsv  # position ↔ cell ordering
     ├── covering_vectors.tsv       # region → cell_ids[]
     ├── distance_vectors.tsv       # point,point → distance_meters
     └── containment_vectors.tsv    # cell,cell → relationship
     ```
  3. **Vector format** (TSV for simplicity):
     ```
     # cell_id_vectors.tsv
     # lat_deg  lon_deg  level  expected_cell_id
     37.7749   -122.4194  30    0x89283082948a948f
     51.5074   -0.1278    30    0x48761cb4e8e87a8f
     -33.8688  151.2093   30    0x31e0bc9e8d6c7a8f
     ```

#### Scenario: S2 Zig Implementation Testing

- **WHEN** implementing S2 in Zig
- **THEN** testing SHALL follow this progression:
  1. **Unit tests** (immediate feedback):
     ```zig
     test "cell_id from lat/lon matches reference" {
         const vectors = @embedFile("testdata/s2/cell_id_vectors.tsv");
         for (parseVectors(vectors)) |v| {
             const actual = S2.cellIdFromLatLon(v.lat, v.lon, v.level);
             try std.testing.expectEqual(v.expected, actual);
         }
     }
     ```
  2. **Property-based tests** (edge cases):
     - Cell ID round-trip: `cellIdFromLatLon(latLonFromCellId(id)) == id`
     - Hierarchy: `parent(child(id)) == id`
     - Containment: `cell.contains(point) == pointInCell(point, cell)`
  3. **Fuzz testing** (unknown unknowns):
     - Random lat/lon inputs
     - Boundary conditions (poles, antimeridian, equator)
     - Degenerate polygons (self-intersecting, very small, very large)

#### Scenario: S2 Cross-Validation During Development

- **WHEN** developing S2 algorithms
- **THEN** cross-validation SHALL be performed:
  ```
  DEVELOPMENT WORKFLOW:

  1. Implement algorithm in Zig
  2. Run against golden vectors (must pass 100%)
  3. Generate random test cases
  4. Run same cases through Go reference (via test harness)
  5. Compare results bit-for-bit
  6. Investigate ANY discrepancy (no tolerance)

  CONTINUOUS VALIDATION:
  - CI runs all golden vector tests
  - Nightly: regenerate vectors from latest reference, diff
  - Pre-release: full cross-validation suite
  ```
- **AND** any discrepancy is a blocking bug (consensus safety)

#### Scenario: S2 Algorithm Sources

- **WHEN** porting specific S2 algorithms
- **THEN** reference these authoritative sources:
  | Algorithm | C++ Reference | Go Reference | Notes |
  |-----------|---------------|--------------|-------|
  | Cell ID encoding | `s2cell_id.cc` | `cellid.go` | Hilbert curve core |
  | Lat/Lon conversion | `s2latlng.cc` | `latlng.go` | Fixed-point conversion |
  | Region Coverer | `s2region_coverer.cc` | `regioncoverer.go` | Most complex |
  | Cap (radius) | `s2cap.cc` | `cap.go` | Used for radius queries |
  | Polygon | `s2polygon.cc` | `polygon.go` | Used for polygon queries |
  | Point containment | `s2contains_point_query.cc` | `containspointquery.go` | Post-filter |
- **AND** study both C++ and Go when implementing (different clarity tradeoffs)

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

### Requirement: Capacity Planning Guide

The system SHALL provide comprehensive capacity planning guidance for production deployments.

#### Scenario: RAM capacity planning

- **WHEN** planning RAM requirements
- **THEN** operators SHALL use:
  ```
  RAM SIZING FORMULA
  ══════════════════

  Components:
  1. Index RAM = entity_count × 1.43 (70% fill) × 64 bytes
  2. WAL buffers = pipeline_slots × message_size_max × 2
  3. LSM cache = configurable (recommend 4-8GB)
  4. OS overhead = 4-8GB

  Formula:
    total_ram = index_ram + wal_buffers + lsm_cache + os_overhead

  Examples:
  | Entities | Index RAM | WAL (4KB msg) | LSM Cache | OS  | Total    |
  |----------|-----------|---------------|-----------|-----|----------|
  | 10M      | 0.9GB     | 64MB          | 4GB       | 4GB | 9GB      |
  | 100M     | 9.1GB     | 64MB          | 8GB       | 4GB | 22GB     |
  | 500M     | 45.8GB    | 64MB          | 8GB       | 8GB | 62GB     |
  | 1B       | 91.5GB    | 64MB          | 8GB       | 8GB | 108GB    |

  RECOMMENDATION: 128GB RAM for 1B entities (safety margin)
  ```
- **AND** for mmap index mode (reduced RAM):
  ```
  RAM (mmap mode) = wal_buffers + lsm_cache + os_cache_target

  Example: 32GB RAM with mmap supports 1B entities (higher latency)
  ```

#### Scenario: Disk capacity planning

- **WHEN** planning disk requirements
- **THEN** operators SHALL use:
  ```
  DISK SIZING FORMULA
  ═══════════════════

  Components:
  1. LSM data = entity_count × avg_versions × 128 bytes
  2. WAL zone = wal_size (fixed, typically 512MB-1GB)
  3. Superblock = 8MB (4 copies × 2MB each)
  4. Compaction headroom = 2.0× multiplier

  Formula:
    min_disk = (lsm_data + wal_zone + superblock) × 2.0

  For TTL workloads (see ttl-retention/spec.md):
    lsm_data = entity_count × updates_per_ttl_window × 128 bytes

  Examples (no TTL, avg 10 versions per entity):
  | Entities | LSM Data | WAL   | Total  | With 2× Headroom |
  |----------|----------|-------|--------|------------------|
  | 10M      | 12.8GB   | 1GB   | 14GB   | 28GB             |
  | 100M     | 128GB    | 1GB   | 130GB  | 260GB            |
  | 1B       | 1.28TB   | 1GB   | 1.3TB  | 2.6TB            |

  Examples (1-hour TTL, 1 update/5min = 12 updates):
  | Entities | LSM Data | Total  | With 2× Headroom |
  |----------|----------|--------|------------------|
  | 100M     | 153GB    | 155GB  | 310GB            |
  | 1B       | 1.5TB    | 1.5TB  | 3TB              |
  ```

#### Scenario: Network capacity planning

- **WHEN** planning network requirements
- **THEN** operators SHALL consider:
  ```
  NETWORK SIZING
  ══════════════

  Intra-cluster (replica-to-replica):
  - Bandwidth: writes × replication_factor × message_overhead
  - Example: 100K events/sec × 3 replicas × 256 bytes = 77MB/s
  - REQUIREMENT: 1Gbps minimum, 10Gbps recommended

  Client-to-cluster:
  - Bandwidth: writes × 256 bytes + reads × response_size
  - Latency: <1ms for intra-DC, <50ms for cross-DC primary
  - REQUIREMENT: Client SDK handles replica discovery

  Cross-region (if standby cluster):
  - Async replication: eventual consistency stream
  - Bandwidth: write_throughput × compression_ratio
  ```

#### Scenario: CPU capacity planning

- **WHEN** planning CPU requirements
- **THEN** operators SHALL consider:
  ```
  CPU SIZING
  ══════════

  VSR processing: 1-2 cores (consensus, message handling)
  Query processing: 2-4 cores (S2 calculations, polygon containment)
  Compaction: 1-2 cores (background, can burst higher)
  I/O completion: 1 core (io_uring completion handling)

  MINIMUM: 8 cores (dedicated server)
  RECOMMENDED: 16+ cores for 1B entity scale

  NOTE: ArcherDB is more I/O and memory bound than CPU bound.
  Modern CPUs with good single-thread performance preferred.
  ```

### Requirement: Disaster Recovery Runbook

The system SHALL provide a comprehensive disaster recovery runbook.

#### Scenario: Single replica failure recovery

- **WHEN** a single replica fails (hardware failure, disk corruption)
- **THEN** recovery procedure SHALL be:
  ```
  SINGLE REPLICA FAILURE RECOVERY
  ════════════════════════════════

  IMPACT: Cluster remains available (quorum intact for 3+ replicas)

  STEPS:
  1. DETECT: Monitor alerts for replica_status != "normal"
  2. ASSESS: Check if failure is recoverable (restart) or requires replacement
  3. ATTEMPT RESTART:
     $ archerdb start --data-file=/path/to/data.archerdb
     - If starts successfully: replica rejoins, catches up via VSR
     - If data corruption detected: proceed to step 4
  4. REPLACE REPLICA (if restart fails):
     a. Provision new hardware (same spec or better)
     b. Format new data file:
        $ archerdb format --data-file=/new/path/data.archerdb \
            --cluster-id=<existing-cluster-id> \
            --replica-index=<failed-replica-index> \
            --replica-count=<total-replicas>
     c. Start replica:
        $ archerdb start --data-file=/new/path/data.archerdb \
            --addresses=<peer-addresses>
     d. Replica will sync from peers via state sync
  5. VERIFY: Check archerdb_replica_status == "normal"

  RTO: 15-60 minutes (depends on data size for state sync)
  ```

#### Scenario: Quorum loss recovery

- **WHEN** quorum is lost (majority of replicas unavailable)
- **THEN** recovery procedure SHALL be:
  ```
  QUORUM LOSS RECOVERY (CRITICAL)
  ═══════════════════════════════

  IMPACT: Cluster is UNAVAILABLE for writes. Reads may work from surviving replicas.

  PRIORITY: Restore quorum ASAP. Every minute of downtime = data loss risk.

  STEPS:
  1. ASSESS: Identify which replicas are available
     $ archerdb status --addresses=<all-replica-addresses>
  2. CLASSIFY FAILURE:
     a. Network partition: Restore network connectivity (fastest)
     b. Multiple hardware failures: Replace replicas
     c. Datacenter outage: Wait or failover to DR site
  3. RESTORE QUORUM:
     - For 3-replica cluster: need 2 replicas
     - For 5-replica cluster: need 3 replicas
  4. IF RESTORING FAILED REPLICAS:
     - Follow "Single replica failure recovery" for each
     - Start with replicas that have most recent data (highest commit_op)
  5. VERIFY: archerdb_cluster_status == "available"

  WARNING: Do NOT manually edit data files. Use only archerdb tools.

  RTO: Minutes (network) to hours (hardware replacement)
  RPO: Zero (VSR consensus ensures committed data survives)
  ```

#### Scenario: Full cluster restoration from backup

- **WHEN** entire cluster must be restored from backup
- **THEN** recovery procedure SHALL be:
  ```
  FULL CLUSTER RESTORE FROM BACKUP
  ═════════════════════════════════

  USE CASE: Total datacenter loss, all replicas unrecoverable

  PREREQUISITES:
  - S3/object storage backup available (see backup-restore/spec.md)
  - New hardware provisioned (3-5 nodes)
  - Network connectivity configured

  STEPS:
  1. IDENTIFY LATEST BACKUP:
     $ archerdb backup list --bucket=s3://your-backup-bucket
     - Note most recent consistent snapshot timestamp
  2. RESTORE TO FIRST NODE:
     $ archerdb restore \
         --from-s3=s3://your-backup-bucket/snapshot-<timestamp> \
         --to-data-file=/path/to/data.archerdb \
         --replica-index=0
     - This creates data file from backup
  3. START FIRST REPLICA:
     $ archerdb start --data-file=/path/to/data.archerdb --addresses=<self>
     - Single replica runs in degraded mode
  4. RESTORE REMAINING REPLICAS:
     - Repeat steps 2-3 for replica-index 1, 2, etc.
     - Each replica will sync and form quorum
  5. VERIFY CLUSTER HEALTH:
     $ archerdb status
     - All replicas should show "normal"
     - Check archerdb_commit_sequence matches across replicas

  RTO: 60-90 minutes for 1B entities (see backup-restore/spec.md for breakdown)
  RPO: Time since last backup (configure backup frequency accordingly)
  ```

#### Scenario: Data corruption detection and recovery

- **WHEN** data corruption is detected (checksum mismatch)
- **THEN** recovery procedure SHALL be:
  ```
  DATA CORRUPTION RECOVERY
  ═════════════════════════

  DETECTION: archerdb logs "checksum mismatch" or replica diverges

  STEPS:
  1. STOP AFFECTED REPLICA:
     $ archerdb stop --graceful
  2. RUN INTEGRITY CHECK:
     $ archerdb verify --data-file=/path/to/data.archerdb
     - Reports corrupted blocks and extent of damage
  3. ASSESS OPTIONS:
     a. Minor corruption (few blocks): Replica can recover via state sync
     b. Major corruption: Replace replica from backup or peer
  4. FOR MINOR CORRUPTION:
     $ archerdb repair --data-file=/path/to/data.archerdb
     - Marks corrupted blocks as invalid
     - Replica fetches missing data from peers on restart
  5. FOR MAJOR CORRUPTION:
     - Follow "Single replica failure recovery" (full replacement)
  6. INVESTIGATE ROOT CAUSE:
     - Check disk health (SMART data)
     - Check for memory errors (ECC logs)
     - Consider hardware replacement even if repair succeeds
  ```

### Requirement: Upgrade Path Documentation

The system SHALL document safe upgrade procedures between versions.

#### Scenario: Minor version upgrade (patch)

- **WHEN** upgrading between patch versions (e.g., 1.0.0 → 1.0.1)
- **THEN** upgrade procedure SHALL be:
  ```
  PATCH VERSION UPGRADE
  ═════════════════════

  COMPATIBILITY: Patch versions are always backward compatible.
  DOWNTIME: Zero (rolling restart)

  STEPS:
  1. VERIFY CLUSTER HEALTH:
     $ archerdb status
     - All replicas must be "normal"
  2. UPGRADE ONE REPLICA AT A TIME:
     For each replica (start with backups, primary last):
     a. Stop replica:
        $ archerdb stop --graceful
     b. Replace binary:
        $ cp archerdb-1.0.1 /usr/local/bin/archerdb
     c. Start replica:
        $ archerdb start --data-file=/path/to/data.archerdb
     d. Wait for replica to rejoin:
        $ archerdb status (wait for "normal")
     e. Proceed to next replica
  3. VERIFY CLUSTER VERSION:
     $ archerdb version --cluster
     - All replicas should report new version

  ROLLBACK: Reverse process with old binary (same procedure)
  ```

#### Scenario: Minor version upgrade (feature)

- **WHEN** upgrading between minor versions (e.g., 1.0.x → 1.1.0)
- **THEN** upgrade procedure SHALL be:
  ```
  MINOR VERSION UPGRADE
  ═════════════════════

  COMPATIBILITY: Minor versions maintain wire protocol compatibility.
  DATA FORMAT: May include new features requiring format migration.

  PRE-UPGRADE:
  1. READ RELEASE NOTES for breaking changes
  2. CREATE BACKUP:
     $ archerdb backup create --to-s3=s3://your-bucket/pre-upgrade
  3. TEST UPGRADE in staging environment

  UPGRADE STEPS:
  1. ENTER UPGRADE MODE (if data format changed):
     $ archerdb upgrade prepare --version=1.1.0
     - Cluster continues operating in compatibility mode
  2. ROLLING RESTART (same as patch upgrade):
     - Stop, upgrade binary, start each replica
  3. COMPLETE UPGRADE:
     $ archerdb upgrade complete
     - Enables new features, applies format migrations

  ROLLBACK:
  - If upgrade prepare: $ archerdb upgrade cancel
  - If upgrade complete: Restore from backup (cannot downgrade format)
  ```

#### Scenario: Major version upgrade

- **WHEN** upgrading between major versions (e.g., 1.x → 2.x)
- **THEN** upgrade procedure SHALL be:
  ```
  MAJOR VERSION UPGRADE
  ═════════════════════

  COMPATIBILITY: Major versions may break wire protocol or data format.
  DOWNTIME: Planned maintenance window required.

  PRE-UPGRADE (weeks before):
  1. REVIEW release notes and migration guide
  2. TEST in staging with production-like data
  3. PLAN maintenance window (estimate: 1-2 hours for 1B entities)
  4. NOTIFY stakeholders

  UPGRADE STEPS:
  1. CREATE FULL BACKUP:
     $ archerdb backup create --to-s3=s3://your-bucket/pre-v2-upgrade
  2. STOP ALL CLIENTS:
     - Drain client connections
     - Confirm write traffic = 0
  3. STOP CLUSTER:
     $ archerdb stop --all-replicas
  4. RUN MIGRATION:
     $ archerdb migrate --from-version=1.x --to-version=2.x \
         --data-file=/path/to/data.archerdb
     - This rewrites data file in new format
  5. UPGRADE BINARIES on all nodes
  6. START CLUSTER:
     $ archerdb start (on each replica)
  7. VERIFY health and run smoke tests
  8. RESUME CLIENT TRAFFIC

  ROLLBACK: Restore from pre-upgrade backup to previous version
  ```

#### Scenario: Client SDK version compatibility

- **WHEN** upgrading server or client SDK
- **THEN** compatibility matrix SHALL be:
  ```
  SDK COMPATIBILITY MATRIX
  ════════════════════════

  | Server Version | SDK 1.0.x | SDK 1.1.x | SDK 2.0.x |
  |----------------|-----------|-----------|-----------|
  | Server 1.0.x   | ✓         | ✓         | ✗         |
  | Server 1.1.x   | ✓         | ✓         | ✗         |
  | Server 2.0.x   | ✗         | ✗         | ✓         |

  RULE: SDK minor version must be ≤ server minor version within same major.
  RECOMMENDATION: Upgrade server first, then clients.
  ```

### Requirement: Operational Runbook

The system SHALL provide an operational runbook for day-to-day operations.

#### Scenario: Health check procedures

- **WHEN** performing routine health checks
- **THEN** operators SHALL verify:
  ```
  DAILY HEALTH CHECK CHECKLIST
  ════════════════════════════

  □ Cluster status:
    $ archerdb status
    Expected: All replicas "normal", primary elected

  □ Replication lag:
    $ curl -s localhost:9090/metrics | grep archerdb_replication_lag
    Expected: < 1000 operations

  □ Disk usage:
    $ curl -s localhost:9090/metrics | grep archerdb_disk
    Expected: < 80% (alert threshold)

  □ Memory usage:
    $ curl -s localhost:9090/metrics | grep archerdb_memory
    Expected: Stable (no growth trend)

  □ Compaction health:
    $ curl -s localhost:9090/metrics | grep archerdb_compaction_debt
    Expected: < 0.3 (warning threshold)

  □ Error rates:
    $ curl -s localhost:9090/metrics | grep archerdb_errors_total
    Expected: No unexpected errors

  □ Backup status:
    $ archerdb backup list --bucket=s3://your-bucket | head -5
    Expected: Recent backup within SLA
  ```

#### Scenario: Common troubleshooting procedures

- **WHEN** troubleshooting common issues
- **THEN** operators SHALL follow:
  ```
  TROUBLESHOOTING GUIDE
  ═════════════════════

  ISSUE: High query latency (p99 > target)
  ─────────────────────────────────────────
  1. Check disk I/O: iostat -x 1
     - If await > 10ms: Disk bottleneck
     - Action: Check for compaction storms, disk health
  2. Check memory pressure: free -h
     - If swap > 0: Memory pressure
     - Action: Reduce LSM cache or add RAM
  3. Check CPU: top -p $(pgrep archerdb)
     - If CPU > 90%: Processing bottleneck
     - Action: Profile queries, check S2 calculation complexity

  ISSUE: Replica not joining cluster
  ──────────────────────────────────
  1. Check network connectivity:
     $ nc -zv <peer-address> <port>
  2. Check logs for auth/handshake errors:
     $ journalctl -u archerdb | grep -i error
  3. Verify cluster-id matches:
     $ archerdb info --data-file=<path>
  4. Check firewall rules allow bidirectional traffic

  ISSUE: Write throughput degradation
  ───────────────────────────────────
  1. Check compaction backlog:
     archerdb_lsm_level0_tables gauge
     - If > 8: Compaction falling behind
  2. Check WAL utilization:
     archerdb_wal_utilization gauge
     - If > 80%: WAL pressure
  3. Check for network issues between replicas:
     archerdb_message_roundtrip_ms histogram

  ISSUE: Backup taking too long
  ─────────────────────────────
  1. Check network bandwidth to S3:
     $ iperf3 -c <s3-endpoint>
  2. Check concurrent backup operations (only 1 should run)
  3. Consider incremental backup if full backup too slow
  ```

#### Scenario: Maintenance window procedures

- **WHEN** performing scheduled maintenance
- **THEN** procedures SHALL be:
  ```
  MAINTENANCE WINDOW PROCEDURES
  ═════════════════════════════

  PRE-MAINTENANCE:
  1. Notify stakeholders (24h advance for non-emergency)
  2. Create backup:
     $ archerdb backup create --to-s3=s3://bucket/pre-maintenance
  3. Document current cluster state:
     $ archerdb status > pre-maintenance-status.txt

  DURING MAINTENANCE:
  - For rolling operations (upgrades, restarts):
    - Process one replica at a time
    - Wait for replica to rejoin before proceeding
    - Keep quorum at all times
  - For full-stop operations:
    - Stop all clients first
    - Stop replicas in order: backups first, primary last
    - Perform maintenance
    - Start replicas in reverse order: primary first

  POST-MAINTENANCE:
  1. Verify cluster health:
     $ archerdb status
  2. Run smoke tests:
     $ archerdb test connectivity
  3. Check metrics for anomalies
  4. Document changes made
  5. Notify stakeholders of completion
  ```

#### Scenario: Scaling operations

- **WHEN** scaling cluster resources
- **THEN** procedures SHALL be:
  ```
  SCALING PROCEDURES
  ══════════════════

  VERTICAL SCALING (larger hardware):
  ───────────────────────────────────
  1. For each replica (rolling):
     a. Stop replica
     b. Migrate data file to new hardware:
        $ rsync -av /old/path/data.archerdb new-server:/new/path/
     c. Start on new hardware
     d. Remove old replica from cluster config
  NOTE: VSR static membership means same replica index on new hardware

  HORIZONTAL SCALING (NOT SUPPORTED in v1):
  ─────────────────────────────────────────
  - Cluster size is fixed at format time (3, 5, or 6 replicas)
  - To change cluster size: Full backup → Format new cluster → Restore
  - Future versions may support dynamic membership

  STORAGE SCALING:
  ────────────────
  - Add larger disk, migrate data file, update paths
  - Or use LVM to extend existing volume (if supported by filesystem)
  ```

#### Scenario: On-call response procedures

- **WHEN** responding to alerts on-call
- **THEN** procedures SHALL be:
  ```
  ON-CALL RESPONSE GUIDE
  ══════════════════════

  ALERT: replica_down
  ────────────────────
  Severity: WARNING (if quorum intact), CRITICAL (if quorum at risk)
  Response:
  1. Check if replica is reachable (network)
  2. Check if process is running (systemctl status archerdb)
  3. Check logs for crash reason
  4. Restart replica if safe, escalate if repeated failures

  ALERT: disk_usage_high (>80%)
  ─────────────────────────────
  Severity: WARNING at 80%, CRITICAL at 90%
  Response:
  1. Check compaction debt ratio
  2. If high: Wait for compaction to catch up, or reduce write rate
  3. If normal: Investigate data growth pattern
  4. Plan capacity expansion if trend continues

  ALERT: replication_lag_high
  ───────────────────────────
  Severity: WARNING at 1000 ops, CRITICAL at 10000 ops
  Response:
  1. Check slow replica health (disk, network, CPU)
  2. Check for network partition between replicas
  3. If one replica: May need replacement
  4. If all replicas: Primary may be overloaded

  ALERT: compaction_debt_critical (>0.5)
  ──────────────────────────────────────
  Severity: CRITICAL
  Response:
  1. Check disk space (compaction needs headroom)
  2. Reduce write rate if possible (client throttling)
  3. Consider manual compaction trigger if tooling supports
  4. Plan for capacity expansion

  ESCALATION:
  - SEV1 (cluster down): Immediate page to on-call engineer
  - SEV2 (degraded): Page within 15 minutes
  - SEV3 (warning): Address during business hours
  ```

### Related Specifications

- See `specs/replication/spec.md` for complete VSR protocol (Marzullo's, Flexible Paxos, CTRL)
- See `specs/storage-engine/spec.md` for Free Set and LSM implementation details
- See `specs/query-engine/spec.md` for S2 RegionCoverer usage in queries
- See `specs/hybrid-memory/spec.md` for linear probing hash map implementation
- See `specs/constants/spec.md` for algorithm configuration parameters
- See `specs/backup-restore/spec.md` for backup/restore procedures and RTO/RPO targets
- See `specs/ttl-retention/spec.md` for TTL-aware capacity planning
- See `specs/observability/spec.md` for metrics and alerting configuration
