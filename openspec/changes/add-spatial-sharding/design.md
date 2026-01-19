# Design: Spatial-Aware Sharding

## Context

ArcherDB uses S2 cells for spatial indexing. S2 cells have hierarchical structure where cell IDs encode location at various precision levels. This naturally maps to sharding: use cell prefix as shard key.

## Goals / Non-Goals

### Goals

1. **Spatial locality**: Nearby entities on same shard
2. **Reduced fan-out**: Spatial queries target relevant shards
3. **Configurable**: Choose at cluster creation time

### Non-Goals

1. **Dynamic rebalancing**: Fixed partitioning
2. **Hot-spot elimination**: Document and manage externally
3. **Hybrid strategies**: One strategy per cluster

## Decisions

### Decision 1: S2 Cell Prefix Sharding

**Choice**: Use high bits of S2 cell ID as shard key.

**Rationale**:
- S2 cells are hierarchical (face + position)
- Higher bits = coarser spatial regions
- Natural mapping to power-of-2 shards

**Implementation**:
```zig
/// Compute spatial shard from S2 cell ID.
///
/// Uses top bits of cell ID after face (3 bits).
/// For 16 shards: bits 3-6 (4 bits) determine shard.
pub fn computeSpatialShard(cell_id: u64, num_shards: u32) u32 {
    assert(std.math.isPowerOfTwo(num_shards));

    // Skip face bits (top 3), extract shard bits
    const shard_bits = std.math.log2(num_shards);
    const shift = 64 - 3 - shard_bits;
    const shard_key = (cell_id >> shift) & (num_shards - 1);

    return @intCast(shard_key);
}
```

### Decision 2: Shard Strategy Configuration

**Choice**: Cluster-level configuration at creation time.

**Rationale**:
- Changing strategy requires data migration
- Per-cluster simplifies routing logic
- Clear deployment decision

**Implementation**:
```zig
pub const ShardStrategy = enum {
    /// Hash entity_id for uniform distribution
    entity,
    /// Use S2 cell prefix for spatial locality
    spatial,
};

pub const ClusterConfig = struct {
    shard_strategy: ShardStrategy = .entity,
    num_shards: u32 = 16,
    // ...
};
```

### Decision 3: Entity Lookup via Secondary Index

**Choice**: Maintain entity_id → cell_id mapping for entity-based lookups.

**Rationale**:
- Entity lookups still needed (query_uuid, query_by_entity)
- Secondary index is small (16 bytes per entity)
- Can be distributed same as primary

**Implementation**:
```zig
/// Entity lookup index entry (spatial sharding mode).
pub const EntityLookupEntry = extern struct {
    entity_id: u128,  // Primary key
    cell_id: u64,     // Current S2 cell (for shard routing)
    padding: u64,     // Alignment
};

// On entity lookup:
// 1. Hash entity_id to find lookup shard
// 2. Get cell_id from lookup index
// 3. Compute spatial shard from cell_id
// 4. Query that shard for entity data
```

### Decision 4: Spatial Query Routing

**Choice**: Compute covering shards from query geometry.

**Rationale**:
- S2 library can compute covering cells
- Map covering cells to shard set
- Only query relevant shards

**Implementation**:
```zig
/// Get shards that cover a spatial query region.
pub fn getCoveringShards(
    region: S2Region,
    num_shards: u32,
) std.ArrayList(u32) {
    var shards = std.ArrayList(u32).init(allocator);

    // Get S2 covering at shard granularity
    const covering = s2.getCovering(region, max_level: shard_level);

    for (covering.cells) |cell| {
        const shard = computeSpatialShard(cell.id(), num_shards);
        // Deduplicate
        if (!shards.contains(shard)) {
            shards.append(shard);
        }
    }

    return shards;
}
```

## Architecture

### Shard Layout Comparison

```
ENTITY SHARDING (current):           SPATIAL SHARDING (proposed):
┌─────────────────────────┐          ┌─────────────────────────┐
│    hash(entity_id)      │          │   S2 cell prefix        │
│    determines shard     │          │   determines shard      │
└─────────────────────────┘          └─────────────────────────┘

Entity distribution:                  Entity distribution:
┌───┬───┬───┬───┐                    ┌───┬───┬───┬───┐
│ A │ B │ C │ D │ (uniform)          │ABC│   │   │ D │ (by location)
├───┼───┼───┼───┤                    ├───┼───┼───┼───┤
│ E │ F │ G │ H │                    │EFG│ H │   │   │
├───┼───┼───┼───┤                    ├───┼───┼───┼───┤
│ I │ J │ K │ L │                    │IJK│ L │   │   │
└───┴───┴───┴───┘                    └───┴───┴───┴───┘

Radius query: ALL shards             Radius query: 1-4 shards
```

### Query Routing with Spatial Sharding

```
                     SPATIAL QUERY
                          │
                          ▼
              ┌───────────────────────┐
              │  Compute S2 covering  │
              │  for query region     │
              └───────────┬───────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │  Map cells to shards  │
              │  (e.g., {0, 1, 4})   │
              └───────────┬───────────┘
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
        ┌───────┐     ┌───────┐     ┌───────┐
        │Shard 0│     │Shard 1│     │Shard 4│
        └───────┘     └───────┘     └───────┘
            │             │             │
            └─────────────┴─────────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │   Merge results       │
              └───────────────────────┘
```

### Entity Lookup with Spatial Sharding

```
            ENTITY LOOKUP (query_uuid)
                          │
                          ▼
              ┌───────────────────────┐
              │  Hash entity_id       │
              │  → lookup shard       │
              └───────────┬───────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │  Query lookup index   │
              │  → get cell_id        │
              └───────────┬───────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │  Compute spatial shard│
              │  from cell_id         │
              └───────────┬───────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │  Query data shard     │
              └───────────────────────┘
```

## Configuration

### Cluster Creation

```bash
# Entity sharding (default)
archerdb cluster create --shards=16 --shard-strategy=entity

# Spatial sharding
archerdb cluster create --shards=16 --shard-strategy=spatial
```

### Query Behavior

| Query Type | Entity Sharding | Spatial Sharding |
|------------|-----------------|------------------|
| query_uuid | 1 shard (direct) | 2 shards (lookup + data) |
| query_by_entity | 1 shard | 2 shards |
| query_radius | All shards | 1-4 shards (typical) |
| query_polygon | All shards | Variable (based on shape) |

## Trade-Offs

### Entity vs Spatial Sharding

| Aspect | Entity | Spatial |
|--------|--------|---------|
| Entity lookup | 1 hop | 2 hops |
| Radius query | All shards | Few shards |
| Load balance | Uniform | Uneven (geography) |
| Hot spots | Unlikely | Possible (cities) |
| Best for | Entity-heavy | Spatial-heavy |

**Recommendation**:
- **Entity**: Most workloads, balanced access patterns
- **Spatial**: >80% spatial queries, geographic clustering

## Validation Plan

### Unit Tests

1. **Spatial shard computation**: Correct shard for known cells
2. **Covering computation**: Correct shards for regions
3. **Entity lookup routing**: Correct two-hop path

### Integration Tests

1. **Spatial query routing**: Only relevant shards queried
2. **Entity lookup in spatial mode**: Still works correctly
3. **Load distribution**: Verify shard utilization

### Performance Tests

1. **Radius query improvement**: Measure fan-out reduction
2. **Entity lookup overhead**: Measure 2-hop vs 1-hop latency
3. **Hot spot impact**: Test with NYC-density data
