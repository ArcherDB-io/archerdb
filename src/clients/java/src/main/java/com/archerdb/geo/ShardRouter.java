// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.List;
import java.util.Objects;
import java.util.function.Supplier;

/**
 * Shard-aware request routing (F5.1.4 Shard-Aware Routing).
 *
 * <p>
 * Routes requests to the correct shard based on entity ID, handles leader redirects, and provides
 * access to all shard primaries for scatter-gather queries.
 *
 * <p>
 * Example:
 *
 * <pre>
 * {
 *     &#64;code
 *     ShardRouter router = new ShardRouter(cache, () -> client.refreshTopology());
 *
 *     // Route a request by entity ID
 *     ShardRouter.RouteResult route = router.routeByEntityId(entityId);
 *     System.out.println("Shard " + route.getShardId() + " at " + route.getPrimary());
 *
 *     // Handle not-leader errors
 *     try {
 *         client.query(route.getPrimary(), ...);
 *     } catch (NotShardLeaderException e) {
 *         if (router.handleNotShardLeader(e)) {
 *             // Retry with refreshed topology
 *         }
 *     }
 * }
 * </pre>
 */
public class ShardRouter {

    private final TopologyCache cache;
    private final Supplier<Boolean> refreshCallback;

    /**
     * Creates a new ShardRouter.
     *
     * @param cache the topology cache to use
     * @param refreshCallback callback to refresh topology (returns true if successful)
     */
    public ShardRouter(TopologyCache cache, Supplier<Boolean> refreshCallback) {
        this.cache = Objects.requireNonNull(cache, "cache cannot be null");
        this.refreshCallback = refreshCallback;
    }

    /**
     * Creates a new ShardRouter without refresh callback.
     *
     * @param cache the topology cache to use
     */
    public ShardRouter(TopologyCache cache) {
        this(cache, null);
    }

    /**
     * Holds the result of routing an entity to a shard.
     */
    public static final class RouteResult {
        private final int shardId;
        private final String primary;

        private RouteResult(int shardId, String primary) {
            this.shardId = shardId;
            this.primary = primary;
        }

        /**
         * Returns the shard ID.
         */
        public int getShardId() {
            return shardId;
        }

        /**
         * Returns the primary address.
         */
        public String getPrimary() {
            return primary;
        }
    }

    /**
     * Routes an entity ID to its shard and returns the primary address.
     *
     * @param entityId the entity ID to route
     * @return the routing result containing shard ID and primary address
     * @throws ShardRoutingException if no primary is available for the shard
     */
    public RouteResult routeByEntityId(UInt128 entityId) throws ShardRoutingException {
        int shardId = cache.computeShard(entityId);
        String primary = cache.getShardPrimary(shardId);

        if (primary == null || primary.isEmpty()) {
            throw new ShardRoutingException(shardId, "No primary address for shard " + shardId);
        }

        return new RouteResult(shardId, primary);
    }

    /**
     * Handles a NotShardLeaderException by refreshing the topology.
     *
     * @param exception the exception to handle
     * @return true if topology was refreshed and a retry should be attempted
     */
    public boolean handleNotShardLeader(NotShardLeaderException exception) {
        if (refreshCallback != null) {
            try {
                return refreshCallback.get();
            } catch (Exception e) {
                return false;
            }
        }
        return false;
    }

    /**
     * Returns all shard primary addresses for scatter-gather queries.
     *
     * @return list of all primary addresses
     */
    public List<String> getAllPrimaries() {
        return cache.getAllShardPrimaries();
    }

    /**
     * Returns the underlying topology cache.
     */
    public TopologyCache getCache() {
        return cache;
    }
}
