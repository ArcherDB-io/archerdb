# Change: Add Polygon Hole Support

## Why

Current polygon queries only support simple polygons (single ring). Many real-world geofencing use cases require **polygons with holes** - for example:
- A delivery zone that excludes a private property
- A city boundary that excludes parks or water bodies
- A service area with restricted zones (airports, military bases)

Without hole support, users must perform multiple queries and client-side filtering, which is inefficient and error-prone.

## What Changes

### Wire Format
- **MODIFIED** `QueryPolygonFilter` struct to add `hole_count` field
- **ADDED** `HoleDescriptor` struct to encode hole ring offsets
- Wire format: `[Header][OuterVertices][HoleDescriptor0][Hole0Vertices][HoleDescriptor1][Hole1Vertices]...`

### Algorithm
- **MODIFIED** `pointInPolygon` to support multi-ring polygons
- Point must be inside outer ring AND outside all hole rings

### Validation
- **ADDED** Hole validation rules (winding order, non-intersection, containment)
- **ADDED** Error codes for invalid holes

### Client SDKs
- **MODIFIED** `query_polygon()` API to accept optional holes parameter
- Backwards compatible: existing single-ring queries continue to work

## Impact

- **Affected specs**: query-engine, client-protocol, client-sdk, error-codes, data-model
- **Affected code**:
  - `src/geo_state_machine.zig` - QueryPolygonFilter struct
  - `src/s2_index.zig` - pointInPolygon algorithm
  - `src/post_filter.zig` - checkPolygon method
  - `src/clients/*/` - All client SDK bindings
- **Backwards compatible**: Yes - `hole_count=0` preserves existing behavior
- **Performance impact**: Minimal - O(h) additional checks where h = number of holes

## Alternatives Considered

1. **Multi-polygon queries**: Query multiple simple polygons separately
   - Rejected: Requires client-side coordination, inefficient for large result sets

2. **GeoJSON/WKT format**: Switch to standard geometry formats
   - Rejected: Text parsing overhead, float precision issues, breaks zero-copy design

3. **Boolean operations**: Support polygon union/difference at query time
   - Rejected: Too complex, can be added later as separate feature

## Success Criteria

- [ ] Polygon queries with up to 100 holes work correctly
- [ ] Performance overhead < 5% for queries with 0-10 holes
- [ ] All existing polygon tests pass unchanged
- [ ] Client SDKs provide intuitive API for specifying holes
