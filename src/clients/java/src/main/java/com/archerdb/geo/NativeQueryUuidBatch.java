package com.archerdb.geo;

import com.archerdb.core.Batch;
import com.archerdb.core.UInt128;

/**
 * Native batch class for query by UUID requests.
 *
 * Wire format (128 bytes per filter): offset 0: entity_id (UInt128, 16 bytes) offset 16: limit
 * (u32, 4 bytes) offset 20: reserved (108 bytes)
 */
public final class NativeQueryUuidBatch extends Batch {

    interface Struct {
        int SIZE = 128;
        int EntityId = 0;
        int Limit = 16;
        int Reserved = 20;
    }

    public NativeQueryUuidBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    public byte[] getEntityId() {
        return getUInt128(at(Struct.EntityId));
    }

    public long getEntityId(final UInt128 part) {
        return getUInt128(at(Struct.EntityId), part);
    }

    public void setEntityId(final byte[] entityId) {
        putUInt128(at(Struct.EntityId), entityId);
    }

    public void setEntityId(final long leastSignificant, final long mostSignificant) {
        putUInt128(at(Struct.EntityId), leastSignificant, mostSignificant);
    }

    public int getLimit() {
        return getUInt32(at(Struct.Limit));
    }

    public void setLimit(final int limit) {
        putUInt32(at(Struct.Limit), limit);
    }
}
