package com.archerdb.geo;

import java.util.List;

/**
 * Query result with pagination and multi-region metadata support.
 *
 * <p>
 * For multi-region deployments, query results include {@link ResponseMetadata} that indicates which
 * region served the request and any staleness information.
 */
public final class QueryResult {

    private final List<GeoEvent> events;
    private final boolean hasMore;
    private final long cursor;
    private final ResponseMetadata metadata;

    /**
     * Creates a query result without metadata (for backwards compatibility).
     */
    public QueryResult(List<GeoEvent> events, boolean hasMore, long cursor) {
        this(events, hasMore, cursor, ResponseMetadata.PRIMARY);
    }

    /**
     * Creates a query result with multi-region metadata.
     *
     * @param events the returned events
     * @param hasMore true if more results are available
     * @param cursor the pagination cursor
     * @param metadata multi-region response metadata
     */
    public QueryResult(List<GeoEvent> events, boolean hasMore, long cursor,
            ResponseMetadata metadata) {
        this.events = events;
        this.hasMore = hasMore;
        this.cursor = cursor;
        this.metadata = metadata != null ? metadata : ResponseMetadata.PRIMARY;
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

    /**
     * Returns the multi-region response metadata.
     *
     * <p>
     * The metadata indicates which region served this query and any staleness information for
     * follower reads.
     */
    public ResponseMetadata getMetadata() {
        return metadata;
    }

    /**
     * Returns the read staleness in nanoseconds (convenience method). Returns 0 for primary region
     * reads.
     */
    public long getReadStalenessNs() {
        return metadata.getReadStalenessNs();
    }

    /**
     * Returns true if this result came from a follower region.
     */
    public boolean isFromFollower() {
        return metadata.isFromFollower();
    }
}
