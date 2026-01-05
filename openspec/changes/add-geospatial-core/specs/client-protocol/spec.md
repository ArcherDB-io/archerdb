# Client Protocol Specification

## ADDED Requirements

### Requirement: Custom Binary Protocol

The system SHALL use a custom binary protocol for client-server communication to maximize performance and minimize serialization overhead.

#### Scenario: Scope of this specification

- **WHEN** interpreting protocol requirements in this file
- **THEN** they SHALL apply to **client-facing** TCP connections (SDK ↔ replica)
- **AND** inter-replica VSR messages are specified separately in `specs/replication/spec.md`
- **AND** both protocols use fixed-size 256-byte headers and share checksum primitives, but header field layouts and semantics MAY differ

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

### Requirement: UUID Single Query Wire Format

The system SHALL define precise wire format for single UUID lookups.

#### Scenario: query_uuid request encoding

- **WHEN** encoding a single UUID lookup request
- **THEN** the body SHALL be structured as:
  ```
  QueryUuidRequest (32 bytes):
  ├─ entity_id: u128       # UUID to look up
  ├─ reserved: [16]u8      # Padding to 32 bytes (must be zero)
  ```
- **AND** total body size is exactly 32 bytes
- **AND** this is more efficient than query_uuid_batch for single lookups

#### Scenario: query_uuid response encoding

- **WHEN** encoding a single UUID lookup response
- **THEN** the body SHALL be structured as:
  ```
  QueryUuidResponse (variable):
  ├─ status: u8            # 0 = found, 200 = entity_not_found (see error-codes/spec.md)
  ├─ reserved1: [15]u8     # Padding to 16-byte alignment
  ├─ event: GeoEvent       # 128 bytes (only if status = 0)
  ```
- **AND** total body size is 16 bytes if not found, 144 bytes if found
- **AND** status = 0 (ok) means entity was found and event is included
- **AND** status = 200 (entity_not_found) means entity does not exist

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
- **AND** count = 0 (empty batch) is valid: returns empty response with found_count=0, not_found_count=0

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
  - `query_latest` (0x14) - Retrieve most recent events globally or by group (see query-engine/spec.md)

#### Scenario: Admin operations

- **WHEN** defining admin operation codes
- **THEN** the following SHALL be supported:
  - `register` (0x00) - Establish or resume client session (handshake)
  - `ping` (0x20) - Liveness check
  - `get_status` (0x21) - Cluster status query
  - `cleanup_expired` (0x30) - Explicit TTL expiration cleanup

#### Scenario: Reserved operation code ranges

- **WHEN** allocating operation codes for future extensions
- **THEN** the following ranges SHALL be reserved:
  - `0x00` - Session/handshake operations (register)
  - `0x01-0x0F` - Write operations (insert, upsert, delete, future mutations)
  - `0x10-0x1F` - Query operations (uuid, radius, polygon, future spatial queries)
  - `0x20-0x2F` - Admin/status operations (ping, get_status, future diagnostics)
  - `0x30-0x3F` - Maintenance operations (cleanup_expired, future compaction triggers)
  - `0x40-0xEF` - Reserved for future use (MUST return `invalid_operation` error)
  - `0xF0-0xFF` - Reserved for internal/debug operations (not exposed to clients)
- **AND** new operations MUST be allocated within their semantic range
- **AND** unknown operation codes MUST return `invalid_operation` (2) error

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

- **WHEN** a session is inactive for > `session_timeout_ms` (default: 60,000ms = 60 seconds)
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
- **AND** total = 1+1+1+1+4+8+2+2+2+2+256+40 = 320 bytes (status through reserved3)
- **AND** this is distinct from QueryResponseHeader (32 bytes for successful queries)

#### Scenario: Partial batch failures

- **WHEN** a batch contains multiple operations and some fail validation
- **THEN** the response body SHALL be (variable size):
  ```
  BatchWriteResponse (variable size, 8-byte aligned):
  ├─ header: WriteResponse      # 32 bytes (status, counts, timestamp)
  ├─ status_per_event: [N]u8    # N = original event count from request
  ├─ padding: [P]u8             # Padding to 8-byte alignment
  ```
- **AND** header.status contains the first failing error code
- **AND** status_per_event[i] contains:
  - `ok` (0) for events that passed validation
  - Error code for the failing event
  - `not_processed` (255) for events after the first failure
- **AND** batch is atomic: all succeed or all fail (no partial commits)
- **AND** total body size = 32 + N + P bytes (where P = padding to 8-byte boundary)
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

#### Scenario: Insert/Upsert batch encoding

- **WHEN** encoding an insert_events or upsert_events batch
- **THEN** the message body SHALL be:
  ```
  EventBatch (variable size):
  ├─ count: u32             # Number of events in batch (max 10,000)
  ├─ reserved: u32          # Alignment padding (must be zero)
  ├─ events[0]: GeoEvent    # 128 bytes
  ├─ events[1]: GeoEvent    # 128 bytes
  ├─ ...
  └─ events[N-1]: GeoEvent  # 128 bytes
  ```
- **AND** events SHALL be packed contiguously with no gaps
- **AND** total size = 8 + (count × 128) bytes
- **AND** insert_events and upsert_events use identical wire format
- **AND** only semantic difference: insert fails on duplicate, upsert uses LWW

#### Scenario: Write operation response format

- **WHEN** a write operation (insert_events, upsert_events, delete_entities) completes successfully
- **THEN** the response body SHALL be (32 bytes, 16-byte aligned):
  ```
  WriteResponse (32 bytes):
  ├─ status: u8             # 0 = ok, non-zero = partial failure
  ├─ reserved1: [7]u8       # Padding
  ├─ events_processed: u32  # Number of events successfully processed
  ├─ events_failed: u32     # Number of events that failed validation
  ├─ timestamp_assigned: u64 # Timestamp assigned by VSR prepare (nanoseconds)
  ├─ reserved2: [8]u8       # Padding to 32 bytes
  ```
- **AND** status = 0 indicates all events processed successfully
- **AND** events_failed > 0 indicates some events failed coordinate/format validation
- **AND** timestamp_assigned is the consensus timestamp from VSR prepare phase
- **AND** for delete_entities: events_processed = entities deleted, events_failed = entities not found

#### Scenario: Query parameter encoding

- **WHEN** encoding a query_radius operation
- **THEN** the message body SHALL contain:
  ```
  QueryRadius (80 bytes, 16-byte aligned):
  ├─ lat_nano: i64          # Center latitude (8 bytes)
  ├─ lon_nano: i64          # Center longitude (8 bytes)
  ├─ radius_mm: u32         # Radius in millimeters (4 bytes)
  ├─ limit: u32             # Max results per page (0 = default 81,000) (4 bytes)
  ├─ start_time: u64        # Optional time range start (0 = no filter) (8 bytes)
  ├─ end_time: u64          # Optional time range end (0 = no filter) (8 bytes)
  ├─ after_cursor: u128     # Pagination cursor (0 = first page) (16 bytes)
  ├─ group_id: u64          # Optional group filter (0 = all groups) (8 bytes)
  ├─ reserved: [16]u8       # Padding to 80 bytes (8+8+4+4+8+8+16+8+16=80)
  ```
- **AND** for first query, set `after_cursor = 0`
- **AND** for pagination, set `after_cursor = cursor_id` from previous response
- **AND** set `group_id = 0` to query all groups, or specific value to filter

#### Scenario: Polygon query encoding

- **WHEN** encoding a query_polygon operation
- **THEN** the message body SHALL contain:
  ```
  QueryPolygon (variable size):
  Header (64 bytes, 16-byte aligned):
  ├─ vertex_count: u32      # Number of polygon vertices (max 10,000) (4 bytes)
  ├─ limit: u32             # Max results per page (0 = default 81,000) (4 bytes)
  ├─ start_time: u64        # Optional time range start (0 = no filter) (8 bytes)
  ├─ end_time: u64          # Optional time range end (0 = no filter) (8 bytes)
  ├─ after_cursor: u128     # Pagination cursor from previous response (0 = first page) (16 bytes)
  ├─ group_id: u64          # Optional group filter (0 = all groups) (8 bytes)
  ├─ reserved: [16]u8       # Padding to 64 bytes (4+4+8+8+16+8=48, +16 reserved=64)

  Vertex Array:
  ├─ vertices[0]: LatLon    # First vertex (16 bytes)
  ├─ vertices[1]: LatLon    # Second vertex (16 bytes)
  ├─ ...
  └─ vertices[N-1]: LatLon  # Last vertex (16 bytes)

  Where LatLon is (16 bytes, 8-byte aligned):
  ├─ lat_nano: i64          # Latitude in nanodegrees
  └─ lon_nano: i64          # Longitude in nanodegrees
  ```
- **AND** total body size = 64 + (vertex_count × 16) bytes
- **AND** maximum vertex_count SHALL be 10,000 (polygon_vertices_max)
- **AND** polygon is automatically closed (last vertex connects to first)
- **AND** for first query, set `after_cursor = 0`
- **AND** for pagination, set `after_cursor = cursor_id` from previous response

#### Scenario: Time range filter semantics

- **WHEN** querying with start_time and/or end_time filters
- **THEN** the time range SHALL use half-open interval semantics [start_time, end_time)
- **AND** events are included where: `event.timestamp >= start_time` (inclusive start)
- **AND** events are excluded where: `event.timestamp >= end_time` (exclusive end)
- **AND** this allows non-overlapping adjacent time ranges (e.g., [0, 100) then [100, 200))
- **AND** when `start_time = 0`, no lower bound filter is applied
- **AND** when `end_time = 0`, no upper bound filter is applied
- **AND** when both are 0, all events matching spatial criteria are returned

#### Scenario: query_latest request encoding

- **WHEN** encoding a query_latest request (operation 0x14)
- **THEN** the message body SHALL contain:
  ```
  QueryLatest (64 bytes, 8-byte aligned):
  ├─ limit: u32             # Max results (default 1000, max 81000) (4 bytes)
  ├─ reserved1: u32         # Padding (must be zero) (4 bytes)
  ├─ group_id: u64          # Optional group filter (0 = all groups) (8 bytes)
  ├─ cursor_timestamp: u64  # For pagination (0 = start from latest) (8 bytes)
  ├─ reserved2: [40]u8      # Padding to 64 bytes (must be zero)
  ```
- **AND** total body size is exactly 64 bytes
- **AND** results are ordered newest-to-oldest by timestamp
- **AND** for first query, set `cursor_timestamp = 0`
- **AND** for pagination, set `cursor_timestamp` to last event's timestamp from previous response
- **AND** see query-engine/spec.md for complete semantics

#### Clarification: query_latest is temporal, not spatial

- **WHEN** distinguishing query_latest from spatial queries (radius/polygon)
- **THEN** the following SHALL be understood:
  - **query_latest** (0x14): Returns N most recent events **globally or by group_id**, ordered newest-to-oldest
    - Purpose: Replay, debugging, monitoring (NOT production spatial queries)
    - Does NOT filter by location
    - Does filter by timestamp (via pagination cursor)
    - Does filter by group_id (optional)
  - **query_radius** (0x11): Returns events within X meters of a point
  - **query_polygon** (0x12): Returns events within an arbitrary geopolygon
  - DO NOT use query_latest for spatial filtering; use query_radius or query_polygon instead

#### Scenario: query_latest response encoding

- **WHEN** query_latest completes
- **THEN** the response uses standard QueryResponseHeader (32 bytes) followed by GeoEvent array
- **AND** `has_more = 1` indicates more results available via pagination
- **AND** `cursor_id` contains the timestamp of the last returned event for pagination
- **AND** events are ordered from newest to oldest

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

#### Scenario: Query response data structure clarification

- **WHEN** implementing query response parsing
- **THEN** the following clarification SHALL apply:
  - Query responses return **full GeoEvent structs** (128 bytes each), NOT IndexEntry structs (64 bytes)
  - This is consistent with the wire format definition above and query_result_max constant in constants/spec.md
  - Calculation: query_result_max = 81,000 events × 128 bytes/event = ~10.37MB + 32-byte header = 10.4MB
  - Clients must allocate receive buffers with 128 bytes per result, not 64 bytes
  - Size limit validation: count ≤ query_result_max AND (32 + count × 128) ≤ message_size_max
  - **IMPORTANT for SDK developers**: Allocate buffers as: `buffer_size = header_size + (expected_results × 128)`

#### Scenario: Empty result handling

- **WHEN** a query matches zero events
- **THEN** `status` SHALL be `ok`
- **AND** `count` SHALL be 0
- **AND** `total_count` SHALL be 0
- **AND** no event data is included in body

### Requirement: Multi-Batch Partial Result Retry Semantics

The system SHALL define clear retry behavior for partial multi-batch failures to enable correct client SDK implementation.

#### Scenario: Multi-batch response structure

- **WHEN** a multi-batch message is processed
- **THEN** the response SHALL use multi-batch encoding (same as request):
  - Payload: Concatenated batch responses
  - Trailer: Array of u16 response sizes + u16 response count
- **AND** `partial_result` flag in message header indicates incomplete processing
- **AND** batch trailer enables client to parse which batches succeeded/failed

#### Scenario: Partial success identification

- **WHEN** multi-batch message partially succeeds
- **THEN** the client SDK SHALL:
  1. Parse response trailer to identify batch count returned
  2. Extract status for each batch response
  3. Identify first failed batch index F (first batch with error status)
  4. Identify skipped batches (indices F+1 to N where N = request batch count)
- **AND** batches 0..F-1 are considered successfully processed
- **AND** batches F..N require retry

#### Scenario: Retry strategy for idempotent operations

- **WHEN** multi-batch contains idempotent operations (upsert, query)
- **AND** partial failure occurs at batch F
- **THEN** the client SDK SHALL:
  1. **Retry batches F..N** (failed and skipped batches)
  2. Do NOT retry batches 0..F-1 (already succeeded)
  3. Safe because: upsert uses LWW semantics (replaying is idempotent)
- **AND** this minimizes duplicate work while ensuring all batches complete
- **AND** ArcherDB v1 operations (upsert, query, delete) are ALL idempotent

#### Scenario: Retry strategy for validation failures

- **WHEN** multi-batch validation fails at batch F (e.g., invalid_coordinates)
- **THEN** the system SHALL:
  1. Stop processing immediately (fail-fast)
  2. Return error response for batch F
  3. Mark batches 0..F-1 as skipped (not processed)
  4. Mark batches F+1..N as skipped (not processed)
  5. Set `partial_result = true` in reply header
- **AND** client SHALL fix validation error and retry ENTIRE message 0..N
- **AND** validation is all-or-nothing (transactional semantics)

#### Scenario: Retry strategy for resource exhaustion

- **WHEN** multi-batch resource exhaustion occurs at batch F (e.g., message_body_too_large)
- **AND** batches 0..F-1 already committed successfully
- **THEN** the client SDK SHALL:
  1. Accept results for batches 0..F-1 (already processed)
  2. Retry batches F..N in a NEW message
  3. Potentially split batch F if it's too large (pagination)
- **AND** this provides graceful degradation (partial progress)

#### Scenario: Multi-batch atomic transactions (future)

- **WHEN** atomic multi-batch transactions are supported (future version)
- **THEN** the semantics SHALL be:
  - All-or-nothing: if any batch fails validation, none execute
  - Set `transaction_id` in multi-batch header to enable atomic mode
  - If batch F fails during execution:
    - Roll back batches 0..F-1 (undo already-applied changes)
    - Return error for entire transaction
  - **NOT SUPPORTED in v1** (all operations are independent)
- **AND** v1 clients SHALL NOT set `transaction_id` (reserved field must be 0)

#### Scenario: Partial result flag interpretation

- **WHEN** response message has `partial_result = true` in header
- **THEN** client SHALL interpret as:
  - For multi-batch: Some batches were skipped due to error or size limit
  - For single-batch: Result was truncated due to message size limit (pagination required)
  - Check response count vs request count to determine which batches processed
- **AND** client SDK SHALL expose this information to application
- **AND** application can decide whether to retry or handle partial results

#### Scenario: SDK retry configuration

- **WHEN** client SDK implements multi-batch retry logic
- **THEN** it SHALL provide configuration options:
  ```
  RetryConfig {
    max_retries: u32,           // Default: 10
    initial_backoff_ms: u32,    // Default: 100ms
    max_backoff_ms: u32,        // Default: 5000ms
    backoff_multiplier: f32,    // Default: 2.0
    retry_on_validation_error: bool,  // Default: false (client should fix)
    retry_on_resource_error: bool,    // Default: true (transient)
  }
  ```
- **AND** SDKs SHALL log retry attempts at DEBUG level
- **AND** SDKs SHALL surface retry count to application (for monitoring)

#### Scenario: Cross-language SDK consistency

- **WHEN** implementing client SDKs in multiple languages
- **THEN** ALL SDKs SHALL implement identical retry semantics:
  - Retry failed+skipped batches for idempotent operations
  - Use exponential backoff with same default parameters
  - Surface partial result information to application
  - Provide configuration for retry behavior
- **AND** integration tests SHALL verify cross-language consistency
- **AND** wire format compatibility tests SHALL include partial failure scenarios

### Requirement: Multi-Batch Wire Format (Binary Protocol)

The system SHALL define explicit binary wire format for multi-batch requests and responses with truncation algorithm.

#### Scenario: Multi-batch request encoding (concatenated batches)

- **WHEN** client sends multiple operations in a single message (multi-batch)
- **THEN** the message body SHALL be structured as:
  ```
  MULTI-BATCH REQUEST BODY:
  ┌──────────────────────────────────────────────────────────────┐
  │ Batch 0 (variable size)                                      │
  │  ├─ count: u32         # events or UUIDs in this batch       │
  │  ├─ reserved: u32      # alignment padding                   │
  │  └─ events/ids: [count]...                                   │
  ├──────────────────────────────────────────────────────────────┤
  │ Batch 1 (variable size)                                      │
  │  ├─ count: u32                                               │
  │  ├─ reserved: u32                                            │
  │  └─ events/ids: [count]...                                   │
  ├──────────────────────────────────────────────────────────────┤
  │ ...                                                          │
  ├──────────────────────────────────────────────────────────────┤
  │ Batch N (variable size)                                      │
  │  ├─ count: u32                                               │
  │  ├─ reserved: u32                                            │
  │  └─ events/ids: [count]...                                   │
  └──────────────────────────────────────────────────────────────┘
  ```
- **AND** each batch follows the standard format for its operation type:
  - `insert_events`, `upsert_events`: 8 + (count × 128) bytes
  - `query_uuid_batch`: 8 + (count × 16) bytes
  - `delete_entities`: 8 + (count × 16) bytes
- **AND** batches are concatenated without gaps (no padding between them)
- **AND** maximum message body size is `message_size_max` (10.4MB by default)
- **AND** client SHALL include multiple batches in single message if total size ≤ message_size_max

**Example: 3-batch request (2 upsert + 1 query_uuid_batch)**:
```
Batch 0 (upsert 2 events): 8 + (2 × 128) = 264 bytes
Batch 1 (upsert 3 events): 8 + (3 × 128) = 392 bytes
Batch 2 (query 5 UUIDs): 8 + (5 × 16) = 88 bytes
Total: 264 + 392 + 88 = 744 bytes
```

#### Scenario: Multi-batch response encoding (with trailer)

- **WHEN** server returns multi-batch response
- **THEN** the message body SHALL be structured as:
  ```
  MULTI-BATCH RESPONSE BODY:
  ┌──────────────────────────────────────────────────────────────┐
  │ Response 0 (variable size)                                   │
  │  ├─ status: u8         # per-response status                 │
  │  ├─ reserved: [7]u8    # alignment to 8 bytes                │
  │  └─ response data      # status-specific fields              │
  ├──────────────────────────────────────────────────────────────┤
  │ Response 1 (variable size)                                   │
  │  ├─ status: u8                                               │
  │  ├─ reserved: [7]u8                                          │
  │  └─ response data                                            │
  ├──────────────────────────────────────────────────────────────┤
  │ ... (truncated responses if partial_result = true)          │
  └──────────────────────────────────────────────────────────────┘
  ┌──────────────────────────────────────────────────────────────┐
  │ TRAILER (at end of message body)                             │
  ├──────────────────────────────────────────────────────────────┤
  │ sizes[0]: u16         # byte size of response 0              │
  │ sizes[1]: u16         # byte size of response 1              │
  │ ...                                                          │
  │ sizes[N-1]: u16       # byte size of response N-1            │
  │ count: u16            # total batch count returned (N)       │
  └──────────────────────────────────────────────────────────────┘
  ```
- **AND** trailer is located at the VERY END of message body
- **AND** trailer byte size = 2 × (response_count + 1) bytes
- **AND** trailer MUST be present even if response_count = 0 (then only count: 0x0000)
- **AND** response_count in trailer indicates how many batches were processed (may be < request count if truncated)

**Example: 3-batch response (partial, truncated at batch 2)**:
```
Response 0 (WriteResponse): status=0, events_processed=2, events_failed=0, events_skipped=0
  Byte size: 8 bytes (1 byte status + 7 bytes reserved + 0 bytes details)
Response 1 (WriteResponse): status=0, events_processed=3, events_failed=0, events_skipped=0
  Byte size: 8 bytes
Response 2: SKIPPED (not returned due to truncation)

Trailer:
  sizes[0]: 0x0008  (response 0 is 8 bytes, little-endian: 08 00)
  sizes[1]: 0x0008  (response 1 is 8 bytes, little-endian: 08 00)
  count: 0x0002    (2 responses returned, little-endian: 02 00)
Total trailer: 6 bytes
Message body: 8 + 8 + 6 = 22 bytes
```

#### Scenario: Multi-batch truncation algorithm (server-side)

- **WHEN** server processes multi-batch request that would produce response > message_size_max
- **THEN** the truncation algorithm SHALL be:

```
Algorithm: TRUNCATE_MULTI_BATCH
Input: batch_responses[0..N], message_size_max
Output: truncated_responses[0..F], partial_result_flag, error_status

Step 1: Calculate initial trailer size
  trailer_size = 2 × (N + 1)  // u16 per response + count

Step 2: Calculate cumulative response sizes and iterate
  body_size = 0
  for batch_index in 0..N:
    response_i = batch_responses[batch_index]
    response_size_i = calculate_response_size(response_i)

    // Check if this response would exceed limit
    new_body_size = body_size + response_size_i + (2 × (batch_index + 2))
                    // ^current size  ^next response  ^updated trailer (one more entry)

    if new_body_size > message_size_max:
      // This batch doesn't fit; truncate here
      return {
        responses: batch_responses[0..batch_index-1],
        response_count: batch_index,
        trailer_size: 2 × (batch_index + 1),  // Only count returned responses
        partial_result: true,
        error: error_code_from_truncation_reason
      }

    body_size = new_body_size

Step 3: If all batches fit, return all
  return {
    responses: batch_responses[0..N],
    response_count: N + 1,
    trailer_size: 2 × (N + 2),
    partial_result: false,
    error: none
  }

Special cases:
- If response_count becomes 0 (first response too large):
  Return single error response (error_code = resource_exhausted)
  NO truncation trailer (single-response message)
- If validation fails at batch F:
  Return response 0..F-1 (skipped, not in body)
  Return error response for batch F
  NO responses for batch F+1..N
  Set partial_result = true
```

**Truncation Example (message_size_max = 1000 bytes)**:
```
Batch 0 (upsert 2 events): response = 8 bytes
Batch 1 (upsert 3 events): response = 8 bytes
Batch 2 (query 5 UUIDs): response = 100 bytes (variable, depends on matches)

Iteration:
- batch_index=0: body_size=0, new_size=8+4=12 ≤ 1000 ✓ continue
- batch_index=1: body_size=12, new_size=12+8+4=24 ≤ 1000 ✓ continue
- batch_index=2: body_size=24, new_size=24+100+6=130 ≤ 1000 ✓ continue
- batch_index=3: (doesn't exist, all responses fit)

Result: response_count=3, partial_result=false, no truncation
```

**Truncation Example (message_size_max = 50 bytes)**:
```
Same batches as above.

Iteration:
- batch_index=0: body_size=0, new_size=8+4=12 ≤ 50 ✓ continue
- batch_index=1: body_size=12, new_size=12+8+4=24 ≤ 50 ✓ continue
- batch_index=2: body_size=24, new_size=24+100+6=130 > 50 ✗ TRUNCATE

Result: response_count=2, partial_result=true, return responses[0..1] only
Client will retry batch 2 in a new message
```

#### Scenario: Multi-batch response parsing (client-side)

- **WHEN** client receives multi-batch response
- **THEN** the parsing algorithm SHALL be:

```
Algorithm: PARSE_MULTI_BATCH_RESPONSE
Input: message_body[0..body_size], message_size_max
Output: batch_results[0..response_count], partial_result_flag

Step 1: Validate trailer exists
  if body_size < 2:
    return ERROR: "Response body too small for trailer"

  // Read count from very end of message (last 2 bytes)
  count_offset = body_size - 2
  response_count = read_u16_le(message_body[count_offset:count_offset+2])

  // Validate trailer size
  expected_trailer_size = 2 × (response_count + 1)
  if body_size < expected_trailer_size:
    return ERROR: "Body size insufficient for declared count"

Step 2: Extract trailer
  trailer_offset = body_size - expected_trailer_size
  response_sizes = []
  for i in 0..response_count-1:
    size_i = read_u16_le(message_body[trailer_offset + 2*i:trailer_offset + 2*i + 2])
    response_sizes.append(size_i)

Step 3: Validate trailer sizes sum
  payload_size = sum(response_sizes)
  if payload_size > trailer_offset:
    return ERROR: "Response sizes exceed payload area"

Step 4: Parse individual batch responses
  batch_results = []
  offset = 0
  for i in 0..response_count-1:
    response_start = offset
    response_end = offset + response_sizes[i]
    response_data = message_body[response_start:response_end]

    batch_result = parse_response(response_data, operation_type[i])
    batch_results.append(batch_result)

    offset = response_end

Step 5: Check partial_result flag
  if partial_result flag set in message header:
    // Some batches were truncated/skipped
    // Batches [0..response_count-1] succeeded or error
    // Batches [response_count..request_count-1] must be retried
    return {
      batch_results: batch_results,
      partial_result: true,
      first_truncated_batch: response_count
    }
  else:
    // All batches returned
    return {
      batch_results: batch_results,
      partial_result: false
    }

Error handling:
- If any response_sizes[i] = 0: ERROR (invalid)
- If any response has invalid status: Include in batch_results as error
- If offset != trailer_offset at end: ERROR (size mismatch)
```

**Parsing Example (same truncated response as above)**:
```
Message body:
  [0..7]: Response 0 (8 bytes)
  [8..15]: Response 1 (8 bytes)
  [16..19]: sizes[0]=0x0008, sizes[1]=0x0008 (4 bytes)
  [20..21]: count=0x0002 (2 bytes)
  Total: 22 bytes

Parsing:
- count_offset = 22 - 2 = 20
- response_count = read_u16_le([20..21]) = 0x0002 = 2
- trailer_size = 2 × (2 + 1) = 6 bytes
- trailer_offset = 22 - 6 = 16
- sizes[0] = read_u16_le([16..17]) = 0x0008 = 8
- sizes[1] = read_u16_le([18..19]) = 0x0008 = 8
- payload_size = 8 + 8 = 16 ≤ trailer_offset ✓
- Response 0: [0..7] (8 bytes)
- Response 1: [8..15] (8 bytes)
- offset=16 == trailer_offset ✓

Result: 2 responses parsed successfully, partial_result=true
```

#### Scenario: Multi-batch protocol constants and byte order

- **WHEN** implementing multi-batch encoding/decoding
- **THEN** these CRITICAL constants SHALL be used:
  ```
  MULTI-BATCH PROTOCOL CONSTANTS
  ══════════════════════════════

  BYTE ORDER:
  - All u16/u32/u64 values use LITTLE-ENDIAN byte order
  - Example: count=0x0002 is encoded as bytes [0x02, 0x00]
  - This matches TigerBeetle protocol conventions

  MESSAGE CONSTRAINTS:
  - message_size_max: 10,485,760 bytes (10.4MB)
  - batch_count_max: No hard limit per message, but limited by message_size_max
  - response_count: u16, thus max 65,535 responses (in theory; practically limited by message_size)
  - response_size: u16 per response in trailer, max 65,535 bytes per response

  TRUNCATION BEHAVIOR:
  - If any single response exceeds message_size_max:
    Return ERROR status code: resource_exhausted (code 211)
    Return response_count: 0 (no trailer returned)
    Return single error message (NOT wrapped in multi-batch)
  - If partial responses fit but not all:
    Return response_count: N (where N < request_count)
    Set partial_result flag in message header
    Include trailer with N entries
    Client MUST retry truncated batches

  BATCH INDEPENDENCE:
  - Each batch is validated and processed independently
  - Validation failure in batch N does NOT prevent batch N+1 processing
  - If batch N validation fails:
    Return error status in response N
    Continue processing batch N+1
  - All batches 0..F-1 are included in response, even if some have error status
  - This enables partial success scenarios (some batches error, others succeed)

  EMPTY BATCH HANDLING:
  - Empty batch (count=0) is VALID and SHALL be processed
  - Empty batch size: 8 bytes (count: u32=0 + reserved: u32)
  - Empty batch response: Valid response with count=0, no operations performed
  - Use case: Padding for alignment, or conditional skipping by client
  ```

#### Scenario: Edge cases and validation

- **WHEN** parsing or generating multi-batch messages
- **THEN** the following edge cases SHALL be handled:

| Case | Behavior | Example |
|------|----------|---------|
| **Empty response** (count=0) | Trailer only: just "00 00" (count=0) | single_batch=false, returns 0 responses |
| **Single batch response** | Trailer present: sizes[0], count=0x0001 | Parsed same way as multi-batch |
| **Batch too large for message** | Batch 0 response > (message_size_max - 4) | Truncate at batch 0, return error_code=resource_exhausted |
| **All batches skipped (validation)** | count=0, partial_result=true | Trailer: only "00 00", client retries all |
| **Mixed operation types** | Each batch response format matches its operation | trailer size = 2 × (count + 1) regardless |
| **Malformed response** | count field > 100 (unreasonable) | Client SHALL reject, not attempt to parse |

- **AND** client SDKs SHALL validate:
  - response_count ≤ request_count (cannot return more than sent)
  - response_count > 0 OR partial_result = true (at least one batch or explicit truncation)
  - sum(response_sizes) + trailer_size ≤ message_size_max
  - No response_sizes[i] = 0 (each response must be non-empty or omitted)

#### Scenario: Wire format compatibility testing

- **WHEN** testing multi-batch wire format
- **THEN** test cases SHALL include:
  - 1 batch, no truncation
  - 5 batches, no truncation
  - 10 batches, truncated at batch 5
  - Truncated at batch 0 (first response too large)
  - Zero batches (empty response)
  - Large responses (100KB individual response)
  - Mixed operation types in single message
  - Validation failure (error in batch F)
  - Resource exhaustion (partial_result = true)
- **AND** tests SHALL verify binary compatibility across all SDKs (Zig, Java, Go, Python, Node.js)

### Requirement: Delete Operation Format

The system SHALL define precise wire format for entity deletion (GDPR compliance).

#### Scenario: delete_entities request encoding

- **WHEN** encoding a delete_entities request
- **THEN** the message body SHALL be structured as:
  ```
  DeleteRequest:
  ├─ count: u32             # Number of entity UUIDs to delete
  ├─ reserved: u32          # Alignment padding
  ├─ entity_ids: [count]u128  # Array of entity UUIDs to delete
  ```
- **AND** total size = 8 + (count × 16) bytes
- **AND** maximum count is 10,000 entities per request (batch_events_max / 16 * 128 ≈ 80K, limited for consistency)
- **AND** duplicate entity IDs are allowed (second delete is no-op)
- **AND** count = 0 (empty delete) is valid: returns success with events_processed=0
- **AND** response uses standard WriteResponse format (events_processed = deleted, events_failed = not found)

### Requirement: Admin Operation Formats

The system SHALL define precise wire formats for admin operations (ping, get_status).

#### Scenario: ping request/response format

- **WHEN** sending a ping request
- **THEN** the request body SHALL be empty (0 bytes)
- **AND** the response body SHALL be empty (0 bytes)
- **AND** success is indicated by `status = ok` in response header
- **AND** ping does NOT go through VSR consensus (handled directly by replica)
- **AND** ping is used for connection keepalive and primary discovery

#### Scenario: get_status request/response format

- **WHEN** sending a get_status request
- **THEN** the request body SHALL be empty (0 bytes)
- **AND** the response body SHALL be (64 bytes):
  ```
  StatusResponse (64 bytes):
  ├─ status: u8             # 0 = ok
  ├─ is_primary: u8         # 1 if this replica is current primary
  ├─ replica_id: u8         # This replica's ID (0-5)
  ├─ primary_id: u8         # Current primary's replica ID
  ├─ replica_count: u8      # Total replicas in cluster
  ├─ reserved1: [3]u8       # Padding to 8-byte alignment
  ├─ view: u64              # Current VSR view number
  ├─ op: u64                # Latest committed operation number
  ├─ commit_timestamp: u64  # Timestamp of latest commit (nanoseconds)
  ├─ entity_count: u64      # Current entity count in index
  ├─ index_capacity: u64    # Maximum entity capacity
  ├─ reserved2: [16]u8      # Padding to 64 bytes (total: 5+3+8+8+8+8+8+16=64)
  ```
- **AND** get_status does NOT go through VSR consensus (read-only local state)
- **AND** values may be slightly stale on non-primary replicas

#### Scenario: cleanup_expired request/response format

- **WHEN** sending a cleanup_expired request
- **THEN** the request body SHALL be (64 bytes):
  ```
  CleanupRequest (64 bytes, 8-byte aligned):
  ├─ batch_size: u32         # Number of index entries to scan (0 = scan all) (4 bytes)
  ├─ reserved: [60]u8        # Padding to 64 bytes (must be zero)
  ```
- **AND** the response body SHALL be (64 bytes):
  ```
  CleanupResponse (64 bytes, 8-byte aligned):
  ├─ entries_scanned: u64    # Number of index entries examined (8 bytes)
  ├─ entries_removed: u64    # Number of expired entries cleaned up (8 bytes)
  ├─ reserved: [48]u8        # Padding to 64 bytes
  ```
- **AND** cleanup_expired DOES go through VSR consensus (all replicas apply same cleanup deterministically)
- **AND** VSR assigns the timestamp used for expiration comparison (ensuring identical cleanup across replicas)
- **NOTE:** See ttl-retention/spec.md for incremental cleanup patterns and operational guidance

### Requirement: Error Code Taxonomy

The system SHALL use a comprehensive error code enum based on TigerBeetle's taxonomy, extended for geospatial operations.

#### Scenario: General error codes

- **WHEN** defining general error codes
- **THEN** the following SHALL be included:
  - `ok = 0` - Success
  - `too_much_data = 1` - Batch exceeds batch_events_max (10,000 events)
  - `invalid_operation = 2` - Unknown or malformed operation code
  - `invalid_data_size = 3` - Message exceeds message_size_max (10MB) or size doesn't match expected format
  - `checksum_mismatch = 4` - Message checksum verification failed
  - `session_expired = 5` - Client session was evicted
  - `timeout = 6` - Operation timed out
  - `not_primary = 7` - Node is not the current primary (redirect)
  - `unknown_event_format = 8` - Reserved bytes non-zero (unrecognized wire format version)
  - `connection_failed = 9` - Client failed to establish connection to any replica
  - `batch_full = 10` - SDK-side batch buffer is at capacity
  - `version_not_supported = 11` - Protocol version not supported by server
  - `not_processed = 255` - Sentinel: event not processed (in batch, appears after first failure)

#### Scenario: Geospatial validation error codes (100-116)

- **WHEN** defining geospatial-specific validation error codes
- **THEN** the following SHALL be included (per error-codes/spec.md ranges 100-199):
  - `invalid_coordinates = 100` - Lat/lon out of valid range
  - `polygon_too_complex = 101` - Vertex count exceeds limit
  - `query_result_too_large = 102` - Result set exceeds max_result_size
  - `invalid_s2_cell = 103` - S2 cell ID is malformed
  - `radius_too_large = 104` - Radius exceeds maximum allowed
  - `event_already_expired = 106` - Imported event's TTL has already expired
  - `query_timeout = 107` - Query exceeded CPU time budget
  - `polygon_too_simple = 108` - Polygon has fewer than 3 distinct vertices (duplicates removed)
  - `polygon_self_intersecting = 109` - Polygon edges cross each other
  - `radius_zero = 110` - Zero radius requires exact coordinate match (use uuid query)
  - `polygon_too_large = 111` - Polygon appears to wrap around world (malformed input)
  - `polygon_degenerate = 112` - Polygon has collinear points (zero area)
  - `polygon_empty = 113` - Polygon vertex array is empty (0 vertices provided)
  - `id_must_not_be_zero = 114` - ID field cannot be zero (reserved sentinel value)
  - `id_must_not_be_int_max = 115` - ID field cannot be max int value (reserved sentinel)
  - `timestamp_must_be_zero = 116` - Timestamp field must be zero for server-assigned timestamps
- **NOTE**: `entity_not_found = 200` is a State error, not a validation error (see error-codes/spec.md)

#### Scenario: Cluster error codes

- **WHEN** defining cluster-related error codes
- **THEN** the following SHALL be included:
  - `cluster_unavailable = 200` - No quorum available
  - `view_change_in_progress = 201` - Cannot serve requests during view change
  - `replica_lagging = 202` - Replica too far behind (stale read rejected)
  - `index_capacity_exceeded = 203` - RAM index is at capacity, cannot insert new entities
  - `out_of_space = 204` - Disk is full, cannot write data
  - `too_many_queries = 205` - Query queue is full, try again later
  - `backup_required = 207` - Writes halted pending backup (backup-mandatory mode)
  - `cluster_mismatch = 208` - Client certificate cluster ID doesn't match server
  - `checkpoint_lag_backpressure = 209` - Writes halted because index checkpoint is lagging too far behind WAL head
  - `entity_expired = 210` - Entity has expired due to TTL (see error-codes/spec.md)
  - `resource_exhausted = 211` - Internal resource pool exhausted (see error-codes/spec.md)
  - `index_degraded = 310` - Hash probe length exceeded threshold (see error-codes/spec.md)

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

### Related Specifications

- See `specs/error-codes/spec.md` for complete error code enumeration and error response format
- See `specs/data-model/spec.md` for GeoEvent wire format and validation rules
- See `specs/query-engine/spec.md` for operation semantics and multi-batch processing
- See `specs/client-retry/spec.md` for client-side retry logic and primary discovery
- See `specs/replication/spec.md` for VSR protocol and session management
- See `specs/security/spec.md` for mTLS authentication requirements
- See `specs/observability/spec.md` for trace context propagation in message headers

## Implementation Status

**Overall: 85-90% Complete**

### Core Protocol Components

| Component | File | Status |
|-----------|------|--------|
| Message Header (256 bytes) | `src/vsr/message_header.zig` | ✓ Complete |
| Operation Codes | `src/archerdb.zig:704-744` | ✓ Complete (offset 128+) |
| Error Code Taxonomy | `src/error_codes.zig` | ✓ Complete |
| Multi-Batch Encoding | `src/vsr/multi_batch.zig` | ✓ Complete |
| Query Filters (128 bytes) | `src/geo_state_machine.zig` | ✓ Complete |
| Write Results (8 bytes/event) | `src/geo_state_machine.zig` | ✓ Complete |
| Admin Responses (128 bytes) | `src/archerdb.zig` | ✓ Complete |

### Design Differences from Spec

| Aspect | Spec | Implementation | Notes |
|--------|------|----------------|-------|
| Magic bytes | In header offset 100 | Checkpoint files only | VSR uses command field |
| Operation codes | 0x01-0x30 | 128+18 to 128+27 | Intentional VSR/SM separation |
| Error response | 320 bytes unified | 8 bytes per-event | TigerBeetle batch model |
| Response sizes | 64/320 bytes | 128 bytes | GeoEvent alignment |
| query_uuid_batch | Operation 0x13 | Multi-batch protocol | Protocol-level, not operation |

### Implementation Notes

- Uses **layered protocol model**: VSR (0-127) + State Machine (128+)
- Per-event 8-byte results more efficient for bulk operations than unified error
- 128-byte response alignment matches GeoEvent struct size
- Multi-batch trailer encoding fully implemented with proper truncation
- All struct sizes verified at compile-time
