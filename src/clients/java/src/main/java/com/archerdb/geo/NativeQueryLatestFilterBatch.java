// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import com.archerdb.core.Batch;

// Uses Batch for native communication

/**
 * Native batch class for QueryLatestFilter wire format.
 *
 * Wire format (128 bytes per filter): offset 0: limit (u32, 4 bytes) offset 4: reserved_align (u32,
 * 4 bytes) offset 8: group_id (u64, 8 bytes) offset 16: cursor_timestamp (u64, 8 bytes) offset 24:
 * reserved (104 bytes)
 */
public final class NativeQueryLatestFilterBatch extends Batch {

    interface Struct {
        int SIZE = 128;

        int Limit = 0;
        int ReservedAlign = 4;
        int GroupId = 8;
        int CursorTimestamp = 16;
        int Reserved = 24;
    }

    public NativeQueryLatestFilterBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    public int getLimit() {
        return getUInt32(at(Struct.Limit));
    }

    public void setLimit(final int limit) {
        putUInt32(at(Struct.Limit), limit);
    }

    public long getGroupId() {
        return getUInt64(at(Struct.GroupId));
    }

    public void setGroupId(final long groupId) {
        putUInt64(at(Struct.GroupId), groupId);
    }

    public long getCursorTimestamp() {
        return getUInt64(at(Struct.CursorTimestamp));
    }

    public void setCursorTimestamp(final long cursorTimestamp) {
        putUInt64(at(Struct.CursorTimestamp), cursorTimestamp);
    }
}
