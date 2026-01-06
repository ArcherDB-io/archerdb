package com.archerdb.geo;

import java.util.ArrayList;
import java.util.List;

/**
 * Filter for polygon queries.
 */
public final class QueryPolygonFilter {

    private final List<PolygonVertex> vertices;
    private final int limit;
    private final long timestampMin;
    private final long timestampMax;
    private final long groupId;

    private QueryPolygonFilter(Builder builder) {
        this.vertices = new ArrayList<>(builder.vertices);
        this.limit = builder.limit;
        this.timestampMin = builder.timestampMin;
        this.timestampMax = builder.timestampMax;
        this.groupId = builder.groupId;
    }

    public List<PolygonVertex> getVertices() {
        return vertices;
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
     * Builder for creating QueryPolygonFilter instances.
     */
    public static class Builder {
        private final List<PolygonVertex> vertices = new ArrayList<>();
        private int limit = 1000;
        private long timestampMin = 0;
        private long timestampMax = 0;
        private long groupId = 0;

        public Builder() {}

        /**
         * Adds a vertex in degrees.
         */
        public Builder addVertex(double latitude, double longitude) {
            vertices.add(new PolygonVertex(CoordinateUtils.degreesToNano(latitude),
                    CoordinateUtils.degreesToNano(longitude)));
            return this;
        }

        /**
         * Adds a vertex in nanodegrees.
         */
        public Builder addVertexNano(long latNano, long lonNano) {
            vertices.add(new PolygonVertex(latNano, lonNano));
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
            if (vertices.size() < 3) {
                throw new IllegalArgumentException(String
                        .format("Polygon must have at least 3 vertices, got %d", vertices.size()));
            }
            if (vertices.size() > CoordinateUtils.POLYGON_VERTICES_MAX) {
                throw new IllegalArgumentException(
                        String.format("Polygon exceeds maximum %d vertices",
                                CoordinateUtils.POLYGON_VERTICES_MAX));
            }
            return new QueryPolygonFilter(this);
        }
    }
}
