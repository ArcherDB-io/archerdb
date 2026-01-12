package com.archerdb.geo;

import com.archerdb.core.Batch;
import com.archerdb.core.UInt128;

/**
 * Native batch class for delete entity requests.
 *
 * Wire format (16 bytes per entity): offset 0: entity_id (UInt128, 16 bytes)
 */
public final class NativeDeleteBatch extends Batch {

    interface Struct {
        int SIZE = 16;
        int EntityId = 0;
    }

    public NativeDeleteBatch(final int capacity) {
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
}
