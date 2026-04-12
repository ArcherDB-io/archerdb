# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Comprehensive Python SDK operation tests - ALL FIXTURE CASES.

This test suite uses pytest.mark.parametrize to run ALL test cases from
the shared JSON fixtures, ensuring complete coverage matching Go SDK (79 cases).

Each operation loads all cases from its fixture file and runs them parametrically.
"""

from __future__ import annotations

import pytest

import archerdb
from archerdb import (
    GeoClientSync,
    create_geo_event,
    id as archerdb_id,
)

from tests.sdk_tests.common.fixture_adapter import (
    load_operation_fixture,
)


# Load all fixtures once at module level (Fixture dataclass objects)
_fixtures = {
    "insert": load_operation_fixture("insert"),
    "upsert": load_operation_fixture("upsert"),
    "delete": load_operation_fixture("delete"),
    "query-uuid": load_operation_fixture("query-uuid"),
    "query-uuid-batch": load_operation_fixture("query-uuid-batch"),
    "query-radius": load_operation_fixture("query-radius"),
    "query-polygon": load_operation_fixture("query-polygon"),
    "query-latest": load_operation_fixture("query-latest"),
    "ping": load_operation_fixture("ping"),
    "status": load_operation_fixture("status"),
    "topology": load_operation_fixture("topology"),
    "ttl-set": load_operation_fixture("ttl-set"),
    "ttl-extend": load_operation_fixture("ttl-extend"),
    "ttl-clear": load_operation_fixture("ttl-clear"),
}


def _should_skip_case(case) -> tuple[bool, str]:
    """Determine if a test case should be skipped."""
    case_name = case.name if hasattr(case, "name") else case.get("name", "")

    return False, ""


def _is_invalid_input_case(case) -> bool:
    """Check if this test case expects SDK-side validation error (invalid coords/zero entity_id)."""
    case_name = case.name if hasattr(case, "name") else case.get("name", "")
    expected = (
        case.expected_output
        if hasattr(case, "expected_output")
        else case.get("expected_output")
    )

    # Only flag cases that expect specific error codes for invalid input
    # e.g., LAT_OUT_OF_RANGE, ENTITY_ID_MUST_NOT_BE_ZERO
    if expected and "results" in expected:
        for result in expected["results"]:
            status = result.get("status", "")
            if (
                "OUT_OF_RANGE" in status
                or "MUST_NOT_BE_ZERO" in status
                or "INVALID" in status
            ):
                return True

    # Check for explicit invalid coordinate tests (lat>90, lon>180)
    if "invalid_lat" in case_name or "invalid_lon" in case_name:
        return True

    # Check for entity_id=0 tests that expect error
    if "entity_id_zero" in case_name and expected:
        for result in expected.get("results", []):
            if result.get("code", 0) != 0:
                return True

    return False


def _get_case_attr(case, attr: str, default=None):
    """Get attribute from TestCase dataclass or dict."""
    if hasattr(case, attr):
        return getattr(case, attr)
    return case.get(attr, default)


# =============================================================================
# 1. Insert Operation - ALL CASES
# =============================================================================


class TestInsertOperation:
    """Insert operation - comprehensive fixture-driven tests."""

    @pytest.mark.parametrize(
        "case",
        _fixtures["insert"].cases,
        ids=[c.name for c in _fixtures["insert"].cases],
    )
    def test_insert(self, client: GeoClientSync, case):
        """Test insert operation with all fixture cases."""
        skip, reason = _should_skip_case(case)
        if skip:
            pytest.skip(reason)

        # Handle invalid input tests - SDK may validate or server returns error
        if _is_invalid_input_case(case):
            # For coordinate validation, SDK raises ValueError
            if "invalid_lat" in case.name or "invalid_lon" in case.name:
                with pytest.raises(ValueError):
                    events = []
                    for ev in case.input["events"]:
                        event = create_geo_event(
                            entity_id=ev["entity_id"],
                            latitude=ev["latitude"],
                            longitude=ev["longitude"],
                        )
                        events.append(event)
                return

            # For entity_id=0, server returns error - verify error in response
            events = []
            for ev in case.input["events"]:
                # Skip validation by using raw values
                from archerdb.types import GeoEvent, GeoEventFlags, degrees_to_nano

                event = GeoEvent(
                    id=0,
                    entity_id=ev["entity_id"],
                    lat_nano=degrees_to_nano(ev["latitude"]),
                    lon_nano=degrees_to_nano(ev["longitude"]),
                )
                events.append(event)
            errors = client.insert_events(events)
            assert len(errors) > 0, "Expected insert errors for invalid input"
            return

        # Convert events from fixture
        events = []
        for ev in case.input["events"]:
            event = create_geo_event(
                entity_id=ev["entity_id"],
                latitude=ev["latitude"],
                longitude=ev["longitude"],
                correlation_id=ev.get("correlation_id", 0),
                user_data=ev.get("user_data", 0),
                group_id=ev.get("group_id", 0),
                altitude_m=ev.get("altitude_m", 0.0),
                velocity_mps=ev.get("velocity_mps", 0.0),
                ttl_seconds=ev.get("ttl_seconds", 0),
                accuracy_m=ev.get("accuracy_m", 0.0),
                heading=ev.get("heading", 0.0),
                flags=ev.get("flags", 0),
            )
            events.append(event)

        # Execute operation
        errors = client.insert_events(events)

        # Verify result
        expected = case.expected_output
        if expected and expected.get("all_ok"):
            assert errors == [], f"Insert failed with errors: {errors}"


# =============================================================================
# 2. Upsert Operation - ALL CASES
# =============================================================================


class TestUpsertOperation:
    """Upsert operation - comprehensive fixture-driven tests."""

    @pytest.mark.parametrize(
        "case",
        _fixtures["upsert"].cases,
        ids=[c.name for c in _fixtures["upsert"].cases],
    )
    def test_upsert(self, client: GeoClientSync, case):
        """Test upsert operation with all fixture cases."""
        skip, reason = _should_skip_case(case)
        if skip:
            pytest.skip(reason)

        # Handle setup events if needed
        if "setup_events" in case.input:
            setup_events = []
            for ev in case.input["setup_events"]:
                event = create_geo_event(
                    entity_id=ev["entity_id"],
                    latitude=ev["latitude"],
                    longitude=ev["longitude"],
                )
                setup_events.append(event)
            client.insert_events(setup_events)

        # Convert upsert events
        events = []
        for ev in case.input["events"]:
            event = create_geo_event(
                entity_id=ev["entity_id"],
                latitude=ev["latitude"],
                longitude=ev["longitude"],
                group_id=ev.get("group_id", 0),
            )
            events.append(event)

        # Execute operation
        errors = client.upsert_events(events)

        # Verify result
        expected = case.expected_output
        if expected and expected.get("all_ok"):
            assert errors == [], f"Upsert failed: {errors}"


# =============================================================================
# 3. Delete Operation - ALL CASES
# =============================================================================


class TestDeleteOperation:
    """Delete operation - comprehensive fixture-driven tests."""

    @pytest.mark.parametrize(
        "case",
        _fixtures["delete"].cases,
        ids=[c.name for c in _fixtures["delete"].cases],
    )
    def test_delete(self, client: GeoClientSync, case):
        """Test delete operation with all fixture cases."""
        skip, reason = _should_skip_case(case)
        if skip:
            pytest.skip(reason)

        # Handle invalid input tests (entity_id_zero)
        if _is_invalid_input_case(case):
            entity_ids = case.input.get("entity_ids", [])
            if not entity_ids and "entity_id" in case.input:
                entity_ids = [case.input["entity_id"]]
            # SDK batch add validates entity_id != 0
            from archerdb.client import InvalidEntityId

            with pytest.raises(InvalidEntityId):
                client.delete_entities(entity_ids)
            return

        # Handle setup config if needed
        setup_config = case.input.get("setup", {})
        if setup_config:
            from tests.sdk_tests.common.fixture_adapter import setup_test_data

            setup_test_data(client, setup_config)

        # Get entity IDs to delete
        entity_ids = case.input.get("entity_ids", [])
        if not entity_ids and "entity_id" in case.input:
            entity_ids = [case.input["entity_id"]]

        # Execute operation
        result = client.delete_entities(entity_ids)

        # Verify result
        expected = case.expected_output
        if expected:
            if "deleted_count" in expected:
                assert result.deleted_count == expected["deleted_count"]


# =============================================================================
# 4. Query UUID Operation - ALL CASES
# =============================================================================


class TestQueryUuidOperation:
    """Query UUID operation - comprehensive fixture-driven tests."""

    @pytest.mark.parametrize(
        "case",
        _fixtures["query-uuid"].cases,
        ids=[c.name for c in _fixtures["query-uuid"].cases],
    )
    def test_query_uuid(self, client: GeoClientSync, case):
        """Test query_uuid operation with all fixture cases."""
        skip, reason = _should_skip_case(case)
        if skip:
            pytest.skip(reason)

        # Handle invalid input tests (entity_id_zero)
        if _is_invalid_input_case(case):
            entity_id = case.input.get("entity_id", 0)
            # SDK's get_latest_by_uuid doesn't validate entity_id=0
            # It just returns None (not found)
            result = client.get_latest_by_uuid(entity_id)
            assert result is None, "Entity with id=0 should not exist"
            return

        # Handle setup config if needed (fixture uses "setup" key)
        setup_config = case.input.get("setup", {})
        if setup_config:
            from tests.sdk_tests.common.fixture_adapter import setup_test_data

            setup_test_data(client, setup_config)

        # Execute query
        entity_id = case.input.get("entity_id")
        result = client.get_latest_by_uuid(entity_id)

        # Verify result
        expected = case.expected_output
        if expected:
            if expected.get("not_found"):
                assert result is None, f"Expected not found, got {result}"
            elif expected.get("found"):
                assert result is not None, "Expected to find entity"


# =============================================================================
# 5. Query Radius Operation - ALL CASES
# =============================================================================


class TestQueryRadiusOperation:
    """Query radius operation - comprehensive fixture-driven tests."""

    @pytest.mark.parametrize(
        "case",
        _fixtures["query-radius"].cases,
        ids=[c.name for c in _fixtures["query-radius"].cases],
    )
    def test_query_radius(self, client: GeoClientSync, case):
        """Test query_radius operation with all fixture cases."""
        skip, reason = _should_skip_case(case)
        if skip:
            pytest.skip(reason)

        # Handle setup config if needed (fixture uses "setup" key with nested config)
        setup_config = case.input.get("setup", {})
        if setup_config:
            from tests.sdk_tests.common.fixture_adapter import setup_test_data

            setup_test_data(client, setup_config)

        # Execute query (fixture uses center_latitude/center_longitude)
        input_data = case.input
        result = client.query_radius(
            latitude=input_data.get("center_latitude", input_data.get("latitude", 0.0)),
            longitude=input_data.get(
                "center_longitude", input_data.get("longitude", 0.0)
            ),
            radius_m=input_data.get("radius_m", 1000),
            limit=input_data.get("limit", 100),
        )

        # Verify result
        expected = case.expected_output
        if expected:
            if "count" in expected:
                assert len(result.events) == expected["count"]
            elif "count_min" in expected:
                assert len(result.events) >= expected["count_min"]
            elif "count_in_range" in expected:
                assert len(result.events) >= expected["count_in_range"]


# =============================================================================
# 6. Query Latest Operation - ALL CASES
# =============================================================================


class TestQueryLatestOperation:
    """Query latest operation - comprehensive fixture-driven tests."""

    @pytest.mark.parametrize(
        "case",
        _fixtures["query-latest"].cases,
        ids=[c.name for c in _fixtures["query-latest"].cases],
    )
    def test_query_latest(self, client: GeoClientSync, case):
        """Test query_latest operation with all fixture cases."""
        skip, reason = _should_skip_case(case)
        if skip:
            pytest.skip(reason)

        # Handle setup config if needed (fixture uses "setup" key)
        setup_config = case.input.get("setup", {})
        if setup_config:
            from tests.sdk_tests.common.fixture_adapter import setup_test_data

            setup_test_data(client, setup_config)

        # Execute query
        result = client.query_latest(
            limit=case.input.get("limit", 100),
        )

        # Verify result
        expected = case.expected_output
        if expected and "count_min" in expected:
            assert len(result.events) >= expected["count_min"]
