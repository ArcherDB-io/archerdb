using System;
using System.Threading;
using Xunit;

namespace ArcherDB.Tests;

public class CircuitBreakerTests
{
    [Fact]
    public void InitialState_IsClosed()
    {
        var cb = new CircuitBreaker();
        Assert.Equal(CircuitState.Closed, cb.State);
    }

    [Fact]
    public void Closed_AllowsRequests()
    {
        var cb = new CircuitBreaker();
        Assert.True(cb.AllowRequest());
    }

    [Fact]
    public void Closed_StaysClosedUnderThreshold()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 10, FailureRateThreshold = 0.5 };
        var cb = new CircuitBreaker(config);

        // 4 failures, 6 successes = 40% failure rate < 50% threshold
        for (int i = 0; i < 4; i++) cb.RecordFailure();
        for (int i = 0; i < 6; i++) cb.RecordSuccess();

        Assert.Equal(CircuitState.Closed, cb.State);
    }

    [Fact]
    public void Closed_OpensAfterThresholdExceeded()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 10, FailureRateThreshold = 0.5 };
        var cb = new CircuitBreaker(config);

        // 6 failures, 4 successes = 60% failure rate > 50% threshold
        for (int i = 0; i < 6; i++) cb.RecordFailure();
        for (int i = 0; i < 4; i++) cb.RecordSuccess();

        Assert.Equal(CircuitState.Open, cb.State);
    }

    [Fact]
    public void Open_RejectsRequests()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 10, FailureRateThreshold = 0.5, OpenDurationSeconds = 30 };
        var cb = new CircuitBreaker(config);

        // Open the circuit
        for (int i = 0; i < 10; i++) cb.RecordFailure();

        Assert.Equal(CircuitState.Open, cb.State);
        Assert.False(cb.AllowRequest());
    }

    [Fact]
    public void Open_TransitionsToHalfOpenAfterDuration()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 5, FailureRateThreshold = 0.5, OpenDurationSeconds = 1 };
        var cb = new CircuitBreaker(config);

        // Open the circuit
        for (int i = 0; i < 5; i++) cb.RecordFailure();
        Assert.Equal(CircuitState.Open, cb.State);

        // Wait for open duration
        Thread.Sleep(1100);

        // Should transition to half-open
        Assert.True(cb.AllowRequest());
        Assert.Equal(CircuitState.HalfOpen, cb.State);
    }

    [Fact]
    public void HalfOpen_ClosesOnSuccess()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 5, FailureRateThreshold = 0.5, OpenDurationSeconds = 0 };
        var cb = new CircuitBreaker(config);

        // Open then transition to half-open
        for (int i = 0; i < 5; i++) cb.RecordFailure();
        cb.AllowRequest(); // Triggers transition to half-open

        Assert.Equal(CircuitState.HalfOpen, cb.State);

        // Success in half-open should close
        cb.RecordSuccess();
        Assert.Equal(CircuitState.Closed, cb.State);
    }

    [Fact]
    public void HalfOpen_ReopensOnFailure()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 5, FailureRateThreshold = 0.5, OpenDurationSeconds = 0 };
        var cb = new CircuitBreaker(config);

        // Open then transition to half-open
        for (int i = 0; i < 5; i++) cb.RecordFailure();
        cb.AllowRequest(); // Triggers transition to half-open

        // Failure in half-open should reopen
        cb.RecordFailure();
        Assert.Equal(CircuitState.Open, cb.State);
    }

    [Fact]
    public void HalfOpen_LimitsRequests()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 5, FailureRateThreshold = 0.5, OpenDurationSeconds = 0, HalfOpenRequests = 3 };
        var cb = new CircuitBreaker(config);

        // Open then transition to half-open
        for (int i = 0; i < 5; i++) cb.RecordFailure();
        cb.AllowRequest(); // First request + triggers transition

        // Should allow up to HalfOpenRequests
        Assert.True(cb.AllowRequest());
        Assert.True(cb.AllowRequest());
        Assert.False(cb.AllowRequest()); // 4th request blocked
    }

    [Fact]
    public void MinimumRequests_Required()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 10, FailureRateThreshold = 0.5 };
        var cb = new CircuitBreaker(config);

        // 5 failures with only 5 requests (less than minimum 10)
        for (int i = 0; i < 5; i++) cb.RecordFailure();

        // Circuit should remain closed - not enough requests
        Assert.Equal(CircuitState.Closed, cb.State);
    }

    [Fact]
    public void ForceClose_ResetsState()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 5, FailureRateThreshold = 0.5 };
        var cb = new CircuitBreaker(config);

        // Open the circuit
        for (int i = 0; i < 5; i++) cb.RecordFailure();
        Assert.Equal(CircuitState.Open, cb.State);

        // Force close
        cb.ForceClose();
        Assert.Equal(CircuitState.Closed, cb.State);
        Assert.True(cb.AllowRequest());
    }

    [Fact]
    public void StateChanges_AreTracked()
    {
        var config = new CircuitBreakerConfig { MinimumRequests = 5, FailureRateThreshold = 0.5, OpenDurationSeconds = 0 };
        var cb = new CircuitBreaker(config);

        Assert.Equal(0, cb.StateChangeCount);

        // Open the circuit
        for (int i = 0; i < 5; i++) cb.RecordFailure();
        Assert.Equal(1, cb.StateChangeCount); // Closed -> Open

        // Transition to half-open
        cb.AllowRequest();
        Assert.Equal(2, cb.StateChangeCount); // Open -> HalfOpen
    }

    [Fact]
    public void DefaultConfig_MatchesSpec()
    {
        var config = new CircuitBreakerConfig();

        Assert.Equal(0.5, config.FailureRateThreshold); // 50% per spec
        Assert.Equal(10, config.MinimumRequests); // 10 per spec
        Assert.Equal(10, config.WindowSizeSeconds); // 10s per spec
        Assert.Equal(30, config.OpenDurationSeconds); // 30s per spec
        Assert.Equal(5, config.HalfOpenRequests); // 5 per spec
    }
}
