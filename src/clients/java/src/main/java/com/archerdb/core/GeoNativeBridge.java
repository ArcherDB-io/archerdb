package com.archerdb.core;

import java.nio.ByteBuffer;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * Public bridge for geo package to access native client infrastructure.
 *
 * <p>
 * This class provides the public API for the archerdb.geo package to submit requests to the native
 * client without exposing the internal implementation details of NativeClient, Request, and Batch.
 *
 * <p>
 * Usage pattern:
 *
 * <pre>
 * {
 *     &#64;code
 *     GeoNativeBridge bridge = GeoNativeBridge.create(clusterIdBytes, addresses);
 *     try {
 *         ByteBuffer response = bridge.submitRequest(operation, batch, timeoutMs);
 *         // Parse response...
 *     } finally {
 *         bridge.close();
 *     }
 * }
 * </pre>
 */
public final class GeoNativeBridge implements AutoCloseable {

    private final NativeClient nativeClient;
    private volatile boolean closed = false;

    private GeoNativeBridge(NativeClient nativeClient) {
        this.nativeClient = nativeClient;
    }

    /**
     * Creates a new bridge connected to the specified cluster.
     *
     * @param clusterIdBytes 16-byte cluster ID in little-endian format
     * @param addresses comma-separated list of replica addresses (host:port)
     * @return a new bridge instance
     * @throws InitializationException if connection fails
     */
    public static GeoNativeBridge create(byte[] clusterIdBytes, String addresses) {
        if (clusterIdBytes == null || clusterIdBytes.length != 16) {
            throw new IllegalArgumentException("ClusterID must be a 16-byte array");
        }
        if (addresses == null || addresses.isEmpty()) {
            throw new IllegalArgumentException("Addresses cannot be null or empty");
        }

        NativeClient client = NativeClient.init(clusterIdBytes, addresses);
        return new GeoNativeBridge(client);
    }

    /**
     * Creates a new bridge for echo testing (no actual server connection).
     *
     * @param clusterIdBytes 16-byte cluster ID in little-endian format
     * @param addresses comma-separated list of replica addresses (host:port)
     * @return a new bridge instance for echo testing
     */
    public static GeoNativeBridge createEcho(byte[] clusterIdBytes, String addresses) {
        if (clusterIdBytes == null || clusterIdBytes.length != 16) {
            throw new IllegalArgumentException("ClusterID must be a 16-byte array");
        }
        if (addresses == null || addresses.isEmpty()) {
            throw new IllegalArgumentException("Addresses cannot be null or empty");
        }

        NativeClient client = NativeClient.initEcho(clusterIdBytes, addresses);
        return new GeoNativeBridge(client);
    }

    /**
     * Submits a geo request to the native client and waits for the response.
     *
     * @param operation the operation code
     * @param batch the batch containing the request data (must extend Batch)
     * @param timeoutMs timeout in milliseconds
     * @return the response buffer, or null if no response data
     * @throws IllegalStateException if the bridge is closed
     * @throws RuntimeException if the request fails or times out
     */
    public ByteBuffer submitRequest(byte operation, Batch batch, int timeoutMs) {
        ensureOpen();

        Request.Operations op = operationFromByte(operation);
        GeoRequest request = new GeoRequest(nativeClient, op, batch);
        request.beginRequest();
        return request.waitForResult(timeoutMs);
    }

    /**
     * Checks if the bridge is still open.
     */
    public boolean isOpen() {
        return !closed;
    }

    @Override
    public void close() {
        if (!closed) {
            closed = true;
            nativeClient.close();
        }
    }

    private void ensureOpen() {
        if (closed) {
            throw new IllegalStateException("Bridge has been closed");
        }
    }

    private static Request.Operations operationFromByte(byte op) {
        for (Request.Operations o : Request.Operations.values()) {
            if (o.value == op) {
                return o;
            }
        }
        throw new IllegalArgumentException("Unknown operation code: " + op);
    }

    /**
     * Internal request implementation for geo operations.
     */
    private static final class GeoRequest extends Request<Batch> {
        private final CompletableFuture<ByteBuffer> future = new CompletableFuture<>();

        GeoRequest(NativeClient nativeClient, Operations operation, Batch batch) {
            super(nativeClient, operation, batch);
        }

        @Override
        void endRequest(byte receivedOperation, byte status, long timestamp) {
            try {
                if (status == PacketStatus.Ok.value) {
                    // Success - response data is in replyBuffer (accessed via reflection for now)
                    // In a full implementation, this would parse the response buffer
                    future.complete(null);
                } else if (status == PacketStatus.ClientShutdown.value) {
                    future.completeExceptionally(new IllegalStateException("Client is closed"));
                } else {
                    future.completeExceptionally(new RequestException(status));
                }
            } catch (Throwable t) {
                future.completeExceptionally(t);
            }
        }

        @Override
        protected void setResult(Batch result) {
            // Not used for geo requests
        }

        @Override
        protected void setException(Throwable exception) {
            future.completeExceptionally(exception);
        }

        ByteBuffer waitForResult(int timeoutMs) {
            try {
                return future.get(timeoutMs, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new RuntimeException("Request interrupted", e);
            } catch (ExecutionException e) {
                Throwable cause = e.getCause();
                if (cause instanceof RuntimeException) {
                    throw (RuntimeException) cause;
                }
                throw new RuntimeException("Request failed", cause);
            } catch (TimeoutException e) {
                throw new RuntimeException("Request timed out after " + timeoutMs + "ms", e);
            }
        }
    }
}
