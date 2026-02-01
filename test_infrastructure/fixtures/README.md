# ArcherDB Test Fixtures

This directory contains canonical JSON test fixtures for cross-SDK parity validation.

## Directory Structure

```
fixtures/
  v1/                           # Version 1 protocol fixtures
    insert.json                 # Insert operation (opcode 146)
    upsert.json                 # Upsert operation (opcode 147)
    delete.json                 # Delete operation (opcode 148)
    query-uuid.json             # Query by UUID (opcode 149)
    query-uuid-batch.json       # Batch query by UUID (opcode 156)
    query-radius.json           # Radius query (opcode 150)
    query-polygon.json          # Polygon query (opcode 151)
    query-latest.json           # Query latest events (opcode 154)
    ping.json                   # Ping (opcode 152)
    status.json                 # Status (opcode 153)
    ttl-set.json                # Set TTL (opcode 158)
    ttl-extend.json             # Extend TTL (opcode 159)
    ttl-clear.json              # Clear TTL (opcode 160)
    topology.json               # Get topology (opcode 157)
  README.md                     # This file
```

## Fixture Format

Each fixture file follows this JSON structure:

```json
{
  "operation": "operation_name",
  "version": "1.0.0",
  "description": "Description of what operation does",
  "cases": [
    {
      "name": "unique_case_name",
      "description": "What this test validates",
      "tags": ["smoke", "pr", "nightly"],
      "input": {
        "setup": { ... },        // Optional setup data
        ...                      // Operation-specific input
      },
      "expected_output": { ... },
      "expected_error": null     // or error description if expected
    }
  ]
}
```

## CI Tier Tags

Each test case is tagged for specific CI tiers:

| Tag | CI Tier | Budget | Purpose |
|-----|---------|--------|---------|
| `smoke` | Smoke | <5 min | Fast validation on every push |
| `pr` | PR | <15 min | Comprehensive PR validation |
| `nightly` | Nightly | No limit | Full suite including edge cases |

### Tag Guidelines

- **smoke**: Basic connectivity and happy path only
- **pr**: Error handling, edge cases, validation
- **nightly**: Boundary conditions, stress tests, multi-node scenarios

## Test Case Categories

### 1. Happy Path Cases
Basic operations that should succeed:
- `single_event_valid` (insert)
- `basic_radius_1km` (query-radius)
- `triangle_basic` (query-polygon)

### 2. Error Cases
Operations that should fail gracefully:
- `invalid_lat_over_90` (insert) - LAT_OUT_OF_RANGE
- `single_entity_not_found` (delete) - ENTITY_NOT_FOUND
- `nonexistent_entity` (query-uuid) - returns null

### 3. Boundary Conditions
Geographic and data edge cases:
- `boundary_north_pole` - lat=90
- `boundary_antimeridian_east` - lon=180
- `boundary_null_island` - lat=0, lon=0

### 4. Hotspot Stress Tests
High-concentration data for performance validation:
- `hotspot_insert_batch` - 100 events at 95%+ same location
- `hotspot_radius_query` - Query hotspot area with 1000 events
- `hotspot_polygon_query` - Polygon over hotspot data

These stress tests validate query performance when data is not uniformly distributed.

## Using Fixtures in SDK Tests

### Python Example

```python
from test_infrastructure.fixtures.fixture_loader import load_fixture, filter_cases_by_tag

# Load insert fixture
insert_fixture = load_fixture("insert")

# Get only smoke tests
smoke_cases = filter_cases_by_tag(insert_fixture, "smoke")

# Run each case
for case in smoke_cases:
    result = client.insert(case.input["events"])
    assert_matches(result, case.expected_output)
```

### Node.js Example

```javascript
const fs = require('fs');
const path = require('path');

const fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../fixtures/v1/insert.json'))
);

const smokeCases = fixture.cases.filter(c => c.tags.includes('smoke'));

for (const testCase of smokeCases) {
  const result = await client.insert(testCase.input.events);
  expect(result).toMatchExpected(testCase.expected_output);
}
```

### Go Example

```go
import (
    "encoding/json"
    "testing"
)

type Fixture struct {
    Operation string     `json:"operation"`
    Cases     []TestCase `json:"cases"`
}

func TestInsertFromFixture(t *testing.T) {
    data, _ := os.ReadFile("fixtures/v1/insert.json")
    var fixture Fixture
    json.Unmarshal(data, &fixture)

    for _, tc := range fixture.Cases {
        if contains(tc.Tags, "smoke") {
            result := client.Insert(tc.Input.Events)
            assertMatches(t, result, tc.ExpectedOutput)
        }
    }
}
```

## Adding New Test Cases

1. **Choose the right fixture file** based on operation
2. **Pick appropriate tags** for CI tier
3. **Include setup if needed** in the `setup` field
4. **Document expected output** including error codes
5. **Add metadata** for hotspot/stress tests

### Example: Adding a new radius query case

```json
{
  "name": "radius_with_sorting",
  "description": "Radius query with results sorted by distance",
  "tags": ["pr"],
  "input": {
    "setup": {
      "insert_first": [
        {"entity_id": 99901, "latitude": 40.7128, "longitude": -74.0060},
        {"entity_id": 99902, "latitude": 40.7200, "longitude": -74.0100}
      ]
    },
    "center_latitude": 40.7128,
    "center_longitude": -74.0060,
    "radius_m": 5000,
    "sort_by_distance": true
  },
  "expected_output": {
    "count": 2,
    "first_entity_id": 99901,
    "_note": "Closer entity should be first"
  },
  "expected_error": null
}
```

## Version Management

- **v1/**: Current protocol version
- **v2/**: Future protocol changes (when needed)

When protocol changes:
1. Create new version directory (e.g., `v2/`)
2. Copy and modify fixtures for new protocol
3. Keep old versions for backwards compatibility testing

## Validation

Run fixture validation:

```bash
python3 test-infrastructure/fixtures/fixture_loader.py
```

This validates:
- All fixture files are valid JSON
- Required fields present in each case
- At least 14 operation fixtures exist

## Cross-SDK Parity

These fixtures enable **golden file testing**:

> Same input should produce same output across all 6 SDKs

This ensures:
- Wire format compatibility
- Consistent error handling
- Predictable behavior regardless of language

## Reference

- Wire format spec: `src/clients/test-data/wire-format-test-cases.json`
- Operation codes: See individual fixture files
- Result codes: `insert_result_codes`, `delete_result_codes` in wire format spec
