package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

/**
 * Unit tests for SessionManager.
 *
 * <p>
 * Per client-sdk/spec.md session management requirements:
 * <ul>
 * <li>Generate random client_id (persistent per SDK instance)</li>
 * <li>Maintain monotonic request_number per session</li>
 * <li>Session expiration handling</li>
 * </ul>
 */
class SessionManagerTest {

    // ========================================================================
    // Client ID Tests
    // ========================================================================

    @Test
    void testClientIdIsGenerated() {
        SessionManager manager = new SessionManager();

        assertNotNull(manager.getClientId());
    }

    @Test
    void testClientIdIsPersistentPerInstance() {
        SessionManager manager = new SessionManager();

        UInt128 clientId1 = manager.getClientId();
        UInt128 clientId2 = manager.getClientId();

        assertEquals(clientId1, clientId2, "Client ID should be persistent per instance");
    }

    @Test
    void testClientIdIsDifferentAcrossInstances() {
        SessionManager manager1 = new SessionManager();
        SessionManager manager2 = new SessionManager();

        assertNotEquals(manager1.getClientId(), manager2.getClientId(),
                "Different instances should have different client IDs");
    }

    // ========================================================================
    // Request Number Tests
    // ========================================================================

    @Test
    void testRequestNumberStartsAtZero() {
        SessionManager manager = new SessionManager();

        assertEquals(0, manager.currentRequestNumber());
    }

    @Test
    void testRequestNumberIncrementsMonotonically() {
        SessionManager manager = new SessionManager();

        assertEquals(1, manager.nextRequestNumber());
        assertEquals(2, manager.nextRequestNumber());
        assertEquals(3, manager.nextRequestNumber());
    }

    @Test
    void testCurrentRequestNumberDoesNotIncrement() {
        SessionManager manager = new SessionManager();

        manager.nextRequestNumber(); // -> 1
        manager.nextRequestNumber(); // -> 2

        assertEquals(2, manager.currentRequestNumber());
        assertEquals(2, manager.currentRequestNumber());
    }

    @Test
    void testRequestNumberIsThreadSafe() throws InterruptedException {
        SessionManager manager = new SessionManager();
        int threadCount = 10;
        int incrementsPerThread = 1000;

        Thread[] threads = new Thread[threadCount];
        for (int i = 0; i < threadCount; i++) {
            threads[i] = new Thread(() -> {
                for (int j = 0; j < incrementsPerThread; j++) {
                    manager.nextRequestNumber();
                }
            });
        }

        for (Thread thread : threads) {
            thread.start();
        }
        for (Thread thread : threads) {
            thread.join();
        }

        assertEquals(threadCount * incrementsPerThread, manager.currentRequestNumber(),
                "All increments should be counted");
    }

    // ========================================================================
    // Session Registration Tests
    // ========================================================================

    @Test
    void testInitiallyNotRegistered() {
        SessionManager manager = new SessionManager();

        assertFalse(manager.isRegistered());
        assertEquals(0, manager.getSessionId());
    }

    @Test
    void testRegisterSession() {
        SessionManager manager = new SessionManager();
        long sessionId = 12345L;

        manager.register(sessionId);

        assertTrue(manager.isRegistered());
        assertEquals(sessionId, manager.getSessionId());
    }

    @Test
    void testClearSession() {
        SessionManager manager = new SessionManager();
        manager.register(12345L);
        manager.nextRequestNumber(); // -> 1
        manager.nextRequestNumber(); // -> 2

        manager.clearSession();

        assertFalse(manager.isRegistered());
        assertEquals(0, manager.getSessionId());
        // Request number should NOT be reset
        assertEquals(2, manager.currentRequestNumber());
    }

    // ========================================================================
    // Session Expiration Tests
    // ========================================================================

    @Test
    void testInitiallyNotExpired() {
        SessionManager manager = new SessionManager();

        assertFalse(manager.isExpired());
    }

    @Test
    void testExpiresAfterTimeout() throws InterruptedException {
        // Use very short timeout for testing
        SessionManager manager = new SessionManager(50);

        assertFalse(manager.isExpired());

        Thread.sleep(100);

        assertTrue(manager.isExpired());
    }

    @Test
    void testActivityUpdatesExpiration() throws InterruptedException {
        SessionManager manager = new SessionManager(100);

        Thread.sleep(60);
        assertFalse(manager.isExpired());

        manager.updateActivity();

        Thread.sleep(60);
        assertFalse(manager.isExpired(), "Activity should reset expiration");
    }

    @Test
    void testNextRequestNumberUpdatesActivity() throws InterruptedException {
        SessionManager manager = new SessionManager(100);

        Thread.sleep(60);
        manager.nextRequestNumber(); // Should update activity

        Thread.sleep(60);
        assertFalse(manager.isExpired());
    }

    @Test
    void testTimeUntilExpiration() {
        SessionManager manager = new SessionManager(1000);

        long remaining = manager.timeUntilExpirationMs();

        assertTrue(remaining > 0 && remaining <= 1000);
    }

    @Test
    void testTimeUntilExpirationZeroWhenExpired() throws InterruptedException {
        SessionManager manager = new SessionManager(10);

        Thread.sleep(50);

        assertEquals(0, manager.timeUntilExpirationMs());
    }

    // ========================================================================
    // Request Header Tests
    // ========================================================================

    @Test
    void testCreateHeader() {
        SessionManager manager = new SessionManager();
        manager.register(54321L);

        SessionManager.RequestHeader header = manager.createHeader();

        assertEquals(manager.getClientId(), header.getClientId());
        assertEquals(1, header.getRequestNumber());
        assertEquals(54321L, header.getSessionId());
    }

    @Test
    void testHeaderRequestNumberIncrements() {
        SessionManager manager = new SessionManager();

        SessionManager.RequestHeader header1 = manager.createHeader();
        SessionManager.RequestHeader header2 = manager.createHeader();

        assertEquals(1, header1.getRequestNumber());
        assertEquals(2, header2.getRequestNumber());
    }

    @Test
    void testHeaderToString() {
        SessionManager manager = new SessionManager();
        manager.register(123L);

        SessionManager.RequestHeader header = manager.createHeader();

        String str = header.toString();
        assertTrue(str.contains("clientId"));
        assertTrue(str.contains("requestNumber"));
        assertTrue(str.contains("sessionId"));
    }

    // ========================================================================
    // Configuration Tests
    // ========================================================================

    @Test
    void testDefaultSessionTimeout() {
        SessionManager manager = new SessionManager();

        assertEquals(SessionManager.DEFAULT_SESSION_TIMEOUT_MS, manager.getSessionTimeoutMs());
    }

    @Test
    void testCustomSessionTimeout() {
        SessionManager manager = new SessionManager(120_000);

        assertEquals(120_000, manager.getSessionTimeoutMs());
    }

    @Test
    void testDefaultTimeoutIs60Seconds() {
        assertEquals(60_000, SessionManager.DEFAULT_SESSION_TIMEOUT_MS);
    }
}
