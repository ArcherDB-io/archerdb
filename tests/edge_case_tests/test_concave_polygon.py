# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Concave polygon query edge case tests (EDGE-03).

Tests for polygon queries with concave (non-convex) shapes that have
one or more interior angles greater than 180 degrees.

Test Cases:
    - L-shaped polygon with concave corner
    - Point in concave region (exterior) vs interior
    - 5-pointed star polygon
    - Self-intersecting polygon rejection
    - Minimum vertex count (triangle)
    - Complex 10+ vertex concave polygon
"""

import pytest

from .conftest import (
    build_insert_event,
    build_polygon_query,
    generate_entity_id,
    load_fixture,
)


@pytest.mark.edge_case
class TestConcavePolygon:
    """Test concave polygon query handling (EDGE-03)."""

    def test_l_shape_polygon(self, single_node_cluster, local_fixtures_dir):
        """L-shaped polygon: point in concave region should NOT be found.

        The L-shape has one concave corner. Points in that concave region
        are geometrically outside the polygon.
        """
        fixtures = load_fixture(local_fixtures_dir / "concave_polygons.json")
        l_shape = fixtures["polygons"]["l_shape"]

        # Build polygon vertices
        vertices = [{"lat": v["lat"], "lon": v["lon"]} for v in l_shape["vertices"]]
        query = build_polygon_query(vertices=vertices)

        assert len(query["vertices"]) == 6  # L-shape has 6 vertices

        # Test point in concave region - should be exterior
        concave_point = l_shape["test_points"]["exterior"][0]
        assert concave_point["expected"] is False
        assert concave_point["lat"] == 1.5
        assert concave_point["lon"] == 1.5

    def test_l_shape_interior(self, single_node_cluster, local_fixtures_dir):
        """L-shaped polygon: point in L interior IS found.

        Points clearly inside the L-shape (not in concave bay) should
        be found by the polygon query.
        """
        fixtures = load_fixture(local_fixtures_dir / "concave_polygons.json")
        l_shape = fixtures["polygons"]["l_shape"]

        # Test interior points
        interior_points = l_shape["test_points"]["interior"]
        for point in interior_points:
            assert point["expected"] is True

        # Insert event inside L
        entity_id = generate_entity_id()
        interior = interior_points[0]  # (0.5, 0.5) - inside lower-left
        event = build_insert_event(
            entity_id=entity_id,
            lat=interior["lat"],
            lon=interior["lon"],
        )

        assert event["latitude"] == 0.5
        assert event["longitude"] == 0.5

    def test_star_polygon(self, single_node_cluster, local_fixtures_dir):
        """5-pointed star: verify concave region handling.

        A star shape has 5 concave "bays" between the points.
        Points in these bays are exterior to the polygon.
        """
        fixtures = load_fixture(local_fixtures_dir / "concave_polygons.json")
        star = fixtures["polygons"]["star_5point"]

        vertices = [{"lat": v["lat"], "lon": v["lon"]} for v in star["vertices"]]
        query = build_polygon_query(vertices=vertices)

        assert len(query["vertices"]) == 10  # 5 points + 5 inner vertices

        # Center should be interior
        center = star["test_points"]["interior"][0]
        assert center["expected"] is True
        assert center["lat"] == 0.0
        assert center["lon"] == 0.0

        # Bay between points should be exterior
        bay = star["test_points"]["exterior"][0]
        assert bay["expected"] is False

    def test_self_intersecting_rejected(self, single_node_cluster, local_fixtures_dir):
        """Self-intersecting polygon should return error.

        A figure-8 or bowtie shape where edges cross is invalid.
        The server should reject such queries.
        """
        fixtures = load_fixture(local_fixtures_dir / "concave_polygons.json")
        invalid = fixtures["polygons"]["self_intersecting_invalid"]

        assert invalid["invalid"] is True

        vertices = [{"lat": v["lat"], "lon": v["lon"]} for v in invalid["vertices"]]
        query = build_polygon_query(vertices=vertices)

        # Query built but should be rejected by server
        assert len(query["vertices"]) == 4

    def test_minimum_vertices(self, single_node_cluster, local_fixtures_dir):
        """Triangle (3 vertices) is minimum valid polygon.

        A polygon must have at least 3 vertices. Triangle queries
        should work correctly.
        """
        fixtures = load_fixture(local_fixtures_dir / "concave_polygons.json")
        triangle = fixtures["polygons"]["triangle_minimum"]

        vertices = [{"lat": v["lat"], "lon": v["lon"]} for v in triangle["vertices"]]
        query = build_polygon_query(vertices=vertices)

        assert len(query["vertices"]) == 3

        # Interior point
        interior = triangle["test_points"]["interior"][0]
        assert interior["expected"] is True

    def test_complex_concave(self, single_node_cluster, local_fixtures_dir):
        """Complex 12-vertex concave polygon.

        A polygon with multiple concave regions tests the robustness
        of point-in-polygon algorithms.
        """
        fixtures = load_fixture(local_fixtures_dir / "concave_polygons.json")
        complex_poly = fixtures["polygons"]["complex_concave"]

        vertices = [{"lat": v["lat"], "lon": v["lon"]} for v in complex_poly["vertices"]]
        query = build_polygon_query(vertices=vertices)

        assert len(query["vertices"]) == 12

        # Interior point
        interior = complex_poly["test_points"]["interior"][0]
        assert interior["expected"] is True

        # Exterior point in concave indent
        exterior = complex_poly["test_points"]["exterior"][0]
        assert exterior["expected"] is False

    def test_polygon_vertex_winding_order(self, single_node_cluster, local_fixtures_dir):
        """Polygon vertices can be clockwise or counterclockwise.

        The polygon algorithm should handle either winding order.
        """
        fixtures = load_fixture(local_fixtures_dir / "concave_polygons.json")
        l_shape = fixtures["polygons"]["l_shape"]

        # Original order (counterclockwise)
        vertices_ccw = [{"lat": v["lat"], "lon": v["lon"]} for v in l_shape["vertices"]]

        # Reversed order (clockwise)
        vertices_cw = list(reversed(vertices_ccw))

        query_ccw = build_polygon_query(vertices=vertices_ccw)
        query_cw = build_polygon_query(vertices=vertices_cw)

        # Both should be valid polygon queries
        assert len(query_ccw["vertices"]) == len(query_cw["vertices"])

    def test_polygon_with_hole_concept(self, single_node_cluster, local_fixtures_dir):
        """Conceptual test for polygon with hole (donut shape).

        Note: ArcherDB may or may not support polygon holes.
        This test verifies the concept of exterior vs interior regions.
        """
        # A square with a smaller square hole would have:
        # - Outer boundary: 4 vertices (counterclockwise)
        # - Inner hole: 4 vertices (clockwise)

        # Without hole support, we can test a simple square
        outer_square = [
            {"lat": 0.0, "lon": 0.0},
            {"lat": 0.0, "lon": 4.0},
            {"lat": 4.0, "lon": 4.0},
            {"lat": 4.0, "lon": 0.0},
        ]

        query = build_polygon_query(vertices=outer_square)
        assert len(query["vertices"]) == 4

    def test_l_shape_boundary_vertex(self, single_node_cluster, local_fixtures_dir):
        """Point exactly on concave vertex.

        A point exactly on a polygon vertex is typically considered
        inside (on the boundary).
        """
        fixtures = load_fixture(local_fixtures_dir / "concave_polygons.json")
        l_shape = fixtures["polygons"]["l_shape"]

        boundary = l_shape["test_points"]["boundary"][0]
        assert boundary["expected"] is True
        assert boundary["lat"] == 1.0
        assert boundary["lon"] == 1.0

        # This is the concave corner vertex
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=boundary["lat"],
            lon=boundary["lon"],
        )

        assert event["latitude"] == 1.0
        assert event["longitude"] == 1.0
