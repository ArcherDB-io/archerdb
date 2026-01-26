---
status: complete
phase: 15-cluster-consensus
source: [15-01-SUMMARY.md, 15-02-SUMMARY.md, 15-03-SUMMARY.md, 15-04-SUMMARY.md, 15-05-SUMMARY.md, 15-06-SUMMARY.md, 15-07-SUMMARY.md, 15-08-SUMMARY.md, 15-09-SUMMARY.md, 15-10-SUMMARY.md, 15-11-SUMMARY.md]
started: 2026-01-25T09:44:40Z
updated: 2026-01-25T09:59:46Z
---

## Current Test

[testing complete]

## Tests

### 1. Connection pool metrics exported
expected: Running `curl http://localhost:9090/metrics` includes connection pool metrics: archerdb_pool_connections_active, archerdb_pool_connections_idle, archerdb_pool_waiters, archerdb_pool_memory_pressure_state, archerdb_pool_acquire_total.
result: pass

### 2. Load shedding metrics exported
expected: Running `curl http://localhost:9090/metrics` includes load shedding metrics: archerdb_shed_score, archerdb_shed_threshold, archerdb_shed_requests_total, archerdb_shed_retry_after_last_ms.
result: pass

### 3. Read replica routing metrics exported
expected: Running `curl http://localhost:9090/metrics` includes routing metrics: archerdb_routing_reads_total, archerdb_routing_writes_total, archerdb_routing_to_replica_total, archerdb_routing_failover_total.
result: pass

### 4. CLI timeout profile flags
expected: Running `archerdb --help` shows --vsr-timeout-profile=<cloud|datacenter|custom>, --vsr-timeout-jitter-pct, and override flags like --vsr-timeout-heartbeat-ms, --vsr-timeout-election-ms, --vsr-timeout-request-ms, --vsr-timeout-connection-ms, --vsr-timeout-view-change-ms.
result: pass

### 5. CLI quorum preset flags
expected: Running `archerdb --help` shows --vsr-quorum-preset=<classic|fast_commit|strong_leader> plus --vsr-quorum-phase1 and --vsr-quorum-phase2 overrides.
result: pass

### 6. HTTP overload responses include Retry-After
expected: When load shedding is active (shed score at/above threshold), HTTP requests to the metrics server (e.g., /metrics) return 429 with a Retry-After header derived from the latest shed retry-after gauge.
result: pass

### 7. Cluster health dashboard exists
expected: File observability/grafana/dashboards/archerdb-cluster-health.json exists with panels for pool utilization, load shedding, replica routing, and consensus health.
result: pass

### 8. Cluster alert rules exist
expected: File observability/prometheus/rules/archerdb-cluster.yaml exists with alert rules for pool exhaustion, shedding spikes, replica lag, and quorum risk (with runbook annotations).
result: pass

## Summary

total: 8
passed: 8
issues: 0
pending: 0
skipped: 0

## Gaps

[none]
