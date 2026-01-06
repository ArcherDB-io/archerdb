package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

/**
 * Unit tests for GeoEvent and GeoEvent.Builder.
 */
class GeoEventTest {

    // ========================================================================
    // Builder Tests
    // ========================================================================

    @Test
    void testBuilderBasic() {
        UInt128 entityId = UInt128.random();

        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(entityId)
                .setLatitude(37.7749)
                .setLongitude(-122.4194)
                .build();

        assertEquals(entityId, event.getEntityId());
        assertEquals(37_774_900_000L, event.getLatNano());
        assertEquals(-122_419_400_000L, event.getLonNano());
        assertEquals(37.7749, event.getLatitude(), 0.0001);
        assertEquals(-122.4194, event.getLongitude(), 0.0001);
    }

    @Test
    void testBuilderWithAllFields() {
        UInt128 entityId = UInt128.random();
        UInt128 correlationId = UInt128.random();
        UInt128 userData = UInt128.random();

        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(entityId)
                .setCorrelationId(correlationId)
                .setUserData(userData)
                .setLatitude(37.7749)
                .setLongitude(-122.4194)
                .setGroupId(100L)
                .setAltitudeMm(50_000)      // 50 meters
                .setVelocityMmps(15_500)    // 15.5 m/s
                .setTtlSeconds(86400)
                .setAccuracyMm(5_000)       // 5 meters
                .setHeadingCentideg((short) 9000)  // 90 degrees (East)
                .setStatus((short) 1)
                .setEventType((byte) 2)
                .build();

        assertEquals(entityId, event.getEntityId());
        assertEquals(correlationId, event.getCorrelationId());
        assertEquals(userData, event.getUserData());
        assertEquals(100L, event.getGroupId());
        assertEquals(50_000, event.getAltitudeMm());
        assertEquals(15_500, event.getVelocityMmps());
        assertEquals(86400, event.getTtlSeconds());
        assertEquals(5_000, event.getAccuracyMm());
        assertEquals(9000, event.getHeadingCentideg());
        assertEquals(1, event.getStatus());
        assertEquals(2, event.getEventType());
    }

    @Test
    void testBuilderWithFriendlyUnits() {
        UInt128 entityId = UInt128.random();

        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(entityId)
                .setLatitude(40.7128)
                .setLongitude(-74.0060)
                .setAltitudeMeters(100.5)
                .setVelocityMps(30.5)
                .setAccuracyMeters(10.0)
                .setHeadingDegrees(180.0)
                .build();

        assertEquals(100_500, event.getAltitudeMm());
        assertEquals(30_500, event.getVelocityMmps());
        assertEquals(10_000, event.getAccuracyMm());
        assertEquals(18000, event.getHeadingCentideg());
    }

    @Test
    void testBuilderComputesCompositeId() {
        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(37.7749)
                .setLongitude(-122.4194)
                .build();

        // ID should be computed (not zero)
        assertNotEquals(UInt128.ZERO, event.getId());
    }

    @Test
    void testBuilderInvalidLatitude() {
        GeoEvent.Builder builder = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLongitude(0);

        IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> builder.setLatitude(91)
        );
        assertTrue(ex.getMessage().contains("latitude"));
    }

    @Test
    void testBuilderInvalidLongitude() {
        GeoEvent.Builder builder = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0);

        IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> builder.setLongitude(181)
        );
        assertTrue(ex.getMessage().contains("longitude"));
    }

    @Test
    void testBuilderInvalidHeading() {
        GeoEvent.Builder builder = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(0);

        IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> builder.setHeadingDegrees(361)
        );
        assertTrue(ex.getMessage().contains("heading"));
    }

    // ========================================================================
    // GeoEvent Method Tests
    // ========================================================================

    @Test
    void testGetLatitudeLongitude() {
        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(37.7749)
                .setLongitude(-122.4194)
                .build();

        assertEquals(37.7749, event.getLatitude(), 0.0001);
        assertEquals(-122.4194, event.getLongitude(), 0.0001);
    }

    @Test
    void testGetAltitudeMeters() {
        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(0)
                .setAltitudeMm(50_500)
                .build();

        assertEquals(50.5, event.getAltitudeMeters(), 0.0001);
    }

    @Test
    void testGetVelocityMps() {
        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(0)
                .setVelocityMmps(15_500)
                .build();

        assertEquals(15.5, event.getVelocityMps(), 0.0001);
    }

    @Test
    void testGetAccuracyMeters() {
        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(0)
                .setAccuracyMm(5_500)
                .build();

        assertEquals(5.5, event.getAccuracyMeters(), 0.0001);
    }

    @Test
    void testGetHeadingDegrees() {
        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(0)
                .setHeadingCentideg((short) 9000)
                .build();

        assertEquals(90.0, event.getHeadingDegrees(), 0.0001);
    }

    // ========================================================================
    // Edge Case Tests
    // ========================================================================

    @Test
    void testBoundaryLatitudes() {
        // Maximum latitude (North Pole)
        GeoEvent eventNorth = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(90.0)
                .setLongitude(0)
                .build();
        assertEquals(90_000_000_000L, eventNorth.getLatNano());

        // Minimum latitude (South Pole)
        GeoEvent eventSouth = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(-90.0)
                .setLongitude(0)
                .build();
        assertEquals(-90_000_000_000L, eventSouth.getLatNano());
    }

    @Test
    void testBoundaryLongitudes() {
        // Maximum longitude (Date Line +)
        GeoEvent eventEast = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(180.0)
                .build();
        assertEquals(180_000_000_000L, eventEast.getLonNano());

        // Minimum longitude (Date Line -)
        GeoEvent eventWest = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(-180.0)
                .build();
        assertEquals(-180_000_000_000L, eventWest.getLonNano());
    }

    @Test
    void testOriginCoordinates() {
        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(0)
                .build();

        assertEquals(0L, event.getLatNano());
        assertEquals(0L, event.getLonNano());
    }

    @Test
    void testHeadingFullRange() {
        // Test all cardinal directions
        short[] headings = {0, 9000, 18000, 27000}; // N, E, S, W
        double[] expectedDegrees = {0, 90, 180, 270};

        for (int i = 0; i < headings.length; i++) {
            GeoEvent event = new GeoEvent.Builder()
                    .setEntityId(UInt128.random())
                    .setLatitude(0)
                    .setLongitude(0)
                    .setHeadingCentideg(headings[i])
                    .build();

            assertEquals(expectedDegrees[i], event.getHeadingDegrees(), 0.0001,
                    "Heading mismatch at index " + i);
        }
    }

    @Test
    void testDefaultValues() {
        GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(0)
                .setLongitude(0)
                .build();

        // Default values should be zero/null
        assertEquals(UInt128.ZERO, event.getCorrelationId());
        assertEquals(UInt128.ZERO, event.getUserData());
        assertEquals(0L, event.getGroupId());
        assertEquals(0L, event.getTimestamp());
        assertEquals(0, event.getAltitudeMm());
        assertEquals(0, event.getVelocityMmps());
        assertEquals(0, event.getTtlSeconds());
        assertEquals(0, event.getAccuracyMm());
        assertEquals(0, event.getHeadingCentideg());
        assertEquals(0, event.getStatus());
        assertEquals(0, event.getEventType());
    }
}
