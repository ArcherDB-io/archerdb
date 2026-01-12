using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace ArcherDB;

/// <summary>
/// Log levels for SDK logging.
/// </summary>
public enum LogLevel
{
    Debug,
    Info,
    Warn,
    Error
}

/// <summary>
/// Logger interface for SDK observability.
/// </summary>
public interface ILogger
{
    void Log(LogLevel level, string message);
}

/// <summary>
/// Null logger that discards all messages.
/// </summary>
public sealed class NullLogger : ILogger
{
    public static readonly NullLogger Instance = new();
    public void Log(LogLevel level, string message) { }
}

/// <summary>
/// Console logger for development/debugging.
/// </summary>
public sealed class ConsoleLogger : ILogger
{
    private readonly LogLevel _minLevel;

    public ConsoleLogger(LogLevel minLevel = LogLevel.Info)
    {
        _minLevel = minLevel;
    }

    public void Log(LogLevel level, string message)
    {
        if (level >= _minLevel)
        {
            Console.WriteLine($"[{DateTime.UtcNow:O}] [{level}] {message}");
        }
    }
}

/// <summary>
/// Counter metric for tracking counts.
/// </summary>
public sealed class Counter
{
    private long _value;
    private readonly ConcurrentDictionary<string, long> _labeled = new();

    public string Name { get; }
    public string Help { get; }

    public Counter(string name, string help)
    {
        Name = name;
        Help = help;
    }

    public void Inc(long delta = 1)
    {
        Interlocked.Add(ref _value, delta);
    }

    public void Inc(string label, long delta = 1)
    {
        _labeled.AddOrUpdate(label, delta, (_, v) => v + delta);
    }

    public long Value => Interlocked.Read(ref _value);

    public long GetLabeledValue(string label)
    {
        return _labeled.TryGetValue(label, out var value) ? value : 0;
    }

    public string ToPrometheus()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# HELP {Name} {Help}");
        sb.AppendLine($"# TYPE {Name} counter");

        if (_labeled.Count == 0)
        {
            sb.AppendLine($"{Name} {_value}");
        }
        else
        {
            foreach (var (label, value) in _labeled)
            {
                sb.AppendLine($"{Name}{{label=\"{label}\"}} {value}");
            }
        }

        return sb.ToString();
    }
}

/// <summary>
/// Gauge metric for tracking values that can go up and down.
/// </summary>
public sealed class Gauge
{
    private long _value;
    public string Name { get; }
    public string Help { get; }

    public Gauge(string name, string help)
    {
        Name = name;
        Help = help;
    }

    public void Set(long value)
    {
        Interlocked.Exchange(ref _value, value);
    }

    public void Inc(long delta = 1)
    {
        Interlocked.Add(ref _value, delta);
    }

    public void Dec(long delta = 1)
    {
        Interlocked.Add(ref _value, -delta);
    }

    public long Value => Interlocked.Read(ref _value);

    public string ToPrometheus()
    {
        return $"# HELP {Name} {Help}\n# TYPE {Name} gauge\n{Name} {_value}\n";
    }
}

/// <summary>
/// Histogram metric for tracking distributions.
/// </summary>
public sealed class Histogram
{
    private readonly double[] _buckets;
    private readonly long[] _bucketCounts;
    private long _count;
    private double _sum;
    private readonly object _lock = new();

    public string Name { get; }
    public string Help { get; }

    public Histogram(string name, string help, double[]? buckets = null)
    {
        Name = name;
        Help = help;
        _buckets = buckets ?? new[] { 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };
        _bucketCounts = new long[_buckets.Length + 1]; // +1 for +Inf bucket
    }

    public void Observe(double value)
    {
        lock (_lock)
        {
            _count++;
            _sum += value;

            for (int i = 0; i < _buckets.Length; i++)
            {
                if (value <= _buckets[i])
                {
                    _bucketCounts[i]++;
                }
            }
            _bucketCounts[_buckets.Length]++; // +Inf bucket
        }
    }

    public string ToPrometheus()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# HELP {Name} {Help}");
        sb.AppendLine($"# TYPE {Name} histogram");

        lock (_lock)
        {
            long cumulative = 0;
            for (int i = 0; i < _buckets.Length; i++)
            {
                cumulative += _bucketCounts[i];
                sb.AppendLine($"{Name}_bucket{{le=\"{_buckets[i]}\"}} {cumulative}");
            }
            sb.AppendLine($"{Name}_bucket{{le=\"+Inf\"}} {_count}");
            sb.AppendLine($"{Name}_sum {_sum}");
            sb.AppendLine($"{Name}_count {_count}");
        }

        return sb.ToString();
    }
}

/// <summary>
/// SDK metrics per observability/spec.md.
/// </summary>
public sealed class SdkMetrics
{
    public static readonly SdkMetrics Instance = new();

    public Counter RequestsTotal { get; } = new("archerdb_client_requests_total", "Total client requests");
    public Histogram RequestDuration { get; } = new("archerdb_client_request_duration_seconds", "Request duration in seconds");
    public Gauge ConnectionsActive { get; } = new("archerdb_client_connections_active", "Active connections");
    public Counter ReconnectionsTotal { get; } = new("archerdb_client_reconnections_total", "Total reconnections");
    public Counter SessionRenewalsTotal { get; } = new("archerdb_client_session_renewals_total", "Total session renewals");
    public Counter RetriesTotal { get; } = new("archerdb_client_retries_total", "Total retry attempts");
    public Counter RetryExhaustedTotal { get; } = new("archerdb_client_retry_exhausted_total", "Total retry exhaustions");
    public Counter PrimaryDiscoveriesTotal { get; } = new("archerdb_client_primary_discoveries_total", "Total primary discoveries");
    public Counter CircuitBreakerTripsTotal { get; } = new("archerdb_client_circuit_breaker_trips_total", "Total circuit breaker trips");

    public void RecordRequest(string operation, double durationSeconds, bool success)
    {
        RequestsTotal.Inc(operation);
        RequestDuration.Observe(durationSeconds);
        if (!success)
        {
            RequestsTotal.Inc($"{operation}_error");
        }
    }

    public string ToPrometheus()
    {
        var sb = new StringBuilder();
        sb.Append(RequestsTotal.ToPrometheus());
        sb.Append(RequestDuration.ToPrometheus());
        sb.Append(ConnectionsActive.ToPrometheus());
        sb.Append(ReconnectionsTotal.ToPrometheus());
        sb.Append(SessionRenewalsTotal.ToPrometheus());
        sb.Append(RetriesTotal.ToPrometheus());
        sb.Append(RetryExhaustedTotal.ToPrometheus());
        sb.Append(PrimaryDiscoveriesTotal.ToPrometheus());
        sb.Append(CircuitBreakerTripsTotal.ToPrometheus());
        return sb.ToString();
    }
}

/// <summary>
/// Request timer for measuring operation durations.
/// </summary>
public sealed class RequestTimer : IDisposable
{
    private readonly Stopwatch _stopwatch;
    private readonly string _operation;
    private readonly SdkMetrics _metrics;
    private bool _success = true;

    public RequestTimer(string operation, SdkMetrics? metrics = null)
    {
        _operation = operation;
        _metrics = metrics ?? SdkMetrics.Instance;
        _stopwatch = Stopwatch.StartNew();
    }

    public void MarkError()
    {
        _success = false;
    }

    public void Dispose()
    {
        _stopwatch.Stop();
        _metrics.RecordRequest(_operation, _stopwatch.Elapsed.TotalSeconds, _success);
    }
}

/// <summary>
/// Health tracker for monitoring replica health.
/// </summary>
public sealed class HealthTracker
{
    private readonly ConcurrentDictionary<string, ReplicaHealth> _replicaHealth = new();
    private readonly int _failureThreshold;

    public HealthTracker(int failureThreshold = 3)
    {
        _failureThreshold = failureThreshold;
    }

    public void RecordSuccess(string replicaId)
    {
        var health = _replicaHealth.GetOrAdd(replicaId, _ => new ReplicaHealth());
        health.RecordSuccess();
    }

    public void RecordFailure(string replicaId)
    {
        var health = _replicaHealth.GetOrAdd(replicaId, _ => new ReplicaHealth());
        health.RecordFailure(_failureThreshold);
    }

    public bool IsHealthy(string replicaId)
    {
        return !_replicaHealth.TryGetValue(replicaId, out var health) || health.IsHealthy;
    }

    private sealed class ReplicaHealth
    {
        private int _consecutiveFailures;
        public bool IsHealthy { get; private set; } = true;

        public void RecordSuccess()
        {
            Interlocked.Exchange(ref _consecutiveFailures, 0);
            IsHealthy = true;
        }

        public void RecordFailure(int threshold)
        {
            if (Interlocked.Increment(ref _consecutiveFailures) >= threshold)
            {
                IsHealthy = false;
            }
        }
    }
}
