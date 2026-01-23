# Phase 8: Observability Dashboards - Context

**Gathered:** 2026-01-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Production-ready Grafana dashboards and Prometheus alerting rules for ArcherDB operators. Provides visual monitoring of cluster health, query performance, replication status, and storage metrics. Includes alerting rules with configurable thresholds and routing templates.

</domain>

<decisions>
## Implementation Decisions

### Dashboard layout
- Layered depth: Overview dashboard with drill-down links to detail dashboards
- Overview shows balanced grid (equal weight to health, throughput, latency, replication)
- Four detail dashboards: Queries, Replication, Storage, Cluster/Node health
- Spacious panel density (2 panels per row) for readability
- Time range presets: Standard Grafana defaults plus ArcherDB-specific (last compaction cycle, last checkpoint)
- Cluster-wide aggregated view by default, drill into individual nodes manually
- Theme-agnostic (works with user's chosen Grafana theme)
- Annotation markers for key events: restarts, failovers, config changes

### Alert thresholds
- Tiered defaults: Conservative for pager-worthy alerts, aggressive for warnings/dashboard indicators
- Query latency: Warn >500ms p99, Critical >2s p99
- Replication lag: Both time-based (Warn >30s, Critical >2min) AND operations-based (Warn >1000 ops, Critical >10000 ops) — alert on whichever breaches first
- Memory usage: Warn >70%, Critical >85%

### Target audience
- Both SRE/Ops and Developers equally
- Technical internals in detail dashboards (LSM levels, compaction stats, VSR state)
- Abstractions in overview dashboard (latency, throughput, health status)
- Configurable terminology: Support switching between ArcherDB terms, generic database terms, and plain English via dashboard variable
- Rich tooltips on all panels explaining what they show and why it matters
- Tooltips include "Learn more" links to documentation

### Alert routing
- Broad coverage: Templates for Slack, PagerDuty, OpsGenie, email, generic webhook
- Every alert must include runbook link (required, not optional)
- Configurable escalation templates (users decide critical vs warning routing policy)
- Alert messages include brief remediation hint AND link to detailed runbook

### Claude's Discretion
- Exact panel queries and PromQL expressions
- Color schemes within theme-agnostic constraints
- Which metrics warrant their own panel vs combined views
- Annotation query implementation details
- Runbook file structure and naming

</decisions>

<specifics>
## Specific Ideas

- Terminology toggle as dashboard variable: "archerdb" | "database" | "plain" — panels reference this for display strings
- Overview dashboard should feel immediately useful to someone unfamiliar with ArcherDB
- Detail dashboards can assume familiarity with internals
- Alert runbooks should be in the documentation (Phase 9), alerts link to them

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 08-observability-dashboards*
*Context gathered: 2026-01-23*
