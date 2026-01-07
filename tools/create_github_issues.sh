#!/bin/bash
# Script to create all ArcherDB GitHub issues from tasks.md
# Run with: bash tools/create_github_issues.sh

REPO="ArcherDB-io/archerdb"

echo "Creating F2 Phase Issues..."

# F2.1: RAM Index Implementation
gh issue create --repo $REPO \
  --title "F2.1: RAM Index Implementation" \
  --label "phase:F2" \
  --milestone "F2: RAM Index Integration" \
  --body "## Objective
Add O(1) entity lookup index (Aerospike pattern).

## Tasks
- [ ] F2.1.1 Create \`src/ram_index.zig\` (NEW FILE)
- [ ] F2.1.2 Define 64-byte \`IndexEntry\` extern struct (cache-line aligned)
- [ ] F2.1.3 Implement index capacity configuration mechanism
- [ ] F2.1.4 Implement Robin Hood hashing with linear probing
- [ ] F2.1.5 Implement resize operation (if dynamic sizing chosen)
- [ ] F2.1.6 Add index metrics (load factor, probe distance, collisions)
- [ ] F2.1.7 Write comprehensive unit tests

## IndexEntry Struct
\`\`\`zig
const IndexEntry = extern struct {
    entity_id: u128,      // 16 bytes
    lsm_pointer: u64,     // 8 bytes - points to LSM storage
    s2_cell_id: u64,      // 8 bytes - for spatial queries
    timestamp: u64,       // 8 bytes - last update time
    version: u64,         // 8 bytes - for optimistic locking
    flags: u32,           // 4 bytes - status flags
    _padding: [12]u8,     // 12 bytes - align to 64 bytes
};
\`\`\`

## Reference
See \`tasks.md\` F2.1.x and \`specs/hybrid-memory/spec.md\`."

# F2.2: Index-LSM Integration
gh issue create --repo $REPO \
  --title "F2.2: Index-LSM Integration" \
  --label "phase:F2" --label "critical" \
  --milestone "F2: RAM Index Integration" \
  --body "## Objective
Integrate RAM index with ArcherDB's LSM storage.

## Tasks
- [ ] F2.2.1 Modify state machine to update index on upsert
- [ ] F2.2.2 Implement index rebuild from LSM on startup
- [ ] F2.2.3 Integrate index with checkpoint sequence
- [ ] F2.2.4 Handle index-LSM consistency during recovery
- [ ] F2.2.5 Add index persistence for fast restart (optional)
- [ ] F2.2.6 Performance benchmark: UUID lookup <500μs target
- [ ] F2.2.7 Integration tests for index-LSM consistency
- [ ] F2.2.8 Implement index compaction with LSM compaction
- [ ] F2.2.9 Validate recovery window meets SLA (depends on F0.2.7)

## Reference
See \`tasks.md\` F2.2.x."

# F2.3: Recovery Validation
gh issue create --repo $REPO \
  --title "F2.3: Recovery SLA Validation (Decision Gate)" \
  --label "phase:F2" --label "decision-gate" --label "validation" --label "critical" \
  --milestone "Gate 4: Recovery SLA (Week 12)" \
  --body "## Objective
Validate all recovery paths meet their SLAs.

## Recovery Scenarios

### Case A: WAL Replay (Most Common)
- **SLA**: < 1 second
- **Data size dependency**: None (only depends on ops since last checkpoint)
- [ ] F2.3.1 Setup: Crash at exactly 8192 ops after index checkpoint
- [ ] F2.3.2 Measure: WAL replay time
- [ ] F2.3.3 Verify: Index reconstructed correctly

### Case B: LSM Replay (Rare)
- **SLA**: < 30 seconds
- **Data size dependency**: Weak (depends on table coverage)
- [ ] F2.3.4 Setup: Crash after 50,000 ops (beyond WAL retention)
- [ ] F2.3.5 Measure: LSM table scan + index rebuild time
- [ ] F2.3.6 Verify: All entries recovered correctly

### Case C: Full Rebuild (Very Rare)
- **SLA**: < 2 hours for 16TB / < 2 minutes for 128GB
- **Data size dependency**: Strong
- [ ] F2.3.7 Setup: Start fresh replica with empty index
- [ ] F2.3.8 Measure: Time to rebuild from 1B entities (128GB data)
- [ ] F2.3.9 Verify: Index matches LSM state exactly

## Decision Gate
- **GO**: All three recovery paths meet SLAs
- **NO-GO**: Extend F2 +2 weeks for optimization

## Reference
See \`tasks.md\` F2.3.x and \`specs/hybrid-memory/spec.md\`."

# F2.4: TTL Implementation
gh issue create --repo $REPO \
  --title "F2.4: TTL Implementation & Index Degradation" \
  --label "phase:F2" \
  --milestone "F2: RAM Index Integration" \
  --body "## Objective
Implement TTL expiration and index degradation detection.

## Tasks
- [ ] F2.4.1 Create \`src/ttl.zig\` (NEW FILE)
- [ ] F2.4.2 Implement lazy TTL expiration check during lookups
- [ ] F2.4.3 Implement background TTL scanner with configurable batch size
- [ ] F2.4.4 Integrate TTL checks with compaction (skip expired during compaction)
- [ ] F2.4.5 Add TTL metrics: expired_count, expiration_rate, avg_ttl_remaining
- [ ] F2.4.6 Implement TTL tombstone generation for expired entries
- [ ] F2.4.7 Write TTL tests (lazy expiration, background scan, compaction integration)
- [ ] F2.4.8 **CRITICAL**: Implement cleanup_expired operation (0x30) handler

## Index Degradation Detection
- [ ] F2.4.9 Create degradation_detector.zig
- [ ] F2.4.10 Monitor probe distance distribution
- [ ] F2.4.11 Alert on >15 average probe distance
- [ ] F2.4.12 Implement automatic resize trigger when load factor >85%

## Reference
See \`tasks.md\` F2.4.x and \`specs/ttl-retention/spec.md\`."

echo "Creating F3 Phase Issues..."

# F3.1: S2 Library Integration
gh issue create --repo $REPO \
  --title "F3.1: S2 Library Integration" \
  --label "phase:F3" --label "critical" \
  --milestone "F3: S2 Spatial Index" \
  --body "## Objective
Integrate S2 geometry library based on F0.4.6 decision.

## Tasks (Depends on F0.4.6 decision)

### If Option A (Pure Zig):
- [ ] F3.1.1a Create \`src/s2/\` directory structure
- [ ] F3.1.2a Implement lat_lon_to_cell_id() in pure Zig
- [ ] F3.1.3a Implement cell_id_to_lat_lon() inverse
- [ ] F3.1.4a Implement cell covering algorithms

### If Option B (C++ FFI):
- [ ] F3.1.1b Set up Google S2 C++ library build
- [ ] F3.1.2b Create Zig C FFI bindings
- [ ] F3.1.3b Implement hash verification layer
- [ ] F3.1.4b Benchmark FFI overhead

### Common Tasks
- [ ] F3.1.5 Validate against golden vectors from F0.4.7
- [ ] F3.1.6 Performance benchmark: cell_id computation <1μs
- [ ] F3.1.7 Cross-platform validation (x86/ARM/macOS)

## Reference
See \`tasks.md\` F3.1.x and \`design.md\` Decision 3a."

# F3.2: Golden Vector Testing
gh issue create --repo $REPO \
  --title "F3.2: S2 Golden Vector Testing" \
  --label "phase:F3" --label "validation" --label "critical" \
  --milestone "F3: S2 Spatial Index" \
  --body "## Objective
Validate S2 implementation with golden vectors across all platforms.

## Tasks
- [ ] F3.2.1 Generate 10,000+ golden vectors from Google S2 reference (C++)
- [ ] F3.2.2 Store vectors in \`testdata/s2/golden_vectors_v1.tsv\`
- [ ] F3.2.3 Create CI job to validate on Linux x86-64
- [ ] F3.2.4 Create CI job to validate on Linux ARM64
- [ ] F3.2.5 Create CI job to validate on macOS x86-64
- [ ] F3.2.6 Create CI job to validate on macOS ARM64
- [ ] F3.2.7 Document any platform-specific variations

## Acceptance Criteria
- 100% match on all golden vectors across all 4 platforms
- ANY divergence = BLOCKER (investigate and fix)

## Reference
See \`tasks.md\` F3.2.x."

# F3.3: Radius Query Implementation
gh issue create --repo $REPO \
  --title "F3.3: Radius Query Implementation" \
  --label "phase:F3" \
  --milestone "F3: S2 Spatial Index" \
  --body "## Objective
Implement radius-based spatial queries using S2 covering.

## Tasks
- [ ] F3.3.1 Implement radius-to-S2-covering algorithm
- [ ] F3.3.2 Implement \`query_radius\` operation (0x11)
- [ ] F3.3.3 Optimize covering for small radii (<100m)
- [ ] F3.3.4 Optimize covering for large radii (>10km)
- [ ] F3.3.5 Add result count limiting and pagination
- [ ] F3.3.6 Performance benchmark: <50ms p99 for 100m radius, 10K entities

## Query Flow
1. Convert (lat, lon, radius) to S2 covering cells
2. Scan index for matching cell prefixes
3. Filter by exact distance (post-filter)
4. Return sorted by distance

## Reference
See \`tasks.md\` F3.3.x and \`specs/query-engine/spec.md\`."

# F3.4: Polygon Query Implementation
gh issue create --repo $REPO \
  --title "F3.4: Polygon Query Implementation" \
  --label "phase:F3" \
  --milestone "F3: S2 Spatial Index" \
  --body "## Objective
Implement polygon-based spatial queries.

## Tasks
- [ ] F3.4.1 Implement polygon-to-S2-covering algorithm
- [ ] F3.4.2 Implement \`query_polygon\` operation (0x12)
- [ ] F3.4.3 Handle simple polygons (convex)
- [ ] F3.4.4 Handle complex polygons (concave, with holes)
- [ ] F3.4.5 Implement point-in-polygon post-filtering
- [ ] F3.4.6 Add polygon validation (max vertices, self-intersection check)
- [ ] F3.4.7 Performance benchmark: <200ms p99 for city-sized polygon

## Polygon Constraints
- Maximum 256 vertices per polygon
- No self-intersecting polygons
- Holes supported via multi-polygon encoding

## Reference
See \`tasks.md\` F3.4.x and \`specs/query-engine/spec.md\`."

echo "Creating F4 Phase Issues..."

# F4.1: VOPR GeoEvent Adaptation
gh issue create --repo $REPO \
  --title "F4.1: VOPR GeoEvent Adaptation" \
  --label "phase:F4" --label "critical" \
  --milestone "F4: VOPR & Hardening" \
  --body "## Objective
Adapt ArcherDB's VOPR simulator for GeoEvent workloads.

## Tasks
- [ ] F4.1.1 Study existing VOPR workload generators
- [ ] F4.1.2 Create GeoEvent workload generator
- [ ] F4.1.3 Generate realistic lat/lon distributions (city clusters)
- [ ] F4.1.4 Generate realistic TTL distributions
- [ ] F4.1.5 Generate realistic query patterns (radius/polygon mix)
- [ ] F4.1.6 Integrate with VOPR fault injection framework
- [ ] F4.1.7 Add GeoEvent-specific invariant checks

## Workload Parameters
- Entity count: 1M-100M
- Geographic distribution: Clustered (cities) + uniform (rural)
- TTL distribution: 10% never, 50% 24h, 30% 7d, 10% 30d
- Query mix: 60% radius, 30% UUID, 10% polygon

## Reference
See \`tasks.md\` F4.1.x."

# F4.2: Cluster VOPR Testing
gh issue create --repo $REPO \
  --title "F4.2: Cluster VOPR Testing (10M+ Operations)" \
  --label "phase:F4" --label "validation" --label "critical" \
  --milestone "F4: VOPR & Hardening" \
  --body "## Objective
Run comprehensive VOPR testing on multi-node cluster.

## Test Configurations
- [ ] F4.2.1 3-node cluster, 10M operations
- [ ] F4.2.2 5-node cluster, 10M operations
- [ ] F4.2.3 3-node cluster with network partitions
- [ ] F4.2.4 5-node cluster with node failures
- [ ] F4.2.5 Mixed failure scenarios (network + disk + node)

## Fault Injection Scenarios
- [ ] F4.2.6 Network partition (minority isolated)
- [ ] F4.2.7 Network partition (majority isolated)
- [ ] F4.2.8 Leader failure during commit
- [ ] F4.2.9 Follower failure during replication
- [ ] F4.2.10 Disk I/O errors (simulated)
- [ ] F4.2.11 Slow disk (latency injection)

## Acceptance Criteria
- All scenarios pass without data loss or divergence
- Minimum 10M operations per scenario
- All VOPR seeds recorded for reproducibility

## Reference
See \`tasks.md\` F4.2.x."

# F4.3: Replication Testing
gh issue create --repo $REPO \
  --title "F4.3: VSR Replication Validation" \
  --label "phase:F4" --label "validation" \
  --milestone "F4: VOPR & Hardening" \
  --body "## Objective
Validate VSR replication correctness with GeoEvents.

## Tasks
- [ ] F4.3.1 Test view change during GeoEvent commit
- [ ] F4.3.2 Test state transfer to recovering replica
- [ ] F4.3.3 Test checkpoint synchronization across replicas
- [ ] F4.3.4 Verify index consistency across replicas after view changes
- [ ] F4.3.5 Test split-brain recovery (should not occur with correct quorums)
- [ ] F4.3.6 Validate Flexible Paxos quorum configurations

## Quorum Configurations to Test
| Cluster Size | Write Quorum | Read Quorum | Fault Tolerance |
|-------------|--------------|-------------|-----------------|
| 3 | 2 | 2 | 1 |
| 5 | 3 | 3 | 2 |
| 5 | 4 | 2 | 2 (optimized reads) |

## Reference
See \`tasks.md\` F4.3.x and \`specs/replication/spec.md\`."

# F4.4: Performance Benchmarking
gh issue create --repo $REPO \
  --title "F4.4: Performance Benchmarking & Optimization" \
  --label "phase:F4" --label "validation" \
  --milestone "F4: VOPR & Hardening" \
  --body "## Objective
Validate all performance targets and optimize as needed.

## Performance Targets
| Operation | Target | Acceptance |
|-----------|--------|------------|
| UUID lookup | <500μs p99 | MUST |
| Radius query (100m, 10K entities) | <50ms p99 | MUST |
| Polygon query (city, 100K entities) | <200ms p99 | SHOULD |
| Upsert throughput | 1M ops/sec | MUST |
| Recovery (WAL) | <1 second | MUST |
| Recovery (LSM) | <30 seconds | MUST |

## Tasks
- [ ] F4.4.1 Create benchmark suite for all operations
- [ ] F4.4.2 Benchmark single-node performance
- [ ] F4.4.3 Benchmark 3-node cluster performance
- [ ] F4.4.4 Benchmark 5-node cluster performance
- [ ] F4.4.5 Profile and optimize hot paths
- [ ] F4.4.6 Document performance characteristics
- [ ] F4.4.7 Create performance regression CI job

## Reference
See \`tasks.md\` F4.4.x and \`specs/performance-validation/spec.md\`."

echo "Creating F5 Phase Issues..."

# F5.1: Client Protocol Finalization
gh issue create --repo $REPO \
  --title "F5.1: Client Protocol Finalization" \
  --label "phase:F5" \
  --milestone "F5: SDK & Production Readiness" \
  --body "## Objective
Finalize and document the client wire protocol.

## Tasks
- [ ] F5.1.1 Finalize message header format (256 bytes)
- [ ] F5.1.2 Finalize all operation request/response formats
- [ ] F5.1.3 Document protocol version negotiation
- [ ] F5.1.4 Document error response format
- [ ] F5.1.5 Create protocol specification document
- [ ] F5.1.6 Create wire format test vectors
- [ ] F5.1.7 Implement protocol version compatibility checks

## Reference
See \`tasks.md\` F5.1.x and \`specs/client-protocol/spec.md\`."

# F5.2: Zig Client SDK
gh issue create --repo $REPO \
  --title "F5.2: Zig Client SDK" \
  --label "phase:F5" \
  --milestone "F5: SDK & Production Readiness" \
  --body "## Objective
Create the reference Zig client SDK.

## Tasks
- [ ] F5.2.1 Create \`clients/zig/\` directory structure
- [ ] F5.2.2 Implement connection pool
- [ ] F5.2.3 Implement request/response serialization
- [ ] F5.2.4 Implement retry logic with exponential backoff
- [ ] F5.2.5 Implement batch operations
- [ ] F5.2.6 Add client-side validation
- [ ] F5.2.7 Create comprehensive examples
- [ ] F5.2.8 Write SDK documentation

## Reference
See \`tasks.md\` F5.2.x."

# F5.3: Multi-Language SDKs
gh issue create --repo $REPO \
  --title "F5.3: Multi-Language SDK Skeletons" \
  --label "phase:F5" \
  --milestone "F5: SDK & Production Readiness" \
  --body "## Objective
Create SDK skeletons for major languages.

## Tasks
- [ ] F5.3.1 Java SDK skeleton
- [ ] F5.3.2 Go SDK skeleton
- [ ] F5.3.3 Python SDK skeleton
- [ ] F5.3.4 Node.js SDK skeleton
- [ ] F5.3.5 Rust SDK skeleton (optional)

## SDK Requirements (All Languages)
- Connection pooling
- Automatic reconnection
- Request batching
- Error handling with typed exceptions
- Async/await support where applicable
- Comprehensive documentation

## Reference
See \`tasks.md\` F5.3.x."

# F5.4: Observability & Monitoring
gh issue create --repo $REPO \
  --title "F5.4: Observability & Monitoring" \
  --label "phase:F5" \
  --milestone "F5: SDK & Production Readiness" \
  --body "## Objective
Implement comprehensive observability for production deployment.

## Tasks
- [ ] F5.4.1 Implement Prometheus metrics endpoint
- [ ] F5.4.2 Add all 73 metrics from METRICS_REFERENCE.md
- [ ] F5.4.3 Create Grafana dashboard templates
- [ ] F5.4.4 Implement structured logging
- [ ] F5.4.5 Add distributed tracing support (OpenTelemetry)
- [ ] F5.4.6 Create alerting rules for SLA violations
- [ ] F5.4.7 Document runbook for common issues

## Key Metrics Categories
- Operations: latency histograms, throughput counters
- Storage: LSM levels, compaction stats, disk usage
- Index: load factor, probe distances, hit rates
- Replication: view changes, commit latency, lag
- TTL: expiration rates, cleanup throughput

## Reference
See \`tasks.md\` F5.4.x and \`specs/observability/spec.md\`."

# F5.5: Production Deployment
gh issue create --repo $REPO \
  --title "F5.5: Production Deployment & Documentation" \
  --label "phase:F5" \
  --milestone "F5: SDK & Production Readiness" \
  --body "## Objective
Prepare for production deployment.

## Tasks
- [ ] F5.5.1 Create Docker images
- [ ] F5.5.2 Create Kubernetes manifests
- [ ] F5.5.3 Create Helm chart
- [ ] F5.5.4 Document hardware requirements
- [ ] F5.5.5 Document capacity planning guide
- [ ] F5.5.6 Create backup/restore procedures
- [ ] F5.5.7 Create disaster recovery runbook
- [ ] F5.5.8 Security hardening guide
- [ ] F5.5.9 Performance tuning guide

## Reference
See \`tasks.md\` F5.5.x and \`specs/deployment/spec.md\`."

echo "Adding all new issues to project..."

# Get all issue numbers and add to project
for i in $(gh issue list --repo $REPO --state open --json number --jq '.[].number'); do
  gh project item-add 1 --owner ArcherDB-io --url "https://github.com/ArcherDB-io/archerdb/issues/$i" 2>/dev/null || true
done

echo "Done! Created all phase issues."
