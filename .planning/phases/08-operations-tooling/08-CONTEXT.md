# Phase 8: Operations Tooling - Context

**Gathered:** 2026-01-31
**Status:** Ready for planning

<domain>
## Phase Boundary

Production deployment, upgrade, and disaster recovery capabilities. Operators can deploy ArcherDB clusters, perform zero-downtime upgrades with automatic rollback, run continuous backups without impacting traffic, and recover from failures with < 5 minute RTO and zero data loss.

</domain>

<decisions>
## Implementation Decisions

### Deployment Model
- **TigerBeetle-style flexibility:** Single static binary runs anywhere (bare metal, Docker, Kubernetes)
- Kubernetes: Both raw manifests (simple cases) and Helm chart (production with values.yaml)
- Storage: Host path for bare metal, PVC with storage class for cloud Kubernetes
- Local dev: Document both binary-with-config and Docker Compose paths equally
- No container runtime required for basic operation

### Backup Strategy
- **Continuous (CDC):** Stream changes to backup location in near-real-time
- Destinations: Both local filesystem and S3-compatible storage
- Zero traffic impact: Backups read from follower replica, never primary
- Retention: Sensible defaults (7 daily + 4 weekly + 12 monthly), operator can override via config

### Upgrade Approach
- **Rolling upgrade with fallback:** One node at a time, can pause/rollback if health degrades
- Rollback triggers: Health probe failures OR latency/error spike (P99 doubles, error rate threshold)
- Data format: Backwards compatible only — old versions can read new data
- Version compatibility: TigerBeetle model — each version specifies oldest compatible source, sequential upgrades if too far behind
- Upgrade order: Replicas first, then clients

### Disaster Recovery
- RTO: < 5 minutes
- RPO: Zero data loss (synchronous replication)
- Failover: Fully automatic — system detects failure and promotes replica without operator
- Single node failures handled by consensus automatically

### Claude's Discretion
- Deployment topology recommendations (same-DC vs multi-AZ)
- Helm chart structure and values organization
- Specific CDC implementation approach
- Health check intervals and thresholds for upgrade rollback

</decisions>

<specifics>
## Specific Ideas

- "Just like TigerBeetle" — single binary, runs anywhere, zero dependencies
- Forward upgradeability guaranteed: old data files migrate to new versions automatically
- Documentation should show multiple deployment paths equally (not favor one over another)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 08-operations-tooling*
*Context gathered: 2026-01-31*
