#!/usr/bin/env python3
"""
ArcherDB Entity Tracking Walkthrough

This sample demonstrates:
1. Tracking a moving entity over time
2. Updating entity positions (upsert)
3. Looking up entity by UUID
4. Deleting entities
5. Historical position queries
"""
import os
import time
import random

from archerdb import GeoClientSync, GeoClientConfig, GeoEvent


def main():
    address = os.getenv("ARCHERDB_ADDRESS", "127.0.0.1:3001")
    config = GeoClientConfig(
        cluster_id=0,
        addresses=[address],
    )

    with GeoClientSync(config) as client:
        print(f"Connected to ArcherDB at {address}")
        print("=" * 50)

        # Create a unique entity ID for our tracked vehicle
        entity_id = random.randint(1, 2**63)
        print(f"\n1. CREATING ENTITY: Vehicle {entity_id}")

        # Simulate a vehicle route from SF Ferry Building to Fisherman's Wharf
        route = [
            {"name": "Ferry Building", "lat": 37.7955, "lon": -122.3937},
            {"name": "Pier 23", "lat": 37.8005, "lon": -122.4007},
            {"name": "Pier 33", "lat": 37.8087, "lon": -122.4097},
            {"name": "Fisherman's Wharf", "lat": 37.8080, "lon": -122.4177},
        ]

        base_time = int(time.time() * 1_000_000_000)

        # Insert initial position
        print("\n2. INSERTING INITIAL POSITION")
        batch = client.create_batch()
        event = GeoEvent(
            entity_id=entity_id,
            latitude=route[0]["lat"],
            longitude=route[0]["lon"],
            timestamp=base_time,
            velocity_mms=5000,  # 5 m/s
            heading_cdeg=31500,  # ~315 degrees (northwest)
            group_id=1,
        )
        batch.add(event)
        errors = batch.commit()
        print(f"   Inserted at {route[0]['name']}: ({route[0]['lat']:.4f}, {route[0]['lon']:.4f})")

        # Look up the entity
        print("\n3. LOOKING UP ENTITY BY UUID")
        found = client.get_latest_by_uuid(entity_id)
        if found:
            print(f"   Found entity {entity_id}")
            print(f"   Position: ({found.latitude:.4f}, {found.longitude:.4f})")
            print(f"   Velocity: {found.velocity_mms / 1000:.1f} m/s")

        # Update positions along the route
        print("\n4. UPDATING POSITIONS ALONG ROUTE")
        for i, stop in enumerate(route[1:], 1):
            batch = client.create_upsert_batch()
            event = GeoEvent(
                entity_id=entity_id,
                latitude=stop["lat"],
                longitude=stop["lon"],
                timestamp=base_time + (i * 60_000_000_000),  # 1 minute apart
                velocity_mms=5000,
                heading_cdeg=31500,
                group_id=1,
            )
            batch.add(event)
            batch.commit()
            print(f"   Updated to {stop['name']}: ({stop['lat']:.4f}, {stop['lon']:.4f})")

        # Query to verify latest position
        print("\n5. VERIFYING LATEST POSITION")
        found = client.get_latest_by_uuid(entity_id)
        if found:
            print(f"   Latest position: ({found.latitude:.4f}, {found.longitude:.4f})")
            print(f"   Expected: Fisherman's Wharf ({route[-1]['lat']:.4f}, {route[-1]['lon']:.4f})")

        # Query historical positions in the area
        print("\n6. QUERYING HISTORICAL POSITIONS IN AREA")
        result = client.query_radius(
            latitude=37.8020,  # Center between start and end
            longitude=-122.4057,
            radius_m=2000,  # 2km radius
        )
        print(f"   Found {len(result.events)} historical positions in 2km area")

        # Delete the entity
        print("\n7. DELETING ENTITY")
        delete_result = client.delete_entities([entity_id])
        print(f"   Deleted {delete_result.deleted_count} entities")
        print(f"   Not found: {delete_result.not_found_count}")

        # Verify deletion
        print("\n8. VERIFYING DELETION")
        found = client.get_latest_by_uuid(entity_id)
        if found is None:
            print("   Entity successfully deleted (not found)")
        else:
            print("   Warning: Entity still found after deletion")

        print("\n" + "=" * 50)
        print("Walkthrough complete!")
        print("ok")


if __name__ == "__main__":
    main()
