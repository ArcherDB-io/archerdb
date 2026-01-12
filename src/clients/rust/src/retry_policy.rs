//! Retry policy implementation per client-retry/spec.md.
//!
//! Implements exponential backoff with jitter: 100ms, 200ms, 400ms, 800ms, 1600ms.
//! Maximum 5 retries (6 total attempts) with 30s total timeout.

use std::time::{Duration, Instant};

/// Retry policy configuration matching client-retry/spec.md requirements.
#[derive(Debug, Clone)]
pub struct RetryConfig {
    /// Whether retry is enabled (default: true).
    pub enabled: bool,
    /// Maximum number of retry attempts (default: 5, meaning 6 total attempts).
    pub max_retries: u32,
    /// Base backoff delay in milliseconds (default: 100ms).
    pub base_backoff_ms: u64,
    /// Maximum backoff delay in milliseconds (default: 1600ms).
    pub max_backoff_ms: u64,
    /// Total timeout across all attempts in milliseconds (default: 30000ms).
    pub total_timeout_ms: u64,
    /// Whether to add jitter to backoff (default: true).
    pub use_jitter: bool,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_retries: 5,
            base_backoff_ms: 100,
            max_backoff_ms: 1600,
            total_timeout_ms: 30000,
            use_jitter: true,
        }
    }
}

/// Error codes per error-codes/spec.md.
pub mod error_codes {
    // Retryable errors
    pub const TIMEOUT: i32 = 0x01;
    pub const VIEW_CHANGE_IN_PROGRESS: i32 = 0x02;
    pub const NOT_PRIMARY: i32 = 0x03;
    pub const CLUSTER_UNAVAILABLE: i32 = 0x04;
    pub const REPLICA_LAGGING: i32 = 0x05;

    // Non-retryable errors
    pub const INVALID_OPERATION: i32 = 0x10;
    pub const INVALID_COORDINATES: i32 = 0x11;
    pub const TOO_MUCH_DATA: i32 = 0x12;
    pub const POLYGON_TOO_COMPLEX: i32 = 0x13;
    pub const QUERY_RESULT_TOO_LARGE: i32 = 0x14;
    pub const CHECKSUM_MISMATCH: i32 = 0x15;
    pub const INVALID_DATA_SIZE: i32 = 0x16;

    /// Returns true if the error code is retryable per spec.
    pub fn is_retryable(code: i32) -> bool {
        matches!(
            code,
            TIMEOUT | VIEW_CHANGE_IN_PROGRESS | NOT_PRIMARY | CLUSTER_UNAVAILABLE | REPLICA_LAGGING
        )
    }
}

/// Retry policy implementation.
pub struct RetryPolicy {
    config: RetryConfig,
}

impl RetryPolicy {
    /// Creates a new retry policy with the specified configuration.
    pub fn new(config: RetryConfig) -> Self {
        Self { config }
    }

    /// Creates a new retry policy with default configuration.
    pub fn with_defaults() -> Self {
        Self::new(RetryConfig::default())
    }

    /// Returns the configuration.
    pub fn config(&self) -> &RetryConfig {
        &self.config
    }

    /// Calculates the delay for a given attempt number (0-indexed).
    /// Returns 0 for the first attempt.
    pub fn get_delay_ms(&self, attempt: u32) -> u64 {
        if attempt == 0 {
            return 0;
        }

        // Exponential backoff: base * 2^(attempt-1)
        let exponential = self.config.base_backoff_ms.saturating_mul(1 << (attempt - 1).min(31));
        let base_delay = exponential.min(self.config.max_backoff_ms);

        if self.config.use_jitter {
            // Add jitter: delay + random(0, delay/2)
            let jitter = (base_delay / 2) as f64 * rand_fraction();
            base_delay + jitter as u64
        } else {
            base_delay
        }
    }

    /// Executes an operation with retry logic.
    pub fn execute<T, E, F>(&self, mut operation: F) -> Result<T, RetryError<E>>
    where
        F: FnMut() -> Result<T, E>,
        E: RetryableError,
    {
        if !self.config.enabled {
            return operation().map_err(|e| RetryError::OperationFailed(e));
        }

        let start = Instant::now();
        let total_timeout = Duration::from_millis(self.config.total_timeout_ms);
        let mut attempts = 0;
        let mut last_error = None;

        loop {
            // Check total timeout
            if start.elapsed() >= total_timeout {
                return Err(RetryError::TotalTimeoutExceeded {
                    attempts,
                    last_error,
                });
            }

            // Check max retries (attempt 0 is first try, not a retry)
            if attempts > self.config.max_retries {
                return Err(RetryError::RetriesExhausted {
                    attempts,
                    last_error,
                });
            }

            // Calculate and apply delay
            let delay_ms = self.get_delay_ms(attempts);
            if delay_ms > 0 {
                std::thread::sleep(Duration::from_millis(delay_ms));
            }

            match operation() {
                Ok(result) => return Ok(result),
                Err(e) => {
                    if !e.is_retryable() {
                        return Err(RetryError::NonRetryableError(e));
                    }
                    last_error = Some(e);
                    attempts += 1;
                }
            }
        }
    }
}

/// Simple pseudo-random fraction for jitter.
fn rand_fraction() -> f64 {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};

    let state = RandomState::new();
    let mut hasher = state.build_hasher();
    hasher.write_u64(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64);
    (hasher.finish() as f64) / (u64::MAX as f64)
}

/// Trait for errors that can indicate retryability.
pub trait RetryableError {
    fn is_retryable(&self) -> bool;
}

/// Error type for retry operations.
#[derive(Debug)]
pub enum RetryError<E> {
    /// Operation failed with a non-retryable error.
    NonRetryableError(E),
    /// Operation failed after all retries were exhausted.
    RetriesExhausted {
        attempts: u32,
        last_error: Option<E>,
    },
    /// Total timeout was exceeded.
    TotalTimeoutExceeded {
        attempts: u32,
        last_error: Option<E>,
    },
    /// Operation failed (retry disabled).
    OperationFailed(E),
}

impl<E: std::fmt::Display> std::fmt::Display for RetryError<E> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RetryError::NonRetryableError(e) => write!(f, "Non-retryable error: {}", e),
            RetryError::RetriesExhausted { attempts, .. } => {
                write!(f, "Retries exhausted after {} attempts", attempts)
            }
            RetryError::TotalTimeoutExceeded { attempts, .. } => {
                write!(f, "Total timeout exceeded after {} attempts", attempts)
            }
            RetryError::OperationFailed(e) => write!(f, "Operation failed: {}", e),
        }
    }
}

impl<E: std::error::Error + 'static> std::error::Error for RetryError<E> {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            RetryError::NonRetryableError(e) => Some(e),
            RetryError::RetriesExhausted { last_error: Some(e), .. } => Some(e),
            RetryError::TotalTimeoutExceeded { last_error: Some(e), .. } => Some(e),
            RetryError::OperationFailed(e) => Some(e),
            _ => None,
        }
    }
}

/// Exception for exhausted retries (used in tests).
#[derive(Debug, Clone)]
pub struct RetryExhaustedException {
    pub attempts: u32,
}

impl std::fmt::Display for RetryExhaustedException {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Retry exhausted after {} attempts", self.attempts)
    }
}

impl std::error::Error for RetryExhaustedException {}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug)]
    struct TestError {
        code: i32,
    }

    impl std::fmt::Display for TestError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(f, "TestError({})", self.code)
        }
    }

    impl std::error::Error for TestError {}

    impl RetryableError for TestError {
        fn is_retryable(&self) -> bool {
            error_codes::is_retryable(self.code)
        }
    }

    #[test]
    fn test_default_config_matches_spec() {
        let config = RetryConfig::default();

        assert!(config.enabled);
        assert_eq!(config.max_retries, 5); // 5 retries = 6 total attempts per spec
        assert_eq!(config.base_backoff_ms, 100); // 100ms base per spec
        assert_eq!(config.max_backoff_ms, 1600); // 1600ms max per spec
        assert_eq!(config.total_timeout_ms, 30000); // 30s total timeout per spec
        assert!(config.use_jitter);
    }

    #[test]
    fn test_first_attempt_no_delay() {
        let policy = RetryPolicy::new(RetryConfig {
            use_jitter: false,
            ..Default::default()
        });
        assert_eq!(policy.get_delay_ms(0), 0);
    }

    #[test]
    fn test_exponential_backoff() {
        let policy = RetryPolicy::new(RetryConfig {
            use_jitter: false,
            base_backoff_ms: 100,
            max_backoff_ms: 1600,
            ..Default::default()
        });

        assert_eq!(policy.get_delay_ms(0), 0);    // Attempt 0
        assert_eq!(policy.get_delay_ms(1), 100);  // Attempt 1: 100ms
        assert_eq!(policy.get_delay_ms(2), 200);  // Attempt 2: 200ms
        assert_eq!(policy.get_delay_ms(3), 400);  // Attempt 3: 400ms
        assert_eq!(policy.get_delay_ms(4), 800);  // Attempt 4: 800ms
        assert_eq!(policy.get_delay_ms(5), 1600); // Attempt 5: 1600ms
    }

    #[test]
    fn test_caps_at_max() {
        let policy = RetryPolicy::new(RetryConfig {
            use_jitter: false,
            base_backoff_ms: 100,
            max_backoff_ms: 500,
            ..Default::default()
        });

        assert_eq!(policy.get_delay_ms(4), 500); // Would be 800 but capped at 500
        assert_eq!(policy.get_delay_ms(5), 500); // Would be 1600 but capped at 500
    }

    #[test]
    fn test_jitter_adds_randomness() {
        let policy = RetryPolicy::new(RetryConfig {
            use_jitter: true,
            base_backoff_ms: 100,
            ..Default::default()
        });

        // With jitter, delay should be base + random(0, base/2)
        // So delay should be between 100 and 150 for attempt 1
        let delay = policy.get_delay_ms(1);
        assert!(delay >= 100 && delay <= 150);
    }

    #[test]
    fn test_error_codes_retryable() {
        // Retryable errors per spec
        assert!(error_codes::is_retryable(error_codes::TIMEOUT));
        assert!(error_codes::is_retryable(error_codes::VIEW_CHANGE_IN_PROGRESS));
        assert!(error_codes::is_retryable(error_codes::NOT_PRIMARY));
        assert!(error_codes::is_retryable(error_codes::CLUSTER_UNAVAILABLE));
        assert!(error_codes::is_retryable(error_codes::REPLICA_LAGGING));

        // Non-retryable errors per spec
        assert!(!error_codes::is_retryable(error_codes::INVALID_OPERATION));
        assert!(!error_codes::is_retryable(error_codes::INVALID_COORDINATES));
        assert!(!error_codes::is_retryable(error_codes::TOO_MUCH_DATA));
        assert!(!error_codes::is_retryable(error_codes::POLYGON_TOO_COMPLEX));
        assert!(!error_codes::is_retryable(error_codes::QUERY_RESULT_TOO_LARGE));
        assert!(!error_codes::is_retryable(error_codes::CHECKSUM_MISMATCH));
        assert!(!error_codes::is_retryable(error_codes::INVALID_DATA_SIZE));
    }

    #[test]
    fn test_execute_returns_on_success() {
        let policy = RetryPolicy::with_defaults();
        let mut call_count = 0;

        let result: Result<i32, RetryError<TestError>> = policy.execute(|| {
            call_count += 1;
            Ok(42)
        });

        assert_eq!(result.unwrap(), 42);
        assert_eq!(call_count, 1);
    }

    #[test]
    fn test_execute_disabled_no_retries() {
        let policy = RetryPolicy::new(RetryConfig {
            enabled: false,
            ..Default::default()
        });
        let mut call_count = 0;

        let result: Result<i32, RetryError<TestError>> = policy.execute(|| {
            call_count += 1;
            Err(TestError { code: error_codes::TIMEOUT })
        });

        assert!(matches!(result, Err(RetryError::OperationFailed(_))));
        assert_eq!(call_count, 1);
    }

    #[test]
    fn test_execute_non_retryable_no_retry() {
        let policy = RetryPolicy::new(RetryConfig {
            max_retries: 5,
            ..Default::default()
        });
        let mut call_count = 0;

        let result: Result<i32, RetryError<TestError>> = policy.execute(|| {
            call_count += 1;
            Err(TestError { code: error_codes::INVALID_COORDINATES })
        });

        assert!(matches!(result, Err(RetryError::NonRetryableError(_))));
        assert_eq!(call_count, 1);
    }
}
