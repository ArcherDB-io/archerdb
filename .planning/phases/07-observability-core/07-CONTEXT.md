# Phase 7: Observability Core - Context

**Gathered:** 2026-01-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Full observability stack for production operations — comprehensive metrics, distributed tracing, structured logging, and health endpoints. Operators can monitor ArcherDB performance, trace requests end-to-end, correlate logs, and integrate with Kubernetes health checks.

</domain>

<decisions>
## Implementation Decisions

### Metrics Design
- `archerdb_` prefix for all metrics (e.g., `archerdb_query_latency_seconds`)
- Rich labels: operation, status, replica_id, shard_id (higher cardinality acceptable)
- Separate metrics for internal operations: `archerdb_compaction_*`, `archerdb_checkpoint_*`, `archerdb_vsr_*`
- Full process metrics: memory, disk, CPU, thread count, GC stats
- Replication metrics with full breakdown: lag, bytes_pending, last_sync_timestamp per target
- Build info metric: `archerdb_build_info{version="x.y.z", commit="abc123"} = 1`
- Endpoint: `/metrics` with content negotiation for Prometheus or OpenMetrics format

### Tracing Scope
- Trace everything: client operations, internal ops (compaction, checkpoint, replication, VSR), and low-level (S2 lookups, LSM reads, network I/O)
- 100% sampling — every operation traced (full visibility)
- Export protocols: OTLP (gRPC/HTTP) and Jaeger Thrift
- Context propagation: support both W3C Trace Context and B3, auto-detect incoming format
- Spans include full parameters: coordinates, radius, entity IDs
- Detailed span events: cache hit/miss, LSM level accessed, S2 cell computed
- Cross-service linking: continue SDK span if present, else create root span
- Baggage propagation supported for user-defined metadata

### Log Structure
- Output format configurable: `--log-format=json|text`
- Default to human-readable text for TTY, JSON for files/pipes
- Per-module log levels: global default + component overrides (e.g., `--log-level=vsr:debug`)
- Full correlation context in every log line: request_id, trace_id, span_id, replica_id
- Sensitive data handling: redacted at info/warn, full data visible at debug level

### Health Endpoints
- Extended structure: `/health` (overall), `/ready` (can serve), `/live` (process alive), `/health/detailed` (component breakdown)
- Detailed status codes: 200 healthy, 429 degraded, 503 unhealthy + JSON body with component status
- Check all dependencies: disk, memory, S3, peer replicas
- Configurable timeout: default 3s, `--health-timeout` flag
- Port: configurable, default same as service, `--admin-port` for separate
- No authentication on observability endpoints (rely on network isolation)
- Startup behavior: both `/live` and `/ready` return 503 until fully initialized
- Response includes: uptime_seconds, version, commit_hash

### Claude's Discretion
- Histogram bucket boundaries for latency metrics
- Exact span attribute names and types
- JSON log schema field ordering
- Component health check implementation details

</decisions>

<specifics>
## Specific Ideas

- "Full visibility" philosophy — 100% tracing, rich labels, detailed events
- Enterprise-grade observability without compromises on data granularity
- Kubernetes-native health checks with proper startup/readiness/liveness semantics
- Correlation IDs flowing through all systems (logs, traces, metrics labels)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 07-observability-core*
*Context gathered: 2026-01-23*
