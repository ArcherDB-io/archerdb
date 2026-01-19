# Data Model - Sub-Meter Precision

## MODIFIED Requirements

### Requirement: Coordinate Precision

The system SHALL document and validate sub-meter coordinate precision.

#### Scenario: Nanodegree precision definition

- **WHEN** storing coordinates
- **THEN** the system SHALL use nanodegrees (10^-9 degrees)
- **AND** precision SHALL be:
  | Latitude | 1 nanodegree | Precision |
  |----------|--------------|-----------|
  | 0° (equator) | 0.111 mm | Sub-millimeter |
  | 30° | 0.096 mm | Sub-millimeter |
  | 45° | 0.079 mm | Sub-millimeter |
  | 60° | 0.056 mm | Sub-millimeter |
  | 80° | 0.019 mm | Sub-millimeter |
- **AND** this exceeds RTK GPS precision (1-2 cm) by approximately 100x

#### Scenario: Precision vs GPS technologies

- **WHEN** comparing to positioning technologies
- **THEN** nanodegree precision SHALL exceed:
  | Technology | Typical Accuracy | Nanodegree Advantage |
  |------------|------------------|---------------------|
  | Consumer GPS | 3-5 m | 30,000-50,000x |
  | Dual-frequency GPS | 0.3-1 m | 3,000-10,000x |
  | RTK GPS | 1-2 cm | 100-200x |
  | UWB Indoor | 10-30 cm | 1,000-3,000x |
  | Carrier-phase | 1-5 cm | 100-500x |
  | Survey-grade | 1-5 mm | 10-50x |

#### Scenario: Precision preservation requirement

- **WHEN** coordinates are stored and retrieved
- **THEN** exact nanodegree values SHALL be preserved
- **AND** no rounding or truncation SHALL occur in storage
- **AND** precision loss MAY occur only in SDK float64 conversion

### Requirement: S2 Index Precision

The system SHALL document S2 cell precision at each level.

#### Scenario: S2 level precision table

- **WHEN** using S2 spatial indexing
- **THEN** cell precision SHALL be:
  | Level | Cell Size (approx) | Use Case |
  |-------|-------------------|----------|
  | 12 | ~3.3 km | Regional queries |
  | 16 | ~153 m | Block-level queries |
  | 20 | ~10 m | Building-level |
  | 24 | ~0.6 m | Sub-meter |
  | 28 | ~4 cm | RTK GPS precision |
  | 30 | ~1 cm | High-precision GPS |

#### Scenario: Default S2 level for sub-meter

- **WHEN** sub-meter precision is required
- **THEN** S2 level 24+ (0.6m cells) SHALL be used
- **AND** for RTK applications, level 28+ (4cm cells) is RECOMMENDED

### Requirement: Sub-Meter Use Case Support

The system SHALL support sub-meter precision use cases.

#### Scenario: RTK GPS support

- **WHEN** RTK GPS coordinates (1-2 cm precision) are stored
- **THEN** the system SHALL preserve full precision
- **AND** queries SHALL return exact stored values
- **AND** documentation SHALL confirm RTK compatibility

#### Scenario: UWB indoor positioning support

- **WHEN** UWB coordinates (10-30 cm precision) are stored
- **THEN** the system SHALL preserve full precision
- **AND** sub-meter radius queries SHALL work correctly

#### Scenario: Precision agriculture support

- **WHEN** precision agriculture coordinates (10 cm) are stored
- **THEN** the system SHALL preserve full precision
- **AND** enable field-level spatial queries

### Requirement: SDK Precision Guidelines

Client SDKs SHALL preserve precision during coordinate conversion.

#### Scenario: Float64 conversion precision

- **WHEN** converting decimal degrees to nanodegrees
- **THEN** SDK SHALL:
  - Use integer arithmetic where possible
  - Preserve at least 9 decimal places
  - Document any precision limitations
- **AND** float64 provides 15-17 significant digits (sufficient for 9 decimal places)

#### Scenario: High-precision conversion

- **WHEN** maximum precision is required
- **THEN** SDK MAY provide:
  ```python
  # Python example using Decimal
  from decimal import Decimal
  lat_nano = int(Decimal("37.774929123") * Decimal("1000000000"))
  ```
- **AND** integer result SHALL be exact

#### Scenario: Precision validation

- **WHEN** SDK processes coordinates
- **THEN** SDK SHOULD warn if:
  - Coordinates exceed valid bounds
  - Conversion may lose significant digits
  - S2 level insufficient for required precision

## ADDED Requirements

### Requirement: Precision Test Coverage

The system SHALL include tests validating sub-meter precision.

#### Scenario: Exact value preservation test

- **WHEN** testing precision
- **THEN** the system SHALL verify:
  ```zig
  test "exact nanodegree preservation" {
      const original_lat: i64 = 37_774929123;
      const original_lon: i64 = -122_419415678;

      // Insert and retrieve
      const event = insertAndRetrieve(original_lat, original_lon);

      // Exact match required
      try testing.expectEqual(original_lat, event.lat_nano);
      try testing.expectEqual(original_lon, event.lon_nano);
  }
  ```

#### Scenario: RTK precision test

- **WHEN** testing RTK-level precision
- **THEN** the system SHALL verify:
  ```zig
  test "rtk precision preserved" {
      // RTK precision: 2cm ≈ 180 nanodegrees at equator
      const rtk_precision_nano: i64 = 180;

      // ... test that precision is maintained
  }
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Coordinate Precision | IMPLEMENTED | `src/geo_event.zig` - Nanodegree storage (i64 lat_nano, lon_nano) |
| S2 Index Precision | IMPLEMENTED | S2 levels up to 30 supported for sub-centimeter precision |
| Sub-Meter Use Case Support | IMPLEMENTED | Full precision preservation in storage and retrieval |
| SDK Precision Guidelines | IMPLEMENTED | All SDKs preserve full precision in coordinate conversion |
| Precision Test Coverage | IMPLEMENTED | Tests verify exact nanodegree round-trip preservation |

## Related Specifications

- See base `data-model/spec.md` for GeoEvent definition
- See `index-sharding/spec.md` for S2 configuration
- See `client-sdk/spec.md` for SDK requirements
