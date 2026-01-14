"""
ArcherDB Error Codes and Exceptions

Provides v2 error code enums and exceptions for:
- Multi-region errors (213-218)
- Sharding errors (220-224)
- Encryption errors (410-414)
"""

from __future__ import annotations
from dataclasses import dataclass
from enum import IntEnum
from typing import Optional


class ArcherDBError(Exception):
    """Base exception for all ArcherDB errors."""

    def __init__(self, code: int, message: str, retryable: bool = False):
        self.code = code
        self.message = message
        self.retryable = retryable
        super().__init__(f"[{code}] {message}")


# ============================================================================
# Multi-Region Error Codes (213-218)
# ============================================================================

class MultiRegionError(IntEnum):
    """Multi-region error codes (213-218) per v2 replication/spec.md."""

    FOLLOWER_READ_ONLY = 213
    """Write operation rejected: follower regions are read-only."""

    STALE_FOLLOWER = 214
    """Follower data exceeds maximum staleness threshold."""

    PRIMARY_UNREACHABLE = 215
    """Cannot connect to primary region."""

    REPLICATION_TIMEOUT = 216
    """Cross-region replication timeout."""

    REGION_CONFIG_MISMATCH = 217
    """Region configuration does not match cluster topology."""

    UNKNOWN_REGION = 218
    """Unknown region specified in request."""


MULTI_REGION_ERROR_MESSAGES = {
    MultiRegionError.FOLLOWER_READ_ONLY: "Write operation rejected: follower regions are read-only",
    MultiRegionError.STALE_FOLLOWER: "Follower data exceeds maximum staleness threshold",
    MultiRegionError.PRIMARY_UNREACHABLE: "Cannot connect to primary region",
    MultiRegionError.REPLICATION_TIMEOUT: "Cross-region replication timeout",
    MultiRegionError.REGION_CONFIG_MISMATCH: "Region configuration does not match cluster topology",
    MultiRegionError.UNKNOWN_REGION: "Unknown region specified in request",
}

MULTI_REGION_ERROR_RETRYABLE = {
    MultiRegionError.FOLLOWER_READ_ONLY: False,
    MultiRegionError.STALE_FOLLOWER: True,
    MultiRegionError.PRIMARY_UNREACHABLE: True,
    MultiRegionError.REPLICATION_TIMEOUT: True,
    MultiRegionError.REGION_CONFIG_MISMATCH: False,
    MultiRegionError.UNKNOWN_REGION: False,
}


def is_multi_region_error(code: int) -> bool:
    """Returns True if the given code is a multi-region error (213-218)."""
    return 213 <= code <= 218


def multi_region_error_message(code: int) -> Optional[str]:
    """Returns the message for a multi-region error code."""
    try:
        return MULTI_REGION_ERROR_MESSAGES[MultiRegionError(code)]
    except ValueError:
        return None


# ============================================================================
# Sharding Error Codes (220-224)
# ============================================================================

class ShardingError(IntEnum):
    """Sharding error codes (220-224) per v2 index-sharding/spec.md."""

    NOT_SHARD_LEADER = 220
    """This node is not the leader for target shard."""

    SHARD_UNAVAILABLE = 221
    """Target shard has no available replicas."""

    RESHARDING_IN_PROGRESS = 222
    """Cluster is currently resharding."""

    INVALID_SHARD_COUNT = 223
    """Target shard count is invalid."""

    SHARD_MIGRATION_FAILED = 224
    """Data migration to new shard failed."""


SHARDING_ERROR_MESSAGES = {
    ShardingError.NOT_SHARD_LEADER: "This node is not the leader for target shard",
    ShardingError.SHARD_UNAVAILABLE: "Target shard has no available replicas",
    ShardingError.RESHARDING_IN_PROGRESS: "Cluster is currently resharding",
    ShardingError.INVALID_SHARD_COUNT: "Target shard count is invalid",
    ShardingError.SHARD_MIGRATION_FAILED: "Data migration to new shard failed",
}

SHARDING_ERROR_RETRYABLE = {
    ShardingError.NOT_SHARD_LEADER: True,
    ShardingError.SHARD_UNAVAILABLE: True,
    ShardingError.RESHARDING_IN_PROGRESS: True,
    ShardingError.INVALID_SHARD_COUNT: False,
    ShardingError.SHARD_MIGRATION_FAILED: False,
}


def is_sharding_error(code: int) -> bool:
    """Returns True if the given code is a sharding error (220-224)."""
    return 220 <= code <= 224


def sharding_error_message(code: int) -> Optional[str]:
    """Returns the message for a sharding error code."""
    try:
        return SHARDING_ERROR_MESSAGES[ShardingError(code)]
    except ValueError:
        return None


# ============================================================================
# Encryption Error Codes (410-414)
# ============================================================================

class EncryptionError(IntEnum):
    """Encryption error codes (410-414) per v2 security/spec.md."""

    ENCRYPTION_KEY_UNAVAILABLE = 410
    """Cannot retrieve encryption key from provider."""

    DECRYPTION_FAILED = 411
    """Failed to decrypt data (auth tag mismatch)."""

    ENCRYPTION_NOT_ENABLED = 412
    """Encryption required but not configured."""

    KEY_ROTATION_IN_PROGRESS = 413
    """Key rotation in progress, retry later."""

    UNSUPPORTED_ENCRYPTION_VERSION = 414
    """File encrypted with unsupported version."""


ENCRYPTION_ERROR_MESSAGES = {
    EncryptionError.ENCRYPTION_KEY_UNAVAILABLE: "Cannot retrieve encryption key from provider",
    EncryptionError.DECRYPTION_FAILED: "Failed to decrypt data (auth tag mismatch)",
    EncryptionError.ENCRYPTION_NOT_ENABLED: "Encryption required but not configured",
    EncryptionError.KEY_ROTATION_IN_PROGRESS: "Key rotation in progress, retry later",
    EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION: "File encrypted with unsupported version",
}

ENCRYPTION_ERROR_RETRYABLE = {
    EncryptionError.ENCRYPTION_KEY_UNAVAILABLE: True,
    EncryptionError.DECRYPTION_FAILED: False,
    EncryptionError.ENCRYPTION_NOT_ENABLED: False,
    EncryptionError.KEY_ROTATION_IN_PROGRESS: True,
    EncryptionError.UNSUPPORTED_ENCRYPTION_VERSION: False,
}


def is_encryption_error(code: int) -> bool:
    """Returns True if the given code is an encryption error (410-414)."""
    return 410 <= code <= 414


def encryption_error_message(code: int) -> Optional[str]:
    """Returns the message for an encryption error code."""
    try:
        return ENCRYPTION_ERROR_MESSAGES[EncryptionError(code)]
    except ValueError:
        return None


# ============================================================================
# Exception Classes
# ============================================================================

class MultiRegionException(ArcherDBError):
    """Exception for multi-region errors."""

    def __init__(self, error: MultiRegionError):
        super().__init__(
            code=error.value,
            message=MULTI_REGION_ERROR_MESSAGES[error],
            retryable=MULTI_REGION_ERROR_RETRYABLE[error],
        )
        self.error = error


class ShardingException(ArcherDBError):
    """Exception for sharding errors."""

    def __init__(self, error: ShardingError, shard_id: Optional[int] = None):
        super().__init__(
            code=error.value,
            message=SHARDING_ERROR_MESSAGES[error],
            retryable=SHARDING_ERROR_RETRYABLE[error],
        )
        self.error = error
        self.shard_id = shard_id


class EncryptionException(ArcherDBError):
    """Exception for encryption errors."""

    def __init__(self, error: EncryptionError):
        super().__init__(
            code=error.value,
            message=ENCRYPTION_ERROR_MESSAGES[error],
            retryable=ENCRYPTION_ERROR_RETRYABLE[error],
        )
        self.error = error


# ============================================================================
# Error Code Utilities
# ============================================================================

def is_retryable(code: int) -> bool:
    """Returns True if the error code indicates a retryable error."""
    if is_multi_region_error(code):
        try:
            return MULTI_REGION_ERROR_RETRYABLE[MultiRegionError(code)]
        except ValueError:
            pass
    elif is_sharding_error(code):
        try:
            return SHARDING_ERROR_RETRYABLE[ShardingError(code)]
        except ValueError:
            pass
    elif is_encryption_error(code):
        try:
            return ENCRYPTION_ERROR_RETRYABLE[EncryptionError(code)]
        except ValueError:
            pass
    return False


def error_message(code: int) -> Optional[str]:
    """Returns the message for any v2 error code."""
    if is_multi_region_error(code):
        return multi_region_error_message(code)
    elif is_sharding_error(code):
        return sharding_error_message(code)
    elif is_encryption_error(code):
        return encryption_error_message(code)
    return None
