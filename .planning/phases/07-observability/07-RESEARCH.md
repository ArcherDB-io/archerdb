# Phase 7: Observability - Research

**Researched:** 2026-01-31
**Domain:** Prometheus metrics, Grafana dashboards, alerting, structured logging
**Confidence:** HIGH

## Summary

Phase 7 focuses on completing the observability stack for ArcherDB. Research reveals that **substantial infrastructure already exists** in the codebase:

- **Metrics foundation**: Complete Prometheus-compatible metrics system in `src/archerdb/metrics.zig` with Counter, Gauge, Histogram types and 150+ metrics already defined
- **HTTP server**: `/metrics` endpoint at `src/archerdb/metrics_server.zig` with process metrics, caching, and bearer token auth
- **Dashboards**: 5 Grafana dashboards in `observability/grafana/dashboards/` (overview, queries, replication, storage, cluster)
- **Alerting**: Alert rules in `observability/prometheus/alerts/` with storage and memory rules already defined
- **Logging**: Structured JSON logger with correlation context in `src/archerdb/observability/`
- **Tracing**: OTLP trace exporter supporting W3C and B3 trace context propagation

The primary work is **integration and enhancement**, not building from scratch. Key gaps to address:
1. Adding remaining metrics per CONTEXT.md decisions (~100+ metrics with internals)
2. Updating histogram buckets to match CONTEXT.md specification (1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s)
3. Creating unified overview dashboard with dual Y-axis and status indicators
4. Adding aggressive latency alerts (P99 > 25ms warning, > 100ms critical)
5. Adding disk space projection alerts (<24h to full)
6. Ensuring short trace IDs (12-16 char) in log output

**Primary recommendation:** Extend existing infrastructure rather than building new systems. Focus on metric completeness, dashboard consolidation, and alert threshold tuning per CONTEXT.md decisions.

## Standard Stack

The established libraries/tools for this domain:

### Core (Already Implemented)
| Component | Location | Purpose | Status |
|-----------|----------|---------|--------|
| Prometheus metrics | `src/archerdb/metrics.zig` | Counter/Gauge/Histogram primitives | Complete |
| Metrics HTTP server | `src/archerdb/metrics_server.zig` | `/metrics` endpoint, `/health/*` endpoints | Complete |
| JSON logger | `src/archerdb/observability/json_logger.zig` | Structured NDJSON logs with redaction | Complete |
| Correlation context | `src/archerdb/observability/correlation.zig` | W3C/B3 trace context propagation | Complete |
| OTLP exporter | `src/archerdb/observability/trace_export.zig` | Trace export to Jaeger/Tempo | Complete |

### Supporting (External)
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| Prometheus | 2.x+ | Metric scraping and storage | Production monitoring |
| Grafana | 9.x+ | Dashboard visualization | Operator dashboards |
| Alertmanager | 0.25.x+ | Alert routing and notification | Production alerting |
| Jaeger/Tempo | Current | Distributed trace collection | Request debugging |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Native Prometheus format | OpenMetrics | OpenMetrics is Prometheus-compatible; native format works |
| Custom JSON logs | OpenTelemetry Logs | Custom format provides tighter control over schema |
| OTLP HTTP | OTLP gRPC | HTTP is simpler, gRPC has better performance for high volume |

**No installation needed** - ArcherDB implements metrics natively in Zig. External tools (Prometheus, Grafana) are operator-provided.

## Architecture Patterns

### Existing Project Structure
```
src/archerdb/
├── metrics.zig              # Core primitives + Registry
├── metrics_server.zig       # HTTP server for /metrics
├── storage_metrics.zig      # LSM/compaction metrics
├── index_metrics.zig        # RAM index metrics
├── query_metrics.zig        # Query latency breakdown
├── cluster_metrics.zig      # Connection pool, load shedding
└── observability/
    ├── correlation.zig      # Trace context propagation
    ├── json_logger.zig      # Structured JSON logging
    ├── trace_export.zig     # OTLP trace exporter
    └── module_log_levels.zig

observability/
├── grafana/
│   ├── dashboards/          # 5 JSON dashboards
│   └── provisioning/
├── prometheus/
│   ├── alerts/              # storage.yml, memory.yml
│   └── rules/
└── alertmanager/
    └── templates/           # slack, pagerduty, etc.
```

### Pattern 1: Static Metrics Registry
**What:** All metrics are statically defined in `metrics.Registry` for zero allocation at runtime.
**When to use:** Always - this is the existing pattern. Add new metrics to the Registry.
**Example:**
```zig
// Source: src/archerdb/metrics.zig
pub const Registry = struct {
    pub var write_latency: LatencyHistogram = latencyHistogram(
        "archerdb_write_latency_seconds",
        "Write operation latency histogram",
        null,
    );
    // Add new metrics here following same pattern
};
```

### Pattern 2: Prometheus Text Format Output
**What:** Metrics are formatted on-demand via `Registry.format(writer)` when `/metrics` is scraped.
**When to use:** The metrics server handles this automatically. No changes needed.
**Example:**
```zig
// Source: src/archerdb/metrics_server.zig
fn handleMetrics(client_fd: posix.socket_t) !void {
    metrics.Registry.format(writer) catch |err| {...};
}
```

### Pattern 3: Correlation Context Thread-Local
**What:** Trace context is stored in thread-local storage and accessed via `correlation.getCurrent()`.
**When to use:** Any code that logs or records spans can access trace context.
**Example:**
```zig
// Source: src/archerdb/observability/correlation.zig
if (correlation.getCurrent()) |ctx| {
    const trace_hex = ctx.traceIdHex();
    // Include in log output
}
```

### Anti-Patterns to Avoid
- **Dynamic metric names:** Never generate metric names programmatically. Use labels instead.
- **Unbounded labels:** Never use entity_id, user_id, or client_id as labels (cardinality explosion).
- **Blocking on export:** Trace export is async. Never block request processing waiting for export.
- **Retries on export failure:** Per existing trace_export.zig: drops spans on failure to protect production reliability.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Histogram buckets | Custom bucket logic | `HistogramType(N)` | Already handles cumulative buckets, percentiles, Prometheus format |
| Trace ID generation | Custom random IDs | `correlation.CorrelationContext.newRoot()` | Handles W3C format, sampled flag, proper entropy |
| Process metrics | Manual /proc parsing | `collectProcessMetrics()` | Already reads VmRSS, CPU time, open FDs on Linux/Darwin |
| JSON escaping | Manual string escaping | `json_logger.escapeJsonToWriter()` | Handles all special chars, unicode, control chars |
| Metric caching | Custom TTL logic | `MetricsCache` | Already caches /metrics response for 1 second |

**Key insight:** The observability infrastructure is mature. Extend it, don't replace it.

## Common Pitfalls

### Pitfall 1: Cardinality Explosion
**What goes wrong:** Adding unbounded label values (user_id, request_id) creates millions of time series.
**Why it happens:** Prometheus creates a new time series for each unique label combination.
**How to avoid:** Per CONTEXT.md: use client_type labels (sdk_java, sdk_node, http) not individual client_id.
**Warning signs:** Prometheus memory growing, slow queries, high scrape durations.

### Pitfall 2: Histogram Bucket Mismatch
**What goes wrong:** Default buckets (0.5ms, 1ms, 5ms...) don't match expected latency distribution.
**Why it happens:** Phase 5 showed P99 around 1ms. Need finer granularity at low end.
**How to avoid:** Use CONTEXT.md buckets: 1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s.
**Warning signs:** All observations in first or last bucket, no distribution visibility.

### Pitfall 3: Missing Trace Context
**What goes wrong:** Logs from different components can't be correlated to same request.
**Why it happens:** Trace context not propagated through all code paths.
**How to avoid:** Call `correlation.setCurrent(&ctx)` at request start, `setCurrent(null)` at end. Use defer.
**Warning signs:** Log aggregator shows disjoint log entries with no trace_id.

### Pitfall 4: Alert Fatigue
**What goes wrong:** Too many alerts, operators start ignoring them.
**Why it happens:** Thresholds too sensitive, alerts fire for transient conditions.
**How to avoid:** Per CONTEXT.md: three severity levels (Info, Warning, Critical). Aggressive latency thresholds catch real issues early. Include runbook links.
**Warning signs:** High alert volume, slow MTTR, alert dismissal without investigation.

### Pitfall 5: Dashboard Information Overload
**What goes wrong:** Too many panels, operators can't find what matters.
**Why it happens:** Adding every metric as a panel.
**How to avoid:** Per CONTEXT.md: Single overview dashboard with key metrics. Green/yellow/red status indicators. Dual Y-axis for throughput+latency correlation.
**Warning signs:** Dashboard takes >5 seconds to load, operators create personal dashboards.

## Code Examples

Verified patterns from official sources:

### Adding a New Counter Metric
```zig
// Source: src/archerdb/metrics.zig pattern
pub var my_new_counter: Counter = Counter.init(
    "archerdb_my_operation_total",  // Always archerdb_ prefix, _total suffix for counters
    "Total my operations processed",
    null,  // or "label=\"value\"" for labeled metrics
);

// Usage:
metrics.Registry.my_new_counter.inc();  // Increment by 1
metrics.Registry.my_new_counter.add(5); // Increment by N
```

### Adding a New Histogram Metric with Custom Buckets
```zig
// Source: src/archerdb/metrics.zig pattern
// Define histogram type with bucket count
pub const CustomHistogram = HistogramType(10);

// Create histogram with CONTEXT.md buckets
pub var my_latency: CustomHistogram = CustomHistogram.init(
    "archerdb_my_latency_seconds",
    "My operation latency histogram",
    null,
    .{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 5.0 },
);

// Usage:
const start = std.time.nanoTimestamp();
// ... do work ...
const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
metrics.Registry.my_latency.observeNs(elapsed_ns);
```

### JSON Log with Trace Context
```zig
// Source: src/archerdb/observability/json_logger.zig pattern
const handler = JsonLogHandler.init(std.io.getStdErr().writer(), true);

// With correlation context set:
var ctx = correlation.CorrelationContext.newRoot(0);
correlation.setCurrent(&ctx);
defer correlation.setCurrent(null);

// Logs will automatically include trace_id, span_id
handler.log(.info, .replica, "processing request {}", .{42});
// Output: {"ts":1706000000000,"level":"info","scope":"replica","msg":"processing request 42","trace_id":"...","span_id":"..."}
```

### Prometheus Alert Rule Format
```yaml
# Source: observability/prometheus/alerts/storage.yml pattern
groups:
  - name: archerdb-latency
    rules:
      - alert: ArcherDBHighP99Latency
        expr: histogram_quantile(0.99, sum(rate(archerdb_read_latency_seconds_bucket[5m])) by (le, instance)) > 0.025
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High P99 latency on {{ $labels.instance }}"
          description: "P99 read latency is {{ $value | humanizeDuration }} (threshold: 25ms)"
          runbook_url: "https://docs.archerdb.io/runbooks/high-latency"
          remediation: "Check cache hit ratio, compaction status, disk I/O"
```

### Grafana Panel JSON Structure
```json
// Source: observability/grafana/dashboards/archerdb-overview.json pattern
{
  "title": "Throughput & Latency",
  "type": "timeseries",
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "targets": [
    {
      "expr": "sum(rate(archerdb_read_operations_total{instance=~\"$instance\"}[5m]))",
      "legendFormat": "Read ops/s"
    },
    {
      "expr": "histogram_quantile(0.99, sum(rate(archerdb_read_latency_seconds_bucket{instance=~\"$instance\"}[5m])) by (le))",
      "legendFormat": "P99 latency"
    }
  ],
  "fieldConfig": {
    "overrides": [
      {"matcher": {"id": "byName", "options": "P99 latency"}, "properties": [{"id": "custom.axisPlacement", "value": "right"}]}
    ]
  }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| StatsD push model | Prometheus pull model | 2016+ | Standard for cloud-native |
| Custom log formats | Structured JSON (NDJSON) | 2019+ | Log aggregation compatibility |
| Application-specific IDs | W3C Trace Context | 2020+ | Cross-service tracing |
| Manual dashboards | Infrastructure as Code | 2018+ | Reproducible, version-controlled |

**Current ecosystem:**
- Prometheus is the de facto standard for metrics
- OpenTelemetry is emerging for unified observability but Prometheus remains dominant for metrics
- Grafana is the standard for dashboards
- OTLP (OpenTelemetry Protocol) for trace export

**Deprecated/outdated:**
- Push-based metrics (StatsD, Graphite) - still work but pull model preferred
- Per-request trace sampling decisions - use head-based sampling at service entry

## Open Questions

Things that couldn't be fully resolved:

1. **Short Trace ID Format**
   - What we know: CONTEXT.md specifies 12-16 char alphanumeric short IDs
   - What's unclear: Current correlation.zig uses full 32-char hex trace IDs (standard W3C format)
   - Recommendation: Add a `shortTraceId()` method that returns first 12 chars of hex, or implement base62 encoding for even shorter IDs. Keep full IDs internally for interoperability.

2. **Runtime Log Level Toggle**
   - What we know: CONTEXT.md specifies "runtime toggle to Debug without restart"
   - What's unclear: Current module_log_levels.zig exists but integration path unclear
   - Recommendation: Expose log level change via `/control/log-level` HTTP endpoint (similar to existing `/control/reshard/`)

3. **Disk Space Projection Alert**
   - What we know: CONTEXT.md specifies alert when <24h to full
   - What's unclear: Requires rate calculation of disk growth, which Prometheus handles via `predict_linear()`
   - Recommendation: Use PromQL `predict_linear(node_filesystem_avail_bytes[1h], 24*3600) < 0` pattern

## Sources

### Primary (HIGH confidence)
- `/home/g/archerdb/src/archerdb/metrics.zig` - Complete metrics implementation (53K tokens)
- `/home/g/archerdb/src/archerdb/metrics_server.zig` - HTTP server with health endpoints
- `/home/g/archerdb/observability/README.md` - Existing observability stack documentation
- `/home/g/archerdb/.planning/phases/07-observability/07-CONTEXT.md` - User decisions
- [Prometheus Metric Naming](https://prometheus.io/docs/practices/naming/) - Official best practices
- [Prometheus Labels Best Practices](https://www.cncf.io/blog/2025/07/22/prometheus-labels-understanding-and-best-practices/) - CNCF guidance

### Secondary (MEDIUM confidence)
- `/home/g/archerdb/observability/prometheus/alerts/storage.yml` - Existing alert patterns
- `/home/g/archerdb/observability/grafana/dashboards/archerdb-overview.json` - Dashboard structure

### Tertiary (LOW confidence)
- None - all findings verified against codebase

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Verified against actual codebase implementation
- Architecture: HIGH - Patterns extracted from existing code
- Pitfalls: HIGH - Based on Prometheus best practices and common database monitoring patterns

**Research date:** 2026-01-31
**Valid until:** 90 days (stable domain, infrastructure already implemented)

---

## Implementation Guidance for Planner

### What Already Exists (Do NOT Recreate)
1. Prometheus metrics primitives (Counter, Gauge, Histogram)
2. Metrics HTTP server with caching and auth
3. JSON structured logger with redaction
4. W3C/B3 trace context parsing
5. OTLP trace exporter
6. 5 Grafana dashboards
7. Storage and memory alert rules

### What Needs to Be Done
1. **Metrics Completion** - Add remaining internal metrics:
   - Compaction: pending_bytes, stall_duration, level_sizes
   - WAL: sync_duration, entries_written, buffer_usage
   - Replication: lag_seconds, apply_rate, queue_depth
   - Cache: hit_ratio per cache type, eviction_rate

2. **Histogram Bucket Update** - Modify `latencyHistogram()` to use CONTEXT.md buckets:
   - Current: 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0
   - Target: 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 5.0

3. **Dashboard Consolidation** - Create unified overview per CONTEXT.md:
   - Green/yellow/red status indicators per node
   - Dual Y-axis panel (throughput bars + latency lines)
   - 1-hour default time range

4. **Alert Rules** - Add new alerts:
   - Latency: Warning P99 > 25ms, Critical P99 > 100ms
   - Disk: Both percentage (80%/90%) AND projection (<24h)
   - Runbook links in all alerts

5. **Log Enhancement** - Add short trace ID support:
   - Method to generate 12-16 char alphanumeric IDs
   - Runtime log level toggle endpoint

6. **Metric Labels** - Add client_type label to operation metrics:
   - Values: sdk_java, sdk_node, http (not individual client_id)
