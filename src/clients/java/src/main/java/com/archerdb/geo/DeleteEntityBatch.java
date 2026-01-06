package com.archerdb.geo;

import java.util.ArrayList;
import java.util.List;

/**
 * Batch builder for entity deletion.
 */
public final class DeleteEntityBatch {

    private final List<UInt128> entityIds = new ArrayList<>();
    private final GeoClientImpl client;

    DeleteEntityBatch(GeoClientImpl client) {
        this.client = client;
    }

    /**
     * Adds an entity ID for deletion.
     *
     * @param entityId the entity ID to delete
     * @throws IllegalStateException if batch is full
     * @throws IllegalArgumentException if entityId is zero
     */
    public void add(UInt128 entityId) {
        if (entityIds.size() >= CoordinateUtils.BATCH_SIZE_MAX) {
            throw new IllegalStateException(String.format("Batch is full (max %d entities)",
                    CoordinateUtils.BATCH_SIZE_MAX));
        }
        if (entityId.isZero()) {
            throw new IllegalArgumentException("entity_id must not be zero");
        }
        entityIds.add(entityId);
    }

    /**
     * Returns the number of entities in the batch.
     */
    public int count() {
        return entityIds.size();
    }

    /**
     * Clears all entity IDs from the batch.
     */
    public void clear() {
        entityIds.clear();
    }

    /**
     * Commits the delete batch.
     *
     * @return delete result with counts
     */
    public DeleteResult commit() {
        if (entityIds.isEmpty()) {
            return new DeleteResult(0, 0);
        }

        DeleteResult result = client.deleteEntities(entityIds);
        entityIds.clear();
        return result;
    }
}
