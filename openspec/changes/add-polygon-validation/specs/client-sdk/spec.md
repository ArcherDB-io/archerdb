# Client SDK - Self-Intersecting Polygon Validation

## ADDED Requirements

### Requirement: Self-Intersection Detection

Client SDKs SHALL detect self-intersecting polygons before sending queries.

#### Scenario: Detection algorithm

- **WHEN** validating polygon geometry
- **THEN** SDKs SHALL:
  - Use sweep line algorithm (O(n log n))
  - Find all segment intersection points
  - Report intersection locations
- **AND** detection SHALL be deterministic

#### Scenario: Detection accuracy

- **WHEN** polygon contains self-intersection
- **THEN** detection SHALL find it with 100% accuracy
- **AND** no false positives on valid polygons
- **AND** handle edge cases (collinear segments, tangent points)

#### Scenario: Detection performance

- **WHEN** validating polygon
- **THEN** validation SHALL complete in:
  - <1ms for polygons with <100 vertices
  - <10ms for polygons with <1000 vertices
  - <100ms for polygons with <10000 vertices

### Requirement: Validation Modes

Client SDKs SHALL support configurable validation modes.

#### Scenario: Validation mode enum

- **WHEN** configuring validation
- **THEN** SDKs SHALL support:
  ```python
  class PolygonValidation(Enum):
      NONE = "none"      # No validation
      WARN = "warn"      # Log warning, proceed
      STRICT = "strict"  # Raise error, reject
  ```

#### Scenario: Client configuration

- **WHEN** creating client
- **THEN** validation mode SHALL be configurable:
  ```python
  client = ArcherDBClient(
      polygon_validation=PolygonValidation.STRICT
  )
  ```
- **AND** default SHALL be `WARN` for backward compatibility

#### Scenario: Per-query override

- **WHEN** executing query
- **THEN** validation MAY be overridden:
  ```python
  result = client.query_polygon(
      polygon=poly,
      validation=PolygonValidation.NONE
  )
  ```

### Requirement: Validation Behavior

Client SDKs SHALL behave according to configured validation mode.

#### Scenario: Strict mode behavior

- **WHEN** validation mode is STRICT
- **AND** polygon is self-intersecting
- **THEN** SDK SHALL:
  - Raise `SelfIntersectionError`
  - NOT send query to server
  - Include intersection details in error

#### Scenario: Warn mode behavior

- **WHEN** validation mode is WARN
- **AND** polygon is self-intersecting
- **THEN** SDK SHALL:
  - Log warning with intersection details
  - Proceed with query
  - Return results (which may be undefined)

#### Scenario: None mode behavior

- **WHEN** validation mode is NONE
- **THEN** SDK SHALL:
  - Skip validation entirely
  - Send query directly to server
  - Behave as legacy implementation

### Requirement: Error Details

Self-intersection errors SHALL include detailed location information.

#### Scenario: Error message format

- **WHEN** self-intersection is detected
- **THEN** error SHALL include:
  ```
  SelfIntersectionError: Polygon has 2 self-intersection(s):
    1. Segments 2-3 and 5-6 intersect at (37.774929, -122.419418)
    2. Segments 7-8 and 10-11 intersect at (37.775012, -122.420001)
  ```

#### Scenario: Programmatic access

- **WHEN** handling self-intersection error
- **THEN** code SHALL access intersection details:
  ```python
  try:
      client.query_polygon(poly)
  except SelfIntersectionError as e:
      for inter in e.intersections:
          print(f"Segment {inter.seg1_idx} crosses {inter.seg2_idx}")
          print(f"At point ({inter.lat}, {inter.lon})")
  ```

### Requirement: Repair Suggestions

Client SDKs MAY provide repair suggestions for simple cases.

#### Scenario: Repair hint

- **WHEN** self-intersection is detected
- **AND** simple repair is possible
- **THEN** SDK MAY suggest:
  ```
  Suggestion: Removing vertex 4 may fix the intersection
  ```

#### Scenario: No repair available

- **WHEN** no simple repair exists
- **THEN** SDK SHALL suggest:
  ```
  Suggestion: Review polygon vertices manually
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Self-Intersection Detection | IMPLEMENTED | All SDKs - sweep line algorithm |
| Validation Modes | IMPLEMENTED | NONE/WARN/STRICT modes in all SDKs |
| Validation Behavior | IMPLEMENTED | Mode-specific behavior implemented |
| Error Details | IMPLEMENTED | `PolygonValidationError` with intersection details |
| Repair Suggestions | IMPLEMENTED | Vertex removal suggestions in error messages |

**SDK Implementation Locations:**
- Python: `src/clients/python/src/archerdb/types.py`
- Go: `src/clients/go/pkg/types/polygon_validation.go`
- Rust: `src/clients/rust/src/lib.rs`
- Java: `src/clients/java/src/main/java/com/archerdb/geo/PolygonValidation.java`
- .NET: `src/clients/dotnet/ArcherDB/PolygonValidation.cs`
- Node: `src/clients/node/src/geo.ts`

## Related Specifications

- See base `client-sdk/spec.md` for SDK requirements
- See `query-engine/spec.md` for polygon query behavior
- See `error-codes/spec.md` for error handling
