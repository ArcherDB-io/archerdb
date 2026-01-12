package com.archerdb.geo;

import com.archerdb.core.Batch;

/**
 * Native batch class for radius query requests.
 *
 * Wire format (128 bytes per filter): offset 0: center_lat_nano (i64, 8 bytes) offset 8:
 * center_lon_nano (i64, 8 bytes) offset 16: radius_mm (u32, 4 bytes) offset 20: limit (u32, 4
 * bytes) offset 24: timestamp_min (u64, 8 bytes) offset 32: timestamp_max (u64, 8 bytes) offset 40:
 * group_id (u64, 8 bytes) offset 48: reserved (80 bytes)
 */
public final class NativeQueryRadiusBatch extends Batch {

    interface Struct {
        int SIZE = 128;
        int CenterLatNano = 0;
        int CenterLonNano = 8;
        int RadiusMm = 16;
        int Limit = 20;
        int TimestampMin = 24;
        int TimestampMax = 32;
        int GroupId = 40;
        int Reserved = 48;
    }

    public NativeQueryRadiusBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    public long getCenterLatNano() {
        return getUInt64(at(Struct.CenterLatNano));
    }

    public void setCenterLatNano(final long latNano) {
        putUInt64(at(Struct.CenterLatNano), latNano);
    }

    public long getCenterLonNano() {
        return getUInt64(at(Struct.CenterLonNano));
    }

    public void setCenterLonNano(final long lonNano) {
        putUInt64(at(Struct.CenterLonNano), lonNano);
    }

    public int getRadiusMm() {
        return getUInt32(at(Struct.RadiusMm));
    }

    public void setRadiusMm(final int radiusMm) {
        putUInt32(at(Struct.RadiusMm), radiusMm);
    }

    public int getLimit() {
        return getUInt32(at(Struct.Limit));
    }

    public void setLimit(final int limit) {
        putUInt32(at(Struct.Limit), limit);
    }

    public long getTimestampMin() {
        return getUInt64(at(Struct.TimestampMin));
    }

    public void setTimestampMin(final long timestampMin) {
        putUInt64(at(Struct.TimestampMin), timestampMin);
    }

    public long getTimestampMax() {
        return getUInt64(at(Struct.TimestampMax));
    }

    public void setTimestampMax(final long timestampMax) {
        putUInt64(at(Struct.TimestampMax), timestampMax);
    }

    public long getGroupId() {
        return getUInt64(at(Struct.GroupId));
    }

    public void setGroupId(final long groupId) {
        putUInt64(at(Struct.GroupId), groupId);
    }
}
