// Package errors provides v2.0 error codes for ArcherDB distributed features.
//
// Error code ranges:
//   - Multi-region errors: 213-218
//   - Sharding errors: 220-224
//   - Encryption errors: 410-414
package errors

import "fmt"

// ErrorCode represents a v2 error code.
type ErrorCode int

// Multi-region error codes (213-218) per v2 replication/spec.md.
const (
	// FollowerReadOnly indicates write operation rejected: follower regions are read-only.
	FollowerReadOnly ErrorCode = 213

	// StaleFollower indicates follower data exceeds maximum staleness threshold.
	StaleFollower ErrorCode = 214

	// PrimaryUnreachable indicates cannot connect to primary region.
	PrimaryUnreachable ErrorCode = 215

	// ReplicationTimeout indicates cross-region replication timeout.
	ReplicationTimeout ErrorCode = 216

	// RegionConfigMismatch indicates region configuration does not match cluster topology.
	RegionConfigMismatch ErrorCode = 217

	// UnknownRegion indicates unknown region specified in request.
	UnknownRegion ErrorCode = 218
)

// Sharding error codes (220-224) per v2 index-sharding/spec.md.
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

// Encryption error codes (410-414) per v2 security/spec.md.
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
	// Multi-region errors
	FollowerReadOnly:     "Write operation rejected: follower regions are read-only",
	StaleFollower:        "Follower data exceeds maximum staleness threshold",
	PrimaryUnreachable:   "Cannot connect to primary region",
	ReplicationTimeout:   "Cross-region replication timeout",
	RegionConfigMismatch: "Region configuration does not match cluster topology",
	UnknownRegion:        "Unknown region specified in request",

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
	// Multi-region errors
	FollowerReadOnly:     false,
	StaleFollower:        true,
	PrimaryUnreachable:   true,
	ReplicationTimeout:   true,
	RegionConfigMismatch: false,
	UnknownRegion:        false,

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

// ArcherDBError represents an ArcherDB v2 error with code, message, and retry semantics.
type ArcherDBError struct {
	Code      ErrorCode
	Message   string
	Retryable bool
}

func (e *ArcherDBError) Error() string {
	return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

// NewError creates a new ArcherDBError from an error code.
func NewError(code ErrorCode) *ArcherDBError {
	return &ArcherDBError{
		Code:      code,
		Message:   errorMessages[code],
		Retryable: retryable[code],
	}
}

// NewErrorWithMessage creates a new ArcherDBError with a custom message.
func NewErrorWithMessage(code ErrorCode, message string) *ArcherDBError {
	return &ArcherDBError{
		Code:      code,
		Message:   message,
		Retryable: retryable[code],
	}
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
