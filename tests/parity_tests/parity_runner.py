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
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

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


def load_fixture(operation: str) -> Optional[Dict[str, Any]]:
    """Load fixture for specified operation.

    Loads from test_infrastructure/fixtures/v1/ directory,
    converting operation name from kebab-case to snake_case.

    Args:
        operation: Operation name (e.g., 'query-radius')

    Returns:
        Fixture dict with test_cases, or None if not found
    """
    # Convert kebab-case to snake_case for file name
    fixture_name = operation.replace("-", "_")
    fixture_path = PROJECT_ROOT / "test_infrastructure" / "fixtures" / "v1" / f"{fixture_name}.json"

    if not fixture_path.exists():
        # Try edge case fixtures
        edge_case_dir = Path(__file__).parent / "fixtures" / "edge_cases"
        for edge_file in edge_case_dir.glob("*.json"):
            try:
                with open(edge_file) as f:
                    data = json.load(f)
                    # Check if this fixture has test cases for our operation
                    for case in data.get("test_cases", []):
                        if case.get("operation") == operation:
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


def run_parity_tests(
    server_url: str,
    operations: Optional[List[str]] = None,
    sdks: Optional[List[str]] = None,
    verbose: bool = False,
) -> List[ParityResult]:
    """Run parity tests across all SDKs for all operations.

    Args:
        server_url: ArcherDB server URL (e.g., 'http://127.0.0.1:7000')
        operations: List of operations to test (default: all 14)
        sdks: List of SDKs to test (default: all 5)
        verbose: Print progress information

    Returns:
        List of ParityResult objects with pass/fail status
    """
    operations = operations or OPERATIONS
    sdks = sdks or list(SDK_RUNNERS.keys())

    verifier = ParityVerifier(server_url)
    results: List[ParityResult] = []

    for op in operations:
        if verbose:
            print(f"Testing operation: {op}")

        # Load fixture for operation
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

            if verbose:
                print(f"  Case: {case_name}")

            result = verifier.verify_parity(op, input_data, sdks, case_name)
            results.append(result)

            if verbose:
                status = "PASS" if result.passed else "FAIL"
                print(f"    Result: {status}")
                if not result.passed and result.mismatches:
                    for mismatch in result.mismatches:
                        print(f"      Mismatch: {mismatch.get('sdk', 'unknown')}")

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
        help="Start a local single-node cluster for parity tests",
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

    cluster = None
    server_url = args.url
    if args.start_cluster:
        from test_infrastructure.harness.cluster import ArcherDBCluster, ClusterConfig

        cluster = ArcherDBCluster(ClusterConfig(node_count=1, base_port=args.cluster_port))
        cluster.start()
        if not cluster.wait_for_ready(timeout=60):
            cluster.stop()
            raise SystemExit("Cluster failed to become ready")
        leader_port = cluster.wait_for_leader(timeout=30)
        if not leader_port:
            cluster.stop()
            raise SystemExit("Cluster leader not available")
        server_url = f"http://127.0.0.1:{leader_port}"

    try:
        # Run tests
        results = run_parity_tests(
            server_url,
            args.ops,
            args.sdks,
            verbose=args.verbose,
        )
    finally:
        if cluster:
            cluster.stop()

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
