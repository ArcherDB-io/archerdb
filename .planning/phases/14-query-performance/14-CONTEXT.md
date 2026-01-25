# Phase 14: Query Performance - Context

**Gathered:** 2026-01-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Achieve 80%+ cache hit ratio for dashboard workloads with sub-millisecond cached queries. Implements query result caching, batch query API, S2 cell covering cache, query latency breakdown metrics, and prepared queries. This is query-layer optimization for repeated dashboard patterns, not general database performance.

</domain>

<decisions>
## Implementation Decisions

### Cache behavior
- Write-invalidation strategy — cache entries invalidate on writes, no time-based TTL
- Cache everything — no bypass mechanism, all read queries go through cache
- Let invalidation handle freshness rather than expiry timers

### Cache invalidation granularity
- Claude's discretion on spatial invalidation approach (coarse vs S2 cell-based)
- S2 cell covering cache eliminates redundant computation for repeated bounding boxes

### Cache eviction
- Claude's discretion on eviction strategy (LRU vs size-weighted)

### Batch API design
- DynamoDB-style partial success handling — each query succeeds/fails independently
- Response includes results for successful queries and errors for failed ones
- No atomic/transactional semantics across the batch
- Parallel execution — all queries in batch run concurrently
- No limit on queries per batch — clients control batch size

### Batch request format
- Claude's discretion on format (array vs named queries)

### Metrics exposure
- Cache metrics as counter pair: archerdb_query_cache_hits_total and archerdb_query_cache_misses_total
- Query metrics labeled by type (point/range/spatial)
- Separate prepared query counters (not labels on existing metrics)

### Latency breakdown
- Claude's discretion on histogram structure for parse/plan/execute/serialize breakdown

### Prepared query UX
- Session-scoped lifetime — prepared queries live for connection duration (PostgreSQL style)
- Queries deallocate when session ends

### Prepared query creation and execution
- Claude's discretion on creation mechanism (PREPARE statement vs API endpoint)
- Claude's discretion on execution reference (name vs handle)
- Claude's discretion on parameter type checking (strict vs coercion)

### Claude's Discretion
- Cache eviction algorithm (LRU or size-weighted LRU)
- Spatial cache invalidation granularity (coarse or S2 cell-based)
- Batch request format structure
- Latency histogram organization
- Prepared query creation syntax
- Prepared query execution reference mechanism
- Parameter type handling approach

</decisions>

<specifics>
## Specific Ideas

- Dashboard workload pattern: same queries repeat constantly (refresh every few seconds, multiple users viewing same dashboards)
- Cache eliminates redundant parse/plan overhead for repeated identical queries
- S2 cell covering cache specifically targets expensive spatial computation

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 14-query-performance*
*Context gathered: 2026-01-24*
