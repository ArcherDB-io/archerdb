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
    POLYGON_HOLES_MAX,
    POLYGON_HOLE_VERTICES_MIN,
    MAX_SHARDS,
    MAX_REPLICAS_PER_SHARD,
    # Enums
    GeoEventFlags,
    GeoOperation,
    InsertGeoEventResult,
    DeleteEntityResult,
    ShardStatus,
    TopologyChangeType,
    # Data classes
    GeoEvent,
    InsertGeoEventsError,
    DeleteEntitiesError,
    QueryUuidFilter,
    QueryRadiusFilter,
    PolygonVertex,
    PolygonHole,
    QueryPolygonFilter,
    QueryLatestFilter,
    QueryResponse,
    QueryResult,
    DeleteResult,
    StatusResponse,
    ShardInfo,
    TopologyResponse,
    TopologyChangeNotification,
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

# Topology support (F5.1 Smart Client Topology Discovery)
from .topology import (
    TopologyCache,
    ShardRouter,
    ShardRoutingError,
    NotShardLeaderError,
    ScatterGatherExecutor,
    ScatterGatherResult,
    ScatterGatherConfig,
    default_scatter_gather_config,
)

# Client classes and utilities
from .client import (
    # ID generation
    id,
    # Configuration
    RetryConfig,
    OperationOptions,
    GeoClientConfig,
    # Errors - Base
    ArcherDBError,
    # Errors - Connection
    ConnectionFailed,
    ConnectionTimeout,
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

# Observability (per client-sdk/spec.md)
from .observability import (
    # Logging
    LogLevel,
    SDKLogger,
    StandardLogger,
    NullLogger,
    configure_logging,
    get_logger,
    # Metrics
    MetricLabels,
    SDKMetrics,
    Counter,
    Gauge,
    Histogram,
    get_metrics,
    reset_metrics,
    # Health check
    ConnectionState,
    HealthStatus,
    HealthTracker,
    # Timing
    RequestTimer,
)

# v2 Error codes (multi-region, sharding, encryption)
from .errors import (
    # Multi-region errors (213-218)
    MultiRegionError,
    MULTI_REGION_ERROR_MESSAGES,
    MULTI_REGION_ERROR_RETRYABLE,
    is_multi_region_error,
    multi_region_error_message,
    # Sharding errors (220-224)
    ShardingError,
    SHARDING_ERROR_MESSAGES,
    SHARDING_ERROR_RETRYABLE,
    is_sharding_error,
    sharding_error_message,
    # Encryption errors (410-414)
    EncryptionError,
    ENCRYPTION_ERROR_MESSAGES,
    ENCRYPTION_ERROR_RETRYABLE,
    is_encryption_error,
    encryption_error_message,
    # Exception classes
    MultiRegionException,
    ShardingException,
    EncryptionException,
    # Utilities
    is_retryable,
    error_message,
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
    "POLYGON_HOLES_MAX",
    "POLYGON_HOLE_VERTICES_MIN",
    "MAX_SHARDS",
    "MAX_REPLICAS_PER_SHARD",
    # Enums
    "GeoEventFlags",
    "GeoOperation",
    "InsertGeoEventResult",
    "DeleteEntityResult",
    "ShardStatus",
    "TopologyChangeType",
    # Data classes
    "GeoEvent",
    "InsertGeoEventsError",
    "DeleteEntitiesError",
    "QueryUuidFilter",
    "QueryRadiusFilter",
    "PolygonVertex",
    "PolygonHole",
    "QueryPolygonFilter",
    "QueryLatestFilter",
    "QueryResponse",
    "QueryResult",
    "DeleteResult",
    "ShardInfo",
    "TopologyResponse",
    "TopologyChangeNotification",
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
    "RetryConfig",
    "OperationOptions",
    "GeoClientConfig",
    # Errors - Base
    "ArcherDBError",
    # Errors - Connection
    "ConnectionFailed",
    "ConnectionTimeout",
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
    # Errors - Topology
    "ShardRoutingError",
    "NotShardLeaderError",
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
    # Topology support (F5.1)
    "TopologyCache",
    "ShardRouter",
    "ScatterGatherExecutor",
    "ScatterGatherResult",
    "ScatterGatherConfig",
    "default_scatter_gather_config",
    # Observability - Logging
    "LogLevel",
    "SDKLogger",
    "StandardLogger",
    "NullLogger",
    "configure_logging",
    "get_logger",
    # Observability - Metrics
    "MetricLabels",
    "SDKMetrics",
    "Counter",
    "Gauge",
    "Histogram",
    "get_metrics",
    "reset_metrics",
    # Observability - Health check
    "ConnectionState",
    "HealthStatus",
    "HealthTracker",
    # Observability - Timing
    "RequestTimer",
    # v2 Error codes - Multi-region (213-218)
    "MultiRegionError",
    "MULTI_REGION_ERROR_MESSAGES",
    "MULTI_REGION_ERROR_RETRYABLE",
    "is_multi_region_error",
    "multi_region_error_message",
    # v2 Error codes - Sharding (220-224)
    "ShardingError",
    "SHARDING_ERROR_MESSAGES",
    "SHARDING_ERROR_RETRYABLE",
    "is_sharding_error",
    "sharding_error_message",
    # v2 Error codes - Encryption (410-414)
    "EncryptionError",
    "ENCRYPTION_ERROR_MESSAGES",
    "ENCRYPTION_ERROR_RETRYABLE",
    "is_encryption_error",
    "encryption_error_message",
    # v2 Exception classes
    "MultiRegionException",
    "ShardingException",
    "EncryptionException",
    # v2 Utilities
    "is_retryable",
    "error_message",
]
