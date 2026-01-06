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

        GeoEvent event = new GeoEvent.Builder().setEntityId(entityId).setLatitude(37.7749)
                .setLongitude(-122.4194).build();

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

        GeoEvent event = new GeoEvent.Builder().setEntityId(entityId)
                .setCorrelationId(correlationId).setUserData(userData).setLatitude(37.7749)
                .setLongitude(-122.4194).setGroupId(100L).setAltitudeMm(50_000) // 50 meters
                .setVelocityMms(15_500) // 15.5 m/s
                .setTtlSeconds(86400).setAccuracyMm(5_000) // 5 meters
                .setHeadingCdeg((short) 9000) // 90 degrees (East)
                .build();

        assertEquals(entityId, event.getEntityId());
        assertEquals(correlationId, event.getCorrelationId());
        assertEquals(userData, event.getUserData());
        assertEquals(100L, event.getGroupId());
        assertEquals(50_000, event.getAltitudeMm());
        assertEquals(15_500, event.getVelocityMms());
        assertEquals(86400, event.getTtlSeconds());
        assertEquals(5_000, event.getAccuracyMm());
        assertEquals(9000, event.getHeadingCdeg());
    }

    @Test
    void testBuilderWithFriendlyUnits() {
        UInt128 entityId = UInt128.random();

        GeoEvent event = new GeoEvent.Builder().setEntityId(entityId).setLatitude(40.7128)
                .setLongitude(-74.0060).setAltitude(100.5).setVelocity(30.5).setAccuracy(10.0)
                .setHeading(180.0).build();

        assertEquals(100_500, event.getAltitudeMm());
        assertEquals(30_500, event.getVelocityMms());
        assertEquals(10_000, event.getAccuracyMm());
        assertEquals(18000, event.getHeadingCdeg());
    }

    @Test
    void testBuilderGeneratesId() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();

        // ID is available (may be zero if not explicitly set - server assigns it)
        assertNotNull(event.getId());
    }

    // ========================================================================
    // GeoEvent Method Tests
    // ========================================================================

    @Test
    void testGetLatitudeLongitude() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
                .setLongitude(-122.4194).build();

        assertEquals(37.7749, event.getLatitude(), 0.0001);
        assertEquals(-122.4194, event.getLongitude(), 0.0001);
    }

    @Test
    void testGetAltitudeAsMeters() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                .setLongitude(0).setAltitudeMm(50_500).build();

        assertEquals(50.5, event.getAltitude(), 0.0001);
    }

    @Test
    void testGetVelocity() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                .setLongitude(0).setVelocityMms(15_500).build();

        assertEquals(15.5, event.getVelocity(), 0.0001);
    }

    @Test
    void testGetAccuracy() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                .setLongitude(0).setAccuracyMm(5_500).build();

        assertEquals(5.5, event.getAccuracy(), 0.0001);
    }

    @Test
    void testGetHeading() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                .setLongitude(0).setHeadingCdeg((short) 9000).build();

        assertEquals(90.0, event.getHeading(), 0.0001);
    }

    // ========================================================================
    // Edge Case Tests
    // ========================================================================

    @Test
    void testBoundaryLatitudes() {
        // Maximum latitude (North Pole)
        GeoEvent eventNorth = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(90.0)
                .setLongitude(0).build();
        assertEquals(90_000_000_000L, eventNorth.getLatNano());

        // Minimum latitude (South Pole)
        GeoEvent eventSouth = new GeoEvent.Builder().setEntityId(UInt128.random())
                .setLatitude(-90.0).setLongitude(0).build();
        assertEquals(-90_000_000_000L, eventSouth.getLatNano());
    }

    @Test
    void testBoundaryLongitudes() {
        // Maximum longitude (Date Line +)
        GeoEvent eventEast = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                .setLongitude(180.0).build();
        assertEquals(180_000_000_000L, eventEast.getLonNano());

        // Minimum longitude (Date Line -)
        GeoEvent eventWest = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                .setLongitude(-180.0).build();
        assertEquals(-180_000_000_000L, eventWest.getLonNano());
    }

    @Test
    void testOriginCoordinates() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                .setLongitude(0).build();

        assertEquals(0L, event.getLatNano());
        assertEquals(0L, event.getLonNano());
    }

    @Test
    void testHeadingFullRange() {
        // Test all cardinal directions
        short[] headings = {0, 9000, 18000, 27000}; // N, E, S, W
        double[] expectedDegrees = {0, 90, 180, 270};

        for (int i = 0; i < headings.length; i++) {
            GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                    .setLongitude(0).setHeadingCdeg(headings[i]).build();

            assertEquals(expectedDegrees[i], event.getHeading(), 0.0001,
                    "Heading mismatch at index " + i);
        }
    }

    @Test
    void testDefaultValues() {
        GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(0)
                .setLongitude(0).build();

        // Default values should be zero/null
        assertEquals(UInt128.ZERO, event.getCorrelationId());
        assertEquals(UInt128.ZERO, event.getUserData());
        assertEquals(0L, event.getGroupId());
        assertEquals(0L, event.getTimestamp());
        assertEquals(0, event.getAltitudeMm());
        assertEquals(0, event.getVelocityMms());
        assertEquals(0, event.getTtlSeconds());
        assertEquals(0, event.getAccuracyMm());
        assertEquals(0, event.getHeadingCdeg());
    }
}
