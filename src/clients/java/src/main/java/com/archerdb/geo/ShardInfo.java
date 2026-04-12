// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.Collections;
import java.util.List;
import java.util.Objects;

/**
 * Information about a single shard in the cluster (F5.1.2 Topology Response Format).
 */
public final class ShardInfo {

    private final int id;
    private final String primary;
    private final List<String> replicas;
    private final ShardStatus status;
    private final long entityCount;
    private final long sizeBytes;

    /**
     * Creates a new ShardInfo.
     *
     * @param id shard identifier (0 to num_shards-1)
     * @param primary primary/leader node address
     * @param replicas replica node addresses
     * @param status current shard status
     * @param entityCount approximate number of entities in the shard
     * @param sizeBytes approximate size of the shard in bytes
     */
    public ShardInfo(int id, String primary, List<String> replicas, ShardStatus status,
            long entityCount, long sizeBytes) {
        this.id = id;
        this.primary = Objects.requireNonNull(primary, "primary cannot be null");
        this.replicas =
                replicas != null ? Collections.unmodifiableList(replicas) : Collections.emptyList();
        this.status = Objects.requireNonNull(status, "status cannot be null");
        this.entityCount = entityCount;
        this.sizeBytes = sizeBytes;
    }

    /**
     * Creates a minimal ShardInfo (for testing).
     */
    public ShardInfo(int id, String primary, ShardStatus status) {
        this(id, primary, Collections.emptyList(), status, 0L, 0L);
    }

    /**
     * Returns the shard identifier (0 to num_shards-1).
     */
    public int getId() {
        return id;
    }

    /**
     * Returns the primary/leader node address.
     */
    public String getPrimary() {
        return primary;
    }

    /**
     * Returns the replica node addresses (immutable).
     */
    public List<String> getReplicas() {
        return replicas;
    }

    /**
     * Returns the current shard status.
     */
    public ShardStatus getStatus() {
        return status;
    }

    /**
     * Returns the approximate number of entities in the shard.
     */
    public long getEntityCount() {
        return entityCount;
    }

    /**
     * Returns the approximate size of the shard in bytes.
     */
    public long getSizeBytes() {
        return sizeBytes;
    }

    /**
     * Returns true if this shard can accept read requests.
     */
    public boolean isReadable() {
        return status.isReadable();
    }

    /**
     * Returns true if this shard can accept write requests.
     */
    public boolean isWritable() {
        return status.isWritable();
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj)
            return true;
        if (!(obj instanceof ShardInfo))
            return false;
        ShardInfo other = (ShardInfo) obj;
        return id == other.id && primary.equals(other.primary) && replicas.equals(other.replicas)
                && status == other.status && entityCount == other.entityCount
                && sizeBytes == other.sizeBytes;
    }

    @Override
    public int hashCode() {
        return Objects.hash(id, primary, replicas, status, entityCount, sizeBytes);
    }

    @Override
    public String toString() {
        return String.format("ShardInfo{id=%d, primary='%s', replicas=%s, status=%s}", id, primary,
                replicas, status);
    }
}
