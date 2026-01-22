# Requirements: ArcherDB Completion

**Defined:** 2026-01-22
**Core Value:** Correctness, performance, completeness with no compromises

Everything below must be complete before release. No versions, no deferrals.

## Requirements

### Core Geospatial - S2 Indexing (S2)

- [ ] **S2-01**: S2 cell indexing correctly partitions geographic space
- [ ] **S2-02**: S2 cell level selection optimized for query patterns
- [ ] **S2-03**: S2 covering algorithms minimize false positives
- [ ] **S2-04**: S2 index handles antimeridian crossing correctly
- [ ] **S2-05**: S2 index handles polar regions correctly
- [ ] **S2-06**: S2 cell ID computation matches Google S2 reference
- [ ] **S2-07**: S2 index performance benchmarked and optimized
- [ ] **S2-08**: S2 index memory usage documented and bounded

### Core Geospatial - Radius Query (RAD)

- [ ] **RAD-01**: Radius query returns all points within specified distance
- [ ] **RAD-02**: Radius query returns no points outside specified distance
- [ ] **RAD-03**: Radius query handles edge cases (zero radius, huge radius)
- [ ] **RAD-04**: Radius query uses great-circle distance (haversine)
- [ ] **RAD-05**: Radius query efficiently uses S2 cell covering
- [ ] **RAD-06**: Radius query latency benchmarked at various scales
- [ ] **RAD-07**: Radius query handles high-density clusters
- [ ] **RAD-08**: Radius query result ordering is deterministic

### Core Geospatial - Polygon Query (POLY)

- [ ] **POLY-01**: Polygon query returns all points inside polygon
- [ ] **POLY-02**: Polygon query returns no points outside polygon
- [ ] **POLY-03**: Polygon query handles convex polygons
- [ ] **POLY-04**: Polygon query handles concave polygons
- [ ] **POLY-05**: Polygon query handles polygons with holes
- [ ] **POLY-06**: Polygon query handles self-intersecting polygons (reject or handle)
- [ ] **POLY-07**: Polygon query handles polygons crossing antimeridian
- [ ] **POLY-08**: Polygon query efficiently uses S2 cell covering
- [ ] **POLY-09**: Polygon query latency benchmarked at various scales

### Core Geospatial - Entity Operations (ENT)

- [ ] **ENT-01**: Insert GeoEvent stores location with all metadata
- [ ] **ENT-02**: Upsert GeoEvent updates existing entity correctly
- [ ] **ENT-03**: Upsert creates tombstone for previous version
- [ ] **ENT-04**: Delete entity removes from all indexes (GDPR erasure)
- [ ] **ENT-05**: Delete verifiable (entity not retrievable after delete)
- [ ] **ENT-06**: UUID query returns correct entity by ID
- [ ] **ENT-07**: Batch UUID query returns all requested entities
- [ ] **ENT-08**: Latest query returns most recent position per entity
- [ ] **ENT-09**: TTL expiration removes expired entities automatically
- [ ] **ENT-10**: TTL cleanup metrics exposed for GDPR compliance

### Core Geospatial - RAM Index (RAM)

- [ ] **RAM-01**: RAM index provides O(1) latest position lookup
- [ ] **RAM-02**: RAM index handles concurrent access correctly
- [ ] **RAM-03**: RAM index race conditions prevented (line 1859 fix verified)
- [ ] **RAM-04**: RAM index memory usage bounded and documented
- [ ] **RAM-05**: RAM index survives checkpoint/restart
- [ ] **RAM-06**: RAM index memory-mapped mode works correctly
- [ ] **RAM-07**: RAM index handles hash collisions correctly
- [ ] **RAM-08**: RAM index TTL integration works correctly

### Core Storage - LSM Tree (LSM)

- [ ] **LSM-01**: LSM tree persists all committed data
- [ ] **LSM-02**: LSM compaction merges levels correctly
- [ ] **LSM-03**: LSM compaction eliminates tombstones properly
- [ ] **LSM-04**: LSM range scans return correct ordered results
- [ ] **LSM-05**: LSM handles write amplification within bounds
- [ ] **LSM-06**: LSM compaction tuning parameters optimized (constants.zig)
- [ ] **LSM-07**: LSM performance under sustained write load
- [ ] **LSM-08**: LSM recovery from crash is correct

### Core Storage - Durability (DUR)

- [ ] **DUR-01**: Write-ahead log captures all mutations
- [ ] **DUR-02**: Checkpoint captures complete consistent state
- [ ] **DUR-03**: Recovery from checkpoint restores full state
- [ ] **DUR-04**: Recovery from WAL replays uncommitted transactions
- [ ] **DUR-05**: Fsync guarantees data on disk (F_FULLFSYNC on Darwin)
- [ ] **DUR-06**: No data loss under clean shutdown
- [ ] **DUR-07**: No data loss under crash (within WAL window)
- [ ] **DUR-08**: Encryption at rest protects all persisted data

### Core Consensus - VSR Protocol (VSR)

- [ ] **VSR-01**: VSR achieves consensus across replica quorum
- [ ] **VSR-02**: VSR handles view changes correctly
- [ ] **VSR-03**: VSR handles replica failures and recovery
- [ ] **VSR-04**: VSR maintains linearizable consistency
- [ ] **VSR-05**: VSR snapshot verification enabled and working
- [ ] **VSR-06**: VSR journal prepare checksums verified
- [ ] **VSR-07**: VSR deprecated message types removed
- [ ] **VSR-08**: VSR handles network partitions correctly
- [ ] **VSR-09**: VSR state machine determinism verified

### Replication - Cross-Region (REPL)

- [ ] **REPL-01**: S3RelayTransport uploads data to S3 (implement, not simulate)
- [ ] **REPL-02**: S3 backend supports generic S3 API (AWS, MinIO, R2, GCS, Backblaze)
- [ ] **REPL-03**: S3 upload handles authentication (AWS SigV4, IAM roles)
- [ ] **REPL-04**: S3 upload handles retries with exponential backoff
- [ ] **REPL-05**: S3 upload handles multipart uploads for large entries
- [ ] **REPL-06**: Disk spillover writes to disk when memory queue fills
- [ ] **REPL-07**: Disk spillover recovers from spillover files on restart
- [ ] **REPL-08**: Disk spillover has queue persistence with metadata tracking
- [ ] **REPL-09**: Replication lag metrics exposed
- [ ] **REPL-10**: Integration tests verify S3 upload with MinIO
- [ ] **REPL-11**: Integration tests verify disk spillover and recovery

### Sharding (SHARD)

- [ ] **SHARD-01**: Consistent hashing distributes entities evenly
- [ ] **SHARD-02**: Jump hash matches across all client versions
- [ ] **SHARD-03**: Shard routing is deterministic for same entity
- [ ] **SHARD-04**: Cross-shard queries fan out correctly
- [ ] **SHARD-05**: Coordinator aggregates results correctly
- [ ] **SHARD-06**: Resharding maintains data integrity

### Message Bus (MBUS)

- [ ] **MBUS-01**: All error conditions audited (fatal vs recoverable)
- [ ] **MBUS-02**: Error handling documented with rationale
- [ ] **MBUS-03**: Connection closure on appropriate errors only
- [ ] **MBUS-04**: Darwin vs Linux shutdown() differences resolved
- [ ] **MBUS-05**: Connection state transitions tested
- [ ] **MBUS-06**: Peer eviction logic correct under load

### Platform Support (PLAT)

- [ ] **PLAT-01**: Windows support code removed from io/windows.zig
- [ ] **PLAT-02**: Windows removed from build.zig targets
- [ ] **PLAT-03**: Windows removed from documentation
- [ ] **PLAT-04**: macOS x86_64 test assertion fixed (build.zig:811)
- [ ] **PLAT-05**: Darwin fsync uses F_FULLFSYNC correctly
- [ ] **PLAT-06**: Multiversion deprecated architectures resolved
- [ ] **PLAT-07**: Linux io_uring works on all supported kernels
- [ ] **PLAT-08**: macOS kqueue implementation correct

### Encryption (ENC)

- [ ] **ENC-01**: AES-256-GCM encryption verified correct
- [ ] **ENC-02**: Aegis-256 encryption verified correct
- [ ] **ENC-03**: Key wrapping (KEK/DEK) implemented correctly
- [ ] **ENC-04**: Key rotation procedure documented and tested
- [ ] **ENC-05**: Hardware AES-NI detection works on all platforms
- [ ] **ENC-06**: Software fallback works when AES-NI unavailable
- [ ] **ENC-07**: Encrypted file format versioned for migration

### SDK - C (SDKC)

- [ ] **SDKC-01**: All geospatial operations available
- [ ] **SDKC-02**: All error codes mapped from state machine
- [ ] **SDKC-03**: Header file fully documented (arch_client.h)
- [ ] **SDKC-04**: Memory management documented (ownership rules)
- [ ] **SDKC-05**: Thread safety documented
- [ ] **SDKC-06**: Sample code for all operations
- [ ] **SDKC-07**: Test coverage complete

### SDK - Go (SDKG)

- [ ] **SDKG-01**: All geospatial operations available
- [ ] **SDKG-02**: All error codes mapped with errors.Is support
- [ ] **SDKG-03**: Godoc comments complete
- [ ] **SDKG-04**: Context support for cancellation
- [ ] **SDKG-05**: Idiomatic Go patterns throughout
- [ ] **SDKG-06**: Sample code for all operations
- [ ] **SDKG-07**: Test coverage complete
- [ ] **SDKG-08**: README with quick start guide

### SDK - Java (SDKJ)

- [ ] **SDKJ-01**: All geospatial operations available
- [ ] **SDKJ-02**: All error codes mapped as exceptions
- [ ] **SDKJ-03**: Javadoc complete
- [ ] **SDKJ-04**: CompletableFuture async support
- [ ] **SDKJ-05**: Try-with-resources support
- [ ] **SDKJ-06**: Sample code for all operations
- [ ] **SDKJ-07**: Test coverage complete
- [ ] **SDKJ-08**: README with quick start guide
- [ ] **SDKJ-09**: Maven Central ready

### SDK - Node.js (SDKN)

- [ ] **SDKN-01**: All geospatial operations available
- [ ] **SDKN-02**: All error codes mapped as typed errors
- [ ] **SDKN-03**: TSDoc comments complete
- [ ] **SDKN-04**: TypeScript types for all operations
- [ ] **SDKN-05**: Promise/async-await support
- [ ] **SDKN-06**: Sample code for all operations
- [ ] **SDKN-07**: Test coverage complete
- [ ] **SDKN-08**: README with quick start guide
- [ ] **SDKN-09**: npm publish ready

### SDK - Python (SDKP)

- [ ] **SDKP-01**: All geospatial operations available
- [ ] **SDKP-02**: All error codes mapped as exceptions
- [ ] **SDKP-03**: Docstrings complete (Google style)
- [ ] **SDKP-04**: Type hints for all operations
- [ ] **SDKP-05**: Async support (asyncio)
- [ ] **SDKP-06**: Sample code for all operations
- [ ] **SDKP-07**: Test coverage complete
- [ ] **SDKP-08**: README with quick start guide
- [ ] **SDKP-09**: PyPI publish ready

### Observability - Metrics (MET)

- [ ] **MET-01**: Prometheus metrics for all operations
- [ ] **MET-02**: Latency histograms (p50, p95, p99)
- [ ] **MET-03**: Throughput counters (ops/sec)
- [ ] **MET-04**: Error counters by type
- [ ] **MET-05**: Replication lag gauge
- [ ] **MET-06**: LSM compaction metrics
- [ ] **MET-07**: Memory usage metrics
- [ ] **MET-08**: Connection pool metrics
- [ ] **MET-09**: S2 index metrics (cell count, coverage)

### Observability - Tracing (TRACE)

- [ ] **TRACE-01**: OpenTelemetry tracing integration
- [ ] **TRACE-02**: Trace spans for insert operations
- [ ] **TRACE-03**: Trace spans for query operations
- [ ] **TRACE-04**: Trace spans for compaction
- [ ] **TRACE-05**: Trace spans for replication
- [ ] **TRACE-06**: Trace context propagation across VSR
- [ ] **TRACE-07**: Trace export to Jaeger/Zipkin

### Observability - Logging (LOG)

- [ ] **LOG-01**: Structured JSON logging
- [ ] **LOG-02**: Correlation IDs across operations
- [ ] **LOG-03**: Log levels configurable at runtime
- [ ] **LOG-04**: Sensitive data redacted from logs
- [ ] **LOG-05**: Log rotation support

### Observability - Health (HEALTH)

- [ ] **HEALTH-01**: /health endpoint (basic liveness)
- [ ] **HEALTH-02**: /ready endpoint (can accept traffic)
- [ ] **HEALTH-03**: /live endpoint (not deadlocked)
- [ ] **HEALTH-04**: Health checks include replica status
- [ ] **HEALTH-05**: Health checks include storage status

### Observability - Dashboards (DASH)

- [ ] **DASH-01**: Grafana dashboard template
- [ ] **DASH-02**: Dashboard shows query latency
- [ ] **DASH-03**: Dashboard shows throughput
- [ ] **DASH-04**: Dashboard shows replication lag
- [ ] **DASH-05**: Dashboard shows cluster health
- [ ] **DASH-06**: Prometheus alerting rules
- [ ] **DASH-07**: Alerts for resource exhaustion (proactive)
- [ ] **DASH-08**: Alerts for replication lag
- [ ] **DASH-09**: Alerts for error rate spikes

### Documentation - API Reference (AREF)

- [ ] **AREF-01**: All geospatial operations documented
- [ ] **AREF-02**: Request/response formats documented
- [ ] **AREF-03**: Error codes and meanings documented
- [ ] **AREF-04**: Rate limits and quotas documented
- [ ] **AREF-05**: Wire protocol documented

### Documentation - Architecture (ARCH)

- [ ] **ARCH-01**: VSR consensus protocol explained
- [ ] **ARCH-02**: LSM-tree storage engine explained
- [ ] **ARCH-03**: S2 geospatial indexing explained
- [ ] **ARCH-04**: RAM index design explained
- [ ] **ARCH-05**: Sharding architecture explained
- [ ] **ARCH-06**: Replication architecture explained
- [ ] **ARCH-07**: Data flow diagrams

### Documentation - Operations (OPS)

- [ ] **OPS-01**: Deployment guide (single node)
- [ ] **OPS-02**: Deployment guide (cluster)
- [ ] **OPS-03**: Kubernetes deployment guide
- [ ] **OPS-04**: Scaling guide (horizontal and vertical)
- [ ] **OPS-05**: Backup and restore procedures
- [ ] **OPS-06**: Disaster recovery procedures
- [ ] **OPS-07**: Upgrade procedures
- [ ] **OPS-08**: Troubleshooting guide

### Documentation - Benchmarks (BENCH)

- [ ] **BENCH-01**: Benchmark methodology documented
- [ ] **BENCH-02**: Benchmark environment documented
- [ ] **BENCH-03**: Benchmark vs PostGIS (geospatial queries)
- [ ] **BENCH-04**: Benchmark vs Redis/Tile38 (latency)
- [ ] **BENCH-05**: Benchmark vs Elasticsearch Geo (throughput)
- [ ] **BENCH-06**: Benchmark vs Aerospike (write performance)
- [ ] **BENCH-07**: Benchmark results reproducible

### Code Cleanup (CLEAN)

- [ ] **CLEAN-01**: Remove deprecated --aof flag
- [ ] **CLEAN-02**: All 181 TODO comments resolved
- [ ] **CLEAN-03**: All FIXME/XXX/HACK/BUG markers resolved
- [ ] **CLEAN-04**: REPL stub implemented or removed
- [ ] **CLEAN-05**: state_machine_tests stub implemented or removed
- [ ] **CLEAN-06**: tiering.zig placeholder implemented or removed
- [ ] **CLEAN-07**: backup_config.zig stub implemented
- [ ] **CLEAN-08**: TLS CRL/OCSP checking implemented
- [ ] **CLEAN-09**: CDC AMQP export implemented
- [ ] **CLEAN-10**: CSV import implemented

### Testing - CI (CI)

- [ ] **CI-01**: CI runs on Linux (ubuntu-latest)
- [ ] **CI-02**: CI runs on macOS (macos-latest)
- [ ] **CI-03**: VOPR fuzzer runs in CI
- [ ] **CI-04**: All unit tests pass
- [ ] **CI-05**: All integration tests pass
- [ ] **CI-06**: Test coverage report generated
- [ ] **CI-07**: Performance regression detection

### Testing - Integration (INT)

- [ ] **INT-01**: Integration tests for all geospatial operations
- [ ] **INT-02**: Integration tests for replication
- [ ] **INT-03**: Integration tests for backup/restore
- [ ] **INT-04**: Integration tests for failover
- [ ] **INT-05**: Integration tests for all SDKs
- [ ] **INT-06**: Integration tests for encryption

### Performance (PERF)

- [ ] **PERF-01**: Insert throughput benchmarked
- [ ] **PERF-02**: Radius query latency benchmarked
- [ ] **PERF-03**: Polygon query latency benchmarked
- [ ] **PERF-04**: UUID lookup latency benchmarked
- [ ] **PERF-05**: Batch query latency benchmarked
- [ ] **PERF-06**: Compaction impact on latency measured
- [ ] **PERF-07**: Bottlenecks identified and optimized
- [ ] **PERF-08**: Minimum hardware requirements documented
- [ ] **PERF-09**: Recommended hardware for different scales

## Out of Scope

| Feature | Reason |
|---------|--------|
| Windows platform support | Maintenance burden, focus on Linux/macOS |
| Mobile SDKs (iOS/Android) | Server-side database, clients use existing SDKs |
| GUI administration tool | CLI and metrics sufficient |
| Multi-tenancy isolation | Single-tenant deployments |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| (To be populated during roadmap creation) | | |

**Coverage:**
- Total requirements: 213
- Mapped to phases: 0
- Unmapped: 213

---
*Requirements defined: 2026-01-22*
*Last updated: 2026-01-22 after revision*
