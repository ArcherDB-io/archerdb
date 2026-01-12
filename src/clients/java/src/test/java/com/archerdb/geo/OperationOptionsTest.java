package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

/**
 * Tests for OperationOptions per-operation retry override.
 */
class OperationOptionsTest {

    @Test
    void testDefaultOptionsHasNoOverrides() {
        OperationOptions options = OperationOptions.DEFAULT;
        assertFalse(options.hasOverrides());
        assertNull(options.getMaxRetries());
        assertNull(options.getTimeoutMs());
        assertNull(options.getBaseBackoffMs());
        assertNull(options.getMaxBackoffMs());
        assertNull(options.getJitterEnabled());
    }

    @Test
    void testBuilderSetMaxRetries() {
        OperationOptions options = OperationOptions.builder().setMaxRetries(3).build();

        assertTrue(options.hasOverrides());
        assertEquals(Integer.valueOf(3), options.getMaxRetries());
        assertNull(options.getTimeoutMs());
    }

    @Test
    void testBuilderSetTimeoutMs() {
        OperationOptions options = OperationOptions.builder().setTimeoutMs(10000).build();

        assertTrue(options.hasOverrides());
        assertEquals(Long.valueOf(10000), options.getTimeoutMs());
        assertNull(options.getMaxRetries());
    }

    @Test
    void testBuilderSetAllOptions() {
        OperationOptions options = OperationOptions.builder().setMaxRetries(3).setTimeoutMs(10000)
                .setBaseBackoffMs(50).setMaxBackoffMs(500).setJitterEnabled(false).build();

        assertTrue(options.hasOverrides());
        assertEquals(Integer.valueOf(3), options.getMaxRetries());
        assertEquals(Long.valueOf(10000), options.getTimeoutMs());
        assertEquals(Long.valueOf(50), options.getBaseBackoffMs());
        assertEquals(Long.valueOf(500), options.getMaxBackoffMs());
        assertEquals(Boolean.FALSE, options.getJitterEnabled());
    }

    @Test
    void testConvenienceWithMaxRetries() {
        OperationOptions options = OperationOptions.withMaxRetries(2);

        assertTrue(options.hasOverrides());
        assertEquals(Integer.valueOf(2), options.getMaxRetries());
    }

    @Test
    void testConvenienceWithTimeout() {
        OperationOptions options = OperationOptions.withTimeout(5000);

        assertTrue(options.hasOverrides());
        assertEquals(Long.valueOf(5000), options.getTimeoutMs());
    }

    @Test
    void testConvenienceWithBothRetriesAndTimeout() {
        OperationOptions options = OperationOptions.with(3, 10000);

        assertTrue(options.hasOverrides());
        assertEquals(Integer.valueOf(3), options.getMaxRetries());
        assertEquals(Long.valueOf(10000), options.getTimeoutMs());
    }

    @Test
    void testToRetryPolicyNoOverrides() {
        RetryPolicy basePolicy = RetryPolicy.DEFAULT;
        OperationOptions options = OperationOptions.DEFAULT;

        RetryPolicy result = options.toRetryPolicy(basePolicy);

        // Should return the same base policy when no overrides
        assertSame(basePolicy, result);
    }

    @Test
    void testToRetryPolicyWithOverrides() {
        RetryPolicy basePolicy = RetryPolicy.DEFAULT;
        OperationOptions options =
                OperationOptions.builder().setMaxRetries(2).setTimeoutMs(5000).build();

        RetryPolicy result = options.toRetryPolicy(basePolicy);

        assertNotSame(basePolicy, result);
        assertEquals(2, result.getMaxRetries());
        assertEquals(5000, result.getTotalTimeoutMs());
        // Base policy values should be preserved for non-overridden options
        assertEquals(basePolicy.getBaseBackoffMs(), result.getBaseBackoffMs());
        assertEquals(basePolicy.getMaxBackoffMs(), result.getMaxBackoffMs());
        assertEquals(basePolicy.isJitterEnabled(), result.isJitterEnabled());
    }

    @Test
    void testToRetryPolicyPreservesNonOverriddenValues() {
        RetryPolicy basePolicy = RetryPolicy.builder().setMaxRetries(5).setTotalTimeoutMs(30000)
                .setBaseBackoffMs(100).setMaxBackoffMs(1600).setJitterEnabled(true).build();

        OperationOptions options = OperationOptions.builder().setMaxRetries(1) // Only override this
                .build();

        RetryPolicy result = options.toRetryPolicy(basePolicy);

        assertEquals(1, result.getMaxRetries()); // Overridden
        assertEquals(30000, result.getTotalTimeoutMs()); // Preserved
        assertEquals(100, result.getBaseBackoffMs()); // Preserved
        assertEquals(1600, result.getMaxBackoffMs()); // Preserved
        assertTrue(result.isJitterEnabled()); // Preserved
    }

    @Test
    void testInvalidMaxRetriesThrows() {
        assertThrows(IllegalArgumentException.class,
                () -> OperationOptions.builder().setMaxRetries(-1));
    }

    @Test
    void testInvalidTimeoutThrows() {
        assertThrows(IllegalArgumentException.class,
                () -> OperationOptions.builder().setTimeoutMs(0));
        assertThrows(IllegalArgumentException.class,
                () -> OperationOptions.builder().setTimeoutMs(-1));
    }

    @Test
    void testInvalidBaseBackoffThrows() {
        assertThrows(IllegalArgumentException.class,
                () -> OperationOptions.builder().setBaseBackoffMs(-1));
    }

    @Test
    void testInvalidMaxBackoffThrows() {
        assertThrows(IllegalArgumentException.class,
                () -> OperationOptions.builder().setMaxBackoffMs(-1));
    }

    @Test
    void testZeroMaxRetriesAllowed() {
        // Zero retries means no retry, which is valid
        OperationOptions options = OperationOptions.withMaxRetries(0);
        assertEquals(Integer.valueOf(0), options.getMaxRetries());
    }

    @Test
    void testZeroBaseBackoffAllowed() {
        // Zero backoff means immediate retry, which may be valid for some use cases
        OperationOptions options = OperationOptions.builder().setBaseBackoffMs(0).build();
        assertEquals(Long.valueOf(0), options.getBaseBackoffMs());
    }
}
