# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Polar coordinate edge case tests (EDGE-01).

Tests for coordinate handling at geographic poles where longitude
is ambiguous and all meridians converge.

Test Cases:
    - North pole insert/query (lat=90)
    - South pole insert/query (lat=-90)
    - Longitude equivalence at poles (all longitudes map to same point)
    - Radius queries centered at poles
    - Near-pole precision (89.9999 vs 90.0)
"""

import pytest

from .conftest import (
    EdgeCaseAPIClient,
    EdgeCaseCoordinates,
    build_insert_event,
    build_radius_query,
    generate_entity_id,
    load_fixture,
)


@pytest.mark.edge_case
class TestPolarCoordinates:
    """Test polar coordinate handling (EDGE-01)."""

    def test_north_pole_insert(
        self, single_node_cluster, edge_case_fixtures_dir, api_client
    ):
        """Insert event at north pole (lat=90) and verify retrievable.

        At the north pole, all longitudes converge to a single point.
        The event should be inserted successfully regardless of longitude.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "polar_coordinates.json")
        north_pole = next(
            tc for tc in fixtures["test_cases"] if tc["name"] == "north_pole"
        )

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=north_pole["input"]["latitude"],
            lon=north_pole["input"]["longitude"],
        )

        # Insert via API
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify retrievable by UUID
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        assert result["latitude"] == 90.0 or abs(result["latitude"] - 90.0) < 1e-6

    def test_south_pole_insert(
        self, single_node_cluster, edge_case_fixtures_dir, api_client
    ):
        """Insert event at south pole (lat=-90) and verify retrievable.

        At the south pole, all longitudes converge to a single point.
        The event should be inserted successfully regardless of longitude.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "polar_coordinates.json")
        south_pole = next(
            tc for tc in fixtures["test_cases"] if tc["name"] == "south_pole"
        )

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=south_pole["input"]["latitude"],
            lon=south_pole["input"]["longitude"],
        )

        # Insert via API
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify retrievable by UUID
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        assert result["latitude"] == -90.0 or abs(result["latitude"] + 90.0) < 1e-6

    def test_pole_longitude_equivalence(
        self, single_node_cluster, edge_case_fixtures_dir, api_client
    ):
        """Insert at pole with lon=0, query with lon=180, should find.

        At poles, longitude has no meaning - all longitudes refer to the
        same geographic point. A radius query at the same pole but with
        a different longitude should still find the event.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "polar_coordinates.json")
        north_pole = next(
            tc for tc in fixtures["test_cases"] if tc["name"] == "north_pole"
        )
        north_pole_180 = next(
            tc for tc in fixtures["test_cases"] if tc["name"] == "north_pole_180"
        )

        # Both are at lat=90 but different longitudes
        assert north_pole["input"]["latitude"] == 90.0
        assert north_pole_180["input"]["latitude"] == 90.0
        assert north_pole["input"]["longitude"] != north_pole_180["input"]["longitude"]

        # Insert at lon=0
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=north_pole["input"]["latitude"],
            lon=north_pole["input"]["longitude"],
        )

        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query at lon=180 should still find event (1km radius at pole)
        query_response = api_client.query_radius(
            lat=north_pole_180["input"]["latitude"],
            lon=north_pole_180["input"]["longitude"],
            radius_m=1000,
        )
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        # Should find the event (pole longitude equivalence)
        results = query_response.json()
        # Results may be list or dict with events key
        events = results if isinstance(results, list) else results.get("events", [])
        found = any(e.get("entity_id") == entity_id for e in events)
        assert found, "Event at pole should be found regardless of query longitude"

    def test_radius_query_at_north_pole(
        self, single_node_cluster, edge_case_fixtures_dir, api_client
    ):
        """Radius query centered at north pole (90,0) with 1km radius.

        A radius query at the pole should correctly compute the circular
        region and return any events within range.
        """
        # Insert event at north pole
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=90.0,
            lon=0.0,
        )
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query at north pole
        query_response = api_client.query_radius(
            lat=90.0,
            lon=0.0,
            radius_m=1000,
        )
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        results = query_response.json()
        events = results if isinstance(results, list) else results.get("events", [])
        found = any(e.get("entity_id") == entity_id for e in events)
        assert found, "Event at pole should be found in pole-centered query"

    def test_radius_query_at_south_pole(self, single_node_cluster, api_client):
        """Radius query centered at south pole (-90,0) with 1km radius.

        A radius query at the south pole should work identically to
        the north pole query.
        """
        # Insert event at south pole
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=EdgeCaseCoordinates.SOUTH_POLE_DEG,
            lon=0.0,
        )
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query at south pole
        query_response = api_client.query_radius(
            lat=-90.0,
            lon=0.0,
            radius_m=1000,
        )
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        results = query_response.json()
        events = results if isinstance(results, list) else results.get("events", [])
        found = any(e.get("entity_id") == entity_id for e in events)
        assert found, "Event at south pole should be found"

    def test_near_pole_precision(
        self, single_node_cluster, edge_case_fixtures_dir, api_client
    ):
        """Insert at 89.9999, verify distinct from 90.0.

        Points very close to (but not at) the pole should maintain
        their distinct coordinates and not be treated as pole points.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "polar_coordinates.json")
        near_pole = next(
            tc for tc in fixtures["test_cases"] if tc["name"] == "near_north_pole"
        )

        # Near pole is at 89.9999, not exactly 90
        assert near_pole["input"]["latitude"] == 89.9999
        assert near_pole["input"]["latitude"] < 90.0

        entity_id_at_pole = generate_entity_id()
        entity_id_near_pole = generate_entity_id()

        event_at_pole = build_insert_event(
            entity_id=entity_id_at_pole,
            lat=90.0,
            lon=0.0,
        )

        event_near_pole = build_insert_event(
            entity_id=entity_id_near_pole,
            lat=near_pole["input"]["latitude"],
            lon=near_pole["input"]["longitude"],
        )

        # Insert both events
        response = api_client.insert([event_at_pole, event_near_pole])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query both to verify distinct coordinates
        pole_response = api_client.query_uuid(entity_id_at_pole)
        near_response = api_client.query_uuid(entity_id_near_pole)

        assert pole_response.status_code == 200
        assert near_response.status_code == 200

        pole_result = pole_response.json()
        near_result = near_response.json()

        # The two events should have different latitudes
        assert pole_result["latitude"] != near_result["latitude"]

    def test_arctic_circle(
        self, single_node_cluster, edge_case_fixtures_dir, api_client
    ):
        """Insert at Arctic Circle latitude (66.5).

        The Arctic Circle is a well-defined latitude boundary.
        Events here should work normally.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "polar_coordinates.json")
        arctic = next(
            tc for tc in fixtures["test_cases"] if tc["name"] == "arctic_circle"
        )

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=arctic["input"]["latitude"],
            lon=arctic["input"]["longitude"],
        )

        # Insert via API
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify retrievable
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        assert abs(result["latitude"] - 66.5) < 1e-6

    def test_antarctic_circle(
        self, single_node_cluster, edge_case_fixtures_dir, api_client
    ):
        """Insert at Antarctic Circle latitude (-66.5).

        The Antarctic Circle is a well-defined latitude boundary.
        Events here should work normally.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "polar_coordinates.json")
        antarctic = next(
            tc for tc in fixtures["test_cases"] if tc["name"] == "antarctic_circle"
        )

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=antarctic["input"]["latitude"],
            lon=antarctic["input"]["longitude"],
        )

        # Insert via API
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify retrievable
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        assert abs(result["latitude"] + 66.5) < 1e-6

    def test_pole_with_negative_longitude(
        self, single_node_cluster, edge_case_fixtures_dir, api_client
    ):
        """Insert at pole with negative longitude.

        Even with negative longitude, the pole event should be valid.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "polar_coordinates.json")
        pole_neg = next(
            tc for tc in fixtures["test_cases"] if tc["name"] == "north_pole_negative"
        )

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=pole_neg["input"]["latitude"],
            lon=pole_neg["input"]["longitude"],
        )

        # Insert via API
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify retrievable
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        assert result["latitude"] == 90.0 or abs(result["latitude"] - 90.0) < 1e-6
        assert result["longitude"] == -90.0 or abs(result["longitude"] + 90.0) < 1e-6
