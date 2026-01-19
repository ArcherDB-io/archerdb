# Design: Self-Intersecting Polygon Validation

## Context

Polygon containment queries use either crossing number or winding number algorithms. Self-intersecting polygons produce different results depending on algorithm, making results undefined. Client-side validation prevents these issues.

## Goals / Non-Goals

### Goals

1. **Detect self-intersections**: Find all crossing segments
2. **Clear errors**: Report exact intersection locations
3. **Fast validation**: <1ms for typical polygons

### Non-Goals

1. **Automatic repair**: Just detection
2. **Server-side validation**: Client responsibility
3. **Complex topology**: Focus on simple polygons

## Decisions

### Decision 1: Sweep Line Algorithm

**Choice**: Use Bentley-Ottmann sweep line for O(n log n) detection.

**Rationale**:
- Optimal complexity for segment intersection
- Handles all edge cases correctly
- Well-documented algorithm

**Implementation**:
```python
def find_self_intersections(polygon: List[Point]) -> List[Intersection]:
    """
    Find all self-intersections in polygon using sweep line.

    Returns list of intersections with segment indices.
    """
    segments = polygon_to_segments(polygon)
    events = initialize_events(segments)
    active = SortedSet()  # segments crossing sweep line
    intersections = []

    while events:
        event = events.pop_min()

        if event.type == EventType.LEFT:
            # Segment starts - add to active set
            active.add(event.segment)
            # Check neighbors for intersection
            check_neighbors(event.segment, active, events)

        elif event.type == EventType.RIGHT:
            # Segment ends - remove from active set
            check_neighbors(event.segment, active, events)
            active.remove(event.segment)

        elif event.type == EventType.INTERSECTION:
            intersections.append(event.intersection)
            # Swap segment order in active set
            swap_segments(event.seg1, event.seg2, active)
            # Recheck neighbors
            check_new_neighbors(event.seg1, event.seg2, active, events)

    return intersections
```

### Decision 2: Validation Modes

**Choice**: Offer strict (error) and warn (log + proceed) modes.

**Rationale**:
- Strict for new applications
- Warn for migration from permissive systems
- Gradual adoption path

**Implementation**:
```python
class PolygonValidation(Enum):
    NONE = "none"      # No validation (legacy behavior)
    WARN = "warn"      # Log warning, proceed anyway
    STRICT = "strict"  # Raise error, reject polygon

client = ArcherDBClient(
    polygon_validation=PolygonValidation.STRICT
)
```

### Decision 3: Clear Error Messages

**Choice**: Include segment indices and intersection coordinates.

**Rationale**:
- Developers can locate and fix issue
- Visualization tools can highlight problem
- Debugging is straightforward

**Implementation**:
```python
class SelfIntersectionError(ArcherDBError):
    def __init__(self, intersections: List[Intersection]):
        self.intersections = intersections

        # Build clear message
        msg = f"Polygon has {len(intersections)} self-intersection(s):\n"
        for i, inter in enumerate(intersections):
            msg += f"  {i+1}. Segments {inter.seg1_idx}-{inter.seg1_idx+1} and "
            msg += f"{inter.seg2_idx}-{inter.seg2_idx+1} "
            msg += f"intersect at ({inter.x:.6f}, {inter.y:.6f})\n"

        super().__init__(msg)

# Example error:
# SelfIntersectionError: Polygon has 1 self-intersection(s):
#   1. Segments 2-3 and 5-6 intersect at (37.774929, -122.419418)
```

### Decision 4: Repair Suggestions

**Choice**: Provide optional repair hints for simple cases.

**Rationale**:
- Many intersections are accidental
- Simple fix: remove offending vertex
- Not automatic repair (user decision)

**Implementation**:
```python
def suggest_repair(polygon: List[Point], intersections: List[Intersection]) -> str:
    """Suggest fix for simple self-intersections."""
    if len(intersections) == 1:
        inter = intersections[0]
        # Check if removing one vertex fixes it
        for idx in [inter.seg1_idx + 1, inter.seg2_idx + 1]:
            test_poly = polygon[:idx] + polygon[idx+1:]
            if not has_self_intersection(test_poly):
                return f"Removing vertex {idx} may fix the intersection"

    return "Consider reviewing polygon vertices manually"
```

## Architecture

### Validation Flow

```
    Client                      SDK                       Server
       │                         │                           │
       │ query_polygon(poly)     │                           │
       │────────────────────────>│                           │
       │                         │                           │
       │                    ┌────┴────┐                      │
       │                    │Validate │                      │
       │                    │polygon  │                      │
       │                    └────┬────┘                      │
       │                         │                           │
       │                    ┌────┴────┐                      │
       │                    │Self-    │                      │
       │                    │intersect│                      │
       │                    │check    │                      │
       │                    └────┬────┘                      │
       │                         │                           │
       │              ┌──────────┴──────────┐                │
       │              │                     │                │
       │            valid               invalid              │
       │              │                     │                │
       │              ▼                     ▼                │
       │         ┌────────┐           ┌──────────┐           │
       │         │Send to │           │Raise     │           │
       │         │server  │           │error     │           │
       │         └────────┘           └──────────┘           │
       │              │                     │                │
       │              │                     │                │
       │              ▼                     │                │
       │              │─────────────────────┼───────────────>│
       │              │                     │                │
       │<─────────────│                     │                │
```

### Algorithm Visualization

```
Sweep Line Algorithm:

Input polygon:          Sweep line:              Result:
                        │
A ─────── B             │ A ─────── B            Intersection at X
 \       /              │  \       /
  \     /               │   \  X  /              Segments: 0-1 and 2-3
   \   /                │    \│  /
    \ /              ───┼─────┼─────            Point: (x, y)
     X                  │    /│\
    / \                 │   / │ \
   /   \                │  /  │  \
  /     \               │ D   │   C
 D ───── C              │     │
                        sweep line
```

## Configuration

### SDK Configuration

```python
# Strict validation (recommended for new apps)
client = ArcherDBClient(
    polygon_validation=PolygonValidation.STRICT
)

# Warning only (migration path)
client = ArcherDBClient(
    polygon_validation=PolygonValidation.WARN
)

# No validation (legacy behavior)
client = ArcherDBClient(
    polygon_validation=PolygonValidation.NONE
)
```

### Per-Query Override

```python
# Override validation for specific query
result = client.query_polygon(
    polygon=poly,
    validation=PolygonValidation.NONE  # Skip for this query
)
```

## Trade-Offs

### Validation Location

| Location | Pros | Cons |
|----------|------|------|
| Client (chosen) | Early feedback, no network | Every SDK must implement |
| Server | Single implementation | Late feedback, wastes network |
| Both | Defense in depth | Redundant work |

**Chose client**: Early feedback is more valuable.

## Validation Plan

### Unit Tests

1. **Detection accuracy**: Known self-intersecting polygons
2. **No false positives**: Valid polygons pass
3. **Edge cases**: Collinear vertices, near-intersections

### Integration Tests

1. **SDK integration**: All SDKs validate correctly
2. **Mode behavior**: Strict/warn/none work as expected
3. **Error messages**: Useful for debugging

### Performance Tests

1. **Typical polygons**: <1ms for 100 vertices
2. **Large polygons**: Acceptable for 10,000 vertices
3. **No intersections**: Fast path optimization
