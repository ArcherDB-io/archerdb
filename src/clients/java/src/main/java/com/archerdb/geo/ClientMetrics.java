// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Client-side metrics for SDK observability.
 *
 * <p>
 * Per client-sdk/spec.md and observability/spec.md, the SDK exposes:
 * <ul>
 * <li>archerdb_client_requests_total{operation, status}</li>
 * <li>archerdb_client_request_duration_seconds{operation}</li>
 * <li>archerdb_client_connections_active</li>
 * <li>archerdb_client_reconnections_total</li>
 * <li>archerdb_client_session_renewals_total</li>
 * <li>archerdb_client_retries_total</li>
 * <li>archerdb_client_retry_exhausted_total</li>
 * </ul>
 *
 * <p>
 * This class provides a simple in-memory metrics store that can be exported to Prometheus,
 * OpenTelemetry, or other monitoring systems.
 *
 * <p>
 * Thread-safe for concurrent updates from multiple threads.
 */
public final class ClientMetrics {

    /**
     * Shared global metrics instance.
     */
    private static final ClientMetrics GLOBAL = new ClientMetrics();

    // Request counters by operation and status
    private final Map<String, AtomicLong> requestCounters = new ConcurrentHashMap<>();

    // Duration histograms by operation (simplified as sum for now)
    private final Map<String, AtomicLong> durationSumNanos = new ConcurrentHashMap<>();
    private final Map<String, AtomicLong> durationCounts = new ConcurrentHashMap<>();

    // Connection metrics
    private final AtomicLong connectionsActive = new AtomicLong(0);
    private final AtomicLong reconnectionsTotal = new AtomicLong(0);
    private final AtomicLong sessionRenewalsTotal = new AtomicLong(0);

    // Retry metrics
    private final AtomicLong retriesTotal = new AtomicLong(0);
    private final AtomicLong retryExhaustedTotal = new AtomicLong(0);
    private final AtomicLong primaryDiscoveriesTotal = new AtomicLong(0);

    // Error metrics
    private final Map<String, AtomicLong> errorCounters = new ConcurrentHashMap<>();

    /**
     * Returns the global metrics instance.
     */
    public static ClientMetrics global() {
        return GLOBAL;
    }

    /**
     * Records a request completion.
     *
     * @param operation the operation name (e.g., "insert", "query_radius")
     * @param status "success" or "error"
     * @param durationNanos duration in nanoseconds
     */
    public void recordRequest(String operation, String status, long durationNanos) {
        String key = operation + "_" + status;
        requestCounters.computeIfAbsent(key, k -> new AtomicLong(0)).incrementAndGet();

        durationSumNanos.computeIfAbsent(operation, k -> new AtomicLong(0))
                .addAndGet(durationNanos);
        durationCounts.computeIfAbsent(operation, k -> new AtomicLong(0)).incrementAndGet();
    }

    /**
     * Records a successful request.
     */
    public void recordSuccess(String operation, long durationNanos) {
        recordRequest(operation, "success", durationNanos);
    }

    /**
     * Records a failed request.
     */
    public void recordError(String operation, long durationNanos, String errorType) {
        recordRequest(operation, "error", durationNanos);
        errorCounters.computeIfAbsent(errorType, k -> new AtomicLong(0)).incrementAndGet();
    }

    /**
     * Records a connection becoming active.
     */
    public void connectionOpened() {
        connectionsActive.incrementAndGet();
    }

    /**
     * Records a connection closing.
     */
    public void connectionClosed() {
        connectionsActive.decrementAndGet();
    }

    /**
     * Records a reconnection attempt.
     */
    public void recordReconnection() {
        reconnectionsTotal.incrementAndGet();
    }

    /**
     * Records a session renewal.
     */
    public void recordSessionRenewal() {
        sessionRenewalsTotal.incrementAndGet();
    }

    /**
     * Records a retry attempt.
     */
    public void recordRetry() {
        retriesTotal.incrementAndGet();
    }

    /**
     * Records retry exhaustion (all retries failed).
     */
    public void recordRetryExhausted() {
        retryExhaustedTotal.incrementAndGet();
    }

    /**
     * Records a primary discovery event.
     */
    public void recordPrimaryDiscovery() {
        primaryDiscoveriesTotal.incrementAndGet();
    }

    // Getters for metrics values

    public long getRequestCount(String operation, String status) {
        AtomicLong counter = requestCounters.get(operation + "_" + status);
        return counter != null ? counter.get() : 0;
    }

    public double getAverageDurationSeconds(String operation) {
        AtomicLong sum = durationSumNanos.get(operation);
        AtomicLong count = durationCounts.get(operation);
        if (sum == null || count == null || count.get() == 0) {
            return 0.0;
        }
        return sum.get() / (count.get() * 1_000_000_000.0);
    }

    public long getConnectionsActive() {
        return connectionsActive.get();
    }

    public long getReconnectionsTotal() {
        return reconnectionsTotal.get();
    }

    public long getSessionRenewalsTotal() {
        return sessionRenewalsTotal.get();
    }

    public long getRetriesTotal() {
        return retriesTotal.get();
    }

    public long getRetryExhaustedTotal() {
        return retryExhaustedTotal.get();
    }

    public long getPrimaryDiscoveriesTotal() {
        return primaryDiscoveriesTotal.get();
    }

    public long getErrorCount(String errorType) {
        AtomicLong counter = errorCounters.get(errorType);
        return counter != null ? counter.get() : 0;
    }

    /**
     * Exports metrics in Prometheus text format.
     */
    public String exportPrometheus() {
        StringBuilder sb = new StringBuilder();

        // Request counts
        sb.append("# HELP archerdb_client_requests_total Total client requests\n");
        sb.append("# TYPE archerdb_client_requests_total counter\n");
        for (Map.Entry<String, AtomicLong> entry : requestCounters.entrySet()) {
            String[] parts = entry.getKey().split("_");
            if (parts.length >= 2) {
                String operation = parts[0];
                String status = parts[parts.length - 1];
                sb.append(String.format(
                        "archerdb_client_requests_total{operation=\"%s\",status=\"%s\"} %d%n",
                        operation, status, entry.getValue().get()));
            }
        }

        // Connection metrics
        sb.append("# HELP archerdb_client_connections_active Active connections\n");
        sb.append("# TYPE archerdb_client_connections_active gauge\n");
        sb.append(
                String.format("archerdb_client_connections_active %d%n", connectionsActive.get()));

        sb.append("# HELP archerdb_client_reconnections_total Total reconnections\n");
        sb.append("# TYPE archerdb_client_reconnections_total counter\n");
        sb.append(String.format("archerdb_client_reconnections_total %d%n",
                reconnectionsTotal.get()));

        // Retry metrics
        sb.append("# HELP archerdb_client_retries_total Total retry attempts\n");
        sb.append("# TYPE archerdb_client_retries_total counter\n");
        sb.append(String.format("archerdb_client_retries_total %d%n", retriesTotal.get()));

        sb.append("# HELP archerdb_client_retry_exhausted_total Exhausted retries\n");
        sb.append("# TYPE archerdb_client_retry_exhausted_total counter\n");
        sb.append(String.format("archerdb_client_retry_exhausted_total %d%n",
                retryExhaustedTotal.get()));

        return sb.toString();
    }

    /**
     * Resets all metrics (useful for testing).
     */
    public void reset() {
        requestCounters.clear();
        durationSumNanos.clear();
        durationCounts.clear();
        connectionsActive.set(0);
        reconnectionsTotal.set(0);
        sessionRenewalsTotal.set(0);
        retriesTotal.set(0);
        retryExhaustedTotal.set(0);
        primaryDiscoveriesTotal.set(0);
        errorCounters.clear();
    }
}
