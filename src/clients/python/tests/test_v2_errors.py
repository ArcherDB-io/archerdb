"""Tests for v2.0 error codes (multi-region 213-218, sharding 220-224, encryption 410-414)."""

import pytest
from archerdb.errors import (
    # Multi-region
    MultiRegionError,
    MultiRegionException,
    MULTI_REGION_ERROR_MESSAGES,
    MULTI_REGION_ERROR_RETRYABLE,
    is_multi_region_error,
    multi_region_error_message,
    # Sharding
    ShardingError,
    ShardingException,
    SHARDING_ERROR_MESSAGES,
    SHARDING_ERROR_RETRYABLE,
    is_sharding_error,
    sharding_error_message,
    # Encryption
    EncryptionError,
    EncryptionException,
    ENCRYPTION_ERROR_MESSAGES,
    ENCRYPTION_ERROR_RETRYABLE,
    is_encryption_error,
    encryption_error_message,
    # Utilities
    is_retryable,
    error_message,
    ArcherDBError,
)


# ============================================================================
# Multi-Region Error Tests
# ============================================================================

class TestMultiRegionError:
    """Tests for multi-region error codes (213-218)."""

    def test_code_values(self):
        """Verify multi-region error code values."""
        assert MultiRegionError.FOLLOWER_READ_ONLY == 213
        assert MultiRegionError.STALE_FOLLOWER == 214
        assert MultiRegionError.PRIMARY_UNREACHABLE == 215
        assert MultiRegionError.REPLICATION_TIMEOUT == 216
        assert MultiRegionError.REGION_CONFIG_MISMATCH == 217
        assert MultiRegionError.UNKNOWN_REGION == 218

    def test_retry_semantics(self):
        """Verify multi-region error retry semantics."""
        assert MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.FOLLOWER_READ_ONLY] is False
        assert MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.STALE_FOLLOWER] is True
        assert MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.PRIMARY_UNREACHABLE] is True
        assert MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.REPLICATION_TIMEOUT] is True
        assert MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.REGION_CONFIG_MISMATCH] is False
        assert MULTI_REGION_ERROR_RETRYABLE[MultiRegionError.UNKNOWN_REGION] is False

    def test_is_multi_region_error(self):
        """Verify is_multi_region_error helper."""
        assert not is_multi_region_error(212)
        assert is_multi_region_error(213)
        assert is_multi_region_error(216)
        assert is_multi_region_error(218)
        assert not is_multi_region_error(219)

    def test_messages(self):
        """Verify multi-region error messages."""
        assert "follower" in MULTI_REGION_ERROR_MESSAGES[MultiRegionError.FOLLOWER_READ_ONLY].lower()
        assert "staleness" in MULTI_REGION_ERROR_MESSAGES[MultiRegionError.STALE_FOLLOWER].lower()
        assert "primary" in MULTI_REGION_ERROR_MESSAGES[MultiRegionError.PRIMARY_UNREACHABLE].lower()

    def test_multi_region_error_message(self):
        """Verify multi_region_error_message helper."""
        assert multi_region_error_message(213) is not None
        assert "follower" in multi_region_error_message(213).lower()
        assert multi_region_error_message(212) is None
        assert multi_region_error_message(219) is None

    def test_exception(self):
        """Verify MultiRegionException."""
        exc = MultiRegionException(MultiRegionError.FOLLOWER_READ_ONLY)
        assert exc.code == 213
        assert exc.retryable is False
        assert exc.error == MultiRegionError.FOLLOWER_READ_ONLY
        assert "[213]" in str(exc)


# ============================================================================
# Sharding Error Tests
# ============================================================================

class TestShardingError:
    """Tests for sharding error codes (220-224)."""

    def test_code_values(self):
        """Verify sharding error code values."""
        assert ShardingError.NOT_SHARD_LEADER == 220
        assert ShardingError.SHARD_UNAVAILABLE == 221
        assert ShardingError.RESHARDING_IN_PROGRESS == 222
        assert ShardingError.INVALID_SHARD_COUNT == 223
        assert ShardingError.SHARD_MIGRATION_FAILED == 224

    def test_retry_semantics(self):
        """Verify sharding error retry semantics."""
        assert SHARDING_ERROR_RETRYABLE[ShardingError.NOT_SHARD_LEADER] is True
        assert SHARDING_ERROR_RETRYABLE[ShardingError.SHARD_UNAVAILABLE] is True
        assert SHARDING_ERROR_RETRYABLE[ShardingError.RESHARDING_IN_PROGRESS] is True
        assert SHARDING_ERROR_RETRYABLE[ShardingError.INVALID_SHARD_COUNT] is False
        assert SHARDING_ERROR_RETRYABLE[ShardingError.SHARD_MIGRATION_FAILED] is False

    def test_is_sharding_error(self):
        """Verify is_sharding_error helper."""
        assert not is_sharding_error(219)
        assert is_sharding_error(220)
        assert is_sharding_error(222)
        assert is_sharding_error(224)
        assert not is_sharding_error(225)

    def test_messages(self):
        """Verify sharding error messages."""
        assert "leader" in SHARDING_ERROR_MESSAGES[ShardingError.NOT_SHARD_LEADER].lower()
        # Message says "no available" instead of "unavailable"
        assert "available" in SHARDING_ERROR_MESSAGES[ShardingError.SHARD_UNAVAILABLE].lower()
        assert "resharding" in SHARDING_ERROR_MESSAGES[ShardingError.RESHARDING_IN_PROGRESS].lower()

    def test_sharding_error_message(self):
        """Verify sharding_error_message helper."""
        assert sharding_error_message(220) is not None
        assert "leader" in sharding_error_message(220).lower()
        assert sharding_error_message(219) is None
        assert sharding_error_message(225) is None

    def test_exception(self):
        """Verify ShardingException."""
        exc = ShardingException(ShardingError.NOT_SHARD_LEADER)
        assert exc.code == 220
        assert exc.retryable is True
        assert exc.error == ShardingError.NOT_SHARD_LEADER
        assert "[220]" in str(exc)
        assert exc.shard_id is None

    def test_exception_with_shard_id(self):
        """Verify ShardingException with shard_id."""
        exc = ShardingException(ShardingError.SHARD_UNAVAILABLE, shard_id=5)
        assert exc.shard_id == 5
        assert exc.code == 221


# ============================================================================
# Encryption Error Tests
# ============================================================================

class TestEncryptionError:
    """Tests for encryption error codes (410-414)."""

    def test_code_values(self):
        """Verify encryption error code values."""
        assert EncryptionError.ENCRYPTION_KEY_UNAVAILABLE == 410
        assert EncryptionError.DECRYPTION_FAILED == 411
        assert EncryptionError.ENCRYPTION_NOT_ENABLED == 412
        assert EncryptionError.KEY_ROTATION_IN_PROGRESS == 413
        assert EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION == 414

    def test_retry_semantics(self):
        """Verify encryption error retry semantics."""
        assert ENCRYPTION_ERROR_RETRYABLE[EncryptionError.ENCRYPTION_KEY_UNAVAILABLE] is True
        assert ENCRYPTION_ERROR_RETRYABLE[EncryptionError.DECRYPTION_FAILED] is False
        assert ENCRYPTION_ERROR_RETRYABLE[EncryptionError.ENCRYPTION_NOT_ENABLED] is False
        assert ENCRYPTION_ERROR_RETRYABLE[EncryptionError.KEY_ROTATION_IN_PROGRESS] is True
        assert ENCRYPTION_ERROR_RETRYABLE[EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION] is False

    def test_is_encryption_error(self):
        """Verify is_encryption_error helper."""
        assert not is_encryption_error(409)
        assert is_encryption_error(410)
        assert is_encryption_error(412)
        assert is_encryption_error(414)
        assert not is_encryption_error(415)

    def test_messages(self):
        """Verify encryption error messages."""
        assert "key" in ENCRYPTION_ERROR_MESSAGES[EncryptionError.ENCRYPTION_KEY_UNAVAILABLE].lower()
        assert "decrypt" in ENCRYPTION_ERROR_MESSAGES[EncryptionError.DECRYPTION_FAILED].lower()
        assert "rotation" in ENCRYPTION_ERROR_MESSAGES[EncryptionError.KEY_ROTATION_IN_PROGRESS].lower()

    def test_encryption_error_message(self):
        """Verify encryption_error_message helper."""
        assert encryption_error_message(410) is not None
        assert "key" in encryption_error_message(410).lower()
        assert encryption_error_message(409) is None
        assert encryption_error_message(415) is None

    def test_exception(self):
        """Verify EncryptionException."""
        exc = EncryptionException(EncryptionError.DECRYPTION_FAILED)
        assert exc.code == 411
        assert exc.retryable is False
        assert exc.error == EncryptionError.DECRYPTION_FAILED
        assert "[411]" in str(exc)


# ============================================================================
# Utility Function Tests
# ============================================================================

class TestUtilityFunctions:
    """Tests for utility functions."""

    def test_is_retryable_multi_region(self):
        """Verify is_retryable for multi-region errors."""
        assert not is_retryable(213)  # FOLLOWER_READ_ONLY
        assert is_retryable(214)      # STALE_FOLLOWER
        assert is_retryable(215)      # PRIMARY_UNREACHABLE

    def test_is_retryable_sharding(self):
        """Verify is_retryable for sharding errors."""
        assert is_retryable(220)      # NOT_SHARD_LEADER
        assert not is_retryable(223)  # INVALID_SHARD_COUNT
        assert not is_retryable(224)  # SHARD_MIGRATION_FAILED

    def test_is_retryable_encryption(self):
        """Verify is_retryable for encryption errors."""
        assert is_retryable(410)      # ENCRYPTION_KEY_UNAVAILABLE
        assert not is_retryable(411)  # DECRYPTION_FAILED
        assert is_retryable(413)      # KEY_ROTATION_IN_PROGRESS

    def test_is_retryable_unknown(self):
        """Verify is_retryable for unknown codes."""
        assert not is_retryable(999)
        assert not is_retryable(0)
        assert not is_retryable(-1)

    def test_error_message_multi_region(self):
        """Verify error_message for multi-region errors."""
        assert "follower" in error_message(213).lower()
        assert "replication" in error_message(216).lower()

    def test_error_message_sharding(self):
        """Verify error_message for sharding errors."""
        assert "leader" in error_message(220).lower()
        assert "resharding" in error_message(222).lower()

    def test_error_message_encryption(self):
        """Verify error_message for encryption errors."""
        assert "key" in error_message(410).lower()
        assert "version" in error_message(414).lower()

    def test_error_message_unknown(self):
        """Verify error_message for unknown codes."""
        assert error_message(999) is None
        assert error_message(0) is None


# ============================================================================
# Base Error Class Tests
# ============================================================================

class TestArcherDBError:
    """Tests for base ArcherDBError class."""

    def test_construction(self):
        """Verify base error construction."""
        error = ArcherDBError(500, "Test error", retryable=True)
        assert error.code == 500
        assert error.message == "Test error"
        assert error.retryable is True
        assert "[500]" in str(error)

    def test_default_retryable(self):
        """Verify default retryable is False."""
        error = ArcherDBError(500, "Test error")
        assert error.retryable is False

    def test_is_exception(self):
        """Verify ArcherDBError is an Exception."""
        error = ArcherDBError(500, "Test error")
        assert isinstance(error, Exception)
