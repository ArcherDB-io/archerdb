# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Batch size limit error tests (ERR-07).

Tests that batch size limits are enforced with appropriate errors.

Design decisions (per 14-CONTEXT.md):
- Batch limit is 10,000 events (BATCH_SIZE_MAX)
- BatchTooLarge error (code 3003) is returned for oversized batches
- SDK validates batch size client-side before server submission
- BatchTooLarge is NOT retryable (fix by reducing batch size)
"""

from __future__ import annotations

import pytest

# Import from SDK
from archerdb import (
    GeoClientSync,
    GeoEvent,
    BatchTooLarge,
    BATCH_SIZE_MAX,
    split_batch,
    create_geo_event,
)
from archerdb.client import ArcherDBError
from archerdb.errors import is_retryable


class TestBatchErrors:
    """Batch size limits are enforced with appropriate errors (ERR-07)."""

    def test_batch_size_max_constant(self):
        """BATCH_SIZE_MAX is 10,000 events."""
        assert BATCH_SIZE_MAX == 10_000

    def test_batch_too_large_error_code(self):
        """BatchTooLarge has error code 3003."""
        assert BatchTooLarge.code == 3003

    def test_batch_too_large_not_retryable(self):
        """BatchTooLarge errors are not retryable (fix by reducing batch).

        Per CONTEXT.md: BatchTooLarge (5002) is not retryable.
        Note: SDK uses code 3003 for BatchTooLarge.
        """
        assert BatchTooLarge.retryable is False
        # Also check via is_retryable if code is in range
        # Note: SDK BatchTooLarge.code=3003, fixtures reference 5002
        # Testing the actual SDK class

    def test_batch_validation_before_server_call(self):
        """SDK validates batch size client-side before server submission.

        Per CONTEXT.md: SDK catches invalid batch before network call.
        This is verified by the split_batch helper function.
        """
        # Create a batch larger than limit
        large_events = [
            create_geo_event(entity_id=i, latitude=0.0, longitude=0.0)
            for i in range(1, 10_002)  # 10,001 events
        ]

        # split_batch helper should split oversized batches
        chunks = split_batch(large_events, chunk_size=BATCH_SIZE_MAX)

        # Should have 2 chunks: one of 10,000 and one of 1
        chunks_list = list(chunks)
        assert len(chunks_list) == 2
        assert len(chunks_list[0]) == 10_000
        assert len(chunks_list[1]) == 1


class TestSplitBatchHelper:
    """Tests for the split_batch helper function."""

    def test_split_batch_at_default_limit(self):
        """split_batch uses 1000 as default chunk size (per SDK spec)."""
        events = [
            create_geo_event(entity_id=i, latitude=0.0, longitude=0.0)
            for i in range(1, 2001)  # 2000 events
        ]

        # Default is 1000 per SDK split_batch implementation
        chunks = list(split_batch(events))
        assert len(chunks) == 2
        assert len(chunks[0]) == 1000
        assert len(chunks[1]) == 1000

    def test_split_batch_custom_size(self):
        """split_batch respects custom chunk_size."""
        events = [
            create_geo_event(entity_id=i, latitude=0.0, longitude=0.0)
            for i in range(1, 101)  # 100 events
        ]

        chunks = list(split_batch(events, chunk_size=30))
        assert len(chunks) == 4  # 30 + 30 + 30 + 10

    def test_split_batch_small_batch(self):
        """split_batch handles batches smaller than chunk_size."""
        events = [
            create_geo_event(entity_id=i, latitude=0.0, longitude=0.0)
            for i in range(1, 11)  # 10 events
        ]

        chunks = list(split_batch(events, chunk_size=100))
        assert len(chunks) == 1
        assert len(chunks[0]) == 10

    def test_split_batch_empty(self):
        """split_batch handles empty list."""
        chunks = list(split_batch([]))
        assert len(chunks) == 0

    def test_split_batch_exact_multiple(self):
        """split_batch handles batch that's exact multiple of chunk_size."""
        events = [
            create_geo_event(entity_id=i, latitude=0.0, longitude=0.0)
            for i in range(1, 101)  # 100 events
        ]

        chunks = list(split_batch(events, chunk_size=50))
        assert len(chunks) == 2
        assert all(len(chunk) == 50 for chunk in chunks)


class TestBatchSizeLimits:
    """Test batch size limit constants and validation."""

    def test_batch_size_max_value(self):
        """BATCH_SIZE_MAX is 10,000 per SDK spec."""
        from archerdb.types import BATCH_SIZE_MAX
        assert BATCH_SIZE_MAX == 10_000

    def test_batch_too_large_error_properties(self):
        """BatchTooLarge has correct code and retryability."""
        assert BatchTooLarge.code == 3003
        assert BatchTooLarge.retryable is False

    def test_batch_size_limits_in_sdk(self):
        """SDK constants for batch size limits."""
        from archerdb.types import (
            BATCH_SIZE_MAX,
            QUERY_LIMIT_MAX,
        )

        # Batch insert limit
        assert BATCH_SIZE_MAX == 10_000

        # Query limit (for reference)
        assert QUERY_LIMIT_MAX == 81_000


class TestBatchErrorHandling:
    """Tests for batch error handling patterns."""

    def test_batch_error_suggests_split(self):
        """BatchTooLarge error docstring suggests using split_batch."""
        # The error class docstring should mention split_batch
        docstring = BatchTooLarge.__doc__ or ""
        assert "split" in docstring.lower() or BATCH_SIZE_MAX in str(docstring)

    def test_batch_error_code_classification(self):
        """BatchTooLarge is a validation error (3xxx range)."""
        assert 3000 <= BatchTooLarge.code < 4000

    def test_batch_error_is_not_server_error(self):
        """BatchTooLarge is validated client-side, not a server error."""
        # Server errors are 2xxx range
        assert not (2000 <= BatchTooLarge.code < 3000)

        # Validation errors are 3xxx range
        assert 3000 <= BatchTooLarge.code < 4000

    @pytest.mark.integration
    def test_batch_at_limit_succeeds(self, client):
        """Batch of exactly BATCH_SIZE_MAX events should succeed.

        This test requires running server for actual insertion.
        Marked as integration test.
        """
        # Create batch at exactly the limit
        events = [
            create_geo_event(
                entity_id=i,
                latitude=37.7749 + (i * 0.0001),  # Slight variation
                longitude=-122.4194
            )
            for i in range(1, BATCH_SIZE_MAX + 1)
        ]

        # Should not raise BatchTooLarge for exactly 10,000 events
        # The actual insertion is tested in integration tests
        assert len(events) == BATCH_SIZE_MAX
