// ArcherDB Java Client - TTL Clear Response
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025 ArcherDB Developers

package com.archerdb.geo;

/**
 * Response from a TTL clear operation.
 *
 * <p>
 * Wire format: 64 bytes total, must match server's TtlClearResponse.
 *
 * <p>
 * Part of v2.1 Manual TTL Support.
 */
public final class TtlClearResponse {
    private final UInt128 entityId;
    private final int previousTtlSeconds;
    private final TtlOperationResult result;

    /**
     * Creates a new TTL clear response.
     *
     * @param entityId the entity that was modified
     * @param previousTtlSeconds the previous TTL value
     * @param result the operation result
     */
    public TtlClearResponse(UInt128 entityId, int previousTtlSeconds, TtlOperationResult result) {
        this.entityId = entityId;
        this.previousTtlSeconds = previousTtlSeconds;
        this.result = result;
    }

    /**
     * Returns the entity ID that was modified.
     *
     * @return the entity ID
     */
    public UInt128 getEntityId() {
        return entityId;
    }

    /**
     * Returns the previous TTL value in seconds (before clearing).
     *
     * @return the previous TTL
     */
    public int getPreviousTtlSeconds() {
        return previousTtlSeconds;
    }

    /**
     * Returns the operation result.
     *
     * @return the result code
     */
    public TtlOperationResult getResult() {
        return result;
    }

    /**
     * Returns true if the operation succeeded.
     *
     * @return true if successful
     */
    public boolean isSuccess() {
        return result == TtlOperationResult.SUCCESS;
    }

    @Override
    public String toString() {
        return String.format("TtlClearResponse{entityId=%s, previousTtl=%d, result=%s}", entityId,
                previousTtlSeconds, result);
    }
}
