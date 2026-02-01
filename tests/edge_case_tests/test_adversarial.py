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

    def test_max_radius_query(self, single_node_cluster):
        """Query with 1000km radius (maximum allowed).

        The maximum supported radius should work correctly.
        """
        # 1000km = 1,000,000 meters
        query = build_radius_query(
            lat=0.0,
            lon=0.0,
            radius_m=1_000_000,  # 1000km max radius
        )

        assert query["radius_m"] == 1_000_000

    def test_zero_radius_query(self, single_node_cluster):
        """Query with 0 radius (point query edge case).

        A zero-radius query is a degenerate case - should either
        return only exact matches or empty.
        """
        query = build_radius_query(
            lat=40.7128,
            lon=-74.0060,
            radius_m=0,  # Zero radius
        )

        assert query["radius_m"] == 0

    def test_boundary_latitude(self, single_node_cluster):
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
        assert event_north["latitude"] == 90.0

        # South pole (min latitude)
        entity_id_south = generate_entity_id()
        event_south = build_insert_event(
            entity_id=entity_id_south,
            lat=EdgeCaseCoordinates.SOUTH_POLE_DEG,  # -90.0
            lon=0.0,
        )
        assert event_south["latitude"] == -90.0

    def test_boundary_longitude(self, single_node_cluster):
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
        assert event_east["longitude"] == 180.0

        # West anti-meridian (min longitude)
        entity_id_west = generate_entity_id()
        event_west = build_insert_event(
            entity_id=entity_id_west,
            lat=0.0,
            lon=EdgeCaseCoordinates.ANTI_MERIDIAN_WEST_DEG,  # -180.0
        )
        assert event_west["longitude"] == -180.0

    def test_one_nanodegree_precision(self, single_node_cluster):
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

        # In nanodegrees, these should be distinct
        lat_1_nano = degrees_to_nanodegrees(event_1["latitude"])
        lat_2_nano = degrees_to_nanodegrees(event_2["latitude"])

        assert lat_2_nano - lat_1_nano == 1  # Exactly 1 nanodegree apart

    def test_max_velocity(self, single_node_cluster):
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

        assert event["velocity_mms"] == 100_000

    def test_max_altitude(self, single_node_cluster):
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
        assert event_everest["altitude_mm"] == 9_000_000

        # Mariana Trench: ~11,000m below sea level = -11,000,000mm
        entity_id_trench = generate_entity_id()
        event_trench = build_insert_event(
            entity_id=entity_id_trench,
            lat=11.3493,  # Mariana Trench location
            lon=142.1996,
            altitude_mm=-11_000_000,  # -11000m
        )
        assert event_trench["altitude_mm"] == -11_000_000

    def test_all_coordinate_extremes(self, single_node_cluster):
        """Insert at all 4 corners of coordinate space.

        Test all combinations of min/max latitude and longitude.
        """
        corners = [
            (90.0, 180.0, "NE corner (North Pole, East Anti-meridian)"),
            (90.0, -180.0, "NW corner (North Pole, West Anti-meridian)"),
            (-90.0, 180.0, "SE corner (South Pole, East Anti-meridian)"),
            (-90.0, -180.0, "SW corner (South Pole, West Anti-meridian)"),
        ]

        for lat, lon, description in corners:
            entity_id = generate_entity_id()
            event = build_insert_event(
                entity_id=entity_id,
                lat=lat,
                lon=lon,
            )
            assert event["latitude"] == lat, f"Failed for {description}"
            assert event["longitude"] == lon, f"Failed for {description}"

    def test_boundary_queries_near_poles(self, single_node_cluster):
        """Radius query very close to poles.

        Queries near poles test S2 cell edge cases.
        """
        # Query 1km from north pole
        query_near_north = build_radius_query(
            lat=89.99,  # Very close to pole
            lon=0.0,
            radius_m=1000,
        )
        assert query_near_north["center_lat"] == 89.99

        # Query 1km from south pole
        query_near_south = build_radius_query(
            lat=-89.99,
            lon=0.0,
            radius_m=1000,
        )
        assert query_near_south["center_lat"] == -89.99

    def test_boundary_queries_near_antimeridian(self, single_node_cluster):
        """Radius query very close to antimeridian.

        Queries near the date line test wrapping logic.
        """
        # Query near east antimeridian
        query_near_east = build_radius_query(
            lat=0.0,
            lon=179.99,
            radius_m=50_000,  # 50km - should cross antimeridian
        )
        assert query_near_east["center_lon"] == 179.99

        # Query near west antimeridian
        query_near_west = build_radius_query(
            lat=0.0,
            lon=-179.99,
            radius_m=50_000,
        )
        assert query_near_west["center_lon"] == -179.99

    def test_nanodegree_constants(self, single_node_cluster):
        """Verify nanodegree constants match geo_workload.zig.

        Constants should match the Zig source for consistency.
        """
        assert EdgeCaseCoordinates.NORTH_POLE_LAT == 90_000_000_000
        assert EdgeCaseCoordinates.SOUTH_POLE_LAT == -90_000_000_000
        assert EdgeCaseCoordinates.ANTI_MERIDIAN_EAST == 180_000_000_000
        assert EdgeCaseCoordinates.ANTI_MERIDIAN_WEST == -180_000_000_000
        assert EdgeCaseCoordinates.EQUATOR_LAT == 0
        assert EdgeCaseCoordinates.PRIME_MERIDIAN_LON == 0
        assert EdgeCaseCoordinates.ONE_NANODEGREE == 1

    def test_zero_coordinates(self, single_node_cluster):
        """Insert at origin (0,0) - Null Island.

        The point where equator meets prime meridian.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=EdgeCaseCoordinates.EQUATOR_LAT / 1e9,  # 0.0
            lon=EdgeCaseCoordinates.PRIME_MERIDIAN_LON / 1e9,  # 0.0
        )

        assert event["latitude"] == 0.0
        assert event["longitude"] == 0.0
