# Phase 15: Cluster & Consensus - Research

**Researched:** 2026-01-24
**Domain:** Distributed systems - connection pooling, VSR consensus tuning, load shedding, read replicas
**Confidence:** MEDIUM (existing codebase patterns well-understood; industry patterns from multiple sources)

## Summary

Phase 15 hardens ArcherDB's cluster infrastructure for enterprise scale through four major components: connection pooling (prevent connection storms), VSR timeout tuning with jitter (reduce unnecessary view changes), load shedding (graceful overload protection), and read replicas (10x read scaling).

The codebase already has solid foundations: the Java client has a `ConnectionPool` with health checks, the Java/Go clients have `CircuitBreaker` implementations, VSR replica has comprehensive timeout mechanisms with exponential backoff and jitter, and Grafana dashboards exist for cluster/replication monitoring.

**Primary recommendation:** Build server-side connection pooling and load shedding as new infrastructure layers, extend existing VSR timeout tuning with configurable profiles, and add read replica routing to the existing replica infrastructure.

## Standard Stack

The established libraries/tools for this domain:

### Core (In-Codebase)
| Component | Location | Purpose | Reuse Strategy |
|-----------|----------|---------|----------------|
| VSR Timeout | `src/vsr.zig:745` | Timeout with backoff+jitter | Extend with configurable profiles |
| Java ConnectionPool | `clients/java/.../ConnectionPool.java` | Client-side pooling | Port patterns to server-side |
| Java CircuitBreaker | `clients/java/.../CircuitBreaker.java` | Per-replica failure isolation | Port to server-side load shedding |
| Go CircuitBreaker | `clients/go/pkg/circuitbreaker/` | Go client circuit breaker | Reference for patterns |
| Metrics Infrastructure | `src/archerdb/metrics.zig` | Counter/Gauge/Histogram | Add cluster metrics |
| Grafana Dashboards | `observability/grafana/dashboards/` | Existing cluster/replication dashboards | Extend for new metrics |

### Supporting (Industry Patterns)
| Pattern | Source | Purpose | Adaptation |
|---------|--------|---------|------------|
| PgBouncer pooling modes | Industry standard | Transaction vs session pooling | Transaction mode for high throughput |
| HikariCP health checks | Industry standard | Periodic connection validation | 30s interval (matches existing) |
| Netflix adaptive concurrency | Industry pattern | Dynamic load adjustment | Reference for load shedding signals |
| Flexible Paxos | Academic paper | Reduced quorum for latency | CLUST-05 implementation |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Server-side pooling | Client-side only | Server pooling protects database, client pooling just protects client |
| Hard cutoff shedding | Gradual rejection | Hard cutoff is more predictable for operators (per user decision) |
| VSR built-in routing | External proxy | Built-in keeps single deployment, proxy adds operational complexity |

## Architecture Patterns

### Recommended Project Structure
```
src/
├── connection_pool.zig       # Server-side connection pool
├── load_shedding.zig         # Overload detection and rejection
├── read_replica_router.zig   # Query routing to replicas
├── vsr/
│   ├── replica.zig           # Extended with timeout profiles
│   └── timeout_profiles.zig  # Cloud/datacenter/custom profiles
├── archerdb/
│   └── metrics.zig           # Extended with cluster metrics
observability/
├── grafana/dashboards/
│   └── archerdb-cluster-health.json  # New health dashboard
└── prometheus/rules/
    └── archerdb-cluster.yaml         # Cluster alerts
```

### Pattern 1: Server-Side Connection Pool

**What:** Pool of client connections managed server-side with adaptive reaping
**When to use:** All client connections to protect database from connection storms

```zig
// Pattern based on existing Java ConnectionPool
pub const ServerConnectionPool = struct {
    const Self = @This();

    // Configuration (per user decision: 16-32 default, adaptive reaping)
    max_connections: u32 = 32,
    min_connections: u32 = 4,

    // Adaptive reaping based on memory pressure
    idle_timeout_normal_ms: u64 = 300_000,   // 5 min when idle
    idle_timeout_pressure_ms: u64 = 30_000,  // 30s under memory pressure

    // Health check (30s per existing spec)
    health_check_interval_ms: u64 = 30_000,

    // Metrics (aggregate always, per-client for top-N)
    metrics: PoolMetrics,

    pub fn acquire(self: *Self) !*Connection {
        // Try pool first, create if under capacity, queue if full
    }

    pub fn release(self: *Self, conn: *Connection) void {
        // Health check before return, close if unhealthy
    }
};
```

### Pattern 2: Composite Load Shedding

**What:** Multi-signal overload detection with hard cutoff and 429 response
**When to use:** Request ingress point, before resource allocation

```zig
// Per user decision: composite signal, hard cutoff, 429 with Retry-After
pub const LoadShedder = struct {
    // Composite signal weights (Claude's discretion)
    queue_depth_weight: f32 = 0.4,
    latency_p99_weight: f32 = 0.3,
    resource_pressure_weight: f32 = 0.3,

    // Hard cutoff threshold (adjustable within guardrails)
    threshold: f32 = 0.8,  // 0.0-1.0 scale
    min_threshold: f32 = 0.5,  // Cannot set lower (guardrail)
    max_threshold: f32 = 0.95, // Cannot set higher

    pub fn shouldShed(self: *Self) ShedDecision {
        const score = self.computeCompositeScore();
        if (score >= self.threshold) {
            return .{ .shed = true, .retry_after_ms = self.computeRetryAfter() };
        }
        return .{ .shed = false };
    }
};
```

### Pattern 3: VSR Timeout Profiles

**What:** Pre-configured timeout values for different network environments
**When to use:** Cluster initialization, with per-timeout overrides

```zig
// Per user decision: profile + overrides for hybrid/configurable
pub const TimeoutProfile = enum {
    cloud,       // High variance network (AWS, GCP cross-AZ)
    datacenter,  // Low latency, predictable network
    custom,      // Start from profile, override specific values
};

pub const TimeoutConfig = struct {
    profile: TimeoutProfile = .cloud,

    // Profile-specific defaults (ms)
    heartbeat_interval: u64 = switch (profile) {
        .cloud => 500,      // Longer for cross-AZ
        .datacenter => 100, // Shorter for local
        .custom => 300,     // Midpoint default
    },

    // Jitter policy (Claude's discretion)
    jitter_range_pct: u8 = 20,  // +/- 20% randomization

    // Per-timeout overrides
    overrides: ?TimeoutOverrides = null,
};
```

### Pattern 4: Read Replica Routing

**What:** Automatic routing of read-only queries to replicas
**When to use:** All query execution after write/read classification

```zig
// Per user decision: automatic read detection, server-side routing, fail to leader
pub const ReadReplicaRouter = struct {
    leader: *Replica,
    replicas: []*Replica,

    pub fn route(self: *Self, query: *Query) *Replica {
        // Automatic classification (pure reads to replica, writes to leader)
        if (query.isReadOnly()) {
            if (self.selectHealthyReplica()) |replica| {
                return replica;
            }
            // Fail to leader if all replicas unhealthy
            return self.leader;
        }
        return self.leader;
    }

    fn selectHealthyReplica(self: *Self) ?*Replica {
        // Round-robin with health filtering
        for (self.replicas) |replica| {
            if (replica.isHealthy()) return replica;
        }
        return null;
    }
};
```

### Anti-Patterns to Avoid
- **Global connection limit without per-client limits:** Allows single client to exhaust pool
- **Fixed timeout values:** Doesn't adapt to network conditions, causes unnecessary view changes
- **Gradual load shedding:** Less predictable for operators, harder to reason about
- **Client-controlled replica selection:** Clients may not have health information

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Connection health checks | Custom ping logic | Extend existing `HealthChecker<T>` pattern | Java client already has proven pattern |
| Circuit breaker state machine | New state machine | Port existing `CircuitBreaker.java` | Tested implementation with metrics |
| Exponential backoff + jitter | Manual calculation | Existing `Timeout.backoff()` in vsr.zig | Already handles wrapping, jitter |
| Metrics collection | Custom counters | Existing `Counter`/`Gauge`/`Histogram` | Thread-safe, Prometheus-compatible |
| Dashboard creation | New dashboard from scratch | Extend existing archerdb-cluster.json | Consistent with existing patterns |

**Key insight:** The codebase has mature implementations of all building blocks in either Zig core or client SDKs. The work is integration and configuration, not fundamental implementation.

## Common Pitfalls

### Pitfall 1: Connection Pool Cardinality Explosion

**What goes wrong:** Per-client metrics with high cardinality explode Prometheus storage
**Why it happens:** Each unique client_id becomes a label, potentially millions of combinations
**How to avoid:** Per user decision - aggregate metrics always, per-client labels only for top-N active clients
**Warning signs:** Prometheus scrape duration increasing, memory usage climbing

### Pitfall 2: Timeout Thundering Herd

**What goes wrong:** All replicas time out simultaneously, causing view change storm
**Why it happens:** Fixed timeout values without jitter
**How to avoid:** Existing `Timeout.backoff()` adds jitter - ensure all new timeouts use it
**Warning signs:** Multiple view changes in quick succession (check `archerdb_vsr_view` metric)

### Pitfall 3: Load Shedding Oscillation

**What goes wrong:** System oscillates between shedding and not shedding rapidly
**Why it happens:** Threshold too close to normal operating point
**How to avoid:** Hard cutoff (per user decision) with hysteresis if needed later
**Warning signs:** High rate of 429 responses followed by low rate, repeating

### Pitfall 4: Read Replica Stale Reads After Write

**What goes wrong:** User writes data, immediately reads, gets stale result from replica
**Why it happens:** Async replication lag between leader and replica
**How to avoid:** Per user decision - eventual consistency (unbounded staleness) is acceptable; document this clearly
**Warning signs:** User reports "data disappeared" after writing

### Pitfall 5: Flexible Paxos Quorum Misconfiguration

**What goes wrong:** Phase-1 quorum too small, can't complete leader election during failures
**Why it happens:** Reducing phase-2 quorum without increasing phase-1 proportionally
**How to avoid:** Enforce invariant: Q1 + Q2 > N (phase-1 + phase-2 quorums exceed total replicas)
**Warning signs:** Cluster unavailable during planned maintenance

## Code Examples

Verified patterns from existing codebase:

### Existing Timeout with Jitter (src/vsr.zig)
```zig
// Source: src/vsr.zig:745-780
pub const Timeout = struct {
    name: []const u8,
    id: u128,
    after: u64,
    after_dynamic: ?u64 = null,
    attempts: u8 = 0,
    rtt: u64 = constants.rtt_ticks,
    rtt_multiple: u8 = constants.rtt_multiple,
    ticks: u64 = 0,
    ticking: bool = false,

    /// Increments attempts counter and resets timeout with exponential backoff and jitter.
    pub fn backoff(self: *Timeout, prng: *stdx.PRNG) void {
        assert(self.ticking);
        self.ticks = 0;
        self.attempts +%= 1;
        log.debug("{}: {s} backing off", .{ self.id, self.name });
        self.set_after_for_rtt_and_attempts(prng);  // Applies jitter
    }
};
```

### Existing Connection Pool Pattern (Java client)
```java
// Source: clients/java/.../ConnectionPool.java:205-246
public PooledConnection<T> acquire() throws ConnectionException {
    ensureOpen();
    // Try pool first
    PooledConnection<T> conn = pool.poll();
    if (conn != null) {
        conn.markInUse();
        return conn;
    }
    // Create new if under capacity
    if (currentSize.get() < maxSize) {
        int newSize = currentSize.incrementAndGet();
        if (newSize <= maxSize) {
            T underlying = connectionFactory.create();
            conn = new PooledConnection<>(underlying, this);
            conn.markInUse();
            return conn;
        }
        currentSize.decrementAndGet();
    }
    // Queue wait with timeout
    conn = pool.poll(acquireTimeoutMs, TimeUnit.MILLISECONDS);
    if (conn == null) {
        throw ConnectionException.connectionTimeout("pool", (int) acquireTimeoutMs);
    }
    conn.markInUse();
    return conn;
}
```

### Existing Circuit Breaker Pattern (Java client)
```java
// Source: clients/java/.../CircuitBreaker.java:129-155
public boolean allowRequest() {
    State currentState = state.get();
    switch (currentState) {
        case CLOSED:
            return true;
        case OPEN:
            long elapsed = System.currentTimeMillis() - openedAt.get();
            if (elapsed >= openDurationMs) {
                if (transitionTo(State.HALF_OPEN)) {
                    resetHalfOpenCounters();
                }
                return allowHalfOpenRequest();
            }
            rejectedRequests.incrementAndGet();
            return false;
        case HALF_OPEN:
            return allowHalfOpenRequest();
    }
}
```

### Existing Metrics Pattern (Zig)
```zig
// Source: src/archerdb/metrics.zig:24-64
pub const Counter = struct {
    value: std.atomic.Value(u64),
    name: []const u8,
    help: []const u8,
    labels: ?[]const u8,

    pub fn init(name: []const u8, help: []const u8, labels: ?[]const u8) Counter {
        return .{
            .value = std.atomic.Value(u64).init(0),
            .name = name,
            .help = help,
            .labels = labels,
        };
    }

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn format(self: *const Counter, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} counter\n", .{self.name});
        // ... prometheus format
    }
};
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Fixed Paxos quorums | Flexible Paxos | 2016 (paper) | Reduced latency, same safety |
| Global rate limits | Adaptive concurrency | ~2020 (Netflix) | Better utilization under load |
| Client-side pooling only | Server-side + client | Industry trend | Protects database from all clients |
| Manual read/write routing | Transparent proxy routing | AWS RDS, etc. | Application simplicity |

**Deprecated/outdated:**
- Majority quorums for all operations: Flexible Paxos shows only phase-2 needs intersection with phase-1
- Static timeout values: Modern systems use adaptive timeouts with jitter

## Open Questions

Things that couldn't be fully resolved:

1. **Optimal composite signal weights for load shedding**
   - What we know: Queue depth, latency P99, and resource pressure are the right signals
   - What's unclear: Exact weighting depends on workload characteristics
   - Recommendation: Start with equal weights (0.33/0.33/0.34), tune based on production data

2. **Top-N threshold for per-client metrics**
   - What we know: Need aggregate metrics always, per-client for debugging
   - What's unclear: What N balances utility vs cardinality?
   - Recommendation: Start with N=10 (top 10 by connection count), configurable

3. **Specific timeout values for cloud vs datacenter profiles**
   - What we know: Cloud has higher variance, datacenter is more predictable
   - What's unclear: Exact values depend on specific cloud provider/network topology
   - Recommendation: Provide reasonable defaults with full override capability

4. **Read replica lag monitoring granularity**
   - What we know: Need to track replication lag for operational awareness
   - What's unclear: Should lag be tracked per-operation or sampled?
   - Recommendation: Sample-based (every N ops or every M seconds) to avoid overhead

## Sources

### Primary (HIGH confidence)
- ArcherDB codebase: `src/vsr.zig`, `src/vsr/replica.zig` - Timeout infrastructure, VSR implementation
- ArcherDB codebase: `clients/java/.../ConnectionPool.java` - Proven pooling patterns
- ArcherDB codebase: `clients/java/.../CircuitBreaker.java` - Circuit breaker state machine
- ArcherDB codebase: `observability/grafana/dashboards/` - Existing dashboard patterns

### Secondary (MEDIUM confidence)
- [AWS Builder's Library - Using load shedding to avoid overload](https://aws.amazon.com/builders-library/using-load-shedding-to-avoid-overload/) - Load shedding principles
- [Flexible Paxos: Quorum intersection revisited](https://fpaxos.github.io/) - Flexible quorum theory
- [Microsoft Connection Pooling Best Practices](https://learn.microsoft.com/en-us/azure/postgresql/connectivity/concepts-connection-pooling-best-practices) - Pool sizing guidance
- [Agoda Adaptive Load Shedding](https://medium.com/agoda-engineering/adaptive-load-shedding-8c4c3b0eacf4) - Adaptive shedding patterns

### Tertiary (LOW confidence)
- Various Medium articles on connection pooling (need verification against official docs)
- Stack Overflow discussions on load shedding thresholds (anecdotal)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Based on existing codebase patterns
- Architecture: MEDIUM - Patterns from multiple sources, adaptation needed
- Pitfalls: MEDIUM - Combination of codebase knowledge and industry patterns
- Flexible Paxos: MEDIUM - Academic paper well-established, but implementation details need work

**Research date:** 2026-01-24
**Valid until:** 2026-02-24 (30 days - stable patterns, not fast-moving)
