// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * GeoEvent - 128-byte geospatial event record.
 *
 * <p>
 * Represents a single location update for a moving entity (vehicle, device, person). Coordinates
 * are stored in nanodegrees (10^-9 degrees) for sub-millimeter precision.
 *
 * <p>
 * Example usage:
 *
 * <pre>
 * {
 *     &#64;code
 *     GeoEvent event = new GeoEvent.Builder().setEntityId(UInt128.random()).setLatitude(37.7749)
 *             .setLongitude(-122.4194).setGroupId(fleetId).setTtlSeconds(86400).build();
 * }
 * </pre>
 */
public final class GeoEvent {

    // Primary key fields (stored as lo/hi pairs for wire format efficiency)
    private final long idLo;
    private final long idHi;
    private final long entityIdLo;
    private final long entityIdHi;
    private final long correlationIdLo;
    private final long correlationIdHi;
    private final long userDataLo;
    private final long userDataHi;

    // Coordinates in nanodegrees
    private final long latNano;
    private final long lonNano;

    // Grouping and timing
    private final long groupId;
    private final long timestamp;

    // Physical measurements
    private final int altitudeMm;
    private final int velocityMms;
    private final int ttlSeconds;
    private final int accuracyMm;
    private final short headingCdeg;

    // Status
    private final short flags;

    private GeoEvent(Builder builder) {
        this.idLo = builder.idLo;
        this.idHi = builder.idHi;
        this.entityIdLo = builder.entityIdLo;
        this.entityIdHi = builder.entityIdHi;
        this.correlationIdLo = builder.correlationIdLo;
        this.correlationIdHi = builder.correlationIdHi;
        this.userDataLo = builder.userDataLo;
        this.userDataHi = builder.userDataHi;
        this.latNano = builder.latNano;
        this.lonNano = builder.lonNano;
        this.groupId = builder.groupId;
        this.timestamp = builder.timestamp;
        this.altitudeMm = builder.altitudeMm;
        this.velocityMms = builder.velocityMms;
        this.ttlSeconds = builder.ttlSeconds;
        this.accuracyMm = builder.accuracyMm;
        this.headingCdeg = builder.headingCdeg;
        this.flags = builder.flags;
    }

    // ========== ID Getters ==========

    /**
     * Returns the composite key as UInt128: [S2 Cell ID (upper 64) | Timestamp (lower 64)]. Zero
     * for server-assigned ID.
     */
    public UInt128 getId() {
        return UInt128.of(idLo, idHi);
    }

    /** Returns the low 64 bits of the composite ID. */
    public long getIdLo() {
        return idLo;
    }

    /** Returns the high 64 bits of the composite ID. */
    public long getIdHi() {
        return idHi;
    }

    // ========== Entity ID Getters ==========

    /**
     * Returns the UUID identifying the moving entity.
     */
    public UInt128 getEntityId() {
        return UInt128.of(entityIdLo, entityIdHi);
    }

    /** Returns the low 64 bits of the entity ID. */
    public long getEntityIdLo() {
        return entityIdLo;
    }

    /** Returns the high 64 bits of the entity ID. */
    public long getEntityIdHi() {
        return entityIdHi;
    }

    // ========== Correlation ID Getters ==========

    /**
     * Returns the UUID for trip/session/job correlation.
     */
    public UInt128 getCorrelationId() {
        return UInt128.of(correlationIdLo, correlationIdHi);
    }

    /** Returns the low 64 bits of the correlation ID. */
    public long getCorrelationIdLo() {
        return correlationIdLo;
    }

    /** Returns the high 64 bits of the correlation ID. */
    public long getCorrelationIdHi() {
        return correlationIdHi;
    }

    // ========== User Data Getters ==========

    /**
     * Returns opaque application metadata.
     */
    public UInt128 getUserData() {
        return UInt128.of(userDataLo, userDataHi);
    }

    /** Returns the low 64 bits of user data. */
    public long getUserDataLo() {
        return userDataLo;
    }

    /** Returns the high 64 bits of user data. */
    public long getUserDataHi() {
        return userDataHi;
    }

    // ========== Coordinate Getters ==========

    /**
     * Returns latitude in nanodegrees.
     */
    public long getLatNano() {
        return latNano;
    }

    /**
     * Returns longitude in nanodegrees.
     */
    public long getLonNano() {
        return lonNano;
    }

    /**
     * Returns latitude in degrees.
     */
    public double getLatitude() {
        return CoordinateUtils.nanoToDegrees(latNano);
    }

    /**
     * Returns longitude in degrees.
     */
    public double getLongitude() {
        return CoordinateUtils.nanoToDegrees(lonNano);
    }

    // ========== Group ID Getter ==========

    /**
     * Returns fleet/region grouping identifier.
     */
    public long getGroupId() {
        return groupId;
    }

    // ========== Timestamp Getter ==========

    /**
     * Returns event timestamp in nanoseconds since Unix epoch.
     */
    public long getTimestamp() {
        return timestamp;
    }

    // ========== Physical Measurement Getters ==========

    /**
     * Returns altitude in millimeters above WGS84 ellipsoid.
     */
    public int getAltitudeMm() {
        return altitudeMm;
    }

    /**
     * Returns altitude in meters.
     */
    public double getAltitude() {
        return CoordinateUtils.mmToMeters(altitudeMm);
    }

    /**
     * Returns speed in millimeters per second.
     */
    public int getVelocityMms() {
        return velocityMms;
    }

    /**
     * Returns speed in meters per second.
     */
    public double getVelocity() {
        return CoordinateUtils.mmToMeters(velocityMms);
    }

    /**
     * Returns time-to-live in seconds (0 = never expires).
     */
    public int getTtlSeconds() {
        return ttlSeconds;
    }

    /**
     * Returns GPS accuracy radius in millimeters.
     */
    public int getAccuracyMm() {
        return accuracyMm;
    }

    /**
     * Returns GPS accuracy radius in meters.
     */
    public double getAccuracy() {
        return CoordinateUtils.mmToMeters(accuracyMm);
    }

    /**
     * Returns heading in centidegrees (0-36000, where 0=North, 9000=East).
     */
    public short getHeadingCdeg() {
        return headingCdeg;
    }

    /**
     * Returns heading in degrees (0-360).
     */
    public double getHeading() {
        return CoordinateUtils.centidegreesToHeading(headingCdeg);
    }

    /**
     * Returns packed status flags.
     */
    public short getFlags() {
        return flags;
    }

    /**
     * Returns true if the specified flag is set.
     */
    public boolean hasFlag(GeoEventFlags flag) {
        return (flags & flag.getValue()) != 0;
    }

    @Override
    public String toString() {
        return String.format("GeoEvent{entityId=%s, lat=%.6f, lon=%.6f, timestamp=%d}",
                getEntityId(), getLatitude(), getLongitude(), timestamp);
    }

    /**
     * Builder for creating GeoEvent instances.
     */
    public static class Builder {
        private long idLo = 0;
        private long idHi = 0;
        private long entityIdLo = 0;
        private long entityIdHi = 0;
        private long correlationIdLo = 0;
        private long correlationIdHi = 0;
        private long userDataLo = 0;
        private long userDataHi = 0;
        private long latNano = 0;
        private long lonNano = 0;
        private long groupId = 0;
        private long timestamp = 0;
        private int altitudeMm = 0;
        private int velocityMms = 0;
        private int ttlSeconds = 0;
        private int accuracyMm = 0;
        private short headingCdeg = 0;
        private short flags = 0;

        public Builder() {}

        // ========== ID Setters ==========

        /**
         * Sets the composite ID (usually left as zero for server-assigned).
         */
        public Builder setId(UInt128 id) {
            this.idLo = id.getLo();
            this.idHi = id.getHi();
            return this;
        }

        /**
         * Sets the composite ID from raw lo/hi values (internal use).
         */
        public Builder id(long lo, long hi) {
            this.idLo = lo;
            this.idHi = hi;
            return this;
        }

        // ========== Entity ID Setters ==========

        /**
         * Sets the entity ID (required).
         */
        public Builder setEntityId(UInt128 entityId) {
            this.entityIdLo = entityId.getLo();
            this.entityIdHi = entityId.getHi();
            return this;
        }

        /**
         * Sets the entity ID from raw lo/hi values (internal use).
         */
        public Builder entityId(long lo, long hi) {
            this.entityIdLo = lo;
            this.entityIdHi = hi;
            return this;
        }

        // ========== Correlation ID Setters ==========

        /**
         * Sets the correlation ID.
         */
        public Builder setCorrelationId(UInt128 correlationId) {
            this.correlationIdLo = correlationId.getLo();
            this.correlationIdHi = correlationId.getHi();
            return this;
        }

        /**
         * Sets the correlation ID from raw lo/hi values (internal use).
         */
        public Builder correlationId(long lo, long hi) {
            this.correlationIdLo = lo;
            this.correlationIdHi = hi;
            return this;
        }

        // ========== User Data Setters ==========

        /**
         * Sets user data.
         */
        public Builder setUserData(UInt128 userData) {
            this.userDataLo = userData.getLo();
            this.userDataHi = userData.getHi();
            return this;
        }

        /**
         * Sets user data from raw lo/hi values (internal use).
         */
        public Builder userData(long lo, long hi) {
            this.userDataLo = lo;
            this.userDataHi = hi;
            return this;
        }

        // ========== Coordinate Setters ==========

        /**
         * Sets latitude in nanodegrees.
         */
        public Builder setLatNano(long latNano) {
            this.latNano = latNano;
            return this;
        }

        /**
         * Sets longitude in nanodegrees.
         */
        public Builder setLonNano(long lonNano) {
            this.lonNano = lonNano;
            return this;
        }

        /**
         * Sets latitude in degrees (-90 to +90).
         */
        public Builder setLatitude(double latitude) {
            this.latNano = CoordinateUtils.degreesToNano(latitude);
            return this;
        }

        /**
         * Sets latitude in degrees (alias for internal use).
         */
        public Builder latitude(double latitude) {
            return setLatitude(latitude);
        }

        /**
         * Sets longitude in degrees (-180 to +180).
         */
        public Builder setLongitude(double longitude) {
            this.lonNano = CoordinateUtils.degreesToNano(longitude);
            return this;
        }

        /**
         * Sets longitude in degrees (alias for internal use).
         */
        public Builder longitude(double longitude) {
            return setLongitude(longitude);
        }

        // ========== Group ID Setters ==========

        /**
         * Sets group ID.
         */
        public Builder setGroupId(long groupId) {
            this.groupId = groupId;
            return this;
        }

        /**
         * Sets group ID (alias for internal use).
         */
        public Builder groupId(long groupId) {
            return setGroupId(groupId);
        }

        // ========== Timestamp Setters ==========

        /**
         * Sets timestamp (0 for server-assigned).
         */
        public Builder setTimestamp(long timestamp) {
            this.timestamp = timestamp;
            return this;
        }

        /**
         * Sets timestamp (alias for internal use).
         */
        public Builder timestamp(long timestamp) {
            return setTimestamp(timestamp);
        }

        // ========== Physical Measurement Setters ==========

        /**
         * Sets altitude in millimeters.
         */
        public Builder setAltitudeMm(int altitudeMm) {
            this.altitudeMm = altitudeMm;
            return this;
        }

        /**
         * Sets altitude in millimeters (alias for internal use).
         */
        public Builder altitudeMm(int altitudeMm) {
            return setAltitudeMm(altitudeMm);
        }

        /**
         * Sets altitude in meters.
         */
        public Builder setAltitude(double meters) {
            this.altitudeMm = CoordinateUtils.metersToMm(meters);
            return this;
        }

        /**
         * Sets velocity in millimeters per second.
         */
        public Builder setVelocityMms(int velocityMms) {
            this.velocityMms = velocityMms;
            return this;
        }

        /**
         * Sets velocity in millimeters per second (alias for internal use).
         */
        public Builder velocityMms(int velocityMms) {
            return setVelocityMms(velocityMms);
        }

        /**
         * Sets velocity in meters per second.
         */
        public Builder setVelocity(double mps) {
            this.velocityMms = (int) Math.round(mps * CoordinateUtils.MM_PER_METER);
            return this;
        }

        /**
         * Sets time-to-live in seconds.
         */
        public Builder setTtlSeconds(int ttlSeconds) {
            this.ttlSeconds = ttlSeconds;
            return this;
        }

        /**
         * Sets time-to-live in seconds (alias for internal use).
         */
        public Builder ttlSeconds(int ttlSeconds) {
            return setTtlSeconds(ttlSeconds);
        }

        /**
         * Sets GPS accuracy in millimeters.
         */
        public Builder setAccuracyMm(int accuracyMm) {
            this.accuracyMm = accuracyMm;
            return this;
        }

        /**
         * Sets GPS accuracy in millimeters (alias for internal use).
         */
        public Builder accuracyMm(int accuracyMm) {
            return setAccuracyMm(accuracyMm);
        }

        /**
         * Sets GPS accuracy in meters.
         */
        public Builder setAccuracy(double meters) {
            this.accuracyMm = (int) Math.round(meters * CoordinateUtils.MM_PER_METER);
            return this;
        }

        /**
         * Sets heading in centidegrees.
         */
        public Builder setHeadingCdeg(short headingCdeg) {
            this.headingCdeg = headingCdeg;
            return this;
        }

        /**
         * Sets heading in centidegrees (alias for internal use).
         */
        public Builder headingCdeg(short headingCdeg) {
            return setHeadingCdeg(headingCdeg);
        }

        /**
         * Sets heading in degrees (0-360).
         */
        public Builder setHeading(double degrees) {
            this.headingCdeg = CoordinateUtils.headingToCentidegrees(degrees);
            return this;
        }

        /**
         * Sets flags.
         */
        public Builder setFlags(short flags) {
            this.flags = flags;
            return this;
        }

        /**
         * Sets flags (alias for internal use).
         */
        public Builder flags(short flags) {
            return setFlags(flags);
        }

        /**
         * Sets a specific flag.
         */
        public Builder setFlag(GeoEventFlags flag) {
            this.flags |= flag.getValue();
            return this;
        }

        /**
         * Builds the GeoEvent instance.
         *
         * @throws IllegalArgumentException if entity_id is zero or coordinates are invalid
         */
        public GeoEvent build() {
            if (entityIdLo == 0 && entityIdHi == 0) {
                throw new IllegalArgumentException("entity_id must not be zero");
            }

            if (!CoordinateUtils.isValidLatitudeNano(latNano)) {
                throw new IllegalArgumentException(
                        String.format("latitude %d out of range [-90e9, +90e9]", latNano));
            }

            if (!CoordinateUtils.isValidLongitudeNano(lonNano)) {
                throw new IllegalArgumentException(
                        String.format("longitude %d out of range [-180e9, +180e9]", lonNano));
            }

            if (headingCdeg < 0 || headingCdeg > 36000) {
                throw new IllegalArgumentException(
                        String.format("heading %d out of range [0, 36000]", headingCdeg));
            }

            return new GeoEvent(this);
        }
    }
}
