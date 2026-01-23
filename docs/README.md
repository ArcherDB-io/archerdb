# ArcherDB Documentation

ArcherDB is a distributed geospatial database built for real-time location tracking at scale. It combines the consistency guarantees of Viewstamped Replication (VSR) with a high-performance S2-based spatial index, enabling sub-millisecond queries across billions of location events.

## Getting Started

New to ArcherDB? Start here:

- [Quickstart](quickstart.md) - Insert and query your first location data in 5 minutes
- [Getting Started Guide](getting-started.md) - Comprehensive setup, SDK installation, and usage patterns
- [Error Codes](error-codes.md) - Complete error reference with troubleshooting guidance

## API Reference

- [API Reference](api-reference.md) - Complete API documentation for all operations
- [SDK Retry Semantics](sdk-retry-semantics.md) - Retry behavior, idempotency, and error handling

## Architecture

- [VSR Understanding](vsr_understanding.md) - How Viewstamped Replication provides consensus
- [LSM Tuning](lsm-tuning.md) - Storage engine configuration and optimization
- [Durability Verification](durability-verification.md) - How ArcherDB ensures data durability

## Operations

- [Operations Runbook](operations-runbook.md) - Day-to-day operational procedures
- [Disaster Recovery](disaster-recovery.md) - Backup, restore, and failover procedures
- [Capacity Planning](capacity-planning.md) - Sizing clusters for your workload
- [Multi-Region Deployment](multi-region-deployment.md) - Cross-region replication setup

## Security

- [Encryption Guide](encryption-guide.md) - Encryption at rest configuration
- [Encryption Security](encryption-security.md) - Security model and key management

## SDKs

ArcherDB provides official SDKs for five languages:

| Language | Package | Documentation |
|----------|---------|---------------|
| Node.js | `archerdb-node` | [README](../src/clients/node/README.md) |
| Python | `archerdb` | [README](../src/clients/python/README.md) |
| Go | `archerdb-go` | [README](../src/clients/go/README.md) |
| Java | `archerdb-java` | [README](../src/clients/java/README.md) |
| C | `libarcherdb` | [README](../src/clients/c/README.md) |

## Guides

- [Journal Sizing](journal_sizing.md) - Write-ahead log configuration

## Internals

For contributors and those curious about implementation details:

- [Message Bus Errors](internals/message-bus-errors.md) - Network layer error handling
