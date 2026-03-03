# ArcherDB

High-performance geospatial database for fleet tracking, logistics, and real-time location applications.

ArcherDB provides specialized geospatial capabilities on a battle-tested distributed systems foundation.

## Deployment Model

ArcherDB follows a trusted-network, infrastructure-first security model:

- Built-in authn/authz is out of scope (enforce at API/service gateway)
- Built-in TLS/mTLS is out of scope (terminate and enforce in your network layer)
- Built-in encryption-at-rest is out of scope (use disk/volume/cloud-native encryption)
- Built-in managed backup orchestration is out of scope (use platform snapshots/backup tooling)

## Features

### Geospatial operations
- Insert location events
- Upsert location events
- Delete entities (GDPR erasure)
- Query by UUID
- Batch query by UUID
- Radius geospatial query
- Polygon geospatial query
- Latest events query

### Indexing
- S2 geospatial indexing
- RAM entity index (latest position)
- RAM index memory-mapped mode

### Storage & durability
- LSM-tree storage engine
- LSM range scans
- LSM compaction
- Write-ahead log/journal
- Checkpointing/snapshot
- Append-only file durability
- Grid/block storage
- Sharding/partitioning

### Replication & clustering
- Consensus replication (VSR)
- Cluster membership/reconfiguration
- Replica sync/repair
- Multi-region replication
- Client session management
- Topology discovery
- Cluster ping/status

### Data lifecycle & governance
- TTL expiration/retention
- Manual TTL operations
- Data validation/integrity
- Compliance/privacy controls
- Trusted-network deployment guidance

### Data movement & integration
- Replica recovery/rebuild
- External snapshot/backup integration (operator-managed)
- Data export
- CSV import/export
- Incremental load
- ETL/data transformation
- Change data capture (AMQP)

### Observability & ops
- Metrics/observability
- StatsD metrics
- Tracing/logging
- Signal handling/graceful shutdown
- CLI/REPL

### Clients & SDKs
- C client SDK
- Go client SDK
- Java client SDK
- Node.js client SDK
- Python client SDK

### SDK Feature Matrix
All SDK features listed below are supported across each language.

| Feature | C | Go | Java | Node.js | Python |
| --- | --- | --- | --- | --- | --- |
| TTL expiration/retention | yes | yes | yes | yes | yes |
| batch query by UUID | yes | yes | yes | yes | yes |
| cluster ping/status | yes | yes | yes | yes | yes |
| delete entities (GDPR erasure) | yes | yes | yes | yes | yes |
| insert location events | yes | yes | yes | yes | yes |
| latest events query | yes | yes | yes | yes | yes |
| manual TTL operations | yes | yes | yes | yes | yes |
| polygon geospatial query | yes | yes | yes | yes | yes |
| query by UUID | yes | yes | yes | yes | yes |
| radius geospatial query | yes | yes | yes | yes | yes |
| topology discovery | yes | yes | yes | yes | yes |
| upsert location events | yes | yes | yes | yes | yes |

### Tooling & testing
- Benchmarking
- Benchmark load generator
- Correctness testing
- Fuzz testing
- Deterministic simulation/fault injection
- Documentation generation
- Build system

### Internal infrastructure
- Platform I/O
- Memory management
- Message bus/RPC
- Randomness/sampling
- Internal utilities

## Quick Start

```bash
# Build from source
./zig/download.sh
./zig/zig build

# Run a single-node cluster
./zig-out/bin/archerdb format --cluster=0 --replica=0 --replica-count=1 data.archerdb
./zig-out/bin/archerdb start --addresses=3000 data.archerdb
```

## Tier Profiles

ArcherDB is distributed as tiered builds with distinct product intent:

- `lite`: Demo/evaluation tier. Fast and lightweight by design, with intentionally strict storage limits.
- `standard`: Baseline production tier.
- `pro`: Higher-performance mainstream tier.
- `enterprise`: High-end production tier.
- `ultra`: Top-end tier for premium performance positioning.

See [Tier Profiles](docs/tier-profiles.md) for authoritative tier intent and guardrails.

## Documentation

- [Getting Started Guide](docs/getting-started.md)
- [Operations Runbook](docs/operations-runbook.md)
- [Disaster Recovery](docs/disaster-recovery.md)
- [Capacity Planning](docs/capacity-planning.md)
- [SDK Retry Semantics](docs/sdk-retry-semantics.md)
- [API Reference](docs/api-reference.md) *(coming soon)*

## Architecture

Core architecture:

- **Consensus**: Viewstamped Replication (VR) for strong consistency
- **Storage**: LSM-tree optimized for append-heavy workloads
- **Testing**: VOPR (Viewstamped Operation Replayer) for deterministic simulation

Geospatial extensions:

- **GeoEvent state machine**: Location-aware events
- **S2 indexing**: Google's S2 geometry for efficient spatial queries
- **RAM entity index**: Sub-microsecond latest-position lookups

## Building from Source

### Prerequisites

- Linux (kernel >= 5.6), macOS, or Windows
- [Zig](https://ziglang.org/) (bundled, use `./zig/download.sh`)

### Build

```bash
# Download the bundled Zig compiler
./zig/download.sh

# Build all targets
./zig/zig build

# Run tests
./zig/zig build test
```
