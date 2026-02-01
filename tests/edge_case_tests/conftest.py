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
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest
import requests

from test_infrastructure.harness import ArcherDBCluster, ClusterConfig


def pytest_configure(config):
    """Register edge case markers."""
    config.addinivalue_line("markers", "edge_case: mark test as edge case test")
    config.addinivalue_line("markers", "slow: mark test as slow (TTL waits, scale tests)")


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
    """HTTP client for edge case test API calls.

    Wraps the ArcherDB HTTP API for insert, query-radius, query-uuid,
    query-polygon, and delete operations.

    Usage:
        with ArcherDBCluster(config) as cluster:
            client = EdgeCaseAPIClient(cluster)
            response = client.insert([event])
            client.close()
    """

    def __init__(self, cluster: ArcherDBCluster):
        """Initialize client with cluster connection.

        Args:
            cluster: Running ArcherDB cluster.
        """
        self.cluster = cluster
        self._session = requests.Session()
        self._leader_port = cluster.wait_for_leader(timeout=30)
        if self._leader_port is None:
            raise RuntimeError("No leader found in cluster")
        self._base_url = f"http://127.0.0.1:{self._leader_port}"

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
        return self._session.post(
            f"{self._base_url}/insert",
            json=events,
            timeout=timeout,
        )

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
        query = {
            "center_lat": lat,
            "center_lon": lon,
            "radius_m": radius_m,
            "limit": limit,
        }
        return self._session.post(
            f"{self._base_url}/query-radius",
            json=query,
            timeout=timeout,
        )

    def query_uuid(self, entity_id: str, timeout: float = 10.0) -> requests.Response:
        """Query event by entity ID.

        Args:
            entity_id: Entity ID as hex string.
            timeout: Request timeout.

        Returns:
            HTTP response with event or 404.
        """
        return self._session.get(
            f"{self._base_url}/query-uuid/{entity_id}",
            timeout=timeout,
        )

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
        query = {
            "vertices": vertices,
            "limit": limit,
        }
        return self._session.post(
            f"{self._base_url}/query-polygon",
            json=query,
            timeout=timeout,
        )

    def delete(self, entity_id: str, timeout: float = 10.0) -> requests.Response:
        """Delete event by entity ID.

        Args:
            entity_id: Entity ID to delete.
            timeout: Request timeout.

        Returns:
            HTTP response (200 success, 404 not found).
        """
        return self._session.delete(
            f"{self._base_url}/delete/{entity_id}",
            timeout=timeout,
        )

    def close(self) -> None:
        """Close HTTP session."""
        self._session.close()


@pytest.fixture
def api_client(single_node_cluster) -> EdgeCaseAPIClient:
    """API client for edge case tests.

    Yields:
        EdgeCaseAPIClient connected to cluster leader.
    """
    client = EdgeCaseAPIClient(single_node_cluster)
    yield client
    client.close()
