# Index Sharding - Spatial-Aware Sharding

## ADDED Requirements

### Requirement: Sharding Strategy Selection

The system SHALL support multiple sharding strategies configurable at cluster creation.

#### Scenario: Sharding strategy enum

- **WHEN** configuring cluster sharding
- **THEN** the system SHALL support:
  ```zig
  pub const ShardStrategy = enum {
      /// Hash entity_id for uniform distribution
      entity,
      /// Use S2 cell prefix for spatial locality
      spatial,
  };
  ```
- **AND** default SHALL be `entity`

#### Scenario: Strategy configuration at cluster creation

- **WHEN** creating a cluster
- **THEN** the operator MAY specify:
  ```bash
  archerdb cluster create --shard-strategy=spatial
  ```
- **AND** strategy SHALL be immutable after cluster creation

#### Scenario: Strategy in topology metadata

- **WHEN** clients discover topology
- **THEN** the topology response SHALL include:
  ```json
  {
    "shard_strategy": "spatial",
    "num_shards": 16,
    ...
  }
  ```
- **AND** clients SHALL use strategy for routing

### Requirement: Spatial Shard Computation

The system SHALL compute shard assignment from S2 cell ID for spatial sharding.

#### Scenario: Cell-to-shard mapping

- **WHEN** using spatial sharding
- **THEN** shard SHALL be computed as:
  ```zig
  pub fn computeSpatialShard(cell_id: u64, num_shards: u32) u32 {
      // Skip face bits (3), use next log2(num_shards) bits
      const shard_bits = std.math.log2(num_shards);
      const shift = 64 - 3 - shard_bits;
      return @intCast((cell_id >> shift) & (num_shards - 1));
  }
  ```
- **AND** nearby locations SHALL map to same or adjacent shards

#### Scenario: Shard count constraint

- **WHEN** using spatial sharding
- **THEN** num_shards MUST be power of 2
- **AND** num_shards MUST be between 4 and 256
- **AND** larger shard counts provide finer spatial granularity

### Requirement: Spatial Query Routing

The system SHALL route spatial queries to covering shards only.

#### Scenario: Covering shard computation

- **WHEN** routing a spatial query (radius, polygon)
- **THEN** the system SHALL:
  1. Compute S2 covering for query region
  2. Map covering cells to shard set
  3. Query only shards in covering set
- **AND** covering SHALL be deduplicated

#### Scenario: Radius query routing

- **WHEN** executing radius query with spatial sharding
- **THEN** the system SHALL:
  ```zig
  pub fn routeRadiusQuery(center: LatLng, radius_m: f64) []u32 {
      const region = S2Cap.fromCenterRadius(center, radius_m);
      return getCoveringShards(region, num_shards);
  }
  ```
- **AND** typical queries SHALL hit 1-4 shards
- **AND** large queries MAY hit more shards

#### Scenario: Polygon query routing

- **WHEN** executing polygon query with spatial sharding
- **THEN** the system SHALL:
  - Compute S2 polygon from vertices
  - Get covering shards for polygon
  - Query covering shards only
- **AND** complex polygons MAY require more shards

### Requirement: Entity Lookup with Spatial Sharding

The system SHALL support entity lookups via secondary index when using spatial sharding.

#### Scenario: Entity lookup index

- **WHEN** using spatial sharding
- **THEN** the system SHALL maintain:
  ```zig
  pub const EntityLookupEntry = extern struct {
      entity_id: u128,  // Primary key
      cell_id: u64,     // Current S2 cell
      padding: u64,     // Alignment
  };
  ```
- **AND** index SHALL be distributed via entity_id hash

#### Scenario: Entity lookup routing

- **WHEN** performing entity lookup in spatial mode
- **THEN** the system SHALL:
  1. Hash entity_id to find lookup shard
  2. Query lookup index for cell_id
  3. Compute spatial shard from cell_id
  4. Query data shard for entity
- **AND** this requires 2 hops vs 1 hop in entity mode

#### Scenario: Lookup index updates

- **WHEN** entity location changes
- **THEN** the system SHALL:
  - Update lookup index with new cell_id
  - Move data to new shard if cell changed significantly
- **AND** index update SHALL be atomic with data update

### Requirement: Spatial Sharding Metrics

The system SHALL expose metrics for spatial sharding.

#### Scenario: Strategy metric

- **WHEN** exposing cluster metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_shard_strategy Configured sharding strategy (0=entity, 1=spatial)
  # TYPE archerdb_shard_strategy gauge
  archerdb_shard_strategy 1
  ```

#### Scenario: Fan-out reduction metric

- **WHEN** executing spatial queries
- **THEN** the system SHALL track:
  ```
  # HELP archerdb_query_shards_queried Shards queried per query
  # TYPE archerdb_query_shards_queried histogram
  archerdb_query_shards_queried_bucket{type="radius",le="1"} 5000
  archerdb_query_shards_queried_bucket{type="radius",le="4"} 9500
  archerdb_query_shards_queried_bucket{type="radius",le="16"} 10000
  ```

#### Scenario: Shard utilization metric

- **WHEN** using spatial sharding
- **THEN** the system SHALL expose per-shard metrics:
  ```
  archerdb_shard_entity_count{shard="0"} 50000000
  archerdb_shard_entity_count{shard="1"} 75000000
  archerdb_shard_entity_count{shard="2"} 10000000
  ```
- **AND** operators can detect hot spots via imbalance

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Sharding Strategy Selection | IMPLEMENTED | `src/sharding.zig` - entity and spatial strategies |
| Spatial Shard Computation | IMPLEMENTED | `src/sharding.zig` - computeSpatialShard from S2 cell ID |
| Spatial Query Routing | IMPLEMENTED | `src/coordinator.zig` - getCoveringShards for radius/polygon |
| Entity Lookup with Spatial Sharding | IMPLEMENTED | `src/geo_sharding.zig` - EntityLookupIndex |
| Spatial Sharding Metrics | IMPLEMENTED | `src/archerdb/metrics.zig` - shard strategy and fan-out metrics |

## Related Specifications

- See base `index-sharding/spec.md` for entity sharding
- See `query-engine/spec.md` for spatial query types
- See `client-sdk/spec.md` for client routing
