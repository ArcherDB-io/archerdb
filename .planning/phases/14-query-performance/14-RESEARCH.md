# Phase 14: Query Performance - Research

**Researched:** 2026-01-24
**Domain:** Query caching, batch operations, prepared queries for geospatial dashboard workloads
**Confidence:** HIGH

## Summary

Phase 14 implements query-layer performance optimizations for enterprise dashboard workloads where the same queries repeat constantly (refresh every few seconds, multiple users viewing identical dashboards). The research confirms that ArcherDB's existing infrastructure provides strong foundations:

1. **SetAssociativeCache** (CLOCK Nth-Chance eviction) is already used in the LSM layer and can be adapted for query result caching
2. **S2 RegionCoverer** already computes cell coverings for spatial queries - caching these eliminates redundant computation
3. **VSR session model** (ClientSessions) provides connection-scoped lifecycle for prepared queries
4. **Metrics infrastructure** (Counter, Gauge, Histogram) is mature and ready for cache/latency metrics

**Primary recommendation:** Implement write-invalidation cache using existing SetAssociativeCache pattern, add S2 covering cache as separate specialized cache, leverage VSR sessions for prepared query lifecycle.

## Standard Stack

### Core (Built-in Zig patterns)

| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| SetAssociativeCacheType | `src/lsm/set_associative_cache.zig` | CLOCK eviction cache | Production-proven in LSM layer |
| CacheMapType | `src/lsm/cache_map.zig` | Hybrid cache + stash | Handles eviction + guaranteed entries |
| ClientSessions | `src/vsr/client_sessions.zig` | Session tracking | VSR-integrated connection lifecycle |
| Counter/Gauge/Histogram | `src/archerdb/metrics.zig` | Prometheus metrics | Mature, tested metric primitives |
| RegionCoverer | `src/s2/region_coverer.zig` | S2 cell covering | Spatial query foundation |

### Supporting

| Component | Location | Purpose | When to Use |
|-----------|----------|---------|-------------|
| stdx.hash_inline | stdx | Deterministic hashing | Cache key computation |
| BoundedArrayType | stdx | Fixed-capacity arrays | Covering cache entries |
| FixedBufferAllocator | std | Scratch allocations | S2 covering computation |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| SetAssociativeCache | Simple HashMap | HashMap has no eviction policy, unbounded growth |
| Write-invalidation | TTL-based | TTL adds complexity and stale data risk |
| Session-scoped prepared | Global prepared | Session scope matches PostgreSQL UX, simpler lifecycle |

## Architecture Patterns

### Recommended Structure

```
src/
├── query_cache.zig              # Query result cache implementation
├── s2_covering_cache.zig        # S2 cell covering cache
├── prepared_queries.zig         # Prepared query compilation/storage
├── batch_query.zig              # Batch query execution
└── geo_state_machine.zig        # (existing) - add cache integration
```

### Pattern 1: Write-Invalidation Cache

**What:** Cache entries are invalidated on any write operation, not by TTL expiry.

**When to use:** Dashboard workloads where data freshness comes from writes, not time.

**Implementation approach:**
```zig
// Query result cache - stores serialized response bytes
pub const QueryResultCache = struct {
    // Key: hash of query parameters (filter + operation type)
    // Value: cached response bytes + metadata
    cache: SetAssociativeCacheType(
        u64,                    // Query hash key
        CachedResult,           // Response + metadata
        key_from_result,
        hash_identity,          // Key already hashed
        layout,
    ),

    // Invalidation tracking
    generation: u64,            // Incremented on every write

    pub fn get(self: *QueryResultCache, query_hash: u64) ?*CachedResult {
        if (self.cache.get(query_hash)) |result| {
            if (result.generation == self.generation) {
                return result;  // Valid hit
            }
            // Stale entry - invalidated by write
            return null;
        }
        return null;
    }

    pub fn invalidateAll(self: *QueryResultCache) void {
        self.generation +%= 1;  // Wrapping increment
    }
};
```

**Why this pattern:** Write-invalidation is simpler than tracking spatial overlap for invalidation. Per context decisions, no bypass mechanism needed - all queries go through cache.

### Pattern 2: S2 Covering Cache

**What:** Cache computed S2 cell coverings for repeated bounding boxes/caps.

**When to use:** Spatial queries with repeated geometric patterns (same dashboard regions).

**Implementation approach:**
```zig
// S2 covering cache - stores computed cell ranges
pub const S2CoveringCache = struct {
    // Key: hash of region parameters
    // Value: computed cell ranges
    cache: SetAssociativeCacheType(
        u64,
        CachedCovering,
        key_from_covering,
        hash_identity,
        layout,
    ),

    pub const CachedCovering = struct {
        // Region parameters for validation
        param_hash: u64,
        // Computed covering
        ranges: [s2_max_cells]CellRange,
        num_ranges: u8,
    };

    pub fn getOrCompute(
        self: *S2CoveringCache,
        center_lat: i64,
        center_lon: i64,
        radius_mm: u32,
        scratch: []u8,
    ) [s2_max_cells]CellRange {
        const param_hash = hashCoverParams(center_lat, center_lon, radius_mm);

        if (self.cache.get(param_hash)) |cached| {
            return cached.ranges;
        }

        // Compute and cache
        const covering = S2.coverCap(scratch, center_lat, center_lon, radius_mm, 8, 30);
        _ = self.cache.upsert(&.{
            .param_hash = param_hash,
            .ranges = covering,
            .num_ranges = countValidRanges(covering),
        });
        return covering;
    }
};
```

### Pattern 3: Batch Query Execution

**What:** DynamoDB-style partial success - execute queries in parallel, return results for successful and errors for failed.

**When to use:** Dashboard refreshes that need multiple independent queries.

**Implementation approach:**
```zig
// Batch query request/response format
pub const BatchQueryRequest = struct {
    query_count: u32,
    // Followed by: query_count x QueryEntry
};

pub const QueryEntry = struct {
    query_type: QueryType,      // uuid, radius, polygon, latest
    query_id: u32,              // Client-assigned ID for correlation
    // Query-specific parameters follow
};

pub const BatchQueryResponse = struct {
    total_count: u32,
    success_count: u32,
    error_count: u32,
    // Followed by: QueryResult entries (successful first, then errors)
};

pub const QueryResultEntry = struct {
    query_id: u32,              // Correlates to request
    status: u8,                 // 0 = success, error code otherwise
    result_offset: u32,         // Offset to result data in response
    result_length: u32,         // Length of result data
};
```

### Pattern 4: Prepared Query Compilation

**What:** Pre-parse and validate queries, store compiled representation for fast re-execution.

**When to use:** Repeatedly executed queries with parameter substitution.

**Implementation approach:**
```zig
// Prepared query storage - session-scoped
pub const PreparedQuery = struct {
    name_hash: u64,             // Hash of user-provided name
    query_type: QueryType,
    // Pre-validated, normalized parameters
    compiled: CompiledQuery,
    // Execution statistics
    execution_count: u64,
    total_duration_ns: u64,
};

pub const SessionPreparedQueries = struct {
    queries: [max_prepared_per_session]?PreparedQuery,
    count: u32,

    pub fn prepare(self: *SessionPreparedQueries, name: []const u8, query: []const u8) !u32 {
        // Parse and validate query
        const compiled = try parseQuery(query);
        const name_hash = stdx.hash_inline(name);

        // Find slot (by name or empty)
        const slot = self.findOrAllocSlot(name_hash) orelse return error.TooManyPrepared;
        self.queries[slot] = .{
            .name_hash = name_hash,
            .query_type = compiled.query_type,
            .compiled = compiled,
            .execution_count = 0,
            .total_duration_ns = 0,
        };
        return slot;
    }

    pub fn execute(self: *SessionPreparedQueries, slot: u32, params: []const u8, output: []u8) !usize {
        const pq = &(self.queries[slot] orelse return error.PreparedNotFound);
        // Fast-path execution using pre-compiled query
        const start = std.time.nanoTimestamp();
        const result = try executeCompiled(&pq.compiled, params, output);
        pq.execution_count += 1;
        pq.total_duration_ns += @intCast(std.time.nanoTimestamp() - start);
        return result;
    }
};
```

### Pattern 5: Latency Breakdown Metrics

**What:** Separate histograms for each query phase (parse, plan, execute, serialize).

**When to use:** Performance diagnosis, SLA monitoring.

**Implementation approach:**
```zig
// Per-phase latency tracking
pub const QueryLatencyBreakdown = struct {
    parse_ns: LatencyHistogram,
    plan_ns: LatencyHistogram,
    execute_ns: LatencyHistogram,
    serialize_ns: LatencyHistogram,

    pub fn init() QueryLatencyBreakdown {
        return .{
            .parse_ns = latencyHistogram("archerdb_query_parse_seconds", "Query parse latency", null),
            .plan_ns = latencyHistogram("archerdb_query_plan_seconds", "Query plan latency", null),
            .execute_ns = latencyHistogram("archerdb_query_execute_seconds", "Query execute latency", null),
            .serialize_ns = latencyHistogram("archerdb_query_serialize_seconds", "Query serialize latency", null),
        };
    }

    pub fn record(self: *QueryLatencyBreakdown, breakdown: Breakdown) void {
        self.parse_ns.observeNs(breakdown.parse_ns);
        self.plan_ns.observeNs(breakdown.plan_ns);
        self.execute_ns.observeNs(breakdown.execute_ns);
        self.serialize_ns.observeNs(breakdown.serialize_ns);
    }
};
```

### Anti-Patterns to Avoid

- **TTL-based cache with dashboard workloads:** Adds stale data risk and complexity. Write-invalidation is simpler and correct.
- **Fine-grained spatial invalidation:** Complex to implement, diminishing returns. Coarse invalidation (invalidate all on write) is sufficient for dashboard workloads.
- **Global prepared queries:** Session-scoped is simpler lifecycle, matches PostgreSQL UX, avoids global state management.
- **Atomic batch semantics:** Not needed per context decisions. Partial success allows clients to retry failed queries independently.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Cache eviction | Custom LRU list | SetAssociativeCacheType | CLOCK Nth-Chance is better for cache-unfriendly workloads |
| S2 covering | Simplified grid | RegionCoverer | Handles cell hierarchy, level selection, range merging |
| Session lifecycle | Manual tracking | ClientSessions | VSR-integrated, handles registration/expiry |
| Metrics histograms | Rolling windows | HistogramType | Prometheus-compatible buckets, tested |
| Query hashing | Simple string hash | stdx.hash_inline | Deterministic across platforms |

**Key insight:** ArcherDB already has production-proven implementations of the core data structures. The work is integration and composition, not greenfield implementation.

## Common Pitfalls

### Pitfall 1: Cache Key Collision

**What goes wrong:** Different queries hash to same key, returning wrong results.

**Why it happens:** Insufficient entropy in cache key, not including all relevant parameters.

**How to avoid:** Include all query parameters in hash: operation type, all filter fields, pagination cursor.

**Warning signs:** Intermittent wrong results, especially with similar queries.

### Pitfall 2: Invalidation Race Conditions

**What goes wrong:** Write invalidates cache, but concurrent read still serves stale data.

**Why it happens:** Generation counter check not atomic with cache lookup.

**How to avoid:** Use generation comparison at lookup time, not store time. Generation wrapping is acceptable (2^64 writes is effectively infinite).

**Warning signs:** Occasional stale reads after writes, especially under load.

### Pitfall 3: S2 Covering Cache Key Mismatch

**What goes wrong:** Different regions hash to same key due to floating-point precision.

**Why it happens:** Using floating-point parameters in hash computation.

**How to avoid:** All S2 operations use nanodegrees (i64) and millimeters (u32) - integer types only in cache keys.

**Warning signs:** Wrong query results for similar but different geographic regions.

### Pitfall 4: Prepared Query Memory Leak

**What goes wrong:** Prepared queries accumulate without cleanup.

**Why it happens:** Session cleanup doesn't release prepared query resources.

**How to avoid:** Hook prepared query cleanup into session deallocation in ClientSessions lifecycle.

**Warning signs:** Memory growth correlated with session churn.

### Pitfall 5: Batch Query Response Size

**What goes wrong:** Batch response exceeds message_body_size_max.

**Why it happens:** No limit on queries per batch + large result sets.

**How to avoid:** Track accumulated response size during batch execution, truncate with has_more flag.

**Warning signs:** Message serialization failures, client timeouts.

## Code Examples

### Cache Hit/Miss Metric Integration

```zig
// Source: Existing pattern from geo_state_machine.zig QueryMetrics
pub fn recordCacheAccess(self: *QueryMetrics, hit: bool) void {
    if (hit) {
        archerdb_metrics.Registry.query_cache_hits.inc();
    } else {
        archerdb_metrics.Registry.query_cache_misses.inc();
    }
}

// In commit() query execution path:
if (self.query_cache.get(query_hash)) |cached| {
    self.query_metrics.recordCacheAccess(true);
    @memcpy(output[0..cached.len], cached.data[0..cached.len]);
    return cached.len;
}
self.query_metrics.recordCacheAccess(false);
// ... execute query
```

### Batch Query Wire Format

```zig
// Source: Following existing pattern from QueryUuidBatchFilter
pub const BatchQueryFilter = extern struct {
    /// Number of queries in batch
    query_count: u32,
    /// Reserved for future use
    reserved: u32 = 0,

    comptime {
        assert(@sizeOf(BatchQueryFilter) == 8);
        assert(stdx.no_padding(BatchQueryFilter));
    }
};

/// Individual query in batch - variable size based on query_type
pub const BatchQueryEntry = extern struct {
    /// Query type: 0=uuid, 1=radius, 2=polygon, 3=latest
    query_type: u8,
    /// Reserved for alignment
    _pad: [3]u8 = @splat(0),
    /// Client-assigned query ID for correlation
    query_id: u32,
    // Followed by query-specific filter (size varies by type)

    comptime {
        assert(@sizeOf(BatchQueryEntry) == 8);
    }
};
```

### S2 Covering Cache Hash Function

```zig
// Hash function for S2 covering cache keys
fn hashCoverParams(center_lat: i64, center_lon: i64, radius_mm: u32) u64 {
    // Use deterministic hash combining
    var hash: u64 = 0;
    hash = stdx.hash_inline(@as(u64, @bitCast(center_lat)));
    hash ^= stdx.hash_inline(@as(u64, @bitCast(center_lon)));
    hash ^= stdx.hash_inline(@as(u64, radius_mm));
    return hash;
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| LRU lists | CLOCK Nth-Chance | Established | Better for cache-unfriendly access patterns |
| Global query cache | Connection-scoped | N/A (design decision) | Simpler lifecycle, no cross-session coordination |
| TTL expiry | Write-invalidation | N/A (design decision) | Guaranteed freshness, simpler implementation |

**Deprecated/outdated:**
- None identified - this is greenfield implementation on existing foundations

## Open Questions

### 1. Cache Size Configuration

**What we know:** SetAssociativeCache requires value_count_max as multiple of value_count_max_multiple.

**What's unclear:** Optimal cache size for dashboard workloads - depends on query diversity, result sizes.

**Recommendation:** Start with configurable cache size, default to 1024 entries. Monitor hit ratio to tune.

### 2. Prepared Query Parameter Types

**What we know:** Context says "Claude's discretion on parameter type checking (strict vs coercion)".

**What's unclear:** What parameter types are most useful for geospatial queries.

**Recommendation:** Strict type checking initially - coordinates as i64 nanodegrees, radius as u32 mm. Matches existing filter types.

### 3. Batch Request Format

**What we know:** Context says "Claude's discretion on format (array vs named queries)".

**What's unclear:** Whether named queries add value over array indices.

**Recommendation:** Array format with client-assigned query_id for correlation. Simpler than named queries, sufficient for dashboard use cases.

## Sources

### Primary (HIGH confidence)

- `src/lsm/set_associative_cache.zig` - CLOCK eviction implementation
- `src/lsm/cache_map.zig` - Hybrid cache + stash pattern
- `src/vsr/client_sessions.zig` - Session lifecycle management
- `src/archerdb/metrics.zig` - Prometheus metrics primitives
- `src/s2/region_coverer.zig` - S2 covering computation
- `src/geo_state_machine.zig` - Query execution model, existing QueryMetrics

### Secondary (MEDIUM confidence)

- `.planning/phases/14-query-performance/14-CONTEXT.md` - User decisions from discussion phase

### Tertiary (LOW confidence)

- None - all findings verified against codebase

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Verified against existing codebase implementations
- Architecture: HIGH - Patterns follow existing ArcherDB conventions
- Pitfalls: HIGH - Derived from codebase analysis and common cache/query issues

**Research date:** 2026-01-24
**Valid until:** 2026-02-24 (30 days - stable domain, no external dependencies)
