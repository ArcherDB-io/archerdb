package com.archerdb.geo;

/**
 * Filter for radius queries. Returns events within a circular region.
 */
public final class QueryRadiusFilter {

    private final long centerLatNano;
    private final long centerLonNano;
    private final int radiusMm;
    private final int limit;
    private final long timestampMin;
    private final long timestampMax;
    private final long groupId;

    private QueryRadiusFilter(Builder builder) {
        this.centerLatNano = builder.centerLatNano;
        this.centerLonNano = builder.centerLonNano;
        this.radiusMm = builder.radiusMm;
        this.limit = builder.limit;
        this.timestampMin = builder.timestampMin;
        this.timestampMax = builder.timestampMax;
        this.groupId = builder.groupId;
    }

    public long getCenterLatNano() {
        return centerLatNano;
    }

    public long getCenterLonNano() {
        return centerLonNano;
    }

    public double getCenterLatitude() {
        return CoordinateUtils.nanoToDegrees(centerLatNano);
    }

    public double getCenterLongitude() {
        return CoordinateUtils.nanoToDegrees(centerLonNano);
    }

    public int getRadiusMm() {
        return radiusMm;
    }

    public double getRadiusMeters() {
        return CoordinateUtils.mmToMeters(radiusMm);
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
     * Builder for creating QueryRadiusFilter instances.
     */
    public static class Builder {
        private long centerLatNano;
        private long centerLonNano;
        private int radiusMm;
        private int limit = 1000;
        private long timestampMin = 0;
        private long timestampMax = 0;
        private long groupId = 0;

        public Builder() {}

        /**
         * Sets center latitude in nanodegrees.
         */
        public Builder setCenterLatNano(long latNano) {
            this.centerLatNano = latNano;
            return this;
        }

        /**
         * Sets center longitude in nanodegrees.
         */
        public Builder setCenterLonNano(long lonNano) {
            this.centerLonNano = lonNano;
            return this;
        }

        /**
         * Sets center latitude in degrees.
         */
        public Builder setCenterLatitude(double lat) {
            this.centerLatNano = CoordinateUtils.degreesToNano(lat);
            return this;
        }

        /**
         * Sets center longitude in degrees.
         */
        public Builder setCenterLongitude(double lon) {
            this.centerLonNano = CoordinateUtils.degreesToNano(lon);
            return this;
        }

        /**
         * Sets radius in millimeters.
         */
        public Builder setRadiusMm(int radiusMm) {
            this.radiusMm = radiusMm;
            return this;
        }

        /**
         * Sets radius in meters.
         */
        public Builder setRadiusMeters(double meters) {
            this.radiusMm = CoordinateUtils.metersToMm(meters);
            return this;
        }

        /**
         * Sets maximum results to return.
         */
        public Builder setLimit(int limit) {
            this.limit = limit;
            return this;
        }

        /**
         * Sets minimum timestamp filter (0 = no filter).
         */
        public Builder setTimestampMin(long timestampMin) {
            this.timestampMin = timestampMin;
            return this;
        }

        /**
         * Sets maximum timestamp filter (0 = no filter).
         */
        public Builder setTimestampMax(long timestampMax) {
            this.timestampMax = timestampMax;
            return this;
        }

        /**
         * Sets group ID filter (zero = no filter).
         */
        public Builder setGroupId(long groupId) {
            this.groupId = groupId;
            return this;
        }

        /**
         * Builds the filter.
         *
         * @throws IllegalArgumentException if coordinates or radius are invalid
         */
        public QueryRadiusFilter build() {
            if (!CoordinateUtils.isValidLatitudeNano(centerLatNano)) {
                throw new IllegalArgumentException("Invalid center latitude");
            }
            if (!CoordinateUtils.isValidLongitudeNano(centerLonNano)) {
                throw new IllegalArgumentException("Invalid center longitude");
            }
            if (radiusMm <= 0) {
                throw new IllegalArgumentException("Radius must be positive");
            }
            if (limit > CoordinateUtils.QUERY_LIMIT_MAX) {
                throw new IllegalArgumentException(String.format("Limit %d exceeds max %d", limit,
                        CoordinateUtils.QUERY_LIMIT_MAX));
            }
            return new QueryRadiusFilter(this);
        }
    }

    /**
     * Creates a radius query filter with user-friendly units.
     *
     * @param latitude center latitude in degrees
     * @param longitude center longitude in degrees
     * @param radiusMeters radius in meters
     * @param limit maximum results
     * @return the filter
     */
    public static QueryRadiusFilter create(double latitude, double longitude, double radiusMeters,
            int limit) {
        return new Builder().setCenterLatitude(latitude).setCenterLongitude(longitude)
                .setRadiusMeters(radiusMeters).setLimit(limit).build();
    }
}
