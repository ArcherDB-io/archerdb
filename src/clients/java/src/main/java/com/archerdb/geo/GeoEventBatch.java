package com.archerdb.geo;

import java.util.ArrayList;
import java.util.List;

/**
 * Batch builder for accumulating events before commit.
 */
public final class GeoEventBatch {

    private final List<GeoEvent> events = new ArrayList<>();
    private final GeoClientImpl client;
    private final boolean upsert;

    GeoEventBatch(GeoClientImpl client, boolean upsert) {
        this.client = client;
        this.upsert = upsert;
    }

    /**
     * Adds a GeoEvent to the batch.
     *
     * @param event the event to add
     * @throws IllegalStateException if batch is full
     */
    public void add(GeoEvent event) {
        if (events.size() >= CoordinateUtils.BATCH_SIZE_MAX) {
            throw new IllegalStateException(
                    String.format("Batch is full (max %d events)", CoordinateUtils.BATCH_SIZE_MAX));
        }
        events.add(event);
    }

    /**
     * Returns the number of events in the batch.
     */
    public int count() {
        return events.size();
    }

    /**
     * Returns true if the batch is full.
     */
    public boolean isFull() {
        return events.size() >= CoordinateUtils.BATCH_SIZE_MAX;
    }

    /**
     * Clears all events from the batch.
     */
    public void clear() {
        events.clear();
    }

    /**
     * Commits the batch to the cluster.
     *
     * @return list of errors (empty if all succeeded)
     */
    public List<InsertGeoEventsError> commit() {
        if (events.isEmpty()) {
            return new ArrayList<>();
        }

        List<InsertGeoEventsError> results;
        if (upsert) {
            results = client.upsertEvents(events);
        } else {
            results = client.insertEvents(events);
        }

        events.clear();
        return results;
    }
}
