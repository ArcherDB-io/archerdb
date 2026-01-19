# Client SDK v2 Spec Deltas

## MODIFIED Requirements

### Requirement: Multi-Region Client Configuration

Client SDKs SHALL support configuration for multi-region deployments with automatic failover.

#### Scenario: Multi-region configuration

- **WHEN** configuring a client for multi-region
- **THEN** the SDK SHALL accept:
  ```python
  config = ClientConfig(
      regions=[
          RegionConfig(
              name="us-west-2",
              addresses=["node1:3001", "node2:3001", "node3:3001"],
              role="primary"
          ),
          RegionConfig(
              name="eu-west-1",
              addresses=["node4:3001", "node5:3001", "node6:3001"],
              role="follower"
          )
      ],
      read_preference="nearest",  # primary, follower, nearest
      write_region="primary"      # primary, nearest_primary
  )
  ```
- **AND** SDK SHALL validate at least one primary region exists

#### Scenario: Read preference routing

- **WHEN** executing a read operation
- **THEN** the SDK SHALL route based on `read_preference`:
  - **primary**: Always read from primary region
  - **follower**: Prefer follower regions (lower latency for reads)
  - **nearest**: Route to lowest latency region
- **AND** SDK SHALL track latency per region for routing decisions

#### Scenario: Follower read staleness

- **WHEN** reading from a follower region
- **THEN** the SDK SHALL:
  - Include `read_staleness_ns` in response metadata
  - Support `min_commit_op` parameter for freshness requirements
  - Automatically retry on primary if follower too stale
- **AND** staleness SHALL be exposed to application

### Requirement: Shard-Aware Client Routing

Client SDKs SHALL automatically route operations to the correct shard.

#### Scenario: Automatic shard routing

- **WHEN** a client sends a write operation
- **THEN** the SDK SHALL:
  - Compute target shard: `shard = hash(entity_id) % shard_count`
  - Route request directly to shard leader
  - Cache shard-to-node mapping
  - Refresh mapping on routing errors
- **AND** routing SHALL be transparent to application code

#### Scenario: Topology discovery

- **WHEN** a client connects to a sharded cluster
- **THEN** the SDK SHALL:
  - Request topology from any seed node
  - Cache `{shard_id: [node_addresses]}`
  - Subscribe to topology change notifications
  - Refresh topology every `topology_refresh_interval` (default: 30s)
- **AND** stale topology SHALL trigger immediate refresh

#### Scenario: Scatter-gather queries

- **WHEN** executing a spatial query (radius, polygon)
- **THEN** the SDK SHALL:
  - Send query to all shards in parallel
  - Use configurable `query_timeout` per shard
  - Merge results with deduplication
  - Return partial results if some shards fail (with warning)
- **AND** scatter-gather SHALL be automatic for spatial queries

### Requirement: Connection Pool Management

Client SDKs SHALL maintain efficient connection pools for multi-region, multi-shard clusters.

#### Scenario: Per-shard connection pools

- **WHEN** connecting to a sharded cluster
- **THEN** the SDK SHALL:
  - Maintain separate connection pool per shard
  - Size pools based on expected load (`connections_per_shard`, default: 4)
  - Health-check connections periodically
  - Evict unhealthy connections
- **AND** total connections SHALL be bounded by `max_connections`

#### Scenario: Cross-region connection handling

- **WHEN** connecting to multiple regions
- **THEN** the SDK SHALL:
  - Prefer connections to nearest region
  - Maintain warm connections to other regions
  - Track latency per region
  - Failover to other regions on primary failure
- **AND** region failover SHALL be automatic

## ADDED Requirements

### Requirement: Encryption-Aware Client

Client SDKs SHALL support clusters with encryption at rest without application changes.

#### Scenario: Transparent encryption

- **WHEN** connecting to an encrypted cluster
- **THEN** the SDK SHALL:
  - Detect encryption from server metadata
  - Continue operating normally (encryption is server-side)
  - Log connection to encrypted cluster (info level)
- **AND** no client-side configuration SHALL be required

### Requirement: Tiering-Aware Client

Client SDKs SHALL handle responses from tiered storage appropriately.

#### Scenario: Cold tier latency handling

- **WHEN** a query result includes cold tier entities
- **THEN** the SDK SHALL:
  - Extend query timeout automatically for cold tier
  - Include `tier` metadata in response
  - Expose `cold_tier_fetch_count` in response metadata
- **AND** application MAY filter by tier if desired

#### Scenario: Tier hints

- **WHEN** application wants to influence tiering
- **THEN** the SDK SHALL support:
  ```python
  # Prefetch entity to warm tier before query
  client.prefetch_to_warm([entity_id1, entity_id2])

  # Query with tier preference
  result = client.query_radius(lat, lon, radius, tier_preference="hot_only")
  ```
- **AND** tier hints SHALL be best-effort (not guaranteed)

### Requirement: TTL Extension Client Support

Client SDKs SHALL support TTL extension controls.

#### Scenario: TTL extension bypass

- **WHEN** reading without TTL extension
- **THEN** the SDK SHALL support:
  ```python
  # Read without extending TTL
  result = client.get_by_uuid(entity_id, no_extend=True)
  ```
- **AND** bypass SHALL be useful for analytics/monitoring

#### Scenario: Manual TTL modification

- **WHEN** application needs to modify entity TTL
- **THEN** the SDK SHALL support:
  ```python
  # Extend TTL
  client.extend_ttl(entity_id, extend_by_seconds=86400)

  # Set absolute TTL
  client.set_ttl(entity_id, ttl_seconds=604800)

  # Clear TTL (never expire)
  client.clear_ttl(entity_id)
  ```
- **AND** TTL operations SHALL require appropriate permissions

### Requirement: v2 SDK Metrics

Client SDKs SHALL expose additional metrics for v2 features.

#### Scenario: Multi-region metrics

- **WHEN** exposing SDK metrics
- **THEN** the SDK SHALL provide:
  ```
  archerdb_sdk_requests_total{region="us-west-2",operation="query_uuid"} 1000000
  archerdb_sdk_latency_seconds{region="us-west-2",quantile="0.99"} 0.005
  archerdb_sdk_follower_reads_total{region="eu-west-1"} 500000
  archerdb_sdk_read_staleness_seconds{region="eu-west-1",quantile="0.99"} 0.5
  ```

#### Scenario: Sharding metrics

- **WHEN** exposing sharding metrics
- **THEN** the SDK SHALL provide:
  ```
  archerdb_sdk_shard_requests_total{shard="0"} 250000
  archerdb_sdk_scatter_gather_shards{operation="query_radius"} 4
  archerdb_sdk_topology_refreshes_total 100
  archerdb_sdk_routing_errors_total{reason="stale_topology"} 5
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Multi-Region Client Configuration | IMPLEMENTED | `src/replication.zig`, `src/geo_sharding.zig` |
| Shard-Aware Client Routing | IMPLEMENTED | `src/geo_sharding.zig` |
| Connection Pool Management | IMPLEMENTED | `src/replication.zig` |
| Encryption-Aware Client | IMPLEMENTED | `src/encryption.zig` |
| Tiering-Aware Client | IMPLEMENTED | `src/replication.zig` |
| TTL Extension Client Support | IMPLEMENTED | All client SDKs |
| v2 SDK Metrics | IMPLEMENTED | `src/replication.zig`, `src/geo_sharding.zig` |
