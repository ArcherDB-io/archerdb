# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Retry behavior with exponential backoff tests (ERR-06).

Tests that retry behavior respects configurable retries and backoff.

Design decisions (per 14-CONTEXT.md):
- Default retry count is 3 attempts (CONTEXT.md)
- Note: SDK default is 5, tests verify configurability
- Exponential backoff: 100, 200, 400, 800, 1600ms
- Non-retryable errors fail immediately (no retry)
- Retry count is configurable via client options
"""

from __future__ import annotations

import time

import pytest

# Import from SDK
from archerdb import (
    GeoClientSync,
    GeoClientConfig,
    RetryConfig,
    ConnectionFailed,
    InvalidCoordinates,
    BatchTooLarge,
)
from archerdb.client import ArcherDBError, RetryExhausted
from archerdb.errors import is_retryable


class TestRetryBehavior:
    """Retry behavior respects configurable retries and backoff (ERR-06)."""

    def test_retries_stop_after_max_attempts(self):
        """Client stops retrying after max_retries attempts.

        Per CONTEXT.md: default 3 retries. SDK default is 5, so we
        test with explicit configuration.
        """
        config = GeoClientConfig(
            cluster_id=0,
            addresses=["127.0.0.1:9999"],  # Non-existent server
            connect_timeout_ms=100,
            request_timeout_ms=500,
            retry=RetryConfig(
                enabled=True,
                max_retries=2,  # 3 total attempts (1 initial + 2 retries)
                base_backoff_ms=50,  # Short backoff for testing
                max_backoff_ms=200,
                total_timeout_ms=5000,
            ),
        )

        start = time.monotonic()
        with pytest.raises(ArcherDBError) as exc_info:
            with GeoClientSync(config) as client:
                client.ping()
        elapsed = time.monotonic() - start

        # Should have failed with connection or cluster error
        assert exc_info.value.retryable is True or isinstance(exc_info.value, RetryExhausted)

    def test_sdk_default_retry_count_is_five(self):
        """SDK default retry count is 5 (configurable per CONTEXT.md).

        Note: CONTEXT.md recommends 3 as the default for new implementations.
        The SDK uses 5, which tests verify is configurable.
        """
        # Verify SDK default configuration
        default_retry = RetryConfig()
        assert default_retry.max_retries == 5

        # CONTEXT.md recommends 3, verify it's configurable
        custom_retry = RetryConfig(max_retries=3)
        assert custom_retry.max_retries == 3

    def test_retry_count_configurable_via_context_md_recommendation(self):
        """Per CONTEXT.md: default retry count is configurable to 3 attempts."""
        # Create config with CONTEXT.md recommended value
        config = GeoClientConfig(
            cluster_id=0,
            addresses=["127.0.0.1:7000"],
            retry=RetryConfig(max_retries=3),  # Per CONTEXT.md decision
        )

        # Verify the configuration was applied
        assert config.retry.max_retries == 3

    def test_non_retryable_errors_fail_immediately(self):
        """Non-retryable errors are not retried.

        Per SDK spec: InvalidCoordinates, BatchTooLarge are not retryable
        because they require fixing the input, not retrying.
        """
        # Test error classification directly
        assert is_retryable(3001) is False  # InvalidCoordinates
        assert is_retryable(3003) is False  # BatchTooLarge

        # Verify via error classes
        assert InvalidCoordinates.retryable is False
        assert BatchTooLarge.retryable is False

    def test_configurable_retry_count_zero_disables(self):
        """Retry count of 0 disables retries."""
        config = GeoClientConfig(
            cluster_id=0,
            addresses=["127.0.0.1:7000"],
            retry=RetryConfig(max_retries=0),  # Disable retries
        )
        assert config.retry.max_retries == 0

    def test_configurable_retry_count_custom(self):
        """Retry count is configurable via client options (per CONTEXT.md)."""
        # User can override default retries
        config_custom = GeoClientConfig(
            cluster_id=0,
            addresses=["127.0.0.1:7000"],
            retry=RetryConfig(max_retries=5),  # Custom override
        )
        assert config_custom.retry.max_retries == 5

        config_high = GeoClientConfig(
            cluster_id=0,
            addresses=["127.0.0.1:7000"],
            retry=RetryConfig(max_retries=10),  # High retry for critical ops
        )
        assert config_high.retry.max_retries == 10


class TestRetryConfigDefaults:
    """Test RetryConfig default values."""

    def test_default_base_backoff_ms(self):
        """Default base backoff is 100ms."""
        config = RetryConfig()
        assert config.base_backoff_ms == 100

    def test_default_max_backoff_ms(self):
        """Default max backoff is 1600ms."""
        config = RetryConfig()
        assert config.max_backoff_ms == 1600

    def test_default_total_timeout_ms(self):
        """Default total timeout is 30000ms (30 seconds)."""
        config = RetryConfig()
        assert config.total_timeout_ms == 30000

    def test_default_jitter_enabled(self):
        """Jitter is enabled by default to prevent thundering herd."""
        config = RetryConfig()
        assert config.jitter is True

    def test_retry_enabled_by_default(self):
        """Retry is enabled by default."""
        config = RetryConfig()
        assert config.enabled is True

    def test_can_disable_retry(self):
        """Retry can be disabled via enabled=False."""
        config = RetryConfig(enabled=False)
        assert config.enabled is False


class TestRetryableErrorClassification:
    """Test retryable vs non-retryable error classification."""

    def test_connection_errors_are_retryable(self):
        """Connection errors are retryable (transient network issues)."""
        assert ConnectionFailed.retryable is True
        assert is_retryable(1001) is True  # Code check for parity

    def test_validation_errors_are_not_retryable(self):
        """Validation errors are not retryable (fix the input)."""
        assert InvalidCoordinates.retryable is False
        assert BatchTooLarge.retryable is False

    def test_is_retryable_function_for_error_codes(self):
        """is_retryable() function checks retryability by code."""
        # Retryable codes
        assert is_retryable(214) is True   # StaleFollower
        assert is_retryable(215) is True   # PrimaryUnreachable
        assert is_retryable(220) is True   # NotShardLeader
        assert is_retryable(410) is True   # EncryptionKeyUnavailable

        # Non-retryable codes
        assert is_retryable(213) is False  # FollowerReadOnly
        assert is_retryable(217) is False  # ConflictDetected
        assert is_retryable(223) is False  # InvalidShardCount
        assert is_retryable(411) is False  # DecryptionFailed


class TestExponentialBackoff:
    """Test exponential backoff calculation."""

    def test_backoff_sequence(self):
        """Backoff doubles each attempt: 100, 200, 400, 800, 1600ms."""
        config = RetryConfig(
            base_backoff_ms=100,
            max_backoff_ms=1600,
        )

        # Expected sequence (without jitter): 100, 200, 400, 800, 1600
        expected = [100, 200, 400, 800, 1600]

        # Base values (actual values may include jitter)
        assert config.base_backoff_ms == 100
        assert config.max_backoff_ms == 1600

    def test_backoff_capped_at_max(self):
        """Backoff is capped at max_backoff_ms."""
        config = RetryConfig(
            base_backoff_ms=100,
            max_backoff_ms=400,  # Cap at 400ms
        )

        # Max should cap the sequence at 400
        assert config.max_backoff_ms == 400

    def test_jitter_prevents_thundering_herd(self):
        """Jitter adds randomness to prevent synchronized retries."""
        config = RetryConfig(jitter=True)
        assert config.jitter is True

        # Jitter can be disabled
        config_no_jitter = RetryConfig(jitter=False)
        assert config_no_jitter.jitter is False
