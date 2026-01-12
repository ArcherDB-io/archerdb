// Package circuitbreaker tests per client-retry/spec.md requirements.
package circuitbreaker

import (
	"sync"
	"testing"
	"time"
)

func TestDefaultConfig(t *testing.T) {
	// Per spec: 50% failure rate, 10 min requests, 10s window, 30s open, 5 half-open requests
	config := DefaultConfig()

	if config.FailureThreshold != 0.5 {
		t.Errorf("FailureThreshold = %v, want 0.5", config.FailureThreshold)
	}
	if config.MinRequests != 10 {
		t.Errorf("MinRequests = %v, want 10", config.MinRequests)
	}
	if config.WindowDurationMs != 10000 {
		t.Errorf("WindowDurationMs = %v, want 10000", config.WindowDurationMs)
	}
	if config.OpenDurationMs != 30000 {
		t.Errorf("OpenDurationMs = %v, want 30000", config.OpenDurationMs)
	}
	if config.HalfOpenRequests != 5 {
		t.Errorf("HalfOpenRequests = %v, want 5", config.HalfOpenRequests)
	}
}

func TestCircuitBreakerInitialState(t *testing.T) {
	cb := New("test-replica")

	if cb.State() != Closed {
		t.Errorf("Initial state = %v, want Closed", cb.State())
	}
	if !cb.IsClosed() {
		t.Error("IsClosed() = false, want true")
	}
	if cb.IsOpen() {
		t.Error("IsOpen() = true, want false")
	}
	if !cb.AllowRequest() {
		t.Error("AllowRequest() = false, want true (circuit closed)")
	}
}

func TestCircuitBreakerOpensOn50PercentFailureWith10Requests(t *testing.T) {
	// Per spec: Opens when 50% failure rate in 10s window AND >= 10 requests
	cb := New("test-replica")

	// 5 successes
	for i := 0; i < 5; i++ {
		cb.AllowRequest()
		cb.RecordSuccess()
	}

	if cb.State() != Closed {
		t.Errorf("State after 5 successes = %v, want Closed", cb.State())
	}

	// 5 failures (total 10 requests, 50% failure rate)
	for i := 0; i < 5; i++ {
		cb.AllowRequest()
		cb.RecordFailure()
	}

	if cb.State() != Open {
		t.Errorf("State after 50%% failure rate = %v, want Open", cb.State())
	}
	if !cb.IsOpen() {
		t.Error("IsOpen() = false, want true")
	}
}

func TestCircuitBreakerDoesNotOpenBelowMinRequests(t *testing.T) {
	// Per spec: Minimum requests in window before circuit can open
	cb := New("test-replica")

	// 4 failures out of 9 requests (44% failure rate, but < 10 min requests)
	for i := 0; i < 5; i++ {
		cb.AllowRequest()
		cb.RecordSuccess()
	}
	for i := 0; i < 4; i++ {
		cb.AllowRequest()
		cb.RecordFailure()
	}

	if cb.State() != Closed {
		t.Errorf("State with < 10 requests = %v, want Closed", cb.State())
	}
}

func TestCircuitBreakerRejectsRequestsWhenOpen(t *testing.T) {
	cb := New("test-replica")
	cb.ForceOpen()

	if cb.AllowRequest() {
		t.Error("AllowRequest() = true when open, want false")
	}
}

func TestCircuitBreakerTransitionsToHalfOpen(t *testing.T) {
	// Per spec: Stays open for 30 seconds before transitioning to half-open
	config := DefaultConfig()
	config.OpenDurationMs = 50 // 50ms for testing
	cb := NewWithConfig("test-replica", config)

	cb.ForceOpen()
	if cb.State() != Open {
		t.Errorf("State after ForceOpen = %v, want Open", cb.State())
	}

	// Wait for open duration
	time.Sleep(60 * time.Millisecond)

	// State check should transition to half-open
	if cb.State() != HalfOpen {
		t.Errorf("State after open duration = %v, want HalfOpen", cb.State())
	}
	if !cb.IsHalfOpen() {
		t.Error("IsHalfOpen() = false, want true")
	}
}

func TestCircuitBreakerHalfOpenLimitsRequests(t *testing.T) {
	// Per spec: Half-open allows 5 test requests
	config := DefaultConfig()
	config.HalfOpenRequests = 3 // 3 for faster testing
	config.OpenDurationMs = 10
	cb := NewWithConfig("test-replica", config)

	cb.ForceOpen()
	time.Sleep(20 * time.Millisecond)

	// First 3 requests should be allowed
	for i := 0; i < 3; i++ {
		if !cb.AllowRequest() {
			t.Errorf("AllowRequest() %d = false in half-open, want true", i)
		}
	}

	// 4th request should be rejected
	if cb.AllowRequest() {
		t.Error("AllowRequest() 4 = true in half-open, want false (limit reached)")
	}
}

func TestCircuitBreakerClosesAfterHalfOpenSuccesses(t *testing.T) {
	// Per spec: Circuit closes after sufficient successes in half-open
	config := DefaultConfig()
	config.HalfOpenRequests = 3
	config.OpenDurationMs = 10
	cb := NewWithConfig("test-replica", config)

	cb.ForceOpen()
	time.Sleep(20 * time.Millisecond)

	// All half-open requests succeed
	for i := 0; i < 3; i++ {
		cb.AllowRequest()
		cb.RecordSuccess()
	}

	if cb.State() != Closed {
		t.Errorf("State after half-open successes = %v, want Closed", cb.State())
	}
}

func TestCircuitBreakerReopensOnHalfOpenFailure(t *testing.T) {
	// Per spec: Circuit re-opens on any failure in half-open
	config := DefaultConfig()
	config.HalfOpenRequests = 5
	config.OpenDurationMs = 10
	cb := NewWithConfig("test-replica", config)

	cb.ForceOpen()
	time.Sleep(20 * time.Millisecond)

	// First request succeeds
	cb.AllowRequest()
	cb.RecordSuccess()

	// Second request fails
	cb.AllowRequest()
	cb.RecordFailure()

	if cb.State() != Open {
		t.Errorf("State after half-open failure = %v, want Open", cb.State())
	}
}

func TestCircuitBreakerError(t *testing.T) {
	err := ErrCircuitOpen{
		CircuitName:  "test-replica",
		CircuitState: Open,
	}

	msg := err.Error()
	if msg == "" {
		t.Error("Error message is empty")
	}
	if err.CircuitName != "test-replica" {
		t.Errorf("CircuitName = %v, want test-replica", err.CircuitName)
	}
	if err.CircuitState != Open {
		t.Errorf("CircuitState = %v, want Open", err.CircuitState)
	}
}

func TestCircuitBreakerMetrics(t *testing.T) {
	cb := New("test-replica")

	// Generate some activity
	for i := 0; i < 5; i++ {
		cb.AllowRequest()
		cb.RecordSuccess()
	}
	for i := 0; i < 3; i++ {
		cb.AllowRequest()
		cb.RecordFailure()
	}

	metrics := cb.Metrics()

	if metrics.State != Closed {
		t.Errorf("Metrics.State = %v, want Closed", metrics.State)
	}
	if metrics.TotalRequests != 8 {
		t.Errorf("Metrics.TotalRequests = %v, want 8", metrics.TotalRequests)
	}
	if metrics.FailedRequests != 3 {
		t.Errorf("Metrics.FailedRequests = %v, want 3", metrics.FailedRequests)
	}
}

func TestCircuitBreakerConcurrency(t *testing.T) {
	// Test thread safety
	cb := New("test-replica")
	var wg sync.WaitGroup

	// 100 concurrent operations
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()

			if cb.AllowRequest() {
				if idx%2 == 0 {
					cb.RecordSuccess()
				} else {
					cb.RecordFailure()
				}
			}

			// Read operations
			_ = cb.State()
			_ = cb.FailureRate()
			_ = cb.Metrics()
		}(i)
	}

	wg.Wait()

	// Should not panic or deadlock
	_ = cb.String()
}

func TestCircuitBreakerForceMethods(t *testing.T) {
	cb := New("test-replica")

	cb.ForceOpen()
	if cb.State() != Open {
		t.Errorf("State after ForceOpen = %v, want Open", cb.State())
	}

	cb.ForceClosed()
	if cb.State() != Closed {
		t.Errorf("State after ForceClosed = %v, want Closed", cb.State())
	}
}

func TestCircuitBreakerString(t *testing.T) {
	cb := New("test-replica")

	str := cb.String()
	if str == "" {
		t.Error("String() returned empty")
	}
}

func TestStateString(t *testing.T) {
	tests := []struct {
		state State
		want  string
	}{
		{Closed, "CLOSED"},
		{Open, "OPEN"},
		{HalfOpen, "HALF_OPEN"},
		{State(99), "UNKNOWN"},
	}

	for _, tt := range tests {
		if got := tt.state.String(); got != tt.want {
			t.Errorf("State(%d).String() = %v, want %v", tt.state, got, tt.want)
		}
	}
}

func TestCircuitBreakerFailureRate(t *testing.T) {
	cb := New("test-replica")

	// No requests
	if cb.FailureRate() != 0.0 {
		t.Errorf("FailureRate with no requests = %v, want 0.0", cb.FailureRate())
	}

	// 50% failure rate
	for i := 0; i < 5; i++ {
		cb.AllowRequest()
		cb.RecordSuccess()
	}
	for i := 0; i < 5; i++ {
		cb.AllowRequest()
		cb.RecordFailure()
	}

	rate := cb.FailureRate()
	if rate < 0.49 || rate > 0.51 {
		t.Errorf("FailureRate = %v, want ~0.5", rate)
	}
}
