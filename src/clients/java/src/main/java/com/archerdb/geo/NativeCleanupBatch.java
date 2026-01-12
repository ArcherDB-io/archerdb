package com.archerdb.geo;

import com.archerdb.core.Batch;

/**
 * Native batch class for cleanup_expired requests.
 *
 * <p>
 * Per client-protocol/spec.md cleanup_expired (0x30) request format:
 * <ul>
 * <li>batch_size: u32 - Number of index entries to scan (0 = scan all)</li>
 * <li>reserved: u32 - Reserved for future use</li>
 * </ul>
 *
 * <p>
 * Wire format (8 bytes):
 * <ul>
 * <li>offset 0: batch_size (u32, 4 bytes)</li>
 * <li>offset 4: reserved (u32, 4 bytes)</li>
 * </ul>
 */
public final class NativeCleanupBatch extends Batch {

    interface Struct {
        int SIZE = 8;
        int BatchSize = 0;
        int Reserved = 4;
    }

    public NativeCleanupBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    public int getBatchSize() {
        return getUInt32(at(Struct.BatchSize));
    }

    public void setBatchSize(final int batchSize) {
        putUInt32(at(Struct.BatchSize), batchSize);
    }
}
