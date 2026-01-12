using System;
using System.Threading.Tasks;
using Xunit;

namespace ArcherDB.Tests;

public class RetryPolicyTests
{
    [Fact]
    public void DefaultConfig_MatchesSpec()
    {
        var config = new RetryConfig();

        Assert.True(config.Enabled);
        Assert.Equal(5, config.MaxRetries); // 5 retries = 6 total attempts per spec
        Assert.Equal(100, config.BaseBackoffMs); // 100ms base per spec
        Assert.Equal(1600, config.MaxBackoffMs); // 1600ms max per spec
        Assert.Equal(30000, config.TotalTimeoutMs); // 30s total timeout per spec
        Assert.True(config.UseJitter);
    }

    [Fact]
    public void GetDelayMs_FirstAttempt_IsZero()
    {
        var policy = new RetryPolicy(new RetryConfig { UseJitter = false });
        Assert.Equal(0, policy.GetDelayMs(0));
    }

    [Fact]
    public void GetDelayMs_ExponentialBackoff()
    {
        var policy = new RetryPolicy(new RetryConfig { UseJitter = false, BaseBackoffMs = 100, MaxBackoffMs = 1600 });

        Assert.Equal(0, policy.GetDelayMs(0)); // Attempt 0
        Assert.Equal(100, policy.GetDelayMs(1)); // Attempt 1: 100ms
        Assert.Equal(200, policy.GetDelayMs(2)); // Attempt 2: 200ms
        Assert.Equal(400, policy.GetDelayMs(3)); // Attempt 3: 400ms
        Assert.Equal(800, policy.GetDelayMs(4)); // Attempt 4: 800ms
        Assert.Equal(1600, policy.GetDelayMs(5)); // Attempt 5: 1600ms
    }

    [Fact]
    public void GetDelayMs_CapsAtMax()
    {
        var policy = new RetryPolicy(new RetryConfig { UseJitter = false, BaseBackoffMs = 100, MaxBackoffMs = 500 });

        Assert.Equal(500, policy.GetDelayMs(4)); // Would be 800 but capped at 500
        Assert.Equal(500, policy.GetDelayMs(5)); // Would be 1600 but capped at 500
    }

    [Fact]
    public void GetDelayMs_WithJitter_AddsRandomness()
    {
        var policy = new RetryPolicy(new RetryConfig { UseJitter = true, BaseBackoffMs = 100 });

        // With jitter, delay should be base + random(0, base/2)
        // So delay should be between 100 and 150 for attempt 1
        int delay = policy.GetDelayMs(1);
        Assert.True(delay >= 100 && delay <= 150);
    }

    [Fact]
    public void ErrorCodes_RetryableClassification()
    {
        // Retryable errors per spec
        Assert.True(ErrorCodes.IsRetryable(ErrorCodes.Timeout));
        Assert.True(ErrorCodes.IsRetryable(ErrorCodes.ViewChangeInProgress));
        Assert.True(ErrorCodes.IsRetryable(ErrorCodes.NotPrimary));
        Assert.True(ErrorCodes.IsRetryable(ErrorCodes.ClusterUnavailable));
        Assert.True(ErrorCodes.IsRetryable(ErrorCodes.ReplicaLagging));

        // Non-retryable errors per spec
        Assert.False(ErrorCodes.IsRetryable(ErrorCodes.InvalidOperation));
        Assert.False(ErrorCodes.IsRetryable(ErrorCodes.InvalidCoordinates));
        Assert.False(ErrorCodes.IsRetryable(ErrorCodes.TooMuchData));
        Assert.False(ErrorCodes.IsRetryable(ErrorCodes.PolygonTooComplex));
        Assert.False(ErrorCodes.IsRetryable(ErrorCodes.QueryResultTooLarge));
        Assert.False(ErrorCodes.IsRetryable(ErrorCodes.ChecksumMismatch));
        Assert.False(ErrorCodes.IsRetryable(ErrorCodes.InvalidDataSize));
    }

    [Fact]
    public void Execute_ReturnsOnSuccess()
    {
        var policy = new RetryPolicy();
        int callCount = 0;

        var result = policy.Execute(() =>
        {
            callCount++;
            return 42;
        });

        Assert.Equal(42, result);
        Assert.Equal(1, callCount);
    }

    [Fact]
    public void Execute_DisabledRetry_NoRetries()
    {
        var policy = new RetryPolicy(new RetryConfig { Enabled = false });
        int callCount = 0;

        var ex = Assert.Throws<RequestException>(() =>
        {
            policy.Execute<int>(() =>
            {
                callCount++;
                throw new RequestException("test", ErrorCodes.Timeout);
            });
        });

        Assert.Equal(1, callCount); // Only one attempt when disabled
    }

    [Fact]
    public void Execute_NonRetryableError_NoRetry()
    {
        var policy = new RetryPolicy(new RetryConfig { MaxRetries = 5 });
        int callCount = 0;

        var ex = Assert.Throws<RequestException>(() =>
        {
            policy.Execute<int>(() =>
            {
                callCount++;
                throw new RequestException("test", ErrorCodes.InvalidCoordinates);
            });
        });

        Assert.Equal(1, callCount); // Only one attempt for non-retryable
    }

    [Fact]
    public async Task ExecuteAsync_ReturnsOnSuccess()
    {
        var policy = new RetryPolicy();

        var result = await policy.ExecuteAsync(async () =>
        {
            await Task.Delay(1);
            return 42;
        });

        Assert.Equal(42, result);
    }

    [Fact]
    public void RetryExhaustedException_ContainsAttemptCount()
    {
        var ex = new RetryExhaustedException(6, new Exception("test"));

        Assert.Equal(6, ex.Attempts);
        Assert.Contains("6", ex.Message);
    }

    [Fact]
    public void CircuitBreakerOpenException_HasMessage()
    {
        var ex = new CircuitBreakerOpenException();
        Assert.Contains("Circuit breaker is open", ex.Message);

        var exWithReplica = new CircuitBreakerOpenException("replica-1");
        Assert.Contains("replica-1", exWithReplica.Message);
    }
}

// Helper exception for testing (simulates RequestException)
public class RequestException : Exception
{
    public int ErrorCode { get; }

    public RequestException(string message, int errorCode) : base(message)
    {
        ErrorCode = errorCode;
    }
}
