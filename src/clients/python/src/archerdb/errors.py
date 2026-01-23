"""
ArcherDB Error Codes and Exceptions

This module provides error code enums and typed exceptions for ArcherDB
distributed features including multi-region replication, sharding, and
encryption.

Error Code Ranges:
    - 200-212: Core state errors (entity not found, expired)
    - 213-218: Multi-region errors (follower read-only, replication timeout)
    - 220-224: Sharding errors (not shard leader, resharding in progress)
    - 410-414: Encryption errors (key unavailable, decryption failed)

Retryability:
    Each error code has an associated retryability flag. Use is_retryable()
    to check if an operation can be retried after an error.

    Retryable errors (True):
        - Transient failures (timeouts, leader changes, unavailable replicas)

    Non-retryable errors (False):
        - Permanent failures (invalid configuration, conflicts)

Example:
    from archerdb.errors import (
        is_retryable,
        error_message,
        MultiRegionError,
        ShardingError,
    )

    try:
        result = client.insert_events(events)
    except ArcherDBError as e:
        if is_retryable(e.code):
            print(f"Retryable error: {error_message(e.code)}")
            # Schedule retry
        else:
            print(f"Permanent error: {e}")
            # Handle failure
"""

from __future__ import annotations
from dataclasses import dataclass
from enum import IntEnum
from typing import Optional


class ArcherDBError(Exception):
    """
    Base exception for all ArcherDB distributed errors.

    All typed ArcherDB exceptions inherit from this class. Catch this
    to handle any ArcherDB error uniformly.

    Attributes:
        code: Numeric error code for programmatic handling.
        message: Human-readable error description.
        retryable: Whether the operation can be retried.
            True for transient errors, False for permanent errors.

    Example:
        try:
            client.insert_events(events)
        except ArcherDBError as e:
            logger.error(f"Error {e.code}: {e.message}")
            if e.retryable:
                retry_queue.put(events)
    """

    def __init__(self, code: int, message: str, retryable: bool = False):
        """
        Create a new ArcherDBError.

        Args:
            code: Numeric error code.
            message: Human-readable error description.
            retryable: Whether the operation can be retried. Default False.
        """
        self.code = code
        self.message = message
        self.retryable = retryable
        super().__init__(f"[{code}] {message}")


# ============================================================================
# State Error Codes (200-243) - Core Errors
# ============================================================================

class StateError(IntEnum):
    """
    Core state error codes (200-243).

    These errors indicate issues with the requested entity state.
    All state errors are non-retryable.

    Attributes:
        ENTITY_NOT_FOUND: Code 200 - Entity UUID not found in index.
        ENTITY_EXPIRED: Code 210 - Entity has expired due to TTL.
    """

    ENTITY_NOT_FOUND = 200
    """Query UUID not found in index. Code: 200. Non-retryable."""

    ENTITY_EXPIRED = 210
    """Entity has expired due to TTL. Code: 210. Non-retryable."""


STATE_ERROR_MESSAGES = {
    StateError.ENTITY_NOT_FOUND: "Entity not found",
    StateError.ENTITY_EXPIRED: "Entity has expired due to TTL",
}


def is_state_error(code: int) -> bool:
    """
    Check if an error code is a core state error (200-243).

    Args:
        code: The error code to check.

    Returns:
        True if the code is in the state error range.
    """
    return 200 <= code <= 243


def state_error_message(code: int) -> Optional[str]:
    """
    Get the message for a state error code.

    Args:
        code: The state error code.

    Returns:
        Human-readable error message, or None if code is not a state error.
    """
    try:
        return STATE_ERROR_MESSAGES[StateError(code)]
    except ValueError:
        return None


class StateException(ArcherDBError):
    """
    Exception for core state errors.

    Raised when an entity is not found or has expired.

    Attributes:
        error: The specific StateError enum value.
        code: Numeric error code (inherited).
        retryable: Always False for state errors.

    Example:
        try:
            event = client.get_latest_by_uuid(entity_id)
        except StateException as e:
            if e.error == StateError.ENTITY_NOT_FOUND:
                print("Entity does not exist")
            elif e.error == StateError.ENTITY_EXPIRED:
                print("Entity has expired")
    """

    def __init__(self, error: StateError):
        """
        Create a StateException.

        Args:
            error: The StateError enum value.
        """
        super().__init__(
            code=error.value,
            message=STATE_ERROR_MESSAGES[error],
            retryable=False,
        )
        self.error = error


# ============================================================================
# Multi-Region Error Codes (213-218)
# ============================================================================

class MultiRegionError(IntEnum):
    """
    Multi-region error codes (213-218).

    These errors occur in multi-region deployments with active-passive
    or active-active replication. Per v2 replication/spec.md.

    Attributes:
        FOLLOWER_READ_ONLY: Code 213 - Write rejected, follower is read-only.
            Non-retryable. Redirect write to primary region.
        STALE_FOLLOWER: Code 214 - Follower data too stale.
            Retryable. Wait for replication to catch up.
        PRIMARY_UNREACHABLE: Code 215 - Cannot reach primary region.
            Retryable. Primary may recover.
        REPLICATION_TIMEOUT: Code 216 - Cross-region replication timed out.
            Retryable. Network may recover.
        CONFLICT_DETECTED: Code 217 - Write conflict in active-active mode.
            Non-retryable. Application must resolve conflict.
        GEO_SHARD_MISMATCH: Code 218 - Entity belongs to different region.
            Non-retryable. Route to correct region.
    """

    FOLLOWER_READ_ONLY = 213
    """Write rejected: follower regions are read-only. Code: 213. Non-retryable."""

    STALE_FOLLOWER = 214
    """Follower data exceeds staleness threshold. Code: 214. Retryable."""

    PRIMARY_UNREACHABLE = 215
    """Cannot connect to primary region. Code: 215. Retryable."""

    REPLICATION_TIMEOUT = 216
    """Cross-region replication timeout. Code: 216. Retryable."""

    CONFLICT_DETECTED = 217
    """Write conflict in active-active replication. Code: 217. Non-retryable."""

    GEO_SHARD_MISMATCH = 218
    """Entity geo-shard doesn't match target region. Code: 218. Non-retryable."""


MULTI_REGION_ERROR_MESSAGES = {
    MultiRegionError.FOLLOWER_READ_ONLY: "Write operation rejected: follower regions are read-only",
    MultiRegionError.STALE_FOLLOWER: "Follower data exceeds maximum staleness threshold",
    MultiRegionError.PRIMARY_UNREACHABLE: "Cannot connect to primary region",
    MultiRegionError.REPLICATION_TIMEOUT: "Cross-region replication timeout",
    MultiRegionError.CONFLICT_DETECTED: "Write conflict detected in active-active replication",
    MultiRegionError.GEO_SHARD_MISMATCH: "Entity geo-shard does not match target region",
}

MULTI_REGION_ERROR_RETRYABLE = {
    MultiRegionError.FOLLOWER_READ_ONLY: False,
    MultiRegionError.STALE_FOLLOWER: True,
    MultiRegionError.PRIMARY_UNREACHABLE: True,
    MultiRegionError.REPLICATION_TIMEOUT: True,
    MultiRegionError.CONFLICT_DETECTED: False,
    MultiRegionError.GEO_SHARD_MISMATCH: False,
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
    """
    Sharding error codes (220-224).

    These errors occur during shard routing and resharding operations.
    Per v2 index-sharding/spec.md.

    Attributes:
        NOT_SHARD_LEADER: Code 220 - Node is not the leader for the shard.
            Retryable. Client should refresh topology and retry.
        SHARD_UNAVAILABLE: Code 221 - No replicas available for shard.
            Retryable. Replicas may become available.
        RESHARDING_IN_PROGRESS: Code 222 - Cluster is resharding.
            Retryable. Wait for resharding to complete.
        INVALID_SHARD_COUNT: Code 223 - Requested shard count is invalid.
            Non-retryable. Use a valid shard count (power of 2, max 256).
        SHARD_MIGRATION_FAILED: Code 224 - Data migration failed.
            Non-retryable. Check cluster health.
    """

    NOT_SHARD_LEADER = 220
    """Node is not the leader for target shard. Code: 220. Retryable."""

    SHARD_UNAVAILABLE = 221
    """Target shard has no available replicas. Code: 221. Retryable."""

    RESHARDING_IN_PROGRESS = 222
    """Cluster is currently resharding. Code: 222. Retryable."""

    INVALID_SHARD_COUNT = 223
    """Target shard count is invalid. Code: 223. Non-retryable."""

    SHARD_MIGRATION_FAILED = 224
    """Data migration to new shard failed. Code: 224. Non-retryable."""


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
    """
    Encryption error codes (410-414).

    These errors occur during encryption/decryption operations and
    key management. Per v2 security/spec.md.

    Attributes:
        ENCRYPTION_KEY_UNAVAILABLE: Code 410 - Cannot get key from KMS.
            Retryable. KMS may become available.
        DECRYPTION_FAILED: Code 411 - Decryption failed (auth tag mismatch).
            Non-retryable. Data may be corrupted or tampered.
        ENCRYPTION_NOT_ENABLED: Code 412 - Encryption required but not configured.
            Non-retryable. Enable encryption in configuration.
        KEY_ROTATION_IN_PROGRESS: Code 413 - Key rotation in progress.
            Retryable. Wait for rotation to complete.
        UNSUPPORTED_ENCRYPTION_VERSION: Code 414 - Unsupported encryption version.
            Non-retryable. Upgrade client or decrypt with compatible version.
    """

    ENCRYPTION_KEY_UNAVAILABLE = 410
    """Cannot retrieve encryption key from provider. Code: 410. Retryable."""

    DECRYPTION_FAILED = 411
    """Decryption failed (auth tag mismatch). Code: 411. Non-retryable."""

    ENCRYPTION_NOT_ENABLED = 412
    """Encryption required but not configured. Code: 412. Non-retryable."""

    KEY_ROTATION_IN_PROGRESS = 413
    """Key rotation in progress, retry later. Code: 413. Retryable."""

    UNSUPPORTED_ENCRYPTION_VERSION = 414
    """File encrypted with unsupported version. Code: 414. Non-retryable."""


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
    """Returns the message for any distributed error code."""
    if is_multi_region_error(code):
        return multi_region_error_message(code)
    elif is_sharding_error(code):
        return sharding_error_message(code)
    elif is_encryption_error(code):
        return encryption_error_message(code)
    return None
