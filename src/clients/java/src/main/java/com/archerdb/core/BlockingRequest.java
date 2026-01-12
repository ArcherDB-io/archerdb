package com.archerdb.core;

import static com.archerdb.core.AssertionError.assertTrue;

/**
 * Generic blocking request infrastructure.
 *
 * This class provides the core blocking request mechanism used by the ArcherDB client for
 * synchronous operations. Financial-specific factory methods have been removed in favor of the
 * archerdb.geo package implementations.
 */
final class BlockingRequest<TResponse extends Batch> extends Request<TResponse> {

    private TResponse result;
    private Throwable exception;

    BlockingRequest(final NativeClient nativeClient, final Operations operation,
            final Batch batch) {
        super(nativeClient, operation, batch);

        result = null;
        exception = null;
    }

    public boolean isDone() {
        return result != null || exception != null;
    }

    public TResponse waitForResult() {

        waitForCompletionUninterruptibly();
        return getResult();
    }

    @Override
    protected void setResult(final TResponse result) {

        synchronized (this) {

            if (isDone()) {
                throw new IllegalStateException("Request has already been completed");
            } else {
                this.result = result;
                this.exception = null;
            }

            notify();
        }

    }

    @Override
    protected void setException(final Throwable exception) {

        synchronized (this) {

            if (isDone()) {
                throw new IllegalStateException("Request has already been completed");
            } else {
                this.result = null;
                this.exception = exception;
            }

            notify();
        }

    }

    private void waitForCompletionUninterruptibly() {
        try {

            if (!isDone()) {
                synchronized (this) {
                    while (!isDone()) {
                        wait();
                    }
                }
            }

        } catch (InterruptedException interruptedException) {
            // Since we don't support canceling an ongoing request
            // this exception should never exposed by the API to be handled by the user
            throw new AssertionError(interruptedException,
                    "Unexpected thread interruption on waitForCompletion.");
        }
    }

    TResponse getResult() {

        assertTrue(result != null || exception != null, "Unexpected request result: result=null");

        // Handling checked and unchecked exceptions accordingly
        if (exception != null) {

            if (exception instanceof RequestException)
                throw (RequestException) exception;

            if (exception instanceof RuntimeException)
                throw (RuntimeException) exception;

            if (exception instanceof Error)
                throw (Error) exception;

            throw new AssertionError(exception, "Unexpected exception");

        } else {

            return this.result;
        }
    }

}
