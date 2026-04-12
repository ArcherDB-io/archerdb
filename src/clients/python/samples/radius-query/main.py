#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""
ArcherDB Radius Query Sample - Advanced Spatial Queries

This sample demonstrates:
1. Inserting events at known locations
2. Performing radius queries with different parameters
3. Time-range filtering within radius queries
4. Pagination of results
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

        # Insert events at known distances from a center point
        # Using Golden Gate Park as center
        center_lat = 37.7694
        center_lon = -122.4862

        now_ns = int(time.time() * 1_000_000_000)

        batch = client.create_batch()
        events_data = [
            # Entity at 100m away
            {"lat": 37.7703, "lon": -122.4862, "dist": "~100m"},
            # Entity at 500m away
            {"lat": 37.7739, "lon": -122.4862, "dist": "~500m"},
            # Entity at 1km away
            {"lat": 37.7784, "lon": -122.4862, "dist": "~1km"},
            # Entity at 2km away
            {"lat": 37.7874, "lon": -122.4862, "dist": "~2km"},
            # Entity at 5km away (in Pacific Ocean direction)
            {"lat": 37.7694, "lon": -122.5412, "dist": "~5km"},
        ]

        for i, data in enumerate(events_data):
            event = GeoEvent(
                entity_id=random.randint(1, 2**63),
                latitude=data["lat"],
                longitude=data["lon"],
                timestamp=now_ns + i,
                group_id=1,
            )
            batch.add(event)

        errors = batch.commit()
        print(f"Inserted {len(events_data)} events at various distances\n")

        # Query 1: Find everything within 200m
        result = client.query_radius(
            latitude=center_lat,
            longitude=center_lon,
            radius_m=200,
        )
        print(f"Within 200m: {len(result.events)} events")

        # Query 2: Find everything within 600m
        result = client.query_radius(
            latitude=center_lat,
            longitude=center_lon,
            radius_m=600,
        )
        print(f"Within 600m: {len(result.events)} events")

        # Query 3: Find everything within 1.5km
        result = client.query_radius(
            latitude=center_lat,
            longitude=center_lon,
            radius_m=1500,
        )
        print(f"Within 1.5km: {len(result.events)} events")

        # Query 4: Find everything within 3km
        result = client.query_radius(
            latitude=center_lat,
            longitude=center_lon,
            radius_m=3000,
        )
        print(f"Within 3km: {len(result.events)} events")

        # Query 5: Find everything within 10km (should get all)
        result = client.query_radius(
            latitude=center_lat,
            longitude=center_lon,
            radius_m=10000,
        )
        print(f"Within 10km: {len(result.events)} events")

        # Query with pagination
        print("\nPagination example (limit 2 per page):")
        result = client.query_radius(
            latitude=center_lat,
            longitude=center_lon,
            radius_m=10000,
            limit=2,
        )
        print(f"  Page 1: {len(result.events)} events, has_more={result.has_more}")

        if result.has_more and result.cursor:
            result2 = client.query_radius(
                latitude=center_lat,
                longitude=center_lon,
                radius_m=10000,
                limit=2,
                timestamp_max=result.cursor - 1,  # Use cursor for pagination
            )
            print(f"  Page 2: {len(result2.events)} events, has_more={result2.has_more}")

        print("\nok")


if __name__ == "__main__":
    main()
