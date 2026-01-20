# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

import os

import pytest

from archerdb import GeoClientSync, GeoClientConfig, create_geo_event, id as archerdb_id


RUN_INTEGRATION = os.getenv("ARCHERDB_INTEGRATION") == "1"
SERVER_ADDR = os.getenv("ARCHERDB_ADDRESS", "127.0.0.1:3001")


@pytest.mark.skipif(
    not RUN_INTEGRATION,
    reason="Set ARCHERDB_INTEGRATION=1 to run integration tests",
)
def test_insert_query_delete_roundtrip() -> None:
    client = GeoClientSync(GeoClientConfig(cluster_id=0, addresses=[SERVER_ADDR]))
    try:
        entity_id = archerdb_id()
        event = create_geo_event(
            entity_id=entity_id,
            latitude=37.7749,
            longitude=-122.4194,
            ttl_seconds=60,
        )

        errors = client.insert_events([event])
        assert errors == []

        found = client.get_latest_by_uuid(entity_id)
        assert found is not None
        assert found.entity_id == entity_id

        radius_result = client.query_radius(
            latitude=37.7749,
            longitude=-122.4194,
            radius_m=2000,
            limit=5,
        )
        assert radius_result.events

        latest_result = client.query_latest(limit=5)
        assert latest_result.events

        delete_result = client.delete_entities([entity_id])
        assert delete_result.deleted_count == 1
        assert delete_result.not_found_count == 0

        missing = client.get_latest_by_uuid(entity_id)
        assert missing is None
    finally:
        client.close()
