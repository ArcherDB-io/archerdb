"""
ArcherDB Python SDK - Native Binding Interface

This module provides the low-level interface to the ArcherDB native client library,
wrapping the ctypes bindings with Python-friendly types.
"""

import ctypes
import os
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, List, Optional, Tuple

# Add archerdb bindings to path
_sdk_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _sdk_dir)

from archerdb import bindings
from archerdb.lib import c_uint128

from .types import (
    GeoEvent,
    GeoOperation,
    InsertGeoEventResult,
    DeleteEntityResult,
    QueryUuidFilter,
    QueryRadiusFilter,
    QueryPolygonFilter,
    QueryLatestFilter,
    StatusResponse,
    TtlSetRequest,
    TtlSetResponse,
    TtlExtendRequest,
    TtlExtendResponse,
    TtlClearRequest,
    TtlClearResponse,
    TopologyResponse,
    degrees_to_nano,
)
from .errors import ArcherDBError, StateError, StateException


# ============================================================================
# Wire Format Structures (matching Zig extern structs)
# ============================================================================

# We use the auto-generated structures from bindings.py to ensure consistency
CGeoEvent = bindings.CGeoEvent
CInsertGeoEventsResult = bindings.CInsertGeoEventsResult
CDeleteEntitiesResult = bindings.CDeleteEntitiesResult
CQueryUuidFilter = bindings.CQueryUuidFilter
CQueryRadiusFilter = bindings.CQueryRadiusFilter
CQueryLatestFilter = bindings.CQueryLatestFilter

# Batch query structures are not in bindings.py (likely not exposed in C header directly)
# So we define them here matching client-protocol/spec.md

class CQueryUuidBatchFilter(ctypes.Structure):
    """16-byte QueryUuidBatchFilter header (F1.3.4).

    Wire format:
      [CQueryUuidBatchFilter: 16 bytes]
      [entity_ids[0..count]: 16 bytes each (u128)]

    Header is 16 bytes to ensure entity_ids array is 16-byte aligned for u128 access.
    """
    _fields_ = [
        ("count", ctypes.c_uint32),        # u32, 4 bytes
        ("reserved", ctypes.c_uint8 * 12), # 12 bytes padding (must be zero)
    ]


class CQueryUuidBatchResult(ctypes.Structure):
    """16-byte QueryUuidBatchResult header (F1.3.4).

    Wire format:
      [CQueryUuidBatchResult: 16 bytes]
      [not_found_indices[0..not_found_count]: 2 bytes each (u16)]
      [padding to 16-byte alignment]
      [events[0..found_count]: 128 bytes each (GeoEvent)]
    """
    _fields_ = [
        ("found_count", ctypes.c_uint32),      # u32, 4 bytes
        ("not_found_count", ctypes.c_uint32),  # u32, 4 bytes
        ("reserved", ctypes.c_uint8 * 8),      # [8]u8
    ]

# ============================================================================
# Helpers
# ============================================================================

def _compute_pseudo_s2_cell(lat_nano: int, lon_nano: int) -> int:
    """Compute pseudo-S2 cell ID from coordinates."""
    product = lat_nano * lon_nano
    return abs(product) & 0xFFFFFFFFFFFFFFFF


def _pack_composite_id(s2_cell_id: int, timestamp_ns: int) -> int:
    """Pack S2 cell ID and timestamp into composite u128 ID."""
    return (s2_cell_id << 64) | (timestamp_ns & 0xFFFFFFFFFFFFFFFF)


# ============================================================================
# Serialization
# ============================================================================

def geo_event_to_wire(event: GeoEvent) -> CGeoEvent:
    """Convert GeoEvent to wire format (CGeoEvent)."""
    c_event = CGeoEvent()
    # Explicitly zero the reserved field (12 bytes)
    ctypes.memset(ctypes.addressof(c_event.reserved), 0, 12)

    # Set entity_id
    c_event.entity_id = c_uint128.from_param(event.entity_id)

    # Set coordinates
    c_event.lat_nano = event.lat_nano
    c_event.lon_nano = event.lon_nano

    # Compute composite ID if not set
    if event.id == 0:
        s2_cell = _compute_pseudo_s2_cell(event.lat_nano, event.lon_nano)
        timestamp_ns = int(time.time_ns())
        composite_id = _pack_composite_id(s2_cell, timestamp_ns)
        c_event.id = c_uint128.from_param(composite_id)
    else:
        c_event.id = c_uint128.from_param(event.id)

    # Set other u128 fields
    c_event.correlation_id = c_uint128.from_param(event.correlation_id)
    c_event.user_data = c_uint128.from_param(event.user_data)

    # Set other fields
    c_event.group_id = event.group_id
    c_event.timestamp = event.timestamp
    c_event.altitude_mm = event.altitude_mm
    c_event.velocity_mms = event.velocity_mms
    c_event.ttl_seconds = event.ttl_seconds
    c_event.accuracy_mm = event.accuracy_mm
    c_event.heading_cdeg = event.heading_cdeg
    c_event.flags = event.flags

    return c_event


def wire_to_geo_event(c_event: CGeoEvent) -> GeoEvent:
    """Convert wire format (CGeoEvent) to GeoEvent."""
    return c_event.to_python()


def query_uuid_filter_to_wire(filter: QueryUuidFilter) -> CQueryUuidFilter:
    """Convert QueryUuidFilter to wire format."""
    c_filter = CQueryUuidFilter()
    c_filter.entity_id = c_uint128.from_param(filter.entity_id)
    return c_filter


def query_radius_filter_to_wire(filter: QueryRadiusFilter) -> CQueryRadiusFilter:
    """Convert QueryRadiusFilter to wire format."""
    c_filter = CQueryRadiusFilter()
    c_filter.center_lat_nano = filter.center_lat_nano
    c_filter.center_lon_nano = filter.center_lon_nano
    # radius_mm is u32 in wire format (max ~4.3 billion mm = ~4,300 km)
    c_filter.radius_mm = min(filter.radius_mm, 0xFFFFFFFF)
    c_filter.limit = filter.limit
    c_filter.timestamp_min = filter.timestamp_min
    c_filter.timestamp_max = filter.timestamp_max
    c_filter.group_id = filter.group_id
    return c_filter


def query_latest_filter_to_wire(filter: QueryLatestFilter) -> CQueryLatestFilter:
    """Convert QueryLatestFilter to wire format."""
    c_filter = CQueryLatestFilter()
    c_filter.limit = filter.limit
    c_filter._reserved_align = 0
    c_filter.group_id = filter.group_id
    c_filter.cursor_timestamp = getattr(filter, 'cursor_timestamp', 0) or 0
    return c_filter


def query_polygon_filter_to_wire(filter: QueryPolygonFilter) -> bytes:
    """
    Convert QueryPolygonFilter to wire format.

    Wire format:
    - QueryPolygonFilter header (128 bytes)
    - Outer ring vertices (16 bytes each)
    - HoleDescriptors (8 bytes each, if holes present)
    - Hole vertices (16 bytes each, if holes present)
    """
    import struct

    # Compute counts from lists
    vertex_count = len(filter.vertices)
    hole_count = len(filter.holes) if filter.holes else 0

    # Build header (128 bytes)
    # vertex_count: u32, hole_count: u32, limit: u32, _reserved_align: u32
    # timestamp_min: u64, timestamp_max: u64, group_id: u64
    # reserved: [88]u8
    # Total: 4 + 4 + 4 + 4 + 8 + 8 + 8 + 88 = 128 bytes
    header = struct.pack(
        '<IIIIQQQ88s',  # little-endian: 4*u32 + 3*u64 + 88 bytes
        vertex_count,
        hole_count,
        filter.limit,
        0,  # _reserved_align
        filter.timestamp_min,
        filter.timestamp_max,
        filter.group_id,
        b'\x00' * 88  # reserved bytes
    )

    # Build outer ring vertices (16 bytes each: i64 lat_nano + i64 lon_nano)
    vertices_bytes = b''
    for v in filter.vertices:
        vertices_bytes += struct.pack('<qq', v.lat_nano, v.lon_nano)

    # Build holes (if any)
    hole_descriptors = b''
    hole_vertices_bytes = b''
    if filter.holes:
        for hole in filter.holes:
            # HoleDescriptor: vertex_count (u32) + reserved (u32)
            hole_descriptors += struct.pack('<II', len(hole.vertices), 0)
            # Hole vertices
            for v in hole.vertices:
                hole_vertices_bytes += struct.pack('<qq', v.lat_nano, v.lon_nano)

    return header + vertices_bytes + hole_descriptors + hole_vertices_bytes


# ============================================================================
# Native Client
# ============================================================================

@dataclass
class NativeClientResult:
    """Result from a native client operation."""
    status: int
    data_size: int
    data: Optional[bytes]


class NativeClient:
    """
    Low-level native client for ArcherDB.

    Thread-safe wrapper around the ArcherDB native bindings.
    """

    def __init__(self, cluster_id: int, addresses: List[str]):
        self._cluster_id = cluster_id
        self._addresses = addresses
        self._client: Optional[bindings.CClient] = None
        self._on_completion: Optional[Callable] = None
        self._callback_received = threading.Event()
        self._callback_result: List[Any] = [None, None, None]
        self._lock = threading.Lock()
        self._connected = False
        # Keep packet alive until callback completes to prevent use-after-free
        # The C client stores internal pointers to the packet memory
        self._current_packet: Optional[bindings.CPacket] = None
        self._current_data: Optional[ctypes.Array] = None

    def connect(self) -> bool:
        """Connect to the cluster. Returns True on success."""
        with self._lock:
            if self._connected:
                return True

            @bindings.OnCompletion
            def on_completion(ctx, packet, timestamp, data_ptr, data_size):
                self._callback_result[0] = packet.contents.status
                self._callback_result[1] = data_size
                if data_size > 0 and data_ptr:
                    self._callback_result[2] = bytes(
                        ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_ubyte * data_size)).contents
                    )
                else:
                    self._callback_result[2] = None
                self._callback_received.set()

            self._on_completion = on_completion
            self._client = bindings.CClient()
            cluster_id = c_uint128.from_param(self._cluster_id)
            addresses = ",".join(self._addresses).encode()

            init_status = bindings.arch_client_init(
                ctypes.byref(self._client),
                ctypes.cast(ctypes.byref(cluster_id), ctypes.POINTER(ctypes.c_uint8 * 16)),
                addresses,
                len(addresses),
                42,
                on_completion
            )

            if init_status == bindings.InitStatus.SUCCESS:
                self._connected = True
                return True
            return False

    def disconnect(self) -> None:
        """Disconnect from the cluster."""
        with self._lock:
            if self._client and self._connected:
                bindings.arch_client_deinit(ctypes.byref(self._client))
                self._connected = False
                self._client = None

    def is_connected(self) -> bool:
        """Return True if connected."""
        return self._connected

    def submit(
        self,
        operation: int,
        data: ctypes.Array,
        timeout: float = 30.0
    ) -> NativeClientResult:
        """Submit an operation and wait for result."""
        with self._lock:
            if not self._connected or not self._client:
                raise RuntimeError("Client not connected")

            # Store packet and data in instance to prevent garbage collection
            # The C client stores internal pointers that would become dangling
            # if we allowed Python to free this memory before the callback
            self._current_packet = bindings.CPacket()
            self._current_data = data
            packet = self._current_packet

            # Zero the opaque field explicitly (maps to internal packet fields)
            ctypes.memset(ctypes.addressof(packet.opaque), 0, 64)
            packet.user_data = 1
            packet.user_tag = 0
            packet.operation = operation
            packet.status = bindings.PacketStatus.OK
            packet.data = ctypes.cast(data, ctypes.c_void_p)
            packet.data_size = ctypes.sizeof(data)

            self._callback_received.clear()
            self._callback_result[0] = None
            self._callback_result[1] = None
            self._callback_result[2] = None

            client_status = bindings.arch_client_submit(
                ctypes.byref(self._client),
                ctypes.byref(packet)
            )

            if client_status != bindings.ClientStatus.OK:
                self._current_packet = None
                self._current_data = None
                return NativeClientResult(status=-1, data_size=0, data=None)

        # Wait outside lock to allow other threads
        if not self._callback_received.wait(timeout=timeout):
            # Timeout - packet may still be in flight, keep references
            return NativeClientResult(status=-2, data_size=0, data=None)

        # Callback received - C client is done with the packet
        # Clear references to allow garbage collection
        with self._lock:
            self._current_packet = None
            self._current_data = None

        return NativeClientResult(
            status=self._callback_result[0] if self._callback_result[0] is not None else -3,
            data_size=self._callback_result[1] or 0,
            data=self._callback_result[2],
        )

    def submit_bytes(
        self,
        operation: int,
        data: bytes,
        timeout: float = 30.0
    ) -> NativeClientResult:
        """Submit an operation with raw bytes data and wait for result."""
        with self._lock:
            if not self._connected or not self._client:
                raise RuntimeError("Client not connected")

            # Create a ctypes buffer from bytes and store in instance
            # to prevent garbage collection while C client holds pointers
            c_data = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
            self._current_data = c_data

            self._current_packet = bindings.CPacket()
            packet = self._current_packet

            # Zero the opaque field explicitly (maps to internal packet fields)
            ctypes.memset(ctypes.addressof(packet.opaque), 0, 64)
            packet.user_data = 1
            packet.user_tag = 0
            packet.operation = operation
            packet.status = bindings.PacketStatus.OK
            packet.data = ctypes.cast(c_data, ctypes.c_void_p)
            packet.data_size = len(data)

            self._callback_received.clear()
            self._callback_result[0] = None
            self._callback_result[1] = None
            self._callback_result[2] = None

            client_status = bindings.arch_client_submit(
                ctypes.byref(self._client),
                ctypes.byref(packet)
            )

            if client_status != bindings.ClientStatus.OK:
                self._current_packet = None
                self._current_data = None
                return NativeClientResult(status=-1, data_size=0, data=None)

        # Wait outside lock to allow other threads
        if not self._callback_received.wait(timeout=timeout):
            # Timeout - packet may still be in flight, keep references
            return NativeClientResult(status=-2, data_size=0, data=None)

        # Callback received - C client is done with the packet
        with self._lock:
            self._current_packet = None
            self._current_data = None

        return NativeClientResult(
            status=self._callback_result[0] if self._callback_result[0] is not None else -3,
            data_size=self._callback_result[1] or 0,
            data=self._callback_result[2],
        )

    # ========== High-level Operations ==========

    def insert_events(self, events: List[GeoEvent]) -> List[Tuple[int, InsertGeoEventResult]]:
        """
        Insert events and return list of (index, result) for errors.
        Empty list means all succeeded.
        """
        if not events:
            return []

        # Convert to wire format
        c_events = (CGeoEvent * len(events))()
        for i, event in enumerate(events):
            c_events[i] = geo_event_to_wire(event)

        # Submit
        result = self.submit(GeoOperation.INSERT_EVENTS.value, c_events)

        if result.status < 0:
            # All failed due to connection error
            return [(i, InsertGeoEventResult.RESERVED_FIELD) for i in range(len(events))]

        if result.status != bindings.PacketStatus.OK.value:
            return [(i, InsertGeoEventResult.RESERVED_FIELD) for i in range(len(events))]

        # Parse results - only return non-OK results (actual errors)
        errors = []
        if result.data_size > 0 and result.data:
            num_results = result.data_size // 8
            for i in range(num_results):
                idx = int.from_bytes(result.data[i*8:i*8+4], 'little')
                code = int.from_bytes(result.data[i*8+4:i*8+8], 'little')
                try:
                    result_enum = InsertGeoEventResult(code)
                except ValueError:
                    result_enum = InsertGeoEventResult.RESERVED_FIELD
                # Only include actual errors, not OK results
                if result_enum != InsertGeoEventResult.OK:
                    errors.append((idx, result_enum))

        return errors

    def upsert_events(self, events: List[GeoEvent]) -> List[Tuple[int, InsertGeoEventResult]]:
        """Upsert events (same as insert but with upsert semantics)."""
        if not events:
            return []

        c_events = (CGeoEvent * len(events))()
        for i, event in enumerate(events):
            c_events[i] = geo_event_to_wire(event)

        result = self.submit(GeoOperation.UPSERT_EVENTS.value, c_events)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return [(i, InsertGeoEventResult.RESERVED_FIELD) for i in range(len(events))]

        errors = []
        if result.data_size > 0 and result.data:
            num_results = result.data_size // 8
            for i in range(num_results):
                idx = int.from_bytes(result.data[i*8:i*8+4], 'little')
                code = int.from_bytes(result.data[i*8+4:i*8+8], 'little')
                try:
                    result_enum = InsertGeoEventResult(code)
                except ValueError:
                    result_enum = InsertGeoEventResult.RESERVED_FIELD
                # Only include actual errors, not OK results
                if result_enum != InsertGeoEventResult.OK:
                    errors.append((idx, result_enum))

        return errors

    def delete_entities(self, entity_ids: List[int]) -> List[Tuple[int, DeleteEntityResult]]:
        """Delete entities by ID."""
        if not entity_ids:
            return []

        # Pack entity_ids as u128 array
        c_ids = (ctypes.c_uint8 * (len(entity_ids) * 16))()
        for i, entity_id in enumerate(entity_ids):
            id_bytes = entity_id.to_bytes(16, 'little')
            for j in range(16):
                c_ids[i * 16 + j] = id_bytes[j]

        result = self.submit(GeoOperation.DELETE_ENTITIES.value, c_ids)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return [(i, DeleteEntityResult.ENTITY_NOT_FOUND) for i in range(len(entity_ids))]

        errors = []
        if result.data_size > 0 and result.data:
            num_results = result.data_size // 8
            for i in range(num_results):
                idx = int.from_bytes(result.data[i*8:i*8+4], 'little')
                code = int.from_bytes(result.data[i*8+4:i*8+8], 'little')
                try:
                    result_enum = DeleteEntityResult(code)
                except ValueError:
                    result_enum = DeleteEntityResult.ENTITY_NOT_FOUND
                if result_enum != DeleteEntityResult.OK:
                    errors.append((idx, result_enum))

        return errors

    def query_uuid(self, entity_id: int) -> List[GeoEvent]:
        """Query by UUID."""
        filter = QueryUuidFilter(entity_id=entity_id)
        c_filter = query_uuid_filter_to_wire(filter)
        c_filter_array = (CQueryUuidFilter * 1)(c_filter)

        result = self.submit(GeoOperation.QUERY_UUID.value, c_filter_array)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return []

        if result.data_size < 16 or not result.data:
            return []

        status = result.data[0]
        if status == 0:
            if result.data_size < 16 + 128:
                return []
            c_event = CGeoEvent.from_buffer_copy(result.data[16:16 + 128])
            return [wire_to_geo_event(c_event)]
        if status == StateError.ENTITY_NOT_FOUND:
            return []
        if status == StateError.ENTITY_EXPIRED:
            raise StateException(StateError.ENTITY_EXPIRED)

        message = f"Query UUID failed with status {status}"
        raise ArcherDBError(code=status, message=message, retryable=False)

    def query_uuid_batch(self, entity_ids: List[int]) -> "QueryUuidBatchResult":
        """
        Query multiple entities by UUID in a single request (F1.3.4).

        Args:
            entity_ids: List of entity UUIDs to look up (max 10,000)

        Returns:
            QueryUuidBatchResult with found events and not-found indices
        """
        from .types import QueryUuidBatchResult

        count = len(entity_ids)
        if count == 0:
            return QueryUuidBatchResult(
                found_count=0,
                not_found_count=0,
                not_found_indices=[],
                events=[],
            )

        # Build wire format: 16-byte header + entity_ids array
        # Header: count(u32) + reserved(12 bytes)
        header = CQueryUuidBatchFilter(count=count, reserved=(ctypes.c_uint8 * 12)())
        header_bytes = bytes(header)

        # Entity IDs: each is 16 bytes (u128)
        entity_bytes = b''
        for eid in entity_ids:
            entity_bytes += eid.to_bytes(16, 'little')

        # Combine into single buffer
        request_data = header_bytes + entity_bytes

        # Create ctypes array for submission
        request_array = (ctypes.c_uint8 * len(request_data))(*request_data)

        result = self.submit(GeoOperation.QUERY_UUID_BATCH.value, request_array)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            # On error, return empty result with all as not found
            return QueryUuidBatchResult(
                found_count=0,
                not_found_count=count,
                not_found_indices=list(range(count)),
                events=[],
            )

        # Parse response:
        # [CQueryUuidBatchResult: 16 bytes header]
        # [not_found_indices[0..not_found_count]: 2 bytes each (u16)]
        # [padding to 16-byte alignment]
        # [events[0..found_count]: 128 bytes each (GeoEvent)]
        HEADER_SIZE = 16

        if result.data_size < HEADER_SIZE or not result.data:
            return QueryUuidBatchResult(
                found_count=0,
                not_found_count=count,
                not_found_indices=list(range(count)),
                events=[],
            )

        # Parse header
        header_result = CQueryUuidBatchResult.from_buffer_copy(result.data[:HEADER_SIZE])
        found_count = header_result.found_count
        not_found_count = header_result.not_found_count

        # Parse not_found_indices
        not_found_size = not_found_count * 2
        not_found_indices = []
        offset = HEADER_SIZE
        for i in range(not_found_count):
            if offset + 2 <= result.data_size:
                idx = int.from_bytes(result.data[offset:offset+2], 'little')
                not_found_indices.append(idx)
                offset += 2

        # Calculate events offset (aligned to 16 bytes)
        # Note: Server allocates space for max_not_found_count (= total requested count),
        # not actual not_found_count, so we need to match that calculation
        total_count = found_count + not_found_count
        max_not_found_size = total_count * 2  # Space reserved for all possible not_found indices
        events_offset_unaligned = HEADER_SIZE + max_not_found_size
        events_offset = (events_offset_unaligned + 15) & ~15

        # Parse events
        events = []
        offset = events_offset
        for i in range(found_count):
            if offset + 128 <= result.data_size:
                c_event = CGeoEvent.from_buffer_copy(result.data[offset:offset+128])
                events.append(wire_to_geo_event(c_event))
                offset += 128

        return QueryUuidBatchResult(
            found_count=found_count,
            not_found_count=not_found_count,
            not_found_indices=not_found_indices,
            events=events,
        )

    def query_radius(self, filter: QueryRadiusFilter) -> List[GeoEvent]:
        """Query by radius."""
        c_filter = query_radius_filter_to_wire(filter)
        c_filter_array = (CQueryRadiusFilter * 1)(c_filter)

        result = self.submit(GeoOperation.QUERY_RADIUS.value, c_filter_array)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return []

        # Response format: 16-byte QueryResponse header + GeoEvent array
        # QueryResponse is 16 bytes: count(u32) + has_more(u8) + partial_result(u8) + reserved([10]u8)
        # The 16-byte size ensures GeoEvent array is 16-byte aligned (u128 alignment)
        HEADER_SIZE = 16
        events = []
        if result.data_size > HEADER_SIZE and result.data:
            # Skip the 16-byte header
            event_data = result.data[HEADER_SIZE:]
            num_events = len(event_data) // 128
            for i in range(num_events):
                c_event = CGeoEvent.from_buffer_copy(event_data[i*128:(i+1)*128])
                events.append(wire_to_geo_event(c_event))

        return events

    def query_latest(self, filter: QueryLatestFilter) -> List[GeoEvent]:
        """Query latest events."""
        c_filter = query_latest_filter_to_wire(filter)
        c_filter_array = (CQueryLatestFilter * 1)(c_filter)

        result = self.submit(GeoOperation.QUERY_LATEST.value, c_filter_array)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return []

        # Response format: 16-byte QueryResponse header + GeoEvent array
        # QueryResponse is 16 bytes: count(u32) + has_more(u8) + partial_result(u8) + reserved([10]u8)
        # The 16-byte size ensures GeoEvent array is 16-byte aligned (u128 alignment)
        HEADER_SIZE = 16
        events = []
        if result.data_size > HEADER_SIZE and result.data:
            # Skip the 16-byte header
            event_data = result.data[HEADER_SIZE:]
            num_events = len(event_data) // 128
            for i in range(num_events):
                c_event = CGeoEvent.from_buffer_copy(event_data[i*128:(i+1)*128])
                events.append(wire_to_geo_event(c_event))

        return events

    def query_polygon(self, filter: QueryPolygonFilter) -> List[GeoEvent]:
        """Query by polygon."""
        # Polygon queries use raw bytes since they have variable length
        wire_data = query_polygon_filter_to_wire(filter)

        result = self.submit_bytes(GeoOperation.QUERY_POLYGON.value, wire_data)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return []

        # Response format: 16-byte QueryResponse header + GeoEvent array
        HEADER_SIZE = 16
        events = []
        if result.data_size > HEADER_SIZE and result.data:
            # Skip the 16-byte header
            event_data = result.data[HEADER_SIZE:]
            num_events = len(event_data) // 128
            for i in range(num_events):
                c_event = CGeoEvent.from_buffer_copy(event_data[i*128:(i+1)*128])
                events.append(wire_to_geo_event(c_event))

        return events

    def ping(self) -> bool:
        """Send a ping to verify server connectivity."""
        import struct

        request = struct.pack("<Q", 0x676e6970)  # "ping"
        result = self.submit_bytes(GeoOperation.ARCHERDB_PING.value, request)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return False

        if result.data_size >= 4 and result.data:
            return result.data[:4] == b"pong"

        return True

    def get_status(self) -> StatusResponse:
        """Fetch server status via archerdb_get_status."""
        import struct

        request = struct.pack("<Q", 0)
        result = self.submit_bytes(GeoOperation.ARCHERDB_GET_STATUS.value, request)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return StatusResponse()

        if result.data_size < 64 or not result.data:
            return StatusResponse()

        ram_index_count = struct.unpack("<Q", result.data[0:8])[0]
        ram_index_capacity = struct.unpack("<Q", result.data[8:16])[0]
        ram_index_load_pct = struct.unpack("<I", result.data[16:20])[0]
        tombstone_count = struct.unpack("<Q", result.data[24:32])[0]
        ttl_expirations = struct.unpack("<Q", result.data[32:40])[0]
        deletion_count = struct.unpack("<Q", result.data[40:48])[0]

        return StatusResponse(
            ram_index_count=ram_index_count,
            ram_index_capacity=ram_index_capacity,
            ram_index_load_pct=ram_index_load_pct,
            tombstone_count=tombstone_count,
            ttl_expirations=ttl_expirations,
            deletion_count=deletion_count,
        )

    def get_topology(self) -> bytes:
        """Fetch raw topology response bytes."""
        import struct

        request = struct.pack("<Q", 0)
        result = self.submit_bytes(GeoOperation.GET_TOPOLOGY.value, request)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            raise ArcherDBError(code=result.status, message="Topology request failed")

        if result.data_size == 0 or not result.data:
            raise ArcherDBError(code=-1, message="Empty topology response")

        return result.data

    def ttl_set(self, request: TtlSetRequest) -> TtlSetResponse:
        """Set TTL for an entity."""
        result = self.submit_bytes(GeoOperation.TTL_SET.value, request.to_bytes())

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            raise ArcherDBError(code=result.status, message="TTL set request failed")

        if result.data_size < 64 or not result.data:
            raise ArcherDBError(code=-1, message="Invalid TTL set response")

        return TtlSetResponse.from_bytes(result.data)

    def ttl_extend(self, request: TtlExtendRequest) -> TtlExtendResponse:
        """Extend TTL for an entity."""
        result = self.submit_bytes(GeoOperation.TTL_EXTEND.value, request.to_bytes())

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            raise ArcherDBError(code=result.status, message="TTL extend request failed")

        if result.data_size < 64 or not result.data:
            raise ArcherDBError(code=-1, message="Invalid TTL extend response")

        return TtlExtendResponse.from_bytes(result.data)

    def ttl_clear(self, request: TtlClearRequest) -> TtlClearResponse:
        """Clear TTL for an entity."""
        result = self.submit_bytes(GeoOperation.TTL_CLEAR.value, request.to_bytes())

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            raise ArcherDBError(code=result.status, message="TTL clear request failed")

        if result.data_size < 64 or not result.data:
            raise ArcherDBError(code=-1, message="Invalid TTL clear response")

        return TtlClearResponse.from_bytes(result.data)

    def cleanup_expired(self, batch_size: int = 0) -> Tuple[int, int]:
        """
        Trigger TTL cleanup to remove expired entries.

        Args:
            batch_size: Number of index entries to scan (0 = scan all).

        Returns:
            Tuple of (entries_scanned, entries_removed).

        Per client-protocol/spec.md cleanup_expired (opcode 155):
        - Request: CleanupRequest (64 bytes) with batch_size field
        - Response: CleanupResponse (64 bytes) with entries_scanned, entries_removed
        """
        import struct

        # Build CleanupRequest: batch_size (u32) + reserved (60 bytes)
        request = struct.pack("<I60s", batch_size, b'\x00' * 60)

        result = self.submit_bytes(GeoOperation.CLEANUP_EXPIRED.value, request)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return (0, 0)

        # Parse CleanupResponse: entries_scanned (u64) + entries_removed (u64) + reserved (48 bytes)
        if result.data_size >= 16 and result.data:
            entries_scanned = struct.unpack("<Q", result.data[0:8])[0]
            entries_removed = struct.unpack("<Q", result.data[8:16])[0]
            return (entries_scanned, entries_removed)

        return (0, 0)
