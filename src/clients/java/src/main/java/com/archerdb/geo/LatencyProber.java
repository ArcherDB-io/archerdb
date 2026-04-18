// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Background latency prober for multi-region clients. Mirrors {@code geo_routing.LatencyProber}
 * from the Python SDK.
 *
 * <p>
 * The prober periodically TCP-connects to each region's first configured address and records the
 * connect duration as a latency sample. Samples feed into {@link RegionLatencyStats}, which
 * {@link MultiRegionGeoClient#selectReadClient()} consults for {@link ReadPreference#NEAREST}
 * routing.
 *
 * <p>
 * Design choices:
 * <ul>
 * <li>A single daemon thread handles all regions sequentially. Java clients rarely have more than a
 * handful of regions, so a thread-pool is unwarranted and would complicate lifecycle.</li>
 * <li>TCP connect time is the probe signal, matching Python. It is a conservative proxy for RTT —
 * slightly biased high by local TCP stack overhead, but comparable across regions.</li>
 * <li>Failures are swallowed and recorded as such. Network unreachable, connection refused, and
 * connect timeouts all map to {@link RegionLatencyStats#recordFailure(int)}.</li>
 * <li>{@link #recordSample(String, long)} / {@link #recordFailure(String)} are package-private for
 * tests to seed stats without starting the thread or opening sockets.</li>
 * </ul>
 *
 * <p>
 * Thread-safety: {@code stats} is a {@link ConcurrentHashMap}. Individual
 * {@link RegionLatencyStats} instances synchronize internally. Lifecycle methods {@link #start()} /
 * {@link #stop()} are idempotent.
 */
final class LatencyProber {

    private final List<RegionConfig> regions;
    private final int probeIntervalMs;
    private final int probeTimeoutMs;
    private final int unhealthyThreshold;
    private final Map<String, RegionLatencyStats> stats;
    private volatile Thread thread;
    private volatile boolean running = false;

    LatencyProber(List<RegionConfig> regions, int probeIntervalMs, int probeTimeoutMs,
            int sampleWindow, int unhealthyThreshold) {
        if (probeIntervalMs <= 0) {
            throw new IllegalArgumentException("probeIntervalMs must be positive");
        }
        if (probeTimeoutMs <= 0) {
            throw new IllegalArgumentException("probeTimeoutMs must be positive");
        }
        this.regions = regions;
        this.probeIntervalMs = probeIntervalMs;
        this.probeTimeoutMs = probeTimeoutMs;
        this.unhealthyThreshold = unhealthyThreshold;
        this.stats = new ConcurrentHashMap<>(regions.size() * 2);
        for (RegionConfig r : regions) {
            stats.put(r.getName(), new RegionLatencyStats(r.getName(), sampleWindow));
        }
    }

    /** Start the background probe thread. Idempotent. */
    synchronized void start() {
        if (running)
            return;
        running = true;
        thread = new Thread(this::probeLoop, "archerdb-latency-prober");
        thread.setDaemon(true);
        thread.start();
    }

    /** Stop the background probe thread. Idempotent. Waits up to 2 seconds for thread exit. */
    synchronized void stop() {
        if (!running)
            return;
        running = false;
        Thread t = thread;
        thread = null;
        if (t != null) {
            t.interrupt();
            try {
                t.join(2000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }

    RegionLatencyStats getStats(String regionName) {
        return stats.get(regionName);
    }

    Map<String, RegionLatencyStats> getAllStats() {
        return stats;
    }

    /**
     * Seed a successful probe directly. Intended for tests so latency-aware selection can be
     * exercised without opening real sockets. Not part of the public SDK surface.
     */
    void recordSample(String regionName, long rttNanos) {
        RegionLatencyStats s = stats.get(regionName);
        if (s != null)
            s.addSample(rttNanos);
    }

    /**
     * Seed a probe failure directly. Test-only, same rationale as {@link #recordSample}.
     */
    void recordFailure(String regionName) {
        RegionLatencyStats s = stats.get(regionName);
        if (s != null)
            s.recordFailure(unhealthyThreshold);
    }

    private void probeLoop() {
        while (running) {
            probeAllRegions();
            try {
                Thread.sleep(probeIntervalMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    private void probeAllRegions() {
        for (RegionConfig region : regions) {
            if (!running)
                return;
            probeRegion(region);
        }
    }

    private void probeRegion(RegionConfig region) {
        String[] addresses = region.getAddresses();
        if (addresses == null || addresses.length == 0) {
            recordFailure(region.getName());
            return;
        }
        HostPort hp = parseHostPort(addresses[0]);
        if (hp == null) {
            recordFailure(region.getName());
            return;
        }
        long start = System.nanoTime();
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(hp.host, hp.port), probeTimeoutMs);
            long rtt = System.nanoTime() - start;
            recordSample(region.getName(), rtt);
        } catch (IOException e) {
            // Probe failures are expected under network partitions or when a region is
            // temporarily down — the health model handles those. Detailed logging would need a
            // module dependency on java.logging that this SDK deliberately does not declare.
            recordFailure(region.getName());
        }
    }

    private static HostPort parseHostPort(String address) {
        if (address == null)
            return null;
        String trimmed = address.trim();
        if (trimmed.isEmpty())
            return null;
        int colon = trimmed.lastIndexOf(':');
        if (colon < 0)
            return null;
        String host = trimmed.substring(0, colon);
        String portStr = trimmed.substring(colon + 1);
        try {
            int port = Integer.parseInt(portStr);
            if (port <= 0 || port > 65535)
                return null;
            return new HostPort(host, port);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static final class HostPort {
        final String host;
        final int port;

        HostPort(String host, int port) {
            this.host = host;
            this.port = port;
        }
    }
}
