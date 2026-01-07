"""
TigerBeetle compatibility layer for ArcherDB.

This module provides backward compatibility for code using the 'tigerbeetle'
package name. For new code, use 'archerdb' directly.

Note: ArcherDB is a geospatial database - financial types (Account, Transfer)
are not available. Use GeoEvent and related geospatial types instead.
"""

# Re-export from archerdb (the actual implementation)
from archerdb import (
    # Version
    __version__,
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
    QueryResponse,
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
    id,
    # Configuration
    TLSConfig,
    RetryConfig,
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

# Aliases for compatibility (tigerbeetle -> archerdb naming)
ClientSync = GeoClientSync
ClientAsync = GeoClientAsync

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
    "QueryResponse",
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
    # Errors
    "ArcherDBError",
    "ConnectionFailed",
    "ConnectionTimeout",
    "TLSError",
    "ClusterUnavailable",
    "ViewChangeInProgress",
    "NotPrimary",
    "InvalidCoordinates",
    "PolygonTooComplex",
    "BatchTooLarge",
    "InvalidEntityId",
    "OperationTimeout",
    "QueryResultTooLarge",
    "OutOfSpace",
    "SessionExpired",
    "ClientClosedError",
    "RetryExhausted",
    # Batch classes
    "GeoEventBatch",
    "GeoEventBatchAsync",
    "DeleteEntityBatch",
    "DeleteEntityBatchAsync",
    # Client classes
    "GeoClientSync",
    "GeoClientAsync",
    # Aliases
    "ClientSync",
    "ClientAsync",
    # Batch helpers
    "split_batch",
]
