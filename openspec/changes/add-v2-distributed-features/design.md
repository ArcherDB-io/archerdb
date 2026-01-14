# Design: v2 Distributed Features

## Context

ArcherDB v1 provides a single-region, strongly consistent geospatial database using VSR consensus. Production requirements demand:

1. **Global reach**: Applications need low-latency access from multiple regions
2. **Scale beyond 1B entities**: Horizontal sharding required
3. **Compliance**: Encryption at rest for regulated industries
4. **Cost optimization**: Tiered storage for historical data

### Constraints

- VSR consensus requires same-region latency (50ms max round-trip)
- Cross-region synchronous replication is impractical (100-200ms latency)
- Data must remain strongly consistent within regions
- Migration from v1 must preserve data integrity

### Stakeholders

- **Operators**: Need simple deployment, monitoring, and maintenance
- **Developers**: Need SDK updates for multi-region routing
- **Compliance teams**: Need encryption and audit capabilities

## Goals / Non-Goals

### Goals
- Enable horizontal scaling beyond single-cluster limits
- Provide cross-region read replicas for latency reduction
- Support encryption at rest with hardware acceleration
- Implement intelligent data tiering for cost optimization
- Maintain v1's performance guarantees within regions

### Non-Goals
- Real-time cross-region synchronous writes (physically impossible at scale)
- Full ACID transactions across regions (use eventual consistency)
- Support for non-x86 architectures (AES-NI dependency)
- Automatic geo-routing based on client location (v3 consideration)

## Decisions

### Decision 1: Async Log Shipping for Cross-Region Replication

**Choice**: Primary region ships committed WAL entries to follower regions asynchronously.

**Rationale**:
- Preserves strong consistency within primary region
- Provides eventual consistency to follower regions (sub-second lag typical)
- Reuses existing S3 backup infrastructure
- Allows follower regions to serve stale reads

**Alternatives Considered**:
1. *Synchronous cross-region VSR*: Rejected - 100-200ms latency per commit unacceptable
2. *Application-level replication*: Rejected - Complex, error-prone, inconsistent
3. *Database triggers*: Rejected - Not applicable to our architecture

**Implementation**:
```
Primary Region                    Follower Region
┌─────────────────┐              ┌─────────────────┐
│   R1  R2  R3    │   WAL Ship   │   F1  F2  F3    │
│   (VSR Quorum)  │ ───────────► │   (Read-Only)   │
│                 │   S3/Direct  │                 │
│   Commit → WAL  │              │   Apply → Index │
└─────────────────┘              └─────────────────┘
```

### Decision 2: Entity-ID Hash Sharding

**Choice**: Shard entities by `hash(entity_id) % shard_count`.

**Rationale**:
- Even distribution across shards
- Deterministic routing without metadata lookup
- Entity updates always go to same shard
- Simple to implement and reason about

**Alternatives Considered**:
1. *Geohash sharding*: Rejected - Entity location changes cause shard migrations
2. *Consistent hashing ring*: Deferred to v2.1 - Simpler modulo sufficient for v2.0
3. *Range sharding*: Rejected - Hot spots on sequential entity IDs

**Trade-off**: Spatial queries must scatter-gather across all shards (no locality benefit).

### Decision 3: Stop-the-World Resharding for v2.0

**Choice**: Planned maintenance window required for resharding.

**Rationale**:
- Dramatically simpler implementation
- Acceptable for initial deployments (quarterly scaling events)
- Online resharding complexity deferred to v2.1

**Procedure**:
1. Create full backup
2. Stop writes (read-only mode)
3. Deploy new cluster with target shard count
4. Restore from backup with new shard mapping
5. Update client configurations
6. Resume writes

**Estimated Downtime**: 60-90 minutes for 1B entities.

### Decision 4: AES-256-GCM for Encryption at Rest

**Choice**: Encrypt data files with AES-256-GCM using AES-NI hardware acceleration.

**Rationale**:
- Industry standard for data-at-rest encryption
- AES-NI provides 10+ GB/s throughput (no performance impact)
- GCM provides authenticated encryption (integrity + confidentiality)
- Compatible with HSM/KMS key management

**Key Hierarchy**:
```
Master Key (KMS/Vault)
    │
    ├── Data Encryption Key (DEK) - per data file
    │       └── Rotates independently
    │
    └── Wrapped DEK (stored in file header)
            └── Unwrapped at file open
```

### Decision 5: Hot-Warm-Cold Tiering Based on Access Age

**Choice**: Tier data based on last access time, not insertion time.

**Rationale**:
- Frequently accessed old data stays hot
- Rarely accessed recent data can migrate to warm/cold
- Aligns with TTL extension on read behavior
- Configurable thresholds per deployment

**Tiers**:
| Tier | Storage | Access Time | Use Case |
|------|---------|-------------|----------|
| Hot | NVMe RAM Index | <7 days | Active entities |
| Warm | NVMe LSM | 7-30 days | Recent history |
| Cold | S3 | >30 days | Archive/compliance |

### Decision 6: Active-Active Conflict Resolution (v2.2)

**Choice**: Last-writer-wins with vector clocks for conflict detection.

**Rationale**:
- Simple mental model for developers
- Vector clocks enable conflict detection without coordination
- Conflicts are rare for geospatial data (entity updates from same source)
- Custom resolution hooks available for complex cases

**Deferred to v2.2** because:
- Requires significant protocol changes
- Most deployments don't need active-active
- Can be added without breaking v2.0/v2.1 deployments

## Risks / Trade-offs

### Risk 1: Cross-Region Lag Visibility
**Risk**: Developers may assume follower reads are fresh.
**Mitigation**:
- Expose `archerdb_replication_lag_seconds` metric prominently
- SDK returns `read_staleness_ms` with every follower read
- Documentation emphasizes eventual consistency model

### Risk 2: Resharding Downtime
**Risk**: Stop-the-world resharding unacceptable for some users.
**Mitigation**:
- Clear documentation of downtime expectations
- Online resharding roadmap in v2.1
- Blue-green deployment guidance for minimal impact

### Risk 3: Encryption Performance on Older CPUs
**Risk**: CPUs without AES-NI will have significant overhead.
**Mitigation**:
- AES-NI already required for v1 (no new constraint)
- Startup check fails fast if AES-NI unavailable
- Fallback to software AES only in CI/test environments

### Risk 4: Tiering Migration Storms
**Risk**: Mass migration to cold tier during quiet periods.
**Mitigation**:
- Rate-limit migrations to 1% of hot tier per hour
- Configurable migration windows
- Metrics for migration queue depth

## Migration Plan

### Phase 1: v1 → v2.0 (Incremental)
1. Deploy v2.0 server alongside v1 (blue-green)
2. Enable async log shipping to follower region
3. Update SDKs to v2 (backward compatible)
4. Switch traffic to v2.0 primary
5. Decommission v1 cluster

### Phase 2: Enable Sharding (v2.0)
1. Schedule maintenance window
2. Create backup of single-shard cluster
3. Deploy multi-shard cluster
4. Restore with shard mapping
5. Update client configurations
6. Validate data integrity

### Phase 3: Enable Encryption (v2.1)
1. Generate master key in KMS
2. Enable encryption on new data files
3. Background migration encrypts existing files
4. Validate with `archerdb verify --encryption`

### Rollback Procedure
- v2.0 → v1: Restore from pre-upgrade backup (data loss since backup)
- v2.1 → v2.0: Disable new features via config (no data loss)
- Encrypted → Unencrypted: Not supported (compliance constraint)

## Open Questions

1. **Follower Promotion**: Should follower regions be promotable to primary?
   - Current answer: No (requires manual disaster recovery)
   - Future consideration for v2.2

2. **Shard Rebalancing Trigger**: Automatic vs manual?
   - Current answer: Manual (operator-initiated)
   - Automatic rebalancing adds complexity

3. **Cold Tier Query Performance**: What latency SLA for cold tier reads?
   - Proposal: <5 seconds for cold tier (S3 latency)
   - Hot/warm maintain existing SLAs

4. **TTL Extension Limits**: Maximum extension count?
   - Proposal: Configurable, default unlimited
   - Some use cases need expiry guarantees

## References

- `specs/replication/spec.md` - v1 VSR consensus details
- `specs/index-sharding/spec.md` - Existing sharding design docs
- `specs/backup-restore/spec.md` - S3 backup infrastructure
- AWS KMS documentation for key management patterns
- Google Spanner paper for geo-distributed inspiration
