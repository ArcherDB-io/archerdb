//! Circuit breaker implementation per client-retry/spec.md.
//!
//! 3-state pattern: Closed (normal) -> Open (fail fast) -> Half-Open (testing recovery).
//! Per-replica scope allows trying other replicas when one circuit trips.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Circuit breaker states per client-retry spec.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CircuitState {
    /// Normal operation - requests flow through.
    Closed,
    /// Circuit tripped - requests fail fast.
    Open,
    /// Testing recovery - limited requests allowed.
    HalfOpen,
}

/// Circuit breaker configuration matching client-retry/spec.md requirements.
#[derive(Debug, Clone)]
pub struct CircuitBreakerConfig {
    /// Failure rate threshold to open circuit (default: 0.5 = 50%).
    pub failure_rate_threshold: f64,
    /// Minimum requests before evaluating failure rate (default: 10).
    pub minimum_requests: u32,
    /// Time window for failure rate calculation (default: 10s).
    pub window_size: Duration,
    /// Duration circuit stays open before transitioning to half-open (default: 30s).
    pub open_duration: Duration,
    /// Number of test requests allowed in half-open state (default: 5).
    pub half_open_requests: u32,
}

impl Default for CircuitBreakerConfig {
    fn default() -> Self {
        Self {
            failure_rate_threshold: 0.5,
            minimum_requests: 10,
            window_size: Duration::from_secs(10),
            open_duration: Duration::from_secs(30),
            half_open_requests: 5,
        }
    }
}

/// Circuit breaker implementation.
pub struct CircuitBreaker {
    config: CircuitBreakerConfig,
    state: Mutex<CircuitBreakerState>,
    state_change_count: AtomicU64,
}

struct CircuitBreakerState {
    state: CircuitState,
    failure_count: u32,
    success_count: u32,
    half_open_attempts: u32,
    window_start: Instant,
    opened_at: Option<Instant>,
}

impl CircuitBreaker {
    /// Creates a new circuit breaker with the specified configuration.
    pub fn new(config: CircuitBreakerConfig) -> Self {
        Self {
            config,
            state: Mutex::new(CircuitBreakerState {
                state: CircuitState::Closed,
                failure_count: 0,
                success_count: 0,
                half_open_attempts: 0,
                window_start: Instant::now(),
                opened_at: None,
            }),
            state_change_count: AtomicU64::new(0),
        }
    }

    /// Creates a new circuit breaker with default configuration.
    pub fn with_defaults() -> Self {
        Self::new(CircuitBreakerConfig::default())
    }

    /// Returns the current state of the circuit breaker.
    pub fn state(&self) -> CircuitState {
        self.state.lock().unwrap().state
    }

    /// Returns the number of state changes.
    pub fn state_change_count(&self) -> u64 {
        self.state_change_count.load(Ordering::SeqCst)
    }

    /// Checks if a request is allowed through the circuit breaker.
    pub fn allow_request(&self) -> bool {
        let mut state = self.state.lock().unwrap();

        match state.state {
            CircuitState::Closed => true,
            CircuitState::Open => {
                // Check if it's time to transition to half-open
                if let Some(opened_at) = state.opened_at {
                    if opened_at.elapsed() >= self.config.open_duration {
                        self.transition_to(&mut state, CircuitState::HalfOpen);
                        state.half_open_attempts = 1;
                        return true;
                    }
                }
                false
            }
            CircuitState::HalfOpen => {
                // Allow limited requests in half-open state
                if state.half_open_attempts < self.config.half_open_requests {
                    state.half_open_attempts += 1;
                    true
                } else {
                    false
                }
            }
        }
    }

    /// Records a successful request.
    pub fn record_success(&self) {
        let mut state = self.state.lock().unwrap();
        self.reset_window_if_needed(&mut state);
        state.success_count += 1;

        if state.state == CircuitState::HalfOpen {
            // Successful test in half-open -> close circuit
            self.transition_to(&mut state, CircuitState::Closed);
            self.reset_counts(&mut state);
        }
    }

    /// Records a failed request.
    pub fn record_failure(&self) {
        let mut state = self.state.lock().unwrap();
        self.reset_window_if_needed(&mut state);
        state.failure_count += 1;

        if state.state == CircuitState::HalfOpen {
            // Failed test in half-open -> reopen circuit
            self.transition_to(&mut state, CircuitState::Open);
            state.opened_at = Some(Instant::now());
            return;
        }

        // Check if we should open the circuit
        let total_requests = state.failure_count + state.success_count;
        if total_requests >= self.config.minimum_requests {
            let failure_rate = state.failure_count as f64 / total_requests as f64;
            if failure_rate >= self.config.failure_rate_threshold {
                self.transition_to(&mut state, CircuitState::Open);
                state.opened_at = Some(Instant::now());
            }
        }
    }

    /// Force closes the circuit breaker (for testing/admin).
    pub fn force_close(&self) {
        let mut state = self.state.lock().unwrap();
        self.transition_to(&mut state, CircuitState::Closed);
        self.reset_counts(&mut state);
    }

    fn transition_to(&self, state: &mut CircuitBreakerState, new_state: CircuitState) {
        if state.state != new_state {
            state.state = new_state;
            self.state_change_count.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn reset_window_if_needed(&self, state: &mut CircuitBreakerState) {
        if state.window_start.elapsed() >= self.config.window_size {
            self.reset_counts(state);
        }
    }

    fn reset_counts(&self, state: &mut CircuitBreakerState) {
        state.failure_count = 0;
        state.success_count = 0;
        state.half_open_attempts = 0;
        state.window_start = Instant::now();
    }
}

/// Error type for circuit breaker open condition.
#[derive(Debug, Clone)]
pub struct CircuitBreakerOpenError {
    pub replica_id: Option<String>,
}

impl std::fmt::Display for CircuitBreakerOpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.replica_id {
            Some(id) => write!(f, "Circuit breaker for replica {} is open - request rejected", id),
            None => write!(f, "Circuit breaker is open - request rejected"),
        }
    }
}

impl std::error::Error for CircuitBreakerOpenError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn test_initial_state_is_closed() {
        let cb = CircuitBreaker::with_defaults();
        assert_eq!(cb.state(), CircuitState::Closed);
    }

    #[test]
    fn test_closed_allows_requests() {
        let cb = CircuitBreaker::with_defaults();
        assert!(cb.allow_request());
    }

    #[test]
    fn test_opens_after_threshold() {
        let config = CircuitBreakerConfig {
            minimum_requests: 10,
            failure_rate_threshold: 0.5,
            ..Default::default()
        };
        let cb = CircuitBreaker::new(config);

        // 6 failures, 4 successes = 60% failure rate > 50% threshold
        for _ in 0..6 {
            cb.record_failure();
        }
        for _ in 0..4 {
            cb.record_success();
        }

        assert_eq!(cb.state(), CircuitState::Open);
    }

    #[test]
    fn test_open_rejects_requests() {
        let config = CircuitBreakerConfig {
            minimum_requests: 10,
            failure_rate_threshold: 0.5,
            open_duration: Duration::from_secs(30),
            ..Default::default()
        };
        let cb = CircuitBreaker::new(config);

        // Open the circuit
        for _ in 0..10 {
            cb.record_failure();
        }

        assert_eq!(cb.state(), CircuitState::Open);
        assert!(!cb.allow_request());
    }

    #[test]
    fn test_half_open_closes_on_success() {
        let config = CircuitBreakerConfig {
            minimum_requests: 5,
            failure_rate_threshold: 0.5,
            open_duration: Duration::from_millis(1),
            ..Default::default()
        };
        let cb = CircuitBreaker::new(config);

        // Open the circuit
        for _ in 0..5 {
            cb.record_failure();
        }

        // Wait for transition to half-open
        thread::sleep(Duration::from_millis(5));
        assert!(cb.allow_request());
        assert_eq!(cb.state(), CircuitState::HalfOpen);

        // Success should close
        cb.record_success();
        assert_eq!(cb.state(), CircuitState::Closed);
    }

    #[test]
    fn test_half_open_reopens_on_failure() {
        let config = CircuitBreakerConfig {
            minimum_requests: 5,
            failure_rate_threshold: 0.5,
            open_duration: Duration::from_millis(1),
            ..Default::default()
        };
        let cb = CircuitBreaker::new(config);

        // Open then transition to half-open
        for _ in 0..5 {
            cb.record_failure();
        }
        thread::sleep(Duration::from_millis(5));
        cb.allow_request();

        // Failure should reopen
        cb.record_failure();
        assert_eq!(cb.state(), CircuitState::Open);
    }

    #[test]
    fn test_force_close() {
        let config = CircuitBreakerConfig {
            minimum_requests: 5,
            failure_rate_threshold: 0.5,
            ..Default::default()
        };
        let cb = CircuitBreaker::new(config);

        // Open the circuit
        for _ in 0..5 {
            cb.record_failure();
        }
        assert_eq!(cb.state(), CircuitState::Open);

        // Force close
        cb.force_close();
        assert_eq!(cb.state(), CircuitState::Closed);
    }

    #[test]
    fn test_state_changes_tracked() {
        let config = CircuitBreakerConfig {
            minimum_requests: 5,
            failure_rate_threshold: 0.5,
            open_duration: Duration::from_millis(1),
            ..Default::default()
        };
        let cb = CircuitBreaker::new(config);

        assert_eq!(cb.state_change_count(), 0);

        // Open the circuit
        for _ in 0..5 {
            cb.record_failure();
        }
        assert_eq!(cb.state_change_count(), 1);

        // Transition to half-open
        thread::sleep(Duration::from_millis(5));
        cb.allow_request();
        assert_eq!(cb.state_change_count(), 2);
    }

    #[test]
    fn test_default_config_matches_spec() {
        let config = CircuitBreakerConfig::default();

        assert!((config.failure_rate_threshold - 0.5).abs() < f64::EPSILON); // 50% per spec
        assert_eq!(config.minimum_requests, 10); // 10 per spec
        assert_eq!(config.window_size, Duration::from_secs(10)); // 10s per spec
        assert_eq!(config.open_duration, Duration::from_secs(30)); // 30s per spec
        assert_eq!(config.half_open_requests, 5); // 5 per spec
    }
}
