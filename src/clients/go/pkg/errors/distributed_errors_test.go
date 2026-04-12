// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package errors

import (
	"testing"
)

// TestStateErrorCodes verifies state error codes (200-210).
func TestStateErrorCodes(t *testing.T) {
	tests := []struct {
		code      ErrorCode
		retryable bool
	}{
		{EntityNotFound, false},
		{EntityExpired, false},
	}

	for _, tc := range tests {
		if int(tc.code) < 200 || int(tc.code) > 210 {
			t.Errorf("State error code %d out of range 200-210", tc.code)
		}

		err := NewError(tc.code)
		if err.Code != tc.code {
			t.Errorf("Expected code %d, got %d", tc.code, err.Code)
		}
		if err.Retryable != tc.retryable {
			t.Errorf("Code %d: expected retryable=%v, got %v", tc.code, tc.retryable, err.Retryable)
		}
		if err.Message == "" {
			t.Errorf("Code %d should have a non-empty message", tc.code)
		}
	}
}

// TestStateException verifies StateException type.
func TestStateException(t *testing.T) {
	exc := NewStateException(EntityNotFound)

	if exc.Code != EntityNotFound {
		t.Errorf("Expected code %d, got %d", EntityNotFound, exc.Code)
	}
	if exc.StateError != EntityNotFound {
		t.Errorf("Expected StateError %d, got %d", EntityNotFound, exc.StateError)
	}
	if exc.Retryable {
		t.Error("StateException should not be retryable")
	}
	if exc.Message == "" {
		t.Error("StateException should have a message")
	}

	// Verify error string format
	errStr := exc.Error()
	if errStr != "[200] Entity not found" {
		t.Errorf("Unexpected error string: %s", errStr)
	}
}

// TestIsStateError verifies IsStateError helper.
func TestIsStateError(t *testing.T) {
	if IsStateError(199) {
		t.Error("199 should not be a state error")
	}
	if !IsStateError(200) {
		t.Error("200 should be a state error")
	}
	if !IsStateError(205) {
		t.Error("205 should be a state error")
	}
	if !IsStateError(210) {
		t.Error("210 should be a state error")
	}
	if IsStateError(211) {
		t.Error("211 should not be a state error")
	}
}

// TestMultiRegionException verifies MultiRegionException type.
func TestMultiRegionException(t *testing.T) {
	exc := NewMultiRegionException(StaleFollower)

	if exc.Code != StaleFollower {
		t.Errorf("Expected code %d, got %d", StaleFollower, exc.Code)
	}
	if !exc.Retryable {
		t.Error("StaleFollower should be retryable")
	}

	excNonRetry := NewMultiRegionException(FollowerReadOnly)
	if excNonRetry.Retryable {
		t.Error("FollowerReadOnly should not be retryable")
	}
}

// TestShardingException verifies ShardingException type.
func TestShardingException(t *testing.T) {
	exc := NewShardingException(NotShardLeader)

	if exc.Code != NotShardLeader {
		t.Errorf("Expected code %d, got %d", NotShardLeader, exc.Code)
	}
	if exc.ShardID != -1 {
		t.Errorf("Expected ShardID -1, got %d", exc.ShardID)
	}

	// Test with shard ID context
	excWithShard := NewShardingExceptionWithShard(ShardUnavailable, 42)
	if excWithShard.ShardID != 42 {
		t.Errorf("Expected ShardID 42, got %d", excWithShard.ShardID)
	}
}

// TestEncryptionException verifies EncryptionException type.
func TestEncryptionException(t *testing.T) {
	exc := NewEncryptionException(KeyRotationInProgress)

	if exc.Code != KeyRotationInProgress {
		t.Errorf("Expected code %d, got %d", KeyRotationInProgress, exc.Code)
	}
	if !exc.Retryable {
		t.Error("KeyRotationInProgress should be retryable")
	}

	excNonRetry := NewEncryptionException(DecryptionFailed)
	if excNonRetry.Retryable {
		t.Error("DecryptionFailed should not be retryable")
	}
}

// TestMultiRegionErrorCodes verifies multi-region error codes (213-218).
func TestMultiRegionErrorCodes(t *testing.T) {
	tests := []struct {
		code      ErrorCode
		retryable bool
	}{
		{FollowerReadOnly, false},
		{StaleFollower, true},
		{PrimaryUnreachable, true},
		{ReplicationTimeout, true},
		{ConflictDetected, false},
		{GeoShardMismatch, false},
	}

	for _, tc := range tests {
		if int(tc.code) < 213 || int(tc.code) > 218 {
			t.Errorf("Multi-region error code %d out of range 213-218", tc.code)
		}

		err := NewError(tc.code)
		if err.Code != tc.code {
			t.Errorf("Expected code %d, got %d", tc.code, err.Code)
		}
		if err.Retryable != tc.retryable {
			t.Errorf("Code %d: expected retryable=%v, got %v", tc.code, tc.retryable, err.Retryable)
		}
		if err.Message == "" {
			t.Errorf("Code %d should have a non-empty message", tc.code)
		}
	}
}

// TestShardingErrorCodes verifies sharding error codes (220-224).
func TestShardingErrorCodes(t *testing.T) {
	tests := []struct {
		code      ErrorCode
		retryable bool
	}{
		{NotShardLeader, true},
		{ShardUnavailable, true},
		{ReshardingInProgress, true},
		{InvalidShardCount, false},
		{ShardMigrationFailed, false},
	}

	for _, tc := range tests {
		if int(tc.code) < 220 || int(tc.code) > 224 {
			t.Errorf("Sharding error code %d out of range 220-224", tc.code)
		}

		err := NewError(tc.code)
		if err.Code != tc.code {
			t.Errorf("Expected code %d, got %d", tc.code, err.Code)
		}
		if err.Retryable != tc.retryable {
			t.Errorf("Code %d: expected retryable=%v, got %v", tc.code, tc.retryable, err.Retryable)
		}
		if err.Message == "" {
			t.Errorf("Code %d should have a non-empty message", tc.code)
		}
	}
}

// TestEncryptionErrorCodes verifies encryption error codes (410-414).
func TestEncryptionErrorCodes(t *testing.T) {
	tests := []struct {
		code      ErrorCode
		retryable bool
	}{
		{EncryptionKeyUnavailable, true},
		{DecryptionFailed, false},
		{EncryptionNotEnabled, false},
		{KeyRotationInProgress, true},
		{UnsupportedEncryptionVersion, false},
	}

	for _, tc := range tests {
		if int(tc.code) < 410 || int(tc.code) > 414 {
			t.Errorf("Encryption error code %d out of range 410-414", tc.code)
		}

		err := NewError(tc.code)
		if err.Code != tc.code {
			t.Errorf("Expected code %d, got %d", tc.code, err.Code)
		}
		if err.Retryable != tc.retryable {
			t.Errorf("Code %d: expected retryable=%v, got %v", tc.code, tc.retryable, err.Retryable)
		}
		if err.Message == "" {
			t.Errorf("Code %d should have a non-empty message", tc.code)
		}
	}
}

// TestIsMultiRegionError verifies IsMultiRegionError helper.
func TestIsMultiRegionError(t *testing.T) {
	if IsMultiRegionError(212) {
		t.Error("212 should not be a multi-region error")
	}
	if !IsMultiRegionError(213) {
		t.Error("213 should be a multi-region error")
	}
	if !IsMultiRegionError(216) {
		t.Error("216 should be a multi-region error")
	}
	if !IsMultiRegionError(218) {
		t.Error("218 should be a multi-region error")
	}
	if IsMultiRegionError(219) {
		t.Error("219 should not be a multi-region error")
	}
}

// TestIsShardingError verifies IsShardingError helper.
func TestIsShardingError(t *testing.T) {
	if IsShardingError(219) {
		t.Error("219 should not be a sharding error")
	}
	if !IsShardingError(220) {
		t.Error("220 should be a sharding error")
	}
	if !IsShardingError(222) {
		t.Error("222 should be a sharding error")
	}
	if !IsShardingError(224) {
		t.Error("224 should be a sharding error")
	}
	if IsShardingError(225) {
		t.Error("225 should not be a sharding error")
	}
}

// TestIsEncryptionError verifies IsEncryptionError helper.
func TestIsEncryptionError(t *testing.T) {
	if IsEncryptionError(409) {
		t.Error("409 should not be an encryption error")
	}
	if !IsEncryptionError(410) {
		t.Error("410 should be an encryption error")
	}
	if !IsEncryptionError(412) {
		t.Error("412 should be an encryption error")
	}
	if !IsEncryptionError(414) {
		t.Error("414 should be an encryption error")
	}
	if IsEncryptionError(415) {
		t.Error("415 should not be an encryption error")
	}
}

// TestIsRetryable verifies IsRetryable helper.
func TestIsRetryable(t *testing.T) {
	// State errors (never retryable)
	if IsRetryable(int(EntityNotFound)) {
		t.Error("EntityNotFound should not be retryable")
	}
	if IsRetryable(int(EntityExpired)) {
		t.Error("EntityExpired should not be retryable")
	}

	// Multi-region
	if IsRetryable(int(FollowerReadOnly)) {
		t.Error("FollowerReadOnly should not be retryable")
	}
	if !IsRetryable(int(StaleFollower)) {
		t.Error("StaleFollower should be retryable")
	}

	// Sharding
	if !IsRetryable(int(NotShardLeader)) {
		t.Error("NotShardLeader should be retryable")
	}
	if IsRetryable(int(InvalidShardCount)) {
		t.Error("InvalidShardCount should not be retryable")
	}

	// Encryption
	if !IsRetryable(int(EncryptionKeyUnavailable)) {
		t.Error("EncryptionKeyUnavailable should be retryable")
	}
	if IsRetryable(int(DecryptionFailed)) {
		t.Error("DecryptionFailed should not be retryable")
	}

	// Unknown code
	if IsRetryable(999) {
		t.Error("Unknown code 999 should not be retryable")
	}
}

// TestErrorFormat verifies error string format.
func TestErrorFormat(t *testing.T) {
	err := NewError(NotShardLeader)
	expected := "[220] This node is not the leader for target shard"
	if err.Error() != expected {
		t.Errorf("Expected %q, got %q", expected, err.Error())
	}
}

// TestNewErrorWithMessage verifies custom message.
func TestNewErrorWithMessage(t *testing.T) {
	customMsg := "Custom error message for shard 5"
	err := NewErrorWithMessage(NotShardLeader, customMsg)

	if err.Code != NotShardLeader {
		t.Errorf("Expected code %d, got %d", NotShardLeader, err.Code)
	}
	if err.Message != customMsg {
		t.Errorf("Expected message %q, got %q", customMsg, err.Message)
	}
	if !err.Retryable {
		t.Error("NotShardLeader should be retryable")
	}
}

// TestGetErrorMessage verifies GetErrorMessage helper.
func TestGetErrorMessage(t *testing.T) {
	msg := GetErrorMessage(220)
	if msg == "" {
		t.Error("Expected message for code 220")
	}
	if msg != "This node is not the leader for target shard" {
		t.Errorf("Unexpected message: %s", msg)
	}

	// Unknown code
	msg = GetErrorMessage(999)
	if msg != "" {
		t.Error("Expected empty message for unknown code 999")
	}
}

// ============================================================================
// Operation Context Tests
// ============================================================================

// TestOperationType verifies OperationType constants.
func TestOperationType(t *testing.T) {
	if OpUnknown != "" {
		t.Errorf("OpUnknown should be empty string, got %q", OpUnknown)
	}
	if OpInsert != "insert" {
		t.Errorf("OpInsert should be 'insert', got %q", OpInsert)
	}
	if OpQuery != "query" {
		t.Errorf("OpQuery should be 'query', got %q", OpQuery)
	}
}

// TestStateExceptionWithContext verifies StateException with operation context.
func TestStateExceptionWithContext(t *testing.T) {
	exc := NewStateExceptionWithContext(EntityNotFound, "entity-123", OpGet)

	if exc.EntityID != "entity-123" {
		t.Errorf("Expected EntityID 'entity-123', got %q", exc.EntityID)
	}
	if exc.OperationType != OpGet {
		t.Errorf("Expected OperationType OpGet, got %q", exc.OperationType)
	}
	if exc.Code != EntityNotFound {
		t.Errorf("Expected code %d, got %d", EntityNotFound, exc.Code)
	}
}

// TestMultiRegionExceptionWithContext verifies MultiRegionException with operation context.
func TestMultiRegionExceptionWithContext(t *testing.T) {
	exc := NewMultiRegionExceptionWithContext(GeoShardMismatch, "entity-456", 7, OpInsert)

	if exc.EntityID != "entity-456" {
		t.Errorf("Expected EntityID 'entity-456', got %q", exc.EntityID)
	}
	if exc.ShardID != 7 {
		t.Errorf("Expected ShardID 7, got %d", exc.ShardID)
	}
	if exc.OperationType != OpInsert {
		t.Errorf("Expected OperationType OpInsert, got %q", exc.OperationType)
	}
}

// TestShardingExceptionWithContext verifies ShardingException with full context.
func TestShardingExceptionWithContext(t *testing.T) {
	exc := NewShardingExceptionWithContext(NotShardLeader, 42, "entity-789", OpUpdate)

	if exc.ShardID != 42 {
		t.Errorf("Expected ShardID 42, got %d", exc.ShardID)
	}
	if exc.EntityID != "entity-789" {
		t.Errorf("Expected EntityID 'entity-789', got %q", exc.EntityID)
	}
	if exc.OperationType != OpUpdate {
		t.Errorf("Expected OperationType OpUpdate, got %q", exc.OperationType)
	}
	if !exc.Retryable {
		t.Error("NotShardLeader should be retryable")
	}
}

// TestEncryptionExceptionWithContext verifies EncryptionException with operation context.
func TestEncryptionExceptionWithContext(t *testing.T) {
	exc := NewEncryptionExceptionWithContext(DecryptionFailed, "entity-abc", 3, OpQuery)

	if exc.EntityID != "entity-abc" {
		t.Errorf("Expected EntityID 'entity-abc', got %q", exc.EntityID)
	}
	if exc.ShardID != 3 {
		t.Errorf("Expected ShardID 3, got %d", exc.ShardID)
	}
	if exc.OperationType != OpQuery {
		t.Errorf("Expected OperationType OpQuery, got %q", exc.OperationType)
	}
	if exc.Retryable {
		t.Error("DecryptionFailed should not be retryable")
	}
}

// TestNewErrorWithContext verifies NewErrorWithContext.
func TestNewErrorWithContext(t *testing.T) {
	err := NewErrorWithContext(ShardUnavailable, "entity-xyz", 5, OpDelete)

	if err.EntityID != "entity-xyz" {
		t.Errorf("Expected EntityID 'entity-xyz', got %q", err.EntityID)
	}
	if err.ShardID != 5 {
		t.Errorf("Expected ShardID 5, got %d", err.ShardID)
	}
	if err.OperationType != OpDelete {
		t.Errorf("Expected OperationType OpDelete, got %q", err.OperationType)
	}
	if err.Code != ShardUnavailable {
		t.Errorf("Expected code %d, got %d", ShardUnavailable, err.Code)
	}
}

// TestDefaultContextValues verifies that context fields have proper defaults.
func TestDefaultContextValues(t *testing.T) {
	// Standard constructor should have default context values
	exc := NewShardingException(NotShardLeader)

	if exc.EntityID != "" {
		t.Errorf("Expected empty EntityID, got %q", exc.EntityID)
	}
	if exc.ShardID != -1 {
		t.Errorf("Expected ShardID -1, got %d", exc.ShardID)
	}
	if exc.OperationType != OpUnknown {
		t.Errorf("Expected OperationType OpUnknown, got %q", exc.OperationType)
	}
}
