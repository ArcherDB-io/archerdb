# archerdb-node

The ArcherDB Node.js client for high-performance geospatial data storage and queries.

## Prerequisites

Linux >= 5.6 is the only production environment we support. For development, macOS and Windows are also supported.

* Node.js >= 18

## Installation

```console
npm install --save-exact archerdb-node
```

## Quick Start

```javascript
const { createGeoClient, createGeoEvent } = require('archerdb-node')

async function main() {
  const client = createGeoClient({
    clusterId: 0n,
    addresses: ['127.0.0.1:3001'],
  })

  try {
    // Insert a geo event
    const event = createGeoEvent({
      entityId: 0x12345678n,       // UUID of tracked entity
      latitude: 37.7749,           // San Francisco
      longitude: -122.4194,
      timestampNs: BigInt(Date.now()) * 1000000n,
      groupId: 1n,
    })

    const errors = await client.insertEvents([event])
    if (errors.length === 0) {
      console.log('Event inserted successfully!')
    }

    // Query events within 1km radius
    const results = await client.queryRadius({
      centerLat: 37.7749,
      centerLon: -122.4194,
      radiusMeters: 1000,
      limit: 100,
    })

    console.log(`Found ${results.events.length} events within 1km`)
  } finally {
    client.destroy()
  }
}

main()
```

### Sidenote: `BigInt`

ArcherDB uses 64-bit and 128-bit integers for IDs and timestamps. JavaScript's `Number` max value is `2^53-1`, so we use `BigInt`. The `n` suffix denotes a BigInt literal: `1n` equals `BigInt(1)`.

## Sample Projects

* [Basic](/src/clients/node/samples/basic/): Insert and query geospatial events.
* [Radius Query](/src/clients/node/samples/radius-query/): Advanced radius queries with pagination.
* [Polygon Query](/src/clients/node/samples/polygon-query/): Geofence-based polygon queries.

## API Reference

### Creating a Client

```javascript
const { createGeoClient } = require('archerdb-node')

const client = createGeoClient({
  clusterId: 0n,
  addresses: ['127.0.0.1:3001', '127.0.0.1:3002', '127.0.0.1:3003'],
})

// When done
client.destroy()
```

### GeoEvent Structure

```javascript
const { createGeoEvent } = require('archerdb-node')

const event = createGeoEvent({
  entityId: 0x12345678n,                    // u128: UUID of tracked entity
  latitude: 37.7749,                        // f64: Degrees (-90 to +90)
  longitude: -122.4194,                     // f64: Degrees (-180 to +180)
  timestampNs: 1704067200000000000n,        // u64: Nanoseconds since epoch
  groupId: 1n,                              // u64: Fleet/region grouping
  correlationId: 0n,                        // u128: Trip/session correlation
  userData: 0n,                             // u128: Application metadata
  altitudeMm: 0,                            // i32: Altitude in millimeters
  speedMmps: 0,                             // u32: Speed in mm/s
  headingMicrodeg: 0,                       // u32: Heading in microdegrees
  accuracyMm: 0,                            // u32: GPS accuracy in mm
  status: 0,                                // u16: Application status flags
  eventType: 0,                             // u8: Event type code
})
```

### Insert Events

```javascript
const events = [
  createGeoEvent({ entityId: 1n, latitude: 37.7749, longitude: -122.4194, timestampNs: now }),
  createGeoEvent({ entityId: 2n, latitude: 37.7849, longitude: -122.4094, timestampNs: now }),
]

const errors = await client.insertEvents(events)
for (const error of errors) {
  console.log(`Event ${error.index} failed: ${error.result}`)
}
```

### Upsert Events

```javascript
const errors = await client.upsertEvents(events)
```

### Query by Radius

```javascript
const results = await client.queryRadius({
  centerLat: 37.7749,
  centerLon: -122.4194,
  radiusMeters: 5000,           // 5km radius
  limit: 1000,                  // Max results per page
  timestampMin: startNs,        // Optional time filter
  timestampMax: endNs,
  groupId: 1n,                  // Optional group filter
})

for (const event of results.events) {
  console.log(`Entity ${event.entityId} at (${event.latitude}, ${event.longitude})`)
}

// Pagination
if (results.hasMore) {
  const nextResults = await client.queryRadius({
    centerLat: 37.7749,
    centerLon: -122.4194,
    radiusMeters: 5000,
    limit: 1000,
    cursor: results.cursor,
  })
}
```

### Query by Polygon

```javascript
// Polygon vertices (counter-clockwise winding)
const vertices = [
  { lat: 37.78, lon: -122.42 },
  { lat: 37.78, lon: -122.40 },
  { lat: 37.76, lon: -122.40 },
  { lat: 37.76, lon: -122.42 },
]

const results = await client.queryPolygon({
  vertices,
  limit: 1000,
  timestampMin: startNs,
  timestampMax: endNs,
})
```

### Query Latest by Entity UUID

```javascript
const event = await client.getLatestByUuid(0x12345678n)

if (event) {
  console.log(`Last seen at (${event.latitude}, ${event.longitude})`)
}
```

### Query Latest Events

```javascript
const results = await client.queryLatest({
  limit: 100,
  timestampMin: startNs,
  groupId: 1n,
})

for (const event of results.events) {
  console.log(`Entity ${event.entityId}: ${event.latitude}, ${event.longitude}`)
}
```

### Delete Entities

GDPR-compliant deletion of all events for specified entities.

```javascript
const result = await client.deleteEntities([entityId1, entityId2])
console.log(`Deleted ${result.deletedCount} entities`)
```

## Error Handling

```javascript
const { ArcherDBError, ConnectionError, ValidationError } = require('archerdb-node')

try {
  const results = await client.queryRadius({
    centerLat: 91.0,  // Invalid: exceeds 90
    centerLon: -122.4194,
    radiusMeters: 1000,
  })
} catch (error) {
  if (error instanceof ValidationError) {
    console.log(`Invalid input: ${error.message}`)
  } else if (error instanceof ConnectionError) {
    console.log(`Connection failed: ${error.message}`)
  } else if (error instanceof ArcherDBError) {
    console.log(`ArcherDB error: ${error.message}`)
  }
}
```

## Performance Tips

1. **Batch operations**: Always batch inserts (up to 10,000 events per call).
2. **Reuse client**: Create one client instance and reuse it.
3. **Use pagination**: For large result sets, use cursor-based pagination.
4. **Filter early**: Use `groupId` and time filters to reduce result size.

```javascript
// Efficient batching
const BATCH_SIZE = 8000
for (let i = 0; i < events.length; i += BATCH_SIZE) {
  const batch = events.slice(i, i + BATCH_SIZE)
  const errors = await client.insertEvents(batch)
}
```

## TypeScript Support

Full TypeScript definitions are included:

```typescript
import { createGeoClient, createGeoEvent, GeoEvent, QueryResult } from 'archerdb-node'

const client = createGeoClient({
  clusterId: 0n,
  addresses: ['127.0.0.1:3001'],
})

const event: GeoEvent = createGeoEvent({
  entityId: 1n,
  latitude: 37.7749,
  longitude: -122.4194,
  timestampNs: BigInt(Date.now()) * 1000000n,
})

const results: QueryResult = await client.queryRadius({
  centerLat: 37.7749,
  centerLon: -122.4194,
  radiusMeters: 1000,
})
```

## Links

* [ArcherDB Documentation](https://github.com/ArcherDB-io/archerdb)
* [Client SDK Specification](/openspec/changes/add-geospatial-core/specs/client-sdk/spec.md)
