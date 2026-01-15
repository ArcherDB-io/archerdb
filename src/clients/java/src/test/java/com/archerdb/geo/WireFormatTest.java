package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.stream.Stream;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.Arguments;

/**
 * Wire format compatibility tests.
 *
 * Loads canonical test data from wire-format-test-cases.json and verifies the Java SDK produces
 * compatible output with other language SDKs.
 */
class WireFormatTest {

    private static JsonObject testData;

    @BeforeAll
    static void loadTestData() throws IOException {
        Path testDataPath = findTestDataPath();
        String json = Files.readString(testDataPath);
        testData = new Gson().fromJson(json, JsonObject.class);
    }

    private static Path findTestDataPath() {
        // Test runs from src/clients/java/, so ../test-data is the correct relative path
        Path[] candidates = {Paths.get("../test-data/wire-format-test-cases.json"),
                Paths.get("../../test-data/wire-format-test-cases.json"),
                Paths.get("src/clients/test-data/wire-format-test-cases.json"),
                Paths.get("test-data/wire-format-test-cases.json"),};

        for (Path path : candidates) {
            if (Files.exists(path)) {
                return path;
            }
        }

        String projectRoot = System.getProperty("user.dir");
        for (Path path : candidates) {
            Path fullPath = Paths.get(projectRoot).resolve(path);
            if (Files.exists(fullPath)) {
                return fullPath;
            }
        }

        throw new RuntimeException("Could not find wire-format-test-cases.json");
    }

    // ========================================================================
    // Constants Tests
    // ========================================================================

    @Test
    @DisplayName("Wire format constants match canonical values")
    void testConstants() {
        JsonObject constants = testData.getAsJsonObject("constants");

        assertEquals(constants.get("LAT_MAX").getAsDouble(), CoordinateUtils.LAT_MAX, "LAT_MAX");
        assertEquals(constants.get("LON_MAX").getAsDouble(), CoordinateUtils.LON_MAX, "LON_MAX");
        assertEquals(constants.get("NANODEGREES_PER_DEGREE").getAsLong(),
                CoordinateUtils.NANODEGREES_PER_DEGREE, "NANODEGREES_PER_DEGREE");
        assertEquals(constants.get("MM_PER_METER").getAsInt(), CoordinateUtils.MM_PER_METER,
                "MM_PER_METER");
        assertEquals(constants.get("CENTIDEGREES_PER_DEGREE").getAsInt(),
                CoordinateUtils.CENTIDEGREES_PER_DEGREE, "CENTIDEGREES_PER_DEGREE");
        assertEquals(constants.get("BATCH_SIZE_MAX").getAsInt(), CoordinateUtils.BATCH_SIZE_MAX,
                "BATCH_SIZE_MAX");
        assertEquals(constants.get("QUERY_LIMIT_MAX").getAsInt(), CoordinateUtils.QUERY_LIMIT_MAX,
                "QUERY_LIMIT_MAX");
        assertEquals(constants.get("POLYGON_VERTICES_MAX").getAsInt(),
                CoordinateUtils.POLYGON_VERTICES_MAX, "POLYGON_VERTICES_MAX");
    }

    // ========================================================================
    // GeoEvent Flags Tests
    // ========================================================================

    @Test
    @DisplayName("Wire format GeoEvent flags match canonical values")
    void testGeoEventFlags() {
        JsonObject flags = testData.getAsJsonObject("geo_event_flags");

        assertEquals(flags.get("NONE").getAsInt(), GeoEventFlags.NONE.getValue(), "NONE");
        assertEquals(flags.get("LINKED").getAsInt(), GeoEventFlags.LINKED.getValue(), "LINKED");
        assertEquals(flags.get("IMPORTED").getAsInt(), GeoEventFlags.IMPORTED.getValue(),
                "IMPORTED");
        assertEquals(flags.get("STATIONARY").getAsInt(), GeoEventFlags.STATIONARY.getValue(),
                "STATIONARY");
        assertEquals(flags.get("LOW_ACCURACY").getAsInt(), GeoEventFlags.LOW_ACCURACY.getValue(),
                "LOW_ACCURACY");
        assertEquals(flags.get("OFFLINE").getAsInt(), GeoEventFlags.OFFLINE.getValue(), "OFFLINE");
        assertEquals(flags.get("DELETED").getAsInt(), GeoEventFlags.DELETED.getValue(), "DELETED");
    }

    // ========================================================================
    // Result Codes Tests
    // ========================================================================

    @Test
    @DisplayName("Wire format insert result codes match canonical values")
    void testInsertResultCodes() {
        JsonObject codes = testData.getAsJsonObject("insert_result_codes");

        assertEquals(codes.get("OK").getAsInt(), InsertGeoEventResult.OK.getCode(), "OK");
        assertEquals(codes.get("INVALID_COORDINATES").getAsInt(),
                InsertGeoEventResult.INVALID_COORDINATES.getCode(), "INVALID_COORDINATES");
        assertEquals(codes.get("EXISTS").getAsInt(), InsertGeoEventResult.EXISTS.getCode(),
                "EXISTS");
        assertEquals(codes.get("LINKED_EVENT_FAILED").getAsInt(),
                InsertGeoEventResult.LINKED_EVENT_FAILED.getCode(), "LINKED_EVENT_FAILED");
    }

    // ========================================================================
    // Coordinate Conversion Tests
    // ========================================================================

    static Stream<Arguments> coordinateConversionsProvider() {
        JsonArray conversions = testData.getAsJsonArray("coordinate_conversions");
        return conversions.asList().stream().map(e -> {
            JsonObject obj = e.getAsJsonObject();
            return Arguments.of(obj.get("description").getAsString(),
                    obj.get("degrees").getAsDouble(), obj.get("expected_nanodegrees").getAsLong());
        });
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("coordinateConversionsProvider")
    @DisplayName("Wire format coordinate conversions")
    void testCoordinateConversions(String description, double degrees, long expectedNano) {
        long result = CoordinateUtils.degreesToNano(degrees);
        assertEquals(expectedNano, result, description);
    }

    @ParameterizedTest(name = "Roundtrip: {0}")
    @MethodSource("coordinateConversionsProvider")
    @DisplayName("Wire format coordinate roundtrip")
    void testCoordinateRoundtrip(String description, double degrees, long expectedNano) {
        double back = CoordinateUtils.nanoToDegrees(expectedNano);
        long roundTrip = CoordinateUtils.degreesToNano(back);
        assertEquals(expectedNano, roundTrip, "Roundtrip: " + description);
    }

    // ========================================================================
    // Distance Conversion Tests
    // ========================================================================

    static Stream<Arguments> distanceConversionsProvider() {
        JsonArray conversions = testData.getAsJsonArray("distance_conversions");
        return conversions.asList().stream().map(e -> {
            JsonObject obj = e.getAsJsonObject();
            return Arguments.of(obj.get("description").getAsString(),
                    obj.get("meters").getAsDouble(), obj.get("expected_mm").getAsInt());
        });
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("distanceConversionsProvider")
    @DisplayName("Wire format distance conversions")
    void testDistanceConversions(String description, double meters, int expectedMm) {
        int result = CoordinateUtils.metersToMm(meters);
        assertEquals(expectedMm, result, description);
    }

    // ========================================================================
    // Heading Conversion Tests
    // ========================================================================

    static Stream<Arguments> headingConversionsProvider() {
        JsonArray conversions = testData.getAsJsonArray("heading_conversions");
        return conversions.asList().stream().map(e -> {
            JsonObject obj = e.getAsJsonObject();
            return Arguments.of(obj.get("description").getAsString(),
                    obj.get("degrees").getAsDouble(), obj.get("expected_centidegrees").getAsInt());
        });
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("headingConversionsProvider")
    @DisplayName("Wire format heading conversions")
    void testHeadingConversions(String description, double degrees, int expectedCdeg) {
        short result = CoordinateUtils.headingToCentidegrees(degrees);
        assertEquals((short) expectedCdeg, result, description);
    }

    // ========================================================================
    // GeoEvent Creation Tests
    // ========================================================================

    static Stream<Arguments> geoEventsProvider() {
        JsonArray events = testData.getAsJsonArray("geo_events");
        return events.asList().stream().map(e -> {
            JsonObject obj = e.getAsJsonObject();
            return Arguments.of(obj.get("description").getAsString(), obj.getAsJsonObject("input"),
                    obj.getAsJsonObject("expected"));
        });
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("geoEventsProvider")
    @DisplayName("Wire format GeoEvent creation")
    void testGeoEventCreation(String description, JsonObject input, JsonObject expected) {
        GeoEvent.Builder builder = new GeoEvent.Builder()
                .setEntityId(UInt128.fromLong(input.get("entity_id").getAsLong()))
                .setLatitude(input.get("latitude").getAsDouble())
                .setLongitude(input.get("longitude").getAsDouble());

        if (input.has("correlation_id") && input.get("correlation_id").getAsLong() != 0) {
            builder.setCorrelationId(UInt128.fromLong(input.get("correlation_id").getAsLong()));
        }
        if (input.has("user_data") && input.get("user_data").getAsLong() != 0) {
            builder.setUserData(UInt128.fromLong(input.get("user_data").getAsLong()));
        }
        if (input.has("group_id") && input.get("group_id").getAsLong() != 0) {
            builder.setGroupId(input.get("group_id").getAsLong());
        }
        if (input.has("altitude_m") && input.get("altitude_m").getAsDouble() != 0) {
            builder.setAltitude(input.get("altitude_m").getAsDouble());
        }
        if (input.has("velocity_mps") && input.get("velocity_mps").getAsDouble() != 0) {
            builder.setVelocity(input.get("velocity_mps").getAsDouble());
        }
        if (input.has("ttl_seconds") && input.get("ttl_seconds").getAsInt() != 0) {
            builder.setTtlSeconds(input.get("ttl_seconds").getAsInt());
        }
        if (input.has("accuracy_m") && input.get("accuracy_m").getAsDouble() != 0) {
            builder.setAccuracy(input.get("accuracy_m").getAsDouble());
        }
        if (input.has("heading") && input.get("heading").getAsDouble() != 0) {
            builder.setHeading(input.get("heading").getAsDouble());
        }
        if (input.has("flags") && input.get("flags").getAsInt() != 0) {
            builder.setFlags((short) input.get("flags").getAsInt());
        }

        GeoEvent event = builder.build();

        // Verify fields
        assertEquals(expected.get("entity_id").getAsLong(), event.getEntityId().getLo(),
                "entity_id");
        assertEquals(expected.get("lat_nano").getAsLong(), event.getLatNano(), "lat_nano");
        assertEquals(expected.get("lon_nano").getAsLong(), event.getLonNano(), "lon_nano");
        // ID should be 0 before prepare
        assertEquals(0L, event.getId().getLo(), "id should be 0 before prepare");
        assertEquals(0L, event.getId().getHi(), "id high should be 0 before prepare");
        // Timestamp should be 0 (server-assigned)
        assertEquals(expected.get("timestamp").getAsLong(), event.getTimestamp(), "timestamp");
        assertEquals(expected.get("correlation_id").getAsLong(), event.getCorrelationId().getLo(),
                "correlation_id");
        assertEquals(expected.get("user_data").getAsLong(), event.getUserData().getLo(),
                "user_data");
        assertEquals(expected.get("group_id").getAsLong(), event.getGroupId(), "group_id");
        assertEquals(expected.get("altitude_mm").getAsInt(), event.getAltitudeMm(), "altitude_mm");
        assertEquals(expected.get("velocity_mms").getAsInt(), event.getVelocityMms(),
                "velocity_mms");
        assertEquals(expected.get("ttl_seconds").getAsInt(), event.getTtlSeconds(), "ttl_seconds");
        assertEquals(expected.get("accuracy_mm").getAsInt(), event.getAccuracyMm(), "accuracy_mm");
        assertEquals(expected.get("heading_cdeg").getAsInt(), (int) event.getHeadingCdeg(),
                "heading_cdeg");
        assertEquals(expected.get("flags").getAsInt(), (int) event.getFlags(), "flags");
    }

    // ========================================================================
    // Validation Tests
    // ========================================================================

    @Test
    @DisplayName("Invalid latitudes are rejected")
    void testInvalidLatitudes() {
        JsonArray invalids =
                testData.getAsJsonObject("validation_cases").getAsJsonArray("invalid_latitudes");
        for (var elem : invalids) {
            double lat = elem.getAsDouble();
            assertFalse(CoordinateUtils.isValidLatitude(lat),
                    "Latitude " + lat + " should be invalid");
        }
    }

    @Test
    @DisplayName("Invalid longitudes are rejected")
    void testInvalidLongitudes() {
        JsonArray invalids =
                testData.getAsJsonObject("validation_cases").getAsJsonArray("invalid_longitudes");
        for (var elem : invalids) {
            double lon = elem.getAsDouble();
            assertFalse(CoordinateUtils.isValidLongitude(lon),
                    "Longitude " + lon + " should be invalid");
        }
    }

    @Test
    @DisplayName("Valid boundary latitudes are accepted")
    void testValidBoundaryLatitudes() {
        JsonArray valids = testData.getAsJsonObject("validation_cases")
                .getAsJsonArray("valid_boundary_latitudes");
        for (var elem : valids) {
            double lat = elem.getAsDouble();
            assertTrue(CoordinateUtils.isValidLatitude(lat),
                    "Latitude " + lat + " should be valid");
        }
    }

    @Test
    @DisplayName("Valid boundary longitudes are accepted")
    void testValidBoundaryLongitudes() {
        JsonArray valids = testData.getAsJsonObject("validation_cases")
                .getAsJsonArray("valid_boundary_longitudes");
        for (var elem : valids) {
            double lon = elem.getAsDouble();
            assertTrue(CoordinateUtils.isValidLongitude(lon),
                    "Longitude " + lon + " should be valid");
        }
    }
}
