// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * GeoJSON and WKT parsing and formatting utilities.
 * <p>
 * Provides functions to convert between standard geospatial formats (GeoJSON, WKT) and ArcherDB's
 * native nanodegree coordinate representation.
 * </p>
 *
 * @see <a href="https://geojson.org/">GeoJSON Specification</a>
 * @see <a href="https://en.wikipedia.org/wiki/Well-known_text_representation_of_geometry">WKT
 *      Specification</a>
 */
public final class GeoFormatParser {

    private static final double LAT_MAX = 90.0;
    private static final double LON_MAX = 180.0;
    private static final long NANODEGREES_PER_DEGREE = 1_000_000_000L;

    private static final Pattern WKT_POINT_PATTERN = Pattern.compile(
            "(?i)^\\s*POINT\\s*\\(\\s*([\\d.\\-]+)\\s+([\\d.\\-]+)(?:\\s+[\\d.\\-]+)?\\s*\\)\\s*$");

    private GeoFormatParser() {
        // Utility class
    }

    /**
     * Parses a GeoJSON Point string to nanodegree coordinates.
     *
     * @param geojson GeoJSON Point string: {"type": "Point", "coordinates": [lon, lat]}
     * @return long[2] containing {lat_nano, lon_nano}
     * @throws GeoFormatException if parsing fails
     */
    public static long[] parseGeoJSONPoint(String geojson) throws GeoFormatException {
        if (geojson == null || geojson.trim().isEmpty()) {
            throw new GeoFormatException("GeoJSON string is null or empty");
        }

        // Simple JSON parsing without external dependencies
        String trimmed = geojson.trim();

        // Check type field
        if (!trimmed.contains("\"type\"") || !trimmed.contains("\"Point\"")) {
            throw new GeoFormatException("Expected type 'Point' in GeoJSON");
        }

        // Extract coordinates array
        int coordsStart = trimmed.indexOf("\"coordinates\"");
        if (coordsStart == -1) {
            throw new GeoFormatException("Missing 'coordinates' field");
        }

        int arrayStart = trimmed.indexOf('[', coordsStart);
        int arrayEnd = trimmed.indexOf(']', arrayStart);
        if (arrayStart == -1 || arrayEnd == -1) {
            throw new GeoFormatException("Invalid coordinates array");
        }

        String coordsStr = trimmed.substring(arrayStart + 1, arrayEnd);
        String[] parts = coordsStr.split(",");
        if (parts.length < 2) {
            throw new GeoFormatException("Point must have [lon, lat] coordinates");
        }

        try {
            double lon = Double.parseDouble(parts[0].trim());
            double lat = Double.parseDouble(parts[1].trim());

            validateCoordinates(lat, lon);

            return new long[] {degreesToNano(lat), degreesToNano(lon)};
        } catch (NumberFormatException e) {
            throw new GeoFormatException("Invalid coordinate values: " + e.getMessage());
        }
    }

    /**
     * Parses a GeoJSON Polygon string to nanodegree coordinates.
     *
     * @param geojson GeoJSON Polygon string
     * @return GeoJSONPolygonResult containing exterior ring and holes
     * @throws GeoFormatException if parsing fails
     */
    public static GeoJSONPolygonResult parseGeoJSONPolygon(String geojson)
            throws GeoFormatException {
        if (geojson == null || geojson.trim().isEmpty()) {
            throw new GeoFormatException("GeoJSON string is null or empty");
        }

        String trimmed = geojson.trim();

        // Check type field
        if (!trimmed.contains("\"type\"") || !trimmed.contains("\"Polygon\"")) {
            throw new GeoFormatException("Expected type 'Polygon' in GeoJSON");
        }

        // Find coordinates array
        int coordsStart = trimmed.indexOf("\"coordinates\"");
        if (coordsStart == -1) {
            throw new GeoFormatException("Missing 'coordinates' field");
        }

        // Parse the nested arrays
        int outerStart = trimmed.indexOf('[', coordsStart);
        if (outerStart == -1) {
            throw new GeoFormatException("Invalid coordinates array");
        }

        // Find all rings
        List<List<long[]>> rings = new ArrayList<>();
        int depth = 0;
        boolean inNumber = false;
        StringBuilder currentNumber = new StringBuilder();
        List<long[]> currentRing = null;
        List<Double> currentPoint = new ArrayList<>();

        for (int i = outerStart; i < trimmed.length(); i++) {
            char c = trimmed.charAt(i);

            if (c == '[') {
                depth++;
                if (depth == 2) {
                    currentRing = new ArrayList<>();
                } else if (depth == 3) {
                    currentPoint = new ArrayList<>();
                }
            } else if (c == ']') {
                if (inNumber && currentNumber.length() > 0) {
                    currentPoint.add(Double.parseDouble(currentNumber.toString()));
                    currentNumber = new StringBuilder();
                    inNumber = false;
                }

                if (depth == 3 && currentRing != null && currentPoint.size() >= 2) {
                    double lon = currentPoint.get(0);
                    double lat = currentPoint.get(1);
                    validateCoordinates(lat, lon);
                    currentRing.add(new long[] {degreesToNano(lat), degreesToNano(lon)});
                }
                if (depth == 2 && currentRing != null && currentRing.size() >= 3) {
                    rings.add(currentRing);
                }

                depth--;
                if (depth == 0)
                    break;
            } else if (c >= '0' && c <= '9' || c == '.' || c == '-' || c == 'e' || c == 'E'
                    || c == '+') {
                if (!inNumber && depth >= 3) {
                    inNumber = true;
                    currentNumber = new StringBuilder();
                    currentNumber.append(c);
                } else if (inNumber) {
                    currentNumber.append(c);
                }
            } else if (c == ',' && depth == 3 && inNumber && currentNumber.length() > 0) {
                currentPoint.add(Double.parseDouble(currentNumber.toString()));
                currentNumber = new StringBuilder();
                inNumber = false;
            }
        }

        if (rings.isEmpty()) {
            throw new GeoFormatException("Polygon must have at least one ring");
        }

        List<long[]> exterior = rings.get(0);
        List<List<long[]>> holes =
                rings.size() > 1 ? rings.subList(1, rings.size()) : Collections.emptyList();

        return new GeoJSONPolygonResult(exterior, holes);
    }

    /**
     * Parses a WKT POINT string to nanodegree coordinates.
     *
     * @param wkt WKT string like "POINT(lon lat)"
     * @return long[2] containing {lat_nano, lon_nano}
     * @throws GeoFormatException if parsing fails
     */
    public static long[] parseWKTPoint(String wkt) throws GeoFormatException {
        if (wkt == null || wkt.trim().isEmpty()) {
            throw new GeoFormatException("WKT string is null or empty");
        }

        Matcher matcher = WKT_POINT_PATTERN.matcher(wkt);
        if (!matcher.matches()) {
            throw new GeoFormatException("Invalid WKT POINT format");
        }

        try {
            double lon = Double.parseDouble(matcher.group(1));
            double lat = Double.parseDouble(matcher.group(2));

            validateCoordinates(lat, lon);

            return new long[] {degreesToNano(lat), degreesToNano(lon)};
        } catch (NumberFormatException e) {
            throw new GeoFormatException("Invalid coordinate values: " + e.getMessage());
        }
    }

    /**
     * Parses a WKT POLYGON string to nanodegree coordinates.
     *
     * @param wkt WKT string like "POLYGON((lon lat, lon lat, ...))"
     * @return WKTPolygonResult containing exterior ring and holes
     * @throws GeoFormatException if parsing fails
     */
    public static WKTPolygonResult parseWKTPolygon(String wkt) throws GeoFormatException {
        if (wkt == null || wkt.trim().isEmpty()) {
            throw new GeoFormatException("WKT string is null or empty");
        }

        String upper = wkt.trim().toUpperCase();
        if (!upper.startsWith("POLYGON")) {
            throw new GeoFormatException("Expected POLYGON");
        }

        int outerStart = wkt.indexOf('(');
        int outerEnd = wkt.lastIndexOf(')');
        if (outerStart == -1 || outerEnd == -1 || outerStart >= outerEnd) {
            throw new GeoFormatException("Invalid WKT POLYGON: missing parentheses");
        }

        String content = wkt.substring(outerStart + 1, outerEnd);

        // Find matching parentheses for each ring
        List<String> ringStrs = new ArrayList<>();
        int depth = 0;
        int ringStart = 0;
        for (int i = 0; i < content.length(); i++) {
            char c = content.charAt(i);
            if (c == '(') {
                if (depth == 0)
                    ringStart = i;
                depth++;
            } else if (c == ')') {
                depth--;
                if (depth == 0) {
                    ringStrs.add(content.substring(ringStart, i + 1));
                }
            }
        }

        if (ringStrs.isEmpty()) {
            throw new GeoFormatException("POLYGON must have at least one ring");
        }

        List<List<long[]>> rings = new ArrayList<>();
        for (String ringStr : ringStrs) {
            rings.add(parseWKTRing(ringStr));
        }

        List<long[]> exterior = rings.get(0);
        List<List<long[]>> holes =
                rings.size() > 1 ? rings.subList(1, rings.size()) : Collections.emptyList();

        return new WKTPolygonResult(exterior, holes);
    }

    private static List<long[]> parseWKTRing(String ring) throws GeoFormatException {
        ring = ring.trim();
        if (!ring.startsWith("(") || !ring.endsWith(")")) {
            throw new GeoFormatException("Ring must be enclosed in parentheses");
        }

        String content = ring.substring(1, ring.length() - 1);
        String[] pointStrs = content.split(",");

        if (pointStrs.length < 3) {
            throw new GeoFormatException(
                    "Ring must have at least 3 vertices, got " + pointStrs.length);
        }

        List<long[]> result = new ArrayList<>();
        for (int i = 0; i < pointStrs.length; i++) {
            String[] parts = pointStrs[i].trim().split("\\s+");
            if (parts.length < 2) {
                throw new GeoFormatException("Invalid point at index " + i);
            }

            try {
                double lon = Double.parseDouble(parts[0]);
                double lat = Double.parseDouble(parts[1]);

                validateCoordinates(lat, lon);

                result.add(new long[] {degreesToNano(lat), degreesToNano(lon)});
            } catch (NumberFormatException e) {
                throw new GeoFormatException(
                        "Invalid coordinates at point " + i + ": " + e.getMessage());
            }
        }

        return result;
    }

    /**
     * Converts nanodegree coordinates to a GeoJSON Point string.
     *
     * @param latNano Latitude in nanodegrees
     * @param lonNano Longitude in nanodegrees
     * @return GeoJSON Point string
     */
    public static String toGeoJSONPoint(long latNano, long lonNano) {
        double lat = nanoToDegrees(latNano);
        double lon = nanoToDegrees(lonNano);
        return String.format("{\"type\":\"Point\",\"coordinates\":[%s,%s]}", lon, lat);
    }

    /**
     * Converts nanodegree coordinates to a GeoJSON Polygon string.
     *
     * @param exterior Exterior ring as List of long[2]{lat_nano, lon_nano}
     * @param holes Optional holes as List of rings
     * @return GeoJSON Polygon string
     */
    public static String toGeoJSONPolygon(List<long[]> exterior, List<List<long[]>> holes) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"type\":\"Polygon\",\"coordinates\":[");

        appendRingAsGeoJSON(sb, exterior);

        if (holes != null) {
            for (List<long[]> hole : holes) {
                sb.append(",");
                appendRingAsGeoJSON(sb, hole);
            }
        }

        sb.append("]}");
        return sb.toString();
    }

    private static void appendRingAsGeoJSON(StringBuilder sb, List<long[]> ring) {
        sb.append("[");
        boolean first = true;
        for (long[] point : ring) {
            if (!first)
                sb.append(",");
            first = false;
            sb.append("[").append(nanoToDegrees(point[1])).append(",")
                    .append(nanoToDegrees(point[0])).append("]");
        }
        sb.append("]");
    }

    /**
     * Converts nanodegree coordinates to a WKT POINT string.
     *
     * @param latNano Latitude in nanodegrees
     * @param lonNano Longitude in nanodegrees
     * @return WKT POINT string
     */
    public static String toWKTPoint(long latNano, long lonNano) {
        return String.format("POINT(%s %s)", nanoToDegrees(lonNano), nanoToDegrees(latNano));
    }

    /**
     * Converts nanodegree coordinates to a WKT POLYGON string.
     *
     * @param exterior Exterior ring as List of long[2]{lat_nano, lon_nano}
     * @param holes Optional holes as List of rings
     * @return WKT POLYGON string
     */
    public static String toWKTPolygon(List<long[]> exterior, List<List<long[]>> holes) {
        StringBuilder sb = new StringBuilder();
        sb.append("POLYGON(");

        appendRingAsWKT(sb, exterior);

        if (holes != null) {
            for (List<long[]> hole : holes) {
                sb.append(", ");
                appendRingAsWKT(sb, hole);
            }
        }

        sb.append(")");
        return sb.toString();
    }

    private static void appendRingAsWKT(StringBuilder sb, List<long[]> ring) {
        sb.append("(");
        boolean first = true;
        for (long[] point : ring) {
            if (!first)
                sb.append(", ");
            first = false;
            sb.append(nanoToDegrees(point[1])).append(" ").append(nanoToDegrees(point[0]));
        }
        sb.append(")");
    }

    /**
     * Converts degrees to nanodegrees.
     */
    public static long degreesToNano(double degrees) {
        return Math.round(degrees * NANODEGREES_PER_DEGREE);
    }

    /**
     * Converts nanodegrees to degrees.
     */
    public static double nanoToDegrees(long nano) {
        return (double) nano / NANODEGREES_PER_DEGREE;
    }

    private static void validateCoordinates(double lat, double lon) throws GeoFormatException {
        if (lat < -LAT_MAX || lat > LAT_MAX) {
            throw new GeoFormatException("Latitude " + lat + " out of bounds [-90, 90]");
        }
        if (lon < -LON_MAX || lon > LON_MAX) {
            throw new GeoFormatException("Longitude " + lon + " out of bounds [-180, 180]");
        }
    }

    /**
     * Result of parsing a GeoJSON Polygon.
     */
    public static class GeoJSONPolygonResult {
        private final List<long[]> exterior;
        private final List<List<long[]>> holes;

        public GeoJSONPolygonResult(List<long[]> exterior, List<List<long[]>> holes) {
            this.exterior = exterior;
            this.holes = holes;
        }

        public List<long[]> getExterior() {
            return exterior;
        }

        public List<List<long[]>> getHoles() {
            return holes;
        }
    }

    /**
     * Result of parsing a WKT Polygon.
     */
    public static class WKTPolygonResult {
        private final List<long[]> exterior;
        private final List<List<long[]>> holes;

        public WKTPolygonResult(List<long[]> exterior, List<List<long[]>> holes) {
            this.exterior = exterior;
            this.holes = holes;
        }

        public List<long[]> getExterior() {
            return exterior;
        }

        public List<List<long[]>> getHoles() {
            return holes;
        }
    }
}
