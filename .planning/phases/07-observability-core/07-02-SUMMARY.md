---
phase: 07-observability-core
plan: 02
subsystem: observability
tags: [opentelemetry, otlp, tracing, w3c-trace-context, b3, distributed-tracing]

# Dependency graph
requires:
  - phase: 07-observability-core
    plan: 01
    provides: Prometheus metrics infrastructure
provides:
  - CorrelationContext for W3C/B3 trace header parsing
  - OtlpTraceExporter for OTLP HTTP JSON export
  - CLI options for trace export configuration
  - Thread-local context propagation
affects: [07-03-health-endpoints, integration-tests, production-observability]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "W3C Trace Context parsing (traceparent header format)"
    - "B3 header propagation (64-bit and 128-bit trace IDs)"
    - "Non-blocking span export with dedicated thread"
    - "POSIX socket HTTP client (no std.http.Client)"

key-files:
  created:
    - src/archerdb/observability/correlation.zig
    - src/archerdb/observability/trace_export.zig
    - src/archerdb/observability.zig
  modified:
    - src/archerdb/cli.zig

key-decisions:
  - "POSIX sockets for HTTP POST (consistent with metrics_server.zig pattern)"
  - "Drop spans on export failure (no retry per RESEARCH.md anti-patterns)"
  - "Default 5-second flush interval with 100-span batch size"
  - "Thread-local storage for correlation context propagation"
  - "Mutex-protected buffer for thread-safe span recording"

patterns-established:
  - "observability module structure (correlation + trace_export sub-modules)"
  - "CLI experimental flag gating for new observability options"

# Metrics
duration: 8min
completed: 2026-01-23
---

# Phase 07 Plan 02: Trace Export Summary

**OTLP trace exporter with W3C/B3 context propagation for distributed tracing to Jaeger/Tempo collectors**

## Performance

- **Duration:** 8 min
- **Started:** 2026-01-23T02:15:57Z
- **Completed:** 2026-01-23T02:23:29Z
- **Tasks:** 3
- **Files modified:** 4

## Accomplishments
- Implemented W3C Trace Context parsing (traceparent header) with full validation
- Implemented B3 header parsing with 64-bit to 128-bit trace ID padding
- Created OtlpTraceExporter with non-blocking async export via dedicated thread
- Added CLI options --trace-export and --otlp-endpoint for collector configuration
- 43 tests passing for correlation context and trace export modules

## Task Commits

Each task was committed atomically:

1. **Task 1: Create correlation context module** - `4c71651` (feat)
2. **Task 2: Create OTLP trace exporter** - `e5adb52` (feat)
3. **Task 3: Add CLI option and integrate with tracer** - `380af67` (feat)

## Files Created/Modified
- `src/archerdb/observability/correlation.zig` - W3C/B3 trace context parsing and thread-local storage
- `src/archerdb/observability/trace_export.zig` - OTLP JSON exporter with async buffer flush
- `src/archerdb/observability.zig` - Module root with convenience re-exports
- `src/archerdb/cli.zig` - Added --trace-export and --otlp-endpoint options

## Decisions Made
- Used POSIX sockets for HTTP POST rather than std.http.Client (consistent with existing metrics_server.zig)
- Drop spans on export failure with no retry (per RESEARCH.md - observability should not affect reliability)
- Default flush interval of 5 seconds with 100-span batch size for reasonable latency/efficiency balance
- Thread-local storage for correlation context allows request-scoped propagation without explicit passing
- Mutex protection on span buffer enables safe concurrent recording from multiple threads

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - implementation proceeded smoothly.

## User Setup Required

None - no external service configuration required. OTLP export is optional and disabled by default.

To enable trace export:
```bash
archerdb start --experimental --trace-export=otlp --otlp-endpoint=http://localhost:4318/v1/traces ...
```

## Next Phase Readiness
- Correlation context ready for integration with request handling
- OTLP exporter can be wired up to tracer.stop() when spans complete
- Health endpoints (07-03) can use correlation context for request tracing
- Ready for Jaeger/Tempo integration testing

---
*Phase: 07-observability-core*
*Completed: 2026-01-23*
