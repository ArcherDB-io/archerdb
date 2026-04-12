# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Cross-SDK parity test runner.

Runs identical operations across all 5 SDKs and verifies results match.
Per CONTEXT.md: Python SDK as golden reference, server as ultimate truth.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Any, Dict, List, Optional

# Add project root to path for imports
PROJECT_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from tests.parity_tests.parity_verifier import ParityVerifier, ParityResult
from tests.parity_tests.sdk_runners import (
    python_runner,
    node_runner,
    go_runner,
    java_runner,
    c_runner,
)

# All SDK runners with consistent interface
SDK_RUNNERS: Dict[str, Any] = {
    "python": python_runner,
    "node": node_runner,
    "go": go_runner,
    "java": java_runner,
    "c": c_runner,
}

# All 14 operations per CONTEXT.md (14 ops x 5 SDKs = 70 cells)
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

if TYPE_CHECKING:
    from test_infrastructure.harness.cluster import ArcherDBCluster


def load_fixture(operation: str) -> Optional[Dict[str, Any]]:
    """Load fixture for specified operation.

    Loads from test_infrastructure/fixtures/v1/ directory,
    converting operation name from kebab-case to snake_case.

    Args:
        operation: Operation name (e.g., 'query-radius')

    Returns:
        Fixture dict with test_cases, or None if not found
    """
    fixture_dir = PROJECT_ROOT / "test_infrastructure" / "fixtures" / "v1"
    # Support both kebab-case and snake_case fixture file names.
    candidate_names = [f"{operation}.json", f"{operation.replace('-', '_')}.json"]
    fixture_path = None
    for candidate in candidate_names:
        path = fixture_dir / candidate
        if path.exists():
            fixture_path = path
            break

    if fixture_path is None:
        # Try edge case fixtures
        edge_case_dir = Path(__file__).parent / "fixtures" / "edge_cases"
        for edge_file in edge_case_dir.glob("*.json"):
            try:
                with open(edge_file) as f:
                    data = json.load(f)
                    # Check if this fixture has test cases for our operation
                    test_cases = data.get("test_cases", data.get("cases", []))
                    for case in test_cases:
                        if case.get("operation") == operation:
                            if "cases" in data and "test_cases" not in data:
                                data["test_cases"] = data["cases"]
                            return data
            except (json.JSONDecodeError, OSError):
                continue
        return None

    try:
        with open(fixture_path) as f:
            data = json.load(f)
            # Normalize fixture format - wrap cases as test_cases if needed
            if "cases" in data and "test_cases" not in data:
                data["test_cases"] = data["cases"]
            return data
    except (json.JSONDecodeError, OSError):
        return None


def _requested_node_count(input_data: Dict[str, Any], default_nodes: int) -> int:
    """Resolve the cluster size requested by a fixture case."""
    cluster_config = input_data.get("cluster_config")
    if isinstance(cluster_config, dict):
        node_count = cluster_config.get("node_count")
        if isinstance(node_count, int) and node_count > 0:
            return node_count
    return default_nodes


def _case_requires_ephemeral_cluster(
    input_data: Dict[str, Any],
    default_nodes: int,
) -> bool:
    """Return True when a case needs its own local cluster shape/state."""
    setup = input_data.get("setup")
    if isinstance(setup, dict) and setup:
        return True
    return _requested_node_count(input_data, default_nodes) != default_nodes


def _start_local_cluster(
    node_count: int,
    base_port: int = 0,
    require_ready: bool = True,
) -> tuple["ArcherDBCluster", str]:
    """Start a local test cluster and return it plus a usable server URL."""
    from test_infrastructure.harness.cluster import ArcherDBCluster, ClusterConfig

    cluster = ArcherDBCluster(
        ClusterConfig(
            node_count=node_count,
            base_port=base_port,
            startup_timeout=_startup_timeout_for_nodes(node_count),
        )
    )
    cluster.start()
    if require_ready and not cluster.wait_for_ready(timeout=cluster.config.startup_timeout):
        cluster.stop()
        raise RuntimeError("Cluster failed to become ready")

    server_url = _cluster_server_url(cluster)
    return cluster, server_url


def _cluster_server_url(cluster: "ArcherDBCluster") -> str:
    """Resolve a healthy SDK endpoint for a running cluster."""
    leader_port = cluster.wait_for_leader(timeout=30)
    if leader_port:
        return f"http://127.0.0.1:{leader_port}"

    for replica_idx, port in enumerate(cluster.get_ports()):
        if cluster.is_node_running(replica_idx):
            return f"http://127.0.0.1:{port}"

    raise RuntimeError("Cluster has no reachable ports")


def _startup_timeout_for_nodes(node_count: int) -> float:
    """Return a practical startup timeout for the requested cluster size."""
    if node_count <= 1:
        return 60.0
    if node_count <= 3:
        return 120.0
    return 180.0


def _refresh_packaged_sdk_clients(selected_sdks: Optional[List[str]], verbose: bool) -> None:
    """Refresh packaged native SDK artifacts from current source before parity runs.

    Node, Go, and Java parity runners rely on checked-in packaged native artifacts.
    Rebuild them up front so parity validates the current commit rather than stale binaries.
    """
    if os.environ.get("ARCHERDB_PARITY_SKIP_CLIENT_REFRESH") == "1":
        return

    requested_sdks = set(selected_sdks or SDK_RUNNERS.keys())
    needs_refresh = requested_sdks.intersection({"node", "go", "java"})
    if not needs_refresh:
        return

    zig_exe = PROJECT_ROOT / "zig" / "zig"
    if not zig_exe.exists():
        raise RuntimeError(f"Missing Zig executable for SDK refresh: {zig_exe}")

    steps: List[str] = []
    if "node" in needs_refresh:
        steps.append("clients:node")
    if "go" in needs_refresh:
        steps.append("clients:go")
    if "java" in needs_refresh:
        steps.append("clients:java")

    cmd = [str(zig_exe), "build", *steps, "-Drelease"]
    if verbose:
        print(f"Refreshing packaged SDK clients: {' '.join(steps)}")

    result = subprocess.run(
        cmd,
        cwd=str(PROJECT_ROOT),
        text=True,
        capture_output=True,
        timeout=900,
        env=os.environ.copy(),
    )
    if result.returncode != 0:
        output = (result.stdout or "") + (result.stderr or "")
        raise RuntimeError(
            "Failed to refresh packaged SDK clients before parity run:\n"
            f"{output.strip()}"
        )


def _wait_for_sdk_endpoint(server_url: str, timeout: float = 60.0) -> None:
    """Wait until the binary SDK endpoint accepts a trivial ping."""
    from archerdb import GeoClientConfig, GeoClientSync
    import time

    address = server_url.replace("http://", "").replace("https://", "").split("/", 1)[0]
    deadline = time.time() + timeout
    last_error: Optional[str] = None
    while time.time() < deadline:
        try:
            config = GeoClientConfig(
                cluster_id=0,
                addresses=[address],
                connect_timeout_ms=1000,
                request_timeout_ms=1000,
            )
            with GeoClientSync(config) as client:
                if client.ping():
                    return
        except Exception as exc:  # pragma: no cover - transient bring-up probing
            last_error = str(exc)
        time.sleep(0.5)

    raise RuntimeError(
        "Cluster SDK endpoint failed to become queryable"
        + (f": {last_error}" if last_error else "")
    )


def _wait_for_topology_endpoint(server_url: str, timeout: float = 60.0) -> None:
    """Wait until the topology operation returns real shard/address data."""
    from archerdb import GeoClientConfig, GeoClientSync
    import time

    address = server_url.replace("http://", "").replace("https://", "").split("/", 1)[0]
    deadline = time.time() + timeout
    last_error: Optional[str] = None

    while time.time() < deadline:
        try:
            config = GeoClientConfig(
                cluster_id=0,
                addresses=[address],
                connect_timeout_ms=1000,
                request_timeout_ms=1000,
            )
            with GeoClientSync(config) as client:
                topology = client.get_topology()
                shards = getattr(topology, "shards", [])
                if shards and any(
                    getattr(shard, "primary", "").strip()
                    or any(replica.strip() for replica in getattr(shard, "replicas", []))
                    for shard in shards
                ):
                    return
                last_error = "topology response did not include shard addresses yet"
        except Exception as exc:  # pragma: no cover - transient bring-up probing
            last_error = str(exc)
        time.sleep(0.5)

    raise RuntimeError(
        "Cluster topology endpoint failed to become queryable"
        + (f": {last_error}" if last_error else "")
    )


def _apply_case_cluster_setup(
    cluster: "ArcherDBCluster",
    setup: Optional[Dict[str, Any]],
    verbose: bool = False,
) -> None:
    """Apply topology-level fixture setup to a local cluster."""
    if not isinstance(setup, dict):
        return

    stop_node = setup.get("stop_node")
    if isinstance(stop_node, int):
        if verbose:
            print(f"    Setup: stop_node={stop_node}")
        cluster.stop_node(stop_node, graceful=False)

    if setup.get("trigger_leader_failover"):
        from test_infrastructure.topology.failover import FailoverSimulator

        if verbose:
            print("    Setup: trigger_leader_failover")

        simulator = FailoverSimulator(cluster, recovery_timeout_sec=30.0)
        result = simulator.trigger_leader_failure(graceful=False)
        if result.new_leader is None:
            raise RuntimeError("Topology setup failed to elect a new leader")


def run_parity_tests(
    server_url: str,
    operations: Optional[List[str]] = None,
    sdks: Optional[List[str]] = None,
    verbose: bool = False,
    start_local_cluster: bool = False,
    cluster_port: int = 0,
    default_cluster_nodes: int = 1,
) -> List[ParityResult]:
    """Run parity tests across all SDKs for all operations.

    Args:
        server_url: ArcherDB server URL (e.g., 'http://127.0.0.1:7000')
        operations: List of operations to test (default: all 14)
        sdks: List of SDKs to test (default: all 5)
        verbose: Print progress information
        start_local_cluster: Start managed local clusters for parity execution
        cluster_port: Base port for the default managed cluster
        default_cluster_nodes: Node count for the default managed cluster

    Returns:
        List of ParityResult objects with pass/fail status
    """
    operations = operations or OPERATIONS
    sdks = sdks or list(SDK_RUNNERS.keys())

    results: List[ParityResult] = []
    default_cluster: Optional["ArcherDBCluster"] = None
    active_server_url = server_url

    def ensure_default_cluster() -> str:
        nonlocal default_cluster
        nonlocal active_server_url

        if default_cluster is None:
            default_cluster, active_server_url = _start_local_cluster(
                default_cluster_nodes,
                base_port=cluster_port,
            )
        return active_server_url

    try:
        for op in operations:
            if verbose:
                print(f"Testing operation: {op}")

            fixture = load_fixture(op)
            if not fixture:
                if verbose:
                    print(f"  Warning: No fixture for {op}")
                continue

            test_cases = fixture.get("test_cases", [])
            if not test_cases:
                if verbose:
                    print(f"  Warning: No test cases for {op}")
                continue

            for test_case in test_cases:
                input_data = test_case.get("input", {})
                case_name = test_case.get("name", "unnamed")
                case_cluster: Optional["ArcherDBCluster"] = None

                if verbose:
                    print(f"  Case: {case_name}")

                try:
                    case_server_url = server_url
                    if start_local_cluster:
                        if _case_requires_ephemeral_cluster(input_data, default_cluster_nodes):
                            topology_case = op == "topology"
                            case_cluster, case_server_url = _start_local_cluster(
                                _requested_node_count(input_data, default_cluster_nodes),
                                base_port=0,
                                require_ready=not topology_case,
                            )
                            if topology_case:
                                _wait_for_topology_endpoint(
                                    case_server_url,
                                    timeout=_startup_timeout_for_nodes(
                                        _requested_node_count(input_data, default_cluster_nodes)
                                    ),
                                )
                            _apply_case_cluster_setup(
                                case_cluster,
                                input_data.get("setup"),
                                verbose=verbose,
                            )
                            case_server_url = _cluster_server_url(case_cluster)
                            if topology_case:
                                _wait_for_topology_endpoint(
                                    case_server_url,
                                    timeout=_startup_timeout_for_nodes(
                                        _requested_node_count(input_data, default_cluster_nodes)
                                    ),
                                )
                        else:
                            case_server_url = ensure_default_cluster()

                    verifier = ParityVerifier(case_server_url)
                    result = verifier.verify_parity(op, input_data, sdks, case_name)
                except Exception as exc:
                    result = ParityResult(
                        operation=op,
                        test_case=case_name,
                        passed=False,
                        sdk_results={},
                        mismatches=[],
                        error=str(exc),
                    )
                finally:
                    if case_cluster is not None:
                        case_cluster.stop()

                results.append(result)

                if verbose:
                    status = "PASS" if result.passed else "FAIL"
                    print(f"    Result: {status}")
                    if result.error:
                        print(f"      Error: {result.error}")
                    if not result.passed and result.mismatches:
                        for mismatch in result.mismatches:
                            print(f"      Mismatch: {mismatch.get('sdk', 'unknown')}")
    finally:
        if default_cluster is not None:
            default_cluster.stop()

    return results


def main() -> int:
    """CLI entry point for parity test runner.

    Returns:
        Exit code (0 for success, 1 for failures)
    """
    parser = argparse.ArgumentParser(
        description="Run SDK parity tests across all 5 SDKs",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run all tests
  python parity_runner.py

  # Test specific operations
  python parity_runner.py --ops insert query-radius

  # Test specific SDKs
  python parity_runner.py --sdks python node go

  # Custom output paths
  python parity_runner.py --output reports/parity.json --markdown docs/PARITY.md
        """,
    )
    parser.add_argument(
        "--url",
        default="http://127.0.0.1:7000",
        help="ArcherDB server URL (default: http://127.0.0.1:7000)",
    )
    parser.add_argument(
        "--start-cluster",
        action="store_true",
        help="Start managed local cluster(s) for parity tests",
    )
    parser.add_argument(
        "--cluster-nodes",
        type=int,
        default=1,
        help="Default node count for managed local parity cluster (default: 1)",
    )
    parser.add_argument(
        "--cluster-port",
        type=int,
        default=0,
        help="Base port for local cluster (0 = auto-allocate)",
    )
    parser.add_argument(
        "--ops",
        nargs="*",
        help="Operations to test (default: all 14)",
    )
    parser.add_argument(
        "--sdks",
        nargs="*",
        help="SDKs to test (default: all 5)",
    )
    parser.add_argument(
        "--output",
        default="reports/parity.json",
        help="Path for JSON report (default: reports/parity.json)",
    )
    parser.add_argument(
        "--markdown",
        default="docs/PARITY.md",
        help="Path for Markdown report (default: docs/PARITY.md)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print progress information",
    )

    args = parser.parse_args()

    # Validate SDKs
    if args.sdks:
        for sdk in args.sdks:
            if sdk not in SDK_RUNNERS:
                print(f"Error: Unknown SDK '{sdk}'. Valid SDKs: {list(SDK_RUNNERS.keys())}")
                return 1

    # Validate operations
    if args.ops:
        for op in args.ops:
            if op not in OPERATIONS:
                print(f"Error: Unknown operation '{op}'. Valid operations: {OPERATIONS}")
                return 1

    server_url = args.url
    if args.start_cluster:
        server_url = "http://127.0.0.1:0"

    try:
        _refresh_packaged_sdk_clients(args.sdks, args.verbose)
    except Exception as exc:
        print(f"Error: {exc}")
        return 1

    results = run_parity_tests(
        server_url,
        args.ops,
        args.sdks,
        verbose=args.verbose,
        start_local_cluster=args.start_cluster,
        cluster_port=args.cluster_port,
        default_cluster_nodes=args.cluster_nodes,
    )

    # Write reports
    verifier = ParityVerifier(server_url)
    verifier.write_reports(results, args.output, args.markdown)

    # Summary
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)
    total = len(results)

    print(f"\nParity Test Results: {passed}/{total} passed, {failed} failed")
    print(f"JSON report: {args.output}")
    print(f"Markdown report: {args.markdown}")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
