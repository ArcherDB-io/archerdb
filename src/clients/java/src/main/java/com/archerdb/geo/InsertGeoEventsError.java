// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Per-event result for batch insert operations.
 */
public final class InsertGeoEventsError {

    private final int index;
    private final InsertGeoEventResult result;

    public InsertGeoEventsError(int index, InsertGeoEventResult result) {
        this.index = index;
        this.result = result;
    }

    /**
     * Returns the index of the event in the batch that failed.
     */
    public int getIndex() {
        return index;
    }

    /**
     * Returns the result code for the failure.
     */
    public InsertGeoEventResult getResult() {
        return result;
    }

    @Override
    public String toString() {
        return String.format("InsertGeoEventsError{index=%d, result=%s}", index, result);
    }
}
