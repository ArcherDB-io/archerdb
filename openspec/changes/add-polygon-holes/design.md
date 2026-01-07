# Design: Polygon Hole Support

## Context

ArcherDB's polygon query currently supports only simple polygons (single ring). This design extends the wire format and algorithm to support polygons with interior holes while maintaining:
- Zero-copy parsing (wire format = memory format)
- VSR consensus determinism (no floating point in hot path)
- Cache-line alignment constraints
- Backwards compatibility

## Goals / Non-Goals

### Goals
- Support polygons with up to 100 holes
- Maintain wire format alignment requirements
- Preserve existing query performance for simple polygons
- Provide clear validation and error messages

### Non-Goals
- Multi-polygon support (union of disjoint polygons)
- Nested holes (holes within holes)
- Self-intersecting polygons
- GeoJSON/WKT import at the wire level

## Decisions

### Decision 1: Wire Format Structure

**Choice**: Sequential ring encoding with hole descriptors

```
┌────────────────────────────────────────────────────────────┐
│ QueryPolygonFilter (128 bytes)                             │
│   vertex_count: u32      // Outer ring vertices            │
│   hole_count: u32        // Number of holes (0-100)        │
│   limit: u32                                               │
│   timestamp_min: u64                                       │
│   timestamp_max: u64                                       │
│   group_id: u64                                            │
│   reserved: [88]u8       // Reduced from [96]u8            │
├────────────────────────────────────────────────────────────┤
│ PolygonVertex[0..vertex_count] (16 bytes each)             │
│   Outer ring vertices                                      │
├────────────────────────────────────────────────────────────┤
│ HoleDescriptor[0..hole_count] (8 bytes each)               │
│   hole_vertex_count: u32                                   │
│   reserved: u32                                            │
├────────────────────────────────────────────────────────────┤
│ Hole 0 vertices: PolygonVertex[hole_0_count]               │
├────────────────────────────────────────────────────────────┤
│ Hole 1 vertices: PolygonVertex[hole_1_count]               │
├────────────────────────────────────────────────────────────┤
│ ... (remaining holes)                                      │
└────────────────────────────────────────────────────────────┘
```

**Rationale**:
- Header remains 128 bytes (cache-line aligned)
- Hole descriptors before hole vertices enables streaming validation
- Total vertex limit (outer + all holes) remains 10,000
- Zero parsing overhead for simple polygons (hole_count=0)

**Alternatives considered**:
1. **Separate arrays**: Outer vertices, then all hole vertices with offset table
   - Rejected: Requires random access, breaks streaming
2. **GeoJSON-style nested arrays**: Array of rings
   - Rejected: Requires variable-length encoding, breaks zero-copy

### Decision 2: Point-in-Polygon Algorithm

**Choice**: Sequential ring testing

```zig
pub fn pointInPolygonWithHoles(
    point: LatLon,
    outer: []const LatLon,
    holes: []const []const LatLon,
) bool {
    // Must be inside outer ring
    if (!pointInPolygon(point, outer)) return false;

    // Must be outside all holes
    for (holes) |hole| {
        if (pointInPolygon(point, hole)) return false;
    }
    return true;
}
```

**Rationale**:
- Simple, correct, deterministic
- Early exit on outer ring failure (common case)
- O(n + h*m) where n=outer vertices, h=holes, m=avg hole vertices

**Alternatives considered**:
1. **Winding number with signed areas**: Single pass over all rings
   - Rejected: More complex, marginal performance gain
2. **Spatial index for holes**: Build R-tree for hole bounding boxes
   - Rejected: Overkill for <100 holes, adds allocation

### Decision 3: Validation Rules

**Choice**: Strict validation with clear error codes

| Validation | Error Code | Description |
|------------|------------|-------------|
| hole_count > 100 | 120 | Too many holes |
| hole_vertex_count < 3 | 121 | Hole too simple |
| hole outside outer | 122 | Hole not contained |
| holes overlap | 123 | Holes intersect |
| hole self-intersects | 109 | Reuse existing code |

**Rationale**:
- Fail fast with specific errors
- Containment check uses bounding box first (fast), then point-in-polygon
- Overlap detection only checks bounding box intersection (conservative)

### Decision 4: S2 Covering for Holes

**Choice**: Cover outer ring only, post-filter excludes holes

**Rationale**:
- S2 RegionCoverer doesn't natively support holes
- Covering outer ring is conservative (may include extra cells)
- Post-filter accurately excludes points in holes
- Simpler implementation, easier to reason about correctness

**Future optimization**: Could subtract hole coverings for very large holes, but adds complexity.

### Decision 5: Winding Order Convention

**Choice**: Outer ring counter-clockwise (CCW), holes clockwise (CW)

**Rationale**:
- Matches GeoJSON RFC 7946 convention
- Matches PostGIS convention
- Enables signed-area validation
- Client SDKs can auto-correct winding order

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Performance regression for complex holes | Benchmark with 10, 50, 100 holes; set reasonable limits |
| Incorrect validation allowing invalid polygons | Comprehensive test suite with edge cases |
| Wire format changes break existing clients | hole_count=0 is backwards compatible; version negotiation |
| Memory exhaustion with many large holes | Total vertex limit (10,000) applies to outer + all holes |

## Migration Plan

1. **Phase 1**: Add wire format support (hole_count field, backwards compatible)
2. **Phase 2**: Implement validation and algorithm
3. **Phase 3**: Update client SDKs with optional holes parameter
4. **Phase 4**: Documentation and examples

**Rollback**: If issues discovered, clients can omit holes parameter to use simple polygon path.

## Open Questions

1. **Q**: Should we support "nested holes" (islands within holes)?
   **A**: No - out of scope, can be added later if needed

2. **Q**: Should validation compute exact polygon area?
   **A**: No - bounding box sufficient for containment checks, exact area is expensive

3. **Q**: Maximum holes limit - 100 enough?
   **A**: Yes - real-world geofences rarely need >10 holes; 100 is generous

## Constants

```zig
/// Maximum number of holes in a polygon query
pub const polygon_holes_max: u32 = 100;

/// Minimum vertices per hole ring
pub const polygon_hole_vertices_min: u32 = 3;

/// Total vertex limit (outer + all holes combined)
pub const polygon_vertices_max: u32 = 10_000;  // Unchanged
```
