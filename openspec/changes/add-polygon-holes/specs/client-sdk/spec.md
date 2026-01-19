# Client SDK - Polygon Holes

## MODIFIED Requirements

### Requirement: Polygon Query API

The SDK polygon query API SHALL support polygons with holes.

#### Scenario: Polygon query with holes

- **WHEN** an application queries by polygon with holes
- **THEN** the SDK SHALL provide:
  ```
  results = client.query_polygon(
      vertices: []LatLon,           // Outer ring (CCW winding order)
      holes: [][]LatLon,            // Optional: hole rings (CW winding order)
      options: QueryOptions         // Same as existing options
  )
  ```
- **AND** the `holes` parameter SHALL be optional (default: empty)
- **AND** existing code using `query_polygon()` without holes SHALL continue to work

#### Scenario: Polygon query API variants by language

- **WHEN** implementing polygon hole support across SDKs
- **THEN** each SDK SHALL provide idiomatic API:

  **Node.js/TypeScript:**
  ```typescript
  interface QueryPolygonOptions {
    vertices: LatLon[];
    holes?: LatLon[][];  // Optional array of hole rings
    limit?: number;
    timestampMin?: bigint;
    timestampMax?: bigint;
    groupId?: bigint;
  }

  client.queryPolygon(options: QueryPolygonOptions): Promise<GeoEvent[]>
  ```

  **Python:**
  ```python
  def query_polygon(
      self,
      vertices: List[LatLon],
      holes: Optional[List[List[LatLon]]] = None,
      limit: int = 1000,
      timestamp_min: Optional[int] = None,
      timestamp_max: Optional[int] = None,
      group_id: Optional[int] = None,
  ) -> List[GeoEvent]:
  ```

  **Go:**
  ```go
  type QueryPolygonRequest struct {
      Vertices []LatLon
      Holes    [][]LatLon  // Optional
      Limit    uint32
      // ... other fields
  }

  func (c *Client) QueryPolygon(req QueryPolygonRequest) ([]GeoEvent, error)
  ```

  **Java:**
  ```java
  public List<GeoEvent> queryPolygon(
      List<LatLon> vertices,
      List<List<LatLon>> holes,  // May be null or empty
      QueryOptions options
  )
  ```

#### Scenario: Hole validation in SDK

- **WHEN** the SDK encodes a polygon query with holes
- **THEN** the SDK SHALL validate:
  1. Each hole has at least 3 vertices
  2. Total hole count does not exceed 100
  3. Total vertices (outer + holes) do not exceed 10,000
- **AND** validation failures SHALL throw/return client-side errors before network call

## ADDED Requirements

### Requirement: Polygon Builder API

The SDK MAY provide a builder pattern for constructing complex polygons.

#### Scenario: Polygon builder usage

- **WHEN** an application needs to construct a polygon with holes
- **THEN** the SDK MAY provide a fluent builder API:
  ```typescript
  const polygon = new PolygonBuilder()
    .outer([
      { lat: 0, lon: 0 },
      { lat: 10, lon: 0 },
      { lat: 10, lon: 10 },
      { lat: 0, lon: 10 },
    ])
    .addHole([
      { lat: 4, lon: 4 },
      { lat: 6, lon: 4 },
      { lat: 6, lon: 6 },
      { lat: 4, lon: 6 },
    ])
    .addHole([
      { lat: 7, lon: 7 },
      { lat: 9, lon: 7 },
      { lat: 9, lon: 9 },
      { lat: 7, lon: 9 },
    ])
    .build();

  const results = await client.queryPolygon({
    ...polygon,
    limit: 1000,
  });
  ```

### Requirement: Winding Order Helpers

The SDK SHALL provide utilities for winding order management.

#### Scenario: Winding order detection

- **WHEN** vertices are provided for a polygon ring
- **THEN** the SDK SHALL provide a function to detect winding order:
  ```typescript
  isClockwise(vertices: LatLon[]): boolean
  ```
- **AND** winding order SHALL be determined by signed area calculation

#### Scenario: Winding order correction

- **WHEN** vertices have incorrect winding order
- **THEN** the SDK MAY provide automatic correction:
  ```typescript
  // Option 1: Auto-correct in query
  client.queryPolygon({
    vertices: outerRing,
    holes: [hole1, hole2],
    autoCorrectWinding: true,  // Default: true
  });

  // Option 2: Manual correction utilities
  const correctedOuter = ensureCounterClockwise(outerRing);
  const correctedHole = ensureClockwise(hole);
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Polygon Query API | IMPLEMENTED | `src/clients/node/src/geo.ts`, `src/clients/python/src/archerdb/types.py`, `src/clients/rust/src/lib.rs` |
| Polygon Builder API | IMPLEMENTED | `src/geo_state_machine.zig` |
| Winding Order Helpers | IMPLEMENTED | `src/geo_state_machine.zig` |
