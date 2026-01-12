package com.archerdb.geo;

import com.archerdb.core.Batch;

/**
 * Native batch class for ping requests.
 *
 * Wire format (8 bytes per ping): offset 0: ping_data (u64, 8 bytes) - contains "ping" (0x676E6970)
 */
public final class NativePingBatch extends Batch {

    interface Struct {
        int SIZE = 8;
        int PingData = 0;
    }

    public NativePingBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    public long getPingData() {
        return getUInt64(at(Struct.PingData));
    }

    public void setPingData(final long pingData) {
        putUInt64(at(Struct.PingData), pingData);
    }
}
