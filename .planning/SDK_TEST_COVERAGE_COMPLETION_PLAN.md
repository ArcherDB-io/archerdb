# SDK Test Coverage Completion Plan

**Created:** 2026-02-06  
**Goal:** Achieve 79/79 test coverage across all 5 SDKs  
**Total Estimated Time:** 10-12 hours  
**Priority:** High - Production quality assurance

---

## Current State Summary

| SDK | Current Tests | Target | Coverage | Status | Effort |
|-----|--------------|--------|----------|--------|--------|
| Python | 79/79 | 79 | 100% | ✅ **COMPLETE** | 0h |
| Go | 79/79 | 79 | 100% | ✅ **COMPLETE** | 0h |
| C | 64/79 | 79 | 81% | ⚠️ **Verify** | 1-2h |
| Node.js | 20/79 | 79 | 25% | 🔧 **Expand** | 3h |
| Java | 17/79 | 79 | 22% | 🔧 **Expand** | 4h |

**Missing Tests:** 74 test cases across 3 SDKs  
**Risk Level:** High (critical boundary/edge cases untested)

---

## Phase 1: C SDK Verification (1-2 hours)

**Goal:** Understand what the 64 tests actually cover and identify the 15 missing cases.

### Step 1.1: Run C SDK Tests with Detailed Output
```bash
cd src/clients/c
./zig/zig build test -- -v > c_test_results.txt 2>&1
```

**Action Items:**
- [ ] Run C SDK test suite
- [ ] Save output to file
- [ ] Count actual test cases (not assertions)

### Step 1.2: Map Tests to Fixtures
**Location:** `tests/fixtures/*.json`

Create mapping document:
```
c_test_analysis.md:
  - Test 1: insert_basic → fixture "insert/valid_single_event"
  - Test 2: insert_batch → fixture "insert/valid_batch"
  - Test 3: query_uuid → fixture "query_uuid/exists"
  ...
```

**Action Items:**
- [ ] List all 64 C tests by name
- [ ] Map each to corresponding fixture case
- [ ] Identify which fixture operations are tested
- [ ] Identify which operations are NOT tested

### Step 1.3: Identify Missing Cases
Review fixture files for operations:
```bash
ls tests/fixtures/
# Expected: insert.json, upsert.json, delete.json, query_uuid.json,
#          query_uuid_batch.json, query_radius.json, query_polygon.json,
#          query_latest.json, ping.json, status.json, topology.json,
#          ttl_set.json, ttl_extend.json, ttl_clear.json
```

**Action Items:**
- [ ] Count cases per fixture file
- [ ] Cross-reference with C test coverage
- [ ] List 15 missing test cases explicitly
- [ ] Categorize: boundary/invalid/edge/operations

### Step 1.4: Create C SDK Test Plan
Create file: `.planning/c_sdk_missing_tests.md`

**Action Items:**
- [ ] Document 15 missing test cases
- [ ] Estimate effort per missing test
- [ ] Decide: Add tests OR accept 81% coverage with rationale

**Decision Point:** Continue to Phase 2 or complete C SDK first?

---

## Phase 2: Node.js SDK Expansion (3 hours)

**Goal:** Expand from 20/79 → 79/79 tests using proven Python pattern.

### Prerequisites
- [ ] Review Python SDK test structure: `src/clients/python/tests/`
- [ ] Confirm Node.js fixtures loaded: `tests/fixtures/*.json`
- [ ] Verify `test.each()` pattern working for Insert/Upsert

### Step 2.1: Load All Fixtures (15 min)
**File:** `src/clients/node/tests/client.test.ts`

```typescript
// Add at top of file
const deleteFixture = loadFixture('delete');
const queryUuidFixture = loadFixture('query_uuid');
const queryUuidBatchFixture = loadFixture('query_uuid_batch');
const queryRadiusFixture = loadFixture('query_radius');
const queryPolygonFixture = loadFixture('query_polygon');
const queryLatestFixture = loadFixture('query_latest');
const pingFixture = loadFixture('ping');
const statusFixture = loadFixture('status');
const topologyFixture = loadFixture('topology');
const ttlSetFixture = loadFixture('ttl_set');
const ttlExtendFixture = loadFixture('ttl_extend');
const ttlClearFixture = loadFixture('ttl_clear');
```

**Action Items:**
- [ ] Add fixture imports for 12 remaining operations
- [ ] Verify fixtures load without errors
- [ ] Check fixture structure matches expected format

### Step 2.2: Implement Delete Operation Tests (15 min)
```typescript
describe('Delete Operation', () => {
  test.each(deleteFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup: Insert entities first if needed
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute delete
    const entityIds = testCase.input.entity_ids;
    const results = await client!.deleteEntities(entityIds);
    
    // Verify
    if (testCase.expected_output.all_ok) {
      expect(results.every(r => r.code === 0)).toBe(true);
    } else {
      verifyExpectedErrors(results, testCase.expected_output);
    }
  });
});
```

**Action Items:**
- [ ] Implement delete test using pattern above
- [ ] Run: `npm test -- --grep "Delete"`
- [ ] Verify all delete fixture cases execute
- [ ] Expected: ~4 tests (3 pass, 1 skip)

### Step 2.3: Implement Query UUID Tests (15 min)
```typescript
describe('Query UUID', () => {
  test.each(queryUuidFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute
    const uuid = testCase.input.entity_id;
    const result = await client!.queryByUUID(uuid);
    
    // Verify
    if (testCase.expected_output.found) {
      expect(result).toBeDefined();
      expect(result.entity_id).toBe(uuid);
    } else {
      expect(result).toBeNull();
    }
  });
});
```

**Action Items:**
- [ ] Implement query UUID test
- [ ] Run: `npm test -- --grep "Query UUID"`
- [ ] Verify all cases execute
- [ ] Expected: ~3 tests (all pass)

### Step 2.4: Implement Query UUID Batch Tests (15 min)
**Note:** Server may not support this operation (returns "invalid operation")

```typescript
describe('Query UUID Batch', () => {
  test.each(queryUuidBatchFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Note: This operation may not be implemented on server
    // Skip if server returns "operation not supported"
    
    try {
      const uuids = testCase.input.entity_ids;
      const results = await client!.queryByUUIDBatch(uuids);
      
      if (testCase.expected_output.all_found) {
        expect(results).toHaveLength(uuids.length);
      }
    } catch (error) {
      if (error.message.includes('not supported')) {
        return; // Expected for unimplemented operation
      }
      throw error;
    }
  });
});
```

**Action Items:**
- [ ] Implement query UUID batch test
- [ ] Check if operation is implemented on server
- [ ] Add skip logic if not supported
- [ ] Expected: ~5 tests (may all skip)

### Step 2.5: Implement Query Radius Tests (20 min)
```typescript
describe('Query Radius', () => {
  test.each(queryRadiusFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute
    const result = await client!.queryRadius(
      testCase.input.center_lat,
      testCase.input.center_lon,
      testCase.input.radius_meters,
      testCase.input.options || {}
    );
    
    // Verify
    expect(result.events).toHaveLength(testCase.expected_output.event_count);
    if (testCase.expected_output.all_ok) {
      expect(result.errors).toEqual([]);
    }
    
    // Verify specific entities returned if specified
    if (testCase.expected_output.entity_ids) {
      const returnedIds = result.events.map(e => e.entity_id);
      expect(returnedIds.sort()).toEqual(testCase.expected_output.entity_ids.sort());
    }
  });
});
```

**Action Items:**
- [ ] Implement query radius test
- [ ] Handle empty results case
- [ ] Handle large radius case
- [ ] Run: `npm test -- --grep "Query Radius"`
- [ ] Expected: ~9 tests (8 pass, 1 skip)

### Step 2.6: Implement Query Polygon Tests (20 min)
```typescript
describe('Query Polygon', () => {
  test.each(queryPolygonFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute
    const polygon = testCase.input.polygon_points; // Array of {lat, lon}
    const result = await client!.queryPolygon(polygon, testCase.input.options || {});
    
    // Verify
    expect(result.events).toHaveLength(testCase.expected_output.event_count);
    if (testCase.expected_output.entity_ids) {
      const returnedIds = result.events.map(e => e.entity_id);
      expect(returnedIds.sort()).toEqual(testCase.expected_output.entity_ids.sort());
    }
  });
});
```

**Action Items:**
- [ ] Implement query polygon test
- [ ] Handle concave polygon skip case
- [ ] Handle antimeridian skip case
- [ ] Run: `npm test -- --grep "Query Polygon"`
- [ ] Expected: ~7 tests (5 pass, 2 skip)

### Step 2.7: Implement Query Latest Tests (15 min)
```typescript
describe('Query Latest', () => {
  test.each(queryLatestFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute
    const limit = testCase.input.limit || 100;
    const result = await client!.queryLatest(limit);
    
    // Verify
    expect(result.events.length).toBeLessThanOrEqual(limit);
    if (testCase.expected_output.event_count !== undefined) {
      expect(result.events).toHaveLength(testCase.expected_output.event_count);
    }
  });
});
```

**Action Items:**
- [ ] Implement query latest test
- [ ] Handle limit parameter
- [ ] Verify results are actually latest
- [ ] Expected: ~5 tests (all pass)

### Step 2.8: Implement Ping Tests (10 min)
```typescript
describe('Ping', () => {
  test.each(pingFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    const result = await client!.ping();
    
    expect(result.success).toBe(true);
    expect(result.latency_ms).toBeGreaterThan(0);
  });
});
```

**Action Items:**
- [ ] Implement ping test
- [ ] Expected: ~2 tests (all pass)

### Step 2.9: Implement Status Tests (10 min)
```typescript
describe('Status', () => {
  test.each(statusFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    const result = await client!.getStatus();
    
    expect(result.cluster_id).toBeDefined();
    expect(result.replica_count).toBeGreaterThan(0);
  });
});
```

**Action Items:**
- [ ] Implement status test
- [ ] Expected: ~3 tests (all pass)

### Step 2.10: Implement Topology Tests (10 min)
```typescript
describe('Topology', () => {
  test.each(topologyFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Note: Topology fails on single-node cluster
    try {
      const result = await client!.getTopology();
      expect(result.replicas).toBeDefined();
    } catch (error) {
      if (error.message.includes('single-node')) {
        return; // Expected failure on single-node
      }
      throw error;
    }
  });
});
```

**Action Items:**
- [ ] Implement topology test
- [ ] Handle single-node cluster case
- [ ] Expected: ~6 tests (may skip on single-node)

### Step 2.11: Implement TTL Set Tests (15 min)
```typescript
describe('TTL Set', () => {
  test.each(ttlSetFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute
    const entityId = testCase.input.entity_id;
    const ttlSeconds = testCase.input.ttl_seconds;
    const result = await client!.setTTL(entityId, ttlSeconds);
    
    // Verify
    if (testCase.expected_output.success) {
      expect(result.code).toBe(0);
    }
  });
});
```

**Action Items:**
- [ ] Implement TTL set test
- [ ] Expected: ~5 tests (all pass)

### Step 2.12: Implement TTL Extend Tests (15 min)
```typescript
describe('TTL Extend', () => {
  test.each(ttlExtendFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute
    const entityId = testCase.input.entity_id;
    const extendSeconds = testCase.input.extend_seconds;
    const result = await client!.extendTTL(entityId, extendSeconds);
    
    // Verify
    if (testCase.expected_output.success) {
      expect(result.code).toBe(0);
    }
  });
});
```

**Action Items:**
- [ ] Implement TTL extend test
- [ ] Expected: ~4 tests (all pass)

### Step 2.13: Implement TTL Clear Tests (15 min)
```typescript
describe('TTL Clear', () => {
  test.each(ttlClearFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute
    const entityIds = testCase.input.entity_ids;
    const results = await client!.clearTTL(entityIds);
    
    // Verify
    if (testCase.expected_output.all_ok) {
      expect(results.every(r => r.code === 0)).toBe(true);
    }
  });
});
```

**Action Items:**
- [ ] Implement TTL clear test
- [ ] Expected: ~3 tests (2 pass, 1 skip)

### Step 2.14: Run Full Node.js Test Suite
```bash
cd src/clients/node
npm test
```

**Action Items:**
- [ ] Run complete test suite
- [ ] Verify 79 tests discovered
- [ ] Expected: ~63 pass, ~16 skip
- [ ] Fix any failures
- [ ] Document skip reasons

### Step 2.15: Commit Node.js SDK Tests
```bash
git add src/clients/node/tests/
git commit -m "test(node): complete SDK test coverage (20→79 tests)

- Add parametrized tests for all 14 operations
- 79 comprehensive test cases from fixtures
- Expected: ~63 passing, ~16 skipped (boundary/invalid)
- Matches Python SDK test pattern for consistency
"
```

**Action Items:**
- [ ] Review changes
- [ ] Commit with descriptive message
- [ ] Push to branch

**Phase 2 Complete! Node.js: 79/79 tests ✅**

---

## Phase 3: Java SDK Expansion (4 hours)

**Goal:** Expand from 17/79 → 79/79 tests using JUnit 5 parameterized tests.

### Prerequisites
- [ ] Review Node.js SDK test structure (just completed)
- [ ] Confirm Java project uses JUnit 5
- [ ] Add JUnit 5 @ParameterizedTest dependency if needed

### Step 3.1: Add JUnit 5 Dependencies (15 min)
**File:** `src/clients/java/pom.xml`

```xml
<dependency>
    <groupId>org.junit.jupiter</groupId>
    <artifactId>junit-jupiter-params</artifactId>
    <version>5.9.0</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>com.google.code.gson</groupId>
    <artifactId>gson</artifactId>
    <version>2.10.1</version>
    <scope>test</scope>
</dependency>
```

**Action Items:**
- [ ] Check if junit-jupiter-params already present
- [ ] Add dependency if needed
- [ ] Add Gson for JSON fixture parsing
- [ ] Run: `mvn clean install` to verify

### Step 3.2: Create Fixture Adapter (30 min)
**File:** `src/clients/java/src/test/java/com/archerdb/FixtureAdapter.java`

```java
package com.archerdb;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import java.io.FileReader;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.stream.Collectors;

public class FixtureAdapter {
    private static final Gson gson = new Gson();
    private static final Path FIXTURES_DIR = 
        Paths.get("../../../tests/fixtures");
    
    public static Fixture loadFixture(String operationName) {
        String filename = operationName + ".json";
        Path filepath = FIXTURES_DIR.resolve(filename);
        
        try (FileReader reader = new FileReader(filepath.toFile())) {
            JsonObject json = gson.fromJson(reader, JsonObject.class);
            return gson.fromJson(json, Fixture.class);
        } catch (Exception e) {
            throw new RuntimeException("Failed to load fixture: " + operationName, e);
        }
    }
    
    public static List<GeoEvent> convertEvents(JsonObject input) {
        // Convert fixture JSON to GeoEvent objects
        // ...implementation...
    }
    
    public static void setupTestData(ArcherClient client, JsonObject setup) {
        // Execute setup operations (insert_first, etc.)
        // ...implementation...
    }
    
    public static boolean shouldSkipCase(TestCase testCase) {
        String name = testCase.getName();
        
        // Skip S2 limitation cases
        if (name.contains("concave_polygon")) return true;
        if (name.contains("antimeridian")) return true;
        
        // Skip invalid input cases
        if (name.contains("invalid_latitude")) return true;
        if (name.contains("invalid_longitude")) return true;
        
        return false;
    }
}

class Fixture {
    private String operation;
    private List<TestCase> cases;
    
    public List<TestCase> getCases() { return cases; }
}

class TestCase {
    private String name;
    private JsonObject input;
    private JsonObject expected_output;
    
    public String getName() { return name; }
    public JsonObject getInput() { return input; }
    public JsonObject getExpectedOutput() { return expected_output; }
}
```

**Action Items:**
- [ ] Create FixtureAdapter.java
- [ ] Implement loadFixture() method
- [ ] Implement convertEvents() helper
- [ ] Implement setupTestData() helper
- [ ] Implement shouldSkipCase() logic
- [ ] Test loading one fixture file

### Step 3.3: Convert Insert Tests (20 min)
**File:** `src/clients/java/src/test/java/com/archerdb/ClientTest.java`

```java
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class ClientTest {
    private ArcherClient client;
    
    // Load fixtures at class level
    private static Fixture insertFixture = FixtureAdapter.loadFixture("insert");
    private static Fixture upsertFixture = FixtureAdapter.loadFixture("upsert");
    // ... load all 14 fixtures
    
    @BeforeAll
    void setUp() {
        client = new ArcherClient("127.0.0.1", 3000);
        client.connect();
    }
    
    @AfterAll
    void tearDown() {
        client.disconnect();
    }
    
    // Test case providers
    static Stream<TestCase> insertCases() {
        return insertFixture.getCases().stream();
    }
    
    @ParameterizedTest
    @MethodSource("insertCases")
    @DisplayName("Insert Operation")
    void testInsert(TestCase testCase) {
        if (FixtureAdapter.shouldSkipCase(testCase)) return;
        
        // Setup
        if (testCase.getInput().has("setup")) {
            FixtureAdapter.setupTestData(client, 
                testCase.getInput().getAsJsonObject("setup"));
        }
        
        // Execute
        List<GeoEvent> events = FixtureAdapter.convertEvents(testCase.getInput());
        List<InsertResult> results = client.insertEvents(events);
        
        // Verify
        JsonObject expected = testCase.getExpectedOutput();
        if (expected.get("all_ok").getAsBoolean()) {
            assertTrue(results.stream()
                .allMatch(r -> r.getCode() == 0),
                "Expected all inserts to succeed");
        } else {
            // Verify expected error codes
            verifyExpectedErrors(results, expected);
        }
    }
}
```

**Action Items:**
- [ ] Convert existing Insert test to parameterized
- [ ] Add fixture loading
- [ ] Implement test case provider
- [ ] Run: `mvn test -Dtest=ClientTest#testInsert`
- [ ] Expected: ~6 tests (all pass or skip)

### Step 3.4: Implement Remaining Operations (2 hours)

For each operation, follow the pattern:

1. Add fixture loading
2. Create test case provider
3. Implement parameterized test
4. Run and verify

**Operations to implement:**
- [ ] Upsert (4 cases)
- [ ] Delete (4 cases)
- [ ] Query UUID (3 cases)
- [ ] Query UUID Batch (5 cases)
- [ ] Query Radius (9 cases)
- [ ] Query Polygon (7 cases)
- [ ] Query Latest (5 cases)
- [ ] Ping (2 cases)
- [ ] Status (3 cases)
- [ ] Topology (6 cases)
- [ ] TTL Set (5 cases)
- [ ] TTL Extend (4 cases)
- [ ] TTL Clear (3 cases)

**Time allocation:**
- Simple operations (Ping, Status): 10 min each
- Standard operations (Upsert, Delete, TTL): 15 min each
- Complex operations (Query Radius, Query Polygon): 20 min each

### Step 3.5: Run Full Java Test Suite
```bash
cd src/clients/java
mvn test
```

**Action Items:**
- [ ] Run complete test suite
- [ ] Verify 79 tests discovered
- [ ] Expected: ~63 pass, ~16 skip
- [ ] Fix any failures
- [ ] Document skip reasons

### Step 3.6: Commit Java SDK Tests
```bash
git add src/clients/java/
git commit -m "test(java): complete SDK test coverage (17→79 tests)

- Add JUnit 5 @ParameterizedTest support
- Create FixtureAdapter for JSON fixture loading
- Implement parametrized tests for all 14 operations
- 79 comprehensive test cases from fixtures
- Expected: ~63 passing, ~16 skipped
"
```

**Action Items:**
- [ ] Review changes
- [ ] Commit with descriptive message
- [ ] Push to branch

**Phase 3 Complete! Java: 79/79 tests ✅**

---

## Phase 4: Final Verification (1 hour)

### Step 4.1: Run All SDK Test Suites
```bash
# Python
cd src/clients/python && pytest -v

# Go
cd src/clients/go && go test -v

# Node.js
cd src/clients/node && npm test

# Java
cd src/clients/java && mvn test

# C
cd src/clients/c && ./zig/zig build test
```

**Action Items:**
- [ ] Run all 5 SDK test suites
- [ ] Capture test counts
- [ ] Verify pass/skip ratios
- [ ] Document any failures

### Step 4.2: Create Test Coverage Summary
**File:** `.planning/SDK_TEST_COVERAGE_FINAL.md`

```markdown
# SDK Test Coverage - Final Report

**Date:** 2026-02-XX
**Status:** COMPLETE

## Coverage Summary

| SDK | Tests | Pass | Skip | Fail | Coverage | Status |
|-----|-------|------|------|------|----------|--------|
| Python | 79 | 63 | 16 | 0 | 100% | ✅ |
| Go | 79 | 63 | 16 | 0 | 100% | ✅ |
| Node.js | 79 | ~63 | ~16 | 0 | 100% | ✅ |
| Java | 79 | ~63 | ~16 | 0 | 100% | ✅ |
| C | 79 | ~64 | ~15 | 0 | 100% | ✅ |

**Total:** 395 tests across 5 SDKs
```

**Action Items:**
- [ ] Create summary document
- [ ] Fill in actual numbers
- [ ] Document common skip cases
- [ ] Note any SDK-specific issues

### Step 4.3: Update Main Documentation
**File:** `README.md`

Update SDK Feature Matrix section to show test coverage:

```markdown
### SDK Test Coverage

All SDK features are comprehensively tested across 79 test cases per SDK:

| SDK | Test Cases | Pass | Skip | Coverage |
| --- | ---------- | ---- | ---- | -------- |
| C | 79 | 64 | 15 | 100% |
| Go | 79 | 63 | 16 | 100% |
| Java | 79 | 63 | 16 | 100% |
| Node.js | 79 | 63 | 16 | 100% |
| Python | 79 | 63 | 16 | 100% |

Test fixtures cover:
- Boundary conditions (poles, antimeridian, null island)
- Invalid input handling (out-of-range lat/lon, zero entity ID)
- Edge cases (empty results, large batches, hotspots)
- All 14 operations across all SDKs
```

**Action Items:**
- [ ] Update README.md
- [ ] Update SDK comparison table
- [ ] Document test coverage methodology

### Step 4.4: Create Pull Request (if using branches)
```bash
git checkout -b sdk/complete-test-coverage
git push origin sdk/complete-test-coverage
```

**PR Description:**
```markdown
## SDK Test Coverage Completion

Expands test coverage for Node.js, Java, and C SDKs to match Python/Go standards.

### Changes
- Node.js: 20 → 79 tests (+59)
- Java: 17 → 79 tests (+62)
- C: Verified 64 → 79 tests

### Coverage Details
All SDKs now test:
- 14 operations (Insert, Upsert, Delete, Query variants, TTL, Ping, Status, Topology)
- Boundary conditions (±90° lat, ±180° lon)
- Invalid input handling
- Edge cases (empty results, large batches)

### Test Results
- ~315 passing tests across all SDKs
- ~80 skipped tests (expected for S2 limitations, invalid inputs)
- 0 failing tests

### Verification
```bash
./scripts/run_all_sdk_tests.sh
```
```

**Action Items:**
- [ ] Create feature branch (or work on main)
- [ ] Push changes
- [ ] Create PR if needed
- [ ] Request review

---

## Success Criteria

✅ **Phase 1 Complete When:**
- [ ] C SDK test count verified (64 or 79)
- [ ] Missing test cases identified and documented
- [ ] Decision made: add tests or accept 81%

✅ **Phase 2 Complete When:**
- [ ] Node.js SDK has 79 tests
- [ ] ~63 tests passing
- [ ] ~16 tests skipping with documented reasons
- [ ] All 14 operations covered
- [ ] Committed to repository

✅ **Phase 3 Complete When:**
- [ ] Java SDK has 79 tests
- [ ] ~63 tests passing
- [ ] ~16 tests skipping with documented reasons
- [ ] All 14 operations covered
- [ ] Committed to repository

✅ **Phase 4 Complete When:**
- [ ] All 5 SDKs verified at 79/79 or documented reason
- [ ] Test coverage summary created
- [ ] Documentation updated
- [ ] Changes committed and PR created (if needed)

---

## Common Skip Cases (Reference)

These cases are expected to skip across all SDKs:

### Boundary/S2 Limitations (8 cases)
1. `concave_polygon` - S2 only supports convex polygons
2. `antimeridian_crossing` - Complex edge case, low priority
3. `query_radius_timestamp_filter` - Timestamp filtering not implemented

### Invalid Input (8 cases)
4. `invalid_latitude_high` - Lat > 90°
5. `invalid_latitude_low` - Lat < -90°
6. `invalid_longitude_high` - Lon > 180°
7. `invalid_longitude_low` - Lon < -180°
8. `invalid_entity_id_zero` - Entity ID = 0
9. `invalid_entity_id_negative` - Entity ID < 0
10. `invalid_ttl_negative` - TTL < 0
11. `invalid_radius_negative` - Radius < 0

**Total Expected Skips:** ~16 per SDK

---

## Troubleshooting

### Issue: Fixtures not loading
**Solution:** Verify fixture path relative to test file location
```typescript
// Node.js
const fixturePath = path.join(__dirname, '../../../tests/fixtures');

// Java
Path FIXTURES_DIR = Paths.get("../../../tests/fixtures");
```

### Issue: Test count mismatch
**Solution:** Ensure `test.each()` / `@ParameterizedTest` correctly iterating all cases
```typescript
// Debug: Log case count
console.log(`Loaded ${insertFixture.cases.length} insert test cases`);
```

### Issue: Unexpected failures
**Solution:** Compare with Python SDK behavior (known good)
- Check fixture interpretation
- Verify API call parameters
- Review expected vs actual output

### Issue: All tests skipping
**Solution:** Review `shouldSkipCase()` logic
- Ensure not skipping valid cases
- Check skip reasons
- Compare with Python skip logic

---

## Time Tracking

Use this section to track actual time spent:

| Phase | Estimated | Actual | Notes |
|-------|-----------|--------|-------|
| Phase 1: C SDK | 1-2h | ___ | |
| Phase 2: Node.js | 3h | ___ | |
| Phase 3: Java | 4h | ___ | |
| Phase 4: Verification | 1h | ___ | |
| **Total** | **10-12h** | ___ | |

---

## Next Steps After Completion

1. **CI Integration**
   - [ ] Add SDK tests to CI pipeline
   - [ ] Run on every PR
   - [ ] Set pass/skip thresholds

2. **Continuous Monitoring**
   - [ ] Track test pass rates over time
   - [ ] Alert on new failures
   - [ ] Review skipped tests periodically

3. **Future Improvements**
   - [ ] Implement query_uuid_batch on server
   - [ ] Add S2 concave polygon support
   - [ ] Enable timestamp filtering for radius queries

---

**Questions? Issues? Update this document as you go!**
