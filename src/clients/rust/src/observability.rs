//! Observability implementation per observability/spec.md.
//!
//! Provides logging, metrics, and health tracking for the Rust SDK.

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Mutex, RwLock};
use std::time::Instant;

/// Log levels for SDK logging.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

/// Logger trait for SDK observability.
pub trait Logger: Send + Sync {
    fn log(&self, level: LogLevel, message: &str);
}

/// Null logger that discards all messages.
pub struct NullLogger;

impl Logger for NullLogger {
    fn log(&self, _level: LogLevel, _message: &str) {}
}

/// Console logger for development/debugging.
pub struct ConsoleLogger {
    min_level: LogLevel,
}

impl ConsoleLogger {
    pub fn new(min_level: LogLevel) -> Self {
        Self { min_level }
    }
}

impl Default for ConsoleLogger {
    fn default() -> Self {
        Self::new(LogLevel::Info)
    }
}

impl Logger for ConsoleLogger {
    fn log(&self, level: LogLevel, message: &str) {
        if level >= self.min_level {
            let level_str = match level {
                LogLevel::Debug => "DEBUG",
                LogLevel::Info => "INFO",
                LogLevel::Warn => "WARN",
                LogLevel::Error => "ERROR",
            };
            eprintln!("[{}] {}", level_str, message);
        }
    }
}

/// Counter metric for tracking counts.
pub struct Counter {
    name: String,
    help: String,
    value: AtomicU64,
    labeled: RwLock<HashMap<String, AtomicU64>>,
}

impl Counter {
    pub fn new(name: &str, help: &str) -> Self {
        Self {
            name: name.to_string(),
            help: help.to_string(),
            value: AtomicU64::new(0),
            labeled: RwLock::new(HashMap::new()),
        }
    }

    pub fn inc(&self) {
        self.value.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_by(&self, delta: u64) {
        self.value.fetch_add(delta, Ordering::Relaxed);
    }

    pub fn inc_labeled(&self, label: &str) {
        self.inc_labeled_by(label, 1);
    }

    pub fn inc_labeled_by(&self, label: &str, delta: u64) {
        // Try to get existing counter first
        {
            let labeled = self.labeled.read().unwrap();
            if let Some(counter) = labeled.get(label) {
                counter.fetch_add(delta, Ordering::Relaxed);
                return;
            }
        }

        // Create new counter if needed
        let mut labeled = self.labeled.write().unwrap();
        labeled
            .entry(label.to_string())
            .or_insert_with(|| AtomicU64::new(0))
            .fetch_add(delta, Ordering::Relaxed);
    }

    pub fn value(&self) -> u64 {
        self.value.load(Ordering::Relaxed)
    }

    pub fn labeled_value(&self, label: &str) -> u64 {
        let labeled = self.labeled.read().unwrap();
        labeled
            .get(label)
            .map(|v| v.load(Ordering::Relaxed))
            .unwrap_or(0)
    }

    pub fn to_prometheus(&self) -> String {
        let mut output = format!(
            "# HELP {} {}\n# TYPE {} counter\n",
            self.name, self.help, self.name
        );

        let labeled = self.labeled.read().unwrap();
        if labeled.is_empty() {
            output.push_str(&format!("{} {}\n", self.name, self.value()));
        } else {
            for (label, value) in labeled.iter() {
                output.push_str(&format!(
                    "{}{{label=\"{}\"}} {}\n",
                    self.name,
                    label,
                    value.load(Ordering::Relaxed)
                ));
            }
        }

        output
    }
}

/// Gauge metric for tracking values that can go up and down.
pub struct Gauge {
    name: String,
    help: String,
    value: AtomicI64,
}

impl Gauge {
    pub fn new(name: &str, help: &str) -> Self {
        Self {
            name: name.to_string(),
            help: help.to_string(),
            value: AtomicI64::new(0),
        }
    }

    pub fn set(&self, value: i64) {
        self.value.store(value, Ordering::Relaxed);
    }

    pub fn inc(&self) {
        self.value.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_by(&self, delta: i64) {
        self.value.fetch_add(delta, Ordering::Relaxed);
    }

    pub fn dec(&self) {
        self.value.fetch_sub(1, Ordering::Relaxed);
    }

    pub fn dec_by(&self, delta: i64) {
        self.value.fetch_sub(delta, Ordering::Relaxed);
    }

    pub fn value(&self) -> i64 {
        self.value.load(Ordering::Relaxed)
    }

    pub fn to_prometheus(&self) -> String {
        format!(
            "# HELP {} {}\n# TYPE {} gauge\n{} {}\n",
            self.name,
            self.help,
            self.name,
            self.name,
            self.value()
        )
    }
}

/// Histogram metric for tracking distributions.
pub struct Histogram {
    name: String,
    help: String,
    buckets: Vec<f64>,
    bucket_counts: Vec<AtomicU64>,
    count: AtomicU64,
    sum: Mutex<f64>,
}

impl Histogram {
    pub fn new(name: &str, help: &str, buckets: Option<Vec<f64>>) -> Self {
        let buckets = buckets.unwrap_or_else(|| {
            vec![0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
        });
        let bucket_counts = (0..=buckets.len())
            .map(|_| AtomicU64::new(0))
            .collect();

        Self {
            name: name.to_string(),
            help: help.to_string(),
            buckets,
            bucket_counts,
            count: AtomicU64::new(0),
            sum: Mutex::new(0.0),
        }
    }

    pub fn observe(&self, value: f64) {
        self.count.fetch_add(1, Ordering::Relaxed);
        {
            let mut sum = self.sum.lock().unwrap();
            *sum += value;
        }

        for (i, bucket) in self.buckets.iter().enumerate() {
            if value <= *bucket {
                self.bucket_counts[i].fetch_add(1, Ordering::Relaxed);
            }
        }
        // +Inf bucket
        self.bucket_counts[self.buckets.len()].fetch_add(1, Ordering::Relaxed);
    }

    pub fn to_prometheus(&self) -> String {
        let mut output = format!(
            "# HELP {} {}\n# TYPE {} histogram\n",
            self.name, self.help, self.name
        );

        let mut cumulative = 0u64;
        for (i, bucket) in self.buckets.iter().enumerate() {
            cumulative += self.bucket_counts[i].load(Ordering::Relaxed);
            output.push_str(&format!(
                "{}_bucket{{le=\"{}\"}} {}\n",
                self.name, bucket, cumulative
            ));
        }

        let count = self.count.load(Ordering::Relaxed);
        output.push_str(&format!("{}_bucket{{le=\"+Inf\"}} {}\n", self.name, count));

        let sum = *self.sum.lock().unwrap();
        output.push_str(&format!("{}_sum {}\n", self.name, sum));
        output.push_str(&format!("{}_count {}\n", self.name, count));

        output
    }
}

/// SDK metrics per observability/spec.md.
pub struct SdkMetrics {
    pub requests_total: Counter,
    pub request_duration: Histogram,
    pub connections_active: Gauge,
    pub reconnections_total: Counter,
    pub session_renewals_total: Counter,
    pub retries_total: Counter,
    pub retry_exhausted_total: Counter,
    pub primary_discoveries_total: Counter,
    pub circuit_breaker_trips_total: Counter,
}

impl SdkMetrics {
    pub fn new() -> Self {
        Self {
            requests_total: Counter::new(
                "archerdb_client_requests_total",
                "Total client requests",
            ),
            request_duration: Histogram::new(
                "archerdb_client_request_duration_seconds",
                "Request duration in seconds",
                None,
            ),
            connections_active: Gauge::new(
                "archerdb_client_connections_active",
                "Active connections",
            ),
            reconnections_total: Counter::new(
                "archerdb_client_reconnections_total",
                "Total reconnections",
            ),
            session_renewals_total: Counter::new(
                "archerdb_client_session_renewals_total",
                "Total session renewals",
            ),
            retries_total: Counter::new(
                "archerdb_client_retries_total",
                "Total retry attempts",
            ),
            retry_exhausted_total: Counter::new(
                "archerdb_client_retry_exhausted_total",
                "Total retry exhaustions",
            ),
            primary_discoveries_total: Counter::new(
                "archerdb_client_primary_discoveries_total",
                "Total primary discoveries",
            ),
            circuit_breaker_trips_total: Counter::new(
                "archerdb_client_circuit_breaker_trips_total",
                "Total circuit breaker trips",
            ),
        }
    }

    pub fn record_request(&self, operation: &str, duration_seconds: f64, success: bool) {
        self.requests_total.inc_labeled(operation);
        self.request_duration.observe(duration_seconds);
        if !success {
            self.requests_total.inc_labeled(&format!("{}_error", operation));
        }
    }

    pub fn to_prometheus(&self) -> String {
        let mut output = String::new();
        output.push_str(&self.requests_total.to_prometheus());
        output.push_str(&self.request_duration.to_prometheus());
        output.push_str(&self.connections_active.to_prometheus());
        output.push_str(&self.reconnections_total.to_prometheus());
        output.push_str(&self.session_renewals_total.to_prometheus());
        output.push_str(&self.retries_total.to_prometheus());
        output.push_str(&self.retry_exhausted_total.to_prometheus());
        output.push_str(&self.primary_discoveries_total.to_prometheus());
        output.push_str(&self.circuit_breaker_trips_total.to_prometheus());
        output
    }
}

impl Default for SdkMetrics {
    fn default() -> Self {
        Self::new()
    }
}

/// Request timer for measuring operation durations.
pub struct RequestTimer<'a> {
    operation: String,
    metrics: &'a SdkMetrics,
    start: Instant,
    success: bool,
}

impl<'a> RequestTimer<'a> {
    pub fn new(operation: &str, metrics: &'a SdkMetrics) -> Self {
        Self {
            operation: operation.to_string(),
            metrics,
            start: Instant::now(),
            success: true,
        }
    }

    pub fn mark_error(&mut self) {
        self.success = false;
    }
}

impl<'a> Drop for RequestTimer<'a> {
    fn drop(&mut self) {
        let duration = self.start.elapsed().as_secs_f64();
        self.metrics.record_request(&self.operation, duration, self.success);
    }
}

/// Health state for a replica.
struct ReplicaHealth {
    consecutive_failures: u32,
    is_healthy: bool,
}

/// Health tracker for monitoring replica health.
pub struct HealthTracker {
    failure_threshold: u32,
    replicas: RwLock<HashMap<String, Mutex<ReplicaHealth>>>,
}

impl HealthTracker {
    pub fn new(failure_threshold: u32) -> Self {
        Self {
            failure_threshold,
            replicas: RwLock::new(HashMap::new()),
        }
    }

    pub fn with_defaults() -> Self {
        Self::new(3)
    }

    pub fn record_success(&self, replica_id: &str) {
        self.ensure_replica(replica_id);
        let replicas = self.replicas.read().unwrap();
        if let Some(health) = replicas.get(replica_id) {
            let mut h = health.lock().unwrap();
            h.consecutive_failures = 0;
            h.is_healthy = true;
        }
    }

    pub fn record_failure(&self, replica_id: &str) {
        self.ensure_replica(replica_id);
        let replicas = self.replicas.read().unwrap();
        if let Some(health) = replicas.get(replica_id) {
            let mut h = health.lock().unwrap();
            h.consecutive_failures += 1;
            if h.consecutive_failures >= self.failure_threshold {
                h.is_healthy = false;
            }
        }
    }

    pub fn is_healthy(&self, replica_id: &str) -> bool {
        let replicas = self.replicas.read().unwrap();
        replicas
            .get(replica_id)
            .map(|h| h.lock().unwrap().is_healthy)
            .unwrap_or(true) // Unknown replica is considered healthy
    }

    fn ensure_replica(&self, replica_id: &str) {
        // Check if exists first
        {
            let replicas = self.replicas.read().unwrap();
            if replicas.contains_key(replica_id) {
                return;
            }
        }

        // Create if needed
        let mut replicas = self.replicas.write().unwrap();
        replicas.entry(replica_id.to_string()).or_insert_with(|| {
            Mutex::new(ReplicaHealth {
                consecutive_failures: 0,
                is_healthy: true,
            })
        });
    }
}

impl Default for HealthTracker {
    fn default() -> Self {
        Self::with_defaults()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn test_null_logger_discards_messages() {
        let logger = NullLogger;
        // Should not panic
        logger.log(LogLevel::Debug, "test");
        logger.log(LogLevel::Error, "test");
    }

    #[test]
    fn test_counter_increments() {
        let counter = Counter::new("test_counter", "Test counter");

        assert_eq!(counter.value(), 0);

        counter.inc();
        assert_eq!(counter.value(), 1);

        counter.inc_by(5);
        assert_eq!(counter.value(), 6);
    }

    #[test]
    fn test_counter_labels() {
        let counter = Counter::new("test_counter", "Test counter");

        counter.inc_labeled("label1");
        counter.inc_labeled("label1");
        counter.inc_labeled_by("label2", 5);

        assert_eq!(counter.labeled_value("label1"), 2);
        assert_eq!(counter.labeled_value("label2"), 5);
        assert_eq!(counter.labeled_value("nonexistent"), 0);
    }

    #[test]
    fn test_counter_prometheus_format() {
        let counter = Counter::new("archerdb_test_total", "Test counter");
        counter.inc_by(42);

        let output = counter.to_prometheus();

        assert!(output.contains("# HELP archerdb_test_total Test counter"));
        assert!(output.contains("# TYPE archerdb_test_total counter"));
        assert!(output.contains("archerdb_test_total 42"));
    }

    #[test]
    fn test_gauge_operations() {
        let gauge = Gauge::new("test_gauge", "Test gauge");

        assert_eq!(gauge.value(), 0);

        gauge.set(100);
        assert_eq!(gauge.value(), 100);

        gauge.inc_by(10);
        assert_eq!(gauge.value(), 110);

        gauge.dec_by(5);
        assert_eq!(gauge.value(), 105);
    }

    #[test]
    fn test_gauge_prometheus_format() {
        let gauge = Gauge::new("archerdb_connections", "Active connections");
        gauge.set(5);

        let output = gauge.to_prometheus();

        assert!(output.contains("# HELP archerdb_connections Active connections"));
        assert!(output.contains("# TYPE archerdb_connections gauge"));
        assert!(output.contains("archerdb_connections 5"));
    }

    #[test]
    fn test_histogram_observe() {
        let histogram = Histogram::new(
            "test_histogram",
            "Test histogram",
            Some(vec![0.1, 0.5, 1.0]),
        );

        histogram.observe(0.05);
        histogram.observe(0.3);
        histogram.observe(0.7);
        histogram.observe(1.5);

        let output = histogram.to_prometheus();

        assert!(output.contains("# TYPE test_histogram histogram"));
        assert!(output.contains("test_histogram_bucket{le=\"0.1\"}"));
        assert!(output.contains("test_histogram_bucket{le=\"0.5\"}"));
        assert!(output.contains("test_histogram_bucket{le=\"1\"}"));
        assert!(output.contains("test_histogram_bucket{le=\"+Inf\"}"));
        assert!(output.contains("test_histogram_count 4"));
    }

    #[test]
    fn test_sdk_metrics_record_request() {
        let metrics = SdkMetrics::new();

        metrics.record_request("insert", 0.05, true);
        metrics.record_request("query", 0.10, false);

        assert_eq!(metrics.requests_total.labeled_value("insert"), 1);
        assert_eq!(metrics.requests_total.labeled_value("query"), 1);
        assert_eq!(metrics.requests_total.labeled_value("query_error"), 1);
    }

    #[test]
    fn test_sdk_metrics_prometheus_export() {
        let metrics = SdkMetrics::new();
        metrics.requests_total.inc_labeled("test");
        metrics.connections_active.set(3);

        let output = metrics.to_prometheus();

        assert!(output.contains("archerdb_client_requests_total"));
        assert!(output.contains("archerdb_client_connections_active"));
        assert!(output.contains("archerdb_client_retries_total"));
    }

    #[test]
    fn test_request_timer_measures_duration() {
        let metrics = SdkMetrics::new();

        {
            let _timer = RequestTimer::new("test_op", &metrics);
            thread::sleep(Duration::from_millis(10));
        }

        assert_eq!(metrics.requests_total.labeled_value("test_op"), 1);
    }

    #[test]
    fn test_request_timer_marks_error() {
        let metrics = SdkMetrics::new();

        {
            let mut timer = RequestTimer::new("error_op", &metrics);
            timer.mark_error();
        }

        assert_eq!(metrics.requests_total.labeled_value("error_op"), 1);
        assert_eq!(metrics.requests_total.labeled_value("error_op_error"), 1);
    }

    #[test]
    fn test_health_tracker_initial_state() {
        let tracker = HealthTracker::with_defaults();

        // Unknown replica should be considered healthy
        assert!(tracker.is_healthy("replica-1"));
    }

    #[test]
    fn test_health_tracker_success_transitions() {
        let tracker = HealthTracker::new(3);

        tracker.record_success("replica-1");
        assert!(tracker.is_healthy("replica-1"));
    }

    #[test]
    fn test_health_tracker_failure_threshold() {
        let tracker = HealthTracker::new(3);

        tracker.record_failure("replica-1");
        tracker.record_failure("replica-1");
        assert!(tracker.is_healthy("replica-1")); // Not yet at threshold

        tracker.record_failure("replica-1");
        assert!(!tracker.is_healthy("replica-1")); // At threshold
    }

    #[test]
    fn test_health_tracker_recovery() {
        let tracker = HealthTracker::new(2);

        // Fail the replica
        tracker.record_failure("replica-1");
        tracker.record_failure("replica-1");
        assert!(!tracker.is_healthy("replica-1"));

        // Recovery via success
        tracker.record_success("replica-1");
        assert!(tracker.is_healthy("replica-1"));
    }

    #[test]
    fn test_counter_thread_safe() {
        let counter = Counter::new("thread_safe_counter", "Test");
        let counter = std::sync::Arc::new(counter);
        let mut handles = vec![];

        for _ in 0..10 {
            let counter = counter.clone();
            handles.push(thread::spawn(move || {
                for _ in 0..1000 {
                    counter.inc();
                }
            }));
        }

        for handle in handles {
            handle.join().unwrap();
        }

        assert_eq!(counter.value(), 10000);
    }
}
