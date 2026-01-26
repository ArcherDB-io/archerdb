# Phase 18: Metrics Pipeline Wiring - Research

**Researched:** 2026-01-26
**Domain:** Prometheus metrics integration/wiring in Zig
**Confidence:** HIGH

## Summary

This phase is **integration/plumbing work** — metrics definitions already exist in Phases 12-14, and the Prometheus export pipeline already exists in `metrics_server.zig`. The work focuses on wiring existing metrics to the `/metrics` endpoint and ensuring E2E flow through Grafana dashboards and Prometheus alerts.

**Key findings:**
- Existing metrics infrastructure is mature (Counter, Gauge, Histogram types with thread-safe atomics)
- The `Registry.format()` function in `metrics.zig` is the single point where all metrics are exported
- Storage, query, and RAM index metrics modules already exist (`storage_metrics.zig`, `query_metrics.zig`, `index_metrics.zig`)
- Each metrics module has its own `format_all()` function that needs to be called from `Registry.format()`
- Dashboards exist and reference the expected metric names

**Primary recommendation:** Wire existing `format_all()` functions from storage/query/index metrics modules into `Registry.format()`, add scrape-time computation hooks, and verify E2E flow with integration tests.

## Standard Stack

### Core

| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| metrics.zig | `src/archerdb/metrics.zig` | Central Registry with format() | Single export point |
| metrics_server.zig | `src/archerdb/metrics_server.zig` | HTTP /metrics endpoint | Prometheus scrape handler |
| storage_metrics.zig | `src/archerdb/storage_metrics.zig` | Storage metric definitions | Phase 12 metrics |
| index_metrics.zig | `src/archerdb/index_metrics.zig` | RAM index metric definitions | Phase 13 metrics |
| query_metrics.zig | `src/archerdb/query_metrics.zig` | Query metric definitions | Phase 14 metrics |

### Supporting

| Component | Location | Purpose | When to Use |
|-----------|----------|---------|-------------|
| cluster_metrics.zig | `src/archerdb/cluster_metrics.zig` | Cluster/pool/shedding metrics | Already wired in |
| compaction_metrics.zig | `src/lsm/compaction_metrics.zig` | LSM compaction tracking | Used by storage_metrics |

### Integration Test Infrastructure

| Component | Location | Purpose |
|-----------|----------|---------|
| integration_tests.zig | `src/integration_tests.zig` | External process testing |
| fetchMetrics() | `src/integration_tests.zig:54` | HTTP client for /metrics |
| expectContains() | `src/integration_tests.zig:77` | Assertion helper |

## Architecture Patterns

### Recommended Project Structure

Existing structure is appropriate:
```
src/archerdb/
├── metrics.zig           # Central Registry + format()
├── metrics_server.zig    # HTTP server + /metrics handler
├── storage_metrics.zig   # Storage (Phase 12)
├── index_metrics.zig     # RAM index (Phase 13)
├── query_metrics.zig     # Query (Phase 14)
└── cluster_metrics.zig   # Already wired
```

### Pattern 1: Scrape-Time Computation

**What:** Compute metric values when `/metrics` is called, not on background ticks
**When to use:** Per CONTEXT.md decision — keeps it simple, no background threads
**Example:**
```zig
// In metrics_server.zig handleMetrics()
pub fn handleMetrics(client_fd: posix.socket_t) !void {
    // Before formatting, update scrape-time metrics
    updateStorageMetricsOnScrape();  // NEW: compute fresh values
    updateIndexMetricsOnScrape();     // NEW: compute fresh values
    updateQueryMetricsOnScrape();     // NEW: compute fresh values

    // Then format all metrics
    metrics.Registry.format(writer) catch |err| { ... };
}
```

### Pattern 2: Module format_all() Delegation

**What:** Each metrics module has `format_all(writer)` that Registry.format() calls
**When to use:** Storage/index/query metrics have their own format functions
**Example:**
```zig
// In Registry.format() - add calls to sub-module formatters
pub fn format(writer: anytype) !void {
    // ... existing metrics ...

    // Storage metrics (Phase 12 - STOR-03)
    try storage.format_all(writer);

    // RAM index metrics (Phase 13 - MEM-03)
    try index.format_all(writer);

    // Query metrics (Phase 14 - QUERY-04)
    // query_metrics has QueryLatencyBreakdown.toPrometheus()
    // and SpatialIndexStats.toPrometheus()
}
```

### Pattern 3: Counter Persistence

**What:** Counters persist across restarts for true lifetime totals
**When to use:** Per CONTEXT.md decision — differs from standard Prometheus pattern
**Implementation approach:**
- Store counter state to persistent file on graceful shutdown
- Load counter state on startup
- Alternatively, use VSR state machine for durability
**Caution:** This requires careful handling to avoid double-counting

### Pattern 4: Debug Metrics Gating

**What:** Internal/debug metrics gated by `--debug-metrics` flag
**When to use:** Keep default /metrics output clean for operators
**Example:**
```zig
pub fn format(writer: anytype, include_debug: bool) !void {
    // Always include user-facing metrics
    try formatUserFacingMetrics(writer);

    // Conditionally include debug metrics
    if (include_debug) {
        try formatDebugMetrics(writer);
    }
}
```

### Anti-Patterns to Avoid

- **Background tick updates:** CONTEXT.md specifies scrape-time computation only
- **Computation timeouts:** Let Prometheus scrape timeout handle slow responses
- **Hardcoded histogram buckets:** Make configurable via config (per CONTEXT.md)
- **Incomplete wiring:** Wire ALL metrics from Phases 12-14, not just a subset

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Prometheus format | Custom formatter | Existing Counter/Gauge/Histogram.format() | Already handles # HELP/# TYPE correctly |
| HTTP server | New HTTP stack | Existing MetricsServer in metrics_server.zig | Already handles routing, auth, caching |
| Thread safety | Mutexes | std.atomic.Value (existing pattern) | Lock-free, already used throughout |
| Metric types | Custom counters | metrics.Counter/Gauge/HistogramType | Already thread-safe, Prometheus-compatible |

**Key insight:** The infrastructure exists — this phase is wiring, not building.

## Common Pitfalls

### Pitfall 1: Missing HELP/TYPE Lines

**What goes wrong:** Prometheus rejects metrics without proper # HELP/# TYPE headers
**Why it happens:** Manual formatting instead of using .format() methods
**How to avoid:** Use existing Counter/Gauge/Histogram.format() methods which include headers
**Warning signs:** `promtool check metrics` fails, Prometheus scrape errors

### Pitfall 2: Duplicate Metric Names

**What goes wrong:** Same metric exported twice with different labels causes conflicts
**Why it happens:** Multiple modules defining same metric name
**How to avoid:** Check existing Registry metrics before adding; share HELP/TYPE for labeled metrics
**Warning signs:** Prometheus errors about conflicting metric families

### Pitfall 3: Expensive Scrape Computation

**What goes wrong:** /metrics endpoint times out under load
**Why it happens:** Computing too much at scrape time
**How to avoid:** Cache expensive computations, use existing MetricsCache (1-second TTL)
**Warning signs:** Prometheus scrape timeouts, missing data gaps in dashboards

### Pitfall 4: Missing Labels for Cardinality

**What goes wrong:** Dashboard queries fail because expected labels don't exist
**Why it happens:** Metrics exported without per-tree/per-level/per-query-type labels
**How to avoid:** Match label cardinality from dashboard JSON queries
**Warning signs:** Dashboard panels show "No data"

### Pitfall 5: Counter Reset on Restart

**What goes wrong:** Counter values reset to 0 on restart, rate() shows negative spike
**Why it happens:** Standard Prometheus counters start at 0
**How to avoid:** Per CONTEXT.md — persist counter state (this is non-standard but user-requested)
**Warning signs:** `rate()` shows impossible negative values after restarts

## Code Examples

### Wiring storage_metrics.format_all() into Registry.format()

```zig
// In src/archerdb/metrics.zig, inside Registry.format()
pub fn format(writer: anytype) !void {
    // ... existing metrics (info, health_ready, write_*, read_*, etc.) ...

    // Storage metrics (Phase 12 - STOR-03)
    try storage.format_all(writer);

    // ... continue with other metrics ...
}
```

### Wiring index_metrics.format_all() into Registry.format()

```zig
// In src/archerdb/metrics.zig, inside Registry.format()

    // RAM index metrics (Phase 13 - MEM-03)
    try index.format_all(writer);
```

### Wiring query_metrics into Registry.format()

QueryLatencyBreakdown and SpatialIndexStats are structs that need instances:

```zig
// In src/archerdb/metrics.zig, add instance references
pub const query_latency_breakdown = @import("query_metrics.zig").QueryLatencyBreakdown.init();
pub var spatial_index_stats = @import("query_metrics.zig").SpatialIndexStats.init();

// In Registry.format()
    // Query metrics (Phase 14 - QUERY-04)
    try query_latency_breakdown.toPrometheus(writer);
    try spatial_index_stats.toPrometheus(writer);
```

### Integration Test for Metrics Presence

```zig
// In src/integration_tests.zig or new test file
test "metrics: storage metrics exported" {
    // Start ArcherDB with metrics enabled
    var archerdb = try TmpArcherDB.start(.{ .metrics_port = 0 });
    defer archerdb.stop();

    const metrics_response = try fetchMetrics(std.testing.allocator, archerdb.metrics_port);
    defer std.testing.allocator.free(metrics_response);

    // STOR-03: Write amplification monitoring
    try expectContains(metrics_response, "archerdb_compaction_write_amplification");
    try expectContains(metrics_response, "archerdb_storage_space_amplification");
    try expectContains(metrics_response, "archerdb_compaction_level_bytes_total");

    // MEM-03: Memory usage metrics
    try expectContains(metrics_response, "archerdb_ram_index_memory_bytes");
    try expectContains(metrics_response, "archerdb_ram_index_load_factor");
    try expectContains(metrics_response, "archerdb_ram_index_entries_total");

    // QUERY-04: Query latency breakdown
    try expectContains(metrics_response, "archerdb_query_parse_seconds");
    try expectContains(metrics_response, "archerdb_query_plan_seconds");
    try expectContains(metrics_response, "archerdb_query_execute_seconds");
    try expectContains(metrics_response, "archerdb_query_serialize_seconds");
}
```

### Scrape-Time Update Hook

```zig
// In metrics_server.zig, add update hooks before formatting
fn handleMetrics(client_fd: posix.socket_t) !void {
    // Update health status gauge
    const state = replica_state;
    metrics.Registry.health_ready.set(if (state.isReady()) 1 else 0);

    // NEW: Update storage metrics on scrape
    if (getWriteAmpMetrics()) |wam| {
        storage.update_from_metrics(wam);
    }

    // NEW: Update index metrics on scrape
    if (getRAMIndexState()) |idx| {
        index.update_from_index(idx.entry_count, idx.capacity, 64);
    }

    // Check cache first (per observability/spec.md: cache for up to 1 second)
    if (metrics_cache.get()) |cached_data| {
        try sendResponse(client_fd, .ok, "text/plain; version=0.0.4", cached_data);
        return;
    }

    // ... rest of formatting ...
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Background tick updates | Scrape-time computation | CONTEXT.md decision | Simpler, no background threads |
| Reset counters on restart | Persist counter state | CONTEXT.md decision | True lifetime totals |
| All metrics by default | Debug metrics gated | CONTEXT.md decision | Cleaner operator view |

**Current best practice:**
- Compute fresh values on scrape (not background)
- 1-second cache for frequent scrapes
- Debug metrics gated by `--debug-metrics` flag
- Full cardinality labels (per-tree, per-level, per-query-type)

## Open Questions

### 1. Counter Persistence Mechanism

**What we know:** CONTEXT.md requires counters persist across restarts
**What's unclear:** Best mechanism (file? VSR state? checkpoints?)
**Recommendation:** Use checkpoint mechanism (already exists for durability) or simple JSON file written on graceful shutdown. Verify with user if this complexity is worth the benefit.

### 2. Histogram Bucket Configuration

**What we know:** CONTEXT.md says "configurable via config (not hardcoded)"
**What's unclear:** Where config comes from (CLI flags? config file? environment?)
**Recommendation:** Follow existing config patterns in `src/archerdb/cli.zig`. If no precedent, use config file approach.

### 3. Query Metrics Instance Management

**What we know:** QueryLatencyBreakdown and SpatialIndexStats are structs that need instances
**What's unclear:** Where instances should live (Registry? global? passed through call chain?)
**Recommendation:** Add instances to Registry (matches existing pattern for cluster_metrics)

## Sources

### Primary (HIGH confidence)
- `/Users/g/archerdb/src/archerdb/metrics.zig` - Central metrics registry, Counter/Gauge/Histogram types
- `/Users/g/archerdb/src/archerdb/metrics_server.zig` - HTTP endpoint, handleMetrics(), MetricsCache
- `/Users/g/archerdb/src/archerdb/storage_metrics.zig` - STOR-03 metrics definitions with format_all()
- `/Users/g/archerdb/src/archerdb/index_metrics.zig` - MEM-03 metrics definitions with format_all()
- `/Users/g/archerdb/src/archerdb/query_metrics.zig` - QUERY-04 metrics definitions with toPrometheus()
- `/Users/g/archerdb/observability/grafana/dashboards/*.json` - Dashboard metric queries
- `/Users/g/archerdb/observability/prometheus/rules/*.yaml` - Alert rule metric references

### Secondary (MEDIUM confidence)
- `/Users/g/archerdb/.planning/phases/18-metrics-pipeline-wiring/18-CONTEXT.md` - User decisions
- `/Users/g/archerdb/.planning/phases/12-storage-optimization/12-CONTEXT.md` - Phase 12 decisions
- `/Users/g/archerdb/.planning/phases/13-memory-ram-index/13-CONTEXT.md` - Phase 13 decisions
- `/Users/g/archerdb/.planning/phases/14-query-performance/14-CONTEXT.md` - Phase 14 decisions

### Tertiary (LOW confidence)
- None — all findings verified against codebase

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — verified against existing codebase
- Architecture: HIGH — follows established patterns in metrics.zig
- Pitfalls: HIGH — derived from Prometheus conventions and existing code review

**Research date:** 2026-01-26
**Valid until:** 60 days (stable domain, no external dependencies changing)
