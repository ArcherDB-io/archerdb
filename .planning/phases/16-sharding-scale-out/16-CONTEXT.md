# Phase 16: Sharding & Scale-Out - Context

**Gathered:** 2026-01-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Enable horizontal scale-out with sharding by supporting online resharding, cross-shard query execution, hot shard detection/rebalancing visibility, and distributed tracing across the full request path.

</domain>

<decisions>
## Implementation Decisions

### Resharding workflow
- Use dual-write during migration (old + new) with reads from old until cutover.
- Migration errors trigger auto-rollback.

### Tracing coverage
- Default sampling is error-biased (all errors, subset of successes).
- Cross-shard linkage uses a hybrid of parent-child and span links.
- Traces include timing and result counts by default.

### Hot shard signals
- Hot shard detection uses a mixed signal (latency, queue, and throughput).
- Rebalancing is rate-limited by both cooldown windows and max concurrent moves.

### Claude's Discretion
- Traffic cutover strategy during resharding.
- Who drives data movement (source vs destination vs coordinator).
- Cross-shard fan-out strategy.
- Result aggregation approach.
- Cross-shard consistency model.
- Partial failure handling for cross-shard queries.
- Trace span granularity.
- Hot shard thresholds and trigger actions (alert vs auto-rebalance vs approval).

</decisions>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 16-sharding-scale-out*
*Context gathered: 2026-01-25*
