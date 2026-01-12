package com.archerdb.geo;

/**
 * Result of a cleanup_expired operation.
 *
 * <p>
 * Per client-protocol/spec.md cleanup_expired (0x30) response format:
 * <ul>
 * <li>entries_scanned: u64 - Number of index entries examined</li>
 * <li>entries_removed: u64 - Number of expired entries cleaned up</li>
 * </ul>
 */
public final class CleanupResult {

    private final long entriesScanned;
    private final long entriesRemoved;

    /**
     * Creates a new cleanup result.
     *
     * @param entriesScanned number of entries examined
     * @param entriesRemoved number of expired entries removed
     */
    public CleanupResult(long entriesScanned, long entriesRemoved) {
        this.entriesScanned = entriesScanned;
        this.entriesRemoved = entriesRemoved;
    }

    /**
     * Returns the number of index entries examined.
     *
     * @return entries scanned count
     */
    public long getEntriesScanned() {
        return entriesScanned;
    }

    /**
     * Returns the number of expired entries removed.
     *
     * @return entries removed count
     */
    public long getEntriesRemoved() {
        return entriesRemoved;
    }

    /**
     * Returns true if any entries were removed.
     *
     * @return true if entries were cleaned up
     */
    public boolean hasRemovals() {
        return entriesRemoved > 0;
    }

    /**
     * Returns the percentage of scanned entries that were expired.
     *
     * @return expiration ratio (0.0 to 1.0)
     */
    public double getExpirationRatio() {
        if (entriesScanned == 0) {
            return 0.0;
        }
        return (double) entriesRemoved / (double) entriesScanned;
    }

    @Override
    public String toString() {
        return "CleanupResult{entriesScanned=" + entriesScanned + ", entriesRemoved="
                + entriesRemoved + ", expirationRatio="
                + String.format("%.2f%%", getExpirationRatio() * 100) + "}";
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) {
            return true;
        }
        if (!(obj instanceof CleanupResult)) {
            return false;
        }
        CleanupResult other = (CleanupResult) obj;
        return entriesScanned == other.entriesScanned && entriesRemoved == other.entriesRemoved;
    }

    @Override
    public int hashCode() {
        return Long.hashCode(entriesScanned) * 31 + Long.hashCode(entriesRemoved);
    }
}
