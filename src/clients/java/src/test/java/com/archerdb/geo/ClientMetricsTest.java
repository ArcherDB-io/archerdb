// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Unit tests for ClientMetrics.
 *
 * <p>
 * Per client-sdk/spec.md and observability/spec.md, tests verify:
 * <ul>
 * <li>archerdb_client_requests_total{operation, status} counter</li>
 * <li>archerdb_client_request_duration_seconds{operation} histogram</li>
 * <li>archerdb_client_connections_active gauge</li>
 * <li>archerdb_client_reconnections_total counter</li>
 * <li>archerdb_client_retries_total counter</li>
 * <li>archerdb_client_retry_exhausted_total counter</li>
 * <li>Thread-safety for concurrent updates</li>
 * <li>Prometheus export format</li>
 * </ul>
 */
class ClientMetricsTest {

    private ClientMetrics metrics;

    @BeforeEach
    void setUp() {
        metrics = new ClientMetrics();
        // Also reset global metrics for clean test state
        ClientMetrics.global().reset();
    }

    // ========================================================================
    // Request Counter Tests
    // ========================================================================

    @Test
    void testRecordSuccessIncrementsCounter() {
        metrics.recordSuccess("insert", 1000000); // 1ms

        assertEquals(1, metrics.getRequestCount("insert", "success"));
        assertEquals(0, metrics.getRequestCount("insert", "error"));
    }

    @Test
    void testRecordErrorIncrementsCounter() {
        metrics.recordError("query_radius", 5000000, "timeout");

        assertEquals(0, metrics.getRequestCount("query_radius", "success"));
        assertEquals(1, metrics.getRequestCount("query_radius", "error"));
        assertEquals(1, metrics.getErrorCount("timeout"));
    }

    @Test
    void testMultipleOperationsTrackedSeparately() {
        metrics.recordSuccess("insert", 1000000);
        metrics.recordSuccess("insert", 2000000);
        metrics.recordSuccess("query_radius", 3000000);
        metrics.recordError("delete", 1000000, "not_found");

        assertEquals(2, metrics.getRequestCount("insert", "success"));
        assertEquals(1, metrics.getRequestCount("query_radius", "success"));
        assertEquals(1, metrics.getRequestCount("delete", "error"));
    }

    @Test
    void testUnknownOperationReturnsZero() {
        assertEquals(0, metrics.getRequestCount("unknown_operation", "success"));
        assertEquals(0, metrics.getRequestCount("unknown_operation", "error"));
    }

    // ========================================================================
    // Duration Tracking Tests
    // ========================================================================

    @Test
    void testAverageDurationCalculation() {
        metrics.recordSuccess("insert", 1_000_000_000L); // 1 second
        metrics.recordSuccess("insert", 3_000_000_000L); // 3 seconds

        double avgDuration = metrics.getAverageDurationSeconds("insert");
        assertEquals(2.0, avgDuration, 0.001); // Average is 2 seconds
    }

    @Test
    void testAverageDurationZeroForUnknownOperation() {
        assertEquals(0.0, metrics.getAverageDurationSeconds("unknown"));
    }

    @Test
    void testDurationTrackingIncludesErrors() {
        metrics.recordSuccess("query", 1_000_000_000L);
        metrics.recordError("query", 2_000_000_000L, "timeout");

        double avgDuration = metrics.getAverageDurationSeconds("query");
        assertEquals(1.5, avgDuration, 0.001);
    }

    // ========================================================================
    // Connection Metrics Tests
    // ========================================================================

    @Test
    void testConnectionOpenedIncrements() {
        assertEquals(0, metrics.getConnectionsActive());

        metrics.connectionOpened();
        assertEquals(1, metrics.getConnectionsActive());

        metrics.connectionOpened();
        assertEquals(2, metrics.getConnectionsActive());
    }

    @Test
    void testConnectionClosedDecrements() {
        metrics.connectionOpened();
        metrics.connectionOpened();
        metrics.connectionClosed();

        assertEquals(1, metrics.getConnectionsActive());
    }

    @Test
    void testReconnectionCounter() {
        assertEquals(0, metrics.getReconnectionsTotal());

        metrics.recordReconnection();
        metrics.recordReconnection();

        assertEquals(2, metrics.getReconnectionsTotal());
    }

    @Test
    void testSessionRenewalCounter() {
        assertEquals(0, metrics.getSessionRenewalsTotal());

        metrics.recordSessionRenewal();

        assertEquals(1, metrics.getSessionRenewalsTotal());
    }

    // ========================================================================
    // Retry Metrics Tests
    // ========================================================================

    @Test
    void testRetryCounter() {
        assertEquals(0, metrics.getRetriesTotal());

        metrics.recordRetry();
        metrics.recordRetry();
        metrics.recordRetry();

        assertEquals(3, metrics.getRetriesTotal());
    }

    @Test
    void testRetryExhaustedCounter() {
        assertEquals(0, metrics.getRetryExhaustedTotal());

        metrics.recordRetryExhausted();

        assertEquals(1, metrics.getRetryExhaustedTotal());
    }

    @Test
    void testPrimaryDiscoveryCounter() {
        assertEquals(0, metrics.getPrimaryDiscoveriesTotal());

        metrics.recordPrimaryDiscovery();
        metrics.recordPrimaryDiscovery();

        assertEquals(2, metrics.getPrimaryDiscoveriesTotal());
    }

    // ========================================================================
    // Error Counter Tests
    // ========================================================================

    @Test
    void testErrorCountersByType() {
        metrics.recordError("insert", 1000000, "timeout");
        metrics.recordError("insert", 1000000, "timeout");
        metrics.recordError("query", 1000000, "not_found");

        assertEquals(2, metrics.getErrorCount("timeout"));
        assertEquals(1, metrics.getErrorCount("not_found"));
        assertEquals(0, metrics.getErrorCount("unknown_error"));
    }

    // ========================================================================
    // Thread Safety Tests
    // ========================================================================

    @Test
    void testConcurrentUpdates() throws InterruptedException {
        int threadCount = 10;
        int operationsPerThread = 1000;
        ExecutorService executor = Executors.newFixedThreadPool(threadCount);
        CountDownLatch latch = new CountDownLatch(threadCount);

        for (int t = 0; t < threadCount; t++) {
            executor.submit(() -> {
                try {
                    for (int i = 0; i < operationsPerThread; i++) {
                        metrics.recordSuccess("insert", 1000000);
                        metrics.recordRetry();
                        metrics.connectionOpened();
                        metrics.connectionClosed();
                    }
                } finally {
                    latch.countDown();
                }
            });
        }

        assertTrue(latch.await(10, TimeUnit.SECONDS));
        executor.shutdown();

        assertEquals(threadCount * operationsPerThread,
                metrics.getRequestCount("insert", "success"));
        assertEquals(threadCount * operationsPerThread, metrics.getRetriesTotal());
        assertEquals(0, metrics.getConnectionsActive()); // Opens and closes balance
    }

    // ========================================================================
    // Prometheus Export Tests
    // ========================================================================

    @Test
    void testPrometheusExportFormat() {
        metrics.recordSuccess("insert", 1_000_000_000L);
        metrics.recordError("query_radius", 2_000_000_000L, "timeout");
        metrics.connectionOpened();
        metrics.recordReconnection();
        metrics.recordRetry();
        metrics.recordRetryExhausted();

        String prometheus = metrics.exportPrometheus();

        // Verify HELP and TYPE comments
        assertTrue(prometheus.contains("# HELP archerdb_client_requests_total"));
        assertTrue(prometheus.contains("# TYPE archerdb_client_requests_total counter"));
        assertTrue(prometheus.contains("# HELP archerdb_client_connections_active"));
        assertTrue(prometheus.contains("# TYPE archerdb_client_connections_active gauge"));

        // Verify metric values with labels
        assertTrue(prometheus.contains(
                "archerdb_client_requests_total{operation=\"insert\",status=\"success\"}"));
        assertTrue(prometheus.contains("archerdb_client_connections_active 1"));
        assertTrue(prometheus.contains("archerdb_client_reconnections_total 1"));
        assertTrue(prometheus.contains("archerdb_client_retries_total 1"));
        assertTrue(prometheus.contains("archerdb_client_retry_exhausted_total 1"));
    }

    @Test
    void testPrometheusExportEmptyMetrics() {
        String prometheus = metrics.exportPrometheus();

        // Should still have HELP and TYPE headers even if empty
        assertTrue(prometheus.contains("# HELP"));
        assertTrue(prometheus.contains("# TYPE"));
        assertTrue(prometheus.contains("archerdb_client_connections_active 0"));
    }

    // ========================================================================
    // Reset Tests
    // ========================================================================

    @Test
    void testResetClearsAllMetrics() {
        metrics.recordSuccess("insert", 1000000);
        metrics.recordError("query", 1000000, "timeout");
        metrics.connectionOpened();
        metrics.recordReconnection();
        metrics.recordRetry();
        metrics.recordRetryExhausted();
        metrics.recordSessionRenewal();
        metrics.recordPrimaryDiscovery();

        metrics.reset();

        assertEquals(0, metrics.getRequestCount("insert", "success"));
        assertEquals(0, metrics.getRequestCount("query", "error"));
        assertEquals(0, metrics.getErrorCount("timeout"));
        assertEquals(0, metrics.getConnectionsActive());
        assertEquals(0, metrics.getReconnectionsTotal());
        assertEquals(0, metrics.getRetriesTotal());
        assertEquals(0, metrics.getRetryExhaustedTotal());
        assertEquals(0, metrics.getSessionRenewalsTotal());
        assertEquals(0, metrics.getPrimaryDiscoveriesTotal());
        assertEquals(0.0, metrics.getAverageDurationSeconds("insert"));
    }

    // ========================================================================
    // Global Instance Tests
    // ========================================================================

    @Test
    void testGlobalInstanceIsSingleton() {
        ClientMetrics global1 = ClientMetrics.global();
        ClientMetrics global2 = ClientMetrics.global();

        assertSame(global1, global2);
    }

    @Test
    void testGlobalInstanceSharedAcrossThreads() throws InterruptedException {
        ClientMetrics global = ClientMetrics.global();

        Thread thread1 = new Thread(() -> {
            global.recordSuccess("thread_op", 1000000);
        });

        Thread thread2 = new Thread(() -> {
            global.recordSuccess("thread_op", 1000000);
        });

        thread1.start();
        thread2.start();
        thread1.join();
        thread2.join();

        assertEquals(2, global.getRequestCount("thread_op", "success"));
    }
}
