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
    # Manual TTL Operations
    TTL_SET = 158          # vsr_operations_reserved (128) + 30
    TTL_EXTEND = 159       # vsr_operations_reserved (128) + 31
    TTL_CLEAR = 160        # vsr_operations_reserved (128) + 32


class TtlOperationResult(IntEnum):
    """
    Result codes for TTL operations.
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
    ENTITY_ID_MUST_NOT_BE_INT_MAX = 16


class DeleteEntityResult(IntEnum):
    """
    Result codes for entity delete operations.
    Maps to DeleteEntityResult in geo_state_machine.zig
    """
    OK = 0
    LINKED_EVENT_FAILED = 1
    ENTITY_ID_MUST_NOT_BE_ZERO = 2
    ENTITY_NOT_FOUND = 3
    ENTITY_ID_MUST_NOT_BE_INT_MAX = 4


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
# TTL Operations (Manual TTL Support)
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
MAX_ADDRESS_LEN = 64


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
    Matches ShardInfo in topology.zig (472 bytes).
    """
    id: int = 0                     # Shard identifier (0 to num_shards-1)
    primary: str = ""               # Primary/leader node address
    replicas: List[str] = field(default_factory=list)  # Replica node addresses
    status: ShardStatus = ShardStatus.ACTIVE
    entity_count: int = 0           # Approximate number of entities
    size_bytes: int = 0             # Approximate size in bytes

    @classmethod
    def from_bytes(cls, data: bytes) -> "ShardInfo":
        """Parse ShardInfo from raw bytes (472 bytes)."""
        import struct

        min_size = 4 + MAX_ADDRESS_LEN + (MAX_REPLICAS_PER_SHARD * MAX_ADDRESS_LEN) + 1 + 1 + 8 + 8
        if len(data) < min_size:
            raise ValueError(f"ShardInfo requires {min_size} bytes, got {len(data)}")

        offset = 0
        shard_id = struct.unpack("<I", data[offset:offset + 4])[0]
        offset += 4

        primary_raw = data[offset:offset + MAX_ADDRESS_LEN]
        primary = primary_raw.split(b'\x00')[0].decode('utf-8')
        offset += MAX_ADDRESS_LEN

        replicas = []
        for _ in range(MAX_REPLICAS_PER_SHARD):
            replica_raw = data[offset:offset + MAX_ADDRESS_LEN]
            offset += MAX_ADDRESS_LEN
            replica = replica_raw.split(b'\x00')[0].decode('utf-8')
            if replica:
                replicas.append(replica)

        replica_count = data[offset]
        offset += 1
        status = data[offset]
        offset += 1

        # Align to 8-byte boundary for u64 fields
        pad = (8 - (offset % 8)) % 8
        offset += pad

        entity_count = struct.unpack("<Q", data[offset:offset + 8])[0]
        offset += 8
        size_bytes = struct.unpack("<Q", data[offset:offset + 8])[0]

        if replica_count < len(replicas):
            replicas = replicas[:replica_count]

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
    flags: int = 0                  # Reserved flags
    shards: List[ShardInfo] = field(default_factory=list)
    last_change_ns: int = 0         # Timestamp of last topology change (ns since epoch)

    @classmethod
    def from_bytes(cls, data: bytes) -> "TopologyResponse":
        """Parse TopologyResponse from raw bytes."""
        import struct
        if len(data) < 52:
            raise ValueError(f"TopologyResponse requires at least 52 bytes, got {len(data)}")

        version = struct.unpack("<Q", data[0:8])[0]
        num_shards = struct.unpack("<I", data[8:12])[0]

        cluster_id_lo = struct.unpack("<Q", data[12:20])[0]
        cluster_id_hi = struct.unpack("<Q", data[20:28])[0]
        cluster_id = cluster_id_lo | (cluster_id_hi << 64)

        last_change_lo = struct.unpack("<Q", data[28:36])[0]
        last_change_hi = struct.unpack("<Q", data[36:44])[0]
        last_change_ns = last_change_lo | (last_change_hi << 64)
        if last_change_hi & (1 << 63):
            last_change_ns -= 1 << 128

        resharding_status = data[44]
        flags = data[45]

        # Parse shards (ShardInfo wire format)
        shard_header_size = 4 + MAX_ADDRESS_LEN + (MAX_REPLICAS_PER_SHARD * MAX_ADDRESS_LEN) + 1 + 1
        shard_padding = (8 - (shard_header_size % 8)) % 8
        shard_info_size = shard_header_size + shard_padding + 8 + 8

        shards = []
        shard_data_start = 52
        for i in range(num_shards):
            start = shard_data_start + i * shard_info_size
            end = start + shard_info_size
            if end <= len(data):
                shards.append(ShardInfo.from_bytes(data[start:end]))

        return cls(
            version=version,
            cluster_id=cluster_id,
            num_shards=num_shards,
            resharding_status=resharding_status,
            flags=flags,
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


# ============================================================================
# Sharding Strategy (per add-jump-consistent-hash spec)
# ============================================================================


class ShardingStrategy(IntEnum):
    """
    Strategy for distributing entities across shards.

    Different strategies offer different trade-offs:
    - MODULO: Simple, requires power-of-2 shard counts, moves most data on resize
    - VIRTUAL_RING: Consistent hashing with O(log N) lookup and memory cost
    - JUMP_HASH: Google's algorithm - O(1) memory, O(log N) compute, optimal movement

    Maps to ShardingStrategy in sharding.zig
    """
    MODULO = 0       # Simple hash % shards, requires power-of-2
    VIRTUAL_RING = 1 # Consistent hashing with virtual nodes
    JUMP_HASH = 2    # Google's Jump Consistent Hash (default, recommended)

    def requires_power_of_two(self) -> bool:
        """Check if this strategy requires power-of-2 shard counts."""
        return self == ShardingStrategy.MODULO

    @classmethod
    def from_string(cls, s: str) -> "ShardingStrategy":
        """Parse from string representation."""
        mapping = {
            "modulo": cls.MODULO,
            "virtual_ring": cls.VIRTUAL_RING,
            "jump_hash": cls.JUMP_HASH,
        }
        if s.lower() not in mapping:
            raise ValueError(f"Invalid sharding strategy: {s}")
        return mapping[s.lower()]

    def to_string(self) -> str:
        """Convert to string representation."""
        return {
            self.MODULO: "modulo",
            self.VIRTUAL_RING: "virtual_ring",
            self.JUMP_HASH: "jump_hash",
        }[self]


# ============================================================================
# Geo-Sharding Types (v2.2)
# ============================================================================

MAX_REGIONS = 16
MAX_REGION_NAME_LEN = 32
MAX_ENDPOINT_LEN = 128


class GeoShardPolicy(IntEnum):
    """
    Geo-shard policy determining how entities are assigned to regions.
    Maps to GeoShardPolicy in geo_sharding.zig
    """
    NONE = 0                 # No geo-sharding - all entities stay in local region
    BY_ENTITY_LOCATION = 1   # Route to nearest region based on entity lat/lon
    BY_ENTITY_ID_PREFIX = 2  # Route based on entity_id prefix mapping
    EXPLICIT = 3             # Application explicitly specifies target region


@dataclass
class GeoRegion:
    """
    Geographic region definition for geo-sharding.
    Matches GeoRegion in geo_sharding.zig.
    """
    name: str = ""                    # Unique region identifier (e.g., "us-east-1")
    center_lat_deg: float = 0.0       # Region center latitude in degrees
    center_lon_deg: float = 0.0       # Region center longitude in degrees
    endpoint: str = ""                # Primary endpoint address for this region
    priority: int = 0                 # Region priority (lower = preferred)
    active: bool = True               # Whether this region is active/available
    writable: bool = True             # Whether this region accepts writes


@dataclass
class GeoShardConfig:
    """
    Geo-sharding configuration for a cluster.
    Matches GeoShardConfig in geo_sharding.zig.
    """
    policy: GeoShardPolicy = GeoShardPolicy.NONE
    regions: List[GeoRegion] = field(default_factory=list)
    local_region_idx: int = 0
    cross_region_queries_enabled: bool = True
    cross_region_timeout_ms: int = 5000


@dataclass
class CrossRegionQueryResult:
    """
    Result of a cross-region query aggregation.
    """
    regions_queried: int = 0
    regions_responded: int = 0
    regions_failed: int = 0
    total_count: int = 0
    truncated: bool = False
    failed_regions: List[int] = field(default_factory=list)
    latencies_us: List[int] = field(default_factory=list)

    def has_partial_failure(self) -> bool:
        """Check if query had partial failures."""
        return self.regions_failed > 0 and self.regions_responded > 0

    def has_total_failure(self) -> bool:
        """Check if query completely failed."""
        return self.regions_failed > 0 and self.regions_responded == 0


# ============================================================================
# Active-Active Replication Types (v2.2)
# ============================================================================

class ConflictResolutionPolicy(IntEnum):
    """
    Conflict resolution policy for active-active replication.
    Maps to ConflictResolutionPolicy in vector_clock.zig
    """
    LAST_WRITER_WINS = 0     # Highest wall-clock timestamp wins (default)
    PRIMARY_WINS = 1         # Primary region write takes precedence
    CUSTOM_HOOK = 2          # Application-provided custom resolution


class VectorClockComparison(IntEnum):
    """
    Result of comparing two vector clocks.
    """
    LESS_THAN = 0       # First clock happened-before second
    GREATER_THAN = 1    # Second clock happened-before first
    EQUAL = 2           # Clocks are equal
    CONCURRENT = 3      # Clocks are concurrent (conflict)


@dataclass
class VectorClockEntry:
    """
    Vector clock entry for a single region.
    """
    region_id: int = 0
    timestamp: int = 0


@dataclass
class VectorClock:
    """
    Vector clock for tracking causality across regions.
    Matches VectorClock in vector_clock.zig.
    """
    entries: List[VectorClockEntry] = field(default_factory=list)
    wall_time_ns: int = 0

    def get(self, region_id: int) -> int:
        """Get timestamp for a specific region."""
        for entry in self.entries:
            if entry.region_id == region_id:
                return entry.timestamp
        return 0

    def set(self, region_id: int, timestamp: int) -> None:
        """Set timestamp for a specific region."""
        import time
        for entry in self.entries:
            if entry.region_id == region_id:
                entry.timestamp = timestamp
                self.wall_time_ns = time.time_ns()
                return
        self.entries.append(VectorClockEntry(region_id=region_id, timestamp=timestamp))
        self.wall_time_ns = time.time_ns()

    def increment(self, region_id: int) -> int:
        """Increment timestamp for a region (local write)."""
        current = self.get(region_id)
        new_ts = current + 1
        self.set(region_id, new_ts)
        return new_ts

    def merge(self, other: "VectorClock") -> None:
        """Merge another vector clock into this one."""
        for entry in other.entries:
            current = self.get(entry.region_id)
            if entry.timestamp > current:
                self.set(entry.region_id, entry.timestamp)
        if other.wall_time_ns > self.wall_time_ns:
            self.wall_time_ns = other.wall_time_ns

    def compare(self, other: "VectorClock") -> VectorClockComparison:
        """Compare two vector clocks."""
        self_less = False
        self_greater = False

        # Check all entries from self
        for entry in self.entries:
            other_ts = other.get(entry.region_id)
            if entry.timestamp < other_ts:
                self_less = True
            elif entry.timestamp > other_ts:
                self_greater = True

        # Check entries in other that might not be in self
        for entry in other.entries:
            self_ts = self.get(entry.region_id)
            if self_ts < entry.timestamp:
                self_less = True
            elif self_ts > entry.timestamp:
                self_greater = True

        if self_less and self_greater:
            return VectorClockComparison.CONCURRENT
        elif self_less:
            return VectorClockComparison.LESS_THAN
        elif self_greater:
            return VectorClockComparison.GREATER_THAN
        else:
            return VectorClockComparison.EQUAL

    def is_concurrent(self, other: "VectorClock") -> bool:
        """Check if clocks are concurrent (conflict)."""
        return self.compare(other) == VectorClockComparison.CONCURRENT


class ConflictResolutionWinner(IntEnum):
    """Which version wins in a conflict."""
    LOCAL = 0
    REMOTE = 1
    MERGED = 2


class ConflictResolutionReason(IntEnum):
    """Reason for conflict resolution."""
    LATER_TIMESTAMP = 0
    PRIMARY_REGION = 1
    CUSTOM_RESOLUTION = 2
    FALLBACK = 3


@dataclass
class ConflictResolution:
    """Result of conflict resolution."""
    winner: ConflictResolutionWinner = ConflictResolutionWinner.LOCAL
    reason: ConflictResolutionReason = ConflictResolutionReason.FALLBACK


@dataclass
class ConflictStats:
    """Conflict statistics for monitoring."""
    conflicts_detected: int = 0
    conflicts_resolved: int = 0
    last_writer_wins_count: int = 0
    primary_wins_count: int = 0
    custom_resolved_count: int = 0


@dataclass
class ConflictAuditEntry:
    """Conflict audit log entry."""
    entity_id: int = 0
    local_region: int = 0
    remote_region: int = 0
    policy: ConflictResolutionPolicy = ConflictResolutionPolicy.LAST_WRITER_WINS
    winner: ConflictResolutionWinner = ConflictResolutionWinner.LOCAL
    reason: ConflictResolutionReason = ConflictResolutionReason.FALLBACK
    timestamp_ns: int = 0


# ============================================================================
# GeoJSON/WKT Protocol Support (per add-geojson-wkt-protocol spec)
# ============================================================================

import json
import re
from typing import Tuple, Union, Any, Dict


class GeoFormatError(Exception):
    """Error parsing GeoJSON or WKT format."""
    pass


class PolygonValidationError(Exception):
    """Error validating polygon geometry (e.g., self-intersection)."""

    def __init__(
        self,
        message: str,
        segment1_index: int = -1,
        segment2_index: int = -1,
        intersection_point: Tuple[float, float] = None,
        repair_suggestions: List[str] = None,
    ):
        super().__init__(message)
        self.segment1_index = segment1_index
        self.segment2_index = segment2_index
        self.intersection_point = intersection_point
        self.repair_suggestions = repair_suggestions or []

    def get_repair_suggestions(self) -> List[str]:
        """Get suggestions for repairing the polygon."""
        return self.repair_suggestions


def _segments_intersect(
    p1: Tuple[float, float],
    p2: Tuple[float, float],
    p3: Tuple[float, float],
    p4: Tuple[float, float],
) -> bool:
    """
    Check if line segment p1-p2 intersects with segment p3-p4.
    Uses the cross product method with proper handling of edge cases.
    """

    def cross_product(o: Tuple[float, float], a: Tuple[float, float], b: Tuple[float, float]) -> float:
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    def on_segment(p: Tuple[float, float], q: Tuple[float, float], r: Tuple[float, float]) -> bool:
        """Check if point q lies on segment p-r."""
        return (
            min(p[0], r[0]) <= q[0] <= max(p[0], r[0])
            and min(p[1], r[1]) <= q[1] <= max(p[1], r[1])
        )

    d1 = cross_product(p3, p4, p1)
    d2 = cross_product(p3, p4, p2)
    d3 = cross_product(p1, p2, p3)
    d4 = cross_product(p1, p2, p4)

    # General case: segments cross
    if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and \
       ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)):
        return True

    # Collinear cases
    eps = 1e-10
    if abs(d1) < eps and on_segment(p3, p1, p4):
        return True
    if abs(d2) < eps and on_segment(p3, p2, p4):
        return True
    if abs(d3) < eps and on_segment(p1, p3, p2):
        return True
    if abs(d4) < eps and on_segment(p1, p4, p2):
        return True

    return False


def _generate_repair_suggestions(
    vertices: List[Tuple[float, float]],
    segment1_index: int,
    segment2_index: int,
) -> List[str]:
    """
    Generate repair suggestions for a self-intersecting polygon.

    Args:
        vertices: List of (lat, lon) tuples
        segment1_index: Index of first intersecting segment
        segment2_index: Index of second intersecting segment

    Returns:
        List of repair suggestions as strings
    """
    suggestions = []
    n = len(vertices)

    # Suggestion 1: Remove one of the vertices involved in the intersection
    v1_idx = (segment1_index + 1) % n
    v2_idx = (segment2_index + 1) % n

    suggestions.append(
        f"Try removing vertex {v1_idx} at ({vertices[v1_idx][0]:.6f}, {vertices[v1_idx][1]:.6f})"
    )
    suggestions.append(
        f"Try removing vertex {v2_idx} at ({vertices[v2_idx][0]:.6f}, {vertices[v2_idx][1]:.6f})"
    )

    # Suggestion 2: Check if reordering vertices might help (for bow-tie patterns)
    if abs(segment2_index - segment1_index) == 2:
        mid_idx = segment1_index + 1
        suggestions.append(
            f"Bow-tie pattern detected: try swapping vertices {mid_idx} and {segment2_index}"
        )

    # Suggestion 3: General advice
    suggestions.append(
        "Ensure vertices are ordered consistently (clockwise or counter-clockwise)"
    )

    return suggestions


def validate_polygon_no_self_intersection(
    vertices: List[Tuple[float, float]],
    raise_on_error: bool = True,
    include_repair_suggestions: bool = True,
) -> List[Tuple[int, int, Tuple[float, float]]]:
    """
    Validate that a polygon has no self-intersections.

    Uses an O(n²) algorithm suitable for polygons with reasonable vertex counts.
    For very large polygons, consider using a sweep line algorithm.

    Args:
        vertices: List of (lat, lon) tuples in degrees
        raise_on_error: If True, raise PolygonValidationError on first intersection
        include_repair_suggestions: If True, include repair suggestions in error

    Returns:
        List of intersections as (segment1_index, segment2_index, intersection_point)
        Empty list if no intersections.

    Raises:
        PolygonValidationError: If raise_on_error is True and polygon self-intersects
    """
    if len(vertices) < 4:
        # A triangle cannot self-intersect (3 vertices, closed = 3 edges)
        return []

    intersections = []
    n = len(vertices)

    # Check all pairs of non-adjacent edges
    for i in range(n):
        p1 = vertices[i]
        p2 = vertices[(i + 1) % n]

        # Start from i+2 to skip adjacent edges (they share a vertex)
        for j in range(i + 2, n):
            # Skip if edges share a vertex (adjacent edges)
            if j == (i + n - 1) % n:
                continue

            p3 = vertices[j]
            p4 = vertices[(j + 1) % n]

            if _segments_intersect(p1, p2, p3, p4):
                # Calculate approximate intersection point for error message
                # Simple midpoint approximation
                ix = (p1[0] + p2[0] + p3[0] + p4[0]) / 4
                iy = (p1[1] + p2[1] + p3[1] + p4[1]) / 4
                intersection = (ix, iy)

                if raise_on_error:
                    suggestions = []
                    if include_repair_suggestions:
                        suggestions = _generate_repair_suggestions(vertices, i, j)

                    raise PolygonValidationError(
                        f"Polygon self-intersects: edge {i}-{(i+1)%n} crosses edge {j}-{(j+1)%n} "
                        f"near ({ix:.6f}, {iy:.6f})",
                        segment1_index=i,
                        segment2_index=j,
                        intersection_point=intersection,
                        repair_suggestions=suggestions,
                    )
                intersections.append((i, j, intersection))

    return intersections


def _degrees_to_nanodegrees(degrees: float) -> int:
    """Convert degrees to nanodegrees."""
    return int(degrees * NANODEGREES_PER_DEGREE)


def _nanodegrees_to_degrees(nanodegrees: int) -> float:
    """Convert nanodegrees to degrees."""
    return nanodegrees / NANODEGREES_PER_DEGREE


def _validate_latitude(lat: float) -> None:
    """Validate latitude bounds."""
    if lat < -LAT_MAX or lat > LAT_MAX:
        raise GeoFormatError(f"Latitude {lat} out of bounds [-90, 90]")


def _validate_longitude(lon: float) -> None:
    """Validate longitude bounds."""
    if lon < -LON_MAX or lon > LON_MAX:
        raise GeoFormatError(f"Longitude {lon} out of bounds [-180, 180]")


# ============================================================================
# GeoJSON Parsing
# ============================================================================


def parse_geojson_point(geojson: Union[str, Dict[str, Any]]) -> Tuple[int, int]:
    """
    Parse GeoJSON Point to nanodegree coordinates.

    Args:
        geojson: GeoJSON string or dict: {"type": "Point", "coordinates": [lon, lat]}

    Returns:
        Tuple of (lat_nano, lon_nano)

    Raises:
        GeoFormatError: If input is invalid
    """
    if isinstance(geojson, str):
        try:
            geojson = json.loads(geojson)
        except json.JSONDecodeError as e:
            raise GeoFormatError(f"Invalid JSON: {e}")

    if not isinstance(geojson, dict):
        raise GeoFormatError("GeoJSON must be a dict")

    if geojson.get("type") != "Point":
        raise GeoFormatError(f"Expected type 'Point', got '{geojson.get('type')}'")

    coords = geojson.get("coordinates")
    if not coords or not isinstance(coords, (list, tuple)) or len(coords) < 2:
        raise GeoFormatError("Point must have [longitude, latitude] coordinates")

    lon, lat = float(coords[0]), float(coords[1])
    _validate_latitude(lat)
    _validate_longitude(lon)

    return _degrees_to_nanodegrees(lat), _degrees_to_nanodegrees(lon)


def parse_geojson_polygon(
    geojson: Union[str, Dict[str, Any]]
) -> Tuple[List[Tuple[int, int]], List[List[Tuple[int, int]]]]:
    """
    Parse GeoJSON Polygon to nanodegree coordinates.

    Args:
        geojson: GeoJSON string or dict with Polygon

    Returns:
        Tuple of (exterior_ring, holes) where each ring is a list of (lat_nano, lon_nano)

    Raises:
        GeoFormatError: If input is invalid
    """
    if isinstance(geojson, str):
        try:
            geojson = json.loads(geojson)
        except json.JSONDecodeError as e:
            raise GeoFormatError(f"Invalid JSON: {e}")

    if not isinstance(geojson, dict):
        raise GeoFormatError("GeoJSON must be a dict")

    if geojson.get("type") != "Polygon":
        raise GeoFormatError(f"Expected type 'Polygon', got '{geojson.get('type')}'")

    coords = geojson.get("coordinates")
    if not coords or not isinstance(coords, list) or len(coords) < 1:
        raise GeoFormatError("Polygon must have at least one ring")

    def parse_ring(ring: list) -> List[Tuple[int, int]]:
        if len(ring) < 3:
            raise GeoFormatError("Polygon ring must have at least 3 vertices")
        result = []
        for point in ring:
            if not isinstance(point, (list, tuple)) or len(point) < 2:
                raise GeoFormatError("Invalid point in ring")
            lon, lat = float(point[0]), float(point[1])
            _validate_latitude(lat)
            _validate_longitude(lon)
            result.append((_degrees_to_nanodegrees(lat), _degrees_to_nanodegrees(lon)))
        return result

    exterior = parse_ring(coords[0])
    holes = [parse_ring(ring) for ring in coords[1:]] if len(coords) > 1 else []

    return exterior, holes


# ============================================================================
# WKT Parsing
# ============================================================================

_WKT_POINT_PATTERN = re.compile(
    r"^\s*POINT\s*\(\s*(-?[\d.]+)\s+(-?[\d.]+)(?:\s+[-\d.]+)?\s*\)\s*$",
    re.IGNORECASE
)

_WKT_POLYGON_PATTERN = re.compile(
    r"^\s*POLYGON\s*\(\s*(.*)\s*\)\s*$",
    re.IGNORECASE | re.DOTALL
)


def parse_wkt_point(wkt: str) -> Tuple[int, int]:
    """
    Parse WKT POINT to nanodegree coordinates.

    Args:
        wkt: WKT string: "POINT(lon lat)" or "POINT(lon lat z)"

    Returns:
        Tuple of (lat_nano, lon_nano)

    Raises:
        GeoFormatError: If input is invalid
    """
    match = _WKT_POINT_PATTERN.match(wkt)
    if not match:
        raise GeoFormatError(f"Invalid WKT POINT: {wkt}")

    lon, lat = float(match.group(1)), float(match.group(2))
    _validate_latitude(lat)
    _validate_longitude(lon)

    return _degrees_to_nanodegrees(lat), _degrees_to_nanodegrees(lon)


def _parse_wkt_ring(ring_str: str) -> List[Tuple[int, int]]:
    """Parse a single WKT ring like '(x y, x y, ...)'."""
    ring_str = ring_str.strip()
    if not ring_str.startswith("(") or not ring_str.endswith(")"):
        raise GeoFormatError(f"Invalid WKT ring: {ring_str}")

    ring_str = ring_str[1:-1].strip()
    if not ring_str:
        raise GeoFormatError("Empty WKT ring")

    points = []
    for point_str in ring_str.split(","):
        parts = point_str.strip().split()
        if len(parts) < 2:
            raise GeoFormatError(f"Invalid point in WKT: {point_str}")
        lon, lat = float(parts[0]), float(parts[1])
        _validate_latitude(lat)
        _validate_longitude(lon)
        points.append((_degrees_to_nanodegrees(lat), _degrees_to_nanodegrees(lon)))

    if len(points) < 3:
        raise GeoFormatError("WKT ring must have at least 3 vertices")

    return points


def parse_wkt_polygon(
    wkt: str
) -> Tuple[List[Tuple[int, int]], List[List[Tuple[int, int]]]]:
    """
    Parse WKT POLYGON to nanodegree coordinates.

    Args:
        wkt: WKT string: "POLYGON((x y, x y, ...))" or with holes

    Returns:
        Tuple of (exterior_ring, holes) where each ring is a list of (lat_nano, lon_nano)

    Raises:
        GeoFormatError: If input is invalid
    """
    match = _WKT_POLYGON_PATTERN.match(wkt)
    if not match:
        raise GeoFormatError(f"Invalid WKT POLYGON: {wkt}")

    rings_str = match.group(1).strip()

    # Split into rings - find matching parentheses
    rings = []
    depth = 0
    start = 0
    for i, c in enumerate(rings_str):
        if c == "(":
            if depth == 0:
                start = i
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                rings.append(rings_str[start:i + 1])

    if not rings:
        raise GeoFormatError("POLYGON must have at least one ring")

    exterior = _parse_wkt_ring(rings[0])
    holes = [_parse_wkt_ring(ring) for ring in rings[1:]]

    return exterior, holes


# ============================================================================
# GeoJSON/WKT Output Formatting
# ============================================================================


def to_geojson_point(lat_nano: int, lon_nano: int) -> Dict[str, Any]:
    """
    Convert nanodegree coordinates to GeoJSON Point.

    Args:
        lat_nano: Latitude in nanodegrees
        lon_nano: Longitude in nanodegrees

    Returns:
        GeoJSON Point dict
    """
    return {
        "type": "Point",
        "coordinates": [
            _nanodegrees_to_degrees(lon_nano),
            _nanodegrees_to_degrees(lat_nano)
        ]
    }


def to_geojson_polygon(
    exterior: List[Tuple[int, int]],
    holes: Optional[List[List[Tuple[int, int]]]] = None
) -> Dict[str, Any]:
    """
    Convert nanodegree coordinates to GeoJSON Polygon.

    Args:
        exterior: Exterior ring as list of (lat_nano, lon_nano)
        holes: Optional list of holes, each as list of (lat_nano, lon_nano)

    Returns:
        GeoJSON Polygon dict
    """
    def ring_to_coords(ring: List[Tuple[int, int]]) -> List[List[float]]:
        return [
            [_nanodegrees_to_degrees(lon), _nanodegrees_to_degrees(lat)]
            for lat, lon in ring
        ]

    coordinates = [ring_to_coords(exterior)]
    if holes:
        coordinates.extend(ring_to_coords(hole) for hole in holes)

    return {
        "type": "Polygon",
        "coordinates": coordinates
    }


def to_wkt_point(lat_nano: int, lon_nano: int) -> str:
    """
    Convert nanodegree coordinates to WKT POINT.

    Args:
        lat_nano: Latitude in nanodegrees
        lon_nano: Longitude in nanodegrees

    Returns:
        WKT POINT string
    """
    lat = _nanodegrees_to_degrees(lat_nano)
    lon = _nanodegrees_to_degrees(lon_nano)
    return f"POINT({lon} {lat})"


def to_wkt_polygon(
    exterior: List[Tuple[int, int]],
    holes: Optional[List[List[Tuple[int, int]]]] = None
) -> str:
    """
    Convert nanodegree coordinates to WKT POLYGON.

    Args:
        exterior: Exterior ring as list of (lat_nano, lon_nano)
        holes: Optional list of holes, each as list of (lat_nano, lon_nano)

    Returns:
        WKT POLYGON string
    """
    def ring_to_wkt(ring: List[Tuple[int, int]]) -> str:
        points = [
            f"{_nanodegrees_to_degrees(lon)} {_nanodegrees_to_degrees(lat)}"
            for lat, lon in ring
        ]
        return f"({', '.join(points)})"

    rings = [ring_to_wkt(exterior)]
    if holes:
        rings.extend(ring_to_wkt(hole) for hole in holes)

    return f"POLYGON({', '.join(rings)})"


# ============================================================================
# GeoFormat Enum for Output Configuration
# ============================================================================


class GeoFormat(IntEnum):
    """Output format for geographic data."""
    NATIVE = 0      # Native nanodegree format
    GEOJSON = 1     # GeoJSON format
    WKT = 2         # Well-Known Text format
