# Client Protocol - GeoJSON/WKT Support

## ADDED Requirements

### Requirement: GeoJSON Input Support

Client SDKs SHALL accept GeoJSON geometry objects for input.

#### Scenario: GeoJSON Point input

- **WHEN** inserting event with GeoJSON Point
- **THEN** SDK SHALL accept:
  ```json
  {
    "type": "Point",
    "coordinates": [-122.4194, 37.7749]
  }
  ```
- **AND** SDK SHALL convert to nanodegrees:
  - `lon_nano = coordinates[0] * 1e9`
  - `lat_nano = coordinates[1] * 1e9`
- **AND** coordinate order SHALL be [longitude, latitude] per GeoJSON spec

#### Scenario: GeoJSON Polygon input

- **WHEN** querying with GeoJSON Polygon
- **THEN** SDK SHALL accept:
  ```json
  {
    "type": "Polygon",
    "coordinates": [[
      [-122.5, 37.7],
      [-122.4, 37.7],
      [-122.4, 37.8],
      [-122.5, 37.8],
      [-122.5, 37.7]
    ]]
  }
  ```
- **AND** SDK SHALL convert all vertices to nanodegrees
- **AND** first ring SHALL be exterior, subsequent rings SHALL be holes

#### Scenario: GeoJSON validation

- **WHEN** GeoJSON input is invalid
- **THEN** SDK SHALL reject with error:
  - Missing `type` field: "GeoJSON must have 'type' field"
  - Missing `coordinates`: "GeoJSON must have 'coordinates' field"
  - Invalid coordinate count: "Point must have 2 coordinates [lon, lat]"
  - Out of bounds: "Longitude must be between -180 and 180"

### Requirement: WKT Input Support

Client SDKs SHALL accept Well-Known Text (WKT) geometry strings.

#### Scenario: WKT Point input

- **WHEN** inserting event with WKT Point
- **THEN** SDK SHALL accept:
  ```
  POINT(-122.4194 37.7749)
  ```
- **AND** SDK SHALL convert to nanodegrees
- **AND** coordinate order SHALL be (longitude latitude) per WKT spec

#### Scenario: WKT Polygon input

- **WHEN** querying with WKT Polygon
- **THEN** SDK SHALL accept:
  ```
  POLYGON((-122.5 37.7, -122.4 37.7, -122.4 37.8, -122.5 37.8, -122.5 37.7))
  ```
- **AND** SDK SHALL convert all vertices to nanodegrees
- **AND** rings SHALL be comma-separated within parentheses

#### Scenario: WKT validation

- **WHEN** WKT input is invalid
- **THEN** SDK SHALL reject with error:
  - Unknown type: "Unknown WKT type: MULTIPOINT"
  - Syntax error: "WKT syntax error at position 15"
  - Unclosed ring: "Polygon ring must be closed"

### Requirement: Output Format Selection

Client SDKs SHALL support selecting output coordinate format.

#### Scenario: GeoJSON output

- **WHEN** output format is "geojson"
- **THEN** SDK SHALL return coordinates as:
  ```python
  {
      "type": "Point",
      "coordinates": [-122.4194, 37.7749]
  }
  ```
- **AND** coordinates SHALL be decimal degrees

#### Scenario: WKT output

- **WHEN** output format is "wkt"
- **THEN** SDK SHALL return coordinates as:
  ```
  POINT(-122.4194 37.7749)
  ```

#### Scenario: Nanodegrees output (default)

- **WHEN** output format is "nanodegrees" or unspecified
- **THEN** SDK SHALL return raw nanodegree values:
  ```python
  lat_nano: 37774900000
  lon_nano: -122419400000
  ```

### Requirement: Format Conversion Precision

Client SDKs SHALL preserve precision during format conversion.

#### Scenario: Precision preservation

- **WHEN** converting between formats
- **THEN** precision SHALL be:
  - Nanodegrees: exact integer (10^-9 degrees ≈ 0.1mm)
  - GeoJSON/WKT: float64 (15-17 significant digits)
- **AND** round-trip conversion SHALL preserve at least 9 decimal places

#### Scenario: Rounding behavior

- **WHEN** converting decimal to nanodegrees
- **THEN** SDK SHALL use banker's rounding (round half to even)
- **AND** document any precision limitations

### Requirement: Convenience API Methods

Client SDKs SHALL provide format-specific API methods.

#### Scenario: GeoJSON methods

- **WHEN** using GeoJSON input
- **THEN** SDK SHALL provide:
  ```python
  client.insert_event_geojson(geometry=geojson_point, ...)
  client.query_radius_geojson(center=geojson_point, ...)
  client.query_polygon_geojson(polygon=geojson_polygon)
  ```

#### Scenario: WKT methods

- **WHEN** using WKT input
- **THEN** SDK SHALL provide:
  ```python
  client.insert_event_wkt(geometry="POINT(...)", ...)
  client.query_radius_wkt(center="POINT(...)", ...)
  client.query_polygon_wkt(polygon="POLYGON(...)")
  ```

#### Scenario: Output format configuration

- **WHEN** configuring client
- **THEN** SDK SHALL accept:
  ```python
  client = ArcherDBClient(
      default_output_format="geojson"  # "geojson", "wkt", "nanodegrees"
  )
  ```
- **AND** per-query override SHALL be supported

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| GeoJSON Input Support | IMPLEMENTED | All SDKs parse GeoJSON Point and Polygon |
| WKT Input Support | IMPLEMENTED | All SDKs parse WKT POINT and POLYGON |
| Output Format Selection | IMPLEMENTED | Configurable output: geojson, wkt, nanodegrees |
| Format Conversion Precision | IMPLEMENTED | Full precision preservation with banker's rounding |
| Convenience API Methods | IMPLEMENTED | Format-specific methods in all SDKs |

**SDK Implementation Locations:**
- Python: `src/clients/python/src/archerdb/types.py`
- Go: `src/clients/go/pkg/types/geo_format.go`
- Rust: `src/clients/rust/src/lib.rs`
- Java: `src/clients/java/src/main/java/com/archerdb/geo/GeoFormatParser.java`
- .NET: `src/clients/dotnet/ArcherDB/GeoFormatTypes.cs`
- Node: `src/clients/node/src/geo.ts`

## Related Specifications

- See base `client-protocol/spec.md` for wire protocol
- See `data-model/spec.md` for nanodegree format
- See `client-sdk/spec.md` for SDK requirements
