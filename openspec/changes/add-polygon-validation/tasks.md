# Implementation Tasks: Self-Intersecting Polygon Validation

## Phase 1: Core Algorithm

### Task 1.1: Implement segment intersection check
- **Files**: All SDKs
- **Changes**:
  - Line segment intersection function
  - Handle collinear segments
  - Proper epsilon comparison
- **Validation**: Intersection detection accurate
- **Estimated effort**: 2 hours per SDK

### Task 1.2: Implement sweep line algorithm
- **Files**: All SDKs
- **Changes**:
  - Event queue (min-heap by x-coordinate)
  - Active segment set (balanced tree)
  - Intersection event handling
- **Validation**: Finds all intersections
- **Estimated effort**: 3 hours per SDK

### Task 1.3: Optimize for common case
- **Files**: All SDKs
- **Changes**:
  - Fast path for no intersections
  - Early termination options
  - Bounding box pre-check
- **Validation**: <1ms for typical polygons
- **Estimated effort**: 1 hour per SDK

## Phase 2: SDK Integration

### Task 2.1: Add validation configuration
- **Files**: All SDKs
- **Changes**:
  - `PolygonValidation` enum (none, warn, strict)
  - Client constructor option
  - Per-query override
- **Validation**: Configuration works
- **Estimated effort**: 1 hour per SDK

### Task 2.2: Integrate with query methods
- **Files**: All SDKs
- **Changes**:
  - Validate polygon before query
  - Apply configured mode
  - Handle warnings vs errors
- **Validation**: Validation triggers correctly
- **Estimated effort**: 1 hour per SDK

### Task 2.3: Implement error types
- **Files**: All SDKs
- **Changes**:
  - `SelfIntersectionError` exception/error
  - Include segment indices and coordinates
  - Useful error message format
- **Validation**: Errors are informative
- **Estimated effort**: 30 minutes per SDK

## Phase 3: Error Messages

### Task 3.1: Format intersection details
- **Files**: All SDKs
- **Changes**:
  - Include all intersection points
  - Format coordinates appropriately
  - Include segment indices
- **Validation**: Messages are clear
- **Estimated effort**: 30 minutes per SDK

### Task 3.2: Add repair suggestions
- **Files**: All SDKs
- **Changes**:
  - Check if removing vertex fixes issue
  - Suggest simplest fix
  - Optional repair hints
- **Validation**: Suggestions are helpful
- **Estimated effort**: 1 hour per SDK

## Phase 4: Testing

### Task 4.1: Unit tests for algorithm
- **Files**: All SDKs
- **Tests**:
  - Simple bow-tie polygon
  - Complex multi-intersection
  - Valid polygons (no false positives)
  - Edge cases (collinear, near-intersection)
- **Validation**: All tests pass
- **Estimated effort**: 2 hours per SDK

### Task 4.2: Integration tests
- **Files**: All SDKs
- **Tests**:
  - Strict mode rejects invalid
  - Warn mode logs and proceeds
  - None mode allows through
- **Validation**: Modes work correctly
- **Estimated effort**: 1 hour per SDK

### Task 4.3: Performance tests
- **Files**: All SDKs
- **Tests**:
  - 100-vertex polygon <1ms
  - 10,000-vertex polygon reasonable
  - Memory usage acceptable
- **Validation**: Performance targets met
- **Estimated effort**: 1 hour per SDK

## Phase 5: Documentation

### Task 5.1: API documentation
- **Files**: SDK documentation
- **Changes**:
  - Document validation modes
  - Error type documentation
  - Configuration examples
- **Validation**: Docs complete
- **Estimated effort**: 1 hour

### Task 5.2: Best practices guide
- **File**: Documentation
- **Changes**:
  - Common polygon issues
  - How to debug self-intersections
  - Migration guide for existing code
- **Validation**: Guide helpful
- **Estimated effort**: 1 hour

## Dependencies

- Phase 2 depends on Phase 1
- Phases 3-5 depend on Phase 2

## Estimated Total Effort

Assuming 6 SDKs (Node, Python, Rust, Go, Java, .NET):

- **Core Algorithm**: 6 hours per SDK × 6 = 36 hours
- **SDK Integration**: 2.5 hours per SDK × 6 = 15 hours
- **Error Messages**: 1.5 hours per SDK × 6 = 9 hours
- **Testing**: 4 hours per SDK × 6 = 24 hours
- **Documentation**: 2 hours
- **Total**: ~86 hours (~11 working days)

Note: Some work can be parallelized across SDKs.

## Verification Checklist

- [x] Segment intersection algorithm detects all intersections (O(n²) used instead of sweep line for simplicity)
- [x] No false positives on valid polygons (tested with squares, triangles, pentagons, concave L-shapes)
- [x] Validation fast for typical polygons (O(n²) acceptable for polygon sizes < 1000)
- [x] raiseOnError=true rejects invalid polygons with PolygonValidationError
- [x] raiseOnError=false returns list of intersections (for inspection)
- [x] Error messages include segment indices and intersection point
- [ ] Repair suggestions when applicable (deferred - not critical)
- [x] All SDKs implement consistently (Python, Rust, Node, Java, Go, .NET)
- [ ] Documentation explains usage (deferred)

### SDK Implementation Status
- [x] Python: `validate_polygon_no_self_intersection()`, `PolygonValidationError`, 11 unit tests
- [x] Rust: `validate_polygon_no_self_intersection()`, `PolygonValidationError`, 12 unit tests
- [x] Node: `validatePolygonNoSelfIntersection()`, `PolygonValidationError`, 10 unit tests
- [x] Java: `PolygonValidation.validatePolygonNoSelfIntersection()`, `PolygonValidationException`, 10 unit tests
- [x] Go: `ValidatePolygonNoSelfIntersection()`, `PolygonValidationError`, 11 unit tests
- [x] .NET: `PolygonValidation.ValidatePolygonNoSelfIntersection()`, `PolygonValidationException`, 12 unit tests
