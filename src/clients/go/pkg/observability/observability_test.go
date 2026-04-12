// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package observability

import (
	"strings"
	"testing"
	"time"
)

// ============================================================================
// Logging Tests
// ============================================================================

func TestNullLogger(t *testing.T) {
	logger := NullLogger{}
	// Should not panic
	logger.Debug("debug message")
	logger.Info("info message")
	logger.Warn("warn message")
	logger.Error("error message")
}

func TestStandardLogger(t *testing.T) {
	// Create a logger with ERROR level - lower levels should be filtered
	logger := NewStandardLogger("test", ERROR)
	// These should not produce output (level is ERROR)
	logger.Debug("should not appear")
	logger.Info("should not appear")
	logger.Warn("should not appear")
}

func TestSetAndGetLogger(t *testing.T) {
	// Save original
	original := GetLogger()
	defer SetLogger(original)

	customLogger := NullLogger{}
	SetLogger(customLogger)

	got := GetLogger()
	if _, ok := got.(NullLogger); !ok {
		t.Errorf("Expected NullLogger, got %T", got)
	}
}

// ============================================================================
// Counter Tests
// ============================================================================

func TestCounter_Inc(t *testing.T) {
	counter := NewCounter("test_counter", "Test counter")

	// Initial value is 0
	if counter.Get(nil) != 0 {
		t.Errorf("Expected 0, got %d", counter.Get(nil))
	}

	// Increment
	counter.Inc(nil)
	if counter.Get(nil) != 1 {
		t.Errorf("Expected 1, got %d", counter.Get(nil))
	}

	// Add value
	counter.Add(nil, 5)
	if counter.Get(nil) != 6 {
		t.Errorf("Expected 6, got %d", counter.Get(nil))
	}
}

func TestCounter_Labels(t *testing.T) {
	counter := NewCounter("test_counter", "Test counter")

	labels1 := &MetricLabels{Operation: "query", Status: "success"}
	labels2 := &MetricLabels{Operation: "query", Status: "error"}

	counter.Inc(labels1)
	counter.Inc(labels1)
	counter.Inc(labels2)

	if counter.Get(labels1) != 2 {
		t.Errorf("Expected 2, got %d", counter.Get(labels1))
	}
	if counter.Get(labels2) != 1 {
		t.Errorf("Expected 1, got %d", counter.Get(labels2))
	}
}

func TestCounter_GetAll(t *testing.T) {
	counter := NewCounter("test_counter", "Test counter")

	counter.Inc(&MetricLabels{Operation: "query", Status: "success"})
	counter.Inc(&MetricLabels{Operation: "insert", Status: "error"})

	all := counter.GetAll()
	if len(all) != 2 {
		t.Errorf("Expected 2 entries, got %d", len(all))
	}
}

func TestCounter_Reset(t *testing.T) {
	counter := NewCounter("test_counter", "Test counter")
	counter.Inc(nil)
	counter.Reset()

	if counter.Get(nil) != 0 {
		t.Errorf("Expected 0 after reset, got %d", counter.Get(nil))
	}
}

// ============================================================================
// Gauge Tests
// ============================================================================

func TestGauge_Operations(t *testing.T) {
	gauge := NewGauge("test_gauge", "Test gauge")

	// Initial value is 0
	if gauge.Get() != 0 {
		t.Errorf("Expected 0, got %d", gauge.Get())
	}

	// Set
	gauge.Set(10)
	if gauge.Get() != 10 {
		t.Errorf("Expected 10, got %d", gauge.Get())
	}

	// Inc
	gauge.Inc()
	if gauge.Get() != 11 {
		t.Errorf("Expected 11, got %d", gauge.Get())
	}

	// Dec
	gauge.Dec()
	if gauge.Get() != 10 {
		t.Errorf("Expected 10, got %d", gauge.Get())
	}

	// Add
	gauge.Add(5)
	if gauge.Get() != 15 {
		t.Errorf("Expected 15, got %d", gauge.Get())
	}
}

func TestGauge_Reset(t *testing.T) {
	gauge := NewGauge("test_gauge", "Test gauge")
	gauge.Set(100)
	gauge.Reset()

	if gauge.Get() != 0 {
		t.Errorf("Expected 0 after reset, got %d", gauge.Get())
	}
}

// ============================================================================
// Histogram Tests
// ============================================================================

func TestHistogram_Observe(t *testing.T) {
	hist := NewHistogram("test_histogram", "Test histogram")

	// Initial state
	if hist.GetCount(nil) != 0 {
		t.Errorf("Expected count 0, got %d", hist.GetCount(nil))
	}
	if hist.GetSum(nil) != 0 {
		t.Errorf("Expected sum 0, got %f", hist.GetSum(nil))
	}

	// Observe values
	hist.Observe(0.1, nil)
	hist.Observe(0.5, nil)
	hist.Observe(1.0, nil)

	if hist.GetCount(nil) != 3 {
		t.Errorf("Expected count 3, got %d", hist.GetCount(nil))
	}

	expectedSum := 1.6
	if diff := hist.GetSum(nil) - expectedSum; diff > 0.0001 || diff < -0.0001 {
		t.Errorf("Expected sum %f, got %f", expectedSum, hist.GetSum(nil))
	}
}

func TestHistogram_WithLabels(t *testing.T) {
	hist := NewHistogram("test_histogram", "Test histogram")

	labels := &MetricLabels{Operation: "query"}
	hist.Observe(0.1, labels)
	hist.Observe(0.2, labels)

	if hist.GetCount(labels) != 2 {
		t.Errorf("Expected count 2, got %d", hist.GetCount(labels))
	}
}

func TestHistogram_Reset(t *testing.T) {
	hist := NewHistogram("test_histogram", "Test histogram")
	hist.Observe(1.0, nil)
	hist.Reset()

	if hist.GetCount(nil) != 0 {
		t.Errorf("Expected count 0 after reset, got %d", hist.GetCount(nil))
	}
}

// ============================================================================
// SDKMetrics Tests
// ============================================================================

func TestSDKMetrics_RecordRequest(t *testing.T) {
	metrics := NewSDKMetrics()

	metrics.RecordRequest("query_radius", "success", 0.05)
	metrics.RecordRequest("query_radius", "success", 0.03)
	metrics.RecordRequest("query_radius", "error", 0.1)

	successLabels := &MetricLabels{Operation: "query_radius", Status: "success"}
	errorLabels := &MetricLabels{Operation: "query_radius", Status: "error"}

	if metrics.RequestsTotal.Get(successLabels) != 2 {
		t.Errorf("Expected 2 success requests, got %d", metrics.RequestsTotal.Get(successLabels))
	}
	if metrics.RequestsTotal.Get(errorLabels) != 1 {
		t.Errorf("Expected 1 error request, got %d", metrics.RequestsTotal.Get(errorLabels))
	}
}

func TestSDKMetrics_ConnectionMetrics(t *testing.T) {
	metrics := NewSDKMetrics()

	metrics.RecordConnectionOpened()
	metrics.RecordConnectionOpened()
	if metrics.ConnectionsActive.Get() != 2 {
		t.Errorf("Expected 2 connections, got %d", metrics.ConnectionsActive.Get())
	}

	metrics.RecordConnectionClosed()
	if metrics.ConnectionsActive.Get() != 1 {
		t.Errorf("Expected 1 connection, got %d", metrics.ConnectionsActive.Get())
	}
}

func TestSDKMetrics_RetryMetrics(t *testing.T) {
	metrics := NewSDKMetrics()

	metrics.RecordRetry()
	metrics.RecordRetry()
	metrics.RecordRetry()

	if metrics.RetriesTotal.Get(nil) != 3 {
		t.Errorf("Expected 3 retries, got %d", metrics.RetriesTotal.Get(nil))
	}

	metrics.RecordRetryExhausted()
	if metrics.RetryExhaustedTotal.Get(nil) != 1 {
		t.Errorf("Expected 1 retry exhausted, got %d", metrics.RetryExhaustedTotal.Get(nil))
	}

	metrics.RecordPrimaryDiscovery()
	metrics.RecordPrimaryDiscovery()
	if metrics.PrimaryDiscoveriesTotal.Get(nil) != 2 {
		t.Errorf("Expected 2 primary discoveries, got %d", metrics.PrimaryDiscoveriesTotal.Get(nil))
	}
}

func TestSDKMetrics_PrometheusExport(t *testing.T) {
	metrics := NewSDKMetrics()
	metrics.RecordRequest("insert", "success", 0.01)
	metrics.RecordConnectionOpened()
	metrics.RecordRetry()
	metrics.RecordRetryExhausted()
	metrics.RecordPrimaryDiscovery()

	output := metrics.ToPrometheus()

	expectedMetrics := []string{
		"archerdb_client_requests_total",
		"archerdb_client_connections_active",
		"archerdb_client_retries_total",
		"archerdb_client_retry_exhausted_total",
		"archerdb_client_primary_discoveries_total",
		"# HELP",
		"# TYPE",
	}

	for _, metric := range expectedMetrics {
		if !strings.Contains(output, metric) {
			t.Errorf("Expected output to contain %q", metric)
		}
	}
}

func TestGetMetrics_Singleton(t *testing.T) {
	ResetMetrics()
	metrics1 := GetMetrics()
	metrics2 := GetMetrics()

	if metrics1 != metrics2 {
		t.Error("Expected singleton metrics instance")
	}
}

// ============================================================================
// HealthTracker Tests
// ============================================================================

func TestHealthTracker_InitialState(t *testing.T) {
	tracker := NewHealthTracker(3)
	status := tracker.GetStatus()

	if status.Healthy {
		t.Error("Expected unhealthy initial state")
	}
	if status.State != Disconnected {
		t.Errorf("Expected Disconnected state, got %s", status.State)
	}
}

func TestHealthTracker_SuccessTransitions(t *testing.T) {
	tracker := NewHealthTracker(3)

	tracker.RecordSuccess()
	status := tracker.GetStatus()

	if !status.Healthy {
		t.Error("Expected healthy after success")
	}
	if status.State != Connected {
		t.Errorf("Expected Connected state, got %s", status.State)
	}
	if status.LastSuccessfulOpNs <= 0 {
		t.Error("Expected LastSuccessfulOpNs to be set")
	}
}

func TestHealthTracker_FailureThreshold(t *testing.T) {
	tracker := NewHealthTracker(3)

	// Start connected
	tracker.RecordSuccess()
	if !tracker.GetStatus().Healthy {
		t.Error("Expected healthy after success")
	}

	// First two failures: still healthy (below threshold)
	tracker.RecordFailure()
	if !tracker.GetStatus().Healthy {
		t.Error("Expected still healthy after 1 failure")
	}
	tracker.RecordFailure()
	if !tracker.GetStatus().Healthy {
		t.Error("Expected still healthy after 2 failures")
	}

	// Third failure: crosses threshold
	tracker.RecordFailure()
	if tracker.GetStatus().Healthy {
		t.Error("Expected unhealthy after 3 failures")
	}
	if tracker.GetStatus().State != Failed {
		t.Errorf("Expected Failed state, got %s", tracker.GetStatus().State)
	}
}

func TestHealthTracker_Recovery(t *testing.T) {
	tracker := NewHealthTracker(2)

	// Mark as failed
	tracker.RecordFailure()
	tracker.RecordFailure()
	if tracker.GetStatus().State != Failed {
		t.Errorf("Expected Failed state, got %s", tracker.GetStatus().State)
	}

	// Recovery via success
	tracker.RecordSuccess()
	if !tracker.GetStatus().Healthy {
		t.Error("Expected healthy after recovery")
	}
	if tracker.GetStatus().State != Connected {
		t.Errorf("Expected Connected state, got %s", tracker.GetStatus().State)
	}
	if tracker.GetStatus().ConsecutiveFailures != 0 {
		t.Errorf("Expected 0 consecutive failures, got %d", tracker.GetStatus().ConsecutiveFailures)
	}
}

func TestHealthTracker_ToMap(t *testing.T) {
	tracker := NewHealthTracker(3)
	tracker.RecordSuccess()

	m := tracker.ToMap()
	if m["healthy"] != true {
		t.Error("Expected healthy=true")
	}
	if m["state"] != string(Connected) {
		t.Errorf("Expected state=connected, got %v", m["state"])
	}
	if m["consecutive_failures"] != 0 {
		t.Errorf("Expected consecutive_failures=0, got %v", m["consecutive_failures"])
	}
}

func TestHealthTracker_StateTransitions(t *testing.T) {
	tracker := NewHealthTracker(3)

	tracker.SetConnecting()
	if tracker.GetStatus().State != Connecting {
		t.Errorf("Expected Connecting state, got %s", tracker.GetStatus().State)
	}

	tracker.SetReconnecting()
	if tracker.GetStatus().State != Reconnecting {
		t.Errorf("Expected Reconnecting state, got %s", tracker.GetStatus().State)
	}

	tracker.SetDisconnected()
	if tracker.GetStatus().State != Disconnected {
		t.Errorf("Expected Disconnected state, got %s", tracker.GetStatus().State)
	}
}

// ============================================================================
// RequestTimer Tests
// ============================================================================

func TestRequestTimer_Success(t *testing.T) {
	ResetMetrics()
	metrics := GetMetrics()
	timer := NewRequestTimer("test_op", metrics)

	timer.Success()

	labels := &MetricLabels{Operation: "test_op", Status: "success"}
	if metrics.RequestsTotal.Get(labels) != 1 {
		t.Errorf("Expected 1 request, got %d", metrics.RequestsTotal.Get(labels))
	}
}

func TestRequestTimer_Error(t *testing.T) {
	ResetMetrics()
	metrics := GetMetrics()
	timer := NewRequestTimer("test_op", metrics)

	timer.Error()

	labels := &MetricLabels{Operation: "test_op", Status: "error"}
	if metrics.RequestsTotal.Get(labels) != 1 {
		t.Errorf("Expected 1 request, got %d", metrics.RequestsTotal.Get(labels))
	}
}

func TestRequestTimer_Duration(t *testing.T) {
	ResetMetrics()
	metrics := GetMetrics()
	timer := NewRequestTimer("slow_op", metrics)

	// Simulate some work
	time.Sleep(10 * time.Millisecond)

	timer.Success()

	labels := &MetricLabels{Operation: "slow_op"}
	if metrics.RequestDuration.GetSum(labels) < 0.01 {
		t.Errorf("Expected duration >= 10ms, got %f", metrics.RequestDuration.GetSum(labels))
	}
}

func TestRequestTimer_WithHealth(t *testing.T) {
	ResetMetrics()
	metrics := GetMetrics()
	health := NewHealthTracker(3)

	timer := NewRequestTimer("test_op", metrics, WithHealthTracker(health))
	timer.Success()

	if !health.GetStatus().Healthy {
		t.Error("Expected healthy after success")
	}

	timer2 := NewRequestTimer("test_op2", metrics, WithHealthTracker(health))
	timer2.Error()

	if health.GetStatus().ConsecutiveFailures != 1 {
		t.Errorf("Expected 1 consecutive failure, got %d", health.GetStatus().ConsecutiveFailures)
	}
}
