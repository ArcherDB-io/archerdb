# Design: GeoJSON/WKT Wire Protocol Support

## Context

ArcherDB uses nanodegrees (10^-9 degrees) for maximum precision with integer arithmetic. Standard formats like GeoJSON use decimal degrees (float64). SDKs should bridge this gap transparently.

## Goals / Non-Goals

### Goals

1. **Accept standard formats**: GeoJSON and WKT in SDK APIs
2. **Transparent conversion**: SDK handles all format translation
3. **Optional formatting**: Return results as GeoJSON if requested

### Non-Goals

1. **Wire protocol changes**: Keep binary protocol efficient
2. **Full GeoJSON spec**: Focus on geometries, not Features
3. **Complex WKT**: Basic types only

## Decisions

### Decision 1: SDK-Level Conversion Only

**Choice**: SDKs convert formats; wire protocol unchanged.

**Rationale**:
- Wire protocol optimized for performance
- Conversion overhead only when needed
- Simpler server implementation

**Implementation**:
```
┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│  GeoJSON/WKT   │───>│      SDK       │───>│  Wire Protocol │
│    (input)     │    │  (conversion)  │    │  (nanodegrees) │
└────────────────┘    └────────────────┘    └────────────────┘
```

### Decision 2: Overloaded API Methods

**Choice**: Provide method overloads/variants for format acceptance.

**Rationale**:
- Clear API surface
- Type safety where supported
- No breaking changes to existing API

**Implementation**:
```python
# Existing API (unchanged)
client.insert_event(lat_nano=37_774900000, lon_nano=-122_419400000, ...)

# New GeoJSON API
client.insert_event_geojson(
    geometry={"type": "Point", "coordinates": [-122.4194, 37.7749]},
    entity_id="...",
    ...
)

# New WKT API
client.insert_event_wkt(
    geometry="POINT(-122.4194 37.7749)",
    entity_id="...",
    ...
)
```

### Decision 3: Builder Pattern for Convenience

**Choice**: Fluent builder for constructing queries with format conversion.

**Rationale**:
- Readable code
- IDE auto-completion
- Clear conversion points

**Implementation**:
```python
# Fluent query building
result = client.query() \
    .polygon_geojson({
        "type": "Polygon",
        "coordinates": [[[-122.5, 37.7], [-122.4, 37.7], ...]]
    }) \
    .limit(100) \
    .output_format("geojson") \
    .execute()

# result.geometry is GeoJSON, not nanodegrees
```

### Decision 4: Precision Handling

**Choice**: Document precision limits; use banker's rounding.

**Rationale**:
- Nanodegrees provide ~0.1mm precision
- Float64 GeoJSON has ~1mm precision at equator
- No practical precision loss for GPS data

**Implementation**:
```python
def degrees_to_nano(degrees: float) -> int:
    """Convert decimal degrees to nanodegrees with banker's rounding."""
    return round(degrees * 1_000_000_000)  # Python uses banker's rounding

def nano_to_degrees(nano: int) -> float:
    """Convert nanodegrees to decimal degrees."""
    return nano / 1_000_000_000
```

## Architecture

### Conversion Pipeline

```
GeoJSON Input                    SDK Conversion                 Wire Format
─────────────────────────────────────────────────────────────────────────────

{"type": "Point",          ┌─────────────────────┐      lat_nano: 37774900000
 "coordinates":            │  Parse GeoJSON      │      lon_nano: -122419400000
   [-122.4194, 37.7749]}   │  Extract coords     │
        │                  │  Convert to nano    │
        └─────────────────>│  Validate bounds    │─────────────────────────────>
                           └─────────────────────┘


WKT Input                        SDK Conversion                 Wire Format
─────────────────────────────────────────────────────────────────────────────

"POINT(-122.4194 37.7749)" ┌─────────────────────┐      lat_nano: 37774900000
        │                  │  Parse WKT          │      lon_nano: -122419400000
        └─────────────────>│  Extract coords     │
                           │  Convert to nano    │─────────────────────────────>
                           │  Validate bounds    │
                           └─────────────────────┘
```

### Output Formatting

```
Wire Format                      SDK Conversion                 GeoJSON Output
─────────────────────────────────────────────────────────────────────────────

lat_nano: 37774900000      ┌─────────────────────┐      {"type": "Point",
lon_nano: -122419400000    │  Convert from nano  │       "coordinates":
        │                  │  Build GeoJSON      │         [-122.4194, 37.7749]}
        └─────────────────>│  Format output      │─────────────────────────────>
                           └─────────────────────┘
```

## Configuration

### SDK Options

```python
# Client-level default output format
client = ArcherDBClient(
    default_output_format="geojson"  # or "nanodegrees" (default)
)

# Query-level override
result = client.query_radius(
    center_geojson={"type": "Point", "coordinates": [lon, lat]},
    radius_m=1000,
    output_format="geojson"
)
```

### Supported Formats

| Format | Input Types | Output Types |
|--------|-------------|--------------|
| GeoJSON | Point, Polygon, LineString | Point, Polygon |
| WKT | POINT, POLYGON, LINESTRING | POINT, POLYGON |
| Nanodegrees | int64 lat/lon | int64 lat/lon |

## Trade-Offs

### SDK Size vs Convenience

| Approach | SDK Size | Convenience |
|----------|----------|-------------|
| No conversion | Minimal | Low |
| Optional conversion (chosen) | Moderate | High |
| Full GeoJSON support | Large | Very high |

**Chose optional conversion**: Good balance of size and convenience.

## Validation Plan

### Unit Tests

1. **GeoJSON parsing**: All geometry types parse correctly
2. **WKT parsing**: All supported types parse correctly
3. **Conversion accuracy**: Round-trip preserves precision
4. **Invalid input**: Rejects malformed input

### Integration Tests

1. **Insert GeoJSON**: Data stored correctly
2. **Query GeoJSON**: Results formatted correctly
3. **Mixed formats**: GeoJSON input, WKT output

### Performance Tests

1. **Conversion overhead**: Measure parsing time
2. **Memory usage**: Ensure no leaks
3. **Comparison**: With vs without conversion
