# I/O Subsystem Specification

**Reference Implementation:** https://github.com/archerdb/archerdb/tree/main/src/io

This spec is based on ArcherDB's async I/O subsystem. Implementers MUST study:
- `src/io/linux.zig` - io_uring integration with zero-copy optimizations
- `src/io/darwin.zig` - macOS kqueue fallback
- `src/io/windows.zig` - Windows IOCP implementation
- `src/message_bus.zig` - Connection state machine, send/receive logic

**Implementation approach:** ArcherDB's I/O layer is highly optimized. Reuse the io_uring patterns, completion handling, and zero-copy techniques directly. Only adapt the message types.

---

## ADDED Requirements

### Requirement: io_uring Integration

The system SHALL use Linux io_uring for all asynchronous I/O operations on Linux platforms.

#### Scenario: io_uring initialization

- **WHEN** the I/O subsystem is initialized on Linux
- **THEN** an io_uring instance SHALL be created
- **AND** Linux 5.5+ SHALL be required (for OP_ACCEPT support)
- **AND** submission queue depth SHALL equal `grid_iops_read_max + grid_iops_write_max` (default: 192 entries)
- **AND** completion queue depth SHALL equal 2× submission queue depth (default: 384 entries) to handle batched completions

#### Scenario: Operation submission

- **WHEN** I/O operations are submitted
- **THEN** they SHALL be batched into SQEs (Submission Queue Entries)
- **AND** multiple operations SHALL be submitted per syscall
- **AND** this reduces context switch overhead

#### Scenario: Completion handling

- **WHEN** completions are available
- **THEN** CQEs (Completion Queue Entries) SHALL be processed
- **AND** callbacks SHALL be invoked for completed operations
- **AND** errors SHALL be propagated to callbacks with original error code (EAGAIN, EIO, etc.) without translation
- **AND** callback SHALL receive completion.result containing errno value or 0 on success

#### Scenario: Operation cancellation

- **WHEN** cancellation is required
- **THEN** IORING_ASYNC_CANCEL SHALL be used
- **AND** pending operations SHALL be aborted cleanly

### Requirement: Zero-Copy Messaging

The system SHALL minimize data copying through zero-copy optimizations.

#### Scenario: Single-message fast path

- **WHEN** exactly one complete message is received in buffer
- **AND** `process_size == 0` and `receive_size == header.size`
- **THEN** the buffer SHALL be returned directly (no copy)
- **AND** a new buffer is acquired from pool for next receive

#### Scenario: Multi-message slow path

- **WHEN** multiple messages are buffered
- **THEN** only necessary bytes SHALL be copied
- **AND** `stdx.copy_disjoint()` SHALL be used for non-overlapping regions
- **AND** `process_size` advances to track consumed bytes

#### Scenario: Buffer ownership

- **WHEN** zero-copy is used
- **THEN** buffer ownership transfers to consumer
- **AND** original receive buffer is replaced
- **AND** reference counting tracks ownership

### Requirement: Message Bus

The system SHALL implement a message bus for replica-to-replica and client-to-replica communication.

#### Scenario: Connection state machine

- **WHEN** a connection is managed
- **THEN** it SHALL transition through states:
  - `free` - Not in use
  - `accepting` - Accept operation in progress
  - `connecting` - Connect operation in progress
  - `connected` - Active and ready
  - `terminating` - Cleanup in progress

#### Scenario: Send queue per connection

- **WHEN** messages are queued for sending
- **THEN** each connection SHALL have its own send queue (ring buffer)
- **AND** replica send queue max = `max(min(clients_max, 4), 2)`
- **AND** client send queue max = 2

#### Scenario: Replica vs client connections

- **WHEN** managing connections
- **THEN** replica connections SHALL be tracked in `replicas[]` array
- **AND** client connections SHALL be tracked in `clients` hashmap
- **AND** different buffer sizes MAY apply

### Requirement: TCP Stream Deframing

The system SHALL reassemble TCP streams into complete protocol messages.

#### Scenario: Deframe per connection type

- **WHEN** receiving data from a TCP stream
- **THEN** the receiver SHALL deframe messages as `256-byte header + body`
- **AND** for **client** connections it SHALL follow `specs/client-protocol/spec.md`
- **AND** for **replica** connections it SHALL follow `specs/replication/spec.md`
- **AND** it SHALL parse the 256-byte header first
- **AND** it SHALL validate the header checksum before trusting the size field
- **AND** it SHALL receive the body bytes based on `header.size - message_header_size`

#### Scenario: Message buffer ring

- **WHEN** buffering received data
- **THEN** a ring buffer abstraction SHALL be used:
  - `suspend_size ≤ process_size ≤ advance_size ≤ receive_size`
- **AND** compaction moves data when needed

#### Scenario: Checksum caching

- **WHEN** checksums are validated
- **THEN** results SHALL be cached (sticky validation)
- **AND** repeated calls SHALL not recompute checksums
- **AND** this prevents redundant work during message processing

### Requirement: TCP Configuration

The system SHALL configure TCP sockets for optimal performance and reliability.

#### Scenario: Buffer sizing

- **WHEN** TCP buffers are configured
- **THEN** the system SHALL size kernel socket buffers proportionally to `send_queue_max` and expected message sizes
- **AND** it MUST tolerate OS clamping and MUST NOT assume the kernel buffers can hold `send_queue_max` full messages
- **AND** buffer sizing MUST avoid unbounded kernel memory use at `clients_max`
- **AND** receive buffer SHALL be sized to `message_size_max` (10MB) to accept largest possible message
- **AND** send buffer SHALL be sized to `send_queue_max * message_size_max` (but kernel will clamp to wmem_max)
- **AND** `SO_RCVBUFFORCE`/`SO_SNDBUFFORCE` SHALL be tried first (privileged)

#### Scenario: TCP options

- **WHEN** connections are established
- **THEN** these options SHALL be set:
  - `TCP_NODELAY` - Disable Nagle's algorithm
  - `SO_KEEPALIVE` - Enable keepalive
  - `TCP_KEEPIDLE/KEEPINTVL/KEEPCNT` - Keepalive parameters
  - `TCP_USER_TIMEOUT` - Connection timeout

### Requirement: send_now() Optimization

The system SHALL attempt synchronous sends before falling back to async I/O.

#### Scenario: Non-blocking send attempt

- **WHEN** sending a message
- **THEN** first attempt synchronous `sendto()` with `MSG_DONTWAIT`
- **AND** if successful, no io_uring submission needed
- **AND** if `EWOULDBLOCK`, fall back to async io_uring send

#### Scenario: Partial sends

- **WHEN** a send partially completes
- **THEN** `send_progress` SHALL track bytes sent
- **AND** subsequent sends continue from that offset
- **AND** async path handles remainder

### Requirement: Connection Lifecycle

The system SHALL manage connection lifecycle with graceful cleanup.

#### Scenario: Connection termination

- **WHEN** terminating a connection
- **THEN** `shutdown(fd, SHUT_RDWR)` SHALL be called (graceful)
- **AND** state transitions to `terminating`
- **AND** pending I/O is allowed to complete

#### Scenario: Resource cleanup

- **WHEN** cleanup is performed
- **THEN** send queue SHALL be drained (unreferencing messages)
- **AND** receive buffer SHALL be deinitialized
- **AND** file descriptor SHALL be closed via io_uring

#### Scenario: Reconnection

- **WHEN** a replica connection fails
- **THEN** reconnection SHALL be attempted
- **AND** exponential backoff SHALL be used
- **AND** cluster continues operating with remaining replicas

### Requirement: Platform Abstraction

The system SHALL abstract I/O operations for cross-platform support.

#### Scenario: Linux implementation

- **WHEN** running on Linux
- **THEN** io_uring SHALL be used
- **AND** Direct I/O with O_DIRECT SHALL be used
- **AND** this is the primary, optimized path

#### Scenario: macOS implementation

- **WHEN** running on macOS
- **THEN** kqueue or alternative SHALL be used
- **AND** Direct I/O MAY have limitations
- **AND** development/testing is supported

#### Scenario: Windows implementation

- **WHEN** running on Windows
- **THEN** IOCP (I/O Completion Ports) SHALL be used
- **AND** platform-specific Direct I/O APIs
- **AND** full production support

### Requirement: Completion Callbacks

The system SHALL use function pointer callbacks for async I/O completion.

#### Scenario: Callback registration

- **WHEN** an I/O operation is submitted
- **THEN** a callback function pointer SHALL be provided
- **AND** user context SHALL be associated with the operation
- **AND** callback receives completion status

#### Scenario: Callback invocation

- **WHEN** an operation completes
- **THEN** the registered callback SHALL be invoked
- **AND** callback executes in I/O thread context
- **AND** callback MAY submit new I/O operations

### Requirement: I/O Timeouts

The system SHALL support absolute timeouts for I/O operations.

#### Scenario: Timeout specification

- **WHEN** timeouts are specified
- **THEN** they SHALL use `CLOCK_MONOTONIC` absolute time
- **AND** io_uring timeout operations SHALL be used
- **AND** expired operations complete with timeout error

#### Scenario: Timeout handling

- **WHEN** a timeout expires
- **THEN** the operation callback receives timeout error
- **AND** any in-progress kernel work is cancelled
- **AND** resources are cleaned up appropriately

### Related Specifications

- See `specs/replication/spec.md` for message bus usage in VSR protocol (Prepare, PrepareOk, Commit)
- See `specs/storage-engine/spec.md` for Direct I/O requirements (O_DIRECT, sector alignment)
- See `specs/client-protocol/spec.md` for client connection handling and TCP configuration
- See `specs/memory-management/spec.md` for MessagePool and zero-copy message passing
- See `specs/error-codes/spec.md` for I/O error codes and timeout handling
- See `specs/observability/spec.md` for I/O performance metrics (disk read/write latency)

## Implementation Status

**Overall: 95% Complete**

### Platform-Specific I/O

| Platform | Backend | Status |
|----------|---------|--------|
| Linux | io_uring | ✓ Complete |
| Windows | IOCP (64-entry) | ✓ Complete |
| macOS | kqueue | ✓ Complete |

### Core Features

| Feature | Linux | Windows | macOS | Status |
|---------|-------|---------|-------|--------|
| io_uring integration | ✓ Full | N/A | N/A | COMPLETE |
| Direct I/O | ✓ O_DIRECT | ✓ FILE_NO_INTERMEDIATE_BUFFERING | ✓ F_NOCACHE | COMPLETE |
| CQE/Completion handling | ✓ Batched 256 | ✓ 64-entry | ✓ kqueue events | COMPLETE |
| Error code mapping | ✓ Full | ✓ Full | ✓ Full | COMPLETE |
| Operation batching | ✓ Yes | ✓ Yes | ✓ Yes | COMPLETE |
| Zero-copy send | ✓ send_now() | Partial | N/A | IMPLEMENTED |
| Cancellation | ✓ Functional | TODO | TODO | PARTIAL |
| Timeout support | ✓ Full | ✓ Full | ✓ Full | COMPLETE |
| Platform abstraction | ✓ Yes | ✓ Yes | ✓ Yes | COMPLETE |

### Implementation Notes

- io_uring on Linux provides highest performance with full async I/O
- Cross-platform abstraction in `src/io.zig` handles platform differences
- Direct I/O bypasses page cache for deterministic latency
- Cancellation support varies by platform (Linux complete, others TODO)
