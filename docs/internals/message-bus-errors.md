# Message Bus Error Handling

This document explains how the message bus classifies and handles errors.

## Error Classification Principles

The message bus uses a classified error handling approach rather than terminating
all connections on any error. This reduces unnecessary reconnections while still
maintaining correctness and security.

**Core principles:**
1. Protocol violations are always fatal (security boundary)
2. Peer-initiated disconnects are normal (not errors)
3. Resource exhaustion rejects new work, keeps existing connections
4. Timeouts are configurable (currently hardcoded, future work)

## Error Categories

### Fatal Errors (Terminate Connection)

These errors indicate the connection is unusable or untrustworthy:

| Error | Rationale |
|-------|-----------|
| Protocol violation | Peer sent invalid data, cannot trust further communication |
| Version mismatch | Incompatible protocol versions |
| Authentication failure | Peer failed to authenticate |
| Malformed message | Header/payload corruption or invalid format |
| Misdirected message | Message peer type doesn't match connection type |

**Action:** Terminate connection immediately with shutdown().

### Peer-Initiated Disconnects (Not Errors)

These indicate the peer closed the connection - normal operation:

| Error | Rationale |
|-------|-----------|
| ConnectionResetByPeer | Peer closed connection (orderly or crash) |
| BrokenPipe | Write to closed connection (send path) |
| Zero bytes received | Orderly shutdown signal |

**Action:** Log at info level, terminate without shutdown (peer already gone).

### Timeout Errors (Configurable)

These indicate the operation took too long:

| Error | Rationale |
|-------|-----------|
| WouldBlock | Operation would block (timeout reached) |
| ConnectionTimedOut | TCP-level timeout |

**Action:** Currently terminate with warning log. Future: make configurable.

### Resource Exhaustion (Reject New Work)

These errors indicate system capacity limits:

| Error | Rationale | Accept | Recv/Send |
|-------|-----------|--------|-----------|
| SystemResources | OS resource limit (memory, buffers) | Yes | Yes |
| ProcessFdQuotaExceeded | Process file descriptor limit | Yes | No |
| SystemFdQuotaExceeded | System file descriptor limit | Yes | No |

**Action for accept:** Log at WARN, reject new connection, continue accepting.
The OS will backpressure by queueing in the listen backlog.

**Action for recv/send:** Terminate connection (cannot complete I/O).

**Operator response:** Increase limits or add capacity.

### Transient Errors (Log and Continue)

These errors may occur during normal operation and don't indicate problems:

| Error | Rationale |
|-------|-----------|
| ConnectionAborted | Connection aborted before accept completed |

**Action:** Log at debug level, continue normal operation.

## Peer Eviction

When connection slots are exhausted and a replica needs to connect:

1. Prefer dropping client connections over unknown connections
2. Prefer dropping unknown connections over replica connections
3. Log at WARN level with evicted peer type
4. Future: emit metric for alerting
5. Future: emit cluster event for operator automation

**Rationale:** Replica-to-replica connections are critical for consensus.
Client connections can reconnect. Unknown connections haven't proven
their identity yet.

## Platform Differences

### shutdown() Behavior

The `shutdown(fd, SHUT_RDWR)` syscall signals graceful close intent:

| Platform | Behavior |
|----------|----------|
| Linux | Pending I/O operations return immediately with error |
| Darwin | Similar behavior, but timing may differ slightly |

Both platforms support graceful close via `shutdown(.both)` before `close()`.

### SocketNotConnected on shutdown()

This error can occur in several benign scenarios:

1. Terminating during in-progress connect operation
2. Peer closed connection before we initiated shutdown
3. Connection failed during establishment

All cases are handled by continuing with termination cleanup.

## Connection State Machine

```
free -> accepting -> connected -> terminating -> free
         |              ^
         v              |
        error ------> free
         |
free -> connecting -> connected -> terminating -> free
         |              ^
         v              |
        error ------> terminating
```

**States:**
- `free`: Connection slot available for reuse
- `accepting`: Reserved for in-progress accept operation (inbound)
- `connecting`: Outbound connection in progress (to replica)
- `connected`: Fully established, may recv/send
- `terminating`: Cleanup in progress, waiting for I/O completion

**Valid Transitions (all guarded by assertions):**

| From | To | Guard | Location |
|------|-----|-------|----------|
| free | accepting | `connection.state == .free` | accept() |
| accepting | connected | `assert(state == .accepting)` | accept_callback success |
| accepting | free | `assert(state == .accepting)` | accept_callback error |
| free | connecting | `assert(state == .free)` | connect_connection() |
| connecting | connected | `assert(state == .connecting)` | connect_callback success |
| connecting | terminating | via terminate() | connect_callback error |
| connected | terminating | `assert(state != .terminating && state != .free)` | terminate() |
| terminating | free | `assert(state == .terminating)` | terminate_close_callback |

**Invariants:**
- No double-termination: `assert(connection.state != .terminating)` before terminate
- No terminating free connections: `assert(connection.state != .free)` before terminate
- Orderly cleanup: `terminating` state waits for pending I/O before closing fd
- Re-initialization: Connection struct reset to defaults on close (state = .free)

## Configuration (Future Work)

Currently, timeout behavior is hardcoded in constants.zig:

- `connection_delay_min_ms` / `connection_delay_max_ms`: Reconnect backoff
- `tcp_keepidle`, `tcp_keepintvl`, `tcp_keepcnt`: TCP keepalive
- `tcp_user_timeout_ms`: TCP user timeout

Future improvements:
- Configurable idle timeout (how long inactive connection stays open)
- Configurable read/write timeout (per-operation timeout)
- Retry policy configuration (exponential backoff parameters)
- Per-connection timeout overrides

## Logging Levels

| Level | When Used |
|-------|-----------|
| debug | Transient errors during accept, shutdown errors during termination |
| info | Peer-initiated disconnects, connection establishment |
| warn | Resource exhaustion, peer eviction, timeouts, unexpected errors |
| err | Fatal system errors (e.g., cannot create socket) |

## Metrics (Future Work)

Planned metrics for observability:

- `message_bus_accept_errors_total{type="resource_exhaustion|transient|other"}`
- `message_bus_peer_evictions_total{peer_type="client|unknown"}`
- `message_bus_connection_terminations_total{reason="peer_close|timeout|error"}`
- `message_bus_connections_active{peer_type="replica|client|unknown"}`
