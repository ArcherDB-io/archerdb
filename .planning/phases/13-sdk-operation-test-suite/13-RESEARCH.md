# Phase 13: SDK Operation Test Suite - Research

**Researched:** 2026-02-01
**Domain:** Cross-SDK Integration Testing, Test Orchestration, JSON Fixtures
**Confidence:** HIGH

## Summary

This phase creates comprehensive operation tests for all 6 ArcherDB SDKs (Python, Node.js, Go, Java, C, Zig) across all 14 operations. Research focused on three areas: (1) existing SDK test patterns already established in the codebase, (2) the test infrastructure from Phase 11 (cluster harness, fixtures), and (3) cross-language test orchestration strategies.

The foundation is solid:
- **6 SDKs exist** in `src/clients/{python,node,go,java,c,zig}/` with varying test coverage
- **Test harness** from Phase 11 provides `ArcherDBCluster` for programmatic server lifecycle
- **14 JSON fixtures** exist in `test_infrastructure/fixtures/v1/` covering all operations
- **Fixture loader** exists in Python (`test_infrastructure/fixtures/fixture_loader.py`)

Key insight: The Zig SDK (`src/clients/zig/tests/integration/roundtrip_test.zig`) represents the most recent test pattern and covers all 14 operations. This pattern should be replicated across all SDKs.

**Primary recommendation:** Create a unified test runner script that sequentially executes each SDK's tests against shared fixtures, with server-per-SDK isolation and fail-fast semantics per CONTEXT.md decisions.

## Standard Stack

### Core Infrastructure

| Tool/Library | Version | Purpose | Why Standard |
|--------------|---------|---------|--------------|
| Python | 3.11+ | Test orchestration, fixture loading | Phase 11 established Python for harness |
| pytest | 8.x | Python SDK test runner | Already used in Python SDK |
| Jest | 29.x | Node.js SDK test runner | Standard for Node testing |
| go test | 1.21+ | Go SDK test runner | Standard Go testing |
| JUnit 5 | 5.10+ | Java SDK test runner | Industry standard for Java |
| Zig test | 0.15+ | Zig SDK test runner | Built-in Zig testing |
| bash | 5.x | Test orchestration script | Shell glue for unified runner |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| deepdiff | 7.x | Python JSON comparison | Verbose diff output on failures |
| jest-diff | 29.x | Node.js JSON comparison | Test failure formatting |
| testify | 1.9+ | Go assertions | Enhanced assertion messages |
| AssertJ | 3.25+ | Java assertions | Fluent assertion API |

### Existing SDK Test Tools

Based on codebase analysis:

| SDK | Test File | Test Runner | Current Coverage |
|-----|-----------|-------------|------------------|
| Python | `tests/test_integration.py` | pytest | Partial (insert/query/delete roundtrip) |
| Node.js | Not found | Jest (in package.json) | Minimal |
| Go | `integration_test.go`, `geo_test.go` | go test | Partial (5-6 operations) |
| Java | Not found | JUnit (in pom.xml) | Minimal |
| C | `test.zig` | Zig test runner | Wiring tests only |
| Zig | `tests/integration/roundtrip_test.zig` | Zig test | **All 14 operations** |

## Architecture Patterns

### Recommended Project Structure

```
tests/
  run_sdk_tests.sh              # Unified test runner (Phase 13 deliverable)
  fixtures/                     # Symlink to test_infrastructure/fixtures
  sdk_tests/
    common/
      fixture_adapter.py        # Cross-language fixture loading helpers
      result_reporter.py        # Unified test result formatting
    python/
      test_all_operations.py    # pytest tests for all 14 ops
      conftest.py              # pytest fixtures (cluster harness)
    node/
      test_all_operations.ts    # Jest tests for all 14 ops
      jest.config.js
    go/
      all_operations_test.go    # go test for all 14 ops
    java/
      AllOperationsTest.java    # JUnit tests for all 14 ops
    c/
      test_all_operations.c     # C tests via Zig runner
    zig/
      # Use existing: src/clients/zig/tests/integration/roundtrip_test.zig
```

### Pattern 1: Server-Per-SDK Lifecycle (CONTEXT.md Decision)

**What:** Each SDK test suite starts/stops its own isolated server
**When to use:** All SDK test runs

```python
# Source: test_infrastructure/harness/cluster.py
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig

def run_sdk_tests(sdk_name: str, test_command: list[str]) -> int:
    """Run SDK tests with isolated server."""
    config = ClusterConfig(node_count=1)
    with ArcherDBCluster(config) as cluster:
        cluster.wait_for_ready(timeout=60)

        # Pass server address to SDK test
        env = os.environ.copy()
        env['ARCHERDB_ADDRESS'] = cluster.get_addresses()
        env['ARCHERDB_INTEGRATION'] = '1'  # Enable integration tests

        result = subprocess.run(test_command, env=env)
        return result.returncode
```

### Pattern 2: Fresh Database Per Test (CONTEXT.md Decision)

**What:** Clear all data before each test function
**When to use:** Every test case to ensure isolation

```python
# Python SDK example
@pytest.fixture(autouse=True)
def clean_database(client):
    """Delete all entities before each test."""
    # Query and delete all existing entities
    result = client.query_latest(QueryLatestFilter(limit=10000))
    if result.events:
        entity_ids = [e.entity_id for e in result.events]
        client.delete_entities(entity_ids)
    yield
```

```go
// Go SDK example
func cleanDatabase(t *testing.T, client GeoClient) {
    t.Helper()
    result, _ := client.QueryLatest(types.QueryLatestFilter{Limit: 10000})
    if len(result.Events) > 0 {
        ids := make([]types.Uint128, len(result.Events))
        for i, e := range result.Events {
            ids[i] = e.EntityID
        }
        client.DeleteEntities(ids)
    }
}
```

### Pattern 3: Fixture-Driven Tests

**What:** Load test cases from JSON fixtures, execute, compare results
**When to use:** All operation tests

```python
# Source: Extending test_infrastructure/fixtures/fixture_loader.py
from test_infrastructure.fixtures import load_fixture

def test_insert_from_fixtures(client):
    """Test insert operation using fixtures."""
    fixture = load_fixture("insert")

    for case in fixture.cases:
        # Skip non-smoke cases if running smoke tier only
        if "smoke" not in case.tags:
            continue

        # Execute operation
        events = convert_fixture_to_events(case.input["events"])
        results = client.insert_events(events)

        # Verify results match expected output
        assert_results_match(results, case.expected_output)
```

### Pattern 4: Triple Verification Strategy (CONTEXT.md Decision)

**What:** Three-level result verification for geospatial queries
**When to use:** All query operations (radius, polygon, latest)

```python
def verify_radius_query_results(results, expected, center, radius_m):
    """Triple verification for radius queries."""

    # 1. Known ground truth - fixture has expected entity IDs
    if "events_contain" in expected:
        actual_ids = {e.entity_id for e in results.events}
        expected_ids = set(expected["events_contain"])
        assert expected_ids.issubset(actual_ids), \
            f"Missing entities: {expected_ids - actual_ids}"

    # 2. Count validation
    if "count_in_range" in expected:
        assert len(results.events) == expected["count_in_range"], \
            f"Expected {expected['count_in_range']} events, got {len(results.events)}"

    # 3. Geometric assertion - all returned points ARE within radius
    for event in results.events:
        distance = haversine_distance(
            center[0], center[1],
            event.latitude, event.longitude
        )
        assert distance <= radius_m * 1.001, \
            f"Event {event.entity_id} at distance {distance}m exceeds radius {radius_m}m"
```

### Pattern 5: Unified Test Runner Script

**What:** Single script orchestrates all SDK tests
**When to use:** CI execution, manual test runs

```bash
#!/bin/bash
# tests/run_sdk_tests.sh

set -e  # Fail fast on first error (CONTEXT.md decision)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Build ArcherDB first
echo "Building ArcherDB..."
"$PROJECT_ROOT/zig/zig" build -j4 -Dconfig=lite

# SDK test order: Python, Node, Go, Java, C, Zig (CONTEXT.md decision)
SDKS=("python" "node" "go" "java" "c" "zig")

for sdk in "${SDKS[@]}"; do
    echo "========================================"
    echo "Testing $sdk SDK..."
    echo "========================================"

    case $sdk in
        python)
            cd "$PROJECT_ROOT/tests/sdk_tests/python"
            pytest test_all_operations.py -v --tb=short
            ;;
        node)
            cd "$PROJECT_ROOT/tests/sdk_tests/node"
            npm test
            ;;
        go)
            cd "$PROJECT_ROOT/src/clients/go"
            ARCHERDB_INTEGRATION=1 go test -v ./...
            ;;
        java)
            cd "$PROJECT_ROOT/src/clients/java"
            mvn test -Dtest=AllOperationsTest
            ;;
        c)
            cd "$PROJECT_ROOT/src/clients/c"
            "$PROJECT_ROOT/zig/zig" build test
            ;;
        zig)
            cd "$PROJECT_ROOT/src/clients/zig"
            "$PROJECT_ROOT/zig/zig" build test
            ;;
    esac

    echo "$sdk SDK: PASSED"
done

echo "========================================"
echo "ALL SDKs PASSED"
echo "========================================"
```

### Anti-Patterns to Avoid

- **Shared server state:** Each SDK must have its own server instance
- **Test order dependencies:** Tests must not depend on previous test results
- **Swallowing failures:** Per CONTEXT.md, fail fast on any failure
- **Skipping limitations:** Per CONTEXT.md, NO SDK LIMITATIONS ALLOWED - fix the SDK
- **Approximate matching:** Use exact JSON matching, not fuzzy comparisons

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON diff formatting | Custom string comparison | deepdiff/jest-diff/testify | Better visualization of mismatches |
| Fixture loading | Custom JSON parser | `test_infrastructure/fixtures/fixture_loader.py` | Already exists, tested |
| Server lifecycle | Manual subprocess | `test_infrastructure/harness/ArcherDBCluster` | Health checks, cleanup, logging |
| Distance calculations | Custom haversine | SDK's built-in or validated library | Precision matters for verification |
| Entity ID generation | Random integers | SDK's `types.ID()` or `archerdb.id()` | Correct UUID format |

**Key insight:** Phase 11 infrastructure exists and should be extended, not replaced.

## Common Pitfalls

### Pitfall 1: Entity ID Collisions Across Tests

**What goes wrong:** Tests interfere because they use same entity IDs
**Why it happens:** Hardcoded IDs in fixtures or tests
**How to avoid:**
- Use unique entity IDs per test (hash of test name + timestamp)
- Always clean up entities after tests
- Namespace entity IDs by SDK (e.g., Python uses 10xxxx, Go uses 20xxxx)
**Warning signs:** Tests pass individually but fail when run together

### Pitfall 2: Fixture Setup Not Executing

**What goes wrong:** Query tests fail because setup data wasn't inserted
**Why it happens:** Fixture has `setup.insert_first` but test doesn't process it
**How to avoid:**
- Parse fixture structure completely including `setup` block
- Execute setup operations before main operation
- Verify setup succeeded before proceeding
**Warning signs:** Empty query results, "not found" errors

### Pitfall 3: Coordinate Precision Loss

**What goes wrong:** Inserted lat/lon doesn't match queried lat/lon
**Why it happens:** Float to nanodegree conversion rounding
**How to avoid:**
- Always compare nanodegrees (integers), not floats
- Use SDK's conversion functions consistently
- Allow small epsilon for float comparisons if needed
**Warning signs:** "Expected 37.7749, got 37.77489999..."

### Pitfall 4: Timestamp Non-Determinism

**What goes wrong:** Timestamp comparisons fail intermittently
**Why it happens:** Server generates timestamps, test expects exact values
**How to avoid:** Per CONTEXT.md, use range checks (within 1 second of test time)
**Warning signs:** Tests pass sometimes, fail other times

### Pitfall 5: SDK Returning Different JSON Structure

**What goes wrong:** Exact JSON match fails despite correct data
**Why it happens:** SDK serializes with different key order or formatting
**How to avoid:**
- Parse JSON and compare semantically, not as strings
- Normalize before comparison (sort keys)
- Use appropriate comparison library per language
**Warning signs:** "Expected {...}, got {...}" with same content different order

### Pitfall 6: Leader Election Timing

**What goes wrong:** First few operations fail with "no leader" errors
**Why it happens:** Single-node cluster still needs brief leader election
**How to avoid:**
- Wait for `cluster.wait_for_leader()` before running tests
- Add brief sleep (100ms) between server ready and first operation
**Warning signs:** First test fails, subsequent tests pass

## Code Examples

### Python SDK Test Structure

```python
# Source: Extending src/clients/python/tests/test_integration.py
import pytest
from archerdb import GeoClientSync, GeoClientConfig, create_geo_event, id as archerdb_id
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig
from test_infrastructure.fixtures import load_fixture

@pytest.fixture(scope="module")
def cluster():
    """Start fresh cluster for this test module."""
    config = ClusterConfig(node_count=1)
    with ArcherDBCluster(config) as c:
        c.wait_for_ready(timeout=60)
        yield c

@pytest.fixture
def client(cluster):
    """Create client connected to test cluster."""
    config = GeoClientConfig(
        cluster_id=0,
        addresses=[cluster.get_addresses()]
    )
    c = GeoClientSync(config)
    yield c
    c.close()

@pytest.fixture(autouse=True)
def clean_database(client):
    """Fresh database for each test."""
    # Delete all entities
    result = client.query_latest(limit=10000)
    if result.events:
        ids = [e.entity_id for e in result.events]
        client.delete_entities(ids)
    yield

def test_insert_single_event_valid(client):
    """smoke: Basic insert with minimal required fields."""
    fixture = load_fixture("insert")
    case = next(c for c in fixture.cases if c.name == "single_event_valid")

    events = [create_geo_event(
        entity_id=e["entity_id"],
        latitude=e["latitude"],
        longitude=e["longitude"]
    ) for e in case.input["events"]]

    results = client.insert_events(events)

    # Exact match verification
    assert results == []  # No errors means success
```

### Go SDK Test Structure

```go
// Source: Extending src/clients/go/integration_test.go
package archerdb

import (
    "encoding/json"
    "os"
    "testing"

    "github.com/archerdb/archerdb-go/pkg/types"
)

type Fixture struct {
    Operation string     `json:"operation"`
    Cases     []TestCase `json:"cases"`
}

type TestCase struct {
    Name           string                 `json:"name"`
    Tags           []string               `json:"tags"`
    Input          map[string]interface{} `json:"input"`
    ExpectedOutput map[string]interface{} `json:"expected_output"`
}

func loadFixture(t *testing.T, operation string) Fixture {
    t.Helper()
    data, err := os.ReadFile("../../test_infrastructure/fixtures/v1/" + operation + ".json")
    if err != nil {
        t.Fatalf("Failed to load fixture: %v", err)
    }
    var fixture Fixture
    if err := json.Unmarshal(data, &fixture); err != nil {
        t.Fatalf("Failed to parse fixture: %v", err)
    }
    return fixture
}

func TestInsertOperations(t *testing.T) {
    if os.Getenv("ARCHERDB_INTEGRATION") != "1" {
        t.Skip("Set ARCHERDB_INTEGRATION=1")
    }

    client := setupClient(t)
    defer client.Close()

    fixture := loadFixture(t, "insert")

    for _, tc := range fixture.Cases {
        t.Run(tc.Name, func(t *testing.T) {
            cleanDatabase(t, client)

            // Convert fixture input to events
            events := convertInputToEvents(t, tc.Input)

            // Execute
            results, err := client.InsertEvents(events)
            if err != nil {
                t.Fatalf("InsertEvents failed: %v", err)
            }

            // Verify
            verifyResults(t, results, tc.ExpectedOutput)
        })
    }
}
```

### Zig SDK Test (Already Exists - Reference Pattern)

```zig
// Source: src/clients/zig/tests/integration/roundtrip_test.zig
// This is the model for all other SDKs

test "integration: insert and query roundtrip" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    const entity_id = generateTestEntityId("insert_query_roundtrip");

    // Insert event
    const events = [_]types.GeoEvent{
        .{
            .entity_id = entity_id,
            .lat_nano = types.degreesToNano(37.7749),
            .lon_nano = types.degreesToNano(-122.4194),
            .group_id = 1,
        },
    };

    var insert_results = client.insertEvents(std.testing.allocator, &events) catch |err| {
        std.debug.print("Insert failed: {}\n", .{err});
        return;
    };
    defer insert_results.deinit();

    // Verify insert succeeded
    if (insert_results.items.len > 0) {
        try std.testing.expectEqual(types.InsertResultCode.ok, insert_results.items[0].code);
    }

    // Query back by UUID
    const queried = client.getLatestByUUID(std.testing.allocator, entity_id) catch |err| {
        std.debug.print("Query failed: {}\n", .{err});
        return;
    };

    if (queried) |event| {
        try std.testing.expectEqual(events[0].entity_id, event.entity_id);
        try std.testing.expectEqual(events[0].lat_nano, event.lat_nano);
        try std.testing.expectEqual(events[0].lon_nano, event.lon_nano);
    }

    // Clean up
    const delete_ids = [_]u128{entity_id};
    _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
}
```

### Verbose Diff Output Format

```python
# Per CONTEXT.md: show expected vs actual with highlighted differences
def assert_json_match(expected, actual, operation_name):
    """Assert JSON matches with verbose diff on failure."""
    from deepdiff import DeepDiff

    diff = DeepDiff(expected, actual, ignore_order=True)
    if diff:
        print(f"\n{'='*60}")
        print(f"MISMATCH in {operation_name}")
        print(f"{'='*60}")
        print(f"\nExpected:\n{json.dumps(expected, indent=2)}")
        print(f"\nActual:\n{json.dumps(actual, indent=2)}")
        print(f"\nDiff:\n{diff.to_json(indent=2)}")
        print(f"{'='*60}\n")

        raise AssertionError(f"JSON mismatch in {operation_name}")
```

## The 14 Operations Test Matrix

| # | Operation | Opcode | Smoke Cases | PR Cases | Nightly Cases |
|---|-----------|--------|-------------|----------|---------------|
| 1 | insert | 146 | 1 | 3 | 4 |
| 2 | upsert | 147 | 1 | 2 | 2 |
| 3 | delete | 148 | 1 | 2 | 2 |
| 4 | query-uuid | 149 | 1 | 2 | 2 |
| 5 | query-uuid-batch | 156 | 1 | 2 | 2 |
| 6 | query-radius | 150 | 1 | 3 | 5 |
| 7 | query-polygon | 151 | 1 | 2 | 4 |
| 8 | query-latest | 154 | 1 | 2 | 2 |
| 9 | ping | 152 | 1 | 1 | 1 |
| 10 | status | 153 | 1 | 2 | 2 |
| 11 | ttl-set | 158 | 1 | 2 | 2 |
| 12 | ttl-extend | 159 | 1 | 2 | 2 |
| 13 | ttl-clear | 160 | 1 | 2 | 2 |
| 14 | topology | 157 | 1 | 2 | 3 |

**Total per SDK:** 14 operations x (smoke average 1) = ~14 smoke tests
**Total matrix:** 6 SDKs x 14 operations = 84 core tests

Per CONTEXT.md: All tests are smoke tier (run on every commit).

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual test data | JSON fixtures | Phase 11 | Consistent test data across SDKs |
| Hardcoded server address | Dynamic port allocation | Phase 11 | Parallel test safety |
| Per-SDK server setup | Test harness library | Phase 11 | Unified server lifecycle |
| Skip on SDK limitation | Fix SDK immediately | Phase 13 (CONTEXT.md) | No partial implementations |

**Zig SDK sets the standard:** `src/clients/zig/tests/integration/roundtrip_test.zig` covers all 14 operations and should be the reference implementation for other SDKs.

## Open Questions

1. **Fixture Setup Block Processing**
   - What we know: Fixtures have `setup.insert_first` and `setup.insert_first_range` blocks
   - What's unclear: Should setup be its own test function or inline?
   - Recommendation: Inline setup within each test for simplicity, cleanup after

2. **Timeout Handling Across SDKs**
   - What we know: Each SDK has different timeout semantics
   - What's unclear: Optimal timeout values for 14 operations
   - Recommendation: 30s per operation, 5 minutes per SDK total

3. **Error Message Standardization**
   - What we know: SDKs return errors in different formats
   - What's unclear: Should error messages be compared byte-for-byte?
   - Recommendation: Compare error codes (integers), not error messages (strings)

## Sources

### Primary (HIGH confidence)

- `src/clients/zig/tests/integration/roundtrip_test.zig` - Reference implementation covering all 14 ops
- `test_infrastructure/fixtures/v1/*.json` - 14 operation fixtures
- `test_infrastructure/harness/cluster.py` - Server lifecycle management
- `test_infrastructure/fixtures/fixture_loader.py` - Fixture loading utilities
- `src/clients/go/integration_test.go` - Go SDK test patterns

### Secondary (MEDIUM confidence)

- `src/clients/python/tests/test_integration.py` - Python SDK test patterns
- `.github/workflows/ci.yml` - CI configuration (existing test commands)
- `src/clients/test-data/wire-format-test-cases.json` - Wire format constants

### Tertiary (LOW confidence)

- Per-SDK documentation (README.md files) - SDK-specific setup instructions

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Based on existing SDK test infrastructure
- Architecture patterns: HIGH - Extends Phase 11 harness, follows CONTEXT.md decisions
- Pitfalls: HIGH - Derived from existing integration test failures
- Test coverage: HIGH - Fixtures exist for all 14 operations

**Research date:** 2026-02-01
**Valid until:** 2026-03-01 (30 days - stable testing domain)

---

## SDK Coverage Summary

Based on codebase analysis, current SDK test coverage:

| SDK | Location | Test Runner | Operations Covered | Status |
|-----|----------|-------------|-------------------|--------|
| Python | `src/clients/python/tests/` | pytest | ~3-4 | Needs expansion |
| Node.js | `src/clients/node/` | Jest | 0-1 | Needs creation |
| Go | `src/clients/go/*.go` | go test | ~5-6 | Needs expansion |
| Java | `src/clients/java/` | JUnit | 0-1 | Needs creation |
| C | `src/clients/c/test.zig` | Zig test | ~2-3 | Needs expansion |
| Zig | `src/clients/zig/tests/integration/` | Zig test | **All 14** | Reference model |

**Action:** Use Zig SDK tests as the template for all other SDKs.
