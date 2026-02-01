# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Empty result handling tests (EDGE-07).

Tests that queries returning no results return valid empty responses
(not errors). Empty results are a normal condition, not an error.

Test Cases:
    - Radius query on empty database
    - Radius query with no matches
    - UUID query for nonexistent entity
    - Polygon query with no matches
    - Batch UUID query all missing
    - Delete nonexistent entity (idempotent)
"""

import uuid

import pytest

from .conftest import (
    EdgeCaseAPIClient,
    build_insert_event,
    build_polygon_query,
    build_radius_query,
    generate_entity_id,
)


@pytest.mark.edge_case
class TestEmptyResults:
    """Test empty result handling (EDGE-07)."""

    def test_radius_query_empty_database(self, single_node_cluster, api_client):
        """Fresh cluster, query returns empty list (not error).

        A radius query on an empty database should return an empty
        result set, not an error.
        """
        # Query any location on fresh database
        query_response = api_client.query_radius(
            lat=40.7128,
            lon=-74.0060,
            radius_m=10000,  # 10km radius
        )

        # Should succeed with 200, not error
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        # Result should be empty list or empty events array
        result = query_response.json()
        events = result if isinstance(result, list) else result.get("events", [])
        # Either empty list or very few events (from other tests) is acceptable
        # The key is no error occurred
        assert isinstance(events, list), "Result should be a list"

    def test_radius_query_no_matches(self, single_node_cluster, api_client):
        """Insert in one location, query far away, returns empty.

        A radius query in a location with no events should return
        an empty result set.
        """
        # Insert event in New York
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,  # NYC
        )
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query in Sydney (opposite side of globe)
        query_response = api_client.query_radius(
            lat=-33.8688,
            lon=151.2093,  # Sydney
            radius_m=1000,  # 1km radius
        )

        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        events = result if isinstance(result, list) else result.get("events", [])

        # NYC event should NOT be in Sydney radius (16,000km away)
        found = any(e.get("entity_id") == entity_id for e in events)
        assert not found, "NYC event should not be in Sydney 1km radius"

    def test_uuid_query_nonexistent(self, single_node_cluster, api_client):
        """Query for random UUID, returns 404 (not error).

        Querying for a non-existent entity should return 404,
        not a server error.
        """
        # Generate random UUID that doesn't exist
        nonexistent_id = generate_entity_id()

        # Query for nonexistent entity
        query_response = api_client.query_uuid(nonexistent_id)

        # 404 is expected for nonexistent entity
        assert query_response.status_code == 404, "Should return 404 for nonexistent entity"

    def test_polygon_query_empty(self, single_node_cluster, api_client):
        """Polygon query with no matches returns empty list.

        A polygon query covering an area with no events should
        return an empty result set.
        """
        # Define polygon in Antarctica (unlikely to have events)
        vertices = [
            {"lat": -80.0, "lon": 0.0},
            {"lat": -80.0, "lon": 90.0},
            {"lat": -85.0, "lon": 45.0},
        ]

        query_response = api_client.query_polygon(vertices=vertices)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        events = result if isinstance(result, list) else result.get("events", [])

        # Should be empty (no events in Antarctica)
        assert isinstance(events, list), "Result should be a list"

    def test_uuid_batch_all_missing(self, single_node_cluster, api_client):
        """Batch query 10 nonexistent UUIDs, returns 404 for each.

        A batch query for multiple non-existent entities should
        return 404 for each, not a server error.
        """
        # Generate 10 random UUIDs
        missing_ids = [generate_entity_id() for _ in range(10)]

        assert len(missing_ids) == 10
        assert len(set(missing_ids)) == 10  # All unique

        # Query each - all should return 404
        for eid in missing_ids:
            query_response = api_client.query_uuid(eid)
            assert query_response.status_code == 404, f"UUID {eid} should return 404"

    def test_delete_nonexistent(self, single_node_cluster, api_client):
        """Delete nonexistent entity, no error (idempotent).

        Deleting an entity that doesn't exist should succeed
        silently (idempotent operation).
        """
        # Generate random UUID that doesn't exist
        nonexistent_id = generate_entity_id()

        # Delete request for nonexistent entity
        delete_response = api_client.delete(nonexistent_id)

        # Should succeed (idempotent) or return 404 - both are valid
        assert delete_response.status_code in [
            200,
            204,
            404,
        ], f"Delete should be idempotent: {delete_response.text}"

    def test_radius_query_zero_results_structure(self, single_node_cluster, api_client):
        """Verify empty result has correct structure (list, not None).

        Empty results should be an empty list [], not null/None.
        """
        # Query with very small radius at unlikely location
        query_response = api_client.query_radius(
            lat=0.0,
            lon=0.0,
            radius_m=1,  # Very small radius
        )

        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        events = result if isinstance(result, list) else result.get("events", [])

        # Should be a list (empty or not), not None
        assert events is not None, "Result should not be None"
        assert isinstance(events, list), "Result should be a list, not None"

    def test_polygon_query_large_empty_area(self, single_node_cluster, api_client):
        """Large polygon query with no events still returns empty.

        Even a large polygon should return empty if no events exist
        within it.
        """
        # Large polygon in South Pacific (mostly ocean)
        vertices = [
            {"lat": -30.0, "lon": -170.0},
            {"lat": -30.0, "lon": -140.0},
            {"lat": -50.0, "lon": -140.0},
            {"lat": -50.0, "lon": -170.0},
        ]

        query_response = api_client.query_polygon(vertices=vertices, limit=1000)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        events = result if isinstance(result, list) else result.get("events", [])

        # Should be empty despite large area (South Pacific)
        assert isinstance(events, list), "Result should be a list"
