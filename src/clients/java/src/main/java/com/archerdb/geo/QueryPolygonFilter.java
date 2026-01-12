package com.archerdb.geo;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Filter for polygon queries.
 *
 * <p>
 * A polygon can optionally have holes (exclusion zones). The outer boundary should be in
 * counter-clockwise (CCW) winding order, while holes should be in clockwise (CW) winding order.
 */
public final class QueryPolygonFilter {

    private final List<PolygonVertex> vertices;
    private final List<PolygonHole> holes;
    private final int limit;
    private final long timestampMin;
    private final long timestampMax;
    private final long groupId;

    private QueryPolygonFilter(Builder builder) {
        this.vertices = new ArrayList<>(builder.vertices);
        this.holes = new ArrayList<>(builder.holes);
        this.limit = builder.limit;
        this.timestampMin = builder.timestampMin;
        this.timestampMax = builder.timestampMax;
        this.groupId = builder.groupId;
    }

    public List<PolygonVertex> getVertices() {
        return Collections.unmodifiableList(vertices);
    }

    public List<PolygonHole> getHoles() {
        return Collections.unmodifiableList(holes);
    }

    public int getLimit() {
        return limit;
    }

    public long getTimestampMin() {
        return timestampMin;
    }

    public long getTimestampMax() {
        return timestampMax;
    }

    public long getGroupId() {
        return groupId;
    }

    /**
     * A polygon vertex (lat/lon pair).
     */
    public static final class PolygonVertex {
        private final long latNano;
        private final long lonNano;

        public PolygonVertex(long latNano, long lonNano) {
            this.latNano = latNano;
            this.lonNano = lonNano;
        }

        public long getLatNano() {
            return latNano;
        }

        public long getLonNano() {
            return lonNano;
        }

        public double getLatitude() {
            return CoordinateUtils.nanoToDegrees(latNano);
        }

        public double getLongitude() {
            return CoordinateUtils.nanoToDegrees(lonNano);
        }
    }

    /**
     * A polygon hole (exclusion zone within the outer boundary).
     *
     * <p>
     * A hole is defined by a list of vertices in clockwise winding order. Points inside a hole are
     * excluded from query results.
     */
    public static final class PolygonHole {
        private final List<PolygonVertex> vertices;

        public PolygonHole(List<PolygonVertex> vertices) {
            this.vertices = new ArrayList<>(vertices);
        }

        public List<PolygonVertex> getVertices() {
            return Collections.unmodifiableList(vertices);
        }
    }

    /**
     * Builder for creating QueryPolygonFilter instances.
     */
    public static class Builder {
        private final List<PolygonVertex> vertices = new ArrayList<>();
        private final List<PolygonHole> holes = new ArrayList<>();
        private int limit = 1000;
        private long timestampMin = 0;
        private long timestampMax = 0;
        private long groupId = 0;

        // Current hole being built (null when not building a hole)
        private List<PolygonVertex> currentHoleVertices = null;

        public Builder() {}

        /**
         * Adds a vertex to the outer boundary in degrees.
         */
        public Builder addVertex(double latitude, double longitude) {
            vertices.add(new PolygonVertex(CoordinateUtils.degreesToNano(latitude),
                    CoordinateUtils.degreesToNano(longitude)));
            return this;
        }

        /**
         * Adds a vertex to the outer boundary in nanodegrees.
         */
        public Builder addVertexNano(long latNano, long lonNano) {
            vertices.add(new PolygonVertex(latNano, lonNano));
            return this;
        }

        /**
         * Starts building a new hole. Call addHoleVertex() to add vertices, then finishHole() to
         * complete it.
         */
        public Builder startHole() {
            if (currentHoleVertices != null) {
                throw new IllegalStateException(
                        "Already building a hole. Call finishHole() first.");
            }
            currentHoleVertices = new ArrayList<>();
            return this;
        }

        /**
         * Adds a vertex to the current hole in degrees.
         */
        public Builder addHoleVertex(double latitude, double longitude) {
            if (currentHoleVertices == null) {
                throw new IllegalStateException("Not building a hole. Call startHole() first.");
            }
            currentHoleVertices.add(new PolygonVertex(CoordinateUtils.degreesToNano(latitude),
                    CoordinateUtils.degreesToNano(longitude)));
            return this;
        }

        /**
         * Adds a vertex to the current hole in nanodegrees.
         */
        public Builder addHoleVertexNano(long latNano, long lonNano) {
            if (currentHoleVertices == null) {
                throw new IllegalStateException("Not building a hole. Call startHole() first.");
            }
            currentHoleVertices.add(new PolygonVertex(latNano, lonNano));
            return this;
        }

        /**
         * Finishes building the current hole.
         */
        public Builder finishHole() {
            if (currentHoleVertices == null) {
                throw new IllegalStateException("Not building a hole. Call startHole() first.");
            }
            if (currentHoleVertices.size() < CoordinateUtils.POLYGON_HOLE_VERTICES_MIN) {
                throw new IllegalArgumentException(String.format(
                        "Hole must have at least %d vertices, got %d",
                        CoordinateUtils.POLYGON_HOLE_VERTICES_MIN, currentHoleVertices.size()));
            }
            holes.add(new PolygonHole(currentHoleVertices));
            currentHoleVertices = null;
            return this;
        }

        /**
         * Adds a complete hole from a list of vertices in degrees. Each vertex is a double[] with
         * [latitude, longitude].
         */
        public Builder addHole(double[][] holeVertices) {
            if (holeVertices.length < CoordinateUtils.POLYGON_HOLE_VERTICES_MIN) {
                throw new IllegalArgumentException(
                        String.format("Hole must have at least %d vertices, got %d",
                                CoordinateUtils.POLYGON_HOLE_VERTICES_MIN, holeVertices.length));
            }
            List<PolygonVertex> verts = new ArrayList<>();
            for (double[] v : holeVertices) {
                if (v.length != 2) {
                    throw new IllegalArgumentException(
                            "Each vertex must have 2 elements [lat, lon]");
                }
                verts.add(new PolygonVertex(CoordinateUtils.degreesToNano(v[0]),
                        CoordinateUtils.degreesToNano(v[1])));
            }
            holes.add(new PolygonHole(verts));
            return this;
        }

        public Builder setLimit(int limit) {
            this.limit = limit;
            return this;
        }

        public Builder setTimestampMin(long timestampMin) {
            this.timestampMin = timestampMin;
            return this;
        }

        public Builder setTimestampMax(long timestampMax) {
            this.timestampMax = timestampMax;
            return this;
        }

        public Builder setGroupId(long groupId) {
            this.groupId = groupId;
            return this;
        }

        public QueryPolygonFilter build() {
            if (currentHoleVertices != null) {
                throw new IllegalStateException("Unfinished hole. Call finishHole() first.");
            }
            if (vertices.size() < 3) {
                throw new IllegalArgumentException(String
                        .format("Polygon must have at least 3 vertices, got %d", vertices.size()));
            }
            if (vertices.size() > CoordinateUtils.POLYGON_VERTICES_MAX) {
                throw new IllegalArgumentException(
                        String.format("Polygon exceeds maximum %d vertices",
                                CoordinateUtils.POLYGON_VERTICES_MAX));
            }
            if (holes.size() > CoordinateUtils.POLYGON_HOLES_MAX) {
                throw new IllegalArgumentException(
                        String.format("Too many holes: %d exceeds maximum %d", holes.size(),
                                CoordinateUtils.POLYGON_HOLES_MAX));
            }
            return new QueryPolygonFilter(this);
        }
    }
}
