// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

/**
 * Thread-safe connection pool for ArcherDB clients.
 *
 * <p>
 * Per client-sdk/spec.md connection pooling requirements:
 * <ul>
 * <li>Maintain internal connection pool</li>
 * <li>Serialize requests to maintain ordering per thread</li>
 * <li>Default pool size: 1 (single connection)</li>
 * <li>Pool size configurable for high-throughput scenarios</li>
 * <li>Periodic ping health checks (every 30 seconds)</li>
 * <li>Automatic reconnection on failure</li>
 * </ul>
 *
 * <p>
 * This class is thread-safe.
 *
 * @param <T> the connection type
 */
public final class ConnectionPool<T> implements AutoCloseable {

    /**
     * Default pool size (single connection per spec).
     */
    public static final int DEFAULT_POOL_SIZE = 1;

    /**
     * Default health check interval (30 seconds per spec).
     */
    public static final long DEFAULT_HEALTH_CHECK_INTERVAL_MS = 30_000;

    /**
     * Default acquire timeout in milliseconds.
     */
    public static final long DEFAULT_ACQUIRE_TIMEOUT_MS = 5_000;

    private final BlockingQueue<PooledConnection<T>> pool;
    private final int maxSize;
    private final AtomicInteger currentSize;
    private final AtomicBoolean closed;
    private final ConnectionFactory<T> connectionFactory;
    private final HealthChecker<T> healthChecker;
    private final ScheduledExecutorService healthCheckExecutor;
    private final long healthCheckIntervalMs;
    private final long acquireTimeoutMs;
    private final ClientMetrics metrics;

    /**
     * Builder for ConnectionPool.
     *
     * @param <T> the connection type
     */
    public static class Builder<T> {
        private int maxSize = DEFAULT_POOL_SIZE;
        private ConnectionFactory<T> connectionFactory;
        private HealthChecker<T> healthChecker;
        private long healthCheckIntervalMs = DEFAULT_HEALTH_CHECK_INTERVAL_MS;
        private long acquireTimeoutMs = DEFAULT_ACQUIRE_TIMEOUT_MS;
        private ClientMetrics metrics;

        /**
         * Sets the maximum pool size.
         *
         * @param maxSize the maximum number of connections
         * @return this builder
         */
        public Builder<T> setMaxSize(int maxSize) {
            if (maxSize <= 0) {
                throw new IllegalArgumentException("Pool size must be positive");
            }
            this.maxSize = maxSize;
            return this;
        }

        /**
         * Sets the connection factory.
         *
         * @param factory the factory to create connections
         * @return this builder
         */
        public Builder<T> setConnectionFactory(ConnectionFactory<T> factory) {
            this.connectionFactory = factory;
            return this;
        }

        /**
         * Sets the health checker.
         *
         * @param checker the health checker (null to disable)
         * @return this builder
         */
        public Builder<T> setHealthChecker(HealthChecker<T> checker) {
            this.healthChecker = checker;
            return this;
        }

        /**
         * Sets the health check interval.
         *
         * @param intervalMs interval in milliseconds
         * @return this builder
         */
        public Builder<T> setHealthCheckIntervalMs(long intervalMs) {
            if (intervalMs <= 0) {
                throw new IllegalArgumentException("Health check interval must be positive");
            }
            this.healthCheckIntervalMs = intervalMs;
            return this;
        }

        /**
         * Sets the acquire timeout.
         *
         * @param timeoutMs timeout in milliseconds
         * @return this builder
         */
        public Builder<T> setAcquireTimeoutMs(long timeoutMs) {
            if (timeoutMs <= 0) {
                throw new IllegalArgumentException("Acquire timeout must be positive");
            }
            this.acquireTimeoutMs = timeoutMs;
            return this;
        }

        /**
         * Sets the metrics collector.
         *
         * @param metrics the metrics collector
         * @return this builder
         */
        public Builder<T> setMetrics(ClientMetrics metrics) {
            this.metrics = metrics;
            return this;
        }

        /**
         * Builds the connection pool.
         *
         * @return the connection pool
         */
        public ConnectionPool<T> build() {
            if (connectionFactory == null) {
                throw new IllegalStateException("Connection factory is required");
            }
            return new ConnectionPool<>(this);
        }
    }

    /**
     * Creates a new builder.
     *
     * @param <T> the connection type
     * @return the builder
     */
    public static <T> Builder<T> builder() {
        return new Builder<>();
    }

    private ConnectionPool(Builder<T> builder) {
        this.maxSize = builder.maxSize;
        this.connectionFactory = builder.connectionFactory;
        this.healthChecker = builder.healthChecker;
        this.healthCheckIntervalMs = builder.healthCheckIntervalMs;
        this.acquireTimeoutMs = builder.acquireTimeoutMs;
        this.metrics = builder.metrics;
        this.pool = new ArrayBlockingQueue<>(maxSize);
        this.currentSize = new AtomicInteger(0);
        this.closed = new AtomicBoolean(false);

        // Start health check scheduler if checker provided
        if (healthChecker != null) {
            this.healthCheckExecutor = Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "archerdb-health-check");
                t.setDaemon(true);
                return t;
            });
            this.healthCheckExecutor.scheduleAtFixedRate(this::runHealthCheck,
                    healthCheckIntervalMs, healthCheckIntervalMs, TimeUnit.MILLISECONDS);
        } else {
            this.healthCheckExecutor = null;
        }
    }

    /**
     * Acquires a connection from the pool.
     *
     * <p>
     * Creates a new connection if the pool is empty and capacity allows. Blocks if the pool is at
     * capacity.
     *
     * @return a pooled connection
     * @throws ConnectionException if unable to acquire connection
     */
    public PooledConnection<T> acquire() throws ConnectionException {
        ensureOpen();

        // Try to get from pool first
        PooledConnection<T> conn = pool.poll();
        if (conn != null) {
            conn.markInUse();
            return conn;
        }

        // Try to create new connection if under capacity
        if (currentSize.get() < maxSize) {
            int newSize = currentSize.incrementAndGet();
            if (newSize <= maxSize) {
                try {
                    T underlying = connectionFactory.create();
                    conn = new PooledConnection<>(underlying, this);
                    conn.markInUse();
                    return conn;
                } catch (Exception e) {
                    currentSize.decrementAndGet();
                    throw ConnectionException
                            .connectionFailed("Failed to create connection: " + e.getMessage());
                }
            } else {
                currentSize.decrementAndGet();
            }
        }

        // Pool at capacity - wait for available connection
        try {
            conn = pool.poll(acquireTimeoutMs, TimeUnit.MILLISECONDS);
            if (conn == null) {
                throw ConnectionException.connectionTimeout("pool", (int) acquireTimeoutMs);
            }
            conn.markInUse();
            return conn;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw ConnectionException.connectionFailed("Interrupted while acquiring connection");
        }
    }

    /**
     * Returns a connection to the pool.
     *
     * @param conn the connection to return
     */
    void release(PooledConnection<T> conn) {
        if (conn == null || closed.get()) {
            if (conn != null) {
                closeConnection(conn);
            }
            return;
        }

        conn.markIdle();

        // Check if connection is still healthy before returning
        if (healthChecker != null && !healthChecker.isHealthy(conn.getConnection())) {
            closeConnection(conn);
            currentSize.decrementAndGet();
            if (metrics != null) {
                metrics.recordReconnection();
            }
            return;
        }

        // Return to pool
        if (!pool.offer(conn)) {
            // Pool full (shouldn't happen), close connection
            closeConnection(conn);
            currentSize.decrementAndGet();
        }
    }

    /**
     * Invalidates a connection (e.g., after error).
     *
     * @param conn the connection to invalidate
     */
    void invalidate(PooledConnection<T> conn) {
        closeConnection(conn);
        currentSize.decrementAndGet();
        if (metrics != null) {
            metrics.recordReconnection();
        }
    }

    /**
     * Returns the current number of connections in the pool.
     *
     * @return the number of connections
     */
    public int size() {
        return pool.size();
    }

    /**
     * Returns the total number of connections (in use + idle).
     *
     * @return total connection count
     */
    public int totalConnections() {
        return currentSize.get();
    }

    /**
     * Returns the maximum pool size.
     *
     * @return the max size
     */
    public int getMaxSize() {
        return maxSize;
    }

    /**
     * Returns the number of available connections.
     *
     * @return available count
     */
    public int available() {
        return pool.size();
    }

    /**
     * Returns true if the pool is closed.
     *
     * @return true if closed
     */
    public boolean isClosed() {
        return closed.get();
    }

    @Override
    public void close() {
        if (closed.compareAndSet(false, true)) {
            // Stop health check executor
            if (healthCheckExecutor != null) {
                healthCheckExecutor.shutdown();
                try {
                    if (!healthCheckExecutor.awaitTermination(5, TimeUnit.SECONDS)) {
                        healthCheckExecutor.shutdownNow();
                    }
                } catch (InterruptedException e) {
                    healthCheckExecutor.shutdownNow();
                    Thread.currentThread().interrupt();
                }
            }

            // Close all connections
            PooledConnection<T> conn;
            while ((conn = pool.poll()) != null) {
                closeConnection(conn);
            }
        }
    }

    private void ensureOpen() {
        if (closed.get()) {
            throw new IllegalStateException("Connection pool is closed");
        }
    }

    @SuppressWarnings("PMD.EmptyCatchBlock")
    private void closeConnection(PooledConnection<T> conn) {
        try {
            connectionFactory.close(conn.getConnection());
        } catch (Exception e) {
            // Intentionally ignored - we're closing the connection anyway
            // and cannot do anything useful with the exception
        }
    }

    private void runHealthCheck() {
        if (closed.get() || healthChecker == null) {
            return;
        }

        // Check idle connections
        int checked = 0;
        int poolSize = pool.size();

        while (checked < poolSize) {
            PooledConnection<T> conn = pool.poll();
            if (conn == null) {
                break;
            }

            checked++;

            if (healthChecker.isHealthy(conn.getConnection())) {
                pool.offer(conn);
            } else {
                // Connection unhealthy - close and decrement
                closeConnection(conn);
                currentSize.decrementAndGet();
                if (metrics != null) {
                    metrics.recordReconnection();
                }
            }
        }
    }

    /**
     * Factory interface for creating connections.
     *
     * @param <T> the connection type
     */
    @FunctionalInterface
    public interface ConnectionFactory<T> {
        /**
         * Creates a new connection.
         *
         * @return the connection
         * @throws Exception if creation fails
         */
        T create() throws Exception;

        /**
         * Closes a connection.
         *
         * @param connection the connection to close
         */
        @SuppressWarnings("PMD.EmptyCatchBlock")
        default void close(T connection) {
            if (connection instanceof AutoCloseable) {
                try {
                    ((AutoCloseable) connection).close();
                } catch (Exception e) {
                    // Intentionally ignored - best-effort close
                }
            }
        }
    }

    /**
     * Interface for checking connection health.
     *
     * @param <T> the connection type
     */
    @FunctionalInterface
    public interface HealthChecker<T> {
        /**
         * Checks if a connection is healthy.
         *
         * @param connection the connection to check
         * @return true if healthy
         */
        boolean isHealthy(T connection);
    }

    /**
     * A pooled connection wrapper.
     *
     * @param <T> the connection type
     */
    public static final class PooledConnection<T> implements AutoCloseable {
        private final T connection;
        private final ConnectionPool<T> pool;
        private volatile boolean inUse;
        private volatile long lastUsedMs;

        PooledConnection(T connection, ConnectionPool<T> pool) {
            this.connection = connection;
            this.pool = pool;
            this.inUse = false;
            this.lastUsedMs = System.currentTimeMillis();
        }

        /**
         * Returns the underlying connection.
         *
         * @return the connection
         */
        public T getConnection() {
            return connection;
        }

        /**
         * Returns true if this connection is currently in use.
         *
         * @return true if in use
         */
        public boolean isInUse() {
            return inUse;
        }

        /**
         * Returns the last used timestamp.
         *
         * @return last used time in milliseconds
         */
        public long getLastUsedMs() {
            return lastUsedMs;
        }

        void markInUse() {
            this.inUse = true;
            this.lastUsedMs = System.currentTimeMillis();
        }

        void markIdle() {
            this.inUse = false;
            this.lastUsedMs = System.currentTimeMillis();
        }

        /**
         * Returns this connection to the pool.
         */
        @Override
        public void close() {
            pool.release(this);
        }

        /**
         * Invalidates this connection (removes from pool).
         */
        public void invalidate() {
            pool.invalidate(this);
        }

        /**
         * Executes an operation with this connection and returns it to pool.
         *
         * @param operation the operation to execute
         */
        public void use(Consumer<T> operation) {
            try {
                operation.accept(connection);
            } finally {
                close();
            }
        }
    }
}
