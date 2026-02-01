# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""TTL expiration verification tests (EDGE-06).

Tests for time-to-live (TTL) functionality where events automatically
expire and become unavailable after their TTL period.

Test Cases:
    - Event expires after TTL period
    - Event visible before TTL expires
    - TTL=0 means permanent (no expiration)
    - Batch with mixed TTLs
    - TTL extend functionality
    - TTL clear functionality
"""

import time

import pytest

from .conftest import (
    EdgeCaseAPIClient,
    build_insert_event,
    build_radius_query,
    generate_entity_id,
)


@pytest.mark.edge_case
@pytest.mark.slow
class TestTTLExpiration:
    """Test TTL expiration handling (EDGE-06)."""

    def test_event_expires_after_ttl(self, single_node_cluster, api_client):
        """Insert with ttl_seconds=5, wait 6s, query should not find.

        After the TTL expires, the event should no longer be queryable.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=5,  # 5 second TTL
        )

        # Insert event with 5s TTL
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify visible before TTL
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, "Event should exist before TTL"

        # Wait for TTL to expire
        time.sleep(6)

        # Verify NOT found after TTL
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 404, "Event should be gone after TTL expires"

    def test_event_visible_before_ttl(self, single_node_cluster, api_client):
        """Insert with ttl_seconds=30, query immediately, should find.

        Before the TTL expires, the event should be queryable.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=30,  # 30 second TTL (longer for safety)
        )

        # Insert event
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query immediately (within TTL period)
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        assert result["entity_id"] == entity_id

        # Also verify via radius query
        radius_response = api_client.query_radius(
            lat=40.7128,
            lon=-74.0060,
            radius_m=1000,
        )
        assert radius_response.status_code == 200

        results = radius_response.json()
        events = results if isinstance(results, list) else results.get("events", [])
        found = any(e.get("entity_id") == entity_id for e in events)
        assert found, "Event should be found before TTL expires"

    def test_ttl_zero_permanent(self, single_node_cluster, api_client):
        """Insert with ttl_seconds=0, wait, should still exist.

        TTL of 0 means the event is permanent and never expires.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=0,  # Permanent (no TTL)
        )

        # Insert event
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Wait a bit
        time.sleep(2)

        # Event with TTL=0 should still exist
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, "Permanent event should still exist"

        result = query_response.json()
        assert result["entity_id"] == entity_id

    def test_batch_mixed_ttl(self, single_node_cluster, api_client):
        """Insert batch with mixed TTLs, verify after wait.

        A batch can contain events with different TTLs.
        After waiting, only some events should remain.
        """
        events = []
        short_ttl_ids = []
        permanent_ids = []

        # Events with short TTL (3s)
        for i in range(3):
            eid = generate_entity_id()
            short_ttl_ids.append(eid)
            events.append(build_insert_event(
                entity_id=eid,
                lat=40.0 + i * 0.01,
                lon=-74.0,
                ttl_seconds=3,
            ))

        # Events with permanent TTL (0)
        for i in range(3):
            eid = generate_entity_id()
            permanent_ids.append(eid)
            events.append(build_insert_event(
                entity_id=eid,
                lat=41.0 + i * 0.01,
                lon=-74.0,
                ttl_seconds=0,
            ))

        assert len(events) == 6

        # Insert all events
        response = api_client.insert(events)
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify all exist initially
        for eid in short_ttl_ids + permanent_ids:
            resp = api_client.query_uuid(eid)
            assert resp.status_code == 200, f"Event {eid} should exist initially"

        # Wait for short TTL to expire
        time.sleep(4)

        # Short TTL events should be gone
        for eid in short_ttl_ids:
            resp = api_client.query_uuid(eid)
            assert resp.status_code == 404, f"Short TTL event {eid} should be gone"

        # Permanent events should still exist
        for eid in permanent_ids:
            resp = api_client.query_uuid(eid)
            assert resp.status_code == 200, f"Permanent event {eid} should still exist"

    def test_ttl_extend(self, single_node_cluster, api_client):
        """Insert with 5s TTL, extend to 60s, should still exist after 6s.

        TTL extension allows an event to live longer than originally set.
        """
        entity_id = generate_entity_id()

        # Original event with 5s TTL
        original_event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=5,
        )

        response = api_client.insert([original_event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Immediately extend TTL by re-inserting with longer TTL
        extended_event = build_insert_event(
            entity_id=entity_id,  # Same entity
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=60,  # Extended to 60s
        )

        response = api_client.insert([extended_event])
        assert response.status_code == 200, f"TTL extend failed: {response.text}"

        # Wait past original TTL
        time.sleep(6)

        # Event should still exist (extended TTL)
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, "Event should still exist after TTL extension"

    def test_ttl_clear(self, single_node_cluster, api_client):
        """Insert with 5s TTL, clear TTL (set to 0), should persist forever.

        Clearing TTL (setting to 0) makes the event permanent.
        """
        entity_id = generate_entity_id()

        # Original event with 5s TTL
        original_event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=5,
        )

        response = api_client.insert([original_event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Clear TTL by re-inserting with TTL=0
        cleared_event = build_insert_event(
            entity_id=entity_id,  # Same entity
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=0,  # Clear TTL (permanent)
        )

        response = api_client.insert([cleared_event])
        assert response.status_code == 200, f"TTL clear failed: {response.text}"

        # Wait past original TTL
        time.sleep(6)

        # Event should still exist (TTL cleared to permanent)
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, "Event should persist after TTL cleared"

    def test_ttl_very_short(self, single_node_cluster, api_client):
        """Insert with very short TTL (1 second).

        Even very short TTLs should work correctly.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=1,  # 1 second TTL
        )

        # Insert
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify exists immediately
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, "Should exist immediately after insert"

        # Wait for TTL
        time.sleep(2)

        # Should be gone
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 404, "Should be gone after 1s TTL"

    def test_ttl_very_long(self, single_node_cluster, api_client):
        """Insert with very long TTL (24 hours = 86400 seconds).

        Long TTLs should work correctly.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=86400,  # 24 hours
        )

        # Insert
        response = api_client.insert([event])
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Verify exists
        query_response = api_client.query_uuid(entity_id)
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        result = query_response.json()
        assert result["entity_id"] == entity_id
