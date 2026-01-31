package com.archerdb.geo;

import com.archerdb.core.Batch;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.List;

/**
 * Native batch class for polygon query requests.
 *
 * <p>
 * Variable-length wire format: Header (128 bytes): offset 0: vertex_count (u32, 4 bytes) offset 4:
 * hole_count (u32, 4 bytes) offset 8: limit (u32, 4 bytes) offset 12: _reserved_align (u32, 4
 * bytes) offset 16: timestamp_min (u64, 8 bytes) offset 24: timestamp_max (u64, 8 bytes) offset 32:
 * group_id (u64, 8 bytes) offset 40: reserved (88 bytes)
 *
 * <p>
 * Followed by: - Outer ring vertices (vertex_count * 16 bytes): lat_nano (i64), lon_nano (i64) -
 * Hole descriptors (hole_count * 8 bytes): hole_vertex_count (u32), reserved (u32) - Hole vertices
 * (sum of hole vertex counts * 16 bytes): lat_nano (i64), lon_nano (i64)
 *
 * <p>
 * This follows the same pattern as NativeQueryUuidBatchRequest - builds the buffer upfront and
 * passes it to the Batch constructor.
 */
final class NativeQueryPolygonBatch extends Batch {

    private static final int HEADER_SIZE = 128;
    private static final int VERTEX_SIZE = 16;
    private static final int HOLE_DESCRIPTOR_SIZE = 8;

    private NativeQueryPolygonBatch(ByteBuffer buffer) {
        // Use ELEMENT_SIZE = 1 for variable-size polygon buffers (header + variable vertices)
        // This prevents assertion failure in Batch constructor (bufferLen % ELEMENT_SIZE must be 0)
        super(buffer, 1);
    }

    /**
     * Creates a polygon batch from a QueryPolygonFilter.
     */
    static NativeQueryPolygonBatch create(QueryPolygonFilter filter) {
        List<QueryPolygonFilter.PolygonVertex> vertices = filter.getVertices();
        List<QueryPolygonFilter.PolygonHole> holes = filter.getHoles();

        // Calculate sizes
        int vertexCount = vertices.size();
        int holeCount = holes.size();
        int outerVerticesSize = vertexCount * VERTEX_SIZE;
        int holeDescriptorsSize = holeCount * HOLE_DESCRIPTOR_SIZE;

        int totalHoleVertices = 0;
        for (QueryPolygonFilter.PolygonHole hole : holes) {
            totalHoleVertices += hole.getVertices().size();
        }
        int holeVerticesSize = totalHoleVertices * VERTEX_SIZE;

        int totalSize = HEADER_SIZE + outerVerticesSize + holeDescriptorsSize + holeVerticesSize;

        // Build buffer
        ByteBuffer buffer = ByteBuffer.allocateDirect(totalSize).order(ByteOrder.LITTLE_ENDIAN);

        // Write header (128 bytes)
        buffer.putInt(vertexCount); // offset 0: vertex_count
        buffer.putInt(holeCount); // offset 4: hole_count
        buffer.putInt(filter.getLimit()); // offset 8: limit
        buffer.putInt(0); // offset 12: _reserved_align
        buffer.putLong(filter.getTimestampMin()); // offset 16: timestamp_min
        buffer.putLong(filter.getTimestampMax()); // offset 24: timestamp_max
        buffer.putLong(filter.getGroupId()); // offset 32: group_id
        // offset 40-127: reserved (88 bytes) - already zeroed by allocateDirect

        // Skip to end of header
        buffer.position(HEADER_SIZE);

        // Write outer ring vertices
        for (QueryPolygonFilter.PolygonVertex v : vertices) {
            buffer.putLong(v.getLatNano());
            buffer.putLong(v.getLonNano());
        }

        // Write hole descriptors
        for (QueryPolygonFilter.PolygonHole hole : holes) {
            buffer.putInt(hole.getVertices().size()); // hole vertex count
            buffer.putInt(0); // reserved
        }

        // Write hole vertices
        for (QueryPolygonFilter.PolygonHole hole : holes) {
            for (QueryPolygonFilter.PolygonVertex v : hole.getVertices()) {
                buffer.putLong(v.getLatNano());
                buffer.putLong(v.getLonNano());
            }
        }

        // Reset buffer position for sending
        buffer.position(0);

        return new NativeQueryPolygonBatch(buffer);
    }
}
