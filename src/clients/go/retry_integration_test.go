package archerdb

import (
	"testing"
	"time"

	"github.com/archerdb/archerdb-go/pkg/observability"
	"github.com/archerdb/archerdb-go/pkg/types"
)

// ============================================================================
// Retry Metrics Integration Tests (per client-retry/spec.md)
// ============================================================================

// createMockClient creates a geoClient with mock metrics for testing.
// Note: This doesn't use CGO since we're only testing the retry logic.
func createMockClient(retryConfig RetryConfig) *geoClient {
	observability.ResetMetrics()
	return &geoClient{
		retryConfig: retryConfig,
		metrics:     observability.GetMetrics(),
		closed:      false,
	}
}

func TestRetryMetricsRecordedOnRetry(t *testing.T) {
	// Create a client with retry enabled
	client := createMockClient(RetryConfig{
		Enabled:      true,
		MaxRetries:   3,
		BaseBackoff:  1 * time.Millisecond, // Fast for testing
		MaxBackoff:   10 * time.Millisecond,
		TotalTimeout: 1 * time.Second,
		Jitter:       false, // Disable jitter for deterministic testing
	})

	// Create an operation that fails twice then succeeds
	attemptCount := 0
	operation := func() ([]types.InsertGeoEventsError, error) {
		attemptCount++
		if attemptCount < 3 {
			return nil, ConnectionFailedError{Msg: "mock connection failure"}
		}
		return nil, nil
	}

	// Execute with retry
	_, err := client.withRetry(operation)
	if err != nil {
		t.Fatalf("Expected success after retries, got error: %v", err)
	}

	// Verify metrics: 2 retries (attempts 2 and 3)
	metrics := observability.GetMetrics()
	if metrics.RetriesTotal.Get(nil) != 2 {
		t.Errorf("Expected 2 retries, got %d", metrics.RetriesTotal.Get(nil))
	}

	// No exhaustion since we eventually succeeded
	if metrics.RetryExhaustedTotal.Get(nil) != 0 {
		t.Errorf("Expected 0 retry exhausted, got %d", metrics.RetryExhaustedTotal.Get(nil))
	}
}

func TestRetryExhaustedMetricRecorded(t *testing.T) {
	// Create a client with limited retries
	client := createMockClient(RetryConfig{
		Enabled:      true,
		MaxRetries:   2, // Only 2 retries (3 total attempts)
		BaseBackoff:  1 * time.Millisecond,
		MaxBackoff:   10 * time.Millisecond,
		TotalTimeout: 1 * time.Second,
		Jitter:       false,
	})

	// Create an operation that always fails with retryable error
	operation := func() ([]types.InsertGeoEventsError, error) {
		return nil, ConnectionFailedError{Msg: "mock connection failure"}
	}

	// Execute with retry - should exhaust all retries
	_, err := client.withRetry(operation)
	if err == nil {
		t.Fatal("Expected retry exhausted error, got nil")
	}

	if _, ok := err.(RetryExhaustedError); !ok {
		t.Fatalf("Expected RetryExhaustedError, got %T: %v", err, err)
	}

	// Verify metrics: 2 retries (attempts 2 and 3)
	metrics := observability.GetMetrics()
	if metrics.RetriesTotal.Get(nil) != 2 {
		t.Errorf("Expected 2 retries, got %d", metrics.RetriesTotal.Get(nil))
	}

	// Exhaustion should be recorded
	if metrics.RetryExhaustedTotal.Get(nil) != 1 {
		t.Errorf("Expected 1 retry exhausted, got %d", metrics.RetryExhaustedTotal.Get(nil))
	}
}

func TestNoMetricsRecordedOnSuccess(t *testing.T) {
	// Create a client with retry enabled
	client := createMockClient(RetryConfig{
		Enabled:      true,
		MaxRetries:   3,
		BaseBackoff:  1 * time.Millisecond,
		MaxBackoff:   10 * time.Millisecond,
		TotalTimeout: 1 * time.Second,
		Jitter:       false,
	})

	// Create an operation that succeeds immediately
	operation := func() ([]types.InsertGeoEventsError, error) {
		return nil, nil
	}

	// Execute with retry
	_, err := client.withRetry(operation)
	if err != nil {
		t.Fatalf("Expected success, got error: %v", err)
	}

	// Verify no retries recorded (success on first attempt)
	metrics := observability.GetMetrics()
	if metrics.RetriesTotal.Get(nil) != 0 {
		t.Errorf("Expected 0 retries, got %d", metrics.RetriesTotal.Get(nil))
	}

	if metrics.RetryExhaustedTotal.Get(nil) != 0 {
		t.Errorf("Expected 0 retry exhausted, got %d", metrics.RetryExhaustedTotal.Get(nil))
	}
}

func TestNoMetricsRecordedForNonRetryableError(t *testing.T) {
	// Create a client with retry enabled
	client := createMockClient(RetryConfig{
		Enabled:      true,
		MaxRetries:   3,
		BaseBackoff:  1 * time.Millisecond,
		MaxBackoff:   10 * time.Millisecond,
		TotalTimeout: 1 * time.Second,
		Jitter:       false,
	})

	// Create an operation that fails with non-retryable error
	operation := func() ([]types.InsertGeoEventsError, error) {
		return nil, InvalidCoordinatesError{Msg: "invalid coordinates"}
	}

	// Execute with retry
	_, err := client.withRetry(operation)
	if err == nil {
		t.Fatal("Expected error, got nil")
	}

	// Verify no retries recorded (non-retryable error fails immediately)
	metrics := observability.GetMetrics()
	if metrics.RetriesTotal.Get(nil) != 0 {
		t.Errorf("Expected 0 retries, got %d", metrics.RetriesTotal.Get(nil))
	}

	// No exhaustion since we didn't retry
	if metrics.RetryExhaustedTotal.Get(nil) != 0 {
		t.Errorf("Expected 0 retry exhausted, got %d", metrics.RetryExhaustedTotal.Get(nil))
	}
}

func TestNilMetricsDoesNotCrash(t *testing.T) {
	// Create a client without metrics (nil)
	client := &geoClient{
		retryConfig: RetryConfig{
			Enabled:      true,
			MaxRetries:   2,
			BaseBackoff:  1 * time.Millisecond,
			MaxBackoff:   10 * time.Millisecond,
			TotalTimeout: 1 * time.Second,
			Jitter:       false,
		},
		metrics: nil, // Explicitly nil
		closed:  false,
	}

	// Create an operation that always fails
	operation := func() ([]types.InsertGeoEventsError, error) {
		return nil, ConnectionFailedError{Msg: "mock failure"}
	}

	// Execute with retry - should not panic
	_, err := client.withRetry(operation)
	if err == nil {
		t.Fatal("Expected error, got nil")
	}

	// Verify no panic occurred
	t.Log("Nil metrics handling works correctly")
}

func TestRetryDisabledNoMetrics(t *testing.T) {
	// Create a client with retry disabled
	client := createMockClient(RetryConfig{
		Enabled: false,
	})

	// Create an operation that fails
	operation := func() ([]types.InsertGeoEventsError, error) {
		return nil, ConnectionFailedError{Msg: "mock failure"}
	}

	// Execute - should fail immediately without retries
	_, err := client.withRetry(operation)
	if err == nil {
		t.Fatal("Expected error, got nil")
	}

	// Verify no metrics recorded when retry is disabled
	metrics := observability.GetMetrics()
	if metrics.RetriesTotal.Get(nil) != 0 {
		t.Errorf("Expected 0 retries when disabled, got %d", metrics.RetriesTotal.Get(nil))
	}

	if metrics.RetryExhaustedTotal.Get(nil) != 0 {
		t.Errorf("Expected 0 retry exhausted when disabled, got %d", metrics.RetryExhaustedTotal.Get(nil))
	}
}

func TestRetryMetricsExportedInPrometheus(t *testing.T) {
	// Create a client and simulate some retry activity
	client := createMockClient(RetryConfig{
		Enabled:      true,
		MaxRetries:   2,
		BaseBackoff:  1 * time.Millisecond,
		MaxBackoff:   10 * time.Millisecond,
		TotalTimeout: 1 * time.Second,
		Jitter:       false,
	})

	// Operation that fails once then succeeds
	attemptCount := 0
	operation := func() ([]types.InsertGeoEventsError, error) {
		attemptCount++
		if attemptCount < 2 {
			return nil, ConnectionFailedError{Msg: "mock failure"}
		}
		return nil, nil
	}

	_, _ = client.withRetry(operation)

	// Get Prometheus export
	metrics := observability.GetMetrics()
	prometheus := metrics.ToPrometheus()

	// Verify retry metrics are in the export
	expectedStrings := []string{
		"archerdb_client_retries_total",
		"archerdb_client_retry_exhausted_total",
	}

	for _, expected := range expectedStrings {
		if !containsString(prometheus, expected) {
			t.Errorf("Prometheus export missing %q", expected)
		}
	}
}

func containsString(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsStringHelper(s, substr))
}

func containsStringHelper(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
