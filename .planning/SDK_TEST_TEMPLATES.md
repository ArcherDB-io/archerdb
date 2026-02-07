# SDK Test Templates

Copy-paste templates for implementing tests. Just modify the operation-specific parts.

---

## Node.js Template

### Basic Operation (Insert, Upsert, Delete)
```typescript
describe('DELETE_OPERATION_NAME', () => {
  test.each(OPERATION_NAMEFixture.cases)('$name', async (testCase) => {
    // Skip boundary/invalid cases
    if (shouldSkipCase(testCase)) return;
    
    // Setup: Insert test data if needed
    if (testCase.input.setup?.insert_first) {
      const setupEvents = testCase.input.setup.insert_first.map(e => ({
        entityId: e.entity_id,
        lat: e.lat,
        lon: e.lon,
        timestamp: e.timestamp || Date.now(),
        groupId: e.group_id || 0
      }));
      await client!.insertEvents(setupEvents);
    }
    
    // Execute operation
    const INPUT_PARAM = testCase.input.PARAM_NAME;
    const result = await client!.OPERATION_METHOD(INPUT_PARAM);
    
    // Verify results
    if (testCase.expected_output.all_ok) {
      expect(result.errors).toEqual([]);
      expect(result.success).toBe(true);
    } else {
      // Handle expected errors
      expect(result.errors.length).toBeGreaterThan(0);
    }
  });
});
```

### Query Operation (Radius, Polygon, Latest)
```typescript
describe('QUERY_OPERATION_NAME', () => {
  test.each(QUERY_NAMEFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.input.setup?.insert_first) {
      const setupEvents = testCase.input.setup.insert_first.map(e => ({
        entityId: e.entity_id,
        lat: e.lat,
        lon: e.lon,
        timestamp: e.timestamp || Date.now()
      }));
      await client!.insertEvents(setupEvents);
    }
    
    // Execute query
    const result = await client!.QUERY_METHOD(
      testCase.input.PARAM1,
      testCase.input.PARAM2,
      testCase.input.options || {}
    );
    
    // Verify result count
    expect(result.events).toHaveLength(testCase.expected_output.event_count);
    
    // Verify specific entities if specified
    if (testCase.expected_output.entity_ids) {
      const returnedIds = result.events.map(e => e.entityId);
      expect(returnedIds.sort()).toEqual(testCase.expected_output.entity_ids.sort());
    }
    
    // Verify all operations succeeded
    if (testCase.expected_output.all_ok) {
      expect(result.errors).toEqual([]);
    }
  });
});
```

### Simple Operation (Ping, Status, Topology)
```typescript
describe('OPERATION_NAME', () => {
  test.each(OPERATION_NAMEFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // No setup needed for cluster operations
    
    // Execute
    const result = await client!.OPERATION_METHOD();
    
    // Verify
    expect(result).toBeDefined();
    expect(result.EXPECTED_FIELD).toBeDefined();
    
    // For topology: handle single-node cluster case
    // if (error.message.includes('single-node')) return;
  });
});
```

### TTL Operation
```typescript
describe('TTL_OPERATION_NAME', () => {
  test.each(ttlOPERATIONFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup: Insert entity first
    if (testCase.input.setup?.insert_first) {
      await setupTestData(client!, testCase.input.setup);
    }
    
    // Execute TTL operation
    const entityId = testCase.input.entity_id;
    const ttlValue = testCase.input.TTL_PARAM;
    const result = await client!.TTL_METHOD(entityId, ttlValue);
    
    // Verify
    if (testCase.expected_output.success) {
      expect(result.code).toBe(0);
    } else {
      expect(result.code).not.toBe(0);
    }
  });
});
```

---

## Java Template

### Basic Operation
```java
// Load fixture at class level
private static Fixture OPERATION_NAMEFixture = 
    FixtureAdapter.loadFixture("OPERATION_NAME");

// Test case provider
static Stream<TestCase> OPERATION_NAMECases() {
    return OPERATION_NAMEFixture.getCases().stream();
}

// Parameterized test
@ParameterizedTest
@MethodSource("OPERATION_NAMECases")
@DisplayName("OPERATION_NAME Operation")
void testOPERATION_NAME(TestCase testCase) {
    if (FixtureAdapter.shouldSkipCase(testCase)) return;
    
    // Setup
    if (testCase.getInput().has("setup")) {
        FixtureAdapter.setupTestData(client, 
            testCase.getInput().getAsJsonObject("setup"));
    }
    
    // Execute
    INPUT_TYPE input = FixtureAdapter.convertInput(testCase.getInput());
    RESULT_TYPE result = client.OPERATION_METHOD(input);
    
    // Verify
    JsonObject expected = testCase.getExpectedOutput();
    if (expected.get("all_ok").getAsBoolean()) {
        assertTrue(result.isSuccess(), 
            "Expected operation to succeed");
    } else {
        assertFalse(result.isSuccess(),
            "Expected operation to fail");
    }
}
```

### Query Operation
```java
private static Fixture QUERY_NAMEFixture = 
    FixtureAdapter.loadFixture("QUERY_NAME");

static Stream<TestCase> QUERY_NAMECases() {
    return QUERY_NAMEFixture.getCases().stream();
}

@ParameterizedTest
@MethodSource("QUERY_NAMECases")
@DisplayName("QUERY_NAME Query")
void testQUERY_NAME(TestCase testCase) {
    if (FixtureAdapter.shouldSkipCase(testCase)) return;
    
    // Setup test data
    if (testCase.getInput().has("setup")) {
        FixtureAdapter.setupTestData(client, 
            testCase.getInput().getAsJsonObject("setup"));
    }
    
    // Execute query
    JsonObject input = testCase.getInput();
    List<GeoEvent> results = client.QUERY_METHOD(
        input.get("PARAM1").getAsDouble(),
        input.get("PARAM2").getAsDouble()
    );
    
    // Verify
    JsonObject expected = testCase.getExpectedOutput();
    int expectedCount = expected.get("event_count").getAsInt();
    assertEquals(expectedCount, results.size(), 
        "Expected " + expectedCount + " results");
    
    // Verify specific entity IDs if specified
    if (expected.has("entity_ids")) {
        JsonArray expectedIds = expected.getAsJsonArray("entity_ids");
        List<Long> resultIds = results.stream()
            .map(GeoEvent::getEntityId)
            .sorted()
            .collect(Collectors.toList());
        
        List<Long> expectedIdsList = new ArrayList<>();
        expectedIds.forEach(id -> expectedIdsList.add(id.getAsLong()));
        Collections.sort(expectedIdsList);
        
        assertEquals(expectedIdsList, resultIds,
            "Result entity IDs should match expected");
    }
}
```

---

## Fixture Structure Reference

### Insert Fixture Example
```json
{
  "operation": "insert",
  "cases": [
    {
      "name": "valid_single_event",
      "input": {
        "events": [
          {
            "entity_id": 1,
            "lat": 37.7749,
            "lon": -122.4194,
            "timestamp": 1234567890,
            "group_id": 0
          }
        ]
      },
      "expected_output": {
        "all_ok": true,
        "success_count": 1,
        "error_count": 0
      }
    },
    {
      "name": "invalid_latitude_high",
      "input": {
        "events": [
          {
            "entity_id": 2,
            "lat": 91.0,
            "lon": 0.0
          }
        ]
      },
      "expected_output": {
        "all_ok": false,
        "error_codes": [400]
      }
    }
  ]
}
```

### Query Radius Fixture Example
```json
{
  "operation": "query_radius",
  "cases": [
    {
      "name": "finds_nearby_events",
      "input": {
        "setup": {
          "insert_first": [
            {"entity_id": 1, "lat": 37.7749, "lon": -122.4194},
            {"entity_id": 2, "lat": 37.7750, "lon": -122.4195}
          ]
        },
        "center_lat": 37.7749,
        "center_lon": -122.4194,
        "radius_meters": 100,
        "options": {}
      },
      "expected_output": {
        "event_count": 2,
        "entity_ids": [1, 2],
        "all_ok": true
      }
    },
    {
      "name": "empty_result",
      "input": {
        "center_lat": 0.0,
        "center_lon": 0.0,
        "radius_meters": 1,
        "options": {}
      },
      "expected_output": {
        "event_count": 0,
        "all_ok": true
      }
    }
  ]
}
```

---

## Skip Logic Reference

### Node.js shouldSkipCase()
```typescript
function shouldSkipCase(testCase: TestCase): boolean {
  const name = testCase.name;
  
  // S2 geometry limitations
  if (name.includes('concave_polygon')) return true;
  if (name.includes('antimeridian')) return true;
  
  // Invalid input (expected to be rejected)
  if (name.includes('invalid_latitude')) return true;
  if (name.includes('invalid_longitude')) return true;
  if (name.includes('invalid_entity_id')) return true;
  if (name.includes('invalid_ttl')) return true;
  if (name.includes('invalid_radius')) return true;
  
  // Not implemented features
  if (name.includes('timestamp_filter')) return true;
  
  // Single-node cluster limitations
  if (testCase.name.includes('topology') && isSingleNodeCluster()) {
    return true;
  }
  
  return false;
}
```

### Java shouldSkipCase()
```java
public static boolean shouldSkipCase(TestCase testCase) {
    String name = testCase.getName();
    
    // S2 limitations
    if (name.contains("concave_polygon")) return true;
    if (name.contains("antimeridian")) return true;
    
    // Invalid input
    if (name.contains("invalid_latitude")) return true;
    if (name.contains("invalid_longitude")) return true;
    if (name.contains("invalid_entity_id")) return true;
    if (name.contains("invalid_ttl")) return true;
    if (name.contains("invalid_radius")) return true;
    
    // Not implemented
    if (name.contains("timestamp_filter")) return true;
    
    return false;
}
```

---

## Setup Helper Reference

### Node.js setupTestData()
```typescript
async function setupTestData(
  client: ArcherClient, 
  setup: any
): Promise<void> {
  if (setup.insert_first) {
    const events = setup.insert_first.map((e: any) => ({
      entityId: e.entity_id,
      lat: e.lat,
      lon: e.lon,
      timestamp: e.timestamp || Date.now(),
      groupId: e.group_id || 0
    }));
    await client.insertEvents(events);
  }
  
  if (setup.set_ttl) {
    for (const ttl of setup.set_ttl) {
      await client.setTTL(ttl.entity_id, ttl.ttl_seconds);
    }
  }
}
```

### Java setupTestData()
```java
public static void setupTestData(
    ArcherClient client, 
    JsonObject setup
) {
    if (setup.has("insert_first")) {
        JsonArray events = setup.getAsJsonArray("insert_first");
        List<GeoEvent> geoEvents = new ArrayList<>();
        
        for (JsonElement elem : events) {
            JsonObject event = elem.getAsJsonObject();
            geoEvents.add(new GeoEvent(
                event.get("entity_id").getAsLong(),
                event.get("lat").getAsDouble(),
                event.get("lon").getAsDouble(),
                event.has("timestamp") 
                    ? event.get("timestamp").getAsLong() 
                    : System.currentTimeMillis(),
                event.has("group_id") 
                    ? event.get("group_id").getAsInt() 
                    : 0
            ));
        }
        
        client.insertEvents(geoEvents);
    }
    
    if (setup.has("set_ttl")) {
        JsonArray ttls = setup.getAsJsonArray("set_ttl");
        for (JsonElement elem : ttls) {
            JsonObject ttl = elem.getAsJsonObject();
            client.setTTL(
                ttl.get("entity_id").getAsLong(),
                ttl.get("ttl_seconds").getAsInt()
            );
        }
    }
}
```

---

## Verification Helper Reference

### Node.js verifyExpectedErrors()
```typescript
function verifyExpectedErrors(
  results: OperationResult[], 
  expectedOutput: any
): void {
  const errorCodes = results
    .filter(r => r.code !== 0)
    .map(r => r.code);
  
  if (expectedOutput.error_codes) {
    expect(errorCodes).toEqual(expectedOutput.error_codes);
  }
  
  if (expectedOutput.error_count !== undefined) {
    expect(errorCodes.length).toBe(expectedOutput.error_count);
  }
}
```

### Java verifyExpectedErrors()
```java
private void verifyExpectedErrors(
    List<OperationResult> results,
    JsonObject expectedOutput
) {
    List<Integer> errorCodes = results.stream()
        .filter(r -> r.getCode() != 0)
        .map(OperationResult::getCode)
        .collect(Collectors.toList());
    
    if (expectedOutput.has("error_codes")) {
        JsonArray expected = expectedOutput.getAsJsonArray("error_codes");
        List<Integer> expectedCodes = new ArrayList<>();
        expected.forEach(e -> expectedCodes.add(e.getAsInt()));
        
        assertEquals(expectedCodes, errorCodes,
            "Error codes should match expected");
    }
    
    if (expectedOutput.has("error_count")) {
        int expectedCount = expectedOutput.get("error_count").getAsInt();
        assertEquals(expectedCount, errorCodes.size(),
            "Error count should match expected");
    }
}
```

---

## Quick Copy-Paste: Complete Example

### Node.js Query Radius (Complete)
```typescript
describe('Query Radius', () => {
  test.each(queryRadiusFixture.cases)('$name', async (testCase) => {
    if (shouldSkipCase(testCase)) return;
    
    // Setup test data
    if (testCase.input.setup?.insert_first) {
      const setupEvents = testCase.input.setup.insert_first.map(e => ({
        entityId: e.entity_id,
        lat: e.lat,
        lon: e.lon,
        timestamp: e.timestamp || Date.now(),
        groupId: e.group_id || 0
      }));
      await client!.insertEvents(setupEvents);
    }
    
    // Execute radius query
    const result = await client!.queryRadius(
      testCase.input.center_lat,
      testCase.input.center_lon,
      testCase.input.radius_meters,
      testCase.input.options || {}
    );
    
    // Verify event count
    expect(result.events).toHaveLength(testCase.expected_output.event_count);
    
    // Verify specific entities if specified
    if (testCase.expected_output.entity_ids) {
      const returnedIds = result.events.map(e => e.entityId);
      expect(returnedIds.sort()).toEqual(
        testCase.expected_output.entity_ids.sort()
      );
    }
    
    // Verify no errors if expected
    if (testCase.expected_output.all_ok) {
      expect(result.errors).toEqual([]);
    }
  });
});
```

---

**Use these templates as your starting point - just search/replace the operation-specific parts!**
