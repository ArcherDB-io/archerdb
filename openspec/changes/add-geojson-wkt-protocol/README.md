# Change: GeoJSON/WKT Wire Protocol Support

SDK-level support for standard geospatial formats.

## Status: Draft

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design
- [tasks.md](tasks.md) - Implementation tasks (~120 hours)

## Spec Deltas

- [specs/client-protocol/spec.md](specs/client-protocol/spec.md) - Format parsing, output options

## Summary

Accept GeoJSON and WKT formats directly in SDK APIs:

```python
# Before: Manual conversion required
lat_nano = int(37.7749 * 1e9)
lon_nano = int(-122.4194 * 1e9)
client.insert_event(lat_nano=lat_nano, lon_nano=lon_nano, ...)

# After: Native GeoJSON support
client.insert_event_geojson(
    geometry={"type": "Point", "coordinates": [-122.4194, 37.7749]},
    ...
)

# Or WKT
client.insert_event_wkt(
    geometry="POINT(-122.4194 37.7749)",
    ...
)
```

## Supported Formats

| Format | Input | Output |
|--------|-------|--------|
| GeoJSON Point | Yes | Yes |
| GeoJSON Polygon | Yes | Yes |
| WKT POINT | Yes | Yes |
| WKT POLYGON | Yes | Yes |
| Nanodegrees | Yes (existing) | Yes (default) |

## Output Formatting

```python
# Return results as GeoJSON
result = client.query_radius(
    center_geojson={"type": "Point", "coordinates": [lon, lat]},
    radius_m=1000,
    output_format="geojson"
)

# result.events[0].geometry is GeoJSON
```

## Precision

- **Nanodegrees**: 10^-9 degrees ≈ 0.1mm precision
- **GeoJSON/WKT**: float64 ≈ 1mm precision at equator
- **Round-trip**: Preserves 9+ decimal places

## Key Design Decisions

1. **SDK-only conversion**: Wire protocol unchanged
2. **Overloaded methods**: `insert_event_geojson()`, `insert_event_wkt()`
3. **Banker's rounding**: Consistent decimal-to-integer conversion
4. **Optional output format**: Per-query or client-level configuration
