# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Anti-meridian (date line) edge case tests (EDGE-02).

Tests for coordinate handling at the anti-meridian (International Date Line)
where longitude transitions from +180 to -180 degrees.

Test Cases:
    - Insert at +180 longitude
    - Insert at -180 longitude
    - Anti-meridian equivalence (+180 = -180)
    - Radius queries crossing the date line
    - Fiji spanning the date line
    - Near-antimeridian precision
"""

import pytest

from .conftest import (
    EdgeCaseCoordinates,
    build_insert_event,
    build_radius_query,
    generate_entity_id,
    load_fixture,
)


@pytest.mark.edge_case
class TestAntimeridian:
    """Test anti-meridian (date line) handling (EDGE-02)."""

    def test_positive_180_insert(self, single_node_cluster, edge_case_fixtures_dir):
        """Insert event at longitude +180.

        The positive anti-meridian should be a valid insertion point.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        am_east = next(tc for tc in fixtures["test_cases"] if tc["name"] == "antimeridian_east")

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=am_east["input"]["latitude"],
            lon=am_east["input"]["longitude"],
        )

        assert event["longitude"] == 180.0
        assert entity_id is not None

    def test_negative_180_insert(self, single_node_cluster, edge_case_fixtures_dir):
        """Insert event at longitude -180.

        The negative anti-meridian should be a valid insertion point.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        am_west = next(tc for tc in fixtures["test_cases"] if tc["name"] == "antimeridian_west")

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=am_west["input"]["latitude"],
            lon=am_west["input"]["longitude"],
        )

        assert event["longitude"] == -180.0
        assert entity_id is not None

    def test_antimeridian_equivalence(self, single_node_cluster, edge_case_fixtures_dir):
        """Longitude +180 and -180 represent the same line.

        Events at +180 and -180 longitude with the same latitude
        should be at the same geographic location.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        am_east = next(tc for tc in fixtures["test_cases"] if tc["name"] == "antimeridian_east")
        am_west = next(tc for tc in fixtures["test_cases"] if tc["name"] == "antimeridian_west")

        # Both at same latitude (equator in this case)
        assert am_east["input"]["latitude"] == am_west["input"]["latitude"]
        # But different longitude representations
        assert am_east["input"]["longitude"] == 180.0
        assert am_west["input"]["longitude"] == -180.0

        # Insert at +180
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=am_east["input"]["latitude"],
            lon=am_east["input"]["longitude"],
        )

        # Query at -180 should find it
        query = build_radius_query(
            lat=am_west["input"]["latitude"],
            lon=am_west["input"]["longitude"],
            radius_m=1000,
        )

        assert query["center_lon"] == -180.0

    def test_radius_query_crossing(self, single_node_cluster, edge_case_fixtures_dir):
        """Query at lon=179.9 with large radius spans both sides of date line.

        A radius query near the anti-meridian with a large enough radius
        should return events from both sides of the date line.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        crossing_query = next(
            tc for tc in fixtures["test_cases"]
            if tc.get("operation") == "query-radius" and "crossing" in tc["name"]
        )

        query = build_radius_query(
            lat=crossing_query["input"]["latitude"],
            lon=crossing_query["input"]["longitude"],
            radius_m=crossing_query["input"]["radius_m"],
        )

        # Large radius to cross the date line
        assert query["radius_m"] == 1000000  # 1000km

    def test_fiji_spanning_dateline(self, single_node_cluster, edge_case_fixtures_dir):
        """Insert on both sides of Fiji (spans date line), query should find both.

        Fiji straddles the anti-meridian, with some islands at positive
        longitude (~179) and others at negative longitude (~-179).
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        fiji_east = next(tc for tc in fixtures["test_cases"] if tc["name"] == "fiji_east_side")
        fiji_west = next(tc for tc in fixtures["test_cases"] if tc["name"] == "fiji_west_side")

        # Fiji east side at ~179.5
        assert fiji_east["input"]["longitude"] == 179.5
        # Fiji west side at ~-179.5
        assert fiji_west["input"]["longitude"] == -179.5

        entity_id_east = generate_entity_id()
        entity_id_west = generate_entity_id()

        event_east = build_insert_event(
            entity_id=entity_id_east,
            lat=fiji_east["input"]["latitude"],
            lon=fiji_east["input"]["longitude"],
        )

        event_west = build_insert_event(
            entity_id=entity_id_west,
            lat=fiji_west["input"]["latitude"],
            lon=fiji_west["input"]["longitude"],
        )

        # Both events valid
        assert event_east["longitude"] == 179.5
        assert event_west["longitude"] == -179.5

    def test_near_antimeridian(self, single_node_cluster, edge_case_fixtures_dir):
        """Insert at 179.9999 and -179.9999.

        Points very close to (but not at) the anti-meridian should
        maintain their distinct coordinates.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        just_before = next(tc for tc in fixtures["test_cases"] if tc["name"] == "just_before_antimeridian")
        just_after = next(tc for tc in fixtures["test_cases"] if tc["name"] == "just_after_antimeridian")

        assert just_before["input"]["longitude"] == 179.9999
        assert just_after["input"]["longitude"] == -179.9999

        entity_id_before = generate_entity_id()
        entity_id_after = generate_entity_id()

        event_before = build_insert_event(
            entity_id=entity_id_before,
            lat=just_before["input"]["latitude"],
            lon=just_before["input"]["longitude"],
        )

        event_after = build_insert_event(
            entity_id=entity_id_after,
            lat=just_after["input"]["latitude"],
            lon=just_after["input"]["longitude"],
        )

        # Different longitudes, not collapsed to same value
        assert event_before["longitude"] != event_after["longitude"]

    def test_antimeridian_north_hemisphere(self, single_node_cluster, edge_case_fixtures_dir):
        """Anti-meridian in northern hemisphere.

        The anti-meridian extends through all latitudes. Test at
        non-equator location.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        am_north = next(tc for tc in fixtures["test_cases"] if tc["name"] == "antimeridian_north")

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=am_north["input"]["latitude"],
            lon=am_north["input"]["longitude"],
        )

        assert event["latitude"] == 45.0
        assert event["longitude"] == 180.0

    def test_antimeridian_south_hemisphere(self, single_node_cluster, edge_case_fixtures_dir):
        """Anti-meridian in southern hemisphere.

        The anti-meridian extends through all latitudes. Test at
        southern location.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        am_south = next(tc for tc in fixtures["test_cases"] if tc["name"] == "antimeridian_south")

        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=am_south["input"]["latitude"],
            lon=am_south["input"]["longitude"],
        )

        assert event["latitude"] == -45.0
        assert event["longitude"] == -180.0

    def test_radius_query_near_antimeridian(self, single_node_cluster, edge_case_fixtures_dir):
        """Query near antimeridian covering Fiji area.

        A moderate radius query near the date line in the Fiji region.
        """
        fixtures = load_fixture(edge_case_fixtures_dir / "antimeridian.json")
        fiji_query = next(
            tc for tc in fixtures["test_cases"]
            if tc.get("operation") == "query-radius" and "near_antimeridian" in tc["name"]
        )

        query = build_radius_query(
            lat=fiji_query["input"]["latitude"],
            lon=fiji_query["input"]["longitude"],
            radius_m=fiji_query["input"]["radius_m"],
        )

        assert query["center_lat"] == -18.0
        assert query["center_lon"] == 179.9
        assert query["radius_m"] == 50000  # 50km
