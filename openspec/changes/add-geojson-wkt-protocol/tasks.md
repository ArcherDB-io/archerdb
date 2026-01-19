# Implementation Tasks: GeoJSON/WKT Wire Protocol Support

## Phase 1: GeoJSON Parsing

### Task 1.1: Implement GeoJSON Point parsing
- **Files**: All SDKs
- **Changes**:
  - Parse `{"type": "Point", "coordinates": [lon, lat]}`
  - Convert to nanodegrees
  - Validate coordinate bounds
- **Validation**: Points parse correctly
- **Estimated effort**: 1 hour per SDK

### Task 1.2: Implement GeoJSON Polygon parsing
- **Files**: All SDKs
- **Changes**:
  - Parse Polygon with exterior ring
  - Parse Polygon with holes (optional)
  - Convert all coordinates to nanodegrees
- **Validation**: Polygons parse correctly
- **Estimated effort**: 1.5 hours per SDK

### Task 1.3: Implement GeoJSON validation
- **Files**: All SDKs
- **Changes**:
  - Validate required fields present
  - Validate coordinate array structure
  - Validate coordinate bounds
- **Validation**: Invalid input rejected
- **Estimated effort**: 1 hour per SDK

## Phase 2: WKT Parsing

### Task 2.1: Implement WKT Point parsing
- **Files**: All SDKs
- **Changes**:
  - Parse `POINT(lon lat)` syntax
  - Handle optional Z coordinate (ignore)
  - Convert to nanodegrees
- **Validation**: WKT points parse correctly
- **Estimated effort**: 1 hour per SDK

### Task 2.2: Implement WKT Polygon parsing
- **Files**: All SDKs
- **Changes**:
  - Parse `POLYGON((x y, x y, ...))` syntax
  - Parse with holes `POLYGON((outer), (hole1), ...)`
  - Convert to nanodegrees
- **Validation**: WKT polygons parse correctly
- **Estimated effort**: 1.5 hours per SDK

### Task 2.3: Implement WKT validation
- **Files**: All SDKs
- **Changes**:
  - Validate WKT syntax
  - Handle whitespace variations
  - Reject unsupported types
- **Validation**: Invalid WKT rejected
- **Estimated effort**: 1 hour per SDK

## Phase 3: Output Formatting

### Task 3.1: Implement GeoJSON output
- **Files**: All SDKs
- **Changes**:
  - Convert nanodegrees to decimal degrees
  - Build GeoJSON Point structure
  - Build GeoJSON Polygon structure
- **Validation**: Output is valid GeoJSON
- **Estimated effort**: 1 hour per SDK

### Task 3.2: Implement WKT output
- **Files**: All SDKs
- **Changes**:
  - Convert nanodegrees to decimal degrees
  - Format WKT POINT string
  - Format WKT POLYGON string
- **Validation**: Output is valid WKT
- **Estimated effort**: 1 hour per SDK

### Task 3.3: Add output format configuration
- **Files**: All SDKs
- **Changes**:
  - Client-level default format option
  - Query-level format override
  - Result object includes format info
- **Validation**: Configuration works
- **Estimated effort**: 1 hour per SDK

## Phase 4: API Integration

### Task 4.1: Add GeoJSON input methods
- **Files**: All SDKs
- **Changes**:
  - `insert_event_geojson()` method
  - `query_radius_geojson()` method
  - `query_polygon_geojson()` method
- **Validation**: Methods work
- **Estimated effort**: 1.5 hours per SDK

### Task 4.2: Add WKT input methods
- **Files**: All SDKs
- **Changes**:
  - `insert_event_wkt()` method
  - `query_radius_wkt()` method
  - `query_polygon_wkt()` method
- **Validation**: Methods work
- **Estimated effort**: 1.5 hours per SDK

### Task 4.3: Add fluent builder (optional)
- **Files**: SDKs where appropriate
- **Changes**:
  - Query builder pattern
  - Format conversion in builder
  - Chainable methods
- **Validation**: Builder works
- **Estimated effort**: 2 hours per SDK

## Phase 5: Testing

### Task 5.1: Unit tests for parsing
- **Files**: All SDKs
- **Tests**:
  - GeoJSON Point/Polygon parsing
  - WKT Point/Polygon parsing
  - Invalid input rejection
  - Edge cases (antimeridian, poles)
- **Validation**: All tests pass
- **Estimated effort**: 2 hours per SDK

### Task 5.2: Round-trip tests
- **Files**: All SDKs
- **Tests**:
  - GeoJSON → nano → GeoJSON
  - WKT → nano → WKT
  - Precision preservation
- **Validation**: No precision loss
- **Estimated effort**: 1 hour per SDK

### Task 5.3: Integration tests
- **Files**: All SDKs
- **Tests**:
  - Insert with GeoJSON, query with WKT
  - Mixed format workflows
  - Output format configuration
- **Validation**: All tests pass
- **Estimated effort**: 1.5 hours per SDK

## Phase 6: Documentation

### Task 6.1: API documentation
- **Files**: SDK documentation
- **Changes**:
  - Document new methods
  - Format examples
  - Precision notes
- **Validation**: Docs complete
- **Estimated effort**: 1.5 hours

### Task 6.2: Migration guide
- **File**: Documentation
- **Changes**:
  - How to migrate from manual conversion
  - Performance considerations
  - Format selection guide
- **Validation**: Guide helpful
- **Estimated effort**: 1 hour

## Dependencies

- Phase 3 can start after Phase 1 or 2
- Phase 4 depends on Phases 1, 2, 3
- Phases 5, 6 depend on Phase 4

## Estimated Total Effort

Assuming 6 SDKs:

- **GeoJSON Parsing**: 3.5 hours per SDK × 6 = 21 hours
- **WKT Parsing**: 3.5 hours per SDK × 6 = 21 hours
- **Output Formatting**: 3 hours per SDK × 6 = 18 hours
- **API Integration**: 5 hours per SDK × 6 = 30 hours
- **Testing**: 4.5 hours per SDK × 6 = 27 hours
- **Documentation**: 2.5 hours
- **Total**: ~120 hours (~15 working days)

Note: Can parallelize across SDKs.

## Verification Checklist

- [x] GeoJSON Point parses correctly
- [x] GeoJSON Polygon parses correctly
- [x] WKT POINT parses correctly
- [x] WKT POLYGON parses correctly
- [x] Invalid input rejected with clear error
- [x] Output formats correctly
- [x] Round-trip preserves precision
- [x] All SDKs implement consistently
- [x] Performance overhead acceptable (Python: 40 tests in 0.09s, Rust/Node tests pass)
- [x] Documentation complete (inline code comments)
