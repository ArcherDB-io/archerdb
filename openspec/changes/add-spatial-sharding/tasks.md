# Implementation Tasks: Spatial-Aware Sharding

## Phase 1: Sharding Strategy

### Task 1.1: Add ShardStrategy enum
- **File**: `src/sharding.zig`
- **Changes**:
  - Define `ShardStrategy` enum (entity, spatial)
  - Add to cluster configuration
  - Document strategy differences
- **Validation**: Enum compiles
- **Estimated effort**: 30 minutes

### Task 1.2: Implement spatial shard computation
- **File**: `src/sharding.zig`
- **Changes**:
  - Add `computeSpatialShard(cell_id, num_shards)` function
  - Use S2 cell prefix for shard key
  - Add validation for power-of-2 shards
- **Validation**: Correct shards for known cells
- **Estimated effort**: 1 hour

### Task 1.3: Implement covering shard computation
- **File**: `src/sharding.zig`
- **Changes**:
  - Add `getCoveringShards(region, num_shards)` function
  - Integrate with S2 covering algorithm
  - Return deduplicated shard list
- **Validation**: Correct shards for test regions
- **Estimated effort**: 2 hours

## Phase 2: Entity Lookup Index

### Task 2.1: Define EntityLookupEntry
- **File**: `src/sharding.zig` or new file
- **Changes**:
  - Add `EntityLookupEntry` struct (entity_id, cell_id)
  - Add comptime size assertions
  - Implement serialization
- **Validation**: Struct is correct size
- **Estimated effort**: 30 minutes

### Task 2.2: Implement lookup index
- **File**: `src/sharding.zig` or new file
- **Changes**:
  - Hash table for entity_id → cell_id
  - Distributed same as entity sharding
  - Update on entity insert/move
- **Validation**: Lookup returns correct cell_id
- **Estimated effort**: 2 hours

### Task 2.3: Integrate lookup with entity queries
- **File**: Query routing code
- **Changes**:
  - If spatial strategy: lookup cell_id first
  - Then compute spatial shard
  - Query data shard
- **Validation**: Entity queries work in spatial mode
- **Estimated effort**: 1.5 hours

## Phase 3: Query Routing

### Task 3.1: Strategy-aware routing
- **File**: Query routing code
- **Changes**:
  - Check cluster shard strategy
  - Route entity queries appropriately
  - Route spatial queries to covering shards
- **Validation**: Queries go to correct shards
- **Estimated effort**: 2 hours

### Task 3.2: Coordinator integration
- **File**: `src/coordinator.zig`
- **Changes**:
  - Support both sharding strategies
  - Use covering computation for spatial queries
  - Fallback to all shards if strategy unknown
- **Validation**: Coordinator routes correctly
- **Estimated effort**: 1.5 hours

### Task 3.3: Client SDK integration
- **Files**: Client SDKs (Node, Python, Rust, etc.)
- **Changes**:
  - Support spatial shard strategy
  - Compute covering shards for spatial queries
  - Entity lookups use two-hop path
- **Validation**: SDKs work with spatial clusters
- **Estimated effort**: 4 hours

## Phase 4: Configuration

### Task 4.1: CLI configuration
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Add `--shard-strategy` option
  - Validate strategy at cluster creation
  - Show strategy in cluster status
- **Validation**: CLI accepts strategy
- **Estimated effort**: 1 hour

### Task 4.2: Topology metadata
- **File**: Topology/cluster state
- **Changes**:
  - Store shard strategy in cluster metadata
  - Include in topology response
  - Clients discover strategy automatically
- **Validation**: Strategy in topology
- **Estimated effort**: 1 hour

## Phase 5: Metrics & Observability

### Task 5.1: Add strategy metrics
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - `archerdb_shard_strategy` info metric
  - `archerdb_query_shards_queried` histogram (per strategy)
  - `archerdb_entity_lookup_latency` (spatial mode only)
- **Validation**: Metrics visible
- **Estimated effort**: 30 minutes

### Task 5.2: Add shard utilization metrics
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - Per-shard entity count
  - Per-shard query count
  - Highlight imbalance in spatial mode
- **Validation**: Utilization visible
- **Estimated effort**: 30 minutes

## Phase 6: Testing

### Task 6.1: Unit tests for spatial sharding
- **File**: `src/sharding.zig` (test section)
- **Tests**:
  - `computeSpatialShard` correctness
  - `getCoveringShards` correctness
  - Edge cases (poles, antimeridian)
- **Validation**: All tests pass
- **Estimated effort**: 2 hours

### Task 6.2: Integration tests
- **File**: Integration test suite
- **Tests**:
  - Create spatial cluster
  - Insert entities in various locations
  - Verify spatial queries hit correct shards
  - Verify entity lookups work
- **Validation**: All tests pass
- **Estimated effort**: 3 hours

### Task 6.3: Performance comparison
- **File**: Benchmark suite
- **Tests**:
  - Radius query: entity vs spatial sharding
  - Entity lookup: entity vs spatial sharding
  - Mixed workload comparison
- **Validation**: Documented trade-offs
- **Estimated effort**: 2 hours

## Phase 7: Documentation

### Task 7.1: Strategy selection guide
- **File**: Documentation
- **Changes**:
  - When to use entity vs spatial
  - Trade-offs and limitations
  - Hot spot considerations
- **Validation**: Documentation review
- **Estimated effort**: 1 hour

### Task 7.2: Update CLI help
- **File**: CLI help text
- **Changes**:
  - Document `--shard-strategy` option
  - Examples for each strategy
- **Validation**: Help text accurate
- **Estimated effort**: 15 minutes

## Dependencies

- Phase 2 depends on Phase 1
- Phase 3 depends on Phases 1 and 2
- Phase 4-7 can proceed in parallel after Phase 3

## Estimated Total Effort

- **Sharding Strategy**: 3.5 hours
- **Entity Lookup Index**: 4 hours
- **Query Routing**: 7.5 hours
- **Configuration**: 2 hours
- **Metrics**: 1 hour
- **Testing**: 7 hours
- **Documentation**: 1.25 hours
- **Total**: ~26 hours (~3-4 working days)

## Verification Checklist

- [x] `ShardStrategy` enum defined (src/sharding.zig)
- [x] `computeSpatialShard` returns correct shards (src/sharding.zig)
- [x] `getCoveringShards` returns minimal shard set (src/sharding.zig)
- [x] Entity lookup works in spatial mode (2-hop) via `EntityLookupIndex` (src/sharding.zig)
- [x] Spatial queries fan out to fewer shards (getShardsForSpatialQuery in src/sharding.zig:658)
- [ ] Strategy stored in cluster metadata (deferred - requires superblock changes)
- [x] SDKs support spatial strategy (all SDKs: ShardingStrategy.java, geo_sharding.go, GeoShardingTypes.cs, types.py, geo.ts)
- [x] Metrics show shard utilization (src/archerdb/metrics.zig)
- [ ] Documentation explains trade-offs (deferred per project policy)
