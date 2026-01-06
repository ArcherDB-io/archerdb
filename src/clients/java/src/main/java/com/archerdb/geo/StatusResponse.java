package com.archerdb.geo;

/**
 * Server status response from archerdb_get_status operation.
 */
public final class StatusResponse {

    private final long ramIndexCount;
    private final long ramIndexCapacity;
    private final int ramIndexLoadPct;
    private final long tombstoneCount;
    private final long ttlExpirations;
    private final long deletionCount;

    public StatusResponse(long ramIndexCount, long ramIndexCapacity, int ramIndexLoadPct,
            long tombstoneCount, long ttlExpirations, long deletionCount) {
        this.ramIndexCount = ramIndexCount;
        this.ramIndexCapacity = ramIndexCapacity;
        this.ramIndexLoadPct = ramIndexLoadPct;
        this.tombstoneCount = tombstoneCount;
        this.ttlExpirations = ttlExpirations;
        this.deletionCount = deletionCount;
    }

    public long getRamIndexCount() {
        return ramIndexCount;
    }

    public long getRamIndexCapacity() {
        return ramIndexCapacity;
    }

    public int getRamIndexLoadPct() {
        return ramIndexLoadPct;
    }

    /**
     * Returns the load factor as a decimal (e.g., 0.70).
     */
    public double getLoadFactor() {
        return ramIndexLoadPct / 10000.0;
    }

    public long getTombstoneCount() {
        return tombstoneCount;
    }

    public long getTtlExpirations() {
        return ttlExpirations;
    }

    public long getDeletionCount() {
        return deletionCount;
    }

    @Override
    public String toString() {
        return String.format("StatusResponse{entities=%d, capacity=%d, loadFactor=%.1f%%}",
                ramIndexCount, ramIndexCapacity, getLoadFactor() * 100);
    }
}
