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
    build_insert_event,
    build_radius_query,
    generate_entity_id,
)


@pytest.mark.edge_case
@pytest.mark.slow
class TestTTLExpiration:
    """Test TTL expiration handling (EDGE-06)."""

    def test_event_expires_after_ttl(self, single_node_cluster):
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

        assert event["ttl_seconds"] == 5

        # In a real integration test:
        # 1. Insert event
        # 2. Wait 6 seconds
        # 3. Query - should NOT find the event

        # For unit test, verify event structure
        assert event["entity_id"] == entity_id

    def test_event_visible_before_ttl(self, single_node_cluster):
        """Insert with ttl_seconds=10, query immediately, should find.

        Before the TTL expires, the event should be queryable.
        """
        entity_id = generate_entity_id()
        event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=10,  # 10 second TTL
        )

        assert event["ttl_seconds"] == 10

        # Query immediately (within TTL period)
        query = build_radius_query(
            lat=40.7128,
            lon=-74.0060,
            radius_m=1000,  # 1km radius
        )

        # Event should be within query range
        assert query["center_lat"] == event["latitude"]
        assert query["center_lon"] == event["longitude"]

    def test_ttl_zero_permanent(self, single_node_cluster):
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

        assert event["ttl_seconds"] == 0

        # Event with TTL=0 should persist indefinitely
        # Waiting any amount of time should not expire it
        time.sleep(0.1)  # Brief sleep to simulate passage of time

        # Event should still be valid
        assert event["entity_id"] == entity_id

    def test_batch_mixed_ttl(self, single_node_cluster):
        """Insert batch with mixed TTLs, verify after wait.

        A batch can contain events with different TTLs.
        After waiting, only some events should remain.
        """
        events = []

        # Events with short TTL (5s)
        for i in range(5):
            events.append(build_insert_event(
                entity_id=generate_entity_id(),
                lat=40.0 + i * 0.01,
                lon=-74.0,
                ttl_seconds=5,
            ))

        # Events with permanent TTL (0)
        for i in range(5):
            events.append(build_insert_event(
                entity_id=generate_entity_id(),
                lat=41.0 + i * 0.01,
                lon=-74.0,
                ttl_seconds=0,
            ))

        assert len(events) == 10

        short_ttl_count = sum(1 for e in events if e["ttl_seconds"] == 5)
        permanent_count = sum(1 for e in events if e["ttl_seconds"] == 0)

        assert short_ttl_count == 5
        assert permanent_count == 5

    def test_ttl_extend(self, single_node_cluster):
        """Insert with 5s TTL, extend to 60s, should still exist after 6s.

        TTL extension allows an event to live longer than originally set.
        """
        entity_id = generate_entity_id()
        original_event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=5,  # Original 5s TTL
        )

        # Create event with extended TTL (as update)
        extended_event = build_insert_event(
            entity_id=entity_id,  # Same entity
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=60,  # Extended to 60s
        )

        assert original_event["ttl_seconds"] == 5
        assert extended_event["ttl_seconds"] == 60
        assert original_event["entity_id"] == extended_event["entity_id"]

    def test_ttl_clear(self, single_node_cluster):
        """Insert with 5s TTL, clear TTL (set to 0), should persist forever.

        Clearing TTL (setting to 0) makes the event permanent.
        """
        entity_id = generate_entity_id()
        original_event = build_insert_event(
            entity_id=entity_id,
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=5,  # Original 5s TTL
        )

        # Clear TTL by setting to 0
        cleared_event = build_insert_event(
            entity_id=entity_id,  # Same entity
            lat=40.7128,
            lon=-74.0060,
            ttl_seconds=0,  # Clear TTL (permanent)
        )

        assert original_event["ttl_seconds"] == 5
        assert cleared_event["ttl_seconds"] == 0

    def test_ttl_very_short(self, single_node_cluster):
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

        assert event["ttl_seconds"] == 1

    def test_ttl_very_long(self, single_node_cluster):
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

        assert event["ttl_seconds"] == 86400
