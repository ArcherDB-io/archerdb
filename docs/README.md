# ArcherDB Documentation

ArcherDB is a distributed geospatial database for real-time location tracking at scale.

## Quick Links

| Guide | Time | Description |
|-------|------|-------------|
| [Quickstart](quickstart.md) | 5 min | Hello world - first query |
| [Getting Started](getting-started.md) | 10 min | Comprehensive setup and usage |
| [API Reference](api-reference.md) | - | Complete operation documentation |

## For Developers

### Tutorials

Learn ArcherDB step-by-step:

- [Quickstart](quickstart.md) - Insert and query your first location in 5 minutes
- [Getting Started](getting-started.md) - Comprehensive setup, SDK installation, and usage patterns

### How-To Guides

Goal-oriented guides:

- [SDK Retry Semantics](sdk-retry-semantics.md) - Configure retry behavior and handle errors
- [Error Codes](error-codes.md) - Understand and troubleshoot errors

### Reference

Complete API and configuration documentation:

- [API Reference](api-reference.md) - All operations with request/response details
- [Hardware Requirements](hardware-requirements.md) - Minimum and recommended specs
- [LSM Tuning](lsm-tuning.md) - Storage engine configuration
- [Journal Sizing](journal_sizing.md) - Write-ahead log configuration

### SDK Documentation

| Language | Package | Documentation |
|----------|---------|---------------|
| Python | `archerdb` | [README](../src/clients/python/README.md) |
| Node.js | `archerdb-node` | [README](../src/clients/node/README.md) |
| Go | `archerdb-go` | [README](../src/clients/go/README.md) |
| Java | `archerdb-java` | [README](../src/clients/java/README.md) |
| C | `libarcherdb` | [README](../src/clients/c/README.md) |

## For Operators

### Deployment

- [Operations Runbook](operations-runbook.md) - Day-to-day operational procedures
- [Capacity Planning](capacity-planning.md) - Sizing clusters for your workload
- [Multi-Region Deployment](multi-region-deployment.md) - Cross-region replication setup

### Backup & Recovery

- [Backup Operations](backup-operations.md) - Online backup procedures
- [Disaster Recovery](disaster-recovery.md) - Failover and restore procedures
- [Upgrade Guide](upgrade-guide.md) - Rolling upgrades and rollback

### Troubleshooting

- [Troubleshooting Guide](troubleshooting.md) - Diagnose and resolve common issues
- [Error Codes](error-codes.md) - Error reference with troubleshooting guidance

### Performance

- [Benchmarks](benchmarks.md) - Benchmark results and methodology
- [Profiling](profiling.md) - Performance profiling workflows

## Understanding ArcherDB

Architecture and design:

- [Architecture](architecture.md) - System design, data flow, and component interactions
- [VSR Understanding](vsr_understanding.md) - How Viewstamped Replication provides consensus
- [Durability Verification](durability-verification.md) - How ArcherDB ensures data durability

## Security

- [Encryption Guide](encryption-guide.md) - Encryption at rest configuration
- [Encryption Security](encryption-security.md) - Security model and key management

## Internals

For contributors:

- [Message Bus Errors](internals/message-bus-errors.md) - Network layer error handling

## Release Notes

- [Changelog](CHANGELOG.md) - Release history and notable changes
