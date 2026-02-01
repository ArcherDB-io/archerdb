# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Pytest fixtures for topology tests.

Provides cluster fixtures for 1, 3, 5, 6 node topologies.
Uses ARCHERDB_INTEGRATION=1 to enable integration tests.

Fixtures:
    skip_if_not_integration: Skip tests if ARCHERDB_INTEGRATION not set
    single_node_cluster: 1-node cluster for TOPO-01
    three_node_cluster: 3-node cluster for TOPO-02
    five_node_cluster: 5-node cluster for TOPO-03
    six_node_cluster: 6-node cluster for TOPO-04
    partition_capable: Skip if iptables not available
"""

import os

import pytest

from test_infrastructure.harness import ArcherDBCluster, ClusterConfig


def pytest_configure(config):
    """Register topology marker."""
    config.addinivalue_line("markers", "topology: mark test as topology test")


@pytest.fixture(scope="module")
def skip_if_not_integration():
    """Skip if ARCHERDB_INTEGRATION is not set."""
    if not os.getenv("ARCHERDB_INTEGRATION"):
        pytest.skip("Set ARCHERDB_INTEGRATION=1 to run topology tests")


@pytest.fixture
def single_node_cluster(skip_if_not_integration):
    """1-node cluster for TOPO-01.

    Yields:
        ArcherDBCluster: Running single-node cluster.
    """
    config = ClusterConfig(node_count=1)
    with ArcherDBCluster(config) as cluster:
        cluster.wait_for_ready()
        cluster.wait_for_leader()
        yield cluster


@pytest.fixture
def three_node_cluster(skip_if_not_integration):
    """3-node cluster for TOPO-02.

    Yields:
        ArcherDBCluster: Running 3-node cluster.
    """
    config = ClusterConfig(node_count=3)
    with ArcherDBCluster(config) as cluster:
        cluster.wait_for_ready()
        cluster.wait_for_leader()
        yield cluster


@pytest.fixture
def five_node_cluster(skip_if_not_integration):
    """5-node cluster for TOPO-03.

    Yields:
        ArcherDBCluster: Running 5-node cluster.
    """
    config = ClusterConfig(node_count=5)
    with ArcherDBCluster(config) as cluster:
        cluster.wait_for_ready()
        cluster.wait_for_leader()
        yield cluster


@pytest.fixture
def six_node_cluster(skip_if_not_integration):
    """6-node cluster for TOPO-04.

    Yields:
        ArcherDBCluster: Running 6-node cluster.
    """
    config = ClusterConfig(node_count=6)
    with ArcherDBCluster(config) as cluster:
        cluster.wait_for_ready()
        cluster.wait_for_leader()
        yield cluster


@pytest.fixture
def partition_capable(skip_if_not_integration):
    """Skip if iptables not available (requires sudo).

    Raises:
        pytest.skip: If NetworkPartitioner is not available or
            SKIP_PARTITION_TESTS is set.
    """
    from test_infrastructure.topology import NetworkPartitioner

    if not NetworkPartitioner.is_available():
        pytest.skip("Requires sudo privileges for network partition tests")
    if os.getenv("SKIP_PARTITION_TESTS"):
        pytest.skip("SKIP_PARTITION_TESTS is set")
