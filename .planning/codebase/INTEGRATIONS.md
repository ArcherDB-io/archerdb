# External Integrations

**Analysis Date:** 2026-01-22

## APIs & External Services

**Message Queuing:**
- AMQP 0.9.1 - Change data capture integration
  - SDK/Client: Custom implementation in `src/cdc/amqp/protocol.zig`
  - Default port: 5672
  - Protocol: Advanced Message Queuing Protocol
  - Use case: CDC (Change Data Capture) streaming to external systems

## Data Storage

**Databases:**
- Custom LSM-tree storage engine
  - Connection: Direct file I/O
  - File format: `.archerdb` custom binary format
  - Storage: Local filesystem (grid/block storage)

**File Storage:**
- Local filesystem only
  - Data files: `*.archerdb` (custom binary format)
  - Write-ahead log (AOF - Append-Only File)
  - Checkpoint/snapshot files
  - Encryption at rest: AES-256-GCM or Aegis-256

**Caching:**
- RAM entity index (in-memory, memory-mapped mode available)
  - Location: Built into database server
  - Purpose: Latest position lookups (sub-microsecond)

## Authentication & Identity

**Auth Provider:**
- Custom session management
  - Implementation: VSR client session layer (`src/vsr/client.zig`)
  - Encryption: AES-256-GCM/Aegis-256 with hardware AES-NI
  - Key management: Pluggable KEK/DEK model (`src/encryption.zig`)

## Monitoring & Observability

**Error Tracking:**
- None (structured logging only)

**Logs:**
- Zig standard library logging framework
  - Scoped loggers (e.g., `.encryption`, `.geo_state_machine`)
  - Output: stdout/stderr

**Metrics:**
- Prometheus format
  - Implementation: `src/archerdb/metrics.zig`
  - Endpoint: `:9100/metrics` (configurable)
  - Types: Counter, Gauge, Histogram
  - Thread-safe atomic operations

**Dashboards:**
- Grafana
  - Dashboard: `monitoring/grafana/archerdb-dashboard.json`
  - Data source: Prometheus
  - Metrics: Query latency, cluster health, VSR replication, error counts

## CI/CD & Deployment

**Hosting:**
- Docker containers (self-hosted or cloud)
  - Image build: `deploy/Dockerfile`
  - Orchestration: Docker Compose or Kubernetes

**CI Pipeline:**
- GitHub Actions
  - Config: `.github/workflows/ci.yml`
  - Jobs: smoke tests, cross-platform tests, reproducible build verification
  - Test runner: `./zig/zig build test:unit`
  - Platforms: ubuntu-latest, macos-latest

**Deployment Tools:**
- Docker Compose (`deploy/docker-compose.dev.yml`)
- Kubernetes manifests (`deploy/k8s/`)

## Environment Configuration

**Required env vars:**
- `ARCHERDB_REPLICA_INDEX` - Replica number in cluster
- `ARCHERDB_ADDRESSES` - Comma-separated replica addresses
- `ARCHERDB_DATA_FILE` - Path to data file
- `ARCHERDB_DEVELOPMENT` - Development mode flag (optional)

**Secrets location:**
- Encryption keys: External key management system (AWS KMS, Vault, or file-based)
- KEK (Key Encryption Key): Stored externally
- DEK (Data Encryption Key): Per-file, wrapped with KEK in file header

## Webhooks & Callbacks

**Incoming:**
- None (no webhook endpoints)

**Outgoing:**
- AMQP publish events - CDC stream to message broker
  - Protocol: AMQP 0.9.1 (`src/cdc/amqp/protocol.zig`)
  - Content: Geospatial event changes

## Development Integrations

**Pre-commit Hooks:**
- License header validation (`./scripts/add-license-headers.sh --check`)
- Shell script linting (shellcheck)
- Code formatting (`./zig/zig build test -- tidy`)
- Build verification (`./zig/zig build`)

**Development Scripts:**
- `./scripts/dev-cluster.sh` - Local cluster orchestration
- `./scripts/test_clients.sh` - Multi-language client testing
- `./scripts/run_benchmarks.sh` - Performance benchmarking
- `./scripts/run_integration_tests.sh` - Integration test suite
- `./scripts/run_vopr.sh` - Deterministic simulation testing

## Client SDK Distribution

**Languages Supported:**
- C: Shared library + header (`src/clients/c/`)
- Go: Go module (`github.com/archerdb/archerdb-go`)
- Java: Maven artifact (`com.archerdb:archerdb-java:0.1.0-SNAPSHOT`)
- Node.js: npm package (`archerdb-node@0.1.0`)
- Python: pip package (`archerdb@0.0.1`)

**Native Bindings:**
- Zig FFI implementations for each language
  - C: `src/clients/c/arch_client_exports.zig`
  - Go: `src/clients/go/go_bindings.zig`
  - Java: `src/clients/java/java_bindings.zig`
  - Node.js: `src/clients/node/node_bindings.zig`
  - Python: `src/clients/python/python_bindings.zig`

---

*Integration audit: 2026-01-22*
