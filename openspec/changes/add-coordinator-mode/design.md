# Design: Optional Coordinator Node

## Context

ArcherDB's default architecture uses "smart clients" that discover shard topology and route queries directly. This provides optimal latency but requires:
- SDK implementation per language
- Client access to all shard nodes
- Topology management in clients

The coordinator mode provides an alternative where a dedicated proxy handles all routing, enabling simpler clients at the cost of an additional network hop.

## Goals / Non-Goals

### Goals

1. **Simple clients**: Clients connect to one address, coordinator handles routing
2. **Operational simplicity**: Single binary, same as data nodes
3. **HA-capable**: Multiple coordinators with load balancer
4. **Observable**: Dedicated metrics for coordinator health
5. **Low overhead**: <1ms additional latency for routed queries

### Non-Goals

1. **Query caching**: Stateless proxy only
2. **Connection pooling for clients**: Each client gets own connections
3. **Leader election**: Use external load balancer
4. **Query optimization**: Pass-through routing only

## Decisions

### Decision 1: Coordinator as Separate Process Mode

**Choice**: Run coordinator via `archerdb coordinator start`.

**Rationale**:
- **Same binary**: No separate coordinator binary to maintain
- **Flexible deployment**: Can run on dedicated nodes or co-located
- **Familiar operation**: Same CLI patterns as data nodes

**Implementation**:
```bash
# Start coordinator on dedicated node
archerdb coordinator start \
  --bind=0.0.0.0:5000 \
  --shards=shard-0:5001,shard-1:5001,...,shard-15:5001 \
  --max-connections=10000

# Or with seed discovery
archerdb coordinator start \
  --bind=0.0.0.0:5000 \
  --seed-nodes=shard-0:5001,shard-5:5001 \
  --max-connections=10000
```

### Decision 2: Stateless Shared-Nothing Architecture

**Choice**: Coordinators share no state; each is independent.

**Rationale**:
- **Simple HA**: Add more coordinators behind load balancer
- **No coordination**: No Raft/Paxos between coordinators
- **Easy scaling**: Just add more coordinator instances

**Trade-off**: Each coordinator discovers topology independently (slight inefficiency vs simplicity).

**Architecture**:
```
┌─────────────────────────────────────┐
│          Load Balancer              │
│        (nginx, HAProxy, etc)        │
└─────────────────────────────────────┘
         │           │           │
         ▼           ▼           ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│Coordinator 1│ │Coordinator 2│ │Coordinator 3│
│ (stateless) │ │ (stateless) │ │ (stateless) │
└─────────────┘ └─────────────┘ └─────────────┘
         │           │           │
         └─────────┬─┴───────────┘
                   │
    ┌──────────────┼──────────────┐
    ▼              ▼              ▼
┌────────┐    ┌────────┐    ┌────────┐
│Shard 0 │    │Shard 1 │    │Shard N │
└────────┘    └────────┘    └────────┘
```

### Decision 3: Connection Per Shard, Not Pooled

**Choice**: Each coordinator maintains dedicated connections to all shards.

**Rationale**:
- **Simple implementation**: No connection multiplexing
- **Predictable latency**: No queue waiting for connections
- **Clear failure model**: Connection failure = shard unavailable

**Configuration**:
```zig
pub const CoordinatorConfig = struct {
    /// Connections per shard (primary + replicas)
    connections_per_shard: u32 = 4,

    /// Connection timeout in milliseconds
    connect_timeout_ms: u32 = 5_000,

    /// Keepalive interval in milliseconds
    keepalive_interval_ms: u32 = 30_000,
};
```

### Decision 4: Fan-Out with Configurable Partial Failure Handling

**Choice**: Support both strict and partial-result modes.

**Rationale**:
- **Different requirements**: Some queries must be complete, others can be partial
- **Operator control**: Per-query or default configuration

**Implementation**:
```zig
pub const FanOutPolicy = enum {
    /// Fail entire query if any shard fails
    strict,

    /// Return partial results with metadata about failures
    partial,

    /// Wait for timeout, return whatever we have
    best_effort,
};

pub const FanOutResult = struct {
    events: []GeoEvent,
    shards_queried: u32,
    shards_succeeded: u32,
    shards_failed: []u32,  // IDs of failed shards
    partial: bool,         // True if results are incomplete
};
```

### Decision 5: Load Balancing via Round-Robin with Health Awareness

**Choice**: Round-robin across healthy replicas per shard.

**Rationale**:
- **Simple**: No complex load balancing algorithm
- **Effective**: Good enough for most workloads
- **Health-aware**: Skip unhealthy replicas automatically

**Implementation**:
```zig
/// Select replica for a shard using round-robin.
fn selectReplica(self: *Coordinator, shard: *const ShardInfo) Address {
    // Try round-robin starting from last used
    const start = self.rr_state[shard.id];

    for (0..4) |i| {
        const idx = (start + i) % 4;
        const addr = if (idx == 0) shard.primary else shard.replicas[idx - 1];

        if (addr != null and self.isHealthy(shard.id, idx)) {
            self.rr_state[shard.id] = @intCast((idx + 1) % 4);
            return addr.?;
        }
    }

    // Fallback to primary even if unhealthy
    return shard.primary;
}
```

## Architecture

### Component Overview

```
┌────────────────────────────────────────────────────────────────────┐
│                         Coordinator Node                            │
│                                                                     │
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────────────┐  │
│  │  Client Listener │  │ Topology Manager │  │  Health Monitor    │  │
│  │  (TCP/gRPC)      │  │ (Discovery)      │  │  (Ping/Pong)       │  │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬───────────┘  │
│           │                     │                     │             │
│           ▼                     ▼                     ▼             │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                      Query Router                               │ │
│  │  - Single-shard routing (entity_id → shard)                    │ │
│  │  - Fan-out execution (radius/polygon → all shards)             │ │
│  │  - Result aggregation (merge, sort, limit)                     │ │
│  └────────────────────────────────────────────────────────────────┘ │
│           │                                                         │
│           ▼                                                         │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    Shard Connection Pool                        │ │
│  │  [Shard 0: 4 conns] [Shard 1: 4 conns] ... [Shard N: 4 conns]  │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### Request Flow: Single-Shard Query

```
1. Client sends: query_uuid(entity_id=0xABC...)
2. Coordinator receives request
3. Router computes: shard = hash(0xABC...) % 16 = 7
4. Router selects: shard 7 replica via round-robin
5. Coordinator forwards: request to selected replica
6. Shard returns: GeoEvent or NOT_FOUND
7. Coordinator returns: response to client
```

**Latency**: client→coordinator + coordinator→shard + shard→coordinator + coordinator→client

### Request Flow: Fan-Out Query

```
1. Client sends: query_radius(lat=37.7, lon=-122.4, radius=1000m, limit=100)
2. Coordinator receives request
3. Router identifies: all 16 shards needed
4. Coordinator sends: parallel requests to all shards
5. Each shard returns: up to 100 results
6. Coordinator aggregates:
   a. Collect all results (up to 1600)
   b. Sort by timestamp
   c. Apply limit (take top 100)
7. Coordinator returns: final 100 results to client
```

**Latency**: client→coordinator + max(shard_latencies) + aggregation + coordinator→client

### Topology Discovery

```
1. Coordinator starts with seed nodes: [shard-0:5001, shard-5:5001]
2. Connect to first available seed
3. Request topology: GET /topology
4. Receive: {version: 42, shards: [...], num_shards: 16}
5. Cache topology locally
6. Connect to all shard primaries
7. Start health monitoring
8. Periodically refresh topology (every 60s or on error)
```

## Configuration

### CLI Arguments

```
archerdb coordinator start
  --bind=<address>              # Bind address for clients (default: 0.0.0.0:5000)
  --shards=<list>               # Explicit shard list (shard-0:5001,shard-1:5001,...)
  --seed-nodes=<list>           # Seed nodes for discovery (alternative to --shards)
  --max-connections=<n>         # Max client connections (default: 10000)
  --query-timeout-ms=<n>        # Query timeout (default: 30000)
  --health-check-ms=<n>         # Health check interval (default: 5000)
  --connections-per-shard=<n>   # Connections per shard (default: 4)
  --read-from-replicas=<bool>   # Enable replica reads (default: true)
  --fan-out-policy=<policy>     # strict|partial|best_effort (default: partial)
```

### Example Deployment

```yaml
# docker-compose.yml
services:
  coordinator-1:
    image: archerdb:latest
    command: >
      coordinator start
      --bind=0.0.0.0:5000
      --seed-nodes=shard-0:5001,shard-1:5001
      --max-connections=10000
    ports:
      - "5000:5000"

  coordinator-2:
    image: archerdb:latest
    command: >
      coordinator start
      --bind=0.0.0.0:5000
      --seed-nodes=shard-0:5001,shard-1:5001
      --max-connections=10000
    ports:
      - "5001:5000"

  # HAProxy in front for load balancing
  haproxy:
    image: haproxy:latest
    ports:
      - "5000:5000"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg
```

## Trade-Offs

### Coordinator vs Smart Client

| Aspect | Smart Client | Coordinator |
|--------|-------------|-------------|
| Latency | Lower (1 hop) | Higher (2 hops) |
| Client complexity | Higher | Lower |
| Topology management | Per client | Centralized |
| Network access | All shards | Coordinator only |
| Debugging | Distributed | Centralized |
| Scaling | Automatic | Add coordinators |

**Recommendation**:
- **Smart client**: High-throughput, latency-sensitive, few client types
- **Coordinator**: Many client types, serverless, network isolation, central control

## Validation Plan

### Unit Tests

1. **Routing correctness**: Entity routes to correct shard
2. **Fan-out execution**: All shards queried, results aggregated
3. **Health monitoring**: Unhealthy shards excluded from routing
4. **Partial failure**: Correct handling per policy

### Integration Tests

1. **End-to-end**: Client → Coordinator → Shard → Coordinator → Client
2. **HA failover**: Coordinator failure, load balancer routes to backup
3. **Topology changes**: Shard added/removed, coordinator adapts

### Performance Tests

1. **Latency overhead**: <1ms vs direct shard access
2. **Throughput**: 100K+ queries/sec per coordinator
3. **Fan-out scaling**: Latency vs number of shards
