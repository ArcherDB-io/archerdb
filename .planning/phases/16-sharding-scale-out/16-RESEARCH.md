# Phase 16: Sharding & Scale-Out - Research

**Researched:** 2026-01-25
**Domain:** Sharding, online resharding, cross-shard query fan-out, distributed tracing
**Confidence:** MEDIUM

## Summary

Phase 16 focuses on enabling horizontal scale-out with online resharding, parallel cross-shard queries, hot shard detection, and full distributed tracing. The ArcherDB codebase already includes foundational sharding utilities (jump consistent hash, virtual ring, spatial routing), an online resharding state machine with dual-write semantics, and a coordinator that performs fan-out query routing and result aggregation. Metrics and health endpoints already expose shard/resharding status, which should be expanded for migration progress and hot shard detection.

The standard approach for sharding systems in production is to: (1) route targeted queries using shard keys to avoid scatter/gather, (2) rebalance data via background migrations with controlled concurrency (one migration per shard), and (3) perform online resharding with a coordinator driving donor/recipient synchronization and brief cutover. MongoDB’s sharded cluster documentation confirms these patterns for balancing and resharding, including coordinator-driven migrations and monitoring progress via system metrics.

**Primary recommendation:** Extend existing sharding modules (`sharding.zig`, `coordinator.zig`, `metrics.zig`) to implement online resharding with dual-write + cutover, add fan-out parallelism and partial failure handling, and instrument full request paths with OpenTelemetry spans and links.

## Standard Stack

The established libraries/tools for this domain:

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `src/sharding.zig` | current | Jump hash, virtual ring, resharding manager | Already implements consistent hashing + online resharding state machine |
| `src/coordinator.zig` | current | Fan-out query routing and aggregation | Existing coordinator supports scatter/gather and result merging |
| `src/archerdb/metrics.zig` | current | Shard/resharding metrics | Central metrics registry includes shard counts, rates, resharding progress |
| OpenTelemetry Trace API/SDK spec | 1.53.0 | Span links + trace propagation rules | Required for cross-shard tracing semantics (parent/child + links) |
| W3C Trace Context | 1.0 | Trace propagation header format | Required to propagate trace IDs across shard RPCs |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| OpenTelemetry Semantic Conventions | 1.39.0 | Span attribute naming | Use for database/client spans, shard attributes |
| Prometheus Exposition Format | 0.0.4 | Metrics exposition | Existing metrics server uses this format |
| OpenMetrics | 1.0 | Optional metrics upgrade | Use for richer metrics/compatibility |
| MongoDB Sharding Docs | 8.2 | Sharding/resharding operational patterns | Reference for donor/recipient migrations + balancing rules |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `jump_hash` strategy | `virtual_ring` | Virtual ring reduces movement but adds memory + O(log N) lookup |
| `jump_hash` strategy | `modulo` | Modulo is cheap but forces power-of-2 shard counts and high movement |
| Dual-write migration | Stop-the-world reshard | Simpler but violates online resharding requirement |

**Installation:**
```bash
# No new external packages required for this phase
```

## Architecture Patterns

### Recommended Project Structure
```
src/
├── sharding.zig                 # Consistent hashing + resharding state machine
├── geo_sharding.zig             # Spatial shard routing helpers
├── coordinator.zig              # Fan-out query router + aggregation
├── archerdb/
│   ├── metrics.zig              # Shard + resharding metrics registry
│   └── metrics_server.zig       # /health/shards endpoint
└── archerdb/observability/
    └── trace_export.zig         # OTLP exporter for tracing
```

### Pattern 1: Online Resharding State Machine (dual-write + cutover)
**What:** Use a state machine to drive online resharding with dual-write during migration and explicit cutover/rollback.
**When to use:** Adding/removing shards without downtime (SHARD-04).
**Example:**
```zig
// Source: /Users/g/archerdb/src/sharding.zig (ReshardingManager)
pub const ReshardingState = enum { idle, preparing, copying, verifying, switching, cleanup, rollback, complete };

pub fn getShardForEntity(
    self: *const ReshardingManager,
    entity_id: u128,
) struct { primary: u32, secondary: ?u32 } {
    const primary = self.current_ring.?.getShard(entity_id);
    if (self.state == .copying) {
        const secondary = self.target_ring.?.getShard(entity_id);
        if (secondary != primary) return .{ .primary = primary, .secondary = secondary };
    }
    return .{ .primary = primary, .secondary = null };
}
```

### Pattern 2: Parallel Fan-Out + Scatter/Gather Aggregation
**What:** Coordinator creates a fan-out query, executes per-shard requests in parallel, and merges results with shard success counts.
**When to use:** Cross-shard queries (radius/polygon/latest) or batch UUID lookups (SHARD-02).
**Example:**
```zig
// Source: /Users/g/archerdb/src/coordinator.zig
pub fn startFanOutQuery(self: *Coordinator, query_type: QueryType) !u64 {
    const query_id = self.next_query_id;
    const shards_queried = self.topology.num_shards;
    try self.pending_queries.put(query_id, .{
        .query_type = query_type,
        .start_time_ns = @intCast(std.time.nanoTimestamp()),
        .shards_pending = shards_queried,
        .shards_completed = 0,
        .results = std.ArrayList(GeoEvent).init(self.allocator),
    });
    return query_id;
}

pub fn recordShardResult(self: *Coordinator, query_id: u64, events: []const GeoEvent) !void {
    if (self.pending_queries.getPtr(query_id)) |pq| {
        try pq.results.appendSlice(events);
        pq.shards_completed += 1;
    }
}
```

### Pattern 3: Span Links for Cross-Shard Visibility
**What:** Use OpenTelemetry span links to connect per-shard spans to the root request span while preserving parent/child for in-process hops.
**When to use:** Fan-out queries where each shard executes in parallel (SHARD-03).
**Example:**
```text
// Source: https://opentelemetry.io/docs/specs/otel/trace/api/
// Use parent span for coordinator->shard RPCs; add links from shard spans to root.
// Links allow multiple related spans without forcing a strict tree.
```

### Anti-Patterns to Avoid
- **Broadcasting without shard keys:** Scatter/gather for queries that could be targeted causes needless fan-out and latency.
- **Synchronous trace export on request path:** Use async exporting to avoid blocking shard queries.
- **Unbounded migrations:** MongoDB balancer restricts shards to one migration at a time; avoid multi-migration overload.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Consistent hashing | New hashing scheme | `sharding.jumpHash` / `ConsistentHashRing` | Already implemented with optimal movement semantics |
| Resharding metrics | Custom ad-hoc counters | `metrics.Registry.*` shard/resharding metrics | Centralized metrics already defined |
| Fan-out aggregation | New merge utilities | `Coordinator` fan-out tracking + aggregation | Existing API tracks shards_queried/succeeded |
| Shard health endpoint | New HTTP server | `metrics_server.handleHealthShards` | Already serves shard status JSON |
| Trace propagation | Custom trace IDs | W3C Trace Context + OTLP | Standardizes IDs and link semantics |

**Key insight:** ArcherDB already has sharding, coordinator, and metrics primitives. Phase 16 should extend them (dual-write + cutover + tracing), not replace them.

## Common Pitfalls

### Pitfall 1: Scatter/Gather Overuse
**What goes wrong:** Cross-shard queries are broadcast even when a shard key exists, leading to high latency.
**Why it happens:** Missing shard key in queries (MongoDB notes broadcast when shard key is absent).
**How to avoid:** Ensure query planning routes by shard key whenever possible; only fan-out for truly global queries.
**Warning signs:** High fan-out counts for UUID lookups; coordinator_fanout_shards_queried always equals shard_count.

### Pitfall 2: Migration Overload
**What goes wrong:** Rebalancing floods shards with multiple concurrent migrations, causing write stalls.
**Why it happens:** Unlimited migration workers or missing rate limits.
**How to avoid:** Follow balancer-style constraints (one migration per shard, ~n/2 max concurrent). Rate-limit batches.
**Warning signs:** Elevated write latency on all shards during migration.

### Pitfall 3: Resharding Cutover Without Safety Checks
**What goes wrong:** Cutover occurs before migration fully catches up, leading to missing data.
**Why it happens:** No lag threshold/verification before switching shard map.
**How to avoid:** Use `ReshardingState.verifying` with lag checks and allow rollback on mismatch.
**Warning signs:** Post-cutover read repairs, missing entities in new shard map.

### Pitfall 4: Partial Fan-Out Failures Ignored
**What goes wrong:** Returning success even when shard queries failed leads to silent data loss.
**Why it happens:** Aggregator only merges results without tracking shard success/error counts.
**How to avoid:** Return `shards_succeeded`/`shards_queried` and surface partial failure errors or degraded responses.
**Warning signs:** Client sees incomplete results with no error/trace indication.

### Pitfall 5: Trace Tree Without Links
**What goes wrong:** Parallel shard spans are forced into a single parent chain, hiding fan-out parallelism.
**Why it happens:** Only parent/child relationships are used.
**How to avoid:** Use span links for parallel shard operations (OTel links) while keeping parent/child for RPC hops.
**Warning signs:** Traces show sequential shard work even when executed in parallel.

## Code Examples

Verified patterns from official sources:

### Jump Consistent Hash Routing
```zig
// Source: /Users/g/archerdb/src/sharding.zig
pub fn jumpHash(key: u64, num_buckets: u32) u32 {
    var k = key;
    var b: i64 = -1;
    var j: i64 = 0;
    while (j < num_buckets) {
        b = j;
        k = k *% 2862933555777941757 +% 1;
        j = @intFromFloat((@as(f64, @floatFromInt(b + 1))) *
            (@as(f64, @floatFromInt(@as(u64, 1) << 31)) /
                @as(f64, @floatFromInt((k >> 33) + 1))));
    }
    return @intCast(b);
}
```

### Resharding Health Endpoint
```zig
// Source: /Users/g/archerdb/src/archerdb/metrics_server.zig
const shard_count_val = metrics.Registry.shard_count.load(.monotonic);
const resharding_progress_val = metrics.Registry.resharding_progress.load(.monotonic);
const progress_pct: f64 = @as(f64, @floatFromInt(resharding_progress_val)) / 10.0;
```

### Fan-Out Query Aggregation
```zig
// Source: /Users/g/archerdb/src/coordinator.zig
pub fn finalizeFanOutQuery(self: *Coordinator, query_id: u64) !FanOutResult {
    const pq = self.pending_queries.get(query_id) orelse return error.QueryNotFound;
    return .{
        .events = pq.results.items,
        .shards_queried = pq.shards_pending,
        .shards_succeeded = pq.shards_completed,
        .total_time_ns = @intCast(std.time.nanoTimestamp()) - pq.start_time_ns,
    };
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Modulo sharding | Jump consistent hash | Google 2014; adopted in `sharding.zig` | Reduces key movement on resharding |
| Offline resharding | Online dual-write + cutover | Modern sharded DBs (MongoDB 5.0+) | Avoids application downtime |
| Single-span traces | Parent/child + span links | OTel 1.x | Represents parallel fan-out correctly |

**Deprecated/outdated:**
- **Modulo-only sharding:** High data movement and power-of-2 constraints. Use `jump_hash` or `virtual_ring`.

## Open Questions

1. **Cutover strategy for online resharding**
   - What we know: MongoDB resharding blocks writes briefly (2 seconds) and uses coordinator-driven cutover.
   - What's unclear: Acceptable write-block duration for ArcherDB clients.
   - Recommendation: Plan for a short, explicit cutover window with retries and rollback hooks.

2. **Partial failure semantics for fan-out queries**
   - What we know: Coordinator already tracks `shards_succeeded` and `shards_queried`.
   - What's unclear: Whether to return partial results vs fail-fast per query type.
   - Recommendation: Define per-query policies (e.g., majority vs all) and expose in API.

3. **Hot shard thresholds**
   - What we know: Metrics include shard rates, size, and hottest/coldest ratios.
   - What's unclear: Thresholds for triggering alerts vs auto-rebalance.
   - Recommendation: Start with alert-only thresholds and require manual approval for migration.

## Sources

### Primary (HIGH confidence)
- `/Users/g/archerdb/src/sharding.zig` - Sharding strategies + resharding state machine
- `/Users/g/archerdb/src/coordinator.zig` - Fan-out query routing + aggregation
- `/Users/g/archerdb/src/archerdb/metrics.zig` - Shard metrics + resharding progress
- `/Users/g/archerdb/src/archerdb/metrics_server.zig` - /health/shards endpoint
- https://opentelemetry.io/docs/specs/otel/trace/api/ - Span links + tracing API
- https://opentelemetry.io/docs/specs/otel/trace/sdk/ - Sampling and span processing behavior
- https://opentelemetry.io/docs/specs/semconv/general/trace/ - Trace semantic conventions
- https://www.mongodb.com/docs/manual/sharding/ - Sharding concepts, targeted vs broadcast operations
- https://www.mongodb.com/docs/manual/core/sharding-reshard-a-collection/ - Online resharding behaviors
- https://www.mongodb.com/docs/manual/core/sharding-balancer-administration/ - Balancer migration constraints

### Secondary (MEDIUM confidence)
- https://prometheus.io/docs/instrumenting/exposition_formats/ - Prometheus text format
- https://prometheus.io/docs/specs/om/open_metrics_spec/ - OpenMetrics spec

### Tertiary (LOW confidence)
- None (no unverified web sources used)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Derived from existing codebase + official specs
- Architecture: MEDIUM - Patterns based on internal code + MongoDB operational guidance
- Pitfalls: MEDIUM - Informed by MongoDB docs and distributed systems practice

**Research date:** 2026-01-25
**Valid until:** 2026-03-01 (sharding/tracing standards are stable)
