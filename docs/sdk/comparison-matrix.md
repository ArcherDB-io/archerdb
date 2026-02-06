# SDK Comparison Matrix

Feature comparison and code examples across all 5 ArcherDB SDKs.

## Overview

ArcherDB provides official SDKs for 5 languages:

| SDK | Package | Min Version | Install |
|-----|---------|-------------|---------|
| Python | `archerdb` | Python 3.11+ | `pip install archerdb` |
| Node.js | `archerdb-node` | Node 20+ | `npm install archerdb-node` |
| Go | `archerdb-go` | Go 1.21+ | `go get github.com/archerdb/archerdb-go` |
| Java | `archerdb-java` | Java 21+ | Maven/Gradle |
| C | `libarcherdb` | C11+ | Header-only or static lib |

## Feature Parity Matrix

All SDKs implement the complete ArcherDB API with 100% feature parity.

### Operations (14 total)

| Operation | Python | Node.js | Go | Java | C |
|-----------|--------|---------|----|----|---|
| insert | Yes | Yes | Yes | Yes | Yes |
| upsert | Yes | Yes | Yes | Yes | Yes |
| delete | Yes | Yes | Yes | Yes | Yes |
| query-uuid | Yes | Yes | Yes | Yes | Yes |
| query-uuid-batch | Yes | Yes | Yes | Yes | Yes |
| query-radius | Yes | Yes | Yes | Yes | Yes |
| query-polygon | Yes | Yes | Yes | Yes | Yes |
| query-latest | Yes | Yes | Yes | Yes | Yes |
| ping | Yes | Yes | Yes | Yes | Yes |
| status | Yes | Yes | Yes | Yes | Yes |
| topology | Yes | Yes | Yes | Yes | Yes |
| ttl-set | Yes | Yes | Yes | Yes | Yes |
| ttl-extend | Yes | Yes | Yes | Yes | Yes |
| ttl-clear | Yes | Yes | Yes | Yes | Yes |

### Features

| Feature | Python | Node.js | Go | Java | C |
|---------|--------|---------|----|----|---|
| Sync client | Yes | - | Yes | Yes | Yes |
| Async client | Yes | Yes | Yes | Yes | Callback |
| Connection pooling | Yes | Yes | Yes | Yes | Manual |
| Automatic retry | Yes | Yes | Yes | Yes | Yes |
| Configurable retries | Yes | Yes | Yes | Yes | Yes |
| Type safety | Hints | TypeScript | Yes | Yes | Headers |
| Pagination support | Yes | Yes | Yes | Yes | Yes |
| Error categories | Yes | Yes | Yes | Yes | Yes |

### Error Handling

| Error Type | Python | Node.js | Go | Java | C |
|------------|--------|---------|----|----|---|
| Validation errors | Exception | Error | error | Exception | Return code |
| Network errors | Exception | Error | error | Exception | Return code |
| Server errors | Exception | Error | error | Exception | Return code |
| Retryable detection | is_retryable() | isRetryable() | IsRetryable() | isRetryable() | is_retryable() |

## Code Examples

### Insert Event

**Python:**
```python
from archerdb import GeoClientSync, GeoClientConfig, create_geo_event

client = GeoClientSync(GeoClientConfig(
    cluster_id=0,
    addresses=["127.0.0.1:3001"]
))

event = create_geo_event(
    entity_id=1001,
    latitude=37.7749,
    longitude=-122.4194,
    ttl_seconds=3600
)
errors = client.insert_events([event])
```

**Node.js:**
```javascript
import { GeoClient, createGeoEvent } from 'archerdb-node';

const client = new GeoClient({
  clusterId: 0,
  addresses: ['127.0.0.1:3001']
});

const event = createGeoEvent({
  entityId: 1001n,
  latitude: 37.7749,
  longitude: -122.4194,
  ttlSeconds: 3600
});
const errors = await client.insertEvents([event]);
```

**Go:**
```go
import "github.com/archerdb/archerdb-go"

client, err := archerdb.NewClient(archerdb.Config{
    ClusterID: 0,
    Addresses: []string{"127.0.0.1:3001"},
})

event := archerdb.GeoEvent{
    EntityID:   1001,
    Latitude:   37.7749,
    Longitude:  -122.4194,
    TTLSeconds: 3600,
}
errors, err := client.InsertEvents(ctx, []archerdb.GeoEvent{event})
```

**Java:**
```java
import com.archerdb.GeoClient;
import com.archerdb.GeoEvent;

GeoClient client = GeoClient.builder()
    .clusterId(0)
    .addresses(List.of("127.0.0.1:3001"))
    .build();

GeoEvent event = GeoEvent.builder()
    .entityId(1001L)
    .latitude(37.7749)
    .longitude(-122.4194)
    .ttlSeconds(3600)
    .build();
List<Error> errors = client.insertEvents(List.of(event));
```

**C:**
```c
#include <archerdb.h>

archerdb_client_t* client = archerdb_client_create(
    0,  // cluster_id
    "127.0.0.1:3001"
);

archerdb_event_t event = {
    .entity_id = 1001,
    .latitude = 37.7749,
    .longitude = -122.4194,
    .ttl_seconds = 3600
};
int result = archerdb_insert_events(client, &event, 1);
```

### Query Radius

**Python:**
```python
results = client.query_radius(
    center_lat=37.7749,
    center_lon=-122.4194,
    radius_meters=1000,
    limit=100
)
for event in results.events:
    print(f"{event.entity_id}: {event.distance_meters}m away")
```

**Node.js:**
```javascript
const results = await client.queryRadius({
  centerLat: 37.7749,
  centerLon: -122.4194,
  radiusMeters: 1000,
  limit: 100
});
results.events.forEach(event => {
  console.log(`${event.entityId}: ${event.distanceMeters}m away`);
});
```

**Go:**
```go
results, err := client.QueryRadius(ctx, archerdb.RadiusQuery{
    CenterLat:    37.7749,
    CenterLon:    -122.4194,
    RadiusMeters: 1000,
    Limit:        100,
})
for _, event := range results.Events {
    fmt.Printf("%d: %dm away\n", event.EntityID, event.DistanceMeters)
}
```

**Java:**
```java
RadiusQueryResult results = client.queryRadius(RadiusQuery.builder()
    .centerLat(37.7749)
    .centerLon(-122.4194)
    .radiusMeters(1000)
    .limit(100)
    .build());
results.getEvents().forEach(event ->
    System.out.printf("%d: %dm away%n", event.getEntityId(), event.getDistanceMeters()));
```

**C:**
```c
archerdb_radius_query_t query = {
    .center_lat = 37.7749,
    .center_lon = -122.4194,
    .radius_meters = 1000,
    .limit = 100
};
archerdb_result_t* results;
int count = archerdb_query_radius(client, &query, &results);
for (int i = 0; i < count; i++) {
    printf("%llu: %dm away\n", results[i].entity_id, results[i].distance_meters);
}
archerdb_free_results(results);
```

### Error Handling

**Python:**
```python
from archerdb import ArcherDBError

try:
    client.insert_events([event])
except ArcherDBError as e:
    if e.is_retryable():
        # Retry with backoff
        pass
    else:
        # Handle validation error
        print(f"Error {e.code}: {e.message}")
```

**Node.js:**
```javascript
import { ArcherDBError } from 'archerdb-node';

try {
  await client.insertEvents([event]);
} catch (e) {
  if (e instanceof ArcherDBError && e.isRetryable()) {
    // Retry with backoff
  } else {
    console.error(`Error ${e.code}: ${e.message}`);
  }
}
```

**Go:**
```go
errors, err := client.InsertEvents(ctx, events)
if err != nil {
    var archErr *archerdb.Error
    if errors.As(err, &archErr) && archErr.IsRetryable() {
        // Retry with backoff
    } else {
        log.Printf("Error %d: %s", archErr.Code, archErr.Message)
    }
}
```

**Java:**
```java
try {
    client.insertEvents(events);
} catch (ArcherDBException e) {
    if (e.isRetryable()) {
        // Retry with backoff
    } else {
        System.err.printf("Error %d: %s%n", e.getCode(), e.getMessage());
    }
}
```

**C:**
```c
int result = archerdb_insert_events(client, events, count);
if (result != ARCHERDB_OK) {
    if (archerdb_is_retryable(result)) {
        // Retry with backoff
    } else {
        printf("Error %d: %s\n", result, archerdb_strerror(result));
    }
}
```

## Language-Specific Notes

### Python

- **Sync and async clients**: Use `GeoClientSync` for blocking operations, `GeoClientAsync` for async/await
- **Type hints**: Full type annotations for IDE support
- **Native binding**: Performance-critical code runs in the native client library

### Node.js

- **Promise-based**: All operations return Promises
- **TypeScript definitions**: Full TypeScript support included
- **ES modules**: Supports both ESM and CommonJS

### Go

- **Context support**: All operations accept context for cancellation/timeout
- **Connection pooling**: Built-in connection pool management
- **Generics**: Uses Go generics for type-safe APIs (Go 1.18+)

### Java

- **CompletableFuture**: Async operations return CompletableFuture
- **Builder pattern**: Fluent API for configuration and queries
- **Java 11+**: Requires Java 11 or newer

### C

- **Header-only option**: Can use as header-only library
- **Memory management**: Caller responsible for memory (malloc/free patterns)
- **Callbacks**: Async operations use callback functions

## Known Limitations

See [SDK_LIMITATIONS.md](../SDK_LIMITATIONS.md) for detailed workarounds.

Current status:

| SDK | Status | Notes |
|-----|--------|-------|
| Python | 94% parity | Connection error propagation issue |
| Node.js | Not yet verified | - |
| Go | Not yet verified | - |
| Java | Not yet verified | - |
| C | Not yet verified | - |

## Parity Testing

All SDKs are verified against each other to ensure identical behavior:

- 14 operations x 5 SDKs = 70 test cells
- Target: 100% parity before release
- See [PARITY.md](../PARITY.md) for methodology and current matrix

Run parity tests:

```bash
python tests/parity_tests/parity_runner.py
```

## Choosing an SDK

| Use Case | Recommended SDK | Why |
|----------|-----------------|-----|
| Web backend | Python, Node.js, Go | Ecosystem integration |
| Mobile backend | Go, Java | Performance, JVM ecosystem |
| Embedded systems | C | Low-level control, no runtime |
| Data pipelines | Python, Go | Async support, concurrency |
| Enterprise Java | Java | Spring/Jakarta integration |
| Systems programming | C | Zero-overhead, allocator control |

## See Also

- [SDK Overview](README.md) - General SDK documentation
- [SDK Limitations](../SDK_LIMITATIONS.md) - Known issues and workarounds
- [Parity Matrix](../PARITY.md) - Cross-SDK verification
- [curl Examples](../curl-examples.md) - Raw HTTP examples
- [Protocol Reference](../protocol.md) - Wire format details

---

*Last updated: 2026-02-01*
