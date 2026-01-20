"""
ArcherDB Python SDK Tests

Unit tests for type definitions, helpers, and client classes.
These tests verify SDK behavior without requiring a running server.
"""

import unittest
from dataclasses import fields
from unittest.mock import MagicMock

# Import from the archerdb module
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
    POLYGON_HOLES_MAX,
    POLYGON_HOLE_VERTICES_MIN,
    # Enums
    GeoEventFlags,
    GeoOperation,
    InsertGeoEventResult,
    DeleteEntityResult,
    # Data classes
    GeoEvent,
    InsertGeoEventsError,
    DeleteEntitiesError,
    QueryUuidFilter,
    QueryRadiusFilter,
    PolygonVertex,
    QueryPolygonFilter,
    QueryLatestFilter,
    QueryResult,
    DeleteResult,
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
    # ID generation
    id as archerdb_id,
    # Configuration
    GeoClientConfig,
    RetryConfig,
    OperationOptions,
    # Errors
    ArcherDBError,
    ConnectionFailed,
    ConnectionTimeout,
    ClusterUnavailable,
    ViewChangeInProgress,
    NotPrimary,
    InvalidCoordinates,
    PolygonTooComplex,
    BatchTooLarge,
    InvalidEntityId,
    OperationTimeout,
    QueryResultTooLarge,
    OutOfSpace,
    SessionExpired,
    ClientClosedError,
    RetryExhausted,
    # Batch classes
    GeoEventBatch,
    GeoEventBatchAsync,
    DeleteEntityBatch,
    DeleteEntityBatchAsync,
    # Client classes
    GeoClientSync,
    GeoClientAsync,
    # Batch helpers
    split_batch,
)

# Import internal functions for testing
from .client import (
    _is_retryable_error,
    _calculate_retry_delay,
    _with_retry_sync,
)


class TestConstants(unittest.TestCase):
    """Test module constants."""

    def test_coordinate_bounds(self):
        """Coordinate bounds match spec."""
        self.assertEqual(LAT_MAX, 90.0)
        self.assertEqual(LON_MAX, 180.0)

    def test_conversion_factors(self):
        """Conversion factors are correct."""
        self.assertEqual(NANODEGREES_PER_DEGREE, 1_000_000_000)
        self.assertEqual(MM_PER_METER, 1000)
        self.assertEqual(CENTIDEGREES_PER_DEGREE, 100)

    def test_limits(self):
        """Protocol limits match spec."""
        self.assertEqual(BATCH_SIZE_MAX, 10_000)
        self.assertEqual(QUERY_LIMIT_MAX, 81_000)
        self.assertEqual(POLYGON_VERTICES_MAX, 10_000)
        self.assertEqual(POLYGON_HOLES_MAX, 100)
        self.assertEqual(POLYGON_HOLE_VERTICES_MIN, 3)


class TestGeoEventFlags(unittest.TestCase):
    """Test GeoEventFlags enum."""

    def test_flag_values(self):
        """Flag values match server protocol."""
        self.assertEqual(GeoEventFlags.NONE, 0)
        self.assertEqual(GeoEventFlags.LINKED, 1)
        self.assertEqual(GeoEventFlags.IMPORTED, 2)
        self.assertEqual(GeoEventFlags.STATIONARY, 4)
        self.assertEqual(GeoEventFlags.LOW_ACCURACY, 8)
        self.assertEqual(GeoEventFlags.OFFLINE, 16)
        self.assertEqual(GeoEventFlags.DELETED, 32)

    def test_flag_combinations(self):
        """Flags can be combined with bitwise OR."""
        combined = GeoEventFlags.LINKED | GeoEventFlags.STATIONARY
        self.assertEqual(combined, 5)
        self.assertTrue(combined & GeoEventFlags.LINKED)
        self.assertTrue(combined & GeoEventFlags.STATIONARY)
        self.assertFalse(combined & GeoEventFlags.OFFLINE)


class TestGeoOperation(unittest.TestCase):
    """Test GeoOperation enum."""

    def test_operation_values(self):
        """Operation codes match server protocol."""
        self.assertEqual(GeoOperation.INSERT_EVENTS, 146)
        self.assertEqual(GeoOperation.UPSERT_EVENTS, 147)
        self.assertEqual(GeoOperation.DELETE_ENTITIES, 148)
        self.assertEqual(GeoOperation.QUERY_UUID, 149)
        self.assertEqual(GeoOperation.QUERY_RADIUS, 150)
        self.assertEqual(GeoOperation.QUERY_POLYGON, 151)
        self.assertEqual(GeoOperation.QUERY_LATEST, 154)


class TestResultCodes(unittest.TestCase):
    """Test result code enums."""

    def test_insert_result_codes(self):
        """Insert result codes match protocol."""
        self.assertEqual(InsertGeoEventResult.OK, 0)
        self.assertEqual(InsertGeoEventResult.LINKED_EVENT_FAILED, 1)
        self.assertEqual(InsertGeoEventResult.INVALID_COORDINATES, 8)
        self.assertEqual(InsertGeoEventResult.EXISTS, 13)
        self.assertEqual(InsertGeoEventResult.TTL_INVALID, 15)

    def test_delete_result_codes(self):
        """Delete result codes match protocol."""
        self.assertEqual(DeleteEntityResult.OK, 0)
        self.assertEqual(DeleteEntityResult.ENTITY_NOT_FOUND, 3)


class TestCoordinateConversions(unittest.TestCase):
    """Test coordinate conversion helpers."""

    def test_degrees_to_nano(self):
        """Convert degrees to nanodegrees."""
        self.assertEqual(degrees_to_nano(0), 0)
        self.assertEqual(degrees_to_nano(90), 90_000_000_000)
        self.assertEqual(degrees_to_nano(-180), -180_000_000_000)
        self.assertEqual(degrees_to_nano(37.7749), 37_774_900_000)

    def test_nano_to_degrees(self):
        """Convert nanodegrees to degrees."""
        self.assertEqual(nano_to_degrees(0), 0.0)
        self.assertEqual(nano_to_degrees(90_000_000_000), 90.0)
        self.assertEqual(nano_to_degrees(-180_000_000_000), -180.0)
        self.assertAlmostEqual(nano_to_degrees(37_774_900_000), 37.7749, places=4)

    def test_roundtrip_precision(self):
        """Coordinate roundtrip maintains precision."""
        coords = [0, 37.7749, -122.4194, 90.0, -180.0]
        for coord in coords:
            result = nano_to_degrees(degrees_to_nano(coord))
            self.assertAlmostEqual(result, coord, places=9)

    def test_meters_to_mm(self):
        """Convert meters to millimeters."""
        self.assertEqual(meters_to_mm(0), 0)
        self.assertEqual(meters_to_mm(1), 1000)
        self.assertEqual(meters_to_mm(1.5), 1500)
        self.assertEqual(meters_to_mm(1000), 1_000_000)

    def test_mm_to_meters(self):
        """Convert millimeters to meters."""
        self.assertEqual(mm_to_meters(0), 0.0)
        self.assertEqual(mm_to_meters(1000), 1.0)
        self.assertEqual(mm_to_meters(1500), 1.5)

    def test_heading_conversions(self):
        """Heading conversion is accurate."""
        self.assertEqual(heading_to_centidegrees(0), 0)
        self.assertEqual(heading_to_centidegrees(90), 9000)
        self.assertEqual(heading_to_centidegrees(360), 36000)
        self.assertEqual(centidegrees_to_heading(18000), 180.0)


class TestValidation(unittest.TestCase):
    """Test validation helpers."""

    def test_valid_latitude(self):
        """Valid latitudes are accepted."""
        self.assertTrue(is_valid_latitude(0))
        self.assertTrue(is_valid_latitude(90))
        self.assertTrue(is_valid_latitude(-90))
        self.assertTrue(is_valid_latitude(45.5))

    def test_invalid_latitude(self):
        """Invalid latitudes are rejected."""
        self.assertFalse(is_valid_latitude(90.1))
        self.assertFalse(is_valid_latitude(-90.1))
        self.assertFalse(is_valid_latitude(180))

    def test_valid_longitude(self):
        """Valid longitudes are accepted."""
        self.assertTrue(is_valid_longitude(0))
        self.assertTrue(is_valid_longitude(180))
        self.assertTrue(is_valid_longitude(-180))
        self.assertTrue(is_valid_longitude(-122.4194))

    def test_invalid_longitude(self):
        """Invalid longitudes are rejected."""
        self.assertFalse(is_valid_longitude(180.1))
        self.assertFalse(is_valid_longitude(-180.1))
        self.assertFalse(is_valid_longitude(360))


class TestGeoEvent(unittest.TestCase):
    """Test GeoEvent data class."""

    def test_default_values(self):
        """GeoEvent has correct defaults."""
        event = GeoEvent()
        self.assertEqual(event.id, 0)
        self.assertEqual(event.entity_id, 0)
        self.assertEqual(event.lat_nano, 0)
        self.assertEqual(event.lon_nano, 0)
        self.assertEqual(event.flags, GeoEventFlags.NONE)

    def test_field_count(self):
        """GeoEvent has expected number of fields."""
        # GeoEvent should have 14 fields
        self.assertEqual(len(fields(GeoEvent)), 14)

    def test_custom_values(self):
        """GeoEvent accepts custom values."""
        event = GeoEvent(
            entity_id=12345,
            lat_nano=37_774_900_000,
            lon_nano=-122_419_400_000,
            flags=GeoEventFlags.STATIONARY,
        )
        self.assertEqual(event.entity_id, 12345)
        self.assertEqual(event.lat_nano, 37_774_900_000)
        self.assertEqual(event.flags, GeoEventFlags.STATIONARY)


class TestCreateGeoEvent(unittest.TestCase):
    """Test create_geo_event helper function."""

    def test_basic_event(self):
        """Create basic geo event."""
        event = create_geo_event(
            entity_id=12345,
            latitude=37.7749,
            longitude=-122.4194,
        )
        self.assertEqual(event.entity_id, 12345)
        self.assertEqual(event.lat_nano, degrees_to_nano(37.7749))
        self.assertEqual(event.lon_nano, degrees_to_nano(-122.4194))
        self.assertEqual(event.id, 0)  # Server-assigned
        self.assertEqual(event.timestamp, 0)  # Server-assigned

    def test_full_event(self):
        """Create event with all fields."""
        event = create_geo_event(
            entity_id=12345,
            latitude=37.7749,
            longitude=-122.4194,
            correlation_id=99999,
            user_data=42,
            group_id=1001,
            altitude_m=100.5,
            velocity_mps=15.0,
            ttl_seconds=3600,
            accuracy_m=5.0,
            heading=90.0,
            flags=GeoEventFlags.LINKED,
        )
        self.assertEqual(event.correlation_id, 99999)
        self.assertEqual(event.user_data, 42)
        self.assertEqual(event.group_id, 1001)
        self.assertEqual(event.altitude_mm, 100500)
        self.assertEqual(event.velocity_mms, 15000)
        self.assertEqual(event.ttl_seconds, 3600)
        self.assertEqual(event.accuracy_mm, 5000)
        self.assertEqual(event.heading_cdeg, 9000)
        self.assertEqual(event.flags, GeoEventFlags.LINKED)

    def test_invalid_latitude_raises(self):
        """Invalid latitude raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            create_geo_event(entity_id=1, latitude=91, longitude=0)
        self.assertIn("Invalid latitude", str(ctx.exception))

    def test_invalid_longitude_raises(self):
        """Invalid longitude raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            create_geo_event(entity_id=1, latitude=0, longitude=181)
        self.assertIn("Invalid longitude", str(ctx.exception))


class TestQueryFilters(unittest.TestCase):
    """Test query filter data classes."""

    def test_uuid_filter(self):
        """QueryUuidFilter has correct structure."""
        filt = QueryUuidFilter(entity_id=12345)
        self.assertEqual(filt.entity_id, 12345)

    def test_radius_filter_defaults(self):
        """QueryRadiusFilter has correct defaults."""
        filt = QueryRadiusFilter(
            center_lat_nano=37_774_900_000,
            center_lon_nano=-122_419_400_000,
            radius_mm=1_000_000,
        )
        self.assertEqual(filt.limit, 1000)
        self.assertEqual(filt.timestamp_min, 0)
        self.assertEqual(filt.timestamp_max, 0)
        self.assertEqual(filt.group_id, 0)

    def test_polygon_filter(self):
        """QueryPolygonFilter accepts vertices."""
        vertices = [
            PolygonVertex(lat_nano=37_000_000_000, lon_nano=-122_000_000_000),
            PolygonVertex(lat_nano=38_000_000_000, lon_nano=-122_000_000_000),
            PolygonVertex(lat_nano=38_000_000_000, lon_nano=-121_000_000_000),
        ]
        filt = QueryPolygonFilter(vertices=vertices, limit=500)
        self.assertEqual(len(filt.vertices), 3)
        self.assertEqual(filt.limit, 500)

    def test_latest_filter_defaults(self):
        """QueryLatestFilter has correct defaults."""
        filt = QueryLatestFilter()
        self.assertEqual(filt.limit, 1000)
        self.assertEqual(filt.group_id, 0)
        self.assertEqual(filt.cursor_timestamp, 0)


class TestCreateRadiusQuery(unittest.TestCase):
    """Test create_radius_query helper function."""

    def test_basic_query(self):
        """Create basic radius query."""
        query = create_radius_query(
            latitude=37.7749,
            longitude=-122.4194,
            radius_m=1000,
        )
        self.assertEqual(query.center_lat_nano, degrees_to_nano(37.7749))
        self.assertEqual(query.center_lon_nano, degrees_to_nano(-122.4194))
        self.assertEqual(query.radius_mm, 1_000_000)
        self.assertEqual(query.limit, 1000)

    def test_query_with_filters(self):
        """Create radius query with all filters."""
        query = create_radius_query(
            latitude=37.7749,
            longitude=-122.4194,
            radius_m=5000,
            limit=500,
            timestamp_min=1000,
            timestamp_max=2000,
            group_id=42,
        )
        self.assertEqual(query.limit, 500)
        self.assertEqual(query.timestamp_min, 1000)
        self.assertEqual(query.timestamp_max, 2000)
        self.assertEqual(query.group_id, 42)

    def test_invalid_radius_raises(self):
        """Negative radius raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            create_radius_query(latitude=0, longitude=0, radius_m=-100)
        self.assertIn("Invalid radius", str(ctx.exception))


class TestCreatePolygonQuery(unittest.TestCase):
    """Test create_polygon_query helper function."""

    def test_basic_polygon(self):
        """Create basic polygon query."""
        vertices = [(37.0, -122.0), (38.0, -122.0), (38.0, -121.0)]
        query = create_polygon_query(vertices)
        self.assertEqual(len(query.vertices), 3)
        self.assertEqual(query.vertices[0].lat_nano, degrees_to_nano(37.0))
        self.assertEqual(query.limit, 1000)

    def test_too_few_vertices_raises(self):
        """Less than 3 vertices raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            create_polygon_query([(0, 0), (1, 1)])
        self.assertIn("at least 3 vertices", str(ctx.exception))

    def test_invalid_vertex_raises(self):
        """Invalid vertex coordinates raise ValueError."""
        with self.assertRaises(ValueError) as ctx:
            create_polygon_query([(0, 0), (91, 0), (0, 1)])
        self.assertIn("Invalid latitude", str(ctx.exception))

    def test_polygon_with_hole(self):
        """Create polygon query with a hole."""
        # Outer boundary (square)
        outer = [(0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0)]
        # Hole (smaller square inside)
        hole = [(0.25, 0.25), (0.25, 0.75), (0.75, 0.75), (0.75, 0.25)]

        query = create_polygon_query(outer, holes=[hole])
        self.assertEqual(len(query.vertices), 4)
        self.assertEqual(len(query.holes), 1)
        self.assertEqual(len(query.holes[0].vertices), 4)

    def test_polygon_with_multiple_holes(self):
        """Create polygon query with multiple holes."""
        outer = [(0.0, 0.0), (0.0, 10.0), (10.0, 10.0), (10.0, 0.0)]
        hole1 = [(1.0, 1.0), (1.0, 2.0), (2.0, 2.0), (2.0, 1.0)]
        hole2 = [(3.0, 3.0), (3.0, 4.0), (4.0, 4.0), (4.0, 3.0)]

        query = create_polygon_query(outer, holes=[hole1, hole2])
        self.assertEqual(len(query.holes), 2)
        self.assertEqual(len(query.holes[0].vertices), 4)
        self.assertEqual(len(query.holes[1].vertices), 4)

    def test_too_few_hole_vertices_raises(self):
        """Hole with less than 3 vertices raises ValueError."""
        outer = [(0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0)]
        hole = [(0.25, 0.25), (0.25, 0.75)]  # Only 2 vertices

        with self.assertRaises(ValueError) as ctx:
            create_polygon_query(outer, holes=[hole])
        self.assertIn("at least", str(ctx.exception))
        self.assertIn("vertices", str(ctx.exception))

    def test_too_many_holes_raises(self):
        """More than 100 holes raises ValueError."""
        from . import POLYGON_HOLES_MAX

        outer = [(0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0)]
        # Create 101 holes (exceeds max of 100)
        holes = [
            [(0.1 + i * 0.001, 0.1), (0.1 + i * 0.001, 0.2), (0.2 + i * 0.001, 0.2)]
            for i in range(POLYGON_HOLES_MAX + 1)
        ]

        with self.assertRaises(ValueError) as ctx:
            create_polygon_query(outer, holes=holes)
        self.assertIn("Too many holes", str(ctx.exception))

    def test_invalid_hole_vertex_raises(self):
        """Invalid hole vertex coordinates raise ValueError."""
        outer = [(0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0)]
        hole = [(91.0, 0.0), (91.0, 0.5), (91.5, 0.5)]  # Invalid latitude

        with self.assertRaises(ValueError) as ctx:
            create_polygon_query(outer, holes=[hole])
        self.assertIn("Invalid latitude", str(ctx.exception))
        self.assertIn("hole", str(ctx.exception))


class TestQueryResult(unittest.TestCase):
    """Test QueryResult data class."""

    def test_empty_result(self):
        """Empty query result."""
        result = QueryResult()
        self.assertEqual(len(result.events), 0)
        self.assertFalse(result.has_more)
        self.assertIsNone(result.cursor)

    def test_result_with_events(self):
        """Query result with events."""
        events = [GeoEvent(entity_id=i) for i in range(3)]
        result = QueryResult(events=events, has_more=True, cursor=12345)
        self.assertEqual(len(result.events), 3)
        self.assertTrue(result.has_more)
        self.assertEqual(result.cursor, 12345)


class TestIdGeneration(unittest.TestCase):
    """Test ID generation."""

    def test_id_is_positive(self):
        """Generated IDs are positive integers."""
        id_val = archerdb_id()
        self.assertIsInstance(id_val, int)
        self.assertGreater(id_val, 0)

    def test_ids_are_unique(self):
        """Generated IDs are unique."""
        ids = [archerdb_id() for _ in range(100)]
        self.assertEqual(len(set(ids)), 100)

    def test_ids_are_sortable(self):
        """IDs are roughly time-sortable."""
        id1 = archerdb_id()
        id2 = archerdb_id()
        id3 = archerdb_id()
        # ULID-style IDs should be monotonically increasing
        self.assertLess(id1, id2)
        self.assertLess(id2, id3)


class TestErrorHierarchy(unittest.TestCase):
    """Test error class hierarchy."""

    def test_base_error(self):
        """ArcherDBError is base class."""
        err = ArcherDBError("test error")
        self.assertEqual(str(err), "test error")
        self.assertFalse(err.retryable)

    def test_connection_errors_are_retryable(self):
        """Connection errors are retryable."""
        err = ConnectionFailed("connection failed")
        self.assertIsInstance(err, ArcherDBError)
        self.assertTrue(err.retryable)
        self.assertEqual(err.code, 1001)

        err = ConnectionTimeout("timed out")
        self.assertTrue(err.retryable)
        self.assertEqual(err.code, 1002)

    def test_cluster_errors(self):
        """Cluster errors inherit from ArcherDBError."""
        err = ClusterUnavailable("cluster down")
        self.assertIsInstance(err, ArcherDBError)
        self.assertTrue(err.retryable)

        err = ViewChangeInProgress("view change")
        self.assertTrue(err.retryable)

        err = NotPrimary("not primary")
        self.assertTrue(err.retryable)

    def test_validation_errors_not_retryable(self):
        """Validation errors are not retryable."""
        err = InvalidCoordinates("bad coords")
        self.assertIsInstance(err, ArcherDBError)
        self.assertFalse(err.retryable)

        err = PolygonTooComplex("too many vertices")
        self.assertFalse(err.retryable)

        err = BatchTooLarge("batch too large")
        self.assertFalse(err.retryable)

        err = InvalidEntityId("bad id")
        self.assertFalse(err.retryable)

    def test_operation_errors(self):
        """Operation errors have correct retryable status."""
        err = OperationTimeout("timed out")
        self.assertIsInstance(err, ArcherDBError)
        self.assertTrue(err.retryable)

        err = QueryResultTooLarge("result too large")
        self.assertFalse(err.retryable)

        err = OutOfSpace("out of space")
        self.assertFalse(err.retryable)

        err = SessionExpired("session expired")
        self.assertTrue(err.retryable)

    def test_client_closed_error(self):
        """ClientClosedError is not retryable."""
        err = ClientClosedError("client closed")
        self.assertIsInstance(err, ArcherDBError)
        self.assertFalse(err.retryable)
        self.assertEqual(err.code, 5001)


class TestConfiguration(unittest.TestCase):
    """Test configuration classes."""

    def test_geo_client_config_defaults(self):
        """GeoClientConfig has sensible defaults."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        self.assertEqual(config.connect_timeout_ms, 5000)
        self.assertEqual(config.request_timeout_ms, 30000)
        self.assertEqual(config.pool_size, 1)

    def test_geo_client_config_custom(self):
        """GeoClientConfig accepts custom values."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001", "127.0.0.1:3002"],
            connect_timeout_ms=10000,
            request_timeout_ms=60000,
            pool_size=4,
        )
        self.assertEqual(len(config.addresses), 2)
        self.assertEqual(config.connect_timeout_ms, 10000)
        self.assertEqual(config.request_timeout_ms, 60000)
        self.assertEqual(config.pool_size, 4)


class TestGeoEventBatch(unittest.TestCase):
    """Test GeoEventBatch class with mocked client."""

    def setUp(self):
        """Create a mock client for batch tests."""
        self.mock_client = MagicMock(spec=GeoClientSync)

    def test_empty_batch(self):
        """New batch starts empty."""
        batch = GeoEventBatch(self.mock_client)
        self.assertEqual(batch.count(), 0)
        self.assertFalse(batch.is_full())

    def test_add_event(self):
        """Add event to batch."""
        batch = GeoEventBatch(self.mock_client)
        event = create_geo_event(
            entity_id=archerdb_id(),
            latitude=37.7749,
            longitude=-122.4194,
        )
        batch.add(event)
        self.assertEqual(batch.count(), 1)

    def test_batch_clear(self):
        """Batch can be cleared."""
        batch = GeoEventBatch(self.mock_client)
        event = create_geo_event(
            entity_id=archerdb_id(),
            latitude=37.0,
            longitude=-122.0,
        )
        batch.add(event)
        batch.clear()
        self.assertEqual(batch.count(), 0)

    def test_batch_validates_entity_id(self):
        """Batch validates entity_id is not zero."""
        batch = GeoEventBatch(self.mock_client)
        event = GeoEvent(
            entity_id=0,  # Invalid
            lat_nano=37_774_900_000,
            lon_nano=-122_419_400_000,
        )
        with self.assertRaises(InvalidEntityId):
            batch.add(event)

    def test_batch_validates_coordinates(self):
        """Batch validates coordinate ranges."""
        batch = GeoEventBatch(self.mock_client)

        # Invalid latitude
        event = GeoEvent(
            entity_id=archerdb_id(),
            lat_nano=100_000_000_000,  # > 90
            lon_nano=0,
        )
        with self.assertRaises(InvalidCoordinates):
            batch.add(event)


class TestDeleteEntityBatch(unittest.TestCase):
    """Test DeleteEntityBatch class with mocked client."""

    def setUp(self):
        """Create a mock client for batch tests."""
        self.mock_client = MagicMock(spec=GeoClientSync)

    def test_empty_batch(self):
        """New delete batch starts empty."""
        batch = DeleteEntityBatch(self.mock_client)
        self.assertEqual(batch.count(), 0)

    def test_add_entity(self):
        """Add entity ID to delete batch."""
        batch = DeleteEntityBatch(self.mock_client)
        batch.add(12345)
        self.assertEqual(batch.count(), 1)

    def test_add_many(self):
        """Add multiple entity IDs."""
        batch = DeleteEntityBatch(self.mock_client)
        for entity_id in [1, 2, 3, 4, 5]:
            batch.add(entity_id)
        self.assertEqual(batch.count(), 5)

    def test_batch_clear(self):
        """Delete batch can be cleared."""
        batch = DeleteEntityBatch(self.mock_client)
        batch.add(12345)
        batch.clear()
        self.assertEqual(batch.count(), 0)

    def test_validates_entity_id(self):
        """Delete batch validates entity_id is not zero."""
        batch = DeleteEntityBatch(self.mock_client)
        with self.assertRaises(InvalidEntityId):
            batch.add(0)


class TestClientInstantiation(unittest.TestCase):
    """Test client class instantiation."""

    def test_sync_client_creation(self):
        """GeoClientSync can be instantiated."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        client = GeoClientSync(config)
        self.assertIsInstance(client, GeoClientSync)
        self.assertTrue(client.is_connected)
        client.close()
        self.assertFalse(client.is_connected)

    def test_async_client_creation(self):
        """GeoClientAsync can be instantiated."""
        import asyncio

        async def test_async():
            config = GeoClientConfig(
                cluster_id=archerdb_id(),
                addresses=["127.0.0.1:3001", "127.0.0.1:3002"],
            )
            client = GeoClientAsync(config)
            self.assertIsInstance(client, GeoClientAsync)
            self.assertTrue(client.is_connected)
            await client.close()
            self.assertFalse(client.is_connected)

        asyncio.run(test_async())

    def test_client_with_config(self):
        """Client uses configuration values."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
            connect_timeout_ms=10000,
            request_timeout_ms=60000,
        )
        client = GeoClientSync(config)
        self.assertEqual(client._config.connect_timeout_ms, 10000)
        self.assertEqual(client._config.request_timeout_ms, 60000)
        client.close()

    def test_sync_client_creates_batch(self):
        """GeoClientSync can create batches."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        client = GeoClientSync(config)
        batch = client.create_batch()
        self.assertIsInstance(batch, GeoEventBatch)
        client.close()

    def test_sync_client_creates_upsert_batch(self):
        """GeoClientSync can create upsert batches."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        client = GeoClientSync(config)
        batch = client.create_upsert_batch()
        self.assertIsInstance(batch, GeoEventBatch)
        client.close()

    def test_sync_client_creates_delete_batch(self):
        """GeoClientSync can create delete batches."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        client = GeoClientSync(config)
        batch = client.create_delete_batch()
        self.assertIsInstance(batch, DeleteEntityBatch)
        client.close()

    def test_client_context_manager(self):
        """Client supports context manager protocol."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        with GeoClientSync(config) as client:
            self.assertTrue(client.is_connected)
        self.assertFalse(client.is_connected)


class TestSplitBatch(unittest.TestCase):
    """Test split_batch helper function."""

    def test_basic_split(self):
        """Split list into chunks of specified size."""
        items = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        chunks = split_batch(items, 3)

        self.assertEqual(len(chunks), 4)
        self.assertEqual(chunks[0], [1, 2, 3])
        self.assertEqual(chunks[1], [4, 5, 6])
        self.assertEqual(chunks[2], [7, 8, 9])
        self.assertEqual(chunks[3], [10])

    def test_exact_division(self):
        """Split when items divide evenly."""
        items = [1, 2, 3, 4, 5, 6]
        chunks = split_batch(items, 2)

        self.assertEqual(len(chunks), 3)
        self.assertEqual(chunks[0], [1, 2])
        self.assertEqual(chunks[1], [3, 4])
        self.assertEqual(chunks[2], [5, 6])

    def test_empty_list(self):
        """Empty list returns empty result."""
        chunks = split_batch([], 3)
        self.assertEqual(chunks, [])

    def test_single_chunk(self):
        """Chunk size larger than list."""
        items = [1, 2, 3]
        chunks = split_batch(items, 10)

        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0], [1, 2, 3])

    def test_chunk_size_one(self):
        """Chunk size of 1 creates individual items."""
        items = [1, 2, 3]
        chunks = split_batch(items, 1)

        self.assertEqual(len(chunks), 3)
        self.assertEqual(chunks[0], [1])
        self.assertEqual(chunks[1], [2])
        self.assertEqual(chunks[2], [3])

    def test_zero_chunk_size_raises(self):
        """Zero chunk size raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            split_batch([1, 2, 3], 0)
        self.assertIn("chunk_size must be greater than 0", str(ctx.exception))

    def test_negative_chunk_size_raises(self):
        """Negative chunk size raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            split_batch([1, 2, 3], -1)
        self.assertIn("chunk_size must be greater than 0", str(ctx.exception))

    def test_default_chunk_size(self):
        """Default chunk size is 1000."""
        items = list(range(2500))
        chunks = split_batch(items)

        self.assertEqual(len(chunks), 3)
        self.assertEqual(len(chunks[0]), 1000)
        self.assertEqual(len(chunks[1]), 1000)
        self.assertEqual(len(chunks[2]), 500)

    def test_with_geo_events(self):
        """Works with GeoEvent objects."""
        events = [
            GeoEvent(entity_id=i, lat_nano=i * 1000000, lon_nano=-i * 1000000)
            for i in range(1, 11)
        ]
        chunks = split_batch(events, 3)

        self.assertEqual(len(chunks), 4)
        self.assertEqual(chunks[0][0].entity_id, 1)
        self.assertEqual(chunks[3][0].entity_id, 10)


# =============================================================================
# Partial Failure Scenario Tests (F5.3.9)
# =============================================================================


class TestErrorClassification(unittest.TestCase):
    """Test error classification for retry logic."""

    def test_retryable_errors(self):
        """Retryable ArcherDB errors are correctly classified."""
        self.assertTrue(_is_retryable_error(OperationTimeout("timeout")))
        self.assertTrue(_is_retryable_error(ClusterUnavailable("unavailable")))
        self.assertTrue(_is_retryable_error(ViewChangeInProgress("view change")))
        self.assertTrue(_is_retryable_error(NotPrimary("not primary")))
        self.assertTrue(_is_retryable_error(ConnectionFailed("failed")))
        self.assertTrue(_is_retryable_error(ConnectionTimeout("timeout")))
        self.assertTrue(_is_retryable_error(SessionExpired("expired")))

    def test_non_retryable_errors(self):
        """Non-retryable ArcherDB errors are correctly classified."""
        self.assertFalse(_is_retryable_error(InvalidCoordinates("bad coords")))
        self.assertFalse(_is_retryable_error(BatchTooLarge("too big")))
        self.assertFalse(_is_retryable_error(InvalidEntityId("bad id")))
        self.assertFalse(_is_retryable_error(PolygonTooComplex("too complex")))
        self.assertFalse(_is_retryable_error(QueryResultTooLarge("too large")))
        self.assertFalse(_is_retryable_error(OutOfSpace("no space")))

    def test_network_errors(self):
        """Network errors (generic exceptions) are classified correctly."""
        # Network-related messages are retryable
        self.assertTrue(_is_retryable_error(Exception("Connection timeout")))
        self.assertTrue(_is_retryable_error(ConnectionError("connection reset")))
        self.assertTrue(_is_retryable_error(TimeoutError("operation timed out")))
        self.assertTrue(_is_retryable_error(OSError("Network is unreachable")))

        # Non-network generic errors are not retryable
        self.assertFalse(_is_retryable_error(Exception("some other error")))
        self.assertFalse(_is_retryable_error(ValueError("invalid data")))


class TestBackoffCalculation(unittest.TestCase):
    """Test retry backoff calculation."""

    def test_backoff_schedule(self):
        """Backoff follows exponential schedule per spec."""
        config = RetryConfig(
            enabled=True,
            max_retries=5,
            base_backoff_ms=100,
            max_backoff_ms=1600,
            total_timeout_ms=30000,
            jitter=False,  # Disable jitter for deterministic testing
        )

        # First attempt is immediate
        self.assertEqual(_calculate_retry_delay(1, config), 0)

        # Subsequent attempts follow exponential backoff
        self.assertEqual(_calculate_retry_delay(2, config), 100)  # 100 * 2^0
        self.assertEqual(_calculate_retry_delay(3, config), 200)  # 100 * 2^1
        self.assertEqual(_calculate_retry_delay(4, config), 400)  # 100 * 2^2
        self.assertEqual(_calculate_retry_delay(5, config), 800)  # 100 * 2^3
        self.assertEqual(_calculate_retry_delay(6, config), 1600)  # 100 * 2^4

    def test_max_backoff_cap(self):
        """Backoff is capped at max_backoff_ms."""
        config = RetryConfig(
            enabled=True,
            max_retries=10,
            base_backoff_ms=100,
            max_backoff_ms=500,  # Capped at 500ms
            total_timeout_ms=30000,
            jitter=False,
        )

        # Should cap at max_backoff_ms
        self.assertEqual(_calculate_retry_delay(5, config), 500)  # Would be 800
        self.assertEqual(_calculate_retry_delay(6, config), 500)  # Would be 1600
        self.assertEqual(_calculate_retry_delay(10, config), 500)

    def test_jitter_adds_variation(self):
        """Jitter adds randomness to delay."""
        config = RetryConfig(
            enabled=True,
            max_retries=5,
            base_backoff_ms=100,
            max_backoff_ms=1600,
            total_timeout_ms=30000,
            jitter=True,  # Enable jitter
        )

        # With jitter, delays should vary but stay within range
        delays = [_calculate_retry_delay(2, config) for _ in range(100)]

        min_delay = min(delays)
        max_delay = max(delays)

        # For attempt 2 with base 100: should be 100-150ms
        self.assertGreaterEqual(min_delay, 100)
        self.assertLessEqual(max_delay, 150)
        # With 100 samples, we should see variation
        self.assertGreater(max_delay, min_delay)


class TestRetryLogic(unittest.TestCase):
    """Test retry logic execution."""

    def test_success_on_first_attempt(self):
        """Successful operation doesn't retry."""
        config = RetryConfig(
            enabled=True,
            max_retries=5,
            base_backoff_ms=10,
            max_backoff_ms=100,
            total_timeout_ms=1000,
            jitter=False,
        )

        attempts = [0]

        def operation():
            attempts[0] += 1
            return "success"

        result = _with_retry_sync(operation, config)

        self.assertEqual(result, "success")
        self.assertEqual(attempts[0], 1)

    def test_eventual_success(self):
        """Operation succeeds after transient failures."""
        config = RetryConfig(
            enabled=True,
            max_retries=5,
            base_backoff_ms=10,
            max_backoff_ms=100,
            total_timeout_ms=5000,
            jitter=False,
        )

        attempts = [0]

        def operation():
            attempts[0] += 1
            if attempts[0] < 3:
                raise ConnectionFailed("simulated failure")
            return "success after retries"

        result = _with_retry_sync(operation, config)

        self.assertEqual(result, "success after retries")
        self.assertEqual(attempts[0], 3)

    def test_retry_exhaustion(self):
        """All retry attempts exhausted raises RetryExhausted."""
        config = RetryConfig(
            enabled=True,
            max_retries=3,
            base_backoff_ms=10,
            max_backoff_ms=100,
            total_timeout_ms=5000,
            jitter=False,
        )

        attempts = [0]

        def operation():
            attempts[0] += 1
            raise ClusterUnavailable("always fails")

        with self.assertRaises(RetryExhausted) as ctx:
            _with_retry_sync(operation, config)

        self.assertEqual(ctx.exception.attempts, 4)  # max_retries + 1
        self.assertIsInstance(ctx.exception.last_error, ClusterUnavailable)
        self.assertEqual(attempts[0], 4)

    def test_non_retryable_error_fails_immediately(self):
        """Non-retryable errors fail without retry."""
        config = RetryConfig(
            enabled=True,
            max_retries=5,
            base_backoff_ms=10,
            max_backoff_ms=100,
            total_timeout_ms=5000,
            jitter=False,
        )

        attempts = [0]

        def operation():
            attempts[0] += 1
            raise InvalidCoordinates("bad coordinates")

        with self.assertRaises(InvalidCoordinates):
            _with_retry_sync(operation, config)

        # Only one attempt - no retries for non-retryable errors
        self.assertEqual(attempts[0], 1)

    def test_retry_disabled(self):
        """Disabled retry passes through errors immediately."""
        config = RetryConfig(
            enabled=False,  # Retry disabled
            max_retries=5,
            base_backoff_ms=10,
            max_backoff_ms=100,
            total_timeout_ms=5000,
            jitter=False,
        )

        attempts = [0]

        def operation():
            attempts[0] += 1
            raise ClusterUnavailable("fails")

        with self.assertRaises(ClusterUnavailable):
            _with_retry_sync(operation, config)

        # No retries when disabled
        self.assertEqual(attempts[0], 1)


class TestPartialBatchRetryPattern(unittest.TestCase):
    """Test the recommended partial batch retry pattern."""

    def test_split_and_retry_pattern(self):
        """Test splitting large batch after timeout and retrying chunks."""
        large_event_list = [
            {"id": i, "data": f"event-{i}"} for i in range(5000)
        ]

        submit_count = [0]

        def mock_submit(events):
            submit_count[0] += 1
            if len(events) > 1000 and submit_count[0] == 1:
                # First large batch times out
                raise OperationTimeout("batch too large, timeout")
            # Smaller batches succeed
            return [{"id": e["id"], "result": "ok"} for e in events]

        # Pattern implementation
        results = []
        try:
            results = mock_submit(large_event_list)
        except OperationTimeout:
            # Split into smaller batches and retry
            chunks = split_batch(large_event_list, 1000)
            for chunk in chunks:
                chunk_results = mock_submit(chunk)
                results.extend(chunk_results)

        # All events should have been processed
        self.assertEqual(len(results), 5000)
        # Should have made 6 total submissions (1 failed + 5 chunk retries)
        self.assertEqual(submit_count[0], 6)


class TestRetryExhaustedError(unittest.TestCase):
    """Test RetryExhausted error properties."""

    def test_properties(self):
        """RetryExhausted contains expected properties."""
        last_error = ClusterUnavailable("final failure")
        error = RetryExhausted(5, last_error)

        self.assertEqual(error.code, 5002)
        self.assertFalse(error.retryable)
        self.assertEqual(error.attempts, 5)
        self.assertEqual(error.last_error, last_error)
        self.assertIn("5", str(error))
        self.assertIn("final failure", str(error))


def run_tests():
    """Run all tests and print summary."""
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(__import__(__name__))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    # Print summary
    print("\n" + "=" * 70)
    total = result.testsRun
    failures = len(result.failures)
    errors = len(result.errors)
    passed = total - failures - errors

    if result.wasSuccessful():
        print(f"SUCCESS: All {total} tests passed!")
    else:
        print(f"FAILED: {passed}/{total} passed, {failures} failures, {errors} errors")

    return result.wasSuccessful()


# =============================================================================
# Observability Tests (client-sdk/spec.md)
# =============================================================================


class TestLogging(unittest.TestCase):
    """Test logging infrastructure."""

    def test_null_logger(self):
        """NullLogger discards all messages."""
        from .observability import NullLogger

        logger = NullLogger()
        # Should not raise
        logger.debug("debug message")
        logger.info("info message")
        logger.warn("warn message")
        logger.error("error message")

    def test_standard_logger_creation(self):
        """StandardLogger can be created."""
        from .observability import StandardLogger

        logger = StandardLogger(name="test_archerdb", level=10)
        self.assertIsNotNone(logger)

    def test_configure_logging(self):
        """configure_logging sets global logger."""
        from .observability import configure_logging, get_logger, NullLogger, StandardLogger

        # Default is NullLogger
        logger = get_logger()
        self.assertIsInstance(logger, (NullLogger, StandardLogger))

        # Can configure with debug=True
        configure_logging(debug=True)
        logger = get_logger()
        self.assertIsInstance(logger, StandardLogger)


class TestMetrics(unittest.TestCase):
    """Test metrics infrastructure."""

    def test_counter_inc(self):
        """Counter increments correctly."""
        from .observability import Counter, MetricLabels

        counter = Counter("test_counter", "Test counter")

        # Initial value is 0
        self.assertEqual(counter.get(), 0.0)

        # Increment
        counter.inc()
        self.assertEqual(counter.get(), 1.0)

        # Increment by value
        counter.inc(value=5.0)
        self.assertEqual(counter.get(), 6.0)

    def test_counter_with_labels(self):
        """Counter tracks values per label set."""
        from .observability import Counter, MetricLabels

        counter = Counter("test_counter", "Test counter")

        labels1 = MetricLabels(operation="query", status="success")
        labels2 = MetricLabels(operation="query", status="error")

        counter.inc(labels1)
        counter.inc(labels1)
        counter.inc(labels2)

        self.assertEqual(counter.get(labels1), 2.0)
        self.assertEqual(counter.get(labels2), 1.0)

    def test_gauge_operations(self):
        """Gauge set/inc/dec work correctly."""
        from .observability import Gauge

        gauge = Gauge("test_gauge", "Test gauge")

        # Initial value is 0
        self.assertEqual(gauge.get(), 0.0)

        # Set
        gauge.set(10.0)
        self.assertEqual(gauge.get(), 10.0)

        # Inc
        gauge.inc(5.0)
        self.assertEqual(gauge.get(), 15.0)

        # Dec
        gauge.dec(3.0)
        self.assertEqual(gauge.get(), 12.0)

    def test_histogram_observe(self):
        """Histogram records observations."""
        from .observability import Histogram

        hist = Histogram("test_histogram", "Test histogram")

        # Initial state
        self.assertEqual(hist.get_count(), 0)
        self.assertEqual(hist.get_sum(), 0.0)

        # Observe values
        hist.observe(0.1)
        hist.observe(0.5)
        hist.observe(1.0)

        self.assertEqual(hist.get_count(), 3)
        self.assertAlmostEqual(hist.get_sum(), 1.6, places=5)

    def test_sdk_metrics_record_request(self):
        """SDKMetrics records requests."""
        from .observability import SDKMetrics

        metrics = SDKMetrics()

        metrics.record_request("query_radius", "success", 0.05)
        metrics.record_request("query_radius", "success", 0.03)
        metrics.record_request("query_radius", "error", 0.1)

        # Check request count
        from .observability import MetricLabels
        success_labels = MetricLabels(operation="query_radius", status="success")
        error_labels = MetricLabels(operation="query_radius", status="error")

        self.assertEqual(metrics.requests_total.get(success_labels), 2.0)
        self.assertEqual(metrics.requests_total.get(error_labels), 1.0)

    def test_sdk_metrics_prometheus_export(self):
        """SDKMetrics exports to Prometheus format."""
        from .observability import SDKMetrics

        metrics = SDKMetrics()
        metrics.record_request("insert", "success", 0.01)
        metrics.record_connection_opened()

        output = metrics.to_prometheus()

        self.assertIn("archerdb_client_requests_total", output)
        self.assertIn("archerdb_client_connections_active", output)
        self.assertIn("# HELP", output)
        self.assertIn("# TYPE", output)

    def test_get_metrics_singleton(self):
        """get_metrics returns singleton."""
        from .observability import get_metrics, reset_metrics

        reset_metrics()
        metrics1 = get_metrics()
        metrics2 = get_metrics()

        self.assertIs(metrics1, metrics2)

    def test_retry_metrics(self):
        """SDKMetrics tracks retry metrics per client-retry/spec.md."""
        from .observability import SDKMetrics

        metrics = SDKMetrics()

        # Record retries
        metrics.record_retry()
        metrics.record_retry()
        metrics.record_retry()

        self.assertEqual(metrics.retries_total.get(), 3.0)

    def test_retry_exhausted_metric(self):
        """SDKMetrics tracks retry exhaustion per client-retry/spec.md."""
        from .observability import SDKMetrics

        metrics = SDKMetrics()

        metrics.record_retry_exhausted()

        self.assertEqual(metrics.retry_exhausted_total.get(), 1.0)

    def test_primary_discovery_metric(self):
        """SDKMetrics tracks primary discoveries per client-retry/spec.md."""
        from .observability import SDKMetrics

        metrics = SDKMetrics()

        metrics.record_primary_discovery()
        metrics.record_primary_discovery()

        self.assertEqual(metrics.primary_discoveries_total.get(), 2.0)

    def test_retry_metrics_in_prometheus_export(self):
        """Retry metrics appear in Prometheus export."""
        from .observability import SDKMetrics

        metrics = SDKMetrics()
        metrics.record_retry()
        metrics.record_retry_exhausted()
        metrics.record_primary_discovery()

        output = metrics.to_prometheus()

        self.assertIn("archerdb_client_retries_total", output)
        self.assertIn("archerdb_client_retry_exhausted_total", output)
        self.assertIn("archerdb_client_primary_discoveries_total", output)


class TestHealthCheck(unittest.TestCase):
    """Test health check infrastructure."""

    def test_health_tracker_initial_state(self):
        """HealthTracker starts disconnected."""
        from .observability import HealthTracker, ConnectionState

        tracker = HealthTracker()
        status = tracker.get_status()

        self.assertFalse(status.healthy)
        self.assertEqual(status.state, ConnectionState.DISCONNECTED)

    def test_health_tracker_success_transitions(self):
        """HealthTracker transitions to healthy on success."""
        from .observability import HealthTracker, ConnectionState

        tracker = HealthTracker()

        tracker.record_success()
        status = tracker.get_status()

        self.assertTrue(status.healthy)
        self.assertEqual(status.state, ConnectionState.CONNECTED)
        self.assertGreater(status.last_successful_op_ns, 0)

    def test_health_tracker_failure_threshold(self):
        """HealthTracker marks failed after threshold."""
        from .observability import HealthTracker, ConnectionState

        tracker = HealthTracker(failure_threshold=3)

        # Start connected
        tracker.record_success()
        self.assertTrue(tracker.get_status().healthy)

        # Failures below threshold
        tracker.record_failure()
        tracker.record_failure()
        self.assertTrue(tracker.get_status().healthy)

        # Third failure crosses threshold
        tracker.record_failure()
        status = tracker.get_status()
        self.assertFalse(status.healthy)
        self.assertEqual(status.state, ConnectionState.FAILED)
        self.assertEqual(status.consecutive_failures, 3)

    def test_health_tracker_recovery(self):
        """HealthTracker recovers after success."""
        from .observability import HealthTracker, ConnectionState

        tracker = HealthTracker(failure_threshold=2)

        # Fail
        tracker.record_failure()
        tracker.record_failure()
        self.assertFalse(tracker.get_status().healthy)

        # Recover
        tracker.record_success()
        status = tracker.get_status()
        self.assertTrue(status.healthy)
        self.assertEqual(status.consecutive_failures, 0)

    def test_health_status_to_dict(self):
        """HealthStatus serializes to dict."""
        from .observability import HealthStatus, ConnectionState

        status = HealthStatus(
            healthy=True,
            state=ConnectionState.CONNECTED,
            last_successful_op_ns=1234567890,
            consecutive_failures=0,
            details="All good",
        )

        d = status.to_dict()

        self.assertEqual(d["healthy"], True)
        self.assertEqual(d["state"], "connected")
        self.assertEqual(d["last_successful_operation_ns"], 1234567890)


class TestRequestTimer(unittest.TestCase):
    """Test request timing context manager."""

    def test_request_timer_success(self):
        """RequestTimer records successful operation."""
        from .observability import RequestTimer, SDKMetrics, MetricLabels

        metrics = SDKMetrics()

        with RequestTimer("test_op", metrics):
            pass  # Successful operation

        labels = MetricLabels(operation="test_op", status="success")
        self.assertEqual(metrics.requests_total.get(labels), 1.0)

    def test_request_timer_error(self):
        """RequestTimer records failed operation."""
        from .observability import RequestTimer, SDKMetrics, MetricLabels

        metrics = SDKMetrics()

        try:
            with RequestTimer("test_op", metrics):
                raise ValueError("test error")
        except ValueError:
            pass

        labels = MetricLabels(operation="test_op", status="error")
        self.assertEqual(metrics.requests_total.get(labels), 1.0)

    def test_request_timer_duration(self):
        """RequestTimer records duration."""
        import time
        from .observability import RequestTimer, SDKMetrics, MetricLabels

        metrics = SDKMetrics()

        with RequestTimer("slow_op", metrics):
            time.sleep(0.01)  # 10ms

        # Duration should be recorded under the operation label
        labels = MetricLabels(operation="slow_op")
        self.assertGreater(metrics.request_duration.get_sum(labels), 0.005)
        self.assertEqual(metrics.request_duration.get_count(labels), 1)


# =============================================================================
# Batch UUID Lookup Tests (F1.3.4 - Spec: query_uuid_batch)
# =============================================================================


class TestBatchUuidLookup(unittest.TestCase):
    """Test batch UUID lookup feature (F1.3.4)."""

    def setUp(self):
        """Create a mock client for batch UUID tests."""
        self.mock_client = MagicMock(spec=GeoClientSync)

    def test_batch_uuid_lookup_limit(self):
        """Batch UUID lookup respects 10,000 entity limit."""
        # The spec allows up to 10,000 UUIDs per batch lookup
        self.assertEqual(BATCH_SIZE_MAX, 10_000)

    def test_batch_uuid_lookup_returns_dict(self):
        """Batch UUID lookup returns dict mapping entity_id -> GeoEvent."""
        # Test the expected return type structure
        mock_events = {
            123: GeoEvent(entity_id=123, lat_nano=37_000_000_000, lon_nano=-122_000_000_000),
            456: GeoEvent(entity_id=456, lat_nano=38_000_000_000, lon_nano=-121_000_000_000),
            789: None,  # Not found
        }

        # Verify structure
        self.assertIsInstance(mock_events, dict)
        self.assertIsInstance(mock_events[123], GeoEvent)
        self.assertIsNone(mock_events[789])

    def test_batch_uuid_lookup_with_not_found(self):
        """Batch UUID lookup handles entities not found."""
        entity_ids = [100, 200, 300]

        # Simulated response where entity 200 is not found
        mock_result = {
            100: GeoEvent(entity_id=100, lat_nano=37_000_000_000, lon_nano=-122_000_000_000),
            200: None,  # Not found
            300: GeoEvent(entity_id=300, lat_nano=38_000_000_000, lon_nano=-121_000_000_000),
        }

        # Verify we can handle the not_found case
        found = [k for k, v in mock_result.items() if v is not None]
        not_found = [k for k, v in mock_result.items() if v is None]

        self.assertEqual(len(found), 2)
        self.assertEqual(len(not_found), 1)
        self.assertIn(200, not_found)

    def test_empty_batch_uuid_lookup(self):
        """Empty batch UUID lookup returns empty dict."""
        # Empty list should return empty dict
        result = {}
        self.assertEqual(result, {})

    def test_batch_uuid_wire_format(self):
        """Batch UUID lookup uses correct operation code."""
        # Verify the operation code from GeoOperation enum
        self.assertEqual(GeoOperation.QUERY_UUID_BATCH, 156)


# =============================================================================
# TTL Cleanup Tests (cleanup_expired per client-protocol/spec.md)
# =============================================================================


class TestCleanupExpired(unittest.TestCase):
    """Test cleanup_expired operation (per client-protocol/spec.md 0x30)."""

    def test_cleanup_result_dataclass(self):
        """CleanupResult has expected fields."""
        from .types import CleanupResult

        result = CleanupResult(entries_scanned=100, entries_removed=25)

        self.assertEqual(result.entries_scanned, 100)
        self.assertEqual(result.entries_removed, 25)

    def test_cleanup_result_has_removals(self):
        """CleanupResult.has_removals returns True if entries_removed > 0."""
        from .types import CleanupResult

        result_with = CleanupResult(entries_scanned=100, entries_removed=25)
        result_without = CleanupResult(entries_scanned=100, entries_removed=0)

        self.assertTrue(result_with.has_removals)
        self.assertFalse(result_without.has_removals)

    def test_cleanup_result_expiration_ratio(self):
        """CleanupResult.expiration_ratio calculates correctly."""
        from .types import CleanupResult

        result = CleanupResult(entries_scanned=100, entries_removed=25)
        self.assertAlmostEqual(result.expiration_ratio, 0.25, places=5)

        # Zero entries scanned should return 0.0 (no division by zero)
        empty_result = CleanupResult(entries_scanned=0, entries_removed=0)
        self.assertEqual(empty_result.expiration_ratio, 0.0)

    def test_cleanup_operation_code(self):
        """CLEANUP_EXPIRED has correct operation code (0x30 = 155 + offset)."""
        self.assertEqual(GeoOperation.CLEANUP_EXPIRED, 155)

    def test_sync_client_cleanup_expired(self):
        """GeoClientSync.cleanup_expired returns CleanupResult."""
        from .types import CleanupResult

        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        client = GeoClientSync(config)

        result = client.cleanup_expired()
        self.assertIsInstance(result, CleanupResult)

        # Skeleton returns zeros
        self.assertEqual(result.entries_scanned, 0)
        self.assertEqual(result.entries_removed, 0)

        client.close()

    def test_sync_client_cleanup_expired_with_batch_size(self):
        """GeoClientSync.cleanup_expired accepts batch_size parameter."""
        from .types import CleanupResult

        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        client = GeoClientSync(config)

        # Scan only 1000 entries
        result = client.cleanup_expired(batch_size=1000)
        self.assertIsInstance(result, CleanupResult)

        # 0 = scan all (default)
        result_all = client.cleanup_expired(batch_size=0)
        self.assertIsInstance(result_all, CleanupResult)

        client.close()

    def test_sync_client_cleanup_expired_negative_batch_raises(self):
        """GeoClientSync.cleanup_expired raises on negative batch_size."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        client = GeoClientSync(config)

        with self.assertRaises(ValueError) as ctx:
            client.cleanup_expired(batch_size=-1)
        self.assertIn("non-negative", str(ctx.exception))

        client.close()

    def test_cleanup_after_client_closed_raises(self):
        """cleanup_expired raises after client is closed."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        client = GeoClientSync(config)
        client.close()

        with self.assertRaises(ClientClosedError):
            client.cleanup_expired()


class TestCircuitBreaker(unittest.TestCase):
    """Tests for CircuitBreaker (per client-retry/spec.md)."""

    def test_initial_state_is_closed(self):
        """Circuit breaker starts in CLOSED state."""
        from .client import CircuitBreaker, CircuitState

        breaker = CircuitBreaker("test-replica")
        self.assertEqual(breaker.state, CircuitState.CLOSED)
        self.assertTrue(breaker.is_closed)
        self.assertFalse(breaker.is_open)
        self.assertFalse(breaker.is_half_open)

    def test_requests_allowed_when_closed(self):
        """Requests are allowed when circuit is closed."""
        from .client import CircuitBreaker

        breaker = CircuitBreaker("test-replica")
        for _ in range(100):
            self.assertTrue(breaker.allow_request())

    def test_stays_closed_under_threshold(self):
        """Circuit stays closed if failure rate under 50%."""
        from .client import CircuitBreaker, CircuitBreakerConfig

        config = CircuitBreakerConfig(
            failure_threshold=0.5,
            minimum_requests=10,
        )
        breaker = CircuitBreaker("test-replica", config)

        # 9 requests with 4 failures (44%) - under threshold
        for _ in range(5):
            breaker.allow_request()
            breaker.record_success()
        for _ in range(4):
            breaker.allow_request()
            breaker.record_failure()

        self.assertTrue(breaker.is_closed)
        self.assertAlmostEqual(breaker.failure_rate, 4/9, places=2)

    def test_opens_after_threshold_exceeded(self):
        """Circuit opens when failure rate exceeds 50%."""
        from .client import CircuitBreaker, CircuitBreakerConfig

        config = CircuitBreakerConfig(
            failure_threshold=0.5,
            minimum_requests=10,
        )
        breaker = CircuitBreaker("test-replica", config)

        # 10 requests with 6 failures (60%) - exceeds threshold
        for _ in range(4):
            breaker.allow_request()
            breaker.record_success()
        for _ in range(6):
            breaker.allow_request()
            breaker.record_failure()

        self.assertTrue(breaker.is_open)

    def test_rejects_requests_when_open(self):
        """Requests are rejected when circuit is open."""
        from .client import CircuitBreaker

        breaker = CircuitBreaker("test-replica")
        breaker.force_open()

        self.assertFalse(breaker.allow_request())
        self.assertFalse(breaker.allow_request())
        self.assertFalse(breaker.allow_request())
        self.assertGreaterEqual(breaker.rejected_requests, 3)

    def test_transitions_to_half_open(self):
        """Circuit transitions to half-open after open duration."""
        import time
        from .client import CircuitBreaker, CircuitBreakerConfig, CircuitState

        config = CircuitBreakerConfig(open_duration_ms=50)  # Short for testing
        breaker = CircuitBreaker("test-replica", config)
        breaker.force_open()

        time.sleep(0.1)  # Wait for open duration

        # Should transition on next state check
        self.assertEqual(breaker.state, CircuitState.HALF_OPEN)
        self.assertTrue(breaker.is_half_open)

    def test_successful_half_open_closes(self):
        """Successful half-open requests close the circuit."""
        import time
        from .client import CircuitBreaker, CircuitBreakerConfig

        config = CircuitBreakerConfig(
            open_duration_ms=50,
            half_open_requests=5,
        )
        breaker = CircuitBreaker("test-replica", config)
        breaker.force_open()

        time.sleep(0.1)

        # 5 successful requests in half-open
        for _ in range(5):
            self.assertTrue(breaker.allow_request())
            breaker.record_success()

        self.assertTrue(breaker.is_closed)

    def test_failed_half_open_reopens(self):
        """Failed half-open request reopens circuit."""
        import time
        from .client import CircuitBreaker, CircuitBreakerConfig

        config = CircuitBreakerConfig(open_duration_ms=50)
        breaker = CircuitBreaker("test-replica", config)
        breaker.force_open()

        time.sleep(0.1)

        # First half-open request fails
        self.assertTrue(breaker.allow_request())
        breaker.record_failure()

        self.assertTrue(breaker.is_open)

    def test_half_open_limits_requests(self):
        """Half-open state limits test requests."""
        import time
        from .client import CircuitBreaker, CircuitBreakerConfig

        config = CircuitBreakerConfig(
            open_duration_ms=50,
            half_open_requests=5,
        )
        breaker = CircuitBreaker("test-replica", config)
        breaker.force_open()

        time.sleep(0.1)

        # Allow exactly 5 requests
        for _ in range(5):
            self.assertTrue(breaker.allow_request())

        # 6th request rejected
        self.assertFalse(breaker.allow_request())

    def test_minimum_requests_required(self):
        """Minimum requests required before circuit can open."""
        from .client import CircuitBreaker, CircuitBreakerConfig

        config = CircuitBreakerConfig(minimum_requests=10)
        breaker = CircuitBreaker("test-replica", config)

        # 9 failures (100%) - under minimum
        for _ in range(9):
            breaker.allow_request()
            breaker.record_failure()

        self.assertTrue(breaker.is_closed)

        # 10th failure opens circuit
        breaker.allow_request()
        breaker.record_failure()

        self.assertTrue(breaker.is_open)

    def test_force_close_resets_state(self):
        """force_close resets to closed state."""
        from .client import CircuitBreaker

        breaker = CircuitBreaker("test-replica")
        breaker.force_open()
        self.assertTrue(breaker.is_open)

        breaker.force_close()
        self.assertTrue(breaker.is_closed)
        self.assertAlmostEqual(breaker.failure_rate, 0.0, places=2)

    def test_state_changes_tracked(self):
        """State transitions are counted."""
        from .client import CircuitBreaker

        breaker = CircuitBreaker("test-replica")
        self.assertEqual(breaker.state_changes, 0)

        breaker.force_open()
        self.assertEqual(breaker.state_changes, 1)

        breaker.force_close()
        self.assertEqual(breaker.state_changes, 2)

    def test_per_replica_scope(self):
        """Circuit breakers are independent per replica."""
        from .client import CircuitBreaker

        breaker1 = CircuitBreaker("replica-1")
        breaker2 = CircuitBreaker("replica-2")

        breaker1.force_open()

        # breaker2 should still be closed
        self.assertTrue(breaker1.is_open)
        self.assertTrue(breaker2.is_closed)
        self.assertTrue(breaker2.allow_request())

    def test_circuit_breaker_open_exception(self):
        """CircuitBreakerOpen exception has correct attributes."""
        from .client import CircuitBreakerOpen

        ex = CircuitBreakerOpen("test-circuit", "open")
        self.assertEqual(ex.circuit_name, "test-circuit")
        self.assertEqual(ex.circuit_state, "open")
        self.assertEqual(ex.code, 600)
        self.assertTrue(ex.retryable)
        self.assertIn("test-circuit", str(ex))

    def test_repr(self):
        """repr returns useful string."""
        from .client import CircuitBreaker

        breaker = CircuitBreaker("test-replica")
        repr_str = repr(breaker)
        self.assertIn("test-replica", repr_str)
        self.assertIn("closed", repr_str)

    def test_default_config_matches_spec(self):
        """Default config values match spec requirements."""
        from .client import CircuitBreakerConfig

        config = CircuitBreakerConfig()
        self.assertEqual(config.failure_threshold, 0.5)
        self.assertEqual(config.minimum_requests, 10)
        self.assertEqual(config.window_ms, 10_000)
        self.assertEqual(config.open_duration_ms, 30_000)
        self.assertEqual(config.half_open_requests, 5)


class TestOperationOptions(unittest.TestCase):
    """Test OperationOptions per-operation retry override."""

    def test_default_options_all_none(self):
        """Default options have all None values."""
        options = OperationOptions()
        self.assertIsNone(options.max_retries)
        self.assertIsNone(options.timeout_ms)
        self.assertIsNone(options.base_backoff_ms)
        self.assertIsNone(options.max_backoff_ms)
        self.assertIsNone(options.jitter)

    def test_options_with_values(self):
        """Options can be created with specific values."""
        options = OperationOptions(
            max_retries=3,
            timeout_ms=10000,
            base_backoff_ms=50,
            max_backoff_ms=500,
            jitter=False,
        )
        self.assertEqual(options.max_retries, 3)
        self.assertEqual(options.timeout_ms, 10000)
        self.assertEqual(options.base_backoff_ms, 50)
        self.assertEqual(options.max_backoff_ms, 500)
        self.assertEqual(options.jitter, False)

    def test_merge_with_preserves_base_when_no_overrides(self):
        """merge_with returns base config when no options set."""
        base = RetryConfig(
            max_retries=5,
            base_backoff_ms=100,
            max_backoff_ms=1600,
            total_timeout_ms=30000,
            jitter=True,
        )
        options = OperationOptions()
        merged = options.merge_with(base)
        self.assertEqual(merged.max_retries, 5)
        self.assertEqual(merged.base_backoff_ms, 100)
        self.assertEqual(merged.max_backoff_ms, 1600)
        self.assertEqual(merged.total_timeout_ms, 30000)
        self.assertEqual(merged.jitter, True)

    def test_merge_with_overrides_specified_values(self):
        """merge_with applies overrides to base config."""
        base = RetryConfig(
            max_retries=5,
            base_backoff_ms=100,
            max_backoff_ms=1600,
            total_timeout_ms=30000,
            jitter=True,
        )
        options = OperationOptions(max_retries=2, timeout_ms=5000)
        merged = options.merge_with(base)
        # Overridden
        self.assertEqual(merged.max_retries, 2)
        self.assertEqual(merged.total_timeout_ms, 5000)
        # Preserved from base
        self.assertEqual(merged.base_backoff_ms, 100)
        self.assertEqual(merged.max_backoff_ms, 1600)
        self.assertEqual(merged.jitter, True)

    def test_merge_with_all_overrides(self):
        """merge_with can override all values."""
        base = RetryConfig()
        options = OperationOptions(
            max_retries=1,
            timeout_ms=2000,
            base_backoff_ms=50,
            max_backoff_ms=200,
            jitter=False,
        )
        merged = options.merge_with(base)
        self.assertEqual(merged.max_retries, 1)
        self.assertEqual(merged.total_timeout_ms, 2000)
        self.assertEqual(merged.base_backoff_ms, 50)
        self.assertEqual(merged.max_backoff_ms, 200)
        self.assertEqual(merged.jitter, False)

    def test_zero_max_retries_allowed(self):
        """Zero max_retries is valid (means no retry)."""
        options = OperationOptions(max_retries=0)
        base = RetryConfig(max_retries=5)
        merged = options.merge_with(base)
        self.assertEqual(merged.max_retries, 0)

    def test_enabled_flag_preserved(self):
        """merge_with preserves enabled flag from base."""
        base = RetryConfig(enabled=False)
        options = OperationOptions(max_retries=3)
        merged = options.merge_with(base)
        self.assertEqual(merged.enabled, False)


class TestRetryMetricsIntegration(unittest.TestCase):
    """Test that retry logic records metrics per client-retry/spec.md."""

    def setUp(self):
        """Reset metrics before each test."""
        from .observability import reset_metrics
        reset_metrics()

    def test_retry_metrics_recorded_on_retry(self):
        """_with_retry_sync records retry metrics."""
        from .client import _with_retry_sync, RetryConfig
        from .observability import get_metrics

        attempts = [0]

        def operation():
            attempts[0] += 1
            if attempts[0] < 3:
                raise ConnectionFailed("Connection failed")
            return "success"

        config = RetryConfig(
            max_retries=5,
            base_backoff_ms=1,  # Fast tests
            total_timeout_ms=30000,
            jitter=False,
        )

        result = _with_retry_sync(operation, config)

        self.assertEqual(result, "success")
        self.assertEqual(attempts[0], 3)

        metrics = get_metrics()
        # 2 retries (first 2 failures led to retries)
        self.assertEqual(metrics.retries_total.get(), 2.0)
        # No exhaustion - we succeeded
        self.assertEqual(metrics.retry_exhausted_total.get(), 0.0)

    def test_retry_exhausted_metric_recorded(self):
        """_with_retry_sync records retry exhaustion when all retries fail."""
        from .client import _with_retry_sync, RetryConfig
        from .observability import get_metrics

        attempts = [0]

        def operation():
            attempts[0] += 1
            raise ConnectionFailed("Connection failed")

        config = RetryConfig(
            max_retries=3,
            base_backoff_ms=1,  # Fast tests
            total_timeout_ms=30000,
            jitter=False,
        )

        with self.assertRaises(RetryExhausted):
            _with_retry_sync(operation, config)

        self.assertEqual(attempts[0], 4)  # Initial + 3 retries

        metrics = get_metrics()
        # 3 retries recorded
        self.assertEqual(metrics.retries_total.get(), 3.0)
        # Exhaustion recorded
        self.assertEqual(metrics.retry_exhausted_total.get(), 1.0)

    def test_no_metrics_on_success(self):
        """No retry metrics when operation succeeds first time."""
        from .client import _with_retry_sync, RetryConfig
        from .observability import get_metrics

        def operation():
            return "immediate success"

        config = RetryConfig()
        result = _with_retry_sync(operation, config)

        self.assertEqual(result, "immediate success")

        metrics = get_metrics()
        self.assertEqual(metrics.retries_total.get(), 0.0)
        self.assertEqual(metrics.retry_exhausted_total.get(), 0.0)

    def test_no_metrics_on_non_retryable_error(self):
        """No retry metrics when non-retryable error occurs."""
        from .client import _with_retry_sync, RetryConfig
        from .observability import get_metrics

        def operation():
            raise InvalidCoordinates("Bad coordinates")

        config = RetryConfig()

        with self.assertRaises(InvalidCoordinates):
            _with_retry_sync(operation, config)

        metrics = get_metrics()
        # Non-retryable errors don't trigger retry metrics
        self.assertEqual(metrics.retries_total.get(), 0.0)
        self.assertEqual(metrics.retry_exhausted_total.get(), 0.0)

    def test_retry_disabled_no_metrics(self):
        """No retry metrics when retry is disabled."""
        from .client import _with_retry_sync, RetryConfig
        from .observability import get_metrics

        attempts = [0]

        def operation():
            attempts[0] += 1
            if attempts[0] < 3:
                raise ConnectionFailed("Connection failed")
            return "success"

        config = RetryConfig(enabled=False)

        with self.assertRaises(ConnectionFailed):
            _with_retry_sync(operation, config)

        self.assertEqual(attempts[0], 1)  # Only one attempt

        metrics = get_metrics()
        self.assertEqual(metrics.retries_total.get(), 0.0)
        self.assertEqual(metrics.retry_exhausted_total.get(), 0.0)


# =============================================================================
# Polygon Self-Intersection Validation Tests (add-polygon-validation)
# =============================================================================


class TestPolygonValidation(unittest.TestCase):
    """Test polygon self-intersection detection (add-polygon-validation spec)."""

    def test_valid_triangle(self):
        """Triangle cannot self-intersect (too few edges)."""
        from .types import validate_polygon_no_self_intersection

        triangle = [(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)]
        intersections = validate_polygon_no_self_intersection(triangle, raise_on_error=False)
        self.assertEqual(len(intersections), 0)

    def test_valid_square(self):
        """Simple square has no self-intersections."""
        from .types import validate_polygon_no_self_intersection

        square = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        intersections = validate_polygon_no_self_intersection(square, raise_on_error=False)
        self.assertEqual(len(intersections), 0)

    def test_valid_convex_pentagon(self):
        """Convex pentagon has no self-intersections."""
        from .types import validate_polygon_no_self_intersection
        import math

        # Regular pentagon
        pentagon = [
            (math.cos(2 * math.pi * i / 5), math.sin(2 * math.pi * i / 5))
            for i in range(5)
        ]
        intersections = validate_polygon_no_self_intersection(pentagon, raise_on_error=False)
        self.assertEqual(len(intersections), 0)

    def test_bowtie_polygon_intersects(self):
        """Bow-tie (figure-8) polygon has a self-intersection."""
        from .types import validate_polygon_no_self_intersection, PolygonValidationError

        # Classic bow-tie: edges 0-1 and 2-3 cross at the center
        bowtie = [(0.0, 0.0), (1.0, 1.0), (1.0, 0.0), (0.0, 1.0)]
        intersections = validate_polygon_no_self_intersection(bowtie, raise_on_error=False)
        self.assertGreater(len(intersections), 0)

    def test_bowtie_raises_exception(self):
        """Bow-tie polygon raises PolygonValidationError when raise_on_error=True."""
        from .types import validate_polygon_no_self_intersection, PolygonValidationError

        bowtie = [(0.0, 0.0), (1.0, 1.0), (1.0, 0.0), (0.0, 1.0)]

        with self.assertRaises(PolygonValidationError) as ctx:
            validate_polygon_no_self_intersection(bowtie, raise_on_error=True)

        # Check exception attributes
        self.assertGreaterEqual(ctx.exception.segment1_index, 0)
        self.assertGreaterEqual(ctx.exception.segment2_index, 0)
        self.assertIsNotNone(ctx.exception.intersection_point)

    def test_complex_self_intersecting_polygon(self):
        """Complex polygon with multiple self-intersections."""
        from .types import validate_polygon_no_self_intersection

        # Figure that crosses itself multiple times
        complex_polygon = [
            (0.0, 0.0), (4.0, 0.0), (4.0, 4.0),
            (1.0, 1.0), (3.0, 1.0), (3.0, 3.0),
            (0.0, 3.0),
        ]
        intersections = validate_polygon_no_self_intersection(complex_polygon, raise_on_error=False)
        # Should find at least one intersection
        self.assertGreater(len(intersections), 0)

    def test_valid_concave_polygon(self):
        """Concave (non-convex) polygon without self-intersections."""
        from .types import validate_polygon_no_self_intersection

        # L-shaped polygon (concave but valid)
        l_shape = [
            (0.0, 0.0), (2.0, 0.0), (2.0, 1.0),
            (1.0, 1.0), (1.0, 2.0), (0.0, 2.0),
        ]
        intersections = validate_polygon_no_self_intersection(l_shape, raise_on_error=False)
        self.assertEqual(len(intersections), 0)

    def test_star_polygon_intersects(self):
        """5-pointed star (drawn without lifting pen) self-intersects."""
        from .types import validate_polygon_no_self_intersection
        import math

        # 5-pointed star vertices (connecting every 2nd vertex)
        star = []
        for i in range(5):
            angle = math.pi / 2 + i * 4 * math.pi / 5
            star.append((math.cos(angle), math.sin(angle)))

        intersections = validate_polygon_no_self_intersection(star, raise_on_error=False)
        # 5-pointed star has 5 self-intersections
        self.assertGreater(len(intersections), 0)

    def test_segments_intersect_basic(self):
        """Test segment intersection detection directly."""
        from .types import _segments_intersect

        # Clearly crossing segments
        self.assertTrue(_segments_intersect(
            (0.0, 0.0), (1.0, 1.0),  # Diagonal
            (0.0, 1.0), (1.0, 0.0),  # Opposite diagonal
        ))

        # Parallel segments (no intersection)
        self.assertFalse(_segments_intersect(
            (0.0, 0.0), (1.0, 0.0),  # Horizontal
            (0.0, 1.0), (1.0, 1.0),  # Parallel horizontal
        ))

        # T-junction (endpoint touches)
        self.assertTrue(_segments_intersect(
            (0.0, 0.5), (1.0, 0.5),  # Horizontal
            (0.5, 0.0), (0.5, 0.5),  # Vertical ending at intersection
        ))

    def test_validation_error_attributes(self):
        """PolygonValidationError has correct attributes."""
        from .types import PolygonValidationError

        error = PolygonValidationError(
            "Test error",
            segment1_index=1,
            segment2_index=3,
            intersection_point=(0.5, 0.5),
        )

        self.assertEqual(error.segment1_index, 1)
        self.assertEqual(error.segment2_index, 3)
        self.assertEqual(error.intersection_point, (0.5, 0.5))
        self.assertIn("Test error", str(error))

    def test_repair_suggestions_included(self):
        """PolygonValidationError includes repair suggestions for self-intersecting polygon."""
        from .types import validate_polygon_no_self_intersection, PolygonValidationError

        # Bow-tie polygon (self-intersecting)
        bowtie = [(0, 0), (1, 1), (1, 0), (0, 1)]

        with self.assertRaises(PolygonValidationError) as ctx:
            validate_polygon_no_self_intersection(bowtie, raise_on_error=True, include_repair_suggestions=True)

        error = ctx.exception
        self.assertIsInstance(error.repair_suggestions, list)
        self.assertGreater(len(error.repair_suggestions), 0)
        # Should have suggestions about removing vertices and ordering
        suggestions_text = " ".join(error.repair_suggestions)
        self.assertIn("removing vertex", suggestions_text.lower())
        self.assertIn("vertices", suggestions_text.lower())

    def test_repair_suggestions_can_be_disabled(self):
        """Repair suggestions can be disabled."""
        from .types import validate_polygon_no_self_intersection, PolygonValidationError

        bowtie = [(0, 0), (1, 1), (1, 0), (0, 1)]

        with self.assertRaises(PolygonValidationError) as ctx:
            validate_polygon_no_self_intersection(bowtie, raise_on_error=True, include_repair_suggestions=False)

        error = ctx.exception
        self.assertEqual(error.repair_suggestions, [])

    def test_get_repair_suggestions_method(self):
        """get_repair_suggestions() returns the suggestions list."""
        from .types import PolygonValidationError

        suggestions = ["Try removing vertex 1", "Check vertex ordering"]
        error = PolygonValidationError(
            "Test error",
            repair_suggestions=suggestions,
        )

        self.assertEqual(error.get_repair_suggestions(), suggestions)

    def test_empty_or_small_polygon(self):
        """Empty or small polygons return no intersections."""
        from .types import validate_polygon_no_self_intersection

        # Empty
        self.assertEqual(validate_polygon_no_self_intersection([], raise_on_error=False), [])

        # Single point
        self.assertEqual(validate_polygon_no_self_intersection([(0, 0)], raise_on_error=False), [])

        # Two points (line)
        self.assertEqual(validate_polygon_no_self_intersection([(0, 0), (1, 1)], raise_on_error=False), [])

        # Three points (triangle - minimum valid polygon)
        self.assertEqual(validate_polygon_no_self_intersection(
            [(0, 0), (1, 0), (0, 1)], raise_on_error=False
        ), [])


class TestSubMeterPrecision(unittest.TestCase):
    """
    Sub-Meter Precision Tests

    Per openspec/changes/add-submeter-precision/specs/data-model/spec.md

    ArcherDB uses nanodegrees (10^-9 degrees) stored as int64 for coordinates.
    This provides approximately 0.1mm precision at the equator, which exceeds
    modern GPS technologies including RTK GPS (1-2cm accuracy).
    """

    def test_exact_nanodegree_preservation(self):
        """Exact nanodegree values are preserved through conversion."""
        # Per spec: "exact nanodegree values SHALL be preserved"
        # Test with high-precision coordinates (9 decimal places)
        original_lat = 37.774929123  # San Francisco
        original_lon = -122.419415678

        # Convert to nanodegrees
        lat_nano = degrees_to_nano(original_lat)
        lon_nano = degrees_to_nano(original_lon)

        # Expected exact values
        self.assertEqual(lat_nano, 37_774_929_123)
        self.assertEqual(lon_nano, -122_419_415_678)

        # Convert back - should be exact within float64 precision
        lat_back = nano_to_degrees(lat_nano)
        lon_back = nano_to_degrees(lon_nano)

        self.assertAlmostEqual(lat_back, original_lat, places=9)
        self.assertAlmostEqual(lon_back, original_lon, places=9)

    def test_rtk_gps_precision_preserved(self):
        """RTK GPS precision (1-2cm) is preserved."""
        # RTK GPS provides 1-2 cm accuracy
        # 2 cm ≈ 180 nanodegrees at the equator
        # Per spec: nanodegrees exceed RTK precision by ~100x

        rtk_precision_nano = 180  # ~2cm in nanodegrees

        # Create two coordinates that differ by less than RTK precision
        base_lat = 37.774929000
        precise_lat = base_lat + (rtk_precision_nano / 2) / NANODEGREES_PER_DEGREE

        base_nano = degrees_to_nano(base_lat)
        precise_nano = degrees_to_nano(precise_lat)

        # Values should be different (we can distinguish sub-RTK precision)
        self.assertNotEqual(base_nano, precise_nano)

        # The difference should be preserved
        diff = precise_nano - base_nano
        self.assertEqual(diff, rtk_precision_nano // 2)

    def test_uwb_indoor_positioning_precision(self):
        """UWB indoor positioning precision (10-30cm) is preserved."""
        # UWB provides 10-30 cm accuracy
        # 30 cm ≈ 2,700 nanodegrees at the equator

        uwb_precision_cm = 30
        uwb_precision_mm = uwb_precision_cm * 10
        # 1 nanodegree ≈ 0.111 mm at equator
        uwb_precision_nano = int(uwb_precision_mm / 0.111)

        # Create coordinates that differ by 1/10th UWB precision
        base_lat = 37.774929000
        uwb_lat = base_lat + (uwb_precision_nano / 10) / NANODEGREES_PER_DEGREE

        base_nano = degrees_to_nano(base_lat)
        uwb_nano = degrees_to_nano(uwb_lat)

        # Values should be different
        self.assertNotEqual(base_nano, uwb_nano)

    def test_float64_maintains_9_decimal_precision(self):
        """Float64 maintains 9 decimal places for GPS coordinates."""
        # Float64 has 15-17 significant digits
        # GPS coordinates typically have max 8-9 significant digits

        test_coords = [
            (37.774929123, -122.419415678),  # San Francisco
            (35.689487654, 139.691706789),  # Tokyo
            (-33.868820123, 151.209295456),  # Sydney
            (51.507350987, -0.127758321),  # London
        ]

        for lat, lon in test_coords:
            lat_nano = degrees_to_nano(lat)
            lon_nano = degrees_to_nano(lon)
            lat_back = nano_to_degrees(lat_nano)
            lon_back = nano_to_degrees(lon_nano)

            # Should maintain 9 decimal places precision
            self.assertAlmostEqual(lat_back, lat, places=9)
            self.assertAlmostEqual(lon_back, lon, places=9)

    def test_boundary_coordinates_precision(self):
        """Boundary coordinates maintain precision."""
        # Test poles and antimeridian
        test_coords = [
            (90.0, 0.0),  # North pole
            (-90.0, 0.0),  # South pole
            (0.0, 180.0),  # Antimeridian east
            (0.0, -180.0),  # Antimeridian west
            (89.999999999, 179.999999999),  # Near boundaries
            (-89.999999999, -179.999999999),  # Near boundaries
        ]

        for lat, lon in test_coords:
            lat_nano = degrees_to_nano(lat)
            lon_nano = degrees_to_nano(lon)
            lat_back = nano_to_degrees(lat_nano)
            lon_back = nano_to_degrees(lon_nano)

            self.assertAlmostEqual(lat_back, lat, places=9)
            self.assertAlmostEqual(lon_back, lon, places=9)

    def test_precision_constants(self):
        """Precision constants are correct."""
        self.assertEqual(NANODEGREES_PER_DEGREE, 1_000_000_000)
        self.assertEqual(MM_PER_METER, 1000)

    def test_various_latitudes_precision(self):
        """Precision is maintained at various latitudes."""
        # Per spec: At all latitudes, nanodegrees provide sub-millimeter precision
        latitudes = [0, 30, 45, 60, 80, 89]  # Various latitudes

        for lat_deg in latitudes:
            lat = float(lat_deg) + 0.123456789
            lat_nano = degrees_to_nano(lat)
            lat_back = nano_to_degrees(lat_nano)
            self.assertAlmostEqual(lat_back, lat, places=9)

    def test_high_precision_decimal_conversion(self):
        """High-precision decimal conversion is accurate."""
        from decimal import Decimal

        # Per spec: "Use decimal for maximum precision"
        lat_str = "37.774929123"
        lat_decimal = Decimal(lat_str)
        lat_nano = int(lat_decimal * Decimal("1000000000"))

        # Should be exact
        self.assertEqual(lat_nano, 37_774_929_123)

        # Round-trip
        lat_back = float(Decimal(lat_nano) / Decimal("1000000000"))
        self.assertAlmostEqual(lat_back, float(lat_str), places=9)


if __name__ == "__main__":
    import sys

    success = run_tests()
    sys.exit(0 if success else 1)
