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
  - `max_cells`: 16 (default) - Limit query complexity
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
  - covering_duration: median < 100μs, p99 < 1ms
  ```

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
- **AND** rows SHOULD be sorted by `(level, lat_nano, lon_nano)` for stable diffs

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
- **AND** longitude degeneracy at poles SHALL be handled correctly
- **AND** S2's cube-face projection naturally handles polar regions

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

#### Scenario: S2 cross-replica verification

- **WHEN** a replica receives a prepare with GeoEvents
- **THEN** each replica SHALL:
  1. Independently compute `s2_cell_id` from `lat_nano`, `lon_nano`
  2. Construct composite ID: `id = (s2_cell_id << 64) | timestamp_ns`
  3. Compare computed ID with prepare message ID
  4. If mismatch: PANIC with "S2 cell ID divergence detected"
- **AND** this runtime check catches S2 non-determinism in production
- **AND** metric: `archerdb_s2_verification_failures_total` (should always be 0)

#### Scenario: TTL Determinism in Queries

- **WHEN** checking if an event is expired during query execution (radius, polygon, lookup)
- **THEN** the system SHALL use the **consensus timestamp** of the operation (assigned by the primary during Prepare phase).
- **AND** the system SHALL NOT use `clock.now_synchronized()` or any local wall clock during execution.
- **AND** `state_machine.commit()` receives the timestamp; this value MUST be passed down to the query engine filter logic.
- **AND** this ensures that a query executing on Replica A (fast) and Replica B (slow) produces identical results even if an event expires in the interim.

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
- **AND** this assumes S2 covering produces <16 cell ranges

#### Scenario: Polygon query latency target

- **WHEN** performing polygon queries on complex shapes
- **THEN** the system SHALL achieve:
  - p99 < 100ms (more complex than radius due to irregular covering)
  - p50 < 40ms

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
- **AND** `s2_scratch_pool_size` SHOULD equal or exceed `max_concurrent_queries`
- **AND** if `s2_scratch_pool_size < max_concurrent_queries`, some queries will be queued
