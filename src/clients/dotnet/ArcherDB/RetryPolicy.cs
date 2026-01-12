using System;
using System.Threading;
using System.Threading.Tasks;

namespace ArcherDB;

/// <summary>
/// Retry policy configuration per client-retry/spec.md.
/// Exponential backoff: 100ms, 200ms, 400ms, 800ms, 1600ms with jitter.
/// </summary>
public sealed class RetryConfig
{
    /// <summary>Whether retry is enabled (default: true).</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Maximum number of retry attempts (default: 5, giving 6 total attempts).</summary>
    public int MaxRetries { get; set; } = 5;

    /// <summary>Base backoff delay in milliseconds (default: 100).</summary>
    public int BaseBackoffMs { get; set; } = 100;

    /// <summary>Maximum backoff delay in milliseconds (default: 1600).</summary>
    public int MaxBackoffMs { get; set; } = 1600;

    /// <summary>Total timeout for all attempts in milliseconds (default: 30000).</summary>
    public int TotalTimeoutMs { get; set; } = 30000;

    /// <summary>Whether to add jitter to backoff delays (default: true).</summary>
    public bool UseJitter { get; set; } = true;
}

/// <summary>
/// Error codes per error-codes/spec.md.
/// </summary>
public static class ErrorCodes
{
    // Retryable errors
    public const int Timeout = 1;
    public const int ViewChangeInProgress = 201;
    public const int NotPrimary = 7;
    public const int ClusterUnavailable = 202;
    public const int ReplicaLagging = 203;

    // Non-retryable errors
    public const int InvalidOperation = 100;
    public const int InvalidCoordinates = 102;
    public const int TooMuchData = 103;
    public const int PolygonTooComplex = 101;
    public const int QueryResultTooLarge = 104;
    public const int ChecksumMismatch = 2;
    public const int InvalidDataSize = 3;

    /// <summary>
    /// Determines if an error code is retryable per client-retry/spec.md.
    /// </summary>
    public static bool IsRetryable(int errorCode) => errorCode switch
    {
        Timeout => true,
        ViewChangeInProgress => true,
        NotPrimary => true,
        ClusterUnavailable => true,
        ReplicaLagging => true,
        _ => false
    };
}

/// <summary>
/// Retry policy implementation per client-retry/spec.md.
/// </summary>
public sealed class RetryPolicy
{
    private readonly RetryConfig _config;
    private readonly Random _random = new();

    public RetryPolicy(RetryConfig? config = null)
    {
        _config = config ?? new RetryConfig();
    }

    /// <summary>
    /// Calculates the delay for a given attempt number.
    /// Attempt 0: 0ms, Attempt 1: 100ms, Attempt 2: 200ms, etc.
    /// </summary>
    public int GetDelayMs(int attempt)
    {
        if (attempt <= 0) return 0;

        // Exponential backoff: base * 2^(attempt-1)
        int delay = _config.BaseBackoffMs * (1 << (attempt - 1));
        delay = Math.Min(delay, _config.MaxBackoffMs);

        if (_config.UseJitter)
        {
            // Add jitter: random(0, delay/2)
            int jitter = _random.Next(0, delay / 2 + 1);
            delay += jitter;
        }

        return delay;
    }

    /// <summary>
    /// Executes an operation with retry logic.
    /// </summary>
    public T Execute<T>(Func<T> operation, CircuitBreaker? circuitBreaker = null)
    {
        if (!_config.Enabled)
        {
            return operation();
        }

        var startTime = DateTime.UtcNow;
        int attempt = 0;
        Exception? lastException = null;

        while (attempt <= _config.MaxRetries)
        {
            // Check total timeout
            var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;
            if (elapsed >= _config.TotalTimeoutMs)
            {
                throw new TimeoutException($"Total timeout exceeded after {attempt} attempts", lastException);
            }

            // Check circuit breaker
            if (circuitBreaker != null && !circuitBreaker.AllowRequest())
            {
                throw new CircuitBreakerOpenException();
            }

            try
            {
                var result = operation();
                circuitBreaker?.RecordSuccess();
                return result;
            }
            catch (RequestException ex) when (ErrorCodes.IsRetryable(ex.ErrorCode))
            {
                lastException = ex;
                circuitBreaker?.RecordFailure();

                if (attempt < _config.MaxRetries)
                {
                    int delayMs = GetDelayMs(attempt + 1);
                    Thread.Sleep(delayMs);
                }
                attempt++;
            }
            catch (Exception ex)
            {
                // Non-retryable error
                circuitBreaker?.RecordFailure();
                throw;
            }
        }

        throw new RetryExhaustedException(_config.MaxRetries + 1, lastException);
    }

    /// <summary>
    /// Executes an async operation with retry logic.
    /// </summary>
    public async Task<T> ExecuteAsync<T>(Func<Task<T>> operation, CircuitBreaker? circuitBreaker = null, CancellationToken cancellationToken = default)
    {
        if (!_config.Enabled)
        {
            return await operation();
        }

        var startTime = DateTime.UtcNow;
        int attempt = 0;
        Exception? lastException = null;

        while (attempt <= _config.MaxRetries)
        {
            cancellationToken.ThrowIfCancellationRequested();

            // Check total timeout
            var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;
            if (elapsed >= _config.TotalTimeoutMs)
            {
                throw new TimeoutException($"Total timeout exceeded after {attempt} attempts", lastException);
            }

            // Check circuit breaker
            if (circuitBreaker != null && !circuitBreaker.AllowRequest())
            {
                throw new CircuitBreakerOpenException();
            }

            try
            {
                var result = await operation();
                circuitBreaker?.RecordSuccess();
                return result;
            }
            catch (RequestException ex) when (ErrorCodes.IsRetryable(ex.ErrorCode))
            {
                lastException = ex;
                circuitBreaker?.RecordFailure();

                if (attempt < _config.MaxRetries)
                {
                    int delayMs = GetDelayMs(attempt + 1);
                    await Task.Delay(delayMs, cancellationToken);
                }
                attempt++;
            }
            catch (Exception)
            {
                // Non-retryable error
                circuitBreaker?.RecordFailure();
                throw;
            }
        }

        throw new RetryExhaustedException(_config.MaxRetries + 1, lastException);
    }
}

/// <summary>
/// Exception thrown when all retry attempts are exhausted.
/// </summary>
public sealed class RetryExhaustedException : Exception
{
    public int Attempts { get; }

    public RetryExhaustedException(int attempts, Exception? innerException)
        : base($"All {attempts} retry attempts exhausted", innerException)
    {
        Attempts = attempts;
    }
}
