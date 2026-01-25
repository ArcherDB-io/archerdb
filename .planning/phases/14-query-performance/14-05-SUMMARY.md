---
phase: 14
plan: 05
subsystem: prepared-queries
tags: [prepared-statements, session-management, query-optimization, dashboard]
requires:
  - 14-03 # Query latency metrics for observability
provides:
  - prepared_queries: session-scoped prepared query storage
  - execute_prepared: parameter substitution without parse phase
  - deallocate_prepared: session cleanup
affects:
  - future dashboard clients can use prepared queries for repeated patterns
tech-stack:
  added: []
  patterns:
    - session-scoped-lifecycle
    - query-compilation
    - parameter-substitution
key-files:
  created:
    - src/prepared_queries.zig
  modified:
    - src/archerdb.zig
    - src/geo_state_machine.zig
decisions:
  - "Session-scoped lifecycle: prepared queries deallocate when client session ends"
  - "Maximum 32 prepared queries per session to limit memory usage"
  - "Parameter types validated at prepare time for early error detection"
  - "Execution statistics track average latency per prepared query"
metrics:
  duration: "~8 minutes"
  completed: "2026-01-24"
---

# Phase 14 Plan 05: Prepared Query Compilation Summary

Session-scoped prepared query compilation for dashboard workloads with PostgreSQL-like semantics.

## One-liner

Prepared queries with session-scoped lifecycle: compile once, execute many times with parameter substitution, deallocate on session end.

## What Was Built

### 1. Prepared Queries Module (`src/prepared_queries.zig`)

Core prepared query infrastructure:

- **CompiledQuery**: Pre-parsed query representation with filter template and parameter slots
- **PreparedQuery**: Named compiled query with execution statistics (count, total duration)
- **SessionPreparedQueries**: Per-client session storage (max 32 queries per session)
- **PreparedQueryMetrics**: Prometheus metrics for compiles, executions, errors

Supported query types:
- UUID lookup (`UUID $1`)
- Radius search (`RADIUS $1 $2 $3 LIMIT $4`)
- Latest events (`LATEST LIMIT $1 GROUP $2`)

### 2. Wire Format Types (`src/archerdb.zig`)

New operation types:
- `prepare_query` (op 34): Compile and store prepared query
- `execute_prepared` (op 35): Execute with parameter substitution
- `deallocate_prepared` (op 36): Remove prepared query from session

Request/Response types:
- `PrepareQueryRequest`: name_len, query_len + variable-length name and query text
- `PrepareQueryResult`: slot number (or error status)
- `ExecutePreparedRequest`: slot, param_count + variable-length params
- `DeallocatePreparedRequest`: slot or name_hash for targeted deallocation
- `DeallocatePreparedResult`: deallocated flag

### 3. State Machine Integration (`src/geo_state_machine.zig`)

Session management:
- `session_prepared_queries`: AutoHashMap(u128, SessionPreparedQueries) keyed by client ID
- `getOrCreateSession()`: Lazy session creation on first prepare

Execute functions:
- `execute_prepare_query()`: Parse request, compile query, store in session
- `execute_execute_prepared()`: Apply params, dispatch to appropriate query executor
- `execute_deallocate_prepared()`: Remove by slot, name hash, or clear all

## Commits

| Hash | Type | Description |
|------|------|-------------|
| 2b30bb9 | feat | Create prepared queries module |
| df64420 | feat | Integrate prepared queries into state machine |
| 46da875 | test | Add comprehensive prepared query tests |

## Technical Decisions

### Session-Scoped Lifecycle
Following PostgreSQL semantics, prepared queries are tied to client sessions. When a session ends (via explicit deallocation or client disconnect), all prepared queries for that session are automatically deallocated.

### Parameter Validation at Prepare Time
Parameter types (entity_id, lat_nano, lon_nano, radius_mm, etc.) are validated during query compilation. This catches type mismatches early rather than at execute time.

### Execution Statistics
Each prepared query tracks:
- `execution_count`: Number of times executed
- `total_duration_ns`: Cumulative execution time
- `averageExecutionNs()`: Mean execution latency

This enables operators to identify frequently-used queries and their performance characteristics.

## Verification Results

| Check | Status |
|-------|--------|
| Build check (`./zig/zig build -j4 -Dconfig=lite check`) | PASS |
| Prepared query tests (`--test-filter "prepared"`) | PASS |
| State machine tests (`--test-filter "geo_state_machine"`) | PASS |
| Prometheus metrics present | PASS |
| Session cleanup on deallocation | PASS |

## Metrics Provided

```prometheus
# HELP archerdb_prepared_query_compiles_total Total prepared queries compiled
# TYPE archerdb_prepared_query_compiles_total counter
archerdb_prepared_query_compiles_total {count}

# HELP archerdb_prepared_query_executions_total Total prepared query executions
# TYPE archerdb_prepared_query_executions_total counter
archerdb_prepared_query_executions_total {count}

# HELP archerdb_prepared_query_errors_total Prepared query errors by type
# TYPE archerdb_prepared_query_errors_total counter
archerdb_prepared_query_errors_total{error="parse"} {count}
archerdb_prepared_query_errors_total{error="param"} {count}
archerdb_prepared_query_errors_total{error="not_found"} {count}
```

## Deviations from Plan

None - plan executed exactly as written.

## Test Coverage

14 unit tests covering:
- Basic lifecycle (prepare, execute, deallocate)
- UUID query execution with entity_id parameter
- Radius query execution with lat/lon/radius/limit parameters
- Session scope and clear operation
- Session full error (32 query limit)
- Duplicate name error detection
- Not found error handling
- Deallocate by name hash
- Find by name hash
- Average execution time calculation
- Metrics Prometheus export
- Invalid query text detection
- Parameter type sizes
- Multiple executions tracking statistics
- Latest query compilation
- Case-insensitive query type parsing
- Session isolation between clients
- Active queries gauge calculation

## Next Phase Readiness

Phase 14 Wave 2 complete. Prepared queries provide:
- Parse phase elimination for repeated query patterns
- Session-scoped lifecycle matching PostgreSQL semantics
- Execution statistics for performance monitoring
- Foundation for client SDK prepared statement support
