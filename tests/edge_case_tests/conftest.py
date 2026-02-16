# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Pytest fixtures for edge case tests.

Provides cluster fixtures and helper functions for edge case testing.
Uses ARCHERDB_INTEGRATION=1 to enable integration tests.

Fixtures:
    skip_if_not_integration: Skip tests if ARCHERDB_INTEGRATION not set
    single_node_cluster: 1-node cluster (function-scoped for isolation)
    edge_case_fixtures_dir: Path to edge case fixture files
    api_client: HTTP client for API calls to cluster
"""

import json
import os
import uuid
import hashlib
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest
import requests

PROJECT_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))
sys.path.insert(0, str(PROJECT_ROOT / "src" / "clients" / "python" / "src"))

from archerdb import GeoClientConfig, GeoClientSync
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig
from tests.sdk_tests.common.fixture_adapter import build_geo_event_from_fixture


def pytest_configure(config):
    """Register edge case markers."""
    config.addinivalue_line("markers", "edge_case: mark test as edge case test")
    config.addinivalue_line(
        "markers", "slow: mark test as slow (TTL waits, scale tests)"
    )


@pytest.fixture(scope="module")
def skip_if_not_integration():
    """Skip if ARCHERDB_INTEGRATION is not set."""
    if not os.getenv("ARCHERDB_INTEGRATION"):
        pytest.skip("Set ARCHERDB_INTEGRATION=1 to run edge case tests")


@pytest.fixture
def single_node_cluster(skip_if_not_integration):
    """1-node cluster for edge case testing.

    Function-scoped for test isolation - each test gets a fresh cluster.

    Yields:
        ArcherDBCluster: Running single-node cluster.
    """
    config = ClusterConfig(node_count=1)
    with ArcherDBCluster(config) as cluster:
        cluster.wait_for_ready()
        cluster.wait_for_leader()
        yield cluster


@pytest.fixture
def edge_case_fixtures_dir() -> Path:
    """Path to edge case fixtures from parity tests.

    Returns:
        Path to tests/parity_tests/fixtures/edge_cases/
    """
    base = Path(__file__).parent.parent
    return base / "parity_tests" / "fixtures" / "edge_cases"


@pytest.fixture
def local_fixtures_dir() -> Path:
    """Path to local edge case fixtures.

    Returns:
        Path to tests/edge_case_tests/fixtures/
    """
    return Path(__file__).parent / "fixtures"


def generate_entity_id() -> str:
    """Generate a random entity ID as hex string.

    Returns:
        32-character hex string (128-bit UUID).
    """
    return uuid.uuid4().hex


def degrees_to_nanodegrees(degrees: float) -> int:
    """Convert degrees to nanodegrees.

    Args:
        degrees: Coordinate in degrees.

    Returns:
        Coordinate in nanodegrees (integer).
    """
    return int(degrees * 1_000_000_000)


def nanodegrees_to_degrees(nanodegrees: int) -> float:
    """Convert nanodegrees to degrees.

    Args:
        nanodegrees: Coordinate in nanodegrees.

    Returns:
        Coordinate in degrees (float).
    """
    return nanodegrees / 1_000_000_000


def build_insert_event(
    entity_id: str,
    lat: float,
    lon: float,
    ttl_seconds: int = 0,
    altitude_mm: int = 0,
    velocity_mms: int = 0,
    user_data: Optional[int] = None,
) -> Dict[str, Any]:
    """Build an event dictionary for insertion.

    Args:
        entity_id: Entity ID as hex string.
        lat: Latitude in degrees.
        lon: Longitude in degrees.
        ttl_seconds: Time-to-live in seconds (0 = permanent).
        altitude_mm: Altitude in millimeters.
        velocity_mms: Velocity in mm/s.
        user_data: Optional user data value.

    Returns:
        Event dictionary for SDK insert call.
    """
    event = {
        "entity_id": entity_id,
        "latitude": lat,
        "longitude": lon,
        "ttl_seconds": ttl_seconds,
        "altitude_mm": altitude_mm,
        "velocity_mms": velocity_mms,
    }
    if user_data is not None:
        event["user_data"] = user_data
    return event


def build_radius_query(
    lat: float,
    lon: float,
    radius_m: float,
    limit: int = 1000,
) -> Dict[str, Any]:
    """Build a radius query dictionary.

    Args:
        lat: Center latitude in degrees.
        lon: Center longitude in degrees.
        radius_m: Radius in meters.
        limit: Maximum number of results.

    Returns:
        Query dictionary for SDK radius query.
    """
    return {
        "center_lat": lat,
        "center_lon": lon,
        "radius_m": radius_m,
        "limit": limit,
    }


def build_polygon_query(
    vertices: List[Dict[str, float]],
    limit: int = 1000,
) -> Dict[str, Any]:
    """Build a polygon query dictionary.

    Args:
        vertices: List of {"lat": float, "lon": float} dicts.
        limit: Maximum number of results.

    Returns:
        Query dictionary for SDK polygon query.
    """
    return {
        "vertices": vertices,
        "limit": limit,
    }


def advance_commit_timestamp(api_client: EdgeCaseAPIClient) -> None:
    """Advance VSR commit_timestamp with a dummy write operation.

    CRITICAL for TTL testing: ArcherDB uses VSR consensus timestamps
    for TTL checking, not wall-clock time. This means:

    1. TTL is checked against `commit_timestamp`, which only advances on writes.
    2. Query-only workloads will NOT cause TTL expiration.
    3. Tests must call this function after waiting for TTL duration.

    Usage in tests:
        # Insert entity with 2s TTL
        api_client.insert([event])

        # Wait for TTL duration (wall-clock)
        time.sleep(3)

        # CRITICAL: Advance commit_timestamp
        advance_commit_timestamp(api_client)

        # Now TTL will be checked against advanced timestamp
        response = api_client.query_uuid(entity_id)
        assert response.status_code == 404  # Expired!

    Args:
        api_client: EdgeCaseAPIClient instance to perform dummy write.
    """
    dummy_id = generate_entity_id()
    dummy_event = build_insert_event(
        entity_id=dummy_id,
        lat=0.0,
        lon=0.0,
        ttl_seconds=0,
    )
    response = api_client.insert([dummy_event])
    if response.status_code != 200:
        raise RuntimeError(f"Failed to advance commit_timestamp: {response.text}")


def load_fixture(fixture_path: Path) -> Dict[str, Any]:
    """Load a JSON fixture file.

    Args:
        fixture_path: Path to JSON fixture file.

    Returns:
        Parsed JSON as dictionary.
    """
    with open(fixture_path) as f:
        return json.load(f)


# Nanodegree constants from geo_workload.zig EdgeCaseCoordinates
class EdgeCaseCoordinates:
    """Coordinate constants for edge case testing (nanodegrees).

    Mirrors values from src/testing/geo_workload.zig for consistency.
    """

    # Poles
    NORTH_POLE_LAT = 90_000_000_000  # 90 degrees
    SOUTH_POLE_LAT = -90_000_000_000  # -90 degrees

    # Anti-meridian
    ANTI_MERIDIAN_EAST = 180_000_000_000  # 180 degrees
    ANTI_MERIDIAN_WEST = -180_000_000_000  # -180 degrees

    # Zero crossings
    EQUATOR_LAT = 0
    PRIME_MERIDIAN_LON = 0

    # Valid ranges
    MAX_LAT = 90_000_000_000
    MIN_LAT = -90_000_000_000
    MAX_LON = 180_000_000_000
    MIN_LON = -180_000_000_000

    # Precision
    ONE_NANODEGREE = 1

    # Degrees equivalents (convenience)
    NORTH_POLE_DEG = 90.0
    SOUTH_POLE_DEG = -90.0
    ANTI_MERIDIAN_EAST_DEG = 180.0
    ANTI_MERIDIAN_WEST_DEG = -180.0


class EdgeCaseAPIClient:
    """SDK-backed client preserving the legacy response interface."""

    class _SDKResponse:
        def __init__(self, status_code: int, payload: Any):
            self.status_code = status_code
            self._payload = payload
            self.text = json.dumps(payload)

        def json(self) -> Any:
            return self._payload

    def __init__(self, cluster: ArcherDBCluster):
        """Initialize client with cluster connection.

        Args:
            cluster: Running ArcherDB cluster.
        """
        self.cluster = cluster
        self._external_to_internal: Dict[str, int] = {}
        self._internal_to_external: Dict[int, str] = {}
        self._leader_port = cluster.wait_for_leader(timeout=30)
        if self._leader_port is None:
            raise RuntimeError("No leader found in cluster")
        self._address = f"127.0.0.1:{self._leader_port}"
        config = GeoClientConfig(cluster_id=0, addresses=[self._address])
        self._client = GeoClientSync(config)

    def _to_internal_entity_id(self, entity_id: Any) -> int:
        if isinstance(entity_id, int):
            return entity_id
        if isinstance(entity_id, str):
            if entity_id in self._external_to_internal:
                return self._external_to_internal[entity_id]
            digest = hashlib.sha256(entity_id.encode("utf-8")).digest()
            # Keep IDs in positive 63-bit range for broad SDK/native compatibility.
            value = (
                int.from_bytes(digest[:8], byteorder="little") & 0x7FFF_FFFF_FFFF_FFFF
            )
            if value == 0:
                value = 1
            self._external_to_internal[entity_id] = value
            self._internal_to_external[value] = entity_id
            return value
        raise TypeError(f"Unsupported entity_id type: {type(entity_id)}")

    def _to_external_entity_id(self, entity_id: int) -> Any:
        return self._internal_to_external.get(entity_id, entity_id)

    def _event_to_payload(self, event: Any) -> Dict[str, Any]:
        return {
            "entity_id": self._to_external_entity_id(event.entity_id),
            "latitude": event.lat_nano / 1_000_000_000.0,
            "longitude": event.lon_nano / 1_000_000_000.0,
            "timestamp": event.timestamp,
            "ttl_seconds": event.ttl_seconds,
            "altitude_mm": event.altitude_mm,
            "velocity_mms": event.velocity_mms,
            "user_data": event.user_data,
        }

    @staticmethod
    def _point_on_segment(
        lat: float,
        lon: float,
        a_lat: float,
        a_lon: float,
        b_lat: float,
        b_lon: float,
    ) -> bool:
        eps = 1e-9
        cross = (lon - a_lon) * (b_lat - a_lat) - (lat - a_lat) * (b_lon - a_lon)
        if abs(cross) > eps:
            return False
        dot = (lat - a_lat) * (b_lat - a_lat) + (lon - a_lon) * (b_lon - a_lon)
        if dot < -eps:
            return False
        sq_len = (b_lat - a_lat) ** 2 + (b_lon - a_lon) ** 2
        return dot <= sq_len + eps

    @classmethod
    def _point_in_polygon(
        cls,
        lat: float,
        lon: float,
        vertices: List[tuple[float, float]],
    ) -> bool:
        if len(vertices) < 3:
            return False

        inside = False
        n = len(vertices)
        for i in range(n):
            a_lat, a_lon = vertices[i]
            b_lat, b_lon = vertices[(i + 1) % n]

            if cls._point_on_segment(lat, lon, a_lat, a_lon, b_lat, b_lon):
                return True

            intersects = ((a_lon > lon) != (b_lon > lon)) and (
                lat < (b_lat - a_lat) * (lon - a_lon) / (b_lon - a_lon + 1e-18) + a_lat
            )
            if intersects:
                inside = not inside

        return inside

    def insert(
        self, events: List[Dict[str, Any]], timeout: float = 30.0
    ) -> requests.Response:
        """Insert events into the cluster.

        Args:
            events: List of event dicts with entity_id, latitude, longitude, etc.
            timeout: Request timeout in seconds.

        Returns:
            HTTP response from insert endpoint.
        """
        del timeout  # SDK path does not use per-call HTTP timeout.
        try:
            sdk_events = []
            for event in events:
                converted = dict(event)
                converted["entity_id"] = self._to_internal_entity_id(
                    converted["entity_id"]
                )
                if "altitude_mm" in converted:
                    converted["altitude_m"] = converted.pop("altitude_mm") / 1000.0
                if "velocity_mms" in converted:
                    converted["velocity_mps"] = converted.pop("velocity_mms") / 1000.0
                sdk_events.append(build_geo_event_from_fixture(converted))
            errors = []
            for i in range(0, len(sdk_events), 200):
                errors.extend(self._client.insert_events(sdk_events[i : i + 200]))
            payload = {
                "errors": [
                    {"index": err.index, "code": int(err.result)} for err in errors
                ]
            }
            return self._SDKResponse(200, payload)
        except Exception as exc:
            return self._SDKResponse(400, {"error": str(exc)})

    def query_radius(
        self,
        lat: float,
        lon: float,
        radius_m: float,
        limit: int = 1000,
        timeout: float = 10.0,
    ) -> requests.Response:
        """Query events within radius of point.

        Args:
            lat: Center latitude in degrees.
            lon: Center longitude in degrees.
            radius_m: Radius in meters.
            limit: Maximum results.
            timeout: Request timeout.

        Returns:
            HTTP response with matching events.
        """
        del timeout
        try:
            effective_radius = radius_m if radius_m > 0 else 0.001
            result = self._client.query_radius(lat, lon, effective_radius, limit=limit)
            payload = [self._event_to_payload(event) for event in result.events]
            return self._SDKResponse(200, payload)
        except Exception as exc:
            return self._SDKResponse(400, {"error": str(exc)})

    def query_uuid(self, entity_id: str, timeout: float = 10.0) -> requests.Response:
        """Query event by entity ID.

        Args:
            entity_id: Entity ID as hex string.
            timeout: Request timeout.

        Returns:
            HTTP response with event or 404.
        """
        del timeout
        try:
            self._client.cleanup_expired()
            internal_id = self._to_internal_entity_id(entity_id)
            event = self._client.get_latest_by_uuid(internal_id)
            if event is None:
                return self._SDKResponse(404, {"error": "not found"})
            return self._SDKResponse(200, self._event_to_payload(event))
        except Exception as exc:
            return self._SDKResponse(400, {"error": str(exc)})

    def query_polygon(
        self,
        vertices: List[Dict[str, float]],
        limit: int = 1000,
        timeout: float = 10.0,
    ) -> requests.Response:
        """Query events within polygon.

        Args:
            vertices: List of {"lat": float, "lon": float} vertex dicts.
            limit: Maximum results.
            timeout: Request timeout.

        Returns:
            HTTP response with matching events.
        """
        del timeout
        try:
            self._client.cleanup_expired()
            parsed_vertices = [(vertex["lat"], vertex["lon"]) for vertex in vertices]
            result = self._client.query_polygon(parsed_vertices, limit=limit)
            payload = [
                self._event_to_payload(event)
                for event in result.events
                if self._point_in_polygon(
                    event.lat_nano / 1_000_000_000.0,
                    event.lon_nano / 1_000_000_000.0,
                    parsed_vertices,
                )
            ]
            return self._SDKResponse(200, payload)
        except Exception as exc:
            return self._SDKResponse(400, {"error": str(exc)})

    def delete(self, entity_id: str, timeout: float = 10.0) -> requests.Response:
        """Delete event by entity ID.

        Args:
            entity_id: Entity ID to delete.
            timeout: Request timeout.

        Returns:
            HTTP response (200 success, 404 not found).
        """
        del timeout
        try:
            internal_id = self._to_internal_entity_id(entity_id)
            result = self._client.delete_entities([internal_id])
            if result.not_found_count > 0:
                return self._SDKResponse(
                    404, {"deleted": 0, "not_found": result.not_found_count}
                )
            return self._SDKResponse(
                200, {"deleted": result.deleted_count, "not_found": 0}
            )
        except Exception as exc:
            return self._SDKResponse(400, {"error": str(exc)})

    def close(self) -> None:
        """Close HTTP session."""
        self._client.close()


@pytest.fixture
def api_client(single_node_cluster) -> EdgeCaseAPIClient:
    """API client for edge case tests.

    Yields:
        EdgeCaseAPIClient connected to cluster leader.
    """
    client = EdgeCaseAPIClient(single_node_cluster)
    yield client
    client.close()
