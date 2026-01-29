# External Integrations

**Analysis Date:** 2026-01-29

## APIs & External Services

**None Detected - Standalone Database**

ArcherDB is a self-contained geospatial database with no external API dependencies. All functionality is implemented internally.

## Data Storage

**Databases:**
- None - ArcherDB is the database
- Uses local filesystem for persistence (via `src/storage.zig`)
  - Client: Built-in LSM-tree engine
  - Configuration: Path specified via `--data-file` flag or `ARCHERDB_DATA_FILE` env var

**File Storage:**
- Local filesystem only
  - Primary data file format: `.archerdb` (e.g., `0_0.archerdb`)
  - Location: Configurable via CLI (default relative path)
  - Capabilities: Grid storage, compaction, snapshots, append-only logs

**Caching:**
- RAM Entity Index (in-memory)
  - Location: `src/ram_index.zig`, `src/ram_index_simd.zig`
  - Purpose: Sub-microsecond latest-position lookups
  - Features: SIMD optimization, optional memory-mapped mode for large datasets

- Query Result Cache
  - Location: `src/query_cache.zig`
  - Purpose: Cache frequently accessed query results

- S2 Covering Cache
  - Location: `src/s2_covering_cache.zig`
  - Purpose: Cache S2 cell region coverings for spatial queries

## Authentication & Identity

**Auth Provider:**
- Custom (no external auth)
  - Implementation: Client session management via VSR consensus protocol
  - Location: `src/vsr.zig`, client protocol layer
  - Mechanism: TCP connection authentication, no credentials required
  - Future note: Compliance module references consent management but not fully integrated

**Authorization:**
- None - no per-user/per-entity access control
- Cluster-level only: All clients have same access to all data

## Monitoring & Observability

**Error Tracking:**
- None (errors logged locally)
- Custom error codes system
  - Location: `src/error_codes.zig`
  - Output: Logged to stdout/stderr based on configuration

**Logs:**
- Local file-based logging
  - Approach: Text or JSON format (configurable via `--log-format`)
  - Levels: err, warn, info, debug (configurable via `--log-level`)
  - Features: Rotating log files with size limits
  - Implementation: `src/archerdb/main.zig` RotatingLog struct (lines 58-148)

- Module-level logging
  - Location: `src/observability/module_log_levels.zig`
  - Purpose: Per-module log level control

**Metrics Export:**
- StatsD Protocol
  - Location: `src/trace/statsd.zig`
  - Purpose: Export metrics for Prometheus scraping
  - Port: TCP 9100 (metrics server)
  - Metrics tracked: Query latencies, replication lag, cache hits, compaction progress

- Custom Metrics Registry
  - Location: `src/archerdb/metrics.zig`, `src/archerdb/cluster_metrics.zig`
  - Exported metrics:
    - Coordinator fanout operations
    - Resharding progress
    - Replication follower counts
    - Query cache statistics
    - Entity index statistics

**Tracing & Profiling:**
- Event Tracing (Perfetto/Spall/Chrome format)
  - Location: `src/trace.zig`
  - Output format: JSON compatible with:
    - perfetto.dev
    - gravitymoth.com/spall
    - chrome://tracing
  - Usage: `./archerdb start --trace=trace.json`
  - Features: Process/thread IDs, timestamps, event categories, stack traces

- Profiling Support
  - Build: `./zig build profile` (Tracy on-demand profiling + frame pointers)
  - Location: `build.zig` line 97

## CI/CD & Deployment

**Hosting:**
- Docker - Development/staging containerization
  - Dockerfile: `deploy/Dockerfile`
  - Base image: debian:bookworm-slim (multi-stage build)
  - Zig version: 0.15.2 (installed during build)
  - Ports exposed: 3000 (client), 9100 (metrics)
  - Entrypoint: `archerdb` binary (supports format/start/inspect commands)

- Docker Compose - 3-node cluster orchestration
  - Config: `deploy/docker-compose.dev.yml`
  - Services: archerdb-0, archerdb-1, archerdb-2
  - Network: Bridge network (172.28.0.0/16)
  - Health checks: TCP ping on respective ports
  - Data: Named volumes per replica (archerdb-data-0/1/2)
  - Commands: build → format → up (3 commands per spec)

**CI Pipeline:**
- GitHub Actions (inferred from `.github/` directory)
  - Repository: https://github.com/ArcherDB-io/archerdb
  - Build configuration: Standard Zig + test matrix

- Pre-commit Hooks
  - Location: `.claude/hooks/pre-commit-check.sh` (per CLAUDE.md)
  - Checks:
    1. Build check: `./zig/zig build -j4 -Dconfig=lite`
    2. License headers: `./scripts/add-license-headers.sh --check`
    3. Quick unit tests: Representative subset

## Environment Configuration

**Required env vars:**
- `ARCHERDB_REPLICA_INDEX` - Replica index (0-based integer)
- `ARCHERDB_ADDRESSES` - Comma-separated addresses (e.g., "node1:3000,node2:3000")
- `ARCHERDB_DATA_FILE` - Path to data file

**Optional env vars:**
- `ARCHERDB_DEVELOPMENT` - Enable development mode (true/false)

**Secrets location:**
- No built-in secret storage
- Encryption at-rest keys: Pluggable key provider architecture
  - Location: `src/encryption.zig` line 10 (KeyProvider docs)
  - Architecture: Master key (KEK) in external system, per-file Data Encryption Keys (DEK) wrapped with KEK
  - Supported: AWS KMS, Vault, file-based (specified as "pluggable")

**Configuration files:**
- No config files required (all CLI-based)
- Optional: Docker environment files for Compose deployments

## Webhooks & Callbacks

**Incoming:**
- None implemented
- Note: Compliance audit system references webhooks but not production-ready
  - Location: `src/archerdb/etl_integration.zig` (WebhookRegistry structure)

**Outgoing:**
- AMQP 0-9-1 Change Data Capture (CDC)
  - Location: `src/cdc/amqp.zig`, `src/cdc/amqp/protocol.zig`
  - Purpose: Stream data changes to RabbitMQ-compatible brokers
  - Configuration: `src/cdc/runner.zig` (AMQP client initialization)
  - Protocol version: AMQP 0-9-1 (RabbitMQ standard)
  - Components:
    - AMQP spec parser: `src/cdc/amqp/spec_parser.py`
    - Protocol types: `src/cdc/amqp/types.zig`
    - Full encoding/decoding: `src/cdc/amqp/protocol.zig`
  - Example broker: RabbitMQ (4.1.0+, per code comments)

## Data Movement

**Backup/Restore:**
- Snapshot-based backups
  - Location: `src/archerdb/backup_coordinator.zig`, `src/archerdb/restore.zig`
  - Config types: BackupCoordinator, RestoreConfig
  - Method: Via grid checkpointing (snapshots)

**Data Import/Export:**
- CSV Import/Export
  - Tool: `src/csv_import.zig`
  - Build step: `./zig/zig build csv_import`
  - Purpose: Bulk load location events from CSV

- Append-Only File (AOF) Format
  - Location: `src/aof.zig`
  - Purpose: Durable write-ahead log for replication recovery
  - Tool: `./zig/zig build aof` (AOF utility)

## Compliance & Privacy

**Data Governance:**
- TTL/Retention Management
  - Location: `src/ttl.zig`
  - Operations:
    - TTL set: Manual expiration configuration per entity
    - TTL extend: Prolong retention for specific entities
    - TTL clear: Remove expiration for entities
  - Automatic cleanup: Garbage collection of expired events

- GDPR Erasure
  - Location: `src/geo_state_machine.zig` (DeleteEntity operations)
  - Method: Permanent deletion of entity from all shards

**Compliance Modules (Framework, not production-integrated):**
- Breach Notification System
  - Location: `src/archerdb/breach_notification.zig`
  - State: Access pattern anomaly detection framework

- Data Minimization
  - Location: `src/archerdb/data_minimization.zig`
  - State: Pipeline configuration

- Data Subject Rights Handler
  - Location: `src/archerdb/data_subject_rights.zig`
  - State: Request handler framework

- Consent Management
  - Location: `src/archerdb/consent_management.zig`
  - State: Consent tracking (not enforced in queries)

- Compliance Audit
  - Location: `src/archerdb/compliance_audit.zig`
  - State: Audit log tracking

- Data Transform Pipeline
  - Location: `src/archerdb/data_transform.zig`
  - State: ETL pipeline framework

**Encryption:**
- At-rest encryption
  - Algorithm: AES-256-GCM (v1, legacy) or Aegis-256 (v2, current)
  - Location: `src/encryption.zig`
  - Hardware acceleration: AES-NI (x86_64, aarch64)
  - Key management: Pluggable provider (AWS KMS, Vault, file-based)
  - Per-file DEK with KEK wrapping

- In-transit encryption: TLS support (not detailed in code - implementation assumed in network layer)

## Replication & Clustering

**Consensus Protocol:**
- Viewstamped Replication (VSR)
  - Location: `src/vsr.zig`
  - Purpose: Strong consistency across replicas
  - State machine: Pluggable (currently GeoEvent state machine)

**Multi-Region Replication:**
- Location: `docs/multi-region-deployment.md`
- Approach: Standard VSR clusters per region (no built-in federation)

---

*Integration audit: 2026-01-29*
