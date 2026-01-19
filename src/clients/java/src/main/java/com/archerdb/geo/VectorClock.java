// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Vector clock for tracking causality in distributed systems.
 * <p>
 * Used to detect concurrent writes in active-active replication scenarios where the same entity may
 * be modified in multiple regions.
 * </p>
 *
 * @see <a href="https://docs.archerdb.io/reference/active-active#vector-clock">Vector Clock</a>
 */
public class VectorClock {
    private final Map<String, Long> entries;

    /**
     * Creates an empty vector clock.
     */
    public VectorClock() {
        this.entries = new ConcurrentHashMap<>();
    }

    /**
     * Creates a vector clock with initial entries.
     *
     * @param entries Initial entries
     */
    public VectorClock(Map<String, Long> entries) {
        this.entries = new ConcurrentHashMap<>(entries);
    }

    /**
     * Gets the timestamp for a region.
     *
     * @param regionId Region identifier
     * @return Timestamp, or 0 if not present
     */
    public long get(String regionId) {
        return entries.getOrDefault(regionId, 0L);
    }

    /**
     * Sets the timestamp for a region.
     *
     * @param regionId Region identifier
     * @param timestamp Timestamp value
     */
    public void set(String regionId, long timestamp) {
        entries.put(regionId, timestamp);
    }

    /**
     * Increments the timestamp for a region.
     *
     * @param regionId Region identifier
     * @return The new timestamp value
     */
    public long increment(String regionId) {
        return entries.compute(regionId, (k, v) -> (v == null ? 0L : v) + 1);
    }

    /**
     * Merges another vector clock into this one (takes max of each entry).
     *
     * @param other The other vector clock to merge
     */
    public void merge(VectorClock other) {
        for (Map.Entry<String, Long> entry : other.entries.entrySet()) {
            entries.merge(entry.getKey(), entry.getValue(), Math::max);
        }
    }

    /**
     * Creates a deep copy of this vector clock.
     *
     * @return A new VectorClock with the same entries
     */
    public VectorClock copy() {
        return new VectorClock(new HashMap<>(entries));
    }

    /**
     * Returns an unmodifiable view of the entries.
     *
     * @return Unmodifiable map of entries
     */
    public Map<String, Long> getEntries() {
        return Collections.unmodifiableMap(entries);
    }

    /**
     * Compares two vector clocks.
     *
     * @param other The other vector clock
     * @return -1 if this &lt; other, 0 if concurrent, 1 if this &gt; other
     */
    public int compare(VectorClock other) {
        boolean thisGreater = false;
        boolean otherGreater = false;

        // Check entries in this clock
        for (Map.Entry<String, Long> entry : entries.entrySet()) {
            long otherTs = other.get(entry.getKey());
            if (entry.getValue() > otherTs) {
                thisGreater = true;
            }
            if (entry.getValue() < otherTs) {
                otherGreater = true;
            }
        }

        // Check entries only in other clock
        for (Map.Entry<String, Long> entry : other.entries.entrySet()) {
            if (!entries.containsKey(entry.getKey()) && entry.getValue() > 0) {
                otherGreater = true;
            }
        }

        if (thisGreater && !otherGreater) {
            return 1;
        }
        if (otherGreater && !thisGreater) {
            return -1;
        }
        return 0; // Concurrent
    }

    /**
     * Returns true if this clock happened before the other.
     *
     * @param other The other vector clock
     * @return true if this &lt; other
     */
    public boolean happenedBefore(VectorClock other) {
        return compare(other) < 0;
    }

    /**
     * Returns true if the clocks are concurrent (neither happened before the other).
     *
     * @param other The other vector clock
     * @return true if concurrent
     */
    public boolean isConcurrent(VectorClock other) {
        return compare(other) == 0;
    }

    @Override
    public String toString() {
        return "VectorClock{" + entries + "}";
    }
}
