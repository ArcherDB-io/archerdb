// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

/**
 * Statistics about conflict resolution.
 * <p>
 * Tracks how conflicts have been resolved across the system.
 * </p>
 *
 * @see <a href="https://docs.archerdb.io/reference/active-active#stats">Conflict Stats</a>
 */
public class ConflictStats {
    private long totalConflicts;
    private long lastWriterWinsCount;
    private long primaryWinsCount;
    private long customHookCount;
    private long lastConflictTimestamp;

    /**
     * Creates empty conflict stats.
     */
    public ConflictStats() {}

    /**
     * Returns the total number of conflicts detected.
     */
    public long getTotalConflicts() {
        return totalConflicts;
    }

    /**
     * Sets the total number of conflicts detected.
     */
    public void setTotalConflicts(long totalConflicts) {
        this.totalConflicts = totalConflicts;
    }

    /**
     * Returns the count of conflicts resolved by last-writer-wins.
     */
    public long getLastWriterWinsCount() {
        return lastWriterWinsCount;
    }

    /**
     * Sets the count of conflicts resolved by last-writer-wins.
     */
    public void setLastWriterWinsCount(long lastWriterWinsCount) {
        this.lastWriterWinsCount = lastWriterWinsCount;
    }

    /**
     * Returns the count of conflicts resolved by primary-wins.
     */
    public long getPrimaryWinsCount() {
        return primaryWinsCount;
    }

    /**
     * Sets the count of conflicts resolved by primary-wins.
     */
    public void setPrimaryWinsCount(long primaryWinsCount) {
        this.primaryWinsCount = primaryWinsCount;
    }

    /**
     * Returns the count of conflicts resolved by custom hook.
     */
    public long getCustomHookCount() {
        return customHookCount;
    }

    /**
     * Sets the count of conflicts resolved by custom hook.
     */
    public void setCustomHookCount(long customHookCount) {
        this.customHookCount = customHookCount;
    }

    /**
     * Returns the timestamp of the last conflict (nanoseconds).
     */
    public long getLastConflictTimestamp() {
        return lastConflictTimestamp;
    }

    /**
     * Sets the timestamp of the last conflict.
     */
    public void setLastConflictTimestamp(long lastConflictTimestamp) {
        this.lastConflictTimestamp = lastConflictTimestamp;
    }

    @Override
    public String toString() {
        return "ConflictStats{" + "totalConflicts=" + totalConflicts + ", lastWriterWinsCount="
                + lastWriterWinsCount + ", primaryWinsCount=" + primaryWinsCount
                + ", customHookCount=" + customHookCount + ", lastConflictTimestamp="
                + lastConflictTimestamp + '}';
    }
}
