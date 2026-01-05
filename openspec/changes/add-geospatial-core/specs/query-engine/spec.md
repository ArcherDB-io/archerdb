# Query Engine Specification

## ADDED Requirements

### Requirement: TTL Expiration Check on Entity Lookup

The system SHALL check TTL validity during query execution and return errors for expired entities.

#### Scenario: TTL expiration during query

- **WHEN** an entity is retrieved from index or LSM during query execution
- **THEN** the system SHALL check if the entity has expired:
  ```zig
  // During query execution, after fetching IndexEntry or GeoEvent:
  if (entry.ttl_seconds > 0) {
      const now_seconds = timestamp_ns / 1_000_000_000;
      const expiry_seconds = entry.creation_timestamp_ns / 1_000_000_000 + entry.ttl_seconds;
      if (now_seconds > expiry_seconds) {
          return error.entity_expired; // Do NOT return stale data
      }
  }
  ```
- **AND** return error code `entity_expired` (code 210 - see error-codes/spec.md)
- **AND** do NOT return the expired entity to client
- **AND** log this as a normal operation (not a system error)

#### Scenario: TTL coordination with deletion

- **WHEN** both TTL expiration and explicit deletion (GDPR) can occur
- **THEN** the system SHALL treat them equivalently:
  - Both remove entity from RAM index
  - Both generate LSM tombstones
  - Both prevent queries from returning the entity
- **AND** the entity disappears from all queries once TTL is exceeded (same as explicit delete)

---

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
- **AND** the `MultiBatchExecutor` MUST truncate results and set a `partial_result` flag if the aggregate response body exceeds `message_body_size_max` (~10MB; i.e. `message_size_max - message_header_size`)
- **AND** this forces the client to use pagination cursors to fetch remaining data

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

#### Scenario: Cell hierarchy

- **WHEN** navigating the S2 cell hierarchy
- **THEN** the parent cell ID SHALL be obtainable by bit-shifting (truncating 2 bits per level)
- **AND** this enables efficient quad-tree traversal

#### Scenario: Region covering

- **WHEN** a polygon or circle region is queried
- **THEN** the S2 RegionCoverer SHALL decompose it into a set of cell ID ranges
- **AND** the number of cells SHALL be bounded by s2_max_cells constant (default: 16)

#### Design Note: Storage Level vs Query Level Distinction

**Important**: ArcherDB uses **two different S2 cell levels** for different purposes:

1. **Storage Level**: ALWAYS **level 30** (~7.5mm precision)
   - All GeoEvents are indexed at level 30 in the composite ID
   - Enables precise spatial locality in LSM key ordering
   - Cannot be changed at runtime (baked into data format)

2. **Query Level**: VARIES **1-30** depending on query radius/area
   - Query decomposition uses coarser levels (e.g., level 18 for ~150m radius)
   - Efficient cell range generation minimizes cells examined
   - Query level is ONLY used during planning; data is always level 30
   - Post-filter phase performs exact geometry tests on level-30 results

**Why Two Levels?**: Storage level 30 provides precision and locality; query levels 1-30 provide query efficiency. This decoupling is key to ArcherDB's performance model.

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
  clamped to range [0, 18] (max query level)

  Examples:
  - radius = 100 km → level 6 (log2(78.42) ≈ 6.29)
  - radius = 10 km  → level 9 (log2(784.2) ≈ 9.61)
  - radius = 1 km   → level 12 (log2(7842) ≈ 12.93)
  - radius = 100 m  → level 16 (log2(78420) ≈ 16.25)
  ```
- **AND** lower levels (larger cells) for larger areas
- **AND** higher levels (smaller cells) for smaller areas

#### Scenario: S2 level bounds for query decomposition

- **WHEN** decomposing a query region into cells
- **THEN** RegionCoverer SHALL use:
  - `min_level`: Calculated from query area (see above)
  - `max_level`: `min(min_level + 4, s2_cover_max_level)` (default `s2_cover_max_level = 18`)
  - `s2_max_cells`: 16 (default) - Limit query complexity
- **AND** min/max levels SHALL be clamped so that `0 <= min_level <= max_level <= s2_cover_max_level`
- **AND** this produces efficient cell ranges without over-decomposition

### Requirement: S2 Level Tuning Decision Table

The system SHALL provide explicit guidance for selecting S2 parameters based on use case.

#### Scenario: Radius-based level selection decision table

- **WHEN** selecting S2 levels for radius queries
- **THEN** the following decision table SHALL apply:
  ```
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                     S2 LEVEL SELECTION FOR RADIUS QUERIES                            │
  ├──────────────────┬────────────┬────────────┬────────────┬───────────────────────────┤
  │ Query Radius     │ min_level  │ max_level  │ max_cells  │ Use Case                  │
  ├──────────────────┼────────────┼────────────┼────────────┼───────────────────────────┤
  │ 1-10 m           │ 18         │ 18         │ 4          │ Indoor/room-level lookup  │
  │ 10-100 m         │ 16         │ 18         │ 8          │ Building/venue search     │
  │ 100-500 m        │ 15         │ 18         │ 12         │ Block/neighborhood        │
  │ 500m-2 km        │ 13         │ 17         │ 16         │ District/campus           │
  │ 2-10 km          │ 11         │ 15         │ 16         │ City district             │
  │ 10-50 km         │ 9          │ 13         │ 16         │ Metro area                │
  │ 50-200 km        │ 7          │ 11         │ 16         │ Regional                  │
  │ 200-1000 km      │ 5          │ 9          │ 16         │ State/country             │
  └──────────────────┴────────────┴────────────┴────────────┴───────────────────────────┘

  Selection algorithm:
  min_level = max(0, min(18, floor(log2(7842000 / radius_meters))))
  max_level = min(min_level + 4, 18)
  max_cells = radius_meters < 500 ? (radius_meters < 100 ? 4 : 8) : 16
  ```

#### Scenario: Polygon-based level selection decision table

- **WHEN** selecting S2 levels for polygon queries
- **THEN** the following decision table SHALL apply:
  ```
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                     S2 LEVEL SELECTION FOR POLYGON QUERIES                           │
  ├──────────────────┬────────────┬────────────┬────────────┬───────────────────────────┤
  │ Polygon Area     │ min_level  │ max_level  │ max_cells  │ Use Case                  │
  ├──────────────────┼────────────┼────────────┼────────────┼───────────────────────────┤
  │ < 1 km²          │ 16         │ 18         │ 16         │ Building footprint        │
  │ 1-10 km²         │ 14         │ 18         │ 16         │ Neighborhood zone         │
  │ 10-100 km²       │ 12         │ 16         │ 16         │ District boundary         │
  │ 100-1000 km²     │ 10         │ 14         │ 16         │ City boundary             │
  │ 1000-10000 km²   │ 8          │ 12         │ 16         │ County/region             │
  │ > 10000 km²      │ 6          │ 10         │ 16         │ State/province            │
  └──────────────────┴────────────┴────────────┴────────────┴───────────────────────────┘

  Selection algorithm (using bounding box area as proxy):
  area_km2 = bounding_box_area(polygon)
  min_level = max(0, min(18, floor(log2(500000000 / area_km2) / 2)))
  max_level = min(min_level + 4, 18)
  ```

#### Scenario: Use-case specific tuning recommendations

- **WHEN** tuning S2 parameters for specific workloads
- **THEN** the following recommendations SHALL apply:
  ```
  ┌─────────────────────────────────────────────────────────────────────────────────────┐
  │                     USE CASE TUNING RECOMMENDATIONS                                  │
  ├─────────────────────────┬─────────────────────────────────────────────────────────────┤
  │ Use Case                │ Recommended Configuration                                  │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ Fleet Tracking          │ min_level=12, max_level=16, max_cells=16                   │
  │ (vehicles in city)      │ Optimized for 1-5km typical query radius                   │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ Delivery/Logistics      │ min_level=14, max_level=18, max_cells=12                   │
  │ (last-mile)             │ Optimized for 100m-1km radius, dense urban areas           │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ Real-time Rideshare     │ min_level=15, max_level=18, max_cells=8                    │
  │ (nearby drivers)        │ Optimized for <500m radius, fast response                  │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ IoT Sensors             │ min_level=16, max_level=18, max_cells=4                    │
  │ (dense fixed locations) │ Optimized for precise location, small areas                │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ Wildlife Tracking       │ min_level=8, max_level=12, max_cells=16                    │
  │ (large territories)     │ Optimized for 10-100km ranges, sparse data                 │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ Maritime/Aviation       │ min_level=6, max_level=10, max_cells=16                    │
  │ (continental scale)     │ Optimized for 100-1000km ranges                            │
  └─────────────────────────┴─────────────────────────────────────────────────────────────┘
  ```

#### Scenario: Performance impact of S2 level choices

- **WHEN** understanding performance trade-offs
- **THEN** the following guidance SHALL apply:
  ```
  S2 LEVEL SELECTION TRADE-OFFS
  ═════════════════════════════

  Lower min_level (larger cells):
  ✓ Fewer cells in covering → fewer range scans
  ✓ Better for large areas
  ✗ More false positives → more post-filtering CPU
  ✗ May include irrelevant data in scan

  Higher min_level (smaller cells):
  ✓ Tighter covering → fewer false positives
  ✓ Less post-filtering work
  ✗ More cells → more range scans
  ✗ Can cause covering to hit max_cells limit

  Optimal strategy:
  ─────────────────
  1. For small queries (< 1km): Use high min_level (15-18), low max_cells (4-8)
  2. For medium queries (1-10km): Use mid min_level (11-14), medium max_cells (12-16)
  3. For large queries (> 10km): Use low min_level (6-10), high max_cells (16)
  4. Monitor: archerdb_query_post_filter_ratio should be < 2.0
     (ratio of scanned events to returned events)
  ```

#### Scenario: S2 tuning metrics

- **WHEN** monitoring S2 covering efficiency
- **THEN** the following metrics SHALL be exposed:
  ```
  # Number of S2 cells generated per query
  archerdb_query_s2_cells_count histogram
    Labels: query_type={radius|polygon}, level={min_level}

  # Ratio of events scanned to events returned (false positive ratio)
  archerdb_query_post_filter_ratio histogram
    Labels: query_type={radius|polygon}

  # Query covering generation time
  archerdb_query_s2_covering_duration_seconds histogram
    Labels: query_type={radius|polygon}

  Target values:
  - s2_cells_count: median < 8, p99 < 16
  - post_filter_ratio: median < 1.5, p99 < 5.0
  - covering_duration: median < 100μs, p99 < 1ms (assumes radius/simple polygon)
  ```

#### Scenario: S2 covering complexity assumptions

- **WHEN** evaluating S2 covering performance
- **THEN** the targets (covering_duration < 1ms p99) assume:
  - **Radius queries**: Covering produces < 16 cells (median < 8)
  - **Simple polygons**: < 50 vertices, < 10 cells (median ~5)
  - **Moderate polygons**: 50-100 vertices, < 200 cells (median ~50)
- **AND** more complex geometries have higher covering costs:
  - **Complex polygons** (100-1000 vertices): Covering ~200-1000 cells, duration ~2-5ms
  - **Very complex polygons** (1000-10000 vertices): Covering > 1000 cells, duration 5-20ms
  - These exceed the < 1ms target and reduce overall query performance
- **AND** S2 library implementation is deterministic (Chebyshev/CORDIC for trig) per Decision 3a

### Requirement: S2 Implementation Validation

The system SHALL validate S2 implementation using deterministic invariants and golden vectors derived from a reference implementation.

#### Scenario: S2 cell ID invariants (structure + hierarchy)

- **WHEN** validating S2 cell ID computation
- **THEN** the implementation MUST satisfy these invariants for a set of test coordinates:
  - For any valid (lat, lon, level): `cell_id != 0`
  - `0 <= face(cell_id) <= 5`
  - `level(cell_id) == level` (where `level()` extracts the level encoded in the cell id)
  - `get_parent(cell_id)` reduces level by exactly 1
  - `get_children(parent)` returns 4 children whose parent is exactly `parent`
  - For points at the exact poles (`lat=±90°`): any longitude value MUST produce a valid `cell_id` and MUST not crash (longitude is semantically degenerate)

#### Scenario: S2 golden vectors (exact IDs, repo-controlled)

- **WHEN** validating the pure Zig S2 implementation against a reference
- **THEN** the project MUST maintain a golden-vector file checked into the repo which contains:
  - Input tuples `(lat_nano, lon_nano, level)`
  - Expected outputs for `cell_id` (u64)
- **AND** unit tests MUST assert exact equality between:
  - `S2.lat_lon_to_cell_id(lat_nano, lon_nano, level)` and the golden `cell_id`
- **AND** golden vectors MUST be generated from a single authoritative reference implementation (e.g. Google's S2 library) and updated only intentionally
- **AND** the spec forbids placeholder values (no `XXXXXXXX` / partial IDs) because they make validation non-actionable

#### Scenario: Golden vector file location and format

- **WHEN** storing S2 golden vectors in the repository
- **THEN** the file path SHALL be:
  - `testdata/s2/golden_vectors_v1.tsv`
- **AND** the file format SHALL be:
  - UTF-8 text, LF newlines
  - Optional comment lines starting with `#` (ignored by parser)
  - One header row exactly:
    - `lat_nano\tlon_nano\tlevel\tcell_id_hex`
  - One data row per vector with fields:
    - `lat_nano`: signed decimal i64 nanodegrees
    - `lon_nano`: signed decimal i64 nanodegrees
    - `level`: unsigned decimal u8 in `[0..30]`
    - `cell_id_hex`: lower-case hex u64 formatted as `0x%016x`
- **AND** the dataset MUST NOT contain duplicates on the key `(lat_nano, lon_nano, level)`
- **AND** rows SHALL be sorted by `(level, lat_nano, lon_nano)` for stable diffs

#### Scenario: Golden vector coverage requirements

- **WHEN** generating `golden_vectors_v1.tsv`
- **THEN** it MUST include:
  - A fixed “edge case” set of coordinates (at all levels listed below):
    - (0°, 0°), (0°, +180°), (0°, -180°)
    - (+90°, 0°), (-90°, 0°)
    - (+89.999999999°, 0°), (-89.999999999°, 0°)
    - (0°, +179.999999999°), (0°, -179.999999999°)
    - (+45°, +45°), (-45°, -45°)
  - A pseudo-random set of at least 1024 coordinates generated from a fixed seed (see generator scenario)
- **AND** the golden vectors MUST cover these levels:
  - `[0, 1, 5, 10, 15, s2_cover_max_level (18), s2_cell_level (30)]`

#### Scenario: Golden vector generator command (tooling-only)

- **WHEN** regenerating S2 golden vectors
- **THEN** the repository SHALL provide a generator tool at:
  - `tools/s2_golden_gen/main.zig`
- **AND** the generator MUST compute `cell_id` values using an independent, pinned reference S2 implementation (NOT ArcherDB’s Zig S2)
- **AND** the generator MUST NOT introduce C++ build dependencies for the core database
- **AND** C++ is permitted for tooling-only if it is isolated (e.g., containerized) and pinned for reproducibility
- **AND** the generator MUST be deterministic:
  - Same input flags MUST produce byte-for-byte identical output
- **AND** the standard regeneration command SHALL be:
  - `zig run tools/s2_golden_gen/main.zig -- --out testdata/s2/golden_vectors_v1.tsv --seed 1 --random 1024 --levels 0,1,5,10,15,18,30`
- **AND** the generated file MUST include comment headers with:
  - generator identity and version
  - reference S2 library module version
  - seed and parameters used

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
  Cell ID (level 30): Valid cell id at requested level (no crash)
  Note: Longitude is meaningless at exact pole (any value is valid)

  # North Pole radius query (100km radius)
  Center: (lat: 90°, lon: 0°)
  Radius: 100,000 m
  Expected: All points where lat >= 89.1° (approximately)
  S2 covering: Should produce cells on face 0

  # South Pole exact
  Point: (lat: -90°, lon: 0°)
  Cell ID (level 30): Valid cell id at requested level (no crash)

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
- **AND** longitude degeneracy at poles SHALL be handled by S2's cube-face projection (all longitudes converge at ±90° latitude but S2 cells remain well-defined)
- **AND** S2's cube-face projection naturally handles polar regions without special cases

#### Scenario: S2 internal math determinism

- **WHEN** implementing S2 geometry functions in Zig
- **THEN** all internal calculations SHALL:
  - Use fixed-point arithmetic for coordinate transformations where possible
  - OR use strictly deterministic floating-point operations (avoiding platform-specific math library functions)
  - MUST pass golden vector tests on all supported platforms (Linux, macOS, Windows) with bit-for-bit identical results
  - **REASON**: Non-deterministic results would cause state divergence across replicas, leading to cluster-wide "hash-chain mismatch" panics.

#### Scenario: S2 platform independence (CRITICAL)

- **WHEN** implementing S2 geometry for cross-platform determinism
- **THEN** the implementation SHALL address these specific risks:
  ```
  IEEE 754 Floating-Point Determinism Analysis:

  | Operation | IEEE 754 Exact? | S2 Usage | Risk Level |
  |-----------|-----------------|----------|------------|
  | +, -, ×, ÷ | Yes | Heavy | Low |
  | sin, cos | NO | lat/lon→point | HIGH |
  | atan2 | NO | point→lat/lon | HIGH |
  | sqrt | Usually exact | Distance | Medium |
  ```
- **AND** transcendental functions (sin, cos, atan2) are NOT bit-exact across:
  - x86 vs ARM vs RISC-V processors
  - Different libc implementations (glibc vs musl vs macOS)
  - Compiler optimization levels (-O2 vs -O3)
- **AND** to ensure bit-exact results, the implementation SHALL:
  1. Use software-implemented trigonometry (not libc/intrinsics)
  2. Use identical polynomial approximations on all platforms
  3. Verify with golden vectors including edge cases:
     - Poles: (±90°, any longitude)
     - Anti-meridian: (any lat, ±180°)
     - Cell boundaries at all 31 levels
  4. Document that ALL replicas MUST use the same ArcherDB binary version
- **AND** if bit-exact S2 cannot be achieved in pure Zig:
  - Option A: Use C bindings to Google's S2 with identical build flags
  - Option B: Use integer-only S2 approximation (accuracy trade-off)
  - Option C: Defer S2 computation to primary, replicas verify hash only

#### Scenario: S2 Covering Empirical Evidence Test Suite

The system SHALL validate S2 covering performance and complexity empirically using a comprehensive test suite.

- **WHEN** implementing radius and polygon queries
- **THEN** the test suite SHALL validate:
  ```
  S2 COVERING EMPIRICAL EVIDENCE TEST SUITE
  ═════════════════════════════════════════

  OBJECTIVE: Validate that empirical S2 covering times and cell counts match specifications.

  TEST INFRASTRUCTURE:
  ───────────────────
  1. Benchmark harness (measure wall-clock time)
     - Warm-up iterations (discard JIT/cache effects)
     - 10,000+ iterations per test case
     - Report: mean, p50, p99, p99.9 latencies
     - Record: number of cells in covering, actual covering time

  2. Test case library (testdata/s2/covering_test_cases.json)
     - Geometry type (radius, simple polygon, complex polygon)
     - Complexity class (simple, moderate, complex, very complex)
     - Coordinates and parameters
     - Expected cell count range (min-max)
     - Expected latency range (p99 bounds)

  3. Platform matrix
     - Linux x86_64, macOS ARM64, Linux ARM64 (at minimum)
     - Record hardware profile (CPU model, frequency)
     - Verify results are within ±15% of baseline platform (x86-64 Linux is baseline):
       Example: If x86-64 result is 100μs, ARM64/macOS must be within 85-115μs
       Example: If x86-64 result is 100μs, ARM64 measured at 150μs would FAIL (50% > ±15%)
       (Accounts for CPU instruction set differences and clock differences)

  4. Metrics collection
     - archerdb_s2_covering_duration_seconds histogram
     - archerdb_s2_covering_cell_count histogram
     - archerdb_s2_covering_max_cells_exceeded_total counter

  COVERING COMPLEXITY CLASSES:
  ────────────────────────────

  Class 1: SIMPLE (single-cell or few-cell coverings)
  ─────────────────────────────────────────────────
  Geometry: Small radius or simple convex polygon

  Test Cases:
  - Radius 10m at (40.7128, -74.0060) [NYC]
    Expected: 1 cell at level 30
    Expected latency: < 50μs (p99)
    Expected cell count: 1

  - Radius 100m at (51.5074, -0.1278) [London]
    Expected: 1-4 cells at level 29-30
    Expected latency: < 75μs (p99)
    Expected cell count: < 5

  - Triangle: (40°, -100°), (40°, -90°), (35°, -95°)
    Expected: Simple 3-vertex polygon
    Expected latency: < 100μs (p99)
    Expected cell count: < 50

  Success Criteria (ALL MUST PASS):
  - Measured latency ≤ 100μs (p99)
  - Cell count ≤ 50
  - Cross-platform consistency: Within ±15% of x86-64 Linux baseline (see platform matrix)

  Class 2: MODERATE (tens to hundreds of cells)
  ───────────────────────────────────────────
  Geometry: Medium radius or moderate polygon

  Test Cases:
  - Radius 1km at (35.6762, 139.6503) [Tokyo]
    Expected: 50-100 cells at mixed levels
    Expected latency: < 500μs (p99)
    Expected cell count: 50-150

  - Radius 5km at (48.8566, 2.3522) [Paris]
    Expected: 100-300 cells
    Expected latency: < 800μs (p99)
    Expected cell count: 100-400

  - Pentagon: 50-vertex regular polygon at (37.7749, -122.4194) [SF]
    Expected: ~100-200 cells
    Expected latency: < 750μs (p99)
    Expected cell count: 100-300

  Success Criteria:
  - Measured latency ≤ 1ms (p99)
  - Cell count: 50-500
  - Covering efficiency > 80% (covering_cells / bounding_box_cells)

  Class 3: COMPLEX (hundreds to 1000+ cells)
  ──────────────────────────────────────────
  Geometry: Large radius or complex polygon

  Test Cases:
  - Radius 50km at (40.7128, -74.0060) [NYC metro]
    Expected: 500-1000 cells
    Expected latency: < 2ms (p99)
    Expected cell count: 500-1500

  - Radius 100km at equator
    Expected: 1000-2000 cells
    Expected latency: < 5ms (p99)
    Expected cell count: 1000-3000

  - Complex polygon: 200-vertex polygon (e.g., US state boundary simplified)
    Expected: ~500-2000 cells
    Expected latency: < 5ms (p99)
    Expected cell count: 500-2500

  - Polygon spanning antimeridian: vertices at lon ±170° to ±175°
    Expected: Proper antimeridian handling
    Expected cell count: < 3000
    Expected latency: < 10ms (p99)

  Success Criteria:
  - Measured latency ≤ 5-10ms (p99) depending on geometry
  - Cell count ≤ 3000 (max_cells limit)
  - No truncation errors (max_cells_exceeded = false)

  Class 4: VERY COMPLEX (geometries near max_cells limit)
  ─────────────────────────────────────────────────────
  Geometry: Very large radius or highly complex polygon

  Test Cases:
  - Radius 500km (continental scale)
    Expected: 2000-8000 cells
    Expected latency: < 20ms (p99)
    Note: May approach or hit max_cells limit

  - Radius 1000km (near half-globe)
    Expected: 5000-10000+ cells, possible truncation
    Expected latency: < 50ms (p99)
    Note: Truncation is acceptable; truncate_cells=true

  - Polygon with 500+ vertices (complex coastline)
    Expected: 2000-5000 cells
    Expected latency: < 25ms (p99)

  - Global equatorial zone (+/- 30° latitude)
    Expected: Entire equatorial band
    Expected cell count: > 10,000 (definite truncation)
    Expected latency: < 100ms (p99)
    Note: This exceeds targets; documented as NOT SUITABLE for p99 < 50ms

  Success Criteria (PASS-with-Limitation):
  - Measured latency ≤ 20-100ms (p99) depending on geometry
    [Note: PASS criterion, but exceeds typical query target (<50ms). Document in query planning guide.]
  - Truncation acceptance:
    IF cell count exceeds max_cells (8192):
      THEN PASS if: (a) truncation is deterministic (always same cells for same geometry)
                     (b) cell count is fully populated up to max_cells (no gaps in covering)
                     (c) truncation is documented in query result (truncated_by_max_cells flag)
      THEN FAIL if: (a) truncation is nondeterministic (different cells for same geometry)
                     (b) partial covering returned (fewer than max_cells when more cells exist)
  - Cross-platform consistency: Within ±15% of x86-64 Linux baseline
  - Query Planner Guidance:
    - Geometries in this class should be flagged as "exceeds performance targets"
    - Recommend using smaller radii or simplified polygon boundaries for typical (<50ms) queries
    - Suitable for background analytics or reporting, not real-time transactional queries

  EDGE CASES (all complexity classes):
  ──────────────────────────────────────

  1. Radius 0m (point query)
     Expected: 1 cell at level 30
     Latency: < 50μs

  2. Exact pole (lat = ±90°)
     Expected: Valid covering at any level, no crash
     Latency: < 100μs

  3. Antimeridian crossing
     Expected: Proper wrapping, no cell duplication
     Cell count: Matches non-crossing equivalent

  4. Very large radius (> 10,000 km)
     Expected: Truncation at max_cells (safe degradation)
     Latency: < 100ms (p99)

  5. Degenerate polygon (< 3 vertices, self-intersecting)
     Expected: Rejected with validation error (or skip if already validated)
     Latency: N/A (error path, not measured)

  MEASUREMENT PROCEDURE:
  ──────────────────────

  For each test case:

  1. Prepare geometry and parameters
  2. Run 1000 warm-up iterations (discard)
  3. Run 10,000+ measurement iterations
     - Measure `archerdb_s2_covering_duration_seconds` histogram
     - Record actual cell count returned
  4. Collect statistics: mean, p50, p99, p99.9 latencies
  5. Collect metrics: cell_count, max_cells_exceeded, truncated
  6. Repeat on 3+ platforms
  7. Compare results: Verify latency ±15%, cell count exact match

  Success: All measured values within expected bounds
  Failure: > 5% of iterations exceed p99 target

  VALIDATION CHECKLIST:
  ──────────────────────

  □ Class 1 (SIMPLE) latencies < 100μs (p99)
  □ Class 2 (MODERATE) latencies < 1ms (p99)
  □ Class 3 (COMPLEX) latencies < 5-10ms (p99)
  □ Class 4 (VERY COMPLEX) documented as exceeding targets

  □ Cell counts within expected ranges for each class
  □ Antimeridian geometries produce correct cell counts
  □ Pole geometries handled without crashes
  □ Truncation is deterministic (same input → same cells)

  □ Cross-platform consistency (±15% latency variance acceptable)
  □ No platform-specific covering divergence
  □ Metrics correctly recorded in Prometheus

  □ Edge cases explicitly tested and documented
  □ Performance assumptions validated empirically
  □ Degradation graceful (truncation acceptable, no corruption)

  REGRESSION TESTING:
  ──────────────────

  After each code change to S2 covering:
  1. Run full test suite (all 4 complexity classes)
  2. Compare to baseline (previous runs)
  3. Alert if any latency exceeds baseline by > 10% (p99)
  4. Alert if cell count diverges from expected
  5. Maintain historical benchmark results in `/testdata/s2/benchmarks_log.tsv`

  DOCUMENTATION REQUIREMENTS:
  ──────────────────────────

  Each test case SHALL document:
  - Geometry type and parameters
  - Why this test case matters (coverage gap, edge case, etc.)
  - Expected behavior
  - Maximum acceptable latency (p99)
  - Expected cell count range
  - Known limitations or degradations
  ```

#### Scenario: S2 cross-replica verification

- **WHEN** a replica receives a prepare with GeoEvents
- **THEN** each replica SHALL:
  1. Independently compute `s2_cell_id` from `lat_nano`, `lon_nano`
  2. Construct composite ID: `id = (s2_cell_id << 64) | timestamp_ns`
  3. Compare computed ID with prepare message ID
  4. If mismatch: PANIC with "S2 cell ID divergence detected"
- **AND** this runtime check catches S2 non-determinism in production
- **AND** metric: `archerdb_s2_verification_failures_total` (SHALL always be 0)

#### Scenario: TTL Determinism in Queries

- **WHEN** checking if an event is expired during query execution (radius, polygon, lookup)
- **THEN** the system SHALL use the **consensus timestamp** of the operation (assigned by the primary during Prepare phase).
- **AND** the system SHALL NOT use `clock.now_synchronized()` or any local wall clock during execution.
- **AND** `state_machine.commit()` receives the timestamp; this value MUST be passed down to the query engine filter logic.
- **AND** this ensures that a query executing on Replica A (fast) and Replica B (slow) produces identical results even if an event expires in the interim.

#### Scenario: Timestamp Threading Through Three Phases

- **WHEN** a query (radius/polygon/lookup) is executed
- **THEN** the consensus timestamp MUST be threaded as:
  1. **Prepare Phase** (primary only):
     - `prepare(operation, body) -> prepare_timestamp` (derived from accumulated delta_ns)
     - Timestamp assigned before consensus
  2. **Prefetch Phase**:
     - `prefetch(callback, op, operation, body, prepare_timestamp)`
     - Timestamp optionally passed for context; not used for expiration checks
  3. **Commit/Execute Phase** (all replicas):
     - `commit(client, op, consensus_timestamp, operation, body, output)`
     - VSR delivers `consensus_timestamp` from Prepare phase after consensus
     - Query engine uses `consensus_timestamp` for all TTL expiration checks:
       - UUID Lookup: Check IndexEntry.ttl_seconds vs consensus_timestamp
       - Radius Query: Skip expired events using consensus_timestamp
       - Polygon Query: Skip expired events using consensus_timestamp
- **AND** each query result MUST document the consensus_timestamp used (for debugging, audit trail).
- **AND** replication is deterministic: Replica A and B with identical state produce identical results for the same query at the same consensus_timestamp.

### Requirement: UUID Lookup Query

The system SHALL support O(1) lookup of the latest location for a specific entity using the RAM index.

#### Scenario: Successful lookup

- **GIVEN** an entity with UUID `entity_id` exists in the index
- **WHEN** `get_latest(entity_id)` is called
- **THEN** the system SHALL:
  1. Look up IndexEntry in RAM index (O(1) hash lookup)
  2. Extract `latest_id` (composite ID) from IndexEntry
  3. Fetch the GeoEvent via storage point-lookup by ID (`get_event_by_id(latest_id)`)
  4. Return the full GeoEvent struct
- **AND** latency SHALL be less than 1ms at p99

#### Scenario: Entity not found

- **GIVEN** an entity with UUID `entity_id` does not exist
- **WHEN** `get_latest(entity_id)` is called
- **THEN** the system SHALL return null/none

#### Scenario: Prefetch for lookup

- **WHEN** prefetching for lookup operations
- **THEN** the system SHALL enqueue `latest_id` values for prefetch
- **AND** cache blocks containing the corresponding GeoEvents

### Requirement: Latest Events Query (query_latest)

The system SHALL support retrieving the N most recent events across the entire database for replay, debugging, and monitoring purposes.

#### Scenario: Basic query_latest operation

- **WHEN** `query_latest(limit, group_id_filter, cursor_timestamp)` is called
- **THEN** the system SHALL:
  1. Scan LSM tree in reverse chronological order (newest first)
  2. If `group_id_filter != 0`: filter by group_id
  3. If `cursor_timestamp != 0`: start from events with timestamp < cursor_timestamp
  4. Return up to `limit` events (max 81,000 per page)
  5. Order by: timestamp DESC, then entity_id ASC (deterministic tie-break)
- **AND** this query does NOT use spatial indexing (pure temporal scan)
- **AND** deleted entities (tombstones) SHALL be excluded

#### Scenario: query_latest request format

- **WHEN** encoding query_latest request (operation 0x14 / 20)
- **THEN** body SHALL contain:
  ```
  [limit: u32]              # Max results (default 1000, max 81000)
  [group_id: u64]           # Optional group filter (0 = all groups)
  [cursor_timestamp: u64]   # For pagination (0 = start from latest)
  [reserved: [48]u8]        # Alignment
  ```

#### Scenario: query_latest response format

- **WHEN** query_latest completes
- **THEN** response SHALL contain:
  ```
  QueryResponse {
    count: u32,            # number of results returned
    has_more: u8,          # 1 if more results available
    reserved: [3]u8,       # Alignment
    // followed by count × GeoEvent structs (128 bytes each)
  }
  ```

#### Scenario: Use cases for query_latest

- **WHEN** query_latest is appropriate
- **THEN** typical scenarios are:
  - **Event replay**: Stream processing, ETL pipelines (cursor-based pagination)
  - **Debugging**: Investigate recent activity (latest 100-1000 events)
  - **Monitoring dashboards**: Display recent events in admin UI
  - **Compliance audits**: Retrieve recent activity logs for specific group_id
- **AND** query_latest is NOT for production spatial queries (use radius/polygon instead)
- **AND** large-scale replay SHOULD use group_id partitioning to parallelize

#### Scenario: Performance characteristics

- **WHEN** executing query_latest
- **THEN** performance SHALL be:
  - Latency: p99 < 100ms for limit=1000 (LSM L0 scan)
  - Latency: p99 < 500ms for limit=10000 (may hit L1)
  - Throughput: 10,000+ events/sec for sequential replay with pagination
- **AND** this is slower than UUID lookup (no index) but faster than full spatial scan

#### Scenario: Pagination with cursor

- **WHEN** paginating through results
- **THEN** client SHALL:
  1. Make initial request with cursor_timestamp=0
  2. Receive up to 81,000 events ordered by timestamp DESC
  3. Extract lowest timestamp T from results
  4. Make next request with cursor_timestamp=T
  5. Repeat until has_more=0
- **AND** concurrent writes during pagination may cause results to appear in later pages
- **AND** this is acceptable for debugging/replay use cases

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

#### Scenario: Polygon basic validation

- **WHEN** validating polygon input during input_valid()
- **THEN** the system SHALL check:
  1. **Empty polygon**: If vertex_count == 0, return error `polygon_empty` (113)
  2. **Too few vertices**: If vertex_count < 3 (after removing duplicates), return error `polygon_too_simple` (108)
  3. **Degenerate polygon**: If all vertices are collinear (zero area), return error `polygon_degenerate` (112)
  4. **Too many vertices**: If vertex_count > 10,000, return error `polygon_too_complex` (101)
- **AND** validation order SHALL be: empty → too few → degenerate → too many → self-intersecting
- **AND** collinearity detection uses signed area calculation:
  ```
  Collinearity check (zero area detection):
  area = 0
  for i in 0..n-1:
    j = (i + 1) % n
    area += vertices[i].x * vertices[j].y
    area -= vertices[j].x * vertices[i].y
  area = abs(area) / 2

  if area < epsilon (1e-10 in normalized coordinates):
    return DEGENERATE
  ```

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
  - Return error `polygon_too_large` (error code 111)
  - Log warning: "Polygon appears to wrap around world - likely malformed input"
- **AND** legitimate global queries SHALL use multiple smaller polygons

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
- **THEN** the system SHALL use fixed-point arithmetic where possible
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
- **AND** the imported timestamp SHALL be encoded in the GeoEvent ID low 64 bits:
  - `timestamp_ns = @as(u64, @truncate(event.id))`
- **AND** `timestamp_ns < prepare_timestamp` MUST be true
- **AND** imported events do not advance prepare_timestamp

#### Scenario: Timestamp validation

- **WHEN** a non-imported event is received
- **THEN** the GeoEvent ID low 64 bits MUST be zero (server assigns timestamp during prepare):
  - `@as(u64, @truncate(event.id)) == 0`
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
- **AND** this assumes:
  - S2 covering produces <16 cell ranges (documented empirically)
  - **HOT DATA assumption**: Query results are LSM L0/L1 cached (recent writes/queries)
  - Sequential read throughput: 3GB/s (typical NVMe)
  - Post-filter cost (S2 cell → actual radius): <5ms for typical queries
  - S2 covering duration: <1ms (median <100μs per line 299)
- **AND** cold-data queries (uncached entities) may exceed 50ms:
  - Penalty: +40-50ms for additional disk seeks/sequential reads
  - Recommend caching via read-ahead prefetch for known-hot spatial regions
- **AND** worst-case polygon queries (10K vertices, scattered entities) may exceed 50ms/100ms targets

#### Scenario: Polygon query latency target

- **WHEN** performing polygon queries on complex shapes
- **THEN** the system SHALL achieve:
  - p99 < 100ms for **moderate-complexity polygons** (< 100 vertices, <500 covering cells)
  - p50 < 40ms
- **AND** this assumes:
  - Polygon complexity: < 100 vertices for p99 < 100ms
  - S2 covering produces < 500 cells (typical covering, not worst-case)
  - Post-filter cost (containment check): <10ms for typical polygons
  - HOT DATA assumption: Query results are LSM L0/L1 cached
- **AND** **very complex polygons** (10K vertices, 10K+ covering cells):
  - S2 covering: up to 1ms p99 (line 300)
  - Cell scan: ~20ms (thousands of cells × 100-200μs per cell)
  - Post-filter containment: ~30-50ms (complex point-in-polygon tests)
  - **Expected p99: 50-100ms** (may exceed 100ms target)
  - Recommend using radius queries for simple cases; reserve polygons for moderate complexity
- **AND** clients SHOULD batch related queries to amortize covering cost

#### Scenario: View change failover target

- **WHEN** primary fails and view change occurs
- **THEN** the system SHALL achieve:
  - ≤ 3 seconds to elect new primary and resume operations
  - ≤ 1 second for failure detection (via aggressive heartbeats)
  - ≤ 2 seconds for view change protocol execution
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
    flags: u8,             // bit 0: has_cursor, bit 1: ascending, bit 2: has_group_id
    reserved: u16,
    limit: u32,            // max results (default: 81000, max: 81000)
    cursor_id: u128,       // if has_cursor=1, return results after this ID
    group_id: u64,         // if has_group_id=1, only return results matching this group
    // ... query-specific fields
  }
  ```
- **AND** response SHALL include:
  ```
  QueryResponse {
    count: u32,            // number of results returned
    has_more: u8,          // 1 if more results available
    partial_result: u8,    // 1 if response was truncated due to message size limit
    reserved: [2]u8,
    // followed by count × GeoEvent structs
  }
  ```

#### Scenario: Pagination ordering guarantee

- **WHEN** paginating through results
- **THEN** results SHALL be ordered by:
  1. `s2_cell` (primary)
  2. `timestamp` (secondary)
  3. `entity_id` (final tie-breaker for deterministic ordering)
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
- **AND** performance characteristics vary by polygon complexity:
  - **Simple polygons** (< 50 vertices): S2 covering ~5-10 cells, post-filter ~2ms, **p99 < 30ms**
  - **Moderate polygons** (50-100 vertices): S2 covering ~50-200 cells, post-filter ~5-10ms, **p99 < 100ms**
  - **Complex polygons** (100-1000 vertices): S2 covering ~200-1000 cells, post-filter ~20-50ms, **p99: 50-150ms** (may exceed target)
  - **Very complex polygons** (1000-10000 vertices): S2 covering > 1000 cells, post-filter > 50ms, **p99: 100-300ms** (expect significant delays)
- **AND** recommendation: Use radius queries for latency-critical operations; reserve polygons for analytical workloads

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
  - Allow ~81,000 events at 128 bytes each (practical limit with header overhead)

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
        - deletion timestamp is assigned by VSR prepare and encoded in the GeoEvent ID low 64 bits
        - lat_nano, lon_nano: 0 (tombstone has no meaningful location)
        - All other numeric fields: zero
     d. Persist tombstone via normal storage write path (append-only / LSM write)
     e. Remove entity from RAM index (`index.delete(entity_id)`)
  2. Return count deleted and count not found
- **AND** tombstone is a regular GeoEvent with flags.deleted=true
- **AND** append-only storage is preserved (LSM integrity maintained)
- **AND** compaction MUST retain tombstones until older versions are fully eliminated (see storage-engine tombstone handling)

#### Scenario: Tombstone exclusion from spatial queries (Live Entity Filter)

- **WHEN** executing radius or polygon queries
- **THEN** the query engine SHALL filter results against the RAM index:
  1. For each candidate record from the LSM scan:
     a. Perform a lookup in the RAM index for the record's `entity_id`
     b. If `entity_id` is NOT found in the RAM index: DISCARD (Entity is either logically deleted or the record is a duplicate/older version that has been superseded and the index entry was reclaimed after compaction).
     c. If `RAM_index[entity_id].latest_id` has `flags.deleted = true`: DISCARD
     d. If `RAM_index[entity_id].latest_id` is different from the record's `id` AND the query is for "latest only" (no time filter): DISCARD
  2. This "Live Entity Filter" ensures that logically deleted entities do not appear in spatial results, even if their historical records still exist in the LSM tree.
- **AND** this filtering is mandatory for strong consistency and GDPR compliance.

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
  3. **prefetch()**: No-op (no read prefetch required)
  4. **commit()**:
     - For each entity_id, write a tombstone GeoEvent via storage write path
     - For each entity_id, call `index.delete(entity_id)` (RAM index update)
     - No in-place modification of existing on-disk events is permitted

#### Scenario: Delete and compaction

- **WHEN** LSM compaction encounters tombstones (`flags.deleted = true`)
- **THEN** it SHALL follow the tombstone retention rules in `storage-engine/spec.md`:
  - Tombstones MAY need to be copied forward until all older versions are removed
  - Once safe, tombstones MAY be dropped and older versions MUST be absent
- **AND** disk space is reclaimed through compaction
- **AND** deletion becomes permanent once the deletion has been compacted past all older versions

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

#### Scenario: S2 scratch buffer pool exhaustion

- **WHEN** all S2 scratch buffers are in use (pool exhausted)
- **AND** a new polygon or radius query requires a scratch buffer
- **THEN** the system SHALL:
  - Queue the query until a scratch buffer becomes available
  - Apply backpressure via the concurrent query limit (queries share result and scratch pools)
  - Return `too_many_queries` error if queue depth exceeds threshold (default: 1000)
  - Log warning: "S2 scratch pool exhaustion - consider reducing max_concurrent_queries or increasing pool size"
- **AND** `s2_scratch_pool_size` SHALL equal or exceed `max_concurrent_queries`
- **AND** if `s2_scratch_pool_size < max_concurrent_queries`, some queries will be queued

### Requirement: Error Handling and Propagation

The system SHALL implement comprehensive error handling with clear propagation semantics through all execution phases.

#### Scenario: Error handling phase responsibilities

- **WHEN** errors occur during query execution
- **THEN** each phase SHALL handle errors as follows:
  - **input_valid() phase**: Syntactic and semantic validation errors (100-199 range)
  - **prepare() phase**: Timestamp assignment errors (rare, typically OK)
  - **prefetch() phase**: Async I/O errors, cache misses (200-299 state errors)
  - **commit() phase**: Execution errors, resource exhaustion (300-399 resource errors)
- **AND** errors SHALL be detected as early as possible (fail-fast principle)

#### Scenario: Validation error propagation

- **WHEN** input_valid() returns an error
- **THEN** the system SHALL:
  1. NOT call prepare/prefetch/commit phases
  2. Return error immediately to client via reply message
  3. Include error context (field name, actual value, expected range)
  4. Log validation error at DEBUG level (not ERROR - client input issue)
  5. Increment metric: `archerdb_validation_errors_total{error_code="<name>"}`
- **AND** validation errors are NEVER retriable (client must fix input)

#### Scenario: Multi-batch error propagation

- **WHEN** a multi-batch message contains 5 batches
- **AND** batch 3 encounters validation error (invalid_coordinates)
- **THEN** the system SHALL:
  1. Execute input_valid() for all 5 batches first (validate entire message)
  2. If ANY batch fails validation:
     - Stop processing immediately (fail-fast)
     - Return error response for first failed batch
     - Mark remaining batches as skipped
     - Set `partial_result = true` in reply header
  3. Encode multi-batch reply with:
     - No results for batches 1-2 (skipped due to batch 3 failure)
     - Error reply for batch 3 (error_code, context)
     - No results for batches 4-5 (skipped)
- **AND** this ensures transactional semantics (all-or-nothing validation)

#### Scenario: Multi-batch partial execution on resource exhaustion

- **WHEN** a multi-batch executes successfully for batches 1-3
- **AND** batch 4 encounters resource error (too_many_events, message_body_too_large)
- **THEN** the system SHALL:
  1. Commit results for batches 1-3 (already executed successfully)
  2. Return success replies for batches 1-3
  3. Return error reply for batch 4 (error_code, context)
  4. Skip batch 5 (not executed)
  5. Set `partial_result = true` in reply header
  6. Client SHALL retry batch 4-5 in a new message
- **AND** this provides graceful degradation (partial progress vs all-or-nothing failure)

#### Scenario: Prefetch I/O error handling

- **WHEN** prefetch() encounters storage error (checksum_mismatch, storage_unavailable)
- **THEN** the system SHALL:
  1. Invoke prefetch callback with error status
  2. Mark operation as failed
  3. Skip commit() phase for this operation
  4. Return error to client (mapped from storage error)
  5. Log storage error at ERROR level
  6. Increment metric: `archerdb_storage_errors_total{error_type="<type>"}`
- **AND** storage corruption errors (checksum_mismatch) SHALL panic the replica
- **AND** retriable storage errors (storage_unavailable) return `storage_unavailable` to client

#### Scenario: Commit phase error handling

- **WHEN** commit() encounters an error during execution
- **THEN** the system SHALL:
  1. Log error at ERROR level with full context
  2. Return error to client via reply message
  3. Increment error metric: `archerdb_query_errors_total{operation="<op>",error_code="<code>"}`
  4. Mark operation as completed (even if error - no retry at VSR level)
  5. Ensure deterministic error (all replicas must produce same error)
- **AND** non-deterministic errors (e.g., malloc failure) SHALL panic the replica

#### Scenario: Error determinism across replicas

- **WHEN** the same operation executes on multiple replicas
- **THEN** all replicas MUST produce identical errors:
  - Same error code
  - Same error context (entity_id, field values)
  - Same decision (success/failure)
- **AND** this is ensured by:
  - Deterministic input validation
  - Fixed-point arithmetic (no floats)
  - Identical S2 library behavior
  - Deterministic timestamp assignment
- **AND** if replicas diverge on errors, VSR will detect via hash chain mismatch

#### Scenario: VSR layer error mapping

- **WHEN** VSR layer produces an error
- **THEN** it SHALL be mapped to client-facing error codes:
  ```
  VSR Error → Client Error Code
  ═══════════════════════════════════
  Primary unreachable → cluster_unavailable (201)
  Quorum not available → cluster_unavailable (201)
  View change triggered → view_change_in_progress (202)
  This replica not primary → not_primary (203)
  Session expired → session_expired (204)
  Duplicate request → duplicate_request (205)
  Pipeline full → pipeline_full (308)
  ```
- **AND** all VSR errors are retriable (client SHALL retry on different replica or wait)

#### Scenario: Panic vs error return decision

- **WHEN** deciding between panic and error return
- **THEN** the system SHALL:
  - **Panic**: Data corruption, invariant violation, non-deterministic error, impossible state
  - **Error Return**: Invalid input, resource exhaustion, retriable failures, expected conditions
- **AND** panic triggers:
  - Checksum mismatch on read
  - Assertion failure
  - Reached @unreachable code
  - Hash chain break in same view
  - malloc/alloc failure (should never happen with StaticAllocator)
- **AND** error return triggers:
  - Invalid coordinates, TTL overflow, empty batch (client input)
  - Entity not found, cluster unavailable (state)
  - Too many events, result set too large (resource)

#### Scenario: Error context encoding

- **WHEN** encoding error context for client response
- **THEN** the context SHALL include:
  - **For validation errors**: field name, provided value, valid range
    ```
    invalid_coordinates:
      field: "lat_nano"
      provided: 95000000000  # 95°
      valid_range: [-90000000000, 90000000000]
    ```
  - **For state errors**: entity_id, operation attempted
    ```
    entity_not_found:
      entity_id: "01234567-89ab-cdef-0123-456789abcdef"
      operation: "query_uuid"
    ```
  - **For resource errors**: current value, limit, metric
    ```
    too_many_events:
      batch_size: 15000
      batch_events_max: 10000
      message: "Batch exceeds maximum event count"
    ```

#### Scenario: Error logging levels

- **WHEN** logging errors
- **THEN** the system SHALL use appropriate log levels:
  - **DEBUG**: Validation errors (client input issues)
  - **INFO**: Retriable errors (cluster_unavailable, view_change_in_progress)
  - **WARN**: Resource exhaustion (too_many_queries, memory_exhausted)
  - **ERROR**: Storage errors, unexpected failures
  - **CRITICAL**: Data corruption, invariant violations
- **AND** DEBUG/INFO errors do NOT page on-call engineers
- **AND** WARN errors trigger low-priority alerts
- **AND** ERROR/CRITICAL errors page immediately

#### Scenario: Client SDK error handling expectations

- **WHEN** a client SDK receives an error response
- **THEN** it SHALL:
  1. Parse error code from response header
  2. Check `ErrorCode.is_retriable(error_code)`
  3. If retriable: apply exponential backoff and retry
  4. If not retriable: return error to application immediately
  5. For `not_primary` error: rotate connection pool to next replica
  6. For `partial_result` flag: check which batches succeeded/failed
  7. Extract and surface error context to application
- **AND** SDKs SHALL provide typed error objects (not raw error codes)
- **AND** SDKs SHALL log retries at DEBUG level

#### Scenario: Graceful degradation strategy

- **WHEN** the system encounters resource constraints
- **THEN** it SHALL gracefully degrade rather than fail completely:
  - **Memory pressure**: Queue queries, return `too_many_queries` only when queue full
  - **Disk full**: Accept reads, reject writes with `disk_full`
  - **CPU saturation**: Apply query CPU budget, reject queries exceeding budget
  - **Network partition**: Continue serving reads from replicas with quorum
- **AND** graceful degradation ensures partial availability over complete failure

### Requirement: Cold-Start Performance SLA

The system SHALL define and meet performance targets for cluster cold starts (full restart) across three distinct recovery scenarios based on checkpoint validity and data volume.

#### Scenario: Cold start with valid recent checkpoint

- **WHEN** the cluster restarts with a valid index checkpoint (< 2 minutes old)
- **THEN** recovery SHALL complete in:
  - **p50**: < 20 seconds (checkpoint load + partial WAL replay)
  - **p99**: < 60 seconds (checkpoint load + full WAL replay if needed)
- **AND** the system SHALL be able to accept queries as soon as VSR quorum is formed
- **AND** recovery operations (checkpoint load, WAL replay) SHALL NOT block query serving
- **AND** this is the expected case in production (nominal recovery path)

#### Scenario: Cold start with missing or old checkpoint

- **WHEN** the cluster restarts with no valid checkpoint or checkpoint > 5 minutes old
- **THEN** recovery SHALL fall back to LSM replay:
  - **p50**: < 15 seconds (small LSM scan for recent changes)
  - **p99**: < 45 seconds (scan through L0 + partial L1 tables)
- **AND** this path occurs ~1-2% of the time (if checkpointing fails)
- **AND** operators SHALL be alerted if `archerdb_index_checkpoint_age_seconds > 300`

#### Scenario: Cold start with corrupted checkpoint (worst case)

- **WHEN** the cluster restarts with corrupted or unavailable checkpoint
- **THEN** recovery SHALL fall back to full LSM rebuild:
  - **128GB data file (1B entities)**: < 2 minutes (p99)
    - Sequential disk read: ~45 seconds at 3GB/s
    - Index insertion overhead: ~15 seconds
  - **16TB data file (cluster max capacity)**: < 2 hours (p99)
    - Sequential disk read: ~89 minutes at 3GB/s
    - Index insertion overhead: ~30 minutes
- **AND** this path is ONLY expected if checkpoint storage fails
- **AND** cluster SHALL continue serving reads (replicas) during rebuild on primary
- **AND** operators SHALL monitor for `archerdb_recovery_path_taken{path="rebuild"}` increments

#### Scenario: Partial cluster restart (single node failure)

- **WHEN** a single replica fails and restarts while others continue
- **THEN** the restarting node SHALL:
  - Trigger VSR view change if primary fails (quorum election)
  - Join as backup and perform catch-up (see replication-engine/spec.md)
  - Perform recovery in parallel with catch-up to minimize availability impact
- **AND** cluster availability SHALL NOT be affected (quorum remains active)
- **AND** recovery latency targets are the same as full cluster restart (above)

#### Scenario: Rolling restart (maintenance)

- **WHEN** operators perform controlled rolling restart (one replica at a time)
- **THEN** the system SHALL:
  - Maintain quorum at all times (restart only backups first, then primary last)
  - Each restarting node performs recovery independently (see scenarios above)
  - Other nodes continue to serve queries and replicate
- **AND** operators SHOULD use `--wait-for-checkpoint` flag to ensure fast recovery:
  - Blocks node startup until checkpoint age < 60 seconds
  - Prevents worst-case 2-hour rebuild scenario
- **AND** cluster availability SHALL NOT decrease during rolling restart

#### Scenario: Cold-start monitoring and alerting

- **WHEN** tracking cold start performance
- **THEN** the system SHALL expose metrics:
  ```
  # Index checkpoint age (seconds since last successful checkpoint)
  archerdb_index_checkpoint_age_seconds gauge

  # Number of operations between index checkpoint and VSR stable
  archerdb_index_checkpoint_lag_ops gauge

  # Recovery path taken on last startup (wal/lsm/rebuild)
  archerdb_recovery_path_taken{path="wal"|"lsm"|"rebuild"} counter

  # Duration of recovery operation
  archerdb_recovery_duration_seconds histogram

  # Number of events processed during recovery
  archerdb_recovery_events_processed counter

  # Throughput of recovery (events/sec)
  archerdb_recovery_throughput_events_per_sec gauge
  ```
- **AND** alert thresholds SHALL be:
  - **Warning** (yellow): `index_checkpoint_age_seconds > 120` (2 minutes)
  - **Critical** (red): `index_checkpoint_age_seconds > 300` (5 minutes)
  - **Critical** (red): `recovery_path_taken{path="rebuild"}` increments (full rebuild triggered)
- **AND** operators SHALL investigate if recovery takes > 50% of p99 target

#### Scenario: Preventing worst-case recovery

- **WHEN** ensuring fast cold starts
- **THEN** operators SHALL:
  1. **Enable automatic checkpointing** (default: every 60 seconds)
  2. **Monitor `index_checkpoint_age_seconds` continuously** (add to dashboards)
  3. **Alert if checkpointing stalls** (age increases without bound)
  4. **Provision sufficient disk space** for checkpoint (≥256GB for 1B entities)
  5. **Use hardware with fast NVMe** (>2GB/s sequential write for checkpoints)
  6. **Test recovery procedures regularly**:
     - Kill -9 primary node, measure recovery time
     - Simulate checkpoint corruption, measure rebuild time
     - Use chaos testing to validate recovery under failure conditions
  7. **Configure `--wait-for-checkpoint` in production**:
     - Ensures nodes don't start with very old checkpoints
     - Prevents accidental 2-hour rebuilds during maintenance
- **AND** operators SHALL maintain runbook: "How to Recover from Checkpoint Corruption"

#### Scenario: Recovery SLA trade-off guidance

- **WHEN** tuning recovery parameters
- **THEN** the following guidance SHALL apply:
  ```
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │                    RECOVERY TIME TRADE-OFF TABLE                             │
  ├─────────────────────────┬──────────────┬──────────┬─────────────────────────┤
  │ Configuration           │ p99 Time     │ Risk     │ When to Use             │
  ├─────────────────────────┼──────────────┼──────────┼─────────────────────────┤
  │ Checkpoint every 30s    │ < 30s        │ Medium   │ Very strict SLA         │
  │ (Default) every 60s     │ < 60s        │ Low      │ Most deployments        │
  │ Checkpoint every 120s   │ < 2min       │ Medium   │ Cost-sensitive ops      │
  │ Checkpoint every 300s   │ < 5min       │ High     │ NOT recommended         │
  │ Checkpoint disabled     │ < 2 hours    │ EXTREME  │ Dev/test only           │
  └─────────────────────────┴──────────────┴──────────┴─────────────────────────┘

  Recommendation:
  - Production: Use default (60s checkpoint interval, < 60s p99)
  - Staging: 60-120s (cost-conscious, accept higher p99)
  - Development: Disable checkpointing (rebuild on every restart acceptable)

  Memory trade-off:
  - Checkpoint requires 64MB scratch buffer per 1B entities
  - Negligible compared to 128GB index size
  - Do NOT disable checkpointing to save this memory
  ```

### Related Specifications

- See `specs/error-codes/spec.md` for complete error code enumeration and metadata
- See `specs/client-protocol/spec.md` for error response wire format
- See `specs/client-retry/spec.md` for client-side retry semantics
- See `specs/replication/spec.md` for VSR error conditions and view changes
- See `specs/storage-engine/spec.md` for storage layer error handling
- See `specs/observability/spec.md` for error metrics and logging requirements
- See `specs/hybrid-memory/spec.md` for index recovery and checkpoint details

## Implementation Status

**Overall: 90% Complete** (excluding Forest-blocked features)

### Core Query Features

| Feature | File | Status |
|---------|------|--------|
| S2 Cell ID Generation | `src/s2_index.zig` | ✓ Complete |
| S2 Level Selection | `src/s2_index.zig` | ✓ Complete |
| Radius Query Covering | `src/s2_index.zig` | ✓ Complete |
| Distance Post-Filter | `src/s2_index.zig` | ✓ Complete |
| Point-in-Polygon Filter | `src/s2_index.zig` | ✓ Complete |
| Query Result Limiting | `src/geo_state_machine.zig` | ✓ Complete |
| Polygon Validation | `src/s2_index.zig`, `src/geo_state_machine.zig` | ✓ Complete |
| Insert Events | `src/geo_state_machine.zig:1515-1644` | ✓ Complete |
| Query UUID | `src/geo_state_machine.zig:1682-1778` | ✓ Complete |
| Query Radius | `src/geo_state_machine.zig:1887-2071` | ✓ Complete |
| Query Polygon | `src/geo_state_machine.zig:2096-2348` | ✓ Complete |
| Admin Ping | `src/geo_state_machine.zig:1780-1793` | ✓ Complete |
| Admin Status | `src/geo_state_machine.zig:1795-1848` | ✓ Complete |
| QueryResponse struct | `src/geo_state_machine.zig:627-670` | ✓ Complete |
| QueryResponse has_more | `src/geo_state_machine.zig:2061-2071` | ✓ Complete |
| Pagination (cursor) | `src/geo_state_machine.zig` | Stub only |
| Forest LSM Integration | - | Pending Forest |

### Pagination Implementation Details

| Component | File:Line | Status | Blocker |
|-----------|-----------|--------|---------|
| QueryLatestFilter struct | `geo_state_machine.zig:595-624` | ✓ Complete | None |
| cursor_timestamp field | `geo_state_machine.zig:607` | ✓ Defined | None |
| query_result_max constant | `constants.zig:871` | ✓ Complete | None |
| QueryResponse struct | `geo_state_machine.zig:627-670` | ✓ Complete | None |
| Message size truncation | `geo_state_machine.zig:1925-1934` | ✓ Complete | None |
| execute_query_latest | `geo_state_machine.zig:1277` | Stub (returns 0) | Forest LSM |
| Cursor-based range scans | - | ✗ Missing | Forest LSM |
| has_more flag in response | `geo_state_machine.zig:2061-2071` | ✓ Complete | None |

**Unblocked Work** - All Complete:
- ~~QueryResponse struct definition and serialization~~ ✓ Done
- ~~Message size limit detection in query execution~~ ✓ Done
- ~~Response header marshalling with has_more flag~~ ✓ Done

**Blocked by Forest LSM** (~400 lines):
- execute_query_latest full implementation
- Cursor-based positioned reads on LSM trees
- ID-based pagination (id > cursor_id filtering)

### Implementation Notes

- S2 library provides deterministic cell ID generation across platforms
- Dynamic level selection (1-30) based on query radius implemented
- Haversine distance calculation for accurate post-filtering
- Ray-casting algorithm for polygon containment working correctly
- Polygon validation added: `isPolygonDegenerate()`, `isPolygonSelfIntersecting()`, `isPolygonTooLarge()` in `s2_index.zig`
