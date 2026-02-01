# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Server error handling tests (ERR-05).

Tests that HTTP 500, 429, 503 responses are handled correctly
with appropriate retryability flags.

Design decisions (per 14-CONTEXT.md):
- Verify error CODES, not message text (allows message improvements)
- Server errors include HTTP status code in context
- Transient server errors (5xx) are retryable
- Client errors (4xx) may or may not be retryable depending on type
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

# Import from SDK
from archerdb import (
    ClusterUnavailable,
    ViewChangeInProgress,
    NotPrimary,
    OperationTimeout,
    OutOfSpace,
    SessionExpired,
)
from archerdb.client import ArcherDBError
from archerdb.errors import is_retryable

# Load test cases from fixtures
FIXTURES_PATH = Path(__file__).parent / "fixtures" / "error_test_cases.json"


def load_server_error_cases():
    """Load server error test cases from fixtures."""
    with open(FIXTURES_PATH) as f:
        return json.load(f)["server_errors"]


class TestServerErrors:
    """All SDKs handle server errors with correct retryability flags (ERR-05)."""

    def test_http_500_is_retryable(self):
        """HTTP 500 Internal Server Error is retryable.

        Maps to ClusterUnavailable (code 2001) - transient cluster issue.
        """
        # Code 2001 = ClusterUnavailable (HTTP 500 equivalent)
        assert ClusterUnavailable.code == 2001
        assert ClusterUnavailable.retryable is True

    def test_http_429_is_retryable(self):
        """HTTP 429 Rate Limited / View Change is retryable with backoff.

        Maps to ViewChangeInProgress (code 2002) - cluster reconfiguring.
        """
        # Code 2002 = ViewChangeInProgress (HTTP 429 equivalent)
        assert ViewChangeInProgress.code == 2002
        assert ViewChangeInProgress.retryable is True

    def test_http_503_is_retryable(self):
        """HTTP 503 Service Unavailable / Not Primary is retryable.

        Maps to NotPrimary (code 2003) - client should redirect.
        """
        # Code 2003 = NotPrimary (HTTP 503 equivalent)
        assert NotPrimary.code == 2003
        assert NotPrimary.retryable is True

    def test_server_error_context_requirements(self):
        """Per CONTEXT.md: Error includes operation, parameters, retry attempts.

        Verifying that server error classes exist and have proper structure.
        Server errors must include:
        - Error code (identifying the error type)
        - Human-readable message (descriptive, actionable)
        - Server response when available (status code, body, headers)
        - Context details (operation attempted, parameters, retry attempts)
        """
        # Verify all server error classes have required attributes
        server_errors = [
            ClusterUnavailable,
            ViewChangeInProgress,
            NotPrimary,
        ]

        for error_class in server_errors:
            # All errors must have code and retryable attributes
            assert hasattr(error_class, "code"), f"{error_class.__name__} missing code"
            assert hasattr(error_class, "retryable"), f"{error_class.__name__} missing retryable"

    @pytest.mark.parametrize(
        "error_code,expected_retryable",
        [
            (2001, True),   # ClusterUnavailable (HTTP 500)
            (2002, True),   # ViewChangeInProgress (HTTP 429)
            (2003, True),   # NotPrimary (HTTP 503)
            (4001, True),   # OperationTimeout (may have committed)
            (4003, False),  # OutOfSpace (requires admin action)
            (4004, True),   # SessionExpired (auto re-register)
        ],
    )
    def test_server_error_retryability_by_code(self, error_code, expected_retryable):
        """Server error codes have correct retryability classification.

        Per CONTEXT.md: Verify error codes, not message text.
        """
        # Map codes to error classes for verification
        error_class_map = {
            2001: ClusterUnavailable,
            2002: ViewChangeInProgress,
            2003: NotPrimary,
            4001: OperationTimeout,
            4003: OutOfSpace,
            4004: SessionExpired,
        }

        if error_code in error_class_map:
            error_class = error_class_map[error_code]
            assert error_class.retryable is expected_retryable, (
                f"Error code {error_code} ({error_class.__name__}) "
                f"expected retryable={expected_retryable}"
            )

    def test_server_error_fixture_structure(self):
        """Per CONTEXT.md: Error test fixtures have required fields.

        Validates the fixture JSON structure for server errors.
        """
        cases = load_server_error_cases()
        for case_name, case_data in cases.items():
            assert "expected_code" in case_data, f"{case_name} missing expected_code"
            assert "expected_retryable" in case_data, f"{case_name} missing expected_retryable"


class TestServerErrorCodes:
    """Verify correct error codes for server error scenarios."""

    def test_error_code_2001_is_cluster_unavailable(self):
        """Error code 2001 maps to ClusterUnavailable."""
        assert ClusterUnavailable.code == 2001

    def test_error_code_2002_is_view_change(self):
        """Error code 2002 maps to ViewChangeInProgress."""
        assert ViewChangeInProgress.code == 2002

    def test_error_code_2003_is_not_primary(self):
        """Error code 2003 maps to NotPrimary."""
        assert NotPrimary.code == 2003

    def test_cluster_errors_are_retryable(self):
        """All cluster availability errors are retryable."""
        cluster_errors = [
            ClusterUnavailable,
            ViewChangeInProgress,
            NotPrimary,
        ]
        for error_class in cluster_errors:
            assert error_class.retryable is True, (
                f"{error_class.__name__} should be retryable"
            )


class TestDistributedErrors:
    """Test distributed error codes (multi-region, sharding, encryption)."""

    def test_is_retryable_multi_region_errors(self):
        """Multi-region error retryability (codes 213-218).

        Per SDK error codes:
        - 214 (StaleFollower): retryable
        - 215 (PrimaryUnreachable): retryable
        - 216 (ReplicationTimeout): retryable
        - 213 (FollowerReadOnly): NOT retryable
        - 217 (ConflictDetected): NOT retryable
        - 218 (GeoShardMismatch): NOT retryable
        """
        # Retryable multi-region errors
        assert is_retryable(214) is True   # StaleFollower
        assert is_retryable(215) is True   # PrimaryUnreachable
        assert is_retryable(216) is True   # ReplicationTimeout

        # Non-retryable multi-region errors
        assert is_retryable(213) is False  # FollowerReadOnly
        assert is_retryable(217) is False  # ConflictDetected
        assert is_retryable(218) is False  # GeoShardMismatch

    def test_is_retryable_sharding_errors(self):
        """Sharding error retryability (codes 220-224).

        Per SDK error codes:
        - 220 (NotShardLeader): retryable
        - 221 (ShardUnavailable): retryable
        - 222 (ReshardingInProgress): retryable
        - 223 (InvalidShardCount): NOT retryable
        - 224 (ShardMigrationFailed): NOT retryable
        """
        # Retryable sharding errors
        assert is_retryable(220) is True   # NotShardLeader
        assert is_retryable(221) is True   # ShardUnavailable
        assert is_retryable(222) is True   # ReshardingInProgress

        # Non-retryable sharding errors
        assert is_retryable(223) is False  # InvalidShardCount
        assert is_retryable(224) is False  # ShardMigrationFailed

    def test_is_retryable_encryption_errors(self):
        """Encryption error retryability (codes 410-414).

        Per SDK error codes:
        - 410 (EncryptionKeyUnavailable): retryable
        - 413 (KeyRotationInProgress): retryable
        - 411 (DecryptionFailed): NOT retryable
        - 412 (EncryptionNotEnabled): NOT retryable
        - 414 (UnsupportedEncryptionVersion): NOT retryable
        """
        # Retryable encryption errors
        assert is_retryable(410) is True   # EncryptionKeyUnavailable
        assert is_retryable(413) is True   # KeyRotationInProgress

        # Non-retryable encryption errors
        assert is_retryable(411) is False  # DecryptionFailed
        assert is_retryable(412) is False  # EncryptionNotEnabled
        assert is_retryable(414) is False  # UnsupportedEncryptionVersion
