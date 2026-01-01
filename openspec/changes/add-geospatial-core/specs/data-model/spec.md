# Data Model Specification

## ADDED Requirements

### Requirement: GeoEvent Structure

The system SHALL store geospatial events in a fixed-size 128-byte `extern struct` with explicit memory layout guarantees matching TigerBeetle's data-oriented design.

#### Scenario: Struct size and alignment validation

- **WHEN** the GeoEvent struct is compiled
- **THEN** `@sizeOf(GeoEvent)` MUST equal exactly 128 bytes
- **AND** `@alignOf(GeoEvent)` MUST equal 16 bytes (u128 boundary)
- **AND** `stdx.no_padding(GeoEvent)` MUST return true (zero implicit padding)

#### Scenario: Field layout with no padding

- **WHEN** a GeoEvent is defined as `extern struct`
- **THEN** fields SHALL be arranged to pack efficiently without compiler-inserted gaps
- **AND** field order SHALL be: largest alignment first, then descending size
- **AND** the sum of all field sizes MUST equal exactly 128 bytes

#### Scenario: Complete field specification

- **WHEN** a GeoEvent is created
- **THEN** it SHALL contain these fields in order:
  - `id: u128` (16 bytes) - Composite key [S2 Cell ID (upper 64) | Timestamp (lower 64)]
  - `entity_id: u128` (16 bytes) - UUID identifying the moving entity
  - `correlation_id: u128` (16 bytes) - UUID for trip/session/job correlation
  - `user_data: u128` (16 bytes) - Opaque application metadata (sidecar database FK)
  - `lat_nano: i64` (8 bytes) - Latitude in nanodegrees
  - `lon_nano: i64` (8 bytes) - Longitude in nanodegrees
  - `altitude_mm: i32` (4 bytes) - Altitude in millimeters above WGS84
  - `velocity_mms: u32` (4 bytes) - Speed in millimeters per second
  - `group_id: u64` (8 bytes) - Fleet/region grouping identifier
  - `ttl_seconds: u32` (4 bytes) - Time-to-live in seconds (0 = never expires)
  - `heading_cdeg: u16` (2 bytes) - Heading in centidegrees (0-36000)
  - `accuracy_mm: u16` (2 bytes) - GPS accuracy radius in millimeters
  - `flags: GeoEventFlags` (2 bytes) - Packed status bitmask
  - `reserved: [22]u8` (22 bytes) - Reserved for future use (must be zero)

### Requirement: Packed Flags Structure

The system SHALL use a packed struct backed by u16 for boolean flags with explicit padding bits for forward compatibility.

#### Scenario: GeoEventFlags definition

- **WHEN** GeoEventFlags is defined
- **THEN** it SHALL be `packed struct(u16)` with named boolean fields
- **AND** `@sizeOf(GeoEventFlags)` MUST equal `@sizeOf(u16)`
- **AND** `@bitSizeOf(GeoEventFlags)` MUST equal `@sizeOf(GeoEventFlags) * 8`

#### Scenario: Flag fields specification

- **WHEN** GeoEventFlags is created
- **THEN** it SHALL contain:
  - `linked: bool` (bit 0) - Event is part of a linked chain
  - `imported: bool` (bit 1) - Event was imported with client-provided timestamp
  - `stationary: bool` (bit 2) - Entity is not moving
  - `low_accuracy: bool` (bit 3) - GPS accuracy below threshold
  - `offline: bool` (bit 4) - Entity is offline/unreachable
  - `deleted: bool` (bit 5) - Entity has been deleted (for GDPR compliance)
  - `padding: u10` (bits 6-15) - Reserved, must be zero

### Requirement: BlockHeader Structure

The system SHALL wrap batches of GeoEvent records in blocks with a 256-byte header matching TigerBeetle's block header layout for defense-in-depth checksumming.

#### Scenario: Header size validation

- **WHEN** the BlockHeader struct is compiled
- **THEN** `@sizeOf(BlockHeader)` MUST equal exactly 256 bytes
- **AND** `stdx.no_padding(BlockHeader)` MUST return true

#### Scenario: Dual checksum fields

- **WHEN** a block header is defined
- **THEN** it SHALL contain separate checksums for header and body:
  - `checksum: u128` - Aegis-128L MAC of header (after this field)
  - `checksum_padding: u128` - Reserved for future u256 support
  - `checksum_body: u128` - Aegis-128L MAC of body
  - `checksum_body_padding: u128` - Reserved for future u256 support

#### Scenario: Complete header fields

- **WHEN** a block is written
- **THEN** the header SHALL contain (after checksums):
  - `nonce_reserved: u128` - Reserved for future AEAD encryption
  - `cluster: u128` - Cluster identifier (prevents misdirection)
  - `size: u32` - Total size (header + body) in bytes
  - `epoch: u32` - Cluster epoch number
  - `view: u32` - VSR view number when block was written
  - `sequence: u32` - Monotonic sequence within file
  - `block_type: BlockType` (u8) - Enum: free_set, manifest, index, data
  - `reserved_frame: [7]u8` - Frame-level reserved bytes
  - `address: u64` - Grid block address (1-based, 0 is sentinel)
  - `snapshot: u64` - Snapshot ID for MVCC visibility
  - `min_id: u128` - Minimum GeoEvent ID in block (skip-scan hint)
  - `max_id: u128` - Maximum GeoEvent ID in block (skip-scan hint)
  - `count: u32` - Number of valid GeoEvent records
  - `reserved: [36]u8` - Reserved for future use

### Requirement: Fixed-Point Coordinates

The system SHALL use integer fixed-point representation for all coordinates and measurements to ensure deterministic behavior across CPU architectures.

#### Scenario: Latitude/Longitude as nanodegrees

- **WHEN** coordinates are stored
- **THEN** latitude and longitude SHALL be stored as i64 nanodegrees (10^-9 degrees)
- **AND** valid latitude range is -90,000,000,000 to +90,000,000,000 nanodegrees (±90°) INCLUSIVE
- **AND** valid longitude range is -180,000,000,000 to +180,000,000,000 nanodegrees (±180°) INCLUSIVE
- **AND** boundaries are INCLUSIVE: North Pole (+90°), South Pole (-90°), ±180° meridian are all valid
- **AND** data representation precision is approximately 0.1 millimeters (not measurement accuracy)
- **AND** coordinates outside valid ranges SHALL be rejected during validation with error `invalid_coordinates`

#### Scenario: Coordinate conversion functions

- **WHEN** converting from floating-point degrees to nanodegrees
- **THEN** `lat_nano = @as(i64, @intFromFloat(lat_float * 1_000_000_000.0))`
- **WHEN** converting from nanodegrees to floating-point
- **THEN** `lat_float = @as(f64, @floatFromInt(lat_nano)) / 1_000_000_000.0`

#### Scenario: Motion measurements as millimeters

- **WHEN** altitude is stored
- **THEN** it SHALL be in millimeters as i32 (supports ±2,147 km range)
- **WHEN** velocity is stored
- **THEN** it SHALL be in millimeters per second as u32 (max ~4,295 km/s)
- **WHEN** accuracy is stored
- **THEN** it SHALL be in millimeters as u16 (max ~65 meters radius)

### Requirement: Space-Major Composite ID

The system SHALL construct the primary key as a Space-Major composite using bit operations to optimize spatial range queries.

#### Scenario: ID packing

- **WHEN** a GeoEvent ID is created
- **THEN** `id = (@as(u128, s2_cell_id) << 64) | @as(u128, timestamp_ns)`

#### Scenario: ID unpacking

- **WHEN** extracting components from an ID
- **THEN** `s2_cell_id = @as(u64, @truncate(id >> 64))`
- **AND** `timestamp_ns = @as(u64, @truncate(id))`

#### Scenario: Sort order guarantees

- **WHEN** GeoEvents are sorted by ID
- **THEN** they SHALL be ordered primarily by S2 cell (spatial locality)
- **AND** secondarily by timestamp within each cell (temporal locality)

### Requirement: ID Generation

The system SHALL generate unique 128-bit identifiers using cryptographically secure random numbers with validation.

#### Scenario: CSPRNG-based generation

- **WHEN** generating a new entity_id or correlation_id
- **THEN** it SHALL use `std.crypto.random.int(u128)`
- **AND** the value MUST NOT equal 0
- **AND** the value MUST NOT equal `std.math.maxInt(u128)`

#### Scenario: ID validation on input

- **WHEN** an ID is received from a client
- **THEN** `id == 0` SHALL return error `id_must_not_be_zero`
- **AND** `id == maxInt(u128)` SHALL return error `id_must_not_be_int_max`

### Requirement: Reserved Fields Pattern

The system SHALL include reserved fields in all structs to enable forward-compatible schema evolution without changing struct sizes.

#### Scenario: Reserved field initialization

- **WHEN** a struct with reserved fields is created
- **THEN** all reserved fields SHALL be initialized to zero via `@splat(0)`
- **AND** reserved fields SHALL be validated as zero on read

#### Scenario: Reserved field sizing

- **WHEN** designing a struct
- **THEN** reserved bytes SHALL fill remaining space to reach target size (128/256 bytes)
- **AND** reserved fields enable adding new fields without migration

### Requirement: Comptime Validation

The system SHALL validate all struct layouts at compile time using Zig's comptime capabilities.

#### Scenario: Size assertions

- **WHEN** any data struct is defined
- **THEN** it SHALL include a comptime block with:
  - `assert(@sizeOf(T) == expected_size)`
  - `assert(@alignOf(T) == expected_alignment)`
  - `assert(stdx.no_padding(T))`

#### Scenario: No-padding helper function

- **WHEN** validating struct layout
- **THEN** `stdx.no_padding(T)` SHALL verify:
  - For extern structs: sum of field sizes equals struct size
  - For packed structs: bit size equals byte size * 8
  - All u128 fields are 16-byte aligned
