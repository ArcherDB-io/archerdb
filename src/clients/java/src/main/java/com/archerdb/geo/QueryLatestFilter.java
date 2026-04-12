// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Filter for query_latest operation.
 */
public final class QueryLatestFilter {

    private final int limit;
    private final long groupId;
    private final long cursorTimestamp;

    public QueryLatestFilter(int limit, long groupId, long cursorTimestamp) {
        this.limit = limit;
        this.groupId = groupId;
        this.cursorTimestamp = cursorTimestamp;
    }

    public QueryLatestFilter(int limit) {
        this(limit, 0, 0);
    }

    public int getLimit() {
        return limit;
    }

    public long getGroupId() {
        return groupId;
    }

    public long getCursorTimestamp() {
        return cursorTimestamp;
    }

    /**
     * Creates a filter for querying the latest events globally.
     */
    public static QueryLatestFilter global(int limit) {
        return new QueryLatestFilter(limit);
    }

    /**
     * Creates a filter for querying the latest events in a group.
     */
    public static QueryLatestFilter forGroup(long groupId, int limit) {
        return new QueryLatestFilter(limit, groupId, 0);
    }

    /**
     * Creates a filter for paginated queries.
     */
    public static QueryLatestFilter withCursor(int limit, long cursorTimestamp) {
        return new QueryLatestFilter(limit, 0, cursorTimestamp);
    }
}
