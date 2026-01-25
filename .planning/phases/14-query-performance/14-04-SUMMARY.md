---
phase: 14-query-performance
plan: 04
subsystem: query-api
tags: [batch-query, dashboard, wire-format, partial-success]
depends_on:
  requires: [14-01]
  provides: [batch_query_operation, batch_query_metrics]
  affects: [15-monitoring]
tech-stack:
  added: []
  patterns: [generic-executor-pattern, partial-success-semantics]
key-files:
  created:
    - src/batch_query.zig
  modified:
    - src/archerdb.zig
    - src/geo_state_machine.zig
decisions:
  - id: batch-query-wire-format
    choice: "Variable-length request with BatchQueryRequest header + entries + filters"
    rationale: "Flexible wire format supporting mixed query types in single request"
  - id: partial-success
    choice: "DynamoDB-style partial success with per-query status"
    rationale: "Queries independent - one failure shouldn't affect others"
  - id: generic-executor
    choice: "BatchQueryExecutor parameterized by state machine type"
    rationale: "Avoids circular imports, enables testing with mock state machine"
metrics:
  duration: 13min
  completed: 2026-01-25
---

# Phase 14 Plan 04: Batch Query API Summary

Batch query API with DynamoDB-style partial success for dashboard refresh scenarios.

## Changes

### Created Files

**src/batch_query.zig** - Batch query wire format and execution
- `BatchQueryRequest` header (8 bytes): query_count, reserved
- `BatchQueryEntry` (8 bytes): query_type, query_id for correlation
- `BatchQueryResponse` header (16 bytes): counts, has_more flag
- `BatchQueryResultEntry` (16 bytes): per-query status, offset, length
- `QueryType` enum: uuid, radius, polygon, latest
- `BatchQueryExecutor(StateMachineType)`: generic executor
- `BatchQueryMetrics`: Prometheus-format metrics

### Modified Files

**src/archerdb.zig** - Operation enum updates
- Added `batch_query = vsr_operations_reserved + 33`
- Added to EventType, ResultType, is_batchable, is_multi_batch
- Added to is_variable_length (true)
- Added to result_count_expected (returns 1)

**src/geo_state_machine.zig** - State machine integration
- Added `batch_query_metrics` field
- Added `batch_query_mod` import
- Added `execute_batch_query` dispatch in commit
- Added to prepare/commit operation switches
- Added stub implementations for 14-05 prepared query operations (blocking fix)

## Wire Format

Request:
```
[BatchQueryRequest: 8 bytes]
  query_count: u32
  reserved: u32

[BatchQueryEntry + filter] x query_count
  query_type: u8 (0=uuid, 1=radius, 2=polygon, 3=latest)
  _pad: [3]u8
  query_id: u32
  [filter data: variable by type]
```

Response:
```
[BatchQueryResponse: 16 bytes]
  total_count: u32
  success_count: u32
  error_count: u32
  has_more: u8
  _reserved: [3]u8

[BatchQueryResultEntry] x total_count
  query_id: u32
  status: u8
  _pad: [3]u8
  result_offset: u32
  result_length: u32

[result data bytes]
```

## Partial Success Semantics

- Each query in batch executes independently
- Failed queries don't affect successful queries
- Response includes per-query status (0 = success)
- Client correlates results via query_id

## Metrics

```
archerdb_batch_queries_total         - Total batch operations
archerdb_batch_query_size_total      - Sum of queries across batches
archerdb_batch_query_success_total   - Successful queries
archerdb_batch_query_error_total     - Failed queries
archerdb_batch_query_truncated_total - Truncated responses
```

## Test Coverage

- Wire format size and padding tests
- Empty batch handling
- Query count exceeds max (100)
- Query_id correlation preserved
- Mixed query types (latest + radius)
- Metrics recording
- Input too small handling

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Prepared query stubs**
- **Found during:** Task 2
- **Issue:** Prepared query operations (14-05) added to Operation enum but no execute functions
- **Fix:** Added stub implementations that return error/empty responses
- **Files modified:** src/geo_state_machine.zig
- **Commit:** 00c6ad0

**2. [Rule 1 - Bug] Pointer alignment**
- **Found during:** Task 2
- **Issue:** `polygonFilterSize` function expected aligned pointer but batch query provides unaligned
- **Fix:** Used `bytesToValue` instead of pointer cast, calculate size inline
- **Files modified:** src/batch_query.zig
- **Commit:** 00c6ad0

**3. [Rule 1 - Bug] Variable mutation warning**
- **Found during:** Task 2
- **Issue:** `var session_prepared_queries` not mutated, should be `const`
- **Fix:** Changed to `const`
- **Files modified:** src/geo_state_machine.zig
- **Commit:** 00c6ad0

## Commits

| Hash | Type | Description |
|------|------|-------------|
| 17b7f7c | feat | Define batch query wire format |
| 00c6ad0 | feat | Implement batch query execution |
| 4c43625 | test | Add batch query metrics and tests |

## Next Phase Readiness

- Batch query API ready for dashboard integration
- Metrics available for Prometheus scraping
- Wire format documented for client library implementation
