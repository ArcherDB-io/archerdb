# Getting Started with ArcherDB

## Time to First Query

**Total time: ~10 minutes**

| Section | Time | Description |
|---------|------|-------------|
| Prerequisites | 0 min | Verify requirements |
| Installation | 2 min | Download binary |
| Starting cluster | 1 min | Format and start |
| SDK installation | 1 min | Install your language |
| Hello World | 3 min | Insert and query |
| Next steps | 1 min | What to explore |

This guide gets you to your first spatial query quickly, then shows you the full capabilities.

## Prerequisites

- **Operating System**: Linux (kernel >= 5.6), macOS, or Windows
- **For SDKs**: Python 3.9+, Node.js 18+, Go 1.21+, or Java 11+

## Security Boundary Note

ArcherDB expects security controls at the infrastructure boundary:

- Authentication/authorization at your API or gateway layer
- TLS/mTLS in gateway/service mesh or private network transport
- Encryption at rest and key management in storage/cloud platform
- Backup orchestration via external snapshot/backup tooling

## Installation (~2 min)

Download the pre-built binary for your platform:

<details open>
<summary>Linux (x86_64)</summary>

```bash
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-linux-x86_64.tar.gz | tar xz
sudo mv archerdb /usr/local/bin/
archerdb --version
```

</details>

<details>
<summary>macOS (Apple Silicon)</summary>

```bash
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-macos-aarch64.tar.gz | tar xz
sudo mv archerdb /usr/local/bin/
archerdb --version
```

</details>

<details>
<summary>macOS (Intel)</summary>

```bash
curl -L https://github.com/ArcherDB-io/archerdb/releases/latest/download/archerdb-macos-x86_64.tar.gz | tar xz
sudo mv archerdb /usr/local/bin/
archerdb --version
```

</details>

<details>
<summary>Build from Source</summary>

```bash
git clone https://github.com/ArcherDB-io/archerdb.git
cd archerdb
./zig/download.sh
./zig/zig build
# Binary at ./zig-out/bin/archerdb
```

</details>

## Choose a Tier

ArcherDB binaries are intended to be distributed by tier:

- `lite` (recommended for demos/evaluation): fastest first-run experience, low footprint, intentionally storage-limited.
- `standard`: baseline production profile.
- `pro`: higher-performance mainstream profile.
- `enterprise`: high-end production profile.
- `ultra`: top-end profile.

If building from source, choose a tier explicitly:

```bash
./zig/zig build -Dconfig=lite
# or: standard, pro, enterprise, ultra
```

## Starting a Cluster (~1 min)

### Single-Node Development

```bash
# Format data file (cluster=0 for dev)
archerdb format --cluster=0 --replica=0 --replica-count=1 data.archerdb

# Start server on port 3000
archerdb start --addresses=3000 data.archerdb
```

You should see: `info: server ready on 127.0.0.1:3000`

### Production Three-Node Cluster

For fault tolerance (survives 1 node failure):

```bash
# Node 1 (192.168.1.1)
archerdb format --cluster=12345 --replica=0 --replica-count=3 /data/archerdb.db
archerdb start --addresses=192.168.1.1:3000,192.168.1.2:3000,192.168.1.3:3000 /data/archerdb.db

# Node 2 (192.168.1.2)
archerdb format --cluster=12345 --replica=1 --replica-count=3 /data/archerdb.db
archerdb start --addresses=192.168.1.1:3000,192.168.1.2:3000,192.168.1.3:3000 /data/archerdb.db

# Node 3 (192.168.1.3)
archerdb format --cluster=12345 --replica=2 --replica-count=3 /data/archerdb.db
archerdb start --addresses=192.168.1.1:3000,192.168.1.2:3000,192.168.1.3:3000 /data/archerdb.db
```

## SDK Installation (~1 min)

<details open>
<summary>Python</summary>

```bash
pip install archerdb
```

</details>

<details>
<summary>Node.js</summary>

```bash
npm install archerdb-node
```

</details>

<details>
<summary>Go</summary>

```bash
go get github.com/archerdb/archerdb-go
```

</details>

<details>
<summary>Java (Maven)</summary>

```xml
<dependency>
    <groupId>com.archerdb</groupId>
    <artifactId>archerdb-java</artifactId>
    <version>1.0.0</version>
</dependency>
```

Or Gradle:

```groovy
implementation 'com.archerdb:archerdb-java:1.0.0'
```

</details>

<details>
<summary>curl (no SDK)</summary>

Use curl directly - no installation needed.

</details>

## Hello World: Vehicle Tracking (~3 min)

This example demonstrates the core value of ArcherDB: track vehicles and find nearby pickups.

**Scenario:** A delivery vehicle needs to find pickup locations within 1km.

### Step 1: Create Client

<details open>
<summary>Python</summary>

```python
import archerdb

client = archerdb.GeoClientSync(archerdb.GeoClientConfig(
    cluster_id=0,
    addresses=['127.0.0.1:3000']
))
```

</details>

<details>
<summary>Node.js</summary>

```javascript
const { createGeoClient, createGeoEvent, id } = require('archerdb-node')

const client = createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3000'],
})
```

</details>

<details>
<summary>Go</summary>

```go
import (
    archerdb "github.com/archerdb/archerdb-go"
    "github.com/archerdb/archerdb-go/pkg/types"
)

client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
    ClusterID: types.ToUint128(0),
    Addresses: []string{"127.0.0.1:3000"},
})
if err != nil {
    log.Fatal(err)
}
defer client.Close()
```

</details>

<details>
<summary>Java</summary>

```java
import com.archerdb.geo.*;

GeoClient client = GeoClient.create(0L, "127.0.0.1:3000");
```

</details>

<details>
<summary>curl</summary>

```bash
# No client setup needed - use curl directly
BASE_URL="http://127.0.0.1:3000"
```

</details>

### Step 2: Insert Delivery Vehicle

Insert the vehicle at SF city center (37.7749, -122.4194):

<details open>
<summary>Python</summary>

```python
vehicle_id = archerdb.id()
vehicle = archerdb.create_geo_event(
    entity_id=vehicle_id,
    latitude=37.7749,      # SF city center
    longitude=-122.4194,
    group_id=1,            # Fleet ID
)
client.insert_events([vehicle])
print(f"Vehicle {vehicle_id} inserted")
```

</details>

<details>
<summary>Node.js</summary>

```javascript
const vehicleId = id()
const vehicle = createGeoEvent({
  entity_id: vehicleId,
  latitude: 37.7749,      // SF city center
  longitude: -122.4194,
  group_id: 1n,           // Fleet ID
})
await client.insertEvents([vehicle])
console.log(`Vehicle ${vehicleId} inserted`)
```

</details>

<details>
<summary>Go</summary>

```go
vehicleID := types.ID()
vehicle, _ := types.NewGeoEvent(types.GeoEventOptions{
    EntityID:  vehicleID,
    Latitude:  37.7749,      // SF city center
    Longitude: -122.4194,
    GroupID:   1,            // Fleet ID
})
client.InsertEvents([]types.GeoEvent{vehicle})
fmt.Printf("Vehicle %s inserted\n", vehicleID)
```

</details>

<details>
<summary>Java</summary>

```java
UInt128 vehicleId = UInt128.random();
GeoEvent vehicle = new GeoEvent.Builder()
    .setEntityId(vehicleId)
    .setLatitude(37.7749)      // SF city center
    .setLongitude(-122.4194)
    .setGroupId(1L)            // Fleet ID
    .build();

GeoEventBatch batch = client.createBatch();
batch.add(vehicle);
batch.commit();
System.out.println("Vehicle " + vehicleId + " inserted");
```

</details>

<details>
<summary>curl</summary>

```bash
curl -X POST $BASE_URL/insert \
  -H "Content-Type: application/json" \
  -d '{
    "events": [{
      "entity_id": "00000000-0000-0000-0000-000000000001",
      "lat_nano": 37774900000,
      "lon_nano": -122419400000,
      "group_id": 1
    }]
  }'
```

</details>

### Step 3: Insert Nearby Pickup Locations

Add two pickup locations near the vehicle:

| Location | Coordinates | Distance from Vehicle |
|----------|-------------|----------------------|
| Pickup 1 | 37.7751, -122.4180 | ~200m east |
| Pickup 2 | 37.7760, -122.4200 | ~150m north |

<details open>
<summary>Python</summary>

```python
# Pickup 1: 200m east of vehicle
pickup1 = archerdb.create_geo_event(
    entity_id=archerdb.id(),
    latitude=37.7751,
    longitude=-122.4180,
    group_id=2,  # Pickups group
)

# Pickup 2: 150m north of vehicle
pickup2 = archerdb.create_geo_event(
    entity_id=archerdb.id(),
    latitude=37.7760,
    longitude=-122.4200,
    group_id=2,
)

client.insert_events([pickup1, pickup2])
print("2 pickup locations inserted")
```

</details>

<details>
<summary>Node.js</summary>

```javascript
// Pickup 1: 200m east of vehicle
const pickup1 = createGeoEvent({
  entity_id: id(),
  latitude: 37.7751,
  longitude: -122.4180,
  group_id: 2n,  // Pickups group
})

// Pickup 2: 150m north of vehicle
const pickup2 = createGeoEvent({
  entity_id: id(),
  latitude: 37.7760,
  longitude: -122.4200,
  group_id: 2n,
})

await client.insertEvents([pickup1, pickup2])
console.log('2 pickup locations inserted')
```

</details>

<details>
<summary>Go</summary>

```go
// Pickup 1: 200m east of vehicle
pickup1, _ := types.NewGeoEvent(types.GeoEventOptions{
    EntityID:  types.ID(),
    Latitude:  37.7751,
    Longitude: -122.4180,
    GroupID:   2,  // Pickups group
})

// Pickup 2: 150m north of vehicle
pickup2, _ := types.NewGeoEvent(types.GeoEventOptions{
    EntityID:  types.ID(),
    Latitude:  37.7760,
    Longitude: -122.4200,
    GroupID:   2,
})

client.InsertEvents([]types.GeoEvent{pickup1, pickup2})
fmt.Println("2 pickup locations inserted")
```

</details>

<details>
<summary>Java</summary>

```java
// Pickup 1: 200m east of vehicle
GeoEvent pickup1 = new GeoEvent.Builder()
    .setEntityId(UInt128.random())
    .setLatitude(37.7751)
    .setLongitude(-122.4180)
    .setGroupId(2L)  // Pickups group
    .build();

// Pickup 2: 150m north of vehicle
GeoEvent pickup2 = new GeoEvent.Builder()
    .setEntityId(UInt128.random())
    .setLatitude(37.7760)
    .setLongitude(-122.4200)
    .setGroupId(2L)
    .build();

GeoEventBatch batch = client.createBatch();
batch.add(pickup1);
batch.add(pickup2);
batch.commit();
System.out.println("2 pickup locations inserted");
```

</details>

<details>
<summary>curl</summary>

```bash
curl -X POST $BASE_URL/insert \
  -H "Content-Type: application/json" \
  -d '{
    "events": [
      {
        "entity_id": "00000000-0000-0000-0000-000000000002",
        "lat_nano": 37775100000,
        "lon_nano": -122418000000,
        "group_id": 2
      },
      {
        "entity_id": "00000000-0000-0000-0000-000000000003",
        "lat_nano": 37776000000,
        "lon_nano": -122420000000,
        "group_id": 2
      }
    ]
  }'
```

</details>

### Step 4: Find Pickups Within 1km of Vehicle

Query for pickups near the vehicle's location:

<details open>
<summary>Python</summary>

```python
# Find all entities within 1km of vehicle
results = client.query_radius(
    center_lat=37.7749,
    center_lon=-122.4194,
    radius_m=1000,  # 1 kilometer
    limit=100,
)

print(f"Found {len(results.events)} entities within 1km of vehicle:")
for event in results.events:
    print(f"  Entity {event.entity_id} at ({event.latitude:.4f}, {event.longitude:.4f})")
```

Output:
```
Found 3 entities within 1km of vehicle:
  Entity 1234... at (37.7749, -122.4194)  # Vehicle
  Entity 5678... at (37.7751, -122.4180)  # Pickup 1
  Entity 9012... at (37.7760, -122.4200)  # Pickup 2
```

</details>

<details>
<summary>Node.js</summary>

```javascript
// Find all entities within 1km of vehicle
const results = await client.queryRadius({
  latitude: 37.7749,
  longitude: -122.4194,
  radius_m: 1000,  // 1 kilometer
  limit: 100,
})

console.log(`Found ${results.events.length} entities within 1km of vehicle:`)
for (const event of results.events) {
  console.log(`  Entity ${event.entity_id}`)
}
```

</details>

<details>
<summary>Go</summary>

```go
// Find all entities within 1km of vehicle
filter, _ := types.NewRadiusQuery(37.7749, -122.4194, 1000, 100)
results, _ := client.QueryRadius(filter)

fmt.Printf("Found %d entities within 1km of vehicle:\n", len(results.Events))
for _, event := range results.Events {
    fmt.Printf("  Entity %s at (%.4f, %.4f)\n",
        event.EntityID, event.Latitude(), event.Longitude())
}
```

</details>

<details>
<summary>Java</summary>

```java
// Find all entities within 1km of vehicle
QueryResult results = client.queryRadius(
    QueryRadiusFilter.create(37.7749, -122.4194, 1000, 100)
);

System.out.println("Found " + results.getEvents().size() + " entities within 1km of vehicle:");
for (GeoEvent event : results.getEvents()) {
    System.out.println("  Entity " + event.getEntityId());
}
```

</details>

<details>
<summary>curl</summary>

```bash
curl -X POST $BASE_URL/query/radius \
  -H "Content-Type: application/json" \
  -d '{
    "center_lat_nano": 37774900000,
    "center_lon_nano": -122419400000,
    "radius_m": 1000,
    "limit": 100
  }'
```

</details>

**Congratulations!** You've completed the core ArcherDB workflow: insert locations and find nearby entities.

## Additional Operations

### Polygon Queries (Geofencing)

Find entities within a geographic boundary:

<details>
<summary>Python</summary>

```python
# Define a polygon (counter-clockwise winding)
polygon = [
    (37.78, -122.42),  # NW corner
    (37.78, -122.40),  # NE corner
    (37.76, -122.40),  # SE corner
    (37.76, -122.42),  # SW corner
]

results = client.query_polygon(vertices=polygon, limit=1000)
print(f"Found {len(results.events)} entities in polygon")
```

</details>

<details>
<summary>Node.js</summary>

```javascript
const polygon = [
  { lat: 37.78, lon: -122.42 },
  { lat: 37.78, lon: -122.40 },
  { lat: 37.76, lon: -122.40 },
  { lat: 37.76, lon: -122.42 },
]

const results = await client.queryPolygon({ vertices: polygon, limit: 1000 })
console.log(`Found ${results.events.length} entities in polygon`)
```

</details>

<details>
<summary>Go</summary>

```go
vertices := [][]float64{
    {37.78, -122.42},
    {37.78, -122.40},
    {37.76, -122.40},
    {37.76, -122.42},
}

filter, _ := types.NewPolygonQuery(vertices, 1000)
results, _ := client.QueryPolygon(filter)
fmt.Printf("Found %d entities in polygon\n", len(results.Events))
```

</details>

<details>
<summary>Java</summary>

```java
QueryPolygonFilter filter = new QueryPolygonFilter.Builder()
    .addVertex(37.78, -122.42)
    .addVertex(37.78, -122.40)
    .addVertex(37.76, -122.40)
    .addVertex(37.76, -122.42)
    .setLimit(1000)
    .build();

QueryResult results = client.queryPolygon(filter);
System.out.println("Found " + results.getEvents().size() + " entities in polygon");
```

</details>

<details>
<summary>curl</summary>

```bash
curl -X POST $BASE_URL/query/polygon \
  -H "Content-Type: application/json" \
  -d '{
    "vertices": [
      {"lat_nano": 37780000000, "lon_nano": -122420000000},
      {"lat_nano": 37780000000, "lon_nano": -122400000000},
      {"lat_nano": 37760000000, "lon_nano": -122400000000},
      {"lat_nano": 37760000000, "lon_nano": -122420000000}
    ],
    "limit": 1000
  }'
```

</details>

### Polygon with Holes

Exclude regions (parks, lakes, restricted zones):

<details>
<summary>Python</summary>

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
    holes=[park_hole],  # Up to 100 holes
    limit=1000,
)
```

</details>

<details>
<summary>Node.js</summary>

```javascript
const boundary = [
  { lat: 37.79, lon: -122.42 },
  { lat: 37.79, lon: -122.39 },
  { lat: 37.76, lon: -122.39 },
  { lat: 37.76, lon: -122.42 },
]

const parkHole = [
  { lat: 37.78, lon: -122.41 },
  { lat: 37.775, lon: -122.41 },
  { lat: 37.775, lon: -122.40 },
  { lat: 37.78, lon: -122.40 },
]

const results = await client.queryPolygon({
  vertices: boundary,
  holes: [parkHole],
  limit: 1000,
})
```

</details>

<details>
<summary>Go</summary>

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

filter, _ := types.NewPolygonQuery(boundary, 1000, parkHole)
results, _ := client.QueryPolygon(filter)
```

</details>

<details>
<summary>Java</summary>

```java
QueryPolygonFilter filter = new QueryPolygonFilter.Builder()
    .addVertex(37.79, -122.42)
    .addVertex(37.79, -122.39)
    .addVertex(37.76, -122.39)
    .addVertex(37.76, -122.42)
    .startHole()
    .addHoleVertex(37.78, -122.41)
    .addHoleVertex(37.775, -122.41)
    .addHoleVertex(37.775, -122.40)
    .addHoleVertex(37.78, -122.40)
    .finishHole()
    .setLimit(1000)
    .build();
```

</details>

<details>
<summary>curl</summary>

```bash
curl -X POST $BASE_URL/query/polygon \
  -H "Content-Type: application/json" \
  -d '{
    "vertices": [
      {"lat_nano": 37790000000, "lon_nano": -122420000000},
      {"lat_nano": 37790000000, "lon_nano": -122390000000},
      {"lat_nano": 37760000000, "lon_nano": -122390000000},
      {"lat_nano": 37760000000, "lon_nano": -122420000000}
    ],
    "holes": [[
      {"lat_nano": 37780000000, "lon_nano": -122410000000},
      {"lat_nano": 37775000000, "lon_nano": -122410000000},
      {"lat_nano": 37775000000, "lon_nano": -122400000000},
      {"lat_nano": 37780000000, "lon_nano": -122400000000}
    ]],
    "limit": 1000
  }'
```

</details>

**Polygon constraints:**
- Outer boundary: counter-clockwise winding
- Holes: clockwise winding
- Maximum 100 holes per polygon
- Holes must be fully contained within boundary

### Get Latest Position

<details>
<summary>Python</summary>

```python
event = client.get_latest(entity_id)
if event:
    print(f"Last seen at: ({event.latitude:.4f}, {event.longitude:.4f})")

# Batch lookup
events = client.get_latest_batch([entity_id1, entity_id2, entity_id3])
```

</details>

<details>
<summary>Node.js</summary>

```javascript
const event = await client.getLatest(entityId)
if (event) {
  console.log(`Last seen at: (${event.latitude}, ${event.longitude})`)
}

// Batch lookup
const events = await client.getLatestBatch([entityId1, entityId2, entityId3])
```

</details>

<details>
<summary>Go</summary>

```go
event, err := client.GetLatest(entityID)
if err == nil && event != nil {
    fmt.Printf("Last seen at: (%.4f, %.4f)\n", event.Latitude(), event.Longitude())
}

// Batch lookup
events, _ := client.GetLatestBatch([]types.UInt128{entityID1, entityID2})
```

</details>

<details>
<summary>Java</summary>

```java
Optional<GeoEvent> event = client.getLatest(entityId);
event.ifPresent(e ->
    System.out.println("Last seen at: (" + e.getLatitude() + ", " + e.getLongitude() + ")")
);

// Batch lookup
List<GeoEvent> events = client.getLatestBatch(List.of(entityId1, entityId2));
```

</details>

<details>
<summary>curl</summary>

```bash
curl -X POST $BASE_URL/query/latest \
  -H "Content-Type: application/json" \
  -d '{"entity_ids": ["00000000-0000-0000-0000-000000000001"]}'
```

</details>

### Delete Entities (GDPR Compliance)

<details>
<summary>Python</summary>

```python
result = client.delete_entities([entity_id1, entity_id2])
print(f"Deleted: {result.deleted_count}")
```

</details>

<details>
<summary>Node.js</summary>

```javascript
const result = await client.deleteEntities([entityId1, entityId2])
console.log(`Deleted: ${result.deleted_count}`)
```

</details>

<details>
<summary>Go</summary>

```go
result, _ := client.DeleteEntities([]types.UInt128{entityID1, entityID2})
fmt.Printf("Deleted: %d\n", result.DeletedCount)
```

</details>

<details>
<summary>Java</summary>

```java
DeleteResult result = client.deleteEntities(List.of(entityId1, entityId2));
System.out.println("Deleted: " + result.getDeletedCount());
```

</details>

<details>
<summary>curl</summary>

```bash
curl -X POST $BASE_URL/delete \
  -H "Content-Type: application/json" \
  -d '{"entity_ids": ["00000000-0000-0000-0000-000000000001"]}'
```

</details>

## Error Handling

All SDKs provide typed errors:

<details>
<summary>Python</summary>

```python
from archerdb import (
    ArcherDBError,
    InvalidCoordinates,
    ClusterUnavailable,
    OperationTimeout,
)

try:
    client.insert_events(events)
except InvalidCoordinates as e:
    print(f"Bad coordinates: {e}")
except ClusterUnavailable:
    print("Cluster down, retry later")
except OperationTimeout:
    print("Timeout - operation may have committed")
```

</details>

<details>
<summary>Node.js</summary>

```javascript
import {
  InvalidCoordinates,
  ClusterUnavailable,
  OperationTimeout,
} from 'archerdb-node'

try {
  await client.insertEvents(events)
} catch (error) {
  if (error instanceof InvalidCoordinates) {
    console.error('Bad coordinates:', error.message)
  } else if (error instanceof ClusterUnavailable) {
    console.error('Cluster down, retry later')
  } else if (error instanceof OperationTimeout) {
    console.error('Timeout - operation may have committed')
  }
}
```

</details>

<details>
<summary>Go</summary>

```go
import "github.com/archerdb/archerdb-go/pkg/errors"

_, err := client.InsertEvents(events)
if err != nil {
    switch {
    case errors.IsInvalidCoordinates(err):
        log.Printf("Bad coordinates: %v", err)
    case errors.IsClusterUnavailable(err):
        log.Println("Cluster down, retry later")
    case errors.IsOperationTimeout(err):
        log.Println("Timeout - operation may have committed")
    }
}
```

</details>

<details>
<summary>Java</summary>

```java
import com.archerdb.geo.exceptions.*;

try {
    client.insertEvents(events);
} catch (InvalidCoordinatesException e) {
    System.err.println("Bad coordinates: " + e.getMessage());
} catch (ClusterUnavailableException e) {
    System.err.println("Cluster down, retry later");
} catch (OperationTimeoutException e) {
    System.err.println("Timeout - operation may have committed");
}
```

</details>

<details>
<summary>curl</summary>

```bash
# HTTP status codes:
# 200 - Success
# 400 - Invalid request (bad coordinates, malformed JSON)
# 503 - Cluster unavailable
# 504 - Request timeout
```

</details>

## Configuration Reference

### Client Options

| Option | Default | Description |
|--------|---------|-------------|
| `cluster_id` | Required | Cluster identifier |
| `addresses` | Required | List of replica addresses |
| `connect_timeout_ms` | 5000 | Connection timeout |
| `request_timeout_ms` | 30000 | Request timeout |

### Retry Options

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | true | Enable automatic retry |
| `max_retries` | 5 | Maximum retry attempts |
| `base_backoff_ms` | 100 | Base delay for exponential backoff |
| `max_backoff_ms` | 1600 | Maximum backoff delay |

See [SDK Retry Semantics](sdk-retry-semantics.md) for detailed retry behavior.

## What's Next (~1 min)

| Goal | Resource |
|------|----------|
| Complete API documentation | [API Reference](api-reference.md) |
| Deploy to production | [Operations Runbook](operations-runbook.md) |
| Understand architecture | [Architecture](architecture.md) |
| Handle failures | [Troubleshooting](troubleshooting.md) |
| Set up backups | [Backup Operations](backup-operations.md) |
| Plan for disasters | [Disaster Recovery](disaster-recovery.md) |

### SDK Documentation

- [Python SDK](https://github.com/ArcherDB-io/archerdb/blob/main/src/clients/python/README.md)
- [Node.js SDK](https://github.com/ArcherDB-io/archerdb/blob/main/src/clients/node/README.md)
- [Go SDK](https://github.com/ArcherDB-io/archerdb/blob/main/src/clients/go/README.md)
- [Java SDK](https://github.com/ArcherDB-io/archerdb/blob/main/src/clients/java/README.md)
