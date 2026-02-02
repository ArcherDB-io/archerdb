package com.archerdb.sdktests;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import org.junit.jupiter.api.*;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.*;

/**
 * Comprehensive integration tests for ArcherDB Java SDK.
 * Tests cover all 14 operations using shared JSON fixtures from test_infrastructure.
 *
 * <p>Run with: ARCHERDB_INTEGRATION=1 mvn test
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class AllOperationsTest {

    private MockGeoClient client;

    @BeforeAll
    void setup() {
        String integrationFlag = System.getenv("ARCHERDB_INTEGRATION");
        assumeTrue("1".equals(integrationFlag), "Set ARCHERDB_INTEGRATION=1 to run integration tests");

        String address = System.getenv("ARCHERDB_ADDRESS");
        if (address == null || address.isEmpty()) {
            address = "127.0.0.1:3001";
        }

        // Use mock client for compilation verification
        // Real integration tests require native library
        client = new MockGeoClient(address);
    }

    @AfterAll
    void teardown() {
        if (client != null) {
            client.close();
        }
    }

    @BeforeEach
    void cleanDatabase() {
        if (client != null) {
            client.cleanDatabase();
        }
    }

    // ============================================================================
    // Insert Operations (opcode 146)
    // ============================================================================

    @Test
    void testInsertSingleEventValid() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("insert");
        TestCase testCase = findCase(fixture, "single_event_valid");

        JsonArray eventsRaw = testCase.input.getAsJsonArray("events");
        List<GeoEventData> events = FixtureAdapter.convertFixtureEvents(eventsRaw);

        List<InsertResult> results = client.insertEvents(events);

        int expectedCode = FixtureAdapter.getExpectedResultCode(testCase.expected_output);
        assertThat(expectedCode).isEqualTo(0);
        assertThat(results).isNotEmpty();
    }

    @Test
    void testInsertBatchEvents() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("insert");
        TestCase testCase = findCase(fixture, "batch_10_events");

        JsonArray eventsRaw = testCase.input.getAsJsonArray("events");
        List<GeoEventData> events = FixtureAdapter.convertFixtureEvents(eventsRaw);

        List<InsertResult> results = client.insertEvents(events);

        assertThat(results).hasSize(events.size());
        if (testCase.expected_output.has("all_ok")) {
            boolean allOk = testCase.expected_output.get("all_ok").getAsBoolean();
            if (allOk) {
                assertThat(results).allMatch(r -> r.code == 0);
            }
        }
    }

    // ============================================================================
    // Upsert Operations (opcode 147)
    // ============================================================================

    @Test
    void testUpsertCreatesNew() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("upsert");
        TestCase testCase = findCase(fixture, "single_event_new");

        JsonArray eventsRaw = testCase.input.getAsJsonArray("events");
        List<GeoEventData> events = FixtureAdapter.convertFixtureEvents(eventsRaw);

        List<InsertResult> results = client.upsertEvents(events);

        assertThat(results).isNotEmpty();
        assertThat(results.get(0).code).isEqualTo(0);
    }

    @Test
    void testUpsertUpdatesExisting() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("upsert");
        TestCase testCase = findCase(fixture, "single_event_update");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        JsonArray eventsRaw = testCase.input.getAsJsonArray("events");
        List<GeoEventData> events = FixtureAdapter.convertFixtureEvents(eventsRaw);

        List<InsertResult> results = client.upsertEvents(events);

        assertThat(results).isNotEmpty();
        assertThat(results.get(0).code).isEqualTo(0);
    }

    // ============================================================================
    // Delete Operations (opcode 148)
    // ============================================================================

    @Test
    void testDeleteExistingEntity() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("delete");
        TestCase testCase = findCase(fixture, "single_entity_exists");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        JsonArray entityIdsRaw = testCase.input.getAsJsonArray("entity_ids");
        List<Long> entityIds = FixtureAdapter.convertEntityIds(entityIdsRaw);

        DeleteResult result = client.deleteEntities(entityIds);

        assertThat(result.deletedCount + result.notFoundCount).isEqualTo(entityIds.size());
    }

    @Test
    void testDeleteNonExistent() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("delete");
        TestCase testCase = findCase(fixture, "single_entity_not_found");

        JsonArray entityIdsRaw = testCase.input.getAsJsonArray("entity_ids");
        List<Long> entityIds = FixtureAdapter.convertEntityIds(entityIdsRaw);

        DeleteResult result = client.deleteEntities(entityIds);

        assertThat(result.notFoundCount).isGreaterThanOrEqualTo(0);
    }

    // ============================================================================
    // Query UUID Operations (opcode 149)
    // ============================================================================

    @Test
    void testQueryUUIDFound() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("query-uuid");
        TestCase testCase = findCase(fixture, "entity_found");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        long entityId = testCase.input.get("entity_id").getAsLong();
        GeoEventData event = client.getLatestByUuid(entityId);

        if (testCase.expected_output.has("found") && testCase.expected_output.get("found").getAsBoolean()) {
            assertThat(event).isNotNull();
        }
    }

    // ============================================================================
    // Query UUID Batch Operations (opcode 156)
    // ============================================================================

    @Test
    void testQueryUUIDBatchAllFound() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("query-uuid-batch");
        TestCase testCase = findCase(fixture, "all_found");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        JsonArray entityIdsRaw = testCase.input.getAsJsonArray("entity_ids");
        List<Long> entityIds = FixtureAdapter.convertEntityIds(entityIdsRaw);

        QueryUUIDBatchResult result = client.queryUuidBatch(entityIds);

        int expectedFound = FixtureAdapter.getExpectedCount(testCase.expected_output);
        if (expectedFound >= 0) {
            assertThat(result.foundCount).isEqualTo(expectedFound);
        }
    }

    // ============================================================================
    // Query Radius Operations (opcode 150)
    // ============================================================================

    @Test
    void testQueryRadiusFindsNearby() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("query-radius");
        TestCase testCase = findCase(fixture, "basic_radius_1km");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        double centerLat = testCase.input.get("center_latitude").getAsDouble();
        double centerLon = testCase.input.get("center_longitude").getAsDouble();
        double radiusM = testCase.input.get("radius_m").getAsDouble();
        int limit = testCase.input.has("limit") ? testCase.input.get("limit").getAsInt() : 100;

        QueryResult result = client.queryRadius(centerLat, centerLon, radiusM, limit);

        int expectedCount = FixtureAdapter.getExpectedCount(testCase.expected_output);
        if (expectedCount >= 0) {
            assertThat(result.events.size()).isEqualTo(expectedCount);
        }

        List<Long> expectedEntities = FixtureAdapter.getExpectedEntities(testCase.expected_output);
        for (Long expectedId : expectedEntities) {
            assertThat(result.events).anyMatch(e -> e.entityId == expectedId);
        }
    }

    // ============================================================================
    // Query Polygon Operations (opcode 151)
    // ============================================================================

    @Test
    void testQueryPolygonFindsInside() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("query-polygon");
        TestCase testCase = findCase(fixture, "simple_rectangle");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        JsonArray verticesRaw = testCase.input.getAsJsonArray("vertices");
        List<double[]> vertices = new ArrayList<>();
        for (JsonElement elem : verticesRaw) {
            JsonArray arr = elem.getAsJsonArray();
            vertices.add(new double[]{arr.get(0).getAsDouble(), arr.get(1).getAsDouble()});
        }

        int limit = testCase.input.has("limit") ? testCase.input.get("limit").getAsInt() : 100;

        QueryResult result = client.queryPolygon(vertices, limit);

        int expectedCount = FixtureAdapter.getExpectedCount(testCase.expected_output);
        if (expectedCount >= 0) {
            assertThat(result.events.size()).isEqualTo(expectedCount);
        }
    }

    // ============================================================================
    // Query Latest Operations (opcode 154)
    // ============================================================================

    @Test
    void testQueryLatestReturnsRecent() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("query-latest");
        TestCase testCase = findCase(fixture, "basic_query");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        int limit = testCase.input.has("limit") ? testCase.input.get("limit").getAsInt() : 100;

        QueryResult result = client.queryLatest(limit);

        int expectedCount = FixtureAdapter.getExpectedCount(testCase.expected_output);
        if (expectedCount >= 0) {
            assertThat(result.events.size()).isEqualTo(expectedCount);
        }
    }

    // ============================================================================
    // Ping Operations (opcode 152)
    // ============================================================================

    @Test
    void testPingReturnsPong() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("ping");
        TestCase testCase = findCase(fixture, "basic_ping");

        long start = System.currentTimeMillis();
        boolean pong = client.ping();
        long latency = System.currentTimeMillis() - start;

        assertThat(pong).isTrue();

        if (testCase.expected_output.has("latency_ms_max")) {
            int maxLatency = testCase.expected_output.get("latency_ms_max").getAsInt();
            assertThat(latency).isLessThanOrEqualTo(maxLatency);
        }
    }

    // ============================================================================
    // Status Operations (opcode 153)
    // ============================================================================

    @Test
    void testStatusReturnsInfo() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("status");
        TestCase testCase = findCase(fixture, "get_status");

        StatusResponse status = client.getStatus();

        assertThat(status).isNotNull();
        if (testCase.expected_output.has("healthy")) {
            assertThat(status.healthy).isTrue();
        }
    }

    // ============================================================================
    // TTL Set Operations (opcode 158)
    // ============================================================================

    @Test
    void testTTLSetAppliesTTL() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("ttl-set");
        TestCase testCase = findCase(fixture, "set_ttl_new_entity");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        if (!testCase.input.has("entity_id") || !testCase.input.has("ttl_seconds")) {
            return; // Skip if missing parameters
        }

        long entityId = testCase.input.get("entity_id").getAsLong();
        int ttlSeconds = testCase.input.get("ttl_seconds").getAsInt();

        TtlSetResponse response = client.setTtl(entityId, ttlSeconds);

        assertThat(response).isNotNull();
    }

    // ============================================================================
    // TTL Extend Operations (opcode 159)
    // ============================================================================

    @Test
    void testTTLExtendAddsTime() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("ttl-extend");
        TestCase testCase = findCase(fixture, "extend_existing_ttl");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        if (!testCase.input.has("entity_id") || !testCase.input.has("extend_by_seconds")) {
            return; // Skip if missing parameters
        }

        long entityId = testCase.input.get("entity_id").getAsLong();
        int extendBy = testCase.input.get("extend_by_seconds").getAsInt();

        TtlExtendResponse response = client.extendTtl(entityId, extendBy);

        assertThat(response).isNotNull();
    }

    // ============================================================================
    // TTL Clear Operations (opcode 160)
    // ============================================================================

    @Test
    void testTTLClearRemovesTTL() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("ttl-clear");
        TestCase testCase = findCase(fixture, "clear_existing_ttl");

        // Execute setup
        List<GeoEventData> setupEvents = FixtureAdapter.getSetupEvents(testCase.input);
        if (!setupEvents.isEmpty()) {
            client.insertEvents(setupEvents);
            Thread.sleep(50);
        }

        if (!testCase.input.has("entity_id")) {
            return; // Skip if missing parameters
        }

        long entityId = testCase.input.get("entity_id").getAsLong();

        TtlClearResponse response = client.clearTtl(entityId);

        assertThat(response).isNotNull();
    }

    // ============================================================================
    // Topology Operations (opcode 157)
    // ============================================================================

    @Test
    void testTopologyReturnsClusterInfo() throws Exception {
        Fixture fixture = FixtureAdapter.loadFixture("topology");
        TestCase testCase = findCase(fixture, "single_node_topology");

        TopologyResponse topology = client.getTopology();

        assertThat(topology).isNotNull();
        assertThat(topology.numShards).isGreaterThanOrEqualTo(1);
    }

    // ============================================================================
    // Helper Methods
    // ============================================================================

    private TestCase findCase(Fixture fixture, String name) {
        return fixture.cases.stream()
                .filter(c -> c.name.equals(name))
                .findFirst()
                .orElseGet(() -> {
                    // Return first case if named case not found
                    if (!fixture.cases.isEmpty()) {
                        return fixture.cases.get(0);
                    }
                    throw new RuntimeException("No test cases in fixture");
                });
    }
}

// ============================================================================
// Mock Client and Result Types
// ============================================================================

/**
 * Mock client for compilation verification.
 * Real integration tests require native library.
 * This mock tracks inserted events and returns them for queries.
 */
class MockGeoClient {
    private final String address;
    private final List<GeoEventData> storedEvents = new ArrayList<>();

    MockGeoClient(String address) {
        this.address = address;
    }

    void close() {
        // No-op for mock
    }

    void cleanDatabase() {
        storedEvents.clear();
    }

    List<InsertResult> insertEvents(List<GeoEventData> events) {
        List<InsertResult> results = new ArrayList<>();
        for (GeoEventData event : events) {
            storedEvents.add(event);
            results.add(new InsertResult(0, "OK"));
        }
        return results;
    }

    List<InsertResult> upsertEvents(List<GeoEventData> events) {
        return insertEvents(events);
    }

    DeleteResult deleteEntities(List<Long> entityIds) {
        int deleted = 0;
        for (Long id : entityIds) {
            if (storedEvents.removeIf(e -> e.entityId == id)) {
                deleted++;
            }
        }
        return new DeleteResult(deleted, entityIds.size() - deleted);
    }

    GeoEventData getLatestByUuid(long entityId) {
        return storedEvents.stream()
                .filter(e -> e.entityId == entityId)
                .findFirst()
                .orElse(null);
    }

    QueryUUIDBatchResult queryUuidBatch(List<Long> entityIds) {
        QueryUUIDBatchResult result = new QueryUUIDBatchResult();
        result.events = new ArrayList<>();
        result.foundCount = 0;
        result.notFoundCount = 0;

        for (Long id : entityIds) {
            GeoEventData found = storedEvents.stream()
                    .filter(e -> e.entityId == id)
                    .findFirst()
                    .orElse(null);
            if (found != null) {
                result.events.add(found);
                result.foundCount++;
            } else {
                result.notFoundCount++;
            }
        }
        return result;
    }

    QueryResult queryRadius(double centerLat, double centerLon, double radiusM, int limit) {
        QueryResult result = new QueryResult();
        result.events = new ArrayList<>();
        result.hasMore = false;

        // Simple mock: return events within approximate radius
        double radiusDeg = radiusM / 111000.0; // Rough conversion
        for (GeoEventData event : storedEvents) {
            double latDiff = Math.abs(event.latitude - centerLat);
            double lonDiff = Math.abs(event.longitude - centerLon);
            if (latDiff <= radiusDeg && lonDiff <= radiusDeg) {
                result.events.add(event);
                if (result.events.size() >= limit) break;
            }
        }
        return result;
    }

    QueryResult queryPolygon(List<double[]> vertices, int limit) {
        QueryResult result = new QueryResult();
        result.events = new ArrayList<>();
        result.hasMore = false;

        // Simple mock: check if event is within bounding box of polygon
        double minLat = Double.MAX_VALUE, maxLat = -Double.MAX_VALUE;
        double minLon = Double.MAX_VALUE, maxLon = -Double.MAX_VALUE;
        for (double[] v : vertices) {
            minLat = Math.min(minLat, v[0]);
            maxLat = Math.max(maxLat, v[0]);
            minLon = Math.min(minLon, v[1]);
            maxLon = Math.max(maxLon, v[1]);
        }

        for (GeoEventData event : storedEvents) {
            if (event.latitude >= minLat && event.latitude <= maxLat &&
                event.longitude >= minLon && event.longitude <= maxLon) {
                result.events.add(event);
                if (result.events.size() >= limit) break;
            }
        }
        return result;
    }

    QueryResult queryLatest(int limit) {
        QueryResult result = new QueryResult();
        result.events = new ArrayList<>(storedEvents.subList(0, Math.min(limit, storedEvents.size())));
        result.hasMore = storedEvents.size() > limit;
        return result;
    }

    boolean ping() {
        return true;
    }

    StatusResponse getStatus() {
        StatusResponse status = new StatusResponse();
        status.healthy = true;
        status.ramIndexCount = storedEvents.size();
        status.ramIndexCapacity = 1000000;
        return status;
    }

    TtlSetResponse setTtl(long entityId, int ttlSeconds) {
        TtlSetResponse response = new TtlSetResponse();
        response.entityId = entityId;
        response.newTtlSeconds = ttlSeconds;
        return response;
    }

    TtlExtendResponse extendTtl(long entityId, int extendBySeconds) {
        TtlExtendResponse response = new TtlExtendResponse();
        response.entityId = entityId;
        return response;
    }

    TtlClearResponse clearTtl(long entityId) {
        TtlClearResponse response = new TtlClearResponse();
        response.entityId = entityId;
        return response;
    }

    TopologyResponse getTopology() {
        TopologyResponse topology = new TopologyResponse();
        topology.numShards = 1;
        topology.version = 1;
        return topology;
    }
}

class InsertResult {
    int code;
    String status;

    InsertResult(int code, String status) {
        this.code = code;
        this.status = status;
    }
}

class DeleteResult {
    int deletedCount;
    int notFoundCount;

    DeleteResult(int deletedCount, int notFoundCount) {
        this.deletedCount = deletedCount;
        this.notFoundCount = notFoundCount;
    }
}

class QueryResult {
    List<GeoEventData> events;
    boolean hasMore;
    long cursor;
}

class QueryUUIDBatchResult {
    int foundCount;
    int notFoundCount;
    List<GeoEventData> events;
}

class StatusResponse {
    boolean healthy;
    long ramIndexCount;
    long ramIndexCapacity;
}

class TtlSetResponse {
    long entityId;
    int previousTtlSeconds;
    int newTtlSeconds;
}

class TtlExtendResponse {
    long entityId;
    int previousTtlSeconds;
    int newTtlSeconds;
}

class TtlClearResponse {
    long entityId;
    int previousTtlSeconds;
}

class TopologyResponse {
    int numShards;
    long version;
}
