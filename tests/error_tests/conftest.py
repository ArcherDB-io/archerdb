# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Pytest configuration and fixtures for error handling tests.

This module provides fixtures for:
- ArcherDB cluster lifecycle (module-scoped)
- Client creation and cleanup
- Non-existent server configurations for connection error tests
- Integration test skip markers

Design decisions (per 14-CONTEXT.md):
- Verify error CODES, not message text
- Tests should be deterministic
- Use native error types (ArcherDBError subclasses)
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# Add project paths for imports
PROJECT_ROOT = Path(__file__).parent.parent.parent
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
            if "integration" in item.keywords:
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

    cluster_instance = ArcherDBCluster(config)
    cluster_instance.start()

    try:
        # Wait for cluster to be ready
        if not cluster_instance.wait_for_ready(timeout=60.0):
            cluster_instance.stop()
            pytest.fail("Cluster failed to become ready")

        # Wait for leader (needed for writes)
        leader_port = cluster_instance.wait_for_leader(timeout=30.0)
        if leader_port is None:
            cluster_instance.stop()
            pytest.fail("Cluster failed to elect leader")

        yield cluster_instance
    finally:
        cluster_instance.stop()


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

    client_instance = GeoClientSync(config)
    try:
        yield client_instance
    finally:
        client_instance.close()


@pytest.fixture
def nonexistent_server_config():
    """Configuration pointing to a server that doesn't exist.

    Returns:
        GeoClientConfig: Config with address 127.0.0.1:9999 (no server)
    """
    from archerdb import GeoClientConfig, RetryConfig

    return GeoClientConfig(
        cluster_id=0,
        addresses=["127.0.0.1:9999"],  # Non-existent server
        connect_timeout_ms=1000,  # Short timeout for faster test
        request_timeout_ms=2000,
        retry=RetryConfig(
            enabled=True,
            max_retries=0,  # No retries for connection tests
        ),
    )


@pytest.fixture
def timeout_server_config():
    """Configuration pointing to a non-routable IP that will timeout.

    Returns:
        GeoClientConfig: Config with address 10.255.255.1:9999 (black-hole IP)
    """
    from archerdb import GeoClientConfig, RetryConfig

    return GeoClientConfig(
        cluster_id=0,
        addresses=["10.255.255.1:9999"],  # Non-routable IP (timeout)
        connect_timeout_ms=1000,  # Short timeout for test speed
        request_timeout_ms=2000,
        retry=RetryConfig(
            enabled=True,
            max_retries=0,  # No retries for timeout tests
        ),
    )


@pytest.fixture(autouse=True)
def clean_database(request, cluster):
    """Delete all entities before each integration test for isolation.

    Only runs for integration tests that use the cluster fixture.
    """
    # Skip cleanup for non-integration tests or tests without cluster
    if not RUN_INTEGRATION:
        yield
        return

    # Only clean if this test uses the client fixture
    if "client" not in request.fixturenames:
        yield
        return

    # Get client from request
    try:
        from archerdb import GeoClientSync, GeoClientConfig

        addresses = cluster.get_addresses()
        address_list = [f"127.0.0.1:{port}" for port in addresses.split(",")]

        config = GeoClientConfig(
            cluster_id=0,
            addresses=address_list,
            connect_timeout_ms=5000,
            request_timeout_ms=30000,
        )

        with GeoClientSync(config) as cleanup_client:
            # Query and delete all existing entities
            result = cleanup_client.query_latest(limit=10000)
            if result.events:
                entity_ids = [e.entity_id for e in result.events]
                if entity_ids:
                    cleanup_client.delete_entities(entity_ids)
    except Exception:
        # If cleanup fails, continue anyway
        pass

    yield

    # Post-test cleanup is optional
    try:
        from archerdb import GeoClientSync, GeoClientConfig

        addresses = cluster.get_addresses()
        address_list = [f"127.0.0.1:{port}" for port in addresses.split(",")]

        config = GeoClientConfig(
            cluster_id=0,
            addresses=address_list,
            connect_timeout_ms=5000,
            request_timeout_ms=30000,
        )

        with GeoClientSync(config) as cleanup_client:
            result = cleanup_client.query_latest(limit=10000)
            if result.events:
                entity_ids = [e.entity_id for e in result.events]
                if entity_ids:
                    cleanup_client.delete_entities(entity_ids)
    except Exception:
        pass
