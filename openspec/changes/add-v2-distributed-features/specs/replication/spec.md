# Replication v2 Spec Deltas

## ADDED Requirements

### Requirement: Async Log Shipping

The system SHALL support asynchronous replication of committed operations from a primary region to one or more follower regions.

#### Scenario: Primary ships committed operations

- **WHEN** an operation commits in the primary region
- **THEN** the committed WAL entry SHALL be queued for async shipping
- **AND** the entry SHALL be shipped to all configured follower regions
- **AND** shipping SHALL occur within `async_ship_interval` (default: 100ms)
- **AND** shipping SHALL NOT block primary region commits

#### Scenario: Follower applies shipped operations

- **WHEN** a follower region receives shipped WAL entries
- **THEN** it SHALL apply entries in commit order
- **AND** it SHALL update its local index and LSM
- **AND** it SHALL track `follower_commit_op` (highest applied op)
- **AND** it SHALL expose replication lag via metrics

#### Scenario: Shipping transport options

- **WHEN** configuring async log shipping
- **THEN** the system SHALL support:
  - **Direct TCP**: Low-latency shipping over dedicated connection
  - **S3 Relay**: Ship via S3 bucket for cross-cloud scenarios
- **AND** transport SHALL be configurable per follower region
- **AND** shipping SHALL use authenticated, encrypted channels

#### Scenario: Shipping failure handling

- **WHEN** shipping to a follower fails
- **THEN** the system SHALL:
  - Retry with exponential backoff (100ms, 200ms, 400ms... max 30s)
  - Queue unshipped entries in memory (up to `ship_buffer_max` entries)
  - Spill to disk if memory buffer exhausted
  - Alert via `archerdb_replication_ship_failures_total` metric
- **AND** shipping failures SHALL NOT impact primary region operation

### Requirement: Read-Only Follower Regions

The system SHALL support read-only follower regions that serve queries from replicated data.

#### Scenario: Follower serves read queries

- **WHEN** a client connects to a follower region
- **THEN** the follower SHALL serve read queries (query_uuid, query_radius, query_polygon, query_latest)
- **AND** the follower SHALL reject write operations with error `follower_read_only` (code 213)
- **AND** responses SHALL include `read_staleness_ns` header field

#### Scenario: Follower read consistency

- **WHEN** a client queries a follower
- **THEN** the response SHALL reflect data as of `follower_commit_op`
- **AND** the client MAY specify `min_commit_op` to ensure freshness
- **AND** if `min_commit_op > follower_commit_op`, return error `stale_follower` (code 214) with retry hint

#### Scenario: Follower region configuration

- **WHEN** deploying a follower region
- **THEN** the operator SHALL configure:
  ```
  --role=follower
  --primary-region=<endpoint>
  --region-id=<unique-id>
  ```
- **AND** the follower SHALL connect to primary for initial state sync
- **AND** the follower SHALL maintain its own VSR cluster for read availability

### Requirement: Geo-Sharding

The system SHALL support partitioning entities across geographic regions for data locality.

#### Scenario: Entity-to-region mapping

- **WHEN** geo-sharding is enabled
- **THEN** entities SHALL be assigned to regions based on `geo_shard_policy`:
  - **by_entity_location**: Route to nearest region based on entity lat/lon
  - **by_entity_id_prefix**: Route based on entity_id prefix mapping
  - **explicit**: Application specifies target region per entity
- **AND** entity-to-region mapping SHALL be stored in metadata

#### Scenario: Geo-shard routing

- **WHEN** a client submits a write with geo-sharding enabled
- **THEN** the receiving node SHALL:
  - Determine target region from geo_shard_policy
  - Forward to target region if different from current
  - Return error if target region unavailable
- **AND** cross-region forwarding SHALL be transparent to client

#### Scenario: Cross-region query aggregation

- **WHEN** a spatial query spans multiple geo-shards
- **THEN** the system SHALL:
  - Scatter query to all relevant regions
  - Gather results with deduplication
  - Merge results ordered by distance/timestamp
- **AND** cross-region queries SHALL have higher latency (documented SLA)

### Requirement: Active-Active Replication (v2.2+)

The system SHALL support active-active replication where multiple regions accept writes with conflict resolution.

#### Scenario: Concurrent writes to different regions

- **WHEN** the same entity is written in multiple regions concurrently
- **THEN** the system SHALL:
  - Accept writes in each region independently
  - Detect conflict via vector clock comparison
  - Resolve conflict using configured policy (default: last-writer-wins)
  - Converge to consistent state across all regions

#### Scenario: Conflict resolution policies

- **WHEN** a write conflict is detected
- **THEN** the system SHALL resolve using:
  - **last_writer_wins**: Highest timestamp wins (default)
  - **primary_wins**: Primary region write takes precedence
  - **custom_hook**: Application-provided resolution function
- **AND** losing writes SHALL be logged to conflict audit log

#### Scenario: Vector clock tracking

- **WHEN** tracking causality for active-active
- **THEN** each entity SHALL maintain a vector clock:
  - `{region_id: logical_timestamp}` per region
  - Updated on every write
  - Propagated with async replication
- **AND** vector clock size SHALL be bounded by region count

#### Scenario: Conflict metrics

- **WHEN** conflicts occur
- **THEN** the system SHALL emit:
  - `archerdb_replication_conflicts_total{resolution="last_writer_wins|primary_wins|custom"}`
  - `archerdb_replication_conflict_rate` (per second gauge)
- **AND** high conflict rates SHALL trigger alerts

### Requirement: Multi-Region Observability

The system SHALL expose metrics for monitoring cross-region replication health.

#### Scenario: Replication lag metrics

- **WHEN** exposing replication metrics
- **THEN** the system SHALL provide:
  ```
  # Primary region metrics
  archerdb_replication_ship_queue_depth{follower="region-2"} 150
  archerdb_replication_ship_bytes_total{follower="region-2"} 1073741824
  archerdb_replication_ship_latency_seconds{follower="region-2",quantile="0.99"} 0.15

  # Follower region metrics
  archerdb_replication_lag_ops{primary="region-1"} 500
  archerdb_replication_lag_seconds{primary="region-1"} 0.5
  archerdb_replication_apply_rate{primary="region-1"} 10000
  ```

#### Scenario: Region health status

- **WHEN** monitoring region health
- **THEN** the system SHALL expose:
  ```
  archerdb_region_status{region="region-1",role="primary"} 1
  archerdb_region_status{region="region-2",role="follower"} 1
  archerdb_region_available{region="region-2"} 1
  ```
- **AND** `/health/region` endpoint SHALL return region-specific status

## ADDED Error Codes

### Requirement: Multi-Region Error Codes

The system SHALL define error codes for multi-region operations.

#### Scenario: New error codes

- **WHEN** multi-region errors occur
- **THEN** the following error codes SHALL be used:
  | Code | Name | Message | Retry |
  |------|------|---------|-------|
  | 213 | follower_read_only | Follower region cannot accept writes | No |
  | 214 | stale_follower | Follower has not caught up to requested op | Yes |
  | 215 | region_unavailable | Target region is not reachable | Yes |
  | 216 | cross_region_timeout | Cross-region operation timed out | Yes |
  | 217 | conflict_detected | Write conflict detected (active-active) | No |
  | 218 | geo_shard_mismatch | Entity geo-shard does not match target region | No |

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Async Log Shipping | IMPLEMENTED | `src/replication.zig` |
| Read-Only Follower Regions | IMPLEMENTED | `src/replication.zig` |
| Geo-Sharding | IMPLEMENTED | `src/geo_sharding.zig` |
| Active-Active Replication (v2.2+) | IMPLEMENTED | `src/replication.zig`, `src/vector_clock.zig` |
| Multi-Region Observability | IMPLEMENTED | `src/replication.zig` |
| Multi-Region Error Codes | IMPLEMENTED | `src/replication.zig` |
