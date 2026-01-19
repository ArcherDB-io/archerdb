package com.archerdb.core;

import java.lang.annotation.Native;
import java.nio.ByteBuffer;
import java.util.Objects;

abstract class Request<TResponse extends Batch> {

    // @formatter:off
    /*
     * Overview:
     *
     * Implements a context that will be used to submit the request and to signal the completion.
     * A reference to this class is stored by the JNI side in the "user_data" field when calling "arch_client_submit",
     * meaning that no GC will occur before the callback completion
     *
     * Memory:
     *
     * - Holds the request body until the completion to be accessible by the C client.
     * - Copies the response body to be exposed to the application.
     *
     * Completion:
     *
     * - See AsyncRequest.java and BlockingRequest.java
     *
     */
    // @formatter:on

    /**
     * Operation codes for ArcherDB geospatial operations.
     *
     * Legacy ArcherDB operations have been removed. See archerdb.geo package for geospatial client
     * implementation.
     */
    enum Operations {
        PULSE(128),

        // ArcherDB geospatial operations (F1.2)
        INSERT_EVENTS(146),
        UPSERT_EVENTS(147),
        DELETE_ENTITIES(148),
        QUERY_UUID(149),
        QUERY_RADIUS(150),
        QUERY_POLYGON(151),
        ARCHERDB_PING(152),
        ARCHERDB_GET_STATUS(153),
        QUERY_LATEST(154),
        CLEANUP_EXPIRED(155),
        QUERY_UUID_BATCH(156),
        GET_TOPOLOGY(157),
        TTL_SET(158),
        TTL_EXTEND(159),
        TTL_CLEAR(160);

        byte value;

        Operations(int value) {
            this.value = (byte) value;
        }
    }

    static final ByteBuffer REPLY_EMPTY = ByteBuffer.allocate(0).asReadOnlyBuffer();

    // Used only by the JNI side
    @Native
    private final ByteBuffer sendBuffer;

    @Native
    private final long sendBufferLen;

    @Native
    private byte[] replyBuffer;

    private final NativeClient nativeClient;
    private final Operations operation;
    private final int requestLen;

    protected Request(final NativeClient nativeClient, final Operations operation,
            final Batch batch) {
        Objects.requireNonNull(nativeClient, "Client cannot be null");
        Objects.requireNonNull(batch, "Batch cannot be null");

        this.nativeClient = nativeClient;
        this.operation = operation;
        this.requestLen = batch.getLength();
        this.sendBuffer = batch.getBuffer();
        this.sendBufferLen = batch.getBufferLen();
        this.replyBuffer = null;
    }

    public void beginRequest() {
        nativeClient.submit(this);
    }

    /**
     * Handles request completion callback from the JNI side.
     *
     * Note: Geospatial operations are handled by the archerdb.geo package, which has its own native
     * bindings implementation. This method is kept for infrastructure compatibility.
     */
    @SuppressWarnings("unchecked")
    void endRequest(final byte receivedOperation, final byte status, final long timestamp) {
        // This method is called from the JNI side, on the arch_client thread
        // We CAN'T throw any exception here, any event must be stored and
        // handled from the user's thread on the completion.

        Throwable exception = null;

        try {
            if (receivedOperation != operation.value) {
                exception =
                        new AssertionError("Unexpected callback operation: expected=%d, actual=%d",
                                operation.value, receivedOperation);
            } else if (status != PacketStatus.Ok.value) {
                if (status == PacketStatus.ClientShutdown.value) {
                    exception = new IllegalStateException("Client is closed");
                } else {
                    exception = new RequestException(status);
                }
            } else {
                // Geo operations are handled by archerdb.geo package
                exception = new AssertionError(
                        "Operation %d should be handled by archerdb.geo package", operation.value);
            }
        } catch (Throwable any) {
            exception = any;
        }

        try {
            setException(exception);
        } catch (Throwable any) {
            System.err.println("Completion of request failed!\n"
                    + "This is a bug in ArcherDB. Please report it at https://github.com/ArcherDB-io/archerdb.\n"
                    + "Cause: " + any.toString());
            any.printStackTrace();
            Runtime.getRuntime().halt(1);
        }
    }

    // Used by unit tests.
    @SuppressWarnings("unused")
    void setReplyBuffer(byte[] buffer) {
        this.replyBuffer = buffer;
    }

    byte[] getReplyBuffer() {
        return replyBuffer;
    }

    // Unused: Used by the JNI side.
    @SuppressWarnings("unused")
    byte getOperation() {
        return this.operation.value;
    }

    protected abstract void setResult(final TResponse result);

    protected abstract void setException(final Throwable exception);
}
