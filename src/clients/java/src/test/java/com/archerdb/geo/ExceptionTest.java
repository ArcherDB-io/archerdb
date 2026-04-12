// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;

import java.io.IOException;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * Unit tests for the ArcherDB exception hierarchy.
 *
 * <p>
 * Per error-codes/spec.md, tests verify:
 * <ul>
 * <li>Each error code maps to the correct exception class</li>
 * <li>Retryable semantics are correct per error type</li>
 * <li>Exception messages are informative</li>
 * <li>Cause chaining works correctly</li>
 * </ul>
 */
class ExceptionTest {

    // ========================================================================
    // ArcherDBException Base Class Tests
    // ========================================================================

    @Test
    void testArcherDBExceptionBasicConstruction() {
        ArcherDBException ex = new ArcherDBException(100, "Test message", true);

        assertEquals(100, ex.getErrorCode());
        assertEquals("Test message", ex.getMessage());
        assertTrue(ex.isRetryable());
        assertNull(ex.getCause());
    }

    @Test
    void testArcherDBExceptionWithCause() {
        Exception cause = new RuntimeException("Root cause");
        ArcherDBException ex = new ArcherDBException(100, "Test message", false, cause);

        assertEquals(100, ex.getErrorCode());
        assertFalse(ex.isRetryable());
        assertEquals(cause, ex.getCause());
    }

    @Test
    void testArcherDBExceptionIsRuntimeException() {
        ArcherDBException ex = new ArcherDBException(100, "Test", true);
        assertTrue(ex instanceof RuntimeException);
    }

    // ========================================================================
    // ConnectionException Tests (Codes 1-99)
    // ========================================================================

    @Test
    void testConnectionFailedFactory() {
        String endpoint = "10.0.0.1:3000";
        ConnectionException ex = ConnectionException.connectionFailed(endpoint);

        assertEquals(ConnectionException.CONNECTION_FAILED, ex.getErrorCode());
        assertTrue(ex.getMessage().contains(endpoint));
        assertTrue(ex.isRetryable(), "Connection errors should be retryable");
    }

    @Test
    void testConnectionTimeoutFactory() {
        String endpoint = "10.0.0.1:3000";
        int timeoutMs = 5000;
        ConnectionException ex = ConnectionException.connectionTimeout(endpoint, timeoutMs);

        assertEquals(ConnectionException.CONNECTION_TIMEOUT, ex.getErrorCode());
        assertTrue(ex.getMessage().contains(endpoint));
        assertTrue(ex.getMessage().contains("5000"));
        assertTrue(ex.isRetryable());
    }

    @Test
    void testTlsErrorFactory() {
        String reason = "Certificate expired";
        ConnectionException ex = ConnectionException.tlsError(reason);

        assertEquals(ConnectionException.TLS_ERROR, ex.getErrorCode());
        assertTrue(ex.getMessage().contains(reason));
        assertTrue(ex.isRetryable());
    }

    @ParameterizedTest
    @ValueSource(ints = {1, 2, 3})
    void testConnectionErrorCodesAreInRange(int errorCode) {
        assertTrue(errorCode >= 1 && errorCode <= 99,
                "Connection error codes should be in range 1-99");
    }

    // ========================================================================
    // ValidationException Tests (Codes 100-199)
    // ========================================================================

    @Test
    void testInvalidCoordinatesFactory() {
        ValidationException ex = ValidationException.invalidCoordinates(91.0, -122.0);

        assertEquals(ValidationException.INVALID_COORDINATES, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("91"));
        assertFalse(ex.isRetryable(), "Validation errors should NOT be retryable");
    }

    @Test
    void testInvalidEntityIdFactory() {
        ValidationException ex = ValidationException.invalidEntityId("reason");

        assertEquals(ValidationException.INVALID_ENTITY_ID, ex.getErrorCode());
        assertFalse(ex.isRetryable());
    }

    @Test
    void testInvalidPolygonFactory() {
        ValidationException ex = ValidationException.invalidPolygon("Too few vertices");

        assertEquals(ValidationException.INVALID_POLYGON, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("Too few vertices"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testPolygonSelfIntersectingFactory() {
        ValidationException ex = ValidationException.polygonSelfIntersecting(5, 10);

        assertEquals(ValidationException.POLYGON_SELF_INTERSECTING, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("5"));
        assertTrue(ex.getMessage().contains("10"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testPolygonTooLargeFactory() {
        ValidationException ex = ValidationException.polygonTooLarge(360.0);

        assertEquals(ValidationException.POLYGON_TOO_LARGE, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("360"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testInvalidRadiusFactory() {
        ValidationException ex = ValidationException.invalidRadius(100000.0, 50000.0);

        assertEquals(ValidationException.INVALID_RADIUS, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("100000"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testRadiusZeroFactory() {
        ValidationException ex = ValidationException.radiusZero();

        assertEquals(ValidationException.RADIUS_ZERO, ex.getErrorCode());
        assertFalse(ex.isRetryable());
    }

    // ========================================================================
    // Polygon Hole Validation Tests (Codes 117-120)
    // ========================================================================

    @Test
    void testHoleNotContainedFactory() {
        ValidationException ex = ValidationException.holeNotContained(2);

        assertEquals(ValidationException.HOLE_NOT_CONTAINED, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("2"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testHolesOverlapFactory() {
        ValidationException ex = ValidationException.holesOverlap(1, 3);

        assertEquals(ValidationException.HOLES_OVERLAP, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("1"));
        assertTrue(ex.getMessage().contains("3"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testTooManyHolesFactory() {
        ValidationException ex = ValidationException.tooManyHoles(20, 16);

        assertEquals(ValidationException.TOO_MANY_HOLES, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("20"));
        assertTrue(ex.getMessage().contains("16"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testHoleVertexCountInvalidFactory() {
        ValidationException ex = ValidationException.holeVertexCountInvalid(2, 2, 3);

        assertEquals(ValidationException.HOLE_VERTEX_COUNT_INVALID, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("2")); // hole index
        assertFalse(ex.isRetryable());
    }

    // ========================================================================
    // ClusterException Tests (Codes 201-203)
    // ========================================================================

    @Test
    void testClusterUnavailableFactory() {
        ClusterException ex = ClusterException.clusterUnavailable(5, 1, 2);

        assertEquals(ClusterException.CLUSTER_UNAVAILABLE, ex.getErrorCode());
        assertTrue(ex.isRetryable(), "Cluster unavailable should be retryable");
        assertEquals(5, ex.getView());
    }

    @Test
    void testViewChangeInProgressFactory() {
        ClusterException ex = ClusterException.viewChangeInProgress(5, 6);

        assertEquals(ClusterException.VIEW_CHANGE_IN_PROGRESS, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("5"));
        assertTrue(ex.getMessage().contains("6"));
        assertTrue(ex.isRetryable());
        assertEquals(6, ex.getView());
    }

    @Test
    void testNotPrimaryFactory() {
        ClusterException ex = ClusterException.notPrimary(5, 2, 1);

        assertEquals(ClusterException.NOT_PRIMARY, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("2")); // primary index
        assertTrue(ex.isRetryable());
        assertEquals(2, ex.getPrimaryIndex());
    }

    @Test
    void testClusterExceptionViewAndPrimaryGetters() {
        ClusterException ex = new ClusterException(201, "test", 10, 3);

        assertEquals(10, ex.getView());
        assertEquals(3, ex.getPrimaryIndex());
    }

    // ========================================================================
    // OperationException Tests (Codes 200-399)
    // ========================================================================

    @Test
    void testTimeoutFactory() {
        OperationException ex = OperationException.timeout("insert", 5000);

        assertEquals(OperationException.TIMEOUT, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("insert"));
        assertTrue(ex.getMessage().contains("5000"));
        assertTrue(ex.isRetryable(), "Timeout should be retryable with caution");
    }

    @Test
    void testEntityNotFoundFactory() {
        UInt128 entityId = UInt128.random();
        OperationException ex = OperationException.entityNotFound(entityId);

        assertEquals(OperationException.ENTITY_NOT_FOUND, ex.getErrorCode());
        assertTrue(ex.getMessage().contains(entityId.toString()));
        assertFalse(ex.isRetryable(), "Entity not found should NOT be retryable");
    }

    @Test
    void testEntityExpiredFactory() {
        UInt128 entityId = UInt128.random();
        OperationException ex = OperationException.entityExpired(entityId);

        assertEquals(OperationException.ENTITY_EXPIRED, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("TTL"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testSessionExpiredFactory() {
        OperationException ex = OperationException.sessionExpired("timeout");

        assertEquals(OperationException.SESSION_EXPIRED, ex.getErrorCode());
        assertFalse(ex.isRetryable(), "Session expired should NOT be retryable");
    }

    @Test
    void testResultSetTooLargeFactory() {
        OperationException ex = OperationException.resultSetTooLarge(15000, 10000);

        assertEquals(OperationException.RESULT_SET_TOO_LARGE, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("15000"));
        assertTrue(ex.getMessage().contains("10000"));
        assertFalse(ex.isRetryable());
    }

    @Test
    void testDiskFullFactory() {
        OperationException ex = OperationException.diskFull();

        assertEquals(OperationException.DISK_FULL, ex.getErrorCode());
        assertTrue(ex.isRetryable(), "Disk full is retryable after operator intervention");
    }

    @Test
    void testMemoryExhaustedFactory() {
        OperationException ex = OperationException.memoryExhausted();

        assertEquals(OperationException.MEMORY_EXHAUSTED, ex.getErrorCode());
        assertTrue(ex.isRetryable());
    }

    @Test
    void testRateLimitExceededFactory() {
        OperationException ex = OperationException.rateLimitExceeded(1500, 1000);

        assertEquals(OperationException.RATE_LIMIT_EXCEEDED, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("1500"));
        assertTrue(ex.isRetryable());
    }

    @Test
    void testTooManyQueriesFactory() {
        OperationException ex = OperationException.tooManyQueries(150, 100);

        assertEquals(OperationException.TOO_MANY_QUERIES, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("150"));
        assertTrue(ex.isRetryable());
    }

    @Test
    void testTooManyClientsFactory() {
        OperationException ex = OperationException.tooManyClients(550, 500);

        assertEquals(OperationException.TOO_MANY_CLIENTS, ex.getErrorCode());
        assertTrue(ex.isRetryable());
    }

    @Test
    void testIndexCapacityExceededFactory() {
        OperationException ex =
                OperationException.indexCapacityExceeded(1_000_000_000L, 500_000_000L);

        assertEquals(OperationException.INDEX_CAPACITY_EXCEEDED, ex.getErrorCode());
        assertFalse(ex.isRetryable(), "Index capacity exceeded should NOT be retryable");
    }

    @Test
    void testResourceExhaustedFactory() {
        OperationException ex = OperationException.resourceExhausted("file handles");

        assertEquals(OperationException.RESOURCE_EXHAUSTED, ex.getErrorCode());
        assertTrue(ex.getMessage().contains("file handles"));
        assertTrue(ex.isRetryable());
    }

    // ========================================================================
    // Exception Chaining Tests
    // ========================================================================

    @Test
    void testExceptionChaining() {
        IOException networkError = new IOException("Network failure");
        ConnectionException connEx = new ConnectionException(ConnectionException.CONNECTION_FAILED,
                "Connection failed", networkError);

        assertEquals(networkError, connEx.getCause());
        assertEquals("Network failure", connEx.getCause().getMessage());
    }

    @Test
    void testOperationExceptionWithCause() {
        RuntimeException cause = new RuntimeException("Original error");
        OperationException ex =
                new OperationException(OperationException.TIMEOUT, "Timeout", true, cause);

        assertEquals(cause, ex.getCause());
    }

    // ========================================================================
    // Error Code Range Tests
    // ========================================================================

    @Test
    void testValidationErrorCodesInRange() {
        assertTrue(ValidationException.INVALID_COORDINATES >= 100);
        assertTrue(ValidationException.INVALID_COORDINATES < 200);
        assertTrue(ValidationException.HOLE_VERTEX_COUNT_INVALID >= 100);
        assertTrue(ValidationException.HOLE_VERTEX_COUNT_INVALID < 200);
    }

    @Test
    void testClusterErrorCodesInRange() {
        assertTrue(ClusterException.CLUSTER_UNAVAILABLE >= 200);
        assertTrue(ClusterException.CLUSTER_UNAVAILABLE < 300);
        assertTrue(ClusterException.NOT_PRIMARY >= 200);
        assertTrue(ClusterException.NOT_PRIMARY < 300);
    }

    @Test
    void testOperationErrorCodesInRange() {
        assertTrue(OperationException.ENTITY_NOT_FOUND >= 200);
        assertTrue(OperationException.DISK_FULL >= 300);
        assertTrue(OperationException.DISK_FULL < 400);
    }
}
