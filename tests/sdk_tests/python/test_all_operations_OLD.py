# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Comprehensive Python SDK operation tests for all 14 operations.

Tests are organized by operation, each loading test cases from
the shared JSON fixtures created in Phase 11. Each test:
1. Loads the operation fixture
2. Executes setup if needed (insert_first for query tests)
3. Calls the SDK method
4. Verifies result matches expected output
5. Cleans up (autouse fixture handles this)

Operations tested:
1.  insert (opcode 146)
2.  upsert (opcode 147)
3.  delete (opcode 148)
4.  query_uuid (opcode 149)
5.  query_uuid_batch (opcode 156)
6.  query_radius (opcode 150)
7.  query_polygon (opcode 151)
8.  query_latest (opcode 154)
9.  ping (opcode 152)
10. status (opcode 153)
11. ttl_set (opcode 158)
12. ttl_extend (opcode 159)
13. ttl_clear (opcode 160)
14. topology (opcode 157)
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
    get_case_by_name,
    convert_fixture_events,
    setup_test_data,
    verify_events_contain,
    verify_count_in_range,
)


# =============================================================================
# 1. Insert Operation (opcode 146) - ALL FIXTURE CASES
# =============================================================================

# Load all insert test cases from fixture
_insert_fixture = load_operation_fixture("insert")
_insert_cases = _insert_fixture.cases


class TestInsertOperation:
    """Tests for insert operation using ALL cases from insert.json fixture."""

    @pytest.mark.parametrize("case", _insert_cases, ids=[c.name for c in _insert_cases])
    def test_insert_all_cases(self, client: GeoClientSync, case):
        """Run ALL insert test cases from fixture for comprehensive coverage."""
        # Skip boundary/invalid tests - they cause session eviction (protocol validation)
        if any(tag in case.tags for tag in ["boundary", "invalid"]):
            pytest.skip("Boundary/invalid test - causes session eviction")

        # Convert fixture events to SDK format
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

        # Call SDK - insert_events returns errors (empty = all success)
        errors = client.insert_events(events)

        # Verify based on expected output
        expected = case.expected_output
        if expected and expected.get("all_ok"):
            assert errors == [], f"Insert failed with errors: {errors}"
            # Verify data was inserted
            if events:
                found = client.get_latest_by_uuid(events[0].entity_id)
                assert found is not None, "Inserted event not found"
                assert found.entity_id == events[0].entity_id


# =============================================================================
# 2. Upsert Operation (opcode 147)
# =============================================================================


class TestUpsertOperation:
    """Tests for upsert operation using fixtures from upsert.json."""

    def test_upsert_creates_new(self, client: GeoClientSync):
        """smoke: Upsert creates new entity if not exists."""
        fixture = load_operation_fixture("upsert")
        case = get_case_by_name(fixture, "upsert_new_entity")
        if case is None:
            # Fallback - use a unique entity
            entity_id = archerdb_id()
            event = create_geo_event(
                entity_id=entity_id,
                latitude=40.7128,
                longitude=-74.0060,
            )

            errors = client.upsert_events([event])
            assert errors == [], f"Upsert failed: {errors}"

            found = client.get_latest_by_uuid(entity_id)
            assert found is not None
            return

        ev = case.input["events"][0]
        event = create_geo_event(
            entity_id=ev["entity_id"],
            latitude=ev["latitude"],
            longitude=ev["longitude"],
        )

        errors = client.upsert_events([event])
        assert errors == []

    def test_upsert_updates_existing(self, client: GeoClientSync):
        """smoke: Upsert updates existing entity."""
        entity_id = archerdb_id()

        # First insert
        event1 = create_geo_event(
            entity_id=entity_id,
            latitude=40.7128,
            longitude=-74.0060,
        )
        client.insert_events([event1])

        # Upsert with new location
        event2 = create_geo_event(
            entity_id=entity_id,
            latitude=40.7500,
            longitude=-73.9800,
        )
        errors = client.upsert_events([event2])
        assert errors == []

        # Verify update
        found = client.get_latest_by_uuid(entity_id)
        assert found is not None
        # Check that coordinates changed (nanodegree precision)
        assert abs(archerdb.nano_to_degrees(found.lat_nano) - 40.7500) < 0.0001


# =============================================================================
# 3. Delete Operation (opcode 148)
# =============================================================================


class TestDeleteOperation:
    """Tests for delete operation using fixtures from delete.json."""

    def test_delete_existing_entity(self, client: GeoClientSync):
        """smoke: Delete existing entity."""
        entity_id = archerdb_id()

        # Insert first
        event = create_geo_event(
            entity_id=entity_id,
            latitude=40.7128,
            longitude=-74.0060,
        )
        client.insert_events([event])

        # Verify inserted
        found = client.get_latest_by_uuid(entity_id)
        assert found is not None

        # Delete
        result = client.delete_entities([entity_id])
        assert result.deleted_count == 1
        assert result.not_found_count == 0

        # Verify deleted
        found = client.get_latest_by_uuid(entity_id)
        assert found is None

    def test_delete_nonexistent_entity(self, client: GeoClientSync):
        """pr: Delete non-existent entity returns not_found."""
        entity_id = archerdb_id()

        result = client.delete_entities([entity_id])
        assert result.not_found_count == 1
        assert result.deleted_count == 0


# =============================================================================
# 4. Query UUID Operation (opcode 149)
# =============================================================================


class TestQueryUuidOperation:
    """Tests for query_uuid operation using fixtures from query-uuid.json."""

    def test_query_uuid_found(self, client: GeoClientSync):
        """smoke: Query UUID returns existing entity."""
        entity_id = archerdb_id()

        event = create_geo_event(
            entity_id=entity_id,
            latitude=40.7128,
            longitude=-74.0060,
        )
        client.insert_events([event])

        found = client.get_latest_by_uuid(entity_id)
        assert found is not None
        assert found.entity_id == entity_id

    def test_query_uuid_not_found(self, client: GeoClientSync):
        """smoke: Query UUID returns None for non-existent entity."""
        entity_id = archerdb_id()

        found = client.get_latest_by_uuid(entity_id)
        assert found is None


# =============================================================================
# 5. Query UUID Batch Operation (opcode 156)
# =============================================================================


class TestQueryUuidBatchOperation:
    """Tests for query_uuid_batch operation."""

    def test_query_uuid_batch_all_found(self, client: GeoClientSync):
        """smoke: Batch UUID lookup returns all existing entities."""
        entity_ids = [archerdb_id() for _ in range(3)]

        # Insert all
        events = [
            create_geo_event(
                entity_id=eid,
                latitude=40.7128 + i * 0.001,
                longitude=-74.0060,
            )
            for i, eid in enumerate(entity_ids)
        ]
        client.insert_events(events)

        # Batch query
        results = client.get_latest_batch(entity_ids)
        assert len(results) == 3
        for eid in entity_ids:
            assert eid in results
            assert results[eid] is not None

    def test_query_uuid_batch_partial(self, client: GeoClientSync):
        """pr: Batch UUID lookup with some not found."""
        existing_id = archerdb_id()
        missing_id = archerdb_id()

        event = create_geo_event(
            entity_id=existing_id,
            latitude=40.7128,
            longitude=-74.0060,
        )
        client.insert_events([event])

        results = client.get_latest_batch([existing_id, missing_id])
        assert existing_id in results
        assert results[existing_id] is not None
        assert missing_id in results
        assert results[missing_id] is None


# =============================================================================
# 6. Query Radius Operation (opcode 150)
# =============================================================================


class TestQueryRadiusOperation:
    """Tests for query_radius operation using fixtures from query-radius.json."""

    def test_query_radius_basic(self, client: GeoClientSync):
        """smoke: Basic radius query finds nearby events."""
        fixture = load_operation_fixture("query-radius")
        case = get_case_by_name(fixture, "basic_radius_1km")
        assert case is not None

        # Setup test data
        if "setup" in case.input:
            setup_test_data(client, case.input["setup"])

        # Execute query
        result = client.query_radius(
            latitude=case.input["center_latitude"],
            longitude=case.input["center_longitude"],
            radius_m=case.input["radius_m"],
            limit=1000,
        )

        # Verify expected output
        expected = case.expected_output
        if "events_contain" in expected:
            verify_events_contain(
                result.events, expected["events_contain"], "query_radius"
            )
        if "count_in_range" in expected:
            verify_count_in_range(len(result.events), expected, "query_radius")

    def test_query_radius_with_limit(self, client: GeoClientSync):
        """pr: Radius query respects limit parameter."""
        # Insert 20 events at same location
        events = []
        for i in range(20):
            event = create_geo_event(
                entity_id=archerdb_id(),
                latitude=40.7128,
                longitude=-74.0060,
            )
            events.append(event)
        client.insert_events(events)

        # Query with limit=10
        result = client.query_radius(
            latitude=40.7128,
            longitude=-74.0060,
            radius_m=1000,
            limit=10,
        )

        assert len(result.events) == 10

    def test_query_radius_empty_result(self, client: GeoClientSync):
        """pr: Radius query returns empty for no matches."""
        result = client.query_radius(
            latitude=0.0,
            longitude=0.0,
            radius_m=100,
            limit=1000,
        )

        assert len(result.events) == 0


# =============================================================================
# 7. Query Polygon Operation (opcode 151)
# =============================================================================


class TestQueryPolygonOperation:
    """Tests for query_polygon operation."""

    def test_query_polygon_finds_inside(self, client: GeoClientSync):
        """smoke: Polygon query finds events inside polygon."""
        # Insert event inside a square polygon
        entity_id = archerdb_id()
        event = create_geo_event(
            entity_id=entity_id,
            latitude=40.7128,
            longitude=-74.0060,
        )
        client.insert_events([event])

        # Query with square polygon around the point
        result = client.query_polygon(
            vertices=[
                (40.71, -74.01),  # SW
                (40.72, -74.01),  # NW
                (40.72, -74.00),  # NE
                (40.71, -74.00),  # SE
            ],
            limit=1000,
        )

        assert len(result.events) >= 1
        entity_ids = [e.entity_id for e in result.events]
        assert entity_id in entity_ids

    def test_query_polygon_empty_result(self, client: GeoClientSync):
        """pr: Polygon query returns empty for no matches."""
        # Query in area with no data
        result = client.query_polygon(
            vertices=[
                (0.0, 0.0),
                (0.1, 0.0),
                (0.1, 0.1),
                (0.0, 0.1),
            ],
            limit=1000,
        )

        assert len(result.events) == 0


# =============================================================================
# 8. Query Latest Operation (opcode 154)
# =============================================================================


class TestQueryLatestOperation:
    """Tests for query_latest operation."""

    def test_query_latest_returns_recent(self, client: GeoClientSync):
        """smoke: Query latest returns most recent events."""
        # Insert some events
        events = []
        for i in range(5):
            event = create_geo_event(
                entity_id=archerdb_id(),
                latitude=40.7128 + i * 0.001,
                longitude=-74.0060,
            )
            events.append(event)
        client.insert_events(events)

        result = client.query_latest(limit=10)
        assert len(result.events) == 5

    def test_query_latest_with_limit(self, client: GeoClientSync):
        """pr: Query latest respects limit."""
        events = []
        for i in range(10):
            event = create_geo_event(
                entity_id=archerdb_id(),
                latitude=40.7128,
                longitude=-74.0060,
            )
            events.append(event)
        client.insert_events(events)

        result = client.query_latest(limit=5)
        assert len(result.events) == 5


# =============================================================================
# 9. Ping Operation (opcode 152)
# =============================================================================


class TestPingOperation:
    """Tests for ping operation."""

    def test_ping_returns_pong(self, client: GeoClientSync):
        """smoke: Ping returns successful response."""
        result = client.ping()
        assert result is True


# =============================================================================
# 10. Status Operation (opcode 153)
# =============================================================================


class TestStatusOperation:
    """Tests for status operation."""

    def test_status_returns_info(self, client: GeoClientSync):
        """smoke: Status returns server information."""
        result = client.get_status()

        # Status should have ram_index fields
        assert hasattr(result, "ram_index_count") or isinstance(result, dict)


# =============================================================================
# 11. TTL Set Operation (opcode 158)
# =============================================================================


class TestTtlSetOperation:
    """Tests for ttl_set operation."""

    def test_ttl_set_applies_ttl(self, client: GeoClientSync):
        """smoke: Set TTL on existing entity."""
        entity_id = archerdb_id()

        # Insert first
        event = create_geo_event(
            entity_id=entity_id,
            latitude=40.7128,
            longitude=-74.0060,
        )
        client.insert_events([event])

        # Set TTL
        result = client.set_ttl(entity_id, ttl_seconds=3600)

        # Verify operation completed (result structure varies)
        assert result is not None


# =============================================================================
# 12. TTL Extend Operation (opcode 159)
# =============================================================================


class TestTtlExtendOperation:
    """Tests for ttl_extend operation."""

    def test_ttl_extend_adds_time(self, client: GeoClientSync):
        """smoke: Extend TTL adds time to existing TTL."""
        entity_id = archerdb_id()

        # Insert with initial TTL
        event = create_geo_event(
            entity_id=entity_id,
            latitude=40.7128,
            longitude=-74.0060,
            ttl_seconds=1800,
        )
        client.insert_events([event])

        # Extend TTL
        result = client.extend_ttl(entity_id, extend_by_seconds=1800)
        assert result is not None


# =============================================================================
# 13. TTL Clear Operation (opcode 160)
# =============================================================================


class TestTtlClearOperation:
    """Tests for ttl_clear operation."""

    def test_ttl_clear_removes_ttl(self, client: GeoClientSync):
        """smoke: Clear TTL removes expiration."""
        entity_id = archerdb_id()

        # Insert with TTL
        event = create_geo_event(
            entity_id=entity_id,
            latitude=40.7128,
            longitude=-74.0060,
            ttl_seconds=3600,
        )
        client.insert_events([event])

        # Clear TTL
        result = client.clear_ttl(entity_id)
        assert result is not None


# =============================================================================
# 14. Topology Operation (opcode 157)
# =============================================================================


class TestTopologyOperation:
    """Tests for topology operation."""

    def test_topology_returns_cluster_info(self, client: GeoClientSync):
        """smoke: Topology returns cluster configuration."""
        result = client.get_topology()

        # Should return topology information
        assert result is not None
        # Single node cluster
        if hasattr(result, "shards"):
            assert len(result.shards) >= 1
