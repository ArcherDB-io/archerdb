# Change: Spatial-Aware Sharding

Shard by geohash instead of entity ID for spatial query locality.

## Status: Draft

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design
- [tasks.md](tasks.md) - Implementation tasks (~26 hours)

## Spec Deltas

- [specs/index-sharding/spec.md](specs/index-sharding/spec.md) - Spatial sharding strategy

## Summary

Adds geohash-based sharding to reduce fan-out for spatial queries:

| Query Type | Entity Sharding | Spatial Sharding |
|------------|-----------------|------------------|
| query_uuid | 1 shard | 2 shards |
| query_radius | All 16 shards | 1-4 shards |
| query_polygon | All 16 shards | Variable |

## How It Works

```
ENTITY SHARDING:              SPATIAL SHARDING:
┌───┬───┬───┬───┐            ┌───┬───┬───┬───┐
│ A │ B │ C │ D │            │ABC│   │   │ D │
├───┼───┼───┼───┤            ├───┼───┼───┼───┤
│ E │ F │ G │ H │            │EFG│ H │   │   │
├───┼───┼───┼───┤            ├───┼───┼───┼───┤
│ I │ J │ K │ L │            │IJK│ L │   │   │
└───┴───┴───┴───┘            └───┴───┴───┴───┘
  (uniform)                    (by location)
```

## Trade-Offs

| Aspect | Entity | Spatial |
|--------|--------|---------|
| Entity lookup | 1 hop | 2 hops |
| Radius query | All shards | Few shards |
| Load balance | Uniform | Uneven |
| Hot spots | Unlikely | Possible |
| Best for | Entity-heavy | Spatial-heavy |

## Usage

```bash
# Create cluster with spatial sharding
archerdb cluster create --shards=16 --shard-strategy=spatial

# Entity sharding (default)
archerdb cluster create --shards=16 --shard-strategy=entity
```

## When to Use

- **Entity sharding**: Most workloads, entity-based access
- **Spatial sharding**: >80% spatial queries, geographic clustering
