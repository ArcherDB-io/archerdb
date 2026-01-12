# Implementation Guide Specification

**Primary Reference:** https://github.com/archerdb/archerdb

---

## CRITICAL: Implementation Strategy

### Requirement: Fork ArcherDB (Do Not Build From Scratch)

The system SHALL be implemented by **forking ArcherDB**, not by building from scratch. This decision is non-negotiable and critical for project success.

#### Scenario: Strategic rationale

- **WHEN** beginning ArcherDB implementation
- **THEN** the developer MUST understand why forking is mandatory:
  1. **Risk Reduction**: VSR consensus took ArcherDB 5+ years to perfect; reimplementing it introduces unnecessary risk
  2. **Time Savings**: ~70% of codebase is reusable, reducing timeline from 18+ months to 6-9 months
  3. **Battle-Tested Code**: ArcherDB's storage engine, I/O layer, and replication are production-proven
  4. **Specification Alignment**: These specs were written to be compatible with ArcherDB's architecture
  5. **Licensing**: ArcherDB is Apache 2.0 licensed, permitting commercial forks

#### Scenario: Getting started (Day 1)

- **WHEN** beginning implementation
- **THEN** the first steps SHALL be:
  ```bash
  # Step 1: Fork ArcherDB
  git clone https://github.com/archerdb/archerdb.git archerdb
  cd archerdb

  # Step 2: Verify build works
  zig build
  ./zig-out/bin/archerdb version

  # Step 3: Run existing tests to establish baseline
  zig build test

  # Step 4: Run VOPR simulator to understand testing approach
  zig build vopr

  # Step 5: Study the codebase (allow 2-4 weeks for knowledge acquisition)
  # Focus areas: src/vsr/replica.zig, src/archerdb.zig, src/lsm/
  ```
- **AND** modifications SHALL NOT begin until the developer can:
  - Explain VSR message flow (Prepare → PrepareOk → Commit)
  - Describe the checkpoint sequence (grid → fsync → superblock → fsync)
  - Understand the state machine interface (prepare/prefetch/commit phases)

### Requirement: Zig Ecosystem and Language Feature Validation (Week 0 Gate)

The system SHALL validate Zig language maturity and availability of critical stdlib features before committing to implementation.

- **WHEN** beginning Week 0 setup (before F0.1 fork)
- **THEN** a language feature validation audit SHALL be executed:
  ```
  ZIG ECOSYSTEM VALIDATION PROCEDURE
  ══════════════════════════════════

  OBJECTIVE: Validate that Zig language and standard library provide all critical
  features required for ArcherDB implementation. Identify fallbacks for any missing
  or unstable features before F0.1 begins.

  CRITICAL FEATURES MATRIX:
  ────────────────────────

  Feature Category 1: Numeric & Math (Required for S2, CORDIC, Chebyshev)
  ──────────────────────────────────────────────────────────────────────
  ✓ REQUIRED: std.math.sin, cos, atan2 with f64 precision
  ✓ REQUIRED: comptime float operations (compile-time trig for polynomial coefficients)
  ✓ REQUIRED: u64/u128 integer math with overflow detection
  ✓ OPTIONAL: Hardware AES (Aegis-128L) - fallback: libsodium binding

  Validation test:
    1. Compile: `const pi = std.math.pi; const sin_pi_4 = std.math.sin(pi/4);`
    2. Verify: sin(π/4) ≈ 0.7071 ± 1e-15 precision
    3. Compile-time: const cos_val = std.math.cos(angle) at comptime
    4. Result: PASS if all 3 work correctly

  Feature Category 2: Concurrency & Async I/O (Required for io_uring, replication)
  ──────────────────────────────────────────────────────────────────────────────
  ✓ REQUIRED: std.os.linux.io_uring integration (ArcherDB foundation)
  ✓ REQUIRED: async/await syntax (if used by ArcherDB)
  ✓ REQUIRED: Thread-safe atomics (std.atomic.*)
  ✓ REQUIRED: Mutex/RwLock (std.Thread.Mutex, std.Thread.RwLock)
  ✗ OPTIONAL: Go-style channels (Zig doesn't have, use message pool instead)

  Validation test:
    1. Compile ArcherDB's io_uring code without errors
    2. Run ArcherDB's async tests: `zig build test -- io`
    3. Measure atomic CAS performance (must be lock-free)
    4. Result: PASS if ArcherDB compiles and runs

  Feature Category 3: Memory & Allocation (Required for zero-allocation discipline)
  ──────────────────────────────────────────────────────────────────────────────
  ✓ REQUIRED: StaticAllocator pattern (ArcherDB's memory discipline)
  ✓ REQUIRED: extern struct with exact layout control
  ✓ REQUIRED: @sizeOf, @alignOf, comptime assertions
  ✓ REQUIRED: No runtime allocations in hot path (Zig compiler validation)
  ✓ OPTIONAL: Memory tagging/ASAN for debugging

  Validation test:
    1. Create GeoEvent extern struct with @sizeOf == 128
    2. Verify no padding or reordering: comptime check
    3. Test pointer arithmetic: index * 128 byte offset
    4. Compile-time allocation check: all allocations in init paths only
    5. Result: PASS if struct layout is exact and no hot-path allocations

  Feature Category 4: Standard Library Stability (Required for LSM, storage)
  ──────────────────────────────────────────────────────────────────────────
  ✓ REQUIRED: std.ArrayList, std.HashMap (collections)
  ✓ REQUIRED: std.fs for file I/O
  ✓ REQUIRED: std.crypto for hashing (SHA256, CRC32C)
  ✓ REQUIRED: std.testing framework
  ✗ BREAKING RISK: std.meta, std.builtin API changes (track Zig version carefully)

  Validation test:
    1. Pin Zig version: use exactly version X.Y.Z (e.g., 0.11.0)
    2. Compile ArcherDB with pinned version
    3. Test std.ArrayList, HashMap operations
    4. Test std.crypto.hash.sha256
    5. Verify reproducible builds: same commit → same binary hash
    6. Result: PASS if all tests pass and builds are deterministic

  Feature Category 5: C FFI Integration (Required for S2 library)
  ──────────────────────────────────────────────────────────────
  ✓ REQUIRED: @cImport for C headers
  ✓ REQUIRED: Calling C functions from Zig with type safety
  ✓ REQUIRED: extern structs matching C layout
  ✓ CRITICAL: ABI stability across platforms (Linux x86/ARM, macOS Intel/ARM)

  Validation test:
    1. Create simple C library (test.c with: int add(int a, int b) { return a+b; })
    2. Build it: gcc -shared -o libtest.so test.c
    3. Call from Zig: const lib = @cImport(@cInclude("test.h"));
    4. Link and run: zig build-exe test.zig -ltest -L.
    5. Verify on multiple platforms (x86 Linux, ARM Linux, macOS)
    6. Result: PASS if C interop works on all platforms without bugs

  WEEK 0 VALIDATION PROCEDURE:
  ──────────────────────────

  Timeline: 2-3 days (days 1-3 of Week 0)
  Owner: Solo developer (AI-assisted validation)
  Gate: MUST PASS before F0.1 begins

  Day 1: Feature detection (4 hours)
  ─────────────────────────────────
  1. Clone ArcherDB repo and build with pinned Zig version
  2. Run all stdlib feature tests (math, async, memory, fs, crypto)
  3. Document results in: docs/zig_ecosystem_audit_week0.md
  4. List any FAILURES as "Blockers"

  Day 2: Fallback implementation (4 hours)
  ──────────────────────────────────────
  For each FAILURE, implement fallback:
    - Hardware AES missing → Link libsodium (external C library)
    - Missing std.* API → Implement wrapper or use alternative
    - Performance regression → Profile and optimize or use C binding
  4. Document fallback in: docs/zig_ecosystem_workarounds.md

  Day 3: Integration & Cross-platform (4 hours)
  ─────────────────────────────────────────────
  1. Test all required features on secondary platforms:
     - Linux ARM64 (Graviton2 or emulated via QEMU)
     - macOS x86-64 and ARM64 (if available)
     - Windows (if in scope)
  2. Verify C FFI ABI compatibility across platforms
  3. Create CI pipeline to re-validate on every commit
  4. Document platform-specific workarounds

  DECISION GATE:
  ──────────────
  GO: All critical features present and working → Proceed to F0.1 fork
     - Document: "Zig ecosystem audit PASSED - ready for implementation"
     - Timeline impact: Zero (stays on schedule)

  NO-GO (unlikely): Critical features missing with no fallback → Options:
    1. Use different language (Go? C++?) - 2-4 month delay for rewrite
    2. Delay project 4-6 months (wait for Zig 1.0, ecosystem maturity)
    3. Build fallback implementation in C, wrap in Zig
    - Timeline impact: +1-4 months depending on option
    - Probability: < 5% (Zig is stable enough for this use case)

  MONITORING DURING F0-F4:
  ──────────────────────
  1. Watch Zig release notes weekly (breaking changes?)
  2. Re-validate critical features every 2 weeks
  3. Set alerts for Zig version warnings or deprecations
  4. Maintain pinned version in build.zig.zon (Zig package manager)
  5. Have contingency: documented steps to revert to previous Zig version

  DOCUMENTATION DELIVERABLES:
  ──────────────────────────
  - docs/zig_ecosystem_audit_week0.md: Audit results, feature status
  - docs/zig_ecosystem_workarounds.md: Fallback implementations
  - docs/zig_pinned_version.txt: Exact Zig version used (e.g., "0.11.0")
  - build.zig.zon: Package manager lock file (Zig 0.12+)
  - Continuous integration: .github/workflows/zig-audit.yml (re-validate weekly)
  ```

### Requirement: Component Classification (Keep vs Replace vs Add)

The system SHALL clearly classify which ArcherDB components to keep, replace, or add.

#### Scenario: Components to KEEP unchanged (~70% of codebase)

- **WHEN** identifying reusable components
- **THEN** the following SHALL be kept with minimal or no modifications:

  | Component | ArcherDB Files | Why Keep |
  |-----------|-------------------|----------|
  | **VSR Consensus** | `src/vsr/replica.zig`, `journal.zig`, `clock.zig` | Core distributed consensus - extremely complex, proven correct |
  | **Storage Engine** | `src/storage.zig`, `src/vsr/superblock.zig`, `src/vsr/free_set.zig` | Crash-safe storage with slot alternation |
  | **LSM Tree** | `src/lsm/*.zig` | Compaction, manifest, tables - domain agnostic |
  | **I/O Layer** | `src/io/linux.zig`, `darwin.zig`, `windows.zig` | io_uring/kqueue/IOCP - highly optimized |
  | **Message Pool** | `src/message_pool.zig` | Zero-allocation messaging |
  | **Client Sessions** | `src/vsr/client_sessions.zig` | Idempotency tracking |
  | **VOPR Simulator** | `src/simulator.zig`, `src/testing/*.zig` | Deterministic testing framework |
  | **Stdx Utilities** | `src/stdx.zig` | Intrusive data structures |

- **AND** modifications to these components SHALL require explicit justification documented in code comments

#### Scenario: Components to REPLACE (~20% of codebase)

- **WHEN** identifying components requiring replacement
- **THEN** the following SHALL be replaced entirely:

  | ArcherDB Component | ArcherDB Replacement | Key Changes |
  |----------------------|---------------------|-------------|
  | `src/archerdb.zig` | `src/archerdb.zig` | GeoEvent state machine instead of Account/Transfer |
  | `src/state_machine.zig` | `src/geo_state_machine.zig` | Geospatial operations, S2 integration |
  | Account struct (128 bytes) | GeoEvent struct (128 bytes) | Same size, different fields |
  | Transfer struct | Query structs | Radius, polygon, UUID queries |
  | `src/clients/*` | `src/clients/*` | New API, same connection logic |

- **AND** replacement components MUST maintain the same interfaces expected by VSR layer

#### Scenario: Components to ADD (~10% of codebase)

- **WHEN** identifying new components
- **THEN** the following SHALL be added:

  | New Component | Purpose | Complexity |
  |--------------|---------|------------|
  | `src/ram_index.zig` | O(1) entity lookup index (64GB for 1B entities) | Medium |
  | `src/s2/` | S2 geometry library (port or FFI) | High |
  | `src/s2_index.zig` | Spatial index for range queries | Medium |
  | `src/ttl.zig` | TTL expiration tracking | Low |
  | Golden vector tests | S2 determinism validation | Medium |

### Requirement: State Machine Interface Preservation

The system SHALL preserve ArcherDB's state machine interface to minimize VSR layer changes.

#### Scenario: State machine contract

- **WHEN** implementing the GeoEvent state machine
- **THEN** it MUST implement the same interface as ArcherDB's state machine:

  ```zig
  // This interface is defined by ArcherDB's VSR layer and MUST be preserved
  pub const StateMachine = struct {
      // Called during prepare phase - validate operations, compute deterministic results
      pub fn prepare(self: *StateMachine, operation: Operation, input: []const u8) !void;

      // Called during prefetch phase - load required data from storage
      pub fn prefetch(self: *StateMachine) !void;

      // Called during commit phase - apply operation to state (MUST be deterministic)
      pub fn commit(self: *StateMachine) void;

      // Called to compact state (checkpoint)
      pub fn compact(self: *StateMachine, callback: CompactCallback) void;

      // Called on replica startup to open/recover state
      pub fn open(self: *StateMachine, callback: OpenCallback) void;
  };
  ```

- **AND** the `Operation` enum SHALL be modified to include geospatial operations:

  ```zig
  pub const Operation = enum(u8) {
      // VSR internal operations (ArcherDB infrastructure, NOT client-facing)
      reserved = 254,         // Internal sentinel
      root = 255,             // Internal VSR root operation

      // Client-facing operations (semantic ranges per client-protocol/spec.md)
      // Session: 0x00
      register = 0,           // 0x00 - Establish/resume client session

      // Write operations: 0x01-0x0F
      insert_events = 1,      // 0x01
      upsert_events = 2,      // 0x02
      delete_entities = 3,    // 0x03 (GDPR)

      // Query operations: 0x10-0x1F
      query_uuid = 16,        // 0x10
      query_radius = 17,      // 0x11
      query_polygon = 18,     // 0x12
      query_uuid_batch = 19,  // 0x13
      query_latest = 20,      // 0x14

      // Admin operations: 0x20-0x2F
      ping = 32,              // 0x20
      get_status = 33,        // 0x21

      // Maintenance: 0x30-0x3F
      cleanup_expired = 48,   // 0x30
  };
  ```

### Requirement: Implementation Phases

The system SHALL be implemented in clearly defined phases.

#### Scenario: Phase 1 - Fork and Foundation (Weeks 1-6)

- **WHEN** beginning Phase 1
- **THEN** deliverables SHALL be:
  1. Forked repository with renamed entry points
  2. GeoEvent struct defined (128 bytes, matching layout requirements)
  3. Basic state machine compiling (no functionality yet)
  4. ArcherDB codebase study completed
  5. Development environment and CI/CD established
- **AND** success criteria: `zig build` succeeds, VSR flow understood and documented

#### Scenario: Phase 2 - State Machine Replacement (Weeks 7-14)

- **WHEN** beginning Phase 2
- **THEN** deliverables SHALL be:
  1. GeoEvent state machine with upsert operation
  2. Single-node writes working (no replication testing yet)
  3. UUID lookup queries working
  4. Basic client SDK (one language)
- **AND** success criteria: Can write and read GeoEvents on single node

#### Scenario: Phase 3 - RAM Index Integration (Weeks 15-20)

- **WHEN** beginning Phase 3
- **THEN** deliverables SHALL be:
  1. RAM index implementation with Robin Hood hashing
  2. Index checkpointing integrated with superblock
  3. O(1) entity lookups verified
  4. Tombstone tracking (if delete supported)
- **AND** success criteria: UUID lookups complete in <500μs p99

#### Scenario: Phase 4 - S2 Geometry Integration (Weeks 21-26)

- **WHEN** beginning Phase 4
- **THEN** deliverables SHALL be:
  1. S2 library integrated (port or FFI)
  2. Golden vector tests passing (bit-exact determinism)
  3. Radius queries working
  4. Polygon queries working
- **AND** success criteria: Spatial queries return correct results, all replicas agree

#### Scenario: Phase 5 - Replication Testing (Weeks 27-32)

- **WHEN** beginning Phase 5
- **THEN** deliverables SHALL be:
  1. 3-replica and 5-replica clusters tested
  2. VOPR simulator adapted for GeoEvent operations
  3. View change scenarios passing
  4. Network partition scenarios passing
  5. Crash recovery scenarios passing
- **AND** success criteria: VOPR finds no safety violations in 10M+ operations

#### Scenario: Phase 6 - Production Hardening (Weeks 33-38)

- **WHEN** beginning Phase 6
- **THEN** deliverables SHALL be:
  1. Performance benchmarks meeting targets
  2. Observability (metrics, tracing, logging) complete
  3. Client SDKs for primary languages
  4. Documentation and runbooks
  5. Security review completed
- **AND** success criteria: Ready for beta deployment

### Requirement: Common Pitfalls to Avoid

The system documentation SHALL warn against common implementation mistakes.

#### Scenario: Pitfalls that WILL cause failure

- **WHEN** implementing ArcherDB
- **THEN** these critical mistakes MUST be avoided:

  | Pitfall | Why It's Fatal | Prevention |
  |---------|----------------|------------|
  | Modifying VSR consensus logic | Breaks correctness proofs, introduces subtle bugs | Treat `src/vsr/replica.zig` as read-only |
  | Non-deterministic state machine | Causes replica divergence, cluster-wide panic | Use consensus timestamps, validate S2 with golden vectors |
  | Runtime memory allocation in hot paths | Latency spikes, potential OOM | Follow ArcherDB's static allocation discipline |
  | Changing message header layout | Breaks wire protocol compatibility | Keep 256-byte header structure |
  | Skipping VOPR testing | Ships bugs that only manifest under network partitions | Run VOPR with millions of operations before release |
  | Using floating-point in consensus path | Non-determinism across CPU architectures | S2 must be bit-exact; use integer math or validated FP |

#### Scenario: Warning signs during development

- **WHEN** development is proceeding
- **THEN** these warning signs indicate problems:
  - "Let's simplify the VSR protocol" → NO, it's correct as designed
  - "We don't need the simulator" → YES YOU DO, consensus bugs are invisible without it
  - "This works on my machine" → Test on 3+ replicas with fault injection
  - "We can optimize this later" → Follow ArcherDB's patterns from day one
  - "Let's use a different hash function" → Ensure identical hashing across all replicas

---

## ADDED Requirements

### Requirement: ArcherDB as Reference Implementation

The system SHALL use ArcherDB's actual source code as the authoritative reference for all borrowed patterns and implementations.

#### Scenario: Implementation methodology

- **WHEN** implementing any component described in these specifications
- **THEN** implementers SHALL:
  1. Read the corresponding ArcherDB source code files (listed below)
  2. Understand the pattern as implemented by ArcherDB
  3. Adapt the pattern to ArcherDB's geospatial domain
  4. Preserve ArcherDB's safety guarantees and optimizations
  5. When specification is ambiguous, ArcherDB's code is authoritative

#### Scenario: Pattern reuse philosophy

- **WHEN** encountering implementation decisions
- **THEN** the priority SHALL be:
  1. **First:** Check if ArcherDB has solved this problem
  2. **If yes:** Reuse ArcherDB's solution (adapt domain types)
  3. **If no:** Design new solution following ArcherDB's principles
  4. **Never:** Reinvent patterns that ArcherDB has proven

### Requirement: ArcherDB File Reference Map

The system SHALL document which ArcherDB files correspond to each ArcherDB component.

#### Scenario: VSR Replication (specs/replication/spec.md)

- **WHEN** implementing VSR replication
- **THEN** study these ArcherDB files:
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
- **THEN** study these ArcherDB files:
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
- **THEN** study these ArcherDB files:
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
- **THEN** study these ArcherDB files:
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
- **THEN** study these ArcherDB files:
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
- **THEN** study these ArcherDB files:
  ```
  src/state_machine.zig            → StateMachine interface (input_valid, prepare, prefetch, commit)
  src/archerdb.zig              → State machine for Account/Transfer operations
  ```
- **AND** implement identical three-phase model
- **AND** replace Account/Transfer with GeoEvent/SpatialQuery operations
- **AND** preserve deterministic timestamp assignment

#### Scenario: Data Model (specs/data-model/spec.md)

- **WHEN** implementing data structures
- **THEN** study these ArcherDB files:
  ```
  src/archerdb.zig              → Account and Transfer struct definitions (128-byte examples)
  src/stdx.zig                     → no_padding() verification utility
  ```
- **AND** use extern struct with explicit layout
- **AND** add comptime size/alignment assertions
- **AND** follow field ordering (largest alignment first)

### Requirement: ArcherDB Version Compatibility

The system SHALL document which ArcherDB version the patterns are based on.

#### Scenario: Reference version

- **WHEN** implementing from ArcherDB patterns
- **THEN** the reference version SHALL be:
  - **ArcherDB version:** 0.15.6 (pinned; see `openspec/changes/add-geospatial-core/DECISIONS.md`)
  - **Commit reference:** `c0178117c4de45a403cda40667e3d608a681f484` (pinned; see `openspec/changes/add-geospatial-core/DECISIONS.md`)
  - **Repository:** https://github.com/archerdb/archerdb
- **AND** document specific commit SHA in implementation code comments

#### Scenario: Pattern evolution

- **WHEN** ArcherDB releases improvements
- **THEN** ArcherDB MAY adopt them:
  - Monitor ArcherDB releases for performance/safety improvements
  - Backport applicable patterns to ArcherDB
  - Test thoroughly before production deployment
  - Document ArcherDB version in release notes

### Requirement: Code Comments Referencing ArcherDB

The system SHALL include code comments referencing specific ArcherDB files for complex implementations.

#### Scenario: VSR implementation comments

- **WHEN** implementing VSR protocol logic
- **THEN** code comments SHALL reference ArcherDB:
  ```zig
  // Based on ArcherDB src/vsr/replica.zig:send_prepare_ok()
  // See: https://github.com/archerdb/archerdb/blob/main/src/vsr/replica.zig
  fn send_prepare_ok(self: *Replica, prepare: *const Header) void {
      // ... implementation ...
  }
  ```

#### Scenario: Attribution in complex algorithms

- **WHEN** implementing ArcherDB algorithms
- **THEN** code comments SHALL attribute:
  - Marzullo's algorithm: `// Based on ArcherDB src/vsr/clock.zig`
  - Hash-chained prepares: `// Based on ArcherDB src/vsr/journal.zig`
  - CTRL protocol: `// Based on ArcherDB CTRL view change optimization`
  - Free set: `// Based on ArcherDB src/vsr/free_set.zig`

### Requirement: Domain Adaptation Documentation

The system SHALL document how ArcherDB patterns are adapted to the geospatial domain.

#### Scenario: Type substitution

- **WHEN** adapting ArcherDB patterns
- **THEN** document type substitutions:
  ```
  ArcherDB         →  ArcherDB
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

- **WHEN** replacing ArcherDB's financial logic
- **THEN** document the substitution:
  ```
  ArcherDB Financial Logic  →  ArcherDB Geospatial Logic
  ────────────────────────────────────────────────────────────
  Double-entry bookkeeping     →  Last-write-wins (LWW) upserts
  Debit = Credit invariant     →  Spatial validity (lat/lon ranges)
  Pending/Posted transfers     →  TTL expiration
  Account balance              →  Latest location (RAM index)
  Transfer history             →  Movement history (spatial log)
  ```

### Requirement: ArcherDB License Compliance

The system SHALL comply with ArcherDB's Apache 2.0 license when borrowing code.

#### Scenario: License attribution

- **WHEN** code is directly adapted from ArcherDB
- **THEN** file headers SHALL include:
  ```zig
  // Portions adapted from ArcherDB (Apache 2.0 License)
  // Original: https://github.com/archerdb/archerdb
  // Copyright ArcherDB, Inc.
  // Modifications for ArcherDB geospatial database
  ```

#### Scenario: Original work

- **WHEN** implementing new geospatial-specific code
- **THEN** standard ArcherDB license applies:
  ```zig
  // Copyright ArcherDB Project
  // Geospatial extensions to ArcherDB patterns
  ```

### Requirement: Divergence Documentation

The system SHALL document any intentional divergences from ArcherDB's patterns.

#### Scenario: Divergence justification

- **WHEN** deviating from ArcherDB's implementation
- **THEN** code comments SHALL explain:
  - What differs from ArcherDB
  - Why the divergence is necessary
  - What risks it introduces
  - How safety is maintained

**Example:**
```zig
// DIVERGENCE from ArcherDB: Added ttl_seconds field to GeoEvent
// ArcherDB: Account/Transfer have no TTL (financial records never expire)
// ArcherDB: Location data expires (configurable per-event TTL)
// Risk: Additional validation needed during compaction
// Safety: Lazy expiration checks + background cleanup task
```

### Requirement: Community Contribution

The system SHALL contribute improvements back to ArcherDB when applicable.

#### Scenario: Upstream contributions

- **WHEN** ArcherDB discovers bugs or improvements in borrowed ArcherDB patterns
- **THEN** the project SHALL:
  - Report bugs to ArcherDB project
  - Contribute fixes upstream if applicable
  - Share performance optimizations discovered
  - Collaborate on shared infrastructure

#### Scenario: Geospatial-specific patterns

- **WHEN** ArcherDB develops geospatial-specific patterns
- **THEN** these SHALL remain ArcherDB-specific:
  - S2 integration (not relevant to ArcherDB)
  - Spatial query engine (domain-specific)
  - TTL/expiration (financial ledgers don't need this)

### Requirement: ArcherDB Team Consultation

The system SHALL maintain communication with ArcherDB team during implementation.

#### Scenario: Design validation

- **WHEN** adapting complex ArcherDB patterns
- **THEN** consider consulting ArcherDB team:
  - VSR protocol implementation questions
  - Performance optimization techniques
  - Correctness verification
  - Distributed systems edge cases

#### Scenario: Attribution and credit

- **WHEN** releasing ArcherDB
- **THEN** documentation SHALL:
  - Credit ArcherDB as foundational architecture
  - Link to ArcherDB project prominently
  - Acknowledge ArcherDB team's work
  - Encourage users to support ArcherDB project

### Requirement: Implementation Priority Based on ArcherDB Complexity

The system SHALL prioritize implementing proven ArcherDB patterns before custom geospatial features.

#### Scenario: Implementation order

- **WHEN** planning implementation sequence
- **THEN** implement in this order:
  1. **Core Types** (GeoEvent, BlockHeader) - Low risk, ArcherDB pattern
  2. **Memory Management** (StaticAllocator, pools) - Critical foundation, copy ArcherDB
  3. **Storage Engine** (data file, superblock) - Reuse ArcherDB exactly
  4. **I/O Subsystem** (io_uring) - Reuse ArcherDB exactly
  5. **VSR Protocol** (replica, view changes) - Most complex, follow ArcherDB precisely
  6. **Query Engine** (state machine) - Adapt ArcherDB's StateMachine interface
  7. **S2 Integration** (NEW - geospatial-specific) - After foundation stable
  8. **Spatial Queries** (NEW - geospatial-specific) - After S2 works
  9. **TTL/Backup** (NEW - ArcherDB features) - After core proven
  10. **Client SDKs** (adapt ArcherDB client patterns) - Final layer

#### Scenario: Risk mitigation

- **WHEN** implementing high-risk components
- **THEN** ArcherDB's proven patterns SHALL be used:
  - **VSR consensus:** Copy ArcherDB's protocol exactly (proven correct)
  - **Storage corruption detection:** Use Aegis-128L checksums like ArcherDB
  - **Memory safety:** Use StaticAllocator discipline exactly
  - **Testing:** Use VOPR simulator pattern before any custom tests

### Requirement: ArcherDB Debugging Techniques

The system SHALL adopt ArcherDB's debugging and verification techniques.

#### Scenario: Assertions and invariants

- **WHEN** implementing critical code paths
- **THEN** use ArcherDB's assertion patterns:
  ```zig
  // Based on ArcherDB's extensive use of assert()
  assert(self.status == .normal);
  assert(self.view >= self.log_view);
  assert(prepare.header.checksum == self.calculate_checksum(prepare));
  ```
- **AND** assertions remain enabled in production (like ArcherDB)
- **AND** assertion failures cause immediate panic (fail-fast)

#### Scenario: Comptime verification

- **WHEN** defining data structures
- **THEN** use comptime checks like ArcherDB:
  ```zig
  comptime {
      assert(@sizeOf(GeoEvent) == 128);
      assert(@alignOf(GeoEvent) == 16);
      stdx.no_padding(GeoEvent);  // From ArcherDB's stdx.zig
  }
  ```

#### Scenario: Logging patterns

- **WHEN** adding log statements
- **THEN** follow ArcherDB's patterns:
  - Use std.log with structured fields
  - Log state transitions explicitly
  - Include view/op numbers in VSR logs
  - Log timing information for performance debugging

### Requirement: ArcherDB Constants Reuse

The system SHALL reuse ArcherDB's constant naming conventions and values where applicable.

#### Scenario: Constant naming

- **WHEN** defining constants
- **THEN** use ArcherDB's naming pattern:
  ```zig
  // ArcherDB naming style (from src/constants.zig)
  // NOTE: ArcherDB values differ - see constants/spec.md for authoritative values
  // Example: ArcherDB uses journal_slot_count = 8192 (not 1024) for 60s checkpoint support
  pub const message_size_max = 10 * 1024 * 1024;  // Same as ArcherDB
  pub const journal_slot_count = 8192;             // ArcherDB: 8192 (ArcherDB: 1024)
  pub const pipeline_max = 256;                    // Same as ArcherDB
  pub const checkpoint_interval = 256;             // Same as ArcherDB
  ```
- **AND** use snake_case with descriptive suffixes
- **AND** include comments explaining derivation

#### Scenario: Derived constants

- **WHEN** constants depend on ArcherDB values
- **THEN** document the relationship:
  ```zig
  // Based on ArcherDB's block_size = 64KB
  pub const block_size = 64 * 1024;
  pub const block_header_size = 256; // BlockHeader at start of each block

  // Derived from ArcherDB's events_per_block pattern
  // Accounts for 256-byte BlockHeader
  pub const events_per_block = (block_size - block_header_size) / geo_event_size; // 510 events
  ```

### Requirement: Journal Sizing Validation and Retention Guarantees

The system SHALL validate that the configured journal_slot_count provides sufficient retention to meet recovery window guarantees.

- **WHEN** validating journal sizing (F0.2.7 gate)
- **THEN** the system SHALL execute a measurement procedure:
  ```
  JOURNAL SIZING VALIDATION PROCEDURE
  ════════════════════════════════════

  OBJECTIVE: Empirically validate that journal_slot_count=8192 supports ≥60 second
  retention window at target throughput of 1M operations/second.

  MEASUREMENT SETUP:
  ─────────────────
  1. Configuration:
     - Single-node ArcherDB instance (no replication, single replica)
     - journal_slot_count = 8192 (ArcherDB: 1024, ArcherDB scaling: 8x)
     - Target throughput: 1M operations/second
     - Measurement duration: 120 seconds (2× desired retention window)

  2. Workload generation:
     - Constant rate: 1M insert_events/second
     - Payload: Minimal GeoEvent (test locations uniformly distributed)
     - Request batching: Multi-batch protocol with 100-200 events per batch
     - Connection count: 16-32 concurrent connections (to saturate 1M ops/sec)

  3. Metrics collection:
     - Timer: Record wall-clock time (must run ≥120s without timeout)
     - WAL: Track journal_head and journal_tail pointers continuously
     - Throughput: Count actual operations written per second
     - Checkpoints: Record when checkpoints occur (every 256 operations per ArcherDB)

  VALIDATION PROCEDURE:
  ────────────────────
  1. Run benchmark for 120 seconds at 1M ops/sec (target: 120M total operations)

  2. Calculate metrics:
     ops_per_checkpoint = (checkpoint_interval × 2) = 512 operations per checkpoint
       [Rationale: ArcherDB's checkpoint_interval=256 pipelines per checkpoint,
        each pipeline contains ~2 batches on average, each batch ~1 operation]

     ops_per_slot_actual = (total_ops_written) / (checkpoints_executed)
       [Record from instrumentation during test]

     retention_seconds = (journal_slot_count × ops_per_slot_actual) / (ops_per_second)
       [Key equation: retention = (8192 slots × ops_per_slot) / 1M ops/sec]

  3. Determine pass/fail:
     PASS criteria:
       - retention_seconds ≥ 60 seconds (meets F2.2.7 gate requirement)
       - No timeout or throughput collapse during 120s run
       - Journal never overflows (tail catches head)

     FAIL criteria:
       - retention_seconds < 60 seconds
       - Timeout or crash during test
       - Journal overflow detected
       - Sustained throughput < 800K ops/sec (20% degradation acceptable)

  4. If PASS: Document results in constants/spec.md:
     ```
     VALIDATION RESULT (Week 2, F0.2.7):
     ═════════════════════════════════════
     Date: [test date]
     Configuration: Single-node, 8192 journal slots, 1M ops/sec target
     Measured ops_per_checkpoint: [X] operations
     Calculated retention: [Y] seconds
     Status: ✅ PASS - meets ≥60s requirement
     ```

  5. If FAIL: Recalculate required journal_slot_count:
     required_slots = (target_throughput × retention_window_seconds) / ops_per_slot

     Example FAIL recovery:
     - Measured ops_per_slot = 1024 (ArcherDB-like)
     - Required for 60s retention: (1M ops/sec × 60s) / 1024 = 58,594 slots
     - Minimum: 65,536 slots (next power of 2)
     - Action: Update F0.4.1 constant to 65536
     - Risk: Larger journal = more memory, slower checkpoint operations
     - Document decision: "F0.2.7 FAIL → require 65K slots for v1.0"

  BLOCKER IMPACT:
  ───────────────
  This validation gates:
  - F2.2.7: Recovery window guarantee definition
  - F2.2.9: Recovery metrics implementation
  - Specification: hybrid-memory/spec.md recovery procedures (relies on retention window)

  Timeline:
  - Must complete by end of Week 2
  - If FAIL, ripple cost: +2-3 days to recalculate and update all downstream specs

  CROSS-REPLICA VALIDATION:
  ───────────────────────
  After F1 (state machine complete), validate on 3-node cluster:
  - All replicas should measure same ops_per_checkpoint
  - Retention window must be consistent across replicas
  - Alert if any replica diverges > 5% from mean retention
  - Root cause: May indicate GC pauses, I/O delays, or clock drift
  ```

### Requirement: ArcherDB Testing Patterns

The system SHALL adopt ArcherDB's testing methodology.

#### Scenario: Simulator-based testing

- **WHEN** testing distributed system behavior
- **THEN** use ArcherDB's approach:
  - Deterministic simulation with PRNG seed
  - Fault injection at multiple layers
  - Two-phase testing (safety properties first, liveness second)
  - Seed-based replay for bug reproduction
  - State machine invariant checking

#### Scenario: Fuzzing strategy

- **WHEN** fuzzing the system
- **THEN** follow ArcherDB's patterns:
  - Generate random but valid operation sequences
  - Inject faults deterministically
  - Verify state machine invariants after each operation
  - Save failing seeds for regression tests

### Requirement: Performance Optimization Patterns

The system SHALL adopt ArcherDB's performance optimization techniques.

#### Scenario: Cache alignment

- **WHEN** defining data structures
- **THEN** follow ArcherDB's alignment strategy:
  - Align structures to cache line boundaries (64 or 128 bytes)
  - Use `align(N)` attribute explicitly
  - Pack fields to minimize padding
  - Verify with `stdx.no_padding()`

#### Scenario: Zero-copy techniques

- **WHEN** implementing message handling
- **THEN** use ArcherDB's zero-copy patterns:
  - Wire format = memory format (extern struct)
  - @ptrCast for buffer reinterpretation
  - Pre-allocated MessagePool (no runtime malloc)
  - Reference counting for shared messages

#### Scenario: Batching

- **WHEN** implementing operations
- **THEN** follow ArcherDB's batching approach:
  - Batch-only API (refuse single operations)
  - Multi-batch encoding (amortize consensus cost)
  - Trailer-based batch metadata
  - Deterministic timestamp distribution across batches

### Requirement: Safety and Correctness Patterns

The system SHALL adopt ArcherDB's safety-critical programming practices.

#### Scenario: Error handling

- **WHEN** handling errors
- **THEN** follow ArcherDB's patterns:
  - Use Zig's error unions (`!Type`)
  - Explicit error handling (no try-catch, check every error)
  - Fail-fast on assertions (don't mask bugs)
  - Log errors with context before panicking

#### Scenario: Undefined behavior prevention

- **WHEN** writing code
- **THEN** avoid undefined behavior like ArcherDB:
  - No uninitialized memory reads
  - No out-of-bounds array access
  - No integer overflow (check explicitly)
  - Use `-OReleaseSafe` in production (keep runtime checks)

### Requirement: Documentation Style

The system SHALL adopt ArcherDB's documentation style for code comments.

#### Scenario: Function documentation

- **WHEN** documenting functions
- **THEN** use ArcherDB's style:
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
- **AND** reference ArcherDB source for complex algorithms

### Requirement: Build and Deployment Patterns

The system SHALL adopt ArcherDB's build system patterns where applicable.

#### Scenario: Build configuration

- **WHEN** setting up build system
- **THEN** reference ArcherDB's approach:
  - Single `build.zig` for entire project
  - Compile-time configuration (no runtime ifdefs)
  - Cross-compilation support (Linux/macOS/Windows)
  - Static linking where possible

#### Scenario: Release optimization levels

- **WHEN** building for production
- **THEN** use ArcherDB's optimization strategy:
  - `-OReleaseSafe` (default) - keep runtime safety checks
  - NOT `-OReleaseFast` (removes bounds checking)
  - Enable LTO (Link-Time Optimization)
  - Enable PGO (Profile-Guided Optimization) for hot paths

### Requirement: Open Questions Resolution via ArcherDB

The system SHALL resolve specification ambiguities by consulting ArcherDB's implementation.

#### Scenario: Specification ambiguity

- **WHEN** a specification is unclear or ambiguous
- **THEN** the resolution process SHALL be:
  1. Check if ArcherDB has solved this problem
  2. Read ArcherDB's code for that component
  3. Understand how ArcherDB handles it
  4. Adopt ArcherDB's approach (unless geospatial-specific)
  5. Document the decision with ArcherDB reference

#### Scenario: Implementation detail omission

- **WHEN** specification omits implementation details
- **THEN** implementers SHALL:
  - NOT make assumptions
  - NOT invent custom solutions
  - Study ArcherDB's handling of similar cases
  - Follow ArcherDB's pattern
  - Propose specification update if detail is critical

**Example:** Specification doesn't detail exact PrepareOk quorum tracking → Study `src/vsr/replica.zig:on_prepare_ok()` → Implement same bitfield approach.

### Requirement: Geospatial-Specific Implementation Guidance

The system SHALL distinguish between ArcherDB-borrowed patterns (marked with `// From ArcherDB:` comments) and geospatial-specific implementations (marked with `// ArcherDB-specific:`).

#### Scenario: S2 Geometry Library (NEW - Not from ArcherDB)

- **WHEN** implementing S2 spatial indexing
- **THEN** this is NEW code (not from ArcherDB):
  - Study S2 geometry papers and Go reference implementation
  - Port core algorithms to Zig (lat/lon ↔ cell_id, Hilbert curve, RegionCoverer)
  - Follow Zig style but NOT ArcherDB style (different domain)
  - Test extensively (this is custom code without ArcherDB's battle-testing)

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

#### Scenario: CRITICAL - S2 Determinism Validation Spike (Decision Gate F0.4.6c)

- **WHEN** implementing S2 geometry library
- **THEN** a CRITICAL validation spike MUST occur in **Weeks 1-4 of Phase F0** (before proceeding to Phase F3)
- **BLOCKING GATE**: Implementation cannot proceed with F3.1-F3.3 (S2 Integration) until this spike is completed

**Why This Spike is Critical**:
- Non-deterministic S2 computation causes **replica divergence** (hash-chain breaks, cluster-wide panic)
- VSR consensus requires **bit-exact identical results** on all replicas across all platforms
- Floating-point math (sin, cos, atan2) NOT bit-exact across x86/ARM/macOS/Linux unless carefully controlled

**Spike Timeline** (2-3 weeks):
```
WEEK 1-2 (F0.4-F0.5): Evaluate Options A & B
─────────────────────────────────────────────
- Option A: Pure Zig with software trig (Chebyshev + CORDIC)
  CRITICAL PASS Criterion (MUST PASS - this is the real test):
    → Golden vector validation: S2 cell ID matches Google reference (C++ S2)
       BIT-EXACT on 10,000 test vectors across ALL available platforms
       - Vectors include all 31 S2 levels: [0, 1, 5, 10, 15, 18, 30]
       - Edge cases: poles (lat ±90°), antimeridian (lon ±180°)
       - Degenerate cases: very small areas, very large areas, line segments
       - ANY SINGLE MISMATCH = FAIL (treat as fatal)
       - Test on: x86-64 Linux (required), ARM64 Linux (required if available),
                  macOS x86-64 (required), macOS ARM64 (required if available)
       - Acceptable to skip 1 platform if hardware unavailable (document gap)
       - Unacceptable to test only 1 platform

  Secondary Validations (diagnostic, help explain failures):
    1. Chebyshev polynomial sin/cos accuracy:
       - Measure: max absolute error vs reference on 1000 test angles
       - Target: < 1e-15
       - If golden vectors pass: ignore this (trig must be good enough)
       - If golden vectors fail: analyze trig error to diagnose issue
    2. CORDIC atan2 accuracy:
       - Measure: max absolute error vs reference on 1000 test points
       - Target: < 1e-15
       - Same diagnostic purpose as Chebyshev

  Performance Target (target, not hard requirement):
    - Covering duration < 1ms p99 on simple geometries (radius < 1km)
    - Acceptable: 10-100ms p99 on complex polygons (can document as limitation)
    - If > 100ms p99 on simple: may reconsider approach

  FAIL Criteria (any one = pivot to Option B):
    - Golden vector mismatch on ANY platform (even 1 vector mismatch = failure)
    - Cannot compile with -O3 on target platforms
    - Covering performance > 100ms p99 on simple geometries
    - Trig functions unable to achieve < 1e-10 accuracy (not 1e-15, just < 1e-10)

- Option B: Primary-computed + hash verification (pragmatic fallback)
  CRITICAL PASS Criterion (MUST PASS):
    → Primary computes S2 cell ID, replicas verify via hash without recomputing S2
       All 10,000 golden vectors produce identical results on all platforms
       (because they use Google's C++ S2, which is deterministic)

  Implementation Details (MUST be specified):
    1. Hash function: SHA-256(cell_id_0 || cell_id_1 || ... || cell_id_N)
       - Compute aggregate hash per batch
       - Include aggregate hash in prepare message
       - Each replica independently verifies after computing all cell IDs
    2. Mismatch handling: If hash doesn't match:
       - Log CRITICAL error: "S2 divergence detected, primary hash=%x, computed=%x"
       - PANIC replica immediately (cannot continue)
       - Do NOT attempt to reconcile or fallback
       - This prevents silent corruption
    3. Integration: Google C++ S2 via:
       - Zig C FFI bindings (preferred, lightweight)
       - Static linking with ABI stability guarantee
       - Version pin: Google S2 library version X.Y.Z (immutable)
       - Build determinism: Binary must be reproducible across platforms

  Performance Requirement:
    - Hash verification latency: < 1ms per batch (10ms for 100-batch message)
    - This is acceptable overhead (< 2% of typical batch latency)

  FAIL Criteria (any one = evaluate fallback):
    - Cannot integrate Google S2 safely (licensing issues, build complexity)
    - Hash verification introduces > 5% latency overhead
    - Platform divergence detected even with Google S2 library
    - Confidence < 70% in long-term maintainability

WEEK 3 (F0.4.6c): Decision Point
────────────────────────────────
- **Friday End-of-Day: GO/NO-GO Decision**
  - IF Option A PASS: Choose Option A (pure Zig, maximum control)
  - IF Option A FAIL + Option B PASS: Choose Option B (pragmatic v1)
  - IF Both FAIL: Evaluate grid-based fallback (absolute last resort)
  - Document decision rationale in design.md Decision 3a section

WEEK 4+ (F0.4.7, then F3.2): Golden Vector Validation
──────────────────────────────────────────────────────
- Generate 10,000+ golden vectors from Google S2 reference (C++)
- Validate on ALL 4 platforms (x86-64 Linux, ARM64 Linux, x86-64 macOS, ARM64 macOS)
- ANY platform divergence = BLOCKER (investigate floating-point difference)
- Success: All platforms produce identical cell IDs for all vectors
- Failure: Escalate to Decision 3a, may need to pivot options
```

**Success Criteria (MUST ALL BE TRUE to proceed)**:

| Criterion | Validation | Failure Action | Timeline |
|-----------|-----------|---------------|-----------|
| **Option Feasibility** | Spike completes with clear winner | Re-run spike, may extend to Week 5 | Week 3 |
| **Performance Target** | Covering < 50ms p99 (Option A acceptable @ 100-200ms, still < polygon SLA) | Reconsider thresholds if needed | Week 3 |
| **Platform Determinism** | S2 cell_id identical on x86/ARM/macOS | ANY divergence = investigate, may pivot | Week 4 |
| **Golden Vectors** | 100% match on 10,000 reference vectors | Fix algorithm, revalidate (add 1 week) | Week 4-5 |
| **Implementation Feasibility** | No show-stopping Zig stdlib gaps | Implement workarounds in F0.2 | Week 2 |

**Failure Criteria** (Any one failure → STOP, evaluate fallback):
- Zig comptime math unable to achieve < 1e-15 error (Option A fails)
- Hash-based verification introduces unacceptable latency (Option B fails)
- Platform divergence detected and root cause unclear
- Confidence < 70% in implementation path

**Fallback Strategy** (If both A and B fail or high risk):
```
GRID-BASED SPATIAL INDEX (Last Resort) - SCOPE & REALISTIC ESTIMATE
───────────────────────────────────────────────────────────────────

⚠️ WARNING: Grid-based fallback is NOT a quick pivot. It is a complete spatial indexing rewrite.

Scope:
- Replace S2 hierarchical cell model with fixed-size grid cells (e.g., 100m × 100m)
- Integer arithmetic only (no floating-point transcendentals)
- Must support radius queries (approximate: expand query box) and polygon queries (grid-based containment test)
- Trade-off: Less elegant spatial hierarchy vs 100% deterministic on any platform

Implementation Effort (REALISTIC):
- Week 1: Design grid cell layout, coordinate conversion formulas (lat/lon → grid_x/grid_y)
- Week 1: Implement grid cell ID encoding (u64 composite ID like S2)
- Week 2: Implement radius query expansion (convert radius meters → grid cell expansion)
- Week 1-2: Implement polygon containment testing with grid cells
- Week 1: Integration testing and performance validation
- TOTAL: ~2 weeks of focused development (AI-assisted)

Timeline Impact:
- If F0.4.6 spike FAILS (both Option A/B): +2 weeks delay in F3 start (Week 26→28)
- If grid fallback needed: +2 weeks in F3 implementation (Week 28→30)
- TOTAL if fallback invoked: +4 weeks vs original plan

Risk:
- Grid cells have different locality properties than S2 (larger cell sizes)
- May impact query performance vs S2 Option B
- Requires re-benchmarking all spatial queries with grid model

Use ONLY if:
1. Option A spike proves mathematically infeasible (> 1e-10 error, < 70% confidence)
2. Option B hash verification proves too slow (> 100ms p99 query latency)
3. Platform divergence proves unsolvable (different CPU precision)

Recommendation:
- Assume Option A/B will work (90% probability)
- Do NOT plan for grid fallback in baseline schedule
- Only implement if spike clearly shows need
- If needed, evaluate timeline impact and adjust milestones
```

**Deliverables After Spike**:
1. **Decision documentation**: "S2 Determinism Strategy (Option X chosen)" in design.md
2. **Spike results**: Recorded in `testdata/s2/spike_report_f0.4.6.txt`
3. **Implementation plan**: Specific algorithms chosen (Option A → Chebyshev/CORDIC, or Option B → hash function)
4. **Risk mitigation**: Any platform-specific issues found and documented
5. **Week 4 go/no-go**: Implementation confidence documented > 80%

**CRITICAL**: This spike is NOT optional or deferrable. Proceeding to F3 without resolving S2 determinism risks entire project correctness (replica divergence → cluster panic).

**Related Requirements**:
- See `tasks.md` F0.4.6a-F0.4.6d for detailed decision gate implementation
- See `design.md` Decision 3a for complete architecture and rationale
- See `query-engine/spec.md` for S2 usage in radius/polygon queries (depends on determinism guarantee)

#### Scenario: Hybrid Memory Index (PARTIALLY from ArcherDB)

- **WHEN** implementing RAM index
- **THEN** this combines patterns:
  - **From ArcherDB:** Hash map structure, static allocation, no resizing
  - **Custom:** LWW conflict resolution (ArcherDB doesn't have this)
  - **Custom:** TTL expiration checks (ArcherDB doesn't have this)
  - **Custom:** Index checkpointing (ArcherDB's state is deterministically reproducible)

**Guideline:** Borrowed foundation + custom features. Test custom features more heavily.

### Requirement: Version Tracking

The system SHALL track which ArcherDB version corresponds to which ArcherDB version.

#### Scenario: Release notes

- **WHEN** releasing ArcherDB versions
- **THEN** release notes SHALL include:
  ```markdown
  ## ArcherDB v0.1.0

  Based on ArcherDB v0.15.3 (commit: abc123...)

  ### ArcherDB Patterns Used:
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

- **WHEN** updating ArcherDB reference version
- **THEN** document in CHANGELOG:
  - Which ArcherDB version we tracked
  - What changed in ArcherDB
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
- **AND** ArcherDB implementation: `src/vsr/clock.zig`

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
- **THEN** use ArcherDB's selection algorithm:
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
- **AND** ArcherDB implementation: `src/lsm/compaction.zig`

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
- **AND** ArcherDB implementation: `src/vsr/journal.zig:verify_hash_chain()`

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
- **THEN** use ArcherDB's free set algorithm:
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
- **AND** ArcherDB implementation: `src/vsr/free_set.zig`

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
- **AND** ArcherDB implementation: `src/vsr/superblock.zig:read_quorum()`

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
- **AND** ArcherDB implementation: `src/vsr/replica.zig:on_do_view_change()`

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

- **WHEN** entire cluster MUST be restored from backup
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

#### Scenario: Corruption detection monitoring in steady state

The system SHALL implement continuous corruption detection to identify failures before recovery is needed.

- **WHEN** the system is operating normally
- **THEN** corruption detection SHALL proceed as follows:
  ```
  CORRUPTION DETECTION IN STEADY STATE
  ════════════════════════════════════

  CONTINUOUS DETECTION (during normal operation):
  ──────────────────────────────────────────────
  1. Periodic integrity checks (during checkpoint):
     - Frequency: Every checkpoint (default 30 seconds)
     - Scope: Verify all index entries can be looked up
     - Verify no orphaned entries in hash table
     - Verify probe lengths match expected structure
     - Time budget: < 100ms (must not block queries)

  2. Checksum verification on block reads:
     - For every page read from index: verify CRC32C checksum
     - Frequency: 100% of reads (always enabled, 0% overhead with hardware CRC)
     - Detection: Mismatch triggers immediate corruption alert
     - Behavior: Log error, increment archerdb_index_corruption_detected counter

  3. Replica divergence detection:
     - Via VSR commit comparison (already in replication/spec.md)
     - When replicas' archerdb_commit_sequence diverges > 1000ms:
       - This is unrecoverable divergence (see hybrid-memory/spec.md)
       - Trigger: Treat as corruption, initiate replica replacement

  METADATA VALIDATION FAILURE HANDLING:
  ─────────────────────────────────────
  Critical metadata structures (WAL head/tail, LSM manifest, superblock) are validated:
  - On every access: Quick validation (< 1μs)
  - On failure: Increment validation_failure_count

  Failure threshold for UNRECOVERABLE declaration:
  - 1st failure: Log as WARNING, continue operation (validation_failures=1)
  - 2-5 failures within 60s: Escalate to ERROR, notify operator (validation_failures=2-5)
  - 6+ failures within 60s: Declare UNRECOVERABLE, halt further writes (validation_failures≥6)
    [Rationale: If metadata is corrupted at this rate, recovery is likely to fail anyway.
     Halt writes to prevent cascading corruption. Operator must provision backup restore.]

  DETECTION ALERTS:
  ─────────────────
  - archerdb_index_corruption_detected: Counter incremented on ANY corruption detection
  - archerdb_metadata_validation_failed: Counter for failed validations
  - Alert rule: If corruption_detected > 0 in past 5 minutes → CRITICAL (page on-call)
  - Alert rule: If validation_failed > 5 in past 60s → CRITICAL (acknowledge in 1 hour)
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

### Requirement: Recovery Edge Cases and Unrecoverable Procedures

The system SHALL define explicit procedures for unrecoverable scenarios and backup restore edge cases.

#### Scenario: Unrecoverable scenario decision tree

- **WHEN** a recovery procedure is attempted and fails
- **THEN** the system SHALL follow this decision tree to determine if recovery is possible:
  ```
  UNRECOVERABLE SCENARIO DECISION TREE
  ════════════════════════════════════

  1. LOAD DATA FILE:
     - Can superblock be read from any of 3 copies?
       YES → Proceed with recovery path selection (see hybrid-memory/spec.md)
       NO  → UNRECOVERABLE (go to step 5)

  2. DETERMINE RECOVERY PATH:
     - Is checkpoint valid and recent (< 5 minutes old)?
       YES → WAL replay path (fast recovery)
       NO  → Proceed to step 3
     - Is LSM manifest readable?
       YES → LSM replay path (medium recovery)
       NO  → Proceed to step 3

  3. CHECK FULL REBUILD FEASIBILITY:
     - Is data file structurally valid?
       YES → Full rebuild possible (slow recovery)
       NO  → UNRECOVERABLE (go to step 5)
     - Is disk space available (need 2x data file size for rebuild)?
       YES → Proceed with full rebuild
       NO  → UNRECOVERABLE (go to step 5)

  4. RECOVERY PATH SELECTED:
     - Execute appropriate path (WAL/LSM/rebuild)
     - Wait for completion
     - Verify index built successfully
     - Return to normal operation

  5. UNRECOVERABLE:
     - Log critical error with detailed failure reason
     - Replica MUST NOT attempt recovery again (prevent infinite loop)
     - Return exit code indicating unrecoverable state
     - Operator MUST provision backup restore (see below)
  ```

#### Scenario: Unrecoverable scenario triggers

- **WHEN** any of these conditions are detected
- **THEN** recovery is declared UNRECOVERABLE:
  ```
  UNRECOVERABLE CONDITION CHECKLIST:

  ✗ All 3 superblock copies corrupted or missing
    - Cannot determine data file layout, checksum algorithm, or recovery window
    - Required action: Full backup restore
    - Time to recovery: 60-90 minutes (for 1B entities)

  ✗ Data file checksum verification fails AND cannot repair
    - Detected when: storage engine reports CRC mismatch on multiple blocks
    - Indicates: Disk failure, data corruption, or bitrot
    - Required action: Full backup restore
    - Investigation: Check disk SMART data, ECC memory logs

  ✗ Index checkpoint corrupted AND full rebuild disk space unavailable
    - Detected when: index_checkpoint_age_seconds continuously increasing
    - No WAL coverage (gap > journal_slot_count)
    - No LSM backup tables
    - No disk space to rebuild
    - Required action: Provision additional disk, then full backup restore

  ✗ Disk space exhaustion prevents index checkpoint and recovery
    - Detected when: Write fails due to no space
    - Cannot checkpoint index (no disk space)
    - Cannot recover from crash (need checkpoint)
    - Cannot restore from backup (need space for new data file)
    - Required action: Delete old backups, external storage, or new hardware

  ✗ VSR superblock quorum lost and primary election impossible
    - Detected when: Cannot read quorum view from superblock
    - All 3 superblock copies have different view data
    - Indicates: Corrupted VSR state, impossible to determine primary
    - Required action: Full backup restore OR manual cluster reset (see replication/spec.md)

  ✗ Replica data file format unrecognized (version mismatch after upgrade failure)
    - Detected when: superblock.version_code != expected version
    - Indicates: Failed upgrade or corrupted superblock
    - Required action: Verify upgrade was complete, or restore from pre-upgrade backup

  ✗ Critical metadata structure validation fails repeatedly
    - Detected when: Journal WAL ring head/tail pointers are inconsistent
    - Or: LSM manifest lists blocks that don't exist on disk
    - Indicates: Severe metadata corruption
    - Required action: Full backup restore
  ```

#### Scenario: Backup restore procedures for edge cases

- **WHEN** performing backup restore in edge case scenarios
- **THEN** procedures SHALL be:
  ```
  BACKUP RESTORE EDGE CASES
  ═════════════════════════

  EDGE CASE 1: Backup checksum mismatch during restore
  ─────────────────────────────────────────────────────
  Scenario: archerdb restore detects CRC mismatch on backup block

  Cause:
  - Network corruption during block download (unlikely with HTTPS)
  - S3 object storage bitrot (rare but possible)
  - Corrupted backup block at source

  Procedure:
  1. Stop restore operation immediately
  2. Log error with block sequence number and checksum details
  3. Re-download the block from S3:
     - Retry 3 times with exponential backoff
     - If still fails: block may be permanently corrupted
  4. Assess recovery options:
     a. If failed block is recent (within tolerance):
        - Restore to point-in-time BEFORE the block
        - Use --point-in-time=<timestamp-before-failure>
        - Accept RPO of data lost
     b. If failed block is critical (early blocks with base data):
        - Escalate to cloud provider (S3 corruption)
        - Request block repair or provide alternative backup
        - Wait for provider to fix, or use older backup
  5. Verify restored data with additional checksums
  6. Run data consistency check post-restore

  Time impact: +10-30 minutes (retry delay, re-download)

  EDGE CASE 2: Backup bucket access denied during restore
  ─────────────────────────────────────────────────────────
  Scenario: S3 credentials expired, IAM policy changed, or bucket deleted

  Cause:
  - Credentials expired mid-restore
  - IAM role revoked
  - Backup bucket deleted or moved
  - Network connectivity lost to S3

  Procedure:
  1. Check S3 bucket accessibility:
     $ aws s3 ls s3://your-backup-bucket
  2. Verify credentials:
     $ aws sts get-caller-identity
  3. If credentials expired:
     - Obtain new credentials
     - Resume restore with --resume flag:
       $ archerdb restore --resume --from-s3=s3://... --credentials=...
  4. If IAM policy changed:
     - Restore policy (s3:GetObject, s3:ListBucket)
     - Resume restore
  5. If bucket deleted:
     - Restore bucket from S3 versioning or provider backups
     - Or restore from alternative backup (if exists)
  6. If network lost:
     - Restore network connectivity
     - Resume restore

  Prevention:
  - Monitor credential expiration (alert 7 days before)
  - Test backup restore quarterly (catches IAM drift)
  - Use IAM policies with long-lived credentials for restore
  - Verify backup bucket exists in account during health checks

  EDGE CASE 3: Partial backup (cluster failure mid-backup)
  ──────────────────────────────────────────────────────────
  Scenario: Backup was interrupted by node failure or network issue

  Symptoms:
  - Block sequence numbers have gaps
  - Backup metadata incomplete
  - List shows partial upload timestamps

  Procedure:
  1. Identify last complete block:
     $ archerdb backup verify --bucket=s3://... --repair
     - Scans all blocks, checks sequence continuity
     - Reports first gap
  2. Restore to point-in-time BEFORE gap:
     $ archerdb restore --from-s3=... --point-in-time=<before-gap> \
         --to-data-file=...
  3. Accept data loss:
     - RPO = time to last complete backup block
     - This is ACCEPTABLE (backup unavailable anyway)
  4. After restore, trigger full backup:
     - Ensures next backup is complete
     - Blocks previous partial backup from being used again

  Prevention:
  - Monitor backup completion metrics:
    archerdb_backup_blocks_uploaded_total - archerdb_backup_lag_blocks
  - Alert if backup hangs for > 1 hour
  - Use mandatory backup mode (halts writes if backup fails)

  EDGE CASE 4: Restore creates smaller index than original
  ──────────────────────────────────────────────────────────
  Scenario: Using --skip-expired filtering, index is much smaller

  Cause:
  - TTL expiration since backup was created
  - Entities deleted since backup
  - Tombstones marked as deleted

  Procedure:
  1. This is EXPECTED behavior (not an error)
     - Filtered expired events per backup-restore spec
     - Smaller index = faster rebuild
  2. Verify restoration succeeded:
     $ archerdb restore --verify --from-s3=... --to-data-file=...
  3. Compare to expected size:
     - If index >> expected: may indicate restore failure
     - If index << expected: verify TTL expiration is correct
  4. Run queries to sample restored data
  5. Proceed with normal operations

  EDGE CASE 5: Cannot allocate disk space for restored data
  ───────────────────────────────────────────────────────────
  Scenario: Target disk has insufficient space for data file

  Cause:
  - Disk smaller than original cluster
  - Other processes using space
  - Filesystem quota exceeded

  Procedure:
  1. Calculate required space:
     - Backup block size ≈ Original data file size
     - Add 2x for rebuild (temporary)
     - Minimum: data_file_size + 2×data_file_size
  2. Free disk space:
     - Delete old backups: $ rm /old-backup-path/*
     - Delete temporary files: $ journalctl --vacuum=2d
     - Move other data to other filesystem
  3. Or provision new disk:
     - Add new device: $ fdisk /dev/sdX
     - Extend filesystem: $ lvextend -L +500G /dev/mapper/...
  4. Resume restore:
     $ archerdb restore --resume --from-s3=... --to-data-file=...
  5. Verify: $ df -h /path (should show adequate free space)

  EDGE CASE 6: Restore from backup created on different cluster version
  ─────────────────────────────────────────────────────────────────────────
  Scenario: Backup from v1.0, restoring to v1.1 cluster

  Cause:
  - Cluster upgraded to new version
  - Need to restore from old backup (replay/rollback)

  Procedure:
  1. Check compatibility:
     $ archerdb backup info --bucket=s3://... \
         --show-version
     Expected: Version matches current cluster or older
  2. If backup is NEWER than cluster:
     - Downgrade not supported
     - Either upgrade cluster or find older backup
     - Or proceed with data loss (restore to older backup)
  3. If backup is SAME or OLDER:
     - Restore normally
     - v1.1 is backward compatible with v1.0 backups
     - Format migration happens post-restore if needed
  4. Verify result:
     $ archerdb status
     $ archerdb verify --data-file=...

  EDGE CASE 7: Restore replica to wrong cluster ID
  ──────────────────────────────────────────────────
  Scenario: Restore backup from Cluster A to Cluster B

  Cause:
  - Operator error (wrong backup path)
  - Cross-cluster disaster (restore to wrong DR site)

  Procedure:
  1. Prevention (CRITICAL):
     - archerdb restore MUST validate cluster-id
     - Block restore if cluster-id mismatch (exit code 2)
     - Operator MUST pass --force-cluster-id to override
  2. If mistake discovered mid-restore:
     - Stop restore immediately
     - Delete partially restored data file
     - Start fresh with correct backup
  3. If discovered post-restore:
     - Data is in wrong cluster (FATAL)
     - Cluster will reject due to cluster-id mismatch
     - Cannot proceed
     - Delete corrupted data file
     - Restore from correct backup
  4. Recovery from cross-cluster restore:
     - Restore failed replicas with correct backup
     - Cluster continues serving from unaffected replicas
     - Affected replica catches up via state sync
  ```

#### Scenario: Unrecoverable cluster procedures

- **WHEN** entire cluster becomes unrecoverable
- **THEN** emergency procedures SHALL be:
  ```
  EMERGENCY UNRECOVERABLE CLUSTER PROCEDURES
  ═══════════════════════════════════════════

  SITUATION: All replicas have corrupted data files, or backups unavailable.
  IMPACT: Complete data loss or very old restore point.
  RTO: 2-4 hours (if backup exists), or catastrophic loss if not.

  STEP 1: ASSESS SITUATION
  ────────────────────────
  - Do backups exist in S3/object storage?
  - What is the oldest complete backup?
  - When was last backup completed?
  - Is any replica data recoverable (even partially)?

  DECISION TREE:
  ┌─ YES, recent backup (< 1 day)      → Restore from backup (RTO: 2 hours)
  ├─ YES, old backup (> 1 week)        → Restore and accept data loss
  ├─ NO backup, but one replica OK      → Full cluster state sync recovery
  └─ NO backup, all replicas corrupt    → TOTAL DATA LOSS

  STEP 2: IF BACKUP EXISTS
  ────────────────────────
  1. Identify latest complete backup:
     $ aws s3 ls s3://backup-bucket --recursive | tail -20
  2. Verify backup integrity:
     $ archerdb backup verify --bucket=s3://... --detailed
  3. Provision new cluster (if old hardware unrecoverable):
     - New hardware (3-5 nodes)
     - Network configured
     - Storage provisioned
  4. Restore each replica:
     - Download backup blocks
     - Build index
     - Verify checksums
     - Start replica
  5. Verify cluster quorum:
     - All replicas joined
     - VSR consensus established
     - Cluster serving requests

  STEP 3: IF NO BACKUP (WORST CASE)
  ──────────────────────────────────
  If one replica survives with partial data:
  1. Identify surviving replica
  2. Perform recovery from that replica:
     $ archerdb start --data-file=/path/to/surviving/data.archerdb
  3. Other replicas catch up via state sync
  4. Cluster continues with recovered state
  5. Accept data loss since last backup

  If all replicas corrupted:
  - TOTAL DATA LOSS (unless external backups exist)
  - Notification to stakeholders (legal implications if personal data lost)
  - Incident post-mortem (why no backup? why not tested?)
  - Transition to manual recovery/litigation support

  POST-EMERGENCY:
  ────────────────
  1. Document what happened (timeline, root cause, recovery actions)
  2. Calculate RPO impact (how much data lost)
  3. Notify affected users if applicable
  4. Implement preventive measures:
     - Mandatory backup mode
     - Backup to multiple regions
     - Regular backup restore drills
     - Better monitoring/alerting
  5. Review disaster recovery SLA (update if unrealistic)
  6. Update runbook with lessons learned
  ```

#### Scenario: Recovery verification checklist

- **WHEN** any recovery operation completes
- **THEN** operators SHALL verify with this checklist:
  ```
  RECOVERY VERIFICATION CHECKLIST
  ═════════════════════════════════

  □ Replica startup:
    - Start time < expected (check archerdb_recovery_duration_seconds)
    - Recovery path matches expectation (WAL/LSM/rebuild)
    - No errors in logs

  □ Index integrity:
    - Entry count matches expected (query sample entities)
    - No missing or corrupted entries
    - Geospatial queries return correct results

  □ Replication health:
    - Replica joins cluster as "normal" status
    - Catches up to other replicas (replication_lag → 0)
    - Accepts write operations

  □ Data consistency:
    - Cross-replica query sampling (spot check 100 random entities)
    - All replicas return same results (linearizability)
    - Timestamp ordering correct (LWW)

  □ Performance baseline:
    - Query latency within expected range
    - No performance regressions
    - Compaction completing normally

  □ TTL/Expiration:
    - Expired events not served in queries
    - Tombstones prevent resurrection
    - TTL metrics consistent

  □ Backup health (post-restore):
    - Create backup and verify blocks upload
    - Backup completion metric increments
    - No backup delays

  □ Alerting active:
    - All monitoring alerts re-enabled
    - No stale alerting rules
    - On-call rotation notified recovery complete

  Failure of ANY check → escalate, do NOT declare recovery complete.
  ```

### Requirement: Recovery SLA Validation and Benchmarking (F2.3 Gate)

The system SHALL validate that recovery procedures meet defined SLA targets before proceeding to production.

- **WHEN** validating recovery performance (F2.3 gate, Week 12)
- **THEN** the system SHALL execute these benchmarks:
  ```
  RECOVERY SLA VALIDATION PROCEDURE
  ═════════════════════════════════

  OBJECTIVE: Empirically validate that recovery times meet SLA targets:
  - WAL replay: < 1 second
  - LSM rebuild: < 30 seconds
  - Full index rebuild: < 2 minutes (128GB), < 2 hours (16TB max)

  TEST SCENARIOS:
  ───────────────

  Scenario 1: WAL Replay Recovery
  ────────────────────────────────
  Setup:
    - Single-node with checkpoint + 60MB WAL (max retention window)
    - Simulate crash immediately after checkpoint written
    - WAL contains 60M operations (1M ops/sec × 60s)

  Test procedure:
    1. Start replica with checkpoint loaded, WAL intact
    2. Measure time from startup to "ready to accept queries"
    3. Repeat 10 times, record p50/p99/p99.9 latencies

  Pass criteria:
    - p99 replay time ≤ 1 second
    - No data loss detected post-recovery
    - Metrics: archerdb_recovery_wal_duration_seconds

  Scenario 2: LSM Replay Recovery
  ───────────────────────────────
  Setup:
    - Single-node with checkpoint + 3-level LSM (L0, L1, L2)
    - Simulate crash during compaction
    - Compaction incomplete (partially written L1 table)

  Test procedure:
    1. Intentionally corrupt checkpoint (mark as invalid)
    2. Startup must rebuild index from WAL + LSM
    3. Measure time to full index readiness
    4. Repeat 5 times (compaction-heavy, slower)

  Pass criteria:
    - p99 LSM replay ≤ 30 seconds
    - No data loss or orphaned LSM tables
    - All L0→L1→L2 compactions replayed correctly
    - Metrics: archerdb_recovery_lsm_duration_seconds

  Scenario 3: Full Index Rebuild
  ──────────────────────────────
  Setup:
    - Single-node with 1B entities (128GB index)
    - Simulate complete checkpoint corruption
    - Force full rebuild by scanning LSM newest→oldest

  Test procedure:
    1. Pre-populate 1B entities (via multi-batch insert)
    2. Trigger intentional corruption (overwrite superblock)
    3. Startup forces full rebuild path
    4. Measure time from crash detection to index ready
    5. Measure memory usage during rebuild

  Pass criteria:
    - p99 rebuild time ≤ 2 minutes (128GB), ≤ 2 hours (16TB max)
    - Memory during rebuild: < 256GB (2x index size acceptable for compaction buffers)
    - Zero entity loss (all 1B entities present post-rebuild)
    - Metrics: archerdb_recovery_rebuild_duration_seconds, archerdb_recovery_rebuild_percent

  DECISION GATE (Week 12):
  ──────────────────────
  GO: All 3 scenarios PASS → Proceed to F2.4 (TTL) and F3 (S2)
  NO-GO: Any scenario FAIL → Options:
    1. Optimize recovery path (faster LSM merge, better checkpoint placement)
    2. Extend F2 timeline +2 weeks (add F2.5 Recovery Optimization phase)
    3. Modify compaction strategy (reduce LSM levels, increase L0 size) → +1 week design

  CONTINGENCY ANALYSIS:
  ─────────────────────
  If FAIL on WAL replay (> 1s):
    - Issue: WAL too large or parsing slow
    - Fix: Optimize WAL format, use mmap for faster reading
    - Blocker risk: LOW (fundamental operations sound)
    - Timeline: +1-2 days optimization

  If FAIL on LSM rebuild (> 30s):
    - Issue: Compaction speed or LSM structure too deep
    - Fix: Increase compaction parallelism, reduce levels
    - Blocker risk: MEDIUM (may require LSM design change)
    - Timeline: +3-5 days design/implementation

  If FAIL on full rebuild (> 2 min for 128GB):
    - Issue: Sequential LSM scan is bottleneck
    - Fix: Parallelize rebuild, use prefetch hints
    - Blocker risk: MEDIUM (core algorithm may need redesign)
    - Timeline: +1 week optimization + testing
    - Risk: If cannot achieve 2 min, may need to limit single-node capacity
      (e.g., max 64GB per node, require sharding for 128GB+)

  MONITORING DURING F3-F4:
  ────────────────────────
  Continuously track recovery metrics in production:
  - Alert if WAL replay ever exceeds 500ms (50% of SLA)
  - Alert if LSM rebuild exceeds 15s (50% of SLA)
  - Alert if full rebuild exceeds 1 min (50% of SLA)
  - Trend analysis: Are recovery times increasing over time?
    (Indicates LSM depth increasing, or checkpoint size growth)
  ```

### Requirement: Query Behavior During Index Recovery

The system SHALL define explicit SLAs for query performance during recovery procedures to prevent cascading failures in S2-heavy workloads.

- **WHEN** index recovery is in progress (WAL replay, LSM rebuild, or full rebuild)
- **THEN** the system SHALL ensure:
  ```
  QUERY BEHAVIOR DURING INDEX RECOVERY
  ═════════════════════════════════════

  RECOVERY PROCEDURE SLAs AND QUERY IMPACT:
  ────────────────────────────────────────

  Recovery Type 1: WAL Replay (< 1 second)
  - Duration: < 1 second (negligible for most deployments)
  - Query availability: AVAILABLE (replicas serve during replay)
  - Expected impact: None (WAL replay does not block queries)

  Recovery Type 2: LSM Replay (< 30 seconds)
  - Duration: < 30 seconds
  - Query availability: AVAILABLE (can serve during LSM rebuild, with warnings)
  - Expected latency impact: +10-20% (LSM table scans slower than in-memory index)
  - Guidance: Accept increased latency during replay
  - S2-specific impact: Radius and polygon queries slower but functional
  - Action: No automatic query rejection; clients should retry if timeout

  Recovery Type 3: Full Rebuild (2-5 minutes for 128GB)
  - Duration: 2-5 minutes (critical for S2-heavy workloads)
  - Query availability: AVAILABLE, but DEGRADED
  - Degradation strategy:
    (a) Queries are ACCEPTED (do not reject)
    (b) S2 covering queries: May take 5-10x normal time
       - Simple coverings: 50μs → 250-500μs (still < 1ms, acceptable)
       - Complex coverings: 5ms → 25-50ms (exceeds 50ms target, degraded)
    (c) Timeout behavior: Increase timeout to 10s (from normal 1-5s)
    (d) Queue behavior: Accept queries but queue them if backlog > 100
  - Expected impact: Cascading timeouts if workload is 100% S2-queries (high complexity)
  - Mitigation strategies:
    1. Preferentially process non-S2 queries during rebuild
    2. For S2 queries: Route to non-degraded replicas if available (VSR load balancing)
    3. Circuit breaker: Disable S2 queries during rebuild if p99 > 100ms consistently
  - Guidance: This is EXPECTED degradation; clients should implement retry logic

  ALERT RULES FOR RECOVERY:
  ────────────────────────
  - Alert: If recovery duration > 2x normal → "Recovery taking longer than expected"
  - Alert: If query_timeout_total > 1000/sec during rebuild → "Query overload during recovery"
  - Alert: If query latency p99 > 50ms during rebuild → "Query degradation during recovery"
  - Action: Do NOT fail queries automatically; accept degradation as expected

  OPERATIONAL GUIDANCE:
  ───────────────────
  1. Schedule full rebuilds during maintenance windows (or low-traffic periods)
  2. For 24/7 systems: Use VSR load balancing to shift S2 workload to healthy replicas
  3. If cascading timeouts occur: Reduce concurrent S2 query rate at client layer
  4. Recovery is complete when: archerdb_index_rebuild_percent = 100 AND validation passes
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
  - SEV1 (cluster down): Immediate investigation required
  - SEV2 (degraded): Address within 15 minutes
  - SEV3 (warning): Address during next work session
  ```

### Requirement: Zig Standard Library Compatibility

The system SHALL explicitly document Zig stdlib requirements and fallback strategies for known gaps.

#### Scenario: Required Zig stdlib features with fallback strategies

- **WHEN** implementing ArcherDB in Zig
- **THEN** the following stdlib features and their fallbacks SHALL be used:

  | Feature | Required | Zig 0.13 Status | Fallback Strategy | F0.1 Validation |
  |---------|----------|-----------|-------------------|-----------------|
  | **Bit Manipulation** (`@bitCast`, `@byteSwap`) | ✅ YES | Native | Guaranteed; no fallback needed | Comptime assert exists |
  | **Intrinsics** (`@popCount`, `@clz`, `@ctz`) | ✅ YES | Native | Guaranteed; no fallback needed | Comptime assert exists |
  | **Memory Operations** (`@memcpy`) | ✅ YES | std.mem | Guaranteed; no fallback needed | Comptime assert exists |
  | **Math Functions** (sin, cos, atan2) | ⚠️ CRITICAL | std.math exists | **Chebyshev/CORDIC pure Zig** (Option A spike in F0.4) | Test on x86/ARM/macOS |
  | **Hashing** (wyhash) | ⚠️ NEEDED | Not in std | **Implement wyhash in pure Zig (1-2 days)** OR use std.hash.SipHash | F0.2 validation spike |
  | **Atomics** (`@atomicLoad`) | ✅ YES | Native | Guaranteed; no fallback needed | Comptime assert exists |
  | **Comptime computation** | ✅ YES | Native | Guaranteed; no fallback needed | Comptime assert exists |
  | **Error Handling** (`!Type`, `catch`) | ✅ YES | Native | Guaranteed; no fallback needed | Comptime assert exists |
  | **C FFI** (`@cImport`) | ✅ YES | Native | Guaranteed; no fallback needed | Test Google S2 C++ bindings |

- **AND** for CRITICAL/NEEDED features:
  1. Create F0.1 spike task to validate feature availability
  2. Document workaround strategy if unavailable
  3. Add `comptime` assertion to code to catch issues at compile-time

#### Scenario: Known Zig ecosystem gaps - mitigation strategies

- **WHEN** encountering Zig stdlib or ecosystem limitations
- **THEN** the following mitigation strategies SHALL be applied:

  | Gap | Severity | Recommended Approach | Effort | Backlog? |
  |----|----------|-------------------|--------|----------|
  | **No wyhash in std** | Medium | Implement wyhash in pure Zig (copy Google's reference) | 1-2 days | NO - do in F0.2 |
  | **Math.sin/cos determinism** | CRITICAL | S2 Option A spike validates; fallback to Option B if unclear | 2 weeks spike | NO - do in F0.4 |
  | **Limited crypto (AES-NI)** | Low | Defer full-disk encryption to v2; use software AES for v1 | Defer | YES - backlog v2 |
  | **No standard UUID type** | Low | Use u128 (already in GeoEvent struct) | N/A | NO - already using |

- **AND** all workaround implementations SHALL be:
  - Stored in separate `src/compat/` directory
  - Documented with `// ZIG_COMPAT_WORKAROUND:` comments
  - Logged at startup with version and rationale
  - Included in deployment checklist to ensure consistency across replicas

#### Scenario: Zig version stability and CI/CD validation

- **WHEN** deploying ArcherDB to production
- **THEN** the following version constraints SHALL be enforced:
  - **Minimum Zig version**: 0.13 (first stable with production guarantees)
  - **Maximum Zig version**: Latest 0.13.x (minor updates only)
  - **Forbidden versions**: 0.11, 0.12 (breaking changes, not production-ready)
  - **CI/CD requirement**: All tests pass on pinned Zig 0.13.x before merge
  - **Docker constraint**: Dockerfile specifies exact Zig version (e.g., `FROM zig:0.13.0`)

- **AND** if Zig 0.13 reaches end-of-life:
  1. Evaluate upgrade path to next stable version
  2. Run full regression test suite
  3. Validate no breaking changes to math, atomics, or C FFI
  4. Update deployment documentation
  5. Plan rolling upgrade for existing clusters

### Requirement: F4 VOPR Simulator and Cluster Testing (Weeks 27-32)

The system SHALL validate distributed correctness using VOPR (Viewstamped Replication Protocol) fault-injection simulator adapted for GeoEvent operations.

- **WHEN** validating cluster behavior (F4 phase, Week 27+)
- **THEN** the system SHALL implement these testing procedures:
  ```
  F4 VOPR ADAPTATION & CLUSTER TESTING SPECIFICATION
  ═══════════════════════════════════════════════════

  F4.1 VOPR ADAPTATION (Weeks 27-28):
  ──────────────────────────────────

  Objective: Adapt ArcherDB's VOPR to GeoEvent operations

  DELIVERABLES:
  1. GeoEvent operation generators:
     - Random locations: Uniform distribution across globe
     - Clustered locations: 90% within 1000km, 10% random (real-world pattern)
     - Adversarial: Coordinates designed to stress S2 calculations
     - Polygon queries: Simple (3 vertices), complex (100+ vertices), edge cases

  2. VOPR invariants for GeoEvents:
     - Linearizability: All replicas eventually agree on operation order
     - Idempotency: Duplicate writes produce same result (LWW - last-write-wins)
     - S2 Determinism: All replicas produce identical S2 cell IDs (bit-exact)
     - TTL Correctness: Expired events removed correctly across replicas
     - Index Consistency: All replicas have identical index state post-sync

  3. Fault injection scenarios:
     - Primary crash: Stop primary replica, verify quorum continues
     - Secondary crash: Stop secondary, quorum continues, data preserved
     - Network partition: Isolate subset of replicas, verify safe behavior
     - Message loss: Drop N% of messages, verify eventual consistency
     - Corruption: Inject bit flips, verify corruption detected

  ACCEPTANCE CRITERIA (Week 28):
  - VOPR runs 1M+ geospatial operations without invariant violations
  - S2 determinism invariant passes (all replicas have identical cell IDs)
  - Recovery after replica crash completes in < 30 seconds

  F4.2 CLUSTER TESTING (Weeks 28-30):
  ────────────────────────────────────

  Objective: Test multi-replica behavior under realistic conditions

  TEST MATRIX:
  ────────────

  Scenario 1: 3-Replica Cluster (Standard)
  ─────────────────────────────────────────
  Setup: 1 primary, 2 secondaries (can tolerate 1 failure)
  Test workload: 1M insert_events/sec sustained for 5 minutes
  Expected behavior:
    - Primary accepts all writes
    - Secondaries sync within <100ms
    - Replication lag: < 1000 operations
    - Failover time (if primary crashes): < 3 seconds

  Pass criteria:
    - All 3 replicas have identical state at end
    - Zero data loss
    - View change completes < 3s
    - Replication lag metric < 1000 ops

  Scenario 2: 5-Replica Cluster (High Availability)
  ──────────────────────────────────────────────────
  Setup: 1 primary, 4 secondaries (can tolerate 2 failures)
  Test workload: 500K ops/sec for 10 minutes (slower due to higher replication cost)
  Expected behavior:
    - Tolerate failure of 2 replicas simultaneously
    - View change still completes < 3 seconds
    - Throughput degradation ≤ 20%

  Pass criteria:
    - All 5 replicas have identical state
    - Can survive simultaneous 2-replica crash
    - Failover completes < 3s

  Scenario 3: 6-Replica Cluster (Maximum)
  ────────────────────────────────────────
  Setup: 1 primary, 5 secondaries (can tolerate 2 failures, Flexible Paxos limit)
  Test workload: 400K ops/sec for 5 minutes
  Expected behavior:
    - Maximum supported configuration works
    - Throughput degradation ≤ 30% vs 3-replica baseline

  Pass criteria:
    - All 6 replicas converge
    - Failover works
    - No performance collapse

  F4.2.4 View Change Timing (< 3 second target):
  ────────────────────────────────────────────────
  Procedure:
    1. Run cluster at steady state (500K ops/sec)
    2. Crash primary replica abruptly (kill -9)
    3. Measure time from crash to first write accepted on new primary
    4. Target: < 3 seconds
    5. Repeat 10 times, report p50/p99

  Acceptance: p99 < 3 seconds, p50 < 1 second

  F4.2.5 Network Partition Testing:
  ──────────────────────────────────
  Procedure:
    1. 3-replica cluster at steady state
    2. Partition: Isolate primary + 1 secondary from 1 secondary
    3. Behavior: Minority partition (1 replica) should NOT accept writes (safe)
    4. Majority partition (2 replicas) should elect new primary and continue
    5. Heal partition: All replicas rejoin and resync

  Pass criteria:
    - Minority partition rejects writes (quorum check)
    - Majority partition continues accepting writes
    - Upon heal, minority resync and reach consensus
    - Zero data loss after heal

  F4.3 SAFETY VERIFICATION (Week 31):
  ────────────────────────────────────

  Objective: Formal validation of linearizability and consistency

  F4.3.1 Linearizability Proof (1M+ operations):
  Run VOPR simulator for 1M operations with multiple threads/clients.
  Verify: All operations execute in total order consistent with client observation.
  Tool: ArcherDB's existing history validation logic, adapted for GeoEvents.

  F4.3.2 Mega-Scale Test (10M+ operations):
  Extended VOPR run with 10M operations.
  Verify: No memory leaks, no invariant violations, no state divergence.
  Metrics:
    - Operations/second sustained: Should be consistent
    - Memory usage growth: Should be sub-linear (compaction working)
    - Invariant violations: Must be exactly 0

  F4.3.3 Index Consistency Verification:
  After each major scenario, verify:
    - All replicas have identical index hash (deep equality check)
    - Entity counts match across replicas
    - Latest timestamp for each entity matches

  Acceptance (Week 31):
  - 10M operation VOPR run completes without violation
  - Index consistency verified post-run
  - All 3 failover scenarios pass

  EXIT CRITERIA (Week 32):
  - VOPR passes 10M+ operations with 0 invariant violations
  - View change: p99 < 3 seconds
  - All replicas converge post-partition
  - Index consistency verified
  - Ready for F5 Performance Validation
  ```

### Requirement: F5 Performance Validation Benchmarks (Weeks 33-38)

The system SHALL validate that all performance targets are met under production conditions.

- **WHEN** conducting performance validation (F5 phase, Week 33+)
- **THEN** the system SHALL execute these benchmarks:
  ```
  F5 PERFORMANCE VALIDATION SPECIFICATION
  ═══════════════════════════════════════

  F5.1.1 Write Throughput Validation (Target: 1M events/sec per node)
  ────────────────────────────────────────────────────────────────
  Procedure:
    1. Single-node cluster, 3x replication within same node
    2. Sustained write load: Insert_events in batches of 128
    3. Target: Achieve 1M operations/second sustained for 5 minutes
    4. Measure: Actual ops/sec, p99 latency, memory growth

  Pass criteria:
    - Sustained throughput ≥ 900K ops/sec (90% of target acceptable)
    - p99 latency ≤ 10ms
    - Memory growth ≤ 100MB over 5 minutes

  F5.1.2 UUID Lookup Latency (Target: < 500μs p99)
  ────────────────────────────────────────────────
  Procedure:
    1. Pre-populate 1B entities in index
    2. Random UUID queries, 100 concurrent clients
    3. Target: < 500μs p99 latency
    4. Measure: p50, p99, p99.9 latencies

  Pass criteria:
    - p99 < 500μs
    - p99.9 < 1000μs
    - No query ever exceeds 5ms

  F5.1.3 Radius Query Performance (Target: < 50ms p99)
  ─────────────────────────────────────────────────────
  Procedure:
    1. 1B entities, uniform distribution
    2. Radius queries: 1000 random locations, 100km radius
    3. Measure: p50, p99, p99.9 latencies

  Pass criteria:
    - p99 < 50ms
    - p99.9 < 100ms

  F5.1.4 Polygon Query Performance (Target: < 100ms p99)
  ──────────────────────────────────────────────────────
  Procedure:
    1. 1B entities
    2. Polygon queries: US state boundaries (50-100 vertices)
    3. Measure: p50, p99, p99.9 latencies

  Pass criteria:
    - p99 < 100ms
    - p99.9 < 200ms

  F5.1.5 Memory Usage Validation
  ──────────────────────────────
  Scale validation: Test at 1M, 10M, 100M, 1B entities
  Expected memory scaling:
    - 1M: ~300MB (index + LSM)
    - 10M: ~3GB
    - 100M: ~30GB
    - 1B: ~300GB (includes 91.5GB index + LSM tiers)

  Pass criteria: Memory scaling is linear (slope consistent)

  F5.1.6 Replication Lag (Target: < 10ms same region)
  ────────────────────────────────────────────────────
  Procedure:
    1. 3-node cluster, same datacenter
    2. Write at 1M ops/sec to primary
    3. Measure: Time from write accepted to replicated on secondaries
    4. Target: < 10ms p99

  Pass criteria:
    - p99 lag < 10ms
    - Lag stable (not growing over time)
  ```

### Requirement: F5 Multi-Batch Retry Semantics (Weeks 37-38)

The system SHALL define explicit retry logic for multi-batch failures in client SDKs.

- **WHEN** client receives partial_result=true response
- **THEN** SDKs SHALL implement:
  ```
  MULTI-BATCH RETRY SEMANTICS
  ════════════════════════════

  RESPONSE FORMAT REMINDER:
  ────────────────────────
  Multi-batch response includes:
    - partial_result: bool (true if any batch failed)
    - failed_batch_index: u8 (index F of first failed batch, 0-255)
    - num_batches: u16 (total batches attempted)

  RETRY LOGIC (Idempotent Operations - ArcherDB v1):
  ──────────────────────────────────────────────────
  All ArcherDB v1 write operations are idempotent (upsert, query, delete).
  Exception: insert_events is NOT idempotent (avoid in client code).

  IF partial_result = true AND failed_batch_index = F:
    1. Retry logic: Send batches [F..N] (failed + skipped batches only)
    2. Skip sending batches [0..F-1] (already succeeded on server)
    3. Max retries: 3 (exponential backoff: 10ms, 100ms, 1s)
    4. Verify: Use LWW (last-write-wins) timestamp to detect duplicates
       (Server deduplicates using entity_id + timestamp)

  CODE EXAMPLE (Pseudo-code):
  ──────────────────────────
  fn send_multi_batch(batches: Vec<Batch>) -> Result<Response> {
    let mut all_batches = batches.clone();
    let mut retry_count = 0;

    loop {
      let response = client.send_request(all_batches.clone());

      if response.partial_result {
        // Batch F failed, retry only [F..N]
        let failed_idx = response.failed_batch_index as usize;
        all_batches = all_batches[failed_idx..].to_vec();

        retry_count += 1;
        if retry_count > 3 {
          return Err("Max retries exceeded");
        }

        let backoff_ms = 10 * (10 ^ retry_count);
        sleep(Duration::from_millis(backoff_ms));
        continue;
      }

      return Ok(response);
    }
  }

  FAILURE SCENARIOS:
  ──────────────────

  Scenario A: Validation Failure (One batch has invalid data)
  Example: Batch 2 has invalid_coordinates error
  Behavior: partial_result=true, failed_batch_index=2
  SDK action: Retry only batches [2..N]
  Important: Batch 2 will fail again unless client fixes data
  Recommendation: Log error and skip batch 2, or return error to user

  Scenario B: Resource Exhaustion (Message too large)
  Example: All N batches together exceed message_size_max
  Behavior: partial_result=true, failed_batch_index=0 (none succeeded)
  SDK action: Paginate batches into smaller requests, retry each separately
  Important: Must split original multi-batch into multiple smaller requests

  Scenario C: Replication Lag (Write accepted but not fully replicated)
  Example: Primary accepted, but replication incomplete
  Behavior: partial_result=false (success), but replication_lag_ms = 500
  SDK action: No retry needed, operation succeeded
  Note: Client can wait via polling /metrics if strong consistency required

  MONITORING & OBSERVABILITY:
  ──────────────────────────
  SDK MUST track:
    - retry_count per request
    - retry_latency_ms (time spent retrying)
    - validation_failure_count (how often batches failed validation)
    - resource_exhaustion_count (how often message too large)

  Alert thresholds:
    - validation_failure_rate > 1% → Investigate invalid data source
    - resource_exhaustion_rate > 0.1% → Increase message_size_max or paginate
    - retry_latency_p99 > 1000ms → Investigate replication health
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


## Implementation Status

*This specification covers implementation guidance, not specific requirements.*
