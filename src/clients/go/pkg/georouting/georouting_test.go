package georouting

import (
	"context"
	"encoding/json"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// ============================================================================
// Config Tests
// ============================================================================

func TestDefaultConfig(t *testing.T) {
	config := DefaultConfig()

	if config.Enabled {
		t.Error("Expected Enabled to be false by default")
	}
	if !config.FailoverEnabled {
		t.Error("Expected FailoverEnabled to be true by default")
	}
	if config.ProbeIntervalMs != 30000 {
		t.Errorf("Expected ProbeIntervalMs to be 30000, got %d", config.ProbeIntervalMs)
	}
	if config.ProbeTimeoutMs != 5000 {
		t.Errorf("Expected ProbeTimeoutMs to be 5000, got %d", config.ProbeTimeoutMs)
	}
	if config.FailureThreshold != 3 {
		t.Errorf("Expected FailureThreshold to be 3, got %d", config.FailureThreshold)
	}
	if config.CacheTTLMs != 300000 {
		t.Errorf("Expected CacheTTLMs to be 300000, got %d", config.CacheTTLMs)
	}
	if config.LatencySampleSize != 5 {
		t.Errorf("Expected LatencySampleSize to be 5, got %d", config.LatencySampleSize)
	}
}

// ============================================================================
// LatencyStats Tests
// ============================================================================

func TestLatencyStatsAddSample(t *testing.T) {
	stats := NewLatencyStats(5)

	stats.AddSample(10.0)
	if stats.GetAverageMs() != 10.0 {
		t.Errorf("Expected average 10.0, got %f", stats.GetAverageMs())
	}
	if !stats.IsHealthy() {
		t.Error("Expected healthy after adding sample")
	}
}

func TestLatencyStatsRollingWindow(t *testing.T) {
	stats := NewLatencyStats(3)

	stats.AddSample(10.0)
	stats.AddSample(20.0)
	stats.AddSample(30.0)
	stats.AddSample(40.0) // Should drop 10.0

	expected := (20.0 + 30.0 + 40.0) / 3.0
	if math.Abs(stats.GetAverageMs()-expected) > 0.01 {
		t.Errorf("Expected average %f, got %f", expected, stats.GetAverageMs())
	}
	if stats.GetSampleCount() != 3 {
		t.Errorf("Expected 3 samples, got %d", stats.GetSampleCount())
	}
}

func TestLatencyStatsRecordFailure(t *testing.T) {
	stats := NewLatencyStats(5)
	threshold := 3

	// Record failures up to threshold
	for i := 0; i < threshold; i++ {
		if !stats.IsHealthy() {
			t.Errorf("Expected healthy before %d failures", threshold)
		}
		stats.RecordFailure(threshold)
	}

	if stats.IsHealthy() {
		t.Error("Expected unhealthy after threshold failures")
	}
	if stats.GetConsecutiveFailures() != threshold {
		t.Errorf("Expected %d failures, got %d", threshold, stats.GetConsecutiveFailures())
	}
}

func TestLatencyStatsSuccessResetsFailures(t *testing.T) {
	stats := NewLatencyStats(5)
	threshold := 3

	// Record some failures
	stats.RecordFailure(threshold)
	stats.RecordFailure(threshold)

	// Add successful sample
	stats.AddSample(10.0)

	if stats.GetConsecutiveFailures() != 0 {
		t.Errorf("Expected 0 failures after success, got %d", stats.GetConsecutiveFailures())
	}
	if !stats.IsHealthy() {
		t.Error("Expected healthy after successful sample")
	}
}

func TestLatencyStatsMarkHealthy(t *testing.T) {
	stats := NewLatencyStats(5)

	// Make unhealthy
	for i := 0; i < 3; i++ {
		stats.RecordFailure(3)
	}
	if stats.IsHealthy() {
		t.Error("Expected unhealthy after failures")
	}

	// Mark healthy
	stats.MarkHealthy()
	if !stats.IsHealthy() {
		t.Error("Expected healthy after MarkHealthy")
	}
	if stats.GetConsecutiveFailures() != 0 {
		t.Error("Expected 0 failures after MarkHealthy")
	}
}

// ============================================================================
// Metrics Tests
// ============================================================================

func TestMetricsRecordQuery(t *testing.T) {
	metrics := NewMetrics()

	metrics.RecordQuery("us-east-1")
	metrics.RecordQuery("us-east-1")

	if metrics.GetQueriesTotal() != 2 {
		t.Errorf("Expected 2 queries, got %d", metrics.GetQueriesTotal())
	}
}

func TestMetricsRecordSwitch(t *testing.T) {
	metrics := NewMetrics()

	metrics.RecordSwitch("us-east-1", "us-west-2")

	if metrics.GetSwitchesTotal() != 1 {
		t.Errorf("Expected 1 switch, got %d", metrics.GetSwitchesTotal())
	}
	if metrics.GetCurrentRegion() != "us-west-2" {
		t.Errorf("Expected current region us-west-2, got %s", metrics.GetCurrentRegion())
	}
}

func TestMetricsRecordLatency(t *testing.T) {
	metrics := NewMetrics()

	metrics.RecordLatency("us-east-1", 10.0)
	metrics.RecordLatency("us-east-1", 20.0)

	// Prometheus output should include latency
	prometheus := metrics.ToPrometheus()
	if !strings.Contains(prometheus, "archerdb_geo_routing_region_latency_ms") {
		t.Error("Expected latency metric in Prometheus output")
	}
	if !strings.Contains(prometheus, "us-east-1") {
		t.Error("Expected region label in Prometheus output")
	}
}

func TestMetricsToPrometheus(t *testing.T) {
	metrics := NewMetrics()

	metrics.RecordQuery("us-east-1")
	metrics.RecordSwitch("", "us-east-1")

	prometheus := metrics.ToPrometheus()

	if !strings.Contains(prometheus, "archerdb_geo_routing_queries_total 1") {
		t.Error("Expected queries_total in Prometheus output")
	}
	if !strings.Contains(prometheus, "archerdb_geo_routing_region_switches_total 1") {
		t.Error("Expected switches_total in Prometheus output")
	}
}

func TestMetricsReset(t *testing.T) {
	metrics := NewMetrics()

	metrics.RecordQuery("us-east-1")
	metrics.RecordSwitch("", "us-east-1")
	metrics.Reset()

	if metrics.GetQueriesTotal() != 0 {
		t.Error("Expected 0 queries after reset")
	}
	if metrics.GetSwitchesTotal() != 0 {
		t.Error("Expected 0 switches after reset")
	}
}

// ============================================================================
// Discovery Tests
// ============================================================================

func TestDiscoveryResponseIsExpired(t *testing.T) {
	// Not expired
	resp := &DiscoveryResponse{
		FetchedAt: time.Now(),
	}
	if resp.IsExpired(300000) {
		t.Error("Expected not expired immediately after fetch")
	}

	// Expired by time
	resp = &DiscoveryResponse{
		FetchedAt: time.Now().Add(-6 * time.Minute),
	}
	if !resp.IsExpired(300000) {
		t.Error("Expected expired after TTL")
	}

	// Expired by explicit ExpiresAt
	resp = &DiscoveryResponse{
		FetchedAt: time.Now(),
		ExpiresAt: time.Now().Add(-1 * time.Second),
	}
	if !resp.IsExpired(300000) {
		t.Error("Expected expired when ExpiresAt is in past")
	}
}

func TestDiscoveryClientFetch(t *testing.T) {
	// Create test server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/regions" {
			t.Errorf("Expected path /regions, got %s", r.URL.Path)
		}

		response := map[string]interface{}{
			"regions": []map[string]interface{}{
				{
					"name":     "us-east-1",
					"endpoint": "us-east-1.example.com:8080",
					"location": map[string]float64{
						"Latitude":  37.7749,
						"Longitude": -122.4194,
					},
					"healthy": true,
				},
			},
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()

	client := NewDiscoveryClient(server.URL, 5000, 300000)

	ctx := context.Background()
	resp, err := client.Fetch(ctx)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if len(resp.Regions) != 1 {
		t.Errorf("Expected 1 region, got %d", len(resp.Regions))
	}
	if resp.Regions[0].Name != "us-east-1" {
		t.Errorf("Expected region name us-east-1, got %s", resp.Regions[0].Name)
	}
}

func TestDiscoveryClientCaching(t *testing.T) {
	fetchCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fetchCount++
		response := map[string]interface{}{
			"regions": []map[string]interface{}{
				{"name": "us-east-1", "endpoint": "localhost:8080", "healthy": true},
			},
		}
		json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()

	client := NewDiscoveryClient(server.URL, 5000, 300000)
	ctx := context.Background()

	// First fetch
	_, err := client.Fetch(ctx)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	// Second fetch should use cache
	_, err = client.Fetch(ctx)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if fetchCount != 1 {
		t.Errorf("Expected 1 server fetch (cached), got %d", fetchCount)
	}

	// Invalidate cache
	client.InvalidateCache()

	// Third fetch should hit server
	_, err = client.Fetch(ctx)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if fetchCount != 2 {
		t.Errorf("Expected 2 server fetches after invalidate, got %d", fetchCount)
	}
}

// ============================================================================
// Prober Tests
// ============================================================================

func TestProberProbeOnce(t *testing.T) {
	// Start a test listener
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to start listener: %v", err)
	}
	defer listener.Close()

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()

	config := Config{
		ProbeTimeoutMs: 1000,
	}
	prober := NewProber(config)

	ctx := context.Background()
	latency, err := prober.ProbeOnce(ctx, listener.Addr().String())
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if latency < 0 {
		t.Error("Expected non-negative latency")
	}
}

func TestProberProbeRegionSuccess(t *testing.T) {
	// Start a test listener
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to start listener: %v", err)
	}
	defer listener.Close()

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()

	config := Config{
		ProbeTimeoutMs:    1000,
		FailureThreshold:  3,
		LatencySampleSize: 5,
	}
	prober := NewProber(config)

	region := RegionInfo{
		Name:     "test-region",
		Endpoint: listener.Addr().String(),
	}

	ctx := context.Background()
	prober.ProbeRegion(ctx, region)

	stats := prober.GetStats("test-region")
	if stats == nil {
		t.Fatal("Expected stats to be created")
	}
	if !stats.IsHealthy() {
		t.Error("Expected healthy after successful probe")
	}
	if stats.GetSampleCount() != 1 {
		t.Errorf("Expected 1 sample, got %d", stats.GetSampleCount())
	}
}

func TestProberProbeRegionFailure(t *testing.T) {
	config := Config{
		ProbeTimeoutMs:    100, // Short timeout
		FailureThreshold:  2,
		LatencySampleSize: 5,
	}
	prober := NewProber(config)

	region := RegionInfo{
		Name:     "test-region",
		Endpoint: "127.0.0.1:1", // Invalid port
	}

	ctx := context.Background()
	prober.ProbeRegion(ctx, region)
	prober.ProbeRegion(ctx, region)

	stats := prober.GetStats("test-region")
	if stats == nil {
		t.Fatal("Expected stats to be created")
	}
	if stats.IsHealthy() {
		t.Error("Expected unhealthy after failures")
	}
}

// ============================================================================
// Selector Tests
// ============================================================================

func TestSelectorSelectPreferred(t *testing.T) {
	config := Config{
		PreferredRegion:   "us-west-2",
		FailureThreshold:  3,
		LatencySampleSize: 5,
	}
	prober := NewProber(config)
	metrics := NewMetrics()
	selector := NewSelector(config, prober, metrics)

	regions := []RegionInfo{
		{Name: "us-east-1", Endpoint: "localhost:8081", Healthy: true},
		{Name: "us-west-2", Endpoint: "localhost:8082", Healthy: true},
	}

	region, err := selector.Select(regions)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if region.Name != "us-west-2" {
		t.Errorf("Expected preferred region us-west-2, got %s", region.Name)
	}
}

func TestSelectorSelectByLatency(t *testing.T) {
	config := Config{
		FailureThreshold:  3,
		LatencySampleSize: 5,
	}
	prober := NewProber(config)
	metrics := NewMetrics()
	selector := NewSelector(config, prober, metrics)

	// Set up latency stats
	stats1 := prober.GetOrCreateStats("us-east-1")
	stats1.AddSample(50.0)

	stats2 := prober.GetOrCreateStats("us-west-2")
	stats2.AddSample(10.0) // Lower latency

	regions := []RegionInfo{
		{Name: "us-east-1", Endpoint: "localhost:8081", Healthy: true},
		{Name: "us-west-2", Endpoint: "localhost:8082", Healthy: true},
	}

	region, err := selector.Select(regions)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if region.Name != "us-west-2" {
		t.Errorf("Expected lowest latency region us-west-2, got %s", region.Name)
	}
}

func TestSelectorSelectHealthyOnly(t *testing.T) {
	config := Config{
		FailureThreshold:  3,
		LatencySampleSize: 5,
	}
	prober := NewProber(config)
	metrics := NewMetrics()
	selector := NewSelector(config, prober, metrics)

	// Make one region unhealthy via prober
	stats := prober.GetOrCreateStats("us-east-1")
	stats.AddSample(10.0)
	stats.MarkUnhealthy()

	// Set up healthy region
	stats2 := prober.GetOrCreateStats("us-west-2")
	stats2.AddSample(20.0)

	regions := []RegionInfo{
		{Name: "us-east-1", Endpoint: "localhost:8081", Healthy: true},
		{Name: "us-west-2", Endpoint: "localhost:8082", Healthy: true},
	}

	region, err := selector.Select(regions)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if region.Name != "us-west-2" {
		t.Errorf("Expected healthy region us-west-2, got %s", region.Name)
	}
}

func TestSelectorSelectExclude(t *testing.T) {
	config := Config{
		FailureThreshold:  3,
		LatencySampleSize: 5,
	}
	prober := NewProber(config)
	metrics := NewMetrics()
	selector := NewSelector(config, prober, metrics)

	regions := []RegionInfo{
		{Name: "us-east-1", Endpoint: "localhost:8081", Healthy: true},
		{Name: "us-west-2", Endpoint: "localhost:8082", Healthy: true},
	}

	region, err := selector.Select(regions, "us-east-1")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if region.Name != "us-west-2" {
		t.Errorf("Expected non-excluded region us-west-2, got %s", region.Name)
	}
}

func TestSelectorNoRegions(t *testing.T) {
	config := Config{
		FailureThreshold:  3,
		LatencySampleSize: 5,
	}
	prober := NewProber(config)
	metrics := NewMetrics()
	selector := NewSelector(config, prober, metrics)

	_, err := selector.Select([]RegionInfo{})
	if err == nil {
		t.Error("Expected error for empty regions")
	}
}

func TestSelectorNoHealthyRegions(t *testing.T) {
	config := Config{
		FailureThreshold:  3,
		LatencySampleSize: 5,
	}
	prober := NewProber(config)
	metrics := NewMetrics()
	selector := NewSelector(config, prober, metrics)

	// Make all regions unhealthy
	stats := prober.GetOrCreateStats("us-east-1")
	stats.MarkUnhealthy()

	regions := []RegionInfo{
		{Name: "us-east-1", Endpoint: "localhost:8081", Healthy: true},
	}

	_, err := selector.Select(regions)
	if err == nil {
		t.Error("Expected error when no healthy regions")
	}
}

// ============================================================================
// Haversine Distance Tests
// ============================================================================

func TestHaversineDistance(t *testing.T) {
	// New York to Los Angeles ~3940 km
	nyc := &Location{Latitude: 40.7128, Longitude: -74.0060}
	la := &Location{Latitude: 34.0522, Longitude: -118.2437}

	distance := haversineDistance(nyc, la)

	// Allow 5% margin
	if distance < 3700 || distance > 4200 {
		t.Errorf("Expected distance ~3940 km, got %f", distance)
	}
}

func TestHaversineDistanceSamePoint(t *testing.T) {
	point := &Location{Latitude: 40.7128, Longitude: -74.0060}

	distance := haversineDistance(point, point)

	if distance != 0 {
		t.Errorf("Expected distance 0 for same point, got %f", distance)
	}
}

// ============================================================================
// GeoRouter Tests
// ============================================================================

func TestGeoRouterNotEnabled(t *testing.T) {
	config := DefaultConfig()
	config.Enabled = false

	router := NewGeoRouter("http://localhost:8080", config)

	ctx := context.Background()
	err := router.Start(ctx)
	if err != nil {
		t.Errorf("Expected no error when disabled, got %v", err)
	}

	_, err = router.GetCurrentEndpoint(ctx)
	if err == nil {
		t.Error("Expected error when geo-routing not enabled")
	}
}

func TestGeoRouterNoFailoverWhenDisabled(t *testing.T) {
	config := DefaultConfig()
	config.Enabled = true
	config.FailoverEnabled = false

	// Create test server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		response := map[string]interface{}{
			"regions": []map[string]interface{}{
				{"name": "us-east-1", "endpoint": "localhost:8081", "healthy": true},
				{"name": "us-west-2", "endpoint": "localhost:8082", "healthy": true},
			},
		}
		json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()

	router := NewGeoRouter(server.URL, config)

	ctx := context.Background()
	err := router.Start(ctx)
	if err != nil {
		t.Fatalf("Failed to start router: %v", err)
	}
	defer router.Stop()

	// Record failures
	newRegion, err := router.RecordFailure(ctx, "us-east-1")
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	// Should not switch when failover disabled
	if newRegion != nil {
		t.Error("Expected no failover when disabled")
	}
}

func TestGeoRouterIsEnabled(t *testing.T) {
	config := DefaultConfig()
	config.Enabled = true

	router := NewGeoRouter("http://localhost:8080", config)

	if !router.IsEnabled() {
		t.Error("Expected IsEnabled to return true")
	}
}

func TestGeoRouterGetConfig(t *testing.T) {
	config := DefaultConfig()
	config.Enabled = true
	config.PreferredRegion = "us-west-2"

	router := NewGeoRouter("http://localhost:8080", config)

	gotConfig := router.GetConfig()
	if gotConfig.PreferredRegion != "us-west-2" {
		t.Errorf("Expected PreferredRegion us-west-2, got %s", gotConfig.PreferredRegion)
	}
}

func TestGeoRouterRecordSuccess(t *testing.T) {
	config := DefaultConfig()
	config.Enabled = true

	router := NewGeoRouter("http://localhost:8080", config)

	router.RecordSuccess("us-east-1")

	if router.GetMetrics().GetQueriesTotal() != 1 {
		t.Error("Expected 1 query recorded")
	}
}

func TestGeoRouterIntegration(t *testing.T) {
	// Create test listener for probing
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to start listener: %v", err)
	}
	defer listener.Close()

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()

	// Create test server for discovery
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		response := map[string]interface{}{
			"regions": []map[string]interface{}{
				{
					"name":     "us-east-1",
					"endpoint": listener.Addr().String(),
					"healthy":  true,
				},
			},
		}
		json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()

	config := DefaultConfig()
	config.Enabled = true
	config.ProbeIntervalMs = 100
	config.ProbeTimeoutMs = 1000

	router := NewGeoRouter(server.URL, config)

	ctx := context.Background()
	err = router.Start(ctx)
	if err != nil {
		t.Fatalf("Failed to start router: %v", err)
	}
	defer router.Stop()

	// Wait for probing
	time.Sleep(200 * time.Millisecond)

	current := router.GetCurrentRegion()
	if current != "us-east-1" {
		t.Errorf("Expected current region us-east-1, got %s", current)
	}

	endpoint, err := router.GetCurrentEndpoint(ctx)
	if err != nil {
		t.Fatalf("Failed to get endpoint: %v", err)
	}
	if endpoint != listener.Addr().String() {
		t.Errorf("Expected endpoint %s, got %s", listener.Addr().String(), endpoint)
	}
}
