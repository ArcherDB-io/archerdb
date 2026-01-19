package com.archerdb.geo;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Tests for polygon self-intersection validation (add-polygon-validation spec).
 */
public class PolygonValidationTest {

    @Test
    void testValidTriangle() throws Exception {
        // Triangle cannot self-intersect (too few edges)
        List<double[]> triangle = Arrays.asList(new double[] {0.0, 0.0}, new double[] {1.0, 0.0},
                new double[] {0.5, 1.0});
        List<PolygonValidation.IntersectionInfo> result =
                PolygonValidation.validatePolygonNoSelfIntersection(triangle, false);
        assertEquals(0, result.size());
    }

    @Test
    void testValidSquare() throws Exception {
        // Simple square has no self-intersections
        List<double[]> square = Arrays.asList(new double[] {0.0, 0.0}, new double[] {1.0, 0.0},
                new double[] {1.0, 1.0}, new double[] {0.0, 1.0});
        List<PolygonValidation.IntersectionInfo> result =
                PolygonValidation.validatePolygonNoSelfIntersection(square, false);
        assertEquals(0, result.size());
    }

    @Test
    void testValidConvexPentagon() throws Exception {
        // Convex pentagon has no self-intersections
        List<double[]> pentagon = new ArrayList<>();
        for (int i = 0; i < 5; i++) {
            double angle = 2.0 * Math.PI * i / 5.0;
            pentagon.add(new double[] {Math.cos(angle), Math.sin(angle)});
        }
        List<PolygonValidation.IntersectionInfo> result =
                PolygonValidation.validatePolygonNoSelfIntersection(pentagon, false);
        assertEquals(0, result.size());
    }

    @Test
    void testBowtiePolygonIntersects() throws Exception {
        // Bow-tie (figure-8) polygon has a self-intersection
        List<double[]> bowtie = Arrays.asList(new double[] {0.0, 0.0}, new double[] {1.0, 1.0},
                new double[] {1.0, 0.0}, new double[] {0.0, 1.0});
        List<PolygonValidation.IntersectionInfo> result =
                PolygonValidation.validatePolygonNoSelfIntersection(bowtie, false);
        assertTrue(result.size() > 0, "Bow-tie should have intersections");
    }

    @Test
    void testBowtieRaisesException() {
        // Bow-tie polygon throws exception when raiseOnError=true
        List<double[]> bowtie = Arrays.asList(new double[] {0.0, 0.0}, new double[] {1.0, 1.0},
                new double[] {1.0, 0.0}, new double[] {0.0, 1.0});

        PolygonValidation.PolygonValidationException ex =
                assertThrows(PolygonValidation.PolygonValidationException.class,
                        () -> PolygonValidation.validatePolygonNoSelfIntersection(bowtie, true));

        assertTrue(ex.segment1Index >= 0 && ex.segment1Index < 4);
        assertTrue(ex.segment2Index >= 0 && ex.segment2Index < 4);
        assertTrue(ex.getMessage().contains("self-intersects"));
    }

    @Test
    void testValidConcavePolygon() throws Exception {
        // Concave (non-convex) polygon without self-intersections (L-shape)
        List<double[]> lShape = Arrays.asList(new double[] {0.0, 0.0}, new double[] {2.0, 0.0},
                new double[] {2.0, 1.0}, new double[] {1.0, 1.0}, new double[] {1.0, 2.0},
                new double[] {0.0, 2.0});
        List<PolygonValidation.IntersectionInfo> result =
                PolygonValidation.validatePolygonNoSelfIntersection(lShape, false);
        assertEquals(0, result.size());
    }

    @Test
    void testStarPolygonIntersects() throws Exception {
        // 5-pointed star (drawn without lifting pen) self-intersects
        List<double[]> star = new ArrayList<>();
        for (int i = 0; i < 5; i++) {
            double angle = Math.PI / 2.0 + i * 4.0 * Math.PI / 5.0;
            star.add(new double[] {Math.cos(angle), Math.sin(angle)});
        }
        List<PolygonValidation.IntersectionInfo> result =
                PolygonValidation.validatePolygonNoSelfIntersection(star, false);
        assertTrue(result.size() > 0, "5-pointed star should have intersections");
    }

    @Test
    void testSegmentsIntersectBasic() {
        // Clearly crossing segments
        assertTrue(PolygonValidation.segmentsIntersect(new double[] {0.0, 0.0},
                new double[] {1.0, 1.0}, // Diagonal
                new double[] {0.0, 1.0}, new double[] {1.0, 0.0} // Opposite diagonal
        ));

        // Parallel segments (no intersection)
        assertFalse(PolygonValidation.segmentsIntersect(new double[] {0.0, 0.0},
                new double[] {1.0, 0.0}, // Horizontal
                new double[] {0.0, 1.0}, new double[] {1.0, 1.0} // Parallel horizontal
        ));

        // T-junction (endpoint touches)
        assertTrue(PolygonValidation.segmentsIntersect(new double[] {0.0, 0.5},
                new double[] {1.0, 0.5}, // Horizontal
                new double[] {0.5, 0.0}, new double[] {0.5, 0.5} // Vertical ending at intersection
        ));
    }

    @Test
    void testPolygonValidationExceptionAttributes() {
        PolygonValidation.PolygonValidationException ex =
                new PolygonValidation.PolygonValidationException("Test error", 1, 3,
                        new double[] {0.5, 0.5});

        assertEquals(1, ex.segment1Index);
        assertEquals(3, ex.segment2Index);
        assertEquals(0.5, ex.intersectionPoint[0], 0.001);
        assertEquals(0.5, ex.intersectionPoint[1], 0.001);
        assertTrue(ex.getMessage().contains("Test error"));
    }

    @Test
    void testEmptyOrSmallPolygon() throws Exception {
        // Empty
        assertEquals(0, PolygonValidation
                .validatePolygonNoSelfIntersection(new ArrayList<>(), false).size());

        // Single point
        assertEquals(0, PolygonValidation
                .validatePolygonNoSelfIntersection(Arrays.asList(new double[] {0, 0}), false)
                .size());

        // Two points (line)
        assertEquals(0,
                PolygonValidation
                        .validatePolygonNoSelfIntersection(
                                Arrays.asList(new double[] {0, 0}, new double[] {1, 1}), false)
                        .size());

        // Three points (triangle - minimum valid polygon)
        assertEquals(0, PolygonValidation.validatePolygonNoSelfIntersection(
                Arrays.asList(new double[] {0, 0}, new double[] {1, 0}, new double[] {0, 1}), false)
                .size());
    }
}
