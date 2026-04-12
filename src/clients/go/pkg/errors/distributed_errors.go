// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
// Package errors provides error codes for ArcherDB distributed features.
//
// Error code ranges:
//   - State errors: 200-210
//   - Multi-region errors: 213-218
//   - Sharding errors: 220-224
//   - Encryption errors: 410-414
package errors

import "fmt"

// ErrorCode represents an ArcherDB error code.
type ErrorCode int

// State error codes (200-210).
const (
	// EntityNotFound indicates the requested entity UUID was not found in the index.
	EntityNotFound ErrorCode = 200

	// EntityExpired indicates the entity has expired due to TTL.
	EntityExpired ErrorCode = 210
)

// Multi-region error codes (213-218).
const (
	// FollowerReadOnly indicates write operation rejected: follower regions are read-only.
	FollowerReadOnly ErrorCode = 213

	// StaleFollower indicates follower data exceeds maximum staleness threshold.
	StaleFollower ErrorCode = 214

	// PrimaryUnreachable indicates cannot connect to primary region.
	PrimaryUnreachable ErrorCode = 215

	// ReplicationTimeout indicates cross-region replication timeout.
	ReplicationTimeout ErrorCode = 216

	// ConflictDetected indicates write conflict detected in active-active replication.
	ConflictDetected ErrorCode = 217

	// GeoShardMismatch indicates entity geo-shard does not match target region.
	GeoShardMismatch ErrorCode = 218
)

// Sharding error codes (220-224).
const (
	// NotShardLeader indicates this node is not the leader for target shard.
	NotShardLeader ErrorCode = 220

	// ShardUnavailable indicates target shard has no available replicas.
	ShardUnavailable ErrorCode = 221

	// ReshardingInProgress indicates cluster is currently resharding.
	ReshardingInProgress ErrorCode = 222

	// InvalidShardCount indicates target shard count is invalid.
	InvalidShardCount ErrorCode = 223

	// ShardMigrationFailed indicates data migration to new shard failed.
	ShardMigrationFailed ErrorCode = 224
)

// Encryption error codes (410-414).
const (
	// EncryptionKeyUnavailable indicates cannot retrieve encryption key from provider.
	EncryptionKeyUnavailable ErrorCode = 410

	// DecryptionFailed indicates failed to decrypt data (auth tag mismatch).
	DecryptionFailed ErrorCode = 411

	// EncryptionNotEnabled indicates encryption required but not configured.
	EncryptionNotEnabled ErrorCode = 412

	// KeyRotationInProgress indicates key rotation in progress, retry later.
	KeyRotationInProgress ErrorCode = 413

	// UnsupportedEncryptionVersion indicates file encrypted with unsupported version.
	UnsupportedEncryptionVersion ErrorCode = 414
)

// Error messages for each error code.
var errorMessages = map[ErrorCode]string{
	// State errors
	EntityNotFound: "Entity not found",
	EntityExpired:  "Entity has expired due to TTL",

	// Multi-region errors
	FollowerReadOnly:   "Write operation rejected: follower regions are read-only",
	StaleFollower:      "Follower data exceeds maximum staleness threshold",
	PrimaryUnreachable: "Cannot connect to primary region",
	ReplicationTimeout: "Cross-region replication timeout",
	ConflictDetected:   "Write conflict detected in active-active replication",
	GeoShardMismatch:   "Entity geo-shard does not match target region",

	// Sharding errors
	NotShardLeader:       "This node is not the leader for target shard",
	ShardUnavailable:     "Target shard has no available replicas",
	ReshardingInProgress: "Cluster is currently resharding",
	InvalidShardCount:    "Target shard count is invalid",
	ShardMigrationFailed: "Data migration to new shard failed",

	// Encryption errors
	EncryptionKeyUnavailable:     "Cannot retrieve encryption key from provider",
	DecryptionFailed:             "Failed to decrypt data (auth tag mismatch)",
	EncryptionNotEnabled:         "Encryption required but not configured",
	KeyRotationInProgress:        "Key rotation in progress, retry later",
	UnsupportedEncryptionVersion: "File encrypted with unsupported version",
}

// Retryable indicates whether each error code is retryable.
var retryable = map[ErrorCode]bool{
	// State errors (not retryable - entity state is definitive)
	EntityNotFound: false,
	EntityExpired:  false,

	// Multi-region errors
	FollowerReadOnly:   false,
	StaleFollower:      true,
	PrimaryUnreachable: true,
	ReplicationTimeout: true,
	ConflictDetected:   false,
	GeoShardMismatch:   false,

	// Sharding errors
	NotShardLeader:       true,
	ShardUnavailable:     true,
	ReshardingInProgress: true,
	InvalidShardCount:    false,
	ShardMigrationFailed: false,

	// Encryption errors
	EncryptionKeyUnavailable:     true,
	DecryptionFailed:             false,
	EncryptionNotEnabled:         false,
	KeyRotationInProgress:        true,
	UnsupportedEncryptionVersion: false,
}

// OperationType represents the type of operation that caused an error.
type OperationType string

const (
	OpUnknown OperationType = ""
	OpInsert  OperationType = "insert"
	OpUpdate  OperationType = "update"
	OpDelete  OperationType = "delete"
	OpQuery   OperationType = "query"
	OpGet     OperationType = "get"
)

// ArcherDBError represents an ArcherDB error with code, message, and retry semantics.
type ArcherDBError struct {
	Code          ErrorCode
	Message       string
	Retryable     bool
	EntityID      string        // Optional: the entity ID involved in the error
	ShardID       int           // Optional: the shard ID involved in the error (-1 if not set)
	OperationType OperationType // Optional: the operation type that caused the error
}

func (e *ArcherDBError) Error() string {
	return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

// StateException is a typed error for state errors (entity not found, expired).
// State errors are never retryable - the entity state is definitive.
type StateException struct {
	StateError    ErrorCode     // The specific state error enum value
	Code          ErrorCode     // Numeric error code (same as StateError, for convenience)
	Message       string
	Retryable     bool
	EntityID      string        // Optional: the entity ID involved in the error
	OperationType OperationType // Optional: the operation type that caused the error
}

func (e *StateException) Error() string {
	return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

// NewStateException creates a StateException from a StateError code.
func NewStateException(code ErrorCode) *StateException {
	return &StateException{
		StateError:    code,
		Code:          code,
		Message:       errorMessages[code],
		Retryable:     false, // State errors are never retryable
		EntityID:      "",
		OperationType: OpUnknown,
	}
}

// NewStateExceptionWithContext creates a StateException with operation context.
func NewStateExceptionWithContext(code ErrorCode, entityID string, opType OperationType) *StateException {
	return &StateException{
		StateError:    code,
		Code:          code,
		Message:       errorMessages[code],
		Retryable:     false,
		EntityID:      entityID,
		OperationType: opType,
	}
}

// MultiRegionException is a typed error for multi-region errors.
type MultiRegionException struct {
	MultiRegionError ErrorCode     // The specific multi-region error enum value
	Code             ErrorCode     // Numeric error code
	Message          string
	Retryable        bool
	EntityID         string        // Optional: the entity ID involved in the error
	ShardID          int           // Optional: the shard ID involved in the error (-1 if not set)
	OperationType    OperationType // Optional: the operation type that caused the error
}

func (e *MultiRegionException) Error() string {
	return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

// NewMultiRegionException creates a MultiRegionException from an error code.
func NewMultiRegionException(code ErrorCode) *MultiRegionException {
	return &MultiRegionException{
		MultiRegionError: code,
		Code:             code,
		Message:          errorMessages[code],
		Retryable:        retryable[code],
		EntityID:         "",
		ShardID:          -1,
		OperationType:    OpUnknown,
	}
}

// NewMultiRegionExceptionWithContext creates a MultiRegionException with operation context.
func NewMultiRegionExceptionWithContext(code ErrorCode, entityID string, shardID int, opType OperationType) *MultiRegionException {
	return &MultiRegionException{
		MultiRegionError: code,
		Code:             code,
		Message:          errorMessages[code],
		Retryable:        retryable[code],
		EntityID:         entityID,
		ShardID:          shardID,
		OperationType:    opType,
	}
}

// ShardingException is a typed error for sharding errors.
type ShardingException struct {
	ShardingError ErrorCode     // The specific sharding error enum value
	Code          ErrorCode     // Numeric error code
	Message       string
	Retryable     bool
	ShardID       int           // Optional: the shard ID involved in the error (-1 if not set)
	EntityID      string        // Optional: the entity ID involved in the error
	OperationType OperationType // Optional: the operation type that caused the error
}

func (e *ShardingException) Error() string {
	return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

// NewShardingException creates a ShardingException from an error code.
func NewShardingException(code ErrorCode) *ShardingException {
	return &ShardingException{
		ShardingError: code,
		Code:          code,
		Message:       errorMessages[code],
		Retryable:     retryable[code],
		ShardID:       -1,
		EntityID:      "",
		OperationType: OpUnknown,
	}
}

// NewShardingExceptionWithShard creates a ShardingException with shard ID context.
func NewShardingExceptionWithShard(code ErrorCode, shardID int) *ShardingException {
	return &ShardingException{
		ShardingError: code,
		Code:          code,
		Message:       errorMessages[code],
		Retryable:     retryable[code],
		ShardID:       shardID,
		EntityID:      "",
		OperationType: OpUnknown,
	}
}

// NewShardingExceptionWithContext creates a ShardingException with full operation context.
func NewShardingExceptionWithContext(code ErrorCode, shardID int, entityID string, opType OperationType) *ShardingException {
	return &ShardingException{
		ShardingError: code,
		Code:          code,
		Message:       errorMessages[code],
		Retryable:     retryable[code],
		ShardID:       shardID,
		EntityID:      entityID,
		OperationType: opType,
	}
}

// EncryptionException is a typed error for encryption errors.
type EncryptionException struct {
	EncryptionError ErrorCode     // The specific encryption error enum value
	Code            ErrorCode     // Numeric error code
	Message         string
	Retryable       bool
	EntityID        string        // Optional: the entity ID involved in the error
	ShardID         int           // Optional: the shard ID involved in the error (-1 if not set)
	OperationType   OperationType // Optional: the operation type that caused the error
}

func (e *EncryptionException) Error() string {
	return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

// NewEncryptionException creates an EncryptionException from an error code.
func NewEncryptionException(code ErrorCode) *EncryptionException {
	return &EncryptionException{
		EncryptionError: code,
		Code:            code,
		Message:         errorMessages[code],
		Retryable:       retryable[code],
		EntityID:        "",
		ShardID:         -1,
		OperationType:   OpUnknown,
	}
}

// NewEncryptionExceptionWithContext creates an EncryptionException with operation context.
func NewEncryptionExceptionWithContext(code ErrorCode, entityID string, shardID int, opType OperationType) *EncryptionException {
	return &EncryptionException{
		EncryptionError: code,
		Code:            code,
		Message:         errorMessages[code],
		Retryable:       retryable[code],
		EntityID:        entityID,
		ShardID:         shardID,
		OperationType:   opType,
	}
}

// NewError creates a new ArcherDBError from an error code.
func NewError(code ErrorCode) *ArcherDBError {
	return &ArcherDBError{
		Code:          code,
		Message:       errorMessages[code],
		Retryable:     retryable[code],
		EntityID:      "",
		ShardID:       -1,
		OperationType: OpUnknown,
	}
}

// NewErrorWithMessage creates a new ArcherDBError with a custom message.
func NewErrorWithMessage(code ErrorCode, message string) *ArcherDBError {
	return &ArcherDBError{
		Code:          code,
		Message:       message,
		Retryable:     retryable[code],
		EntityID:      "",
		ShardID:       -1,
		OperationType: OpUnknown,
	}
}

// NewErrorWithContext creates a new ArcherDBError with operation context.
func NewErrorWithContext(code ErrorCode, entityID string, shardID int, opType OperationType) *ArcherDBError {
	return &ArcherDBError{
		Code:          code,
		Message:       errorMessages[code],
		Retryable:     retryable[code],
		EntityID:      entityID,
		ShardID:       shardID,
		OperationType: opType,
	}
}

// IsStateError returns true if the code is a state error (200-210).
func IsStateError(code int) bool {
	return code >= 200 && code <= 210
}

// IsMultiRegionError returns true if the code is a multi-region error (213-218).
func IsMultiRegionError(code int) bool {
	return code >= 213 && code <= 218
}

// IsShardingError returns true if the code is a sharding error (220-224).
func IsShardingError(code int) bool {
	return code >= 220 && code <= 224
}

// IsEncryptionError returns true if the code is an encryption error (410-414).
func IsEncryptionError(code int) bool {
	return code >= 410 && code <= 414
}

// IsRetryable returns true if the error code indicates a retryable error.
func IsRetryable(code int) bool {
	if r, ok := retryable[ErrorCode(code)]; ok {
		return r
	}
	return false
}

// GetErrorMessage returns the message for an error code, or empty string if not found.
func GetErrorMessage(code int) string {
	if msg, ok := errorMessages[ErrorCode(code)]; ok {
		return msg
	}
	return ""
}
