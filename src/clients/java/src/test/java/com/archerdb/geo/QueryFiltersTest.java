package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

import java.util.Arrays;
import java.util.List;

/**
 * Unit tests for query filter classes.
 */
class QueryFiltersTest {

    // ========================================================================
    // QueryRadiusFilter Tests
    // ========================================================================

    @Test
    void testQueryRadiusFilterBuilder() {
        QueryRadiusFilter filter = QueryRadiusFilter.builder()
                .setCenter(37.7749, -122.4194)
                .setRadiusMeters(1000)
                .setLimit(500)
                .setGroupId(42L)
                .build();

        assertEquals(37_774_900_000L, filter.getCenterLatNano());
        assertEquals(-122_419_400_000L, filter.getCenterLonNano());
        assertEquals(1_000_000, filter.getRadiusMm()); // 1000m = 1000000mm
        assertEquals(500, filter.getLimit());
        assertEquals(42L, filter.getGroupId());
    }

    @Test
    void testQueryRadiusFilterDefaults() {
        QueryRadiusFilter filter = QueryRadiusFilter.builder()
                .setCenter(0, 0)
                .setRadiusMeters(100)
                .build();

        assertEquals(1000, filter.getLimit()); // Default limit
        assertEquals(0L, filter.getGroupId()); // No group filter
        assertEquals(0L, filter.getTimestampMin());
        assertEquals(0L, filter.getTimestampMax());
    }

    @Test
    void testQueryRadiusFilterTimeRange() {
        long now = System.nanoTime();
        long oneHourAgo = now - 3_600_000_000_000L;

        QueryRadiusFilter filter = QueryRadiusFilter.builder()
                .setCenter(0, 0)
                .setRadiusMeters(100)
                .setTimestampMin(oneHourAgo)
                .setTimestampMax(now)
                .build();

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
    void testQueryRadiusFilterInvalidCenter() {
        QueryRadiusFilter.Builder builder = QueryRadiusFilter.builder()
                .setRadiusMeters(100);

        assertThrows(IllegalArgumentException.class, () -> builder.setCenter(91, 0));
        assertThrows(IllegalArgumentException.class, () -> builder.setCenter(0, 181));
    }

    @Test
    void testQueryRadiusFilterInvalidRadius() {
        QueryRadiusFilter.Builder builder = QueryRadiusFilter.builder()
                .setCenter(0, 0);

        assertThrows(IllegalArgumentException.class, () -> builder.setRadiusMeters(0));
        assertThrows(IllegalArgumentException.class, () -> builder.setRadiusMeters(-100));
    }

    // ========================================================================
    // QueryPolygonFilter Tests
    // ========================================================================

    @Test
    void testQueryPolygonFilterBuilder() {
        List<double[]> vertices = Arrays.asList(
                new double[]{37.78, -122.42},
                new double[]{37.78, -122.40},
                new double[]{37.76, -122.40},
                new double[]{37.76, -122.42}
        );

        QueryPolygonFilter filter = QueryPolygonFilter.builder()
                .setVertices(vertices)
                .setLimit(500)
                .setGroupId(10L)
                .build();

        assertEquals(4, filter.getVertexCount());
        assertEquals(500, filter.getLimit());
        assertEquals(10L, filter.getGroupId());

        // Check first vertex
        assertEquals(37_780_000_000L, filter.getVertexLatNano(0));
        assertEquals(-122_420_000_000L, filter.getVertexLonNano(0));
    }

    @Test
    void testQueryPolygonFilterDefaults() {
        List<double[]> vertices = Arrays.asList(
                new double[]{0, 0},
                new double[]{0, 10},
                new double[]{10, 10}
        );

        QueryPolygonFilter filter = QueryPolygonFilter.builder()
                .setVertices(vertices)
                .build();

        assertEquals(1000, filter.getLimit()); // Default limit
        assertEquals(0L, filter.getGroupId());
        assertEquals(0L, filter.getTimestampMin());
        assertEquals(0L, filter.getTimestampMax());
    }

    @Test
    void testQueryPolygonFilterTooFewVertices() {
        List<double[]> vertices = Arrays.asList(
                new double[]{0, 0},
                new double[]{0, 10}
                // Only 2 vertices - need at least 3
        );

        QueryPolygonFilter.Builder builder = QueryPolygonFilter.builder();

        assertThrows(IllegalArgumentException.class, () -> builder.setVertices(vertices));
    }

    @Test
    void testQueryPolygonFilterInvalidVertex() {
        List<double[]> vertices = Arrays.asList(
                new double[]{91, 0},  // Invalid latitude
                new double[]{0, 10},
                new double[]{10, 10}
        );

        QueryPolygonFilter.Builder builder = QueryPolygonFilter.builder();

        assertThrows(IllegalArgumentException.class, () -> builder.setVertices(vertices));
    }

    // ========================================================================
    // QueryLatestFilter Tests
    // ========================================================================

    @Test
    void testQueryLatestFilterBuilder() {
        QueryLatestFilter filter = QueryLatestFilter.builder()
                .setLimit(100)
                .setGroupId(5L)
                .build();

        assertEquals(100, filter.getLimit());
        assertEquals(5L, filter.getGroupId());
    }

    @Test
    void testQueryLatestFilterDefaults() {
        QueryLatestFilter filter = QueryLatestFilter.builder().build();

        assertEquals(1000, filter.getLimit()); // Default limit
        assertEquals(0L, filter.getGroupId());
        assertEquals(0L, filter.getCursorTimestamp());
    }

    @Test
    void testQueryLatestFilterWithCursor() {
        long cursor = 1704067200_000_000_000L;

        QueryLatestFilter filter = QueryLatestFilter.builder()
                .setCursorTimestamp(cursor)
                .build();

        assertEquals(cursor, filter.getCursorTimestamp());
    }
}
