// ArcherDB Java Client - TTL Set Response
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025 ArcherDB Developers

package com.archerdb.geo;

/**
 * Response from a TTL set operation.
 *
 * <p>
 * Wire format: 64 bytes total, must match server's TtlSetResponse.
 *
 * <p>
 * Part of v2.1 Manual TTL Support.
 */
public final class TtlSetResponse {
    private final UInt128 entityId;
    private final int previousTtlSeconds;
    private final int newTtlSeconds;
    private final TtlOperationResult result;

    /**
     * Creates a new TTL set response.
     *
     * @param entityId the entity that was modified
     * @param previousTtlSeconds the previous TTL value
     * @param newTtlSeconds the new TTL value
     * @param result the operation result
     */
    public TtlSetResponse(UInt128 entityId, int previousTtlSeconds, int newTtlSeconds,
            TtlOperationResult result) {
        this.entityId = entityId;
        this.previousTtlSeconds = previousTtlSeconds;
        this.newTtlSeconds = newTtlSeconds;
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
     * Returns the previous TTL value in seconds.
     *
     * @return the previous TTL
     */
    public int getPreviousTtlSeconds() {
        return previousTtlSeconds;
    }

    /**
     * Returns the new TTL value in seconds.
     *
     * @return the new TTL
     */
    public int getNewTtlSeconds() {
        return newTtlSeconds;
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
        return String.format("TtlSetResponse{entityId=%s, previousTtl=%d, newTtl=%d, result=%s}",
                entityId, previousTtlSeconds, newTtlSeconds, result);
    }
}
