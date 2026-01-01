# Observability Specification

## ADDED Requirements

### Requirement: Prometheus Metrics Endpoint

The system SHALL expose operational metrics via a Prometheus-compatible HTTP endpoint.

#### Scenario: Metrics endpoint configuration

- **WHEN** ArcherDB starts
- **THEN** it SHALL expose an HTTP server on a configurable port (default: 9091)
- **AND** the endpoint SHALL be accessible at `http://<node-ip>:9091/metrics`
- **AND** the endpoint SHALL return metrics in Prometheus text format

#### Scenario: Metrics endpoint security

- **WHEN** serving metrics
- **THEN** the endpoint SHALL:
  - **Default to localhost binding** (`--metrics-bind=127.0.0.1`) for security
  - Optionally bind to all interfaces via `--metrics-bind=0.0.0.0` (requires explicit opt-in)
  - Support optional bearer token authentication via `--metrics-token=<secret>`
  - Support optional TLS via `--metrics-tls-cert` and `--metrics-tls-key`
  - Log warning if binding to 0.0.0.0 without authentication enabled
- **AND** metrics expose operational intelligence (replica count, lag, view changes)
- **AND** unauthenticated exposure is a security risk in untrusted networks

#### Scenario: Metrics authentication

- **WHEN** `--metrics-token` is configured
- **THEN** the endpoint SHALL:
  - Require `Authorization: Bearer <token>` header on all requests
  - Return HTTP 401 Unauthorized if token missing or invalid
  - Rate-limit failed authentication attempts (10 per minute per IP)

#### Scenario: Scrape performance

- **WHEN** Prometheus scrapes the endpoint
- **THEN** the response SHALL:
  - Complete within 100ms (p99)
  - Not block database operations
  - Cache metrics for up to 1 second (avoid recomputing on every scrape)

### Requirement: Core Metrics

The system SHALL expose metrics for write throughput, read latency, and cluster health.

#### Scenario: Write metrics

- **WHEN** exposing write metrics
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_write_operations_total Total write operations processed
  # TYPE archerdb_write_operations_total counter
  archerdb_write_operations_total{operation="insert"} 1234567
  archerdb_write_operations_total{operation="upsert"} 987654

  # HELP archerdb_write_events_total Total GeoEvents written
  # TYPE archerdb_write_events_total counter
  archerdb_write_events_total 5000000

  # HELP archerdb_write_bytes_total Total bytes written to data file
  # TYPE archerdb_write_bytes_total counter
  archerdb_write_bytes_total 640000000

  # HELP archerdb_write_latency_seconds Write operation latency histogram
  # TYPE archerdb_write_latency_seconds histogram
  archerdb_write_latency_seconds_bucket{le="0.001"} 5000
  archerdb_write_latency_seconds_bucket{le="0.005"} 12000
  archerdb_write_latency_seconds_bucket{le="0.01"} 15000
  archerdb_write_latency_seconds_bucket{le="+Inf"} 16000
  archerdb_write_latency_seconds_sum 45.67
  archerdb_write_latency_seconds_count 16000
  ```

#### Scenario: Read metrics

- **WHEN** exposing read metrics
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_read_operations_total Total read operations processed
  # TYPE archerdb_read_operations_total counter
  archerdb_read_operations_total{operation="query_uuid"} 500000
  archerdb_read_operations_total{operation="query_radius"} 75000
  archerdb_read_operations_total{operation="query_polygon"} 25000

  # HELP archerdb_read_events_returned_total Total GeoEvents returned from queries
  # TYPE archerdb_read_events_returned_total counter
  archerdb_read_events_returned_total 10000000

  # HELP archerdb_read_latency_seconds Read operation latency histogram
  # TYPE archerdb_read_latency_seconds histogram
  archerdb_read_latency_seconds_bucket{operation="query_uuid",le="0.0005"} 450000
  archerdb_read_latency_seconds_bucket{operation="query_uuid",le="0.001"} 490000
  archerdb_read_latency_seconds_bucket{operation="query_uuid",le="+Inf"} 500000

  # HELP archerdb_index_lookups_total Primary index lookup count
  # TYPE archerdb_index_lookups_total counter
  archerdb_index_lookups_total 500000

  # HELP archerdb_index_lookup_latency_seconds Index lookup latency
  # TYPE archerdb_index_lookup_latency_seconds histogram
  archerdb_index_lookup_latency_seconds_bucket{le="0.0001"} 480000
  archerdb_index_lookup_latency_seconds_bucket{le="0.0005"} 495000
  archerdb_index_lookup_latency_seconds_bucket{le="+Inf"} 500000
  ```

#### Scenario: Query result size metrics

- **WHEN** exposing query metrics
- **THEN** result size distribution SHALL be tracked:
  ```
  # HELP archerdb_query_result_size Query result size histogram
  # TYPE archerdb_query_result_size histogram
  archerdb_query_result_size_bucket{operation="query_radius",le="10"} 10000
  archerdb_query_result_size_bucket{operation="query_radius",le="100"} 50000
  archerdb_query_result_size_bucket{operation="query_radius",le="1000"} 70000
  archerdb_query_result_size_bucket{operation="query_radius",le="10000"} 74000
  archerdb_query_result_size_bucket{operation="query_radius",le="+Inf"} 75000
  ```

### Requirement: Replication Metrics

The system SHALL expose VSR consensus and replication health metrics.

#### Scenario: VSR state metrics

- **WHEN** exposing replication metrics
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_vsr_view Current VSR view number
  # TYPE archerdb_vsr_view gauge
  archerdb_vsr_view 5

  # HELP archerdb_vsr_status Replica status (0=normal, 1=view_change, 2=recovering)
  # TYPE archerdb_vsr_status gauge
  archerdb_vsr_status 0

  # HELP archerdb_vsr_is_primary Whether this replica is the primary (1=yes, 0=no)
  # TYPE archerdb_vsr_is_primary gauge
  archerdb_vsr_is_primary 1

  # HELP archerdb_vsr_op_number Highest committed operation number
  # TYPE archerdb_vsr_op_number gauge
  archerdb_vsr_op_number 1234567

  # HELP archerdb_vsr_view_changes_total Total view changes
  # TYPE archerdb_vsr_view_changes_total counter
  archerdb_vsr_view_changes_total 3
  ```

#### Scenario: Replication lag metrics

- **WHEN** exposing replication lag
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_vsr_replication_lag_ops Replication lag in operations
  # TYPE archerdb_vsr_replication_lag_ops gauge
  archerdb_vsr_replication_lag_ops{replica="replica-0"} 0
  archerdb_vsr_replication_lag_ops{replica="replica-1"} 5
  archerdb_vsr_replication_lag_ops{replica="replica-2"} 2

  # HELP archerdb_vsr_replication_lag_seconds Replication lag in seconds
  # TYPE archerdb_vsr_replication_lag_seconds gauge
  archerdb_vsr_replication_lag_seconds{replica="replica-0"} 0.000
  archerdb_vsr_replication_lag_seconds{replica="replica-1"} 0.005
  archerdb_vsr_replication_lag_seconds{replica="replica-2"} 0.002
  ```

#### Scenario: Quorum metrics

- **WHEN** exposing quorum status
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_vsr_quorum_size Required quorum size
  # TYPE archerdb_vsr_quorum_size gauge
  archerdb_vsr_quorum_size 3

  # HELP archerdb_vsr_available_replicas Replicas responding to pings
  # TYPE archerdb_vsr_available_replicas gauge
  archerdb_vsr_available_replicas 5

  # HELP archerdb_vsr_quorum_available Quorum is available (1=yes, 0=no)
  # TYPE archerdb_vsr_quorum_available gauge
  archerdb_vsr_quorum_available 1
  ```

### Requirement: Resource Metrics

The system SHALL expose memory, disk, and I/O utilization metrics.

#### Scenario: Memory metrics

- **WHEN** exposing memory metrics
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_memory_allocated_bytes Total memory allocated
  # TYPE archerdb_memory_allocated_bytes gauge
  archerdb_memory_allocated_bytes 68719476736

  # HELP archerdb_memory_used_bytes Memory currently in use
  # TYPE archerdb_memory_used_bytes gauge
  archerdb_memory_used_bytes 51539607552

  # HELP archerdb_index_entries Current entity count in primary index
  # TYPE archerdb_index_entries gauge
  archerdb_index_entries 1000000000

  # HELP archerdb_index_capacity Maximum index capacity
  # TYPE archerdb_index_capacity gauge
  archerdb_index_capacity 1428571428

  # HELP archerdb_index_load_factor Index load factor (0.0 to 1.0)
  # TYPE archerdb_index_load_factor gauge
  archerdb_index_load_factor 0.70

  # HELP archerdb_index_utilization_ratio Index utilization ratio (entries/capacity, 0.0 to 1.0)
  # TYPE archerdb_index_utilization_ratio gauge
  archerdb_index_utilization_ratio 0.70
  ```

#### Scenario: Index capacity alerts

- **WHEN** monitoring index capacity
- **THEN** operators SHOULD configure alerts:
  - Warning: `archerdb_index_utilization_ratio > 0.80` (80% full)
  - Critical: `archerdb_index_utilization_ratio > 0.90` (90% full)
  - Emergency: `archerdb_index_utilization_ratio > 0.95` (95% full - near capacity)

#### Scenario: Disk metrics

- **WHEN** exposing disk metrics
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_data_file_size_bytes Data file size
  # TYPE archerdb_data_file_size_bytes gauge
  archerdb_data_file_size_bytes 137438953472

  # HELP archerdb_disk_reads_total Total disk read operations
  # TYPE archerdb_disk_reads_total counter
  archerdb_disk_reads_total 5000000

  # HELP archerdb_disk_writes_total Total disk write operations
  # TYPE archerdb_disk_writes_total counter
  archerdb_disk_writes_total 1000000

  # HELP archerdb_disk_read_bytes_total Total bytes read from disk
  # TYPE archerdb_disk_read_bytes_total counter
  archerdb_disk_read_bytes_total 640000000000

  # HELP archerdb_disk_write_bytes_total Total bytes written to disk
  # TYPE archerdb_disk_write_bytes_total counter
  archerdb_disk_write_bytes_total 128000000000
  ```

#### Scenario: I/O latency metrics

- **WHEN** exposing I/O latency
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_disk_read_latency_seconds Disk read latency histogram
  # TYPE archerdb_disk_read_latency_seconds histogram
  archerdb_disk_read_latency_seconds_bucket{le="0.0001"} 4500000
  archerdb_disk_read_latency_seconds_bucket{le="0.0005"} 4950000
  archerdb_disk_read_latency_seconds_bucket{le="0.001"} 4990000
  archerdb_disk_read_latency_seconds_bucket{le="+Inf"} 5000000

  # HELP archerdb_disk_write_latency_seconds Disk write latency histogram
  # TYPE archerdb_disk_write_latency_seconds histogram
  archerdb_disk_write_latency_seconds_bucket{le="0.001"} 950000
  archerdb_disk_write_latency_seconds_bucket{le="0.005"} 990000
  archerdb_disk_write_latency_seconds_bucket{le="+Inf"} 1000000
  ```

### Requirement: LSM Tree Metrics

The system SHALL expose LSM tree compaction and table statistics.

#### Scenario: LSM statistics

- **WHEN** exposing LSM metrics
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_lsm_tables_count Current number of tables per level
  # TYPE archerdb_lsm_tables_count gauge
  archerdb_lsm_tables_count{level="0"} 8
  archerdb_lsm_tables_count{level="1"} 12
  archerdb_lsm_tables_count{level="2"} 16

  # HELP archerdb_lsm_compactions_total Total compactions performed
  # TYPE archerdb_lsm_compactions_total counter
  archerdb_lsm_compactions_total{level="0"} 100
  archerdb_lsm_compactions_total{level="1"} 25

  # HELP archerdb_lsm_compaction_latency_seconds Compaction duration
  # TYPE archerdb_lsm_compaction_latency_seconds histogram
  archerdb_lsm_compaction_latency_seconds_bucket{le="1.0"} 80
  archerdb_lsm_compaction_latency_seconds_bucket{le="5.0"} 120
  archerdb_lsm_compaction_latency_seconds_bucket{le="+Inf"} 125
  ```

### Requirement: Error Metrics

The system SHALL expose error counts and rates for monitoring failure modes.

#### Scenario: Error counters

- **WHEN** exposing error metrics
- **THEN** the following SHALL be included:
  ```
  # HELP archerdb_errors_total Total errors by type
  # TYPE archerdb_errors_total counter
  archerdb_errors_total{error="checksum_mismatch"} 5
  archerdb_errors_total{error="invalid_coordinates"} 12
  archerdb_errors_total{error="query_result_too_large"} 3
  archerdb_errors_total{error="not_primary"} 50

  # HELP archerdb_timeouts_total Operations that timed out
  # TYPE archerdb_timeouts_total counter
  archerdb_timeouts_total{operation="insert"} 2
  archerdb_timeouts_total{operation="query_radius"} 5
  ```

### Requirement: Structured Logging

The system SHALL use Zig's `std.log` with configurable output format for operational logging.

#### Scenario: Log format configuration

- **WHEN** starting ArcherDB
- **THEN** log format SHALL be configurable:
  - `--log-format=json` - Structured JSON logs (default for production)
  - `--log-format=text` - Human-readable text logs (development)

#### Scenario: Log level configuration

- **WHEN** configuring log verbosity
- **THEN** the following levels SHALL be supported:
  - `--log-level=debug` - Verbose debugging (development only)
  - `--log-level=info` - Informational messages (default)
  - `--log-level=warn` - Warnings and errors
  - `--log-level=error` - Errors only

#### Scenario: JSON log format

- **WHEN** using `--log-format=json`
- **THEN** each log line SHALL be a JSON object:
  ```json
  {
    "level": "info",
    "ts": "2025-12-31T12:34:56.789123Z",
    "msg": "view change completed",
    "view": 5,
    "primary": "replica-2",
    "replica_id": "replica-0",
    "cluster": "abc123..."
  }
  ```

#### Scenario: Text log format

- **WHEN** using `--log-format=text`
- **THEN** each log line SHALL be human-readable:
  ```
  [INFO] 2025-12-31 12:34:56.789 replica-0: view change completed (view=5, primary=replica-2)
  ```

#### Scenario: Compile-time log filtering

- **WHEN** building ArcherDB
- **THEN** Zig's compile-time log level filtering SHALL be used:
  - `std.log.debug()` calls are zero-cost in release builds
  - `-OReleaseFast` omits all debug/info logs
  - `-OReleaseSafe` includes info and above

### Requirement: Log Content

The system SHALL log key operational events for debugging and auditing.

#### Scenario: Startup/shutdown logs

- **WHEN** the replica starts or stops
- **THEN** it SHALL log:
  - Startup: version, replica ID, cluster ID, configuration
  - Certificate loaded (CN, expiration date)
  - Data file opened (size, superblock sequence)
  - Primary index loaded (entry count, load factor)
  - Listening on addresses (client port, replica port, metrics port)
  - Shutdown: reason, graceful vs forced

#### Scenario: VSR event logs

- **WHEN** VSR state changes occur
- **THEN** the system SHALL log:
  - View change initiated (old view, new view, reason)
  - Primary elected (replica ID, view number)
  - Replica joined/left cluster
  - Quorum lost/restored
  - WAL repair initiated (missing op range)
  - State sync started/completed

#### Scenario: Operation logs

- **WHEN** operations complete
- **THEN** the system MAY log (at debug level):
  - Write batch committed (op_num, event count, latency)
  - Query executed (operation, result count, latency)
  - Large query result (operation, count, S2 cell ranges)

#### Scenario: Error logs

- **WHEN** errors occur
- **THEN** the system SHALL log:
  - Checksum mismatch (file, offset, expected, actual)
  - Certificate validation failure (client CN, error reason)
  - Disk I/O error (operation, path, error code)
  - Invalid message received (operation, error code)
  - Panic/crash (stack trace, state dump)

### Requirement: Log Rotation

The system SHALL support log file rotation to prevent unbounded disk usage.

#### Scenario: Log file configuration

- **WHEN** configuring log output
- **THEN** the following SHALL be supported:
  - `--log-file=<path>` - Log to file instead of stdout
  - `--log-rotate-size=<bytes>` - Rotate when file reaches size (default: 100MB)
  - `--log-rotate-count=<n>` - Keep last N rotated files (default: 10)

#### Scenario: Rotation behavior

- **WHEN** log file reaches rotation size
- **THEN** the system SHALL:
  - Close current log file
  - Rename to `<filename>.1`
  - Shift existing rotated files (`.1` → `.2`, `.2` → `.3`, etc.)
  - Delete oldest file if count exceeds limit
  - Open new log file
  - Continue logging without message loss

### Requirement: Distributed Tracing (Future)

The system SHALL reserve support for distributed tracing in future versions.

#### Scenario: Trace ID propagation (deferred)

- **WHEN** implementing distributed tracing (v2+)
- **THEN** the system MAY:
  - Accept trace IDs in message headers (W3C Trace Context)
  - Propagate trace IDs through VSR messages
  - Export spans to OpenTelemetry collectors
  - Include trace IDs in logs for correlation

### Requirement: Health Check Endpoint

The system SHALL provide a simple health check endpoint for load balancers.

#### Scenario: Health endpoint

- **WHEN** accessing `/health` on metrics port
- **THEN** the system SHALL:
  - Return HTTP 200 if replica is healthy (accepting requests)
  - Return HTTP 503 if replica is unhealthy (view change, recovering)
  - Response body: JSON `{"status": "ok"}` or `{"status": "unavailable", "reason": "view_change"}`

#### Scenario: Liveness vs readiness

- **WHEN** defining health checks
- **THEN** the system SHALL provide:
  - `/health/live` - Process is running (always 200 unless crashed)
  - `/health/ready` - Replica is ready to serve requests (200 if primary or healthy backup)
