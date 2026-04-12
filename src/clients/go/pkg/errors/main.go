// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
// Package errors provides error types for the ArcherDB Go SDK.
//
// All errors implement the GeoError interface and support the standard
// errors.Is and errors.As patterns for type checking.
//
// # Error Categories
//
// Errors are grouped into categories for easier handling:
//
//   - Internal errors: Unexpected conditions within the SDK
//   - Resource errors: Memory, system resources exhausted
//   - Network errors: Connection and communication issues
//   - Client errors: Invalid configuration or state
//
// # Using errors.Is
//
// Check for specific error types:
//
//	import "github.com/archerdb/archerdb-go/pkg/errors"
//
//	if errors.Is(err, &errors.ErrClientClosed{}) {
//	    // Handle closed client
//	}
//
// # Using Category Helpers
//
// Check error categories:
//
//	if errors.IsRetryable(err) {
//	    // Safe to retry
//	}
package errors

import (
	stderrors "errors"
)

// GeoError is the interface implemented by all ArcherDB SDK errors.
type GeoError interface {
	error
	// Code returns the numeric error code.
	Code() int
	// Retryable returns true if the operation can be safely retried.
	Retryable() bool
}

// ============================================================================
// Sentinel Error Variables
// ============================================================================

// Sentinel error instances for use with errors.Is.
var (
	// ErrUnexpectedSentinel matches any ErrUnexpected error.
	ErrUnexpectedSentinel = &ErrUnexpected{}
	// ErrOutOfMemorySentinel matches any ErrOutOfMemory error.
	ErrOutOfMemorySentinel = &ErrOutOfMemory{}
	// ErrSystemResourcesSentinel matches any ErrSystemResources error.
	ErrSystemResourcesSentinel = &ErrSystemResources{}
	// ErrNetworkSubsystemSentinel matches any ErrNetworkSubsystem error.
	ErrNetworkSubsystemSentinel = &ErrNetworkSubsystem{}
	// ErrInvalidConcurrencyMaxSentinel matches any ErrInvalidConcurrencyMax error.
	ErrInvalidConcurrencyMaxSentinel = &ErrInvalidConcurrencyMax{}
	// ErrAddressLimitExceededSentinel matches any ErrAddressLimitExceeded error.
	ErrAddressLimitExceededSentinel = &ErrAddressLimitExceeded{}
	// ErrInvalidAddressSentinel matches any ErrInvalidAddress error.
	ErrInvalidAddressSentinel = &ErrInvalidAddress{}
	// ErrClientEvictedSentinel matches any ErrClientEvicted error.
	ErrClientEvictedSentinel = &ErrClientEvicted{}
	// ErrClientReleaseTooLowSentinel matches any ErrClientReleaseTooLow error.
	ErrClientReleaseTooLowSentinel = &ErrClientReleaseTooLow{}
	// ErrClientReleaseTooHighSentinel matches any ErrClientReleaseTooHigh error.
	ErrClientReleaseTooHighSentinel = &ErrClientReleaseTooHigh{}
	// ErrClientClosedSentinel matches any ErrClientClosed error.
	ErrClientClosedSentinel = &ErrClientClosed{}
	// ErrInvalidOperationSentinel matches any ErrInvalidOperation error.
	ErrInvalidOperationSentinel = &ErrInvalidOperation{}
	// ErrMaximumBatchSizeExceededSentinel matches any ErrMaximumBatchSizeExceeded error.
	ErrMaximumBatchSizeExceededSentinel = &ErrMaximumBatchSizeExceeded{}
)

// ============================================================================
// Internal Errors (1xxx)
// ============================================================================

// ErrUnexpected indicates an unexpected internal error in the SDK.
//
// This is NOT retryable - report as a bug.
//
// Error code: 1000
type ErrUnexpected struct{}

func (e ErrUnexpected) Error() string   { return "Unexpected internal error." }
func (e ErrUnexpected) Code() int       { return 1000 }
func (e ErrUnexpected) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrUnexpected) Is(target error) bool {
	_, ok := target.(*ErrUnexpected)
	return ok
}

// ErrOutOfMemory indicates the internal client ran out of memory.
//
// This may be retryable after freeing memory.
//
// Error code: 1001
type ErrOutOfMemory struct{}

func (e ErrOutOfMemory) Error() string   { return "Internal client ran out of memory." }
func (e ErrOutOfMemory) Code() int       { return 1001 }
func (e ErrOutOfMemory) Retryable() bool { return true }

// Is implements errors.Is support.
func (e *ErrOutOfMemory) Is(target error) bool {
	_, ok := target.(*ErrOutOfMemory)
	return ok
}

// ErrSystemResources indicates the client ran out of system resources.
//
// This may be retryable after resources are freed.
//
// Error code: 1002
type ErrSystemResources struct{}

func (e ErrSystemResources) Error() string   { return "Internal client ran out of system resources." }
func (e ErrSystemResources) Code() int       { return 1002 }
func (e ErrSystemResources) Retryable() bool { return true }

// Is implements errors.Is support.
func (e *ErrSystemResources) Is(target error) bool {
	_, ok := target.(*ErrSystemResources)
	return ok
}

// ============================================================================
// Network Errors (2xxx)
// ============================================================================

// ErrNetworkSubsystem indicates unexpected networking issues.
//
// This is retryable - network issues are often transient.
//
// Error code: 2001
type ErrNetworkSubsystem struct{}

func (e ErrNetworkSubsystem) Error() string {
	return "Internal client had unexpected networking issues."
}
func (e ErrNetworkSubsystem) Code() int       { return 2001 }
func (e ErrNetworkSubsystem) Retryable() bool { return true }

// Is implements errors.Is support.
func (e *ErrNetworkSubsystem) Is(target error) bool {
	_, ok := target.(*ErrNetworkSubsystem)
	return ok
}

// ============================================================================
// Configuration Errors (3xxx)
// ============================================================================

// ErrInvalidConcurrencyMax indicates concurrency max is out of range.
//
// This is NOT retryable - fix the configuration.
//
// Error code: 3001
type ErrInvalidConcurrencyMax struct{}

func (e ErrInvalidConcurrencyMax) Error() string   { return "Concurrency max is out of range." }
func (e ErrInvalidConcurrencyMax) Code() int       { return 3001 }
func (e ErrInvalidConcurrencyMax) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrInvalidConcurrencyMax) Is(target error) bool {
	_, ok := target.(*ErrInvalidConcurrencyMax)
	return ok
}

// ErrAddressLimitExceeded indicates too many cluster addresses were provided.
//
// This is NOT retryable - reduce the number of addresses.
//
// Error code: 3002
type ErrAddressLimitExceeded struct{}

func (e ErrAddressLimitExceeded) Error() string   { return "Too many addresses provided." }
func (e ErrAddressLimitExceeded) Code() int       { return 3002 }
func (e ErrAddressLimitExceeded) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrAddressLimitExceeded) Is(target error) bool {
	_, ok := target.(*ErrAddressLimitExceeded)
	return ok
}

// ErrInvalidAddress indicates an invalid cluster address format.
//
// This is NOT retryable - fix the address format.
//
// Error code: 3003
type ErrInvalidAddress struct{}

func (e ErrInvalidAddress) Error() string   { return "Invalid client cluster address." }
func (e ErrInvalidAddress) Code() int       { return 3003 }
func (e ErrInvalidAddress) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrInvalidAddress) Is(target error) bool {
	_, ok := target.(*ErrInvalidAddress)
	return ok
}

// ============================================================================
// Client State Errors (4xxx)
// ============================================================================

// ErrClientEvicted indicates the client was evicted from the cluster.
//
// This may be retryable - reconnect with a new client.
//
// Error code: 4001
type ErrClientEvicted struct{}

func (e ErrClientEvicted) Error() string   { return "Client was evicted." }
func (e ErrClientEvicted) Code() int       { return 4001 }
func (e ErrClientEvicted) Retryable() bool { return true }

// Is implements errors.Is support.
func (e *ErrClientEvicted) Is(target error) bool {
	_, ok := target.(*ErrClientEvicted)
	return ok
}

// ErrClientReleaseTooLow indicates the client version is too old for the cluster.
//
// This is NOT retryable - upgrade the SDK.
//
// Error code: 4002
type ErrClientReleaseTooLow struct{}

func (e ErrClientReleaseTooLow) Error() string   { return "Client was evicted: release too old." }
func (e ErrClientReleaseTooLow) Code() int       { return 4002 }
func (e ErrClientReleaseTooLow) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrClientReleaseTooLow) Is(target error) bool {
	_, ok := target.(*ErrClientReleaseTooLow)
	return ok
}

// ErrClientReleaseTooHigh indicates the client version is too new for the cluster.
//
// This is NOT retryable - upgrade the cluster or use an older SDK.
//
// Error code: 4003
type ErrClientReleaseTooHigh struct{}

func (e ErrClientReleaseTooHigh) Error() string   { return "Client was evicted: release too new." }
func (e ErrClientReleaseTooHigh) Code() int       { return 4003 }
func (e ErrClientReleaseTooHigh) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrClientReleaseTooHigh) Is(target error) bool {
	_, ok := target.(*ErrClientReleaseTooHigh)
	return ok
}

// ErrClientClosed indicates the client has been closed.
//
// This is NOT retryable - create a new client.
//
// Error code: 4004
type ErrClientClosed struct{}

func (e ErrClientClosed) Error() string   { return "Client was closed." }
func (e ErrClientClosed) Code() int       { return 4004 }
func (e ErrClientClosed) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrClientClosed) Is(target error) bool {
	_, ok := target.(*ErrClientClosed)
	return ok
}

// ============================================================================
// Operation Errors (5xxx)
// ============================================================================

// ErrInvalidOperation indicates an invalid operation was provided.
//
// This is NOT retryable - fix the operation.
//
// Error code: 5001
type ErrInvalidOperation struct{}

func (e ErrInvalidOperation) Error() string   { return "Internal operation provided was invalid." }
func (e ErrInvalidOperation) Code() int       { return 5001 }
func (e ErrInvalidOperation) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrInvalidOperation) Is(target error) bool {
	_, ok := target.(*ErrInvalidOperation)
	return ok
}

// ErrMaximumBatchSizeExceeded indicates the batch size exceeds the maximum.
//
// This is NOT retryable - reduce the batch size.
//
// Error code: 5002
type ErrMaximumBatchSizeExceeded struct{}

func (e ErrMaximumBatchSizeExceeded) Error() string   { return "Maximum batch size exceeded." }
func (e ErrMaximumBatchSizeExceeded) Code() int       { return 5002 }
func (e ErrMaximumBatchSizeExceeded) Retryable() bool { return false }

// Is implements errors.Is support.
func (e *ErrMaximumBatchSizeExceeded) Is(target error) bool {
	_, ok := target.(*ErrMaximumBatchSizeExceeded)
	return ok
}

// ============================================================================
// Category Helper Functions
// ============================================================================

// IsRetryableError returns true if the error represents a retryable condition.
//
// Use this to determine if an operation should be retried:
//
//	if errors.IsRetryableError(err) {
//	    time.Sleep(backoff)
//	    // retry operation
//	}
//
// Note: This differs from IsRetryable(code int) which checks by error code.
// This function checks by error type.
func IsRetryableError(err error) bool {
	if err == nil {
		return false
	}
	var geoErr GeoError
	if stderrors.As(err, &geoErr) {
		return geoErr.Retryable()
	}
	// Check distributed errors
	if archerErr, ok := err.(*ArcherDBError); ok {
		return archerErr.Retryable
	}
	return false
}

// IsNetworkError returns true if the error is network-related.
//
// Network errors include connection failures, timeouts, and networking issues.
func IsNetworkError(err error) bool {
	if err == nil {
		return false
	}
	var netErr *ErrNetworkSubsystem
	return stderrors.As(err, &netErr)
}

// IsResourceError returns true if the error is resource-related.
//
// Resource errors include out of memory and system resource exhaustion.
func IsResourceError(err error) bool {
	if err == nil {
		return false
	}
	var oomErr *ErrOutOfMemory
	var sysErr *ErrSystemResources
	return stderrors.As(err, &oomErr) || stderrors.As(err, &sysErr)
}

// IsConfigError returns true if the error is configuration-related.
//
// Configuration errors indicate invalid settings that must be fixed.
func IsConfigError(err error) bool {
	if err == nil {
		return false
	}
	var concErr *ErrInvalidConcurrencyMax
	var addrLimitErr *ErrAddressLimitExceeded
	var addrErr *ErrInvalidAddress
	return stderrors.As(err, &concErr) ||
		stderrors.As(err, &addrLimitErr) ||
		stderrors.As(err, &addrErr)
}

// IsClientStateError returns true if the error is client state related.
//
// Client state errors indicate the client is in an invalid state.
func IsClientStateError(err error) bool {
	if err == nil {
		return false
	}
	var evictErr *ErrClientEvicted
	var relLowErr *ErrClientReleaseTooLow
	var relHighErr *ErrClientReleaseTooHigh
	var closedErr *ErrClientClosed
	return stderrors.As(err, &evictErr) ||
		stderrors.As(err, &relLowErr) ||
		stderrors.As(err, &relHighErr) ||
		stderrors.As(err, &closedErr)
}

// GetErrorCode returns the error code for a GeoError, or 0 if not a GeoError.
//
// Use for logging or metrics:
//
//	code := errors.GetErrorCode(err)
//	metrics.RecordError(code)
func GetErrorCode(err error) int {
	if err == nil {
		return 0
	}
	var geoErr GeoError
	if stderrors.As(err, &geoErr) {
		return geoErr.Code()
	}
	return 0
}
