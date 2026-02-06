# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Cross-SDK fixture loading and conversion helpers.

This module provides utilities for loading test fixtures from Phase 11
and converting them to formats suitable for SDK consumption.
"""

from __future__ import annotations

import hashlib
import json
import time
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, TYPE_CHECKING

# Import the existing fixture loader from test_infrastructure
import sys
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent))

from test_infrastructure.fixtures.fixture_loader import (
    Fixture,
    TestCase,
    load_fixture as _load_fixture,
    filter_cases_by_tag as _filter_cases_by_tag,
    list_operations,
)

# Re-export for convenience
filter_cases_by_tag = _filter_cases_by_tag


def load_operation_fixture(operation: str) -> Fixture:
    """Load fixture for specified operation.

    Wraps the test_infrastructure fixture_loader to provide
    SDK-specific helpers.

    Args:
        operation: Operation name (e.g., 'insert', 'query-radius')

    Returns:
        Fixture object with all test cases

    Examples:
        >>> fixture = load_operation_fixture("insert")
        >>> print(fixture.operation)
        'insert'
        >>> print(len(fixture.cases))
        14
    """
    return _load_fixture(operation)


def build_geo_event_from_fixture(ev: Dict[str, Any]):
    """Build a GeoEvent from fixture data without client-side validation."""
    from archerdb.types import (
        GeoEvent,
        GeoEventFlags,
        degrees_to_nano,
        meters_to_mm,
        heading_to_centidegrees,
    )

    flags_value = ev.get("flags", 0) or 0
    timestamp_seconds = ev.get("timestamp", 0) or 0

    return GeoEvent(
        id=0,
        entity_id=ev["entity_id"],
        correlation_id=ev.get("correlation_id", 0),
        user_data=ev.get("user_data", 0),
        lat_nano=degrees_to_nano(ev["latitude"]),
        lon_nano=degrees_to_nano(ev["longitude"]),
        group_id=ev.get("group_id", 0),
        timestamp=int(timestamp_seconds) * 1_000_000_000,
        altitude_mm=meters_to_mm(ev.get("altitude_m", 0.0) or 0.0),
        velocity_mms=meters_to_mm(ev.get("velocity_mps", 0.0) or 0.0),
        ttl_seconds=ev.get("ttl_seconds", 0),
        accuracy_mm=meters_to_mm(ev.get("accuracy_m", 0.0) or 0.0),
        heading_cdeg=heading_to_centidegrees(ev.get("heading", 0.0) or 0.0),
        flags=GeoEventFlags(flags_value),
    )


def get_case_by_name(fixture: Fixture, name: str) -> Optional[TestCase]:
    """Get a specific test case by name from a fixture.

    Args:
        fixture: Fixture object to search
        name: Test case name to find

    Returns:
        TestCase if found, None otherwise
    """
    for case in fixture.cases:
        if case.name == name:
            return case
    return None


def convert_fixture_events(fixture_events: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Convert fixture event format to SDK event format.

    Fixture events use user-friendly keys (latitude, longitude) while
    SDKs may use internal formats (lat_nano, lon_nano).

    Args:
        fixture_events: List of events from fixture input

    Returns:
        List of events in SDK-ready format
    """
    sdk_events = []
    for event in fixture_events:
        sdk_event = {
            "entity_id": event.get("entity_id"),
            "latitude": event.get("latitude"),
            "longitude": event.get("longitude"),
        }

        # Copy optional fields if present
        optional_fields = [
            "correlation_id", "user_data", "group_id", "altitude_m",
            "velocity_mps", "ttl_seconds", "accuracy_m", "heading", "flags"
        ]
        for field in optional_fields:
            if field in event:
                sdk_event[field] = event[field]

        sdk_events.append(sdk_event)

    return sdk_events


def generate_unique_entity_id(test_name: str, sdk_name: str = "python") -> int:
    """Generate a unique entity ID based on test name and timestamp.

    Uses hash of test name + SDK name + timestamp to ensure uniqueness
    across tests and SDKs. The hash is truncated to fit in 64 bits
    to avoid issues with some SDKs.

    Args:
        test_name: Name of the test generating the ID
        sdk_name: Name of the SDK (for namespacing)

    Returns:
        Unique 64-bit entity ID
    """
    # Create deterministic but unique ID
    unique_string = f"{test_name}:{sdk_name}:{time.time_ns()}"
    hash_bytes = hashlib.sha256(unique_string.encode()).digest()
    # Use first 8 bytes as u64, ensure non-zero
    entity_id = int.from_bytes(hash_bytes[:8], byteorder='little')
    if entity_id == 0:
        entity_id = 1
    return entity_id


def clean_database(client: Any) -> None:
    """Delete all entities from the database for test isolation.

    Queries latest events and deletes all found entities.
    Call this before each test to ensure clean state.

    Args:
        client: SDK client with query_latest and delete_entities methods
    """
    try:
        cursor = 0
        while True:
            result = client.query_latest(limit=10000, cursor_timestamp=cursor)
            if not hasattr(result, 'events') or not result.events:
                break
            entity_ids = [e.entity_id for e in result.events]
            if entity_ids:
                client.delete_entities(entity_ids)
            next_cursor = result.events[-1].timestamp
            if next_cursor == cursor:
                break
            cursor = next_cursor
    except Exception:
        # If query fails (e.g., empty database), that's fine
        pass


def setup_test_data(client: Any, setup_config: Dict[str, Any]) -> List[int]:
    """Set up test data from fixture setup configuration.

    Handles various setup patterns:
    - insert_first: List of events to insert
    - insert_first_range: Generate range of events
    - insert_hotspot: Generate hotspot concentrated events

    Args:
        client: SDK client for inserting data
        setup_config: Setup configuration from fixture

    Returns:
        List of entity IDs that were inserted
    """
    inserted_ids = []

    # Handle insert_first (list of events)
    if "insert_first" in setup_config:
        events_data = setup_config["insert_first"]
        if isinstance(events_data, dict):
            # Single event
            events_data = [events_data]

        events = []
        for ev in events_data:
            event = build_geo_event_from_fixture(ev)
            events.append(event)
            inserted_ids.append(ev["entity_id"])

        if events:
            client.insert_events(events)

    # Handle insert_first_range (generate range of events)
    if "insert_first_range" in setup_config:
        range_config = setup_config["insert_first_range"]
        start_id = range_config["start_entity_id"]
        count = range_config["count"]
        base_lat = range_config["base_latitude"]
        base_lon = range_config["base_longitude"]
        spread_m = range_config.get("spread_m", 100)

        events = []
        spread_deg = spread_m / 111000.0
        cols = min(10, count) if count > 0 else 1
        rows = int(math.ceil(count / cols)) if count > 0 else 1
        for i in range(count):
            row = i // cols
            col = i % cols
            row_frac = 0.5 if rows <= 1 else row / (rows - 1)
            col_frac = 0.5 if cols <= 1 else col / (cols - 1)
            lat_offset = (row_frac - 0.5) * spread_deg
            lon_offset = (col_frac - 0.5) * spread_deg
            event = build_geo_event_from_fixture({
                "entity_id": start_id + i,
                "latitude": base_lat + lat_offset,
                "longitude": base_lon + lon_offset,
            })
            events.append(event)
            inserted_ids.append(start_id + i)

        if events:
            # Insert in smaller batches to respect server request limits
            for i in range(0, len(events), 200):
                batch = events[i:i+200]
                client.insert_events(batch)

    # Handle insert_hotspot (generate hotspot distribution)
    if "insert_hotspot" in setup_config:
        hotspot = setup_config["insert_hotspot"]
        center_lat = hotspot["center_latitude"]
        center_lon = hotspot["center_longitude"]
        count = int(hotspot["count"])
        concentration = float(hotspot.get("concentration_percentage", 100))
        start_id = int(hotspot.get("start_entity_id", 1))

        hotspot_count = int(round(count * (concentration / 100.0)))
        spread_count = max(count - hotspot_count, 0)

        events = []
        for i in range(count):
            if i < hotspot_count:
                total = max(hotspot_count, 1)
                idx = i
                spread_deg = 0.005  # ~500m
            else:
                total = max(spread_count, 1)
                idx = i - hotspot_count
                spread_deg = 0.05  # ~5km

            cols = min(10, total)
            rows = int(math.ceil(total / cols)) if total > 0 else 1
            row = idx // cols if cols > 0 else 0
            col = idx % cols if cols > 0 else 0
            row_frac = 0.5 if rows <= 1 else row / (rows - 1)
            col_frac = 0.5 if cols <= 1 else col / (cols - 1)
            lat = center_lat + (row_frac - 0.5) * spread_deg
            lon = center_lon + (col_frac - 0.5) * spread_deg

            event = build_geo_event_from_fixture({
                "entity_id": start_id + i,
                "latitude": lat,
                "longitude": lon,
            })
            events.append(event)
            inserted_ids.append(start_id + i)

        if events:
            for i in range(0, len(events), 200):
                batch = events[i:i+200]
                client.insert_events(batch)

    # Handle insert_with_timestamps (events with explicit timestamps)
    if "insert_with_timestamps" in setup_config:
        timestamp_events = setup_config["insert_with_timestamps"]
        events = []
        for ev in timestamp_events:
            event = build_geo_event_from_fixture(ev)
            events.append(event)
            inserted_ids.append(ev["entity_id"])

        if events:
            for i in range(0, len(events), 200):
                batch = events[i:i+200]
                client.insert_events(batch)

    # Handle then_upsert (update after initial insert)
    if "then_upsert" in setup_config:
        upsert_data = setup_config["then_upsert"]
        if isinstance(upsert_data, dict):
            upsert_data = [upsert_data]
        events = [build_geo_event_from_fixture(ev) for ev in upsert_data]
        if events:
            client.upsert_events(events)

    # Handle then_clear_ttl (explicit TTL clear)
    if "then_clear_ttl" in setup_config:
        entity_id = setup_config["then_clear_ttl"]
        client.clear_ttl(entity_id)

    # Handle then_wait_seconds (sleep for TTL propagation)
    if "then_wait_seconds" in setup_config:
        wait_seconds = setup_config["then_wait_seconds"]
        time.sleep(float(wait_seconds))

    # Handle perform_operations (status fixture)
    if "perform_operations" in setup_config:
        operations = setup_config["perform_operations"]
        for op in operations:
            op_type = op.get("type")
            count = int(op.get("count", 0))
            if op_type == "insert" and count > 0:
                events = []
                base_id = 99000
                for i in range(count):
                    events.append(build_geo_event_from_fixture({
                        "entity_id": base_id + i,
                        "latitude": 40.0 + (i * 0.0001),
                        "longitude": -74.0 - (i * 0.0001),
                    }))
                for i in range(0, len(events), 200):
                    batch = events[i:i+200]
                    client.insert_events(batch)
            if op_type == "query_radius" and count > 0:
                for _ in range(count):
                    client.query_radius(40.0, -74.0, 1000, limit=10)

    return inserted_ids


def assert_json_match(
    expected: Any,
    actual: Any,
    operation_name: str,
    ignore_keys: Optional[List[str]] = None
) -> None:
    """Assert that actual JSON matches expected with verbose diff on failure.

    Per CONTEXT.md: Show expected vs actual with highlighted differences
    on any mismatch.

    Args:
        expected: Expected value/structure
        actual: Actual value/structure
        operation_name: Name of operation for error messages
        ignore_keys: Optional list of keys to ignore in comparison

    Raises:
        AssertionError: If values don't match, with detailed diff
    """
    try:
        from deepdiff import DeepDiff

        exclude_paths = None
        if ignore_keys:
            # Build regex pattern to exclude specified keys
            exclude_paths = [f"root\\[.*\\]\\['{key}'\\]" for key in ignore_keys]
            exclude_paths.extend([f"root\\['{key}'\\]" for key in ignore_keys])

        diff = DeepDiff(
            expected,
            actual,
            ignore_order=True,
            exclude_regex_paths=exclude_paths if exclude_paths else None,
        )

        if diff:
            diff_str = _format_diff(expected, actual, diff)
            raise AssertionError(
                f"\n{'='*60}\n"
                f"MISMATCH in {operation_name}\n"
                f"{'='*60}\n"
                f"{diff_str}\n"
                f"{'='*60}\n"
            )
    except ImportError:
        # Fallback if deepdiff not installed
        if expected != actual:
            raise AssertionError(
                f"\n{'='*60}\n"
                f"MISMATCH in {operation_name}\n"
                f"{'='*60}\n"
                f"Expected:\n{json.dumps(expected, indent=2, default=str)}\n\n"
                f"Actual:\n{json.dumps(actual, indent=2, default=str)}\n"
                f"{'='*60}\n"
            )


def _format_diff(expected: Any, actual: Any, diff: Any) -> str:
    """Format a DeepDiff for readable output."""
    lines = []

    lines.append("Expected:")
    lines.append(json.dumps(expected, indent=2, default=str))
    lines.append("")
    lines.append("Actual:")
    lines.append(json.dumps(actual, indent=2, default=str))
    lines.append("")
    lines.append("Differences:")

    # Format diff entries
    for diff_type, changes in diff.items():
        lines.append(f"  {diff_type}:")
        if isinstance(changes, dict):
            for key, value in changes.items():
                lines.append(f"    {key}: {value}")
        else:
            lines.append(f"    {changes}")

    return "\n".join(lines)


def verify_result_code(result: Any, expected_code: int, operation_name: str) -> None:
    """Verify operation result code matches expected.

    Args:
        result: SDK result object or dict
        expected_code: Expected result code (0 = success)
        operation_name: Operation name for error messages

    Raises:
        AssertionError: If result code doesn't match
    """
    if hasattr(result, 'result_code'):
        actual_code = result.result_code
    elif isinstance(result, dict):
        actual_code = result.get('result_code', result.get('code', 0))
    else:
        # Assume success if no code present
        actual_code = 0

    if actual_code != expected_code:
        raise AssertionError(
            f"{operation_name}: Expected result_code {expected_code}, got {actual_code}"
        )


def verify_events_contain(
    events: List[Any],
    expected_ids: List[int],
    operation_name: str
) -> None:
    """Verify that returned events contain all expected entity IDs.

    Args:
        events: List of event objects/dicts from query result
        expected_ids: List of entity IDs that should be present
        operation_name: Operation name for error messages

    Raises:
        AssertionError: If any expected ID is missing
    """
    actual_ids = set()
    for event in events:
        if hasattr(event, 'entity_id'):
            actual_ids.add(event.entity_id)
        elif isinstance(event, dict):
            actual_ids.add(event.get('entity_id'))

    expected_set = set(expected_ids)
    missing = expected_set - actual_ids

    if missing:
        raise AssertionError(
            f"{operation_name}: Missing expected entity IDs: {missing}\n"
            f"  Expected: {expected_set}\n"
            f"  Actual:   {actual_ids}"
        )


def verify_count_in_range(
    actual_count: int,
    expected: Dict[str, Any],
    operation_name: str,
    max_results: Optional[int] = None,
) -> None:
    """Verify count matches expected from fixture.

    Handles both exact count and range specifications:
    - count: Exact count expected
    - count_in_range: Minimum count expected
    - count_in_range_min: Minimum count (alternate key)

    Args:
        actual_count: Actual event count from result
        expected: Expected output dict from fixture
        operation_name: Operation name for error messages

    Raises:
        AssertionError: If count doesn't match expectations
    """
    if "count" in expected:
        expected_count = expected["count"]
        if max_results is not None and expected_count > max_results:
            expected_count = max_results
        if actual_count != expected_count:
            raise AssertionError(
                f"{operation_name}: Expected count {expected_count}, got {actual_count}"
            )

    if "count_in_range" in expected:
        min_count = expected["count_in_range"]
        if max_results is not None and min_count > max_results:
            min_count = max_results
        if actual_count < min_count:
            raise AssertionError(
                f"{operation_name}: Expected at least {min_count} events, got {actual_count}"
            )

    if "count_min" in expected:
        min_count = expected["count_min"]
        if max_results is not None and min_count > max_results:
            min_count = max_results
        if actual_count < min_count:
            raise AssertionError(
                f"{operation_name}: Expected at least {min_count} events, got {actual_count}"
            )

    if "count_in_range_min" in expected:
        min_count = expected["count_in_range_min"]
        if max_results is not None and min_count > max_results:
            min_count = max_results
        if actual_count < min_count:
            raise AssertionError(
                f"{operation_name}: Expected at least {min_count} events, got {actual_count}"
            )
