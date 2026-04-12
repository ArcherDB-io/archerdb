// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
// Package circuitbreaker provides per-replica circuit breaker for failure isolation.
//
// This package implements the circuit breaker pattern from client-retry/spec.md:
// - Opens when: 50% failure rate in 10s window AND >= 10 requests
// - Stays open for 30 seconds before transitioning to half-open
// - Half-open allows 5 test requests before deciding to close or re-open
// - Per-replica scope (not global) to allow trying other replicas
package circuitbreaker

import (
	"fmt"
	"sync"
	"time"
)

// State represents the circuit breaker state.
type State int

const (
	// Closed allows all requests through, monitoring for failures.
	Closed State = iota
	// Open rejects all requests immediately.
	Open
	// HalfOpen allows limited test requests to probe recovery.
	HalfOpen
)

// String returns the state name.
func (s State) String() string {
	switch s {
	case Closed:
		return "CLOSED"
	case Open:
		return "OPEN"
	case HalfOpen:
		return "HALF_OPEN"
	default:
		return "UNKNOWN"
	}
}

// Config holds circuit breaker configuration options.
type Config struct {
	// FailureThreshold is the failure rate to open circuit (default: 0.5 = 50%).
	FailureThreshold float64

	// MinRequests is the minimum requests in window before circuit can open (default: 10).
	MinRequests int

	// WindowDurationMs is the sliding window duration in milliseconds (default: 10000).
	WindowDurationMs int

	// OpenDurationMs is how long circuit stays open before transitioning to half-open (default: 30000).
	OpenDurationMs int

	// HalfOpenRequests is the number of test requests allowed in half-open state (default: 5).
	HalfOpenRequests int
}

// DefaultConfig returns the default circuit breaker configuration per spec.
func DefaultConfig() Config {
	return Config{
		FailureThreshold: 0.5,
		MinRequests:      10,
		WindowDurationMs: 10000,
		OpenDurationMs:   30000,
		HalfOpenRequests: 5,
	}
}

// ErrCircuitOpen is returned when the circuit breaker is open.
type ErrCircuitOpen struct {
	CircuitName  string
	CircuitState State
}

func (e ErrCircuitOpen) Error() string {
	return fmt.Sprintf("circuit breaker '%s' is %s - request rejected", e.CircuitName, e.CircuitState)
}

// CircuitBreaker provides per-replica circuit breaker for failure isolation.
//
// Per client-retry/spec.md:
// - Opens when: 50% failure rate in 10s window AND >= 10 requests
// - Stays open for 30 seconds before transitioning to half-open
// - Half-open allows 5 test requests before deciding to close or re-open
// - Per-replica scope (not global) to allow trying other replicas
//
// Thread-safe implementation.
type CircuitBreaker struct {
	name   string
	config Config

	mu       sync.Mutex
	state    State
	openedAt time.Time

	// Sliding window counters
	totalRequests   int
	failedRequests  int
	windowStartTime time.Time

	// Half-open tracking
	halfOpenSuccesses int
	halfOpenFailures  int
	halfOpenTotal     int

	// Metrics
	stateChanges     int
	rejectedRequests int
}

// New creates a new CircuitBreaker with the given name and default config.
func New(name string) *CircuitBreaker {
	return NewWithConfig(name, DefaultConfig())
}

// NewWithConfig creates a new CircuitBreaker with custom configuration.
func NewWithConfig(name string, config Config) *CircuitBreaker {
	return &CircuitBreaker{
		name:            name,
		config:          config,
		state:           Closed,
		windowStartTime: time.Now(),
	}
}

// Name returns the circuit breaker name.
func (cb *CircuitBreaker) Name() string {
	return cb.name
}

// State returns the current circuit state, checking for automatic transitions.
func (cb *CircuitBreaker) State() State {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	if cb.state == Open {
		elapsed := time.Since(cb.openedAt)
		if elapsed >= time.Duration(cb.config.OpenDurationMs)*time.Millisecond {
			cb.transitionTo(HalfOpen)
			cb.resetHalfOpenCounters()
		}
	}
	return cb.state
}

// AllowRequest checks if a request is allowed through.
func (cb *CircuitBreaker) AllowRequest() bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	switch cb.state {
	case Closed:
		return true

	case Open:
		elapsed := time.Since(cb.openedAt)
		if elapsed >= time.Duration(cb.config.OpenDurationMs)*time.Millisecond {
			cb.transitionTo(HalfOpen)
			cb.resetHalfOpenCounters()
			return cb.allowHalfOpenRequest()
		}
		cb.rejectedRequests++
		return false

	case HalfOpen:
		return cb.allowHalfOpenRequest()
	}

	return false
}

func (cb *CircuitBreaker) allowHalfOpenRequest() bool {
	if cb.halfOpenTotal >= cb.config.HalfOpenRequests {
		cb.rejectedRequests++
		return false
	}
	cb.halfOpenTotal++
	return true
}

// RecordSuccess records a successful request.
func (cb *CircuitBreaker) RecordSuccess() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	switch cb.state {
	case Closed:
		cb.recordInWindow(false)

	case HalfOpen:
		cb.halfOpenSuccesses++
		if cb.halfOpenSuccesses >= cb.config.HalfOpenRequests {
			cb.transitionTo(Closed)
			cb.resetCounters()
		}
	}
}

// RecordFailure records a failed request.
func (cb *CircuitBreaker) RecordFailure() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	switch cb.state {
	case Closed:
		cb.recordInWindow(true)
		cb.checkThreshold()

	case HalfOpen:
		cb.halfOpenFailures++
		cb.transitionTo(Open)
	}
}

func (cb *CircuitBreaker) recordInWindow(failed bool) {
	now := time.Now()
	elapsed := now.Sub(cb.windowStartTime)

	// Reset window if expired
	if elapsed >= time.Duration(cb.config.WindowDurationMs)*time.Millisecond {
		cb.totalRequests = 0
		cb.failedRequests = 0
		cb.windowStartTime = now
	}

	cb.totalRequests++
	if failed {
		cb.failedRequests++
	}
}

func (cb *CircuitBreaker) checkThreshold() {
	if cb.totalRequests < cb.config.MinRequests {
		return
	}

	failureRate := float64(cb.failedRequests) / float64(cb.totalRequests)
	if failureRate >= cb.config.FailureThreshold {
		cb.transitionTo(Open)
	}
}

func (cb *CircuitBreaker) transitionTo(newState State) {
	if cb.state == newState {
		return
	}
	cb.state = newState
	cb.stateChanges++

	if newState == Open {
		cb.openedAt = time.Now()
	}
}

func (cb *CircuitBreaker) resetCounters() {
	cb.totalRequests = 0
	cb.failedRequests = 0
	cb.windowStartTime = time.Now()
}

func (cb *CircuitBreaker) resetHalfOpenCounters() {
	cb.halfOpenSuccesses = 0
	cb.halfOpenFailures = 0
	cb.halfOpenTotal = 0
}

// FailureRate returns the current failure rate in the sliding window.
func (cb *CircuitBreaker) FailureRate() float64 {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	if cb.totalRequests == 0 {
		return 0.0
	}
	return float64(cb.failedRequests) / float64(cb.totalRequests)
}

// Metrics returns circuit breaker metrics.
func (cb *CircuitBreaker) Metrics() Metrics {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	failureRate := 0.0
	if cb.totalRequests > 0 {
		failureRate = float64(cb.failedRequests) / float64(cb.totalRequests)
	}

	return Metrics{
		State:            cb.state,
		TotalRequests:    cb.totalRequests,
		FailedRequests:   cb.failedRequests,
		StateChanges:     cb.stateChanges,
		RejectedRequests: cb.rejectedRequests,
		FailureRate:      failureRate,
	}
}

// Metrics holds circuit breaker metrics.
type Metrics struct {
	State            State
	TotalRequests    int
	FailedRequests   int
	StateChanges     int
	RejectedRequests int
	FailureRate      float64
}

// ForceOpen forces the circuit open (for testing).
func (cb *CircuitBreaker) ForceOpen() {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	cb.transitionTo(Open)
}

// ForceClosed forces the circuit closed (for testing).
func (cb *CircuitBreaker) ForceClosed() {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	cb.transitionTo(Closed)
	cb.resetCounters()
}

// IsOpen returns true if the circuit is open.
func (cb *CircuitBreaker) IsOpen() bool {
	return cb.State() == Open
}

// IsClosed returns true if the circuit is closed.
func (cb *CircuitBreaker) IsClosed() bool {
	return cb.State() == Closed
}

// IsHalfOpen returns true if the circuit is half-open.
func (cb *CircuitBreaker) IsHalfOpen() bool {
	return cb.State() == HalfOpen
}

func (cb *CircuitBreaker) String() string {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	failureRate := 0.0
	if cb.totalRequests > 0 {
		failureRate = float64(cb.failedRequests) / float64(cb.totalRequests) * 100
	}

	return fmt.Sprintf("CircuitBreaker[name=%s, state=%s, failureRate=%.2f%%]",
		cb.name, cb.state, failureRate)
}
