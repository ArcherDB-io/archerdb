#!/usr/bin/env python3
"""
ArcherDB Basic Sample - Insert and Query Geospatial Events

This sample demonstrates:
1. Connecting to an ArcherDB cluster
2. Inserting geo events with location data
3. Querying events within a radius
"""
import os
import time
import random

from archerdb import GeoClientSync, GeoClientConfig, GeoEvent


def main():
    # Connect to ArcherDB cluster
    address = os.getenv("ARCHERDB_ADDRESS", "127.0.0.1:3001")
    config = GeoClientConfig(
        cluster_id=0,
        addresses=[address],
    )

    with GeoClientSync(config) as client:
        print(f"Connected to ArcherDB at {address}")

        # Create some geo events representing vehicle positions
        # San Francisco area coordinates
        base_lat = 37.7749
        base_lon = -122.4194

        # Insert events using a batch
        batch = client.create_batch()
        entity_ids = []

        for i in range(5):
            # Slightly offset positions around SF
            entity_id = random.randint(1, 2**63)
            entity_ids.append(entity_id)

            event = GeoEvent(
                entity_id=entity_id,
                latitude=base_lat + (i * 0.001),  # ~111 meters apart
                longitude=base_lon + (i * 0.001),
                timestamp=int(time.time() * 1_000_000_000) + i,  # nanoseconds
                group_id=1,
                altitude_mm=0,
                velocity_mms=0,
                heading_cdeg=0,
                accuracy_mm=10_000,  # 10m accuracy
            )
            batch.add(event)

        errors = batch.commit()
        if errors:
            print(f"Insert errors: {errors}")
        else:
            print(f"Successfully inserted {len(entity_ids)} events")

        # Query events within 1km radius of SF center
        result = client.query_radius(
            latitude=base_lat,
            longitude=base_lon,
            radius_m=1000,
            limit=100,
        )

        print(f"\nFound {len(result.events)} events within 1km of SF center:")
        for event in result.events:
            print(f"  Entity {event.entity_id}: ({event.latitude:.4f}, {event.longitude:.4f})")

        # Look up a specific entity
        if entity_ids:
            event = client.get_latest_by_uuid(entity_ids[0])
            if event:
                print(f"\nLatest position for entity {entity_ids[0]}:")
                print(f"  Location: ({event.latitude:.4f}, {event.longitude:.4f})")
                print(f"  Timestamp: {event.timestamp}")

        print("\nok")


if __name__ == "__main__":
    main()
