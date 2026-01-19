# Design: Sub-Meter Precision

## Context

ArcherDB uses nanodegrees (10^-9 degrees) stored as int64 for coordinates. This provides approximately 0.1mm precision at the equator. With advances in GPS technology (RTK, dual-frequency) and indoor positioning (UWB), this precision is now practically achievable.

## Goals / Non-Goals

### Goals

1. **Document precision**: Clear specification of capabilities
2. **Validate precision**: Prove through testing
3. **Enable use cases**: RTK, UWB, surveying

### Non-Goals

1. **Change data format**: Nanodegrees are sufficient
2. **Add precision options**: Already at maximum useful precision
3. **Support other coordinate systems**: WGS84 only

## Decisions

### Decision 1: Document Actual Precision

**Choice**: Clearly document precision at various latitudes.

**Rationale**:
- Nanodegrees vary in physical distance by latitude
- Users need to understand actual precision
- Enables informed decisions for use cases

**Implementation**:
```
Nanodegree Precision by Latitude:
┌──────────────────────────────────────────────────────────┐
│ Latitude │ 1 nanodegree │ Effective Precision           │
├──────────┼──────────────┼───────────────────────────────┤
│ 0° (equator) │ 0.111 mm │ Sub-millimeter                │
│ 30°         │ 0.096 mm  │ Sub-millimeter                │
│ 45°         │ 0.079 mm  │ Sub-millimeter                │
│ 60°         │ 0.056 mm  │ Sub-millimeter                │
│ 80°         │ 0.019 mm  │ Sub-millimeter                │
└──────────────────────────────────────────────────────────┘

At all latitudes, nanodegrees provide sub-millimeter precision,
exceeding RTK GPS accuracy (1-2 cm) by 100x.
```

### Decision 2: S2 Cell Precision Analysis

**Choice**: Document S2 cell precision at each level.

**Rationale**:
- S2 cells are used for spatial indexing
- Precision limited by chosen S2 level
- Users need to understand indexing precision vs storage precision

**Implementation**:
```
S2 Cell Precision by Level:
┌────────────────────────────────────────────────────────────┐
│ Level │ Cell Size (approx) │ Precision Class              │
├───────┼────────────────────┼──────────────────────────────┤
│ 12    │ ~3.3 km           │ Regional                      │
│ 16    │ ~153 m            │ Block level                   │
│ 20    │ ~10 m             │ Building level                │
│ 24    │ ~0.6 m            │ Sub-meter                     │
│ 28    │ ~4 cm             │ Centimeter                    │
│ 30    │ ~1 cm             │ High-precision GPS            │
└────────────────────────────────────────────────────────────┘

Note: S2 level 30 cells are ~1cm, sufficient for RTK GPS.
GeoEvent storage (nanodegrees) is 100x more precise.
```

### Decision 3: SDK Precision Guidelines

**Choice**: Document SDK precision handling and potential pitfalls.

**Rationale**:
- Float64 has limited precision
- Integer nanodegrees are exact
- SDKs must avoid precision loss

**Implementation**:
```python
# GOOD: Direct integer storage
event.lat_nano = 37_774929123  # Exact
event.lon_nano = -122_419415678  # Exact

# CAUTION: Float64 conversion
lat_degrees = 37.774929123
lat_nano = int(lat_degrees * 1e9)  # May lose precision beyond 15 digits

# Float64 precision limits:
# - 15-17 significant decimal digits
# - At 9 decimal places: effectively exact for GPS coordinates
# - Beyond 9 decimal places: may accumulate rounding errors

# RECOMMENDED: Use integer arithmetic in SDK
# Python: Use decimal module for high-precision conversion
from decimal import Decimal
lat_nano = int(Decimal("37.774929123") * Decimal("1000000000"))
```

### Decision 4: Precision Validation Tests

**Choice**: Add comprehensive precision tests to prove sub-meter accuracy.

**Rationale**:
- Tests document and validate precision
- Catch regressions
- Build confidence for precision-critical users

**Implementation**:
```zig
test "submeter precision preserved" {
    // RTK GPS precision: 2cm = 0.00000018 degrees
    const rtk_precision_nano: i64 = 180; // ~2cm in nanodegrees

    const original_lat: i64 = 37_774929123; // ~37.774929123°
    const original_lon: i64 = -122_419415678;

    // Insert and retrieve
    const event = insertAndRetrieve(original_lat, original_lon);

    // Verify exact preservation
    try testing.expectEqual(original_lat, event.lat_nano);
    try testing.expectEqual(original_lon, event.lon_nano);

    // Verify sub-RTK precision maintained
    try testing.expect(@abs(event.lat_nano - original_lat) < rtk_precision_nano);
}
```

## Architecture

### Precision Stack

```
┌────────────────────────────────────────────────────────────────┐
│                     Precision Stack                             │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  Input Source          Precision        Storage Precision      │
│  ─────────────         ─────────        ─────────────────      │
│                                                                │
│  Consumer GPS          3-5 m            ✓ (0.1mm > 3m)        │
│  Dual-freq GPS         0.3-1 m          ✓ (0.1mm > 0.3m)      │
│  RTK GPS               1-2 cm           ✓ (0.1mm > 1cm)       │
│  UWB Indoor            10-30 cm         ✓ (0.1mm > 10cm)      │
│  Carrier-phase         1-5 cm           ✓ (0.1mm > 1cm)       │
│  Surveying             1-5 mm           ✓ (0.1mm < 1mm) *     │
│                                                                │
│  * Surveying may require careful float64 handling              │
│                                                                │
└────────────────────────────────────────────────────────────────┘

                        ┌──────────────────┐
                        │  Nanodegree      │
                        │  (0.1mm precision)│
                        └────────┬─────────┘
                                 │
                    ┌────────────┼────────────┐
                    │            │            │
                    ▼            ▼            ▼
              ┌──────────┐ ┌──────────┐ ┌──────────┐
              │ GeoEvent │ │ RAM Index│ │ S2 Cell  │
              │ Storage  │ │ (exact)  │ │ (level   │
              │ (exact)  │ │          │ │ dependent)│
              └──────────┘ └──────────┘ └──────────┘
```

### Use Case Mapping

```
┌──────────────────────────────────────────────────────────────┐
│                    Use Case Precision Mapping                 │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Use Case              Required         ArcherDB             │
│  ────────              ────────         ────────             │
│                                                              │
│  Fleet tracking        10m              ✓✓✓ (100,000x)      │
│  Ride-sharing          3m               ✓✓✓ (30,000x)       │
│  Drone delivery        1m               ✓✓✓ (10,000x)       │
│  Precision farming     10cm             ✓✓✓ (1,000x)        │
│  Construction          2cm              ✓✓✓ (200x)          │
│  Indoor positioning    30cm             ✓✓✓ (3,000x)        │
│  Surveying             5mm              ✓✓ (20x)            │
│  Machine control       1mm              ✓ (at limit)        │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Configuration

### S2 Level Selection

For sub-meter precision queries, recommend S2 level 24+ (0.6m cells) or level 28+ (4cm cells) for RTK applications.

```zig
pub const S2Config = struct {
    /// Minimum S2 level for indexing
    /// Level 24 = ~0.6m cells (sub-meter)
    /// Level 28 = ~4cm cells (RTK precision)
    min_level: u8 = 24,

    /// Maximum S2 level for indexing
    max_level: u8 = 30,
};
```

## Trade-Offs

### Storage vs Index Precision

| Component | Precision | Notes |
|-----------|-----------|-------|
| GeoEvent storage | 0.1mm | Exact nanodegrees |
| RAM index | 0.1mm | Same as GeoEvent |
| S2 index | 1cm (L30) | Hierarchical, configurable |
| Query results | 0.1mm | From GeoEvent |

**Conclusion**: S2 indexing is the precision bottleneck, but L30 cells provide 1cm precision, sufficient for all GPS technologies.

## Validation Plan

### Unit Tests

1. **Precision preservation**: Insert/retrieve exact values
2. **Float64 conversion**: Test SDK conversion accuracy
3. **S2 level precision**: Verify cell sizes at each level

### Integration Tests

1. **RTK precision workflow**: End-to-end with cm coordinates
2. **UWB indoor positioning**: Sub-meter queries
3. **Precision agriculture**: Field-level accuracy

### Documentation

1. **Precision table**: Clear precision at each latitude
2. **Use case guide**: Which precision for which application
3. **SDK best practices**: Avoiding precision loss
