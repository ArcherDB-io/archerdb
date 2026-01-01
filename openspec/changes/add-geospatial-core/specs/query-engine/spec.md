# Query Engine Specification

## ADDED Requirements

### Requirement: Three-Phase Execution Model

The system SHALL implement TigerBeetle's three-phase execution model: prepare, prefetch, and commit (execute) to ensure deterministic behavior and optimal I/O patterns.

#### Scenario: Phase ordering

- **WHEN** a request is processed
- **THEN** it SHALL pass through phases in order:
  1. **Prepare**: Calculate timestamps (primary only, before consensus)
  2. **Prefetch**: Load required data into cache (async I/O)
  3. **Commit/Execute**: Apply state changes (deterministic, after consensus)

#### Scenario: Prepare phase

- **WHEN** `state_machine.prepare(operation, body)` is called
- **THEN** it SHALL calculate `delta_nanoseconds` based on operation and batch size
- **AND** it SHALL advance `prepare_timestamp += delta_nanoseconds`
- **AND** this runs BEFORE consensus (only on primary converting request to prepare)

#### Scenario: Prefetch phase

- **WHEN** `state_machine.prefetch(callback, op, operation, body)` is called
- **THEN** it SHALL asynchronously load required data from LSM tree
- **AND** it SHALL invoke callback when prefetch is complete
- **AND** this ensures cache hits during execute phase

#### Scenario: Commit/Execute phase

- **WHEN** `state_machine.commit(client, op, timestamp, operation, body, output)` is called
- **THEN** it SHALL execute state machine logic using the consensus-assigned timestamp
- **AND** it SHALL return bytes written to output buffer
- **AND** all replicas MUST produce identical results for identical inputs

### Requirement: Multi-Batch Processing

The system SHALL support packing multiple independent batches into a single VSR message to amortize consensus costs.

#### Scenario: Multi-batch encoding

- **WHEN** multiple batches are encoded
- **THEN** they SHALL be packed as:
  - Payload: Concatenated batch data
  - Trailer: Array of u16 batch sizes + u16 batch count (from end of message)
- **AND** trailer is written backwards from message end

#### Scenario: Trailer structure

- **WHEN** a multi-batch message is created
- **THEN** the trailer SHALL contain:
  - Padding bytes (0xFF) for alignment to event size
  - Per-batch item counts as u16 (max 65534)
  - Postamble: total batch count as u16

#### Scenario: Multi-batch decoding

- **WHEN** decoding a multi-batch message
- **THEN** the MultiBatchDecoder SHALL:
  - Parse postamble from message end
  - Extract batch counts from trailer
  - Validate padding is 0xFF bytes
  - Provide iterator interface to pop batches

#### Scenario: Execute multi-batch

- **WHEN** executing a multi-batch message
- **THEN** each batch SHALL be executed sequentially
- **AND** timestamps SHALL be distributed across batches deterministically
- **AND** replies SHALL be encoded in same multi-batch format

### Requirement: S2 Spatial Indexing

The system SHALL use Google S2 geometry library for spatial indexing and query decomposition.

#### Scenario: Server-side S2 cell computation (security)

- **WHEN** GeoEvents are validated during input_valid() phase
- **THEN** the server SHALL compute s2_cell_id from lat_nano and lon_nano
- **AND** the server SHALL construct the composite ID: `id = (s2_cell_id << 64) | timestamp_ns`
- **AND** any client-provided ID value SHALL be overwritten with server-computed value
- **AND** this prevents clients from corrupting the spatial index with incorrect S2 cells
- **AND** ensures all spatial queries work correctly

#### Scenario: Coordinate to cell conversion

- **WHEN** a lat/lon coordinate is indexed
- **THEN** it SHALL be converted to an S2 cell ID at level 30 (maximum precision)
- **AND** the cell ID SHALL be a 64-bit unsigned integer
- **AND** conversion uses: `S2.lat_lon_to_cell_id(lat_nano, lon_nano, 30)`
- **CLARIFICATION**: Storage ALWAYS uses level 30 for maximum precision (~7.5mm). The "level 18" mentioned in query decomposition is for QUERY COVERING, not storage. Queries use coarser levels (up to 18) to generate efficient cell ranges that cover the query region, then scan the level-30 data within those ranges.

#### Scenario: Cell hierarchy

- **WHEN** navigating the S2 cell hierarchy
- **THEN** the parent cell ID SHALL be obtainable by bit-shifting (truncating 2 bits per level)
- **AND** this enables efficient quad-tree traversal

#### Scenario: Region covering

- **WHEN** a polygon or circle region is queried
- **THEN** the S2 RegionCoverer SHALL decompose it into a set of cell ID ranges
- **AND** the number of cells SHALL be bounded by s2_max_cells constant (default: 16)

### Requirement: S2 Level Selection Algorithm

The system SHALL dynamically select S2 cell levels based on query area size for optimal performance.

#### Scenario: S2 level selection based on radius

- **WHEN** selecting S2 cell level for a radius query
- **THEN** the system SHALL use this algorithm:
  ```
  Level selection based on approximate cell edge length:
  Level 0:  ~7,842 km  (continental)
  Level 5:  ~245 km    (regional)
  Level 10: ~7.6 km    (city)
  Level 15: ~240 m     (neighborhood)
  Level 18: ~30 m      (building) - max level for query covering
  Level 20: ~7.5 m     (room)
  Level 25: ~0.24 m    (sub-meter)
  Level 30: ~7.5 mm    (maximum precision)

  For radius query:
  min_level = floor(log2(7842 km / radius_km))
  clamped to range [0, 30]

  Examples:
  - radius = 100 km → level 6 (cells ~120 km)
  - radius = 10 km  → level 10 (cells ~7.6 km)
  - radius = 1 km   → level 13 (cells ~950 m)
  - radius = 100 m  → level 17 (cells ~60 m)
  ```
- **AND** lower levels (larger cells) for larger areas
- **AND** higher levels (smaller cells) for smaller areas

#### Scenario: S2 level bounds for query decomposition

- **WHEN** decomposing a query region into cells
- **THEN** RegionCoverer SHALL use:
  - `min_level`: Calculated from query area (see above)
  - `max_level`: min(min_level + 4, 18) - Never go finer than storage level
  - `max_cells`: 16 (default) - Limit query complexity
- **AND** this produces efficient cell ranges without over-decomposition

### Requirement: S2 Implementation Validation

The system SHALL validate S2 implementation using known test vectors.

#### Scenario: S2 coordinate conversion test vectors

- **WHEN** validating S2 implementation
- **THEN** the following conversions SHALL produce exact results:
  ```
  # Test vectors for lat/lon → S2 cell ID at level 30

  # Equator/Prime Meridian (0°, 0°)
  lat_nano=0, lon_nano=0 → cell_id=0x1000000000000000

  # Statue of Liberty (40.689247°, -74.044502°)
  lat_nano=40689247000, lon_nano=-74044502000 → cell_id=0x89c25a11XXXXXXXXXX

  # Eiffel Tower (48.858844°, 2.294351°)
  lat_nano=48858844000, lon_nano=2294351000 → cell_id=0x47a0e9XXXXXXXXXX

  # Tokyo Tower (35.658584°, 139.745433°)
  lat_nano=35658584000, lon_nano=139745433000 → cell_id=0x6488d3XXXXXXXXXX

  # Sydney Opera House (-33.856784°, 151.215297°)
  lat_nano=-33856784000, lon_nano=151215297000 → cell_id=0x31d67aXXXXXXXXXX

  # North Pole (90°, 0°)
  lat_nano=90000000000, lon_nano=0 → cell_id=0x2bffffffffffffff

  # South Pole (-90°, 0°)
  lat_nano=-90000000000, lon_nano=0 → cell_id=0x0800000000000001
  ```
- **AND** X's represent implementation-dependent lower bits (verify face/level match)

#### Scenario: S2 distance calculation test vectors

- **WHEN** validating S2 distance calculations
- **THEN** the following distances SHALL be within 0.01% accuracy:
  ```
  # Point pairs with expected great-circle distances

  # New York → London
  (40.7128, -74.0060) → (51.5074, -0.1278)
  Expected: 5,570.22 km ± 0.5 km

  # San Francisco → Tokyo
  (37.7749, -122.4194) → (35.6762, 139.6503)
  Expected: 8,277.95 km ± 1 km

  # Nearby points (1km apart)
  (51.5074, -0.1278) → (51.5164, -0.1278)
  Expected: 1.0 km ± 0.01 km

  # Very close points (10m apart)
  (51.5074, -0.1278) → (51.5075, -0.1278)
  Expected: 11.1 m ± 0.1 m
  ```

#### Scenario: S2 cell containment test vectors

- **WHEN** validating S2 cell containment
- **THEN** these containment relationships SHALL hold:
  ```
  # Cell hierarchy validation
  cell_at_level(lat, lon, level=0).contains(cell_at_level(lat, lon, level=10)) = true
  cell_at_level(lat, lon, level=10).contains(cell_at_level(lat, lon, level=0)) = false

  # Sibling cells
  siblings(cell_at_level(lat, lon, level=5)) has exactly 4 cells

  # Face validation (S2 has 6 cube faces)
  0 <= cell_id.face() <= 5 for all valid cells
  ```

#### Scenario: Pole region query test vectors

- **WHEN** querying near or at geographic poles
- **THEN** the following test cases SHALL produce correct results:
  ```
  # North Pole exact (S2 handles pole singularity)
  Point: (lat: 90°, lon: 0°)
  Cell ID (level 30): 0x3FFFFFFFFFFFFFFX (face 0 center)
  Note: Longitude is meaningless at exact pole (any value is valid)

  # North Pole radius query (100km radius)
  Center: (lat: 90°, lon: 0°)
  Radius: 100,000 m
  Expected: All points where lat >= 89.1° (approximately)
  S2 covering: Should produce cells on face 0

  # South Pole exact
  Point: (lat: -90°, lon: 0°)
  Cell ID (level 30): 0xBFFFFFFFFFFFFFFX (face 5 center)

  # South Pole radius query (50km radius)
  Center: (lat: -90°, lon: 0°)
  Radius: 50,000 m
  Expected: All points where lat <= -89.55° (approximately)

  # Near-pole polygon (Arctic circle region)
  Vertices: [
    (lat: 85°, lon: 0°),
    (lat: 85°, lon: 120°),
    (lat: 85°, lon: -120°)
  ]
  Note: This polygon should include the North Pole
  S2 covering: Should correctly identify polar inclusion

  # Cross-pole polygon (spans pole)
  Vertices: [
    (lat: 80°, lon: 0°),
    (lat: 80°, lon: 90°),
    (lat: 80°, lon: 180°),
    (lat: 80°, lon: -90°)
  ]
  Contains North Pole: YES
  Note: S2 handles pole-containing polygons correctly
  ```
- **AND** longitude degeneracy at poles SHALL be handled correctly
- **AND** S2's cube-face projection naturally handles polar regions

#### Scenario: Pole edge cases

- **WHEN** handling pole-specific edge cases
- **THEN** the system SHALL:
  1. **Exact pole coordinates**: Accept any longitude value at lat=±90°
  2. **Pole-containing circles**: Radius queries centered at pole work normally
  3. **Pole-crossing polygons**: Polygons containing a pole are valid
  4. **Pole-touching polygons**: Polygons with vertex at exact pole are valid
- **AND** implementation SHALL use S2's robust pole handling (not naive lat/lon math)

### Requirement: UUID Lookup Query

The system SHALL support O(1) lookup of the latest location for a specific entity using the RAM index.

#### Scenario: Successful lookup

- **GIVEN** an entity with UUID `entity_id` exists in the index
- **WHEN** `get_latest(entity_id)` is called
- **THEN** the system SHALL:
  1. Look up offset in RAM index (O(1) hash lookup)
  2. Read 128 bytes from disk at that offset (pread)
  3. Return the full GeoEvent struct
- **AND** latency SHALL be less than 1ms at p99

#### Scenario: Entity not found

- **GIVEN** an entity with UUID `entity_id` does not exist
- **WHEN** `get_latest(entity_id)` is called
- **THEN** the system SHALL return null/none

#### Scenario: Prefetch for lookup

- **WHEN** prefetching for lookup operations
- **THEN** the system SHALL enqueue entity_ids for prefetch
- **AND** cache blocks containing those records

### Requirement: Radius Query

The system SHALL support finding all entities within a specified distance from a point.

#### Scenario: Basic radius query

- **WHEN** `find_in_radius(lat, lon, radius_meters)` is called
- **THEN** the system SHALL return all GeoEvents where the great-circle distance from (lat, lon) is <= radius_meters

#### Scenario: Zero radius query handling

- **WHEN** `find_in_radius(lat, lon, radius_meters=0)` is called
- **THEN** the system SHALL:
  - Return error `radius_zero` (error code 110)
  - Error message: "Zero radius query not supported; use UUID query for exact entity lookup"
- **AND** zero radius is rejected because:
  - GPS coordinates have inherent imprecision (~1-10m)
  - Nanodegree-level exact matches are meaningless for real-world use
  - UUID query is the correct method for exact entity lookup
- **AND** minimum practical radius is 1 millimeter (radius_mm=1)

#### Scenario: Radius query with time filter

- **WHEN** `find_in_radius(lat, lon, radius_meters, start_time, end_time)` is called
- **THEN** the system SHALL return GeoEvents matching spatial AND temporal criteria

#### Scenario: Radius query execution

- **WHEN** a radius query is executed
- **THEN** the query engine SHALL:
  1. Convert the circle to an S2 Cap
  2. Generate covering cell ID ranges
  3. Prefetch blocks for those ID ranges
  4. Scan for records in those ID ranges (using skip-scan)
  5. Post-filter using precise distance calculation

### Requirement: Polygon Query

The system SHALL support finding all entities within an arbitrary polygon.

#### Scenario: Polygon winding order convention

- **WHEN** specifying polygon vertices
- **THEN** the system SHALL use Counter-Clockwise (CCW) winding order convention:
  - Vertices listed in CCW order define the interior (query area)
  - Clockwise order would invert inside/outside (unintended behavior)
- **AND** the system SHALL auto-correct winding order:
  1. Calculate signed area of polygon
  2. If area < 0 (CW order), reverse vertex array
  3. Log info: "Polygon winding order corrected from CW to CCW"
- **AND** this follows GeoJSON and OpenGIS conventions
- **AND** auto-correction ensures correct behavior regardless of client input

#### Scenario: Basic polygon query

- **WHEN** `find_in_polygon(vertices[])` is called
- **THEN** the system SHALL return all GeoEvents where the point is inside the polygon

#### Scenario: Polygon query with time filter

- **WHEN** `find_in_polygon(vertices[], start_time, end_time)` is called
- **THEN** the system SHALL return GeoEvents matching spatial AND temporal criteria

#### Scenario: Polygon query execution

- **WHEN** a polygon query is executed
- **THEN** the query engine SHALL:
  1. Convert the polygon to an S2 Polygon
  2. Generate covering cell ID ranges
  3. Prefetch blocks for those ID ranges
  4. Scan for records in those ID ranges
  5. Post-filter using precise point-in-polygon test

#### Scenario: Anti-meridian polygon handling

- **WHEN** a polygon crosses the anti-meridian (180° longitude)
- **THEN** the system SHALL:
  1. Detect crossing: adjacent vertices with longitude signs differing (e.g., +179° to -179°)
  2. Validate: longitude gap > 180° indicates crossing (not a wrap-around-world polygon)
  3. Use S2 library's native anti-meridian handling (S2Polygon handles crossing naturally)
  4. Generate two separate cell ranges (east and west of meridian)
  5. Combine results from both ranges
- **AND** example valid anti-meridian polygon (Pacific crossing):
  ```
  vertices: [
    (lat: 40°, lon: +175°),   # Near Japan
    (lat: 45°, lon: -170°),   # Alaska side (crosses meridian)
    (lat: 35°, lon: -175°),   # Pacific
    (lat: 40°, lon: +175°)    # Back to start
  ]
  ```
- **AND** S2 RegionCoverer automatically handles the discontinuity

#### Scenario: Anti-meridian edge case detection

- **WHEN** validating polygon vertices
- **THEN** the system SHALL detect ambiguous cases:
  ```
  Crossing detection algorithm:
  For each edge (v1, v2):
    lon_diff = v2.lon - v1.lon
    if abs(lon_diff) > 180°:
      # This edge crosses the anti-meridian
      # Normalize by adding 360° to the smaller longitude
      actual_crossing = true
    else:
      actual_crossing = false
  ```
- **AND** if no edge crosses with > 180° gap: polygon is entirely in one hemisphere
- **AND** if edge crosses: polygon spans the anti-meridian

#### Scenario: Wrap-around-world polygon rejection

- **WHEN** a polygon appears to wrap around the entire world
- **THEN** the system SHALL:
  - Detect: polygon bounds span > 350° of longitude without valid crossing
  - Return error `polygon_too_large` (new error code)
  - Log warning: "Polygon appears to wrap around world - likely malformed input"
- **AND** legitimate global queries should use multiple smaller polygons

#### Scenario: Self-intersecting polygon detection

- **WHEN** validating polygon vertices during input_valid()
- **THEN** the system SHALL detect self-intersecting polygons:
  ```
  Self-intersection detection algorithm (O(n²) simple, O(n log n) optimal):

  For each edge E1 = (V[i], V[i+1]):
    For each non-adjacent edge E2 = (V[j], V[j+1]) where j > i+1:
      If edges_intersect(E1, E2):
        return SELF_INTERSECTING

  Edge intersection test (2D line segment intersection):
  edges_intersect(A, B, C, D):
    # A-B is first edge, C-D is second edge
    d1 = cross_product(C-A, B-A)
    d2 = cross_product(D-A, B-A)
    d3 = cross_product(A-C, D-C)
    d4 = cross_product(B-C, D-C)

    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
       ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)):
      return true  # Edges cross
    return false
  ```
- **AND** if self-intersection detected: return error `polygon_self_intersecting` (109)

#### Scenario: Self-intersecting polygon examples

- **WHEN** identifying invalid polygons
- **THEN** the following shapes SHALL be rejected:
  ```
  # Bowtie (figure-8) - INVALID
  vertices: [
    (0, 0), (2, 2), (0, 2), (2, 0)
  ]
  # Edges (0,0)-(2,2) and (0,2)-(2,0) intersect

  # Complex self-intersection - INVALID
  vertices: [
    (0, 0), (4, 0), (4, 3), (1, 1), (3, 1), (0, 3)
  ]
  # Multiple edge crossings

  # Valid concave polygon (no self-intersection) - VALID
  vertices: [
    (0, 0), (2, 1), (4, 0), (3, 2), (4, 4), (2, 3), (0, 4), (1, 2)
  ]
  # Star shape without crossing edges
  ```

#### Scenario: Performance considerations for polygon validation

- **WHEN** validating large polygons
- **THEN** the system SHALL:
  - Use O(n log n) sweep-line algorithm for polygons > 100 vertices
  - Use O(n²) simple algorithm for polygons ≤ 100 vertices (simpler, constant factors)
  - Total validation time SHALL be < 1ms for 10,000 vertices
- **AND** validation occurs once during input_valid(), not repeatedly
- **AND** metrics: `archerdb_polygon_validation_duration_seconds` histogram

### Requirement: Range Scan Optimization

The system SHALL optimize range scans by converting spatial queries to integer range comparisons with block-level filtering.

#### Scenario: Cell range to ID range

- **WHEN** an S2 cell range is used for querying
- **THEN** it SHALL be converted to composite ID ranges:
  - Start: `(@as(u128, cell_min) << 64) | time_start`
  - End: `(@as(u128, cell_max) << 64) | time_end`

#### Scenario: Time range handling

- **WHEN** no time filter is specified
- **THEN** `time_start = 0` and `time_end = maxInt(u64)`

#### Scenario: Block-level filtering

- **WHEN** scanning blocks for a range query
- **THEN** blocks where `max_id < range_start` or `min_id > range_end` SHALL be skipped entirely
- **AND** only the 256-byte header is read for skip decisions

### Requirement: Post-Filter Precision

The system SHALL perform precise geometric tests after the coarse S2 cell filter.

#### Scenario: Distance post-filter

- **WHEN** results from radius query cell scan are obtained
- **THEN** each result SHALL be verified using Haversine or Vincenty distance formula
- **AND** results outside the actual radius SHALL be excluded

#### Scenario: Point-in-polygon post-filter

- **WHEN** results from polygon query cell scan are obtained
- **THEN** each result SHALL be verified using ray-casting algorithm
- **AND** results outside the actual polygon SHALL be excluded

#### Scenario: Integer-only computation preference

- **WHEN** post-filter calculations are performed
- **THEN** they SHOULD use fixed-point arithmetic where possible
- **AND** floating-point conversions SHALL only occur at final output stage

### Requirement: Input Validation

The system SHALL validate all inputs before the prepare phase to ensure deterministic behavior across replicas.

#### Scenario: Batch validation

- **WHEN** `input_valid(operation, body)` is called
- **THEN** it SHALL verify:
  - Body size is multiple of event size
  - Event count does not exceed operation's max
  - Multi-batch structure is valid (if applicable)
  - Reply will fit in message body

#### Scenario: Empty batch handling

- **WHEN** validating a batch with event count = 0 (empty batch)
- **THEN** `input_valid()` SHALL return true (valid no-op operation)
- **AND** `prepare()` SHALL return delta_nanoseconds = 0
- **AND** `commit()` SHALL complete immediately without state changes
- **AND** response SHALL indicate 0 events processed with status `ok`
- **AND** empty batches are legal (allows clients to test connectivity)

#### Scenario: Multi-batch validation

- **WHEN** validating a multi-batch message
- **THEN** the system SHALL:
  - Decode and validate trailer structure
  - Validate each batch individually
  - Sum expected result counts
  - Verify total reply size fits in message

#### Scenario: Coordinate validation

- **WHEN** validating GeoEvent batches in input_valid()
- **THEN** the system SHALL verify coordinates:
  - Latitude range: -90,000,000,000 to +90,000,000,000 nanodegrees (±90°)
  - Longitude range: -180,000,000,000 to +180,000,000,000 nanodegrees (±180°)
  - S2 cell ID is valid (non-zero, valid level)
- **AND** coordinates outside valid ranges SHALL be rejected with error `invalid_coordinates`
- **AND** validation occurs BEFORE consensus (in input_valid phase)

#### Scenario: Validation failure

- **WHEN** validation fails
- **THEN** the request SHALL be rejected before consensus
- **AND** error SHALL be returned to client immediately

### Requirement: Deterministic Timestamp Assignment

The system SHALL assign unique deterministic timestamps to each event in a batch.

#### Scenario: Timestamp distribution

- **WHEN** a batch of N events is executed at timestamp T
- **THEN** event[i] SHALL get timestamp `T - N + i + 1`
- **AND** the last event gets timestamp T
- **AND** all timestamps are unique and monotonically increasing

#### Scenario: Imported events

- **WHEN** an event has `flags.imported = true`
- **THEN** the client-provided timestamp SHALL be used
- **AND** `event.timestamp < prepare_timestamp` MUST be true
- **AND** imported events do not advance prepare_timestamp

#### Scenario: Timestamp validation

- **WHEN** a non-imported event is received
- **THEN** `event.timestamp` MUST equal 0 (server assigns timestamp)
- **AND** error `timestamp_must_be_zero` if non-zero

### Requirement: Performance SLAs

The system SHALL meet aggressive performance targets matching TigerBeetle-class throughput and latency.

#### Scenario: Write throughput target

- **WHEN** processing write operations
- **THEN** the system SHALL achieve:
  - **1,000,000 events/sec per node** with large batches (10k+ events)
  - 100,000 events/sec per node with small batches (100 events)
  - 5,000,000 events/sec sustained for 5-node cluster
- **AND** this assumes:
  - 16+ CPU cores with AES-NI support
  - NVMe SSD (>3GB/s sequential, <100μs latency)
  - 10Gbps network between replicas (same region)

#### Scenario: Write latency target

- **WHEN** measuring write operation latency
- **THEN** the system SHALL achieve:
  - p99 < 5ms (includes quorum wait across availability zones)
  - p50 < 2ms (typical case, same region)
- **AND** latency includes full round-trip from client request to response

#### Scenario: UUID lookup latency target

- **WHEN** performing UUID lookups
- **THEN** the system SHALL achieve:
  - p99 < 500μs (RAM index lookup + single NVMe read)
  - p50 < 200μs (cache hit case)
- **AND** this assumes hot index in RAM

#### Scenario: Radius query latency target

- **WHEN** performing radius queries on areas containing 1M records
- **THEN** the system SHALL achieve:
  - p99 < 50ms (sequential scan with prefetch)
  - p50 < 20ms
- **AND** this assumes S2 covering produces <16 cell ranges

#### Scenario: Polygon query latency target

- **WHEN** performing polygon queries on complex shapes
- **THEN** the system SHALL achieve:
  - p99 < 100ms (more complex than radius due to irregular covering)
  - p50 < 40ms

#### Scenario: View change failover target

- **WHEN** primary fails and view change occurs
- **THEN** the system SHALL achieve:
  - < 3 seconds to elect new primary and resume operations
  - < 1 second for failure detection (via aggressive heartbeats)
  - < 2 seconds for view change protocol execution
- **AND** this requires all TigerBeetle optimizations:
  - Ping every 200-500ms for fast failure detection
  - CTRL protocol for efficient log reconciliation
  - Pre-prepared replicas (backups maintain full state)
  - Fast quorum determination (proceed as soon as quorum agrees)
  - Primary abdication under backpressure
  - Message prioritization (view change bypasses normal queue)

#### Scenario: Replication lag target

- **WHEN** measuring replication lag in normal operation
- **THEN** the system SHALL achieve:
  - < 10ms lag between primary and replicas (same region)
  - < 50ms lag across regions (if cross-region replication supported)

### Requirement: Query Result Limits

The system SHALL enforce limits on query result sets to prevent resource exhaustion.

#### Scenario: Maximum result set size

- **WHEN** a spatial query is executed
- **THEN** the system SHALL:
  - Enforce maximum result set of 81,000 records per query
  - This limit ensures results fit in 10MB message (81,000 × 128 bytes = 10.37MB with overhead)
  - Return error `query_result_too_large` if exceeded
  - Require pagination for larger result sets

#### Scenario: Pagination support

- **WHEN** a query exceeds the result limit
- **THEN** the client SHALL:
  - Use the highest returned `id` as cursor for next page
  - Re-issue query with additional filter: `id > cursor_id`
  - Repeat until no more results

#### Scenario: Cursor-based pagination protocol

- **WHEN** a query request is made with pagination
- **THEN** the request format SHALL support:
  ```
  QueryRequest {
    query_type: u8,        // radius=1, polygon=2, cell_range=3
    flags: u8,             // bit 0: has_cursor, bit 1: ascending
    reserved: u16,
    limit: u32,            // max results (default: 81000, max: 81000)
    cursor_id: u128,       // if has_cursor=1, return results after this ID
    // ... query-specific fields
  }
  ```
- **AND** response SHALL include:
  ```
  QueryResponse {
    count: u32,            // number of results returned
    has_more: u8,          // 1 if more results available
    reserved: [3]u8,
    // followed by count × GeoEvent structs
  }
  ```

#### Scenario: Pagination ordering guarantee

- **WHEN** paginating through results
- **THEN** results SHALL be ordered by composite ID (s2_cell << 64 | timestamp)
- **AND** each page returns the next 81,000 IDs in order
- **AND** cursor_id ensures no duplicates or gaps between pages
- **AND** concurrent writes during pagination may cause results to appear in later pages

#### Scenario: Pagination with time filter

- **WHEN** query includes time_start and time_end filters
- **AND** pagination cursor is provided
- **THEN** the system SHALL:
  - Apply time filter to candidate results
  - Start scan at cursor_id position
  - Return up to `limit` results matching time filter
  - Time filter reduces result count but cursor position is still by ID

#### Scenario: Maximum polygon complexity

- **WHEN** a polygon query is submitted
- **THEN** the system SHALL:
  - Enforce maximum 10,000 vertices per polygon
  - Return error `polygon_too_complex` if exceeded

#### Scenario: Maximum radius

- **WHEN** a radius query is submitted
- **THEN** the system SHALL:
  - Enforce maximum radius of 1,000 km
  - Return error `radius_too_large` if exceeded
  - Prevent full-database scans from overly large radii

### Requirement: Batch Size Limits

The system SHALL enforce limits on batch sizes to prevent memory exhaustion and ensure bounded latency.

#### Scenario: Maximum batch size

- **WHEN** processing write batches
- **THEN** the system SHALL:
  - Enforce maximum 10,000 events per batch
  - Return error `too_much_data` if exceeded

#### Scenario: Maximum message size

- **WHEN** processing messages
- **THEN** the system SHALL:
  - Enforce maximum message size of 10MB (header + body)
  - Return error `invalid_data_size` if exceeded
  - Allow ~78,000 events at 128 bytes each (theoretical max)

#### Scenario: Multi-batch limits

- **WHEN** processing multi-batch messages
- **THEN** the system SHALL:
  - Enforce maximum 65,534 events per sub-batch (u16 count)
  - Enforce maximum total size of 10MB across all sub-batches

### Requirement: Entity Deletion (GDPR Compliance)

The system SHALL support explicit entity deletion for compliance with data protection regulations.

#### Scenario: Delete operation using tombstones

- **WHEN** `delete_entities(entity_ids[])` is called
- **THEN** the system SHALL use tombstone pattern (append-only compatible):
  1. For each entity_id in the batch:
     a. Check if entity exists in RAM index (lookup)
     b. If not found: increment not_found counter, continue
     c. If found: Create tombstone GeoEvent:
        - entity_id: target entity UUID
        - flags.deleted: true
        - timestamp: deletion timestamp (from VSR prepare)
        - id: SENTINEL_TOMBSTONE_ID (see below)
        - lat_nano, lon_nano: 0 (ignored - tombstones excluded from spatial queries)
        - All other numeric fields: zero
     d. Append tombstone to LSM log (append-only, no in-place modification)
     e. Upsert tombstone into RAM index (supersedes old entry via LWW)
  2. Return count deleted and count not found
- **AND** tombstone is a regular GeoEvent with flags.deleted=true
- **AND** append-only storage is preserved (LSM integrity maintained)
- **AND** compaction will skip BOTH old events AND tombstones

#### Scenario: Tombstone sentinel ID (spatial query exclusion)

- **WHEN** creating a tombstone GeoEvent
- **THEN** the `id` field SHALL use SENTINEL_TOMBSTONE_ID:
  ```
  SENTINEL_TOMBSTONE_ID = 0x0000000000000000_FFFFFFFFFFFFFFFF
  // S2 cell = 0 (invalid cell), timestamp = maxInt(u64)
  ```
- **AND** spatial queries SHALL explicitly exclude sentinel cell 0 from covering
- **AND** this prevents tombstones from appearing in spatial query results
- **AND** tombstones are still findable via entity_id lookup (RAM index)

#### Scenario: Delete operation code

- **WHEN** defining operation codes
- **THEN** add: `delete_entities = 0x03`

#### Scenario: Delete request format

- **WHEN** encoding delete request
- **THEN** body SHALL contain:
  ```
  [count: u32]              # Number of entity IDs to delete
  [reserved: u32]           # Alignment
  [entity_id_1: u128]       # 16 bytes
  [entity_id_2: u128]       # 16 bytes
  ...
  ```
- **AND** maximum 10,000 entities per delete batch

#### Scenario: Delete response format

- **WHEN** delete completes
- **THEN** response SHALL contain:
  ```
  [count_deleted: u32]      # Successfully deleted
  [count_not_found: u32]    # Entity IDs not in index
  [reserved: [56]u8]        # Padding
  ```

#### Scenario: Delete operation three-phase execution

- **WHEN** delete_entities operation is executed
- **THEN** it SHALL follow three-phase model:
  1. **input_valid()**: Validate batch format (count + UUID array), check count <= 10,000
  2. **prepare()**: Assign timestamp for audit trail (deletion timestamp)
  3. **prefetch()**: No-op (index-only operation, no disk I/O needed)
  4. **commit()**: For each entity_id, call `index.delete(entity_id)`, mark on-disk event flags.deleted=true if found

#### Scenario: Delete and compaction

- **WHEN** LSM compaction reads a deleted event (flags.deleted = true)
- **THEN** it SHALL NOT copy the event forward
- **AND** disk space is reclaimed through compaction
- **AND** deletion is eventually permanent (after compaction cycle)
- **AND** flags.deleted bit indicates event should be garbage collected

#### Scenario: GDPR compliance

- **WHEN** handling GDPR right to erasure requests
- **THEN** operators SHALL:
  1. Call `delete_entities([user_entity_ids])`
  2. Wait for next compaction cycle (or trigger manual compaction)
  3. Verify entity no longer in index or data file
  4. Complete within 30 days (GDPR requirement)

### Requirement: Query CPU Budget (DoS Prevention)

The system SHALL enforce CPU time limits on queries to prevent denial-of-service attacks.

#### Scenario: Per-query CPU limit

- **WHEN** executing spatial queries (radius, polygon)
- **THEN** each query SHALL have maximum CPU time of 5 seconds
- **AND** if exceeded, query is aborted with error `query_timeout`
- **AND** prevents DoS via complex queries (e.g., 10,000-vertex star polygons)
- **AND** CPU time includes S2 covering, scan, and post-filtering

#### Scenario: Query complexity hints

- **WHEN** S2 RegionCoverer produces max_cells (16) ranges
- **AND** scan encounters > 1M events
- **THEN** log warning: "Complex query detected - consider smaller area or pagination"

### Requirement: Concurrent Operations

The system SHALL support high concurrency for client operations.

#### Scenario: Maximum concurrent connections

- **WHEN** clients connect
- **THEN** the system SHALL:
  - Support up to 10,000 concurrent client connections per node
  - Enforce per-IP connection limits (default: 100) to prevent DoS
  - Use connection pooling for replica-to-replica communication

#### Scenario: Pipeline depth

- **WHEN** processing operations
- **THEN** the system SHALL:
  - Support pipeline depth matching TigerBeetle's configuration
  - Allow multiple in-flight operations per client session
  - Maintain request ordering per client

#### Scenario: Concurrent spatial query limit

- **WHEN** multiple spatial queries (radius, polygon) execute simultaneously
- **THEN** the system SHALL:
  - Limit concurrent spatial queries to `--max-concurrent-queries` (default: 100)
  - Queue additional queries when limit reached
  - Return `too_many_queries` error if queue depth exceeds 1000
  - This prevents memory exhaustion (100 queries × 10MB results = 1GB max)
- **AND** UUID lookups are NOT subject to this limit (O(1) memory)
- **AND** write operations are NOT subject to this limit (handled by VSR pipeline)

#### Scenario: Query memory budget

- **WHEN** allocating memory for query results
- **THEN** the system SHALL:
  - Pre-allocate result buffers from a fixed pool at startup
  - Pool size: `max_concurrent_queries × message_size_max` (default: 100 × 10MB = 1GB)
  - If pool exhausted: queue query until buffer available
  - This ensures bounded memory usage under load
- **AND** result buffers are returned to pool after response sent to client
