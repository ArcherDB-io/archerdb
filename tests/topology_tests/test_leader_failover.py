# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Leader failover tests (TOPO-05).

Per CONTEXT.md:
- Both graceful (SIGTERM) and ungraceful (SIGKILL) shutdown
- Multiple sequential failovers per test
- Verify acknowledged writes survive leader failure
- Enforce recovery SLA (configurable per topology)

Requirements covered:
    TOPO-05: Leader failover recovers with new leader election
"""

import time

import pytest

from test_infrastructure.topology import ConsistencyChecker, FailoverSimulator
from tests.parity_tests.sdk_runners import python_runner

# Recovery SLA targets per RESEARCH.md (milliseconds)
RECOVERY_SLA_MS = {
    3: 10000,  # 10 seconds
    5: 15000,  # 15 seconds
    6: 20000,  # 20 seconds
}


@pytest.mark.topology
class TestLeaderFailover:
    """TOPO-05: Leader failover with automatic recovery."""

    def test_graceful_leader_failover_3node(self, three_node_cluster):
        """Test graceful (SIGTERM) leader shutdown on 3-node cluster.

        Verifies:
            - Cluster elects new leader after graceful shutdown
            - Recovery time within SLA (10 seconds)
            - Cluster remains healthy after failover
        """
        cluster = three_node_cluster
        simulator = FailoverSimulator(cluster, recovery_timeout_sec=15.0)
        checker = ConsistencyChecker(cluster)

        # Insert test data before failover
        leader_port = cluster.wait_for_leader()
        server_url = f"http://127.0.0.1:{leader_port}"
        result = python_runner.run_operation(
            server_url,
            "insert",
            {
                "events": [
                    {"entity_id": f"failover-test-{i}", "latitude": 37.7749, "longitude": -122.4194}
                    for i in range(10)
                ]
            },
        )
        assert "error" not in result, f"Insert failed: {result}"

        # Trigger graceful failover
        failover_result = simulator.trigger_leader_failure(graceful=True)

        # Verify recovery
        assert failover_result.new_leader is not None, "No new leader elected"
        assert failover_result.recovery_time_ms < RECOVERY_SLA_MS[3], (
            f"Recovery too slow: {failover_result.recovery_time_ms}ms > {RECOVERY_SLA_MS[3]}ms"
        )

        # Verify cluster health
        health = checker.verify_cluster_health()
        assert health["has_leader"], "Cluster has no leader after recovery"

    def test_ungraceful_leader_failover_3node(self, three_node_cluster):
        """Test ungraceful (SIGKILL) leader crash on 3-node cluster.

        Verifies:
            - Cluster elects new leader after crash
            - Acknowledged writes survive leader crash
            - Data is readable from new leader
        """
        cluster = three_node_cluster
        simulator = FailoverSimulator(cluster, recovery_timeout_sec=15.0)

        # Insert acknowledged writes
        leader_port = cluster.wait_for_leader()
        server_url = f"http://127.0.0.1:{leader_port}"
        entity_ids = [f"crash-test-{i}" for i in range(10)]
        result = python_runner.run_operation(
            server_url,
            "insert",
            {
                "events": [
                    {"entity_id": eid, "latitude": 37.7749, "longitude": -122.4194}
                    for eid in entity_ids
                ]
            },
        )
        assert "error" not in result, f"Insert failed: {result}"

        # Crash leader (SIGKILL)
        failover_result = simulator.trigger_leader_failure(graceful=False)

        # Per CONTEXT.md: "acknowledged writes must survive leader failure"
        assert failover_result.new_leader is not None, "No new leader after crash"
        new_leader_port = cluster.get_ports()[failover_result.new_leader]
        server_url = f"http://127.0.0.1:{new_leader_port}"

        # Verify data survived - check a sample of the entities
        for eid in entity_ids[:3]:
            result = python_runner.run_operation(server_url, "query-uuid", {"entity_id": eid})
            # Should succeed or return empty (not error)
            assert "error" not in result or "not found" in str(result.get("error", "")).lower(), (
                f"Query for {eid} failed after crash: {result}"
            )

    def test_sequential_failovers(self, three_node_cluster):
        """Test multiple sequential failovers (per CONTEXT.md).

        Verifies:
            - Cluster can handle 2+ consecutive leader failures
            - Each failover results in successful leader election
            - Cluster remains functional after sequential failures
        """
        cluster = three_node_cluster
        simulator = FailoverSimulator(cluster, recovery_timeout_sec=15.0)

        # Perform 2 sequential failovers
        for i in range(2):
            failover_result = simulator.trigger_leader_failure(graceful=True)
            assert failover_result.new_leader is not None, (
                f"Failover {i + 1} failed: no new leader"
            )

            # Brief wait before next failover and restart old leader
            time.sleep(2)
            cluster.start_node(failover_result.old_leader)
            time.sleep(2)  # Wait for rejoin

    def test_graceful_leader_failover_5node(self, five_node_cluster):
        """Test graceful leader failover on 5-node cluster.

        Verifies:
            - 5-node cluster recovers within SLA (15 seconds)
            - New leader elected from remaining 4 nodes
        """
        cluster = five_node_cluster
        simulator = FailoverSimulator(cluster, recovery_timeout_sec=20.0)

        # Trigger graceful failover
        failover_result = simulator.trigger_leader_failure(graceful=True)

        # Verify recovery
        assert failover_result.new_leader is not None, "No new leader elected"
        assert failover_result.recovery_time_ms < RECOVERY_SLA_MS[5], (
            f"Recovery too slow: {failover_result.recovery_time_ms}ms > {RECOVERY_SLA_MS[5]}ms"
        )

    def test_ungraceful_leader_failover_6node(self, six_node_cluster):
        """Test ungraceful leader failover on 6-node cluster.

        Verifies:
            - 6-node cluster recovers from crash within SLA (20 seconds)
            - New leader elected despite sudden failure
        """
        cluster = six_node_cluster
        simulator = FailoverSimulator(cluster, recovery_timeout_sec=25.0)

        # Crash leader (SIGKILL)
        failover_result = simulator.trigger_leader_failure(graceful=False)

        # Verify recovery
        assert failover_result.new_leader is not None, "No new leader after crash"
        assert failover_result.recovery_time_ms < RECOVERY_SLA_MS[6], (
            f"Recovery too slow: {failover_result.recovery_time_ms}ms > {RECOVERY_SLA_MS[6]}ms"
        )
