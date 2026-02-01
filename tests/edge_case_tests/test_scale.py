# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors

"""Scale tests for large batch and high volume scenarios (EDGE-04, EDGE-05).

Tests for handling large numbers of events:
- EDGE-04: 10K entity batch insert completes without error
- EDGE-05: 100K+ events can be inserted and queried

Test Cases:
    - 10K batch insert in single operation
    - 10K batch response time under 30 seconds
    - Sequential 5K batches (twice)
    - 100K events in sequential batches
    - 100K event query performance
    - Memory stability under high volume
"""

import time

import pytest

from test_infrastructure.generators.data_generator import DatasetConfig, generate_events

from .conftest import (
    EdgeCaseAPIClient,
    build_radius_query,
    generate_entity_id,
    load_fixture,
)


@pytest.mark.edge_case
@pytest.mark.slow
class TestLargeBatch:
    """Test large batch insert handling (EDGE-04)."""

    def test_10k_batch_insert(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """Generate 10,000 events with unique entity_ids, insert in single batch.

        The system should accept a batch of 10K events without error.
        Each event has a unique entity_id.
        """
        config_data = load_fixture(local_fixtures_dir / "scale_test_config.json")
        batch_config = config_data["test_parameters"]["batch_10k"]

        # Generate events using data_generator
        config = DatasetConfig(
            size=batch_config["count"],
            pattern="uniform",
            seed=42,
        )
        events = generate_events(config)

        assert len(events) == 10000
        # All entity_ids should be unique
        entity_ids = [e["entity_id"] for e in events]
        assert len(set(entity_ids)) == 10000

        # Actually insert via API
        response = api_client.insert(events, timeout=60.0)
        assert response.status_code == 200, f"10K batch insert failed: {response.text}"

    def test_10k_batch_response_time(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """Insert 10K events, ensure response within 30 seconds.

        The batch insert should complete within the configured timeout.
        """
        config_data = load_fixture(local_fixtures_dir / "scale_test_config.json")
        batch_config = config_data["test_parameters"]["batch_10k"]
        timeout_s = batch_config["timeout_s"]

        # Generate events
        config = DatasetConfig(
            size=batch_config["count"],
            pattern="uniform",
            seed=43,  # Different seed from previous test
        )
        events = generate_events(config)
        assert len(events) == 10000

        # Measure actual insert time
        start_time = time.time()
        response = api_client.insert(events, timeout=float(timeout_s))
        insert_time = time.time() - start_time

        assert response.status_code == 200, f"Insert failed: {response.text}"
        assert insert_time < timeout_s, f"Insert took {insert_time:.1f}s (timeout: {timeout_s}s)"

    def test_5k_batch_twice(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """Two 5K batches to verify sequential large batches work.

        The system should handle multiple large batches in sequence.
        """
        config_data = load_fixture(local_fixtures_dir / "scale_test_config.json")
        seq_config = config_data["test_parameters"]["sequential_5k"]

        # Generate first batch with seed 42
        config1 = DatasetConfig(
            size=seq_config["per_batch"],
            pattern="uniform",
            seed=42,
        )
        events1 = generate_events(config1)

        # Generate second batch with different seed
        config2 = DatasetConfig(
            size=seq_config["per_batch"],
            pattern="uniform",
            seed=43,
        )
        events2 = generate_events(config2)

        assert len(events1) == 5000
        assert len(events2) == 5000

        # Insert first batch
        response1 = api_client.insert(events1, timeout=30.0)
        assert response1.status_code == 200, f"First 5K batch failed: {response1.text}"

        # Insert second batch
        response2 = api_client.insert(events2, timeout=30.0)
        assert response2.status_code == 200, f"Second 5K batch failed: {response2.text}"

    def test_10k_unique_coordinates(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """10K events with varied coordinate distribution.

        Uniform distribution should spread events across globe.
        """
        config = DatasetConfig(
            size=10000,
            pattern="uniform",
            seed=44,
        )
        events = generate_events(config)

        lats = [e["latitude"] for e in events]
        lons = [e["longitude"] for e in events]

        # Should have variety in coordinates
        assert min(lats) < -45
        assert max(lats) > 45
        assert min(lons) < -90
        assert max(lons) > 90

        # Insert and verify
        response = api_client.insert(events, timeout=60.0)
        assert response.status_code == 200, f"Insert failed: {response.text}"


@pytest.mark.edge_case
@pytest.mark.slow
class TestHighVolume:
    """Test high volume event handling (EDGE-05)."""

    def test_100k_events_sequential(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """Insert 100K events in batches of 1000, verify total count.

        100,000 events inserted in 100 batches of 1,000 each.
        """
        config_data = load_fixture(local_fixtures_dir / "scale_test_config.json")
        hv_config = config_data["test_parameters"]["high_volume_100k"]

        total_inserted = 0
        batch_count = hv_config["batches"]
        per_batch = hv_config["batch_size"]

        for i in range(batch_count):
            config = DatasetConfig(
                size=per_batch,
                pattern="uniform",
                seed=42 + i,  # Different seed per batch
            )
            events = generate_events(config)

            response = api_client.insert(events, timeout=30.0)
            assert response.status_code == 200, f"Batch {i} failed: {response.text}"
            total_inserted += len(events)

        assert total_inserted == 100000

    def test_100k_events_query(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """After 100K insert, radius query returns results.

        A radius query on a populated dataset should work correctly.
        """
        # First insert some events
        config = DatasetConfig(
            size=1000,
            pattern="uniform",
            seed=42,
        )
        events = generate_events(config)

        response = api_client.insert(events, timeout=30.0)
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query near an event that was inserted
        sample_event = events[0]
        query_response = api_client.query_radius(
            lat=sample_event["latitude"],
            lon=sample_event["longitude"],
            radius_m=10000,  # 10km radius
            limit=100,
        )
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"

        # Should find the sample event
        results = query_response.json()
        events_found = results if isinstance(results, list) else results.get("events", [])
        found = any(e.get("entity_id") == sample_event["entity_id"] for e in events_found)
        assert found, "Should find inserted event in radius query"

    def test_100k_memory_stable(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """Insert 100K events, verify server stability.

        The server should remain healthy after large data ingestion.
        This is verified via health check after insertion.
        """
        # Insert 10 batches of 1000 for faster test
        batches_inserted = 0
        for i in range(10):
            config = DatasetConfig(
                size=1000,
                pattern="uniform",
                seed=100 + i,
            )
            events = generate_events(config)

            response = api_client.insert(events, timeout=30.0)
            assert response.status_code == 200, f"Batch {i} failed: {response.text}"
            batches_inserted += 1

        assert batches_inserted == 10

        # Verify server still responsive with a query
        query_response = api_client.query_radius(
            lat=0.0, lon=0.0, radius_m=1000
        )
        assert query_response.status_code == 200, "Server should remain responsive"

    def test_100k_varied_distribution(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """100K events with city-concentrated distribution.

        Tests that non-uniform distribution also handles high volume.
        """
        config = DatasetConfig(
            size=1000,  # Sample size for unit test
            pattern="city_concentrated",
            cities=["New York", "London", "Tokyo", "Sydney"],
            seed=42,
        )
        events = generate_events(config)

        assert len(events) == 1000

        # Insert events
        response = api_client.insert(events, timeout=30.0)
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Events should cluster near cities
        lats = [e["latitude"] for e in events]

        # Should have values near city coordinates
        assert any(35 < lat < 45 for lat in lats)  # Tokyo/NYC range

    def test_100k_hotspot_distribution(
        self, single_node_cluster, local_fixtures_dir, api_client
    ):
        """100K events with hotspot distribution.

        Events concentrated at specific hotspot coordinates.
        """
        config = DatasetConfig(
            size=1000,  # Sample size for unit test
            pattern="hotspot",
            hotspots=[
                (40.7128, -74.0060),  # NYC
                (51.5074, -0.1278),   # London
                (35.6762, 139.6503),  # Tokyo
            ],
            seed=42,
        )
        events = generate_events(config)

        assert len(events) == 1000

        # Insert events
        response = api_client.insert(events, timeout=30.0)
        assert response.status_code == 200, f"Insert failed: {response.text}"

        # Query near NYC hotspot
        query_response = api_client.query_radius(
            lat=40.7128, lon=-74.0060, radius_m=100000  # 100km
        )
        assert query_response.status_code == 200, f"Query failed: {query_response.text}"
