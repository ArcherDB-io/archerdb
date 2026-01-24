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

### TTL Operations

```javascript
// Set TTL (24-hour expiration)
await client.setTtl(entityId, 86400)

// Extend TTL by 1 day
await client.extendTtl(entityId, 86400)

// Clear TTL (never expires)
await client.clearTtl(entityId)

// Cleanup expired entries
const result = await client.cleanupExpired()
console.log(`Removed ${result.entries_removed} expired entries`)
```

## TypeScript Types

Full TypeScript support is included. Import types directly:

```typescript
import {
  GeoClient,
  GeoClientConfig,
  GeoEvent,
  GeoEventOptions,
  QueryResult,
  RadiusQueryOptions,
  PolygonQueryOptions,
  DeleteResult,
  InsertGeoEventsError,
  // Error types
  ArcherDBError,
  ValidationError,
  ConnectionError,
  // Type guards
  isArcherDBError,
  isNetworkError,
  isRetryableError,
} from 'archerdb-node'
```

### GeoEvent Type

```typescript
interface GeoEvent {
  id: bigint              // Composite key (S2 cell | timestamp)
  entity_id: bigint       // UUID of tracked entity (u128)
  correlation_id: bigint  // Trip/session correlation (u128)
  user_data: bigint       // Application metadata (u128)
  lat_nano: bigint        // Latitude in nanodegrees
  lon_nano: bigint        // Longitude in nanodegrees
  group_id: bigint        // Fleet/region grouping (u64)
  timestamp: bigint       // Nanoseconds since Unix epoch
  altitude_mm: number     // Altitude in millimeters
  velocity_mms: number    // Speed in millimeters per second
  ttl_seconds: number     // Time-to-live in seconds (0 = never)
  accuracy_mm: number     // GPS accuracy in millimeters
  heading_cdeg: number    // Heading in centidegrees (0-36000)
  flags: number           // GeoEventFlags bitmask
}
```

### GeoEventOptions Type

```typescript
interface GeoEventOptions {
  entity_id: bigint       // Required: entity UUID
  latitude: number        // Required: degrees (-90 to +90)
  longitude: number       // Required: degrees (-180 to +180)
  correlation_id?: bigint // Optional: trip/session ID
  user_data?: bigint      // Optional: application data
  group_id?: bigint       // Optional: fleet/region grouping
  altitude_m?: number     // Optional: altitude in meters
  velocity_mps?: number   // Optional: speed in m/s
  ttl_seconds?: number    // Optional: TTL in seconds
  accuracy_m?: number     // Optional: GPS accuracy in meters
  heading?: number        // Optional: heading in degrees (0-360)
  flags?: GeoEventFlags   // Optional: event flags
}
```

### QueryResult Type

```typescript
interface QueryResult {
  events: GeoEvent[]      // Matching events
  has_more: boolean       // True if more results available
  cursor?: bigint         // Pagination cursor for next query
}
```

## Error Handling

ArcherDB uses typed errors with numeric codes for programmatic handling:

```typescript
import {
  ArcherDBError,
  InvalidCoordinates,
  BatchTooLarge,
  ConnectionTimeout,
  isArcherDBError,
  isNetworkError,
  isValidationError,
  isRetryableError,
} from 'archerdb-node'

try {
  const results = await client.queryRadius(options)
} catch (error) {
  // Check specific error types
  if (error instanceof InvalidCoordinates) {
    // Coordinates out of valid range - fix input
    console.error(`Invalid coordinates: ${error.message}`)
    return
  }

  if (isValidationError(error)) {
    // Other validation errors (polygon too complex, batch too large, etc.)
    console.error(`Validation error (${error.code}): ${error.message}`)
    return
  }

  if (isNetworkError(error)) {
    // Network issues - may be retryable
    console.error(`Network error: ${error.message}`)
    if (isRetryableError(error)) {
      // Implement retry logic
    }
    return
  }

  if (isArcherDBError(error)) {
    // Other ArcherDB errors
    console.error(`ArcherDB error (${error.code}): ${error.message}`)
    console.error(`Retryable: ${error.retryable}`)
    return
  }

  // Unknown error
  throw error
}
```

### Error Types

| Error Class | Codes | Retryable | Description |
|-------------|-------|-----------|-------------|
| `ConnectionFailed` | 1001 | Yes | Cannot connect to cluster |
| `ConnectionTimeout` | 1002 | Yes | Connection timed out |
| `ClusterUnavailable` | 2001 | Yes | No cluster replicas available |
| `ViewChangeInProgress` | 2002 | Yes | Cluster view change in progress |
| `NotPrimary` | 2003 | Yes | Not connected to primary |
| `InvalidCoordinates` | 3001 | No | Coordinates out of range |
| `PolygonTooComplex` | 3002 | No | Too many polygon vertices |
| `BatchTooLarge` | 3003 | No | Batch exceeds 10,000 items |
| `InvalidEntityId` | 3004 | No | Entity ID is zero |
| `OperationTimeout` | 4001 | Yes* | Operation timed out |
| `QueryResultTooLarge` | 4002 | No | Result exceeds limit |
| `OutOfSpace` | 4003 | No | Cluster storage full |
| `SessionExpired` | 4004 | Yes | Client session expired |

\* OperationTimeout may have partially committed - use idempotent operations.

### Type Guards

```typescript
// Check if any ArcherDB error
if (isArcherDBError(error)) { ... }

// Check if network-related (connection/cluster errors)
if (isNetworkError(error)) { ... }

// Check if validation error (invalid input)
if (isValidationError(error)) { ... }

// Check if operation error (timeout, too large, etc.)
if (isOperationError(error)) { ... }

// Check if error can be retried
if (isRetryableError(error)) { ... }
```

## Retry Configuration

Configure automatic retry behavior when creating the client:

```typescript
const client = createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3001'],
  retry: {
    enabled: true,          // Enable automatic retry (default: true)
    max_retries: 5,         // Maximum retry attempts (default: 5)
    base_backoff_ms: 100,   // Initial backoff delay (default: 100)
    max_backoff_ms: 1600,   // Maximum backoff delay (default: 1600)
    total_timeout_ms: 30000,// Total timeout for all retries (default: 30000)
    jitter: true,           // Add random jitter to backoff (default: true)
  },
})
```

### Backoff Schedule

| Attempt | Delay |
|---------|-------|
| 1 | 0ms (immediate) |
| 2 | 100ms + jitter |
| 3 | 200ms + jitter |
| 4 | 400ms + jitter |
| 5 | 800ms + jitter |
| 6 | 1600ms + jitter |

### Per-Operation Overrides

Override retry settings for individual operations:

```typescript
// Use shorter timeout for time-sensitive queries
const results = await client.queryRadius(
  { latitude: 37.77, longitude: -122.41, radius_m: 1000 },
  { max_retries: 2, timeout_ms: 5000 }
)

// Disable retry for idempotent batch insert
const errors = await client.insertEvents(events, { max_retries: 0 })
```

### Manual Retry with Batch Splitting

When a large batch times out, split it into smaller chunks:

```typescript
import { splitBatch, OperationTimeout } from 'archerdb-node'

try {
  await client.insertEvents(largeEventList)
} catch (error) {
  if (error instanceof OperationTimeout) {
    // Split into smaller batches and retry
    const chunks = splitBatch(largeEventList, 1000)
    for (const chunk of chunks) {
      await client.insertEvents(chunk)
    }
  }
}
```

## Circuit Breaker

The client includes per-replica circuit breakers for fault isolation:

- **Opens when:** 50% failure rate in 10s window AND >= 10 requests
- **Stays open:** 30 seconds before transitioning to half-open
- **Half-open:** Allows 5 test requests before deciding to close or re-open
- **Per-replica:** Failures on one replica don't affect others

Circuit breaker state is automatic - no configuration needed.

## Best Practices

### 1. Always Destroy Clients

```typescript
const client = createGeoClient(config)
try {
  // ... use client
} finally {
  client.destroy()
}
```

### 2. Use Batching for High Throughput

```typescript
// Good: Batch multiple events
const batch = client.createBatch()
for (const event of events) {
  batch.add(event)
}
await batch.commit()

// Avoid: Single-event inserts in a loop
for (const event of events) {
  await client.insertEvents([event]) // Slower
}
```

### 3. Handle Pagination

```typescript
let cursor: bigint | undefined
do {
  const results = await client.queryRadius({
    latitude: 37.77,
    longitude: -122.41,
    radius_m: 5000,
    limit: 1000,
    timestamp_max: cursor,
  })

  for (const event of results.events) {
    processEvent(event)
  }

  cursor = results.cursor
} while (results.has_more)
```

### 4. Use Group IDs for Multi-Tenant

```typescript
// Insert with group_id
const event = createGeoEvent({
  entity_id: vehicleId,
  latitude: 37.77,
  longitude: -122.41,
  group_id: fleetId,  // Fleet/tenant identifier
})

// Query filtered by group
const results = await client.queryRadius({
  latitude: 37.77,
  longitude: -122.41,
  radius_m: 5000,
  group_id: fleetId,  // Only returns events in this fleet
})
```
