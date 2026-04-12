// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Result structure for delete operations.
 */
public final class DeleteResult {

    private final int deletedCount;
    private final int notFoundCount;

    public DeleteResult(int deletedCount, int notFoundCount) {
        this.deletedCount = deletedCount;
        this.notFoundCount = notFoundCount;
    }

    /**
     * Returns the number of entities successfully deleted.
     */
    public int getDeletedCount() {
        return deletedCount;
    }

    /**
     * Returns the number of entities that were not found.
     */
    public int getNotFoundCount() {
        return notFoundCount;
    }

    @Override
    public String toString() {
        return String.format("DeleteResult{deleted=%d, notFound=%d}", deletedCount, notFoundCount);
    }
}
