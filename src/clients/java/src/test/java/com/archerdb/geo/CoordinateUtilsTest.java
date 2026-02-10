package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * Unit tests for CoordinateUtils.
 */
class CoordinateUtilsTest {

    // ========================================================================
    // Constants Tests
    // ========================================================================

    @Test
    void testConstants() {
        assertEquals(90.0, CoordinateUtils.LAT_MAX);
        assertEquals(180.0, CoordinateUtils.LON_MAX);
        assertEquals(1_000_000_000L, CoordinateUtils.NANODEGREES_PER_DEGREE);
        assertEquals(1000, CoordinateUtils.MM_PER_METER);
        assertEquals(100, CoordinateUtils.CENTIDEGREES_PER_DEGREE);
        assertEquals(10_000, CoordinateUtils.BATCH_SIZE_MAX);
        assertEquals(81_000, CoordinateUtils.QUERY_LIMIT_MAX);
        assertEquals(10_000, CoordinateUtils.POLYGON_VERTICES_MAX);
    }

    // ========================================================================
    // Coordinate Conversion Tests
    // ========================================================================

    @ParameterizedTest
    @CsvSource({"37.7749, 37774900000", "-122.4194, -122419400000", "90.0, 90000000000",
            "-90.0, -90000000000", "180.0, 180000000000", "-180.0, -180000000000", "0.0, 0"})
    void testDegreesToNano(double degrees, long expectedNano) {
        assertEquals(expectedNano, CoordinateUtils.degreesToNano(degrees));
    }

    @ParameterizedTest
    @CsvSource({"37774900000, 37.7749", "-122419400000, -122.4194", "90000000000, 90.0",
            "-90000000000, -90.0", "0, 0.0"})
    void testNanoToDegrees(long nano, double expectedDegrees) {
        assertEquals(expectedDegrees, CoordinateUtils.nanoToDegrees(nano), 0.0001);
    }

    @Test
    void testDegreesNanoRoundTrip() {
        double[] testValues = {0, 37.7749, -122.4194, 90, -90, 180, -180, 45.5, -45.5};
        for (double v : testValues) {
            long nano = CoordinateUtils.degreesToNano(v);
            double back = CoordinateUtils.nanoToDegrees(nano);
            assertEquals(v, back, 0.0001, "Round trip failed for " + v);
        }
    }

    @ParameterizedTest
    @CsvSource({"1.0, 1000", "5.5, 5500", "0.0, 0", "1000.0, 1000000"})
    void testMetersToMm(double meters, int expectedMm) {
        assertEquals(expectedMm, CoordinateUtils.metersToMm(meters));
    }

    @ParameterizedTest
    @CsvSource({"1000, 1.0", "5500, 5.5", "0, 0.0"})
    void testMmToMeters(int mm, double expectedMeters) {
        assertEquals(expectedMeters, CoordinateUtils.mmToMeters(mm), 0.0001);
    }

    @ParameterizedTest
    @CsvSource({"0, 0", // North
            "90, 9000", // East
            "180, 18000", // South
            "270, 27000" // West
    // Note: 360 degrees maps to 36000 which exceeds short max (32767)
    // Wire format allows 0-36000 centidegrees; Java short APIs cannot represent 36000.
    })
    void testHeadingToCentidegrees(double degrees, short expectedCdeg) {
        assertEquals(expectedCdeg, CoordinateUtils.headingToCentidegrees(degrees));
    }

    @ParameterizedTest
    @CsvSource({"0, 0", "9000, 90", "18000, 180", "27000, 270"})
    void testCentidegreesToHeading(short cdeg, double expectedDegrees) {
        assertEquals(expectedDegrees, CoordinateUtils.centidegreesToHeading(cdeg), 0.0001);
    }

    // ========================================================================
    // Coordinate Validation Tests
    // ========================================================================

    @ParameterizedTest
    @ValueSource(doubles = {0, 90, -90, 45.5, -45.5, 89.999999})
    void testValidLatitudes(double lat) {
        assertTrue(CoordinateUtils.isValidLatitude(lat));
    }

    @ParameterizedTest
    @ValueSource(doubles = {90.1, -90.1, 180, -180, 1000})
    void testInvalidLatitudes(double lat) {
        assertFalse(CoordinateUtils.isValidLatitude(lat));
    }

    @ParameterizedTest
    @ValueSource(doubles = {0, 180, -180, 90, -90, 179.999999})
    void testValidLongitudes(double lon) {
        assertTrue(CoordinateUtils.isValidLongitude(lon));
    }

    @ParameterizedTest
    @ValueSource(doubles = {180.1, -180.1, 360, -360})
    void testInvalidLongitudes(double lon) {
        assertFalse(CoordinateUtils.isValidLongitude(lon));
    }

    @ParameterizedTest
    @ValueSource(longs = {0, 90_000_000_000L, -90_000_000_000L, 37_774_900_000L})
    void testValidLatitudesNano(long latNano) {
        assertTrue(CoordinateUtils.isValidLatitudeNano(latNano));
    }

    @ParameterizedTest
    @ValueSource(longs = {91_000_000_000L, -91_000_000_000L, 180_000_000_000L})
    void testInvalidLatitudesNano(long latNano) {
        assertFalse(CoordinateUtils.isValidLatitudeNano(latNano));
    }

    @ParameterizedTest
    @ValueSource(longs = {0, 180_000_000_000L, -180_000_000_000L, 122_419_400_000L})
    void testValidLongitudesNano(long lonNano) {
        assertTrue(CoordinateUtils.isValidLongitudeNano(lonNano));
    }

    @ParameterizedTest
    @ValueSource(longs = {181_000_000_000L, -181_000_000_000L})
    void testInvalidLongitudesNano(long lonNano) {
        assertFalse(CoordinateUtils.isValidLongitudeNano(lonNano));
    }

    @Test
    void testValidateCoordinates_valid() {
        assertDoesNotThrow(() -> CoordinateUtils.validateCoordinates(37.7749, -122.4194));
        assertDoesNotThrow(() -> CoordinateUtils.validateCoordinates(0, 0));
        assertDoesNotThrow(() -> CoordinateUtils.validateCoordinates(90, 180));
        assertDoesNotThrow(() -> CoordinateUtils.validateCoordinates(-90, -180));
    }

    @Test
    void testValidateCoordinates_invalidLatitude() {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
                () -> CoordinateUtils.validateCoordinates(91, 0));
        assertTrue(ex.getMessage().contains("Invalid latitude"));
    }

    @Test
    void testValidateCoordinates_invalidLongitude() {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
                () -> CoordinateUtils.validateCoordinates(0, 181));
        assertTrue(ex.getMessage().contains("Invalid longitude"));
    }
}
