# SDK Parity Matrix

Cross-SDK parity verification for ArcherDB. All 5 SDKs must produce identical results for identical operations.

**Generated:** 2026-04-09T03:08:16.801998Z

## Summary

- Total tests: 79
- Passed: 79
- Failed: 0

## Methodology

Per Phase 14 CONTEXT.md decisions:
- **Verification strategy:** Layered approach
  1. Direct comparison between all SDKs
  2. Python SDK as golden reference for tie-breaking
  3. Server responses as ultimate truth
- **Equality definition:** Exact match required
  - Structural equality (same fields, types, values)
  - Exact byte equality for coordinates (nanodegrees, no epsilon tolerance)

## Matrix (14 ops x 5 SDKs = 70 cells)

| Operation | Python | Node.js | Go | Java | C |
|-----------|--------|---------|----|----|---|
| delete | PASS | PASS | PASS | PASS | PASS |
| insert | PASS | PASS | PASS | PASS | PASS |
| ping | PASS | PASS | PASS | PASS | PASS |
| query-latest | PASS | PASS | PASS | PASS | PASS |
| query-polygon | PASS | PASS | PASS | PASS | PASS |
| query-radius | PASS | PASS | PASS | PASS | PASS |
| query-uuid | PASS | PASS | PASS | PASS | PASS |
| query-uuid-batch | PASS | PASS | PASS | PASS | PASS |
| status | PASS | PASS | PASS | PASS | PASS |
| topology | PASS | PASS | PASS | PASS | PASS |
| ttl-clear | PASS | PASS | PASS | PASS | PASS |
| ttl-extend | PASS | PASS | PASS | PASS | PASS |
| ttl-set | PASS | PASS | PASS | PASS | PASS |
| upsert | PASS | PASS | PASS | PASS | PASS |

Legend: PASS = identical results, FAIL = mismatch, - = not tested

## Edge Cases Verified

Per CONTEXT.md, all geographic edge cases are high priority:

### Polar Regions
- North pole (lat=90, any longitude)
- South pole (lat=-90, any longitude)
- Longitude ambiguity at poles

### Antimeridian (Date Line)
- lon=180 and lon=-180 (same line)
- Queries spanning date line
- Points near antimeridian

### Zero Crossings
- Equator (lat=0)
- Prime meridian (lon=0)
- Intersection (0, 0)

## Running Parity Tests

```bash
# Start server
./zig/zig build run -- --config=lite

# Run all parity tests
python tests/parity_tests/parity_runner.py

# Run specific operation
python tests/parity_tests/parity_runner.py --ops insert query-radius

# Run specific SDKs
python tests/parity_tests/parity_runner.py --sdks python node go
```

## CI Integration

Machine-readable report: `reports/parity.json`

---
*Last updated: 2026-04-09T03:08:16.802562Z*