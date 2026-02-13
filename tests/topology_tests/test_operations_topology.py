# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Test all 14 operations across all topologies (TOPO-01 to TOPO-04).

Uses pytest parametrization to test each operation on each topology.
Per CONTEXT.md: Continue through failures to collect full scope.

Requirements covered:
    TOPO-01: All 14 operations pass on single-node cluster
    TOPO-02: All 14 operations pass on 3-node cluster
    TOPO-03: All 14 operations pass on 5-node cluster
    TOPO-04: All 14 operations pass on 6-node cluster
"""

import json
from pathlib import Path

import pytest

from tests.parity_tests.sdk_runners import python_runner

# All 14 operations to test
OPERATIONS = [
    "insert",
    "upsert",
    "delete",
    "query-uuid",
    "query-uuid-batch",
    "query-radius",
    "query-polygon",
    "query-latest",
    "ping",
    "status",
    "topology",
    "ttl-set",
    "ttl-extend",
    "ttl-clear",
]

# Fixtures directory path
FIXTURES_DIR = (
    Path(__file__).parent.parent.parent / "test_infrastructure" / "fixtures" / "v1"
)


def load_fixture(operation: str) -> dict:
    """Load fixture data for operation.

    Args:
        operation: Operation name (e.g., 'query-radius').

    Returns:
        Dict with fixture data, or empty dict if no fixture exists.
    """
    fixture_file = None
    for fixture_name in (operation.replace("-", "_"), operation):
        candidate = FIXTURES_DIR / f"{fixture_name}.json"
        if candidate.exists():
            fixture_file = candidate
            break

    if fixture_file is None:
        # Return minimal fixture for operations without fixture files
        return {}

    with open(fixture_file) as f:
        data = json.load(f)

    # Extract the test case input (use first smoke test case if available)
    test_cases = data.get("test_cases", data.get("cases", []))
    if test_cases:
        # Prefer smoke-tagged test cases for quick verification
        for tc in test_cases:
            if "smoke" in tc.get("tags", []):
                return tc.get("input", {})
        # Fall back to first test case
        return test_cases[0].get("input", {})

    return data.get("input", {})


def _run_operation_with_setup(cluster, operation: str) -> dict:
    """Run operation with any required setup data.

    Some operations require pre-existing data. This function handles
    the setup automatically.

    Args:
        cluster: ArcherDBCluster instance.
        operation: Operation name.

    Returns:
        Operation result dict.
    """
    leader_port = cluster.wait_for_leader()
    server_url = f"http://127.0.0.1:{leader_port}"
    input_data = load_fixture(operation)

    # Operations that need setup data first
    if operation in ("query-uuid", "query-uuid-batch", "delete", "ttl-set", "ttl-extend", "ttl-clear"):
        # Insert test data before querying/deleting/TTL operations
        entity_id = input_data.get("entity_id") or f"test-{operation}"
        entity_ids = input_data.get("entity_ids", [entity_id])

        setup_events = [
            {"entity_id": eid, "latitude": 37.7749, "longitude": -122.4194}
            for eid in entity_ids
        ]
        python_runner.run_operation(server_url, "insert", {"events": setup_events})

        # For single entity operations, ensure entity_id is set
        if operation == "query-uuid" and "entity_id" not in input_data:
            input_data["entity_id"] = entity_id
        elif operation == "query-uuid-batch" and "entity_ids" not in input_data:
            input_data["entity_ids"] = entity_ids
        elif operation == "delete" and "entity_ids" not in input_data:
            input_data["entity_ids"] = entity_ids
        elif operation in ("ttl-set", "ttl-extend", "ttl-clear"):
            if "entity_id" not in input_data:
                input_data["entity_id"] = entity_id
            if operation == "ttl-set" and "ttl_seconds" not in input_data:
                input_data["ttl_seconds"] = 3600
            elif operation == "ttl-extend" and "extension_seconds" not in input_data:
                input_data["extension_seconds"] = 1800

    return python_runner.run_operation(server_url, operation, input_data)


@pytest.mark.topology
class TestSingleNodeOperations:
    """TOPO-01: All operations pass on single-node cluster."""

    @pytest.mark.parametrize("operation", OPERATIONS)
    def test_operation(self, single_node_cluster, operation):
        """Test operation on single-node cluster.

        Args:
            single_node_cluster: 1-node cluster fixture.
            operation: Operation name from OPERATIONS list.
        """
        result = _run_operation_with_setup(single_node_cluster, operation)

        assert "error" not in result or result.get("error") is None, (
            f"Operation {operation} failed: {result.get('error')}"
        )


@pytest.mark.topology
class TestThreeNodeOperations:
    """TOPO-02: All operations pass on 3-node cluster."""

    @pytest.mark.parametrize("operation", OPERATIONS)
    def test_operation(self, three_node_cluster, operation):
        """Test operation on 3-node cluster.

        Args:
            three_node_cluster: 3-node cluster fixture.
            operation: Operation name from OPERATIONS list.
        """
        result = _run_operation_with_setup(three_node_cluster, operation)

        assert "error" not in result or result.get("error") is None, (
            f"Operation {operation} failed: {result.get('error')}"
        )


@pytest.mark.topology
class TestFiveNodeOperations:
    """TOPO-03: All operations pass on 5-node cluster."""

    @pytest.mark.parametrize("operation", OPERATIONS)
    def test_operation(self, five_node_cluster, operation):
        """Test operation on 5-node cluster.

        Args:
            five_node_cluster: 5-node cluster fixture.
            operation: Operation name from OPERATIONS list.
        """
        result = _run_operation_with_setup(five_node_cluster, operation)

        assert "error" not in result or result.get("error") is None, (
            f"Operation {operation} failed: {result.get('error')}"
        )


@pytest.mark.topology
class TestSixNodeOperations:
    """TOPO-04: All operations pass on 6-node cluster."""

    @pytest.mark.parametrize("operation", OPERATIONS)
    def test_operation(self, six_node_cluster, operation):
        """Test operation on 6-node cluster.

        Args:
            six_node_cluster: 6-node cluster fixture.
            operation: Operation name from OPERATIONS list.
        """
        result = _run_operation_with_setup(six_node_cluster, operation)

        assert "error" not in result or result.get("error") is None, (
            f"Operation {operation} failed: {result.get('error')}"
        )
