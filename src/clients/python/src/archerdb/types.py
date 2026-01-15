"""
ArcherDB Python SDK - Type Definitions

This module provides type definitions for GeoEvent operations,
matching the server's geo_event.zig and geo_state_machine.zig structures.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum, IntFlag
from typing import List, Optional


# ============================================================================
# Constants
# ============================================================================

# Coordinate bounds
LAT_MAX: float = 90.0
LON_MAX: float = 180.0

# Conversion factors
NANODEGREES_PER_DEGREE: int = 1_000_000_000
MM_PER_METER: int = 1000
CENTIDEGREES_PER_DEGREE: int = 100

# Limits per spec (assumes production config with 10MB message_size_max)
# NOTE: These limits are configuration-dependent and computed dynamically by the server.
# The server returns actual limits during client registration (batch_size_limit).
# With the default 1MB message_size_max, effective limits are ~8,180 events.
# For production deployments, configure message_size_max = 10MB in server config.
BATCH_SIZE_MAX: int = 10_000
QUERY_LIMIT_MAX: int = 81_000
POLYGON_VERTICES_MAX: int = 10_000

# Polygon hole limits (per spec)
POLYGON_HOLES_MAX: int = 100
POLYGON_HOLE_VERTICES_MIN: int = 3

# Safe limits for default 1MB message configuration
# Use these if connecting to a server with default configuration
BATCH_SIZE_MAX_DEFAULT: int = 8_000
QUERY_LIMIT_MAX_DEFAULT: int = 8_000


# ============================================================================
# Enums
# ============================================================================

class GeoEventFlags(IntFlag):
    """
    GeoEvent status flags.
    Maps to GeoEventFlags in geo_event.zig
    """
    NONE = 0
    LINKED = 1 << 0        # Event is part of a linked chain
    IMPORTED = 1 << 1      # Event was imported with client-provided timestamp
    STATIONARY = 1 << 2    # Entity is not moving
    LOW_ACCURACY = 1 << 3  # GPS accuracy below threshold
    OFFLINE = 1 << 4       # Entity is offline/unreachable
    DELETED = 1 << 5       # Entity has been deleted (GDPR compliance)


class GeoOperation(IntEnum):
    """
    ArcherDB geospatial operation codes.
    Maps to Operation enum in archerdb.zig
    """
    INSERT_EVENTS = 146    # vsr_operations_reserved (128) + 18
    UPSERT_EVENTS = 147    # vsr_operations_reserved (128) + 19
    DELETE_ENTITIES = 148  # vsr_operations_reserved (128) + 20
    QUERY_UUID = 149       # vsr_operations_reserved (128) + 21
    QUERY_RADIUS = 150     # vsr_operations_reserved (128) + 22
    QUERY_POLYGON = 151    # vsr_operations_reserved (128) + 23
    ARCHERDB_PING = 152    # vsr_operations_reserved (128) + 24
    ARCHERDB_GET_STATUS = 153  # vsr_operations_reserved (128) + 25
    QUERY_LATEST = 154     # vsr_operations_reserved (128) + 26
    CLEANUP_EXPIRED = 155  # vsr_operations_reserved (128) + 27
    QUERY_UUID_BATCH = 156 # vsr_operations_reserved (128) + 28
    GET_TOPOLOGY = 157     # vsr_operations_reserved (128) + 29
    # Manual TTL Operations (v2.1)
    TTL_SET = 158          # vsr_operations_reserved (128) + 30
    TTL_EXTEND = 159       # vsr_operations_reserved (128) + 31
    TTL_CLEAR = 160        # vsr_operations_reserved (128) + 32


class TtlOperationResult(IntEnum):
    """
    Result codes for TTL operations (v2.1).
    Maps to TtlOperationResult in ttl.zig
    """
    SUCCESS = 0
    ENTITY_NOT_FOUND = 1
    INVALID_TTL = 2
    NOT_PERMITTED = 3
    ENTITY_IMMUTABLE = 4


class InsertGeoEventResult(IntEnum):
    """
    Result codes for GeoEvent insert operations.
    Maps to InsertGeoEventResult in geo_state_machine.zig
    """
    OK = 0
    LINKED_EVENT_FAILED = 1
    LINKED_EVENT_CHAIN_OPEN = 2
    TIMESTAMP_MUST_BE_ZERO = 3
    RESERVED_FIELD = 4
    RESERVED_FLAG = 5
    ID_MUST_NOT_BE_ZERO = 6
    ENTITY_ID_MUST_NOT_BE_ZERO = 7
    INVALID_COORDINATES = 8
    LAT_OUT_OF_RANGE = 9
    LON_OUT_OF_RANGE = 10
    EXISTS_WITH_DIFFERENT_ENTITY_ID = 11
    EXISTS_WITH_DIFFERENT_COORDINATES = 12
    EXISTS = 13
    HEADING_OUT_OF_RANGE = 14
    TTL_INVALID = 15


class DeleteEntityResult(IntEnum):
    """
    Result codes for entity delete operations.
    Maps to DeleteEntityResult in geo_state_machine.zig
    """
    OK = 0
    LINKED_EVENT_FAILED = 1
    ENTITY_ID_MUST_NOT_BE_ZERO = 2
    ENTITY_NOT_FOUND = 3


# ============================================================================
# Data Classes
# ============================================================================

@dataclass
class GeoEvent:
    """
    128-byte geospatial event record.

    Represents a single location update for a moving entity.
    Coordinates are stored in nanodegrees (10^-9 degrees).

    Example:
        event = GeoEvent(
            entity_id=archerdb.id(),
            lat_nano=int(37.7749 * 1e9),
            lon_nano=int(-122.4194 * 1e9),
            group_id=fleet_id,
        )
    """
    # Primary key fields
    id: int = 0  # Composite key [S2 Cell ID | Timestamp], 0 = server-assigned
    entity_id: int = 0  # UUID identifying the moving entity
    correlation_id: int = 0  # UUID for trip/session correlation
    user_data: int = 0  # Opaque application metadata

    # Coordinates in nanodegrees
    lat_nano: int = 0  # -90e9 to +90e9
    lon_nano: int = 0  # -180e9 to +180e9

    # Grouping and timing
    group_id: int = 0  # Fleet/region grouping
    timestamp: int = 0  # Nanoseconds since epoch, 0 = server-assigned

    # Physical measurements
    altitude_mm: int = 0  # Millimeters above WGS84
    velocity_mms: int = 0  # Millimeters per second
    ttl_seconds: int = 0  # Time-to-live (0 = never expires)
    accuracy_mm: int = 0  # GPS accuracy radius in mm
    heading_cdeg: int = 0  # Centidegrees (0-36000)

    # Status
    flags: GeoEventFlags = GeoEventFlags.NONE


@dataclass
class InsertGeoEventsError:
    """Per-event result for batch insert operations."""
    index: int
    result: InsertGeoEventResult


@dataclass
class DeleteEntitiesError:
    """Per-entity result for batch delete operations."""
    index: int
    result: DeleteEntityResult


@dataclass
class QueryUuidFilter:
    """Filter for UUID lookup queries."""
    entity_id: int
    limit: int = 1


@dataclass
class QueryUuidBatchFilter:
    """Filter for batch UUID lookup queries (F1.3.4)."""
    count: int
    entity_ids: List[int]


@dataclass
class QueryUuidBatchResult:
    """Result of batch UUID lookup (F1.3.4)."""
    found_count: int
    not_found_count: int
    not_found_indices: List[int]  # Indices of entity_ids that were not found
    events: List['GeoEvent']  # Found events in request order


@dataclass
class QueryRadiusFilter:
    """Filter for radius queries."""
    center_lat_nano: int
    center_lon_nano: int
    radius_mm: int
    limit: int = 1000
    timestamp_min: int = 0
    timestamp_max: int = 0
    group_id: int = 0
    flags: int = 0  # Reserved for future use


@dataclass
class PolygonVertex:
    """Polygon vertex (lat/lon pair)."""
    lat_nano: int
    lon_nano: int


@dataclass
class PolygonHole:
    """
    Polygon hole (exclusion zone within the outer boundary).

    A hole is defined by a list of vertices in clockwise winding order.
    Points inside a hole are excluded from query results.
    """
    vertices: List[PolygonVertex] = field(default_factory=list)


@dataclass
class QueryPolygonFilter:
    """
    Filter for polygon queries.

    A polygon can optionally have holes (exclusion zones). The outer boundary
    should be in counter-clockwise (CCW) winding order, while holes should
    be in clockwise (CW) winding order.
    """
    vertices: List[PolygonVertex] = field(default_factory=list)
    holes: List[PolygonHole] = field(default_factory=list)
    limit: int = 1000
    timestamp_min: int = 0
    timestamp_max: int = 0
    group_id: int = 0


@dataclass
class QueryLatestFilter:
    """Filter for query_latest operation."""
    limit: int = 1000
    group_id: int = 0
    cursor_timestamp: int = 0


@dataclass
class QueryResponse:
    """
    Wire format header for query responses (8 bytes).
    Matches QueryResponse struct in geo_state_machine.zig.

    The server sends this header followed by an array of GeoEvent records.
    Use from_bytes() to parse the header from response data.
    """
    count: int = 0           # Number of events in response (u32)
    has_more: bool = False   # More results available beyond limit (u8 flag)
    partial_result: bool = False  # Result set was truncated (u8 flag)
    # 2 bytes reserved/padding

    # Flag bit positions in the flags byte
    FLAG_HAS_MORE: int = 0x01
    FLAG_PARTIAL_RESULT: int = 0x02

    @classmethod
    def from_bytes(cls, data: bytes) -> "QueryResponse":
        """
        Parse QueryResponse header from raw bytes.

        Args:
            data: At least 8 bytes of response data

        Returns:
            Parsed QueryResponse header

        Raises:
            ValueError: If data is less than 8 bytes
        """
        if len(data) < 8:
            raise ValueError(f"QueryResponse requires 8 bytes, got {len(data)}")

        import struct
        # Format: u32 count (little-endian) + u8 flags + u8 reserved + u16 reserved
        count, flags, _, _ = struct.unpack("<IBBH", data[:8])

        return cls(
            count=count,
            has_more=bool(flags & cls.FLAG_HAS_MORE),
            partial_result=bool(flags & cls.FLAG_PARTIAL_RESULT),
        )

    @staticmethod
    def header_size() -> int:
        """Return the size of the QueryResponse header in bytes."""
        return 8


@dataclass
class QueryResult:
    """Query result with pagination support."""
    events: List[GeoEvent] = field(default_factory=list)
    has_more: bool = False
    cursor: Optional[int] = None


@dataclass
class DeleteResult:
    """Result structure for delete operations."""
    deleted_count: int = 0
    not_found_count: int = 0


@dataclass
class StatusResponse:
    """
    Server status response from archerdb_get_status operation.
    Matches StatusResponse in geo_state_machine.zig (64 bytes).
    """
    ram_index_count: int = 0       # Number of entities in RAM index
    ram_index_capacity: int = 0    # Total RAM index capacity
    ram_index_load_pct: int = 0    # Load factor as percentage * 100 (e.g., 7000 = 70%)
    tombstone_count: int = 0       # Number of tombstone entries
    ttl_expirations: int = 0       # Total TTL expirations processed
    deletion_count: int = 0        # Total deletions processed

    @property
    def load_factor(self) -> float:
        """Return the load factor as a decimal (e.g., 0.70)."""
        return self.ram_index_load_pct / 10000.0


@dataclass
class CleanupResult:
    """
    Result of a cleanup_expired operation.

    Per client-protocol/spec.md cleanup_expired (0x30) response format:
    - entries_scanned: u64 - Number of index entries examined
    - entries_removed: u64 - Number of expired entries cleaned up
    """
    entries_scanned: int = 0
    entries_removed: int = 0

    @property
    def has_removals(self) -> bool:
        """Return True if any entries were removed."""
        return self.entries_removed > 0

    @property
    def expiration_ratio(self) -> float:
        """
        Return the percentage of scanned entries that were expired.

        Returns:
            Expiration ratio (0.0 to 1.0)
        """
        if self.entries_scanned == 0:
            return 0.0
        return self.entries_removed / self.entries_scanned


# ============================================================================
# TTL Operations (v2.1 Manual TTL Support)
# ============================================================================

@dataclass
class TtlSetRequest:
    """
    Request to set absolute TTL for an entity (64 bytes).
    CLI: `archerdb ttl set <entity_id> --ttl=<seconds>`
    """
    entity_id: int = 0
    ttl_seconds: int = 0  # 0 = infinite (use ttl_clear for explicit clear)
    flags: int = 0

    def to_bytes(self) -> bytes:
        """Serialize to wire format (64 bytes)."""
        import struct
        # u128 entity_id + u32 ttl_seconds + u32 flags + 40 bytes reserved
        entity_bytes = self.entity_id.to_bytes(16, "little")
        return entity_bytes + struct.pack("<II", self.ttl_seconds, self.flags) + b"\x00" * 40


@dataclass
class TtlSetResponse:
    """
    Response from TTL set operation (64 bytes).
    """
    entity_id: int = 0
    previous_ttl_seconds: int = 0
    new_ttl_seconds: int = 0
    result: TtlOperationResult = TtlOperationResult.SUCCESS

    @classmethod
    def from_bytes(cls, data: bytes) -> "TtlSetResponse":
        """Parse response from wire format."""
        if len(data) < 64:
            raise ValueError(f"TtlSetResponse requires 64 bytes, got {len(data)}")
        import struct
        entity_id = int.from_bytes(data[:16], "little")
        prev_ttl, new_ttl, result_code = struct.unpack("<IIB", data[16:25])
        return cls(
            entity_id=entity_id,
            previous_ttl_seconds=prev_ttl,
            new_ttl_seconds=new_ttl,
            result=TtlOperationResult(result_code),
        )


@dataclass
class TtlExtendRequest:
    """
    Request to extend TTL by an amount (64 bytes).
    CLI: `archerdb ttl extend <entity_id> --by=<seconds>`
    """
    entity_id: int = 0
    extend_by_seconds: int = 0
    flags: int = 0

    def to_bytes(self) -> bytes:
        """Serialize to wire format (64 bytes)."""
        import struct
        entity_bytes = self.entity_id.to_bytes(16, "little")
        return entity_bytes + struct.pack("<II", self.extend_by_seconds, self.flags) + b"\x00" * 40


@dataclass
class TtlExtendResponse:
    """
    Response from TTL extend operation (64 bytes).
    """
    entity_id: int = 0
    previous_ttl_seconds: int = 0
    new_ttl_seconds: int = 0
    result: TtlOperationResult = TtlOperationResult.SUCCESS

    @classmethod
    def from_bytes(cls, data: bytes) -> "TtlExtendResponse":
        """Parse response from wire format."""
        if len(data) < 64:
            raise ValueError(f"TtlExtendResponse requires 64 bytes, got {len(data)}")
        import struct
        entity_id = int.from_bytes(data[:16], "little")
        prev_ttl, new_ttl, result_code = struct.unpack("<IIB", data[16:25])
        return cls(
            entity_id=entity_id,
            previous_ttl_seconds=prev_ttl,
            new_ttl_seconds=new_ttl,
            result=TtlOperationResult(result_code),
        )


@dataclass
class TtlClearRequest:
    """
    Request to clear TTL (entity never expires) (64 bytes).
    CLI: `archerdb ttl clear <entity_id>`
    """
    entity_id: int = 0
    flags: int = 0

    def to_bytes(self) -> bytes:
        """Serialize to wire format (64 bytes)."""
        import struct
        entity_bytes = self.entity_id.to_bytes(16, "little")
        return entity_bytes + struct.pack("<I", self.flags) + b"\x00" * 44


@dataclass
class TtlClearResponse:
    """
    Response from TTL clear operation (64 bytes).
    """
    entity_id: int = 0
    previous_ttl_seconds: int = 0
    result: TtlOperationResult = TtlOperationResult.SUCCESS

    @classmethod
    def from_bytes(cls, data: bytes) -> "TtlClearResponse":
        """Parse response from wire format."""
        if len(data) < 64:
            raise ValueError(f"TtlClearResponse requires 64 bytes, got {len(data)}")
        import struct
        entity_id = int.from_bytes(data[:16], "little")
        prev_ttl, result_code = struct.unpack("<IB", data[16:21])
        return cls(
            entity_id=entity_id,
            previous_ttl_seconds=prev_ttl,
            result=TtlOperationResult(result_code),
        )


# ============================================================================
# Topology Types (F5.1 Smart Client Topology Discovery)
# ============================================================================

# Maximum shards supported
MAX_SHARDS = 256
MAX_REPLICAS_PER_SHARD = 6


class ShardStatus(IntEnum):
    """
    Shard status indicator.
    Maps to ShardStatus in topology.zig
    """
    ACTIVE = 0              # Shard is active and accepting requests
    SYNCING = 1             # Shard is syncing data (read-only)
    UNAVAILABLE = 2         # Shard is unavailable
    MIGRATING = 3           # Shard is being migrated during resharding
    DECOMMISSIONING = 4     # Shard is being decommissioned


class TopologyChangeType(IntEnum):
    """
    Type of topology change notification.
    Maps to TopologyChangeNotification.ChangeType in topology.zig
    """
    LEADER_CHANGE = 0       # Shard leader changed (failover)
    REPLICA_ADDED = 1       # Replica added to a shard
    REPLICA_REMOVED = 2     # Replica removed from a shard
    RESHARDING_STARTED = 3  # Resharding operation started
    RESHARDING_COMPLETED = 4  # Resharding operation completed
    STATUS_CHANGE = 5       # Shard status changed


@dataclass
class ShardInfo:
    """
    Information about a single shard.
    Matches ShardInfo in topology.zig (192 bytes).
    """
    id: int = 0                     # Shard identifier (0 to num_shards-1)
    primary: str = ""               # Primary/leader node address
    replicas: List[str] = field(default_factory=list)  # Replica node addresses
    status: ShardStatus = ShardStatus.ACTIVE
    entity_count: int = 0           # Approximate number of entities
    size_bytes: int = 0             # Approximate size in bytes

    @classmethod
    def from_bytes(cls, data: bytes) -> "ShardInfo":
        """Parse ShardInfo from raw bytes (192 bytes)."""
        import struct
        if len(data) < 192:
            raise ValueError(f"ShardInfo requires 192 bytes, got {len(data)}")

        # Format: u32 id, u8 status, 3 bytes padding, u64 entity_count, u64 size_bytes
        # Then addresses (null-terminated strings in fixed-size buffers)
        shard_id, status, _, entity_count, size_bytes = struct.unpack("<IBHQQ", data[:24])

        # Primary address: 64 bytes starting at offset 24
        primary_raw = data[24:88]
        primary = primary_raw.split(b'\x00')[0].decode('utf-8')

        # Replicas: 6 * 64 bytes starting at offset 88
        replicas = []
        for i in range(MAX_REPLICAS_PER_SHARD):
            start = 88 + i * 64
            end = start + 64
            if end <= len(data):
                replica_raw = data[start:end]
                replica = replica_raw.split(b'\x00')[0].decode('utf-8')
                if replica:
                    replicas.append(replica)

        return cls(
            id=shard_id,
            primary=primary,
            replicas=replicas,
            status=ShardStatus(status),
            entity_count=entity_count,
            size_bytes=size_bytes,
        )


@dataclass
class TopologyResponse:
    """
    Cluster topology information.
    Matches TopologyResponse in topology.zig.
    """
    version: int = 0                # Topology version (increments on changes)
    cluster_id: int = 0             # Cluster identifier (128-bit as int)
    num_shards: int = 0             # Number of shards in the cluster
    resharding_status: int = 0      # 0=idle, 1=preparing, 2=migrating, 3=finalizing
    shards: List[ShardInfo] = field(default_factory=list)
    last_change_ns: int = 0         # Timestamp of last topology change (ns since epoch)

    @classmethod
    def from_bytes(cls, data: bytes) -> "TopologyResponse":
        """Parse TopologyResponse from raw bytes."""
        import struct
        if len(data) < 48:  # Minimum header size
            raise ValueError(f"TopologyResponse requires at least 48 bytes, got {len(data)}")

        # Header format: u64 version, u128 cluster_id (as 2x u64), u32 num_shards,
        # u8 resharding_status, 3 bytes padding, i64 last_change_ns
        version = struct.unpack("<Q", data[0:8])[0]
        cluster_id_lo = struct.unpack("<Q", data[8:16])[0]
        cluster_id_hi = struct.unpack("<Q", data[16:24])[0]
        cluster_id = cluster_id_lo | (cluster_id_hi << 64)
        num_shards, resharding_status = struct.unpack("<IB", data[24:29])
        last_change_ns = struct.unpack("<q", data[32:40])[0]

        # Parse shards (192 bytes each)
        shards = []
        shard_data_start = 48  # After header
        for i in range(num_shards):
            start = shard_data_start + i * 192
            end = start + 192
            if end <= len(data):
                shard = ShardInfo.from_bytes(data[start:end])
                shards.append(shard)

        return cls(
            version=version,
            cluster_id=cluster_id,
            num_shards=num_shards,
            resharding_status=resharding_status,
            shards=shards,
            last_change_ns=last_change_ns,
        )


@dataclass
class TopologyChangeNotification:
    """
    Notification of a topology change event.
    """
    new_version: int = 0            # New topology version
    old_version: int = 0            # Previous topology version
    change_type: TopologyChangeType = TopologyChangeType.STATUS_CHANGE
    affected_shard: int = 0         # Shard affected by the change
    timestamp_ns: int = 0           # Timestamp of the change (ns since epoch)


# ============================================================================
# Coordinate Conversion Helpers
# ============================================================================

def degrees_to_nano(degrees: float) -> int:
    """
    Convert degrees to nanodegrees.

    Args:
        degrees: Coordinate in degrees

    Returns:
        Coordinate in nanodegrees

    Example:
        lat = degrees_to_nano(37.7749)  # Returns 37774900000
    """
    return round(degrees * NANODEGREES_PER_DEGREE)


def nano_to_degrees(nano: int) -> float:
    """
    Convert nanodegrees to degrees.

    Args:
        nano: Coordinate in nanodegrees

    Returns:
        Coordinate in degrees
    """
    return nano / NANODEGREES_PER_DEGREE


def meters_to_mm(meters: float) -> int:
    """Convert meters to millimeters."""
    return round(meters * MM_PER_METER)


def mm_to_meters(mm: int) -> float:
    """Convert millimeters to meters."""
    return mm / MM_PER_METER


def heading_to_centidegrees(degrees: float) -> int:
    """Convert heading from degrees (0-360) to centidegrees (0-36000)."""
    return round(degrees * CENTIDEGREES_PER_DEGREE)


def centidegrees_to_heading(cdeg: int) -> float:
    """Convert heading from centidegrees to degrees."""
    return cdeg / CENTIDEGREES_PER_DEGREE


def is_valid_latitude(lat: float) -> bool:
    """Check if latitude is in valid range (-90 to +90)."""
    return -LAT_MAX <= lat <= LAT_MAX


def is_valid_longitude(lon: float) -> bool:
    """Check if longitude is in valid range (-180 to +180)."""
    return -LON_MAX <= lon <= LON_MAX


# ============================================================================
# Builder Functions
# ============================================================================

def create_geo_event(
    entity_id: int,
    latitude: float,
    longitude: float,
    *,
    correlation_id: int = 0,
    user_data: int = 0,
    group_id: int = 0,
    altitude_m: float = 0.0,
    velocity_mps: float = 0.0,
    ttl_seconds: int = 0,
    accuracy_m: float = 0.0,
    heading: float = 0.0,
    flags: GeoEventFlags = GeoEventFlags.NONE,
) -> GeoEvent:
    """
    Create a GeoEvent from user-friendly units.

    Handles unit conversions automatically:
    - Degrees to nanodegrees
    - Meters to millimeters
    - Heading degrees to centidegrees

    Args:
        entity_id: UUID identifying the entity
        latitude: Latitude in degrees (-90 to +90)
        longitude: Longitude in degrees (-180 to +180)
        correlation_id: Optional trip/session correlation ID
        user_data: Optional application metadata
        group_id: Optional fleet/region grouping
        altitude_m: Altitude in meters (optional)
        velocity_mps: Speed in meters per second (optional)
        ttl_seconds: Time-to-live in seconds (optional)
        accuracy_m: GPS accuracy in meters (optional)
        heading: Heading in degrees 0-360 (optional)
        flags: Event flags (optional)

    Returns:
        GeoEvent ready for insertion

    Raises:
        ValueError: If coordinates are out of range

    Example:
        event = create_geo_event(
            entity_id=archerdb.id(),
            latitude=37.7749,
            longitude=-122.4194,
            velocity_mps=15.5,
            heading=90,
        )
    """
    if not is_valid_latitude(latitude):
        raise ValueError(f"Invalid latitude: {latitude}. Must be between -90 and +90.")
    if not is_valid_longitude(longitude):
        raise ValueError(f"Invalid longitude: {longitude}. Must be between -180 and +180.")

    return GeoEvent(
        id=0,  # Server-assigned
        entity_id=entity_id,
        correlation_id=correlation_id,
        user_data=user_data,
        lat_nano=degrees_to_nano(latitude),
        lon_nano=degrees_to_nano(longitude),
        group_id=group_id,
        timestamp=0,  # Server-assigned
        altitude_mm=meters_to_mm(altitude_m),
        velocity_mms=meters_to_mm(velocity_mps),
        ttl_seconds=ttl_seconds,
        accuracy_mm=meters_to_mm(accuracy_m),
        heading_cdeg=heading_to_centidegrees(heading),
        flags=flags,
    )


def create_radius_query(
    latitude: float,
    longitude: float,
    radius_m: float,
    *,
    limit: int = 1000,
    timestamp_min: int = 0,
    timestamp_max: int = 0,
    group_id: int = 0,
) -> QueryRadiusFilter:
    """
    Create a radius query filter from user-friendly units.

    Args:
        latitude: Center latitude in degrees
        longitude: Center longitude in degrees
        radius_m: Radius in meters
        limit: Maximum results (default 1000)
        timestamp_min: Minimum timestamp filter (optional)
        timestamp_max: Maximum timestamp filter (optional)
        group_id: Group ID filter (optional)

    Returns:
        QueryRadiusFilter ready for query

    Raises:
        ValueError: If coordinates or radius are invalid
    """
    if not is_valid_latitude(latitude):
        raise ValueError(f"Invalid latitude: {latitude}")
    if not is_valid_longitude(longitude):
        raise ValueError(f"Invalid longitude: {longitude}")
    if radius_m <= 0:
        raise ValueError(f"Invalid radius: {radius_m}. Must be positive.")

    return QueryRadiusFilter(
        center_lat_nano=degrees_to_nano(latitude),
        center_lon_nano=degrees_to_nano(longitude),
        radius_mm=meters_to_mm(radius_m),
        limit=limit,
        timestamp_min=timestamp_min,
        timestamp_max=timestamp_max,
        group_id=group_id,
    )


def create_polygon_query(
    vertices: List[tuple[float, float]],
    *,
    holes: Optional[List[List[tuple[float, float]]]] = None,
    limit: int = 1000,
    timestamp_min: int = 0,
    timestamp_max: int = 0,
    group_id: int = 0,
) -> QueryPolygonFilter:
    """
    Create a polygon query filter from user-friendly units.

    Args:
        vertices: List of (lat, lon) tuples in degrees, CCW winding order
        holes: Optional list of holes, each hole is a list of (lat, lon) tuples
               in clockwise winding order
        limit: Maximum results (default 1000)
        timestamp_min: Minimum timestamp filter (optional)
        timestamp_max: Maximum timestamp filter (optional)
        group_id: Group ID filter (optional)

    Returns:
        QueryPolygonFilter ready for query

    Raises:
        ValueError: If polygon or holes are invalid

    Example:
        # Simple polygon (no holes)
        query = create_polygon_query([(37.79, -122.40), (37.79, -122.39), (37.78, -122.39)])

        # Polygon with a hole (e.g., park with a lake)
        query = create_polygon_query(
            vertices=[(37.79, -122.40), (37.79, -122.39), (37.78, -122.39), (37.78, -122.40)],
            holes=[
                [(37.785, -122.395), (37.787, -122.395), (37.787, -122.393), (37.785, -122.393)]
            ]
        )
    """
    if len(vertices) < 3:
        raise ValueError(f"Polygon must have at least 3 vertices, got {len(vertices)}")
    if len(vertices) > POLYGON_VERTICES_MAX:
        raise ValueError(
            f"Polygon exceeds maximum {POLYGON_VERTICES_MAX} vertices, got {len(vertices)}"
        )

    polygon_vertices = []
    for i, (lat, lon) in enumerate(vertices):
        if not is_valid_latitude(lat):
            raise ValueError(f"Invalid latitude at vertex {i}: {lat}")
        if not is_valid_longitude(lon):
            raise ValueError(f"Invalid longitude at vertex {i}: {lon}")
        polygon_vertices.append(PolygonVertex(
            lat_nano=degrees_to_nano(lat),
            lon_nano=degrees_to_nano(lon),
        ))

    # Process holes
    polygon_holes = []
    if holes:
        if len(holes) > POLYGON_HOLES_MAX:
            raise ValueError(
                f"Too many holes: {len(holes)} exceeds maximum {POLYGON_HOLES_MAX}"
            )

        for hole_idx, hole_vertices in enumerate(holes):
            if len(hole_vertices) < POLYGON_HOLE_VERTICES_MIN:
                raise ValueError(
                    f"Hole {hole_idx} must have at least {POLYGON_HOLE_VERTICES_MIN} vertices, "
                    f"got {len(hole_vertices)}"
                )

            hole_vertex_list = []
            for i, (lat, lon) in enumerate(hole_vertices):
                if not is_valid_latitude(lat):
                    raise ValueError(f"Invalid latitude at hole {hole_idx} vertex {i}: {lat}")
                if not is_valid_longitude(lon):
                    raise ValueError(f"Invalid longitude at hole {hole_idx} vertex {i}: {lon}")
                hole_vertex_list.append(PolygonVertex(
                    lat_nano=degrees_to_nano(lat),
                    lon_nano=degrees_to_nano(lon),
                ))

            polygon_holes.append(PolygonHole(vertices=hole_vertex_list))

    return QueryPolygonFilter(
        vertices=polygon_vertices,
        holes=polygon_holes,
        limit=limit,
        timestamp_min=timestamp_min,
        timestamp_max=timestamp_max,
        group_id=group_id,
    )
