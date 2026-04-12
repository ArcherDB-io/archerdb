# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors

import os
import sys
import time
import pytest
import faulthandler
faulthandler.enable()

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

from archerdb.client import GeoClientSync, GeoClientConfig, id as gen_id
from archerdb.types import create_geo_event

def reproduce():
    print("Starting reproduction...")
    address = os.environ.get("ARCHERDB_ADDRESS", "127.0.0.1:3001")
    
    print(f"Connecting to {address}...")
    config = GeoClientConfig(
        cluster_id=0,
        addresses=[address]
    )
    client = GeoClientSync(config)
    
    try:
        print("Connected.")
        entity_id = gen_id()
        event = create_geo_event(
            entity_id=entity_id,
            latitude=37.7749,
            longitude=-122.4194,
            ttl_seconds=60
        )
        
        print("Inserting event...")
        client.insert_events([event])
        print("Insert done.")

        print("Querying latest...")
        found = client.get_latest_by_uuid(entity_id)
        if found:
            print("Found.")
        else:
            print("Not found.")

        print("Querying radius...")
        client.query_radius(
            latitude=37.7749,
            longitude=-122.4194,
            radius_m=2000,
            limit=5,
        )
        print("Radius query done.")

        print("Querying global latest...")
        client.query_latest(limit=5)
        print("Latest query done.")
        
        # Short sleep to allow IO thread to work
        time.sleep(0.1)
        
    finally:
        print("Closing client...")
        client.close()
        print("Client closed.")

if __name__ == "__main__":
    reproduce()
