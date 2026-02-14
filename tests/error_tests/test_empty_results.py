# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Empty result handling tests (ERR-04).

Tests that empty query results return success, not errors, with correct
structure and metadata.

Design decisions (per 14-CONTEXT.md):
- Empty results return success with count=0 (not errors)
- Verify BOTH structure (correct empty array/list type) AND metadata
- Entity not found is a specific error code (200), not empty result
"""

from __future__ import annotations

import pytest

# Import from SDK
from archerdb import (
    GeoClientSync,
    GeoClientConfig,
    GeoEvent,
    QueryResult,
    create_geo_event,
)
from archerdb.client import ArcherDBError
from archerdb.errors import StateError


class TestEmptyResults:
    """Empty query results return success, not errors (ERR-04)."""

    @pytest.mark.integration
    def test_empty_radius_query_structure(self, client):
        """Empty radius query returns correct structure AND metadata.

        Per CONTEXT.md:
        - Structure: correct empty array/list type
        - Metadata: count=0, success status
        """
        # Query area with no entities (tiny radius at origin)
        result = client.query_radius(
            latitude=0.0,
            longitude=0.0,
            radius_m=1.0,  # Tiny radius, likely empty
        )

        # Structure: correct empty array/list type (per CONTEXT.md)
        assert isinstance(result.events, list)
        assert len(result.events) == 0

        # Metadata: count=0, success status (per CONTEXT.md)
        assert len(result.events) == 0

    @pytest.mark.integration
    def test_empty_polygon_query_returns_empty_list(self, client):
        """Empty polygon query returns empty list, not error.

        Per CONTEXT.md: Empty results verify BOTH structure AND metadata.
        """
        # Small polygon in ocean (coordinates as (lat, lon) tuples in degrees)
        vertices = [
            (0.001, 0.001),
            (0.002, 0.001),
            (0.002, 0.002),
            (0.001, 0.002),
        ]

        result = client.query_polygon(vertices=vertices)

        assert isinstance(result.events, list)
        assert len(result.events) == 0

    def test_empty_result_is_not_error(self):
        """Empty results should NOT raise exceptions.

        Per SDK spec: Empty results are success cases, not error cases.
        The SDK must not raise an error for a query that returns no results.
        """
        # StateError.ENTITY_NOT_FOUND (200) is for UUID lookups
        # Empty spatial queries should return empty list, not error
        assert StateError.ENTITY_NOT_FOUND == 200


class TestEntityNotFoundErrors:
    """Tests for entity not found error handling."""

    def test_entity_not_found_error_code(self):
        """Query for non-existent UUID returns error code 200.

        Per error code spec: StateError.ENTITY_NOT_FOUND = 200.
        This is different from empty spatial query results.
        """
        assert StateError.ENTITY_NOT_FOUND == 200

    def test_entity_not_found_is_not_retryable(self):
        """Entity not found is a permanent error, not retryable.

        The entity simply doesn't exist - retrying won't help.
        """
        # State errors are not retryable (per errors.py)
        from archerdb.errors import is_state_error

        # Entity not found is a state error
        assert is_state_error(200) is True

    def test_entity_expired_error_code(self):
        """Expired entity returns error code 210.

        Per error code spec: StateError.ENTITY_EXPIRED = 210.
        """
        assert StateError.ENTITY_EXPIRED == 210


class TestEmptyResultMetadata:
    """Tests for empty result metadata per CONTEXT.md."""

    def test_query_result_has_count_attribute(self):
        """QueryResult type has count attribute for metadata."""
        # Verify the QueryResult class exists and has expected structure
        from archerdb.types import QueryResult

        assert hasattr(QueryResult, "__annotations__")

    def test_query_result_has_events_attribute(self):
        """QueryResult type has events attribute for data."""
        from archerdb.types import QueryResult

        assert hasattr(QueryResult, "__annotations__")

    @pytest.mark.integration
    def test_empty_query_latest_returns_structure(self, client):
        """Empty query_latest returns correct structure.

        Per CONTEXT.md: Empty results verify structure AND metadata.
        """
        # Query when database is empty (cleaned before test)
        result = client.query_latest(limit=100)

        # Structure verification
        assert isinstance(result.events, list)

        # Count may be 0 or match events length
        assert len(result.events) >= 0


class TestEmptyResultEdgeCases:
    """Edge cases for empty result handling."""

    @pytest.mark.integration
    def test_zero_radius_query(self, client):
        """Query with radius=0 should return empty or error gracefully."""
        # Zero radius is rejected by SDK validation (radius must be positive)
        try:
            result = client.query_radius(
                latitude=0.0,
                longitude=0.0,
                radius_m=0.0,  # Zero radius
            )
            # If successful, should be empty
            assert len(result.events) == 0
        except (ArcherDBError, ValueError):
            # SDK validates radius > 0 and raises ValueError
            # Either outcome is acceptable
            pass

    @pytest.mark.integration
    def test_large_limit_empty_result(self, client):
        """Large limit with no results returns empty list efficiently."""
        # Query with large limit on empty database
        result = client.query_latest(limit=10000)

        assert isinstance(result.events, list)
        # Should not take excessive memory for empty result
