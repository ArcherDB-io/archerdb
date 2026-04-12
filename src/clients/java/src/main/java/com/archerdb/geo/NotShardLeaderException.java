// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Exception thrown when a request is sent to a node that is not the shard leader.
 *
 * <p>
 * This typically occurs after a failover when the client's cached topology is stale. The exception
 * includes a hint about the new leader address, which can be used to update the topology cache and
 * retry.
 */
public class NotShardLeaderException extends ShardRoutingException {

    private final String leaderHint;

    /**
     * Creates a new NotShardLeaderException.
     *
     * @param shardId the shard ID
     * @param leaderHint hint about the new leader address (may be null)
     */
    public NotShardLeaderException(int shardId, String leaderHint) {
        super(shardId, formatMessage(shardId, leaderHint));
        this.leaderHint = leaderHint;
    }

    private static String formatMessage(int shardId, String leaderHint) {
        if (leaderHint != null && !leaderHint.isEmpty()) {
            return "Not shard leader, hint: " + leaderHint;
        }
        return "Not shard leader for shard " + shardId;
    }

    /**
     * Returns the hint about the new leader address, or null if not available.
     */
    public String getLeaderHint() {
        return leaderHint;
    }
}
