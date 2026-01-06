package com.tigerbeetle;

import java.util.concurrent.CompletableFuture;

/**
 * Generic async request infrastructure.
 *
 * This class provides the core async request mechanism used by the ArcherDB client for asynchronous
 * operations. Financial-specific factory methods have been removed in favor of the archerdb.geo
 * package implementations.
 */
final class AsyncRequest<TResponse extends Batch> extends Request<TResponse> {

    private final CompletableFuture<TResponse> future;

    AsyncRequest(final NativeClient nativeClient, final Operations operation, final Batch batch) {
        super(nativeClient, operation, batch);

        future = new CompletableFuture<TResponse>();
    }

    public CompletableFuture<TResponse> getFuture() {
        return future;
    }

    @Override
    protected void setResult(final TResponse result) {
        final var completed = future.complete(result);
        if (!completed) {
            throw new IllegalStateException("Request has already been completed");
        }
    }

    @Override
    protected void setException(final Throwable exception) {
        final var completed = future.completeExceptionally(exception);
        if (!completed) {
            throw new IllegalStateException("Request has already been completed");
        }
    }
}
