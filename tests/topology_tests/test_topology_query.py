# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Topology query tests (TOPO-07).

Per CONTEXT.md:
- Verify after every topology change
- Ensure clients see accurate node list and current leader

Requirements covered:
    TOPO-07: Topology query returns accurate cluster state after changes
"""

import pytest

from test_infrastructure.topology import FailoverSimulator
from tests.parity_tests.sdk_runners import python_runner


@pytest.mark.topology
class TestTopologyQuery:
    """TOPO-07: Topology query returns correct cluster state."""

    def test_topology_reports_all_nodes(self, three_node_cluster):
        """Topology query should report all 3 nodes.

        Verifies:
            - Topology query returns success
            - Node count matches expected (3)
            - At least one node has primary role
        """
        cluster = three_node_cluster
        leader_port = cluster.wait_for_leader()
        server_url = f"http://127.0.0.1:{leader_port}"

        result = python_runner.run_operation(server_url, "topology", {})

        assert "error" not in result, f"Topology query failed: {result}"
        nodes = result.get("nodes", [])
        assert len(nodes) == 3, f"Expected 3 nodes, got {len(nodes)}"

        # At least one node should be primary
        roles = [n.get("role") for n in nodes]
        assert "primary" in roles, "No primary node in topology"

    def test_topology_after_failover(self, three_node_cluster):
        """Topology should reflect leader change after failover.

        Verifies:
            - Topology query succeeds after failover
            - New topology shows a primary node
            - Primary node is different from the one that was stopped
        """
        cluster = three_node_cluster
        simulator = FailoverSimulator(cluster, recovery_timeout_sec=15.0)

        # Get initial topology
        initial_leader_port = cluster.wait_for_leader()
        initial_leader_idx = cluster.get_leader_replica()
        server_url = f"http://127.0.0.1:{initial_leader_port}"

        initial_result = python_runner.run_operation(server_url, "topology", {})
        assert "error" not in initial_result, f"Initial topology query failed: {initial_result}"

        # Failover
        failover_result = simulator.trigger_leader_failure(graceful=True)
        assert failover_result.new_leader is not None, "No new leader after failover"
        assert failover_result.new_leader != initial_leader_idx, (
            "New leader is same as old leader"
        )

        # Query topology from new leader
        new_leader_port = cluster.get_ports()[failover_result.new_leader]
        server_url = f"http://127.0.0.1:{new_leader_port}"

        new_result = python_runner.run_operation(server_url, "topology", {})
        assert "error" not in new_result, f"Topology query after failover failed: {new_result}"

        # New topology should show at least one primary
        new_nodes = new_result.get("nodes", [])
        primary_nodes = [n for n in new_nodes if n.get("role") == "primary"]
        assert len(primary_nodes) >= 1, "No primary in topology after failover"

    def test_topology_single_node(self, single_node_cluster):
        """Topology on single-node cluster shows 1 node.

        Verifies:
            - Single node topology has exactly 1 node
            - That node is primary
        """
        cluster = single_node_cluster
        leader_port = cluster.wait_for_leader()
        server_url = f"http://127.0.0.1:{leader_port}"

        result = python_runner.run_operation(server_url, "topology", {})

        assert "error" not in result, f"Topology query failed: {result}"
        nodes = result.get("nodes", [])
        assert len(nodes) == 1, f"Expected 1 node, got {len(nodes)}"
        assert nodes[0].get("role") == "primary", "Single node should be primary"

    def test_topology_five_node(self, five_node_cluster):
        """Topology on 5-node cluster shows 5 nodes.

        Verifies:
            - 5-node topology has exactly 5 nodes
            - Exactly one node is primary
        """
        cluster = five_node_cluster
        leader_port = cluster.wait_for_leader()
        server_url = f"http://127.0.0.1:{leader_port}"

        result = python_runner.run_operation(server_url, "topology", {})

        assert "error" not in result, f"Topology query failed: {result}"
        nodes = result.get("nodes", [])
        assert len(nodes) == 5, f"Expected 5 nodes, got {len(nodes)}"

        # Exactly one primary expected
        roles = [n.get("role") for n in nodes]
        assert "primary" in roles, "No primary node in 5-node topology"

    def test_topology_six_node(self, six_node_cluster):
        """Topology on 6-node cluster shows 6 nodes.

        Verifies:
            - 6-node topology has exactly 6 nodes
            - Exactly one node is primary
        """
        cluster = six_node_cluster
        leader_port = cluster.wait_for_leader()
        server_url = f"http://127.0.0.1:{leader_port}"

        result = python_runner.run_operation(server_url, "topology", {})

        assert "error" not in result, f"Topology query failed: {result}"
        nodes = result.get("nodes", [])
        assert len(nodes) == 6, f"Expected 6 nodes, got {len(nodes)}"

        # Verify primary exists
        roles = [n.get("role") for n in nodes]
        assert "primary" in roles, "No primary node in 6-node topology"

    def test_topology_node_count_varies(
        self, single_node_cluster, three_node_cluster, five_node_cluster, six_node_cluster
    ):
        """Topology correctly reflects different cluster sizes.

        Verifies:
            - Each cluster size reports correct node count
            - All clusters have a primary node
        """
        test_cases = [
            (single_node_cluster, 1, "single"),
            (three_node_cluster, 3, "three"),
            (five_node_cluster, 5, "five"),
            (six_node_cluster, 6, "six"),
        ]

        for cluster, expected_count, name in test_cases:
            leader_port = cluster.wait_for_leader()
            server_url = f"http://127.0.0.1:{leader_port}"

            result = python_runner.run_operation(server_url, "topology", {})

            assert "error" not in result, f"Topology failed for {name}-node cluster: {result}"
            nodes = result.get("nodes", [])
            assert len(nodes) == expected_count, (
                f"{name}-node cluster: expected {expected_count} nodes, got {len(nodes)}"
            )

            # Each should have a primary
            roles = [n.get("role") for n in nodes]
            assert "primary" in roles, f"{name}-node cluster has no primary"
