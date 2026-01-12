package com.archerdb.geo;

/**
 * Exception for validation errors (invalid inputs).
 *
 * <p>
 * Per client-sdk/spec.md and error-codes/spec.md, validation errors include:
 * <ul>
 * <li>InvalidCoordinates - Lat/lon out of range (code 100)</li>
 * <li>InvalidPolygon - Polygon validation failure (code 108)</li>
 * <li>PolygonSelfIntersecting - Polygon edges cross (code 109)</li>
 * <li>InvalidBatchSize - Batch exceeds limits (code 104)</li>
 * <li>InvalidEntityId - Entity ID malformed (code 103)</li>
 * <li>InvalidRadius - Radius parameter invalid (code 107)</li>
 * </ul>
 *
 * <p>
 * Validation errors are NOT retryable - they indicate client bugs that must be fixed before
 * retrying.
 */
public class ValidationException extends ArcherDBException {

    private static final long serialVersionUID = 1L;

    // Validation error codes (100-199)
    public static final int INVALID_COORDINATES = 100;
    public static final int TTL_OVERFLOW = 101;
    public static final int INVALID_TTL = 102;
    public static final int INVALID_ENTITY_ID = 103;
    public static final int INVALID_BATCH_SIZE = 104;
    public static final int INVALID_S2_CELL = 106;
    public static final int INVALID_RADIUS = 107;
    public static final int INVALID_POLYGON = 108;
    public static final int POLYGON_SELF_INTERSECTING = 109;
    public static final int RADIUS_ZERO = 110;
    public static final int POLYGON_TOO_LARGE = 111;
    public static final int POLYGON_DEGENERATE = 112;
    public static final int POLYGON_EMPTY = 113;
    public static final int COORDINATE_MISMATCH = 114;
    public static final int TIMESTAMP_IN_FUTURE = 115;
    public static final int TIMESTAMP_TOO_OLD = 116;
    public static final int TOO_MANY_HOLES = 117;
    public static final int HOLE_VERTEX_COUNT_INVALID = 118;
    public static final int HOLE_NOT_CONTAINED = 119;
    public static final int HOLES_OVERLAP = 120;

    /**
     * Creates a validation exception.
     */
    public ValidationException(int errorCode, String message) {
        // Validation errors are NOT retryable
        super(errorCode, message, false);
    }

    /**
     * Creates an invalid coordinates exception.
     */
    public static ValidationException invalidCoordinates(double lat, double lon) {
        return new ValidationException(INVALID_COORDINATES, String.format(
                "Invalid coordinates: lat=%f (valid: -90 to +90), lon=%f (valid: -180 to +180)",
                lat, lon));
    }

    /**
     * Creates an invalid entity ID exception.
     */
    public static ValidationException invalidEntityId(String reason) {
        return new ValidationException(INVALID_ENTITY_ID, "Invalid entity ID: " + reason);
    }

    /**
     * Creates an invalid batch size exception.
     */
    public static ValidationException invalidBatchSize(int size, int max) {
        return new ValidationException(INVALID_BATCH_SIZE,
                String.format("Batch size %d exceeds maximum %d", size, max));
    }

    /**
     * Creates an invalid radius exception.
     */
    public static ValidationException invalidRadius(double radiusMeters, double maxMeters) {
        return new ValidationException(INVALID_RADIUS, String
                .format("Radius %f meters exceeds maximum %f meters", radiusMeters, maxMeters));
    }

    /**
     * Creates a radius zero exception.
     */
    public static ValidationException radiusZero() {
        return new ValidationException(RADIUS_ZERO, "Radius query with 0 meters not supported");
    }

    /**
     * Creates an invalid polygon exception.
     */
    public static ValidationException invalidPolygon(String reason) {
        return new ValidationException(INVALID_POLYGON, "Invalid polygon: " + reason);
    }

    /**
     * Creates a polygon self-intersecting exception.
     */
    public static ValidationException polygonSelfIntersecting(int edge1, int edge2) {
        return new ValidationException(POLYGON_SELF_INTERSECTING,
                String.format("Polygon self-intersects: edges %d and %d cross", edge1, edge2));
    }

    /**
     * Creates a polygon too large exception.
     */
    public static ValidationException polygonTooLarge(double widthDegrees) {
        return new ValidationException(POLYGON_TOO_LARGE,
                String.format("Polygon spans %f degrees longitude (max 350)", widthDegrees));
    }

    /**
     * Creates a polygon empty exception.
     */
    public static ValidationException polygonEmpty() {
        return new ValidationException(POLYGON_EMPTY, "Polygon has zero vertices");
    }

    /**
     * Creates a polygon degenerate exception.
     */
    public static ValidationException polygonDegenerate(int vertexCount) {
        return new ValidationException(POLYGON_DEGENERATE,
                String.format("Polygon with %d vertices is degenerate (zero area)", vertexCount));
    }

    /**
     * Creates a too many holes exception.
     */
    public static ValidationException tooManyHoles(int count, int max) {
        return new ValidationException(TOO_MANY_HOLES,
                String.format("Polygon has %d holes (max %d)", count, max));
    }

    /**
     * Creates a hole vertex count invalid exception.
     */
    public static ValidationException holeVertexCountInvalid(int holeIndex, int count, int min) {
        return new ValidationException(HOLE_VERTEX_COUNT_INVALID,
                String.format("Hole %d has %d vertices (min %d)", holeIndex, count, min));
    }

    /**
     * Creates a hole not contained exception.
     */
    public static ValidationException holeNotContained(int holeIndex) {
        return new ValidationException(HOLE_NOT_CONTAINED,
                String.format("Hole %d is not fully contained within polygon", holeIndex));
    }

    /**
     * Creates a holes overlap exception.
     */
    public static ValidationException holesOverlap(int hole1, int hole2) {
        return new ValidationException(HOLES_OVERLAP,
                String.format("Holes %d and %d overlap", hole1, hole2));
    }
}
