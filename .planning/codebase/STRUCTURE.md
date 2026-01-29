# Codebase Structure

**Analysis Date:** 2026-01-29

## Directory Layout

```
archerdb/
├── src/                        # Primary source code
│   ├── archerdb/              # ArcherDB application layer
│   ├── clients/               # Client SDKs (C, Go, Java, Node, Python)
│   ├── cdc/                   # Change Data Capture (AMQP integration)
│   ├── devhub/                # Developer tooling
│   ├── docs_website/          # Documentation website build
│   ├── index/                 # RAM index checkpoint utilities
│   ├── io/                    # Platform I/O abstraction
│   ├── lsm/                   # LSM-tree storage engine
│   ├── repl/                  # REPL shell utility
│   ├── replication/           # Replication protocol helpers
│   ├── s2/                    # S2 geometry library (spatial indexing)
│   ├── scripts/               # Build/automation scripts
│   ├── stdx/                  # Standard library extensions
│   ├── testing/               # Testing utilities (cluster sim, fuzz)
│   ├── trace/                 # Distributed tracing infrastructure
│   ├── vsr/                   # Viewstamped Replication consensus
│   ├── *.zig                  # Core modules (state machine, geo_event, etc.)
│
├── build.zig                  # Build configuration (Zig build system)
├── build.zig.zon              # Build dependencies
├── docs/                      # User documentation
├── .planning/codebase/        # GSD planning documents (generated)
├── scripts/                   # Utility scripts (test-constrained.sh, etc.)
├── tools/                     # External tools
├── zig/                       # Zig compiler download script
└── [build outputs]
    ├── zig-out/              # Build artifacts
    └── .zig-cache/           # Compiler cache
```

## Directory Purposes

**`src/archerdb/`:**
- Purpose: Application-layer code (CLI, metrics, observability, data management)
- Contains: CLI command parsing, server startup, metrics collection, backup/restore, data export/validation, GDPR compliance features
- Key files: `cli.zig` (command parsing), `main.zig` (server entry), `metrics.zig`, `cluster_metrics.zig`, `inspect.zig`, `data_export.zig`, `backup_coordinator.zig`, `compliance_audit.zig`, `dpia.zig`

**`src/vsr/`:**
- Purpose: Viewstamped Replication consensus protocol and replica coordination
- Contains: Replica state machine, prepare/commit phases, view changes, client protocol, message headers, timing/timeout handling, membership management
- Key files: `replica.zig` (core replica), `client.zig` (client protocol), `flexible_paxos.zig` (voting), `grid.zig` (storage blocks), `journal.zig` (write-ahead log), `superblock.zig` (metadata), `message_header.zig` (wire format), `clock.zig` (clock drift detection)

**`src/lsm/`:**
- Purpose: LSM-tree storage engine with compaction and manifest management
- Contains: Tree structure, table management, manifest log, compaction strategies (tiered, adaptive), compression (LZ4), scanning, K-way merge
- Key files: `tree.zig` (LSM tree), `forest.zig` (collection of trees), `groove.zig` (per-tree state), `manifest.zig` (metadata), `compaction.zig` (merging logic), `compression.zig` (LZ4 wrapper), `table.zig` (disk/memory tables)

**`src/s2/`:**
- Purpose: Google S2 geometry library for spatial indexing
- Contains: S2 cell hierarchy, covering algorithms, polygon operations, Hilbert curve ordering
- Key files: Cell operations, polygon/rectangle intersection tests (vendored)

**`src/io/`:**
- Purpose: Platform-independent async I/O abstraction
- Contains: Linux io_uring implementation, macOS kevent implementation, file operations, network operations
- Key files: `linux.zig` (io_uring), `darwin.zig` (kevent), `common.zig` (shared interfaces), `test.zig` (testing backend)

**`src/stdx/`:**
- Purpose: Standard library extensions and utilities
- Contains: Ring buffers, hash tables, PRNG, bit operations, flags parsing, memory utilities
- Key files: `stdx.zig` (root exports), `testing/` (testing helpers), `vendored/` (vendored dependencies like LZ4)

**`src/testing/`:**
- Purpose: Testing infrastructure for unit, integration, and deterministic simulation testing
- Contains: Cluster simulator, VOPR (Viewstamped Operation Prover) test harness, fuzzing framework
- Key files: `cluster.zig` (in-process cluster simulation), `vortex/` (full system test framework)

**`src/clients/`:**
- Purpose: Multi-language SDKs for interacting with ArcherDB
- Contains: C client with JNI/FFI bindings, Go, Java, Node.js, Python clients
- Key files: `c/arch_client.zig` (Zig client implementation), `c/arch_client.h` (generated C header), per-language bindings

**`src/cdc/`:**
- Purpose: Change Data Capture via AMQP message broker
- Contains: Event streaming for replication and ETL
- Key files: `runner.zig` (AMQP event dispatch)

**`src/trace/`:**
- Purpose: Distributed tracing and profiling infrastructure
- Contains: Tracy integration for real-time profiling, event logging for debugging
- Key files: `trace.zig` (Tracy wrapper), `event.zig` (trace event definitions)

**`src/replication/`:**
- Purpose: Multi-region replication helpers
- Contains: Async replication coordination between regions
- Key files: Replication protocol utilities

## Key File Locations

**Entry Points:**
- `src/archerdb/main.zig`: Server binary entry point (pub fn main)
- `src/archerdb/cli.zig`: CLI command parsing and dispatch (format, start, inspect, aof subcommands)
- `src/vopr.zig`: Deterministic simulation test harness

**Configuration:**
- `build.zig`: Build system configuration (compiler flags, optimization, test/fuzz/VOPR targets)
- `build.zig.zon`: Build dependencies (LZ4 library)
- `src/constants.zig`: Compile-time configuration (cluster size, buffer counts, LSM levels, grid block sizes)

**Core Logic:**
- `src/geo_state_machine.zig`: Geospatial state machine (insert, query, delete, TTL operations)
- `src/archerdb.zig`: ArcherDB type definitions (GeoEvent, operation types, request/response types)
- `src/geo_event.zig`: GeoEvent structure and validation
- `src/ttl.zig`: TTL expiration and cleanup logic
- `src/s2_index.zig`: S2 spatial indexing integration
- `src/ram_index.zig`: In-memory entity index for latest positions
- `src/sharding.zig`: Sharding and rebalancing logic

**Storage:**
- `src/vsr/grid.zig`: Block grid storage with checksums
- `src/vsr/journal.zig`: Write-ahead log sequencing
- `src/vsr/superblock.zig`: Metadata persistence and versioning
- `src/lsm/forest.zig`: Multi-tree LSM forest
- `src/lsm/manifest.zig`: Table manifest (metadata tracking)
- `src/lsm/manifest_log.zig`: Durable manifest log

**Consensus:**
- `src/vsr/replica.zig`: Core replica consensus implementation (580KB - largest file)
- `src/vsr/client.zig`: Client request/reply handling
- `src/vsr/flexible_paxos.zig`: Flexible Paxos quorum voting
- `src/vsr/membership.zig`: Cluster membership configuration

**Messaging:**
- `src/message_bus.zig`: Message routing and protocol handling
- `src/message_pool.zig`: Message object pool allocation
- `src/message_buffer.zig`: Message framing and buffering

**Testing:**
- `src/unit_tests.zig`: Unit test registry
- `src/integration_tests.zig`: Integration test registry
- `src/testing/cluster.zig`: In-process cluster simulator
- `src/state_machine_fuzz.zig`: State machine fuzzing
- `src/lsm/tree_fuzz.zig`: LSM tree fuzzing

## Naming Conventions

**Files:**
- Core modules: `module_name.zig` (e.g., `geo_state_machine.zig`, `ram_index.zig`)
- Utilities: `utility_name.zig` (e.g., `message_pool.zig`, `time.zig`)
- Tests: `*_test.zig` or `*_fuzz.zig` (e.g., `replica_test.zig`, `tree_fuzz.zig`)
- Benchmarks: `*_benchmark.zig` (e.g., `k_way_merge_benchmark.zig`)

**Directories:**
- Subsystems: lowercase with underscores (e.g., `lsm/`, `vsr/`, `stdx/`)
- Feature areas: feature-name (e.g., `index/`, `cdc/`, `clients/`)

**Functions & Types:**
- PascalCase for types: `StateMachine`, `ReplicaType`, `GridType`
- camelCase for functions: `pub fn main()`, `fn initialize()`
- UPPER_CASE for constants: `grid_block_size`, `constants.replicas_max`
- test_ prefix for test functions: `test "my test name"`

## Where to Add New Code

**New Geospatial Feature (e.g., new query type):**
- Primary code: `src/geo_state_machine.zig` (add operation variant, execute logic)
- Type definitions: `src/archerdb.zig` (add request/response structs)
- Validation: `src/geo_event.zig` or new module in `src/`
- Tests: `src/integration_tests.zig` or new `src/feature_test.zig`
- Example: `pub const QueryMyFeatureFilter = extern struct { ... }` in `archerdb.zig`, then `QueryMyFeature(filter)` in state machine

**New Storage/Index Feature:**
- If LSM-related: `src/lsm/` directory (new file or extend `tree.zig`/`forest.zig`)
- If persistence-related: `src/vsr/` (extend `grid.zig`, `superblock.zig`, or `journal.zig`)
- If indexing: `src/` (new module at top level, import in state machine)

**New Client SDK:**
- Implementation: `src/clients/[language]/` directory
- JNI/FFI wrapper: `src/clients/c/arch_client.zig` (generates header)
- Bindings generation: `build.zig` (add client build step)
- Tests: `src/clients/[language]/tests/` with language-specific test runner

**New Admin Command:**
- CLI implementation: `src/archerdb/cli.zig` (add subcommand variant)
- Main logic: New module in `src/archerdb/` (e.g., `src/archerdb/my_command.zig`)
- Integration with main: `src/archerdb/main.zig` (dispatch in CLI handler)

**Utilities & Helpers:**
- Shared across modules: `src/stdx/` (e.g., `src/stdx/my_util.zig`)
- Single-module helpers: Alongside consumer module
- Test helpers: `src/testing/` directory

## Special Directories

**`.planning/codebase/`:**
- Purpose: GSD (Generic Software Development) planning documents generated by Claude
- Generated: Yes (by `/gsd:map-codebase` command)
- Committed: Yes - stored in git for reference by future planner/executor commands
- Contents: ARCHITECTURE.md, STRUCTURE.md, CONVENTIONS.md, TESTING.md, CONCERNS.md, STACK.md, INTEGRATIONS.md

**`zig-out/`:**
- Purpose: Build output directory
- Generated: Yes (by `./zig/zig build`)
- Committed: No (in `.gitignore`)
- Contains: `bin/archerdb`, `bin/archerdb-sample`, libraries, object files

**`.zig-cache/`:**
- Purpose: Zig compiler cache
- Generated: Yes (automatically by compiler)
- Committed: No (in `.gitignore`)
- Contains: Incremental compilation artifacts

**`docs/`:**
- Purpose: User-facing documentation (operations, API reference, architecture overview)
- Generated: No (hand-written)
- Committed: Yes
- Key files: `architecture.md`, `getting-started.md`, `operations-runbook.md`, `api-reference.md`

**`scripts/`:**
- Purpose: Development and deployment utilities
- Generated: No (hand-written)
- Committed: Yes
- Key scripts: `test-constrained.sh` (constrained resource testing), `add-license-headers.sh` (license compliance)

**`tools/`:**
- Purpose: External or third-party tools
- Generated: No (checked in or referenced)
- Committed: Partially (symlinks or minimal references)

---

*Structure analysis: 2026-01-29*
