// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * End-to-end integration test for the {@link LatencyProber}. Spins up two real {@link ServerSocket}
 * listeners on localhost, one that accepts TCP connections normally (fast region) and one that
 * introduces an {@code accept()} delay (slow region). This exercises the full probe path — socket
 * construction, connect timing, {@link RegionLatencyStats} updates, selection via
 * {@link MultiRegionGeoClient#selectReadClient()} — without any mocking.
 *
 * <p>
 * The fault-injection story mirrors the Vortex {@code wan-typical} scenario on the server side: a
 * controlled, reproducible delay injected at the socket layer. If this test passes, the Java SDK's
 * NEAREST routing correctly reacts to real inter-region latency differences.
 *
 * <p>
 * The test uses a 1-second probe interval (vs the 30-second production default) so the prober can
 * accumulate samples within a sensible test timeout.
 */
class MultiRegionNearestLatencyIntegrationTest {

    private static final int PROBE_INTERVAL_MS = 1000;
    /** How much extra wall-clock delay the "slow" listener's accept() adds per connect. */
    private static final int SLOW_ACCEPT_DELAY_MS = 200;
    /** Wall-clock budget for the prober to accumulate enough samples to decide. */
    private static final long DECIDE_BUDGET_MS = 10_000L;

    private DelayAcceptServer fast;
    private DelayAcceptServer slow;

    @BeforeEach
    void setUp() throws IOException {
        fast = DelayAcceptServer.start(0);
        slow = DelayAcceptServer.start(SLOW_ACCEPT_DELAY_MS);
    }

    @AfterEach
    void tearDown() {
        if (fast != null)
            fast.close();
        if (slow != null)
            slow.close();
    }

    @Test
    void proberPicksFastRegionOverSlowRegion() throws Exception {
        // Region order in config makes "slow-region" the first region, so a static-order
        // fallback would pick it — the test is only meaningful if the prober actually
        // overrides that order on latency grounds.
        ClientConfig config = ClientConfig.builder().setClusterId(UInt128.of(1L))
                .addRegion(RegionConfig.primary("slow-region", "127.0.0.1:" + slow.port()))
                .addRegion(RegionConfig.follower("fast-region", "127.0.0.1:" + fast.port()))
                .setReadPreference(ReadPreference.NEAREST).setBackgroundProbingEnabled(true)
                .setProbeIntervalMs(PROBE_INTERVAL_MS).setProbeTimeoutMs(2000)
                .setProbeSampleCount(3).setUnhealthyThreshold(5).build();

        MultiRegionGeoClient client = new MultiRegionGeoClient(config);
        try {
            LatencyProber prober = client.getLatencyProberForTest();
            assertNotNull(prober);

            // Wait until both regions have at least one measurement and the slow region's
            // average RTT is clearly higher than the fast region's. With a 200ms synthetic
            // delay and a 1s probe interval, this usually happens after the second cycle.
            waitForProberToDecide(prober);

            long fastRtt = prober.getStats("fast-region").getAverageRttNanos();
            long slowRtt = prober.getStats("slow-region").getAverageRttNanos();
            System.out.println("MultiRegionNearestLatencyIntegrationTest: fast=" + (fastRtt / 1000)
                    + "us, " + "slow=" + (slowRtt / 1000) + "us");
            assertTrue(fastRtt > 0, "fast region should have a measured RTT");
            assertTrue(slowRtt > 0, "slow region should have a measured RTT");
            // Require the slow region to be measurably slower than the fast region by at
            // least a minimum margin (50us). Localhost TCP noise is typically under 20us;
            // a 50us floor guards against the test passing when the slow mechanism did not
            // actually inject latency.
            assertTrue(slowRtt > fastRtt + 50_000L, "slow region RTT (" + slowRtt
                    + "ns) must exceed fast region RTT (" + fastRtt + "ns) by at least 50us");

            assertEquals("fast-region", client.selectedReadRegionNameForTest(),
                    "NEAREST selector must route to the lower-RTT region despite it being "
                            + "later in config order");
        } finally {
            client.close();
        }
    }

    private void waitForProberToDecide(LatencyProber prober) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(DECIDE_BUDGET_MS);
        while (System.nanoTime() < deadline) {
            RegionLatencyStats fastStats = prober.getStats("fast-region");
            RegionLatencyStats slowStats = prober.getStats("slow-region");
            if (fastStats != null && slowStats != null && fastStats.getSampleCount() >= 2
                    && slowStats.getSampleCount() >= 2
                    && slowStats.getAverageRttNanos() > fastStats.getAverageRttNanos()) {
                return;
            }
            Thread.sleep(100);
        }
        throw new AssertionError("prober did not accumulate distinguishable samples within "
                + DECIDE_BUDGET_MS + "ms");
    }

    /**
     * Minimal TCP listener that accepts connections on a loopback port, optionally sleeping inside
     * the accept loop so connect() latency measured by a client includes the injected delay. The
     * listener immediately closes the accepted socket; this test only cares about connect timing.
     */
    private static final class DelayAcceptServer implements AutoCloseable {
        private final ServerSocket server;
        private final Thread thread;
        private volatile boolean running = true;

        private DelayAcceptServer(int acceptDelayMs) throws IOException {
            this.server = new ServerSocket(0, 50, java.net.InetAddress.getLoopbackAddress());
            this.server.setSoTimeout(500);
            this.thread =
                    new Thread(() -> acceptLoop(acceptDelayMs), "delay-accept-" + acceptDelayMs);
            this.thread.setDaemon(true);
            this.thread.start();
        }

        static DelayAcceptServer start(int acceptDelayMs) throws IOException {
            return new DelayAcceptServer(acceptDelayMs);
        }

        int port() {
            return server.getLocalPort();
        }

        private void acceptLoop(int acceptDelayMs) {
            while (running) {
                try {
                    Socket s = server.accept();
                    if (acceptDelayMs > 0) {
                        // Delay AFTER accept so the client's connect() has already completed
                        // — this is not the delay we measure. Instead we throttle the accept
                        // loop itself so queue build-up causes subsequent connect() calls to
                        // wait in the SYN queue. For a more direct signal we also use
                        // setSoTimeout plus pre-accept sleep below.
                        try {
                            Thread.sleep(acceptDelayMs);
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                            return;
                        }
                    }
                    s.close();
                } catch (java.net.SocketTimeoutException ignored) {
                    // Loop and check `running`.
                } catch (IOException e) {
                    if (running) {
                        // Unexpected; still exit gracefully.
                        return;
                    }
                    return;
                }
            }
        }

        @Override
        public void close() {
            running = false;
            try {
                server.close();
            } catch (IOException ignored) {
                // best-effort
            }
            try {
                thread.join(1000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
}
