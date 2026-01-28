# ArcherDB API Reference

This document provides complete API documentation for ArcherDB, covering all operations, data types, error handling, and protocol details.

## Overview

ArcherDB provides a binary protocol over TCP for high-performance geospatial operations. For most use cases, we recommend using one of the official [SDKs](/#sdks) rather than implementing the protocol directly.

### Consistency Model

ArcherDB uses Viewstamped Replication (VSR) to provide **linearizability** - all operations appear to execute atomically in a single, consistent order across all replicas. Once an operation returns success:

- The data is durably stored on a majority of replicas
- All subsequent reads will see the written data
- The operation will survive any minority of replica failures

### Request/Response Flow

1. Client sends a request to any replica
2. If the replica is not the primary, it forwards to the primary
3. Primary replicates to followers and waits for quorum
4. Primary commits and returns response to client

For more details on the consensus protocol, see [VSR Understanding](vsr_understanding.md).

## Data Types

### GeoEvent

A GeoEvent represents a single location update for an entity (vehicle, device, user, etc.).

| Field | Type | Range | Description |
|-------|------|-------|-------------|
| `id` | u128 | Auto-generated | Composite key (entity_id + timestamp). Do not set manually. |
| `entity_id` | u128 | Non-zero | Unique identifier for the tracked entity |
| `correlation_id` | u128 | Any | Trip, session, or job correlation ID |
| `user_data` | u128 | Any | Application-specific metadata |
| `lat_nano` | i64 | -90e9 to +90e9 | Latitude in nanodegrees |
| `lon_nano` | i64 | -180e9 to +180e9 | Longitude in nanodegrees |
| `group_id` | u64 | Any | Fleet, region, or tenant identifier |
| `altitude_mm` | i32 | -10,000,000 to +100,000,000 | Altitude in millimeters (-10km to +100km) |
| `velocity_mms` | u32 | 0 to 1,000,000,000 | Speed in millimeters per second (0 to 1000 m/s) |
| `ttl_seconds` | u32 | 0 to 4,294,967,295 | Time-to-live in seconds (0 = never expire) |
| `accuracy_mm` | u32 | 0 to 4,294,967,295 | GPS accuracy radius in millimeters |
| `heading_cdeg` | u16 | 0 to 35999 | Heading in centidegrees (0 = North, 9000 = East) |
| `flags` | u16 | Bitmask | Status flags (application-defined) |

### Coordinate Encoding

ArcherDB uses integer coordinates for precision and performance:

```
latitude_nanodegrees = latitude_degrees × 1,000,000,000
longitude_nanodegrees = longitude_degrees × 1,000,000,000
altitude_mm = altitude_meters × 1,000
velocity_mms = velocity_mps × 1,000
heading_cdeg = heading_degrees × 100
```

**Example:** San Francisco (37.7749, -122.4194) becomes:
- `lat_nano`: 37,774,900,000
- `lon_nano`: -122,419,400,000

**Precision:** Nanodegrees provide ~0.1mm precision at the equator, far exceeding GPS accuracy.

### ID Types

| Type | Size | Usage |
|------|------|-------|
| `u128` | 128 bits | Entity IDs, correlation IDs, user data |
| `u64` | 64 bits | Group IDs, timestamps |
| `u32` | 32 bits | Limits, counters, durations |

All SDKs provide an `id()` function to generate unique 128-bit identifiers.

## Operations

### createBatch / commit

Insert or upsert a batch of GeoEvents atomically.

#### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `events` | GeoEvent[] | Yes | Array of events to insert/upsert (1 to 10,000) |
| `mode` | string | No | `"insert"` (default) or `"upsert"` |

**Insert vs Upsert:**
- **Insert**: Fails if an event with the same `entity_id` + timestamp exists
- **Upsert**: Updates existing event or inserts if not present (idempotent, recommended)

#### Response

| Field | Type | Description |
|-------|------|-------------|
| `results` | EventResult[] | Per-event results (same order as request) |
| `committed` | bool | True if the batch committed successfully |

**EventResult:**

| Field | Type | Description |
|-------|------|-------------|
| `index` | u32 | Index in the original batch |
| `result` | u16 | Result code (0 = success, see [Error Codes](error-codes.md)) |

#### Errors

| Code | Name | Description | Retryable |
|------|------|-------------|-----------|
| 100 | `INVALID_COORDINATES` | Latitude or longitude out of valid range | No |
| 101 | `INVALID_ENTITY_ID` | Entity ID is zero | No |
| 300 | `BATCH_TOO_LARGE` | Batch exceeds 10,000 events | No |
| 211 | `CLUSTER_UNAVAILABLE` | No quorum available | Yes |
| 220 | `NOT_SHARD_LEADER` | Wrong shard (auto-retried by SDK) | Yes |

For complete error codes, see [Error Codes Reference](error-codes.md).

#### Examples

<details>
<summary>Node.js</summary>

```typescript
import { createGeoClient, createGeoEvent, id } from 'archerdb-node'

const client = await createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3000'],
})

// Create a batch
const batch = client.createBatch()

// Add events
batch.add(createGeoEvent({
  entity_id: id(),
  latitude: 37.7749,
  longitude: -122.4194,
  group_id: 1n,
}))

batch.add(createGeoEvent({
  entity_id: id(),
  latitude: 37.7849,
  longitude: -122.4094,
  group_id: 1n,
}))

// Commit (default: insert mode)
const results = await batch.commit()

// Check per-event results
for (const result of results) {
  if (result.error) {
    console.error(`Event ${result.index} failed: ${result.error}`)
  }
}

// Or use upsert mode (idempotent)
const upsertBatch = client.createBatch({ mode: 'upsert' })
// ... add events ...
await upsertBatch.commit()
```

</details>

<details>
<summary>Python</summary>

```python
import archerdb

client = archerdb.GeoClientSync(archerdb.GeoClientConfig(
    cluster_id=0,
    addresses=['127.0.0.1:3000']
))

# Create a batch
batch = client.create_batch()

# Add events
batch.add(archerdb.create_geo_event(
    entity_id=archerdb.id(),
    latitude=37.7749,
    longitude=-122.4194,
    group_id=1,
))

batch.add(archerdb.create_geo_event(
    entity_id=archerdb.id(),
    latitude=37.7849,
    longitude=-122.4094,
    group_id=1,
))

# Commit
results = batch.commit()

# Check per-event results
for result in results:
    if result.error:
        print(f"Event {result.index} failed: {result.error}")
```

</details>

<details>
<summary>Go</summary>

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

// Create events
events := []types.GeoEvent{
    {
        EntityID: types.ID(),
        LatNano:  37774900000,
        LonNano:  -122419400000,
        GroupID:  1,
    },
    {
        EntityID: types.ID(),
        LatNano:  37784900000,
        LonNano:  -122409400000,
        GroupID:  1,
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

</details>

<details>
<summary>Java</summary>

```java
import com.archerdb.geo.*;
import java.math.BigInteger;
import java.util.List;

GeoClientConfig config = new GeoClientConfig.Builder()
    .clusterId(BigInteger.ZERO)
    .addresses(List.of("127.0.0.1:3000"))
    .build();

try (GeoClient client = new GeoClient(config)) {
    // Create events
    List<GeoEvent> events = List.of(
        GeoEvent.builder()
            .entityId(GeoClient.generateId())
            .latNano(37774900000L)
            .lonNano(-122419400000L)
            .groupId(1L)
            .build(),
        GeoEvent.builder()
            .entityId(GeoClient.generateId())
            .latNano(37784900000L)
            .lonNano(-122409400000L)
            .groupId(1L)
            .build()
    );

    // Insert events
    List<EventResult> results = client.createEvents(events);

    // Check per-event results
    for (EventResult result : results) {
        if (result.getResult() != 0) {
            System.err.println("Event " + result.getIndex() + " failed: " + result.getResult());
        }
    }
}
```

</details>

<details>
<summary>C</summary>

```c
#include <archerdb.h>
#include <stdio.h>

arch_client_t* client = arch_client_new(0, "127.0.0.1:3000", NULL);

// Create events
geo_event_t events[2] = {
    {
        .entity_id = arch_id(),
        .lat_nano = 37774900000,
        .lon_nano = -122419400000,
        .group_id = 1,
    },
    {
        .entity_id = arch_id(),
        .lat_nano = 37784900000,
        .lon_nano = -122409400000,
        .group_id = 1,
    },
};

// Insert events (synchronous callback)
void on_result(void* ctx, const event_result_t* results, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (results[i].result != 0) {
            printf("Event %u failed: %u\n", results[i].index, results[i].result);
        }
    }
}

arch_create_events(client, events, 2, on_result, NULL);

arch_client_destroy(client);
```

</details>

---

### queryRadius

Find all entities within a radius of a center point.

#### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `center_lat` | f64 | Yes | Center latitude in degrees (-90 to +90) |
| `center_lon` | f64 | Yes | Center longitude in degrees (-180 to +180) |
| `radius_m` | u32 | Yes | Radius in meters (1 to 40,000,000) |
| `limit` | u32 | No | Maximum results per page (default: 1,000, max: 10,000) |
| `cursor` | bytes | No | Pagination cursor from previous response |
| `group_id` | u64 | No | Filter by group ID |

#### Response

| Field | Type | Description |
|-------|------|-------------|
| `events` | GeoEvent[] | Matching events |
| `has_more` | bool | True if more results available |
| `cursor` | bytes | Cursor for next page (present if `has_more` is true) |

**Ordering:** Results are returned in deterministic order based on S2 cell ID, enabling consistent pagination.

#### Errors

| Code | Name | Description | Retryable |
|------|------|-------------|-----------|
| 100 | `INVALID_COORDINATES` | Center coordinates out of range | No |
| 101 | `INVALID_RADIUS` | Radius outside valid range (1 to 40,000,000 meters) | No |
| 300 | `QUERY_RESULT_TOO_LARGE` | Result set exceeds configured maximum | No |

#### Examples

<details>
<summary>Node.js</summary>

```typescript
// Basic query
const results = await client.queryRadius({
  center_lat: 37.7749,
  center_lon: -122.4194,
  radius_m: 1000,
  limit: 100,
})

console.log(`Found ${results.events.length} entities`)

// With group filter
const fleetResults = await client.queryRadius({
  center_lat: 37.7749,
  center_lon: -122.4194,
  radius_m: 5000,
  group_id: 1n,  // Only fleet 1
  limit: 100,
})

// Pagination
let allEvents = []
let cursor = undefined

do {
  const page = await client.queryRadius({
    center_lat: 37.7749,
    center_lon: -122.4194,
    radius_m: 10000,
    limit: 1000,
    cursor,
  })
  allEvents.push(...page.events)
  cursor = page.has_more ? page.cursor : undefined
} while (cursor)
```

</details>

<details>
<summary>Python</summary>

```python
# Basic query
results = client.query_radius(
    center_lat=37.7749,
    center_lon=-122.4194,
    radius_m=1000,
    limit=100,
)

print(f"Found {len(results.events)} entities")

# With group filter
fleet_results = client.query_radius(
    center_lat=37.7749,
    center_lon=-122.4194,
    radius_m=5000,
    group_id=1,  # Only fleet 1
    limit=100,
)

# Pagination
all_events = []
cursor = None

while True:
    page = client.query_radius(
        center_lat=37.7749,
        center_lon=-122.4194,
        radius_m=10000,
        limit=1000,
        cursor=cursor,
    )
    all_events.extend(page.events)
    if not page.has_more:
        break
    cursor = page.cursor
```

</details>

<details>
<summary>Go</summary>

```go
// Basic query
filter := types.RadiusFilter{
    CenterLatNano: 37774900000,
    CenterLonNano: -122419400000,
    RadiusM:       1000,
    Limit:         100,
}

results, err := client.QueryRadius(filter)
if err != nil {
    log.Fatal(err)
}

fmt.Printf("Found %d entities\n", len(results.Events))

// Pagination
var allEvents []types.GeoEvent
var cursor []byte

for {
    filter := types.RadiusFilter{
        CenterLatNano: 37774900000,
        CenterLonNano: -122419400000,
        RadiusM:       10000,
        Limit:         1000,
        Cursor:        cursor,
    }

    page, err := client.QueryRadius(filter)
    if err != nil {
        log.Fatal(err)
    }

    allEvents = append(allEvents, page.Events...)
    if !page.HasMore {
        break
    }
    cursor = page.Cursor
}
```

</details>

<details>
<summary>Java</summary>

```java
// Basic query
QueryRadiusFilter filter = new QueryRadiusFilter.Builder()
    .centerLatNano(37774900000L)
    .centerLonNano(-122419400000L)
    .radiusM(1000)
    .limit(100)
    .build();

QueryResult results = client.queryRadius(filter);
System.out.println("Found " + results.getEvents().size() + " entities");

// Pagination
List<GeoEvent> allEvents = new ArrayList<>();
byte[] cursor = null;

do {
    QueryRadiusFilter pageFilter = new QueryRadiusFilter.Builder()
        .centerLatNano(37774900000L)
        .centerLonNano(-122419400000L)
        .radiusM(10000)
        .limit(1000)
        .cursor(cursor)
        .build();

    QueryResult page = client.queryRadius(pageFilter);
    allEvents.addAll(page.getEvents());
    cursor = page.hasMore() ? page.getCursor() : null;
} while (cursor != null);
```

</details>

<details>
<summary>C</summary>

```c
// Basic query
radius_filter_t filter = {
    .center_lat_nano = 37774900000,
    .center_lon_nano = -122419400000,
    .radius_m = 1000,
    .limit = 100,
};

void on_result(void* ctx, const geo_event_t* events, size_t count, bool has_more, const uint8_t* cursor, size_t cursor_len) {
    printf("Found %zu entities\n", count);

    // Handle pagination if needed
    if (has_more) {
        // Store cursor for next query
    }
}

arch_query_radius(client, &filter, on_result, NULL);
```

</details>

---

### queryPolygon

Find all entities within a polygon boundary, optionally excluding holes.

#### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `vertices` | Coordinate[] | Yes | Outer boundary vertices (3 to 1,000 points, counter-clockwise) |
| `holes` | Coordinate[][] | No | Interior holes to exclude (0 to 100 holes, clockwise winding) |
| `limit` | u32 | No | Maximum results per page (default: 1,000, max: 10,000) |
| `cursor` | bytes | No | Pagination cursor from previous response |
| `group_id` | u64 | No | Filter by group ID |

**Coordinate:**

| Field | Type | Description |
|-------|------|-------------|
| `lat` | f64 | Latitude in degrees (-90 to +90) |
| `lon` | f64 | Longitude in degrees (-180 to +180) |

**Winding Order:**
- **Outer boundary:** Counter-clockwise (exterior ring)
- **Holes:** Clockwise (interior rings)

This follows the GeoJSON convention. SDKs provide validation helpers to check winding order.

#### Response

| Field | Type | Description |
|-------|------|-------------|
| `events` | GeoEvent[] | Matching events |
| `has_more` | bool | True if more results available |
| `cursor` | bytes | Cursor for next page (present if `has_more` is true) |

#### Errors

| Code | Name | Description | Retryable |
|------|------|-------------|-----------|
| 100 | `INVALID_COORDINATES` | Vertex coordinates out of range | No |
| 102 | `POLYGON_TOO_COMPLEX` | Too many vertices (max 1,000) or holes (max 100) | No |
| 103 | `INVALID_POLYGON` | Self-intersecting, degenerate, or invalid hole layout | No |

#### Examples

<details>
<summary>Node.js</summary>

```typescript
// Simple polygon (downtown San Francisco)
const results = await client.queryPolygon({
  vertices: [
    { lat: 37.79, lon: -122.42 },  // NW
    { lat: 37.79, lon: -122.39 },  // NE
    { lat: 37.76, lon: -122.39 },  // SE
    { lat: 37.76, lon: -122.42 },  // SW
  ],
  limit: 1000,
})

// Polygon with hole (exclude a park)
const resultsWithHole = await client.queryPolygon({
  vertices: [
    { lat: 37.79, lon: -122.42 },
    { lat: 37.79, lon: -122.39 },
    { lat: 37.76, lon: -122.39 },
    { lat: 37.76, lon: -122.42 },
  ],
  holes: [
    // Park to exclude (clockwise winding)
    [
      { lat: 37.78, lon: -122.41 },
      { lat: 37.775, lon: -122.41 },
      { lat: 37.775, lon: -122.40 },
      { lat: 37.78, lon: -122.40 },
    ],
  ],
  limit: 1000,
})
```

</details>

<details>
<summary>Python</summary>

```python
# Simple polygon
results = client.query_polygon(
    vertices=[
        (37.79, -122.42),  # NW
        (37.79, -122.39),  # NE
        (37.76, -122.39),  # SE
        (37.76, -122.42),  # SW
    ],
    limit=1000,
)

# Polygon with hole
results_with_hole = client.query_polygon(
    vertices=[
        (37.79, -122.42),
        (37.79, -122.39),
        (37.76, -122.39),
        (37.76, -122.42),
    ],
    holes=[
        # Park to exclude (clockwise winding)
        [
            (37.78, -122.41),
            (37.775, -122.41),
            (37.775, -122.40),
            (37.78, -122.40),
        ],
    ],
    limit=1000,
)
```

</details>

<details>
<summary>Go</summary>

```go
// Simple polygon
vertices := [][]float64{
    {37.79, -122.42},
    {37.79, -122.39},
    {37.76, -122.39},
    {37.76, -122.42},
}

filter, err := types.NewPolygonQuery(vertices, 1000)
if err != nil {
    log.Fatal(err)
}

results, err := client.QueryPolygon(filter)

// Polygon with hole
parkHole := [][]float64{
    {37.78, -122.41},
    {37.775, -122.41},
    {37.775, -122.40},
    {37.78, -122.40},
}

filterWithHole, err := types.NewPolygonQuery(vertices, 1000, parkHole)
```

</details>

<details>
<summary>Java</summary>

```java
// Simple polygon
QueryPolygonFilter filter = new QueryPolygonFilter.Builder()
    .addVertex(37.79, -122.42)
    .addVertex(37.79, -122.39)
    .addVertex(37.76, -122.39)
    .addVertex(37.76, -122.42)
    .setLimit(1000)
    .build();

QueryResult results = client.queryPolygon(filter);

// Polygon with hole
QueryPolygonFilter filterWithHole = new QueryPolygonFilter.Builder()
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
<summary>C</summary>

```c
// Simple polygon
coordinate_t vertices[] = {
    {.lat = 37.79, .lon = -122.42},
    {.lat = 37.79, .lon = -122.39},
    {.lat = 37.76, .lon = -122.39},
    {.lat = 37.76, .lon = -122.42},
};

polygon_filter_t filter = {
    .vertices = vertices,
    .vertex_count = 4,
    .limit = 1000,
};

arch_query_polygon(client, &filter, on_result, NULL);
```

</details>

---

### getLatest

Get the most recent location for a single entity.

#### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity_id` | u128 | Yes | Entity to look up |

#### Response

| Field | Type | Description |
|-------|------|-------------|
| `event` | GeoEvent | Most recent event (null if entity not found) |
| `found` | bool | True if entity exists |

#### Errors

| Code | Name | Description | Retryable |
|------|------|-------------|-----------|
| 101 | `INVALID_ENTITY_ID` | Entity ID is zero | No |

#### Examples

<details>
<summary>Node.js</summary>

```typescript
const event = await client.getLatest(entityId)

if (event) {
  console.log(`Last seen at: ${event.lat_nano / 1e9}, ${event.lon_nano / 1e9}`)
} else {
  console.log('Entity not found')
}
```

</details>

<details>
<summary>Python</summary>

```python
event = client.get_latest(entity_id)

if event:
    print(f"Last seen at: {event.lat_nano / 1e9}, {event.lon_nano / 1e9}")
else:
    print("Entity not found")
```

</details>

<details>
<summary>Go</summary>

```go
event, found, err := client.GetLatest(entityID)
if err != nil {
    log.Fatal(err)
}

if found {
    fmt.Printf("Last seen at: %f, %f\n", float64(event.LatNano)/1e9, float64(event.LonNano)/1e9)
} else {
    fmt.Println("Entity not found")
}
```

</details>

<details>
<summary>Java</summary>

```java
Optional<GeoEvent> event = client.getLatest(entityId);

if (event.isPresent()) {
    GeoEvent e = event.get();
    System.out.printf("Last seen at: %f, %f%n",
        e.getLatNano() / 1e9, e.getLonNano() / 1e9);
} else {
    System.out.println("Entity not found");
}
```

</details>

<details>
<summary>C</summary>

```c
geo_event_t event;
bool found = arch_get_latest(client, entity_id, &event);

if (found) {
    printf("Last seen at: %f, %f\n",
        (double)event.lat_nano / 1e9,
        (double)event.lon_nano / 1e9);
} else {
    printf("Entity not found\n");
}
```

</details>

---

### getLatestBatch

Get the most recent location for multiple entities in a single request.

#### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity_ids` | u128[] | Yes | Entities to look up (1 to 10,000) |

#### Response

| Field | Type | Description |
|-------|------|-------------|
| `events` | GeoEvent[] | Events for found entities (may be fewer than requested) |

**Note:** The response only includes events for entities that exist. Missing entities are silently omitted.

#### Examples

<details>
<summary>Node.js</summary>

```typescript
const events = await client.getLatestBatch([entityId1, entityId2, entityId3])

console.log(`Found ${events.length} of 3 entities`)

for (const event of events) {
  console.log(`Entity ${event.entity_id}: ${event.lat_nano}, ${event.lon_nano}`)
}
```

</details>

<details>
<summary>Python</summary>

```python
events = client.get_latest_batch([entity_id1, entity_id2, entity_id3])

print(f"Found {len(events)} of 3 entities")

for event in events:
    print(f"Entity {event.entity_id}: {event.lat_nano}, {event.lon_nano}")
```

</details>

<details>
<summary>Go</summary>

```go
entityIDs := []types.Uint128{entityID1, entityID2, entityID3}

events, err := client.GetLatestBatch(entityIDs)
if err != nil {
    log.Fatal(err)
}

fmt.Printf("Found %d of 3 entities\n", len(events))
```

</details>

<details>
<summary>Java</summary>

```java
List<BigInteger> entityIds = List.of(entityId1, entityId2, entityId3);

List<GeoEvent> events = client.getLatestBatch(entityIds);

System.out.println("Found " + events.size() + " of 3 entities");
```

</details>

<details>
<summary>C</summary>

```c
uint128_t entity_ids[3] = {entity_id1, entity_id2, entity_id3};

void on_batch_result(void* ctx, const geo_event_t* events, size_t count) {
    printf("Found %zu of 3 entities\n", count);
}

arch_get_latest_batch(client, entity_ids, 3, on_batch_result, NULL);
```

</details>

---

### deleteEntities

Permanently delete all data for specified entities (GDPR compliance).

#### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity_ids` | u128[] | Yes | Entities to delete (1 to 10,000) |

#### Response

| Field | Type | Description |
|-------|------|-------------|
| `deleted_count` | u32 | Number of entities actually deleted |
| `not_found_count` | u32 | Number of entities that didn't exist |

#### Errors

| Code | Name | Description | Retryable |
|------|------|-------------|-----------|
| 101 | `INVALID_ENTITY_ID` | One or more entity IDs are zero | No |

#### Examples

<details>
<summary>Node.js</summary>

```typescript
const result = await client.deleteEntities([entityId1, entityId2])

console.log(`Deleted: ${result.deleted_count}`)
console.log(`Not found: ${result.not_found_count}`)
```

</details>

<details>
<summary>Python</summary>

```python
result = client.delete_entities([entity_id1, entity_id2])

print(f"Deleted: {result.deleted_count}")
print(f"Not found: {result.not_found_count}")
```

</details>

<details>
<summary>Go</summary>

```go
result, err := client.DeleteEntities([]types.Uint128{entityID1, entityID2})
if err != nil {
    log.Fatal(err)
}

fmt.Printf("Deleted: %d, Not found: %d\n", result.DeletedCount, result.NotFoundCount)
```

</details>

<details>
<summary>Java</summary>

```java
DeleteResult result = client.deleteEntities(List.of(entityId1, entityId2));

System.out.println("Deleted: " + result.getDeletedCount());
System.out.println("Not found: " + result.getNotFoundCount());
```

</details>

<details>
<summary>C</summary>

```c
uint128_t entity_ids[2] = {entity_id1, entity_id2};

delete_result_t result;
arch_delete_entities(client, entity_ids, 2, &result);

printf("Deleted: %u, Not found: %u\n", result.deleted_count, result.not_found_count);
```

</details>

## Request/Response Formats

### Batch Semantics

Batch operations (createBatch/commit) are **atomic**: either all events in the batch commit together, or none do. However, individual events within a batch can fail validation while others succeed.

**Atomic commit:**
- All valid events are committed in a single transaction
- Replication to quorum is guaranteed before response
- On failure, no events from the batch are committed

**Per-event results:**
- Each event in the batch gets an individual result code
- A batch can "succeed" (commit) even if some events have validation errors
- Check `result.error` for each event to detect partial failures

### Pagination

All query operations use cursor-based pagination:

| Field | Type | Direction | Description |
|-------|------|-----------|-------------|
| `limit` | u32 | Request | Maximum events per page (default: 1,000, max: 10,000) |
| `cursor` | bytes | Both | Opaque pagination token |
| `has_more` | bool | Response | True if more results exist |

**Best practices:**
- Use a reasonable `limit` (1,000 is usually sufficient)
- Don't parse or modify the cursor - treat it as opaque
- Cursors may expire if the underlying data changes significantly

### Result Ordering

Query results are returned in **deterministic order** based on S2 cell ID. This ordering:
- Ensures consistent pagination (no duplicates or gaps)
- Groups spatially nearby entities together
- Is not sorted by distance from query center

To sort by distance, sort results client-side after receiving them.

## Error Handling

### Error Categories

Errors are grouped into ranges by category:

| Range | Category | General Handling |
|-------|----------|------------------|
| 0 | Success | Operation completed |
| 1-99 | Protocol | Check client version, message format |
| 100-199 | Validation | Fix request parameters |
| 200-299 | State | Check cluster health, retry if transient |
| 300-399 | Resource | Reduce batch size, check limits |
| 400-499 | Security | Check authentication, permissions |
| 500-599 | Internal | Contact support (should not occur) |

### Retry Semantics

SDKs automatically retry transient errors with exponential backoff. See [SDK Retry Semantics](sdk-retry-semantics.md) for detailed configuration.

**Retryable errors** (automatically retried):
- `211` - Cluster unavailable (no quorum)
- `220` - Not shard leader
- `222` - Resharding in progress
- Network timeouts

**Non-retryable errors** (fail immediately):
- `100-199` - Validation errors (fix the request)
- `300-399` - Resource limits (reduce batch size)

For the complete error reference, see [Error Codes](error-codes.md).

## Rate Limits and Quotas

ArcherDB does not implement server-side rate limiting. Instead, limits are enforced through connection and batch constraints.

### Connection Limits

| Limit | Default | Description |
|-------|---------|-------------|
| Pool size | 1 | Connections per client (configurable via `pool_size`) |
| Max concurrent requests | Pool size | One request per connection |

Increase `pool_size` for higher throughput. Each connection adds server-side overhead.

### Batch Size Limits

| Limit | Value | Description |
|-------|-------|-------------|
| Max events per batch | 10,000 | Insert/upsert batch size |
| Max entity IDs per lookup | 10,000 | getLatestBatch, deleteEntities |
| Max polygon vertices | 1,000 | queryPolygon outer ring |
| Max polygon holes | 100 | queryPolygon interior rings |

### Query Result Limits

| Limit | Default | Max | Description |
|-------|---------|-----|-------------|
| Results per page | 1,000 | 10,000 | Events returned per query |

Use pagination for larger result sets.

### Performance Guidelines

| Batch Size | Typical Latency | Throughput |
|------------|-----------------|------------|
| 1-100 | 1-5 ms | Low |
| 100-1,000 | 5-20 ms | Medium |
| 1,000-5,000 | 20-50 ms | High |
| 5,000-10,000 | 50-100 ms | Maximum |

For maximum throughput:
- Use batches of 1,000-5,000 events
- Use multiple client connections (`pool_size`)
- Distribute load across client instances

## Wire Protocol

For most use cases, use the official SDKs. This section provides protocol details for advanced users who need to implement custom clients.

### Overview

ArcherDB uses a custom binary protocol over TCP:

- **Transport:** TCP with optional TLS
- **Framing:** Length-prefixed messages
- **Encoding:** Little-endian binary
- **Compression:** None (data is already compact)

### Message Format

Every message has the following structure:

```
+----------------+----------------+------------------+
| Length (4 B)   | Header (16 B)  | Payload (var)    |
+----------------+----------------+------------------+
```

| Field | Size | Description |
|-------|------|-------------|
| Length | 4 bytes | Total message size (excluding this field) |
| Header | 16 bytes | Message type, client ID, sequence number |
| Payload | Variable | Operation-specific data |

### Connection Establishment

1. Client connects to any replica
2. Client sends `Register` message with cluster ID
3. Server responds with session ID
4. Client uses session ID for all subsequent requests

### Advanced: Source Reference

For full protocol details, see the source files:

- Message definitions: `src/message.zig`
- Protocol encoding: `src/protocol.zig`
- Error codes: `src/error_codes.zig`

The SDKs implement this protocol correctly and handle edge cases like reconnection, request deduplication, and shard routing.

## Related Documentation

- [Getting Started](getting-started.md) - Tutorial with complete examples
- [Error Codes](error-codes.md) - Complete error reference
- [SDK Retry Semantics](sdk-retry-semantics.md) - Retry configuration
- [SDKs](/#sdks) - Language-specific documentation
