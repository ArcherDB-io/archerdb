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

    def test_connection_failed_is_retryable(self):
        """ConnectionFailed errors are classified as retryable.

        Per SDK spec: Connection failures are transient and should be
        retried with exponential backoff.
        """
        # Test the error class attributes directly
        assert ConnectionFailed.code == 1001
        assert ConnectionFailed.retryable is True

    def test_connection_config_with_multiple_addresses(self):
        """Client configuration supports multiple addresses.

        When multiple addresses are provided, the client should be
        configured to try each one.
        """
        config = GeoClientConfig(
            cluster_id=0,
            addresses=[
                "127.0.0.1:9991",
                "127.0.0.1:9992",
                "127.0.0.1:9993",
            ],
            connect_timeout_ms=500,
            request_timeout_ms=2000,
            retry=RetryConfig(
                enabled=True,
                max_retries=0,
            ),
        )

        # Verify configuration was applied
        assert len(config.addresses) == 3
        assert config.connect_timeout_ms == 500


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
