# archerdb-java

The ArcherDB Java client for high-performance geospatial data storage and queries.

## Prerequisites

Linux >= 5.6 is the only production environment we support. For development, macOS and Windows are also supported.

* Java >= 11 (Java 21+: pass `--enable-native-access=ALL-UNNAMED` to the JVM to silence native access warnings)
* Maven >= 3.6 (recommended)

## Installation

### Maven

```xml
<dependency>
    <groupId>com.archerdb</groupId>
    <artifactId>archerdb-java</artifactId>
    <version>0.1.0</version>
</dependency>
```

### Gradle

```groovy
implementation 'com.archerdb:archerdb-java:0.1.0'
```

## Quick Start

```java
import com.archerdb.geo.*;

public class Main {
    public static void main(String[] args) throws Exception {
        // Connect to ArcherDB cluster
        try (GeoClient client = GeoClient.create(0L, "127.0.0.1:3001")) {
            // Insert a geo event
            GeoEvent event = new GeoEvent.Builder()
                .setEntityId(UInt128.random())
                .setLatitude(37.7749)        // San Francisco
                .setLongitude(-122.4194)
                .setTimestamp(System.nanoTime())
                .setGroupId(1L)
                .build();

            GeoEventBatch batch = client.createBatch();
            batch.add(event);
            batch.commit();

            System.out.println("Event inserted successfully!");

            // Query events within 1km radius
            QueryResult result = client.queryRadius(
                QueryRadiusFilter.create(37.7749, -122.4194, 1000, 100)
            );

            System.out.println("Found " + result.getEvents().size() + " events within 1km");
        }
    }
}
```

## Sample Projects

* [Basic](/src/clients/java/samples/basic/): Insert and query geospatial events.
* [Radius Query](/src/clients/java/samples/radius-query/): Advanced radius queries with pagination.
* [Polygon Query](/src/clients/java/samples/polygon-query/): Geofence-based polygon queries.

## API Reference

### Creating a Client

```java
import com.archerdb.geo.GeoClient;

// Single-node cluster
GeoClient client = GeoClient.create(0L, "127.0.0.1:3001");

// Multi-node cluster
GeoClient client = GeoClient.create(0L,
    "127.0.0.1:3001",
    "127.0.0.1:3002",
    "127.0.0.1:3003"
);

// Use try-with-resources for automatic cleanup
try (GeoClient client = GeoClient.create(0L, "127.0.0.1:3001")) {
    // Use the client
}
```

### GeoEvent Structure

```java
import com.archerdb.geo.*;

GeoEvent event = new GeoEvent.Builder()
    .setEntityId(UInt128.random())       // UUID of tracked entity
    .setCorrelationId(UInt128.ZERO)      // Trip/session correlation
    .setUserData(UInt128.ZERO)           // Application metadata
    .setLatitude(37.7749)                // Degrees (-90 to +90)
    .setLongitude(-122.4194)             // Degrees (-180 to +180)
    .setTimestamp(System.nanoTime())     // Nanoseconds since epoch
    .setGroupId(1L)                      // Fleet/region grouping
    .setAltitudeMm(0)                    // Altitude in millimeters
    .setSpeedMmps(0)                     // Speed in mm/s
    .setHeadingMicrodeg(0)               // Heading in microdegrees
    .setAccuracyMm(0)                    // GPS accuracy in mm
    .setStatus((short) 0)                // Application status flags
    .setEventType((byte) 0)              // Event type code
    .build();
```

### Insert Events

```java
GeoEventBatch batch = client.createBatch();
batch.add(event1);
batch.add(event2);
batch.add(event3);

batch.commit();  // Blocks until replicated

// Check for errors
List<InsertError> errors = batch.getErrors();
for (InsertError error : errors) {
    System.out.println("Event " + error.getIndex() + " failed: " + error.getResult());
}
```

### Upsert Events

```java
GeoEventBatch batch = client.createUpsertBatch();
batch.add(event);
batch.commit();
```

### Query by Radius

```java
QueryRadiusFilter filter = QueryRadiusFilter.builder()
    .setCenter(37.7749, -122.4194)   // Center coordinates
    .setRadiusMeters(5000)           // 5km radius
    .setLimit(1000)                  // Max results per page
    .setTimestampMin(startNs)        // Optional time filter
    .setTimestampMax(endNs)
    .setGroupId(1L)                  // Optional group filter
    .build();

QueryResult result = client.queryRadius(filter);

for (GeoEvent event : result.getEvents()) {
    System.out.printf("Entity at (%.6f, %.6f)%n",
        event.getLatitude(), event.getLongitude());
}

// Pagination
if (result.hasMore()) {
    QueryRadiusFilter nextFilter = QueryRadiusFilter.builder()
        .setCenter(37.7749, -122.4194)
        .setRadiusMeters(5000)
        .setLimit(1000)
        .setTimestampMax(result.getCursor() - 1)  // Continue from cursor
        .build();
    QueryResult nextResult = client.queryRadius(nextFilter);
}
```

### Query by Polygon

```java
// Polygon vertices (counter-clockwise winding)
List<LatLon> vertices = Arrays.asList(
    new LatLon(37.78, -122.42),
    new LatLon(37.78, -122.40),
    new LatLon(37.76, -122.40),
    new LatLon(37.76, -122.42)
);

QueryPolygonFilter filter = QueryPolygonFilter.builder()
    .setVertices(vertices)
    .setLimit(1000)
    .setTimestampMin(startNs)
    .setTimestampMax(endNs)
    .build();

QueryResult result = client.queryPolygon(filter);
```

### Query Latest by Entity UUID

```java
GeoEvent event = client.getLatestByUuid(entityId);

if (event != null) {
    System.out.printf("Last seen at (%.6f, %.6f)%n",
        event.getLatitude(), event.getLongitude());
}
```

### Query Latest Events

```java
QueryLatestFilter filter = QueryLatestFilter.builder()
    .setLimit(100)
    .setTimestampMin(startNs)
    .setGroupId(1L)
    .build();

QueryResult result = client.queryLatest(filter);

for (GeoEvent event : result.getEvents()) {
    System.out.printf("Entity %s: %.6f, %.6f%n",
        event.getEntityId(), event.getLatitude(), event.getLongitude());
}
```

### Delete Entities

GDPR-compliant deletion of all events for specified entities.

```java
DeleteResult result = client.deleteEntities(Arrays.asList(entityId1, entityId2));
System.out.println("Deleted " + result.getDeletedCount() + " entities");
```

## Exception Handling

ArcherDB uses a typed exception hierarchy for precise error handling:

```java
import com.archerdb.geo.*;

try {
    QueryResult result = client.queryRadius(filter);
} catch (ValidationException e) {
    // Invalid input (e.g., coordinates out of range, invalid polygon)
    // Client error - fix the request, don't retry
    System.err.println("Invalid query: " + e.getMessage());
    System.err.println("Error code: " + e.getErrorCode());
} catch (ConnectionException e) {
    // Network issues - usually retryable
    if (e.isRetryable()) {
        // Implement retry with exponential backoff
        System.out.println("Connection failed, retrying...");
    }
} catch (ClusterException e) {
    // Cluster state issues (view change, not primary)
    // Always retryable - SDK handles automatically
    System.out.println("Cluster issue: " + e.getMessage());
} catch (OperationException e) {
    // Operation-level failures (timeout, entity not found, etc.)
    switch (e.getErrorCode()) {
        case OperationException.ENTITY_NOT_FOUND:
            System.out.println("Entity does not exist");
            break;
        case OperationException.ENTITY_EXPIRED:
            System.out.println("Entity has expired (TTL)");
            break;
        case OperationException.TIMEOUT:
            // Timeout is retryable but with caution - operation may have committed
            if (e.isRetryable()) {
                System.out.println("Operation timed out, may retry");
            }
            break;
        default:
            System.err.println("Operation failed: " + e.getMessage());
    }
} catch (ArcherDBException e) {
    // Catch-all for other ArcherDB errors
    System.err.println("ArcherDB error: " + e.getMessage());
    System.err.println("Error code: " + e.getErrorCode());
    System.err.println("Retryable: " + e.isRetryable());
}
```

### Exception Types

| Exception | Error Codes | Retryable | Description |
|-----------|-------------|-----------|-------------|
| `ConnectionException` | 1-3 | Yes | Network connectivity issues (connection failed, timeout, TLS error) |
| `ClusterException` | 201-203 | Yes | Cluster state issues (unavailable, view change, not primary) |
| `ValidationException` | 100-120 | No | Invalid input parameters (coordinates, polygon, batch size) |
| `OperationException` | 200-310 | Varies | Operation-level failures (entity not found, timeout, resource exhausted) |

### Sharding Errors (220-224)

For sharded clusters, use `ShardingError` to handle shard-specific errors:

```java
try {
    QueryResult result = client.queryRadius(filter);
} catch (ArcherDBException e) {
    ShardingError shardError = ShardingError.fromCode(e.getErrorCode());
    if (shardError != null) {
        switch (shardError) {
            case NOT_SHARD_LEADER:
                // SDK automatically refreshes topology and retries
                break;
            case RESHARDING_IN_PROGRESS:
                // Wait and retry - cluster is resharding
                Thread.sleep(5000);
                break;
            case SHARD_UNAVAILABLE:
                // Shard has no available replicas
                System.err.println("Shard unavailable: " + e.getMessage());
                break;
        }
    }
}
```

### Encryption Errors (410-414)

For clusters with encryption at rest:

```java
EncryptionError encError = EncryptionError.fromCode(e.getErrorCode());
if (encError != null) {
    switch (encError) {
        case ENCRYPTION_KEY_UNAVAILABLE:
            // KMS/Vault connectivity issue - retry with backoff
            break;
        case DECRYPTION_FAILED:
            // Data corruption or tampering - do not retry
            break;
        case KEY_ROTATION_IN_PROGRESS:
            // Wait for rotation to complete
            break;
    }
}
```

### Retryable vs Non-Retryable

```java
try {
    client.insertEvents(events);
} catch (ArcherDBException e) {
    if (e.isRetryable()) {
        // Safe to retry with exponential backoff
        // Examples: connection timeout, cluster view change, rate limit
    } else {
        // Do NOT retry - fix the request first
        // Examples: invalid coordinates, polygon self-intersecting
    }
}
```

## Performance Tips

1. **Batch operations**: Always batch inserts (up to 10,000 events per call).
2. **Reuse client**: Create one client and reuse (thread-safe).
3. **Use pagination**: For large result sets, use cursor-based pagination.
4. **Filter early**: Use `groupId` and time filters to reduce result size.

```java
// Efficient batching
final int BATCH_SIZE = 8000;
for (int i = 0; i < events.size(); i += BATCH_SIZE) {
    GeoEventBatch batch = client.createBatch();
    int end = Math.min(i + BATCH_SIZE, events.size());
    for (int j = i; j < end; j++) {
        batch.add(events.get(j));
    }
    batch.commit();
}
```

## Thread Safety

The client is thread-safe. A single instance should be shared:

```java
GeoClient client = GeoClient.create(0L, "127.0.0.1:3001");

ExecutorService executor = Executors.newFixedThreadPool(10);
for (int i = 0; i < 10; i++) {
    executor.submit(() -> {
        GeoEventBatch batch = client.createBatch();
        batch.add(createEvent());
        batch.commit();
    });
}
executor.shutdown();
executor.awaitTermination(1, TimeUnit.MINUTES);

client.close();
```

## Async Support

For non-blocking operations using `CompletableFuture`, use `GeoClientAsync`:

```java
import com.archerdb.geo.GeoClientAsync;
import java.util.concurrent.CompletableFuture;

// Create async client (uses ForkJoinPool.commonPool by default)
try (GeoClientAsync client = GeoClientAsync.create(0L, "127.0.0.1:3001")) {

    // Basic async insert
    client.insertEventsAsync(events)
        .thenAccept(errors -> {
            if (errors.isEmpty()) {
                System.out.println("All events inserted!");
            } else {
                errors.forEach(e ->
                    System.err.println("Event " + e.getIndex() + " failed"));
            }
        })
        .exceptionally(ex -> {
            System.err.println("Insert failed: " + ex.getMessage());
            return null;
        });

    // Async query with result processing
    CompletableFuture<QueryResult> queryFuture = client.queryRadiusAsync(filter)
        .thenApply(result -> {
            System.out.println("Found " + result.getEvents().size() + " events");
            return result;
        });

    // Wait for result if needed
    QueryResult result = queryFuture.join();
}
```

### Parallel Queries

Execute multiple queries in parallel and combine results:

```java
// Query three regions simultaneously
CompletableFuture<QueryResult> region1 = client.queryRadiusAsync(filter1);
CompletableFuture<QueryResult> region2 = client.queryRadiusAsync(filter2);
CompletableFuture<QueryResult> region3 = client.queryRadiusAsync(filter3);

// Wait for all to complete
CompletableFuture.allOf(region1, region2, region3)
    .thenRun(() -> {
        int total = region1.join().getEvents().size()
                  + region2.join().getEvents().size()
                  + region3.join().getEvents().size();
        System.out.println("Total events across all regions: " + total);
    })
    .join();
```

### Chaining Operations

Chain dependent operations using `thenCompose`:

```java
// Look up entity, then query nearby
client.getLatestByUuidAsync(entityId)
    .thenCompose(event -> {
        if (event != null) {
            // Query around entity's current location
            QueryRadiusFilter filter = QueryRadiusFilter.builder()
                .setCenter(event.getLatitude(), event.getLongitude())
                .setRadiusMeters(1000)
                .setLimit(100)
                .build();
            return client.queryRadiusAsync(filter);
        }
        return CompletableFuture.completedFuture(QueryResult.empty());
    })
    .thenAccept(result -> {
        System.out.println("Found " + result.getEvents().size() + " nearby entities");
    });
```

### Custom Executor

For fine-grained control over thread pool:

```java
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;

// Create dedicated thread pool
ExecutorService executor = Executors.newFixedThreadPool(4);

// Wrap existing sync client with custom executor
GeoClient syncClient = GeoClient.create(0L, "127.0.0.1:3001");
GeoClientAsync asyncClient = GeoClientAsync.create(syncClient, executor);

// Use async client...

// Cleanup
asyncClient.close();  // Closes underlying sync client
executor.shutdown();
```

### All Async Methods

`GeoClientAsync` provides async versions of all `GeoClient` operations:

| Sync Method | Async Method | Return Type |
|-------------|--------------|-------------|
| `insertEvents()` | `insertEventsAsync()` | `CompletableFuture<List<InsertGeoEventsError>>` |
| `upsertEvents()` | `upsertEventsAsync()` | `CompletableFuture<List<InsertGeoEventsError>>` |
| `deleteEntities()` | `deleteEntitiesAsync()` | `CompletableFuture<DeleteResult>` |
| `getLatestByUuid()` | `getLatestByUuidAsync()` | `CompletableFuture<GeoEvent>` |
| `lookupBatch()` | `lookupBatchAsync()` | `CompletableFuture<Map<UInt128, GeoEvent>>` |
| `queryRadius()` | `queryRadiusAsync()` | `CompletableFuture<QueryResult>` |
| `queryPolygon()` | `queryPolygonAsync()` | `CompletableFuture<QueryResult>` |
| `queryLatest()` | `queryLatestAsync()` | `CompletableFuture<QueryResult>` |
| `setTtl()` | `setTtlAsync()` | `CompletableFuture<TtlSetResponse>` |
| `extendTtl()` | `extendTtlAsync()` | `CompletableFuture<TtlExtendResponse>` |
| `clearTtl()` | `clearTtlAsync()` | `CompletableFuture<TtlClearResponse>` |
| `ping()` | `pingAsync()` | `CompletableFuture<Boolean>` |
| `getStatus()` | `getStatusAsync()` | `CompletableFuture<StatusResponse>` |
| `getTopology()` | `getTopologyAsync()` | `CompletableFuture<TopologyResponse>` |

## Links

* [ArcherDB Documentation](https://github.com/ArcherDB-io/archerdb)
