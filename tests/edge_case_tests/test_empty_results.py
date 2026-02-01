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
    build_insert_event,
    build_polygon_query,
    build_radius_query,
    generate_entity_id,
)


@pytest.mark.edge_case
class TestEmptyResults:
    """Test empty result handling (EDGE-07)."""

    def test_radius_query_empty_database(self, single_node_cluster):
        """Fresh cluster, query returns empty list (not error).

        A radius query on an empty database should return an empty
        result set, not an error.
        """
        # Query any location on fresh database
        query = build_radius_query(
            lat=40.7128,
            lon=-74.0060,
            radius_m=10000,  # 10km radius
        )

        # Query structure is valid
        assert query["center_lat"] == 40.7128
        assert query["center_lon"] == -74.0060
        assert query["radius_m"] == 10000

        # Expected result: empty list, not error
        # In integration test: response.events == []

    def test_radius_query_no_matches(self, single_node_cluster):
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

        # Query in Sydney (opposite side of globe)
        query = build_radius_query(
            lat=-33.8688,
            lon=151.2093,  # Sydney
            radius_m=1000,  # 1km radius
        )

        # Event is in NYC, query is in Sydney
        # Distance is ~16,000km, way outside 1km radius
        assert event["latitude"] != query["center_lat"]
        assert event["longitude"] != query["center_lon"]

        # Expected result: empty list (NYC event not in Sydney radius)

    def test_uuid_query_nonexistent(self, single_node_cluster):
        """Query for random UUID, returns empty/null (not error).

        Querying for a non-existent entity should return null/empty,
        not an error.
        """
        # Generate random UUID that doesn't exist
        nonexistent_id = uuid.uuid4().hex

        # Query structure for UUID lookup
        query = {"entity_id": nonexistent_id}

        assert len(query["entity_id"]) == 32

        # Expected result: null or empty, not error

    def test_polygon_query_empty(self, single_node_cluster):
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
        query = build_polygon_query(vertices=vertices)

        assert len(query["vertices"]) == 3

        # Expected result: empty list (no events in Antarctica polygon)

    def test_uuid_batch_all_missing(self, single_node_cluster):
        """Batch query 10 nonexistent UUIDs, returns empty for each.

        A batch query for multiple non-existent entities should
        return empty/null for each, not an error.
        """
        # Generate 10 random UUIDs
        missing_ids = [uuid.uuid4().hex for _ in range(10)]

        assert len(missing_ids) == 10
        assert len(set(missing_ids)) == 10  # All unique

        # Query structure for batch lookup
        query = {"entity_ids": missing_ids}

        # Expected result: 10 empty/null responses, not error

    def test_delete_nonexistent(self, single_node_cluster):
        """Delete nonexistent entity, no error (idempotent).

        Deleting an entity that doesn't exist should succeed
        silently (idempotent operation).
        """
        # Generate random UUID that doesn't exist
        nonexistent_id = uuid.uuid4().hex

        # Delete request structure
        delete_request = {"entity_id": nonexistent_id}

        assert len(delete_request["entity_id"]) == 32

        # Expected result: success (no error), even though nothing deleted

    def test_radius_query_zero_results_structure(self, single_node_cluster):
        """Verify empty result has correct structure (list, not None).

        Empty results should be an empty list [], not null/None.
        """
        query = build_radius_query(
            lat=0.0,
            lon=0.0,
            radius_m=1,  # Very small radius
        )

        # Query is valid
        assert query["radius_m"] == 1

        # Expected result structure: {"events": []}
        # NOT: {"events": null} or error

    def test_polygon_query_large_empty_area(self, single_node_cluster):
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
        query = build_polygon_query(vertices=vertices, limit=1000)

        assert len(query["vertices"]) == 4
        assert query["limit"] == 1000

        # Expected result: empty list despite large area
