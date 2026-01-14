# Change: Add v2 Distributed Features

## Why

ArcherDB v1 provides strong single-region consistency with VSR consensus, but production deployments require:
- **Geographic distribution** for latency-sensitive global applications
- **Horizontal scaling** beyond single-cluster limits (1B entities per node)
- **Data protection** with encryption at rest for compliance
- **Storage efficiency** through intelligent data tiering

These v2 features transform ArcherDB from a single-region database into a globally distributed geospatial platform capable of serving multi-region, multi-tenant workloads at scale.

## What Changes

### Multi-Region Replication
- **ADDED** Async log shipping from primary to follower regions
- **ADDED** Read-only cross-region followers for read scaling
- **ADDED** Geo-sharding for regional data locality
- **ADDED** Active-active replication with conflict resolution (v2.2+)

### Index Sharding
- **ADDED** Stop-the-world resharding for capacity expansion (v2.0)
- **ADDED** Online resharding with minimal downtime (v2.1+)
- **ADDED** Shard management CLI commands
- **ADDED** Smart client topology discovery and routing

### Security
- **ADDED** Full-disk encryption with AES-NI hardware acceleration
- **ADDED** Key management integration (AWS KMS, HashiCorp Vault)
- **ADDED** Encryption key rotation without downtime

### Hybrid Memory (Data Tiering)
- **ADDED** Hot-Warm-Cold data tiering based on access patterns
- **ADDED** Automatic tier migration with configurable policies
- **ADDED** S3-compatible cold tier for cost optimization

### TTL Retention
- **ADDED** TTL extension on read (touch-to-extend pattern)
- **ADDED** Configurable TTL extension policies per entity type

### Client SDK Updates
- **MODIFIED** All SDKs to support multi-region routing
- **MODIFIED** All SDKs to support shard-aware connections
- **ADDED** Follower read preferences for read scaling

### Observability
- **ADDED** Cross-region replication lag metrics
- **ADDED** Shard health and balance metrics
- **ADDED** Encryption key rotation metrics
- **ADDED** Data tiering migration metrics

## Impact

### Affected Specs
- `specs/replication/spec.md` - Multi-region replication additions
- `specs/index-sharding/spec.md` - Resharding and shard management
- `specs/security/spec.md` - Encryption at rest
- `specs/hybrid-memory/spec.md` - Data tiering
- `specs/ttl-retention/spec.md` - TTL extension on read
- `specs/client-sdk/spec.md` - Multi-region and shard-aware clients
- `specs/observability/spec.md` - New metrics

### Affected Code
- `src/vsr/` - Async log shipping, follower replication
- `src/sharding/` - New module for shard management
- `src/storage/` - Encryption layer, tiering engine
- `src/clients/` - All SDK updates
- `src/archerdb/` - CLI commands, metrics

### Breaking Changes
- **BREAKING**: Wire protocol v2 for multi-region message routing
- **BREAKING**: Data file format v2 for encryption headers
- **BREAKING**: Configuration format changes for sharding

### Migration Path
1. v1 → v2.0: Deploy stop-the-world resharding, async log shipping
2. v2.0 → v2.1: Enable online resharding, encryption at rest
3. v2.1 → v2.2: Enable active-active (optional, advanced)

## Version Roadmap

| Version | Features | Target |
|---------|----------|--------|
| v2.0 | Async log shipping, read-only followers, stop-the-world resharding, encryption at rest | Phase 1 |
| v2.1 | Online resharding, hot-warm-cold tiering, TTL extension | Phase 2 |
| v2.2 | Active-active replication, geo-sharding | Phase 3 |

## Dependencies

- v1 spec compliance (complete)
- S3-compatible backup infrastructure (for async log shipping)
- Hardware with AES-NI support (required for v1, used for encryption)
