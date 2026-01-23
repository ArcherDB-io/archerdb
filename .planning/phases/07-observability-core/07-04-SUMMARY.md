---
phase: 07-observability-core
plan: 04
subsystem: observability
tags: [health, kubernetes, metrics, endpoints]
depends:
  requires: [07-01]
  provides: [health-detailed-endpoint, health-ready-semantics, health-live-semantics]
  affects: [kubernetes-deployment, operator-dashboards]
tech-stack:
  added: []
  patterns: [component-health-checks, http-status-codes, kubernetes-probes]
key-files:
  created: []
  modified:
    - src/archerdb/metrics_server.zig
    - src/archerdb/main.zig
decisions:
  - id: HEALTH-01
    choice: "Component health checks: replica, memory, storage, replication"
    why: "Core subsystems that affect service availability"
  - id: HEALTH-02
    choice: "HTTP 429 for degraded, 503 for unhealthy"
    why: "Per CONTEXT.md requirement for status code semantics"
  - id: HEALTH-03
    choice: "16GB default memory limit for percentage calculation"
    why: "Reasonable default; production should use cgroup limits"
metrics:
  duration: "7 min"
  completed: "2026-01-23"
---

# Phase 7 Plan 04: Health Endpoints Summary

Extended health endpoints with Kubernetes-compatible semantics and component-level health breakdown.

## One-liner

/health/detailed with replica/memory/storage/replication checks, proper 200/429/503 status codes

## What Was Done

### Task 1: Add /health/detailed endpoint (7f6891a)

Added comprehensive health endpoint with component breakdown:

1. **Health types and structures:**
   - `HealthStatus` enum: healthy, degraded, unhealthy
   - `CheckStatus` enum: pass, warn, fail
   - `ComponentCheck` struct: name, status, message, duration_ms

2. **Component health checks:**
   - **Replica:** Pass if ready, fail otherwise with reason
   - **Memory:** Pass <90%, warn 90-95%, fail >95% of limit
   - **Storage:** Fail if >10 new write errors since last check
   - **Replication:** Pass <30s lag, warn 30-60s, fail >60s (only if active)

3. **Overall status aggregation:**
   - All pass -> healthy (200)
   - Any warn, no fail -> degraded (429)
   - Any fail -> unhealthy (503)

4. **JSON response format:**
```json
{
  "status": "healthy",
  "uptime_seconds": 3600,
  "version": "0.0.1",
  "commit_hash": "abc123",
  "checks": [
    {"name": "replica", "status": "pass"},
    {"name": "memory", "status": "pass"},
    {"name": "storage", "status": "pass"},
    {"name": "replication", "status": "pass"}
  ]
}
```

### Task 2: Enhance existing health endpoints (7f6891a)

Updated /health/live and /health/ready per CONTEXT.md requirements:

1. **Server initialization tracking:**
   - `server_start_time_ns` for uptime calculation
   - `server_initialized` flag (false until markInitialized() called)
   - `setStartTime()` and `markInitialized()` public APIs

2. **/health/live changes:**
   - Always returns 200 (liveness probe semantics)
   - Never checks external dependencies
   - Response includes uptime_seconds, version, commit_hash

3. **/health/ready changes:**
   - Returns 503 until server_initialized == true
   - Then checks replica_state.isReady()
   - Response includes reason, uptime_seconds, version, commit_hash

4. **HTTP status codes added:**
   - 429 Too Many Requests (for degraded health)

### Task 3: Add health endpoint tests (8cbab3b)

Comprehensive test coverage for health endpoint behavior:

- `getUptimeSeconds` calculation and edge cases
- `setStartTime` and `markInitialized` APIs
- `HealthStatus` and `CheckStatus` toString methods
- `ComponentCheck` struct initialization
- `getBuildVersion`/`getBuildCommit` from registry
- Replica state effects on ready status
- Overall status aggregation logic
- `HttpStatus` includes 429 for degraded

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed missing .auto case in log_runtime switch (69971df)**

- **Found during:** Verification phase
- **Issue:** Plan 07-03 introduced LogFormat.auto enum variant but didn't update the switch statement in main.zig:log_runtime()
- **Fix:** Added .auto case that falls back to log_text (auto should be resolved at startup)
- **Files modified:** src/archerdb/main.zig
- **Commit:** 69971df

## Commits

| Hash | Type | Description |
|------|------|-------------|
| 7f6891a | feat | Add /health/detailed and enhance health endpoints |
| 8cbab3b | test | Add health endpoint tests |
| 69971df | fix | Handle auto log format in runtime switch |

## Verification

All verification criteria met:

1. `./zig/zig build` compiles successfully
2. `./zig/zig build test:unit -- --test-filter "metrics_server"` passes (18 tests)
3. Health endpoints verified:
   - /health/live always returns 200 with uptime
   - /health/ready returns 503 until initialized
   - /health/detailed returns component breakdown
4. JSON responses include uptime_seconds, version, commit_hash

## Files Changed

**src/archerdb/metrics_server.zig:**
- Added HealthStatus, CheckStatus, ComponentCheck types
- Added server_start_time_ns, server_initialized, last_write_errors tracking
- Added setStartTime(), markInitialized(), isInitialized(), getUptimeSeconds(), getBuildVersion(), getBuildCommit() functions
- Added handleHealthDetailed() handler with component checks
- Updated handleHealthLive() to always return 200 with metadata
- Updated handleHealthReady() to check server_initialized first
- Added HttpStatus.too_many_requests (429)
- Added 18 new tests for health endpoint behavior

**src/archerdb/main.zig:**
- Added .auto case to log_format_runtime switch (bugfix from 07-03)

## Requirements Addressed

| ID | Requirement | Status |
|----|-------------|--------|
| HEALTH-01 | /health returns overall system health | COMPLETE |
| HEALTH-02 | /ready returns 503 until initialized | COMPLETE |
| HEALTH-03 | /live always returns 200 | COMPLETE |
| HEALTH-04 | /health/detailed component breakdown | COMPLETE |
| HEALTH-05 | Responses include uptime, version, commit | COMPLETE |

## Next Steps

Plan 07-04 complete. All Phase 7 Observability Core plans now complete:
- 07-01: Prometheus Metrics
- 07-02: Distributed Tracing
- 07-03: Structured Logging
- 07-04: Health Endpoints

Ready for Phase 8 or UAT verification.
