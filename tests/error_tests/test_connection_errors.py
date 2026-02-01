# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Connection failure error handling tests (ERR-01).

Tests that all SDKs handle connection failures gracefully with correct
error codes and retryability flags.

Design decisions (per 14-CONTEXT.md):
- Verify error CODES, not message text (allows message improvements)
- Connection errors are retryable (transient network issues)
- Error context should include server address
"""

from __future__ import annotations

import pytest

# Import from SDK
from archerdb import GeoClientSync, GeoClientConfig, RetryConfig
from archerdb import ConnectionFailed, ConnectionTimeout
from archerdb.client import ArcherDBError


class TestConnectionErrors:
    """All SDKs handle connection failures gracefully (ERR-01)."""

    def test_connection_refused_returns_error_code(self, nonexistent_server_config):
        """Connection to non-existent server returns correct error code.

        Per CONTEXT.md: Verify error CODE (1001), not message text.
        """
        with pytest.raises(ArcherDBError) as exc_info:
            with GeoClientSync(nonexistent_server_config) as client:
                client.ping()

        # Verify by error CODE per CONTEXT.md (not message text)
        assert exc_info.value.code == 1001  # ConnectionFailed
        assert exc_info.value.retryable is True

    def test_connection_refused_specific_exception(self, nonexistent_server_config):
        """Connection refused raises ConnectionFailed exception type."""
        with pytest.raises(ConnectionFailed) as exc_info:
            with GeoClientSync(nonexistent_server_config) as client:
                client.ping()

        # Verify exception attributes
        assert exc_info.value.code == 1001
        assert exc_info.value.retryable is True

    def test_connection_error_includes_context(self, nonexistent_server_config):
        """Error includes server address in context (per CONTEXT.md).

        Per CONTEXT.md: Context details should include operation attempted
        and parameters. We check that address is included but don't assert
        exact format.
        """
        with pytest.raises(ArcherDBError) as exc_info:
            with GeoClientSync(nonexistent_server_config) as client:
                client.ping()

        # Address should be in message (context), but don't assert exact format
        error_str = str(exc_info.value)
        # Either the IP or port should appear in the error context
        assert "127.0.0.1" in error_str or "9999" in error_str

    def test_connection_failed_is_retryable(self):
        """ConnectionFailed errors are classified as retryable.

        Per SDK spec: Connection failures are transient and should be
        retried with exponential backoff.
        """
        # Test the error class attributes directly
        assert ConnectionFailed.code == 1001
        assert ConnectionFailed.retryable is True

    def test_connection_with_multiple_bad_addresses(self):
        """Client tries all addresses before failing.

        When multiple addresses are provided, the client should try
        each one before reporting connection failure.
        """
        config = GeoClientConfig(
            cluster_id=0,
            addresses=[
                "127.0.0.1:9991",
                "127.0.0.1:9992",
                "127.0.0.1:9993",
            ],
            connect_timeout_ms=500,  # Short timeout per address
            request_timeout_ms=2000,
            retry=RetryConfig(
                enabled=True,
                max_retries=0,  # No retries - just try each address once
            ),
        )

        with pytest.raises(ArcherDBError) as exc_info:
            with GeoClientSync(config) as client:
                client.ping()

        # Should fail with connection error after trying all addresses
        assert exc_info.value.code in [1001, 2001]  # ConnectionFailed or ClusterUnavailable
        assert exc_info.value.retryable is True


class TestConnectionErrorCodes:
    """Verify correct error codes for different connection scenarios."""

    def test_error_code_1001_is_connection_failed(self):
        """Error code 1001 maps to ConnectionFailed."""
        assert ConnectionFailed.code == 1001

    def test_error_code_1002_is_connection_timeout(self):
        """Error code 1002 maps to ConnectionTimeout."""
        assert ConnectionTimeout.code == 1002

    def test_connection_errors_are_retryable(self):
        """All connection errors should be retryable."""
        assert ConnectionFailed.retryable is True
        assert ConnectionTimeout.retryable is True
