# Technology Stack

**Analysis Date:** 2026-01-29

## Languages

**Primary:**
- Zig 0.15.2 - Core database engine, server implementation, and all system components
  - Location: `src/archerdb.zig`, `src/vsr.zig`, `src/geo_state_machine.zig`
  - Build requirement: Exactly Zig 0.14.1 (validated at compile-time in `build.zig` line 44-61)

**Secondary Client SDKs:**
- C - Client library bindings
  - Location: `src/clients/c/`
- Go 1.21 - Client library
  - Location: `src/clients/go/`, `go.mod`
- Java 11 - Client library
  - Location: `src/clients/java/`, `pom.xml`
- Node.js/TypeScript - Client library
  - Location: `src/clients/node/`, `package.json`, target Node.js 14+
- Python 3.7+ - Client library
  - Location: `src/clients/python/`, `pyproject.toml`

## Runtime

**Environment:**
- Linux (kernel >= 5.6), macOS, Windows
- Supported architectures via `resolve_target()` in `build.zig`:
  - x86_64-linux with x86_64_v3+aes CPU features
  - x86_64-macos with x86_64_v3+aes CPU features
  - aarch64-linux with baseline+aes+neon CPU features
  - aarch64-macos with baseline+aes+neon CPU features

**Package Manager:**
- Zig Build System (Zig's built-in package manager)
  - Manifest: `build.zig.zon`
  - Lockfile: Integrated via .fingerprint field

## Frameworks

**Core:**
- Viewstamped Replication (VSR) - Consensus/replication protocol
  - Location: `src/vsr.zig`, `src/vsr/`
  - Purpose: Strong consistency consensus for distributed cluster

- LSM-Tree Storage Engine - Log-Structured Merge tree
  - Location: `src/lsm/`
  - Purpose: Append-heavy persistent storage optimized for location events

- S2 Geometry Library - Google S2 spherical geometry
  - Location: `src/s2/`
  - Port: Pure Zig implementation from C++ (Google's S2 geometry library)
  - Purpose: Efficient spatial indexing for radius and polygon queries

**Geospatial:**
- GeoEvent State Machine - Location event processing
  - Location: `src/geo_state_machine.zig`, `src/geo_event.zig`
  - Purpose: Processes geospatial operations (insert, query radius, query polygon, latest)

- RAM Entity Index - In-memory index for latest positions
  - Location: `src/ram_index.zig`, `src/ram_index_simd.zig`
  - Purpose: Sub-microsecond lookups for entity latest positions
  - Features: SIMD optimization, memory-mapped mode support

**Integration & CDC:**
- AMQP 0-9-1 Protocol - Change Data Capture
  - Location: `src/cdc/amqp.zig`, `src/cdc/amqp/`
  - Purpose: Real-time data streaming to RabbitMQ-compatible brokers
  - Components: Full AMQP protocol implementation in Zig (spec.zig, protocol.zig, types.zig)

**Testing & Validation:**
- VOPR (Viewstamped Operation Replayer) - Deterministic simulation
  - Location: `src/vopr.zig`
  - Purpose: Fault injection and deterministic testing for consensus bugs
  - States: .testing or .geo (set via build option)

- Property-based Fuzz Testing
  - Location: `src/fuzz_tests.zig`, `src/message_bus_fuzz.zig`, `src/state_machine_fuzz.zig`
  - Purpose: Find edge cases in protocol and storage engine

**Build/Dev:**
- Zig Build System - Build orchestration
  - Config: `build.zig` (27K+ lines defining all build steps)
  - Features: Compile checks, unit/integration/replication tests, benchmark drivers, code generation

- Docker - Development containerization
  - Dockerfile: `deploy/Dockerfile` (multi-stage build, Zig 0.15.2)
  - Compose: `deploy/docker-compose.dev.yml` (3-node cluster)

**Observability:**
- Custom Tracing - Event tracing to Perfetto/Spall/Chrome format
  - Location: `src/trace.zig`
  - Output: JSON compatible with perfetto.dev, spall, chrome://tracing
  - Files: `src/trace/event.zig`, `src/trace/statsd.zig`

- StatsD Metrics - Metrics export
  - Location: `src/trace/statsd.zig`
  - Purpose: Export metrics in StatsD format (for Prometheus integration)

- Custom Metrics Registry
  - Location: `src/archerdb/metrics.zig`, `src/archerdb/cluster_metrics.zig`
  - Purpose: Internal metrics collection and export

## Key Dependencies

**Critical:**
- LZ4 1.10.0 (Zig fork) - Data compression
  - Git: `github.com/allyourcodebase/lz4.git?ref=1.10.0-6`
  - Hash: `lz4-1.10.0-6-ewyzw-4NAAAWDpY4xpiqr4LQhZQAC0x_rGnW2iPh6jk2`
  - Used in: LSM compaction, network message compression

**Cryptography (Standard Library):**
- AES-256-GCM (Zig std.crypto.aead)
  - Location: `src/encryption.zig` line 26
  - Purpose: Encryption at rest with AES-NI hardware acceleration
  - Version: ENCRYPTION_VERSION_GCM (v1, legacy) and ENCRYPTION_VERSION_AEGIS (v2, current)

- Aegis-256 (Zig std.crypto.aead)
  - Location: `src/encryption.zig` line 27
  - Purpose: Current encryption cipher (faster with AES-NI than GCM)
  - Supports both reading (v1) and writing (v2)

**Hardware Features (CPU):**
- AES-NI acceleration detection
  - Checked at compile-time via `hasAesNi()` in `src/encryption.zig` line 73
  - x86_64: Requires .aes CPU feature
  - aarch64: Requires .aes CPU feature (crypto extensions)

## Configuration

**Environment Variables (Docker/Deployment):**
- `ARCHERDB_REPLICA_INDEX` - Replica index in cluster (0, 1, 2, etc.)
- `ARCHERDB_ADDRESSES` - Comma-separated replica addresses (e.g., "node1:3000,node2:3001,node3:3002")
- `ARCHERDB_DATA_FILE` - Path to persistent data file (e.g., "/data/0_0.archerdb")
- `ARCHERDB_DEVELOPMENT` - Enable development mode (true/false)

**Build Options (Via `-D` flags):**
- `-Dconfig=lite` - Build configuration with ~130 MiB RAM footprint (for testing)
- `-Dconfig=production` - Build configuration with 7+ GiB RAM footprint
- `-Dconfig_verify` - Enable extra assertions (auto-enabled for Debug builds)
- `-Dconfig-aof-recovery` - Enable AOF Recovery mode
- `-Dvopr-state-machine=geo` - Set VOPR state machine (.geo or .testing)
- `-Dtarget=aarch64-linux` - Cross-compilation target
- `-Dmultiversion=latest` - Include past version for upgrades

**Server CLI Flags:**
- `--addresses=HOST:PORT[,HOST:PORT,...]` - Cluster replica addresses
- `--development` - Development mode (relaxed timing, debug logging)
- `--data-file=PATH` - Path to persistent data file
- `--replica-count=N` - Number of replicas in cluster
- `--cluster=ID` - Cluster identifier (used during format)
- `--replica=INDEX` - Replica index (0-based)
- `--log-level` - Log level (err, warn, info, debug)
- `--log-format` - Log format (text, json)
- `--trace=FILE` - Enable tracing to JSON file

## Platform Requirements

**Development:**
- Zig 0.15.2 (enforced at compile time)
- Linux/macOS/Windows with POSIX I/O support
- 24GB+ RAM recommended (for full builds)
- 8 cores recommended (uses `-j4` by default in constrained mode)

**Production:**
- Linux kernel >= 5.6 (for io_uring support)
- 7+ GiB RAM (for production build configuration)
- CPU with AES-NI support (x86_64 or aarch64 crypto extensions)
- Network: TCP/IP for client protocol (port 3000) and inter-replica communication
- Storage: Local filesystem with ~130 MiB-several GiB capacity depending on config
- Metrics port: TCP 9100 (Prometheus/StatsD)

**Client Platforms:**
- Node.js: 14+
- Python: 3.7+
- Go: 1.21+
- Java: 11+ (JDK 11 required, Java 25 class file version not yet supported by JaCoCo)
- C: C99+

---

*Stack analysis: 2026-01-29*
