# Tasks: Add Polygon Hole Support

## Status: COMPLETE ✓

All tasks completed including core implementation, client SDKs (Node.js, Python, Go, Java, .NET, C), tests, benchmarks, and documentation.

## 1. Wire Format Changes ✓

- [x] 1.1 Add `hole_count` field to `QueryPolygonFilter` in `src/geo_state_machine.zig`
- [x] 1.2 Create `HoleDescriptor` struct (8 bytes: vertex_count + reserved)
- [x] 1.3 Update validation to include hole vertex limits
- [x] 1.4 Add `polygon_holes_max` constant (100) to `src/constants.zig`
- [x] 1.5 Add `polygon_hole_vertices_min` constant (3) to `src/constants.zig`

## 2. Algorithm Implementation ✓

- [x] 2.1 Create `pointInPolygonWithHoles()` in `src/s2_index.zig`
- [x] 2.2 Create `checkPolygonWithHoles()` in post-filter
- [x] 2.3 Create `filterPolygonCandidateWithHoles()` in post-filter
- [x] 2.4 Add `excluded_by_hole` stat tracking
- [x] 2.5 Add bounding box helper functions (`BoundingBox`, `getPolygonBoundingBox`)
- [x] 2.6 Add winding order helpers (`signedArea`, `isClockwise`, `isCounterClockwise`)
- [x] 2.7 Add hole validation helpers (`isHoleContained`, `doHolesBoundingBoxesOverlap`)

## 3. Message Parsing Integration ✓

- [x] 3.1 Parse hole descriptors in `execute_query_polygon()`
- [x] 3.2 Parse hole vertices in `execute_query_polygon()`
- [x] 3.3 Validate hole count (max 100)
- [x] 3.4 Validate hole vertex counts (min 3 per hole)
- [x] 3.5 Calculate total message size including holes
- [x] 3.6 Convert holes to LatLon format for post-filter
- [x] 3.7 Call `pointInPolygonWithHoles()` when holes present

## 4. Error Codes ✓

- [x] 4.1 Add error code 117: `too_many_holes`
- [x] 4.2 Add error code 118: `hole_vertex_count_invalid`
- [x] 4.3 Add error code 119: `hole_not_contained`
- [x] 4.4 Add error code 120: `holes_overlap`
- [x] 4.5 Add descriptions for error codes
- [x] 4.6 Add unit tests for error codes

## 5. Public API Exports ✓

- [x] 5.1 Export `HoleDescriptor` from `src/archerdb.zig`

## 6. Testing ✓

- [x] 6.1 Unit tests for `pointInPolygonWithHoles()` (5 test cases)
- [x] 6.2 Unit tests for `BoundingBox.containsPoint()`
- [x] 6.3 Unit tests for `getPolygonBoundingBox()`
- [x] 6.4 Unit tests for winding order (`signedArea`)
- [x] 6.5 Unit tests for error codes 117-120
- [x] 6.6 Wire format size tests (`HoleDescriptor`, `QueryPolygonFilter`)
- [x] 6.7 Wire format calculation test

## 7. Auxiliary Updates ✓

- [x] 7.1 Update `geo_workload.zig` for new reserved size (88 bytes)
- [x] 7.2 Add `hole_count = 0` to test polygon queries
- [x] 7.3 Update `geo_benchmark_load.zig` with `hole_count = 0`

## 8. Client SDK Updates ✓

- [x] 8.1 Node.js SDK (`src/clients/node/src/geo.ts`)
  - Added POLYGON_HOLES_MAX, POLYGON_HOLE_VERTICES_MIN constants
  - Added PolygonHole type and holes field to QueryPolygonFilter
  - Updated createPolygonQuery() with hole validation
- [x] 8.2 Python SDK (`src/clients/python/src/archerdb/`)
  - Added PolygonHole dataclass and constants
  - Updated create_polygon_query() with holes parameter
  - Added SDK unit tests for polygon holes
- [x] 8.3 Go SDK (`src/clients/go/pkg/types/`)
  - Added PolygonHole struct and constants
  - Updated NewPolygonQuery() with variadic holes parameter
  - Added Go unit tests and benchmarks
- [x] 8.4 Java SDK (`src/clients/java/`)
  - Added PolygonHole inner class to QueryPolygonFilter
  - Added Builder methods: startHole(), addHoleVertex(), finishHole(), addHole()
  - Added constants to CoordinateUtils
- [x] 8.5 .NET SDK (auto-generated from Zig types)
- [x] 8.6 C header exports (`src/clients/c/`)
  - Added hole_descriptor_t export

## 9. Testing ✓

- [x] 9.1 Python SDK unit tests for polygon holes
- [x] 9.2 Go SDK unit tests for polygon holes
- [x] 9.3 Go SDK benchmarks for polygon queries with holes

## 10. Documentation ✓

- [x] 10.1 Update API reference for polygon holes
- [x] 10.2 Add usage examples to SDK documentation (docs/getting-started.md)

## Files Modified

| File | Changes |
|------|---------|
| `src/geo_state_machine.zig` | QueryPolygonFilter.hole_count, HoleDescriptor, execute_query_polygon hole parsing |
| `src/constants.zig` | polygon_holes_max, polygon_hole_vertices_min |
| `src/s2_index.zig` | pointInPolygonWithHoles, BoundingBox, validation helpers, winding order |
| `src/post_filter.zig` | checkPolygonWithHoles, filterPolygonCandidateWithHoles, excluded_by_hole |
| `src/archerdb.zig` | Export HoleDescriptor |
| `src/error_codes.zig` | Error codes 117-120 with descriptions |
| `src/testing/geo_workload.zig` | Updated reserved size, added hole_count |
| `src/archerdb/geo_benchmark_load.zig` | Added hole_count = 0 |
| `src/clients/node/src/geo.ts` | PolygonHole type, holes validation |
| `src/clients/python/src/archerdb/types.py` | PolygonHole dataclass, hole validation |
| `src/clients/python/src/archerdb/client.py` | holes parameter in query_polygon |
| `src/clients/python/src/archerdb/test_archerdb.py` | Polygon hole unit tests |
| `src/clients/go/pkg/types/geo_event.go` | PolygonHole struct, hole constants |
| `src/clients/go/pkg/types/geo_event_test.go` | Polygon hole tests and benchmarks |
| `src/clients/java/.../QueryPolygonFilter.java` | PolygonHole class, Builder updates |
| `src/clients/java/.../CoordinateUtils.java` | Hole constants |
| `src/clients/c/arch_client_exports.zig` | hole_descriptor_t export |
| `src/clients/c/arch_client_header.zig` | hole_descriptor_t mapping |
