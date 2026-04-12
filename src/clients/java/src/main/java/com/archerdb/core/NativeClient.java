// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.core;

import static com.archerdb.core.AssertionError.assertTrue;

import java.lang.ref.Cleaner;
import java.nio.ByteBuffer;

final class NativeClient implements AutoCloseable {
    private final static Cleaner cleaner;

    /*
     * Holds the `arch_client` buffer in an object instance detached from `NativeClient` to provide
     * state for the cleaner to dispose native memory when the `Client` instance is GCed. Also
     * implements `Runnable` to be usable as the cleaner action.
     * https://docs.oracle.com/javase%2F9%2Fdocs%2Fapi%2F%2F/java/lang/ref/Cleaner.html
     */
    private static final class CleanableState implements Runnable {
        private ByteBuffer arch_client;

        public CleanableState(ByteBuffer arch_client) {
            assertTrue(arch_client.isDirect(), "Invalid client buffer");
            this.arch_client = arch_client;
        }

        public void submit(final Request<?> request) {
            NativeClient.submit(arch_client, request);
        }

        public void close() {
            clientDeinit(arch_client);
        }

        @Override
        public void run() {
            close();
        }
    }

    static {
        JNILoader.loadFromJar();
        cleaner = Cleaner.create();
    }

    private final CleanableState state;
    private final Cleaner.Cleanable cleanable;

    public static NativeClient init(final byte[] clusterID, final String addresses) {
        assertArgs(clusterID, addresses);
        final var arch_client =
                ByteBuffer.allocateDirect(ArchClientHandle.SIZE + ArchClientHandle.ALIGNMENT);
        clientInit(arch_client, clusterID, addresses);
        return new NativeClient(arch_client);
    }

    public static NativeClient initEcho(final byte[] clusterID, final String addresses) {
        assertArgs(clusterID, addresses);
        final var arch_client =
                ByteBuffer.allocateDirect(ArchClientHandle.SIZE + ArchClientHandle.ALIGNMENT);
        clientInitEcho(arch_client, clusterID, addresses);
        return new NativeClient(arch_client);
    }

    private static void assertArgs(final byte[] clusterID, final String addresses) {
        assertTrue(clusterID.length == 16, "ClusterID must be a UInt128");
        assertTrue(addresses != null, "Replica addresses cannot be null");
    }

    private NativeClient(final ByteBuffer arch_client) {
        try {
            this.state = new CleanableState(arch_client);
            this.cleanable = cleaner.register(this, state);
        } catch (Throwable forward) {
            clientDeinit(arch_client);
            throw forward;
        }
    }

    public void submit(final Request<?> request) {
        this.state.submit(request);
    }

    @Override
    public void close() {
        // When the user calls `close()` or the client is used in a `try-resource` block,
        // we call `NativeHandle.close` to force it to run synchronously in the same thread.
        // Otherwise, if the user never disposes the client and `close` is never called,
        // the cleaner calls `NativeHandle.close` in another thread when the client is GCed.
        this.state.close();

        // Unregistering the cleanable.
        cleanable.clean();
    }

    private static native void submit(ByteBuffer arch_client, Request<?> request)
            throws ClientClosedException;

    private static native void clientInit(ByteBuffer arch_client, byte[] clusterID,
            String addresses) throws InitializationException;

    private static native void clientInitEcho(ByteBuffer arch_client, byte[] clusterID,
            String addresses) throws InitializationException;

    private static native void clientDeinit(ByteBuffer arch_client);
}
