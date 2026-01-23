# Phase 7: Observability Core - Research

**Researched:** 2026-01-23
**Domain:** Observability (Metrics, Tracing, Logging, Health Endpoints)
**Confidence:** HIGH

## Summary

Phase 7 builds upon ArcherDB's existing observability infrastructure to complete a production-ready observability stack. The codebase already has substantial foundations: Prometheus-compatible metrics in `src/archerdb/metrics.zig` with Counter/Gauge/Histogram types, a metrics HTTP server in `src/archerdb/metrics_server.zig`, Perfetto-compatible tracing in `src/trace.zig`, and StatsD export capability. The gap analysis shows that while metric collection is well-established, the phase requires: (1) expanding OTLP/Jaeger trace export, (2) adding structured JSON logging with correlation IDs, (3) extending health endpoints, and (4) ensuring 100% trace coverage.

The standard approach for observability in systems databases follows the "three pillars" model: metrics for aggregates, traces for request flow, logging for events. For a Zig database like ArcherDB, custom implementation is necessary since there are no mature OpenTelemetry libraries for Zig. The existing trace infrastructure outputs Chrome/Perfetto-compatible JSON which can be adapted to OTLP JSON format. Context propagation (W3C Trace Context, B3) requires parsing incoming headers and injecting trace context into all log entries.

Key decisions from CONTEXT.md are already locked: `archerdb_` metric prefix, 100% trace sampling, OTLP (gRPC/HTTP) and Jaeger Thrift export, W3C Trace Context + B3 propagation, configurable JSON/text log format, per-module log levels, and Kubernetes-style health endpoints returning 200/429/503.

**Primary recommendation:** Extend existing infrastructure rather than rewrite. Add OTLP JSON export adapter for traces, wrap std.log with JSON formatter and correlation ID injection, and enhance metrics_server.zig with additional health endpoints.

## Standard Stack

The established tools for this domain:

### Core (Existing in Codebase)
| Component | Location | Purpose | Status |
|-----------|----------|---------|--------|
| Counter/Gauge/Histogram | `src/archerdb/metrics.zig` | Prometheus metrics primitives | Complete |
| Registry.format() | `src/archerdb/metrics.zig` | Prometheus text exposition | Complete |
| MetricsServer | `src/archerdb/metrics_server.zig` | HTTP /metrics, /health endpoints | Needs extension |
| Tracer | `src/trace.zig` | Perfetto/Chrome tracing JSON | Needs OTLP adapter |
| StatsD | `src/trace/statsd.zig` | UDP metric export | Complete |
| Event types | `src/trace/event.zig` | Trace event definitions | Complete |

### Required Extensions
| Extension | Purpose | Integration Point |
|-----------|---------|-------------------|
| OTLP Trace Exporter | Export traces to Jaeger/collectors | Add to `src/trace.zig` |
| JSON Log Formatter | Structured logging output | Replace std.log handler |
| Correlation Context | Request/trace ID threading | Add to request handling |
| Extended Health | /ready, /live, /health/detailed | Extend `metrics_server.zig` |

### Protocol Specifications
| Protocol | Version | Purpose | Source |
|----------|---------|---------|--------|
| [Prometheus Exposition Format](https://prometheus.io/docs/instrumenting/exposition_formats/) | 0.0.4 | Metric text format | Already implemented |
| [OpenMetrics](https://prometheus.io/docs/specs/om/open_metrics_spec/) | 1.0 | Enhanced metric format | Content negotiation |
| [OTLP](https://opentelemetry.io/docs/specs/otlp/) | 1.x | Trace/metric transport | gRPC:4317, HTTP:4318 |
| [W3C Trace Context](https://www.w3.org/TR/trace-context/) | 1.0 | traceparent/tracestate headers | Context propagation |
| [B3 Propagation](https://github.com/openzipkin/b3-propagation) | - | Zipkin-style headers | Legacy compatibility |
| [Jaeger Thrift](https://github.com/jaegertracing/jaeger-idl/blob/master/thrift/jaeger.thrift) | - | Legacy trace format | Backward compat |

### Alternatives Considered
| Standard Choice | Alternative | Why Standard |
|----------------|-------------|--------------|
| OTLP JSON over HTTP | OTLP gRPC (protobuf) | HTTP/JSON simpler in Zig, no protobuf dep |
| Custom trace export | OpenTelemetry SDK | No mature Zig OTel SDK exists |
| std.log wrapper | External logging lib | Minimal dependencies, control |
| In-process health checks | External health agent | Lower latency, direct access |

## Architecture Patterns

### Recommended Project Structure
```
src/
├── archerdb/
│   ├── metrics.zig           # [EXISTS] Metric types and registry
│   ├── metrics_server.zig    # [EXISTS] HTTP server, extend for health
│   └── observability/
│       ├── trace_export.zig  # [NEW] OTLP/Jaeger trace exporters
│       ├── json_logger.zig   # [NEW] Structured JSON log handler
│       └── correlation.zig   # [NEW] Request/trace context
├── trace.zig                 # [EXISTS] Core tracer
├── trace/
│   ├── event.zig             # [EXISTS] Event definitions
│   └── statsd.zig            # [EXISTS] StatsD export
```

### Pattern 1: Correlation ID Threading
**What:** Every operation carries request_id, trace_id, span_id through call stack
**When to use:** All client-initiated operations
**Example:**
```zig
// Source: CONTEXT.md requirement for full correlation context
pub const CorrelationContext = struct {
    request_id: u128,      // Client request identifier
    trace_id: [32]u8,      // W3C trace ID (hex)
    span_id: [16]u8,       // Current span ID (hex)
    replica_id: u8,        // This replica's index

    pub fn fromHeaders(headers: anytype) ?CorrelationContext {
        // Parse W3C traceparent: version-trace_id-parent_id-flags
        // Or B3: X-B3-TraceId, X-B3-SpanId
        // ...
    }

    pub fn toLogFields(self: *const CorrelationContext, writer: anytype) !void {
        try writer.print(
            "\"request_id\":\"{x:0>32}\",\"trace_id\":\"{s}\",\"span_id\":\"{s}\",\"replica_id\":{d}",
            .{ self.request_id, self.trace_id, self.span_id, self.replica_id }
        );
    }
};
```

### Pattern 2: OTLP JSON Trace Export
**What:** Convert existing Perfetto-format traces to OTLP JSON
**When to use:** Exporting to Jaeger, OpenTelemetry Collector
**Example:**
```zig
// Source: https://opentelemetry.io/docs/specs/otlp/ (JSON encoding)
pub const OtlpTraceExporter = struct {
    endpoint: []const u8,  // e.g., "http://localhost:4318/v1/traces"

    pub fn exportSpan(self: *OtlpTraceExporter, span: Span) !void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        // OTLP JSON format - trace_id/span_id as lowercase hex (not base64)
        try w.print(
            \\{{"resourceSpans":[{{"resource":{{"attributes":[
            \\{{"key":"service.name","value":{{"stringValue":"archerdb"}}}}
            \\]}},"scopeSpans":[{{"spans":[{{
            \\"traceId":"{s}","spanId":"{s}","name":"{s}",
            \\"startTimeUnixNano":{d},"endTimeUnixNano":{d},
            \\"attributes":[{s}]
            \\}}]}}]}}]}}
        , .{
            span.trace_id,
            span.span_id,
            span.name,
            span.start_time_ns,
            span.end_time_ns,
            span.attributes_json,
        });

        // HTTP POST to collector
        // ...
    }
};
```

### Pattern 3: JSON Log Formatter
**What:** Override std.log to emit structured JSON
**When to use:** When `--log-format=json` specified
**Example:**
```zig
// Source: https://github.com/softprops/zig-jsonlog pattern
pub const JsonLogHandler = struct {
    correlation: ?*const CorrelationContext,

    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @Type(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const level_str = switch (level) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
        };

        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        w.print("{{\"ts\":{d},\"level\":\"{s}\",\"scope\":\"{s}\",", .{
            std.time.timestamp(),
            level_str,
            @tagName(scope),
        }) catch return;

        // Add correlation context if present
        if (correlation) |ctx| {
            ctx.toLogFields(w) catch return;
            w.writeByte(',') catch return;
        }

        // Message with args
        w.writeAll("\"msg\":\"") catch return;
        std.fmt.format(w, format, args) catch return;
        w.writeAll("\"}\n") catch return;

        std.io.getStdErr().writeAll(fbs.getWritten()) catch {};
    }
};
```

### Pattern 4: Health Endpoint Response
**What:** Kubernetes probe responses with component status
**When to use:** All health endpoints
**Example:**
```zig
// Source: https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/
pub const HealthResponse = struct {
    status: enum { healthy, degraded, unhealthy },
    checks: []const ComponentCheck,
    uptime_seconds: u64,
    version: []const u8,
    commit_hash: []const u8,

    pub const ComponentCheck = struct {
        name: []const u8,       // "replica", "storage", "s3"
        status: enum { pass, warn, fail },
        message: ?[]const u8,
    };

    pub fn httpStatus(self: *const HealthResponse) HttpStatus {
        return switch (self.status) {
            .healthy => .ok,           // 200
            .degraded => .too_many_requests,  // 429
            .unhealthy => .service_unavailable,  // 503
        };
    }

    pub fn toJson(self: *const HealthResponse, writer: anytype) !void {
        try writer.print(
            \\{{"status":"{s}","uptime_seconds":{d},"version":"{s}","commit":"{s}","checks":[
        , .{
            @tagName(self.status),
            self.uptime_seconds,
            self.version,
            self.commit_hash,
        });
        // ... format checks array
    }
};
```

### Anti-Patterns to Avoid
- **High-cardinality labels:** Don't include entity_id or request_id as metric labels. Use trace attributes instead.
- **Blocking trace export:** Export traces asynchronously. Don't block request path on collector availability.
- **Log sampling in code:** Sample at collection time (fluentd/vector), not in application. 100% logging at debug level.
- **Health checks with side effects:** Health endpoints must be read-only, never mutate state.
- **Polling for metrics:** Never poll internal state. Use atomic increments and read-on-scrape.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Prometheus text format | Custom text generation | Existing `Counter.format()` in metrics.zig | Already correct, tested |
| Histogram percentiles | Manual bucket math | `histogram_quantile()` in Prometheus | Prometheus does interpolation server-side |
| Trace ID generation | `std.crypto.random` | UUID v4 or existing trace context | Need proper 128-bit trace IDs |
| HTTP health server | New TCP handler | Existing `MetricsServer` in metrics_server.zig | Already handles connections |
| Atomic counters | Mutex-protected integers | `std.atomic.Value(u64)` (already used) | Lock-free, cache-friendly |
| Log rotation | Custom file handling | `--log-rotate-size` CLI (planned) | OS-level handling better |

**Key insight:** ArcherDB's metrics infrastructure is production-quality. The work is extending and connecting, not rebuilding.

## Common Pitfalls

### Pitfall 1: Trace Context Corruption
**What goes wrong:** Lost or garbled trace IDs when propagating through VSR
**Why it happens:** Binary protocols don't preserve string context
**How to avoid:** Store trace context in request metadata, not message body. Use fixed-size binary trace IDs (16 bytes), convert to hex only for export.
**Warning signs:** Orphaned spans in Jaeger, missing parent relationships

### Pitfall 2: Histogram Bucket Explosion
**What goes wrong:** Out of memory from too many histogram buckets
**Why it happens:** Per-label histograms with high cardinality (e.g., per-shard latency)
**How to avoid:** Limit labels to low-cardinality dimensions. Max ~10 label combinations per histogram.
**Warning signs:** /metrics endpoint slow (>1s), metrics buffer overflow

### Pitfall 3: Log Volume in Production
**What goes wrong:** Disk fills, I/O contention from excessive logging
**Why it happens:** Debug logging left enabled, no per-module filtering
**How to avoid:** Default to `--log-level=info`. Implement `--log-level=vsr:debug` style overrides.
**Warning signs:** Disk I/O metrics spike, log rotation thrashing

### Pitfall 4: Health Check Cascading Failures
**What goes wrong:** Kubernetes restarts all replicas simultaneously
**Why it happens:** Health checks depend on cluster state, quorum lost triggers unhealthy
**How to avoid:** /live should NEVER check external dependencies. Only /ready checks cluster.
**Warning signs:** All pods restart together, CrashLoopBackoff

### Pitfall 5: Collector Unavailability Blocking Requests
**What goes wrong:** Request latency spikes when Jaeger/OTLP collector down
**Why it happens:** Synchronous trace export on request path
**How to avoid:** Buffer traces in-process, export asynchronously with timeout. Drop traces on buffer full.
**Warning signs:** Request latency correlates with collector health

### Pitfall 6: Metric Cardinality from Dynamic Labels
**What goes wrong:** Memory usage grows unbounded
**Why it happens:** Using request_id, entity_uuid as metric labels
**How to avoid:** Only static labels (operation, status, level). Dynamic data goes in traces.
**Warning signs:** Registry.format() slows down, OOM during scrape

## Code Examples

Verified patterns from existing codebase:

### Counter Usage (from metrics.zig)
```zig
// Source: /home/g/archerdb/src/archerdb/metrics.zig:330-339
pub var write_operations_total: Counter = Counter.init(
    "archerdb_write_operations_total",
    "Total write operations processed",
    null,
);

// Usage:
Registry.write_operations_total.inc();
Registry.write_operations_total.add(batch_size);
```

### Histogram for Latency (from metrics.zig)
```zig
// Source: /home/g/archerdb/src/archerdb/metrics.zig:261-277
pub const LatencyHistogram = HistogramType(9);
pub fn latencyHistogram(name: []const u8, help: []const u8, labels: ?[]const u8) LatencyHistogram {
    return LatencyHistogram.init(name, help, labels, .{
        0.0005, // 500μs
        0.001,  // 1ms
        0.005,  // 5ms
        0.01,   // 10ms
        0.05,   // 50ms
        0.1,    // 100ms
        0.5,    // 500ms
        1.0,    // 1s
        5.0,    // 5s
    });
}

// Usage - observe nanoseconds for efficiency:
Registry.write_latency.observeNs(duration_ns);
```

### Trace Event Start/Stop (from trace.zig)
```zig
// Source: /home/g/archerdb/src/trace.zig:268-356
pub fn start(tracer: *Tracer, event: Event) void {
    const event_tracing = event.as(EventTracing);
    const stack = event_tracing.stack();
    const time_now = tracer.time.monotonic();

    assert(tracer.events_started[stack] == null);
    tracer.events_started[stack] = time_now;
    // ... JSON output for Perfetto
}

pub fn stop(tracer: *Tracer, event: Event) void {
    const event_start = tracer.events_started[stack].?;
    const event_duration = event_end.duration_since(event_start);
    tracer.events_started[stack] = null;
    tracer.timing(event_timing, event_duration);
    // ... JSON output
}

// Usage:
tracer.start(.{ .replica_commit = .{ .stage = .idle, .op = 123 } });
defer tracer.stop(.{ .replica_commit = .{ .stage = .idle, .op = 456 } });
```

### Health Endpoint Handler (from metrics_server.zig)
```zig
// Source: /home/g/archerdb/src/archerdb/metrics_server.zig:448-473
fn handleHealthReady(client_fd: posix.socket_t) !void {
    const state = replica_state;

    if (state.isReady()) {
        const body = \\{"status":"ok"};
        try sendResponse(client_fd, .ok, "application/json", body);
    } else {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            "{{\"status\":\"unavailable\",\"reason\":\"{s}\"}}",
            .{state.reason()}
        ) catch "{\"status\":\"unavailable\"}";
        try sendResponse(client_fd, .service_unavailable, "application/json", body);
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Jaeger Thrift-only | OTLP preferred, Thrift deprecated | 2024 | Use OTLP for new deployments |
| Prometheus 0.0.4 | OpenMetrics 1.0/2.0 | 2020/2024 | Content negotiation, new features |
| Log files only | Structured JSON + log aggregation | 2020+ | Required for cloud-native |
| Pull-only metrics | Push gateway for batch jobs | Always | ArcherDB is long-running, pull OK |
| Separate trace/metric systems | Unified OTLP | 2023+ | Single collector endpoint |

**Deprecated/outdated:**
- **Jaeger Thrift exporter:** OpenTelemetry SDKs removed Jaeger Thrift. Use OTLP. Thrift only for legacy compatibility.
- **Summary metric type:** Prefer Histograms - aggregatable server-side, Summaries are not.
- **X-Request-ID header:** Use W3C traceparent for trace propagation. X-Request-ID for application-level correlation only.

## Open Questions

Things that couldn't be fully resolved:

1. **OTLP gRPC vs HTTP/JSON**
   - What we know: HTTP/JSON is simpler (no protobuf), gRPC is more efficient
   - What's unclear: Performance requirements for trace export throughput
   - Recommendation: Start with HTTP/JSON for simplicity, add gRPC if needed

2. **Span attribute schema**
   - What we know: CONTEXT.md says "full parameters: coordinates, radius, entity IDs"
   - What's unclear: Exact attribute names, whether to follow OTel semantic conventions
   - Recommendation: Use OTel semantic conventions where applicable, custom `archerdb.*` for geo-specific

3. **Log redaction implementation**
   - What we know: CONTEXT.md requires "redacted at info/warn, full at debug"
   - What's unclear: Which fields exactly are sensitive (coordinates? entity IDs?)
   - Recommendation: Treat entity content/metadata as sensitive, IDs as non-sensitive

4. **Metrics auth for /metrics endpoint**
   - What we know: Bearer token auth exists in metrics_server.zig
   - What's unclear: Whether health endpoints should also be protected
   - Recommendation: Keep health endpoints unauthenticated (K8s probes need access)

## Sources

### Primary (HIGH confidence)
- `/home/g/archerdb/src/archerdb/metrics.zig` - Existing metric implementation (verified)
- `/home/g/archerdb/src/archerdb/metrics_server.zig` - Existing HTTP server (verified)
- `/home/g/archerdb/src/trace.zig` - Existing tracer (verified)
- `/home/g/archerdb/src/trace/event.zig` - Event definitions (verified)
- `/home/g/archerdb/src/archerdb/cli.zig` - CLI options (verified)
- [OTLP Specification](https://opentelemetry.io/docs/specs/otlp/) - Wire format
- [Prometheus Exposition Format](https://prometheus.io/docs/instrumenting/exposition_formats/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [B3 Propagation](https://github.com/openzipkin/b3-propagation)
- [Kubernetes Health Probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)

### Secondary (MEDIUM confidence)
- [OpenMetrics Spec](https://prometheus.io/docs/specs/om/open_metrics_spec/)
- [Jaeger APIs](https://www.jaegertracing.io/docs/2.14/architecture/apis/)
- [Prometheus Histograms Guide](https://prometheus.io/docs/practices/histograms/)
- [zlog Zig logging library](https://github.com/hendriknielaender/zlog) - Pattern reference
- [zig-jsonlog](https://github.com/softprops/zig-jsonlog) - Pattern reference

### Tertiary (LOW confidence)
- Zig OpenTelemetry ecosystem search - No mature libraries found as of 2026-01

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Verified existing codebase implementation
- Architecture: HIGH - Patterns derived from existing code + official specs
- Pitfalls: MEDIUM - Based on general observability experience, some ArcherDB-specific

**Research date:** 2026-01-23
**Valid until:** 60 days (observability protocols are stable)
