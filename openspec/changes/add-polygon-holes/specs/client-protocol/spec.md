## MODIFIED Requirements

### Requirement: Polygon Query Wire Format

The wire format for polygon queries SHALL support multi-ring polygons with holes.

#### Scenario: QueryPolygonFilter structure

- **WHEN** encoding a polygon query
- **THEN** the `QueryPolygonFilter` header SHALL have the following layout:
  ```
  QueryPolygonFilter (128 bytes):
    offset 0:   vertex_count: u32      // Outer ring vertex count
    offset 4:   hole_count: u32        // Number of hole rings (0-100)
    offset 8:   limit: u32             // Maximum results to return
    offset 12:  reserved_align: u32    // Alignment padding
    offset 16:  timestamp_min: u64     // Minimum timestamp filter
    offset 24:  timestamp_max: u64     // Maximum timestamp filter
    offset 32:  group_id: u64          // Group ID filter
    offset 40:  reserved: [88]u8       // Reserved for future use
  ```
- **AND** the struct SHALL be 128 bytes (cache-line aligned)
- **AND** `hole_count = 0` SHALL indicate a simple polygon (backwards compatible)

#### Scenario: HoleDescriptor structure

- **WHEN** a polygon query includes holes (`hole_count > 0`)
- **THEN** hole descriptors SHALL follow the outer ring vertices:
  ```
  HoleDescriptor (8 bytes):
    offset 0:   vertex_count: u32      // Vertices in this hole ring
    offset 4:   reserved: u32          // Reserved for future use
  ```
- **AND** hole descriptors SHALL be 8-byte aligned

#### Scenario: Complete message layout with holes

- **WHEN** encoding a polygon query with holes
- **THEN** the message body SHALL have the following layout:
  ```
  [QueryPolygonFilter: 128 bytes]
  [OuterVertex[0]: 16 bytes]
  [OuterVertex[1]: 16 bytes]
  ...
  [OuterVertex[vertex_count-1]: 16 bytes]
  [HoleDescriptor[0]: 8 bytes]
  [HoleDescriptor[1]: 8 bytes]
  ...
  [HoleDescriptor[hole_count-1]: 8 bytes]
  [Hole0Vertex[0]: 16 bytes]
  ...
  [Hole0Vertex[hole_0_count-1]: 16 bytes]
  [Hole1Vertex[0]: 16 bytes]
  ...
  ```
- **AND** total message size SHALL NOT exceed `message_body_size_max`

#### Scenario: Message size calculation

- **WHEN** calculating message size for polygon query with holes
- **THEN** the size SHALL be computed as:
  ```
  size = 128  // QueryPolygonFilter
       + (vertex_count × 16)  // Outer vertices
       + (hole_count × 8)     // Hole descriptors
       + sum(hole_vertex_counts) × 16  // All hole vertices
  ```
- **AND** the size SHALL be validated before transmission

## ADDED Requirements

### Requirement: Polygon Hole Constants

The protocol SHALL define constants for polygon hole limits.

#### Scenario: Hole limit constants

- **WHEN** validating polygon query parameters
- **THEN** the following limits SHALL apply:
  ```
  polygon_holes_max: u32 = 100          // Maximum holes per polygon
  polygon_hole_vertices_min: u32 = 3    // Minimum vertices per hole
  polygon_vertices_max: u32 = 10_000    // Total vertices (outer + holes)
  ```

#### Scenario: Validation order

- **WHEN** validating a polygon query with holes
- **THEN** validation SHALL proceed in this order:
  1. Check `hole_count <= polygon_holes_max`
  2. Check each `hole_vertex_count >= polygon_hole_vertices_min`
  3. Check total vertices <= `polygon_vertices_max`
  4. Validate hole containment within outer ring
  5. Check for hole overlaps

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| QueryPolygonFilter 128-byte | ✓ Complete | `geo_state_machine.zig:634` |
| HoleDescriptor 8-byte | ✓ Complete | `geo_state_machine.zig:660` |
| Message Layout with Holes | ✓ Complete | Variable-length body parsing |
| polygon_holes_max (100) | ✓ Complete | `constants.zig` |
| polygon_hole_vertices_min (3) | ✓ Complete | `constants.zig` |
| Validation Order | ✓ Complete | query_polygon validation logic |
