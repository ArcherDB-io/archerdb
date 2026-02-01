# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Topology test runner for multi-cluster testing.

This module provides the TopologyTestRunner class that orchestrates full
test suites across all cluster topologies (1/3/5/6 nodes).

Per CONTEXT.md:
- Sequential execution: 1-node -> 3-node -> 5-node -> 6-node
- Continue through failures to collect full scope
- Full test suite (14 ops x 6 SDKs) per topology
"""

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional


class TopologyTestRunner:
    """Runs full test suite across all topologies.

    Orchestrates testing of all 14 operations across 6 SDKs for each
    cluster topology (1, 3, 5, 6 nodes).

    Usage:
        runner = TopologyTestRunner(output_dir="reports/topology")

        # Run single topology
        results = runner.run_topology_suite(3)  # 3-node cluster

        # Run full suite
        all_results = runner.run_full_suite()

        # Save results
        runner.save_results(all_results, "full-suite-results.json")
    """

    TOPOLOGIES = [1, 3, 5, 6]

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

    SDKS = ["python", "node", "go", "java", "c", "zig"]

    def __init__(self, output_dir: str = "reports/topology") -> None:
        """Initialize topology test runner.

        Args:
            output_dir: Directory for saving test results.
        """
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.results: Dict[str, Any] = {}

    def run_topology_suite(
        self,
        topology: int,
        sdks: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """Run full test suite for a single topology.

        Args:
            topology: Number of nodes in the cluster.
            sdks: List of SDK names to test (default: all 6).

        Returns:
            Dict with test results per operation per SDK.
        """
        if sdks is None:
            sdks = self.SDKS

        from test_infrastructure.harness import ArcherDBCluster, ClusterConfig

        config = ClusterConfig(node_count=topology)
        results: Dict[str, Any] = {
            "topology": topology,
            "operations": {},
            "errors": [],
            "start_time": datetime.utcnow().isoformat(),
        }

        try:
            with ArcherDBCluster(config) as cluster:
                cluster.wait_for_ready()
                leader_port = cluster.wait_for_leader()

                if leader_port is None:
                    results["errors"].append({
                        "error": "No leader elected",
                        "topology": topology,
                    })
                    return results

                server_url = f"http://127.0.0.1:{leader_port}"

                for operation in self.OPERATIONS:
                    results["operations"][operation] = {}
                    for sdk in sdks:
                        try:
                            success = self._run_operation_test(
                                cluster, sdk, operation, server_url
                            )
                            results["operations"][operation][sdk] = {
                                "passed": success,
                                "error": None,
                            }
                        except Exception as e:
                            results["operations"][operation][sdk] = {
                                "passed": False,
                                "error": str(e),
                            }
                            results["errors"].append({
                                "sdk": sdk,
                                "operation": operation,
                                "error": str(e),
                            })
                            # Continue through failures per CONTEXT.md

        except Exception as e:
            results["errors"].append({
                "error": str(e),
                "topology": topology,
            })

        results["end_time"] = datetime.utcnow().isoformat()
        return results

    def run_full_suite(self) -> Dict[str, Any]:
        """Run complete topology test suite.

        Executes tests sequentially across all topologies (1, 3, 5, 6 nodes).

        Returns:
            Combined results for all topologies.
        """
        all_results: Dict[str, Any] = {
            "start_time": datetime.utcnow().isoformat(),
            "topologies": {},
        }

        for topology in self.TOPOLOGIES:
            print(f"\n{'='*60}")
            print(f"Testing {topology}-node topology")
            print(f"{'='*60}")

            try:
                results = self.run_topology_suite(topology)
                all_results["topologies"][str(topology)] = results
            except Exception as e:
                all_results["topologies"][str(topology)] = {
                    "error": str(e),
                    "topology": topology,
                }
                # Continue to next topology

        all_results["end_time"] = datetime.utcnow().isoformat()
        return all_results

    def _run_operation_test(
        self,
        cluster: Any,
        sdk: str,
        operation: str,
        server_url: str,
    ) -> bool:
        """Run a single operation test via SDK runner.

        Args:
            cluster: The running cluster.
            sdk: SDK name (python, node, go, java, c, zig).
            operation: Operation name.
            server_url: Server URL for the operation.

        Returns:
            True if the test passed, False otherwise.
        """
        # Load fixture from test_infrastructure/fixtures/v1/
        fixture_path = self._get_fixture_path(operation)
        if not fixture_path.exists():
            raise FileNotFoundError(f"Fixture not found: {fixture_path}")

        with open(fixture_path) as f:
            fixture_data = json.load(f)

        # Get input data from fixture
        input_data = fixture_data.get("input", {})

        # Import SDK runner
        runner = self._get_sdk_runner(sdk)

        # Run operation via SDK
        result = runner.run_operation(server_url, operation, input_data)

        # Check for error in result
        if isinstance(result, dict) and result.get("error"):
            return False

        return True

    def _get_fixture_path(self, operation: str) -> Path:
        """Get fixture file path for an operation.

        Args:
            operation: Operation name.

        Returns:
            Path to the fixture JSON file.
        """
        # Find project root
        project_root = Path(__file__).resolve().parent.parent.parent
        fixture_dir = project_root / "test_infrastructure" / "fixtures" / "v1"
        return fixture_dir / f"{operation}.json"

    def _get_sdk_runner(self, sdk: str) -> Any:
        """Get SDK runner module for a specific SDK.

        Args:
            sdk: SDK name.

        Returns:
            SDK runner module with run_operation function.
        """
        from tests.parity_tests import sdk_runners

        runner_map = {
            "python": sdk_runners.python_runner,
            "node": sdk_runners.node_runner,
            "go": sdk_runners.go_runner,
            "java": sdk_runners.java_runner,
            "c": sdk_runners.c_runner,
            "zig": sdk_runners.zig_runner,
        }

        if sdk not in runner_map:
            raise ValueError(f"Unknown SDK: {sdk}")

        return runner_map[sdk]

    def save_results(self, results: Dict[str, Any], filename: str) -> Path:
        """Save results to JSON file.

        Args:
            results: Results dictionary to save.
            filename: Output filename.

        Returns:
            Path to the saved file.
        """
        output_path = self.output_dir / filename
        with open(output_path, "w") as f:
            json.dump(results, f, indent=2)
        return output_path

    def generate_summary(self, results: Dict[str, Any]) -> Dict[str, Any]:
        """Generate summary statistics from results.

        Args:
            results: Full test results.

        Returns:
            Summary with pass/fail counts per topology and SDK.
        """
        summary: Dict[str, Any] = {
            "total_tests": 0,
            "total_passed": 0,
            "total_failed": 0,
            "by_topology": {},
            "by_sdk": {},
            "by_operation": {},
        }

        for topo, topo_results in results.get("topologies", {}).items():
            if "error" in topo_results:
                summary["by_topology"][topo] = {"error": topo_results["error"]}
                continue

            topo_summary = {"passed": 0, "failed": 0}

            for op, op_results in topo_results.get("operations", {}).items():
                for sdk, sdk_result in op_results.items():
                    summary["total_tests"] += 1

                    if sdk_result.get("passed"):
                        summary["total_passed"] += 1
                        topo_summary["passed"] += 1
                    else:
                        summary["total_failed"] += 1
                        topo_summary["failed"] += 1

                    # Track by SDK
                    if sdk not in summary["by_sdk"]:
                        summary["by_sdk"][sdk] = {"passed": 0, "failed": 0}
                    if sdk_result.get("passed"):
                        summary["by_sdk"][sdk]["passed"] += 1
                    else:
                        summary["by_sdk"][sdk]["failed"] += 1

                    # Track by operation
                    if op not in summary["by_operation"]:
                        summary["by_operation"][op] = {"passed": 0, "failed": 0}
                    if sdk_result.get("passed"):
                        summary["by_operation"][op]["passed"] += 1
                    else:
                        summary["by_operation"][op]["failed"] += 1

            summary["by_topology"][topo] = topo_summary

        return summary
