"""
ArcherDB Python SDK

High-performance geospatial database client for fleet tracking,
logistics, and real-time location applications.

Example:
    import archerdb

    # Create client
    client = archerdb.GeoClientSync(
        cluster_id=archerdb.id(),
        addresses=["127.0.0.1:3001"]
    )

    # Insert events
    batch = client.create_batch()
    batch.insert(archerdb.create_geo_event(
        entity_id=archerdb.id(),
        latitude=37.7749,
        longitude=-122.4194,
    ))
    results = batch.submit()

    # Query by radius
    result = client.query_radius(37.7749, -122.4194, 1000)
    for event in result.events:
        print(f"Entity {event.entity_id} at {event.lat_nano}, {event.lon_nano}")
"""

from __future__ import annotations

# Version
__version__ = "0.1.0"

# Types and enums
from .types import (
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
)

# Client classes and utilities
from .client import (
    # ID generation
    id,
    # Configuration
    TLSConfig,
    RetryConfig,
    GeoClientConfig,
    # Errors - Base
    ArcherDBError,
    # Errors - Connection
    ConnectionFailed,
    ConnectionTimeout,
    TLSError,
    # Errors - Cluster
    ClusterUnavailable,
    ViewChangeInProgress,
    NotPrimary,
    # Errors - Validation
    InvalidCoordinates,
    PolygonTooComplex,
    BatchTooLarge,
    InvalidEntityId,
    # Errors - Operation
    OperationTimeout,
    QueryResultTooLarge,
    OutOfSpace,
    SessionExpired,
    ClientClosedError,
    # Errors - Retry
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

# Public API
__all__ = [
    # Version
    "__version__",
    # Constants
    "LAT_MAX",
    "LON_MAX",
    "NANODEGREES_PER_DEGREE",
    "MM_PER_METER",
    "CENTIDEGREES_PER_DEGREE",
    "BATCH_SIZE_MAX",
    "QUERY_LIMIT_MAX",
    "POLYGON_VERTICES_MAX",
    # Enums
    "GeoEventFlags",
    "GeoOperation",
    "InsertGeoEventResult",
    "DeleteEntityResult",
    # Data classes
    "GeoEvent",
    "InsertGeoEventsError",
    "DeleteEntitiesError",
    "QueryUuidFilter",
    "QueryRadiusFilter",
    "PolygonVertex",
    "QueryPolygonFilter",
    "QueryLatestFilter",
    "QueryResult",
    "DeleteResult",
    # Conversion helpers
    "degrees_to_nano",
    "nano_to_degrees",
    "meters_to_mm",
    "mm_to_meters",
    "heading_to_centidegrees",
    "centidegrees_to_heading",
    "is_valid_latitude",
    "is_valid_longitude",
    # Builder functions
    "create_geo_event",
    "create_radius_query",
    "create_polygon_query",
    # ID generation
    "id",
    # Configuration
    "TLSConfig",
    "RetryConfig",
    "GeoClientConfig",
    # Errors - Base
    "ArcherDBError",
    # Errors - Connection
    "ConnectionFailed",
    "ConnectionTimeout",
    "TLSError",
    # Errors - Cluster
    "ClusterUnavailable",
    "ViewChangeInProgress",
    "NotPrimary",
    # Errors - Validation
    "InvalidCoordinates",
    "PolygonTooComplex",
    "BatchTooLarge",
    "InvalidEntityId",
    # Errors - Operation
    "OperationTimeout",
    "QueryResultTooLarge",
    "OutOfSpace",
    "SessionExpired",
    "ClientClosedError",
    # Errors - Retry
    "RetryExhausted",
    # Batch classes
    "GeoEventBatch",
    "GeoEventBatchAsync",
    "DeleteEntityBatch",
    "DeleteEntityBatchAsync",
    # Client classes
    "GeoClientSync",
    "GeoClientAsync",
    # Batch helpers
    "split_batch",
]
