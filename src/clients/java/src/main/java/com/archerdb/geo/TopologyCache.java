package com.archerdb.geo;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.ReadWriteLock;
import java.util.concurrent.locks.ReentrantReadWriteLock;
import java.util.function.Consumer;

/**
 * Thread-safe cache for cluster topology (F5.1 Smart Client Topology Discovery).
 *
 * <p>
 * Provides efficient access to cached topology, shard computation, and change notifications.
 *
 * <p>
 * Example:
 *
 * <pre>
 * {
 *     &#64;code
 *     TopologyCache cache = new TopologyCache();
 *     cache.update(topologyResponse);
 *
 *     // Compute shard for an entity
 *     int shardId = cache.computeShard(entityId);
 *     String primary = cache.getShardPrimary(shardId);
 *
 *     // Subscribe to changes
 *     Runnable unsubscribe = cache.onChange(notification -> {
 *         System.out.println("Topology changed: " + notification);
 *     });
 * }
 * </pre>
 */
public class TopologyCache {

    private final ReadWriteLock lock = new ReentrantReadWriteLock();
    private volatile TopologyResponse topology;
    private volatile Instant lastRefresh;
    private final AtomicLong refreshCount = new AtomicLong(0);
    private final AtomicLong version = new AtomicLong(0);
    private final CopyOnWriteArrayList<Consumer<TopologyChangeNotification>> listeners =
            new CopyOnWriteArrayList<>();

    /**
     * Creates a new empty topology cache.
     */
    public TopologyCache() {}

    /**
     * Returns the cached topology, or null if not yet fetched.
     */
    public TopologyResponse get() {
        lock.readLock().lock();
        try {
            return topology;
        } finally {
            lock.readLock().unlock();
        }
    }

    /**
     * Returns the current cached topology version, or 0 if not cached.
     */
    public long getVersion() {
        return version.get();
    }

    /**
     * Updates the cached topology and notifies subscribers if the version changed.
     *
     * @param newTopology the new topology response
     */
    public void update(TopologyResponse newTopology) {
        if (newTopology == null) {
            return;
        }

        long oldVersion;
        lock.writeLock().lock();
        try {
            oldVersion = version.get();
            topology = newTopology;
            version.set(newTopology.getVersion());
            lastRefresh = Instant.now();
            refreshCount.incrementAndGet();
        } finally {
            lock.writeLock().unlock();
        }

        // Notify subscribers if version changed (outside lock)
        if (newTopology.getVersion() != oldVersion && oldVersion != 0) {
            TopologyChangeNotification notification = new TopologyChangeNotification(
                    newTopology.getVersion(), oldVersion, System.nanoTime());
            for (Consumer<TopologyChangeNotification> listener : listeners) {
                try {
                    listener.accept(notification);
                } catch (Exception e) { // NOPMD - intentionally swallowed to not break other
                                        // listeners
                    // Listener exceptions should not affect other listeners or cache updates
                }
            }
        }
    }

    /**
     * Marks the cache as stale, forcing a refresh on next access.
     */
    public void invalidate() {
        version.set(0);
    }

    /**
     * Returns the time of the last topology refresh, or null if never refreshed.
     */
    public Instant getLastRefresh() {
        lock.readLock().lock();
        try {
            return lastRefresh;
        } finally {
            lock.readLock().unlock();
        }
    }

    /**
     * Returns the number of times the cache has been refreshed.
     */
    public long getRefreshCount() {
        return refreshCount.get();
    }

    /**
     * Registers a callback to be invoked when the topology changes.
     *
     * @param listener the callback to invoke
     * @return a Runnable that unregisters the callback when called
     */
    public Runnable onChange(Consumer<TopologyChangeNotification> listener) {
        if (listener == null) {
            throw new IllegalArgumentException("listener cannot be null");
        }
        listeners.add(listener);
        return () -> listeners.remove(listener);
    }

    /**
     * Computes the shard ID for a given entity ID using consistent hashing.
     *
     * <p>
     * Uses XOR folding of the 128-bit ID: shard = (lo ^ hi) % num_shards
     *
     * @param entityId the entity ID
     * @return the shard ID (0 to num_shards-1), or 0 if no topology cached
     */
    public int computeShard(UInt128 entityId) {
        lock.readLock().lock();
        try {
            if (topology == null || topology.getNumShards() == 0) {
                return 0;
            }
            // XOR folding for consistent hash
            long hash = entityId.getLo() ^ entityId.getHi();
            // Handle negative values from signed long
            return (int) (Long.remainderUnsigned(hash, topology.getNumShards()));
        } finally {
            lock.readLock().unlock();
        }
    }

    /**
     * Returns the primary address for a given shard.
     *
     * @param shardId the shard ID
     * @return the primary address, or null if not found
     */
    public String getShardPrimary(int shardId) {
        lock.readLock().lock();
        try {
            if (topology == null || shardId < 0 || shardId >= topology.getShards().size()) {
                return null;
            }
            return topology.getShards().get(shardId).getPrimary();
        } finally {
            lock.readLock().unlock();
        }
    }

    /**
     * Returns all shard primary addresses.
     *
     * @return list of primary addresses, or empty list if no topology
     */
    public List<String> getAllShardPrimaries() {
        lock.readLock().lock();
        try {
            if (topology == null) {
                return List.of();
            }
            List<String> primaries = new ArrayList<>(topology.getShards().size());
            for (ShardInfo shard : topology.getShards()) {
                primaries.add(shard.getPrimary());
            }
            return primaries;
        } finally {
            lock.readLock().unlock();
        }
    }

    /**
     * Returns true if the cluster is currently resharding.
     */
    public boolean isResharding() {
        lock.readLock().lock();
        try {
            return topology != null && topology.isResharding();
        } finally {
            lock.readLock().unlock();
        }
    }

    /**
     * Returns the list of active shard IDs.
     *
     * @return list of active shard IDs
     */
    public List<Integer> getActiveShards() {
        lock.readLock().lock();
        try {
            if (topology == null) {
                return List.of();
            }
            List<Integer> active = new ArrayList<>();
            for (ShardInfo shard : topology.getShards()) {
                if (shard.getStatus() == ShardStatus.ACTIVE) {
                    active.add(shard.getId());
                }
            }
            return active;
        } finally {
            lock.readLock().unlock();
        }
    }

    /**
     * Returns the number of shards in the cluster.
     *
     * @return number of shards, or 0 if no topology cached
     */
    public int getShardCount() {
        lock.readLock().lock();
        try {
            return topology != null ? topology.getNumShards() : 0;
        } finally {
            lock.readLock().unlock();
        }
    }
}
