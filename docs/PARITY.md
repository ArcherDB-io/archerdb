# SDK Parity Matrix

Cross-SDK parity verification for ArcherDB. All 6 SDKs must produce identical results for identical operations.

**Status:** Run `python tests/parity_tests/parity_runner.py` to update this matrix.

## Methodology

Per Phase 14 CONTEXT.md decisions:
- **Verification strategy:** Layered approach
  1. Direct comparison between all SDKs
  2. Python SDK as golden reference for tie-breaking
  3. Server responses as ultimate truth
- **Equality definition:** Exact match required
  - Structural equality (same fields, types, values)
  - Exact byte equality for coordinates (nanodegrees, no epsilon tolerance)
- **Floating-point handling:** Exact match at nanodegree precision

## Matrix (14 ops x 6 SDKs = 84 cells)

| Operation | Python | Node.js | Go | Java | C | Zig |
|-----------|--------|---------|----|----|---|-----|
| insert | - | - | - | - | - | - |
| upsert | - | - | - | - | - | - |
| delete | - | - | - | - | - | - |
| query-uuid | - | - | - | - | - | - |
| query-uuid-batch | - | - | - | - | - | - |
| query-radius | - | - | - | - | - | - |
| query-polygon | - | - | - | - | - | - |
| query-latest | - | - | - | - | - | - |
| ping | - | - | - | - | - | - |
| status | - | - | - | - | - | - |
| topology | - | - | - | - | - | - |
| ttl-set | - | - | - | - | - | - |
| ttl-extend | - | - | - | - | - | - |
| ttl-clear | - | - | - | - | - | - |

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
- Intersection (0, 0) - Null Island

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

# Verbose output
python tests/parity_tests/parity_runner.py -v
```

## CI Integration

Machine-readable report: `reports/parity.json`

```json
{
  "generated": "2026-02-01T00:00:00Z",
  "summary": {
    "total_tests": 84,
    "passed": 84,
    "failed": 0,
    "pass_rate": "100.0%",
    "target": "84 cells (14 ops x 6 SDKs)"
  }
}
```

The JSON report can be consumed by CI pipelines to:
- Block merges if parity tests fail
- Track parity coverage over time
- Identify which SDKs have issues

## Interpreting Results

### PASS (Identical Results)
All SDKs returned exactly the same result for the operation:
- Same fields present
- Same values (no rounding differences)
- Same error codes when applicable

### FAIL (Mismatch Detected)
SDKs returned different results. Check:
1. Coordinate precision (must match at nanodegree level)
2. Field ordering (should be normalized)
3. Error handling (same error types/codes)
4. Optional field presence

### Not Tested (-)
Operation not yet verified. May need:
- SDK implementation completion
- Fixture creation
- Runner implementation for that operation

## Troubleshooting

### All SDKs Fail
Check if server is running: `curl http://127.0.0.1:7000/ping`

### One SDK Fails
Check SDK-specific issues in `docs/SDK_LIMITATIONS.md`

### Coordinate Mismatches
Verify nanodegree conversion is identical:
- `latitude_nanodegrees = int(latitude * 1e9)`
- `longitude_nanodegrees = int(longitude * 1e9)`

## See Also

- [SDK Comparison Matrix](sdk/comparison-matrix.md) - Feature parity and code examples
- [SDK Limitations](SDK_LIMITATIONS.md) - Known issues and workarounds
- [Testing Guide](testing/README.md) - Run parity tests locally
- [CI Tiers](testing/ci-tiers.md) - Nightly parity testing in CI

---
*Last updated: 2026-02-01*
