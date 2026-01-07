# Getting Started with ArcherDB

This guide walks you through setting up ArcherDB and performing basic operations using the client SDKs.

## Prerequisites

- **Operating System**: Linux (kernel >= 5.6), macOS, or Windows
- **SDK Requirements**:
  - Node.js: Node.js 18+ with npm
  - Python: Python 3.9+
  - Go: Go 1.17+

## Installation

### Option 1: Pre-built Binaries

Download the latest release from [GitHub Releases](https://github.com/ArcherDB-io/archerdb/releases):

```bash
# Linux (x86_64)
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-linux-x86_64.tar.gz | tar xz

# macOS (Apple Silicon)
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-macos-aarch64.tar.gz | tar xz
```

### Option 2: Build from Source

```bash
# Clone the repository
git clone https://github.com/ArcherDB-io/archerdb.git
cd archerdb

# Download the bundled Zig compiler
./zig/download.sh

# Build
./zig/zig build
```

The binary will be at `./zig-out/bin/archerdb`.

## Starting a Cluster

### Single-Node Development Cluster

For development and testing:

```bash
# Format the data file
./archerdb format --cluster=0 --replica=0 --replica-count=1 data.archerdb

# Start the server
./archerdb start --addresses=3000 data.archerdb
```

### Production Three-Node Cluster

For production, use three replicas for fault tolerance (survives 1 failure):

```bash
# On node 1 (192.168.1.1)
./archerdb format --cluster=12345 --replica=0 --replica-count=3 /data/archerdb.db
./archerdb start --addresses=192.168.1.1:3000,192.168.1.2:3000,192.168.1.3:3000 /data/archerdb.db

# On node 2 (192.168.1.2)
./archerdb format --cluster=12345 --replica=1 --replica-count=3 /data/archerdb.db
./archerdb start --addresses=192.168.1.1:3000,192.168.1.2:3000,192.168.1.3:3000 /data/archerdb.db

# On node 3 (192.168.1.3)
./archerdb format --cluster=12345 --replica=2 --replica-count=3 /data/archerdb.db
./archerdb start --addresses=192.168.1.1:3000,192.168.1.2:3000,192.168.1.3:3000 /data/archerdb.db
```

## SDK Installation

### Node.js

```bash
npm install archerdb-node
```

### Python

```bash
pip install archerdb
```

### Go

```bash
go get github.com/archerdb/archerdb-go
```

## Quick Start Example

### Creating a Client

#### Node.js

```typescript
import { createGeoClient, id, createGeoEvent } from 'archerdb-node'

const client = await createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3000'],
})
```

#### Python

```python
import archerdb

client = archerdb.GeoClientSync(archerdb.GeoClientConfig(
    cluster_id=0,
    addresses=['127.0.0.1:3000']
))
```

#### Go

```go
import (
    archerdb "github.com/archerdb/archerdb-go"
    "github.com/archerdb/archerdb-go/pkg/types"
)

client, err := archerdb.NewClient(types.ToUint128(0), []string{"127.0.0.1:3000"})
if err != nil {
    log.Fatal(err)
}
defer client.Close()
```

### Inserting Location Events

Create and insert geospatial events representing vehicle/device locations:

#### Node.js

```typescript
// Create a batch of events
const batch = client.createBatch()

// Add a location event
const event = createGeoEvent({
  entity_id: id(),           // Unique vehicle/device ID
  latitude: 37.7749,         // San Francisco
  longitude: -122.4194,
  velocity_mms: 15000,       // 15 m/s (54 km/h)
  heading_cdeg: 4500,        // 45 degrees (northeast)
  group_id: 1n,              // Fleet ID
})

batch.add(event)

// Commit the batch (waits for replication)
const results = await batch.commit()

// Check for per-event errors
for (const result of results) {
  if (result.error) {
    console.error(`Event ${result.index} failed: ${result.error}`)
  }
}
```

#### Python

```python
# Create a batch
batch = client.create_batch()

# Add a location event
event = archerdb.create_geo_event(
    entity_id=archerdb.id(),
    latitude=37.7749,
    longitude=-122.4194,
    velocity_mms=15000,
    heading_cdeg=4500,
    group_id=1,
)

batch.add(event)

# Commit and check results
results = batch.commit()
for result in results:
    if result.error:
        print(f"Event {result.index} failed: {result.error}")
```

#### Go

```go
// Create events
events := []types.GeoEvent{
    {
        EntityID:    types.ID(),
        LatNano:     37774900000,  // 37.7749 degrees in nanodegrees
        LonNano:     -122419400000,
        VelocityMms: 15000,
        HeadingCdeg: 4500,
        GroupID:     1,
    },
}

// Insert events
results, err := client.CreateEvents(events)
if err != nil {
    log.Fatal(err)
}

// Check per-event results
for _, result := range results {
    if result.Result != 0 {
        log.Printf("Event %d failed: %v", result.Index, result.Result)
    }
}
```

### Querying by Location

Find all entities within a radius of a point:

#### Node.js

```typescript
// Query within 1km of downtown San Francisco
const results = await client.queryRadius({
  center_lat: 37.7749,
  center_lon: -122.4194,
  radius_m: 1000,            // 1 kilometer
  limit: 100,
})

console.log(`Found ${results.events.length} entities`)

for (const event of results.events) {
  console.log(`Entity ${event.entity_id}: ${event.lat_nano}, ${event.lon_nano}`)
}

// Handle pagination if more results exist
if (results.has_more) {
  const nextPage = await client.queryRadius({
    center_lat: 37.7749,
    center_lon: -122.4194,
    radius_m: 1000,
    limit: 100,
    cursor: results.cursor,
  })
}
```

#### Python

```python
# Query within 1km radius
results = client.query_radius(
    center_lat=37.7749,
    center_lon=-122.4194,
    radius_m=1000,
    limit=100,
)

print(f"Found {len(results.events)} entities")

for event in results.events:
    print(f"Entity {event.entity_id}: {event.lat_nano}, {event.lon_nano}")

# Pagination
while results.has_more:
    results = client.query_radius(
        center_lat=37.7749,
        center_lon=-122.4194,
        radius_m=1000,
        limit=100,
        cursor=results.cursor,
    )
```

### Polygon Queries

Find entities within a geographic boundary:

#### Node.js

```typescript
// Define a polygon (counter-clockwise winding)
const polygon = [
  { lat: 37.78, lon: -122.42 },  // NW corner
  { lat: 37.78, lon: -122.40 },  // NE corner
  { lat: 37.76, lon: -122.40 },  // SE corner
  { lat: 37.76, lon: -122.42 },  // SW corner
]

const results = await client.queryPolygon({
  vertices: polygon,
  limit: 1000,
})
```

#### Python

```python
# Define polygon vertices (counter-clockwise)
polygon = [
    (37.78, -122.42),
    (37.78, -122.40),
    (37.76, -122.40),
    (37.76, -122.42),
]

results = client.query_polygon(vertices=polygon, limit=1000)
```

#### Go

```go
vertices := [][]float64{
    {37.78, -122.42},
    {37.78, -122.40},
    {37.76, -122.40},
    {37.76, -122.42},
}

filter, err := types.NewPolygonQuery(vertices, 1000)
if err != nil {
    log.Fatal(err)
}
// Use filter with client.QueryPolygon()
```

### Polygon Queries with Holes

Exclude regions within a polygon (e.g., parks, lakes, restricted zones):

#### Node.js

```typescript
// Outer boundary (counter-clockwise)
const boundary = [
  { lat: 37.79, lon: -122.42 },
  { lat: 37.79, lon: -122.39 },
  { lat: 37.76, lon: -122.39 },
  { lat: 37.76, lon: -122.42 },
]

// Hole to exclude (clockwise winding)
const parkHole = [
  { lat: 37.78, lon: -122.41 },
  { lat: 37.775, lon: -122.41 },
  { lat: 37.775, lon: -122.40 },
  { lat: 37.78, lon: -122.40 },
]

const results = await client.queryPolygon({
  vertices: boundary,
  holes: [parkHole],  // Can include multiple holes (up to 100)
  limit: 1000,
})
```

#### Python

```python
# Outer boundary (counter-clockwise)
boundary = [
    (37.79, -122.42),
    (37.79, -122.39),
    (37.76, -122.39),
    (37.76, -122.42),
]

# Hole to exclude (clockwise winding)
park_hole = [
    (37.78, -122.41),
    (37.775, -122.41),
    (37.775, -122.40),
    (37.78, -122.40),
]

results = client.query_polygon(
    vertices=boundary,
    holes=[park_hole],  # Can include multiple holes (up to 100)
    limit=1000,
)
```

#### Go

```go
boundary := [][]float64{
    {37.79, -122.42},
    {37.79, -122.39},
    {37.76, -122.39},
    {37.76, -122.42},
}

parkHole := [][]float64{
    {37.78, -122.41},
    {37.775, -122.41},
    {37.775, -122.40},
    {37.78, -122.40},
}

filter, err := types.NewPolygonQuery(boundary, 1000, parkHole)
if err != nil {
    log.Fatal(err)
}
// Points inside the park hole will be excluded from results
```

#### Java

```java
QueryPolygonFilter filter = new QueryPolygonFilter.Builder()
    // Outer boundary (counter-clockwise)
    .addVertex(37.79, -122.42)
    .addVertex(37.79, -122.39)
    .addVertex(37.76, -122.39)
    .addVertex(37.76, -122.42)
    // Hole (clockwise)
    .startHole()
    .addHoleVertex(37.78, -122.41)
    .addHoleVertex(37.775, -122.41)
    .addHoleVertex(37.775, -122.40)
    .addHoleVertex(37.78, -122.40)
    .finishHole()
    .setLimit(1000)
    .build();
```

**Polygon Hole Constraints:**
- Maximum 100 holes per polygon
- Each hole must have at least 3 vertices
- Outer boundary: counter-clockwise winding order
- Holes: clockwise winding order
- Holes must be fully contained within the outer boundary
- Holes must not overlap with each other

### Getting Latest Position

Retrieve the most recent location for specific entities:

#### Node.js

```typescript
// Get latest position for a single entity
const event = await client.getLatest(entityId)
if (event) {
  console.log(`Last seen at: ${event.lat_nano}, ${event.lon_nano}`)
}

// Batch lookup for multiple entities
const events = await client.getLatestBatch([entityId1, entityId2, entityId3])
```

#### Python

```python
# Single entity lookup
event = client.get_latest(entity_id)
if event:
    print(f"Last seen at: {event.lat_nano}, {event.lon_nano}")

# Batch lookup
events = client.get_latest_batch([entity_id1, entity_id2, entity_id3])
```

### Deleting Entities (GDPR Compliance)

Remove all data for specific entities:

#### Node.js

```typescript
const result = await client.deleteEntities([entityId1, entityId2])
console.log(`Deleted: ${result.deleted_count}, Not found: ${result.not_found_count}`)
```

#### Python

```python
result = client.delete_entities([entity_id1, entity_id2])
print(f"Deleted: {result.deleted_count}, Not found: {result.not_found_count}")
```

## Error Handling

All SDKs provide typed errors for proper handling:

### Node.js

```typescript
import {
  ArcherDBError,
  InvalidCoordinates,
  ClusterUnavailable,
  OperationTimeout,
  RetryExhausted,
} from 'archerdb-node'

try {
  await batch.commit()
} catch (error) {
  if (error instanceof InvalidCoordinates) {
    console.error('Bad coordinates:', error.message)
  } else if (error instanceof ClusterUnavailable) {
    console.error('Cluster down, retry later')
  } else if (error instanceof OperationTimeout) {
    console.error('Timeout - operation may have committed')
  } else if (error instanceof RetryExhausted) {
    console.error(`Failed after ${error.attempts} attempts`)
  }
}
```

### Python

```python
from archerdb import (
    ArcherDBError,
    InvalidCoordinates,
    ClusterUnavailable,
    OperationTimeout,
    RetryExhausted,
)

try:
    batch.commit()
except InvalidCoordinates as e:
    print(f"Bad coordinates: {e}")
except ClusterUnavailable:
    print("Cluster down, retry later")
except OperationTimeout:
    print("Timeout - operation may have committed")
except RetryExhausted as e:
    print(f"Failed after {e.attempts} attempts")
```

## Configuration Options

### Client Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `cluster_id` | Required | Cluster identifier for connection validation |
| `addresses` | Required | List of replica addresses |
| `connect_timeout_ms` | 5000 | Connection timeout |
| `request_timeout_ms` | 30000 | Request timeout |
| `pool_size` | 1 | Connection pool size |

### Retry Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | true | Enable automatic retry |
| `max_retries` | 5 | Maximum retry attempts |
| `base_backoff_ms` | 100 | Base delay for backoff |
| `max_backoff_ms` | 1600 | Maximum backoff delay |
| `total_timeout_ms` | 30000 | Total timeout for all attempts |
| `jitter` | true | Add random jitter to delays |

See [SDK Retry Semantics](sdk-retry-semantics.md) for detailed retry documentation.

## Data Model

### GeoEvent Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | u128 | Auto-generated composite key |
| `entity_id` | u128 | Unique vehicle/device identifier |
| `correlation_id` | u128 | Trip/session/job correlation |
| `user_data` | u128 | Application metadata |
| `lat_nano` | i64 | Latitude in nanodegrees |
| `lon_nano` | i64 | Longitude in nanodegrees |
| `group_id` | u64 | Fleet/region identifier |
| `altitude_mm` | i32 | Altitude in millimeters |
| `velocity_mms` | u32 | Speed in mm/s |
| `ttl_seconds` | u32 | Time-to-live (0 = never) |
| `accuracy_mm` | u32 | GPS accuracy radius |
| `heading_cdeg` | u16 | Heading in centidegrees |
| `flags` | u16 | Status bitmask |

### Coordinate Conversion

```
latitude_nanodegrees = latitude_degrees × 1,000,000,000
longitude_nanodegrees = longitude_degrees × 1,000,000,000
altitude_mm = altitude_meters × 1,000
velocity_mms = velocity_mps × 1,000
heading_cdeg = heading_degrees × 100
```

## Best Practices

1. **Use upsert over insert** - Upsert operations are idempotent and safe to retry.

2. **Batch operations** - Send multiple events per batch (up to 10,000) for better throughput.

3. **Use group_id for filtering** - Assign fleet/region IDs to reduce query scope.

4. **Handle timeouts carefully** - A timeout doesn't mean the operation failed; it may have committed.

5. **Monitor retry metrics** - Track retry counts to detect cluster issues early.

6. **Set appropriate TTL** - Use `ttl_seconds` for data that can be pruned automatically.

## Next Steps

- [Operations Runbook](operations-runbook.md) - Production deployment guide
- [Disaster Recovery](disaster-recovery.md) - Backup and restore procedures
- [SDK Retry Semantics](sdk-retry-semantics.md) - Detailed retry behavior
- [API Reference](api-reference.md) - Complete API documentation
