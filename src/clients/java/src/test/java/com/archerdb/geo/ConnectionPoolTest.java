// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.jupiter.api.Test;

/**
 * Unit tests for ConnectionPool.
 *
 * <p>
 * Per client-sdk/spec.md connection pooling requirements:
 * <ul>
 * <li>Default pool size: 1</li>
 * <li>Configurable pool size</li>
 * <li>Periodic health checks (30 seconds)</li>
 * <li>Automatic reconnection on failure</li>
 * <li>Thread-safe operations</li>
 * </ul>
 */
class ConnectionPoolTest {

    // ========================================================================
    // Default Configuration Tests
    // ========================================================================

    @Test
    void testDefaultPoolSize() {
        assertEquals(1, ConnectionPool.DEFAULT_POOL_SIZE);
    }

    @Test
    void testDefaultHealthCheckInterval() {
        assertEquals(30_000, ConnectionPool.DEFAULT_HEALTH_CHECK_INTERVAL_MS);
    }

    @Test
    void testDefaultAcquireTimeout() {
        assertEquals(5_000, ConnectionPool.DEFAULT_ACQUIRE_TIMEOUT_MS);
    }

    // ========================================================================
    // Pool Creation Tests
    // ========================================================================

    @Test
    void testBuilderRequiresConnectionFactory() {
        assertThrows(IllegalStateException.class, () -> {
            ConnectionPool.<String>builder().build();
        });
    }

    @Test
    void testBuilderRejectsZeroPoolSize() {
        assertThrows(IllegalArgumentException.class, () -> {
            ConnectionPool.<String>builder().setMaxSize(0);
        });
    }

    @Test
    void testBuilderRejectsNegativePoolSize() {
        assertThrows(IllegalArgumentException.class, () -> {
            ConnectionPool.<String>builder().setMaxSize(-1);
        });
    }

    @Test
    void testBuilderRejectsZeroHealthCheckInterval() {
        assertThrows(IllegalArgumentException.class, () -> {
            ConnectionPool.<String>builder().setHealthCheckIntervalMs(0);
        });
    }

    @Test
    void testBuilderRejectsZeroAcquireTimeout() {
        assertThrows(IllegalArgumentException.class, () -> {
            ConnectionPool.<String>builder().setAcquireTimeoutMs(0);
        });
    }

    // ========================================================================
    // Acquire/Release Tests
    // ========================================================================

    @Test
    void testAcquireCreatesConnection() throws Exception {
        AtomicInteger createCount = new AtomicInteger(0);

        try (ConnectionPool<String> pool =
                ConnectionPool.<String>builder().setConnectionFactory(() -> {
                    createCount.incrementAndGet();
                    return "connection";
                }).build()) {

            try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
                assertEquals("connection", conn.getConnection());
                assertEquals(1, createCount.get());
            }
        }
    }

    @Test
    void testAcquireReusesReleasedConnection() throws Exception {
        AtomicInteger createCount = new AtomicInteger(0);

        try (ConnectionPool<String> pool =
                ConnectionPool.<String>builder().setConnectionFactory(() -> {
                    return "connection-" + createCount.incrementAndGet();
                }).build()) {

            String firstConnection;
            try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
                firstConnection = conn.getConnection();
            }

            try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
                assertEquals(firstConnection, conn.getConnection(),
                        "Should reuse released connection");
                assertEquals(1, createCount.get(), "Should not create new connection");
            }
        }
    }

    @Test
    void testReleaseReturnsToPool() throws Exception {
        try (ConnectionPool<String> pool =
                ConnectionPool.<String>builder().setConnectionFactory(() -> "connection").build()) {

            assertEquals(0, pool.available());

            try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
                assertEquals(0, pool.available());
            }

            assertEquals(1, pool.available());
        }
    }

    // ========================================================================
    // Pool Size Tests
    // ========================================================================

    @Test
    void testCustomPoolSize() throws Exception {
        try (ConnectionPool<String> pool = ConnectionPool.<String>builder().setMaxSize(5)
                .setConnectionFactory(() -> "connection").build()) {

            assertEquals(5, pool.getMaxSize());
        }
    }

    @Test
    void testPoolSizeLimit() throws Exception {
        AtomicInteger createCount = new AtomicInteger(0);

        try (ConnectionPool<String> pool = ConnectionPool.<String>builder().setMaxSize(3)
                .setAcquireTimeoutMs(100).setConnectionFactory(() -> {
                    return "connection-" + createCount.incrementAndGet();
                }).build()) {

            // Acquire all 3 connections
            ConnectionPool.PooledConnection<String> conn1 = pool.acquire();
            ConnectionPool.PooledConnection<String> conn2 = pool.acquire();
            ConnectionPool.PooledConnection<String> conn3 = pool.acquire();

            assertEquals(3, createCount.get());
            assertEquals(3, pool.totalConnections());

            // Fourth acquire should timeout
            assertThrows(ConnectionException.class, () -> pool.acquire());

            conn1.close();
            conn2.close();
            conn3.close();
        }
    }

    // ========================================================================
    // Health Check Tests
    // ========================================================================

    @Test
    void testUnhealthyConnectionNotReturned() throws Exception {
        AtomicInteger createCount = new AtomicInteger(0);

        try (ConnectionPool<String> pool = ConnectionPool.<String>builder()
                .setConnectionFactory(() -> "connection-" + createCount.incrementAndGet())
                .setHealthChecker(conn -> !conn.equals("connection-1")) // First connection
                                                                        // unhealthy
                .build()) {

            // Acquire and release first connection
            try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
                assertEquals("connection-1", conn.getConnection());
            }

            // Pool should have closed the unhealthy connection
            assertEquals(0, pool.totalConnections());

            // Next acquire should create new connection
            try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
                assertEquals("connection-2", conn.getConnection());
            }
        }
    }

    // ========================================================================
    // Thread Safety Tests
    // ========================================================================

    @Test
    void testConcurrentAcquireRelease() throws Exception {
        int poolSize = 5;
        int threadCount = 20;
        int operationsPerThread = 100;
        AtomicInteger createCount = new AtomicInteger(0);

        try (ConnectionPool<String> pool = ConnectionPool.<String>builder().setMaxSize(poolSize)
                .setConnectionFactory(() -> "connection-" + createCount.incrementAndGet())
                .build()) {

            ExecutorService executor = Executors.newFixedThreadPool(threadCount);
            CountDownLatch latch = new CountDownLatch(threadCount);
            AtomicInteger errorCount = new AtomicInteger(0);

            for (int i = 0; i < threadCount; i++) {
                executor.submit(() -> {
                    try {
                        for (int j = 0; j < operationsPerThread; j++) {
                            try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
                                // Simulate some work
                                Thread.sleep(1);
                            }
                        }
                    } catch (Exception e) {
                        errorCount.incrementAndGet();
                    } finally {
                        latch.countDown();
                    }
                });
            }

            assertTrue(latch.await(30, TimeUnit.SECONDS));
            executor.shutdown();

            assertEquals(0, errorCount.get());
            // Should have created at most poolSize connections
            assertTrue(createCount.get() <= poolSize);
        }
    }

    @Test
    void testPooledConnectionInUseTracking() throws Exception {
        try (ConnectionPool<String> pool =
                ConnectionPool.<String>builder().setConnectionFactory(() -> "connection").build()) {

            ConnectionPool.PooledConnection<String> conn = pool.acquire();

            assertTrue(conn.isInUse());
            assertTrue(conn.getLastUsedMs() > 0);

            conn.close();

            assertFalse(conn.isInUse());
        }
    }

    // ========================================================================
    // Close Tests
    // ========================================================================

    @Test
    void testPoolClose() throws Exception {
        AtomicInteger closeCount = new AtomicInteger(0);

        ConnectionPool<String> pool = ConnectionPool.<String>builder()
                .setConnectionFactory(new ConnectionPool.ConnectionFactory<String>() {
                    @Override
                    public String create() {
                        return "connection";
                    }

                    @Override
                    public void close(String connection) {
                        closeCount.incrementAndGet();
                    }
                }).build();

        // Acquire and release to put connection in pool
        try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
            assertNotNull(conn);
        }

        pool.close();

        assertTrue(pool.isClosed());
        assertEquals(1, closeCount.get());
    }

    @Test
    void testAcquireAfterCloseThrows() throws Exception {
        ConnectionPool<String> pool =
                ConnectionPool.<String>builder().setConnectionFactory(() -> "connection").build();

        pool.close();

        assertThrows(IllegalStateException.class, () -> pool.acquire());
    }

    @Test
    void testDoubleCloseIsSafe() throws Exception {
        ConnectionPool<String> pool =
                ConnectionPool.<String>builder().setConnectionFactory(() -> "connection").build();

        pool.close();
        pool.close(); // Should not throw
    }

    // ========================================================================
    // Invalidate Tests
    // ========================================================================

    @Test
    void testInvalidateRemovesConnection() throws Exception {
        AtomicInteger createCount = new AtomicInteger(0);

        try (ConnectionPool<String> pool =
                ConnectionPool.<String>builder().setConnectionFactory(() -> {
                    return "connection-" + createCount.incrementAndGet();
                }).build()) {

            ConnectionPool.PooledConnection<String> conn = pool.acquire();
            assertEquals(1, pool.totalConnections());

            conn.invalidate();

            assertEquals(0, pool.totalConnections());
            assertEquals(0, pool.available());

            // Next acquire should create new connection
            try (ConnectionPool.PooledConnection<String> conn2 = pool.acquire()) {
                assertEquals("connection-2", conn2.getConnection());
            }
        }
    }

    // ========================================================================
    // Metrics Integration Tests
    // ========================================================================

    @Test
    void testMetricsRecordReconnection() throws Exception {
        ClientMetrics metrics = new ClientMetrics();

        try (ConnectionPool<String> pool = ConnectionPool.<String>builder()
                .setConnectionFactory(() -> "connection").setHealthChecker(conn -> false) // Always
                                                                                          // unhealthy
                .setMetrics(metrics).build()) {

            // Acquire and release - should trigger reconnection metric
            try (ConnectionPool.PooledConnection<String> conn = pool.acquire()) {
                assertNotNull(conn);
            }

            assertEquals(1, metrics.getReconnectionsTotal());
        }
    }

    // ========================================================================
    // Use Helper Tests
    // ========================================================================

    @Test
    void testPooledConnectionUse() throws Exception {
        try (ConnectionPool<String> pool =
                ConnectionPool.<String>builder().setConnectionFactory(() -> "connection").build()) {

            ConnectionPool.PooledConnection<String> conn = pool.acquire();
            AtomicInteger useCount = new AtomicInteger(0);

            conn.use(c -> {
                assertEquals("connection", c);
                useCount.incrementAndGet();
            });

            assertEquals(1, useCount.get());
            assertEquals(1, pool.available()); // Returned to pool
        }
    }
}
