# Query Engine - Polygon Holes

## ADDED Requirements

### Requirement: Polygon Hole Support

The query engine SHALL support polygon queries with interior holes (multi-ring polygons).

A polygon with holes consists of:
- One **outer ring** defining the exterior boundary (counter-clockwise winding)
- Zero or more **hole rings** defining interior exclusion zones (clockwise winding)

A point is considered inside a polygon with holes if and only if:
1. The point is inside the outer ring, AND
2. The point is outside ALL hole rings

#### Scenario: Simple polygon with one hole

- **WHEN** a polygon query is submitted with:
  - Outer ring: Square from (0,0) to (10,10)
  - One hole: Square from (4,4) to (6,6)
- **AND** a point at (5,5) is evaluated
- **THEN** the point SHALL be excluded (inside hole)
- **AND** a point at (2,2) SHALL be included (inside outer, outside hole)

#### Scenario: Polygon with multiple holes

- **WHEN** a polygon query is submitted with multiple holes
- **THEN** a point SHALL be excluded if it falls inside ANY hole
- **AND** the post-filter SHALL check all holes sequentially

#### Scenario: Backwards compatibility with simple polygons

- **WHEN** a polygon query is submitted with `hole_count = 0`
- **THEN** the query SHALL behave identically to the existing simple polygon query
- **AND** no performance overhead SHALL be incurred for the hole check

### Requirement: Polygon Hole Limits

The system SHALL enforce limits on polygon holes to ensure query performance.

#### Scenario: Maximum hole count

- **WHEN** a polygon query specifies more than 100 holes
- **THEN** the system SHALL return error code 117 (`too_many_holes`)
- **AND** the error context SHALL include the requested hole count

#### Scenario: Minimum hole vertices

- **WHEN** any hole ring has fewer than 3 vertices
- **THEN** the system SHALL return error code 118 (`hole_vertex_count_invalid`)
- **AND** the error context SHALL include the hole index and vertex count

#### Scenario: Total vertex limit with holes

- **WHEN** the sum of outer ring vertices and all hole vertices exceeds 10,000
- **THEN** the system SHALL return error code 101 (`polygon_too_complex`)
- **AND** the error context SHALL include the total vertex count

### Requirement: Polygon Hole Validation

The system SHALL validate hole geometry to ensure correct query results.

#### Scenario: Hole containment validation

- **WHEN** a hole ring is not fully contained within the outer ring
- **THEN** the system SHALL return error code 119 (`hole_not_contained`)
- **AND** the error context SHALL include the hole index
- **AND** containment SHALL be checked using bounding box first, then point-in-polygon for edge cases

#### Scenario: Hole overlap detection

- **WHEN** two or more hole rings have overlapping bounding boxes
- **THEN** the system SHALL return error code 120 (`holes_overlap`)
- **AND** the error context SHALL include the indices of overlapping holes
- **AND** this validation is conservative (may reject valid but touching holes)

#### Scenario: Hole winding order

- **WHEN** validating hole rings
- **THEN** the system SHALL accept clockwise winding order for holes
- **AND** the system MAY auto-correct counter-clockwise holes by reversing vertex order
- **AND** winding order SHALL be determined by signed area calculation

### Requirement: Polygon Hole S2 Covering

The S2 covering for polygons with holes SHALL cover the outer ring only.

#### Scenario: S2 covering generation

- **WHEN** generating S2 cell covering for a polygon with holes
- **THEN** the covering SHALL be computed from the outer ring bounding box
- **AND** holes SHALL NOT affect the covering (conservative approach)
- **AND** the post-filter SHALL accurately exclude points in holes

#### Scenario: Post-filter efficiency with holes

- **WHEN** post-filtering candidates for a polygon with holes
- **THEN** the outer ring check SHALL be performed first
- **AND** hole checks SHALL only be performed if point is inside outer ring
- **AND** hole checks SHALL terminate early on first matching hole

## MODIFIED Requirements

### Requirement: Polygon Query Post-Filter

The post-filter for polygon queries SHALL support multi-ring polygons.

The `checkPolygon` method SHALL:
1. First check if point is inside the outer ring
2. If inside outer ring, check each hole ring
3. Return false if point is inside any hole
4. Return true only if inside outer and outside all holes

#### Scenario: Post-filter with holes

- **WHEN** a candidate point is evaluated against a polygon with holes
- **THEN** the `passed_polygon_filter` counter SHALL increment only for points passing all checks
- **AND** the `failed_polygon_filter` counter SHALL increment for points inside holes

#### Scenario: Post-filter metrics

- **WHEN** monitoring polygon post-filter performance
- **THEN** the following metrics SHALL be exposed:
  ```
  archerdb_pf_polygon_outer_checked counter
  archerdb_pf_polygon_holes_checked counter
  archerdb_pf_polygon_excluded_by_hole counter
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Polygon Hole Support | IMPLEMENTED | `src/geo_state_machine.zig` |
| Polygon Hole Limits | IMPLEMENTED | `src/geo_state_machine.zig` |
| Polygon Hole Validation | IMPLEMENTED | `src/geo_state_machine.zig` |
| Polygon Hole S2 Covering | IMPLEMENTED | `src/geo_state_machine.zig` |
| Polygon Query Post-Filter | IMPLEMENTED | `src/geo_state_machine.zig` |
