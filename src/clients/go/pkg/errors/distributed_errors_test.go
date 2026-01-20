package errors

import (
	"testing"
)

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
