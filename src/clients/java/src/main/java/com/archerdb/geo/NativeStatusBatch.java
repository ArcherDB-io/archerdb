package com.archerdb.geo;

import com.archerdb.core.Batch;

/**
 * Native batch class for status requests.
 *
 * Wire format (8 bytes per request): offset 0: reserved (u64, 8 bytes)
 *
 * Response format (64 bytes): offset 0: ram_index_count (u64, 8 bytes) offset 8: ram_index_capacity
 * (u64, 8 bytes) offset 16: ram_index_load_pct (u32, 4 bytes) offset 20: padding (u32, 4 bytes)
 * offset 24: tombstone_count (u64, 8 bytes) offset 32: ttl_expirations (u64, 8 bytes) offset 40:
 * deletion_count (u64, 8 bytes) offset 48: reserved (16 bytes)
 */
public final class NativeStatusBatch extends Batch {

    interface Struct {
        int SIZE = 8;
        int Reserved = 0;
    }

    public NativeStatusBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    public long getReserved() {
        return getUInt64(at(Struct.Reserved));
    }

    public void setReserved(final long reserved) {
        putUInt64(at(Struct.Reserved), reserved);
    }
}
