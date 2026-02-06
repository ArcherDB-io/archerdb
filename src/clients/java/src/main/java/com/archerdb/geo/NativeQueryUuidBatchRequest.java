package com.archerdb.geo;

import com.archerdb.core.Batch;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.List;

/**
 * Native request buffer for query_uuid_batch.
 *
 * Wire format: [count: u32][reserved: u32][entity_ids: u128[]]
 */
final class NativeQueryUuidBatchRequest extends Batch {

    private static final int HEADER_SIZE = 16;
    private static final int ENTITY_ID_SIZE = 16;

    NativeQueryUuidBatchRequest(List<UInt128> entityIds) {
        super(buildBuffer(entityIds), 1);
    }

    private static ByteBuffer buildBuffer(List<UInt128> entityIds) {
        int count = entityIds.size();
        int size = HEADER_SIZE + count * ENTITY_ID_SIZE;
        ByteBuffer buffer = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN);
        buffer.putInt(count);
        buffer.putInt(0);
        buffer.putLong(0);
        for (UInt128 entityId : entityIds) {
            buffer.putLong(entityId.getLo());
            buffer.putLong(entityId.getHi());
        }
        buffer.position(0);
        return buffer;
    }
}
