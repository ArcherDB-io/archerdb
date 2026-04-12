// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.ArrayList;
import java.util.List;

/**
 * Polygon self-intersection validation (per add-polygon-validation spec).
 *
 * <p>
 * Provides utilities to detect self-intersecting polygons before submitting queries.
 */
public final class PolygonValidation {

    private static final double EPS = 1e-10;

    private PolygonValidation() {
        // Utility class
    }

    /**
     * Information about a detected self-intersection.
     */
    public static class IntersectionInfo {
        /** Index of the first intersecting segment (0-based) */
        public final int segment1Index;
        /** Index of the second intersecting segment (0-based) */
        public final int segment2Index;
        /** Approximate intersection point [lat, lon] in degrees */
        public final double[] intersectionPoint;

        public IntersectionInfo(int segment1Index, int segment2Index, double[] intersectionPoint) {
            this.segment1Index = segment1Index;
            this.segment2Index = segment2Index;
            this.intersectionPoint = intersectionPoint;
        }
    }

    /**
     * Exception indicating a polygon self-intersection.
     */
    public static class PolygonValidationException extends Exception {
        /** Index of the first intersecting segment (0-based) */
        public final int segment1Index;
        /** Index of the second intersecting segment (0-based) */
        public final int segment2Index;
        /** Approximate intersection point [lat, lon] in degrees */
        public final double[] intersectionPoint;
        /** Repair suggestions for fixing the self-intersection */
        public final List<String> repairSuggestions;

        public PolygonValidationException(String message, int segment1Index, int segment2Index,
                double[] intersectionPoint) {
            this(message, segment1Index, segment2Index, intersectionPoint, new ArrayList<>());
        }

        public PolygonValidationException(String message, int segment1Index, int segment2Index,
                double[] intersectionPoint, List<String> repairSuggestions) {
            super(message);
            this.segment1Index = segment1Index;
            this.segment2Index = segment2Index;
            this.intersectionPoint = intersectionPoint;
            this.repairSuggestions = repairSuggestions;
        }

        /**
         * Returns repair suggestions for fixing the self-intersection.
         *
         * @return List of repair suggestions
         */
        public List<String> getRepairSuggestions() {
            return repairSuggestions;
        }
    }

    /**
     * Checks if two line segments intersect.
     *
     * <p>
     * Uses the cross product method with proper handling of collinear cases.
     *
     * @param p1 First segment start point [lat, lon]
     * @param p2 First segment end point [lat, lon]
     * @param p3 Second segment start point [lat, lon]
     * @param p4 Second segment end point [lat, lon]
     * @return true if the segments intersect, false otherwise
     */
    public static boolean segmentsIntersect(double[] p1, double[] p2, double[] p3, double[] p4) {
        double d1 = crossProduct(p3, p4, p1);
        double d2 = crossProduct(p3, p4, p2);
        double d3 = crossProduct(p1, p2, p3);
        double d4 = crossProduct(p1, p2, p4);

        // General case: segments cross
        boolean crossD1D2 = d1 > 0 && d2 < 0 || d1 < 0 && d2 > 0;
        boolean crossD3D4 = d3 > 0 && d4 < 0 || d3 < 0 && d4 > 0;
        if (crossD1D2 && crossD3D4) {
            return true;
        }

        // Collinear cases
        if (Math.abs(d1) < EPS && onSegment(p3, p1, p4))
            return true;
        if (Math.abs(d2) < EPS && onSegment(p3, p2, p4))
            return true;
        if (Math.abs(d3) < EPS && onSegment(p1, p3, p2))
            return true;
        if (Math.abs(d4) < EPS && onSegment(p1, p4, p2))
            return true;

        return false;
    }

    private static double crossProduct(double[] o, double[] a, double[] b) {
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
    }

    private static boolean onSegment(double[] p, double[] q, double[] r) {
        return q[0] >= Math.min(p[0], r[0]) && q[0] <= Math.max(p[0], r[0])
                && q[1] >= Math.min(p[1], r[1]) && q[1] <= Math.max(p[1], r[1]);
    }

    /**
     * Validates that a polygon has no self-intersections.
     *
     * <p>
     * Uses an O(n^2) algorithm suitable for polygons with reasonable vertex counts.
     *
     * @param vertices List of [lat, lon] coordinate pairs in degrees
     * @param raiseOnError If true, throws PolygonValidationException on first intersection
     * @return List of all intersections found (empty if valid)
     * @throws PolygonValidationException if raiseOnError is true and polygon self-intersects
     */
    public static List<IntersectionInfo> validatePolygonNoSelfIntersection(List<double[]> vertices,
            boolean raiseOnError) throws PolygonValidationException {

        List<IntersectionInfo> intersections = new ArrayList<>();

        // A triangle cannot self-intersect (3 vertices = 3 edges, need at least 4 for crossing)
        if (vertices.size() < 4) {
            return intersections;
        }

        int n = vertices.size();

        // Check all pairs of non-adjacent edges
        for (int i = 0; i < n; i++) {
            double[] p1 = vertices.get(i);
            double[] p2 = vertices.get((i + 1) % n);

            // Start from i+2 to skip adjacent edges (they share a vertex)
            for (int j = i + 2; j < n; j++) {
                // Skip if edges share a vertex (adjacent edges)
                if (j == (i + n - 1) % n) {
                    continue;
                }

                double[] p3 = vertices.get(j);
                double[] p4 = vertices.get((j + 1) % n);

                if (segmentsIntersect(p1, p2, p3, p4)) {
                    // Calculate approximate intersection point for error message
                    double ix = (p1[0] + p2[0] + p3[0] + p4[0]) / 4.0;
                    double iy = (p1[1] + p2[1] + p3[1] + p4[1]) / 4.0;
                    double[] intersection = new double[] {ix, iy};

                    if (raiseOnError) {
                        // Generate repair suggestions
                        List<String> suggestions = new ArrayList<>();
                        int v1Idx = (i + 1) % n;
                        int v2Idx = (j + 1) % n;

                        suggestions.add(String.format("Try removing vertex %d at (%.6f, %.6f)",
                                v1Idx, vertices.get(v1Idx)[0], vertices.get(v1Idx)[1]));
                        suggestions.add(String.format("Try removing vertex %d at (%.6f, %.6f)",
                                v2Idx, vertices.get(v2Idx)[0], vertices.get(v2Idx)[1]));

                        // Detect bow-tie pattern
                        if (j - i == 2) {
                            suggestions.add(String.format(
                                    "Bow-tie pattern detected: try swapping vertices %d and %d",
                                    i + 1, j));
                        }

                        suggestions.add(
                                "Ensure vertices are ordered consistently (clockwise or counter-clockwise)");

                        throw new PolygonValidationException(String.format(
                                "Polygon self-intersects: edge %d-%d crosses edge %d-%d near (%.6f, %.6f)",
                                i, (i + 1) % n, j, (j + 1) % n, ix, iy), i, j, intersection,
                                suggestions);
                    }

                    intersections.add(new IntersectionInfo(i, j, intersection));
                }
            }
        }

        return intersections;
    }

    /**
     * Validates a QueryPolygonFilter for self-intersections.
     *
     * @param filter The polygon filter to validate
     * @throws PolygonValidationException if the polygon self-intersects
     */
    public static void validatePolygonFilter(QueryPolygonFilter filter)
            throws PolygonValidationException {
        List<double[]> vertices = new ArrayList<>();
        for (QueryPolygonFilter.PolygonVertex v : filter.getVertices()) {
            vertices.add(new double[] {CoordinateUtils.nanoToDegrees(v.getLatNano()),
                    CoordinateUtils.nanoToDegrees(v.getLonNano())});
        }
        validatePolygonNoSelfIntersection(vertices, true);
    }
}
