# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Timeout error handling tests (ERR-02).

Tests that all SDKs handle timeouts gracefully with correct error codes
and retryability flags.

Design decisions (per 14-CONTEXT.md):
- Verify error CODES, not message text
- Timeout errors are retryable (network may recover)
- Use non-routable IP (10.255.255.1) for reliable timeout testing
"""

from __future__ import annotations

import pytest

# Import from SDK
from archerdb import GeoClientSync, GeoClientConfig, RetryConfig
from archerdb import ConnectionTimeout, OperationTimeout
from archerdb.client import ArcherDBError


class TestTimeoutErrors:
    """All SDKs handle timeouts gracefully (ERR-02)."""

    def test_connection_timeout_specific_exception(self):
        """ConnectionTimeout has correct error code and is retryable."""
        # Test the error class attributes directly
        assert ConnectionTimeout.code == 1002
        assert ConnectionTimeout.retryable is True

    def test_operation_timeout_is_retryable(self):
        """OperationTimeout errors are classified as retryable.

        Per SDK spec: Operation timeouts may have committed - retry
        with same request_number for idempotency.
        """
        # Test the error class attributes directly
        assert OperationTimeout.code == 4001
        assert OperationTimeout.retryable is True

    def test_short_connect_timeout_configuration(self):
        """Very short connect timeout can be configured.

        Per SDK spec: connect_timeout_ms limits TCP handshake time.
        """
        config = GeoClientConfig(
            cluster_id=0,
            addresses=["10.255.255.1:9999"],  # Non-routable IP
            connect_timeout_ms=100,  # Very short - 100ms
            request_timeout_ms=200,
            retry=RetryConfig(
                enabled=True,
                max_retries=0,  # No retries
            ),
        )

        # Verify configuration was applied
        assert config.connect_timeout_ms == 100
        assert config.request_timeout_ms == 200


class TestTimeoutErrorCodes:
    """Verify correct error codes for timeout scenarios."""

    def test_error_code_1002_is_connection_timeout(self):
        """Error code 1002 maps to ConnectionTimeout."""
        assert ConnectionTimeout.code == 1002

    def test_error_code_4001_is_operation_timeout(self):
        """Error code 4001 maps to OperationTimeout."""
        assert OperationTimeout.code == 4001

    def test_timeout_errors_are_retryable(self):
        """All timeout errors should be retryable."""
        assert ConnectionTimeout.retryable is True
        assert OperationTimeout.retryable is True

    def test_timeout_error_codes_distinct(self):
        """Connection and operation timeouts have different codes."""
        # Connection timeout (TCP handshake) vs Operation timeout (request)
        assert ConnectionTimeout.code != OperationTimeout.code
        assert ConnectionTimeout.code == 1002
        assert OperationTimeout.code == 4001
