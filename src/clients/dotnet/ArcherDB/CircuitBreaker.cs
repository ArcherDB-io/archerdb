using System;
using System.Threading;

namespace ArcherDB;

/// <summary>
/// Circuit breaker states per client-retry spec.
/// </summary>
public enum CircuitState
{
    /// <summary>Normal operation - requests flow through.</summary>
    Closed,
    /// <summary>Circuit tripped - requests fail fast.</summary>
    Open,
    /// <summary>Testing recovery - limited requests allowed.</summary>
    HalfOpen
}

/// <summary>
/// Circuit breaker configuration matching client-retry/spec.md requirements.
/// </summary>
public sealed class CircuitBreakerConfig
{
    /// <summary>Failure rate threshold to open circuit (default: 0.5 = 50%).</summary>
    public double FailureRateThreshold { get; set; } = 0.5;

    /// <summary>Minimum requests before evaluating failure rate (default: 10).</summary>
    public int MinimumRequests { get; set; } = 10;

    /// <summary>Time window for failure rate calculation in seconds (default: 10).</summary>
    public int WindowSizeSeconds { get; set; } = 10;

    /// <summary>Duration circuit stays open before transitioning to half-open in seconds (default: 30).</summary>
    public int OpenDurationSeconds { get; set; } = 30;

    /// <summary>Number of test requests allowed in half-open state (default: 5).</summary>
    public int HalfOpenRequests { get; set; } = 5;
}

/// <summary>
/// Circuit breaker implementation per client-retry/spec.md.
/// 3-state pattern: Closed (normal) -> Open (fail fast) -> Half-Open (testing recovery).
/// Per-replica scope allows trying other replicas when one circuit trips.
/// </summary>
public sealed class CircuitBreaker
{
    private readonly CircuitBreakerConfig _config;
    private readonly object _lock = new();

    private CircuitState _state = CircuitState.Closed;
    private int _failureCount;
    private int _successCount;
    private int _halfOpenAttempts;
    private DateTime _windowStart;
    private DateTime _openedAt;
    private int _stateChangeCount;

    /// <summary>
    /// Creates a new circuit breaker with the specified configuration.
    /// </summary>
    public CircuitBreaker(CircuitBreakerConfig? config = null)
    {
        _config = config ?? new CircuitBreakerConfig();
        _windowStart = DateTime.UtcNow;
    }

    /// <summary>Current state of the circuit breaker.</summary>
    public CircuitState State
    {
        get { lock (_lock) return _state; }
    }

    /// <summary>Number of state changes (for monitoring).</summary>
    public int StateChangeCount
    {
        get { lock (_lock) return _stateChangeCount; }
    }

    /// <summary>
    /// Checks if a request is allowed through the circuit breaker.
    /// </summary>
    /// <returns>True if request is allowed, false if circuit is open.</returns>
    public bool AllowRequest()
    {
        lock (_lock)
        {
            switch (_state)
            {
                case CircuitState.Closed:
                    return true;

                case CircuitState.Open:
                    // Check if it's time to transition to half-open
                    if ((DateTime.UtcNow - _openedAt).TotalSeconds >= _config.OpenDurationSeconds)
                    {
                        TransitionTo(CircuitState.HalfOpen);
                        _halfOpenAttempts = 1;
                        return true;
                    }
                    return false;

                case CircuitState.HalfOpen:
                    // Allow limited requests in half-open state
                    if (_halfOpenAttempts < _config.HalfOpenRequests)
                    {
                        _halfOpenAttempts++;
                        return true;
                    }
                    return false;

                default:
                    return false;
            }
        }
    }

    /// <summary>
    /// Records a successful request.
    /// </summary>
    public void RecordSuccess()
    {
        lock (_lock)
        {
            ResetWindowIfNeeded();
            _successCount++;

            if (_state == CircuitState.HalfOpen)
            {
                // Successful test in half-open -> close circuit
                TransitionTo(CircuitState.Closed);
                ResetCounts();
            }
        }
    }

    /// <summary>
    /// Records a failed request.
    /// </summary>
    public void RecordFailure()
    {
        lock (_lock)
        {
            ResetWindowIfNeeded();
            _failureCount++;

            if (_state == CircuitState.HalfOpen)
            {
                // Failed test in half-open -> reopen circuit
                TransitionTo(CircuitState.Open);
                _openedAt = DateTime.UtcNow;
                return;
            }

            // Check if we should open the circuit
            int totalRequests = _failureCount + _successCount;
            if (totalRequests >= _config.MinimumRequests)
            {
                double failureRate = (double)_failureCount / totalRequests;
                if (failureRate >= _config.FailureRateThreshold)
                {
                    TransitionTo(CircuitState.Open);
                    _openedAt = DateTime.UtcNow;
                }
            }
        }
    }

    /// <summary>
    /// Force closes the circuit breaker (for testing/admin).
    /// </summary>
    public void ForceClose()
    {
        lock (_lock)
        {
            TransitionTo(CircuitState.Closed);
            ResetCounts();
        }
    }

    private void TransitionTo(CircuitState newState)
    {
        if (_state != newState)
        {
            _state = newState;
            _stateChangeCount++;
        }
    }

    private void ResetWindowIfNeeded()
    {
        if ((DateTime.UtcNow - _windowStart).TotalSeconds >= _config.WindowSizeSeconds)
        {
            ResetCounts();
        }
    }

    private void ResetCounts()
    {
        _failureCount = 0;
        _successCount = 0;
        _halfOpenAttempts = 0;
        _windowStart = DateTime.UtcNow;
    }
}

/// <summary>
/// Exception thrown when circuit breaker is open.
/// </summary>
public sealed class CircuitBreakerOpenException : Exception
{
    public CircuitBreakerOpenException()
        : base("Circuit breaker is open - request rejected") { }

    public CircuitBreakerOpenException(string replicaId)
        : base($"Circuit breaker for replica {replicaId} is open - request rejected") { }
}
