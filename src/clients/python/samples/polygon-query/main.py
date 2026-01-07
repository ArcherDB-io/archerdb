#!/usr/bin/env python3
"""
ArcherDB Polygon Query Sample - Geofence Queries

This sample demonstrates:
1. Creating polygon-based geofences
2. Querying events within polygon boundaries
3. Comparing polygon vs radius queries
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

        now_ns = int(time.time() * 1_000_000_000)

        # Insert events in the San Francisco Financial District area
        batch = client.create_batch()
        locations = [
            # Inside the polygon (Financial District)
            {"name": "Transamerica Pyramid", "lat": 37.7952, "lon": -122.4028},
            {"name": "Salesforce Tower", "lat": 37.7897, "lon": -122.3972},
            {"name": "Embarcadero Center", "lat": 37.7946, "lon": -122.3984},
            # Outside the polygon (other areas)
            {"name": "Golden Gate Bridge", "lat": 37.8199, "lon": -122.4783},
            {"name": "Alcatraz", "lat": 37.8270, "lon": -122.4230},
            {"name": "Twin Peaks", "lat": 37.7544, "lon": -122.4477},
        ]

        for i, loc in enumerate(locations):
            event = GeoEvent(
                entity_id=random.randint(1, 2**63),
                latitude=loc["lat"],
                longitude=loc["lon"],
                timestamp=now_ns + i,
                group_id=1,
            )
            batch.add(event)
            print(f"  Added {loc['name']}: ({loc['lat']:.4f}, {loc['lon']:.4f})")

        errors = batch.commit()
        print(f"\nInserted {len(locations)} events\n")

        # Define a polygon around the Financial District
        # Vertices must be in order (clockwise or counter-clockwise)
        financial_district_polygon = [
            (37.7980, -122.4050),  # Northwest corner
            (37.7980, -122.3900),  # Northeast corner
            (37.7860, -122.3900),  # Southeast corner
            (37.7860, -122.4050),  # Southwest corner
        ]

        # Query events within the Financial District polygon
        print("Querying Financial District polygon:")
        print(f"  Vertices: {financial_district_polygon}\n")

        result = client.query_polygon(
            vertices=financial_district_polygon,
        )

        print(f"Found {len(result.events)} events inside Financial District:")
        for event in result.events:
            # Find the name
            name = "Unknown"
            for loc in locations:
                if abs(event.latitude - loc["lat"]) < 0.0001 and abs(event.longitude - loc["lon"]) < 0.0001:
                    name = loc["name"]
                    break
            print(f"  {name}: ({event.latitude:.4f}, {event.longitude:.4f})")

        # Compare with radius query from center of polygon
        center_lat = 37.7920
        center_lon = -122.3975
        radius_m = 1000  # 1km

        result_radius = client.query_radius(
            latitude=center_lat,
            longitude=center_lon,
            radius_m=radius_m,
        )

        print(f"\nRadius query (1km from center): {len(result_radius.events)} events")
        print("(Radius queries cover circular areas; polygons allow precise boundaries)")

        print("\nok")


if __name__ == "__main__":
    main()
