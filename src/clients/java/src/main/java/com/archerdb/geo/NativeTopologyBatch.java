package com.archerdb.geo;

import com.archerdb.core.Batch;

/**
 * Native batch class for topology requests.
 *
 * Wire format (8 bytes per request): offset 0: reserved (u64, 8 bytes)
 */
public final class NativeTopologyBatch extends Batch {

    interface Struct {
        int SIZE = 8;
        int Reserved = 0;
    }

    public NativeTopologyBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    public long getReserved() {
        return getUInt64(at(Struct.Reserved));
    }

    public void setReserved(final long reserved) {
        putUInt64(at(Struct.Reserved), reserved);
    }
}
