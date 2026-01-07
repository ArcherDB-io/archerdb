package com.archerdb.geo;

import java.util.List;

/**
 * Query result with pagination support.
 */
public final class QueryResult {

    private final List<GeoEvent> events;
    private final boolean hasMore;
    private final long cursor;

    public QueryResult(List<GeoEvent> events, boolean hasMore, long cursor) {
        this.events = events;
        this.hasMore = hasMore;
        this.cursor = cursor;
    }

    /**
     * Returns the list of events.
     */
    public List<GeoEvent> getEvents() {
        return events;
    }

    /**
     * Returns true if more results are available beyond the limit.
     */
    public boolean hasMore() {
        return hasMore;
    }

    /**
     * Returns the cursor for pagination (timestamp of last event).
     */
    public long getCursor() {
        return cursor;
    }

    /**
     * Returns the number of events in the result.
     */
    public int size() {
        return events.size();
    }

    /**
     * Returns true if the result is empty.
     */
    public boolean isEmpty() {
        return events.isEmpty();
    }
}
