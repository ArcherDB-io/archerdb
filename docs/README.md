# ArcherDB Documentation

ArcherDB is a distributed geospatial database built for real-time location tracking at scale. It combines the consistency guarantees of Viewstamped Replication (VSR) with a high-performance S2-based spatial index, enabling sub-millisecond queries across billions of location events.

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
- [Testing Guide](testing/README.md) - Run tests locally for all 5 SDKs
- [Benchmark Guide](benchmarks/README.md) - Run and interpret performance benchmarks

### Reference

Complete API and configuration documentation:

- [API Reference](api-reference.md) - All operations with request/response details
- [OpenAPI Specification](openapi.yaml) - Machine-readable API definition
- [Hardware Requirements](hardware-requirements.md) - Minimum and recommended specs
- [LSM Tuning](lsm-tuning.md) - Storage engine configuration
- [Journal Sizing](journal_sizing.md) - Write-ahead log configuration

### SDK Documentation

Comprehensive guides for each language:

- [SDK Overview](sdk/README.md) - Choosing an SDK, feature matrix, common patterns
- [SDK Comparison Matrix](sdk/comparison-matrix.md) - Feature parity and code examples
- [SDK Limitations](SDK_LIMITATIONS.md) - Known issues and workarounds
- [Parity Matrix](PARITY.md) - Cross-SDK verification status

| Language | Package | Documentation |
|----------|---------|---------------|
| Python | `archerdb` | [Full Guide](../src/clients/python/README.md) |
| Node.js | `archerdb-node` | [Full Guide](../src/clients/node/README.md) |
| Go | `archerdb-go` | [Full Guide](../src/clients/go/README.md) |
| Java | `archerdb-java` | [Full Guide](../src/clients/java/README.md) |
| C | `libarcherdb` | [Full Guide](../src/clients/c/README.md) |

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

### Alert Runbooks

Per-alert response guides linked from Prometheus alerts:

- [Replica Down](runbooks/replica-down.md) - When a replica is unreachable
- [View Changes](runbooks/view-changes.md) - Frequent leader elections
- [Index Degraded](runbooks/index-degraded.md) - Index performance issues

### Performance

- [Benchmarks](BENCHMARKS.md) - Benchmark framework and results
- [Benchmark Guide](benchmarks/README.md) - Running and interpreting benchmarks
- [Profiling](profiling.md) - Performance profiling workflows
- [LSM Tuning](lsm-tuning.md) - Storage engine optimization

### Testing & CI

- [Testing Guide](testing/README.md) - Run all tests locally
- [CI Tiers](testing/ci-tiers.md) - Smoke, PR, nightly, weekly tiers
- [curl Examples](curl-examples.md) - Raw HTTP examples for all operations
- [Protocol Reference](protocol.md) - Wire format and data types

## Understanding ArcherDB

Architecture and design:

- [Architecture](architecture.md) - System design, data flow, and component interactions
- [VSR Understanding](vsr_understanding.md) - How Viewstamped Replication provides consensus
- [Durability Verification](durability-verification.md) - How ArcherDB ensures data durability

## Security

- [Security Best Practices](security-best-practices.md) - Infrastructure security for local deployment
- [Encryption Guide](encryption-guide.md) - Encryption at rest configuration
- [Encryption Security](encryption-security.md) - Security model and key management

## Internals

For contributors:

- [Message Bus Errors](internals/message-bus-errors.md) - Network layer error handling

## Release Notes

- [Changelog](CHANGELOG.md) - Release history and notable changes

---

## Documentation Coverage

All documentation requirements (DOCS-01 through DOCS-08) are complete:

| Requirement | Documentation |
|-------------|---------------|
| DOCS-01: Getting started | [quickstart.md](quickstart.md), [getting-started.md](getting-started.md) |
| DOCS-02: API reference | [api-reference.md](api-reference.md), [openapi.yaml](openapi.yaml) |
| DOCS-03: Operations runbook | [operations-runbook.md](operations-runbook.md), [runbooks/](runbooks/) |
| DOCS-04: Troubleshooting | [troubleshooting.md](troubleshooting.md) |
| DOCS-05: Architecture | [architecture.md](architecture.md) |
| DOCS-06: Performance tuning | [lsm-tuning.md](lsm-tuning.md), [profiling.md](profiling.md), [benchmarks.md](benchmarks.md) |
| DOCS-07: Security | [security-best-practices.md](security-best-practices.md), [encryption-guide.md](encryption-guide.md) |
| DOCS-08: SDK documentation | [sdk/README.md](sdk/README.md), [src/clients/*/README.md](../src/clients/) |

See [REQUIREMENTS.md](../.planning/REQUIREMENTS.md) for full traceability.
