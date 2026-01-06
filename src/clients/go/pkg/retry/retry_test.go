package retry

import (
	"errors"
	"testing"
	"time"

	sdk_errors "github.com/archerdb/archerdb-go/pkg/errors"
)

func TestDefaultConfig(t *testing.T) {
	config := DefaultConfig()

	if !config.Enabled {
		t.Error("Default config should have Enabled=true")
	}
	if config.MaxRetries != 5 {
		t.Errorf("Default MaxRetries should be 5, got %d", config.MaxRetries)
	}
	if config.BaseBackoffMs != 100 {
		t.Errorf("Default BaseBackoffMs should be 100, got %d", config.BaseBackoffMs)
	}
	if config.MaxBackoffMs != 1600 {
		t.Errorf("Default MaxBackoffMs should be 1600, got %d", config.MaxBackoffMs)
	}
	if config.TotalTimeoutMs != 30000 {
		t.Errorf("Default TotalTimeoutMs should be 30000, got %d", config.TotalTimeoutMs)
	}
	if !config.Jitter {
		t.Error("Default config should have Jitter=true")
	}
}

func TestIsRetryable_NetworkErrors(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		expected bool
	}{
		{"timeout error", errors.New("connection timeout"), true},
		{"connection reset", errors.New("connection reset by peer"), true},
		{"connection refused", errors.New("connection refused"), true},
		{"network error", errors.New("network unreachable"), true},
		{"eof error", errors.New("unexpected EOF"), true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsRetryable(tt.err); got != tt.expected {
				t.Errorf("IsRetryable(%v) = %v, want %v", tt.err, got, tt.expected)
			}
		})
	}
}

func TestIsRetryable_SDKErrors(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		expected bool
	}{
		{"client evicted", sdk_errors.ErrClientEvicted{}, true},
		{"client release too low", sdk_errors.ErrClientReleaseTooLow{}, true},
		{"client release too high", sdk_errors.ErrClientReleaseTooHigh{}, true},
		{"system resources", sdk_errors.ErrSystemResources{}, true},
		{"network subsystem", sdk_errors.ErrNetworkSubsystem{}, true},
		{"client closed", sdk_errors.ErrClientClosed{}, false},
		{"invalid operation", sdk_errors.ErrInvalidOperation{}, false},
		{"batch too large", sdk_errors.ErrMaximumBatchSizeExceeded{}, false},
		{"invalid address", sdk_errors.ErrInvalidAddress{}, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsRetryable(tt.err); got != tt.expected {
				t.Errorf("IsRetryable(%v) = %v, want %v", tt.err, got, tt.expected)
			}
		})
	}
}

func TestIsRetryable_NilError(t *testing.T) {
	if IsRetryable(nil) {
		t.Error("IsRetryable(nil) should be false")
	}
}

func TestCalculateDelay_FirstAttempt(t *testing.T) {
	config := DefaultConfig()
	delay := CalculateDelay(1, config)
	if delay != 0 {
		t.Errorf("First attempt should have 0 delay, got %v", delay)
	}
}

func TestCalculateDelay_ExponentialBackoff(t *testing.T) {
	config := DefaultConfig()
	config.Jitter = false // Disable jitter for predictable testing

	expectedDelays := []time.Duration{
		0,                        // Attempt 1
		100 * time.Millisecond,   // Attempt 2
		200 * time.Millisecond,   // Attempt 3
		400 * time.Millisecond,   // Attempt 4
		800 * time.Millisecond,   // Attempt 5
		1600 * time.Millisecond,  // Attempt 6
	}

	for attempt, expected := range expectedDelays {
		delay := CalculateDelay(attempt+1, config)
		if delay != expected {
			t.Errorf("Attempt %d: expected delay %v, got %v", attempt+1, expected, delay)
		}
	}
}

func TestCalculateDelay_MaxBackoff(t *testing.T) {
	config := DefaultConfig()
	config.Jitter = false
	config.MaxBackoffMs = 500

	// Attempt 5 would normally be 800ms, but should be capped at 500ms
	delay := CalculateDelay(5, config)
	if delay != 500*time.Millisecond {
		t.Errorf("Expected delay capped at 500ms, got %v", delay)
	}
}

func TestCalculateDelay_WithJitter(t *testing.T) {
	config := DefaultConfig()
	config.Jitter = true

	// With jitter enabled, delay should be between base and base*1.5
	for attempt := 2; attempt <= 6; attempt++ {
		delay := CalculateDelay(attempt, config)
		baseDelay := config.BaseBackoffMs * (1 << (attempt - 2))
		if baseDelay > config.MaxBackoffMs {
			baseDelay = config.MaxBackoffMs
		}
		minDelay := time.Duration(baseDelay) * time.Millisecond
		maxDelay := time.Duration(baseDelay*3/2) * time.Millisecond

		if delay < minDelay || delay > maxDelay {
			t.Errorf("Attempt %d: delay %v not in range [%v, %v]", attempt, delay, minDelay, maxDelay)
		}
	}
}

func TestDo_Success(t *testing.T) {
	config := DefaultConfig()
	callCount := 0

	err := Do(func() error {
		callCount++
		return nil
	}, config)

	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
	if callCount != 1 {
		t.Errorf("Expected 1 call, got %d", callCount)
	}
}

func TestDo_RetryOnTransientError(t *testing.T) {
	config := DefaultConfig()
	config.BaseBackoffMs = 1 // Use small delays for faster tests
	config.MaxBackoffMs = 10
	callCount := 0

	err := Do(func() error {
		callCount++
		if callCount < 3 {
			return errors.New("timeout error") // Retryable
		}
		return nil
	}, config)

	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
	if callCount != 3 {
		t.Errorf("Expected 3 calls, got %d", callCount)
	}
}

func TestDo_NoRetryOnNonRetryableError(t *testing.T) {
	config := DefaultConfig()
	callCount := 0

	err := Do(func() error {
		callCount++
		return sdk_errors.ErrInvalidOperation{}
	}, config)

	if err == nil {
		t.Error("Expected error, got nil")
	}
	if callCount != 1 {
		t.Errorf("Expected 1 call (no retry), got %d", callCount)
	}
}

func TestDo_ExhaustsRetries(t *testing.T) {
	config := DefaultConfig()
	config.MaxRetries = 2
	config.BaseBackoffMs = 1 // Use small delays for faster tests
	config.MaxBackoffMs = 1
	callCount := 0

	err := Do(func() error {
		callCount++
		return errors.New("timeout error") // Always fail
	}, config)

	var exhausted ErrRetryExhausted
	if !errors.As(err, &exhausted) {
		t.Errorf("Expected ErrRetryExhausted, got %T", err)
	}
	if callCount != 3 { // 1 initial + 2 retries
		t.Errorf("Expected 3 calls, got %d", callCount)
	}
	if exhausted.Attempts != 3 {
		t.Errorf("Expected 3 attempts in error, got %d", exhausted.Attempts)
	}
}

func TestDo_DisabledRetry(t *testing.T) {
	config := DefaultConfig()
	config.Enabled = false
	callCount := 0

	err := Do(func() error {
		callCount++
		return errors.New("timeout error")
	}, config)

	if err == nil {
		t.Error("Expected error, got nil")
	}
	if callCount != 1 {
		t.Errorf("Expected 1 call (retry disabled), got %d", callCount)
	}
}

func TestDo_TotalTimeout(t *testing.T) {
	config := DefaultConfig()
	config.TotalTimeoutMs = 50 // 50ms total timeout
	config.BaseBackoffMs = 100 // 100ms base delay (exceeds timeout)
	config.MaxBackoffMs = 100
	callCount := 0

	err := Do(func() error {
		callCount++
		return errors.New("timeout error")
	}, config)

	var exhausted ErrRetryExhausted
	if !errors.As(err, &exhausted) {
		t.Errorf("Expected ErrRetryExhausted, got %T", err)
	}
	// Should stop quickly due to timeout
	if callCount > 3 {
		t.Errorf("Expected few calls due to timeout, got %d", callCount)
	}
}

func TestErrRetryExhausted_Unwrap(t *testing.T) {
	originalErr := errors.New("original error")
	err := ErrRetryExhausted{
		Attempts:  3,
		LastError: originalErr,
	}

	if !errors.Is(err, originalErr) {
		t.Error("ErrRetryExhausted should unwrap to LastError")
	}
}
