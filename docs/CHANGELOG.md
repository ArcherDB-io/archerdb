# Changelog

All notable changes to ArcherDB will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Observability Stack**
  - Prometheus metrics endpoint (`/metrics`) with S2 cell, query, replication, compaction, and process metrics
  - OpenTelemetry distributed tracing with OTLP export (HTTP POST)
  - W3C Trace Context and B3 propagation support
  - Structured logging with JSON and text formats
  - Per-module log levels (`--log-module-levels=vsr:debug,lsm:warn`)
  - Log rotation with configurable size limits

- **Grafana Dashboards**
  - Cluster Overview dashboard (8 panels)
  - Query Performance dashboard (10 panels)
  - Replication Status dashboard (8 panels)
  - Storage & Compaction dashboard (12 panels)
  - Cluster Health dashboard (10 panels)

- **Prometheus Alerting**
  - 29 alerting rules covering latency, replication, resources, errors, and compaction
  - Alertmanager notification templates for Slack, PagerDuty, OpsGenie, email, and webhook

- **Health Endpoints**
  - `/health/live` - Kubernetes liveness probe (always returns 200)
  - `/health/ready` - Kubernetes readiness probe (200 when initialized)
  - `/health/detailed` - Component-level health with replica, memory, storage, replication status

- **Cross-Region Replication**
  - S3-based WAL transport with AWS, MinIO, R2, GCS, and Backblaze support
  - Automatic provider detection (path-style for MinIO, virtual-hosted for AWS)
  - 16MB multipart uploads for large WAL segments
  - 10 retries with exponential backoff (~17 min total)
  - Disk spillover for S3 outages with automatic recovery

- **Geospatial Features**
  - Polygon queries with holes support (GeoJSON winding order)
  - Point-in-polygon using ray casting algorithm
  - TTL-based automatic data expiration with configurable per-entity TTL
  - Tiering support for hot/cold data separation

- **Security**
  - Encryption at rest with AES-256-GCM and Aegis-256
  - Key rotation support with online re-encryption
  - TLS certificate revocation checking (CRL/OCSP)

- **Operations Tools**
  - Interactive REPL for exploration (`archerdb repl`)
  - CSV import tool for bulk data loading (`archerdb import-csv`)
  - Backup scheduling with cron expressions and intervals
  - Kubernetes deployment manifests with StatefulSet
  - Rolling upgrade procedures

- **SDK Documentation**
  - Comprehensive documentation for all 5 SDKs (C, Go, Java, Node.js, Python)
  - Doxygen comments in C SDK generator
  - Google-style docstrings in Python SDK
  - JSDoc with TypeScript types in Node.js SDK
  - Javadoc with async support in Java SDK
  - Godoc comments in Go SDK

### Changed

- **Platform Support**
  - Removed Windows platform support to focus on Linux and macOS
  - Darwin F_FULLFSYNC validated at startup with immediate failure on unsupported filesystems

- **Performance**
  - Improved LSM compaction tuning optimized for geospatial workloads
  - Enterprise tier: 7 levels, growth factor 8, 64 compaction ops
  - Mid-tier: 6 levels, growth factor 10, 32 compaction ops
  - Dedicated compaction IOPS (18 read, 17 write) to prevent foreground starvation

- **Configuration**
  - Renamed `--aof` flag to `--aof-file` for clarity
  - Renamed `spillover_path` to `spillover_dir` in Config
  - Log format auto-detection (JSON for pipes, text for TTY)

### Fixed

- Darwin F_FULLFSYNC validation at startup catches unsupported filesystems immediately
- Message bus error handling for peer disconnection edge cases
- RAM index race condition at line 1859 in concurrent access scenarios
- ConnectionResetByPeer treated as normal disconnect, not logged as error
- macOS objcopy uses aarch64 binary for all architectures (Rosetta handles x86_64)

### Removed

- **Deprecated Flags**
  - `--aof` flag removed (use `--aof-file` instead)

- **Platform Support**
  - Windows platform support removed (Linux and macOS only)

- **Protocol**
  - Deprecated VSR message types (IDs 12, 21, 22, 23) reserved forever for wire compatibility

### Security

- All encryption keys use constant-time comparison to prevent timing attacks
- KMS credentials validated at startup, not just on first use
- S3 credentials never logged, even at debug level

---

## Release History

This changelog documents the development work completed in Phases 1-9 of the ArcherDB project. The `[Unreleased]` section above represents all features that will be included in the first stable release.

### Version Numbering

ArcherDB follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **MAJOR** version for incompatible API or wire protocol changes
- **MINOR** version for new features in a backward-compatible manner
- **PATCH** version for backward-compatible bug fixes

### Changelog Format

Each release entry includes the following sections (when applicable):

- **Added** - New features
- **Changed** - Changes to existing functionality
- **Deprecated** - Features to be removed in future releases
- **Removed** - Features removed in this release
- **Fixed** - Bug fixes
- **Security** - Security improvements or vulnerability fixes

[Unreleased]: https://github.com/ArcherDB-io/archerdb/compare/v0.1.0...HEAD
