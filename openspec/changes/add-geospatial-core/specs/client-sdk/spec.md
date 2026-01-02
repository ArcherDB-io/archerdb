# Client SDK Specification

This specification defines the architecture and behavior of ArcherDB client SDKs across all supported languages (Zig, Java, Go, Python, Node.js).

---

## ADDED Requirements

### Requirement: SDK Core Architecture

The client SDK SHALL provide a consistent interface across all languages with automatic failover, session management, and batch operations.

#### Scenario: SDK initialization

- **WHEN** a client SDK is initialized
- **THEN** it SHALL accept configuration:
  ```
  Config {
    addresses: []Address,        // All replica addresses
    cluster_id: u128,            // For connection validation
    tls_cert_path: ?string,      // Client certificate (mTLS)
    tls_key_path: ?string,       // Client private key
    tls_ca_path: ?string,        // CA certificate for server validation
    connect_timeout_ms: u32,     // Default: 5000
    request_timeout_ms: u32,     // Default: 30000
  }
  ```
- **AND** SDK SHALL validate configuration before connecting
- **AND** invalid configuration SHALL return clear error messages

#### Scenario: Connection lifecycle

- **WHEN** a client connects to an ArcherDB cluster
- **THEN** the SDK SHALL:
  1. Probe all provided replica addresses in parallel
  2. Identify current primary via `ping` response or `not_primary` error
  3. Establish persistent TCP connection to primary
  4. Complete TLS handshake if configured
  5. Send `register` operation to obtain session ID
  6. Store session ID for request idempotency
- **AND** connection timeout SHALL be configurable (default: 5 seconds)
- **AND** failed connection SHALL return `connection_failed` error

#### Scenario: Automatic primary discovery

- **WHEN** SDK receives `not_primary` error (code 7)
- **THEN** it SHALL:
  1. Parse `primary_id` hint from error response (if present)
  2. Disconnect from current replica
  3. Connect to new primary address
  4. Re-register session if connection was lost
  5. Retry the failed operation automatically
- **AND** retry limit SHALL be 3 attempts per operation
- **AND** exhausted retries SHALL return `cluster_unavailable` to application

#### Scenario: View change handling

- **WHEN** a view change occurs during operation
- **THEN** the SDK SHALL:
  1. Receive `view_change_in_progress` error (code 201)
  2. Wait with exponential backoff (base: 100ms, max: 2s)
  3. Retry operation to same address (may be new primary)
  4. Follow `not_primary` redirect if needed
- **AND** operations are safe to retry (server ensures idempotency)

### Requirement: Session Management

The SDK SHALL manage client sessions for request idempotency and efficient server-side tracking.

#### Scenario: Session registration

- **WHEN** SDK initializes a new connection
- **THEN** it SHALL:
  1. Generate random `client_id: u128` (persistent per SDK instance)
  2. Send `register` operation to cluster
  3. Receive `session: u64` from server
  4. Store (client_id, session) pair for all subsequent requests
- **AND** session persists across reconnections to same cluster
- **AND** session expires after `session_timeout_ms` (default: 60 seconds) of inactivity

#### Scenario: Request numbering

- **WHEN** sending requests
- **THEN** SDK SHALL:
  1. Maintain monotonic `request_number: u64` per session
  2. Increment request_number for each new operation
  3. Include (client_id, request_number) in request header
  4. Server uses this for duplicate detection
- **AND** if server returns cached response, SDK returns to application (no re-execution)

#### Scenario: Session expiration handling

- **WHEN** server returns `session_expired` error (code 5)
- **THEN** SDK SHALL:
  1. Clear local session state
  2. Re-register with `register` operation
  3. Retry failed operation with new session
- **AND** application receives transparent retry (no error surfaced)

### Requirement: Batch Operations API

The SDK SHALL provide efficient batching APIs for high-throughput event ingestion.

#### Scenario: Batch builder pattern

- **WHEN** application accumulates events
- **THEN** SDK SHALL provide:
  ```
  // Create empty batch
  batch = client.create_batch()

  // Add events (validates immediately)
  result = batch.add(event)  // Returns validation error or ok

  // Check current batch state
  count = batch.count()       // Number of events in batch
  is_full = batch.is_full()   // True if count >= 10,000

  // Send batch to cluster
  results = batch.commit()    // Blocks until replicated

  // Get per-event results
  for result in results:
      if result.error:
          handle_error(result.index, result.error)
  ```
- **AND** batch SHALL enforce maximum 10,000 events
- **AND** adding to full batch SHALL return `batch_full` error
- **AND** commit on empty batch SHALL return immediately with empty results

#### Scenario: Batch commit semantics

- **WHEN** `batch.commit()` is called
- **THEN** SDK SHALL:
  1. Serialize events to wire format
  2. Send single `upsert_events` (or `insert_events`) operation
  3. Wait for quorum replication (blocking)
  4. Parse per-event error codes from response
  5. Return structured results to application
- **AND** commit timeout SHALL be configurable (default: 30 seconds)
- **AND** timeout SHALL return `timeout` error (operation may or may not have committed)

#### Scenario: Async batch API (optional)

- **WHEN** SDK supports async/await pattern (Go, Python, Node.js)
- **THEN** it SHALL additionally provide:
  ```
  // Non-blocking commit
  future = batch.commit_async()

  // Wait for result
  results = await future

  // Or with callback
  batch.commit_async(callback=handle_results)
  ```
- **AND** async API SHALL have same semantics as sync API

### Requirement: Query Operations API

The SDK SHALL provide type-safe APIs for all query types.

#### Scenario: UUID lookup API

- **WHEN** application queries by entity UUID
- **THEN** SDK SHALL provide:
  ```
  // Single lookup
  event = client.get_latest(entity_id)  // Returns GeoEvent or null

  // Batch lookup
  events = client.get_latest_batch(entity_ids)  // Returns map[uuid]GeoEvent
  ```
- **AND** batch lookup SHALL be limited to 10,000 UUIDs per call

#### Scenario: Radius query API

- **WHEN** application queries by location radius
- **THEN** SDK SHALL provide:
  ```
  results = client.query_radius(
      center_lat: f64,        // Degrees (SDK converts to nanodegrees)
      center_lon: f64,        // Degrees
      radius_meters: f64,     // Meters (SDK converts to millimeters)
      options: QueryOptions {
          limit: u32,         // Default: 81000
          cursor: ?u128,      // For pagination
          time_start: ?u64,   // Optional time filter (nanoseconds)
          time_end: ?u64,
          group_id: ?u64,     // Optional group filter
      }
  )

  // Results structure
  results.events: []GeoEvent
  results.has_more: bool
  results.cursor: ?u128       // Use for next page if has_more
  ```
- **AND** coordinates SHALL be validated (lat: -90 to +90, lon: -180 to +180)
- **AND** invalid coordinates SHALL return `invalid_coordinates` error

#### Scenario: Polygon query API

- **WHEN** application queries by polygon
- **THEN** SDK SHALL provide:
  ```
  results = client.query_polygon(
      vertices: []LatLon,     // CCW winding order
      options: QueryOptions   // Same as radius query
  )
  ```
- **AND** polygon SHALL be validated:
  - Minimum 3 vertices
  - Maximum 10,000 vertices
  - No self-intersection
- **AND** invalid polygon SHALL return specific error code

#### Scenario: Pagination handling

- **WHEN** query returns `has_more = true`
- **THEN** application SHALL paginate:
  ```
  cursor = null
  all_events = []

  loop {
      results = client.query_radius(..., cursor: cursor)
      all_events.extend(results.events)

      if !results.has_more:
          break
      cursor = results.cursor
  }
  ```
- **AND** cursor is opaque to application (SDK handles encoding)

### Requirement: Delete Operations API

The SDK SHALL provide APIs for GDPR-compliant entity deletion.

#### Scenario: Delete entities API

- **WHEN** application deletes entities
- **THEN** SDK SHALL provide:
  ```
  result = client.delete_entities(entity_ids)

  result.deleted_count: u32       // Successfully deleted
  result.not_found_count: u32     // Entity IDs not in index
  ```
- **AND** delete is idempotent (deleting non-existent entity is not an error)
- **AND** maximum 10,000 entities per delete call

### Requirement: Error Handling

The SDK SHALL provide structured error handling with actionable error types.

#### Scenario: Error type hierarchy

- **WHEN** an operation fails
- **THEN** SDK SHALL return typed errors:
  ```
  ArcherDBError:
    - ConnectionError:
        - ConnectionFailed
        - ConnectionTimeout
        - TLSError
    - ClusterError:
        - ClusterUnavailable
        - ViewChangeInProgress
        - NotPrimary
    - ValidationError:
        - InvalidCoordinates
        - PolygonTooComplex
        - BatchTooLarge
        - InvalidEntityId
    - OperationError:
        - Timeout
        - QueryResultTooLarge
        - OutOfSpace
        - SessionExpired
  ```
- **AND** each error SHALL include:
  - Error code (u16)
  - Human-readable message
  - Retryable flag (bool)

#### Scenario: Retryable errors

- **WHEN** an error is retryable
- **THEN** SDK SHALL indicate via `error.is_retryable()`:
  - `view_change_in_progress` → retryable
  - `not_primary` → retryable (SDK handles automatically)
  - `timeout` → retryable (with caution - may have committed)
  - `cluster_unavailable` → retryable (with backoff)
  - `invalid_coordinates` → NOT retryable (client bug)
  - `out_of_space` → NOT retryable (operator intervention)

### Requirement: Connection Pooling

The SDK SHALL support connection pooling for multi-threaded applications.

#### Scenario: Thread-safe client

- **WHEN** multiple threads use the same client instance
- **THEN** SDK SHALL:
  1. Maintain internal connection pool
  2. Serialize requests to maintain ordering per thread
  3. Use thread-local or pooled buffers for serialization
  4. Ensure session request numbers are atomically incremented
- **AND** default pool size SHALL be 1 (single connection)
- **AND** pool size SHALL be configurable for high-throughput scenarios

#### Scenario: Connection health monitoring

- **WHEN** SDK maintains open connections
- **THEN** it SHALL:
  1. Send periodic `ping` operations (every 30 seconds)
  2. Detect failed connections via timeout
  3. Automatically reconnect on failure
  4. Update primary discovery on reconnect
- **AND** health check failures SHALL trigger reconnection

### Requirement: Observability

The SDK SHALL expose metrics and logging for operational visibility.

#### Scenario: SDK metrics

- **WHEN** application monitors SDK health
- **THEN** SDK SHALL expose:
  ```
  archerdb_client_requests_total{operation, status}
  archerdb_client_request_duration_seconds{operation}
  archerdb_client_connections_active
  archerdb_client_reconnections_total
  archerdb_client_session_renewals_total
  ```
- **AND** metrics format SHALL match application's metrics library (Prometheus, OpenTelemetry, etc.)

#### Scenario: SDK logging

- **WHEN** SDK performs internal operations
- **THEN** it SHALL log at appropriate levels:
  - DEBUG: Connection state changes, request/response details
  - INFO: Successful connection, session registration
  - WARN: Reconnection, view change handling, retries
  - ERROR: Connection failures, unrecoverable errors
- **AND** logging SHALL be pluggable (application provides logger)

### Requirement: Language-Specific Considerations

The SDK SHALL follow idiomatic patterns for each target language.

#### Scenario: Zig SDK

- **WHEN** implementing Zig SDK
- **THEN** it SHALL:
  - Use `std.mem.Allocator` for all allocations
  - Return errors via error union (`!T`)
  - Use comptime for wire format validation
  - Provide async I/O integration with `std.event.Loop`

#### Scenario: Go SDK

- **WHEN** implementing Go SDK
- **THEN** it SHALL:
  - Use `context.Context` for cancellation
  - Return `(result, error)` tuples
  - Use `sync.Pool` for buffer reuse
  - Support `database/sql` driver interface (optional)

#### Scenario: Java SDK

- **WHEN** implementing Java SDK
- **THEN** it SHALL:
  - Use `CompletableFuture` for async operations
  - Throw checked exceptions for recoverable errors
  - Support Netty for async I/O
  - Provide Spring Boot integration (optional)

#### Scenario: Python SDK

- **WHEN** implementing Python SDK
- **THEN** it SHALL:
  - Support both sync and async (`asyncio`) APIs
  - Use type hints (PEP 484)
  - Support context managers for connection lifecycle
  - Provide pandas integration for bulk operations (optional)

#### Scenario: Node.js SDK

- **WHEN** implementing Node.js SDK
- **THEN** it SHALL:
  - Use Promises/async-await pattern
  - Support TypeScript with full type definitions
  - Use Node.js native TLS
  - Provide streaming API for large result sets (optional)

### Requirement: SDK Versioning

The SDK SHALL maintain compatibility with server versions.

#### Scenario: Version compatibility

- **WHEN** SDK connects to server
- **THEN** it SHALL:
  1. Exchange protocol version during handshake
  2. Verify wire format compatibility
  3. Warn if SDK version is older than server
  4. Error if wire format is incompatible
- **AND** SDK major version SHALL match server major version

#### Scenario: SDK release policy

- **WHEN** releasing SDK updates
- **THEN** release policy SHALL be:
  - Patch versions: Bug fixes, no API changes
  - Minor versions: New features, backward compatible
  - Major versions: Breaking changes, requires code updates
- **AND** SDK SHALL follow semantic versioning (SemVer)

### Related Specifications

- See `specs/client-protocol/spec.md` for wire format and message encoding
- See `specs/client-retry/spec.md` for retry logic and exponential backoff
- See `specs/error-codes/spec.md` for error handling in SDKs
- See `specs/api-versioning/spec.md` for SDK version compatibility requirements
