# Change: Sub-Meter Precision

Document and validate ArcherDB's sub-meter precision capabilities.

## Status: Implemented (Core Tests)

## Quick Links

- [proposal.md](proposal.md) - Problem statement and scope
- [design.md](design.md) - Technical design
- [tasks.md](tasks.md) - Implementation tasks (~25 hours)

## Spec Deltas

- [specs/data-model/spec.md](specs/data-model/spec.md) - Precision documentation, test requirements

## Summary

ArcherDB's nanodegree precision (0.1mm) now exceeds typical GPS accuracy due to advances in positioning technology:

| Technology | Accuracy | Nanodegree Advantage |
|------------|----------|---------------------|
| Consumer GPS | 3-5 m | 30,000-50,000x |
| Dual-frequency GPS | 0.3-1 m | 3,000-10,000x |
| RTK GPS | 1-2 cm | 100-200x |
| UWB Indoor | 10-30 cm | 1,000-3,000x |

## Precision by Latitude

| Latitude | 1 nanodegree | Precision |
|----------|--------------|-----------|
| 0° (equator) | 0.111 mm | Sub-millimeter |
| 45° | 0.079 mm | Sub-millimeter |
| 60° | 0.056 mm | Sub-millimeter |

At all latitudes, nanodegrees provide sub-millimeter precision.

## S2 Index Precision

| Level | Cell Size | Use Case |
|-------|-----------|----------|
| 20 | ~10 m | Building-level |
| 24 | ~0.6 m | Sub-meter |
| 28 | ~4 cm | RTK GPS |
| 30 | ~1 cm | High-precision |

For RTK applications, use S2 level 28+ (4cm cells).

## Supported Use Cases

- **Fleet tracking**: 10m accuracy (30,000x margin)
- **Precision farming**: 10cm accuracy (1,000x margin)
- **Construction/RTK**: 2cm accuracy (200x margin)
- **Indoor UWB**: 30cm accuracy (3,000x margin)
- **Surveying**: 5mm accuracy (20x margin)

## SDK Best Practices

```python
# GOOD: Direct integer storage
event.lat_nano = 37_774929123  # Exact

# CAUTION: Float64 conversion (15-17 digit precision)
lat_nano = int(lat_degrees * 1e9)  # OK for 9 decimal places

# BEST: Use decimal for maximum precision
from decimal import Decimal
lat_nano = int(Decimal("37.774929123") * Decimal("1000000000"))
```

## Key Points

1. **Storage**: 0.1mm precision (nanodegrees are exact integers)
2. **S2 Index**: 1cm precision at level 30
3. **Float64**: 15-17 significant digits (sufficient for GPS)
4. **Use case**: Exceeds all current GPS technologies
