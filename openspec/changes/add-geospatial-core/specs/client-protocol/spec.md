# Client Protocol Specification

## ADDED Requirements

### Requirement: Custom Binary Protocol

The system SHALL use a custom binary protocol for client-server communication to maximize performance and minimize serialization overhead.

#### Scenario: Protocol design philosophy

- **WHEN** designing the client protocol
- **THEN** it SHALL follow TigerBeetle's approach:
  - Zero-copy message passing where possible
  - Fixed-size headers for predictable parsing
  - Batch-oriented API (amortize network/consensus costs)
  - Direct mapping to VSR message format

#### Scenario: Performance characteristics

- **WHEN** comparing to alternative protocols
- **THEN** the binary protocol SHALL provide:
  - Zero serialization overhead for 128-byte GeoEvent structs (wire format = memory format, direct pointer cast)
  - Zero intermediate allocations during encode/decode (messages use pre-allocated MessagePool buffers)
  - Sub-100μs client-side batch encoding (memcpy from application buffer to message buffer)
  - Wire format identical to in-memory format (`extern struct` layout guarantees)
- **AND** zero-copy is achieved via:
  - Client: `@memcpy(message.body, &events)` - single contiguous copy
  - Server: `const events = @as([*]GeoEvent, @ptrCast(message.body))` - zero-copy cast
  - No parsing, no intermediate objects, no heap allocation

### Requirement: Message Framing

The system SHALL use a simple framing protocol for client messages over TCP connections.

#### Scenario: Frame structure

- **WHEN** a client sends a message
- **THEN** the frame SHALL consist of:
  ```
  [Header (256 bytes)]
  [Body (variable, up to message_size_max)]
  ```
- **AND** header contains message metadata (operation, size, checksum)
- **AND** body contains the payload (batch of GeoEvents or query parameters)

#### Scenario: Header fields

- **WHEN** constructing a client message header
- **THEN** it SHALL contain:
  - `magic: u32` - Protocol magic number (0x41524348 = "ARCH")
  - `version: u16` - Protocol version (1)
  - `operation: u16` - Operation code (insert, query_uuid, query_radius, etc.)
  - `size: u32` - Total message size (header + body)
  - `checksum: u128` - Aegis-128L MAC of entire message
  - `client_id: u128` - Client session UUID (for idempotency)
  - `request_id: u64` - Client-assigned request ID (for matching responses)
  - `timeout_ms: u32` - Client timeout hint
  - `reserved: [remaining]u8` - Zero-filled reserved space

#### Scenario: Maximum message size

- **WHEN** enforcing message limits
- **THEN** `message_size_max` SHALL be 10MB (header + body)
- **AND** maximum body size is `message_size_max - 256 bytes (header)` = ~10.0MB
- **AND** theoretical maximum events = 10MB / 128 bytes = ~81,918 events
- **BUT** practical limit is 10,000 events per batch (enforced by query engine for memory management)
- **AND** clients exceeding 10,000 events receive `too_much_data` error
- **AND** clients exceeding 10MB total size receive `invalid_data_size` error

### Requirement: Operation Codes

The system SHALL define operation codes for all client operations matching the query engine capabilities.

#### Scenario: Write operations

- **WHEN** defining write operation codes
- **THEN** the following SHALL be supported:
  - `insert_events` (0x01) - Insert batch of GeoEvents
  - `upsert_events` (0x02) - Insert or update batch (LWW semantics)
  - `delete_entities` (0x03) - Delete entities by UUID (for GDPR right to erasure)

#### Scenario: Query operations

- **WHEN** defining query operation codes
- **THEN** the following SHALL be supported:
  - `query_uuid` (0x10) - Lookup entity by UUID
  - `query_radius` (0x11) - Find events within radius
  - `query_polygon` (0x12) - Find events within polygon
  - `query_uuid_batch` (0x13) - Lookup multiple UUIDs

#### Scenario: Admin operations

- **WHEN** defining admin operation codes
- **THEN** the following SHALL be supported:
  - `ping` (0x20) - Liveness check
  - `get_status` (0x21) - Cluster status query
  - `cleanup_expired` (0x30) - Explicit TTL expiration cleanup

### Requirement: Request/Response Pattern

The system SHALL use a request-response pattern with exactly-once semantics via client sessions.

#### Scenario: Client session lifecycle

- **WHEN** a client connects
- **THEN** it MUST generate a unique `client_id` (UUID v4)
- **AND** the server SHALL track this session for idempotency
- **AND** duplicate requests (same client_id + request_id) SHALL return cached response

#### Scenario: Request flow

- **WHEN** a client sends a request
- **THEN** the flow SHALL be:
  1. Client encodes operation + payload into message
  2. Client sends framed message over TCP
  3. Server validates checksum and operation
  4. Server routes to VSR state machine
  5. Server sends response with matching request_id
  6. Client matches response via request_id

#### Scenario: Timeout handling

- **WHEN** a client request times out
- **THEN** the client MAY retry with same request_id
- **AND** the server SHALL deduplicate via client session
- **AND** the server SHALL return the cached result if already executed

### Requirement: Client Session Management

The system SHALL manage client sessions with explicit limits and eviction policies.

#### Scenario: Session capacity limits

- **WHEN** tracking client sessions
- **THEN** the system SHALL:
  - Support maximum `client_sessions_max` concurrent sessions (default: 10,000)
  - Each session identified by unique `client_id` (u128)
  - Session tracks: last request_id, cached response, last activity timestamp

#### Scenario: Session eviction policy

- **WHEN** session capacity is reached AND new client connects
- **THEN** the system SHALL:
  - Evict the Least Recently Used (LRU) session
  - Return `session_expired` error to evicted client on next request
  - Log warning: "Client session evicted due to capacity"
  - Evicted client must generate new client_id and retry

#### Scenario: Session timeout

- **WHEN** a session is inactive for > `session_timeout` (default: 60 seconds)
- **THEN** the system MAY evict the session proactively
- **AND** client receives `session_expired` on next request
- **AND** client generates new client_id and retries

#### Scenario: Session creation rate limiting

- **WHEN** tracking session creation rates
- **THEN** the system SHALL:
  - Limit new session registrations to 10 per IP per minute
  - Return `resource_exhausted` error if rate limit exceeded
  - Log warning: "Session creation rate limit exceeded for IP: X.X.X.X"
  - Apply exponential backoff hint in error response
- **AND** this prevents session exhaustion DoS attacks
- **AND** legitimate clients rarely hit this limit (10 reconnects/minute is generous)

#### Scenario: Session persistence across view change

- **WHEN** view change occurs (new primary elected)
- **THEN** client sessions SHALL be preserved:
  - Sessions replicated as part of state machine state
  - New primary has complete session table
  - Clients do not need to re-register
- **AND** this is critical for exactly-once semantics

#### Scenario: Session eviction idempotency semantics (CRITICAL)

- **WHEN** a client session is evicted (capacity or timeout)
- **THEN** the following idempotency implications apply:
  1. **Cached response is lost**: The server no longer remembers the last response
  2. **Request ID reset is required**: Client MUST start new request_id sequence
  3. **Duplicate risk window**: During transition, same logical request might execute twice
- **AND** client SDK SHALL handle this safely:
  ```
  Client Session Eviction Recovery:
  1. Receive `session_expired` error
  2. Generate NEW client_id (u128 UUID)
  3. Reset request_id counter to 0
  4. Re-register with new client_id
  5. Retry the failed request with new (client_id, request_id=0)
  ```

#### Scenario: Idempotency guarantees with eviction

- **WHEN** session eviction occurs between request and retry
- **THEN** idempotency depends on operation type:
  ```
  | Operation      | Idempotent? | Safe to Retry?        | Notes                         |
  |----------------|-------------|------------------------|-------------------------------|
  | query_uuid     | Yes         | Always safe            | Read-only                     |
  | query_radius   | Yes         | Always safe            | Read-only                     |
  | query_polygon  | Yes         | Always safe            | Read-only                     |
  | insert_events  | NO          | Potentially dangerous  | May create duplicate events   |
  | upsert_events  | YES         | Always safe            | LWW semantics are idempotent  |
  | delete_entities| YES         | Always safe            | Deleting again is no-op       |
  ```

**⚠️ WARNING: `insert_events` is NOT idempotent and should be avoided in production!**

- **AND** `insert_events` after eviction MAY create duplicate events if:
  - Original request was committed before eviction
  - Client retries with new session after eviction
  - Server doesn't recognize retry (no cached response)
- **AND** applications SHOULD:
  - **USE `upsert_events` BY DEFAULT** - it is always safe to retry
  - Only use `insert_events` when duplicate detection is mandatory at DB level
  - If using `insert_events`: implement application-level deduplication
- **AND** SDK default operation SHOULD be `upsert_events`, not `insert_events`

#### Scenario: Client-side eviction detection

- **WHEN** implementing client SDKs
- **THEN** eviction detection SHALL be:
  1. Receive response with `status = session_expired` (5)
  2. SDK logs warning: "Session evicted, re-registering"
  3. SDK handles reconnection transparently
  4. For `insert_events`: SDK MAY surface warning to application
  5. For `upsert_events`/queries: Retry is transparent and safe

#### Scenario: Minimizing eviction impact

- **WHEN** operating to minimize eviction risk
- **THEN** operators SHALL:
  - Configure `client_sessions_max` based on expected client count
  - Monitor `archerdb_client_sessions_evictions_total` metric
  - Alert if eviction rate exceeds threshold
  - Consider increasing session capacity if evictions are frequent
- **AND** clients SHOULD:
  - Maintain connection activity (periodic pings)
  - Batch operations to reduce request frequency
  - Use connection pooling in SDK (single client_id per pool)

### Requirement: Error Responses

The system SHALL return structured error responses using TigerBeetle-style status codes.

#### Scenario: Error response format

- **WHEN** an operation fails
- **THEN** the response body SHALL contain (fixed 320 bytes):
  ```
  ErrorResponseBody (320 bytes, 8-byte aligned):
  ├─ status: u8             # Error code (see Error Code Taxonomy)
  ├─ primary_replica_id: u8 # Current primary (0xFF if unknown)
  ├─ retry_hint: u8         # 0=no retry, 1=retry immediately, 2=retry with backoff
  ├─ reserved1: u8          # Padding
  ├─ view: u32              # Current view number (8-byte aligned with above)
  ├─ retry_after_ms: u64    # Suggested wait before retry (0 if not applicable)
  ├─ message_len: u16       # Length of error message (max 256)
  ├─ version_min: u16       # Minimum supported protocol version (for negotiation)
  ├─ version_max: u16       # Maximum supported protocol version
  ├─ reserved2: [2]u8       # Padding to 8-byte alignment (reduced from 6)
  ├─ message: [256]u8       # UTF-8 error message (null-terminated)
  └─ reserved3: [40]u8      # Reserved for future use (padding to 320)
  ```
- **AND** total = 1+1+1+1+4+8+2+6+256+40 = 320 bytes
- **AND** this is distinct from QueryResponseHeader (32 bytes for successful queries)

#### Scenario: Partial batch failures

- **WHEN** a batch contains multiple operations and some fail
- **THEN** the response SHALL include:
  - `status_per_event: []u8` - Array of status codes (one per input event)
  - **AND** batch is atomic: all succeed or all fail (no partial commits)
  - **AND** first failure status is returned as primary error
  - **AND** per-event status codes identify which event caused the batch to fail
  - **AND** events after the first failure show `not_processed` status
- **CLARIFICATION**: Per-event status exists for debugging, NOT for partial success. If any event fails validation, the entire batch is rejected. This matches TigerBeetle's batch semantics.

### Requirement: Multi-Language SDK Support

The system SHALL provide official client SDKs for multiple programming languages.

#### Scenario: Supported languages

- **WHEN** official SDKs are released
- **THEN** the following languages SHALL be supported:
  - **Zig** - Reference implementation
  - **Java** - For JVM ecosystem
  - **Go** - For Go backends
  - **Python** - For data science and scripting
  - **Node.js** - For JavaScript/TypeScript backends

#### Scenario: SDK feature parity

- **WHEN** implementing SDKs
- **THEN** all SDKs SHALL provide:
  - Connection pooling and automatic reconnection
  - Request batching helpers
  - Async/await or promise-based APIs (where idiomatic)
  - Type-safe operation builders
  - Error handling with language-native exceptions/results

#### Scenario: SDK maintenance

- **WHEN** maintaining SDKs
- **THEN** the Zig SDK SHALL be the reference implementation
- **AND** other SDKs SHALL match its behavior exactly
- **AND** wire format compatibility SHALL be tested via cross-language integration tests

### Requirement: Connection Handshake Protocol

The system SHALL define a specific handshake sequence for establishing client connections.

#### Scenario: Initial connection handshake

- **WHEN** a client connects to the server
- **THEN** the handshake SHALL follow this sequence:
  ```
  1. Client → Server: TCP connect
  2. Client ↔ Server: TLS handshake (if --tls-required=true)
     - mTLS: Server verifies client certificate
     - Server verifies cluster ID in certificate (if encoded)
  3. Client → Server: Register request (operation=0x00)
     - Header: magic, version, operation=register, client_id
     - Body: empty or client metadata
  4. Server → Client: Register response
     - If new client_id: session created, status=ok
     - If existing client_id: session resumed, status=ok
     - If capacity full: oldest LRU session evicted first, then ok
     - If rate limited: status=resource_exhausted
  5. Connection is now ready for operations
  ```

#### Scenario: Register request format

- **WHEN** a client sends the register request
- **THEN** the message SHALL contain:
  ```
  Header (256 bytes):
  ├─ magic: u32 = 0x41524348 ("ARCH")
  ├─ version: u16 = 1
  ├─ operation: u16 = 0x00 (register)
  ├─ size: u32 = 256 (header only, no body)
  ├─ checksum: u128 = MAC of remaining header
  ├─ client_id: u128 = client-generated UUID
  ├─ request_id: u64 = 0 (first request)
  ├─ timeout_ms: u32 = 5000 (handshake timeout)
  └─ reserved: [remaining]u8 = zeros

  Body: empty (register has no body)
  ```

#### Scenario: Register response format

- **WHEN** the server responds to register
- **THEN** the response SHALL contain:
  ```
  Header (256 bytes):
  ├─ magic: u32 = 0x41524348
  ├─ version: u16 = 1
  ├─ operation: u16 = 0x00 (register)
  ├─ size: u32 = 256 + body_size
  ├─ checksum: u128
  ├─ client_id: u128 = echoed from request
  ├─ request_id: u64 = 0

  Body (32 bytes):
  ├─ status: u8 = ok (0) or error code
  ├─ cluster_id_valid: u8 = 1 if cluster matches
  ├─ primary_replica_id: u8 = current primary (0-5)
  ├─ replica_count: u8 = cluster size
  ├─ view: u32 = current view number
  ├─ session_number: u64 = assigned session number
  ├─ server_timestamp: u64 = server time (nanoseconds)
  └─ reserved: [6]u8 = zeros
  ```

#### Scenario: Handshake timeout

- **WHEN** handshake does not complete within timeout
- **THEN** the system SHALL:
  - Server: close TCP connection after 10 seconds of inactivity
  - Client: retry with exponential backoff (1s, 2s, 4s, max 30s)
  - Log warning if handshake timeouts are frequent

#### Scenario: Protocol version mismatch

- **WHEN** client sends unsupported protocol version
- **THEN** the server SHALL:
  - Respond with `status = invalid_operation` (2)
  - Include `supported_versions` in response body
  - Close connection after response
- **AND** client SDK SHALL use highest mutually supported version

#### Scenario: Cluster ID validation at handshake

- **WHEN** server receives register with mismatched cluster_id (from cert)
- **THEN** the server SHALL:
  - Respond with `status = cluster_mismatch` (208)
  - Log security event: "Client attempted connection to wrong cluster"
  - Close connection
- **AND** this prevents accidental cross-cluster connections

### Requirement: Connection Management

The system SHALL use persistent TCP connections with connection pooling.

#### Scenario: Connection lifecycle

- **WHEN** a client establishes a connection
- **THEN** it SHALL:
  1. Open TCP connection to any replica
  2. Complete TLS handshake (if enabled)
  3. Send register request to establish session
  4. Verify register response success
  5. Reuse connection for multiple requests

#### Scenario: Connection pooling

- **WHEN** implementing client SDKs
- **THEN** they SHOULD maintain a connection pool:
  - Default pool size: 10 connections per replica
  - Connections are lazily established
  - Idle connections are kept alive via periodic pings
  - Failed connections trigger automatic reconnection

#### Scenario: Load balancing

- **WHEN** a client has multiple replica addresses
- **THEN** it SHALL:
  - Connect to the current primary for writes
  - MAY connect to any replica for reads (stale reads acceptable)
  - Automatically discover new primary after view change
  - Use exponential backoff for failed connection attempts

### Requirement: Batch Encoding

The system SHALL encode batches of GeoEvents directly in the message body with zero-copy optimization.

#### Scenario: Insert batch encoding

- **WHEN** encoding an insert_events batch
- **THEN** the message body SHALL be:
  ```
  [count: u32]              # Number of events in batch
  [reserved: u32]           # Alignment padding
  [event_1: GeoEvent]       # 128 bytes
  [event_2: GeoEvent]       # 128 bytes
  ...
  [event_N: GeoEvent]       # 128 bytes
  ```
- **AND** events SHALL be packed contiguously
- **AND** total size = 8 + (count × 128) bytes

#### Scenario: Query parameter encoding

- **WHEN** encoding a query_radius operation
- **THEN** the message body SHALL contain:
  ```
  QueryRadius (64 bytes):
  ├─ lat_nano: i64          # Center latitude
  ├─ lon_nano: i64          # Center longitude
  ├─ radius_mm: u32         # Radius in millimeters
  ├─ start_time: u64        # Optional time range start (0 = no filter)
  ├─ end_time: u64          # Optional time range end (0 = no filter)
  ├─ limit: u32             # Max results (0 = default query_result_max = 81,000)
  ├─ reserved: [20]u8       # Padding to 64 bytes
  ```

#### Scenario: Polygon query encoding

- **WHEN** encoding a query_polygon operation
- **THEN** the message body SHALL contain:
  ```
  [vertex_count: u32]       # Number of polygon vertices
  [start_time: u64]         # Optional time filter
  [end_time: u64]           # Optional time filter
  [limit: u32]              # Max results
  [reserved: u32]           # Padding
  [vertices: []LatLon]      # Array of (lat_nano, lon_nano) pairs

  Where LatLon is:
  struct {
    lat_nano: i64,
    lon_nano: i64,
  }  // 16 bytes
  ```
- **AND** maximum vertex_count SHALL be 10,000

### Requirement: Response Encoding

The system SHALL encode query results as arrays of GeoEvents with metadata.

#### Scenario: Query result format

- **WHEN** returning query results
- **THEN** the response body SHALL be (with proper alignment):
  ```
  QueryResponseHeader (32 bytes, 8-byte aligned):
  ├─ status: u8             # Status code (ok, query_result_too_large, etc.)
  ├─ has_more: u8           # 1 if more results available via pagination
  ├─ reserved1: u16         # Explicit padding for 4-byte alignment
  ├─ count: u32             # Number of events returned (4-byte aligned)
  ├─ total_count: u64       # Total matching events (8-byte aligned)
  ├─ cursor_id: u128        # Last ID for pagination (16-byte aligned)
  └─ [no padding needed]    # 1+1+2+4+8+16 = 32 bytes

  [event_1: GeoEvent]       # 128 bytes
  [event_2: GeoEvent]       # 128 bytes
  ...
  [event_N: GeoEvent]       # 128 bytes
  ```
- **AND** all fields are naturally aligned for zero-copy access

#### Scenario: Empty result handling

- **WHEN** a query matches zero events
- **THEN** `status` SHALL be `ok`
- **AND** `count` SHALL be 0
- **AND** `total_count` SHALL be 0
- **AND** no event data is included in body

### Requirement: Error Code Taxonomy

The system SHALL use a comprehensive error code enum based on TigerBeetle's taxonomy, extended for geospatial operations.

#### Scenario: General error codes

- **WHEN** defining general error codes
- **THEN** the following SHALL be included:
  - `ok = 0` - Success
  - `too_much_data = 1` - Batch exceeds message_size_max
  - `invalid_operation = 2` - Unknown or malformed operation code
  - `invalid_data_size = 3` - Message size doesn't match expected format
  - `checksum_mismatch = 4` - Message checksum verification failed
  - `session_expired = 5` - Client session was evicted
  - `timeout = 6` - Operation timed out
  - `not_primary = 7` - Node is not the current primary (redirect)

#### Scenario: Geospatial error codes

- **WHEN** defining geospatial-specific error codes
- **THEN** the following SHALL be included:
  - `invalid_coordinates = 100` - Lat/lon out of valid range
  - `polygon_too_complex = 101` - Vertex count exceeds limit
  - `query_result_too_large = 102` - Result set exceeds max_result_size
  - `invalid_s2_cell = 103` - S2 cell ID is malformed
  - `radius_too_large = 104` - Radius exceeds maximum allowed
  - `entity_not_found = 105` - UUID lookup found no matching entity
  - `event_already_expired = 106` - Imported event's TTL has already expired
  - `query_timeout = 107` - Query exceeded CPU time budget
  - `polygon_too_simple = 108` - Polygon has fewer than 3 distinct vertices (duplicates removed)
  - `polygon_self_intersecting = 109` - Polygon edges cross each other
  - `radius_zero = 110` - Zero radius requires exact coordinate match (use uuid query)
  - `polygon_too_large = 111` - Polygon appears to wrap around world (malformed input)
  - `polygon_degenerate = 112` - Polygon has collinear points (zero area)
  - `polygon_empty = 113` - Polygon vertex array is empty (0 vertices provided)

#### Scenario: Cluster error codes

- **WHEN** defining cluster-related error codes
- **THEN** the following SHALL be included:
  - `cluster_unavailable = 200` - No quorum available
  - `view_change_in_progress = 201` - Cannot serve requests during view change
  - `replica_lagging = 202` - Replica too far behind (stale read rejected)
  - `index_capacity_exceeded = 203` - RAM index is at capacity, cannot insert new entities
  - `out_of_space = 204` - Disk is full, cannot write data
  - `too_many_queries = 205` - Query queue is full, try again later
  - `resource_exhausted = 206` - Internal resource pool exhausted (message buffers, etc.)
  - `backup_required = 207` - Writes halted pending backup (backup-mandatory mode)
  - `cluster_mismatch = 208` - Client certificate cluster ID doesn't match server
  - `checkpoint_lag_backpressure = 209` - Writes halted because index checkpoint is lagging too far behind WAL head

### Requirement: Protocol Versioning

The system SHALL support protocol version negotiation for future compatibility.

#### Scenario: Version negotiation

- **WHEN** a client connects
- **THEN** its first message SHALL include protocol version in header
- **AND** server SHALL reject incompatible versions with `invalid_operation`
- **AND** server SHALL support backward compatibility within major version

#### Scenario: Version 1 constraints

- **WHEN** implementing protocol version 1
- **THEN** the following are fixed:
  - Message header size: 256 bytes
  - GeoEvent size: 128 bytes
  - Checksum algorithm: Aegis-128L
  - All field offsets and sizes as specified

#### Scenario: Future version support

- **WHEN** introducing protocol version 2
- **THEN** servers MAY support both v1 and v2 simultaneously
- **AND** clients specify version in every message header
- **AND** breaking changes require major version bump
