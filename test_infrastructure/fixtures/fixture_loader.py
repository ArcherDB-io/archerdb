#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""Load and use test fixtures in SDK tests.

This module demonstrates how SDKs should load and validate fixtures
for cross-SDK parity testing.
"""

import json
from pathlib import Path
from dataclasses import dataclass
from typing import List, Optional, Any, Dict


@dataclass
class TestCase:
    """A single test case from a fixture file."""
    name: str
    description: str
    tags: List[str]
    input: dict
    expected_output: Optional[dict]
    expected_error: Optional[str]


@dataclass
class Fixture:
    """A complete fixture file with all test cases."""
    operation: str
    version: str
    description: str
    cases: List[TestCase]


def get_fixtures_dir() -> Path:
    """Get path to fixtures directory."""
    # Try relative to this file
    this_dir = Path(__file__).parent
    fixtures_dir = this_dir / "v1"
    if fixtures_dir.exists():
        return fixtures_dir

    # Try project root
    project_root = Path(__file__).parent.parent.parent
    fixtures_dir = project_root / "test_infrastructure/fixtures/v1"
    if fixtures_dir.exists():
        return fixtures_dir

    raise FileNotFoundError("Fixtures directory not found")


def load_fixture(operation: str) -> Fixture:
    """Load fixture for specified operation.

    Args:
        operation: Operation name (e.g., 'insert', 'query-radius')

    Returns:
        Fixture object with all test cases
    """
    fixtures_dir = get_fixtures_dir()
    fixture_path = fixtures_dir / f"{operation}.json"

    if not fixture_path.exists():
        raise FileNotFoundError(f"Fixture not found: {fixture_path}")

    with open(fixture_path) as f:
        data = json.load(f)

    cases = []
    for case_data in data.get("cases", []):
        cases.append(TestCase(
            name=case_data["name"],
            description=case_data.get("description", ""),
            tags=case_data.get("tags", []),
            input=case_data.get("input", {}),
            expected_output=case_data.get("expected_output"),
            expected_error=case_data.get("expected_error")
        ))

    return Fixture(
        operation=data["operation"],
        version=data["version"],
        description=data.get("description", ""),
        cases=cases
    )


def filter_cases_by_tag(fixture: Fixture, tag: str) -> List[TestCase]:
    """Filter test cases by tag (smoke, pr, nightly).

    Args:
        fixture: Fixture object
        tag: Tag to filter by

    Returns:
        List of TestCase objects with the specified tag
    """
    return [c for c in fixture.cases if tag in c.tags]


def list_operations() -> List[str]:
    """List all available fixture operations."""
    fixtures_dir = get_fixtures_dir()
    return [f.stem for f in fixtures_dir.glob("*.json")]


# Example usage demonstrating SDK consumption
def example_sdk_usage():
    """Demonstrate how an SDK test would use fixtures."""
    # Load insert fixture
    insert_fixture = load_fixture("insert")
    print(f"Loaded {insert_fixture.operation} fixture v{insert_fixture.version}")
    print(f"Total cases: {len(insert_fixture.cases)}")

    # Filter for smoke tests only
    smoke_cases = filter_cases_by_tag(insert_fixture, "smoke")
    print(f"Smoke test cases: {len(smoke_cases)}")

    # Show first smoke test case
    if smoke_cases:
        case = smoke_cases[0]
        print(f"\nExample case: {case.name}")
        print(f"  Description: {case.description}")
        print(f"  Input keys: {list(case.input.keys())}")
        if case.expected_output:
            print(f"  Expected output keys: {list(case.expected_output.keys())}")

    # Check for hotspot cases
    hotspot_cases = [c for c in insert_fixture.cases if "hotspot" in c.name.lower()]
    print(f"\nHotspot stress test cases: {len(hotspot_cases)}")


if __name__ == "__main__":
    print("Testing fixture loader...")

    # List all operations
    ops = list_operations()
    print(f"Available operations: {ops}")
    assert len(ops) >= 14, f"Expected at least 14 fixtures, found {len(ops)}"

    # Load and validate each fixture
    for op in ops:
        fixture = load_fixture(op)
        assert len(fixture.cases) > 0, f"{op} has no test cases"
        print(f"  {op}: {len(fixture.cases)} cases")

    # Run example usage
    print("\n--- Example SDK Usage ---")
    example_sdk_usage()

    print("\nAll fixture loader tests passed!")
