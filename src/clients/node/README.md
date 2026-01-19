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
    cluster_id: 0n,
    addresses: ['127.0.0.1:3001'],
  })

  try {
    const event = createGeoEvent({
      entity_id: 0x12345678n,
      latitude: 37.7749,
      longitude: -122.4194,
      group_id: 1n,
    })

    const errors = await client.insertEvents([event])
    if (errors.length === 0) {
      console.log('Event inserted successfully!')
    }

    const results = await client.queryRadius({
      latitude: 37.7749,
      longitude: -122.4194,
      radius_m: 1000,
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

* [Basic](/src/clients/node/samples/basic/): Insert GeoEvents and query by radius and UUID.
* [Radius Query](/src/clients/node/samples/radius-query/): Run radius queries with pagination over GeoEvents.
* [Polygon Query](/src/clients/node/samples/polygon-query/): Run polygon (geofence) queries over GeoEvents.
* [Walkthrough](/src/clients/node/samples/walkthrough/): Track a moving entity with upserts, queries, and deletes.

## API Reference

### Creating a Client

```javascript
const { createGeoClient } = require('archerdb-node')

const client = createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3001', '127.0.0.1:3002', '127.0.0.1:3003'],
})

// When done
client.destroy()
```

### GeoEvent Options

```javascript
const event = createGeoEvent({
  entity_id: 0x12345678n,           // u128: UUID of tracked entity
  latitude: 37.7749,                // f64: Degrees (-90 to +90)
  longitude: -122.4194,             // f64: Degrees (-180 to +180)
  group_id: 1n,                     // u64: Fleet/region grouping
  correlation_id: 0n,               // u128: Trip/session correlation
  user_data: 0n,                    // u128: Application metadata
  altitude_m: 0,                    // f64: Altitude in meters
  velocity_mps: 0,                  // f64: Speed in meters per second
  ttl_seconds: 0,                   // u32: Time-to-live in seconds
  accuracy_m: 0,                    // f64: GPS accuracy in meters
  heading: 0,                       // f64: Heading in degrees
  flags: 0,                         // u16: GeoEventFlags bitmask
})
```

### Insert Events

```javascript
const errors = await client.insertEvents([event])
for (const error of errors) {
  console.log(`Event ${error.index} failed: ${error.result}`)
}
```

### Upsert Events

```javascript
await client.upsertEvents([event])
```

### Query by Radius

```javascript
const results = await client.queryRadius({
  latitude: 37.7749,
  longitude: -122.4194,
  radius_m: 5000,
  limit: 1000,
})

for (const event of results.events) {
  console.log(`Entity ${event.entity_id} at (${event.latitude}, ${event.longitude})`)
}
```

### Query by Polygon

```javascript
const vertices = [
  { latitude: 37.78, longitude: -122.42 },
  { latitude: 37.78, longitude: -122.40 },
  { latitude: 37.76, longitude: -122.40 },
  { latitude: 37.76, longitude: -122.42 },
]

const results = await client.queryPolygon({ vertices, limit: 1000 })
```

### Query Latest by UUID

```javascript
const event = await client.getLatestByUuid(entity_id)
```

### Query Latest Events

```javascript
const results = await client.queryLatest({ limit: 100 })
```

### Delete Entities

```javascript
const result = await client.deleteEntities([entity_id_1, entity_id_2])
console.log(result)
```
