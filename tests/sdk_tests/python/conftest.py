# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Pytest configuration and fixtures for Python SDK operation tests.

This module provides fixtures for:
- ArcherDB cluster lifecycle (start/stop per test module)
- Client creation and cleanup
- Database cleanup between tests for isolation
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# Add project paths for imports
PROJECT_ROOT = Path(__file__).parent.parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))
sys.path.insert(0, str(PROJECT_ROOT / "src" / "clients" / "python" / "src"))

# Check if integration tests should run
RUN_INTEGRATION = os.getenv("ARCHERDB_INTEGRATION") == "1"


def pytest_configure(config):
    """Add custom markers."""
    config.addinivalue_line(
        "markers", "integration: mark test as integration test requiring server"
    )


def pytest_collection_modifyitems(config, items):
    """Skip integration tests if ARCHERDB_INTEGRATION is not set."""
    if not RUN_INTEGRATION:
        skip_integration = pytest.mark.skip(
            reason="Set ARCHERDB_INTEGRATION=1 to run integration tests"
        )
        for item in items:
            if "integration" in item.keywords or "test_all_operations" in str(item.fspath):
                item.add_marker(skip_integration)


@pytest.fixture(scope="module")
def cluster():
    """Start fresh ArcherDB cluster for this test module.

    Uses the test_infrastructure harness to start a single-node
    cluster with automatic cleanup on teardown.

    Yields:
        ArcherDBCluster: Running cluster instance
    """
    if not RUN_INTEGRATION:
        pytest.skip("Set ARCHERDB_INTEGRATION=1 to run integration tests")

    from test_infrastructure.harness import ArcherDBCluster, ClusterConfig

    config = ClusterConfig(
        node_count=1,
        cache_grid="256MiB",  # Smaller for tests
        startup_timeout=60.0,
    )

    cluster = ArcherDBCluster(config)
    cluster.start()

    try:
        # Wait for cluster to be ready
        if not cluster.wait_for_ready(timeout=60.0):
            cluster.stop()
            pytest.fail("Cluster failed to become ready")

        # Wait for leader (needed for writes)
        leader_port = cluster.wait_for_leader(timeout=30.0)
        if leader_port is None:
            cluster.stop()
            pytest.fail("Cluster failed to elect leader")

        yield cluster
    finally:
        cluster.stop()


@pytest.fixture
def client(cluster):
    """Create SDK client connected to test cluster.

    Yields:
        GeoClientSync: Connected client instance
    """
    from archerdb import GeoClientSync, GeoClientConfig

    addresses = cluster.get_addresses()
    # Convert comma-separated ports to host:port format
    address_list = [f"127.0.0.1:{port}" for port in addresses.split(",")]

    config = GeoClientConfig(
        cluster_id=0,
        addresses=address_list,
        connect_timeout_ms=5000,
        request_timeout_ms=30000,
    )

    client = GeoClientSync(config)
    try:
        yield client
    finally:
        client.close()


@pytest.fixture(autouse=True)
def clean_database(client, cluster):
    """Delete all entities before each test for isolation.

    This fixture runs automatically before each test to ensure
    a clean database state. Per CONTEXT.md decision: fresh
    database per test.
    """
    try:
        # Query and delete all existing entities
        result = client.query_latest(limit=10000)
        if result.events:
            entity_ids = [e.entity_id for e in result.events]
            if entity_ids:
                client.delete_entities(entity_ids)
    except Exception:
        # If query fails (empty database), that's fine
        pass

    yield

    # Post-test cleanup is optional but good practice
    try:
        result = client.query_latest(limit=10000)
        if result.events:
            entity_ids = [e.entity_id for e in result.events]
            if entity_ids:
                client.delete_entities(entity_ids)
    except Exception:
        pass
