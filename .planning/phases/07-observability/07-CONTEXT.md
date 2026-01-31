# Phase 7: Observability - Context

**Gathered:** 2026-01-31
**Status:** Ready for planning

<domain>
## Phase Boundary

Comprehensive monitoring, alerting, and debugging capabilities for operators. Includes Prometheus metrics endpoint, Grafana dashboard, alerting rules, and structured logging with trace IDs. This phase enables operators to observe cluster health, diagnose issues, and respond to alerts.

</domain>

<decisions>
## Implementation Decisions

### Metrics Design
- Comprehensive metrics (~100+) covering internals: compaction, WAL, replication lag, cache hits
- Standard histogram buckets for latency: 1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s
- Client type labels (sdk_java, sdk_node, http) not individual client_id — balanced cardinality

### Dashboard Layout
- Single overview dashboard with all key metrics (not hierarchical or role-based)
- Default time range: last 1 hour
- Cluster state shown as green/yellow/red status indicators per node
- Throughput and latency combined on dual Y-axis panel (throughput bars + latency lines)

### Alert Thresholds
- Three severity levels: Info, Warning, Critical
- Aggressive latency thresholds: Warning at P99 > 25ms, Critical at P99 > 100ms
- Disk space alerts: both percentage-based (80%/90%) AND time-based projection (<24h to full)
- Each alert includes embedded runbook link to relevant troubleshooting section

### Log Structure
- JSON structured format (machine-parseable for log aggregators)
- Default level Info with runtime toggle to Debug without restart
- Trace IDs: 12-16 char alphanumeric short IDs (easier to copy/communicate)
- Rich context per entry: timestamp, level, message, trace_id, node_id, component, client_type, operation, duration_ms

### Claude's Discretion
- Metric naming convention (Prometheus vs OpenTelemetry semantic conventions)
- Specific metric list within "comprehensive" scope
- Dashboard panel arrangement and sizing
- Exact runbook link format and documentation structure

</decisions>

<specifics>
## Specific Ideas

- Latency thresholds are aggressive (25ms/100ms) because Phase 5 showed P99 around 1ms — want to catch regressions early
- Dual Y-axis for throughput/latency correlation at a glance
- Short trace IDs for easier verbal communication during incident response

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 07-observability*
*Context gathered: 2026-01-31*
