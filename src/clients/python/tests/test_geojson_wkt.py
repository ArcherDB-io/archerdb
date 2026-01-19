# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 Anthus Labs, Inc.
"""Tests for GeoJSON/WKT parsing and formatting functions."""

import pytest
import json
from archerdb.types import (
    GeoFormatError,
    GeoFormat,
    NANODEGREES_PER_DEGREE,
    parse_geojson_point,
    parse_geojson_polygon,
    parse_wkt_point,
    parse_wkt_polygon,
    to_geojson_point,
    to_geojson_polygon,
    to_wkt_point,
    to_wkt_polygon,
)


# ============================================================================
# GeoJSON Point Parsing Tests
# ============================================================================

class TestParseGeoJSONPoint:
    """Tests for parse_geojson_point function."""

    def test_parse_valid_dict(self):
        """Parse GeoJSON Point from dict."""
        geojson = {"type": "Point", "coordinates": [-122.4194, 37.7749]}
        lat_nano, lon_nano = parse_geojson_point(geojson)
        assert lat_nano == int(37.7749 * NANODEGREES_PER_DEGREE)
        assert lon_nano == int(-122.4194 * NANODEGREES_PER_DEGREE)

    def test_parse_valid_string(self):
        """Parse GeoJSON Point from JSON string."""
        geojson = '{"type": "Point", "coordinates": [-122.4194, 37.7749]}'
        lat_nano, lon_nano = parse_geojson_point(geojson)
        assert lat_nano == int(37.7749 * NANODEGREES_PER_DEGREE)
        assert lon_nano == int(-122.4194 * NANODEGREES_PER_DEGREE)

    def test_parse_with_altitude(self):
        """Parse GeoJSON Point with altitude (3D)."""
        geojson = {"type": "Point", "coordinates": [-122.4194, 37.7749, 100]}
        lat_nano, lon_nano = parse_geojson_point(geojson)
        assert lat_nano == int(37.7749 * NANODEGREES_PER_DEGREE)
        assert lon_nano == int(-122.4194 * NANODEGREES_PER_DEGREE)

    def test_parse_zero_coordinates(self):
        """Parse GeoJSON Point at origin."""
        geojson = {"type": "Point", "coordinates": [0, 0]}
        lat_nano, lon_nano = parse_geojson_point(geojson)
        assert lat_nano == 0
        assert lon_nano == 0

    def test_parse_extreme_coordinates(self):
        """Parse GeoJSON Point at extreme valid coordinates."""
        geojson = {"type": "Point", "coordinates": [180, 90]}
        lat_nano, lon_nano = parse_geojson_point(geojson)
        assert lat_nano == int(90 * NANODEGREES_PER_DEGREE)
        assert lon_nano == int(180 * NANODEGREES_PER_DEGREE)

        geojson = {"type": "Point", "coordinates": [-180, -90]}
        lat_nano, lon_nano = parse_geojson_point(geojson)
        assert lat_nano == int(-90 * NANODEGREES_PER_DEGREE)
        assert lon_nano == int(-180 * NANODEGREES_PER_DEGREE)

    def test_invalid_json_string(self):
        """Error on invalid JSON string."""
        with pytest.raises(GeoFormatError, match="Invalid JSON"):
            parse_geojson_point("{not valid json}")

    def test_wrong_type(self):
        """Error when type is not Point."""
        geojson = {"type": "Polygon", "coordinates": [[0, 0]]}
        with pytest.raises(GeoFormatError, match="Expected type 'Point'"):
            parse_geojson_point(geojson)

    def test_missing_coordinates(self):
        """Error when coordinates missing."""
        geojson = {"type": "Point"}
        with pytest.raises(GeoFormatError, match="must have.*coordinates"):
            parse_geojson_point(geojson)

    def test_latitude_out_of_range(self):
        """Error when latitude > 90."""
        geojson = {"type": "Point", "coordinates": [0, 91]}
        with pytest.raises(GeoFormatError, match="Latitude.*out of bounds"):
            parse_geojson_point(geojson)

    def test_longitude_out_of_range(self):
        """Error when longitude > 180."""
        geojson = {"type": "Point", "coordinates": [181, 0]}
        with pytest.raises(GeoFormatError, match="Longitude.*out of bounds"):
            parse_geojson_point(geojson)

    def test_not_dict(self):
        """Error when input is not dict."""
        with pytest.raises(GeoFormatError, match="must be a dict"):
            parse_geojson_point([0, 0])


# ============================================================================
# GeoJSON Polygon Parsing Tests
# ============================================================================

class TestParseGeoJSONPolygon:
    """Tests for parse_geojson_polygon function."""

    def test_parse_simple_polygon(self):
        """Parse simple triangle polygon."""
        geojson = {
            "type": "Polygon",
            "coordinates": [
                [[-122.4, 37.7], [-122.3, 37.7], [-122.3, 37.8], [-122.4, 37.7]]
            ]
        }
        exterior, holes = parse_geojson_polygon(geojson)
        assert len(exterior) == 4
        assert len(holes) == 0
        assert exterior[0] == (int(37.7 * NANODEGREES_PER_DEGREE), int(-122.4 * NANODEGREES_PER_DEGREE))

    def test_parse_polygon_with_hole(self):
        """Parse polygon with one hole."""
        geojson = {
            "type": "Polygon",
            "coordinates": [
                [[-122.4, 37.7], [-122.3, 37.7], [-122.3, 37.8], [-122.4, 37.8], [-122.4, 37.7]],
                [[-122.38, 37.72], [-122.35, 37.72], [-122.35, 37.78], [-122.38, 37.78], [-122.38, 37.72]]
            ]
        }
        exterior, holes = parse_geojson_polygon(geojson)
        assert len(exterior) == 5
        assert len(holes) == 1
        assert len(holes[0]) == 5

    def test_parse_polygon_with_multiple_holes(self):
        """Parse polygon with multiple holes."""
        geojson = {
            "type": "Polygon",
            "coordinates": [
                [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
                [[1, 1], [2, 1], [2, 2], [1, 2], [1, 1]],
                [[3, 3], [4, 3], [4, 4], [3, 4], [3, 3]],
            ]
        }
        exterior, holes = parse_geojson_polygon(geojson)
        assert len(exterior) == 5
        assert len(holes) == 2
        assert len(holes[0]) == 5
        assert len(holes[1]) == 5

    def test_parse_from_string(self):
        """Parse polygon from JSON string."""
        geojson_str = '{"type": "Polygon", "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 0]]]}'
        exterior, holes = parse_geojson_polygon(geojson_str)
        assert len(exterior) == 4
        assert len(holes) == 0

    def test_invalid_type(self):
        """Error when type is not Polygon."""
        geojson = {"type": "Point", "coordinates": [0, 0]}
        with pytest.raises(GeoFormatError, match="Expected type 'Polygon'"):
            parse_geojson_polygon(geojson)

    def test_ring_too_few_vertices(self):
        """Error when ring has fewer than 3 vertices."""
        geojson = {"type": "Polygon", "coordinates": [[[0, 0], [1, 1]]]}
        with pytest.raises(GeoFormatError, match="at least 3 vertices"):
            parse_geojson_polygon(geojson)

    def test_missing_coordinates(self):
        """Error when coordinates missing."""
        geojson = {"type": "Polygon"}
        with pytest.raises(GeoFormatError, match="at least one ring"):
            parse_geojson_polygon(geojson)


# ============================================================================
# WKT Point Parsing Tests
# ============================================================================

class TestParseWKTPoint:
    """Tests for parse_wkt_point function."""

    def test_parse_valid_point(self):
        """Parse WKT POINT."""
        lat_nano, lon_nano = parse_wkt_point("POINT(-122.4194 37.7749)")
        assert lat_nano == int(37.7749 * NANODEGREES_PER_DEGREE)
        assert lon_nano == int(-122.4194 * NANODEGREES_PER_DEGREE)

    def test_parse_with_spaces(self):
        """Parse WKT POINT with extra spaces."""
        lat_nano, lon_nano = parse_wkt_point("POINT( -122.4194  37.7749 )")
        assert lat_nano == int(37.7749 * NANODEGREES_PER_DEGREE)
        assert lon_nano == int(-122.4194 * NANODEGREES_PER_DEGREE)

    def test_parse_lowercase(self):
        """Parse lowercase WKT POINT."""
        lat_nano, lon_nano = parse_wkt_point("point(0 0)")
        assert lat_nano == 0
        assert lon_nano == 0

    def test_parse_with_z(self):
        """Parse WKT POINT with Z coordinate."""
        lat_nano, lon_nano = parse_wkt_point("POINT(-122.4 37.7 100)")
        assert lat_nano == int(37.7 * NANODEGREES_PER_DEGREE)
        assert lon_nano == int(-122.4 * NANODEGREES_PER_DEGREE)

    def test_invalid_wkt(self):
        """Error on invalid WKT."""
        with pytest.raises(GeoFormatError, match="Invalid WKT POINT"):
            parse_wkt_point("NOT A POINT")

    def test_latitude_out_of_range(self):
        """Error when latitude > 90."""
        with pytest.raises(GeoFormatError, match="Latitude.*out of bounds"):
            parse_wkt_point("POINT(0 91)")


# ============================================================================
# WKT Polygon Parsing Tests
# ============================================================================

class TestParseWKTPolygon:
    """Tests for parse_wkt_polygon function."""

    def test_parse_simple_polygon(self):
        """Parse simple WKT POLYGON."""
        wkt = "POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))"
        exterior, holes = parse_wkt_polygon(wkt)
        assert len(exterior) == 5
        assert len(holes) == 0
        assert exterior[0] == (0, 0)

    def test_parse_polygon_with_hole(self):
        """Parse WKT POLYGON with hole."""
        wkt = "POLYGON((0 0, 10 0, 10 10, 0 10, 0 0), (2 2, 4 2, 4 4, 2 4, 2 2))"
        exterior, holes = parse_wkt_polygon(wkt)
        assert len(exterior) == 5
        assert len(holes) == 1
        assert len(holes[0]) == 5

    def test_parse_with_spaces(self):
        """Parse WKT POLYGON with extra spaces."""
        wkt = "POLYGON( ( 0 0, 1 0, 1 1, 0 0 ) )"
        exterior, holes = parse_wkt_polygon(wkt)
        assert len(exterior) == 4
        assert len(holes) == 0

    def test_parse_lowercase(self):
        """Parse lowercase WKT POLYGON."""
        wkt = "polygon((0 0, 1 0, 1 1, 0 0))"
        exterior, holes = parse_wkt_polygon(wkt)
        assert len(exterior) == 4

    def test_invalid_wkt(self):
        """Error on invalid WKT."""
        with pytest.raises(GeoFormatError, match="Invalid WKT POLYGON"):
            parse_wkt_polygon("NOT A POLYGON")

    def test_empty_ring(self):
        """Error on empty ring."""
        with pytest.raises(GeoFormatError, match="at least one ring"):
            parse_wkt_polygon("POLYGON()")


# ============================================================================
# GeoJSON Output Tests
# ============================================================================

class TestToGeoJSON:
    """Tests for to_geojson_* functions."""

    def test_to_geojson_point(self):
        """Convert nanodegrees to GeoJSON Point."""
        lat_nano = int(37.7749 * NANODEGREES_PER_DEGREE)
        lon_nano = int(-122.4194 * NANODEGREES_PER_DEGREE)
        geojson = to_geojson_point(lat_nano, lon_nano)
        assert geojson["type"] == "Point"
        assert len(geojson["coordinates"]) == 2
        assert abs(geojson["coordinates"][0] - (-122.4194)) < 0.0001
        assert abs(geojson["coordinates"][1] - 37.7749) < 0.0001

    def test_to_geojson_polygon_simple(self):
        """Convert nanodegrees to GeoJSON Polygon."""
        exterior = [
            (0, 0),
            (int(1 * NANODEGREES_PER_DEGREE), 0),
            (int(1 * NANODEGREES_PER_DEGREE), int(1 * NANODEGREES_PER_DEGREE)),
            (0, 0)
        ]
        geojson = to_geojson_polygon(exterior)
        assert geojson["type"] == "Polygon"
        assert len(geojson["coordinates"]) == 1
        assert len(geojson["coordinates"][0]) == 4

    def test_to_geojson_polygon_with_holes(self):
        """Convert nanodegrees to GeoJSON Polygon with holes."""
        exterior = [(0, 0), (int(10e9), 0), (int(10e9), int(10e9)), (0, int(10e9)), (0, 0)]
        holes = [
            [(int(2e9), int(2e9)), (int(4e9), int(2e9)), (int(4e9), int(4e9)), (int(2e9), int(4e9)), (int(2e9), int(2e9))]
        ]
        geojson = to_geojson_polygon(exterior, holes)
        assert geojson["type"] == "Polygon"
        assert len(geojson["coordinates"]) == 2

    def test_roundtrip_geojson_point(self):
        """Roundtrip test: parse then output GeoJSON Point."""
        original = {"type": "Point", "coordinates": [-122.4194, 37.7749]}
        lat_nano, lon_nano = parse_geojson_point(original)
        result = to_geojson_point(lat_nano, lon_nano)
        assert result["type"] == original["type"]
        assert abs(result["coordinates"][0] - original["coordinates"][0]) < 0.0001
        assert abs(result["coordinates"][1] - original["coordinates"][1]) < 0.0001


# ============================================================================
# WKT Output Tests
# ============================================================================

class TestToWKT:
    """Tests for to_wkt_* functions."""

    def test_to_wkt_point(self):
        """Convert nanodegrees to WKT POINT."""
        lat_nano = int(37.7749 * NANODEGREES_PER_DEGREE)
        lon_nano = int(-122.4194 * NANODEGREES_PER_DEGREE)
        wkt = to_wkt_point(lat_nano, lon_nano)
        assert wkt.startswith("POINT(")
        assert wkt.endswith(")")
        # Check we can parse it back
        parsed_lat, parsed_lon = parse_wkt_point(wkt)
        assert abs(parsed_lat - lat_nano) < 1  # Allow for floating point rounding
        assert abs(parsed_lon - lon_nano) < 1

    def test_to_wkt_polygon_simple(self):
        """Convert nanodegrees to WKT POLYGON."""
        exterior = [
            (0, 0),
            (int(1 * NANODEGREES_PER_DEGREE), 0),
            (int(1 * NANODEGREES_PER_DEGREE), int(1 * NANODEGREES_PER_DEGREE)),
            (0, 0)
        ]
        wkt = to_wkt_polygon(exterior)
        assert wkt.startswith("POLYGON(")
        assert wkt.endswith(")")

    def test_to_wkt_polygon_with_holes(self):
        """Convert nanodegrees to WKT POLYGON with holes."""
        exterior = [(0, 0), (int(10e9), 0), (int(10e9), int(10e9)), (0, int(10e9)), (0, 0)]
        holes = [
            [(int(2e9), int(2e9)), (int(4e9), int(2e9)), (int(4e9), int(4e9)), (int(2e9), int(4e9)), (int(2e9), int(2e9))]
        ]
        wkt = to_wkt_polygon(exterior, holes)
        assert wkt.startswith("POLYGON(")
        # Should have two rings separated by comma
        assert ", (" in wkt

    def test_roundtrip_wkt_point(self):
        """Roundtrip test: output then parse WKT POINT."""
        lat_nano = int(37.7749 * NANODEGREES_PER_DEGREE)
        lon_nano = int(-122.4194 * NANODEGREES_PER_DEGREE)
        wkt = to_wkt_point(lat_nano, lon_nano)
        parsed_lat, parsed_lon = parse_wkt_point(wkt)
        assert abs(parsed_lat - lat_nano) < 1
        assert abs(parsed_lon - lon_nano) < 1


# ============================================================================
# GeoFormat Enum Tests
# ============================================================================

class TestGeoFormat:
    """Tests for GeoFormat enum."""

    def test_enum_values(self):
        """Verify GeoFormat enum values."""
        assert GeoFormat.NATIVE == 0
        assert GeoFormat.GEOJSON == 1
        assert GeoFormat.WKT == 2

    def test_enum_comparison(self):
        """Verify GeoFormat comparison."""
        assert GeoFormat.NATIVE < GeoFormat.GEOJSON
        assert GeoFormat.GEOJSON < GeoFormat.WKT
