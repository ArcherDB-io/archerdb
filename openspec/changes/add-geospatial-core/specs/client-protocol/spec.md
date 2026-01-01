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
  - Direct mapping to VSR/TigerBeetle-style framing (fixed header + body)

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

### Requirement: Wire Encoding

The system SHALL define a portable wire encoding for all multi-byte fields in headers and bodies.

#### Scenario: Endianness and integer representation

- **WHEN** encoding any multi-byte integer field in the client protocol header or body
- **THEN** it SHALL be encoded in little-endian byte order
- **AND** signed integers SHALL use two's complement representation
- **AND** all official SDKs SHALL follow this encoding regardless of host architecture
- **AND** big-endian platforms are not supported for zero-copy decoding; SDKs on such platforms MUST byteswap or refuse with a clear error

### Requirement: Exact Header Byte Layout

The system SHALL define a precise byte-level layout for the 256-byte message header with explicit field offsets.

#### Scenario: Header field offset table

- **WHEN** constructing or parsing a message header
- **THEN** fields SHALL be located at these exact byte offsets:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                    MESSAGE HEADER (256 bytes)                    │
  ├──────────┬───────┬───────────────────────────────────────────────┤
  │  Offset  │ Size  │ Field Name                                    │
  ├──────────┼───────┼───────────────────────────────────────────────┤
  │   0      │  16   │ checksum: u128 (Aegis-128L MAC of bytes 16-255) │
  │  16      │  16   │ checksum_padding: u128 (reserved for u256)    │
  │  32      │  16   │ checksum_body: u128 (Aegis-128L MAC of body)  │
  │  48      │  16   │ checksum_body_padding: u128 (reserved)        │
  │  64      │  16   │ nonce_reserved: u128 (future AEAD)            │
  │  80      │  16   │ cluster: u128 (cluster identifier)            │
  │  96      │   4   │ size: u32 (total message size in bytes)       │
  │ 100      │   4   │ magic: u32 (0x41524348 = "ARCH")              │
  │ 104      │   2   │ version: u16 (protocol version, currently 1)  │
  │ 106      │   2   │ operation: u16 (operation code)               │
  │ 108      │   4   │ timeout_ms: u32 (client timeout hint)         │
  │ 112      │  16   │ client_id: u128 (client UUID)                 │
  │ 128      │   8   │ request: u64 (request number for idempotency) │
  │ 136      │   8   │ view: u64 (current view, responses only)      │
  │ 144      │   8   │ op: u64 (operation number, responses only)    │
  │ 152      │   8   │ commit: u64 (commit number, responses only)   │
  │ 160      │  96   │ reserved: [96]u8 (must be zero)               │
  └──────────┴───────┴───────────────────────────────────────────────┘
  Total: 256 bytes (16-byte aligned for u128 fields)
  ```
- **AND** all u128 fields start at 16-byte aligned offsets (0, 16, 32, 48, 64, 80, 112)
- **AND** all u64 fields start at 8-byte aligned offsets (128, 136, 144, 152)
- **AND** all u32 fields start at 4-byte aligned offsets (96, 100, 108)
- **AND** reserved bytes MUST be zero on send and ignored on receive

#### Scenario: Checksum computation order

- **WHEN** computing the header checksum
- **THEN** the algorithm SHALL be:
  ```zig
  // Step 1: Zero the checksum field
  header.checksum = 0;

  // Step 2: Compute MAC over bytes 16-255 (everything after checksum field)
  const checksum_input = header_bytes[16..256];
  header.checksum = aegis128l_mac(checksum_input, cluster_key);

  // Step 3: Body checksum is computed separately
  header.checksum_body = aegis128l_mac(body_bytes, cluster_key);
  ```
- **AND** cluster_key is derived from the cluster UUID using HKDF
- **AND** checksum_padding fields are included in checksum computation but are always zero

#### Scenario: Field byte order verification test vectors

- **WHEN** validating protocol compliance
- **THEN** these test vectors SHALL pass:
  ```
  # Little-endian u32 encoding for magic number
  magic = 0x41524348 ("ARCH")
  wire bytes at offset 100: [0x48, 0x43, 0x52, 0x41]

  # Little-endian u16 encoding for version = 1
  version = 0x0001
  wire bytes at offset 104: [0x01, 0x00]

  # Little-endian u128 encoding for cluster_id
  cluster_id = 0x0102030405060708090a0b0c0d0e0f10
  wire bytes at offset 80: [0x10, 0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09,
                            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
  ```

### Requirement: UUID Batch Query Wire Format

The system SHALL define precise wire format for batch UUID lookups.

#### Scenario: query_uuid_batch request encoding

- **WHEN** encoding a batch UUID lookup request
- **THEN** the body SHALL be structured as:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │              QUERY_UUID_BATCH REQUEST BODY                       │
  ├──────────┬───────┬───────────────────────────────────────────────┤
  │  Offset  │ Size  │ Field                                         │
  ├──────────┼───────┼───────────────────────────────────────────────┤
  │   0      │   4   │ count: u32 (number of UUIDs, max 10000)       │
  │   4      │   4   │ reserved: u32 (must be zero)                  │
  │   8      │  16   │ entity_ids[0]: u128                           │
  │  24      │  16   │ entity_ids[1]: u128                           │
  │  ...     │  ...  │ ...                                           │
  │ 8+16*N   │  16   │ entity_ids[N-1]: u128                         │
  └──────────┴───────┴───────────────────────────────────────────────┘
  Total body size: 8 + (count × 16) bytes
  ```
- **AND** maximum count is 10,000 UUIDs per request
- **AND** duplicate UUIDs are allowed (will return duplicate results)

#### Scenario: query_uuid_batch response encoding

- **WHEN** encoding a batch UUID lookup response
- **THEN** the body SHALL be structured as:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │              QUERY_UUID_BATCH RESPONSE BODY                      │
  ├──────────┬───────┬───────────────────────────────────────────────┤
  │  Offset  │ Size  │ Field                                         │
  ├──────────┼───────┼───────────────────────────────────────────────┤
  │   0      │   4   │ found_count: u32 (entities found)             │
  │   4      │   4   │ not_found_count: u32 (entities not in index)  │
  │   8      │   8   │ reserved: [8]u8 (must be zero)                │
  │  16      │ 2*N   │ not_found_indices: [N]u16 (packed array)      │
  │ 16+2*N   │ pad   │ padding to 16-byte alignment                  │
  │ aligned  │ 128*M │ events[0..M]: [M]GeoEvent (found entities)    │
  └──────────┴───────┴───────────────────────────────────────────────┘
  Where N = not_found_count, M = found_count
  ```
- **AND** not_found_indices contains the 0-based indices of UUIDs not found
- **AND** events are ordered matching the request order (skipping not-found)

### Requirement: Query Response Alignment

The system SHALL ensure all query responses have proper memory alignment for zero-copy access.

#### Scenario: GeoEvent array alignment in response

- **WHEN** constructing query response bodies containing GeoEvent arrays
- **THEN** the GeoEvent array SHALL start at a 16-byte aligned offset within the body
- **AND** this enables direct `@ptrCast` to `[*]GeoEvent` without copying
- **AND** QueryResponseHeader is padded to ensure alignment:
  ```
  QueryResponseHeader size: 32 bytes (naturally 16-byte aligned)
  GeoEvent array starts at body offset 32 (16-byte aligned)
  ```

#### Scenario: Padding byte values

- **WHEN** padding is required for alignment
- **THEN** padding bytes SHALL be 0x00 (not 0xFF)
- **AND** receivers MUST ignore padding byte values
- **AND** senders MUST write 0x00 for deterministic checksums

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
- **AND** header contains message metadata (operation, size, checksums)
- **AND** body contains the payload (batch of GeoEvents or query parameters)

#### Scenario: Header fields

- **WHEN** constructing a client message header
- **THEN** it SHALL contain (within 256 bytes):
  - `checksum: u128` - Aegis-128L MAC of the header bytes after this field
  - `checksum_padding: u128` - Reserved for u256 checksum upgrades
  - `checksum_body: u128` - Aegis-128L MAC of the body (MAC of empty body is valid)
  - `checksum_body_padding: u128` - Reserved for u256 checksum upgrades
  - `nonce_reserved: u128` - Reserved for future AEAD encryption
  - `cluster: u128` - Cluster identifier (reject if mismatched)
  - `size: u32` - Total message size (header + body)
  - `magic: u32` - Protocol magic number (0x41524348 = "ARCH")
  - `version: u16` - Protocol version (1)
  - `operation: u16` - Operation code (register, insert_events, query_uuid, query_radius, etc.)
  - `timeout_ms: u32` - Client timeout hint
  - `client_id: u128` - Client UUID (for idempotency)
  - `request: u64` - Client-assigned request number (for matching responses + deduplication)
  - `reserved: [remaining]u8` - Zero-filled reserved space
- **AND** header checksum SHALL be verified before trusting `size`
- **AND** body checksum SHALL be verified after receiving the body bytes

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
  - `register` (0x00) - Establish or resume client session (handshake)
  - `ping` (0x20) - Liveness check
  - `get_status` (0x21) - Cluster status query
  - `cleanup_expired` (0x30) - Explicit TTL expiration cleanup

### Requirement: Request/Response Pattern

The system SHALL use a request-response pattern with exactly-once semantics via client sessions.

#### Scenario: Client session lifecycle

- **WHEN** a client connects
- **THEN** it MUST generate a unique `client_id` (UUID v4)
- **AND** the server SHALL track this session for idempotency
- **AND** duplicate requests (same client_id + request) SHALL return cached response

#### Scenario: Request flow

- **WHEN** a client sends a request
- **THEN** the flow SHALL be:
  1. Client encodes operation + payload into message
  2. Client sends framed message over TCP
  3. Server validates header checksum and `cluster` before trusting `size`
  4. Server receives body bytes and validates `checksum_body`
  5. Server routes to VSR state machine
  6. Server sends response with matching request
  7. Client matches response via request

#### Scenario: Timeout handling

- **WHEN** a client request times out
- **THEN** the client MAY retry with the same request
- **AND** the server SHALL deduplicate via client session
- **AND** the server SHALL return the cached result if already executed

### Requirement: Client Session Management

The system SHALL manage client sessions with explicit limits and eviction policies.

#### Scenario: Session capacity limits

- **WHEN** tracking client sessions
- **THEN** the system SHALL:
  - Support maximum `client_sessions_max` concurrent sessions (default: 10,000)
  - Each session identified by unique `client_id` (u128)
  - Session tracks: last request, cached response, last activity timestamp

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
  2. **Request number reset is required**: Client MUST start a new request sequence
  3. **Duplicate risk window**: During transition, same logical request might execute twice
- **AND** client SDK SHALL handle this safely:
  ```
  Client Session Eviction Recovery:
  1. Receive `session_expired` error
  2. Generate NEW client_id (u128 UUID)
  3. Reset request counter to 0
  4. Re-register with new client_id
  5. Retry the failed request with new (client_id, request=0)
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
     - Header: cluster, magic/version, operation=register, client_id, request=0, checksums
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
  ├─ checksum: u128 = MAC of the header bytes after this field
  ├─ checksum_padding: u128 = reserved
  ├─ checksum_body: u128 = MAC of empty body
  ├─ checksum_body_padding: u128 = reserved
  ├─ nonce_reserved: u128 = zeros
  ├─ cluster: u128 = client-configured cluster_id
  ├─ size: u32 = 256 (header only, no body)
  ├─ magic: u32 = 0x41524348 ("ARCH")
  ├─ version: u16 = 1
  ├─ operation: u16 = 0x00 (register)
  ├─ timeout_ms: u32 = 5000 (handshake timeout)
  ├─ client_id: u128 = client-generated UUID
  ├─ request: u64 = 0 (first request)
  └─ reserved: [remaining]u8 = zeros

  Body: empty (register has no body)
  ```

#### Scenario: Register response format

- **WHEN** the server responds to register
- **THEN** the response SHALL contain:
  ```
  Header (256 bytes):
  ├─ checksum: u128
  ├─ checksum_padding: u128
  ├─ checksum_body: u128
  ├─ checksum_body_padding: u128
  ├─ nonce_reserved: u128
  ├─ cluster: u128 = echoed from request
  ├─ size: u32 = 256 + body_size
  ├─ magic: u32 = 0x41524348
  ├─ version: u16 = 1
  ├─ operation: u16 = 0x00 (register)
  ├─ timeout_ms: u32 = 0 (ignored in responses)
  ├─ client_id: u128 = echoed from request
  ├─ request: u64 = 0

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

### Requirement: Wire Format Migration Procedures

The system SHALL define explicit procedures for migrating between protocol versions.

#### Scenario: Version upgrade procedure (v1 → v2)

- **WHEN** upgrading the cluster from protocol v1 to v2
- **THEN** the migration procedure SHALL be:
  ```
  PROTOCOL VERSION UPGRADE PROCEDURE (v1 → v2)
  ════════════════════════════════════════════

  PHASE 1: Preparation (no downtime)
  ─────────────────────────────────────────
  1. Verify all clients support v2 (SDK version check)
  2. Update client SDKs to v2-capable version (supports both v1 and v2)
  3. Configure clients with version_preference=v1 (continue using v1)
  4. Monitor: All clients should report v1 in metrics

  PHASE 2: Server Upgrade (rolling restart)
  ─────────────────────────────────────────
  5. For each replica in order (standby first, primary last):
     a. Stop replica gracefully
     b. Upgrade binary to v2-capable version
     c. Start replica with --protocol-versions=1,2
     d. Wait for state sync to complete
     e. Verify replica healthy in cluster
  6. Cluster now accepts both v1 and v2 clients

  PHASE 3: Client Migration (gradual)
  ─────────────────────────────────────────
  7. Update client configurations: version_preference=v2
  8. Monitor: Clients should start reporting v2 in metrics
  9. Track v1 client count → should decrease to 0

  PHASE 4: Cleanup (optional, enables v2-only features)
  ─────────────────────────────────────────
  10. Once all clients are v2:
      a. Restart replicas with --protocol-versions=2
      b. v1 clients will receive version_not_supported error
      c. Enable v2-only features if any
  ```
- **AND** rollback is possible at any phase by reversing steps
- **AND** mixed v1/v2 operation is supported indefinitely

#### Scenario: Version downgrade procedure (emergency)

- **WHEN** emergency downgrade from v2 to v1 is required
- **THEN** the procedure SHALL be:
  ```
  EMERGENCY DOWNGRADE PROCEDURE
  ═════════════════════════════

  WARNING: Only possible if v2 data is backward-compatible with v1

  1. Update all clients to version_preference=v1
  2. Wait for in-flight v2 requests to complete (monitor metrics)
  3. Rolling restart replicas with --protocol-versions=1
  4. Verify all clients reconnect successfully

  IF v2 introduced incompatible wire format changes:
  - Downgrade is NOT possible without data migration
  - Restore from pre-upgrade backup instead
  ```

#### Scenario: Version compatibility matrix

- **WHEN** determining version compatibility
- **THEN** the following matrix SHALL apply:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │              CLIENT/SERVER VERSION COMPATIBILITY                 │
  ├──────────────┬──────────────┬──────────────┬────────────────────┤
  │ Client       │ Server       │ Compatible?  │ Notes              │
  ├──────────────┼──────────────┼──────────────┼────────────────────┤
  │ v1           │ v1 only      │ ✓ Yes        │ Normal operation   │
  │ v1           │ v1,v2        │ ✓ Yes        │ Server accepts v1  │
  │ v1           │ v2 only      │ ✗ No         │ version_not_supported │
  │ v2           │ v1 only      │ ✗ No         │ version_not_supported │
  │ v2           │ v1,v2        │ ✓ Yes        │ Server accepts v2  │
  │ v2           │ v2 only      │ ✓ Yes        │ Normal operation   │
  └──────────────┴──────────────┴──────────────┴────────────────────┘
  ```

### Requirement: Client-Side Batching Best Practices

The system SHALL document optimal batching strategies for client SDKs.

#### Scenario: Optimal batch size selection

- **WHEN** configuring client batch sizes
- **THEN** the following guidelines SHALL apply:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │              BATCH SIZE SELECTION GUIDE                          │
  ├─────────────────────┬───────────────────────────────────────────┤
  │ Scenario            │ Recommended Batch Size                    │
  ├─────────────────────┼───────────────────────────────────────────┤
  │ High-throughput     │ 5,000 - 10,000 events                     │
  │ ingestion           │ Maximizes consensus amortization          │
  ├─────────────────────┼───────────────────────────────────────────┤
  │ Low-latency         │ 100 - 500 events                          │
  │ real-time tracking  │ Balances latency vs throughput            │
  ├─────────────────────┼───────────────────────────────────────────┤
  │ Interactive         │ 1 - 50 events                             │
  │ applications        │ Minimizes perceived latency               │
  ├─────────────────────┼───────────────────────────────────────────┤
  │ Bulk import         │ 10,000 events (maximum)                   │
  │ (historical data)   │ Maximum throughput, latency unimportant   │
  └─────────────────────┴───────────────────────────────────────────┘
  ```

#### Scenario: Time-based batching

- **WHEN** accumulating events for batching
- **THEN** SDKs SHOULD implement time-based flushing:
  ```zig
  const BatchConfig = struct {
      max_events: u32 = 1000,        // Flush when batch reaches this size
      max_wait_ms: u32 = 100,        // Flush after this delay even if not full
      min_events: u32 = 1,           // Minimum events before flushing
  };

  // Batch is flushed when ANY condition is met:
  // 1. batch.len >= max_events
  // 2. time_since_first_event >= max_wait_ms
  // 3. client.flush() called explicitly
  ```
- **AND** max_wait_ms prevents indefinite buffering for low-rate producers
- **AND** max_events prevents memory exhaustion for high-rate producers

#### Scenario: Connection pooling recommendations

- **WHEN** implementing client connection pools
- **THEN** the following configuration SHALL be recommended:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │              CONNECTION POOL SIZING                              │
  ├─────────────────────┬───────────────────────────────────────────┤
  │ Workload            │ Connections per Replica                   │
  ├─────────────────────┼───────────────────────────────────────────┤
  │ Light (< 1K ops/s)  │ 1 connection                              │
  │ Medium (1K-10K/s)   │ 2-4 connections                           │
  │ Heavy (10K-100K/s)  │ 8-16 connections                          │
  │ Extreme (> 100K/s)  │ 32 connections max                        │
  └─────────────────────┴───────────────────────────────────────────┘

  Notes:
  - More connections = more parallelism but more server resources
  - Pipeline depth of 4-8 per connection is typically optimal
  - Monitor client_sessions_active metric to tune
  ```

#### Scenario: Backpressure handling

- **WHEN** clients receive backpressure signals
- **THEN** they SHALL implement exponential backoff:
  ```
  Backpressure Response Strategy:
  ────────────────────────────────
  Error Code             │ Action
  ───────────────────────┼─────────────────────────────────
  too_many_queries       │ Wait 10-100ms, retry with backoff
  resource_exhausted     │ Wait 100-1000ms, reduce batch size
  cluster_unavailable    │ Wait 1-10s, reconnect to different replica
  view_change_in_progress│ Wait 100-500ms, retry same request
  not_primary            │ Reconnect to new primary immediately
  timeout                │ Retry with same request number (idempotent)

  Exponential Backoff Formula:
  delay = min(base_delay × 2^attempt, max_delay) + jitter
  where jitter = random(0, delay × 0.1)
  ```

### Requirement: Rate Limiting

The system SHALL implement server-side rate limiting to prevent abuse.

#### Scenario: Per-client rate limits

- **WHEN** enforcing rate limits per client session
- **THEN** the following limits SHALL apply:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │              PER-CLIENT RATE LIMITS                              │
  ├─────────────────────┬───────────────────────────────────────────┤
  │ Limit Type          │ Default Value                             │
  ├─────────────────────┼───────────────────────────────────────────┤
  │ Requests/second     │ 1,000 (configurable)                      │
  │ Events/second       │ 100,000 (configurable)                    │
  │ Queries/second      │ 100 (spatial queries are expensive)       │
  │ New sessions/minute │ 10 per IP (prevent session exhaustion)    │
  └─────────────────────┴───────────────────────────────────────────┘
  ```
- **AND** exceeding limits returns `resource_exhausted` with retry_after_ms hint
- **AND** limits are configurable via `--rate-limit-*` flags

#### Scenario: Global rate limiting

- **WHEN** protecting cluster-wide resources
- **THEN** the following global limits SHALL apply:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │              GLOBAL RATE LIMITS (per node)                       │
  ├─────────────────────┬───────────────────────────────────────────┤
  │ Limit Type          │ Default Value                             │
  ├─────────────────────┼───────────────────────────────────────────┤
  │ Total requests/sec  │ 50,000 (hardware dependent)               │
  │ Total events/sec    │ 1,000,000 (write throughput target)       │
  │ Concurrent queries  │ 100 (memory bounded)                      │
  │ Pending writes      │ 1,000 (pipeline depth)                    │
  └─────────────────────┴───────────────────────────────────────────┘
  ```
- **AND** when global limits are reached, new requests receive `too_many_queries`
- **AND** existing in-flight requests are not affected
