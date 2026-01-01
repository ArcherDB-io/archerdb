# Client Retry Policy Specification

## ADDED Requirements

### Requirement: Automatic Retry in Client SDKs

The system SHALL implement automatic retry logic with exponential backoff in all official client SDKs, matching TigerBeetle's client behavior.

#### Scenario: Retry-enabled by default

- **WHEN** a client operation is submitted
- **THEN** the SDK SHALL automatically retry on transient errors
- **AND** retry is enabled by default (applications can opt-out if needed)
- **AND** retry preserves idempotency (same client_id + request_id)

#### Scenario: Retryable error classification

- **WHEN** an operation fails
- **THEN** the SDK SHALL classify errors as:
  - **Retryable (transient):**
    - `timeout` - Operation timed out
    - `view_change_in_progress` - Leader election in progress
    - `not_primary` - Connected to non-primary (redirect needed)
    - `cluster_unavailable` - No quorum available
    - `replica_lagging` - Replica too far behind
    - Network errors (connection reset, timeout, etc.)
  - **Non-retryable (permanent):**
    - `invalid_operation` - Malformed request
    - `invalid_coordinates` - Bad lat/lon values
    - `too_much_data` - Batch exceeds limits
    - `polygon_too_complex` - Too many vertices
    - `query_result_too_large` - Result set too big
    - `checksum_mismatch` - Data corruption
    - `invalid_data_size` - Size mismatch

### Requirement: Exponential Backoff Strategy

The system SHALL use exponential backoff with jitter for retry delays, matching TigerBeetle's approach.

#### Scenario: Backoff schedule

- **WHEN** retrying failed operations
- **THEN** delays SHALL follow:
  - Attempt 1: Immediate (0ms)
  - Attempt 2: 100ms + jitter
  - Attempt 3: 200ms + jitter
  - Attempt 4: 400ms + jitter
  - Attempt 5: 800ms + jitter
  - Attempt 6: 1600ms + jitter
- **AND** maximum retry attempts: 5 (total 6 attempts including initial)

#### Scenario: Jitter calculation

- **WHEN** calculating retry delay
- **THEN** jitter SHALL be:
  ```
  jitter = random(0, base_delay / 2)
  actual_delay = base_delay + jitter
  ```
- **AND** this prevents thundering herd (all clients retry simultaneously)

#### Scenario: Maximum total timeout

- **WHEN** retrying with timeout
- **THEN** total time including retries SHALL not exceed:
  - Client-specified timeout (from request header)
  - OR default 30 seconds if not specified
- **AND** SDK gives up after timeout even if retries remain

### Requirement: Primary Discovery

The system SHALL automatically discover and connect to the current primary after view changes.

#### Scenario: Initial connection

- **WHEN** client connects for the first time
- **THEN** it SHALL:
  - Try each configured replica address in order
  - Send request to first responsive replica
  - If response is `not_primary`, replica includes primary_id in response
  - Client reconnects to primary

#### Scenario: View change handling

- **WHEN** a view change occurs
- **THEN** the client SHALL:
  - Receive `view_change_in_progress` error
  - Wait (exponential backoff)
  - Retry request
  - Discover new primary from `not_primary` redirect
  - Update cached primary address

#### Scenario: Primary cache

- **WHEN** client learns current primary
- **THEN** it SHALL:
  - Cache primary address for subsequent requests
  - Connect directly to primary (skip non-primary replicas)
  - Invalidate cache on `not_primary` error
  - Re-discover primary when needed

### Requirement: Connection Pool Retry

The system SHALL integrate retry logic with connection pooling.

#### Scenario: Connection failure

- **WHEN** a connection fails (closed, timeout, etc.)
- **THEN** the SDK SHALL:
  - Remove failed connection from pool
  - Retry operation on a different connection
  - Establish new connection if pool exhausted
  - Apply exponential backoff between connection attempts

#### Scenario: Connection health checking

- **WHEN** managing connection pool
- **THEN** the SDK SHALL:
  - Send periodic pings on idle connections (every 30 seconds)
  - Close connections that don't respond to ping
  - Lazily reconnect when needed
  - Maintain at least 1 healthy connection

### Requirement: Idempotency Preservation

The system SHALL ensure retries are safe by preserving idempotency guarantees.

#### Scenario: Request ID stability

- **WHEN** retrying a failed operation
- **THEN** the SDK SHALL:
  - Use same `client_id` and `request_id` for all retry attempts
  - Server deduplicates via client sessions
  - If request already executed, server returns cached response
  - No double-execution of operations

#### Scenario: Session management

- **WHEN** client reconnects after crash
- **THEN** it SHALL:
  - Generate new `client_id` (new session)
  - Cannot rely on deduplication from old session
  - Applications must handle potential duplicates if client crashed between request and response

### Requirement: Timeout Handling

The system SHALL handle timeouts correctly across retries.

#### Scenario: Per-attempt timeout

- **WHEN** each attempt is made
- **THEN** individual attempt timeout SHALL be:
  ```
  attempt_timeout = min(
      remaining_total_timeout,
      base_timeout  // e.g., 5 seconds per attempt
  )
  ```

#### Scenario: Total timeout enforcement

- **WHEN** total timeout is exceeded
- **THEN** the SDK SHALL:
  - Cancel current attempt
  - NOT start new retry
  - Return timeout error to application
  - Include retry count in error context

### Requirement: Retry Configuration

The system SHALL allow applications to configure retry behavior per client instance.

#### Scenario: Retry configuration options

- **WHEN** creating a client instance
- **THEN** the following MAY be configured:
  ```
  Client.init(Config{
      .retry_enabled = true,           // Default: true
      .max_retries = 5,                // Default: 5
      .base_backoff_ms = 100,          // Default: 100ms
      .max_backoff_ms = 1600,          // Default: 1600ms
      .total_timeout_ms = 30000,       // Default: 30s
      .retry_jitter = true,            // Default: true
  })
  ```

#### Scenario: Per-operation retry override

- **WHEN** applications need different retry behavior per operation
- **THEN** SDKs MAY support:
  ```
  client.insert_events(events, .{
      .max_retries = 3,
      .timeout_ms = 10000,
  })
  ```

### Requirement: Retry Metrics and Logging

The system SHALL track retry-related metrics in client SDKs for debugging.

#### Scenario: Client-side retry metrics

- **WHEN** SDKs perform retries
- **THEN** they SHOULD expose metrics (if language ecosystem supports):
  ```
  archerdb_client_retries_total counter
  archerdb_client_retry_exhausted_total counter
  archerdb_client_primary_discoveries_total counter
  ```

#### Scenario: Retry logging

- **WHEN** retries occur
- **THEN** SDKs SHOULD log (at debug level):
  - Retry attempt number
  - Error that triggered retry
  - Backoff delay
  - Primary discovery events

### Requirement: Circuit Breaker (Optional)

The system MAY implement circuit breaker pattern to prevent cascading failures.

#### Scenario: Circuit breaker states

- **WHEN** circuit breaker is enabled
- **THEN** it SHALL have states:
  - **Closed**: Normal operation (requests flow)
  - **Open**: Failure threshold exceeded (requests fail fast)
  - **Half-Open**: Testing recovery (limited requests)

#### Scenario: Failure threshold

- **WHEN** failures occur
- **THEN** circuit opens if:
  - 50% of requests fail in 10-second window
  - AND at least 10 requests attempted
- **AND** circuit stays open for 30 seconds
- **AND** circuit enters half-open (allow 5 test requests)
- **AND** if test requests succeed, circuit closes

#### Scenario: Circuit breaker scope

- **WHEN** circuit breaker trips
- **THEN** it SHALL be per-replica (not global)
- **AND** client can try other replicas
- **AND** this isolates failures to specific nodes

### Requirement: Graceful Degradation

The system SHALL provide graceful degradation when all retry attempts are exhausted.

#### Scenario: Retry exhaustion

- **WHEN** all retries are exhausted
- **THEN** the SDK SHALL:
  - Return error to application with context:
    - Original error code
    - Number of attempts made
    - Last error from final attempt
    - Suggested action (check cluster status, verify network)
  - NOT crash or panic
  - Allow application to handle error

#### Scenario: Partial batch retry

- **WHEN** a large batch times out
- **THEN** applications MAY:
  - Split batch into smaller chunks
  - Retry with smaller batches
  - SDK provides helper: `split_batch(events, chunk_size)`

### Requirement: SDK Parity

The system SHALL ensure all official SDKs implement identical retry behavior.

#### Scenario: Cross-language consistency

- **WHEN** implementing retry in each SDK
- **THEN** behavior SHALL be identical across languages:
  - Same backoff schedule
  - Same retryable error classification
  - Same timeout handling
  - Same primary discovery logic
- **AND** cross-language integration tests SHALL verify parity

#### Scenario: Reference implementation

- **WHEN** implementing non-Zig SDKs
- **THEN** the Zig SDK SHALL be the reference
- **AND** other SDKs SHALL match its behavior exactly
- **AND** any deviation must be documented and justified
