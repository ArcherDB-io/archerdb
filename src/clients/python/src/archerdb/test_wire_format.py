"""
ArcherDB Python SDK - Wire Format Compatibility Tests

These tests verify that the Python SDK produces wire-compatible
output with other language SDKs by testing against canonical test cases.
"""

import json
import os
import unittest
from pathlib import Path

from . import (
    # Constants
    LAT_MAX,
    LON_MAX,
    NANODEGREES_PER_DEGREE,
    MM_PER_METER,
    CENTIDEGREES_PER_DEGREE,
    BATCH_SIZE_MAX,
    QUERY_LIMIT_MAX,
    POLYGON_VERTICES_MAX,
    # Enums
    GeoEventFlags,
    GeoOperation,
    InsertGeoEventResult,
    DeleteEntityResult,
    # Conversion helpers
    degrees_to_nano,
    nano_to_degrees,
    meters_to_mm,
    mm_to_meters,
    heading_to_centidegrees,
    centidegrees_to_heading,
    is_valid_latitude,
    is_valid_longitude,
    # Builder functions
    create_geo_event,
    create_radius_query,
    create_polygon_query,
)


def load_test_cases() -> dict:
    """Load canonical test cases from shared test data file."""
    # Find test data relative to this file's location
    test_data_path = Path(__file__).parent.parent.parent.parent.parent / "test-data" / "wire-format-test-cases.json"

    if not test_data_path.exists():
        # Try alternate path
        test_data_path = Path("/home/g/Sync/Projects/archerdb/src/clients/test-data/wire-format-test-cases.json")

    with open(test_data_path) as f:
        return json.load(f)


class TestWireFormatConstants(unittest.TestCase):
    """Test that constants match canonical values."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_coordinate_bounds(self):
        """Coordinate bounds match canonical values."""
        expected = self.test_data["constants"]
        self.assertEqual(LAT_MAX, expected["LAT_MAX"])
        self.assertEqual(LON_MAX, expected["LON_MAX"])

    def test_conversion_factors(self):
        """Conversion factors match canonical values."""
        expected = self.test_data["constants"]
        self.assertEqual(NANODEGREES_PER_DEGREE, expected["NANODEGREES_PER_DEGREE"])
        self.assertEqual(MM_PER_METER, expected["MM_PER_METER"])
        self.assertEqual(CENTIDEGREES_PER_DEGREE, expected["CENTIDEGREES_PER_DEGREE"])

    def test_limits(self):
        """Protocol limits match canonical values."""
        expected = self.test_data["constants"]
        self.assertEqual(BATCH_SIZE_MAX, expected["BATCH_SIZE_MAX"])
        self.assertEqual(QUERY_LIMIT_MAX, expected["QUERY_LIMIT_MAX"])
        self.assertEqual(POLYGON_VERTICES_MAX, expected["POLYGON_VERTICES_MAX"])


class TestWireFormatOperationCodes(unittest.TestCase):
    """Test that operation codes match canonical values."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_operation_codes(self):
        """All operation codes match canonical values."""
        expected = self.test_data["operation_codes"]
        self.assertEqual(GeoOperation.INSERT_EVENTS, expected["INSERT_EVENTS"])
        self.assertEqual(GeoOperation.UPSERT_EVENTS, expected["UPSERT_EVENTS"])
        self.assertEqual(GeoOperation.DELETE_ENTITIES, expected["DELETE_ENTITIES"])
        self.assertEqual(GeoOperation.QUERY_UUID, expected["QUERY_UUID"])
        self.assertEqual(GeoOperation.QUERY_RADIUS, expected["QUERY_RADIUS"])
        self.assertEqual(GeoOperation.QUERY_POLYGON, expected["QUERY_POLYGON"])
        self.assertEqual(GeoOperation.QUERY_LATEST, expected["QUERY_LATEST"])


class TestWireFormatFlags(unittest.TestCase):
    """Test that GeoEvent flags match canonical values."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_geo_event_flags(self):
        """All GeoEvent flags match canonical values."""
        expected = self.test_data["geo_event_flags"]
        self.assertEqual(GeoEventFlags.NONE, expected["NONE"])
        self.assertEqual(GeoEventFlags.LINKED, expected["LINKED"])
        self.assertEqual(GeoEventFlags.IMPORTED, expected["IMPORTED"])
        self.assertEqual(GeoEventFlags.STATIONARY, expected["STATIONARY"])
        self.assertEqual(GeoEventFlags.LOW_ACCURACY, expected["LOW_ACCURACY"])
        self.assertEqual(GeoEventFlags.OFFLINE, expected["OFFLINE"])
        self.assertEqual(GeoEventFlags.DELETED, expected["DELETED"])


class TestWireFormatResultCodes(unittest.TestCase):
    """Test that result codes match canonical values."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_insert_result_codes(self):
        """All insert result codes match canonical values."""
        expected = self.test_data["insert_result_codes"]
        self.assertEqual(InsertGeoEventResult.OK, expected["OK"])
        self.assertEqual(InsertGeoEventResult.LINKED_EVENT_FAILED, expected["LINKED_EVENT_FAILED"])
        self.assertEqual(InsertGeoEventResult.LINKED_EVENT_CHAIN_OPEN, expected["LINKED_EVENT_CHAIN_OPEN"])
        self.assertEqual(InsertGeoEventResult.TIMESTAMP_MUST_BE_ZERO, expected["TIMESTAMP_MUST_BE_ZERO"])
        self.assertEqual(InsertGeoEventResult.RESERVED_FIELD, expected["RESERVED_FIELD"])
        self.assertEqual(InsertGeoEventResult.RESERVED_FLAG, expected["RESERVED_FLAG"])
        self.assertEqual(InsertGeoEventResult.ID_MUST_NOT_BE_ZERO, expected["ID_MUST_NOT_BE_ZERO"])
        self.assertEqual(InsertGeoEventResult.ENTITY_ID_MUST_NOT_BE_ZERO, expected["ENTITY_ID_MUST_NOT_BE_ZERO"])
        self.assertEqual(InsertGeoEventResult.INVALID_COORDINATES, expected["INVALID_COORDINATES"])
        self.assertEqual(InsertGeoEventResult.LAT_OUT_OF_RANGE, expected["LAT_OUT_OF_RANGE"])
        self.assertEqual(InsertGeoEventResult.LON_OUT_OF_RANGE, expected["LON_OUT_OF_RANGE"])
        self.assertEqual(InsertGeoEventResult.EXISTS_WITH_DIFFERENT_ENTITY_ID, expected["EXISTS_WITH_DIFFERENT_ENTITY_ID"])
        self.assertEqual(InsertGeoEventResult.EXISTS_WITH_DIFFERENT_COORDINATES, expected["EXISTS_WITH_DIFFERENT_COORDINATES"])
        self.assertEqual(InsertGeoEventResult.EXISTS, expected["EXISTS"])
        self.assertEqual(InsertGeoEventResult.HEADING_OUT_OF_RANGE, expected["HEADING_OUT_OF_RANGE"])
        self.assertEqual(InsertGeoEventResult.TTL_INVALID, expected["TTL_INVALID"])

    def test_delete_result_codes(self):
        """All delete result codes match canonical values."""
        expected = self.test_data["delete_result_codes"]
        self.assertEqual(DeleteEntityResult.OK, expected["OK"])
        self.assertEqual(DeleteEntityResult.LINKED_EVENT_FAILED, expected["LINKED_EVENT_FAILED"])
        self.assertEqual(DeleteEntityResult.ENTITY_ID_MUST_NOT_BE_ZERO, expected["ENTITY_ID_MUST_NOT_BE_ZERO"])
        self.assertEqual(DeleteEntityResult.ENTITY_NOT_FOUND, expected["ENTITY_NOT_FOUND"])


class TestWireFormatCoordinateConversions(unittest.TestCase):
    """Test coordinate conversion compatibility."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_degrees_to_nanodegrees(self):
        """Degrees to nanodegrees conversion matches canonical values."""
        for case in self.test_data["coordinate_conversions"]:
            with self.subTest(case["description"]):
                result = degrees_to_nano(case["degrees"])
                self.assertEqual(
                    result,
                    case["expected_nanodegrees"],
                    f"{case['description']}: {case['degrees']} degrees -> {result}, expected {case['expected_nanodegrees']}"
                )

    def test_nanodegrees_to_degrees_roundtrip(self):
        """Nanodegrees roundtrip maintains precision."""
        for case in self.test_data["coordinate_conversions"]:
            with self.subTest(case["description"]):
                nano = case["expected_nanodegrees"]
                degrees = nano_to_degrees(nano)
                back_to_nano = degrees_to_nano(degrees)
                self.assertEqual(
                    back_to_nano,
                    nano,
                    f"{case['description']}: roundtrip failed"
                )


class TestWireFormatDistanceConversions(unittest.TestCase):
    """Test distance conversion compatibility."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_meters_to_millimeters(self):
        """Meters to millimeters conversion matches canonical values."""
        for case in self.test_data["distance_conversions"]:
            with self.subTest(case["description"]):
                result = meters_to_mm(case["meters"])
                self.assertEqual(
                    result,
                    case["expected_mm"],
                    f"{case['description']}: {case['meters']} meters -> {result}, expected {case['expected_mm']}"
                )


class TestWireFormatHeadingConversions(unittest.TestCase):
    """Test heading conversion compatibility."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_heading_to_centidegrees(self):
        """Heading to centidegrees conversion matches canonical values."""
        for case in self.test_data["heading_conversions"]:
            with self.subTest(case["description"]):
                result = heading_to_centidegrees(case["degrees"])
                self.assertEqual(
                    result,
                    case["expected_centidegrees"],
                    f"{case['description']}: {case['degrees']} degrees -> {result}, expected {case['expected_centidegrees']}"
                )


class TestWireFormatGeoEvents(unittest.TestCase):
    """Test GeoEvent creation matches canonical values."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_geo_event_creation(self):
        """GeoEvent creation matches canonical expected values."""
        for case in self.test_data["geo_events"]:
            with self.subTest(case["description"]):
                input_data = case["input"]
                expected = case["expected"]

                # Build event from input
                event = create_geo_event(
                    entity_id=input_data["entity_id"],
                    latitude=input_data["latitude"],
                    longitude=input_data["longitude"],
                    correlation_id=input_data.get("correlation_id", 0),
                    user_data=input_data.get("user_data", 0),
                    group_id=input_data.get("group_id", 0),
                    altitude_m=input_data.get("altitude_m", 0.0),
                    velocity_mps=input_data.get("velocity_mps", 0.0),
                    ttl_seconds=input_data.get("ttl_seconds", 0),
                    accuracy_m=input_data.get("accuracy_m", 0.0),
                    heading=input_data.get("heading", 0.0),
                    flags=GeoEventFlags(input_data.get("flags", 0)),
                )

                # Verify all fields
                self.assertEqual(event.entity_id, expected["entity_id"], f"{case['description']}: entity_id mismatch")
                self.assertEqual(event.lat_nano, expected["lat_nano"], f"{case['description']}: lat_nano mismatch")
                self.assertEqual(event.lon_nano, expected["lon_nano"], f"{case['description']}: lon_nano mismatch")
                self.assertEqual(event.id, expected["id"], f"{case['description']}: id mismatch")
                self.assertEqual(event.timestamp, expected["timestamp"], f"{case['description']}: timestamp mismatch")
                self.assertEqual(event.correlation_id, expected["correlation_id"], f"{case['description']}: correlation_id mismatch")
                self.assertEqual(event.user_data, expected["user_data"], f"{case['description']}: user_data mismatch")
                self.assertEqual(event.group_id, expected["group_id"], f"{case['description']}: group_id mismatch")
                self.assertEqual(event.altitude_mm, expected["altitude_mm"], f"{case['description']}: altitude_mm mismatch")
                self.assertEqual(event.velocity_mms, expected["velocity_mms"], f"{case['description']}: velocity_mms mismatch")
                self.assertEqual(event.ttl_seconds, expected["ttl_seconds"], f"{case['description']}: ttl_seconds mismatch")
                self.assertEqual(event.accuracy_mm, expected["accuracy_mm"], f"{case['description']}: accuracy_mm mismatch")
                self.assertEqual(event.heading_cdeg, expected["heading_cdeg"], f"{case['description']}: heading_cdeg mismatch")
                self.assertEqual(int(event.flags), expected["flags"], f"{case['description']}: flags mismatch")


class TestWireFormatRadiusQueries(unittest.TestCase):
    """Test radius query creation matches canonical values."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_radius_query_creation(self):
        """Radius query creation matches canonical expected values."""
        for case in self.test_data["radius_queries"]:
            with self.subTest(case["description"]):
                input_data = case["input"]
                expected = case["expected"]

                query = create_radius_query(
                    latitude=input_data["latitude"],
                    longitude=input_data["longitude"],
                    radius_m=input_data["radius_m"],
                    limit=input_data.get("limit", 1000),
                    timestamp_min=input_data.get("timestamp_min", 0),
                    timestamp_max=input_data.get("timestamp_max", 0),
                    group_id=input_data.get("group_id", 0),
                )

                self.assertEqual(query.center_lat_nano, expected["center_lat_nano"], f"{case['description']}: center_lat_nano mismatch")
                self.assertEqual(query.center_lon_nano, expected["center_lon_nano"], f"{case['description']}: center_lon_nano mismatch")
                self.assertEqual(query.radius_mm, expected["radius_mm"], f"{case['description']}: radius_mm mismatch")
                self.assertEqual(query.limit, expected["limit"], f"{case['description']}: limit mismatch")
                self.assertEqual(query.timestamp_min, expected["timestamp_min"], f"{case['description']}: timestamp_min mismatch")
                self.assertEqual(query.timestamp_max, expected["timestamp_max"], f"{case['description']}: timestamp_max mismatch")
                self.assertEqual(query.group_id, expected["group_id"], f"{case['description']}: group_id mismatch")


class TestWireFormatPolygonQueries(unittest.TestCase):
    """Test polygon query creation matches canonical values."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_polygon_query_creation(self):
        """Polygon query creation matches canonical expected values."""
        for case in self.test_data["polygon_queries"]:
            with self.subTest(case["description"]):
                input_data = case["input"]
                expected = case["expected"]

                # Convert vertices from [lat, lon] arrays to tuples
                vertices = [(v[0], v[1]) for v in input_data["vertices"]]

                query = create_polygon_query(
                    vertices=vertices,
                    limit=input_data.get("limit", 1000),
                    timestamp_min=input_data.get("timestamp_min", 0),
                    timestamp_max=input_data.get("timestamp_max", 0),
                    group_id=input_data.get("group_id", 0),
                )

                # Verify vertices
                self.assertEqual(len(query.vertices), len(expected["vertices"]), f"{case['description']}: vertex count mismatch")
                for i, (actual, exp) in enumerate(zip(query.vertices, expected["vertices"])):
                    self.assertEqual(actual.lat_nano, exp["lat_nano"], f"{case['description']}: vertex {i} lat_nano mismatch")
                    self.assertEqual(actual.lon_nano, exp["lon_nano"], f"{case['description']}: vertex {i} lon_nano mismatch")

                self.assertEqual(query.limit, expected["limit"], f"{case['description']}: limit mismatch")
                self.assertEqual(query.timestamp_min, expected["timestamp_min"], f"{case['description']}: timestamp_min mismatch")
                self.assertEqual(query.timestamp_max, expected["timestamp_max"], f"{case['description']}: timestamp_max mismatch")
                self.assertEqual(query.group_id, expected["group_id"], f"{case['description']}: group_id mismatch")


class TestWireFormatValidation(unittest.TestCase):
    """Test coordinate validation matches canonical expectations."""

    @classmethod
    def setUpClass(cls):
        cls.test_data = load_test_cases()

    def test_invalid_latitudes_rejected(self):
        """Invalid latitudes are rejected."""
        for lat in self.test_data["validation_cases"]["invalid_latitudes"]:
            with self.subTest(latitude=lat):
                self.assertFalse(is_valid_latitude(lat), f"Latitude {lat} should be invalid")

    def test_invalid_longitudes_rejected(self):
        """Invalid longitudes are rejected."""
        for lon in self.test_data["validation_cases"]["invalid_longitudes"]:
            with self.subTest(longitude=lon):
                self.assertFalse(is_valid_longitude(lon), f"Longitude {lon} should be invalid")

    def test_valid_boundary_latitudes_accepted(self):
        """Boundary latitudes are accepted."""
        for lat in self.test_data["validation_cases"]["valid_boundary_latitudes"]:
            with self.subTest(latitude=lat):
                self.assertTrue(is_valid_latitude(lat), f"Latitude {lat} should be valid")

    def test_valid_boundary_longitudes_accepted(self):
        """Boundary longitudes are accepted."""
        for lon in self.test_data["validation_cases"]["valid_boundary_longitudes"]:
            with self.subTest(longitude=lon):
                self.assertTrue(is_valid_longitude(lon), f"Longitude {lon} should be valid")


def run_tests():
    """Run all wire format compatibility tests."""
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(__import__(__name__))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    print("\n" + "=" * 70)
    total = result.testsRun
    failures = len(result.failures)
    errors = len(result.errors)
    passed = total - failures - errors

    if result.wasSuccessful():
        print(f"WIRE FORMAT COMPATIBILITY: All {total} tests passed!")
    else:
        print(f"WIRE FORMAT COMPATIBILITY: {passed}/{total} passed, {failures} failures, {errors} errors")

    return result.wasSuccessful()


if __name__ == "__main__":
    import sys
    success = run_tests()
    sys.exit(0 if success else 1)
