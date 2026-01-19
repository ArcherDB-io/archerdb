// Package georouting provides geo-routing capabilities for the ArcherDB Go SDK
// per the add-geo-routing spec.
//
// Features:
//   - Region Discovery: Fetch available regions from /regions endpoint with caching
//   - Latency Probing: Background TCP latency probing with rolling averages
//   - Region Selection: Filter healthy → apply preference → select lowest latency
//   - Automatic Failover: Mark unhealthy after consecutive failures, select next best
//   - Metrics: Prometheus-format metrics (queries_total, region_switches_total, region_latency_ms)
package georouting

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ============================================================================
// Configuration
// ============================================================================

// Config holds geo-routing configuration options.
type Config struct {
	// Enabled enables geo-routing. Default: false.
	Enabled bool

	// PreferredRegion is the region to prefer when multiple are available.
	PreferredRegion string

	// FailoverEnabled enables automatic failover to another region on failure.
	// Default: true when Enabled is true.
	FailoverEnabled bool

	// ProbeIntervalMs is the interval between latency probes in milliseconds.
	// Default: 30000 (30 seconds).
	ProbeIntervalMs int

	// ProbeTimeoutMs is the timeout for a single probe in milliseconds.
	// Default: 5000 (5 seconds).
	ProbeTimeoutMs int

	// FailureThreshold is the number of consecutive failures before marking unhealthy.
	// Default: 3.
	FailureThreshold int

	// CacheTTLMs is the TTL for region discovery cache in milliseconds.
	// Default: 300000 (5 minutes).
	CacheTTLMs int

	// LatencySampleSize is the number of latency samples for rolling average.
	// Default: 5.
	LatencySampleSize int

	// ClientLocation is the client's geographic location for distance-based selection.
	ClientLocation *Location
}

// DefaultConfig returns a Config with default values.
func DefaultConfig() Config {
	return Config{
		Enabled:           false,
		FailoverEnabled:   true,
		ProbeIntervalMs:   30000,
		ProbeTimeoutMs:    5000,
		FailureThreshold:  3,
		CacheTTLMs:        300000,
		LatencySampleSize: 5,
	}
}

// ============================================================================
// Types
// ============================================================================

// Location represents a geographic coordinate.
type Location struct {
	Latitude  float64
	Longitude float64
}

// RegionInfo holds information about a region.
type RegionInfo struct {
	// Name is the unique region identifier (e.g., "us-east-1").
	Name string `json:"name"`

	// Endpoint is the region's connection endpoint (host:port).
	Endpoint string `json:"endpoint"`

	// Location is the region's geographic location.
	Location Location `json:"location"`

	// Healthy indicates if the region is healthy.
	Healthy bool `json:"healthy"`
}

// DiscoveryResponse is the response from the /regions endpoint.
type DiscoveryResponse struct {
	Regions   []RegionInfo `json:"regions"`
	ExpiresAt time.Time    `json:"-"`
	FetchedAt time.Time    `json:"-"`
}

// IsExpired returns true if the cached response is expired.
func (d *DiscoveryResponse) IsExpired(cacheTTLMs int) bool {
	if !d.ExpiresAt.IsZero() {
		return time.Now().After(d.ExpiresAt)
	}
	ttl := time.Duration(cacheTTLMs) * time.Millisecond
	return time.Since(d.FetchedAt) > ttl
}

// ============================================================================
// Latency Stats
// ============================================================================

// LatencyStats tracks latency statistics for a region.
type LatencyStats struct {
	mu                  sync.Mutex
	samples             []float64
	maxSamples          int
	averageMs           float64
	consecutiveFailures int
	healthy             bool
	lastProbe           time.Time
}

// NewLatencyStats creates a new LatencyStats.
func NewLatencyStats(maxSamples int) *LatencyStats {
	if maxSamples <= 0 {
		maxSamples = 5
	}
	return &LatencyStats{
		samples:    make([]float64, 0, maxSamples),
		maxSamples: maxSamples,
		healthy:    true,
	}
}

// AddSample adds a latency sample in milliseconds.
func (s *LatencyStats) AddSample(latencyMs float64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.samples = append(s.samples, latencyMs)
	if len(s.samples) > s.maxSamples {
		s.samples = s.samples[1:]
	}

	// Calculate rolling average
	var sum float64
	for _, v := range s.samples {
		sum += v
	}
	s.averageMs = sum / float64(len(s.samples))
	s.consecutiveFailures = 0
	s.healthy = true
	s.lastProbe = time.Now()
}

// RecordFailure records a probe failure.
func (s *LatencyStats) RecordFailure(threshold int) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.consecutiveFailures++
	if s.consecutiveFailures >= threshold {
		s.healthy = false
	}
	s.lastProbe = time.Now()
}

// GetAverageMs returns the average latency in milliseconds.
func (s *LatencyStats) GetAverageMs() float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.averageMs
}

// IsHealthy returns true if the region is healthy.
func (s *LatencyStats) IsHealthy() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.healthy
}

// GetConsecutiveFailures returns the number of consecutive failures.
func (s *LatencyStats) GetConsecutiveFailures() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.consecutiveFailures
}

// MarkHealthy marks the region as healthy and resets failures.
func (s *LatencyStats) MarkHealthy() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.healthy = true
	s.consecutiveFailures = 0
}

// MarkUnhealthy marks the region as unhealthy.
func (s *LatencyStats) MarkUnhealthy() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.healthy = false
}

// GetSampleCount returns the number of samples.
func (s *LatencyStats) GetSampleCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.samples)
}

// ============================================================================
// Metrics
// ============================================================================

// Metrics tracks geo-routing metrics.
type Metrics struct {
	queriesTotal        int64
	regionSwitchesTotal int64
	regionLatencies     sync.Map // map[string]*int64 (total latency in microseconds)
	regionLatencyCounts sync.Map // map[string]*int64 (count)
	currentRegion       atomic.Value
}

// NewMetrics creates a new Metrics.
func NewMetrics() *Metrics {
	m := &Metrics{}
	m.currentRegion.Store("")
	return m
}

// RecordQuery records a query.
func (m *Metrics) RecordQuery(region string) {
	atomic.AddInt64(&m.queriesTotal, 1)
}

// RecordSwitch records a region switch.
func (m *Metrics) RecordSwitch(fromRegion, toRegion string) {
	atomic.AddInt64(&m.regionSwitchesTotal, 1)
	m.currentRegion.Store(toRegion)
}

// RecordLatency records a latency sample.
func (m *Metrics) RecordLatency(region string, latencyMs float64) {
	latencyUs := int64(latencyMs * 1000)

	// Update total
	totalKey := region
	actual, _ := m.regionLatencies.LoadOrStore(totalKey, new(int64))
	atomic.AddInt64(actual.(*int64), latencyUs)

	// Update count
	actual, _ = m.regionLatencyCounts.LoadOrStore(totalKey, new(int64))
	atomic.AddInt64(actual.(*int64), 1)
}

// GetQueriesTotal returns total queries.
func (m *Metrics) GetQueriesTotal() int64 {
	return atomic.LoadInt64(&m.queriesTotal)
}

// GetSwitchesTotal returns total region switches.
func (m *Metrics) GetSwitchesTotal() int64 {
	return atomic.LoadInt64(&m.regionSwitchesTotal)
}

// GetCurrentRegion returns the current region.
func (m *Metrics) GetCurrentRegion() string {
	return m.currentRegion.Load().(string)
}

// ToPrometheus exports metrics in Prometheus text format.
func (m *Metrics) ToPrometheus() string {
	var sb strings.Builder

	sb.WriteString("# HELP archerdb_geo_routing_queries_total Total geo-routed queries\n")
	sb.WriteString("# TYPE archerdb_geo_routing_queries_total counter\n")
	sb.WriteString(fmt.Sprintf("archerdb_geo_routing_queries_total %d\n", m.GetQueriesTotal()))

	sb.WriteString("# HELP archerdb_geo_routing_region_switches_total Total region switches\n")
	sb.WriteString("# TYPE archerdb_geo_routing_region_switches_total counter\n")
	sb.WriteString(fmt.Sprintf("archerdb_geo_routing_region_switches_total %d\n", m.GetSwitchesTotal()))

	sb.WriteString("# HELP archerdb_geo_routing_region_latency_ms Region latency in milliseconds\n")
	sb.WriteString("# TYPE archerdb_geo_routing_region_latency_ms gauge\n")
	m.regionLatencies.Range(func(key, value interface{}) bool {
		region := key.(string)
		totalUs := atomic.LoadInt64(value.(*int64))

		countVal, ok := m.regionLatencyCounts.Load(region)
		if ok {
			count := atomic.LoadInt64(countVal.(*int64))
			if count > 0 {
				avgMs := float64(totalUs) / float64(count) / 1000.0
				sb.WriteString(fmt.Sprintf("archerdb_geo_routing_region_latency_ms{region=\"%s\"} %.3f\n", region, avgMs))
			}
		}
		return true
	})

	return sb.String()
}

// Reset resets all metrics.
func (m *Metrics) Reset() {
	atomic.StoreInt64(&m.queriesTotal, 0)
	atomic.StoreInt64(&m.regionSwitchesTotal, 0)
	m.regionLatencies = sync.Map{}
	m.regionLatencyCounts = sync.Map{}
	m.currentRegion.Store("")
}

// ============================================================================
// Region Discovery
// ============================================================================

// DiscoveryClient fetches region information from the /regions endpoint.
type DiscoveryClient struct {
	baseURL    string
	httpClient *http.Client
	cache      *DiscoveryResponse
	cacheMu    sync.RWMutex
	cacheTTLMs int
}

// NewDiscoveryClient creates a new DiscoveryClient.
func NewDiscoveryClient(baseURL string, timeoutMs, cacheTTLMs int) *DiscoveryClient {
	return &DiscoveryClient{
		baseURL: strings.TrimSuffix(baseURL, "/"),
		httpClient: &http.Client{
			Timeout: time.Duration(timeoutMs) * time.Millisecond,
		},
		cacheTTLMs: cacheTTLMs,
	}
}

// Fetch fetches regions from the discovery endpoint.
func (c *DiscoveryClient) Fetch(ctx context.Context) (*DiscoveryResponse, error) {
	// Check cache first
	c.cacheMu.RLock()
	if c.cache != nil && !c.cache.IsExpired(c.cacheTTLMs) {
		resp := c.cache
		c.cacheMu.RUnlock()
		return resp, nil
	}
	c.cacheMu.RUnlock()

	// Fetch from server
	url := c.baseURL + "/regions"
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch regions: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("unexpected status %d: %s", resp.StatusCode, string(body))
	}

	var result struct {
		Regions []RegionInfo `json:"regions"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	discovery := &DiscoveryResponse{
		Regions:   result.Regions,
		FetchedAt: time.Now(),
	}

	// Update cache
	c.cacheMu.Lock()
	c.cache = discovery
	c.cacheMu.Unlock()

	return discovery, nil
}

// InvalidateCache invalidates the discovery cache.
func (c *DiscoveryClient) InvalidateCache() {
	c.cacheMu.Lock()
	c.cache = nil
	c.cacheMu.Unlock()
}

// ============================================================================
// Latency Prober
// ============================================================================

// Prober probes regions for latency.
type Prober struct {
	config    Config
	stats     map[string]*LatencyStats
	statsMu   sync.RWMutex
	stopCh    chan struct{}
	running   bool
	runningMu sync.Mutex
}

// NewProber creates a new Prober.
func NewProber(config Config) *Prober {
	return &Prober{
		config: config,
		stats:  make(map[string]*LatencyStats),
		stopCh: make(chan struct{}),
	}
}

// ProbeOnce probes a single region and returns the latency in milliseconds.
func (p *Prober) ProbeOnce(ctx context.Context, endpoint string) (float64, error) {
	timeout := time.Duration(p.config.ProbeTimeoutMs) * time.Millisecond

	dialer := &net.Dialer{
		Timeout: timeout,
	}

	start := time.Now()

	conn, err := dialer.DialContext(ctx, "tcp", endpoint)
	if err != nil {
		return 0, err
	}
	conn.Close()

	return float64(time.Since(start).Milliseconds()), nil
}

// ProbeRegion probes a region and updates its stats.
func (p *Prober) ProbeRegion(ctx context.Context, region RegionInfo) {
	latencyMs, err := p.ProbeOnce(ctx, region.Endpoint)

	p.statsMu.Lock()
	stats, ok := p.stats[region.Name]
	if !ok {
		stats = NewLatencyStats(p.config.LatencySampleSize)
		p.stats[region.Name] = stats
	}
	p.statsMu.Unlock()

	if err != nil {
		stats.RecordFailure(p.config.FailureThreshold)
	} else {
		stats.AddSample(latencyMs)
	}
}

// GetStats returns the latency stats for a region.
func (p *Prober) GetStats(regionName string) *LatencyStats {
	p.statsMu.RLock()
	defer p.statsMu.RUnlock()
	return p.stats[regionName]
}

// GetOrCreateStats returns or creates stats for a region.
func (p *Prober) GetOrCreateStats(regionName string) *LatencyStats {
	p.statsMu.Lock()
	defer p.statsMu.Unlock()

	stats, ok := p.stats[regionName]
	if !ok {
		stats = NewLatencyStats(p.config.LatencySampleSize)
		p.stats[regionName] = stats
	}
	return stats
}

// Start starts background probing.
func (p *Prober) Start(regions []RegionInfo) {
	p.runningMu.Lock()
	if p.running {
		p.runningMu.Unlock()
		return
	}
	p.running = true
	p.stopCh = make(chan struct{})
	p.runningMu.Unlock()

	go func() {
		ticker := time.NewTicker(time.Duration(p.config.ProbeIntervalMs) * time.Millisecond)
		defer ticker.Stop()

		// Initial probe
		for _, region := range regions {
			ctx, cancel := context.WithTimeout(context.Background(), time.Duration(p.config.ProbeTimeoutMs)*time.Millisecond)
			p.ProbeRegion(ctx, region)
			cancel()
		}

		for {
			select {
			case <-p.stopCh:
				return
			case <-ticker.C:
				for _, region := range regions {
					ctx, cancel := context.WithTimeout(context.Background(), time.Duration(p.config.ProbeTimeoutMs)*time.Millisecond)
					p.ProbeRegion(ctx, region)
					cancel()
				}
			}
		}
	}()
}

// Stop stops background probing.
func (p *Prober) Stop() {
	p.runningMu.Lock()
	defer p.runningMu.Unlock()

	if p.running {
		close(p.stopCh)
		p.running = false
	}
}

// ============================================================================
// Region Selector
// ============================================================================

// Selector selects the best region based on configuration.
type Selector struct {
	config  Config
	prober  *Prober
	metrics *Metrics
}

// NewSelector creates a new Selector.
func NewSelector(config Config, prober *Prober, metrics *Metrics) *Selector {
	return &Selector{
		config:  config,
		prober:  prober,
		metrics: metrics,
	}
}

// Select selects the best region from available regions.
// excludeRegions can be used to exclude specific regions (e.g., after failure).
func (s *Selector) Select(regions []RegionInfo, excludeRegions ...string) (*RegionInfo, error) {
	if len(regions) == 0 {
		return nil, errors.New("no regions available")
	}

	excludeSet := make(map[string]bool)
	for _, r := range excludeRegions {
		excludeSet[r] = true
	}

	// Filter healthy regions not in exclude list
	var candidates []RegionInfo
	for _, r := range regions {
		if excludeSet[r.Name] {
			continue
		}

		// Check health from prober stats
		stats := s.prober.GetStats(r.Name)
		if stats != nil && !stats.IsHealthy() {
			continue
		}

		// Also skip if region reports itself unhealthy
		if !r.Healthy {
			continue
		}

		candidates = append(candidates, r)
	}

	if len(candidates) == 0 {
		return nil, errors.New("no healthy regions available")
	}

	// If preferred region is specified and available, use it
	if s.config.PreferredRegion != "" {
		for _, r := range candidates {
			if r.Name == s.config.PreferredRegion {
				return &r, nil
			}
		}
	}

	// Select by lowest latency
	type candidateWithLatency struct {
		region  RegionInfo
		latency float64
	}

	var withLatency []candidateWithLatency
	for _, r := range candidates {
		stats := s.prober.GetStats(r.Name)
		latency := math.MaxFloat64
		if stats != nil && stats.GetSampleCount() > 0 {
			latency = stats.GetAverageMs()
		}
		withLatency = append(withLatency, candidateWithLatency{r, latency})
	}

	// Sort by latency
	sort.Slice(withLatency, func(i, j int) bool {
		return withLatency[i].latency < withLatency[j].latency
	})

	// If no latency data available, fall back to distance
	if withLatency[0].latency == math.MaxFloat64 && s.config.ClientLocation != nil {
		sort.Slice(withLatency, func(i, j int) bool {
			distI := haversineDistance(s.config.ClientLocation, &withLatency[i].region.Location)
			distJ := haversineDistance(s.config.ClientLocation, &withLatency[j].region.Location)
			return distI < distJ
		})
	}

	return &withLatency[0].region, nil
}

// haversineDistance calculates distance in km between two points.
func haversineDistance(from, to *Location) float64 {
	const R = 6371.0 // Earth's radius in km

	lat1 := from.Latitude * math.Pi / 180
	lat2 := to.Latitude * math.Pi / 180
	dLat := (to.Latitude - from.Latitude) * math.Pi / 180
	dLon := (to.Longitude - from.Longitude) * math.Pi / 180

	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1)*math.Cos(lat2)*math.Sin(dLon/2)*math.Sin(dLon/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))

	return R * c
}

// ============================================================================
// GeoRouter
// ============================================================================

// GeoRouter is the main coordinator for geo-routing.
type GeoRouter struct {
	config          Config
	discoveryClient *DiscoveryClient
	prober          *Prober
	selector        *Selector
	metrics         *Metrics
	currentRegion   atomic.Value
	mu              sync.Mutex
}

// NewGeoRouter creates a new GeoRouter.
func NewGeoRouter(discoveryURL string, config Config) *GeoRouter {
	if config.ProbeIntervalMs == 0 {
		config = DefaultConfig()
		config.Enabled = true
	}

	metrics := NewMetrics()
	prober := NewProber(config)
	selector := NewSelector(config, prober, metrics)

	gr := &GeoRouter{
		config:          config,
		discoveryClient: NewDiscoveryClient(discoveryURL, config.ProbeTimeoutMs, config.CacheTTLMs),
		prober:          prober,
		selector:        selector,
		metrics:         metrics,
	}
	gr.currentRegion.Store("")

	return gr
}

// Start initializes the geo-router by fetching regions and starting probing.
func (gr *GeoRouter) Start(ctx context.Context) error {
	if !gr.config.Enabled {
		return nil
	}

	discovery, err := gr.discoveryClient.Fetch(ctx)
	if err != nil {
		return fmt.Errorf("failed to fetch regions: %w", err)
	}

	if len(discovery.Regions) == 0 {
		return errors.New("no regions discovered")
	}

	// Start background probing
	gr.prober.Start(discovery.Regions)

	// Select initial region
	region, err := gr.selector.Select(discovery.Regions)
	if err != nil {
		return fmt.Errorf("failed to select initial region: %w", err)
	}

	gr.currentRegion.Store(region.Name)
	gr.metrics.currentRegion.Store(region.Name)

	return nil
}

// Stop stops the geo-router.
func (gr *GeoRouter) Stop() {
	gr.prober.Stop()
}

// GetCurrentRegion returns the currently selected region.
func (gr *GeoRouter) GetCurrentRegion() string {
	return gr.currentRegion.Load().(string)
}

// GetCurrentEndpoint returns the endpoint for the currently selected region.
func (gr *GeoRouter) GetCurrentEndpoint(ctx context.Context) (string, error) {
	if !gr.config.Enabled {
		return "", errors.New("geo-routing not enabled")
	}

	current := gr.GetCurrentRegion()
	if current == "" {
		return "", errors.New("no region selected")
	}

	discovery, err := gr.discoveryClient.Fetch(ctx)
	if err != nil {
		return "", err
	}

	for _, r := range discovery.Regions {
		if r.Name == current {
			return r.Endpoint, nil
		}
	}

	return "", fmt.Errorf("region %s not found", current)
}

// SelectRegion selects a region, optionally excluding specific regions.
func (gr *GeoRouter) SelectRegion(ctx context.Context, excludeRegions ...string) (*RegionInfo, error) {
	gr.mu.Lock()
	defer gr.mu.Unlock()

	discovery, err := gr.discoveryClient.Fetch(ctx)
	if err != nil {
		return nil, err
	}

	region, err := gr.selector.Select(discovery.Regions, excludeRegions...)
	if err != nil {
		return nil, err
	}

	oldRegion := gr.currentRegion.Load().(string)
	if oldRegion != region.Name {
		gr.currentRegion.Store(region.Name)
		gr.metrics.RecordSwitch(oldRegion, region.Name)
	}

	return region, nil
}

// RecordSuccess records a successful operation.
func (gr *GeoRouter) RecordSuccess(regionName string) {
	gr.metrics.RecordQuery(regionName)
	stats := gr.prober.GetOrCreateStats(regionName)
	stats.MarkHealthy()
}

// RecordFailure records a failed operation and triggers failover if enabled.
func (gr *GeoRouter) RecordFailure(ctx context.Context, regionName string) (*RegionInfo, error) {
	stats := gr.prober.GetOrCreateStats(regionName)
	stats.RecordFailure(gr.config.FailureThreshold)

	// Check if failover is enabled
	if !gr.config.FailoverEnabled {
		return nil, nil
	}

	// Check if we need to failover
	if !stats.IsHealthy() {
		// Try to select a different region
		return gr.SelectRegion(ctx, regionName)
	}

	return nil, nil
}

// GetMetrics returns the metrics instance.
func (gr *GeoRouter) GetMetrics() *Metrics {
	return gr.metrics
}

// GetConfig returns the configuration.
func (gr *GeoRouter) GetConfig() Config {
	return gr.config
}

// RefreshRegions refreshes the region list from the discovery endpoint.
func (gr *GeoRouter) RefreshRegions(ctx context.Context) error {
	gr.discoveryClient.InvalidateCache()

	discovery, err := gr.discoveryClient.Fetch(ctx)
	if err != nil {
		return err
	}

	// Restart probing with new regions
	gr.prober.Stop()
	gr.prober.Start(discovery.Regions)

	return nil
}

// IsEnabled returns true if geo-routing is enabled.
func (gr *GeoRouter) IsEnabled() bool {
	return gr.config.Enabled
}
