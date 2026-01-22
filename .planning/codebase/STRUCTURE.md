# Codebase Structure

**Analysis Date:** 2026-01-22

## Directory Layout

```
/home/g/archerdb/
├── src/                          # Core Zig source code
│   ├── vsr/                      # VSR consensus protocol
│   ├── lsm/                      # LSM-tree storage engine
│   ├── archerdb/                 # ArcherDB-specific modules
│   ├── clients/                  # Multi-language client SDKs
│   ├── cdc/                      # Change Data Capture (AMQP)
│   ├── io/                       # Platform I/O implementations
│   ├── state_machine/            # State machine utilities
│   ├── testing/                  # Testing infrastructure
│   ├── stdx/                     # Standard library extensions
│   ├── trace/                    # Tracing/observability
│   ├── scripts/                  # Build and release scripts
│   ├── docs_website/             # Documentation generator
│   ├── repl/                     # REPL implementation
│   ├── s2/                       # S2 geometry library
│   └── index/                    # Index checkpoint logic
├── build.zig                     # Zig build system
├── zig/                          # Bundled Zig compiler
├── scripts/                      # Shell scripts (license, hooks)
├── docs/                         # User documentation
├── deploy/                       # Deployment configs
├── .planning/                    # GSD planning artifacts
└── .claude/                      # Claude agent hooks/config
```

## Directory Purposes

**src/vsr/**
- Purpose: Viewstamped Replication consensus protocol
- Contains: Replica, client, journal, grid, superblock, sync, membership
- Key files: `replica.zig`, `client.zig`, `journal.zig`, `grid.zig`, `superblock.zig`

**src/lsm/**
- Purpose: LSM-tree storage engine implementation
- Contains: Forest, tree, groove, compaction, manifest, cache, scan logic
- Key files: `forest.zig`, `tree.zig`, `groove.zig`, `compaction.zig`, `manifest.zig`

**src/archerdb/**
- Purpose: ArcherDB-specific features (backup, metrics, CLI, TLS)
- Contains: Main entry point, CLI, metrics, backup/restore, data export, compliance modules
- Key files: `main.zig`, `cli.zig`, `metrics.zig`, `backup_coordinator.zig`

**src/clients/**
- Purpose: Multi-language client SDKs
- Contains: C (foundation), Go, Java, Node.js, Python bindings
- Key files: `c/arch_client.zig`, `go/go_bindings.zig`, `java/java_bindings.zig`, `node/node_bindings.zig`, `python/python_bindings.zig`

**src/cdc/**
- Purpose: Change Data Capture via AMQP protocol
- Contains: AMQP protocol implementation, CDC runner
- Key files: `runner.zig`, `amqp.zig`, `amqp/protocol.zig`

**src/io/**
- Purpose: Platform-specific async I/O
- Contains: Linux (io_uring), Darwin (kqueue), Windows implementations
- Key files: `io/linux.zig`, `io/darwin.zig`, `io/windows.zig`

**src/testing/**
- Purpose: Testing infrastructure and simulation
- Contains: Cluster simulation, fuzz testing, vortex workload generator
- Key files: `cluster.zig`, `fuzz.zig`, `vortex/supervisor.zig`

**src/stdx/**
- Purpose: Standard library extensions
- Contains: Data structures (RingBuffer, BitSet, BoundedArray), utilities
- Key files: `stdx.zig`, `ring_buffer.zig`, `bit_set.zig`

**scripts/**
- Purpose: Build and maintenance scripts
- Contains: License header management, pre-commit hooks
- Key files: `add-license-headers.sh`, `.claude/hooks/pre-commit-check.sh`

**docs/**
- Purpose: User-facing documentation
- Contains: Getting started, operations runbook, disaster recovery, API reference
- Key files: `getting-started.md`, `operations-runbook.md`, `disaster-recovery.md`

## Key File Locations

**Entry Points:**
- `src/archerdb/main.zig`: Server binary entry point (replica)
- `src/vopr.zig`: Deterministic simulation/testing entry point
- `src/shell.zig`: Interactive shell/REPL
- `src/clients/c/arch_client.zig`: C client SDK entry point

**Configuration:**
- `build.zig`: Zig build system configuration
- `src/config.zig`: Runtime configuration structs
- `src/constants.zig`: Compile-time constants (cluster limits, checkpoint intervals)
- `.editorconfig`: Editor formatting rules

**Core Logic:**
- `src/archerdb.zig`: ArcherDB operation types and enums
- `src/geo_state_machine.zig`: Geospatial state machine implementation (5000+ lines)
- `src/geo_event.zig`: GeoEvent struct definition
- `src/ram_index.zig`: In-memory entity index
- `src/s2_index.zig`: S2 geospatial index
- `src/ttl.zig`: TTL cleanup and manual operations
- `src/sharding.zig`: Consistent hashing for sharding
- `src/replication.zig`: Multi-region async replication

**Testing:**
- `src/unit_tests.zig`: Unit test runner
- `src/integration_tests.zig`: Integration test suite
- `src/*_fuzz.zig`: Fuzz testing modules (storage_fuzz, message_bus_fuzz, etc.)
- `src/state_machine_fuzz.zig`: State machine fuzzer

**Storage:**
- `src/lsm/forest.zig`: Multi-tree LSM forest
- `src/lsm/tree.zig`: Single LSM tree
- `src/vsr/grid.zig`: Block storage abstraction
- `src/storage.zig`: Storage interface
- `src/aof.zig`: Append-only file (WAL)

**Networking:**
- `src/message_bus.zig`: Message routing and transport
- `src/message_pool.zig`: Message memory pooling
- `src/message_buffer.zig`: Message buffering
- `src/vsr/message_header.zig`: VSR message header format

## Naming Conventions

**Files:**
- `snake_case.zig`: Standard module naming
- `*_fuzz.zig`: Fuzz test modules
- `*_test.zig`: Test-only modules
- `build*.zig`: Build system files

**Directories:**
- `snake_case/`: Standard directory naming
- Subdirectories match conceptual grouping (lsm, vsr, clients)

**Zig Types:**
- `PascalCase`: Types, structs, enums (e.g., `GeoEvent`, `Operation`, `Replica`)
- `Type` suffix: Generic type functions (e.g., `ReplicaType`, `ForestType`, `ClientType`)
- `snake_case`: Functions, variables, constants (e.g., `computeShardKey`, `commit`, `prepare`)
- `SCREAMING_SNAKE_CASE`: Global constants (e.g., `MAX_SHARDS`, `clients_max`)

**Operations:**
- VSR reserved operations: `<vsr_operations_reserved` (0-127)
- ArcherDB operations: `≥vsr_operations_reserved` (128+)
- Operation enum values like `insert_events`, `query_radius`, `cleanup_expired`

## Where to Add New Code

**New Geospatial Operation:**
- Primary code: `src/archerdb.zig` (add to Operation enum)
- Implementation: `src/geo_state_machine.zig` (commit/prefetch/prepare handlers)
- Tests: `src/state_machine_tests.zig` or `src/integration_tests.zig`
- Client SDK: Update `src/clients/*/` for each language

**New LSM Index:**
- Schema definition: `src/lsm/schema.zig`
- Tree integration: `src/geo_state_machine.zig` (tree_ids, Forest groove config)
- Tests: `src/lsm/tree_fuzz.zig` or new test file

**New Admin/Metrics Feature:**
- Implementation: `src/archerdb/` (new module or existing like `metrics.zig`)
- CLI integration: `src/archerdb/cli.zig`
- Tests: `src/archerdb/` or `src/unit_tests.zig`

**New Client SDK:**
- FFI bindings: `src/clients/{language}/{language}_bindings.zig`
- Native code: `src/clients/{language}/` (language-specific directory)
- Build integration: `build.zig` (add compilation target)
- Samples: `src/clients/{language}/samples/`

**New VSR Protocol Feature:**
- Core logic: `src/vsr/replica.zig` or related VSR module
- Message handling: `src/vsr/message_header.zig`, `src/message_bus.zig`
- Tests: `src/vsr/replica_test.zig` or `src/vopr.zig` (simulation)

**New Storage Feature:**
- LSM logic: `src/lsm/` (tree, compaction, manifest)
- Grid/block management: `src/vsr/grid.zig`
- Tests: `src/lsm/*_fuzz.zig` or `src/storage_fuzz.zig`

**Utilities:**
- Shared helpers: `src/stdx/` (if general-purpose) or inline in relevant module
- Testing utilities: `src/testing/`

## Special Directories

**zig-cache/**
- Purpose: Zig build cache
- Generated: Yes
- Committed: No

**zig-out/**
- Purpose: Build output (binaries, libraries)
- Generated: Yes
- Committed: No

**.planning/**
- Purpose: GSD (Get Stuff Done) planning artifacts
- Generated: Yes (by Claude agents)
- Committed: Yes
- Contents: Codebase analysis, phase plans, summaries

**.claude/**
- Purpose: Claude agent configuration
- Generated: No
- Committed: Yes
- Contents: Hooks (pre-commit checks), agent configurations

**src/clients/*/lib/**
- Purpose: Pre-built native libraries for each platform
- Generated: Yes (during build)
- Committed: Yes (for distribution)
- Contents: Platform-specific binaries (x86_64-linux, aarch64-macos, etc.)

**src/clients/*/node_modules/**
- Purpose: Node.js dependencies
- Generated: Yes (npm install)
- Committed: No

**src/docs_website/**
- Purpose: Documentation website generator
- Generated: No (source), Yes (output)
- Committed: Source yes, output no

**deploy/**
- Purpose: Deployment configurations and scripts
- Generated: No
- Committed: Yes

## Build Artifacts

**Binary outputs:**
- `zig-out/bin/archerdb`: Main server binary
- `zig-out/lib/libarch_client.{a,so,dylib,dll}`: C client library
- Client SDK artifacts in respective language directories

**Test artifacts:**
- `test.archerdb`: Test database file (not committed)
- `*.log`: Log files (not committed)

**Data files:**
- `*.archerdb`: Database data files
- Checkpoint blocks and superblock data

## Import Patterns

**Core module imports:**
```zig
const vsr = @import("vsr.zig");
const constants = vsr.constants;
const stdx = vsr.stdx;
```

**VSR imports:**
```zig
const ReplicaType = @import("vsr/replica.zig").ReplicaType;
const GridType = @import("vsr/grid.zig").GridType;
```

**State machine imports:**
```zig
const geo_state_machine = @import("geo_state_machine.zig");
const GeoEvent = @import("geo_event.zig").GeoEvent;
```

**LSM imports:**
```zig
const ForestType = @import("lsm/forest.zig").ForestType;
const GrooveType = @import("lsm/groove.zig").GrooveType;
```

## Source File Count

- Total Zig source files: 277
- Primary language: Zig
- Supporting languages: C (client SDK), Go, Java, JavaScript/TypeScript, Python

---

*Structure analysis: 2026-01-22*
