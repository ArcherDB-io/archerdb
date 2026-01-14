package com.archerdb.geo;

import java.util.Collections;
import java.util.List;
import java.util.Objects;

/**
 * Cluster topology information (F5.1.2 Topology Response Format).
 *
 * <p>
 * Contains the current topology version, cluster ID, shard information, and resharding status.
 */
public final class TopologyResponse {

    /** Maximum number of shards supported. */
    public static final int MAX_SHARDS = 256;

    /** Maximum number of replicas per shard. */
    public static final int MAX_REPLICAS_PER_SHARD = 6;

    private final long version;
    private final UInt128 clusterId;
    private final int numShards;
    private final int reshardingStatus;
    private final List<ShardInfo> shards;
    private final long lastChangeNs;

    /**
     * Creates a new TopologyResponse.
     *
     * @param version topology version number (increments on changes)
     * @param clusterId cluster identifier
     * @param numShards number of shards in the cluster
     * @param reshardingStatus resharding state (0=idle, 1=preparing, 2=migrating, 3=finalizing)
     * @param shards information about each shard
     * @param lastChangeNs timestamp of last topology change (nanoseconds since epoch)
     */
    public TopologyResponse(long version, UInt128 clusterId, int numShards, int reshardingStatus,
            List<ShardInfo> shards, long lastChangeNs) {
        this.version = version;
        this.clusterId = Objects.requireNonNull(clusterId, "clusterId cannot be null");
        this.numShards = numShards;
        this.reshardingStatus = reshardingStatus;
        this.shards =
                shards != null ? Collections.unmodifiableList(shards) : Collections.emptyList();
        this.lastChangeNs = lastChangeNs;
    }

    /**
     * Returns the topology version number (increments on changes).
     */
    public long getVersion() {
        return version;
    }

    /**
     * Returns the cluster identifier.
     */
    public UInt128 getClusterId() {
        return clusterId;
    }

    /**
     * Returns the number of shards in the cluster.
     */
    public int getNumShards() {
        return numShards;
    }

    /**
     * Returns the resharding status (0=idle, 1=preparing, 2=migrating, 3=finalizing).
     */
    public int getReshardingStatus() {
        return reshardingStatus;
    }

    /**
     * Returns information about each shard (immutable).
     */
    public List<ShardInfo> getShards() {
        return shards;
    }

    /**
     * Returns the timestamp of the last topology change (nanoseconds since epoch).
     */
    public long getLastChangeNs() {
        return lastChangeNs;
    }

    /**
     * Returns true if the cluster is currently resharding.
     */
    public boolean isResharding() {
        return reshardingStatus != 0;
    }

    /**
     * Returns the shard info for the given shard ID, or null if not found.
     */
    public ShardInfo getShard(int shardId) {
        if (shardId >= 0 && shardId < shards.size()) {
            return shards.get(shardId);
        }
        return null;
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj)
            return true;
        if (!(obj instanceof TopologyResponse))
            return false;
        TopologyResponse other = (TopologyResponse) obj;
        return version == other.version && clusterId.equals(other.clusterId)
                && numShards == other.numShards && reshardingStatus == other.reshardingStatus
                && shards.equals(other.shards) && lastChangeNs == other.lastChangeNs;
    }

    @Override
    public int hashCode() {
        return Objects.hash(version, clusterId, numShards, reshardingStatus, shards, lastChangeNs);
    }

    @Override
    public String toString() {
        return String.format(
                "TopologyResponse{version=%d, numShards=%d, resharding=%b, shardCount=%d}", version,
                numShards, isResharding(), shards.size());
    }
}
