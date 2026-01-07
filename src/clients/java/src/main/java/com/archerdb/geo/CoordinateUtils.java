package com.archerdb.geo;

/**
 * Utility class for coordinate conversions.
 *
 * <p>
 * Provides methods to convert between:
 * <ul>
 * <li>Degrees and nanodegrees</li>
 * <li>Meters and millimeters</li>
 * <li>Heading degrees and centidegrees</li>
 * </ul>
 */
public final class CoordinateUtils {

    // Coordinate bounds
    public static final double LAT_MAX = 90.0;
    public static final double LON_MAX = 180.0;

    // Conversion factors
    public static final long NANODEGREES_PER_DEGREE = 1_000_000_000L;
    public static final int MM_PER_METER = 1000;
    public static final int CENTIDEGREES_PER_DEGREE = 100;

    // Limits per spec
    public static final int BATCH_SIZE_MAX = 10_000;
    public static final int QUERY_LIMIT_MAX = 81_000;
    public static final int POLYGON_VERTICES_MAX = 10_000;

    // Polygon hole limits (per spec)
    public static final int POLYGON_HOLES_MAX = 100;
    public static final int POLYGON_HOLE_VERTICES_MIN = 3;

    // Safe limits for default 1MB message configuration
    public static final int BATCH_SIZE_MAX_DEFAULT = 8_000;
    public static final int QUERY_LIMIT_MAX_DEFAULT = 8_000;

    private CoordinateUtils() {
        // Utility class - no instantiation
    }

    /**
     * Converts degrees to nanodegrees.
     *
     * @param degrees coordinate in degrees
     * @return coordinate in nanodegrees
     */
    public static long degreesToNano(double degrees) {
        return Math.round(degrees * NANODEGREES_PER_DEGREE);
    }

    /**
     * Converts nanodegrees to degrees.
     *
     * @param nano coordinate in nanodegrees
     * @return coordinate in degrees
     */
    public static double nanoToDegrees(long nano) {
        return (double) nano / NANODEGREES_PER_DEGREE;
    }

    /**
     * Converts meters to millimeters.
     *
     * @param meters distance in meters
     * @return distance in millimeters
     */
    public static int metersToMm(double meters) {
        return (int) Math.round(meters * MM_PER_METER);
    }

    /**
     * Converts millimeters to meters.
     *
     * @param mm distance in millimeters
     * @return distance in meters
     */
    public static double mmToMeters(int mm) {
        return (double) mm / MM_PER_METER;
    }

    /**
     * Converts heading from degrees (0-360) to centidegrees (0-36000).
     *
     * @param degrees heading in degrees
     * @return heading in centidegrees
     */
    public static short headingToCentidegrees(double degrees) {
        return (short) Math.round(degrees * CENTIDEGREES_PER_DEGREE);
    }

    /**
     * Converts heading from centidegrees to degrees.
     *
     * @param cdeg heading in centidegrees
     * @return heading in degrees
     */
    public static double centidegreesToHeading(short cdeg) {
        return (double) cdeg / CENTIDEGREES_PER_DEGREE;
    }

    /**
     * Checks if latitude in degrees is valid (-90 to +90).
     *
     * @param lat latitude in degrees
     * @return true if valid
     */
    public static boolean isValidLatitude(double lat) {
        return lat >= -LAT_MAX && lat <= LAT_MAX;
    }

    /**
     * Checks if longitude in degrees is valid (-180 to +180).
     *
     * @param lon longitude in degrees
     * @return true if valid
     */
    public static boolean isValidLongitude(double lon) {
        return lon >= -LON_MAX && lon <= LON_MAX;
    }

    /**
     * Checks if latitude in nanodegrees is valid.
     *
     * @param latNano latitude in nanodegrees
     * @return true if valid
     */
    public static boolean isValidLatitudeNano(long latNano) {
        return latNano >= -90_000_000_000L && latNano <= 90_000_000_000L;
    }

    /**
     * Checks if longitude in nanodegrees is valid.
     *
     * @param lonNano longitude in nanodegrees
     * @return true if valid
     */
    public static boolean isValidLongitudeNano(long lonNano) {
        return lonNano >= -180_000_000_000L && lonNano <= 180_000_000_000L;
    }

    /**
     * Validates coordinates and throws if invalid.
     *
     * @param lat latitude in degrees
     * @param lon longitude in degrees
     * @throws IllegalArgumentException if coordinates are invalid
     */
    public static void validateCoordinates(double lat, double lon) {
        if (!isValidLatitude(lat)) {
            throw new IllegalArgumentException(
                    String.format("Invalid latitude: %f. Must be between -90 and +90.", lat));
        }
        if (!isValidLongitude(lon)) {
            throw new IllegalArgumentException(
                    String.format("Invalid longitude: %f. Must be between -180 and +180.", lon));
        }
    }
}
