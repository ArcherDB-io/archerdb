# Technology Stack

**Analysis Date:** 2026-01-22

## Languages

**Primary:**
- Zig 0.14.1 - Core database implementation (`src/`)

**Secondary:**
- TypeScript ~4.0.2 - Node.js client SDK (`src/clients/node/`)
- Python >=3.7 - Python client SDK (`src/clients/python/`)
- Java 11 - Java client SDK (`src/clients/java/`)
- Go 1.21 - Go client SDK (`src/clients/go/`)
- C - C client SDK and FFI bindings (`src/clients/c/`)

## Runtime

**Environment:**
- Zig 0.14.1 (bundled in `./zig/zig`, 164MB binary)
- Version enforced at compile time in `build.zig`

**Package Manager:**
- Zig build system (`build.zig`, `build.zig.zon`)
- Node: npm (lockfile present in `src/clients/node/package-lock.json`)
- Python: pip with hatchling build backend (`pyproject.toml`)
- Java: Maven (pom.xml files)
- Go: Go modules (`go.mod`)

## Frameworks

**Core:**
- Custom Zig VSR (Viewstamped Replication) implementation - Distributed consensus
- Custom LSM-tree storage engine - Data persistence
- Custom S2 geospatial indexing - Spatial queries

**Testing:**
- Zig built-in test framework - Unit tests (`./zig/zig build test:unit`)
- JUnit 5 (Jupiter) 5.10.1 - Java SDK tests
- JUnit 4 (legacy support) - Java legacy tests
- pytest - Python SDK tests (in venv)

**Build/Dev:**
- Zig build system - All compilation and orchestration
- TypeScript compiler 4.0.2 - Node.js client builds
- Maven - Java client builds
- Hatchling - Python package builds
- Docker - Container builds (`deploy/Dockerfile`)
- Docker Compose 3.9 - Local development clusters (`deploy/docker-compose.dev.yml`)

## Key Dependencies

**Critical:**
- `stdx` - Custom Zig standard library extensions (vendored in `src/stdx/`)
- `aegis` - AES-NI cryptographic primitives (vendored in `src/stdx/vendored/aegis.zig`)

**Infrastructure:**
- AMQP 0.9.1 protocol implementation - Change data capture (`src/cdc/amqp/`)
- Prometheus metrics format - Observability (`src/archerdb/metrics.zig`)

**Java SDK:**
- Gson 2.10.1 - JSON parsing in wire format tests

**Node.js SDK:**
- @types/node ^14.14.41 - TypeScript type definitions
- node-api-headers ^0.0.2 - Native addon headers

## Configuration

**Environment:**
- No .env files detected (no secrets in repository)
- Configuration via command-line flags and arguments
- Docker environment variables: `ARCHERDB_REPLICA_INDEX`, `ARCHERDB_ADDRESSES`, `ARCHERDB_DATA_FILE`, `ARCHERDB_DEVELOPMENT`

**Build:**
- `build.zig` - Main build configuration (2629 lines)
- `build.zig.zon` - Zig package metadata
- `.editorconfig` - Code style configuration
- `tsconfig.json` - TypeScript configuration (Node.js client)
- `pyproject.toml` - Python package configuration
- `pom.xml` - Java Maven configuration

## Platform Requirements

**Development:**
- Linux (kernel >= 5.6), macOS, or Windows
- Supported targets: aarch64-linux, aarch64-macos, x86_64-linux, x86_64-macos, x86_64-windows
- CPU features required: AES-NI (x86_64_v3+aes or aarch64 baseline+aes+neon)
- Zig 0.14.1 (downloaded via `./zig/download.sh`)

**Production:**
- Docker containers (multi-stage build in `deploy/Dockerfile`)
- Kubernetes manifests available (`deploy/k8s/`)
- Metrics exposed on port 9100 (Prometheus format)
- Client connections on ports 3000-3002 (configurable)

---

*Stack analysis: 2026-01-22*
