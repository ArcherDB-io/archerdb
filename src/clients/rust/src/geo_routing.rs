// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

//! Geo-routing client for ArcherDB.
//!
//! This module provides geo-routing functionality including:
//! - Region discovery from /regions endpoint
//! - Latency probing with rolling averages
//! - Region selection based on latency and health
//! - Automatic failover to backup regions
//! - Metrics for monitoring
//!
//! # Example
//!
//! ```no_run
//! use archerdb::geo_routing::{GeoRoutingConfig, GeoRouter, RegionInfo, RegionLocation};
//!
//! // Create sample regions (normally discovered from endpoint)
//! let regions = vec![
//!     RegionInfo {
//!         name: "us-east-1".to_string(),
//!         endpoint: "us-east.example.com:5000".to_string(),
//!         location: RegionLocation { latitude: 39.04, longitude: -77.49 },
//!         healthy: true,
//!     },
//!     RegionInfo {
//!         name: "eu-west-1".to_string(),
//!         endpoint: "eu-west.example.com:5000".to_string(),
//!         location: RegionLocation { latitude: 53.34, longitude: -6.26 },
//!         healthy: true,
//!     },
//! ];
//!
//! let config = GeoRoutingConfig {
//!     preferred_region: Some("us-east-1".to_string()),
//!     failover_enabled: true,
//!     ..Default::default()
//! };
//!
//! let mut router = GeoRouter::new(config);
//! router.set_regions(regions);
//!
//! // Select a region
//! if let Some(region) = router.select_region(&[]) {
//!     println!("Selected region: {}", region.name);
//! }
//! ```

use std::collections::{HashMap, VecDeque};
use std::net::TcpStream;
use std::sync::{Mutex, RwLock};
use std::time::{Duration, Instant, SystemTime};

// ============================================================================
// Configuration
// ============================================================================

/// Default probe interval in milliseconds.
pub const DEFAULT_PROBE_INTERVAL_MS: u64 = 30_000;
/// Default failover timeout in milliseconds.
pub const DEFAULT_FAILOVER_TIMEOUT_MS: u64 = 5_000;
/// Default number of samples for rolling latency average.
pub const DEFAULT_PROBE_SAMPLE_COUNT: usize = 5;
/// Default consecutive failures before marking region unhealthy.
pub const DEFAULT_UNHEALTHY_THRESHOLD: u32 = 3;

/// Configuration for geo-routing behavior.
#[derive(Debug, Clone, Default)]
pub struct GeoRoutingConfig {
    /// Discovery endpoint URL (e.g., "https://archerdb.example.com/regions").
    pub discovery_endpoint: Option<String>,
    /// Direct endpoint for non-geo-routed connections.
    pub direct_endpoint: Option<String>,
    /// Preferred region name (optional).
    pub preferred_region: Option<String>,
    /// Enable automatic failover to backup regions.
    pub failover_enabled: bool,
    /// Interval between latency probes (milliseconds).
    pub probe_interval_ms: u64,
    /// Timeout for failover operations (milliseconds).
    pub failover_timeout_ms: u64,
    /// Number of samples for rolling latency average.
    pub probe_sample_count: usize,
    /// Consecutive failures before marking region unhealthy.
    pub unhealthy_threshold: u32,
}

impl GeoRoutingConfig {
    /// Creates a new configuration with default values.
    pub fn new() -> Self {
        GeoRoutingConfig {
            discovery_endpoint: None,
            direct_endpoint: None,
            preferred_region: None,
            failover_enabled: true,
            probe_interval_ms: DEFAULT_PROBE_INTERVAL_MS,
            failover_timeout_ms: DEFAULT_FAILOVER_TIMEOUT_MS,
            probe_sample_count: DEFAULT_PROBE_SAMPLE_COUNT,
            unhealthy_threshold: DEFAULT_UNHEALTHY_THRESHOLD,
        }
    }

    /// Check if geo-routing is enabled.
    pub fn is_geo_routing_enabled(&self) -> bool {
        self.discovery_endpoint.is_some()
    }
}

// ============================================================================
// Region Data Types
// ============================================================================

/// Health status of a region.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum RegionHealth {
    /// Region is healthy.
    Healthy = 0,
    /// Region is degraded but operational.
    Degraded = 1,
    /// Region is unhealthy.
    Unhealthy = 2,
    /// Region health is unknown.
    #[default]
    Unknown = 3,
}

/// Geographic location of a region.
#[derive(Debug, Clone, Copy, Default)]
pub struct RegionLocation {
    /// Latitude in degrees.
    pub latitude: f64,
    /// Longitude in degrees.
    pub longitude: f64,
}

/// Information about a single region from the /regions endpoint.
#[derive(Debug, Clone, Default)]
pub struct RegionInfo {
    /// Region name.
    pub name: String,
    /// Region endpoint address.
    pub endpoint: String,
    /// Geographic location of the region.
    pub location: RegionLocation,
    /// Whether the region is healthy.
    pub healthy: bool,
}

/// Response from the /regions discovery endpoint.
#[derive(Debug, Clone)]
pub struct DiscoveryResponse {
    /// List of available regions.
    pub regions: Vec<RegionInfo>,
    /// Expiry time (if specified).
    pub expires: Option<SystemTime>,
    /// Time when the response was fetched.
    pub fetched_at: SystemTime,
}

impl Default for DiscoveryResponse {
    fn default() -> Self {
        Self {
            regions: Vec::new(),
            expires: None,
            fetched_at: SystemTime::now(),
        }
    }
}

impl DiscoveryResponse {
    /// Check if the cached response is expired.
    pub fn is_expired(&self) -> bool {
        let now = SystemTime::now();

        if let Some(expires) = self.expires {
            return now > expires;
        }

        // Default 5 minute TTL
        if let Ok(elapsed) = now.duration_since(self.fetched_at) {
            return elapsed > Duration::from_secs(5 * 60);
        }

        false
    }
}

// ============================================================================
// Latency Tracking
// ============================================================================

/// Single latency measurement.
#[derive(Debug, Clone, Copy)]
pub struct LatencyMeasurement {
    /// Round-trip time in milliseconds.
    pub rtt_ms: f64,
    /// Time when measurement was taken.
    pub timestamp: Instant,
}

/// Latency statistics for a region.
#[derive(Debug)]
pub struct RegionLatencyStats {
    /// Region name.
    pub region_name: String,
    /// Rolling latency samples.
    samples: VecDeque<LatencyMeasurement>,
    /// Maximum number of samples to keep.
    max_samples: usize,
    /// Time of last probe.
    pub last_probe_time: Option<Instant>,
    /// Consecutive probe failures.
    pub consecutive_failures: u32,
    /// Current health status.
    pub health: RegionHealth,
}

impl RegionLatencyStats {
    /// Create new stats for a region.
    pub fn new(region_name: String, max_samples: usize) -> Self {
        RegionLatencyStats {
            region_name,
            samples: VecDeque::with_capacity(max_samples),
            max_samples,
            last_probe_time: None,
            consecutive_failures: 0,
            health: RegionHealth::Unknown,
        }
    }

    /// Add a latency sample.
    pub fn add_sample(&mut self, rtt_ms: f64) {
        while self.samples.len() >= self.max_samples {
            self.samples.pop_front();
        }
        self.samples.push_back(LatencyMeasurement {
            rtt_ms,
            timestamp: Instant::now(),
        });
        self.last_probe_time = Some(Instant::now());
        self.consecutive_failures = 0;
        if self.health == RegionHealth::Unhealthy || self.health == RegionHealth::Unknown {
            self.health = RegionHealth::Healthy;
        }
    }

    /// Record a probe failure.
    pub fn record_failure(&mut self, threshold: u32) {
        self.consecutive_failures += 1;
        self.last_probe_time = Some(Instant::now());
        if self.consecutive_failures >= threshold {
            self.health = RegionHealth::Unhealthy;
        }
    }

    /// Get rolling average RTT in milliseconds.
    pub fn get_average_rtt_ms(&self) -> Option<f64> {
        if self.samples.is_empty() {
            return None;
        }
        let sum: f64 = self.samples.iter().map(|s| s.rtt_ms).sum();
        Some(sum / self.samples.len() as f64)
    }

    /// Check if region is healthy.
    pub fn is_healthy(&self) -> bool {
        matches!(self.health, RegionHealth::Healthy | RegionHealth::Unknown)
    }

    /// Get number of samples.
    pub fn sample_count(&self) -> usize {
        self.samples.len()
    }
}

// ============================================================================
// Geo-Routing Metrics
// ============================================================================

/// Metrics for geo-routing operations.
#[derive(Debug, Default)]
pub struct GeoRoutingMetrics {
    queries_by_region: HashMap<String, u64>,
    region_switches: HashMap<String, HashMap<String, u64>>,
    region_latencies_ms: HashMap<String, f64>,
}

impl GeoRoutingMetrics {
    /// Create new metrics.
    pub fn new() -> Self {
        GeoRoutingMetrics::default()
    }

    /// Record a query to a region.
    pub fn record_query(&mut self, region: &str) {
        *self.queries_by_region.entry(region.to_string()).or_insert(0) += 1;
    }

    /// Record a region switch (failover).
    pub fn record_switch(&mut self, from_region: &str, to_region: &str) {
        let switches = self
            .region_switches
            .entry(from_region.to_string())
            .or_default();
        *switches.entry(to_region.to_string()).or_insert(0) += 1;
    }

    /// Update the latency measurement for a region.
    pub fn update_latency(&mut self, region: &str, latency_ms: f64) {
        self.region_latencies_ms
            .insert(region.to_string(), latency_ms);
    }

    /// Get queries by region.
    pub fn queries_by_region(&self) -> &HashMap<String, u64> {
        &self.queries_by_region
    }

    /// Get region switches.
    pub fn region_switches(&self) -> &HashMap<String, HashMap<String, u64>> {
        &self.region_switches
    }

    /// Get region latencies.
    pub fn region_latencies_ms(&self) -> &HashMap<String, f64> {
        &self.region_latencies_ms
    }

    /// Export metrics in Prometheus format.
    pub fn get_prometheus_metrics(&self) -> String {
        let mut lines = Vec::new();

        // Query counts
        for (region, count) in &self.queries_by_region {
            lines.push(format!(
                "archerdb_client_queries_total{{region=\"{}\"}} {}",
                region, count
            ));
        }

        // Region switches
        for (from_r, to_dict) in &self.region_switches {
            for (to_r, count) in to_dict {
                lines.push(format!(
                    "archerdb_client_region_switches_total{{from=\"{}\",to=\"{}\"}} {}",
                    from_r, to_r, count
                ));
            }
        }

        // Latencies
        for (region, latency) in &self.region_latencies_ms {
            lines.push(format!(
                "archerdb_client_region_latency_ms{{region=\"{}\"}} {:.1}",
                region, latency
            ));
        }

        lines.join("\n")
    }
}

// ============================================================================
// Main Geo-Router Class
// ============================================================================

/// Main geo-routing coordinator.
pub struct GeoRouter {
    config: GeoRoutingConfig,
    metrics: Mutex<GeoRoutingMetrics>,
    regions: RwLock<Vec<RegionInfo>>,
    stats: RwLock<HashMap<String, RegionLatencyStats>>,
    current_endpoint: Mutex<Option<String>>,
    current_region: Mutex<Option<String>>,
}

impl GeoRouter {
    /// Create a new geo-router.
    pub fn new(config: GeoRoutingConfig) -> Self {
        GeoRouter {
            config,
            metrics: Mutex::new(GeoRoutingMetrics::new()),
            regions: RwLock::new(Vec::new()),
            stats: RwLock::new(HashMap::new()),
            current_endpoint: Mutex::new(None),
            current_region: Mutex::new(None),
        }
    }

    /// Set the available regions.
    pub fn set_regions(&self, regions: Vec<RegionInfo>) {
        let mut stats = self.stats.write().unwrap();
        for region in &regions {
            stats.entry(region.name.clone()).or_insert_with(|| {
                RegionLatencyStats::new(region.name.clone(), self.config.probe_sample_count)
            });
        }
        *self.regions.write().unwrap() = regions;
    }

    /// Select the optimal region.
    pub fn select_region(&self, exclude: &[String]) -> Option<RegionInfo> {
        let regions = self.regions.read().unwrap();

        // Filter to healthy regions
        let healthy: Vec<&RegionInfo> = regions
            .iter()
            .filter(|r| r.healthy && !exclude.contains(&r.name))
            .filter(|r| {
                self.stats
                    .read()
                    .unwrap()
                    .get(&r.name)
                    .map(|s| s.is_healthy())
                    .unwrap_or(true)
            })
            .collect();

        if healthy.is_empty() {
            return None;
        }

        // Apply region preference
        if let Some(ref preferred) = self.config.preferred_region {
            if let Some(region) = healthy.iter().find(|r| &r.name == preferred) {
                self.set_current_region(&region.name, &region.endpoint);
                return Some((*region).clone());
            }
        }

        // Select by latency
        let region = self.select_by_latency(&healthy);
        if let Some(ref r) = region {
            self.set_current_region(&r.name, &r.endpoint);
        }

        region
    }

    fn select_by_latency(&self, regions: &[&RegionInfo]) -> Option<RegionInfo> {
        let stats = self.stats.read().unwrap();

        // Get latency for each region
        let mut latencies: Vec<(&RegionInfo, f64)> = Vec::new();

        for region in regions {
            if let Some(s) = stats.get(&region.name) {
                if let Some(rtt) = s.get_average_rtt_ms() {
                    latencies.push((region, rtt));
                }
            }
        }

        if !latencies.is_empty() {
            latencies.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
            return Some(latencies[0].0.clone());
        }

        // Return first region if no latency data
        regions.first().map(|r| (*r).clone())
    }

    fn set_current_region(&self, name: &str, endpoint: &str) {
        let mut current = self.current_region.lock().unwrap();
        if current.as_ref() != Some(&name.to_string()) {
            if let Some(ref old) = *current {
                self.metrics.lock().unwrap().record_switch(old, name);
            }
            *current = Some(name.to_string());
            *self.current_endpoint.lock().unwrap() = Some(endpoint.to_string());
        }
    }

    /// Get the current endpoint.
    pub fn get_endpoint(&self) -> String {
        self.current_endpoint
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_default()
    }

    /// Get the current region name.
    pub fn get_current_region(&self) -> Option<String> {
        self.current_region.lock().unwrap().clone()
    }

    /// Handle connection failure by triggering failover.
    pub fn handle_failure(&self) -> Option<String> {
        if !self.config.failover_enabled {
            return None;
        }

        let current_region = self.get_current_region()?;

        // Mark current region as unhealthy
        if let Some(stats) = self.stats.write().unwrap().get_mut(&current_region) {
            stats.health = RegionHealth::Unhealthy;
        }

        // Select new region excluding current
        let new_region = self.select_region(&[current_region.clone()])?;

        self.metrics
            .lock()
            .unwrap()
            .record_switch(&current_region, &new_region.name);

        Some(new_region.endpoint)
    }

    /// Record a query for metrics.
    pub fn record_query(&self) {
        if let Some(region) = self.get_current_region() {
            self.metrics.lock().unwrap().record_query(&region);
        }
    }

    /// Get the metrics.
    pub fn get_metrics(&self) -> GeoRoutingMetrics {
        let metrics = self.metrics.lock().unwrap();
        GeoRoutingMetrics {
            queries_by_region: metrics.queries_by_region.clone(),
            region_switches: metrics.region_switches.clone(),
            region_latencies_ms: metrics.region_latencies_ms.clone(),
        }
    }

    /// Get the list of discovered regions.
    pub fn get_regions(&self) -> Vec<RegionInfo> {
        self.regions.read().unwrap().clone()
    }

    /// Probe a specific region's latency.
    pub fn probe_region(&self, region_name: &str) -> Option<f64> {
        let regions = self.regions.read().unwrap();
        let region = regions.iter().find(|r| r.name == region_name)?;

        // Parse endpoint
        let mut endpoint = region.endpoint.clone();
        if endpoint.contains("://") {
            endpoint = endpoint.split("://").last().unwrap_or(&endpoint).to_string();
        }
        if endpoint.contains('/') {
            endpoint = endpoint.split('/').next().unwrap_or(&endpoint).to_string();
        }

        let (host, port) = if endpoint.contains(':') {
            let parts: Vec<&str> = endpoint.rsplitn(2, ':').collect();
            (parts[1].to_string(), parts[0].parse().unwrap_or(5000))
        } else {
            (endpoint, 5000u16)
        };

        // Measure TCP connect time
        let start = Instant::now();
        let addr = format!("{}:{}", host, port);
        let timeout = Duration::from_millis(self.config.failover_timeout_ms);

        match addr.parse::<std::net::SocketAddr>() {
            Ok(socket_addr) => match TcpStream::connect_timeout(&socket_addr, timeout) {
                Ok(_) => {
                    let rtt_ms = start.elapsed().as_secs_f64() * 1000.0;
                    if let Some(stats) = self.stats.write().unwrap().get_mut(region_name) {
                        stats.add_sample(rtt_ms);
                        if let Some(avg) = stats.get_average_rtt_ms() {
                            self.metrics.lock().unwrap().update_latency(region_name, avg);
                        }
                    }
                    Some(rtt_ms)
                }
                Err(_) => {
                    if let Some(stats) = self.stats.write().unwrap().get_mut(region_name) {
                        stats.record_failure(self.config.unhealthy_threshold);
                    }
                    None
                }
            },
            Err(_) => None,
        }
    }

    /// Add a latency sample for a region.
    pub fn add_latency_sample(&self, region_name: &str, rtt_ms: f64) {
        if let Some(stats) = self.stats.write().unwrap().get_mut(region_name) {
            stats.add_sample(rtt_ms);
            if let Some(avg) = stats.get_average_rtt_ms() {
                self.metrics.lock().unwrap().update_latency(region_name, avg);
            }
        }
    }

    /// Get latency stats for a region.
    pub fn get_stats(&self, region_name: &str) -> Option<(f64, u32, RegionHealth)> {
        let stats = self.stats.read().unwrap();
        let s = stats.get(region_name)?;
        Some((
            s.get_average_rtt_ms().unwrap_or(0.0),
            s.consecutive_failures,
            s.health,
        ))
    }
}

/// Calculate haversine distance between two points.
pub fn haversine_distance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6371.0; // Earth radius in km

    let d_lat = (lat2 - lat1).to_radians();
    let d_lon = (lon2 - lon1).to_radians();

    let a = (d_lat / 2.0).sin().powi(2)
        + lat1.to_radians().cos() * lat2.to_radians().cos() * (d_lon / 2.0).sin().powi(2);

    let c = 2.0 * a.sqrt().asin();

    R * c
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_sample_regions() -> Vec<RegionInfo> {
        vec![
            RegionInfo {
                name: "us-east-1".to_string(),
                endpoint: "us-east.example.com:5000".to_string(),
                location: RegionLocation {
                    latitude: 39.04,
                    longitude: -77.49,
                },
                healthy: true,
            },
            RegionInfo {
                name: "us-west-2".to_string(),
                endpoint: "us-west.example.com:5000".to_string(),
                location: RegionLocation {
                    latitude: 45.52,
                    longitude: -122.68,
                },
                healthy: true,
            },
            RegionInfo {
                name: "eu-west-1".to_string(),
                endpoint: "eu-west.example.com:5000".to_string(),
                location: RegionLocation {
                    latitude: 53.34,
                    longitude: -6.26,
                },
                healthy: true,
            },
        ]
    }

    #[test]
    fn test_region_latency_stats_add_sample() {
        let mut stats = RegionLatencyStats::new("test".to_string(), 5);
        stats.add_sample(10.0);
        stats.add_sample(20.0);
        stats.add_sample(15.0);

        assert_eq!(stats.sample_count(), 3);
        assert_eq!(stats.get_average_rtt_ms(), Some(15.0));
    }

    #[test]
    fn test_region_latency_stats_rolling_window() {
        let mut stats = RegionLatencyStats::new("test".to_string(), 3);
        stats.add_sample(10.0);
        stats.add_sample(20.0);
        stats.add_sample(30.0);
        stats.add_sample(40.0);
        stats.add_sample(50.0);

        // Only last 3 samples: 30, 40, 50
        assert_eq!(stats.sample_count(), 3);
        assert_eq!(stats.get_average_rtt_ms(), Some(40.0));
    }

    #[test]
    fn test_region_latency_stats_record_failure() {
        let mut stats = RegionLatencyStats::new("test".to_string(), 5);
        assert_eq!(stats.health, RegionHealth::Unknown);

        stats.record_failure(3);
        stats.record_failure(3);
        assert_ne!(stats.health, RegionHealth::Unhealthy);

        stats.record_failure(3);
        assert_eq!(stats.health, RegionHealth::Unhealthy);
    }

    #[test]
    fn test_region_latency_stats_success_resets_failures() {
        let mut stats = RegionLatencyStats::new("test".to_string(), 5);
        stats.record_failure(3);
        stats.record_failure(3);
        assert_eq!(stats.consecutive_failures, 2);

        stats.add_sample(10.0);
        assert_eq!(stats.consecutive_failures, 0);
        assert!(stats.is_healthy());
    }

    #[test]
    fn test_geo_routing_metrics_record_query() {
        let mut metrics = GeoRoutingMetrics::new();
        metrics.record_query("us-east-1");
        metrics.record_query("us-east-1");
        metrics.record_query("eu-west-1");

        assert_eq!(metrics.queries_by_region.get("us-east-1"), Some(&2));
        assert_eq!(metrics.queries_by_region.get("eu-west-1"), Some(&1));
    }

    #[test]
    fn test_geo_routing_metrics_record_switch() {
        let mut metrics = GeoRoutingMetrics::new();
        metrics.record_switch("us-east-1", "eu-west-1");
        metrics.record_switch("us-east-1", "eu-west-1");

        let switches = metrics.region_switches.get("us-east-1").unwrap();
        assert_eq!(switches.get("eu-west-1"), Some(&2));
    }

    #[test]
    fn test_geo_routing_metrics_prometheus() {
        let mut metrics = GeoRoutingMetrics::new();
        metrics.record_query("us-east-1");
        metrics.record_switch("us-east-1", "eu-west-1");
        metrics.update_latency("us-east-1", 25.0);

        let output = metrics.get_prometheus_metrics();

        assert!(output.contains("archerdb_client_queries_total{region=\"us-east-1\"} 1"));
        assert!(output.contains(
            "archerdb_client_region_switches_total{from=\"us-east-1\",to=\"eu-west-1\"} 1"
        ));
        assert!(output.contains("archerdb_client_region_latency_ms{region=\"us-east-1\"} 25.0"));
    }

    #[test]
    fn test_geo_routing_config_enabled() {
        let config = GeoRoutingConfig {
            discovery_endpoint: Some("http://example.com/regions".to_string()),
            ..Default::default()
        };
        assert!(config.is_geo_routing_enabled());

        let config = GeoRoutingConfig {
            direct_endpoint: Some("host:5000".to_string()),
            ..Default::default()
        };
        assert!(!config.is_geo_routing_enabled());
    }

    #[test]
    fn test_haversine_distance() {
        // Dublin to London (approx 464 km)
        let dist = haversine_distance(53.34, -6.26, 51.51, -0.13);
        assert!(dist > 450.0 && dist < 480.0);
    }

    #[test]
    fn test_geo_router_select_preferred() {
        let config = GeoRoutingConfig {
            preferred_region: Some("eu-west-1".to_string()),
            ..Default::default()
        };
        let router = GeoRouter::new(config);
        router.set_regions(create_sample_regions());

        let region = router.select_region(&[]);
        assert!(region.is_some());
        assert_eq!(region.unwrap().name, "eu-west-1");
    }

    #[test]
    fn test_geo_router_select_healthy_only() {
        let config = GeoRoutingConfig::new();
        let router = GeoRouter::new(config);

        let mut regions = create_sample_regions();
        regions[0].healthy = false;
        router.set_regions(regions);

        let region = router.select_region(&[]);
        assert!(region.is_some());
        assert_ne!(region.unwrap().name, "us-east-1");
    }

    #[test]
    fn test_geo_router_select_exclude() {
        let config = GeoRoutingConfig::new();
        let router = GeoRouter::new(config);
        router.set_regions(create_sample_regions());

        let region = router.select_region(&["us-east-1".to_string(), "us-west-2".to_string()]);
        assert!(region.is_some());
        assert_eq!(region.unwrap().name, "eu-west-1");
    }

    #[test]
    fn test_geo_router_select_by_latency() {
        let config = GeoRoutingConfig::new();
        let router = GeoRouter::new(config);
        router.set_regions(create_sample_regions());

        // Add latency samples
        router.add_latency_sample("us-east-1", 100.0);
        router.add_latency_sample("us-west-2", 20.0);
        router.add_latency_sample("eu-west-1", 50.0);

        let region = router.select_region(&[]);
        assert!(region.is_some());
        assert_eq!(region.unwrap().name, "us-west-2");
    }

    #[test]
    fn test_geo_router_record_metrics() {
        let config = GeoRoutingConfig::new();
        let router = GeoRouter::new(config);
        router.set_regions(create_sample_regions());

        router.select_region(&[]);
        router.record_query();
        router.record_query();

        let metrics = router.get_metrics();
        let total: u64 = metrics.queries_by_region.values().sum();
        assert_eq!(total, 2);
    }

    #[test]
    fn test_geo_router_no_failover_when_disabled() {
        let config = GeoRoutingConfig {
            failover_enabled: false,
            ..Default::default()
        };
        let router = GeoRouter::new(config);
        router.set_regions(create_sample_regions());
        router.select_region(&[]);

        let result = router.handle_failure();
        assert!(result.is_none());
    }
}
