# Phase 18: Metrics Pipeline Wiring - Context

**Gathered:** 2026-01-26
**Status:** Ready for planning

<domain>
## Phase Boundary

Wire storage, query, and RAM index metrics (defined in Phases 12-14) to the Prometheus export pipeline. Ensure metrics update at runtime and flow through /metrics endpoint to populate Grafana dashboards and trigger alerts. This is integration/plumbing work — metrics definitions already exist.

</domain>

<decisions>
## Implementation Decisions

### Update Frequency
- Compute fresh values on scrape (when /metrics is hit)
- No background tick or event-driven updates — scrape-time computation keeps it simple
- Counters persist across restarts (store counter state for true lifetime totals)
- No computation timeout — let Prometheus scrape timeout handle slow responses

### Export Scope
- Wire ALL metrics defined in Phases 12-14 (complete observability)
- Full cardinality labels included (per-tree, per-level, per-query-type breakdowns)
- Histogram buckets are configurable via config (not hardcoded)
- Internal/debug metrics gated by `--debug-metrics` flag (default: user-facing only)

### Verification Approach
- Both integration tests AND manual verification docs
- Integration tests: CI-runnable, assert presence and appropriate values
- Update dashboards as needed to query newly-wired metrics
- Acceptance bar: scrape succeeds + dashboard populates + alerts fire (full E2E)

### Claude's Discretion
- Caching strategy for expensive computations (based on actual cost analysis)
- Integration test assertion depth per metric type
- Specific dashboard panel updates needed

</decisions>

<specifics>
## Specific Ideas

- Counters must persist across restarts — this differs from standard Prometheus pattern but provides true lifetime totals
- Debug metrics should be opt-in via flag to keep default /metrics output clean for operators
- Full E2E validation means alerts must actually fire when thresholds exceeded, not just theoretically

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 18-metrics-pipeline-wiring*
*Context gathered: 2026-01-26*
