using System;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace ArcherDB.Tests;

public class GeoRoutingTests
{
    // ========================================================================
    // GeoRoutingConfig Tests
    // ========================================================================

    [Fact]
    public void Config_DefaultValues()
    {
        var config = new GeoRoutingConfig();

        Assert.False(config.Enabled);
        Assert.True(config.FailoverEnabled);
        Assert.Equal(30000, config.ProbeIntervalMs);
        Assert.Equal(5000, config.ProbeTimeoutMs);
        Assert.Equal(3, config.FailureThreshold);
        Assert.Equal(300000, config.CacheTtlMs);
        Assert.Equal(5, config.LatencySampleSize);
        Assert.Null(config.PreferredRegion);
        Assert.Null(config.ClientLatitude);
        Assert.Null(config.ClientLongitude);
        Assert.False(config.HasClientLocation);
    }

    [Fact]
    public void Config_CustomValues()
    {
        var config = new GeoRoutingConfig
        {
            Enabled = true,
            PreferredRegion = "us-west-2",
            FailoverEnabled = false,
            ProbeIntervalMs = 10000,
            ProbeTimeoutMs = 2000,
            FailureThreshold = 5,
            CacheTtlMs = 60000,
            LatencySampleSize = 10,
            ClientLatitude = 40.7128,
            ClientLongitude = -74.0060
        };

        Assert.True(config.Enabled);
        Assert.Equal("us-west-2", config.PreferredRegion);
        Assert.False(config.FailoverEnabled);
        Assert.Equal(10000, config.ProbeIntervalMs);
        Assert.Equal(2000, config.ProbeTimeoutMs);
        Assert.Equal(5, config.FailureThreshold);
        Assert.Equal(60000, config.CacheTtlMs);
        Assert.Equal(10, config.LatencySampleSize);
        Assert.Equal(40.7128, config.ClientLatitude);
        Assert.Equal(-74.0060, config.ClientLongitude);
        Assert.True(config.HasClientLocation);
    }

    [Fact]
    public void Config_HasClientLocation_RequiresBoth()
    {
        var config = new GeoRoutingConfig
        {
            ClientLatitude = 40.0
        };
        Assert.False(config.HasClientLocation);

        config.ClientLongitude = -74.0;
        Assert.True(config.HasClientLocation);
    }

    // ========================================================================
    // RegionInfo Tests
    // ========================================================================

    [Fact]
    public void RegionInfo_DefaultValues()
    {
        var region = new RegionInfo();

        Assert.Equal(string.Empty, region.Name);
        Assert.Equal(string.Empty, region.Endpoint);
        Assert.True(region.Healthy);
        Assert.NotNull(region.Location);
    }

    [Fact]
    public void RegionInfo_CustomValues()
    {
        var region = new RegionInfo
        {
            Name = "us-east-1",
            Endpoint = "localhost:8080",
            Healthy = false,
            Location = new RegionLocation
            {
                Latitude = 37.7749,
                Longitude = -122.4194
            }
        };

        Assert.Equal("us-east-1", region.Name);
        Assert.Equal("localhost:8080", region.Endpoint);
        Assert.False(region.Healthy);
        Assert.Equal(37.7749, region.Location.Latitude);
        Assert.Equal(-122.4194, region.Location.Longitude);
    }

    // ========================================================================
    // RegionLatencyStats Tests
    // ========================================================================

    [Fact]
    public void LatencyStats_AddSample()
    {
        var stats = new RegionLatencyStats(5);

        stats.AddSample(10.0);

        Assert.Equal(10.0, stats.AverageMs);
        Assert.True(stats.IsHealthy);
        Assert.Equal(1, stats.SampleCount);
    }

    [Fact]
    public void LatencyStats_MultipleSamples()
    {
        var stats = new RegionLatencyStats(5);

        stats.AddSample(10.0);
        stats.AddSample(20.0);
        stats.AddSample(30.0);

        Assert.Equal(20.0, stats.AverageMs); // (10+20+30)/3
        Assert.Equal(3, stats.SampleCount);
    }

    [Fact]
    public void LatencyStats_RollingWindow()
    {
        var stats = new RegionLatencyStats(3);

        stats.AddSample(10.0);
        stats.AddSample(20.0);
        stats.AddSample(30.0);
        stats.AddSample(40.0); // Should drop 10.0

        var expected = (20.0 + 30.0 + 40.0) / 3.0;
        Assert.Equal(expected, stats.AverageMs, 3);
        Assert.Equal(3, stats.SampleCount);
    }

    [Fact]
    public void LatencyStats_RecordFailure()
    {
        var stats = new RegionLatencyStats(5);
        const int threshold = 3;

        // Record failures up to threshold
        for (int i = 0; i < threshold; i++)
        {
            Assert.True(stats.IsHealthy);
            stats.RecordFailure(threshold);
        }

        Assert.False(stats.IsHealthy);
        Assert.Equal(threshold, stats.ConsecutiveFailures);
    }

    [Fact]
    public void LatencyStats_FailureBeforeThreshold()
    {
        var stats = new RegionLatencyStats(5);

        stats.RecordFailure(3);
        stats.RecordFailure(3);

        Assert.True(stats.IsHealthy); // Not yet at threshold
        Assert.Equal(2, stats.ConsecutiveFailures);
    }

    [Fact]
    public void LatencyStats_SuccessResetsFailures()
    {
        var stats = new RegionLatencyStats(5);

        stats.RecordFailure(3);
        stats.RecordFailure(3);
        stats.AddSample(10.0);

        Assert.Equal(0, stats.ConsecutiveFailures);
        Assert.True(stats.IsHealthy);
    }

    [Fact]
    public void LatencyStats_MarkHealthy()
    {
        var stats = new RegionLatencyStats(5);

        // Make unhealthy
        for (int i = 0; i < 3; i++)
        {
            stats.RecordFailure(3);
        }
        Assert.False(stats.IsHealthy);

        // Mark healthy
        stats.MarkHealthy();
        Assert.True(stats.IsHealthy);
        Assert.Equal(0, stats.ConsecutiveFailures);
    }

    [Fact]
    public void LatencyStats_MarkUnhealthy()
    {
        var stats = new RegionLatencyStats(5);
        stats.AddSample(10.0);
        Assert.True(stats.IsHealthy);

        stats.MarkUnhealthy();
        Assert.False(stats.IsHealthy);
    }

    // ========================================================================
    // GeoRoutingMetrics Tests
    // ========================================================================

    [Fact]
    public void Metrics_RecordQuery()
    {
        var metrics = new GeoRoutingMetrics();

        metrics.RecordQuery("us-east-1");
        metrics.RecordQuery("us-east-1");

        Assert.Equal(2, metrics.QueriesTotal);
    }

    [Fact]
    public void Metrics_RecordSwitch()
    {
        var metrics = new GeoRoutingMetrics();

        metrics.RecordSwitch("us-east-1", "us-west-2");

        Assert.Equal(1, metrics.SwitchesTotal);
        Assert.Equal("us-west-2", metrics.CurrentRegion);
    }

    [Fact]
    public void Metrics_MultipleSwitches()
    {
        var metrics = new GeoRoutingMetrics();

        metrics.RecordSwitch("", "us-east-1");
        metrics.RecordSwitch("us-east-1", "us-west-2");
        metrics.RecordSwitch("us-west-2", "eu-west-1");

        Assert.Equal(3, metrics.SwitchesTotal);
        Assert.Equal("eu-west-1", metrics.CurrentRegion);
    }

    [Fact]
    public void Metrics_RecordLatency()
    {
        var metrics = new GeoRoutingMetrics();

        metrics.RecordLatency("us-east-1", 10.0);
        metrics.RecordLatency("us-east-1", 20.0);

        Assert.Equal(15.0, metrics.GetAverageLatencyMs("us-east-1"), 3);
    }

    [Fact]
    public void Metrics_LatencyMultipleRegions()
    {
        var metrics = new GeoRoutingMetrics();

        metrics.RecordLatency("us-east-1", 10.0);
        metrics.RecordLatency("us-west-2", 50.0);

        Assert.Equal(10.0, metrics.GetAverageLatencyMs("us-east-1"), 3);
        Assert.Equal(50.0, metrics.GetAverageLatencyMs("us-west-2"), 3);
        Assert.Equal(0.0, metrics.GetAverageLatencyMs("unknown"));
    }

    [Fact]
    public void Metrics_ToPrometheus()
    {
        var metrics = new GeoRoutingMetrics();

        metrics.RecordQuery("us-east-1");
        metrics.RecordSwitch("", "us-east-1");
        metrics.RecordLatency("us-east-1", 10.0);

        var prometheus = metrics.ToPrometheus();

        Assert.Contains("archerdb_geo_routing_queries_total 1", prometheus);
        Assert.Contains("archerdb_geo_routing_region_switches_total 1", prometheus);
        Assert.Contains("archerdb_geo_routing_region_latency_ms", prometheus);
        Assert.Contains("us-east-1", prometheus);
        Assert.Contains("# HELP", prometheus);
        Assert.Contains("# TYPE", prometheus);
    }

    [Fact]
    public void Metrics_PrometheusEmpty()
    {
        var metrics = new GeoRoutingMetrics();

        var prometheus = metrics.ToPrometheus();

        Assert.Contains("archerdb_geo_routing_queries_total 0", prometheus);
        Assert.Contains("archerdb_geo_routing_region_switches_total 0", prometheus);
    }

    [Fact]
    public void Metrics_Reset()
    {
        var metrics = new GeoRoutingMetrics();

        metrics.RecordQuery("us-east-1");
        metrics.RecordSwitch("", "us-east-1");
        metrics.RecordLatency("us-east-1", 10.0);
        metrics.Reset();

        Assert.Equal(0, metrics.QueriesTotal);
        Assert.Equal(0, metrics.SwitchesTotal);
        Assert.Equal(string.Empty, metrics.CurrentRegion);
        Assert.Equal(0.0, metrics.GetAverageLatencyMs("us-east-1"));
    }

    // ========================================================================
    // GeoRouter Basic Tests (no network)
    // ========================================================================

    [Fact]
    public void GeoRouter_NotEnabled()
    {
        var config = new GeoRoutingConfig { Enabled = false };
        using var router = new GeoRouter("http://localhost:8080", config);

        Assert.False(router.IsEnabled);
        Assert.NotNull(router.Metrics);
        Assert.NotNull(router.Config);
    }

    [Fact]
    public void GeoRouter_IsEnabled()
    {
        var config = new GeoRoutingConfig { Enabled = true };
        using var router = new GeoRouter("http://localhost:8080", config);

        Assert.True(router.IsEnabled);
    }

    [Fact]
    public void GeoRouter_GetConfig()
    {
        var config = new GeoRoutingConfig
        {
            Enabled = true,
            PreferredRegion = "us-west-2"
        };
        using var router = new GeoRouter("http://localhost:8080", config);

        Assert.Equal("us-west-2", router.Config.PreferredRegion);
        Assert.True(router.Config.Enabled);
    }

    [Fact]
    public void GeoRouter_RecordSuccess()
    {
        var config = new GeoRoutingConfig { Enabled = true };
        using var router = new GeoRouter("http://localhost:8080", config);

        router.RecordSuccess("us-east-1");

        Assert.Equal(1, router.Metrics.QueriesTotal);
    }

    [Fact]
    public async Task GeoRouter_StartWhenDisabled()
    {
        var config = new GeoRoutingConfig { Enabled = false };
        using var router = new GeoRouter("http://localhost:8080", config);

        await router.StartAsync(); // Should not throw when disabled
        await router.StopAsync(); // Should handle gracefully
    }

    [Fact]
    public void GeoRouter_GetCurrentRegionEmpty()
    {
        var config = new GeoRoutingConfig { Enabled = true };
        using var router = new GeoRouter("http://localhost:8080", config);

        // Before start, current region should be empty
        Assert.Equal(string.Empty, router.CurrentRegion);
    }

    [Fact]
    public void GeoRouter_Dispose()
    {
        var config = new GeoRoutingConfig { Enabled = true };
        var router = new GeoRouter("http://localhost:8080", config);

        router.Dispose();
        router.Dispose(); // Should handle double dispose
    }

    // ========================================================================
    // Concurrent Access Tests
    // ========================================================================

    [Fact]
    public void LatencyStats_ConcurrentAccess()
    {
        var stats = new RegionLatencyStats(10);
        const int threadCount = 10;
        const int samplesPerThread = 100;

        var threads = new Thread[threadCount];
        for (int i = 0; i < threadCount; i++)
        {
            threads[i] = new Thread(() =>
            {
                var random = new Random();
                for (int j = 0; j < samplesPerThread; j++)
                {
                    stats.AddSample(random.NextDouble() * 100);
                }
            });
        }

        foreach (var t in threads) t.Start();
        foreach (var t in threads) t.Join();

        // Stats should be consistent after concurrent access
        Assert.True(stats.SampleCount <= 10); // Max samples
        Assert.True(stats.IsHealthy);
    }

    [Fact]
    public void Metrics_ConcurrentAccess()
    {
        var metrics = new GeoRoutingMetrics();
        const int threadCount = 10;
        const int queriesPerThread = 100;

        var threads = new Thread[threadCount];
        for (int i = 0; i < threadCount; i++)
        {
            threads[i] = new Thread(() =>
            {
                for (int j = 0; j < queriesPerThread; j++)
                {
                    metrics.RecordQuery($"region-{j % 3}");
                }
            });
        }

        foreach (var t in threads) t.Start();
        foreach (var t in threads) t.Join();

        Assert.Equal(threadCount * queriesPerThread, metrics.QueriesTotal);
    }
}
