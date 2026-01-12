package com.archerdb.geo;

import com.archerdb.core.Batch;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Native batch class for polygon query requests.
 *
 * <p>
 * Variable-length wire format: Header (64 bytes): offset 0: limit (u32, 4 bytes) offset 4:
 * vertex_count (u32, 4 bytes) offset 8: hole_count (u32, 4 bytes) offset 12: padding (u32, 4 bytes)
 * offset 16: timestamp_min (u64, 8 bytes) offset 24: timestamp_max (u64, 8 bytes) offset 32:
 * group_id (u64, 8 bytes) offset 40: reserved (24 bytes)
 *
 * <p>
 * Followed by: Vertices (16 bytes each): lat_nano (i64), lon_nano (i64) Holes: each hole has
 * hole_vertex_count (u32) followed by that many vertices
 *
 * <p>
 * Note: This is a special batch class that handles variable-length data. It extends Batch to
 * integrate with the native bridge but manages its own buffer for the variable-length content.
 */
public final class NativeQueryPolygonBatch extends Batch {

    private static final int HEADER_SIZE = 64;
    private static final int VERTEX_SIZE = 16;

    interface Header {
        int Limit = 0;
        int VertexCount = 4;
        int HoleCount = 8;
        int Padding = 12;
        int TimestampMin = 16;
        int TimestampMax = 24;
        int GroupId = 32;
        int Reserved = 40;
    }

    private final ByteBuffer variableBuffer;
    private int currentVertexOffset;

    /**
     * Creates a polygon batch with the specified capacity.
     *
     * @param capacity number of filters (typically 1)
     * @param maxVertices maximum number of vertices (outer + all holes)
     * @param maxHoles maximum number of holes
     */
    public NativeQueryPolygonBatch(final int capacity, final int maxVertices, final int maxHoles) {
        // Use header size as element size for Batch infrastructure
        super(capacity, HEADER_SIZE);

        // Allocate variable buffer for vertices and holes
        int variableSize = maxVertices * VERTEX_SIZE + maxHoles * 4; // 4 bytes per hole count
        this.variableBuffer = ByteBuffer.allocateDirect(HEADER_SIZE + variableSize)
                .order(ByteOrder.LITTLE_ENDIAN);
        this.currentVertexOffset = HEADER_SIZE;
    }

    public int getLimit() {
        return getUInt32(at(Header.Limit));
    }

    public void setLimit(final int limit) {
        putUInt32(at(Header.Limit), limit);
        variableBuffer.putInt(Header.Limit, limit);
    }

    public int getVertexCount() {
        return getUInt32(at(Header.VertexCount));
    }

    public void setVertexCount(final int vertexCount) {
        putUInt32(at(Header.VertexCount), vertexCount);
        variableBuffer.putInt(Header.VertexCount, vertexCount);
        // Set vertex offset to right after header
        currentVertexOffset = HEADER_SIZE;
    }

    public int getHoleCount() {
        return getUInt32(at(Header.HoleCount));
    }

    public void setHoleCount(final int holeCount) {
        putUInt32(at(Header.HoleCount), holeCount);
        variableBuffer.putInt(Header.HoleCount, holeCount);
    }

    public long getTimestampMin() {
        return getUInt64(at(Header.TimestampMin));
    }

    public void setTimestampMin(final long timestampMin) {
        putUInt64(at(Header.TimestampMin), timestampMin);
        variableBuffer.putLong(Header.TimestampMin, timestampMin);
    }

    public long getTimestampMax() {
        return getUInt64(at(Header.TimestampMax));
    }

    public void setTimestampMax(final long timestampMax) {
        putUInt64(at(Header.TimestampMax), timestampMax);
        variableBuffer.putLong(Header.TimestampMax, timestampMax);
    }

    public long getGroupId() {
        return getUInt64(at(Header.GroupId));
    }

    public void setGroupId(final long groupId) {
        putUInt64(at(Header.GroupId), groupId);
        variableBuffer.putLong(Header.GroupId, groupId);
    }

    /**
     * Adds a vertex to the outer polygon boundary.
     */
    public void addVertex(final long latNano, final long lonNano) {
        variableBuffer.putLong(currentVertexOffset, latNano);
        variableBuffer.putLong(currentVertexOffset + 8, lonNano);
        currentVertexOffset += VERTEX_SIZE;
    }

    /**
     * Starts a new hole with the specified vertex count. Must be followed by that many
     * addHoleVertex() calls.
     */
    public void startHole(final int holeVertexCount) {
        // After all outer vertices, write hole vertex counts then hole vertices
        // For simplicity, holes are written after outer vertices in sequence
        variableBuffer.putInt(currentVertexOffset, holeVertexCount);
        currentVertexOffset += 4;
    }

    /**
     * Adds a vertex to the current hole.
     */
    public void addHoleVertex(final long latNano, final long lonNano) {
        variableBuffer.putLong(currentVertexOffset, latNano);
        variableBuffer.putLong(currentVertexOffset + 8, lonNano);
        currentVertexOffset += VERTEX_SIZE;
    }

    /**
     * Returns the total buffer size including variable-length data.
     */
    public int getTotalSize() {
        return currentVertexOffset;
    }

    /**
     * Returns the variable buffer containing all data.
     */
    public ByteBuffer getVariableBuffer() {
        variableBuffer.position(0).limit(currentVertexOffset);
        return variableBuffer;
    }
}
