package com.archerdb.sdktests;

import com.archerdb.geo.GeoEvent;
import com.archerdb.geo.UInt128;
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
    public static List<GeoEvent> convertFixtureEvents(JsonArray events) {
        List<GeoEvent> result = new ArrayList<>();
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
    public static GeoEvent mapToGeoEvent(JsonObject obj) {
        GeoEvent.Builder builder = new GeoEvent.Builder();

        // Entity ID (required)
        if (obj.has("entity_id")) {
            builder.setEntityId(UInt128.of(obj.get("entity_id").getAsLong()));
        }

        // Coordinates (required)
        if (obj.has("latitude")) {
            builder.setLatitude(obj.get("latitude").getAsDouble());
        }
        if (obj.has("longitude")) {
            builder.setLongitude(obj.get("longitude").getAsDouble());
        }

        // Optional fields
        if (obj.has("correlation_id")) {
            builder.setCorrelationId(UInt128.of(obj.get("correlation_id").getAsLong()));
        }
        if (obj.has("user_data")) {
            builder.setUserData(UInt128.of(obj.get("user_data").getAsLong()));
        }
        if (obj.has("group_id")) {
            builder.setGroupId(obj.get("group_id").getAsLong());
        }
        if (obj.has("altitude_m")) {
            builder.setAltitude(obj.get("altitude_m").getAsDouble());
        }
        if (obj.has("velocity_mps")) {
            builder.setVelocity(obj.get("velocity_mps").getAsDouble());
        }
        if (obj.has("ttl_seconds")) {
            builder.setTtlSeconds(obj.get("ttl_seconds").getAsInt());
        }
        if (obj.has("accuracy_m")) {
            builder.setAccuracy(obj.get("accuracy_m").getAsDouble());
        }
        if (obj.has("heading")) {
            builder.setHeading(obj.get("heading").getAsDouble());
        }
        if (obj.has("flags")) {
            builder.setFlags((short) obj.get("flags").getAsInt());
        }
        if (obj.has("timestamp")) {
            long timestampNs = obj.get("timestamp").getAsLong() * 1_000_000_000L;
            builder.setTimestamp(timestampNs);
        }

        return builder.build();
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
    public static List<GeoEvent> getSetupEvents(JsonObject input) {
        if (!input.has("setup")) {
            return new ArrayList<>();
        }

        JsonObject setup = input.getAsJsonObject("setup");
        if (setup.has("insert_first")) {
            JsonElement insertFirst = setup.get("insert_first");
            if (insertFirst.isJsonObject()) {
                // Single event
                List<GeoEvent> events = new ArrayList<>();
                events.add(mapToGeoEvent(insertFirst.getAsJsonObject()));
                return events;
            } else if (insertFirst.isJsonArray()) {
                // Array of events
                return convertFixtureEvents(insertFirst.getAsJsonArray());
            }
        }

        if (setup.has("insert_first_range")) {
            JsonObject range = setup.getAsJsonObject("insert_first_range");
            long startId = range.get("start_entity_id").getAsLong();
            int count = range.get("count").getAsInt();
            double baseLat = range.get("base_latitude").getAsDouble();
            double baseLon = range.get("base_longitude").getAsDouble();
            double spreadM = range.has("spread_m") ? range.get("spread_m").getAsDouble() : 100;

            List<GeoEvent> events = new ArrayList<>();
            double spreadDeg = spreadM / 111000.0;
            int cols = Math.min(10, Math.max(count, 1));
            int rows = count > 0 ? (int) Math.ceil((double) count / cols) : 1;
            for (int i = 0; i < count; i++) {
                int row = i / cols;
                int col = i % cols;
                double rowFrac = rows <= 1 ? 0.5 : (double) row / (rows - 1);
                double colFrac = cols <= 1 ? 0.5 : (double) col / (cols - 1);
                double latOffset = (rowFrac - 0.5) * spreadDeg;
                double lonOffset = (colFrac - 0.5) * spreadDeg;
                GeoEvent event = new GeoEvent.Builder()
                        .setEntityId(UInt128.of(startId + i))
                        .setLatitude(baseLat + latOffset)
                        .setLongitude(baseLon + lonOffset)
                        .build();
                events.add(event);
            }
            return events;
        }

        if (setup.has("insert_hotspot")) {
            JsonObject hotspot = setup.getAsJsonObject("insert_hotspot");
            double centerLat = hotspot.get("center_latitude").getAsDouble();
            double centerLon = hotspot.get("center_longitude").getAsDouble();
            int count = hotspot.get("count").getAsInt();
            double concentration = hotspot.has("concentration_percentage")
                    ? hotspot.get("concentration_percentage").getAsDouble() : 100.0;
            long startId = hotspot.has("start_entity_id") ? hotspot.get("start_entity_id").getAsLong() : 1L;

            int hotspotCount = (int) Math.round(count * (concentration / 100.0));
            List<GeoEvent> events = new ArrayList<>();
            for (int i = 0; i < count; i++) {
                boolean inHotspot = i < hotspotCount;
                int total = Math.max(inHotspot ? hotspotCount : (count - hotspotCount), 1);
                int idx = inHotspot ? i : (i - hotspotCount);
                double spreadDeg = inHotspot ? 0.005 : 0.05;
                int cols = Math.min(10, total);
                int rows = total > 0 ? (int) Math.ceil((double) total / cols) : 1;
                int row = idx / cols;
                int col = idx % cols;
                double rowFrac = rows <= 1 ? 0.5 : (double) row / (rows - 1);
                double colFrac = cols <= 1 ? 0.5 : (double) col / (cols - 1);
                double lat = centerLat + (rowFrac - 0.5) * spreadDeg;
                double lon = centerLon + (colFrac - 0.5) * spreadDeg;
                GeoEvent event = new GeoEvent.Builder()
                        .setEntityId(UInt128.of(startId + i))
                        .setLatitude(lat)
                        .setLongitude(lon)
                        .build();
                events.add(event);
            }
            return events;
        }

        if (setup.has("insert_with_timestamps")) {
            JsonArray events = setup.getAsJsonArray("insert_with_timestamps");
            return convertFixtureEvents(events);
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

    /**
     * Extracts expected excluded entity IDs from events_exclude.
     */
    public static List<Long> getExpectedExcludedEntities(JsonObject expected) {
        List<Long> ids = new ArrayList<>();
        if (expected.has("events_exclude")) {
            JsonArray arr = expected.getAsJsonArray("events_exclude");
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
