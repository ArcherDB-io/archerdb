using System;
using System.IO;
using System.Threading;
using Xunit;

namespace ArcherDB.Tests;

public class ObservabilityTests
{
    [Fact]
    public void NullLogger_DiscardsMessages()
    {
        // Should not throw
        NullLogger.Instance.Log(LogLevel.Debug, "test");
        NullLogger.Instance.Log(LogLevel.Error, "test");
    }

    [Fact]
    public void ConsoleLogger_FiltersByLevel()
    {
        var output = new StringWriter();
        Console.SetOut(output);

        var logger = new ConsoleLogger(LogLevel.Warn);
        logger.Log(LogLevel.Debug, "debug message");
        logger.Log(LogLevel.Info, "info message");
        logger.Log(LogLevel.Warn, "warn message");
        logger.Log(LogLevel.Error, "error message");

        var logOutput = output.ToString();
        Assert.DoesNotContain("debug message", logOutput);
        Assert.DoesNotContain("info message", logOutput);
        Assert.Contains("warn message", logOutput);
        Assert.Contains("error message", logOutput);

        Console.SetOut(new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true });
    }

    [Fact]
    public void Counter_Increments()
    {
        var counter = new Counter("test_counter", "Test counter");

        Assert.Equal(0, counter.Value);

        counter.Inc();
        Assert.Equal(1, counter.Value);

        counter.Inc(5);
        Assert.Equal(6, counter.Value);
    }

    [Fact]
    public void Counter_Labels()
    {
        var counter = new Counter("test_counter", "Test counter");

        counter.Inc("label1");
        counter.Inc("label1");
        counter.Inc("label2", 5);

        Assert.Equal(2, counter.GetLabeledValue("label1"));
        Assert.Equal(5, counter.GetLabeledValue("label2"));
        Assert.Equal(0, counter.GetLabeledValue("nonexistent"));
    }

    [Fact]
    public void Counter_PrometheusFormat()
    {
        var counter = new Counter("archerdb_test_total", "Test counter");
        counter.Inc(42);

        var output = counter.ToPrometheus();

        Assert.Contains("# HELP archerdb_test_total Test counter", output);
        Assert.Contains("# TYPE archerdb_test_total counter", output);
        Assert.Contains("archerdb_test_total 42", output);
    }

    [Fact]
    public void Gauge_Operations()
    {
        var gauge = new Gauge("test_gauge", "Test gauge");

        Assert.Equal(0, gauge.Value);

        gauge.Set(100);
        Assert.Equal(100, gauge.Value);

        gauge.Inc(10);
        Assert.Equal(110, gauge.Value);

        gauge.Dec(5);
        Assert.Equal(105, gauge.Value);
    }

    [Fact]
    public void Gauge_PrometheusFormat()
    {
        var gauge = new Gauge("archerdb_connections", "Active connections");
        gauge.Set(5);

        var output = gauge.ToPrometheus();

        Assert.Contains("# HELP archerdb_connections Active connections", output);
        Assert.Contains("# TYPE archerdb_connections gauge", output);
        Assert.Contains("archerdb_connections 5", output);
    }

    [Fact]
    public void Histogram_Observe()
    {
        var histogram = new Histogram("test_histogram", "Test histogram", new[] { 0.1, 0.5, 1.0 });

        histogram.Observe(0.05);
        histogram.Observe(0.3);
        histogram.Observe(0.7);
        histogram.Observe(1.5);

        var output = histogram.ToPrometheus();

        Assert.Contains("# TYPE test_histogram histogram", output);
        Assert.Contains("test_histogram_bucket{le=\"0.1\"}", output);
        Assert.Contains("test_histogram_bucket{le=\"0.5\"}", output);
        Assert.Contains("test_histogram_bucket{le=\"1\"}", output);
        Assert.Contains("test_histogram_bucket{le=\"+Inf\"}", output);
        Assert.Contains("test_histogram_count 4", output);
    }

    [Fact]
    public void SdkMetrics_RecordRequest()
    {
        var metrics = new SdkMetrics();

        metrics.RecordRequest("insert", 0.05, true);
        metrics.RecordRequest("query", 0.10, false);

        Assert.Equal(1, metrics.RequestsTotal.GetLabeledValue("insert"));
        Assert.Equal(1, metrics.RequestsTotal.GetLabeledValue("query"));
        Assert.Equal(1, metrics.RequestsTotal.GetLabeledValue("query_error"));
    }

    [Fact]
    public void SdkMetrics_PrometheusExport()
    {
        var metrics = new SdkMetrics();
        metrics.RequestsTotal.Inc("test");
        metrics.ConnectionsActive.Set(3);

        var output = metrics.ToPrometheus();

        Assert.Contains("archerdb_client_requests_total", output);
        Assert.Contains("archerdb_client_connections_active", output);
        Assert.Contains("archerdb_client_retries_total", output);
    }

    [Fact]
    public void RequestTimer_MeasuresDuration()
    {
        var metrics = new SdkMetrics();

        using (var timer = new RequestTimer("test_op", metrics))
        {
            Thread.Sleep(10);
        }

        // Request should be recorded
        Assert.Equal(1, metrics.RequestsTotal.GetLabeledValue("test_op"));
    }

    [Fact]
    public void RequestTimer_MarksError()
    {
        var metrics = new SdkMetrics();

        using (var timer = new RequestTimer("error_op", metrics))
        {
            timer.MarkError();
        }

        Assert.Equal(1, metrics.RequestsTotal.GetLabeledValue("error_op"));
        Assert.Equal(1, metrics.RequestsTotal.GetLabeledValue("error_op_error"));
    }

    [Fact]
    public void HealthTracker_InitialState()
    {
        var tracker = new HealthTracker();

        // Unknown replica should be considered healthy
        Assert.True(tracker.IsHealthy("replica-1"));
    }

    [Fact]
    public void HealthTracker_SuccessTransitions()
    {
        var tracker = new HealthTracker(failureThreshold: 3);

        tracker.RecordSuccess("replica-1");
        Assert.True(tracker.IsHealthy("replica-1"));
    }

    [Fact]
    public void HealthTracker_FailureThreshold()
    {
        var tracker = new HealthTracker(failureThreshold: 3);

        tracker.RecordFailure("replica-1");
        tracker.RecordFailure("replica-1");
        Assert.True(tracker.IsHealthy("replica-1")); // Not yet at threshold

        tracker.RecordFailure("replica-1");
        Assert.False(tracker.IsHealthy("replica-1")); // At threshold
    }

    [Fact]
    public void HealthTracker_Recovery()
    {
        var tracker = new HealthTracker(failureThreshold: 2);

        // Fail the replica
        tracker.RecordFailure("replica-1");
        tracker.RecordFailure("replica-1");
        Assert.False(tracker.IsHealthy("replica-1"));

        // Recovery via success
        tracker.RecordSuccess("replica-1");
        Assert.True(tracker.IsHealthy("replica-1"));
    }

    [Fact]
    public void Counter_ThreadSafe()
    {
        var counter = new Counter("thread_safe_counter", "Test");
        var threads = new Thread[10];

        for (int i = 0; i < threads.Length; i++)
        {
            threads[i] = new Thread(() =>
            {
                for (int j = 0; j < 1000; j++)
                {
                    counter.Inc();
                }
            });
        }

        foreach (var t in threads) t.Start();
        foreach (var t in threads) t.Join();

        Assert.Equal(10000, counter.Value);
    }
}
