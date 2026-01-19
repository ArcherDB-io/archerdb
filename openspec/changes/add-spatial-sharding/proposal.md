# Proposal: Spatial-Aware Sharding

## Summary

Add geohash-based sharding as an alternative to entity-ID sharding, enabling spatial locality for range queries and reducing cross-shard fan-out.

## Motivation

### Problem

Current sharding uses `hash(entity_id) % num_shards`, which distributes entities randomly across shards. For spatial queries (radius, polygon), this requires fan-out to ALL shards:

```
Radius Query: fan-out to 16 shards
┌───────┐ ┌───────┐ ┌───────┐     ┌───────┐
│Shard 0│ │Shard 1│ │Shard 2│ ... │Shard15│
└───────┘ └───────┘ └───────┘     └───────┘
    ↑         ↑         ↑             ↑
    └─────────┴─────────┴─────────────┘
              All shards queried
```

For location-intensive workloads, this is inefficient.

### Current Behavior

- Sharding based on entity_id hash
- All spatial queries fan out to all shards
- Good for entity-based access patterns
- Inefficient for spatial-heavy workloads

### Desired Behavior

- **Geohash sharding**: Shard by location, not entity
- **Reduced fan-out**: Spatial queries hit fewer shards
- **Configurable**: Choose sharding strategy per cluster
- **Hybrid support**: Entity lookups still work (via secondary index)

## Scope

### In Scope

1. **Geohash-based shard assignment**: Use S2 cell prefix for sharding
2. **Spatial query routing**: Route to relevant shards only
3. **Configuration option**: `--shard-strategy=spatial|entity`
4. **Entity lookup index**: Secondary index for entity-based queries

### Out of Scope

1. **Migration tool**: Converting existing clusters (separate proposal)
2. **Hybrid per-entity**: All entities in cluster use same strategy
3. **Dynamic rebalancing**: Fixed spatial partitioning

## Success Criteria

1. **Reduced fan-out**: Typical radius queries hit 1-4 shards vs all
2. **Entity lookup parity**: Entity-based queries same latency
3. **Clear trade-offs**: Documentation of when to use each strategy

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Hot spots | Uneven load (e.g., cities) | Use finer S2 cells, document limits |
| Entity lookup overhead | Secondary index cost | Keep secondary index in RAM |
| Migration complexity | Can't change strategy easily | Document upfront, cluster per strategy |

## Stakeholders

- **Fleet management**: Vehicles clustered geographically
- **IoT platforms**: Sensors in geographic regions
- **Real-time analytics**: Spatial aggregations benefit from locality
