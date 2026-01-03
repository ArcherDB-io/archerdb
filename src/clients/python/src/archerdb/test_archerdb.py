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
    TLSConfig,
    GeoClientConfig,
    # Errors
    ArcherDBError,
    ConnectionFailed,
    ConnectionTimeout,
    TLSError,
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
    # Batch classes
    GeoEventBatch,
    GeoEventBatchAsync,
    DeleteEntityBatch,
    DeleteEntityBatchAsync,
    # Client classes
    GeoClientSync,
    GeoClientAsync,
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
        filt = QueryUuidFilter(entity_id=12345, limit=10)
        self.assertEqual(filt.entity_id, 12345)
        self.assertEqual(filt.limit, 10)

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

    def test_tls_error_not_retryable(self):
        """TLS error is not retryable."""
        err = TLSError("certificate error")
        self.assertIsInstance(err, ArcherDBError)
        self.assertFalse(err.retryable)
        self.assertEqual(err.code, 1003)

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

    def test_tls_config(self):
        """TLSConfig can be created."""
        config = TLSConfig(
            ca_path="/path/to/ca.crt",
            cert_path="/path/to/client.crt",
            key_path="/path/to/client.key",
        )
        self.assertEqual(config.ca_path, "/path/to/ca.crt")
        self.assertEqual(config.cert_path, "/path/to/client.crt")
        self.assertEqual(config.key_path, "/path/to/client.key")

    def test_geo_client_config_defaults(self):
        """GeoClientConfig has sensible defaults."""
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001"],
        )
        self.assertEqual(config.connect_timeout_ms, 5000)
        self.assertEqual(config.request_timeout_ms, 30000)
        self.assertEqual(config.pool_size, 1)
        self.assertIsNone(config.tls)

    def test_geo_client_config_custom(self):
        """GeoClientConfig accepts custom values."""
        tls = TLSConfig(ca_path="/path/to/ca.crt")
        config = GeoClientConfig(
            cluster_id=archerdb_id(),
            addresses=["127.0.0.1:3001", "127.0.0.1:3002"],
            tls=tls,
            connect_timeout_ms=10000,
            request_timeout_ms=60000,
            pool_size=4,
        )
        self.assertEqual(len(config.addresses), 2)
        self.assertEqual(config.connect_timeout_ms, 10000)
        self.assertEqual(config.request_timeout_ms, 60000)
        self.assertEqual(config.pool_size, 4)
        self.assertIsNotNone(config.tls)


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


if __name__ == "__main__":
    import sys

    success = run_tests()
    sys.exit(0 if success else 1)
