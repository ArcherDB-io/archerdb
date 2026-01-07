# archerdb-java

The ArcherDB Java client for high-performance geospatial data storage and queries.

## Prerequisites

Linux >= 5.6 is the only production environment we support. For development, macOS and Windows are also supported.

* Java >= 11
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

## Error Handling

```java
import com.archerdb.geo.exceptions.*;

try {
    QueryResult result = client.queryRadius(filter);
} catch (ValidationException e) {
    System.out.println("Invalid input: " + e.getMessage());
} catch (ConnectionException e) {
    System.out.println("Connection failed: " + e.getMessage());
} catch (ArcherDBException e) {
    System.out.println("ArcherDB error: " + e.getMessage());
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

For async operations using CompletableFuture:

```java
import com.archerdb.geo.GeoClientAsync;

GeoClientAsync client = GeoClientAsync.create(0L, "127.0.0.1:3001");

CompletableFuture<Void> future = client.insertEventsAsync(events)
    .thenAccept(errors -> {
        if (errors.isEmpty()) {
            System.out.println("All events inserted!");
        }
    });

CompletableFuture<QueryResult> queryFuture = client.queryRadiusAsync(filter)
    .thenApply(result -> {
        System.out.println("Found " + result.getEvents().size() + " events");
        return result;
    });
```

## Links

* [ArcherDB Documentation](https://github.com/ArcherDB-io/archerdb)
* [Client SDK Specification](/openspec/changes/add-geospatial-core/specs/client-sdk/spec.md)
