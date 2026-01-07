# archerdb-python

The ArcherDB Python client for high-performance geospatial data storage and queries.

## Prerequisites

Linux >= 5.6 is the only production environment we support. For development, macOS and Windows are also supported.

* Python >= 3.7

## Installation

```console
pip install archerdb
```

## Quick Start

```python
from archerdb import GeoClientSync, GeoClientConfig, GeoEvent
import time

# Connect to ArcherDB cluster
config = GeoClientConfig(
    cluster_id=0,
    addresses=["127.0.0.1:3001"],
)

with GeoClientSync(config) as client:
    # Insert a geo event
    event = GeoEvent(
        entity_id=0x12345678,  # UUID of the tracked entity
        latitude=37.7749,      # San Francisco
        longitude=-122.4194,
        timestamp_ns=time.time_ns(),
        group_id=1,            # Fleet/region grouping
    )

    errors = client.insert_events([event])
    if not errors:
        print("Event inserted successfully!")

    # Query events within 1km radius
    results = client.query_radius(
        center_lat=37.7749,
        center_lon=-122.4194,
        radius_meters=1000,
        limit=100,
    )

    print(f"Found {len(results.events)} events within 1km")
```

## Sample Projects

* [Basic](/src/clients/python/samples/basic/): Insert and query geospatial events.
* [Radius Query](/src/clients/python/samples/radius-query/): Advanced radius queries with pagination.
* [Polygon Query](/src/clients/python/samples/polygon-query/): Geofence-based polygon queries.

## API Reference

### Creating a Client

```python
from archerdb import GeoClientSync, GeoClientAsync, GeoClientConfig

# Synchronous client
config = GeoClientConfig(
    cluster_id=0,
    addresses=["127.0.0.1:3001", "127.0.0.1:3002", "127.0.0.1:3003"],
)

with GeoClientSync(config) as client:
    # Use the client
    pass

# Asynchronous client
async with GeoClientAsync(config) as client:
    # Use the client with async/await
    pass
```

### GeoEvent Structure

```python
from archerdb import GeoEvent

event = GeoEvent(
    entity_id=0x12345678,     # u128: UUID of the tracked entity
    latitude=37.7749,         # f64: Degrees (-90 to +90)
    longitude=-122.4194,      # f64: Degrees (-180 to +180)
    timestamp_ns=1704067200_000_000_000,  # u64: Nanoseconds since epoch
    group_id=1,               # u64: Fleet/region grouping (optional)
    correlation_id=0,         # u128: Trip/session correlation (optional)
    user_data=0,              # u128: Application metadata (optional)
    altitude_mm=0,            # i32: Altitude in millimeters (optional)
    speed_mmps=0,             # u32: Speed in mm/s (optional)
    heading_microdeg=0,       # u32: Heading in microdegrees (optional)
    accuracy_mm=0,            # u32: GPS accuracy in mm (optional)
    status=0,                 # u16: Application status flags (optional)
    event_type=0,             # u8: Event type code (optional)
)
```

### Insert Events

```python
events = [
    GeoEvent(entity_id=1, latitude=37.7749, longitude=-122.4194, timestamp_ns=now),
    GeoEvent(entity_id=2, latitude=37.7849, longitude=-122.4094, timestamp_ns=now),
]

errors = client.insert_events(events)
for error in errors:
    print(f"Event {error.index} failed: {error.result}")
```

### Upsert Events

Upsert inserts new events or updates existing ones (based on composite ID).

```python
errors = client.upsert_events(events)
```

### Query by Radius

```python
results = client.query_radius(
    center_lat=37.7749,
    center_lon=-122.4194,
    radius_meters=5000,        # 5km radius
    limit=1000,                # Max results per page
    timestamp_min=start_ns,    # Optional: filter by time range
    timestamp_max=end_ns,
    group_id=1,                # Optional: filter by group
)

for event in results.events:
    print(f"Entity {event.entity_id} at ({event.latitude}, {event.longitude})")

# Pagination
if results.has_more:
    next_results = client.query_radius(
        center_lat=37.7749,
        center_lon=-122.4194,
        radius_meters=5000,
        limit=1000,
        cursor=results.cursor,  # Continue from last position
    )
```

### Query by Polygon

```python
# Define polygon vertices (counter-clockwise winding)
vertices = [
    (37.78, -122.42),  # (lat, lon)
    (37.78, -122.40),
    (37.76, -122.40),
    (37.76, -122.42),
]

results = client.query_polygon(
    vertices=vertices,
    limit=1000,
    timestamp_min=start_ns,
    timestamp_max=end_ns,
)
```

### Query Latest by Entity UUID

```python
# Get latest event for a single entity
event = client.get_latest_by_uuid(entity_id=0x12345678)

if event:
    print(f"Last seen at ({event.latitude}, {event.longitude})")
```

### Query Latest Events

```python
results = client.query_latest(
    limit=100,
    timestamp_min=start_ns,
    group_id=1,  # Optional filter
)

for event in results.events:
    print(f"Entity {event.entity_id}: {event.latitude}, {event.longitude}")
```

### Delete Entities

GDPR-compliant deletion of all events for specified entities.

```python
result = client.delete_entities([entity_id_1, entity_id_2])
print(f"Deleted {result.deleted_count} entities")
```

## Error Handling

```python
from archerdb import ArcherDBError, ConnectionError, ValidationError

try:
    results = client.query_radius(
        center_lat=91.0,  # Invalid: exceeds 90
        center_lon=-122.4194,
        radius_meters=1000,
    )
except ValidationError as e:
    print(f"Invalid input: {e}")
except ConnectionError as e:
    print(f"Connection failed: {e}")
except ArcherDBError as e:
    print(f"ArcherDB error: {e}")
```

## Performance Tips

1. **Batch operations**: Always batch inserts (up to 10,000 events per call).
2. **Reuse client**: Create one client and share across threads.
3. **Use pagination**: For large result sets, use cursor-based pagination.
4. **Filter early**: Use `group_id` and time filters to reduce result size.

```python
# Efficient batching
BATCH_SIZE = 8000
for i in range(0, len(events), BATCH_SIZE):
    batch = events[i:i + BATCH_SIZE]
    errors = client.insert_events(batch)
```

## Thread Safety

The client is thread-safe. A single instance should be shared across threads:

```python
import threading

client = GeoClientSync(config)

def worker():
    events = [...]
    client.insert_events(events)

threads = [threading.Thread(target=worker) for _ in range(10)]
for t in threads:
    t.start()
for t in threads:
    t.join()

client.close()
```

## Async Support

For asyncio applications:

```python
import asyncio
from archerdb import GeoClientAsync, GeoClientConfig

async def main():
    config = GeoClientConfig(cluster_id=0, addresses=["127.0.0.1:3001"])

    async with GeoClientAsync(config) as client:
        errors = await client.insert_events(events)
        results = await client.query_radius(37.7749, -122.4194, 1000)
        print(f"Found {len(results.events)} events")

asyncio.run(main())
```

## Links

* [ArcherDB Documentation](https://github.com/ArcherDB-io/archerdb)
* [Client SDK Specification](/openspec/changes/add-geospatial-core/specs/client-sdk/spec.md)
