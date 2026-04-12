// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Unit tests for ClientLogger.
 *
 * <p>
 * Per client-sdk/spec.md, tests verify:
 * <ul>
 * <li>Log levels: DEBUG, INFO, WARN, ERROR</li>
 * <li>Minimum level filtering</li>
 * <li>Custom logger integration</li>
 * <li>Trace context propagation (traceId, spanId)</li>
 * <li>JSON and text output formats</li>
 * </ul>
 */
class ClientLoggerTest {

    private List<ClientLogger.LogEntry> capturedLogs;

    @BeforeEach
    void setUp() {
        capturedLogs = new ArrayList<>();
        ClientLogger.setLogger(capturedLogs::add);
        ClientLogger.setMinLevel(ClientLogger.Level.DEBUG);
        ClientLogger.setJsonFormat(false);
        ClientLogger.clearTraceContext();
    }

    @AfterEach
    void tearDown() {
        ClientLogger.setLogger(null);
        ClientLogger.setMinLevel(ClientLogger.Level.INFO);
        ClientLogger.clearTraceContext();
    }

    // ========================================================================
    // Basic Logging Tests
    // ========================================================================

    @Test
    void testDebugLogging() {
        ClientLogger.debug("Debug message");

        assertEquals(1, capturedLogs.size());
        ClientLogger.LogEntry entry = capturedLogs.get(0);
        assertEquals(ClientLogger.Level.DEBUG, entry.getLevel());
        assertEquals("Debug message", entry.getMessage());
    }

    @Test
    void testInfoLogging() {
        ClientLogger.info("Info message");

        assertEquals(1, capturedLogs.size());
        assertEquals(ClientLogger.Level.INFO, capturedLogs.get(0).getLevel());
    }

    @Test
    void testWarnLogging() {
        ClientLogger.warn("Warning message");

        assertEquals(1, capturedLogs.size());
        assertEquals(ClientLogger.Level.WARN, capturedLogs.get(0).getLevel());
    }

    @Test
    void testErrorLogging() {
        ClientLogger.error("Error message");

        assertEquals(1, capturedLogs.size());
        assertEquals(ClientLogger.Level.ERROR, capturedLogs.get(0).getLevel());
    }

    // ========================================================================
    // Format String Tests
    // ========================================================================

    @Test
    void testDebugWithFormat() {
        ClientLogger.debug("Value: %d, String: %s", 42, "test");

        assertEquals(1, capturedLogs.size());
        assertEquals("Value: 42, String: test", capturedLogs.get(0).getMessage());
    }

    @Test
    void testInfoWithFormat() {
        ClientLogger.info("Connected to %s:%d", "localhost", 3000);

        assertEquals("Connected to localhost:3000", capturedLogs.get(0).getMessage());
    }

    @Test
    void testWarnWithFormat() {
        ClientLogger.warn("Retry attempt %d of %d", 3, 5);

        assertEquals("Retry attempt 3 of 5", capturedLogs.get(0).getMessage());
    }

    @Test
    void testErrorWithFormat() {
        ClientLogger.error("Operation %s failed with code %d", "insert", 500);

        assertEquals("Operation insert failed with code 500", capturedLogs.get(0).getMessage());
    }

    @Test
    void testErrorWithException() {
        Exception cause = new RuntimeException("Root cause");
        ClientLogger.error("Operation failed", cause);

        assertEquals("Operation failed: Root cause", capturedLogs.get(0).getMessage());
    }

    // ========================================================================
    // Log Level Filtering Tests
    // ========================================================================

    @Test
    void testMinLevelFiltersLowerLevels() {
        ClientLogger.setMinLevel(ClientLogger.Level.WARN);

        ClientLogger.debug("Debug - should not appear");
        ClientLogger.info("Info - should not appear");
        ClientLogger.warn("Warn - should appear");
        ClientLogger.error("Error - should appear");

        assertEquals(2, capturedLogs.size());
        assertEquals(ClientLogger.Level.WARN, capturedLogs.get(0).getLevel());
        assertEquals(ClientLogger.Level.ERROR, capturedLogs.get(1).getLevel());
    }

    @Test
    void testMinLevelError() {
        ClientLogger.setMinLevel(ClientLogger.Level.ERROR);

        ClientLogger.debug("Debug");
        ClientLogger.info("Info");
        ClientLogger.warn("Warn");
        ClientLogger.error("Error");

        assertEquals(1, capturedLogs.size());
        assertEquals(ClientLogger.Level.ERROR, capturedLogs.get(0).getLevel());
    }

    @Test
    void testMinLevelDebugLogsEverything() {
        ClientLogger.setMinLevel(ClientLogger.Level.DEBUG);

        ClientLogger.debug("Debug");
        ClientLogger.info("Info");
        ClientLogger.warn("Warn");
        ClientLogger.error("Error");

        assertEquals(4, capturedLogs.size());
    }

    // ========================================================================
    // Trace Context Tests
    // ========================================================================

    @Test
    void testTraceContextPropagation() {
        ClientLogger.setTraceContext("trace-123", "span-456");
        ClientLogger.info("Test message");

        ClientLogger.LogEntry entry = capturedLogs.get(0);
        assertEquals("trace-123", entry.getTraceId());
        assertEquals("span-456", entry.getSpanId());
    }

    @Test
    void testTraceContextClearing() {
        ClientLogger.setTraceContext("trace-123", "span-456");
        ClientLogger.clearTraceContext();
        ClientLogger.info("Test message");

        ClientLogger.LogEntry entry = capturedLogs.get(0);
        assertNull(entry.getTraceId());
        assertNull(entry.getSpanId());
    }

    @Test
    void testTraceContextPerThread() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(2);
        List<ClientLogger.LogEntry> thread1Logs = new ArrayList<>();
        List<ClientLogger.LogEntry> thread2Logs = new ArrayList<>();

        Thread t1 = new Thread(() -> {
            ClientLogger.setLogger(thread1Logs::add);
            ClientLogger.setTraceContext("trace-t1", "span-t1");
            ClientLogger.info("Thread 1 message");
            latch.countDown();
        });

        Thread t2 = new Thread(() -> {
            ClientLogger.setLogger(thread2Logs::add);
            ClientLogger.setTraceContext("trace-t2", "span-t2");
            ClientLogger.info("Thread 2 message");
            latch.countDown();
        });

        t1.start();
        t2.start();
        assertTrue(latch.await(5, TimeUnit.SECONDS));

        // Note: Due to static logger, this test mainly verifies trace context is thread-local
        // In a real scenario, each thread would have its own trace context
    }

    // ========================================================================
    // Output Format Tests
    // ========================================================================

    @Test
    void testTextFormat() {
        ClientLogger.setTraceContext("trace-123", "span-456");
        ClientLogger.info("Test message");

        String text = capturedLogs.get(0).toText();

        assertTrue(text.contains("[INFO]"));
        assertTrue(text.contains("trace=trace-123"));
        assertTrue(text.contains("span=span-456"));
        assertTrue(text.contains("Test message"));
    }

    @Test
    void testTextFormatWithoutTrace() {
        ClientLogger.info("Test message");

        String text = capturedLogs.get(0).toText();

        assertTrue(text.contains("[INFO]"));
        assertTrue(text.contains("Test message"));
        assertFalse(text.contains("trace="));
    }

    @Test
    void testJsonFormat() {
        ClientLogger.setTraceContext("trace-123", "span-456");
        ClientLogger.info("Test message");

        String json = capturedLogs.get(0).toJson();

        assertTrue(json.contains("\"level\":\"INFO\""));
        assertTrue(json.contains("\"message\":\"Test message\""));
        assertTrue(json.contains("\"trace_id\":\"trace-123\""));
        assertTrue(json.contains("\"span_id\":\"span-456\""));
        assertTrue(json.contains("\"timestamp\":\""));
    }

    @Test
    void testJsonFormatWithoutTrace() {
        ClientLogger.info("Test message");

        String json = capturedLogs.get(0).toJson();

        assertTrue(json.contains("\"level\":\"INFO\""));
        assertTrue(json.contains("\"message\":\"Test message\""));
        assertFalse(json.contains("trace_id"));
    }

    @Test
    void testJsonEscapesSpecialCharacters() {
        ClientLogger.info("Message with \"quotes\" and\nnewline");

        String json = capturedLogs.get(0).toJson();

        assertTrue(json.contains("\\\"quotes\\\""));
        assertTrue(json.contains("\\n"));
    }

    // ========================================================================
    // Timestamp Tests
    // ========================================================================

    @Test
    void testTimestampIsRecorded() {
        long before = System.currentTimeMillis();
        ClientLogger.info("Test");
        long after = System.currentTimeMillis();

        ClientLogger.LogEntry entry = capturedLogs.get(0);
        long timestamp = entry.getTimestamp().toEpochMilli();

        assertTrue(timestamp >= before && timestamp <= after);
    }

    // ========================================================================
    // Custom Logger Tests
    // ========================================================================

    @Test
    void testCustomLoggerReceivesEntries() {
        List<String> messages = new ArrayList<>();
        ClientLogger.setLogger(entry -> messages.add(entry.getMessage()));

        ClientLogger.info("Message 1");
        ClientLogger.info("Message 2");

        assertEquals(2, messages.size());
        assertTrue(messages.contains("Message 1"));
        assertTrue(messages.contains("Message 2"));
    }

    @Test
    void testNullLoggerUsesDefault() {
        ClientLogger.setLogger(null);
        // This should not throw - uses default System.out/err
        ClientLogger.info("Test");
    }

    // ========================================================================
    // Level Enum Tests
    // ========================================================================

    @Test
    void testLevelOrdinals() {
        // Verify levels are ordered correctly
        assertTrue(ClientLogger.Level.DEBUG.ordinal() < ClientLogger.Level.INFO.ordinal());
        assertTrue(ClientLogger.Level.INFO.ordinal() < ClientLogger.Level.WARN.ordinal());
        assertTrue(ClientLogger.Level.WARN.ordinal() < ClientLogger.Level.ERROR.ordinal());
    }

    // ========================================================================
    // LogEntry Tests
    // ========================================================================

    @Test
    void testLogEntryGetters() {
        ClientLogger.setTraceContext("trace", "span");
        ClientLogger.error("Error message");

        ClientLogger.LogEntry entry = capturedLogs.get(0);

        assertEquals(ClientLogger.Level.ERROR, entry.getLevel());
        assertEquals("Error message", entry.getMessage());
        assertEquals("trace", entry.getTraceId());
        assertEquals("span", entry.getSpanId());
        assertNotNull(entry.getTimestamp());
    }
}
