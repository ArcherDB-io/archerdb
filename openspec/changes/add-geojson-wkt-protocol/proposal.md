# Proposal: GeoJSON/WKT Wire Protocol Support

## Summary

Add SDK-level support for GeoJSON and WKT (Well-Known Text) formats, allowing developers to use standard geospatial formats while SDKs handle conversion to ArcherDB's internal format.

## Motivation

### Problem

ArcherDB uses a custom binary format (nanodegrees, S2 cells) for optimal performance. However, most geospatial data comes in standard formats:

- **GeoJSON**: Web APIs, Mapbox, OpenStreetMap exports
- **WKT**: PostGIS, Oracle Spatial, industry standard

Currently, developers must manually convert:

```python
# Manual conversion required
import json
geojson = json.loads('{"type":"Point","coordinates":[-122.4194,37.7749]}')
lat_nano = int(geojson['coordinates'][1] * 1e9)
lon_nano = int(geojson['coordinates'][0] * 1e9)
client.insert_event(lat_nano=lat_nano, lon_nano=lon_nano, ...)
```

This is error-prone and tedious.

### Current Behavior

- SDKs only accept nanodegree coordinates
- No GeoJSON/WKT parsing
- Manual conversion required for all data
- Query results return nanodegrees only

### Desired Behavior

- **GeoJSON input**: Accept GeoJSON geometry in insert/query
- **WKT input**: Accept WKT strings in insert/query
- **Output conversion**: Optionally return results as GeoJSON
- **Automatic conversion**: SDKs handle all format conversion

## Scope

### In Scope

1. **GeoJSON parsing**: Point, Polygon, LineString geometries
2. **WKT parsing**: POINT, POLYGON, LINESTRING
3. **Output formatting**: Convert results to GeoJSON
4. **SDK convenience methods**: Fluent APIs for format handling

### Out of Scope

1. **Wire protocol changes**: SDKs convert, protocol unchanged
2. **GeoJSON Feature/FeatureCollection**: Just geometry types
3. **Complex WKT types**: Focus on basic geometries
4. **Validation of exotic geometries**: Basic validation only

## Success Criteria

1. **Developer convenience**: Use GeoJSON directly, no manual conversion
2. **Zero overhead option**: Can still use raw nanodegrees
3. **Format correctness**: Conversion preserves precision

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Precision loss | Coordinate rounding | Document nanodegree precision limits |
| Parser complexity | SDK bloat | Use established libraries where available |
| Performance overhead | Latency increase | Lazy parsing, optional usage |

## Stakeholders

- **Web developers**: Native GeoJSON from JavaScript APIs
- **GIS professionals**: Native WKT from existing tools
- **Data engineers**: Easier data pipeline integration
