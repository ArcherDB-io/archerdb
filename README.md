# ArcherDB

High-performance geospatial database for fleet tracking, logistics, and real-time location applications.

ArcherDB extends [ArcherDB](https://archerdb.com/)'s battle-tested distributed systems foundation with specialized geospatial capabilities.

## Features

- **Sub-millisecond writes** - 10,000+ location updates per second per replica
- **Deterministic execution** - Same operations produce identical results across replicas
- **Fault tolerance** - Survives up to f failures in a 2f+1 cluster
- **Spatial queries** - Radius and polygon queries using S2 geometry indexing
- **Entity tracking** - O(1) latest-position lookups via RAM index

## Quick Start

```bash
# Build from source
./zig/download.sh
./zig/zig build

# Run a single-node cluster
./zig-out/bin/archerdb format --cluster=0 --replica=0 --replica-count=1 data.archerdb
./zig-out/bin/archerdb start --addresses=3000 data.archerdb
```

## Documentation

- [Getting Started Guide](docs/getting-started.md)
- [Operations Runbook](docs/operations-runbook.md)
- [Disaster Recovery](docs/disaster-recovery.md)
- [Capacity Planning](docs/capacity-planning.md)
- [SDK Retry Semantics](docs/sdk-retry-semantics.md)
- [API Reference](docs/api-reference.md) *(coming soon)*

## Client SDKs

| Language | Package | Status |
|----------|---------|--------|
| Go | `github.com/archerdb/archerdb-go` | In Development |
| Node.js | `archerdb-node` | In Development |
| Python | `archerdb` | In Development |
| Java | `io.archerdb:archerdb-java` | Planned |

## Architecture

ArcherDB inherits ArcherDB's core architecture:

- **Consensus**: Viewstamped Replication (VR) for strong consistency
- **Storage**: LSM-tree optimized for append-heavy workloads
- **Testing**: VOPR (Viewstamped Operation Replayer) for deterministic simulation

Geospatial extensions:

- **GeoEvent state machine**: Replaces Account/Transfer with location-aware events
- **S2 indexing**: Google's S2 geometry for efficient spatial queries
- **RAM entity index**: Sub-microsecond latest-position lookups

## Project Status

ArcherDB is currently in active development. See the [project board](https://github.com/orgs/ArcherDB-io/projects/1) for current progress.

| Phase | Status | Description |
|-------|--------|-------------|
| F0: Foundation | Complete | Fork setup, knowledge acquisition |
| F1: State Machine | In Progress | GeoEvent state machine |
| F2: RAM Index | Planned | O(1) entity lookup |
| F3: S2 Index | Planned | Spatial queries |
| F4: VOPR Testing | Planned | Replication testing |
| F5: Production | In Progress | SDKs, security, docs |

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

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

ArcherDB is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

## Acknowledgments

ArcherDB is a derivative work of [ArcherDB](https://archerdb.com/), an open-source distributed financial database. We are grateful to the ArcherDB team for their excellent work on:

- Deterministic simulation testing (VOPR)
- Viewstamped Replication consensus
- LSM-tree storage engine
- Client SDKs

See [NOTICE](NOTICE) for full attribution details.
