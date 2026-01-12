// Package observability provides logging, metrics, and health check infrastructure
// for the ArcherDB Go SDK per client-sdk/spec.md and client-retry/spec.md.
//
// Logging:
//   - DEBUG: Connection state changes, request/response details
//   - INFO: Successful connection, session registration
//   - WARN: Reconnection, view change handling, retries
//   - ERROR: Connection failures, unrecoverable errors
//
// Metrics:
//   - archerdb_client_requests_total{operation, status}
//   - archerdb_client_request_duration_seconds{operation}
//   - archerdb_client_connections_active
//   - archerdb_client_reconnections_total
//   - archerdb_client_session_renewals_total
//   - archerdb_client_retries_total (per client-retry/spec.md)
//   - archerdb_client_retry_exhausted_total (per client-retry/spec.md)
//   - archerdb_client_primary_discoveries_total (per client-retry/spec.md)
//
// Health Check:
//   - Connection status monitoring
//   - Last successful operation timestamp
package observability

import (
	"fmt"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ============================================================================
// Logging Infrastructure
// ============================================================================

// LogLevel represents the severity of a log message.
type LogLevel int

const (
	// DEBUG for connection state changes, request/response details.
	DEBUG LogLevel = 10
	// INFO for successful connection, session registration.
	INFO LogLevel = 20
	// WARN for reconnection, view change handling, retries.
	WARN LogLevel = 30
	// ERROR for connection failures, unrecoverable errors.
	ERROR LogLevel = 40
)

// Logger is the interface for SDK logging.
// Implement this interface to integrate with your application's logging.
type Logger interface {
	// Debug logs a debug message (connection state, request/response details).
	Debug(msg string, keysAndValues ...interface{})
	// Info logs an info message (successful connection, session registration).
	Info(msg string, keysAndValues ...interface{})
	// Warn logs a warning message (reconnection, view change, retries).
	Warn(msg string, keysAndValues ...interface{})
	// Error logs an error message (connection failures, unrecoverable errors).
	Error(msg string, keysAndValues ...interface{})
}

// StandardLogger implements Logger using the standard log package.
type StandardLogger struct {
	name  string
	level LogLevel
}

// NewStandardLogger creates a new StandardLogger.
func NewStandardLogger(name string, level LogLevel) *StandardLogger {
	return &StandardLogger{name: name, level: level}
}

func (l *StandardLogger) formatMessage(level, msg string, keysAndValues ...interface{}) string {
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("[%s] %s: %s", l.name, level, msg))
	if len(keysAndValues) > 0 {
		sb.WriteString(" ")
		for i := 0; i < len(keysAndValues); i += 2 {
			if i > 0 {
				sb.WriteString(", ")
			}
			if i+1 < len(keysAndValues) {
				sb.WriteString(fmt.Sprintf("%v=%v", keysAndValues[i], keysAndValues[i+1]))
			} else {
				sb.WriteString(fmt.Sprintf("%v", keysAndValues[i]))
			}
		}
	}
	return sb.String()
}

// Debug implements Logger.
func (l *StandardLogger) Debug(msg string, keysAndValues ...interface{}) {
	if l.level <= DEBUG {
		log.Println(l.formatMessage("DEBUG", msg, keysAndValues...))
	}
}

// Info implements Logger.
func (l *StandardLogger) Info(msg string, keysAndValues ...interface{}) {
	if l.level <= INFO {
		log.Println(l.formatMessage("INFO", msg, keysAndValues...))
	}
}

// Warn implements Logger.
func (l *StandardLogger) Warn(msg string, keysAndValues ...interface{}) {
	if l.level <= WARN {
		log.Println(l.formatMessage("WARN", msg, keysAndValues...))
	}
}

// Error implements Logger.
func (l *StandardLogger) Error(msg string, keysAndValues ...interface{}) {
	if l.level <= ERROR {
		log.Println(l.formatMessage("ERROR", msg, keysAndValues...))
	}
}

// NullLogger discards all log messages (for testing or disabled logging).
type NullLogger struct{}

// Debug implements Logger.
func (l NullLogger) Debug(msg string, keysAndValues ...interface{}) {}

// Info implements Logger.
func (l NullLogger) Info(msg string, keysAndValues ...interface{}) {}

// Warn implements Logger.
func (l NullLogger) Warn(msg string, keysAndValues ...interface{}) {}

// Error implements Logger.
func (l NullLogger) Error(msg string, keysAndValues ...interface{}) {}

var (
	defaultLogger Logger = NullLogger{}
	loggerMu      sync.RWMutex
)

// SetLogger sets the default SDK logger.
func SetLogger(logger Logger) {
	loggerMu.Lock()
	defer loggerMu.Unlock()
	defaultLogger = logger
}

// GetLogger returns the current SDK logger.
func GetLogger() Logger {
	loggerMu.RLock()
	defer loggerMu.RUnlock()
	return defaultLogger
}

// ============================================================================
// Metrics Infrastructure
// ============================================================================

// MetricLabels holds labels for a metric.
type MetricLabels struct {
	Operation string
	Status    string
}

// String returns a string key for the labels.
func (m MetricLabels) String() string {
	return fmt.Sprintf("%s:%s", m.Operation, m.Status)
}

// Counter is a thread-safe counter metric.
type Counter struct {
	name        string
	description string
	values      sync.Map // map[string]*int64
}

// NewCounter creates a new Counter.
func NewCounter(name, description string) *Counter {
	return &Counter{name: name, description: description}
}

// Name returns the metric name.
func (c *Counter) Name() string { return c.name }

// Description returns the metric description.
func (c *Counter) Description() string { return c.description }

// Inc increments the counter by 1.
func (c *Counter) Inc(labels *MetricLabels) {
	c.Add(labels, 1)
}

// Add adds value to the counter.
func (c *Counter) Add(labels *MetricLabels, value int64) {
	key := ""
	if labels != nil {
		key = labels.String()
	}
	actual, _ := c.values.LoadOrStore(key, new(int64))
	atomic.AddInt64(actual.(*int64), value)
}

// Get returns the current value.
func (c *Counter) Get(labels *MetricLabels) int64 {
	key := ""
	if labels != nil {
		key = labels.String()
	}
	if val, ok := c.values.Load(key); ok {
		return atomic.LoadInt64(val.(*int64))
	}
	return 0
}

// GetAll returns all values with their labels.
type MetricValue struct {
	Labels MetricLabels
	Value  int64
}

// GetAll returns all values with their labels.
func (c *Counter) GetAll() []MetricValue {
	var result []MetricValue
	c.values.Range(func(key, value interface{}) bool {
		keyStr := key.(string)
		parts := strings.SplitN(keyStr, ":", 2)
		labels := MetricLabels{}
		if len(parts) >= 1 && parts[0] != "" {
			labels.Operation = parts[0]
		}
		if len(parts) >= 2 && parts[1] != "" {
			labels.Status = parts[1]
		}
		result = append(result, MetricValue{
			Labels: labels,
			Value:  atomic.LoadInt64(value.(*int64)),
		})
		return true
	})
	return result
}

// Reset clears all values.
func (c *Counter) Reset() {
	c.values = sync.Map{}
}

// Gauge is a thread-safe gauge metric.
type Gauge struct {
	name        string
	description string
	value       int64
}

// NewGauge creates a new Gauge.
func NewGauge(name, description string) *Gauge {
	return &Gauge{name: name, description: description}
}

// Name returns the metric name.
func (g *Gauge) Name() string { return g.name }

// Description returns the metric description.
func (g *Gauge) Description() string { return g.description }

// Set sets the gauge value.
func (g *Gauge) Set(value int64) {
	atomic.StoreInt64(&g.value, value)
}

// Inc increments the gauge by 1.
func (g *Gauge) Inc() {
	atomic.AddInt64(&g.value, 1)
}

// Dec decrements the gauge by 1.
func (g *Gauge) Dec() {
	atomic.AddInt64(&g.value, -1)
}

// Add adds value to the gauge.
func (g *Gauge) Add(value int64) {
	atomic.AddInt64(&g.value, value)
}

// Get returns the current value.
func (g *Gauge) Get() int64 {
	return atomic.LoadInt64(&g.value)
}

// Reset sets the gauge to zero.
func (g *Gauge) Reset() {
	atomic.StoreInt64(&g.value, 0)
}

// Histogram is a thread-safe histogram metric for request durations.
type Histogram struct {
	name        string
	description string
	count       int64
	sum         int64 // stored as nanoseconds for precision
	mu          sync.Mutex
	observations map[string]*histogramData
}

type histogramData struct {
	count int64
	sum   int64
}

// NewHistogram creates a new Histogram.
func NewHistogram(name, description string) *Histogram {
	return &Histogram{
		name:        name,
		description: description,
		observations: make(map[string]*histogramData),
	}
}

// Name returns the metric name.
func (h *Histogram) Name() string { return h.name }

// Description returns the metric description.
func (h *Histogram) Description() string { return h.description }

// Observe records an observation in seconds.
func (h *Histogram) Observe(seconds float64, labels *MetricLabels) {
	nanos := int64(seconds * 1e9)
	h.mu.Lock()
	defer h.mu.Unlock()

	key := ""
	if labels != nil {
		key = labels.Operation
	}

	data, ok := h.observations[key]
	if !ok {
		data = &histogramData{}
		h.observations[key] = data
	}
	data.count++
	data.sum += nanos

	// Also update global totals
	h.count++
	h.sum += nanos
}

// GetCount returns the total observation count.
func (h *Histogram) GetCount(labels *MetricLabels) int64 {
	h.mu.Lock()
	defer h.mu.Unlock()

	if labels == nil {
		return h.count
	}

	if data, ok := h.observations[labels.Operation]; ok {
		return data.count
	}
	return 0
}

// GetSum returns the sum of all observations in seconds.
func (h *Histogram) GetSum(labels *MetricLabels) float64 {
	h.mu.Lock()
	defer h.mu.Unlock()

	if labels == nil {
		return float64(h.sum) / 1e9
	}

	if data, ok := h.observations[labels.Operation]; ok {
		return float64(data.sum) / 1e9
	}
	return 0
}

// Reset clears all observations.
func (h *Histogram) Reset() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.count = 0
	h.sum = 0
	h.observations = make(map[string]*histogramData)
}

// SDKMetrics is the metrics registry for the SDK.
// Metrics exposed per client-sdk/spec.md and client-retry/spec.md.
type SDKMetrics struct {
	// Request metrics
	RequestsTotal   *Counter
	RequestDuration *Histogram

	// Connection metrics
	ConnectionsActive    *Gauge
	ReconnectionsTotal   *Counter
	SessionRenewalsTotal *Counter

	// Retry metrics (per client-retry/spec.md)
	RetriesTotal           *Counter
	RetryExhaustedTotal    *Counter
	PrimaryDiscoveriesTotal *Counter
}

// NewSDKMetrics creates a new SDKMetrics registry.
func NewSDKMetrics() *SDKMetrics {
	return &SDKMetrics{
		RequestsTotal: NewCounter(
			"archerdb_client_requests_total",
			"Total number of requests by operation and status",
		),
		RequestDuration: NewHistogram(
			"archerdb_client_request_duration_seconds",
			"Request duration in seconds by operation",
		),
		ConnectionsActive: NewGauge(
			"archerdb_client_connections_active",
			"Number of active connections",
		),
		ReconnectionsTotal: NewCounter(
			"archerdb_client_reconnections_total",
			"Total number of reconnection attempts",
		),
		SessionRenewalsTotal: NewCounter(
			"archerdb_client_session_renewals_total",
			"Total number of session renewals",
		),
		RetriesTotal: NewCounter(
			"archerdb_client_retries_total",
			"Total number of retry attempts",
		),
		RetryExhaustedTotal: NewCounter(
			"archerdb_client_retry_exhausted_total",
			"Total number of operations that exhausted all retry attempts",
		),
		PrimaryDiscoveriesTotal: NewCounter(
			"archerdb_client_primary_discoveries_total",
			"Total number of primary discovery events",
		),
	}
}

// RecordRequest records a completed request.
func (m *SDKMetrics) RecordRequest(operation, status string, durationSeconds float64) {
	labels := &MetricLabels{Operation: operation, Status: status}
	m.RequestsTotal.Inc(labels)
	m.RequestDuration.Observe(durationSeconds, &MetricLabels{Operation: operation})
}

// RecordConnectionOpened records a new connection being opened.
func (m *SDKMetrics) RecordConnectionOpened() {
	m.ConnectionsActive.Inc()
}

// RecordConnectionClosed records a connection being closed.
func (m *SDKMetrics) RecordConnectionClosed() {
	m.ConnectionsActive.Dec()
}

// RecordReconnection records a reconnection attempt.
func (m *SDKMetrics) RecordReconnection() {
	m.ReconnectionsTotal.Inc(nil)
}

// RecordSessionRenewal records a session renewal.
func (m *SDKMetrics) RecordSessionRenewal() {
	m.SessionRenewalsTotal.Inc(nil)
}

// RecordRetry records a retry attempt (per client-retry/spec.md).
func (m *SDKMetrics) RecordRetry() {
	m.RetriesTotal.Inc(nil)
}

// RecordRetryExhausted records that all retry attempts were exhausted.
func (m *SDKMetrics) RecordRetryExhausted() {
	m.RetryExhaustedTotal.Inc(nil)
}

// RecordPrimaryDiscovery records a primary discovery event.
func (m *SDKMetrics) RecordPrimaryDiscovery() {
	m.PrimaryDiscoveriesTotal.Inc(nil)
}

// ToPrometheus exports metrics in Prometheus text format.
func (m *SDKMetrics) ToPrometheus() string {
	var sb strings.Builder

	// requestsTotal
	sb.WriteString(fmt.Sprintf("# HELP %s %s\n", m.RequestsTotal.Name(), m.RequestsTotal.Description()))
	sb.WriteString(fmt.Sprintf("# TYPE %s counter\n", m.RequestsTotal.Name()))
	for _, mv := range m.RequestsTotal.GetAll() {
		var labelParts []string
		if mv.Labels.Operation != "" {
			labelParts = append(labelParts, fmt.Sprintf(`operation="%s"`, mv.Labels.Operation))
		}
		if mv.Labels.Status != "" {
			labelParts = append(labelParts, fmt.Sprintf(`status="%s"`, mv.Labels.Status))
		}
		if len(labelParts) > 0 {
			sb.WriteString(fmt.Sprintf("%s{%s} %d\n", m.RequestsTotal.Name(), strings.Join(labelParts, ","), mv.Value))
		} else {
			sb.WriteString(fmt.Sprintf("%s %d\n", m.RequestsTotal.Name(), mv.Value))
		}
	}

	// requestDuration histogram
	sb.WriteString(fmt.Sprintf("# HELP %s %s\n", m.RequestDuration.Name(), m.RequestDuration.Description()))
	sb.WriteString(fmt.Sprintf("# TYPE %s histogram\n", m.RequestDuration.Name()))
	sb.WriteString(fmt.Sprintf("%s_count %d\n", m.RequestDuration.Name(), m.RequestDuration.GetCount(nil)))
	sb.WriteString(fmt.Sprintf("%s_sum %f\n", m.RequestDuration.Name(), m.RequestDuration.GetSum(nil)))

	// connectionsActive
	sb.WriteString(fmt.Sprintf("# HELP %s %s\n", m.ConnectionsActive.Name(), m.ConnectionsActive.Description()))
	sb.WriteString(fmt.Sprintf("# TYPE %s gauge\n", m.ConnectionsActive.Name()))
	sb.WriteString(fmt.Sprintf("%s %d\n", m.ConnectionsActive.Name(), m.ConnectionsActive.Get()))

	// reconnectionsTotal
	sb.WriteString(fmt.Sprintf("# HELP %s %s\n", m.ReconnectionsTotal.Name(), m.ReconnectionsTotal.Description()))
	sb.WriteString(fmt.Sprintf("# TYPE %s counter\n", m.ReconnectionsTotal.Name()))
	sb.WriteString(fmt.Sprintf("%s %d\n", m.ReconnectionsTotal.Name(), m.ReconnectionsTotal.Get(nil)))

	// sessionRenewalsTotal
	sb.WriteString(fmt.Sprintf("# HELP %s %s\n", m.SessionRenewalsTotal.Name(), m.SessionRenewalsTotal.Description()))
	sb.WriteString(fmt.Sprintf("# TYPE %s counter\n", m.SessionRenewalsTotal.Name()))
	sb.WriteString(fmt.Sprintf("%s %d\n", m.SessionRenewalsTotal.Name(), m.SessionRenewalsTotal.Get(nil)))

	// Retry metrics (per client-retry/spec.md)
	sb.WriteString(fmt.Sprintf("# HELP %s %s\n", m.RetriesTotal.Name(), m.RetriesTotal.Description()))
	sb.WriteString(fmt.Sprintf("# TYPE %s counter\n", m.RetriesTotal.Name()))
	sb.WriteString(fmt.Sprintf("%s %d\n", m.RetriesTotal.Name(), m.RetriesTotal.Get(nil)))

	sb.WriteString(fmt.Sprintf("# HELP %s %s\n", m.RetryExhaustedTotal.Name(), m.RetryExhaustedTotal.Description()))
	sb.WriteString(fmt.Sprintf("# TYPE %s counter\n", m.RetryExhaustedTotal.Name()))
	sb.WriteString(fmt.Sprintf("%s %d\n", m.RetryExhaustedTotal.Name(), m.RetryExhaustedTotal.Get(nil)))

	sb.WriteString(fmt.Sprintf("# HELP %s %s\n", m.PrimaryDiscoveriesTotal.Name(), m.PrimaryDiscoveriesTotal.Description()))
	sb.WriteString(fmt.Sprintf("# TYPE %s counter\n", m.PrimaryDiscoveriesTotal.Name()))
	sb.WriteString(fmt.Sprintf("%s %d\n", m.PrimaryDiscoveriesTotal.Name(), m.PrimaryDiscoveriesTotal.Get(nil)))

	return sb.String()
}

// Reset resets all metrics (for testing).
func (m *SDKMetrics) Reset() {
	m.RequestsTotal.Reset()
	m.RequestDuration.Reset()
	m.ConnectionsActive.Reset()
	m.ReconnectionsTotal.Reset()
	m.SessionRenewalsTotal.Reset()
	m.RetriesTotal.Reset()
	m.RetryExhaustedTotal.Reset()
	m.PrimaryDiscoveriesTotal.Reset()
}

var (
	globalMetrics *SDKMetrics
	metricsMu     sync.Mutex
)

// GetMetrics returns the global metrics registry.
func GetMetrics() *SDKMetrics {
	metricsMu.Lock()
	defer metricsMu.Unlock()
	if globalMetrics == nil {
		globalMetrics = NewSDKMetrics()
	}
	return globalMetrics
}

// ResetMetrics resets the global metrics registry (for testing).
func ResetMetrics() {
	metricsMu.Lock()
	defer metricsMu.Unlock()
	globalMetrics = NewSDKMetrics()
}

// ============================================================================
// Health Check Infrastructure
// ============================================================================

// ConnectionState represents the connection health state.
type ConnectionState string

const (
	// Connected indicates the client is connected and healthy.
	Connected ConnectionState = "connected"
	// Disconnected indicates the client is not connected.
	Disconnected ConnectionState = "disconnected"
	// Connecting indicates initial connection is in progress.
	Connecting ConnectionState = "connecting"
	// Reconnecting indicates reconnection is in progress.
	Reconnecting ConnectionState = "reconnecting"
	// Failed indicates connection has failed.
	Failed ConnectionState = "failed"
)

// HealthStatus represents the health check result.
type HealthStatus struct {
	// Healthy indicates overall health status.
	Healthy bool
	// State is the current connection state.
	State ConnectionState
	// LastSuccessfulOpNs is the timestamp of last successful operation (nanoseconds since epoch).
	LastSuccessfulOpNs int64
	// ConsecutiveFailures is the number of consecutive failures.
	ConsecutiveFailures int
	// Details provides additional information about health status.
	Details string
}

// HealthTracker tracks connection health status.
type HealthTracker struct {
	state               ConnectionState
	lastSuccessfulOpNs  int64
	consecutiveFailures int
	failureThreshold    int
	mu                  sync.Mutex
}

// NewHealthTracker creates a new HealthTracker.
func NewHealthTracker(failureThreshold int) *HealthTracker {
	if failureThreshold <= 0 {
		failureThreshold = 3
	}
	return &HealthTracker{
		state:            Disconnected,
		failureThreshold: failureThreshold,
	}
}

// RecordSuccess records a successful operation.
func (h *HealthTracker) RecordSuccess() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.lastSuccessfulOpNs = time.Now().UnixNano()
	h.consecutiveFailures = 0
	h.state = Connected
}

// RecordFailure records a failed operation.
func (h *HealthTracker) RecordFailure() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.consecutiveFailures++
	if h.consecutiveFailures >= h.failureThreshold {
		h.state = Failed
	}
}

// SetConnecting marks as currently connecting.
func (h *HealthTracker) SetConnecting() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.state = Connecting
}

// SetReconnecting marks as currently reconnecting.
func (h *HealthTracker) SetReconnecting() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.state = Reconnecting
}

// SetDisconnected marks as disconnected.
func (h *HealthTracker) SetDisconnected() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.state = Disconnected
}

// GetStatus returns the current health status.
func (h *HealthTracker) GetStatus() HealthStatus {
	h.mu.Lock()
	defer h.mu.Unlock()

	healthy := h.state == Connected && h.consecutiveFailures < h.failureThreshold

	var details string
	switch h.state {
	case Failed:
		details = fmt.Sprintf("Connection failed after %d consecutive failures", h.consecutiveFailures)
	case Reconnecting:
		details = "Attempting to reconnect"
	case Connecting:
		details = "Initial connection in progress"
	case Disconnected:
		details = "Client is disconnected"
	case Connected:
		details = ""
	}

	return HealthStatus{
		Healthy:             healthy,
		State:               h.state,
		LastSuccessfulOpNs:  h.lastSuccessfulOpNs,
		ConsecutiveFailures: h.consecutiveFailures,
		Details:             details,
	}
}

// ToMap returns the health status as a map (for JSON serialization).
func (h *HealthTracker) ToMap() map[string]interface{} {
	status := h.GetStatus()
	return map[string]interface{}{
		"healthy":                    status.Healthy,
		"state":                      string(status.State),
		"last_successful_operation_ns": status.LastSuccessfulOpNs,
		"consecutive_failures":       status.ConsecutiveFailures,
		"details":                    status.Details,
	}
}

// ============================================================================
// Request Timer
// ============================================================================

// RequestTimer measures operation duration and records metrics.
type RequestTimer struct {
	operation string
	metrics   *SDKMetrics
	logger    Logger
	health    *HealthTracker
	startTime time.Time
	status    string
}

// NewRequestTimer creates a new RequestTimer.
func NewRequestTimer(operation string, metrics *SDKMetrics, opts ...RequestTimerOption) *RequestTimer {
	t := &RequestTimer{
		operation: operation,
		metrics:   metrics,
		startTime: time.Now(),
		status:    "success",
	}
	for _, opt := range opts {
		opt(t)
	}
	if t.logger != nil {
		t.logger.Debug("Starting operation", "operation", operation)
	}
	return t
}

// RequestTimerOption configures a RequestTimer.
type RequestTimerOption func(*RequestTimer)

// WithLogger sets the logger for the RequestTimer.
func WithLogger(logger Logger) RequestTimerOption {
	return func(t *RequestTimer) {
		t.logger = logger
	}
}

// WithHealthTracker sets the health tracker for the RequestTimer.
func WithHealthTracker(health *HealthTracker) RequestTimerOption {
	return func(t *RequestTimer) {
		t.health = health
	}
}

// Success marks the operation as successful and records metrics.
func (t *RequestTimer) Success() {
	t.status = "success"
	t.finish()
}

// Error marks the operation as failed and records metrics.
func (t *RequestTimer) Error() {
	t.status = "error"
	t.finish()
}

// SetStatus overrides the status (e.g., for partial success).
func (t *RequestTimer) SetStatus(status string) {
	t.status = status
}

func (t *RequestTimer) finish() {
	duration := time.Since(t.startTime)
	durationSeconds := duration.Seconds()

	t.metrics.RecordRequest(t.operation, t.status, durationSeconds)

	if t.status == "error" {
		if t.logger != nil {
			t.logger.Error("Operation failed", "operation", t.operation, "duration_ms", duration.Milliseconds())
		}
		if t.health != nil {
			t.health.RecordFailure()
		}
	} else {
		if t.logger != nil {
			t.logger.Debug("Operation completed", "operation", t.operation, "duration_ms", duration.Milliseconds())
		}
		if t.health != nil {
			t.health.RecordSuccess()
		}
	}
}
