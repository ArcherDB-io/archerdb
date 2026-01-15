## ADDED Requirements

### Requirement: Polygon Hole Error Codes

The system SHALL define specific error codes for polygon hole validation failures.

#### Scenario: Error code 117 - too_many_holes

- **WHEN** a polygon query specifies more than 100 holes
- **THEN** the system SHALL return error code 117
- **AND** the error name SHALL be `too_many_holes`
- **AND** the error context SHALL include:
  - `hole_count`: The requested number of holes
  - `max_holes`: The maximum allowed (100)
- **AND** the error SHALL NOT be retryable

#### Scenario: Error code 118 - hole_vertex_count_invalid

- **WHEN** any hole ring in a polygon query has fewer than 3 vertices
- **THEN** the system SHALL return error code 118
- **AND** the error name SHALL be `hole_vertex_count_invalid`
- **AND** the error context SHALL include:
  - `hole_index`: Index of the invalid hole (0-based)
  - `vertex_count`: Number of vertices in the hole
  - `min_vertices`: Minimum required (3)
- **AND** the error SHALL NOT be retryable

#### Scenario: Error code 119 - hole_not_contained

- **WHEN** a hole ring is not fully contained within the outer ring
- **THEN** the system SHALL return error code 119
- **AND** the error name SHALL be `hole_not_contained`
- **AND** the error context SHALL include:
  - `hole_index`: Index of the invalid hole (0-based)
- **AND** the error SHALL NOT be retryable

#### Scenario: Error code 120 - holes_overlap

- **WHEN** two or more hole rings have overlapping bounding boxes
- **THEN** the system SHALL return error code 120
- **AND** the error name SHALL be `holes_overlap`
- **AND** the error context SHALL include:
  - `hole_index_1`: Index of first overlapping hole
  - `hole_index_2`: Index of second overlapping hole
- **AND** the error SHALL NOT be retryable

## MODIFIED Requirements

### Requirement: Validation Error Code Table

The validation error code table SHALL include polygon hole errors.

#### Scenario: Updated error code range

- **WHEN** documenting error codes
- **THEN** the validation error range (100-199) SHALL include:
  ```
  | Code | Name                      | Description                           | Retryable |
  |------|---------------------------|---------------------------------------|-----------|
  | 101  | polygon_too_complex       | Polygon has too many vertices (>10k)  | No        |
  | ...  | ...                       | ...                                   | ...       |
  | 108  | invalid_polygon           | Generic polygon validation failure    | No        |
  | 109  | polygon_self_intersecting | Polygon edges cross each other        | No        |
  | ...  | ...                       | ...                                   | ...       |
  | 117  | too_many_holes            | More than 100 holes specified         | No        |
  | 118  | hole_vertex_count_invalid | Hole has fewer than 3 vertices        | No        |
  | 119  | hole_not_contained        | Hole not contained in outer ring      | No        |
  | 120  | holes_overlap             | Two or more holes overlap             | No        |
  ```

#### Scenario: Error code documentation

- **WHEN** a client receives a polygon hole error
- **THEN** the error message SHALL clearly indicate:
  - Which validation failed
  - Which hole(s) caused the error (by index)
  - What the limit or requirement is

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| too_many_holes (117) | ✓ Complete | `error_codes.zig:111` |
| hole_vertex_count_invalid (118) | ✓ Complete | `error_codes.zig:113` |
| hole_not_contained (119) | ✓ Complete | `error_codes.zig:115` |
| holes_overlap (120) | ✓ Complete | `error_codes.zig:117` |
| Error descriptions | ✓ Complete | `.description()` methods |
| Non-retryable classification | ✓ Complete | `.isRetriable()` returns false |
