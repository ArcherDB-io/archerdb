package com.archerdb.sdktests;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.io.FileReader;
import java.io.IOException;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;

/**
 * Adapter for loading and converting JSON test fixtures to SDK types.
 * Fixtures are loaded from test_infrastructure/fixtures/v1/{operation}.json
 */
public class FixtureAdapter {
    private static final Gson gson = new Gson();

    /**
     * Loads a fixture file by operation name.
     *
     * @param operation Operation name (e.g., "insert", "query-radius")
     * @return Fixture object containing test cases
     * @throws IOException If fixture file cannot be read
     */
    public static Fixture loadFixture(String operation) throws IOException {
        Path path = Path.of("..", "..", "..", "test_infrastructure", "fixtures", "v1", operation + ".json");
        try (FileReader reader = new FileReader(path.toFile())) {
            return gson.fromJson(reader, Fixture.class);
        }
    }

    /**
     * Generates a deterministic entity ID from a test name.
     *
     * @param testName Test name for seed
     * @return Generated entity ID as long
     */
    public static long generateEntityId(String testName) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(testName.getBytes());
            long result = 0;
            for (int i = 0; i < 8; i++) {
                result = (result << 8) | (hash[i] & 0xFF);
            }
            return result;
        } catch (NoSuchAlgorithmException e) {
            // Fallback to simple hash
            return testName.hashCode() & 0xFFFFFFFFL;
        }
    }

    /**
     * Converts fixture JSON events to SDK GeoEvent list.
     *
     * @param events JSON array of event objects
     * @return List of GeoEventData objects
     */
    public static List<GeoEventData> convertFixtureEvents(JsonArray events) {
        List<GeoEventData> result = new ArrayList<>();
        for (JsonElement elem : events) {
            if (elem.isJsonObject()) {
                result.add(mapToGeoEvent(elem.getAsJsonObject()));
            }
        }
        return result;
    }

    /**
     * Converts a JSON object to GeoEventData.
     */
    public static GeoEventData mapToGeoEvent(JsonObject obj) {
        GeoEventData event = new GeoEventData();

        // Entity ID (required)
        if (obj.has("entity_id")) {
            event.entityId = obj.get("entity_id").getAsLong();
        }

        // Coordinates (required)
        if (obj.has("latitude")) {
            event.latitude = obj.get("latitude").getAsDouble();
        }
        if (obj.has("longitude")) {
            event.longitude = obj.get("longitude").getAsDouble();
        }

        // Optional fields
        if (obj.has("correlation_id")) {
            event.correlationId = obj.get("correlation_id").getAsLong();
        }
        if (obj.has("user_data")) {
            event.userData = obj.get("user_data").getAsLong();
        }
        if (obj.has("group_id")) {
            event.groupId = obj.get("group_id").getAsLong();
        }
        if (obj.has("altitude_m")) {
            event.altitudeM = obj.get("altitude_m").getAsDouble();
        }
        if (obj.has("velocity_mps")) {
            event.velocityMps = obj.get("velocity_mps").getAsDouble();
        }
        if (obj.has("ttl_seconds")) {
            event.ttlSeconds = obj.get("ttl_seconds").getAsInt();
        }
        if (obj.has("accuracy_m")) {
            event.accuracyM = obj.get("accuracy_m").getAsDouble();
        }
        if (obj.has("heading")) {
            event.heading = obj.get("heading").getAsDouble();
        }
        if (obj.has("flags")) {
            event.flags = obj.get("flags").getAsInt();
        }

        return event;
    }

    /**
     * Converts fixture entity_ids to list of longs.
     */
    public static List<Long> convertEntityIds(JsonArray entityIds) {
        List<Long> ids = new ArrayList<>();
        for (JsonElement elem : entityIds) {
            ids.add(elem.getAsLong());
        }
        return ids;
    }

    /**
     * Extracts setup events from test case input.
     *
     * @param input Test case input object
     * @return List of setup events, or empty list if none
     */
    public static List<GeoEventData> getSetupEvents(JsonObject input) {
        if (!input.has("setup")) {
            return new ArrayList<>();
        }

        JsonObject setup = input.getAsJsonObject("setup");
        if (setup.has("insert_first")) {
            JsonElement insertFirst = setup.get("insert_first");
            if (insertFirst.isJsonObject()) {
                // Single event
                List<GeoEventData> events = new ArrayList<>();
                events.add(mapToGeoEvent(insertFirst.getAsJsonObject()));
                return events;
            } else if (insertFirst.isJsonArray()) {
                // Array of events
                return convertFixtureEvents(insertFirst.getAsJsonArray());
            }
        }

        return new ArrayList<>();
    }

    /**
     * Extracts expected result code from expected_output.
     */
    public static int getExpectedResultCode(JsonObject expected) {
        if (expected.has("result_code")) {
            return expected.get("result_code").getAsInt();
        }
        return 0;
    }

    /**
     * Extracts expected count from expected_output.
     */
    public static int getExpectedCount(JsonObject expected) {
        if (expected.has("count")) {
            return expected.get("count").getAsInt();
        }
        if (expected.has("count_in_range")) {
            return expected.get("count_in_range").getAsInt();
        }
        if (expected.has("results_count")) {
            return expected.get("results_count").getAsInt();
        }
        return -1;
    }

    /**
     * Extracts expected entity IDs from events_contain.
     */
    public static List<Long> getExpectedEntities(JsonObject expected) {
        List<Long> ids = new ArrayList<>();
        if (expected.has("events_contain")) {
            JsonArray arr = expected.getAsJsonArray("events_contain");
            for (JsonElement elem : arr) {
                ids.add(elem.getAsLong());
            }
        }
        return ids;
    }
}

/**
 * Data class representing a fixture file structure.
 */
class Fixture {
    String operation;
    String version;
    String description;
    List<TestCase> cases;
}

/**
 * Data class representing a single test case.
 */
class TestCase {
    String name;
    String description;
    List<String> tags;
    JsonObject input;
    JsonObject expected_output;
    String expected_error;
}

/**
 * Data class for GeoEvent data from fixtures.
 * Used as intermediate representation before converting to SDK GeoEvent.
 */
class GeoEventData {
    long entityId;
    double latitude;
    double longitude;
    long correlationId;
    long userData;
    long groupId;
    double altitudeM;
    double velocityMps;
    int ttlSeconds;
    double accuracyM;
    double heading;
    int flags;
}
