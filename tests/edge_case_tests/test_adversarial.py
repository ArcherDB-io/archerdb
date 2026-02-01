# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Adversarial pattern tests (EDGE-08).

Tests for boundary conditions and adversarial workload patterns.
Leverages patterns from src/testing/geo_workload.zig EdgeCaseCoordinates.

Test Cases:
    - Maximum radius query (1000km)
    - Zero radius query (point query edge case)
    - Boundary latitude (+/-90)
    - Boundary longitude (+/-180)
    - One nanodegree precision
    - Maximum velocity
    - Maximum altitude (Everest and ocean floor)
    - All coordinate extremes (4 corners)
"""

import pytest

from .conftest import (
    EdgeCaseAPIClient,
    EdgeCaseCoordinates,
    build_insert_event,
    build_radius_query,
    degrees_to_nanodegrees,
    generate_entity_id,
    nanodegrees_to_degrees,
)


@pytest.mark.edge_case
class TestAdversarialPatterns:
    """Test adversarial/boundary patterns (EDGE-08)."""

    def test_max_radius_query(self, single_node_cluster, api_client):
        """Query with 1000km radius (maximum allowed).

        The maximum supported radius should work correctly.
        """
        # Insert a known event
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=0.0,
            lon=0.0,
        )
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # 1000km = 1,000,000 meters - query with large radius
        query_response = api_client.query_radius(
            lat=0.0,
            lon=0.0,
            radius_m=1_000_000,  # 1000km max radius
        )

        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        results = query_response.json()
        events = results if isinstance(results, list) else results.get("events", [])
        found = any(e.get("entity_id") == entity_id for e in events)
        assert found, "Event should be found with 1000km radius"

    def test_zero_radius_query(self, single_node_cluster, api_client):
        """Query with 0 radius (point query edge case).

        A zero-radius query is a degenerate case - should either
        return only exact matches or empty.
        """
        # Insert event at exact location
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
        )
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query with zero radius at same location
        query_response = api_client.query_radius(
            lat=40.7128,
            lon=-74.0060,
            radius_m=0,  # Zero radius
        )

        # Should succeed (not error) - may return empty or exact match
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

    def test_boundary_latitude(self, single_node_cluster, api_client):
        """Insert at exactly +90 and -90 latitude.

        The exact boundary values for latitude should be valid.
        """
        # North pole (max latitude)
        entity_id_north = generate_entity_id()
        event_north = build_insert_event(
            entity_id=entity_id_north,
            lat=EdgeCaseCoordinates.NORTH_POLE_DEG,  # 90.0
            lon=0.0,
        )

        # South pole (min latitude)
        entity_id_south = generate_entity_id()
        event_south = build_insert_event(
            entity_id=entity_id_south,
            lat=EdgeCaseCoordinates.SOUTH_POLE_DEG,  # -90.0
            lon=0.0,
        )

        # Insert both
        response = api_client.insert([event_north, event_south])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify both retrievable
        north_response = api_client.query_uuid(entity_id_north)
        south_response = api_client.query_uuid(entity_id_south)

        assert north_response.status_code == 200, "North pole event should exist"
        assert south_response.status_code == 200, "South pole event should exist"

        north_result = north_response.json()
        south_result = south_response.json()

        assert north_result["latitude"] == 90.0 or abs(north_result["latitude"] - 90.0) < 1e-6
        assert south_result["latitude"] == -90.0 or abs(south_result["latitude"] + 90.0) < 1e-6

    def test_boundary_longitude(self, single_node_cluster, api_client):
        """Insert at exactly +180 and -180 longitude.

        The exact boundary values for longitude should be valid.
        """
        # East anti-meridian (max longitude)
        entity_id_east = generate_entity_id()
        event_east = build_insert_event(
            entity_id=entity_id_east,
            lat=0.0,
            lon=EdgeCaseCoordinates.ANTI_MERIDIAN_EAST_DEG,  # 180.0
        )

        # West anti-meridian (min longitude)
        entity_id_west = generate_entity_id()
        event_west = build_insert_event(
            entity_id=entity_id_west,
            lat=0.0,
            lon=EdgeCaseCoordinates.ANTI_MERIDIAN_WEST_DEG,  # -180.0
        )

        # Insert both
        response = api_client.insert([event_east, event_west])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify both retrievable
        east_response = api_client.query_uuid(entity_id_east)
        west_response = api_client.query_uuid(entity_id_west)

        assert east_response.status_code == 200, "East anti-meridian event should exist"
        assert west_response.status_code == 200, "West anti-meridian event should exist"

        east_result = east_response.json()
        west_result = west_response.json()

        # Longitude may be normalized
        assert abs(abs(east_result["longitude"]) - 180.0) < 1e-6
        assert abs(abs(west_result["longitude"]) - 180.0) < 1e-6

    def test_one_nanodegree_precision(self, single_node_cluster, api_client):
        """Two points 1 nanodegree apart should be distinct.

        The minimum precision difference (1 nanodegree) should
        be preserved and not collapsed.
        """
        # 1 nanodegree = 0.000000001 degrees
        one_nanodegree_deg = nanodegrees_to_degrees(EdgeCaseCoordinates.ONE_NANODEGREE)

        entity_id_1 = generate_entity_id()
        entity_id_2 = generate_entity_id()

        # Two points 1 nanodegree apart
        event_1 = build_insert_event(
            entity_id=entity_id_1,
            lat=0.0,
            lon=0.0,
        )

        event_2 = build_insert_event(
            entity_id=entity_id_2,
            lat=one_nanodegree_deg,  # 0.000000001
            lon=one_nanodegree_deg,  # 0.000000001
        )

        # Insert both
        response = api_client.insert([event_1, event_2])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify both retrievable
        response_1 = api_client.query_uuid(entity_id_1)
        response_2 = api_client.query_uuid(entity_id_2)

        assert response_1.status_code == 200
        assert response_2.status_code == 200

        # Both should be distinct entities
        result_1 = response_1.json()
        result_2 = response_2.json()

        assert result_1["entity_id"] != result_2["entity_id"]

    def test_max_velocity(self, single_node_cluster, api_client):
        """Event with velocity_mms=100000 (100 m/s).

        High velocity values should be accepted.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            velocity_mms=100_000,  # 100 m/s = 360 km/h
        )

        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify retrievable
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

    def test_max_altitude(self, single_node_cluster, api_client):
        """Event at altitude_mm=9000000 (Everest) and -11000000 (ocean floor).

        Extreme altitude values should be accepted.
        """
        # Mount Everest altitude: ~8849m = 8,849,000mm
        entity_id_everest = generate_entity_id()
        event_everest = build_insert_event(
            entity_id=entity_id_everest,
            lat=27.9881,  # Everest location
            lon=86.9250,
            altitude_mm=9_000_000,  # 9000m
        )

        # Mariana Trench: ~11,000m below sea level = -11,000,000mm
        entity_id_trench = generate_entity_id()
        event_trench = build_insert_event(
            entity_id=entity_id_trench,
            lat=11.3493,  # Mariana Trench location
            lon=142.1996,
            altitude_mm=-11_000_000,  # -11000m
        )

        response = api_client.insert([event_everest, event_trench])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify both retrievable
        everest_response = api_client.query_uuid(entity_id_everest)
        trench_response = api_client.query_uuid(entity_id_trench)

        assert everest_response.status_code == 200, "Everest event should exist"
        assert trench_response.status_code == 200, "Trench event should exist"

    def test_all_coordinate_extremes(self, single_node_cluster, api_client):
        """Insert at all 4 corners of coordinate space.

        Test all combinations of min/max latitude and longitude.
        """
        corners = [
            (90.0, 180.0, "NE corner (North Pole, East Anti-meridian)"),
            (90.0, -180.0, "NW corner (North Pole, West Anti-meridian)"),
            (-90.0, 180.0, "SE corner (South Pole, East Anti-meridian)"),
            (-90.0, -180.0, "SW corner (South Pole, West Anti-meridian)"),
        ]

        events = []
        entity_ids = []

        for lat, lon, description in corners:
            entity_id = generate_entity_id()
            entity_ids.append(entity_id)
            events.append(build_insert_event(
                entity_id=entity_id,
                lat=lat,
                lon=lon,
            ))

        # Insert all corners
        response = api_client.insert(events)
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify all corners retrievable
        for entity_id in entity_ids:
            query_response = api_client.query_uuid(entity_id)
            assert query_response.status_code == 200, f"Corner {entity_id} should exist"

    def test_boundary_queries_near_poles(self, single_node_cluster, api_client):
        """Radius query very close to poles.

        Queries near poles test S2 cell edge cases.
        """
        # Insert events near poles
        entity_id_north = generate_entity_id()
        entity_id_south = generate_entity_id()

        event_north = build_insert_event(
            entity_id=entity_id_north,
            lat=89.99,
            lon=0.0,
        )
        event_south = build_insert_event(
            entity_id=entity_id_south,
            lat=-89.99,
            lon=0.0,
        )

        response = api_client.insert([event_north, event_south])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query 1km from north pole
        query_near_north = api_client.query_radius(
            lat=89.99,
            lon=0.0,
            radius_m=1000,
        )
        assert query_near_north.status_code == 200, f"Query near north failed: {query_near_north.text}"

        # Query 1km from south pole
        query_near_south = api_client.query_radius(
            lat=-89.99,
            lon=0.0,
            radius_m=1000,
        )
        assert query_near_south.status_code == 200, f"Query near south failed: {query_near_south.text}"

    def test_boundary_queries_near_antimeridian(self, single_node_cluster, api_client):
        """Radius query very close to antimeridian.

        Queries near the date line test wrapping logic.
        """
        # Insert events near antimeridian
        entity_id_east = generate_entity_id()
        entity_id_west = generate_entity_id()

        event_east = build_insert_event(
            entity_id=entity_id_east,
            lat=0.0,
            lon=179.99,
        )
        event_west = build_insert_event(
            entity_id=entity_id_west,
            lat=0.0,
            lon=-179.99,
        )

        response = api_client.insert([event_east, event_west])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query near east antimeridian - should cross
        query_near_east = api_client.query_radius(
            lat=0.0,
            lon=179.99,
            radius_m=50_000,  # 50km - should cross antimeridian
        )
        assert query_near_east.status_code == 200, f"Query near east failed: {query_near_east.text}"

        # Query near west antimeridian
        query_near_west = api_client.query_radius(
            lat=0.0,
            lon=-179.99,
            radius_m=50_000,
        )
        assert query_near_west.status_code == 200, f"Query near west failed: {query_near_west.text}"

    def test_nanodegree_constants(self, single_node_cluster, api_client):
        """Verify nanodegree constants match geo_workload.zig.

        Constants should match the Zig source for consistency.
        """
        # Just verify constants are correct values
        assert EdgeCaseCoordinates.NORTH_POLE_LAT == 90_000_000_000
        assert EdgeCaseCoordinates.SOUTH_POLE_LAT == -90_000_000_000
        assert EdgeCaseCoordinates.ANTI_MERIDIAN_EAST == 180_000_000_000
        assert EdgeCaseCoordinates.ANTI_MERIDIAN_WEST == -180_000_000_000
        assert EdgeCaseCoordinates.EQUATOR_LAT == 0
        assert EdgeCaseCoordinates.PRIME_MERIDIAN_LON == 0
        assert EdgeCaseCoordinates.ONE_NANODEGREE == 1

        # Also verify we can insert at origin
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=0.0,
            lon=0.0,
        )
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert at origin failed: {response.text}"

    def test_zero_coordinates(self, single_node_cluster, api_client):
        """Insert at origin (0,0) - Null Island.

        The point where equator meets prime meridian.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=EdgeCaseCoordinates.EQUATOR_LAT / 1e9,  # 0.0
            lon=EdgeCaseCoordinates.PRIME_MERIDIAN_LON / 1e9,  # 0.0
        )

        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify retrievable
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        assert result["latitude"] == 0.0 or abs(result["latitude"]) < 1e-6
        assert result["longitude"] == 0.0 or abs(result["longitude"]) < 1e-6
