# Phase 15: Cluster & Consensus - Context

**Gathered:** 2026-01-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Harden cluster operations for enterprise scale: connection pooling to prevent connection storms, VSR consensus tuning for stability under network variance, load shedding for overload protection, and read replicas for 10x read scaling. This phase focuses on cluster infrastructure that operators configure and monitor.

</domain>

<decisions>
## Implementation Decisions

### Connection Pooling Behavior
- Default pool size: 16-32 connections per client (medium, standard app server defaults)
- Idle connection policy: Adaptive — reap faster under memory pressure, slower when idle
- Metrics: Aggregate always, per-client labels for top-N active clients (avoids cardinality explosion)

### Load Shedding Strategy
- Primary overload signal: Composite (queue depth + latency P99 + resource pressure weighted together)
- Shedding curve: Hard cutoff — below threshold accept all, above threshold reject all new requests
- Shed response: HTTP 429 Too Many Requests with Retry-After header
- Runtime configurability: Yes, but with guardrails — adjustable within safe bounds, cannot disable entirely

### Read Replica Routing
- Staleness guarantee: Eventual (unbounded) — simplest, highest availability
- Replica selection: Server routes — load-balances across healthy replicas automatically
- Failover behavior: Fail to leader if all replicas unhealthy — maintains availability
- Read marking: Automatic for read-only queries — pure reads auto-route to replica, writes to leader

### Consensus Tuning
- Target environment: Hybrid/configurable — presets for cloud (high variance) and datacenter (low latency)
- View change detection: Aggressive — fast leader failover to minimize unavailability window
- Timeout configuration: Profile + overrides — start from preset, allow specific timeout overrides

### Claude's Discretion
- Pool overflow handling (queue vs fail-fast)
- Specific timeout values and jitter policy for consensus
- Composite signal weighting for load shedding
- Top-N threshold for per-client metrics sampling

</decisions>

<specifics>
## Specific Ideas

- Connection pool should behave like standard database pools (PgBouncer, HikariCP patterns)
- Load shedding should be predictable — operators need to understand when and why requests get shed
- Read replica routing should be transparent to applications — just works without client changes

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 15-cluster-consensus*
*Context gathered: 2026-01-24*
