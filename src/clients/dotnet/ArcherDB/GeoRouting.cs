using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace ArcherDB;

/// <summary>
/// Configuration for geo-routing functionality.
/// Per the add-geo-routing spec.
/// </summary>
public sealed class GeoRoutingConfig
{
    /// <summary>
    /// Whether geo-routing is enabled. Default: false.
    /// </summary>
    public bool Enabled { get; set; } = false;

    /// <summary>
    /// Preferred region to use when multiple are available.
    /// </summary>
    public string? PreferredRegion { get; set; }

    /// <summary>
    /// Whether automatic failover is enabled. Default: true.
    /// </summary>
    public bool FailoverEnabled { get; set; } = true;

    /// <summary>
    /// Interval between latency probes in milliseconds. Default: 30000.
    /// </summary>
    public int ProbeIntervalMs { get; set; } = 30000;

    /// <summary>
    /// Timeout for a single probe in milliseconds. Default: 5000.
    /// </summary>
    public int ProbeTimeoutMs { get; set; } = 5000;

    /// <summary>
    /// Number of consecutive failures before marking unhealthy. Default: 3.
    /// </summary>
    public int FailureThreshold { get; set; } = 3;

    /// <summary>
    /// TTL for region discovery cache in milliseconds. Default: 300000.
    /// </summary>
    public int CacheTtlMs { get; set; } = 300000;

    /// <summary>
    /// Number of latency samples for rolling average. Default: 5.
    /// </summary>
    public int LatencySampleSize { get; set; } = 5;

    /// <summary>
    /// Client's latitude for distance-based selection.
    /// </summary>
    public double? ClientLatitude { get; set; }

    /// <summary>
    /// Client's longitude for distance-based selection.
    /// </summary>
    public double? ClientLongitude { get; set; }

    /// <summary>
    /// Returns true if client location is set.
    /// </summary>
    public bool HasClientLocation => ClientLatitude.HasValue && ClientLongitude.HasValue;
}

/// <summary>
/// Information about a discovered region.
/// </summary>
public sealed class RegionInfo
{
    /// <summary>
    /// Unique region identifier (e.g., "us-east-1").
    /// </summary>
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    /// <summary>
    /// Connection endpoint (host:port).
    /// </summary>
    [JsonPropertyName("endpoint")]
    public string Endpoint { get; set; } = string.Empty;

    /// <summary>
    /// Geographic location.
    /// </summary>
    [JsonPropertyName("location")]
    public RegionLocation Location { get; set; } = new();

    /// <summary>
    /// Whether the region is healthy.
    /// </summary>
    [JsonPropertyName("healthy")]
    public bool Healthy { get; set; } = true;
}

/// <summary>
/// Geographic location for a region.
/// </summary>
public sealed class RegionLocation
{
    [JsonPropertyName("Latitude")]
    public double Latitude { get; set; }

    [JsonPropertyName("Longitude")]
    public double Longitude { get; set; }
}

/// <summary>
/// Tracks latency statistics for a region.
/// </summary>
public sealed class RegionLatencyStats
{
    private readonly Queue<double> _samples;
    private readonly int _maxSamples;
    private readonly object _lock = new();

    private double _averageMs;
    private int _consecutiveFailures;
    private bool _healthy = true;
    private DateTime _lastProbe = DateTime.MinValue;

    public RegionLatencyStats(int maxSamples = 5)
    {
        _maxSamples = maxSamples > 0 ? maxSamples : 5;
        _samples = new Queue<double>(_maxSamples);
    }

    /// <summary>
    /// Adds a latency sample in milliseconds.
    /// </summary>
    public void AddSample(double latencyMs)
    {
        lock (_lock)
        {
            _samples.Enqueue(latencyMs);
            while (_samples.Count > _maxSamples)
            {
                _samples.Dequeue();
            }

            _averageMs = _samples.Average();
            _consecutiveFailures = 0;
            _healthy = true;
            _lastProbe = DateTime.UtcNow;
        }
    }

    /// <summary>
    /// Records a probe failure.
    /// </summary>
    public void RecordFailure(int failureThreshold)
    {
        lock (_lock)
        {
            _consecutiveFailures++;
            if (_consecutiveFailures >= failureThreshold)
            {
                _healthy = false;
            }
            _lastProbe = DateTime.UtcNow;
        }
    }

    /// <summary>
    /// Gets the average latency in milliseconds.
    /// </summary>
    public double AverageMs
    {
        get { lock (_lock) return _averageMs; }
    }

    /// <summary>
    /// Gets whether the region is healthy.
    /// </summary>
    public bool IsHealthy
    {
        get { lock (_lock) return _healthy; }
    }

    /// <summary>
    /// Gets the number of consecutive failures.
    /// </summary>
    public int ConsecutiveFailures
    {
        get { lock (_lock) return _consecutiveFailures; }
    }

    /// <summary>
    /// Gets the number of samples.
    /// </summary>
    public int SampleCount
    {
        get { lock (_lock) return _samples.Count; }
    }

    /// <summary>
    /// Marks the region as healthy.
    /// </summary>
    public void MarkHealthy()
    {
        lock (_lock)
        {
            _healthy = true;
            _consecutiveFailures = 0;
        }
    }

    /// <summary>
    /// Marks the region as unhealthy.
    /// </summary>
    public void MarkUnhealthy()
    {
        lock (_lock)
        {
            _healthy = false;
        }
    }
}

/// <summary>
/// Metrics for geo-routing operations.
/// Per the add-geo-routing spec.
/// </summary>
public sealed class GeoRoutingMetrics
{
    private long _queriesTotal;
    private long _regionSwitchesTotal;
    private readonly ConcurrentDictionary<string, (long totalMicros, long count)> _regionLatencies = new();
    private string _currentRegion = string.Empty;

    /// <summary>
    /// Records a query to a region.
    /// </summary>
    public void RecordQuery(string region)
    {
        Interlocked.Increment(ref _queriesTotal);
    }

    /// <summary>
    /// Records a region switch.
    /// </summary>
    public void RecordSwitch(string fromRegion, string toRegion)
    {
        Interlocked.Increment(ref _regionSwitchesTotal);
        _currentRegion = toRegion;
    }

    /// <summary>
    /// Records a latency sample for a region.
    /// </summary>
    public void RecordLatency(string region, double latencyMs)
    {
        var micros = (long)(latencyMs * 1000);
        _regionLatencies.AddOrUpdate(
            region,
            (micros, 1),
            (_, existing) => (existing.totalMicros + micros, existing.count + 1)
        );
    }

    /// <summary>
    /// Gets total queries.
    /// </summary>
    public long QueriesTotal => Interlocked.Read(ref _queriesTotal);

    /// <summary>
    /// Gets total region switches.
    /// </summary>
    public long SwitchesTotal => Interlocked.Read(ref _regionSwitchesTotal);

    /// <summary>
    /// Gets the current region.
    /// </summary>
    public string CurrentRegion => _currentRegion;

    /// <summary>
    /// Gets average latency for a region in milliseconds.
    /// </summary>
    public double GetAverageLatencyMs(string region)
    {
        if (_regionLatencies.TryGetValue(region, out var data) && data.count > 0)
        {
            return data.totalMicros / (data.count * 1000.0);
        }
        return 0.0;
    }

    /// <summary>
    /// Exports metrics in Prometheus text format.
    /// </summary>
    public string ToPrometheus()
    {
        var sb = new StringBuilder();

        sb.AppendLine("# HELP archerdb_geo_routing_queries_total Total geo-routed queries");
        sb.AppendLine("# TYPE archerdb_geo_routing_queries_total counter");
        sb.AppendLine($"archerdb_geo_routing_queries_total {_queriesTotal}");

        sb.AppendLine("# HELP archerdb_geo_routing_region_switches_total Total region switches");
        sb.AppendLine("# TYPE archerdb_geo_routing_region_switches_total counter");
        sb.AppendLine($"archerdb_geo_routing_region_switches_total {_regionSwitchesTotal}");

        sb.AppendLine("# HELP archerdb_geo_routing_region_latency_ms Region latency in milliseconds");
        sb.AppendLine("# TYPE archerdb_geo_routing_region_latency_ms gauge");
        foreach (var (region, data) in _regionLatencies)
        {
            if (data.count > 0)
            {
                var avgMs = data.totalMicros / (data.count * 1000.0);
                sb.AppendLine($"archerdb_geo_routing_region_latency_ms{{region=\"{region}\"}} {avgMs:F3}");
            }
        }

        return sb.ToString();
    }

    /// <summary>
    /// Resets all metrics.
    /// </summary>
    public void Reset()
    {
        Interlocked.Exchange(ref _queriesTotal, 0);
        Interlocked.Exchange(ref _regionSwitchesTotal, 0);
        _regionLatencies.Clear();
        _currentRegion = string.Empty;
    }
}

/// <summary>
/// Main coordinator for geo-routing functionality.
/// Per the add-geo-routing spec.
/// </summary>
public sealed class GeoRouter : IDisposable
{
    private readonly GeoRoutingConfig _config;
    private readonly string _discoveryUrl;
    private readonly GeoRoutingMetrics _metrics;
    private readonly ConcurrentDictionary<string, RegionLatencyStats> _regionStats;
    private readonly HttpClient _httpClient;

    private string _currentRegion = string.Empty;
    private List<RegionInfo>? _cachedRegions;
    private DateTime _cacheExpiry = DateTime.MinValue;
    private CancellationTokenSource? _probingCts;
    private Task? _probingTask;
    private bool _disposed;

    /// <summary>
    /// Creates a new GeoRouter.
    /// </summary>
    /// <param name="discoveryUrl">Base URL for the discovery endpoint</param>
    /// <param name="config">Geo-routing configuration</param>
    public GeoRouter(string discoveryUrl, GeoRoutingConfig config)
    {
        _discoveryUrl = discoveryUrl.TrimEnd('/');
        _config = config;
        _metrics = new GeoRoutingMetrics();
        _regionStats = new ConcurrentDictionary<string, RegionLatencyStats>();
        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromMilliseconds(config.ProbeTimeoutMs)
        };
    }

    /// <summary>
    /// Gets whether geo-routing is enabled.
    /// </summary>
    public bool IsEnabled => _config.Enabled;

    /// <summary>
    /// Gets the configuration.
    /// </summary>
    public GeoRoutingConfig Config => _config;

    /// <summary>
    /// Gets the metrics.
    /// </summary>
    public GeoRoutingMetrics Metrics => _metrics;

    /// <summary>
    /// Gets the currently selected region.
    /// </summary>
    public string CurrentRegion => _currentRegion;

    /// <summary>
    /// Starts the geo-router.
    /// </summary>
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (!_config.Enabled)
        {
            return;
        }

        // Fetch initial regions
        var regions = await FetchRegionsAsync(cancellationToken);
        if (regions.Count == 0)
        {
            throw new InvalidOperationException("No regions discovered");
        }

        // Start background probing
        _probingCts = new CancellationTokenSource();
        _probingTask = RunProbingLoopAsync(_probingCts.Token);

        // Select initial region
        var selected = SelectRegion(regions, Array.Empty<string>());
        if (selected != null)
        {
            _currentRegion = selected.Name;
            _metrics.RecordSwitch(string.Empty, selected.Name);
        }
    }

    /// <summary>
    /// Stops the geo-router.
    /// </summary>
    public async Task StopAsync()
    {
        _probingCts?.Cancel();
        if (_probingTask != null)
        {
            try
            {
                await _probingTask;
            }
            catch (OperationCanceledException)
            {
                // Expected
            }
        }
    }

    /// <summary>
    /// Gets the endpoint for the currently selected region.
    /// </summary>
    public async Task<string> GetCurrentEndpointAsync(CancellationToken cancellationToken = default)
    {
        if (!_config.Enabled)
        {
            throw new InvalidOperationException("Geo-routing not enabled");
        }

        if (string.IsNullOrEmpty(_currentRegion))
        {
            throw new InvalidOperationException("No region selected");
        }

        var regions = await FetchRegionsAsync(cancellationToken);
        var region = regions.FirstOrDefault(r => r.Name == _currentRegion);
        if (region == null)
        {
            throw new InvalidOperationException($"Region not found: {_currentRegion}");
        }

        return region.Endpoint;
    }

    /// <summary>
    /// Selects a region, optionally excluding specific regions.
    /// </summary>
    public async Task<RegionInfo?> SelectBestRegionAsync(
        IEnumerable<string>? excludeRegions = null,
        CancellationToken cancellationToken = default)
    {
        var regions = await FetchRegionsAsync(cancellationToken);
        var exclude = excludeRegions?.ToHashSet() ?? new HashSet<string>();
        var selected = SelectRegion(regions, exclude);

        if (selected != null && selected.Name != _currentRegion)
        {
            var oldRegion = _currentRegion;
            _currentRegion = selected.Name;
            _metrics.RecordSwitch(oldRegion, selected.Name);
        }

        return selected;
    }

    /// <summary>
    /// Records a successful operation.
    /// </summary>
    public void RecordSuccess(string regionName)
    {
        _metrics.RecordQuery(regionName);
        var stats = GetOrCreateStats(regionName);
        stats.MarkHealthy();
    }

    /// <summary>
    /// Records a failed operation and triggers failover if enabled.
    /// </summary>
    public async Task<RegionInfo?> RecordFailureAsync(
        string regionName,
        CancellationToken cancellationToken = default)
    {
        var stats = GetOrCreateStats(regionName);
        stats.RecordFailure(_config.FailureThreshold);

        if (!_config.FailoverEnabled)
        {
            return null;
        }

        if (!stats.IsHealthy)
        {
            return await SelectBestRegionAsync(new[] { regionName }, cancellationToken);
        }

        return null;
    }

    /// <summary>
    /// Refreshes the region list from the discovery endpoint.
    /// </summary>
    public async Task RefreshRegionsAsync(CancellationToken cancellationToken = default)
    {
        _cacheExpiry = DateTime.MinValue;
        await FetchRegionsAsync(cancellationToken);
    }

    private async Task<List<RegionInfo>> FetchRegionsAsync(CancellationToken cancellationToken)
    {
        // Check cache
        if (_cachedRegions != null && DateTime.UtcNow < _cacheExpiry)
        {
            return _cachedRegions;
        }

        // Fetch from server
        var url = $"{_discoveryUrl}/regions";
        var response = await _httpClient.GetStringAsync(url, cancellationToken);

        var result = JsonSerializer.Deserialize<DiscoveryResponse>(response);
        if (result?.Regions == null)
        {
            return new List<RegionInfo>();
        }

        _cachedRegions = result.Regions;
        _cacheExpiry = DateTime.UtcNow.AddMilliseconds(_config.CacheTtlMs);

        return _cachedRegions;
    }

    private sealed class DiscoveryResponse
    {
        [JsonPropertyName("regions")]
        public List<RegionInfo>? Regions { get; set; }
    }

    private RegionInfo? SelectRegion(List<RegionInfo> regions, ISet<string> excludeRegions)
    {
        if (regions.Count == 0)
        {
            return null;
        }

        // Filter healthy regions not in exclude list
        var candidates = regions
            .Where(r => !excludeRegions.Contains(r.Name))
            .Where(r => r.Healthy)
            .Where(r => !_regionStats.TryGetValue(r.Name, out var s) || s.IsHealthy)
            .ToList();

        if (candidates.Count == 0)
        {
            return null;
        }

        // If preferred region is available, use it
        if (!string.IsNullOrEmpty(_config.PreferredRegion))
        {
            var preferred = candidates.FirstOrDefault(r => r.Name == _config.PreferredRegion);
            if (preferred != null)
            {
                return preferred;
            }
        }

        // Sort by latency
        var withLatency = candidates
            .Select(r => (Region: r, Latency: GetLatencyOrMax(r.Name)))
            .OrderBy(x => x.Latency)
            .ToList();

        // If no latency data, fall back to distance
        if (withLatency[0].Latency == double.MaxValue && _config.HasClientLocation)
        {
            withLatency = candidates
                .Select(r => (Region: r, Distance: HaversineDistance(
                    _config.ClientLatitude!.Value,
                    _config.ClientLongitude!.Value,
                    r.Location.Latitude,
                    r.Location.Longitude)))
                .OrderBy(x => x.Distance)
                .Select(x => (x.Region, Latency: x.Distance))
                .ToList();
        }

        return withLatency[0].Region;
    }

    private double GetLatencyOrMax(string regionName)
    {
        if (_regionStats.TryGetValue(regionName, out var stats) && stats.SampleCount > 0)
        {
            return stats.AverageMs;
        }
        return double.MaxValue;
    }

    private static double HaversineDistance(double lat1, double lon1, double lat2, double lon2)
    {
        const double R = 6371.0; // Earth's radius in km

        var dLat = ToRadians(lat2 - lat1);
        var dLon = ToRadians(lon2 - lon1);

        var a = Math.Sin(dLat / 2) * Math.Sin(dLat / 2) +
                Math.Cos(ToRadians(lat1)) * Math.Cos(ToRadians(lat2)) *
                Math.Sin(dLon / 2) * Math.Sin(dLon / 2);
        var c = 2 * Math.Atan2(Math.Sqrt(a), Math.Sqrt(1 - a));

        return R * c;
    }

    private static double ToRadians(double degrees) => degrees * Math.PI / 180.0;

    private RegionLatencyStats GetOrCreateStats(string regionName)
    {
        return _regionStats.GetOrAdd(regionName,
            _ => new RegionLatencyStats(_config.LatencySampleSize));
    }

    private async Task RunProbingLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var regions = await FetchRegionsAsync(cancellationToken);
                foreach (var region in regions)
                {
                    if (cancellationToken.IsCancellationRequested)
                        break;

                    await ProbeRegionAsync(region, cancellationToken);
                }

                await Task.Delay(_config.ProbeIntervalMs, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                // Continue probing on errors
                await Task.Delay(_config.ProbeIntervalMs, cancellationToken);
            }
        }
    }

    private async Task ProbeRegionAsync(RegionInfo region, CancellationToken cancellationToken)
    {
        var parts = region.Endpoint.Split(':');
        if (parts.Length != 2 || !int.TryParse(parts[1], out var port))
        {
            return;
        }

        var host = parts[0];
        var stats = GetOrCreateStats(region.Name);

        try
        {
            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            var sw = System.Diagnostics.Stopwatch.StartNew();

            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(_config.ProbeTimeoutMs);

            await socket.ConnectAsync(host, port, cts.Token);
            sw.Stop();

            var latencyMs = sw.Elapsed.TotalMilliseconds;
            stats.AddSample(latencyMs);
            _metrics.RecordLatency(region.Name, latencyMs);
        }
        catch
        {
            stats.RecordFailure(_config.FailureThreshold);
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;
        _probingCts?.Cancel();
        _probingCts?.Dispose();
        _httpClient.Dispose();
    }
}
