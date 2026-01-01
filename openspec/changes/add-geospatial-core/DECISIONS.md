# Architecture Decision Record

This document captures all architectural decisions made for ArcherDB's core geospatial database implementation.

## Decision Summary

All decisions follow TigerBeetle's proven patterns for maximum performance and operational simplicity.

---

## Client Interface

### Q1: Client API Protocol
**Decision:** Custom Binary Protocol (Option A)

**Rationale:**
- Maximum performance with zero-copy message passing
- Perfect alignment with VSR message format
- 128-byte GeoEvents map directly to wire format
- Proven by TigerBeetle at 1M+ TPS

**Implementation:** See `specs/client-protocol/spec.md`

---

### Q2: SDK Language Priority
**Decision:** Official SDKs for Zig, Java, Go, Python, Node.js

**Rationale:**
- Matches TigerBeetle's proven SDK strategy
- Covers vast majority of backend systems
- These four languages dominate geospatial use cases:
  - Java: Enterprise backends, Android
  - Go: Cloud-native services, microservices
  - Python: Data science, analytics, GeoPandas
  - Node.js: Web dashboards, real-time mapping

**Priority Order:**
1. **Zig** - Reference implementation
2. **Java, Go, Python, Node.js** - Initial release (parallel development)
3. **Swift, C#, Elixir** - Future based on demand

---

## Security

### Q3: Authentication Mechanism
**Decision:** Mutual TLS (mTLS) with optional disable (Option A)

**Rationale:**
- Industry standard for database authentication
- TigerBeetle uses mTLS
- Transport encryption + authentication in one mechanism
- Certificate revocation support
- Production-grade security

**Configuration:**
- Production: `--tls-required=true` (default)
- Development: `--tls-required=false` (localhost only)

**Implementation:** See `specs/security/spec.md`

---

### Q4: Authorization Model
**Decision:** All-or-nothing (Option A)

**Rationale:**
- Matches TigerBeetle's simplicity
- Zero authorization overhead in hot path
- Authenticated clients have full read/write access
- Multi-tenancy via separate clusters (strong isolation)

**Future Extension:**
- Namespace-based authorization MAY be added in v2 using `group_id` field
- Backward compatible with all-or-nothing mode

---

## Operational Features

### Q5: Real-Time Subscriptions
**Decision:** Defer to v2 (Option C)

**Rationale:**
- TigerBeetle launched without subscriptions
- Subscriptions add significant complexity (state management, backpressure, VSR coordination)
- Polling is sufficient for MVP (clients can query every 100ms-1s)
- Better design with usage data after core features proven

**Workaround for v1:**
- Clients poll with time range: `find_in_polygon(vertices, last_query_time, now())`

---

### Q6: Observability - Metrics Export
**Decision:** Prometheus endpoint (Option A)

**Rationale:**
- Industry standard for database monitoring
- Huge ecosystem (Grafana, Alertmanager)
- Pull-based, no external dependencies

**Configuration:**
- Endpoint: `http://<node-ip>:9091/metrics`
- Format: Prometheus text format
- Binding: All interfaces (configurable to localhost only)

**Implementation:** See `specs/observability/spec.md`

---

### Q7: Logging Strategy
**Decision:** Zig std.log with configurable format (Option C)

**Rationale:**
- Matches TigerBeetle approach
- Compile-time log level filtering (zero cost for disabled levels)
- Flexible output format

**Configuration:**
- `--log-format=json` - Structured logs (production)
- `--log-format=text` - Human-readable (development)
- `--log-level=debug|info|warn|error`

**Implementation:** See `specs/observability/spec.md`

---

## Cluster Management

### Q8: Dynamic Membership / Reconfiguration
**Decision:** Static membership only (Option A)

**Rationale:**
- TigerBeetle uses static membership
- Dynamic reconfiguration is extremely complex (open research problem)
- Static membership is production-proven and sufficient
- Plan capacity upfront based on expected load

**Implementation:**
- Cluster size fixed at `archerdb format --cluster=N` time
- Cannot add/remove nodes from running cluster
- Data migration to new cluster if capacity expansion needed

---

### Q9: Maximum Cluster Size
**Decision:** Support 3, 5, or 6 replicas (Option A)

**Rationale:**
- Matches TigerBeetle's flexibility
- Flexible deployment options:
  - 3 nodes: Tolerate 1 failure (quorum=2)
  - 5 nodes: Tolerate 2 failures (quorum=3)
  - 6 nodes: Tolerate 2 failures (quorum=4, Flexible Paxos)

**Configuration:**
- `archerdb format --cluster=3|5|6`
- Default: 5 (good balance of availability and cost)
- Development: 1 node (no replication)

---

## Technical Details

### Q10: S2 Library Integration
**Decision:** Pure Zig implementation (Option B)

**Rationale:**
- Own the entire stack (TigerBeetle philosophy)
- No C++ dependencies
- Better integration, easier debugging
- Full control over performance optimizations

**Implementation Scope:**
- Core algorithms only (~2000 LOC):
  1. Lat/lon → S2 Cell ID (Hilbert curve projection)
  2. Cell hierarchy (bit-shifting)
  3. RegionCoverer (polygon → cell ranges)
  4. Basic point-in-polygon (ray casting)
- Defer complex geodesics and advanced operations

**Tasks:** See `tasks.md` section 12 (S2 Integration)

---

### Q11: H3 Support (Alternative Spatial Index)
**Decision:** S2 only, defer H3 (Option A/C)

**Rationale:**
- S2 covers all core use cases (radius, polygon queries)
- S2 better for database indexing (perfect hierarchy, range scans)
- H3 better for analytics/visualization (user's application layer)
- Focus beats flexibility (TigerBeetle approach)

**Future Consideration:**
- H3 can be added in v2+ if users demand it
- Would require pluggable index architecture (significant complexity)

---

## Performance & Limits

### Q12: Performance SLAs
**Decision:** Aggressive targets matching TigerBeetle-class performance

**Write Performance:**
- **1,000,000 events/sec per node** (10x original target, with large batches 10k+)
- **5,000,000 events/sec cluster** (5-node cluster)
- **p99 < 5ms latency** (includes quorum wait across AZs)

**Read Performance:**
- **UUID lookup:** p99 < 500μs (RAM index + NVMe read)
- **Radius query (1M records):** p99 < 50ms
- **Polygon query:** p99 < 100ms

**Replication:**
- **View change failover:** < 3 seconds (with all TigerBeetle optimizations)
- **Replication lag:** < 10ms (same region)

**Required TigerBeetle Optimizations for <3s Failover:**
1. Aggressive heartbeat intervals (ping every 200-500ms)
2. Fast failure detection (1-2 missed pings)
3. CTRL protocol (skip full log comparison when replicas agree)
4. Pre-prepared replicas (backups maintain full state)
5. Fast quorum determination (proceed as soon as quorum agrees)
6. Primary abdication under backpressure
7. Message prioritization (view change bypasses normal queue)
8. Byzantine clock synchronization (Marzullo's algorithm)

**Hardware Assumptions:**
- CPU: 16+ cores with AES-NI
- RAM: 64-128GB
- Storage: NVMe SSD (>3GB/s sequential, <100μs latency)
- Network: 10Gbps between replicas (same region)

**Implementation:** See `specs/query-engine/spec.md` (Performance SLAs section)

---

### Q13: Entity and Capacity Limits
**Decision:** Approved limits

**Storage Limits:**
- **Max entities per node:** 1 billion (limited by ~48GB RAM index)
- **Max data file size:** 16TB (u64 offsets)
- **Max total events:** ~137 billion events per node
- **Cluster capacity:** `node_count × 1_billion` entities

**Throughput Limits:**
- **Max events/sec per node:** 1M (with batching)
- **Max events/sec per cluster:** 5M sustained (5-node cluster)
- **Max batch size:** 10,000 events per request
- **Max concurrent connections:** 10,000 per node

**Query Limits:**
- **Max result set:** 100,000 records (require pagination beyond)
- **Max polygon vertices:** 10,000
- **Max radius:** 1,000 km (prevent full-scan abuse)
- **Max message size:** 10MB

**Cluster Limits:**
- **Max cluster size:** 6 active replicas

**Implementation:** See `specs/hybrid-memory/spec.md` (Entity and Capacity Limits section)

---

## Error Handling

### Q14: Error Code System
**Decision:** TigerBeetle taxonomy + geospatial extensions (Option A)

**Rationale:**
- Proven error set (TigerBeetle has thought through edge cases)
- Less design work, consistent philosophy
- Extend with spatial-specific errors

**Error Categories:**

**General Errors (from TigerBeetle):**
- `ok = 0` - Success
- `too_much_data = 1` - Batch exceeds limits
- `invalid_operation = 2` - Malformed request
- `invalid_data_size = 3` - Size mismatch
- `checksum_mismatch = 4` - Verification failed
- `session_expired = 5` - Client session evicted
- `timeout = 6` - Operation timed out
- `not_primary = 7` - Redirect to primary

**Geospatial Errors (100+ range):**
- `invalid_coordinates = 100` - Lat/lon out of range
- `polygon_too_complex = 101` - Too many vertices
- `query_result_too_large = 102` - Result exceeds limit
- `invalid_s2_cell = 103` - Malformed S2 cell ID
- `radius_too_large = 104` - Radius exceeds maximum
- `entity_not_found = 105` - UUID not in index
- `index_capacity_exceeded = 106` - Index full

**Cluster Errors (200+ range):**
- `cluster_unavailable = 200` - No quorum
- `view_change_in_progress = 201` - Cannot serve during election
- `replica_lagging = 202` - Stale read rejected

**Implementation:** See `specs/client-protocol/spec.md` (Error Code Taxonomy section)

---

## Hardware Requirements

### Minimum Hardware (Development / Small-Scale)
- **CPU:** 8 cores, x86-64 with AES-NI
- **RAM:** 32GB (supports ~500M entities)
- **Disk:** 500GB NVMe SSD (>2GB/s, <200μs)
- **Network:** 1Gbps

### Recommended Hardware (1B Entities)
- **CPU:** 16+ cores, x86-64 with AES-NI (AVX2 preferred)
- **RAM:** 64-128GB (48GB index + 16-80GB cache)
- **Disk:** 1TB+ NVMe SSD (>3GB/s, <100μs)
- **Network:** 10Gbps between replicas

### High-Performance Hardware (1M+ events/sec)
- **CPU:** 32+ cores, latest x86-64 (Sapphire Rapids / Zen 4)
- **RAM:** 128-256GB (ECC recommended)
- **Disk:** 2TB+ NVMe Gen4/Gen5 (>5GB/s, Optane or high-endurance)
- **Network:** 25-100Gbps (cross-region replication)

**Implementation:** See `specs/hybrid-memory/spec.md` (Hardware Requirements section)

---

## Deferred Features (Post-MVP)

The following features are explicitly **not** in v1:

1. **Real-time subscriptions** - Clients must poll (defer to v2)
2. **H3 spatial index** - S2 only for v1
3. **Dynamic cluster reconfiguration** - Static membership only
4. **Namespace-based authorization** - All-or-nothing only
5. **Distributed tracing** - Reserved for future (OpenTelemetry)
6. **Hot-warm-cold tiering** - Single-tier storage for v1
7. **Index sharding** - Single index per node
8. **Secondary indexes** - Primary UUID index only

These can be added in future versions based on user demand and production learnings.

---

## Implementation Priority

Based on these decisions, the implementation order is (from `tasks.md`):

1. Core Types (GeoEvent, BlockHeader, constants)
2. Memory Management (StaticAllocator, MessagePool)
3. Hybrid Memory (Index-on-RAM, checkpointing)
4. Checksums & Integrity (Aegis-128L)
5. I/O Subsystem (io_uring, message bus)
6. Storage Engine (Data file zones, superblock, WAL)
7. LSM Tree (Tables, compaction, manifest)
8. S2 Integration (Pure Zig implementation)
9. VSR Protocol (Replica, primary, view changes)
10. Query Engine (Three-phase execution, spatial queries)
11. Client Protocol (Binary protocol, SDK scaffolding)
12. Security (mTLS integration)
13. Observability (Prometheus, logging)
14. Testing & Simulation (VOPR simulator, fault injection)
15. CLI Integration (format, start, status commands)
16. Validation & Benchmarks (performance verification)

---

## Additional Decisions (From Deep Review)

### Q15: Backup & Restore to Object Storage
**Decision:** Include S3/object storage backup in v1 (Option A)

**Rationale:**
- Conversation explicitly discussed "Tier 1 DR: S3 Offloading"
- Upload closed blocks to S3 automatically
- Point-in-time restore capability
- RPO < 1 minute, RTO ~20 minutes for 1TB

**Implementation:** See `specs/backup-restore/spec.md`

---

### Q16: Data Retention & TTL Policy
**Decision:** Per-entry TTL with lazy cleanup + explicit cleanup API

**Details:**
- `ttl_seconds: u32` field in GeoEvent (0 = never expires)
- Lazy expiration check during lookup (remove from index)
- Cleanup on upsert (expired old entry = new insert)
- Explicit `cleanup_expired()` operation for batch cleanup
- Compaction discards expired events (don't copy forward)
- Even latest values can expire (entity disappears)

**Impact:**
- IndexEntry grows from 32 to 40 bytes
- RAM requirement increases from 48GB to 64GB (1B entities)
- GeoEvent struct updated (uses 4 bytes of reserved space)

**Implementation:** See `specs/ttl-retention/spec.md`

---

### Q17: Client Retry & Backoff Policy
**Decision:** Built-in automatic retry in all SDKs (Option A)

**Rationale:**
- TigerBeetle clients handle retries automatically
- Exponential backoff: 100ms, 200ms, 400ms, 800ms, 1600ms
- Max 5 retries (6 attempts total)
- Retry only transient errors (timeout, view_change, not_primary)
- Preserve idempotency (same request_id)
- Automatic primary discovery after view change

**Implementation:** See `specs/client-retry/spec.md`

---

### Q18-21: Remaining Questions
**Decision:** Follow TigerBeetle's approach

- **Multi-region:** Single-region clusters only (cross-region = separate clusters)
- **Operational runbooks:** External documentation (not in specs)
- **Alert thresholds:** Configured by operators in Prometheus/Grafana
- **Capacity planning:** Documentation with formulas (not enforced)

---

## Document Status

**Created:** 2025-12-31
**Last Updated:** 2025-12-31 (after deep review)
**Status:** Final - All questions answered, all issues resolved
**Total Decisions:** 21 architectural decisions
**Next Action:** Begin implementation of Core Types (tasks 1.x)

All architectural decisions are now documented and ready for implementation.
