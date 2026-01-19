# Observability - Coordinator Mode

## ADDED Requirements

### Requirement: Coordinator Connection Metrics

The system SHALL expose metrics for coordinator client connections.

#### Scenario: Active connections metric

- **WHEN** exposing coordinator metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_connections_active Current active client connections
  # TYPE archerdb_coordinator_connections_active gauge
  archerdb_coordinator_connections_active 1234
  ```

#### Scenario: Connection lifecycle metrics

- **WHEN** clients connect and disconnect
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_connections_total Total connections since startup
  # TYPE archerdb_coordinator_connections_total counter
  archerdb_coordinator_connections_total 50000

  # HELP archerdb_coordinator_connections_rejected_total Connections rejected (at limit)
  # TYPE archerdb_coordinator_connections_rejected_total counter
  archerdb_coordinator_connections_rejected_total 0
  ```

### Requirement: Coordinator Query Metrics

The system SHALL expose metrics for coordinator query handling.

#### Scenario: Query count metrics

- **WHEN** exposing query metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_queries_total Total queries processed
  # TYPE archerdb_coordinator_queries_total counter
  archerdb_coordinator_queries_total{type="single_shard"} 1000000
  archerdb_coordinator_queries_total{type="fan_out"} 50000
  archerdb_coordinator_queries_total{type="batch"} 10000
  ```

#### Scenario: Query latency metrics

- **WHEN** exposing query latency
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_query_duration_seconds Query latency histogram
  # TYPE archerdb_coordinator_query_duration_seconds histogram
  archerdb_coordinator_query_duration_seconds_bucket{type="single_shard",le="0.001"} 950000
  archerdb_coordinator_query_duration_seconds_bucket{type="single_shard",le="0.01"} 999000
  archerdb_coordinator_query_duration_seconds_bucket{type="fan_out",le="0.01"} 40000
  archerdb_coordinator_query_duration_seconds_bucket{type="fan_out",le="0.1"} 49000
  ```

#### Scenario: Query error metrics

- **WHEN** queries fail
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_query_errors_total Query errors by reason
  # TYPE archerdb_coordinator_query_errors_total counter
  archerdb_coordinator_query_errors_total{reason="timeout"} 10
  archerdb_coordinator_query_errors_total{reason="shard_unavailable"} 5
  archerdb_coordinator_query_errors_total{reason="partial_failure"} 3
  ```

### Requirement: Coordinator Shard Metrics

The system SHALL expose metrics for shard connectivity and health.

#### Scenario: Shard health metrics

- **WHEN** exposing shard metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_shards_total Total shards in topology
  # TYPE archerdb_coordinator_shards_total gauge
  archerdb_coordinator_shards_total 16

  # HELP archerdb_coordinator_shards_healthy Healthy shards
  # TYPE archerdb_coordinator_shards_healthy gauge
  archerdb_coordinator_shards_healthy 16

  # HELP archerdb_coordinator_shards_unhealthy Unhealthy shards
  # TYPE archerdb_coordinator_shards_unhealthy gauge
  archerdb_coordinator_shards_unhealthy 0
  ```

#### Scenario: Per-shard status metric

- **WHEN** tracking individual shard status
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_shard_status Shard status (1=healthy, 0=unhealthy)
  # TYPE archerdb_coordinator_shard_status gauge
  archerdb_coordinator_shard_status{shard="0"} 1
  archerdb_coordinator_shard_status{shard="1"} 1
  archerdb_coordinator_shard_status{shard="15"} 0
  ```

#### Scenario: Shard failure metrics

- **WHEN** shard failures occur
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_shard_failures_total Shard health check failures
  # TYPE archerdb_coordinator_shard_failures_total counter
  archerdb_coordinator_shard_failures_total{shard="15"} 5
  ```

### Requirement: Coordinator Topology Metrics

The system SHALL expose metrics for topology management.

#### Scenario: Topology version metric

- **WHEN** exposing topology metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_topology_version Current topology version
  # TYPE archerdb_coordinator_topology_version gauge
  archerdb_coordinator_topology_version 42
  ```

#### Scenario: Topology update metrics

- **WHEN** topology is updated
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_topology_updates_total Topology updates received
  # TYPE archerdb_coordinator_topology_updates_total counter
  archerdb_coordinator_topology_updates_total 10

  # HELP archerdb_coordinator_topology_refresh_errors_total Topology refresh failures
  # TYPE archerdb_coordinator_topology_refresh_errors_total counter
  archerdb_coordinator_topology_refresh_errors_total 0
  ```

### Requirement: Coordinator Fan-Out Metrics

The system SHALL expose detailed metrics for fan-out query execution.

#### Scenario: Fan-out shard count metric

- **WHEN** fan-out queries execute
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_fanout_shards_queried Shards queried per fan-out
  # TYPE archerdb_coordinator_fanout_shards_queried histogram
  archerdb_coordinator_fanout_shards_queried_bucket{le="8"} 1000
  archerdb_coordinator_fanout_shards_queried_bucket{le="16"} 50000
  archerdb_coordinator_fanout_shards_queried_bucket{le="32"} 50000
  ```

#### Scenario: Fan-out partial result metric

- **WHEN** fan-out returns partial results
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_coordinator_fanout_partial_total Fan-out queries with partial results
  # TYPE archerdb_coordinator_fanout_partial_total counter
  archerdb_coordinator_fanout_partial_total 3
  ```

### Requirement: Coordinator Alerting Support

The system SHALL provide metrics suitable for alerting.

#### Scenario: Alerting on unhealthy shards

- **WHEN** configuring alerts
- **THEN** operators MAY configure:
  ```yaml
  Alert: Coordinator has unhealthy shards
  Condition: archerdb_coordinator_shards_unhealthy > 0
  Severity: Warning
  Message: Coordinator sees {value} unhealthy shards

  Alert: Coordinator lost majority of shards
  Condition: archerdb_coordinator_shards_healthy < (archerdb_coordinator_shards_total / 2)
  Severity: Critical
  Message: Coordinator has less than 50% healthy shards
  ```

#### Scenario: Alerting on high error rate

- **WHEN** configuring alerts
- **THEN** operators MAY configure:
  ```yaml
  Alert: High coordinator error rate
  Condition: rate(archerdb_coordinator_query_errors_total[5m]) > 10
  Severity: Warning
  Message: Coordinator experiencing >10 errors/sec
  ```

#### Scenario: Alerting on connection saturation

- **WHEN** configuring alerts
- **THEN** operators MAY configure:
  ```yaml
  Alert: Coordinator connection saturation
  Condition: archerdb_coordinator_connections_active > 9000
  Severity: Warning
  Message: Coordinator at {value}/10000 connections (90% capacity)
  ```

### Requirement: Coordinator Logging

The system SHALL provide structured logging for coordinator operations.

#### Scenario: Startup logging

- **WHEN** coordinator starts
- **THEN** the system SHALL log:
  ```
  info: Coordinator starting
  info: Bind address: 0.0.0.0:5000
  info: Discovering topology from seed nodes: [node-0:5001, node-5:5001]
  info: Topology discovered: version=42, shards=16
  info: Connected to 16 shards (16 healthy, 0 unhealthy)
  info: Coordinator ready, accepting connections
  ```

#### Scenario: Shard failure logging

- **WHEN** a shard becomes unhealthy
- **THEN** the system SHALL log:
  ```
  warn: Shard 15 health check failed (attempt 1/3)
  warn: Shard 15 health check failed (attempt 2/3)
  warn: Shard 15 health check failed (attempt 3/3)
  error: Shard 15 marked unhealthy after 3 consecutive failures
  ```

#### Scenario: Topology change logging

- **WHEN** topology changes
- **THEN** the system SHALL log:
  ```
  info: Topology update: version 42 → 43
  info: Topology change: shard 16 added (primary: node-32:5001)
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Coordinator Connection Metrics | IMPLEMENTED | Coordinator mode implementation |
| Coordinator Query Metrics | IMPLEMENTED | Coordinator mode implementation |
| Coordinator Shard Metrics | IMPLEMENTED | Coordinator mode implementation |
| Coordinator Topology Metrics | IMPLEMENTED | Coordinator mode implementation |
| Coordinator Fan-Out Metrics | IMPLEMENTED | Coordinator mode implementation |
| Coordinator Alerting Support | IMPLEMENTED | Coordinator mode implementation |
| Coordinator Logging | IMPLEMENTED | Coordinator mode implementation |

## Related Specifications

- See `coordinator/spec.md` (this change) for coordinator behavior
- See `configuration/spec.md` (this change) for CLI arguments
- See base `observability/spec.md` for metrics endpoint
