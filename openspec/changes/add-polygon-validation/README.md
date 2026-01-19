# Change: Self-Intersecting Polygon Validation

Client-side validation to detect and reject self-intersecting polygons.

## Status: Draft

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design
- [tasks.md](tasks.md) - Implementation tasks (~86 hours)

## Spec Deltas

- [specs/client-sdk/spec.md](specs/client-sdk/spec.md) - Validation modes, error format

## Summary

Adds client-side detection of self-intersecting (invalid) polygons:

```python
# Self-intersecting polygon (bow-tie)
poly = [(0,0), (2,2), (2,0), (0,2)]

# With strict validation (recommended)
client = ArcherDBClient(polygon_validation=PolygonValidation.STRICT)
client.query_polygon(poly)
# Raises: SelfIntersectionError: Segments 0-1 and 2-3 intersect at (1,1)
```

## Why It Matters

Self-intersecting polygons produce undefined results:

```
Is P inside?
     A ──────── B
      \        /
       \  P   /
        \    /         Crossing rule: Inside
         \  /          Winding rule: Outside
          \/
          /\           Different algorithms = different answers!
         /  \
        D ──── C
```

## Validation Modes

```python
# Strict - reject invalid (recommended for new apps)
client = ArcherDBClient(polygon_validation=PolygonValidation.STRICT)

# Warn - log warning, proceed anyway
client = ArcherDBClient(polygon_validation=PolygonValidation.WARN)

# None - skip validation (legacy behavior)
client = ArcherDBClient(polygon_validation=PolygonValidation.NONE)
```

## Error Details

```python
try:
    client.query_polygon(poly)
except SelfIntersectionError as e:
    print(f"Found {len(e.intersections)} intersections")
    for inter in e.intersections:
        print(f"  Segments {inter.seg1_idx} and {inter.seg2_idx}")
        print(f"  At ({inter.lat}, {inter.lon})")
```

## Performance

- O(n log n) sweep line algorithm
- <1ms for typical polygons (<100 vertices)
- <10ms for large polygons (<1000 vertices)
