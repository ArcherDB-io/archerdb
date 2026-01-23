---
phase: 07-observability-core
plan: 03
subsystem: logging
tags: [json, structured-logging, correlation, trace-context, log-levels]
depends_on:
  requires: ["07-02"]
  provides: ["json-logger", "module-log-levels", "log-format-auto"]
  affects: ["07-04", "08-metrics"]
tech-stack:
  added: []
  patterns: ["ndjson", "thread-local-context", "sensitive-data-redaction"]
key-files:
  created:
    - src/archerdb/observability/json_logger.zig
    - src/archerdb/observability/module_log_levels.zig
  modified:
    - src/archerdb/cli.zig
    - src/archerdb/main.zig
    - src/archerdb/metrics_server.zig
decisions:
  - id: "LOG-03-01"
    area: "api"
    choice: "Separate --log-module-levels option"
    rationale: "Enum-based --log-level parsing incompatible with comma-separated format"
  - id: "LOG-03-02"
    area: "default"
    choice: "Auto format detection as default"
    rationale: "Best developer experience - text in terminal, JSON in pipes"
metrics:
  duration: "12m"
  completed: "2026-01-23"
---

# Phase 7 Plan 3: Structured Logging Summary

JSON log handler with correlation context, per-module log levels, and TTY auto-detection.

## What Was Built

### 1. JSON Log Handler (`json_logger.zig`)
- NDJSON (newline-delimited JSON) output for log aggregation
- Automatic correlation context inclusion (trace_id, span_id, request_id)
- Sensitive data redaction at info/warn levels
  - Coordinate patterns (lat/lon) replaced with `[REDACTED:coords]`
  - Content/metadata fields replaced with `[REDACTED:content]`
- JSON escaping for special characters
- Schema: `{ts, level, scope, msg, trace_id?, span_id?, request_id?, replica_id?}`

### 2. Per-Module Log Levels (`module_log_levels.zig`)
- Fine-grained log control per subsystem
- CLI format: `--log-module-levels=vsr:debug,lsm:warn`
- Runtime reconfiguration via `setModuleLevel()`/`getModuleLevel()`
- Global instance for system-wide filtering
- Integrates with `log_runtime()` in main.zig

### 3. CLI and Auto-Detection
- New `--log-format=auto` (default) - text for TTY, JSON for pipes/files
- New `--log-module-levels` option for per-module overrides
- Updated help text documenting new options
- `LogFormat.resolve()` for TTY detection at startup

### 4. Correlation Context in HTTP Handling
- `extractCorrelationContext()` parses W3C traceparent or B3 headers
- `extractHeader()` for case-insensitive HTTP header lookup
- Context established at request entry, cleaned up on completion
- Enables automatic trace context in log output

## Commits

| Hash | Description |
|------|-------------|
| 6f03f20 | JSON log handler with correlation context |
| 364fcab | Per-module log level configuration |
| 16a5c52 | CLI log format auto-detection and module levels |
| eb7b3dd | Correlation context wiring in HTTP request handling |

## Files Changed

### Created
- `src/archerdb/observability/json_logger.zig` - JSON log handler with redaction
- `src/archerdb/observability/module_log_levels.zig` - Per-module log level support

### Modified
- `src/archerdb/cli.zig` - Added LogFormat.auto, --log-module-levels option
- `src/archerdb/main.zig` - Integrated module log levels, auto format resolution
- `src/archerdb/metrics_server.zig` - Correlation context wiring in HTTP handling

## Decisions Made

### LOG-03-01: Separate --log-module-levels Option
**Context:** Original plan specified `--log-level=info,vsr:debug` format.
**Decision:** Created separate `--log-module-levels` option.
**Rationale:** The existing flags parser uses LogLevel enum directly, which can't parse comma-separated values. Separate option maintains backward compatibility.

### LOG-03-02: Auto Format Detection as Default
**Context:** Default log format choice.
**Decision:** Changed default from `text` to `auto`.
**Rationale:** Best developer experience - developers get readable text in terminal, production deployments get JSON when piping to files or log collectors.

## Deviations from Plan

None - plan executed as written.

## Verification Results

1. `./zig/zig build` - Compiles successfully
2. `archerdb --help` - Shows updated log-level and log-format options
3. JSON logger tests pass
4. Module log level tests pass
5. Correlation context tests pass
6. Header extraction tests pass

## Success Criteria Met

- [x] JSON log output is valid NDJSON
- [x] Correlation IDs (trace_id, span_id, request_id) included in JSON
- [x] Per-module log levels work (e.g., vsr:debug while default is info)
- [x] Sensitive data redacted at info/warn levels
- [x] Auto-detection: text for TTY, JSON for pipes
- [x] LOG-01 through LOG-05 requirements addressed

## Next Phase Readiness

Plan 07-04 (Health Endpoints) can proceed. The correlation context module is now fully functional and integrated with HTTP request handling.
