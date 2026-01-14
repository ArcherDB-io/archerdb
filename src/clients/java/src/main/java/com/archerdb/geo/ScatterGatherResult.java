package com.archerdb.geo;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Result from a scatter-gather query across multiple shards (F5.1.5 Scatter-Gather Query Support).
 *
 * <p>
 * Contains merged results from all shards, per-shard statistics, and any partial failure
 * information.
 */
public final class ScatterGatherResult {

    private final List<GeoEvent> events;
    private final Map<Integer, Integer> shardResults;
    private final Map<Integer, Throwable> partialFailures;
    private final boolean hasMore;

    /**
     * Creates a new ScatterGatherResult.
     *
     * @param events merged events from all shards
     * @param shardResults per-shard result counts
     * @param partialFailures shards that failed during query
     * @param hasMore true if more results are available
     */
    public ScatterGatherResult(List<GeoEvent> events, Map<Integer, Integer> shardResults,
            Map<Integer, Throwable> partialFailures, boolean hasMore) {
        this.events =
                events != null ? Collections.unmodifiableList(events) : Collections.emptyList();
        this.shardResults = shardResults != null ? Collections.unmodifiableMap(shardResults)
                : Collections.emptyMap();
        this.partialFailures =
                partialFailures != null ? Collections.unmodifiableMap(partialFailures)
                        : Collections.emptyMap();
        this.hasMore = hasMore;
    }

    /**
     * Returns the merged events from all shards (immutable).
     */
    public List<GeoEvent> getEvents() {
        return events;
    }

    /**
     * Returns the per-shard result counts (immutable).
     */
    public Map<Integer, Integer> getShardResults() {
        return shardResults;
    }

    /**
     * Returns shards that failed during query (immutable).
     */
    public Map<Integer, Throwable> getPartialFailures() {
        return partialFailures;
    }

    /**
     * Returns true if more results are available beyond the limit.
     */
    public boolean hasMore() {
        return hasMore;
    }

    /**
     * Returns true if any shards failed.
     */
    public boolean hasPartialFailures() {
        return !partialFailures.isEmpty();
    }

    /**
     * Returns the total number of events.
     */
    public int size() {
        return events.size();
    }

    /**
     * Returns true if no events were returned.
     */
    public boolean isEmpty() {
        return events.isEmpty();
    }

    /**
     * Merges results from multiple shards, deduplicating by entity ID.
     *
     * <p>
     * When duplicate entities are found across shards, the most recent event (highest timestamp) is
     * kept. Results are sorted by timestamp descending.
     *
     * @param results list of query results from each shard
     * @param limit maximum number of events to return (0 = unlimited)
     * @return merged scatter-gather result
     */
    public static ScatterGatherResult merge(List<QueryResult> results, int limit) {
        // Deduplicate by entity ID, keeping most recent
        Map<UInt128, GeoEvent> seen = new HashMap<>();
        Map<Integer, Integer> shardResults = new HashMap<>();
        boolean hasMore = false;

        for (int shardId = 0; shardId < results.size(); shardId++) {
            QueryResult result = results.get(shardId);
            if (result == null) {
                continue;
            }

            shardResults.put(shardId, result.getEvents().size());
            if (result.hasMore()) {
                hasMore = true;
            }

            for (GeoEvent event : result.getEvents()) {
                GeoEvent existing = seen.get(event.getEntityId());
                if (existing == null || event.getTimestamp() > existing.getTimestamp()) {
                    seen.put(event.getEntityId(), event);
                }
            }
        }

        // Sort by timestamp descending
        List<GeoEvent> events = new ArrayList<>(seen.values());
        events.sort(Comparator.comparingLong(GeoEvent::getTimestamp).reversed());

        // Apply limit
        if (limit > 0 && events.size() > limit) {
            events = new ArrayList<>(events.subList(0, limit));
            hasMore = true;
        }

        return new ScatterGatherResult(events, shardResults, null, hasMore);
    }

    @Override
    public String toString() {
        return String.format("ScatterGatherResult{events=%d, shards=%d, failures=%d, hasMore=%b}",
                events.size(), shardResults.size(), partialFailures.size(), hasMore);
    }
}
