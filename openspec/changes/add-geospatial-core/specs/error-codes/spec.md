# Error Codes Specification

## ADDED Requirements

### Requirement: Centralized Error Code Enumeration

The system SHALL define all error codes in a central enumeration with non-overlapping ranges to ensure consistency across all components.

#### Scenario: Error code organization

- **WHEN** defining error codes
- **THEN** they SHALL be organized into non-overlapping ranges:
  - `0`: Success (ok)
  - `1-99`: Protocol errors (message format, checksums, version mismatch)
  - `100-199`: Validation errors (invalid inputs, constraint violations)
  - `200-299`: State errors (entity not found, cluster unavailable)
  - `300-399`: Resource errors (limits exceeded, capacity constraints)
  - `400-499`: Security errors (authentication, authorization)
  - `500-599`: Internal errors (should not occur in production)

#### Scenario: Error code uniqueness

- **WHEN** adding a new error code
- **THEN** its numeric value MUST NOT conflict with existing codes
- **AND** the symbolic name SHALL be unique across all error codes
- **AND** the code SHALL be added to the master enumeration table

### Requirement: Error Code Metadata

The system SHALL provide complete metadata for every error code including retry semantics and required context fields.

#### Scenario: Error code definition structure

- **WHEN** an error code is defined
- **THEN** it SHALL include:
  - **code** (u16): Numeric error code
  - **name** (string): Symbolic name in snake_case
  - **message** (string): Human-readable description
  - **retry_semantics** (enum): `retriable`, `client_error`, `fatal`
  - **context_fields** (array): List of required context field names
- **AND** all fields MUST be populated (no undefined values)

### Requirement: Complete Error Code Table

The system SHALL enumerate all error codes with complete metadata in a central table.

#### Scenario: Error code enumeration

- **WHEN** implementing error handling
- **THEN** the following error codes SHALL be defined:

| Code | Name | Message | Retry | Context Fields |
|------|------|---------|-------|----------------|
| 0 | ok | Operation succeeded | N/A | (none) |
| 1 | invalid_message | Message format is invalid | No | offset, expected, actual |
| 2 | checksum_mismatch_header | Header checksum verification failed | Yes | address, expected_checksum, actual_checksum |
| 3 | checksum_mismatch_body | Body checksum verification failed | Yes | address, expected_checksum, actual_checksum |
| 4 | message_too_large | Message exceeds message_size_max | No | size, message_size_max |
| 5 | message_too_small | Message smaller than header size | No | size, message_header_size |
| 6 | unsupported_version | Protocol version not supported | No | server_version, client_version |
| 7 | invalid_operation | Operation code not recognized | No | operation |
| 8 | cluster_id_mismatch | Message cluster ID does not match | No | expected_cluster, actual_cluster |
| 9 | invalid_magic | Magic number incorrect (not "ARCH") | No | expected_magic, actual_magic |
| 10 | reserved_field_nonzero | Reserved field contains non-zero data | No | field_name, offset |
| 100 | invalid_coordinates | Latitude or longitude out of valid range | No | lat_nano, lon_nano, valid_lat_range, valid_lon_range |
| 101 | ttl_overflow | TTL + timestamp would overflow u64 | No | timestamp, ttl_seconds |
| 102 | invalid_ttl | TTL value is invalid | No | ttl_seconds, max_ttl_seconds |
| 103 | invalid_entity_id | Entity ID is malformed or invalid | No | entity_id |
| 104 | invalid_batch_size | Batch size exceeds limits | No | batch_size, batch_events_max |
| 105 | reserved_105 | Reserved (empty batches are valid no-ops per query-engine spec) | No | (none) |
| 106 | invalid_s2_cell | S2 cell ID is invalid or out of range | No | s2_cell_id, s2_level |
| 107 | invalid_radius | Radius parameter is invalid or too large | No | radius_meters, max_radius_meters |
| 108 | invalid_polygon | Generic polygon validation failure | No | reason |
| 109 | polygon_self_intersecting | Polygon edges cross each other | No | intersection_point, edge1_index, edge2_index |
| 110 | radius_zero | Radius query with 0 meters not supported | No | (none) |
| 111 | polygon_too_large | Polygon spans > 350° longitude (world-wrapping) | No | bbox_width_degrees |
| 112 | polygon_degenerate | All vertices collinear (zero area) | No | vertex_count, computed_area |
| 113 | polygon_empty | Polygon has zero vertices | No | (none) |
| 114 | coordinate_mismatch | S2 cell ID does not match lat/lon coordinates | No | entity_id, computed_cell, provided_cell |
| 115 | timestamp_in_future | Event timestamp is in the future | No | event_timestamp, current_time |
| 116 | timestamp_too_old | Event timestamp exceeds maximum age | No | event_timestamp, current_time, max_age_seconds |
| 200 | entity_not_found | Entity UUID does not exist in index | No | entity_id |
| 201 | cluster_unavailable | Cluster has no quorum (too many replicas down) | Yes | view, replica_count, alive_count, quorum_replication |
| 202 | view_change_in_progress | Cluster is performing view change | Yes | old_view, new_view |
| 203 | not_primary | This replica is not the primary for current view | Yes | view, primary_index, this_replica_index |
| 204 | session_expired | Client session has expired or been evicted | No | client_id, request, reason |
| 205 | duplicate_request | Request was already processed (idempotency) | No | client_id, request, original_op |
| 206 | stale_read | Read timestamp is too old (MVCC) | No | read_timestamp, current_snapshot |
| 207 | checkpoint_in_progress | Cannot process request during checkpoint | Yes | checkpoint_id, progress_percent |
| 208 | storage_unavailable | Storage subsystem is not ready | Yes | reason |
| 209 | index_rebuilding | RAM index is being rebuilt from LSM | Yes | progress_percent |
| 210 | entity_expired | Entity has expired due to TTL | No | entity_id, expiration_time, current_time |
| 211 | resource_exhausted | Internal resource pool exhausted | Yes | resource_type, current_usage, max_capacity |
| 300 | too_many_events | Batch exceeds batch_events_max | No | batch_size, batch_events_max |
| 301 | message_body_too_large | Message body exceeds message_body_size_max | No | body_size, message_body_size_max |
| 302 | result_set_too_large | Query result exceeds message size limit | No | result_count, max_result_count |
| 303 | too_many_clients | Client session limit reached | Yes | clients_max, active_clients |
| 304 | rate_limit_exceeded | Client exceeded rate limit | Yes | client_id, rate_limit, current_rate |
| 305 | memory_exhausted | System memory limit reached | Yes | memory_used, memory_limit |
| 306 | disk_full | Disk space exhausted | Yes | disk_used, disk_capacity |
| 307 | too_many_queries | Concurrent query limit exceeded | Yes | concurrent_queries, max_concurrent_queries |
| 308 | pipeline_full | VSR pipeline cannot accept more operations | Yes | pipeline_depth, pipeline_max |
| 309 | index_capacity_exceeded | RAM index capacity limit reached | No | entity_count, index_capacity, entities_max_per_node |
| 310 | index_degraded | Hash table probe length exceeded max_probe_length | No | avg_probe_length, max_probe_length, probe_limit_hits |
| 400 | authentication_failed | mTLS authentication failed | No | reason, certificate_subject |
| 401 | certificate_expired | Client certificate has expired | No | certificate_subject, expiry_date |
| 402 | certificate_revoked | Client certificate has been revoked | No | certificate_subject, revocation_date |
| 403 | unauthorized | Client not authorized for this operation | No | client_id, operation |
| 404 | cluster_key_mismatch | Cluster key does not match | No | (none) |
| 500 | internal_error | Unexpected internal error (bug) | No | file, line, message |
| 501 | assertion_failed | Internal assertion failed (bug) | No | file, line, assertion |
| 502 | unreachable | Reached supposedly unreachable code (bug) | No | file, line |
| 503 | corruption_detected | Data corruption detected | No | address, expected_checksum, actual_checksum, data_type |
| 504 | invariant_violation | System invariant violated (bug) | No | invariant_name, file, line |

### Requirement: Error Code Implementation

The system SHALL implement error codes as a central Zig enum type.

#### Scenario: Zig enum definition

- **WHEN** implementing error codes
- **THEN** they SHALL be defined in `src/error_codes.zig` as:
  ```zig
  pub const ErrorCode = enum(u16) {
      ok = 0,
      invalid_message = 1,
      checksum_mismatch_header = 2,
      checksum_mismatch_body = 3,
      message_too_large = 4,
      // ... (all codes from table above)

      pub fn is_retriable(self: ErrorCode) bool {
          return switch (self) {
              .ok => false,
              .checksum_mismatch_header, .checksum_mismatch_body => true,
              .cluster_unavailable, .view_change_in_progress => true,
              .not_primary, .checkpoint_in_progress => true,
              .storage_unavailable, .index_rebuilding => true,
              .too_many_clients, .rate_limit_exceeded => true,
              .memory_exhausted, .disk_full => true,
              .too_many_queries, .pipeline_full => true,
              else => false,
          };
      }

      pub fn message(self: ErrorCode) []const u8 {
          return switch (self) {
              .ok => "Operation succeeded",
              .invalid_message => "Message format is invalid",
              .checksum_mismatch_header => "Header checksum verification failed",
              // ... (all messages from table)
          };
      }
  };
  ```
- **AND** all components SHALL use this enum exclusively

### Requirement: Error Response Format

The system SHALL use a standardized error response format for all client-facing errors.

#### Scenario: Error response structure

- **WHEN** returning an error to a client
- **THEN** the response SHALL contain:
  - **operation** (u16): The operation that failed
  - **error_code** (u16): ErrorCode enum value
  - **context_size** (u16): Size of context data in bytes
  - **reserved** (u16): Reserved for future use (must be zero)
  - **context** (variable): Context-specific error data
- **AND** total error response size SHALL NOT exceed message_body_size_max

#### Scenario: Error context encoding

- **WHEN** encoding error context
- **THEN** context SHALL be encoded as:
  - Field count (u16)
  - For each field:
    - Field name length (u8)
    - Field name (UTF-8 string, max 255 bytes)
    - Field value length (u16)
    - Field value (UTF-8 string, max 65535 bytes)
- **AND** this format enables machine-readable error details
- **AND** SDKs SHALL parse context into structured objects

### Requirement: Error Propagation Semantics

The system SHALL define clear error propagation rules through all system layers.

#### Scenario: VSR layer errors

- **WHEN** an error occurs in the VSR layer (replication, view change)
- **THEN** it SHALL be mapped to a client-facing error code
- **AND** the following mappings SHALL apply:
  - Primary unreachable → `cluster_unavailable`
  - Quorum not available → `cluster_unavailable`
  - View change triggered → `view_change_in_progress`
  - This replica not primary → `not_primary`
- **AND** clients SHALL automatically retry retriable errors

#### Scenario: Storage layer errors

- **WHEN** an error occurs in the storage layer (LSM, grid, superblock)
- **THEN** it SHALL be mapped according to:
  - Checksum mismatch → `corruption_detected`
  - Disk full → `disk_full`
  - Read/write failure → `storage_unavailable`
- **AND** corruption errors SHALL panic the replica (safety over availability)
- **AND** resource errors SHALL return to client with retry hint

#### Scenario: State machine errors

- **WHEN** an error occurs in the state machine (validation, execution)
- **THEN** it SHALL be mapped to validation or state error codes
- **AND** validation errors SHALL be returned immediately (no retry)
- **AND** state errors SHALL include relevant entity/operation context

### Requirement: Client SDK Error Handling

The system SHALL specify requirements for client SDK error handling behavior.

#### Scenario: SDK automatic retry

- **WHEN** a client SDK receives a retriable error
- **THEN** it SHALL automatically retry with exponential backoff:
  - Initial backoff: 100ms
  - Max backoff: 5000ms
  - Backoff multiplier: 2.0
  - Max retry attempts: 10
- **AND** SDKs SHALL expose configuration for retry parameters
- **AND** SDKs SHALL surface retry count to application

#### Scenario: SDK non-retriable errors

- **WHEN** a client SDK receives a non-retriable error
- **THEN** it SHALL immediately return the error to the application
- **AND** SDKs SHALL NOT automatically retry
- **AND** SDKs SHALL include full error context in exception/result

#### Scenario: SDK primary discovery

- **WHEN** a client receives `not_primary` error
- **THEN** the SDK SHALL:
  1. Mark current replica as non-primary in connection pool
  2. Attempt connection to next replica in pool
  3. Retry the operation on new connection
  4. Repeat until success or max retries reached
- **AND** this is specified in detail in `specs/client-retry/spec.md`

### Requirement: Metrics for Error Tracking

The system SHALL emit metrics for all error occurrences to enable monitoring and alerting.

#### Scenario: Error counter metrics

- **WHEN** any error occurs
- **THEN** the system SHALL increment:
  - `archerdb_errors_total{error_code="<name>"}` - Total errors by code
  - `archerdb_errors_retriable_total` - Total retriable errors
  - `archerdb_errors_fatal_total` - Total fatal errors
- **AND** these metrics enable error rate monitoring

#### Scenario: Error context logging

- **WHEN** a critical error occurs (5xx codes)
- **THEN** the system SHALL log:
  - Error code and message
  - Full error context
  - Stack trace (if available)
  - Operation and client_id (if applicable)
- **AND** log level SHALL be ERROR for 5xx, WARN for others

### Requirement: Comprehensive Error Code Test Scenarios

The system SHALL define explicit test scenarios for every error code to ensure complete test coverage.

#### Scenario: Protocol error tests (codes 1-10)

- **WHEN** testing protocol error handling
- **THEN** the following test cases SHALL be executed:
  - **Code 1 (invalid_message)**: Send malformed message with incorrect field ordering
  - **Code 2 (checksum_mismatch_header)**: Corrupt header checksum, verify rejection
  - **Code 3 (checksum_mismatch_body)**: Corrupt body checksum, verify rejection
  - **Code 4 (message_too_large)**: Send 15MB message (exceeds 10MB limit)
  - **Code 5 (message_too_small)**: Send 128-byte message (smaller than 256B header)
  - **Code 6 (unsupported_version)**: Send version=99 message to version=1 server
  - **Code 7 (invalid_operation)**: Send operation=9999 (undefined operation code)
  - **Code 8 (cluster_id_mismatch)**: Send message with wrong cluster UUID
  - **Code 9 (invalid_magic)**: Send magic=0x12345678 instead of "ARCH"
  - **Code 10 (reserved_field_nonzero)**: Send message with reserved[0]=0xFF

#### Scenario: Validation error tests (codes 100-111)

- **WHEN** testing validation error handling
- **THEN** the following test cases SHALL be executed:
  - **Code 100 (invalid_coordinates)**: lat_nano=95,000,000,000 (95° > 90° max)
  - **Code 101 (ttl_overflow)**: timestamp=maxInt(u64)-1000, ttl_seconds=2000 (overflow)
  - **Code 102 (invalid_ttl)**: ttl_seconds=maxInt(u32)+1 (hypothetical, type prevents)
  - **Code 103 (invalid_entity_id)**: entity_id=null or malformed UUID (if validated)
  - **Code 104 (invalid_batch_size)**: batch_size=15,000 (exceeds 10,000 limit)
  - **Code 105 (reserved_105)**: Reserved - empty batches are valid no-ops (see query-engine/spec.md)
  - **Code 106 (invalid_s2_cell)**: s2_cell_id with invalid level encoding
  - **Code 107 (invalid_radius)**: radius_meters=2,000,000 (exceeds 1,000,000 max)
  - **Code 108 (invalid_polygon)**: Generic polygon error with malformed input
  - **Code 109 (polygon_self_intersecting)**: Bowtie polygon (edges cross)
  - **Code 110 (radius_zero)**: radius_meters=0 (use UUID query instead)
  - **Code 111 (polygon_too_large)**: polygon spanning 360° longitude
  - **Code 112 (polygon_degenerate)**: All 3+ vertices on same line (zero area)
  - **Code 113 (polygon_empty)**: vertex_count=0
  - **Code 114 (coordinate_mismatch)**: Manually set ID not matching lat/lon
  - **Code 115 (timestamp_in_future)**: event_timestamp > current_time + 60s
  - **Code 116 (timestamp_too_old)**: event_timestamp < current_time - max_age

#### Scenario: State error tests (codes 200-209)

- **WHEN** testing state error handling
- **THEN** the following test cases SHALL be executed:
  - **Code 200 (entity_not_found)**: Query UUID that doesn't exist in index
  - **Code 201 (cluster_unavailable)**: Stop 2/3 replicas, verify error
  - **Code 202 (view_change_in_progress)**: Trigger view change, send query during
  - **Code 203 (not_primary)**: Send write to backup replica
  - **Code 204 (session_expired)**: Use session_id after eviction
  - **Code 205 (duplicate_request)**: Resend same (client_id, request) pair
  - **Code 206 (stale_read)**: Request snapshot older than compacted
  - **Code 207 (checkpoint_in_progress)**: Send query during checkpoint write
  - **Code 208 (storage_unavailable)**: Unmount disk, trigger storage error
  - **Code 209 (index_rebuilding)**: Query during cold start index rebuild

#### Scenario: Resource error tests (codes 300-308)

- **WHEN** testing resource error handling
- **THEN** the following test cases SHALL be executed:
  - **Code 300 (too_many_events)**: Send batch with 15,000 events (exceeds 10,000)
  - **Code 301 (message_body_too_large)**: Body size = 11MB (exceeds message_body_size_max)
  - **Code 302 (result_set_too_large)**: Query returns 100,000 events (exceeds 81,000)
  - **Code 303 (too_many_clients)**: Open 10,001 clients (exceeds clients_max)
  - **Code 304 (rate_limit_exceeded)**: Send 100,000 requests/sec from one client
  - **Code 305 (memory_exhausted)**: Fill index to capacity, try to add entity
  - **Code 306 (disk_full)**: Fill disk to 100%, try to write
  - **Code 307 (too_many_queries)**: Submit 101 concurrent queries (exceeds 100)
  - **Code 308 (pipeline_full)**: Submit writes faster than pipeline can process

#### Scenario: Security error tests (codes 400-404)

- **WHEN** testing security error handling
- **THEN** the following test cases SHALL be executed:
  - **Code 400 (authentication_failed)**: Connect without valid mTLS certificate
  - **Code 401 (certificate_expired)**: Use certificate past expiration date
  - **Code 402 (certificate_revoked)**: Use revoked certificate (if CRL enabled)
  - **Code 403 (unauthorized)**: Attempt operation without proper authorization
  - **Code 404 (cluster_key_mismatch)**: Send message with wrong cluster key

#### Scenario: Internal error tests (codes 500-504)

- **WHEN** testing internal error detection
- **THEN** the following test cases SHALL be verified:
  - **Code 500 (internal_error)**: Unexpected error logged with file:line
  - **Code 501 (assertion_failed)**: Comptime or runtime assertion triggers
  - **Code 502 (unreachable)**: Code path marked @unreachable is hit
  - **Code 503 (corruption_detected)**: Checksum mismatch on read triggers
  - **Code 504 (invariant_violation)**: System invariant check fails

### Related Specifications

- See `specs/client-protocol/spec.md` for error response wire format
- See `specs/client-retry/spec.md` for detailed retry semantics
- See `specs/replication/spec.md` for VSR error conditions
- See `specs/query-engine/spec.md` for state machine error handling
- See `specs/observability/spec.md` for error metrics and logging
- See `specs/storage-engine/spec.md` for storage error conditions
