package com.archerdb.geo;

import com.tigerbeetle.Batch;
import java.nio.ByteBuffer;

// Internal batch methods use the TigerBeetle UInt128 enum for accessing lo/hi parts

/**
 * Native batch class for GeoEvent wire format. Extends TigerBeetle's Batch to use ByteBuffer for
 * zero-copy native communication.
 *
 * Wire format (128 bytes per GeoEvent): offset 0: id (Uint128, 16 bytes) offset 16: entity_id
 * (Uint128, 16 bytes) offset 32: correlation_id (Uint128, 16 bytes) offset 48: user_data (Uint128,
 * 16 bytes) offset 64: lat_nano (i64, 8 bytes) offset 72: lon_nano (i64, 8 bytes) offset 80:
 * group_id (u64, 8 bytes) offset 88: timestamp (u64, 8 bytes) offset 96: altitude_mm (i32, 4 bytes)
 * offset 100: velocity_mms (i32, 4 bytes) offset 104: ttl_seconds (u32, 4 bytes) offset 108:
 * accuracy_mm (u32, 4 bytes) offset 112: heading_cdeg (u16, 2 bytes) offset 114: flags (u16, 2
 * bytes) offset 116: reserved (12 bytes)
 */
public final class NativeGeoEventBatch extends Batch {

    interface Struct {
        int SIZE = 128;

        int Id = 0;
        int EntityId = 16;
        int CorrelationId = 32;
        int UserData = 48;
        int LatNano = 64;
        int LonNano = 72;
        int GroupId = 80;
        int Timestamp = 88;
        int AltitudeMm = 96;
        int VelocityMms = 100;
        int TtlSeconds = 104;
        int AccuracyMm = 108;
        int HeadingCdeg = 112;
        int Flags = 114;
        int Reserved = 116;
    }

    /**
     * Creates an empty batch with the desired maximum capacity.
     *
     * @param capacity the maximum capacity
     * @throws IllegalArgumentException if capacity is negative
     */
    public NativeGeoEventBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    NativeGeoEventBatch(final ByteBuffer buffer) {
        super(buffer, Struct.SIZE);
    }

    // ========== ID (composite S2 + timestamp) ==========

    public byte[] getId() {
        return getUInt128(at(Struct.Id));
    }

    public long getId(final com.tigerbeetle.UInt128 part) {
        return getUInt128(at(Struct.Id), part);
    }

    public void setId(final byte[] id) {
        putUInt128(at(Struct.Id), id);
    }

    public void setId(final long leastSignificant, final long mostSignificant) {
        putUInt128(at(Struct.Id), leastSignificant, mostSignificant);
    }

    // ========== Entity ID ==========

    public byte[] getEntityId() {
        return getUInt128(at(Struct.EntityId));
    }

    public long getEntityId(final com.tigerbeetle.UInt128 part) {
        return getUInt128(at(Struct.EntityId), part);
    }

    public void setEntityId(final byte[] entityId) {
        putUInt128(at(Struct.EntityId), entityId);
    }

    public void setEntityId(final long leastSignificant, final long mostSignificant) {
        putUInt128(at(Struct.EntityId), leastSignificant, mostSignificant);
    }

    // ========== Correlation ID ==========

    public byte[] getCorrelationId() {
        return getUInt128(at(Struct.CorrelationId));
    }

    public void setCorrelationId(final byte[] correlationId) {
        putUInt128(at(Struct.CorrelationId), correlationId);
    }

    public void setCorrelationId(final long leastSignificant, final long mostSignificant) {
        putUInt128(at(Struct.CorrelationId), leastSignificant, mostSignificant);
    }

    // ========== User Data ==========

    public byte[] getUserData() {
        return getUInt128(at(Struct.UserData));
    }

    public void setUserData(final byte[] userData) {
        putUInt128(at(Struct.UserData), userData);
    }

    public void setUserData(final long leastSignificant, final long mostSignificant) {
        putUInt128(at(Struct.UserData), leastSignificant, mostSignificant);
    }

    // ========== Latitude (nano-degrees) ==========

    public long getLatNano() {
        return getUInt64(at(Struct.LatNano));
    }

    public void setLatNano(final long latNano) {
        putUInt64(at(Struct.LatNano), latNano);
    }

    // ========== Longitude (nano-degrees) ==========

    public long getLonNano() {
        return getUInt64(at(Struct.LonNano));
    }

    public void setLonNano(final long lonNano) {
        putUInt64(at(Struct.LonNano), lonNano);
    }

    // ========== Group ID ==========

    public long getGroupId() {
        return getUInt64(at(Struct.GroupId));
    }

    public void setGroupId(final long groupId) {
        putUInt64(at(Struct.GroupId), groupId);
    }

    // ========== Timestamp ==========

    public long getTimestamp() {
        return getUInt64(at(Struct.Timestamp));
    }

    public void setTimestamp(final long timestamp) {
        putUInt64(at(Struct.Timestamp), timestamp);
    }

    // ========== Altitude (millimeters) ==========

    public int getAltitudeMm() {
        return getUInt32(at(Struct.AltitudeMm));
    }

    public void setAltitudeMm(final int altitudeMm) {
        putUInt32(at(Struct.AltitudeMm), altitudeMm);
    }

    // ========== Velocity (mm/s) ==========

    public int getVelocityMms() {
        return getUInt32(at(Struct.VelocityMms));
    }

    public void setVelocityMms(final int velocityMms) {
        putUInt32(at(Struct.VelocityMms), velocityMms);
    }

    // ========== TTL (seconds) ==========

    public int getTtlSeconds() {
        return getUInt32(at(Struct.TtlSeconds));
    }

    public void setTtlSeconds(final int ttlSeconds) {
        putUInt32(at(Struct.TtlSeconds), ttlSeconds);
    }

    // ========== Accuracy (millimeters) ==========

    public int getAccuracyMm() {
        return getUInt32(at(Struct.AccuracyMm));
    }

    public void setAccuracyMm(final int accuracyMm) {
        putUInt32(at(Struct.AccuracyMm), accuracyMm);
    }

    // ========== Heading (centi-degrees) ==========

    public int getHeadingCdeg() {
        return getUInt16(at(Struct.HeadingCdeg));
    }

    public void setHeadingCdeg(final int headingCdeg) {
        putUInt16(at(Struct.HeadingCdeg), headingCdeg);
    }

    // ========== Flags ==========

    public int getFlags() {
        return getUInt16(at(Struct.Flags));
    }

    public void setFlags(final int flags) {
        putUInt16(at(Struct.Flags), flags);
    }

    // ========== Helper: Convert to high-level GeoEvent ==========

    /**
     * Creates a GeoEvent from the current position in the batch.
     */
    public GeoEvent toGeoEvent() {
        return new GeoEvent.Builder()
                .id(getId(com.tigerbeetle.UInt128.LeastSignificant),
                        getId(com.tigerbeetle.UInt128.MostSignificant))
                .entityId(getEntityId(com.tigerbeetle.UInt128.LeastSignificant),
                        getEntityId(com.tigerbeetle.UInt128.MostSignificant))
                .latitude(CoordinateUtils.nanoToDegrees(getLatNano()))
                .longitude(CoordinateUtils.nanoToDegrees(getLonNano())).groupId(getGroupId())
                .timestamp(getTimestamp()).altitudeMm(getAltitudeMm()).velocityMms(getVelocityMms())
                .ttlSeconds(getTtlSeconds()).accuracyMm(getAccuracyMm())
                .headingCdeg((short) getHeadingCdeg()).flags((short) getFlags()).build();
    }

    /**
     * Sets the current position from a high-level GeoEvent.
     */
    public void fromGeoEvent(final GeoEvent event) {
        setEntityId(event.getEntityIdLo(), event.getEntityIdHi());
        setLatNano(event.getLatNano());
        setLonNano(event.getLonNano());
        setGroupId(event.getGroupId());
        setTimestamp(event.getTimestamp());
        setAltitudeMm(event.getAltitudeMm());
        setVelocityMms(event.getVelocityMms());
        setTtlSeconds(event.getTtlSeconds());
        setAccuracyMm(event.getAccuracyMm());
        setHeadingCdeg(event.getHeadingCdeg());
        setFlags(event.getFlags());
        // ID will be computed by the server if not set
    }
}
