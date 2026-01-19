# Implementation Tasks: v2 Distributed Features

## Phase 1: v2.0 Foundation

### 1. Async Log Shipping (Multi-Region)
- [x] 1.1 Define WAL entry format for shipping (include op, timestamp, checksum)
- [x] 1.2 Implement ship queue with memory + disk spillover
- [x] 1.3 Implement Direct TCP transport for low-latency shipping
- [x] 1.4 Implement S3 Relay transport for cross-cloud scenarios
- [x] 1.5 Add shipping retry logic with exponential backoff
- [x] 1.6 Implement follower WAL apply logic
- [x] 1.7 Add replication lag metrics (ship_queue_depth, lag_ops, lag_seconds)
- [x] 1.8 Write unit tests for shipping queue
- [x] 1.9 Write integration tests for primary-follower replication
- [x] 1.10 Update CLI: `--role=primary|follower`, `--primary-region`

### 2. Read-Only Follower Regions
- [x] 2.1 Add `follower_read_only` error code (213)
- [x] 2.2 Implement write rejection on follower nodes
- [x] 2.3 Add `read_staleness_ns` to response headers
- [x] 2.4 Implement `min_commit_op` freshness parameter
- [x] 2.5 Add `stale_follower` error code (214)
- [x] 2.6 Write follower read path tests
- [x] 2.7 Document follower deployment procedure

### 3. Stop-the-World Resharding
- [x] 3.1 Define shard assignment function: `hash(entity_id) % shard_count`
- [x] 3.2 Implement cluster read-only mode
- [x] 3.3 Implement entity export per source shard
- [x] 3.4 Implement entity import to target shards
- [x] 3.5 Add pre-resharding backup creation
- [x] 3.6 Implement topology metadata update
- [x] 3.7 Add resharding CLI: `archerdb shard reshard --to <count>`
- [x] 3.8 Add resharding status metrics
- [x] 3.9 Write resharding integration tests
- [x] 3.10 Implement resharding rollback on failure

### 4. Shard Management CLI
- [x] 4.1 Implement `archerdb shard list` command
- [x] 4.2 Implement `archerdb shard status <shard_id>` command
- [x] 4.3 Add `--json` output format support
- [x] 4.4 Write CLI tests

### 5. Smart Client Topology Discovery
- [x] 5.1 Define `get_topology` operation (new operation code)
- [x] 5.2 Implement topology response format
- [x] 5.3 Add topology change push notifications
- [x] 5.4 Update Go SDK: topology discovery and caching
- [x] 5.5 Update Go SDK: shard-aware routing
- [x] 5.6 Update Go SDK: scatter-gather for spatial queries
- [x] 5.7 Update Python SDK: same features as Go
- [x] 5.8 Update Node.js SDK: same features as Go
- [x] 5.9 Update Java SDK: same features as Go
- [x] 5.10 Write SDK integration tests for sharded cluster

### 6. Encryption at Rest
- [x] 6.1 Define encrypted file header format (96 bytes)
- [x] 6.2 Implement AES-256-GCM encryption with AES-NI
- [x] 6.3 Implement DEK generation and wrapping
- [x] 6.4 Implement file-based key provider (development)
- [x] 6.5 Implement AWS KMS key provider
- [x] 6.6 Implement HashiCorp Vault key provider
- [x] 6.7 Add encrypted file reader/writer
- [x] 6.8 Add encryption CLI flags
- [x] 6.9 Add `archerdb verify --encryption` command
- [x] 6.10 Write encryption unit tests
- [x] 6.11 Write encryption integration tests
- [x] 6.12 Add encryption metrics

### 7. v2.0 Error Codes
- [x] 7.1 Add multi-region error codes (213-218)
- [x] 7.2 Add sharding error codes (220-224)
- [x] 7.3 Add encryption error codes (410-414)
- [x] 7.4 Update SDK error handling for new codes
- [x] 7.5 Update error documentation

### 8. v2.0 Observability
- [x] 8.1 Add replication shipping metrics
- [x] 8.2 Add follower lag metrics
- [x] 8.3 Add shard distribution metrics
- [x] 8.4 Add encryption operation metrics
- [x] 8.5 Add `/health/region` endpoint
- [x] 8.6 Add `/health/shards` endpoint
- [x] 8.7 Add `/health/encryption` endpoint

## Phase 2: v2.1 Enhancements

### 9. Online Resharding
- [x] 9.1 Implement dual-write mode
- [x] 9.2 Implement background data migration
- [x] 9.3 Add migration rate limiting
- [x] 9.4 Implement cutover procedure (brief pause)
- [x] 9.5 Implement online resharding rollback
- [x] 9.6 Add `--mode=online` to reshard command
- [x] 9.7 Add resharding progress metrics
- [x] 9.8 Write online resharding tests

### 10. Hot-Warm-Cold Data Tiering
- [x] 10.1 Define tier metadata structure
- [x] 10.2 Implement access timestamp tracking
- [x] 10.3 Implement hot→warm demotion logic
- [x] 10.4 Implement warm→cold demotion with S3 upload
- [x] 10.5 Implement cold→warm promotion on access
- [x] 10.6 Implement warm→hot promotion
- [x] 10.7 Add migration rate limiting
- [x] 10.8 Add migration window configuration
- [x] 10.9 Add tiering CLI flags
- [x] 10.10 Add tier distribution metrics
- [x] 10.11 Add migration metrics
- [x] 10.12 Write tiering unit tests
- [x] 10.13 Write tiering integration tests

### 11. TTL Extension on Read
- [x] 11.1 Add extension configuration flags
- [x] 11.2 Implement auto-extension on read
- [x] 11.3 Implement extension cooldown
- [x] 11.4 Implement max TTL cap
- [x] 11.5 Add per-entity-type policies
- [x] 11.6 Add `no_extend` query parameter
- [x] 11.7 Add TTL extension metrics
- [x] 11.8 Update SDKs: `no_extend` parameter
- [x] 11.9 Update SDKs: `extend_ttl()`, `set_ttl()`, `clear_ttl()`
- [x] 11.10 Write TTL extension tests

### 12. Key Rotation
- [x] 12.1 Implement KEK rotation (re-wrap DEKs)
- [x] 12.2 Implement DEK rotation (re-encrypt data)
- [x] 12.3 Add rotation progress tracking
- [x] 12.4 Add rotation CLI command
- [x] 12.5 Write key rotation tests

### 13. v2.1 Error Codes
- [x] 13.1 Add tiering error codes (230-233)
- [x] 13.2 Add TTL extension error codes (240-243)
- [x] 13.3 Update SDK error handling

## Phase 3: v2.2 Advanced Features

### 14. Geo-Sharding (v2.2)
- [x] 14.1 Design geo_shard_policy options
- [x] 14.2 Implement by_entity_location routing
- [x] 14.3 Implement entity-to-region metadata
- [x] 14.4 Implement cross-region query aggregation
- [x] 14.5 Add geo-sharding configuration
- [x] 14.6 Update SDKs for geo-sharding
- [x] 14.7 Write geo-sharding tests

### 15. Active-Active Replication (v2.2)
- [x] 15.1 Design vector clock structure
- [x] 15.2 Implement per-entity vector clock tracking
- [x] 15.3 Implement conflict detection
- [x] 15.4 Implement last-writer-wins resolution
- [x] 15.5 Implement primary-wins resolution
- [x] 15.6 Add custom resolution hook interface
- [x] 15.7 Add conflict audit log
- [x] 15.8 Add conflict metrics
- [x] 15.9 Write active-active tests

## Documentation & Testing

> **Note:** Documentation and testing are ongoing and tracked separately.

### 16. Documentation (Ongoing)
- [x] 16.1 Write multi-region deployment guide
- [x] 16.2 Write sharding operations guide
- [x] 16.3 Write encryption setup guide
- [x] 16.4 Write tiering configuration guide
- [x] 16.5 Write migration guide (v1→v2)
- [x] 16.6 Update SDK documentation for v2 features
- [x] 16.7 Update API reference with new operations

### 17. Integration Testing
- [x] 17.1 Multi-region replication integration tests
- [x] 17.2 Resharding integration tests (offline and online)
- [x] 17.3 Encryption end-to-end tests
- [x] 17.4 Tiering migration tests
- [x] 17.5 TTL extension tests
- [x] 17.6 Cross-feature interaction tests

### 18. Performance Testing (Ongoing)
- [x] 18.1 Benchmark async replication throughput
- [x] 18.2 Benchmark encryption overhead
- [x] 18.3 Benchmark tiering migration impact
- [x] 18.4 Benchmark scatter-gather query latency
- [x] 18.5 Benchmark resharding duration

## Dependencies

- Phase 1 tasks can mostly run in parallel
- Phase 2 depends on Phase 1 completion
- Phase 3 depends on Phase 2 completion
- SDK updates should follow server-side feature completion
- Documentation should be written alongside features

## Verification

Each task should include:
1. Unit tests covering happy path and error cases
2. Integration tests for cross-component behavior
3. Metric verification for observability
4. Documentation updates
