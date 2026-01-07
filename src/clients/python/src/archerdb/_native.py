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
    degrees_to_nano,
)


# ============================================================================
# Wire Format Structures (matching Zig extern structs)
# ============================================================================

class CGeoEvent(ctypes.Structure):
    """128-byte GeoEvent matching Zig extern struct."""
    _fields_ = [
        ("id", ctypes.c_uint8 * 16),
        ("entity_id", ctypes.c_uint8 * 16),
        ("correlation_id", ctypes.c_uint8 * 16),
        ("user_data", ctypes.c_uint8 * 16),
        ("lat_nano", ctypes.c_int64),
        ("lon_nano", ctypes.c_int64),
        ("group_id", ctypes.c_uint64),
        ("timestamp", ctypes.c_uint64),
        ("altitude_mm", ctypes.c_int32),
        ("velocity_mms", ctypes.c_uint32),
        ("ttl_seconds", ctypes.c_uint32),
        ("accuracy_mm", ctypes.c_uint32),
        ("heading_cdeg", ctypes.c_uint16),
        ("flags", ctypes.c_uint16),
        ("reserved", ctypes.c_uint8 * 12),
    ]


class CInsertResult(ctypes.Structure):
    """8-byte insert result."""
    _fields_ = [
        ("index", ctypes.c_uint32),
        ("result", ctypes.c_uint32),
    ]


class CDeleteResult(ctypes.Structure):
    """8-byte delete result."""
    _fields_ = [
        ("index", ctypes.c_uint32),
        ("result", ctypes.c_uint32),
    ]


class CQueryUuidFilter(ctypes.Structure):
    """128-byte QueryUuidFilter."""
    _fields_ = [
        ("entity_id", ctypes.c_uint8 * 16),
        ("limit", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 108),
    ]


class CQueryRadiusFilter(ctypes.Structure):
    """128-byte QueryRadiusFilter."""
    _fields_ = [
        ("center_lat_nano", ctypes.c_int64),
        ("center_lon_nano", ctypes.c_int64),
        ("radius_mm", ctypes.c_uint64),
        ("timestamp_min", ctypes.c_uint64),
        ("timestamp_max", ctypes.c_uint64),
        ("group_id", ctypes.c_uint64),
        ("limit", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 72),
    ]


class CQueryLatestFilter(ctypes.Structure):
    """128-byte QueryLatestFilter."""
    _fields_ = [
        ("timestamp_min", ctypes.c_uint64),
        ("timestamp_max", ctypes.c_uint64),
        ("group_id", ctypes.c_uint64),
        ("limit", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 96),
    ]


# Verify sizes
assert ctypes.sizeof(CGeoEvent) == 128, f"CGeoEvent size mismatch: {ctypes.sizeof(CGeoEvent)}"
assert ctypes.sizeof(CQueryUuidFilter) == 128
assert ctypes.sizeof(CQueryRadiusFilter) == 128
assert ctypes.sizeof(CQueryLatestFilter) == 128


# ============================================================================
# Helpers
# ============================================================================

def _set_u128(field: ctypes.Array, value: int) -> None:
    """Set a u128 ctypes field from Python int."""
    value_bytes = value.to_bytes(16, 'little')
    for i in range(16):
        field[i] = value_bytes[i]


def _get_u128(field: ctypes.Array) -> int:
    """Get Python int from u128 ctypes field."""
    return int.from_bytes(bytes(field), 'little')


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

    # Set entity_id
    _set_u128(c_event.entity_id, event.entity_id)

    # Set coordinates
    c_event.lat_nano = event.lat_nano
    c_event.lon_nano = event.lon_nano

    # Compute composite ID if not set
    if event.id == 0:
        s2_cell = _compute_pseudo_s2_cell(event.lat_nano, event.lon_nano)
        timestamp_ns = int(time.time_ns())
        composite_id = _pack_composite_id(s2_cell, timestamp_ns)
        _set_u128(c_event.id, composite_id)
    else:
        _set_u128(c_event.id, event.id)

    # Set other u128 fields
    _set_u128(c_event.correlation_id, event.correlation_id)
    _set_u128(c_event.user_data, event.user_data)

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
    return GeoEvent(
        id=_get_u128(c_event.id),
        entity_id=_get_u128(c_event.entity_id),
        correlation_id=_get_u128(c_event.correlation_id),
        user_data=_get_u128(c_event.user_data),
        lat_nano=c_event.lat_nano,
        lon_nano=c_event.lon_nano,
        group_id=c_event.group_id,
        timestamp=c_event.timestamp,
        altitude_mm=c_event.altitude_mm,
        velocity_mms=c_event.velocity_mms,
        ttl_seconds=c_event.ttl_seconds,
        accuracy_mm=c_event.accuracy_mm,
        heading_cdeg=c_event.heading_cdeg,
        flags=c_event.flags,
    )


def query_uuid_filter_to_wire(filter: QueryUuidFilter) -> CQueryUuidFilter:
    """Convert QueryUuidFilter to wire format."""
    c_filter = CQueryUuidFilter()
    _set_u128(c_filter.entity_id, filter.entity_id)
    c_filter.limit = filter.limit
    return c_filter


def query_radius_filter_to_wire(filter: QueryRadiusFilter) -> CQueryRadiusFilter:
    """Convert QueryRadiusFilter to wire format."""
    c_filter = CQueryRadiusFilter()
    c_filter.center_lat_nano = filter.center_lat_nano
    c_filter.center_lon_nano = filter.center_lon_nano
    c_filter.radius_mm = filter.radius_mm
    c_filter.timestamp_min = filter.timestamp_min
    c_filter.timestamp_max = filter.timestamp_max
    c_filter.group_id = filter.group_id
    c_filter.limit = filter.limit
    c_filter.flags = filter.flags
    return c_filter


def query_latest_filter_to_wire(filter: QueryLatestFilter) -> CQueryLatestFilter:
    """Convert QueryLatestFilter to wire format."""
    c_filter = CQueryLatestFilter()
    # Map cursor_timestamp to timestamp_min (cursor for pagination)
    c_filter.timestamp_min = getattr(filter, 'cursor_timestamp', 0) or 0
    c_filter.timestamp_max = 0  # No upper bound by default
    c_filter.group_id = filter.group_id
    c_filter.limit = filter.limit
    c_filter.flags = 0  # Default flags
    return c_filter


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

            packet = bindings.CPacket()
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
                return NativeClientResult(status=-1, data_size=0, data=None)

        # Wait outside lock to allow other threads
        if not self._callback_received.wait(timeout=timeout):
            return NativeClientResult(status=-2, data_size=0, data=None)

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

        # Parse error results
        errors = []
        if result.data_size > 0 and result.data:
            num_errors = result.data_size // 8
            for i in range(num_errors):
                idx = int.from_bytes(result.data[i*8:i*8+4], 'little')
                code = int.from_bytes(result.data[i*8+4:i*8+8], 'little')
                try:
                    result_enum = InsertGeoEventResult(code)
                except ValueError:
                    result_enum = InsertGeoEventResult.RESERVED_FIELD
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
            num_errors = result.data_size // 8
            for i in range(num_errors):
                idx = int.from_bytes(result.data[i*8:i*8+4], 'little')
                code = int.from_bytes(result.data[i*8+4:i*8+8], 'little')
                try:
                    result_enum = InsertGeoEventResult(code)
                except ValueError:
                    result_enum = InsertGeoEventResult.RESERVED_FIELD
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

    def query_uuid(self, entity_id: int, limit: int = 1) -> List[GeoEvent]:
        """Query by UUID."""
        filter = QueryUuidFilter(entity_id=entity_id, limit=limit)
        c_filter = query_uuid_filter_to_wire(filter)
        c_filter_array = (CQueryUuidFilter * 1)(c_filter)

        result = self.submit(GeoOperation.QUERY_UUID.value, c_filter_array)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return []

        events = []
        if result.data_size >= 128 and result.data:
            num_events = result.data_size // 128
            for i in range(num_events):
                c_event = CGeoEvent.from_buffer_copy(result.data[i*128:(i+1)*128])
                events.append(wire_to_geo_event(c_event))

        return events

    def query_radius(self, filter: QueryRadiusFilter) -> List[GeoEvent]:
        """Query by radius."""
        c_filter = query_radius_filter_to_wire(filter)
        c_filter_array = (CQueryRadiusFilter * 1)(c_filter)

        result = self.submit(GeoOperation.QUERY_RADIUS.value, c_filter_array)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return []

        events = []
        if result.data_size >= 128 and result.data:
            num_events = result.data_size // 128
            for i in range(num_events):
                c_event = CGeoEvent.from_buffer_copy(result.data[i*128:(i+1)*128])
                events.append(wire_to_geo_event(c_event))

        return events

    def query_latest(self, filter: QueryLatestFilter) -> List[GeoEvent]:
        """Query latest events."""
        c_filter = query_latest_filter_to_wire(filter)
        c_filter_array = (CQueryLatestFilter * 1)(c_filter)

        result = self.submit(GeoOperation.QUERY_LATEST.value, c_filter_array)

        if result.status < 0 or result.status != bindings.PacketStatus.OK.value:
            return []

        events = []
        if result.data_size >= 128 and result.data:
            num_events = result.data_size // 128
            for i in range(num_events):
                c_event = CGeoEvent.from_buffer_copy(result.data[i*128:(i+1)*128])
                events.append(wire_to_geo_event(c_event))

        return events
