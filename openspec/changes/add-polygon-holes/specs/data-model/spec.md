# Data Model - Polygon Holes

## ADDED Requirements

### Requirement: HoleDescriptor Structure

The system SHALL define a `HoleDescriptor` structure for encoding polygon holes.

#### Scenario: HoleDescriptor memory layout

- **WHEN** encoding hole information in polygon queries
- **THEN** each hole SHALL be described by a `HoleDescriptor`:
  ```zig
  pub const HoleDescriptor = extern struct {
      /// Number of vertices in this hole ring
      vertex_count: u32,
      /// Reserved for future use (alignment)
      reserved: u32 = 0,

      comptime {
          assert(@sizeOf(HoleDescriptor) == 8);
          assert(stdx.no_padding(HoleDescriptor));
      }
  };
  ```
- **AND** the struct SHALL be 8 bytes
- **AND** the struct SHALL have no padding

#### Scenario: HoleDescriptor validation

- **WHEN** parsing a `HoleDescriptor`
- **THEN** the following SHALL be validated:
  - `vertex_count >= 3` (minimum for a valid ring)
  - `vertex_count <= polygon_vertices_max` (sanity check)
  - `reserved == 0` (reserved field unused)

### Requirement: Extended QueryPolygonFilter

The `QueryPolygonFilter` structure SHALL be extended to support holes.

#### Scenario: QueryPolygonFilter with hole_count

- **WHEN** defining the polygon query filter
- **THEN** the structure SHALL include a `hole_count` field:
  ```zig
  pub const QueryPolygonFilter = extern struct {
      /// Number of vertices in outer ring
      vertex_count: u32,
      /// Number of hole rings (0 for simple polygon)
      hole_count: u32,
      /// Maximum results to return
      limit: u32,
      /// Reserved for alignment
      _reserved_align: u32 = 0,
      /// Minimum timestamp (inclusive, 0 = no filter)
      timestamp_min: u64,
      /// Maximum timestamp (inclusive, 0 = no filter)
      timestamp_max: u64,
      /// Group ID filter (0 = no filter)
      group_id: u64,
      /// Reserved for future use
      reserved: [88]u8 = @splat(0),

      comptime {
          assert(@sizeOf(QueryPolygonFilter) == 128);
          assert(stdx.no_padding(QueryPolygonFilter));
      }
  };
  ```
- **AND** the struct SHALL remain 128 bytes (cache-line aligned)
- **AND** `hole_count = 0` SHALL indicate backwards-compatible simple polygon

#### Scenario: Message body parsing with holes

- **WHEN** parsing a polygon query message body
- **THEN** the parser SHALL:
  1. Read `QueryPolygonFilter` (128 bytes)
  2. Read `vertex_count` outer ring vertices (16 bytes each)
  3. If `hole_count > 0`:
     a. Read `hole_count` `HoleDescriptor` structs (8 bytes each)
     b. For each descriptor, read `vertex_count` hole vertices (16 bytes each)
- **AND** total parsed size SHALL match message body size

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| HoleDescriptor Structure | IMPLEMENTED | `src/geo_state_machine.zig` |
| Extended QueryPolygonFilter | IMPLEMENTED | `src/geo_state_machine.zig` |
