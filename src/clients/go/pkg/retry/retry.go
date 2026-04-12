// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
// Package retry provides retry logic with exponential backoff for ArcherDB Go SDK.
//
// This package implements the retry policy from client-retry/spec.md:
// - Exponential backoff: 0ms, 100ms, 200ms, 400ms, 800ms, 1600ms
// - Jitter: random(0, base_delay/2) to prevent thundering herd
// - Max 5 retries (6 total attempts)
// - Total timeout: 30s default
package retry

import (
	"errors"
	"math/rand"
	"strings"
	"time"

	sdk_errors "github.com/archerdb/archerdb-go/pkg/errors"
)

// Config holds retry configuration options.
type Config struct {
	// Enabled controls whether automatic retry is enabled (default: true).
	Enabled bool

	// MaxRetries is the maximum number of retry attempts after initial failure.
	// Total attempts = MaxRetries + 1 (default: 5).
	MaxRetries int

	// BaseBackoffMs is the base backoff delay in milliseconds.
	// Delay doubles after each attempt: 100, 200, 400, 800, 1600ms (default: 100).
	BaseBackoffMs int

	// MaxBackoffMs is the maximum backoff delay in milliseconds (default: 1600).
	MaxBackoffMs int

	// TotalTimeoutMs is the total timeout for all retry attempts in milliseconds (default: 30000).
	TotalTimeoutMs int

	// Jitter controls whether random jitter is added to backoff delays (default: true).
	Jitter bool
}

// DefaultConfig returns the default retry configuration per spec.
func DefaultConfig() Config {
	return Config{
		Enabled:        true,
		MaxRetries:     5,
		BaseBackoffMs:  100,
		MaxBackoffMs:   1600,
		TotalTimeoutMs: 30000,
		Jitter:         true,
	}
}

// ErrRetryExhausted is returned when all retry attempts have been exhausted.
type ErrRetryExhausted struct {
	Attempts  int
	LastError error
}

func (e ErrRetryExhausted) Error() string {
	return "all retry attempts exhausted"
}

func (e ErrRetryExhausted) Unwrap() error {
	return e.LastError
}

// IsRetryable determines if an error is safe to retry.
//
// Retryable errors:
// - Timeouts
// - Client evicted (server-side session management)
// - Network errors (connection reset, timeout, refused)
//
// Non-retryable errors:
// - Invalid data/operation
// - Maximum batch size exceeded
// - Client closed
func IsRetryable(err error) bool {
	if err == nil {
		return false
	}

	// Check known SDK error types
	var clientEvicted sdk_errors.ErrClientEvicted
	if errors.As(err, &clientEvicted) {
		return true
	}

	var releaseTooLow sdk_errors.ErrClientReleaseTooLow
	if errors.As(err, &releaseTooLow) {
		return true
	}

	var releaseTooHigh sdk_errors.ErrClientReleaseTooHigh
	if errors.As(err, &releaseTooHigh) {
		return true
	}

	var systemResources sdk_errors.ErrSystemResources
	if errors.As(err, &systemResources) {
		return true
	}

	var networkSubsystem sdk_errors.ErrNetworkSubsystem
	if errors.As(err, &networkSubsystem) {
		return true
	}

	// Non-retryable SDK errors
	var clientClosed sdk_errors.ErrClientClosed
	if errors.As(err, &clientClosed) {
		return false
	}

	var invalidOp sdk_errors.ErrInvalidOperation
	if errors.As(err, &invalidOp) {
		return false
	}

	var batchTooLarge sdk_errors.ErrMaximumBatchSizeExceeded
	if errors.As(err, &batchTooLarge) {
		return false
	}

	var invalidAddr sdk_errors.ErrInvalidAddress
	if errors.As(err, &invalidAddr) {
		return false
	}

	// Check error message for network-related errors
	msg := strings.ToLower(err.Error())
	networkKeywords := []string{
		"timeout",
		"connection",
		"reset",
		"refused",
		"network",
		"eof",
	}

	for _, keyword := range networkKeywords {
		if strings.Contains(msg, keyword) {
			return true
		}
	}

	return false
}

// CalculateDelay calculates the retry delay for a given attempt.
//
// Backoff schedule (per spec):
// - Attempt 1: 0ms (immediate)
// - Attempt 2: 100ms + jitter
// - Attempt 3: 200ms + jitter
// - Attempt 4: 400ms + jitter
// - Attempt 5: 800ms + jitter
// - Attempt 6: 1600ms + jitter
func CalculateDelay(attempt int, config Config) time.Duration {
	// First attempt is immediate
	if attempt <= 1 {
		return 0
	}

	// Exponential backoff: base_delay * 2^(attempt-2)
	baseDelay := config.BaseBackoffMs * (1 << (attempt - 2))
	delay := baseDelay
	if delay > config.MaxBackoffMs {
		delay = config.MaxBackoffMs
	}

	if !config.Jitter {
		return time.Duration(delay) * time.Millisecond
	}

	// Jitter: random(0, delay/2)
	jitter := rand.Intn(delay/2 + 1)
	return time.Duration(delay+jitter) * time.Millisecond
}

// Operation represents a function that can be retried.
type Operation func() error

// Do executes an operation with retry logic.
//
// The operation function should return an error if it fails.
// If the error is retryable and we haven't exhausted retries,
// the operation will be retried with exponential backoff.
//
// Example:
//
//	config := retry.DefaultConfig()
//	err := retry.Do(func() error {
//	    _, err := client.InsertEvents(events)
//	    return err
//	}, config)
func Do(operation Operation, config Config) error {
	if !config.Enabled {
		return operation()
	}

	startTime := time.Now()
	maxAttempts := config.MaxRetries + 1
	var lastError error = errors.New("no attempts made")

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		// Check total timeout before starting attempt
		elapsed := time.Since(startTime)
		if elapsed >= time.Duration(config.TotalTimeoutMs)*time.Millisecond {
			return ErrRetryExhausted{Attempts: attempt - 1, LastError: lastError}
		}

		err := operation()
		if err == nil {
			return nil
		}

		lastError = err

		// Non-retryable errors fail immediately
		if !IsRetryable(err) {
			return err
		}

		// Last attempt - don't sleep, just exit loop
		if attempt >= maxAttempts {
			break
		}

		// Calculate delay for next attempt
		delay := CalculateDelay(attempt+1, config)

		// Check if delay would exceed total timeout
		totalElapsed := time.Since(startTime)
		if totalElapsed+delay >= time.Duration(config.TotalTimeoutMs)*time.Millisecond {
			break
		}

		// Wait before next attempt
		if delay > 0 {
			time.Sleep(delay)
		}
	}

	return ErrRetryExhausted{Attempts: maxAttempts, LastError: lastError}
}
