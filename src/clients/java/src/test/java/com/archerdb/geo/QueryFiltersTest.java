// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

/**
 * Unit tests for query filter classes.
 */
class QueryFiltersTest {

    // ========================================================================
    // QueryRadiusFilter Tests
    // ========================================================================

    @Test
    void testQueryRadiusFilterBuilder() {
        QueryRadiusFilter filter = new QueryRadiusFilter.Builder().setCenterLatitude(37.7749)
                .setCenterLongitude(-122.4194).setRadiusMeters(1000).setLimit(500).setGroupId(42L)
                .build();

        assertEquals(37_774_900_000L, filter.getCenterLatNano());
        assertEquals(-122_419_400_000L, filter.getCenterLonNano());
        assertEquals(1_000_000, filter.getRadiusMm()); // 1000m = 1000000mm
        assertEquals(500, filter.getLimit());
        assertEquals(42L, filter.getGroupId());
    }

    @Test
    void testQueryRadiusFilterDefaults() {
        QueryRadiusFilter filter = new QueryRadiusFilter.Builder().setCenterLatitude(0)
                .setCenterLongitude(0).setRadiusMeters(100).build();

        assertEquals(1000, filter.getLimit()); // Default limit
        assertEquals(0L, filter.getGroupId()); // No group filter
        assertEquals(0L, filter.getTimestampMin());
        assertEquals(0L, filter.getTimestampMax());
    }

    @Test
    void testQueryRadiusFilterTimeRange() {
        long now = System.nanoTime();
        long oneHourAgo = now - 3_600_000_000_000L;

        QueryRadiusFilter filter = new QueryRadiusFilter.Builder().setCenterLatitude(0)
                .setCenterLongitude(0).setRadiusMeters(100).setTimestampMin(oneHourAgo)
                .setTimestampMax(now).build();

        assertEquals(oneHourAgo, filter.getTimestampMin());
        assertEquals(now, filter.getTimestampMax());
    }

    @Test
    void testQueryRadiusFilterCreate() {
        // Static factory method
        QueryRadiusFilter filter = QueryRadiusFilter.create(37.7749, -122.4194, 1000, 100);

        assertEquals(37_774_900_000L, filter.getCenterLatNano());
        assertEquals(-122_419_400_000L, filter.getCenterLonNano());
        assertEquals(1_000_000, filter.getRadiusMm());
        assertEquals(100, filter.getLimit());
    }

    @Test
    void testQueryRadiusFilterInvalidLatitude() {
        assertThrows(IllegalArgumentException.class, () -> {
            new QueryRadiusFilter.Builder().setCenterLatitude(91.0) // Invalid: > 90
                    .setCenterLongitude(0).setRadiusMeters(100).build();
        });
    }

    @Test
    void testQueryRadiusFilterInvalidLongitude() {
        assertThrows(IllegalArgumentException.class, () -> {
            new QueryRadiusFilter.Builder().setCenterLatitude(0).setCenterLongitude(181.0) // Invalid:
                                                                                           // > 180
                    .setRadiusMeters(100).build();
        });
    }

    @Test
    void testQueryRadiusFilterInvalidRadius() {
        assertThrows(IllegalArgumentException.class, () -> {
            new QueryRadiusFilter.Builder().setCenterLatitude(0).setCenterLongitude(0)
                    .setRadiusMeters(-100) // Invalid: negative
                    .build();
        });
    }

    @Test
    void testQueryRadiusFilterZeroRadius() {
        assertThrows(IllegalArgumentException.class, () -> {
            new QueryRadiusFilter.Builder().setCenterLatitude(0).setCenterLongitude(0)
                    .setRadiusMeters(0) // Invalid: zero
                    .build();
        });
    }

    @Test
    void testQueryRadiusFilterLimitExceedsMax() {
        assertThrows(IllegalArgumentException.class, () -> {
            new QueryRadiusFilter.Builder().setCenterLatitude(0).setCenterLongitude(0)
                    .setRadiusMeters(100).setLimit(100_000) // Invalid: exceeds 81,000 max
                    .build();
        });
    }

    // ========================================================================
    // QueryPolygonFilter Tests
    // ========================================================================

    @Test
    void testQueryPolygonFilterBuilder() {
        QueryPolygonFilter filter = new QueryPolygonFilter.Builder().addVertex(37.78, -122.42)
                .addVertex(37.78, -122.40).addVertex(37.76, -122.40).addVertex(37.76, -122.42)
                .setLimit(500).setGroupId(10L).build();

        assertEquals(500, filter.getLimit());
        assertEquals(10L, filter.getGroupId());
    }

    @Test
    void testQueryPolygonFilterDefaults() {
        QueryPolygonFilter filter = new QueryPolygonFilter.Builder().addVertex(0, 0)
                .addVertex(0, 10).addVertex(10, 10).build();

        assertEquals(1000, filter.getLimit()); // Default limit
        assertEquals(0L, filter.getGroupId());
        assertEquals(0L, filter.getTimestampMin());
        assertEquals(0L, filter.getTimestampMax());
    }

    @Test
    void testQueryPolygonFilterTooFewVertices() {
        assertThrows(IllegalArgumentException.class, () -> {
            new QueryPolygonFilter.Builder().addVertex(0, 0).addVertex(10, 0)
                    // Only 2 vertices - need at least 3
                    .build();
        });
    }

    @Test
    void testQueryPolygonFilterUnfinishedHole() {
        assertThrows(IllegalStateException.class, () -> {
            new QueryPolygonFilter.Builder().addVertex(0, 0).addVertex(0, 10).addVertex(10, 10)
                    .addVertex(10, 0).startHole().addHoleVertex(2, 2).addHoleVertex(2, 8)
                    .addHoleVertex(8, 8)
                    // Missing finishHole()
                    .build();
        });
    }

    // ========================================================================
    // QueryLatestFilter Tests
    // ========================================================================

    @Test
    void testQueryLatestFilterGlobal() {
        QueryLatestFilter filter = QueryLatestFilter.global(100);

        assertEquals(100, filter.getLimit());
        assertEquals(0L, filter.getGroupId());
    }

    @Test
    void testQueryLatestFilterForGroup() {
        QueryLatestFilter filter = QueryLatestFilter.forGroup(5L, 100);

        assertEquals(100, filter.getLimit());
        assertEquals(5L, filter.getGroupId());
    }

    @Test
    void testQueryLatestFilterWithCursor() {
        long cursor = 1704067200_000_000_000L;

        QueryLatestFilter filter = QueryLatestFilter.withCursor(100, cursor);

        assertEquals(100, filter.getLimit());
        assertEquals(cursor, filter.getCursorTimestamp());
    }

    @Test
    void testQueryLatestFilterConstructor() {
        QueryLatestFilter filter = new QueryLatestFilter(100, 42L, 12345L);

        assertEquals(100, filter.getLimit());
        assertEquals(42L, filter.getGroupId());
        assertEquals(12345L, filter.getCursorTimestamp());
    }
}
