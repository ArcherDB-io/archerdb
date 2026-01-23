# archerdb-go

The official ArcherDB Go client for high-performance geospatial data storage and real-time location tracking.

ArcherDB is designed for applications that track millions of moving entities (vehicles, devices, people) with sub-millisecond query latency. This SDK provides a thread-safe client with automatic retry, connection pooling, and comprehensive error handling.

## Prerequisites

- **Go** >= 1.21
- **Linux** >= 5.6 (production) or macOS (development)

## Installation

```bash
go get github.com/archerdb/archerdb-go
```

## Quick Start

```go
package main

import (
    "fmt"
    "log"

    archerdb "github.com/archerdb/archerdb-go"
    "github.com/archerdb/archerdb-go/pkg/types"
)

func main() {
    // Create client with retry configuration
    client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
        ClusterID: types.ToUint128(0),
        Addresses: []string{"127.0.0.1:3001"},
        Retry: &archerdb.RetryConfig{
            Enabled:    true,
            MaxRetries: 5,
        },
    })
    if err != nil {
        log.Fatal(err)
    }
    defer client.Close()

    // Create a geo event using user-friendly units
    event, err := types.NewGeoEvent(types.GeoEventOptions{
        EntityID:   types.ID(),              // Generate sortable UUID
        Latitude:   37.7749,                 // Degrees
        Longitude:  -122.4194,               // Degrees
        GroupID:    1,                       // Fleet/tenant ID
        TTLSeconds: 86400,                   // 24-hour TTL
    })
    if err != nil {
        log.Fatal(err)
    }

    // Insert the event
    errors, err := client.InsertEvents([]types.GeoEvent{event})
    if err != nil {
        log.Fatal(err)
    }
    if len(errors) > 0 {
        log.Printf("Some events failed: %v", errors)
    }

    // Query events within 1km radius
    filter, _ := types.NewRadiusQuery(37.7749, -122.4194, 1000, 100)
    results, err := client.QueryRadius(filter)
    if err != nil {
        log.Fatal(err)
    }

    fmt.Printf("Found %d events within 1km\n", len(results.Events))
    for _, evt := range results.Events {
        fmt.Printf("  Entity %s at (%.6f, %.6f)\n",
            evt.EntityID.String(), evt.Latitude(), evt.Longitude())
    }
}
```

## Creating a Client

### Basic Configuration

```go
client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
    ClusterID: types.ToUint128(0),           // Cluster identifier
    Addresses: []string{"127.0.0.1:3001"},   // At least one address required
})
```

### Multi-Node Cluster

```go
client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
    ClusterID: types.ToUint128(0),
    Addresses: []string{
        "node1.example.com:3001",
        "node2.example.com:3001",
        "node3.example.com:3001",
    },
})
```

### With Timeouts

```go
client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
    ClusterID:      types.ToUint128(0),
    Addresses:      []string{"127.0.0.1:3001"},
    ConnectTimeout: 5 * time.Second,   // Connection timeout
    RequestTimeout: 10 * time.Second,  // Per-request timeout
})
```

## GeoEvent Structure

The `GeoEvent` is the core data structure for location tracking. Coordinates use precise integer units to avoid floating-point errors.

### Unit Reference

| Field | Unit | Conversion |
|-------|------|------------|
| `LatNano`, `LonNano` | Nanodegrees (10^-9 degrees) | 37.7749 deg = 37774900000 nano |
| `AltitudeMM`, `AccuracyMM`, `RadiusMM` | Millimeters | 1000 m = 1000000 mm |
| `VelocityMMS` | Millimeters/second | 100 m/s = 100000 mm/s |
| `HeadingCdeg` | Centidegrees (0.01 deg) | 90 deg = 9000 cdeg |
| `Timestamp` | Nanoseconds since Unix epoch | `time.Now().UnixNano()` |
| `TTLSeconds` | Seconds | 86400 = 24 hours |

### Using GeoEventOptions (Recommended)

Use `types.NewGeoEvent` with user-friendly units:

```go
event, err := types.NewGeoEvent(types.GeoEventOptions{
    EntityID:      types.ID(),         // Generate sortable UUID
    Latitude:      37.7749,            // Degrees (-90 to +90)
    Longitude:     -122.4194,          // Degrees (-180 to +180)
    CorrelationID: tripID,             // Trip/session tracking
    UserData:      foreignKey,         // App metadata
    GroupID:       fleetID,            // Fleet/tenant grouping
    AltitudeM:     10.5,               // Meters above WGS84
    VelocityMPS:   15.0,               // Meters per second
    TTLSeconds:    86400,              // Time-to-live (0 = never expire)
    AccuracyM:     5.0,                // GPS accuracy in meters
    Heading:       90.0,               // Degrees (0=N, 90=E, 180=S, 270=W)
    Flags:         types.GeoEventFlagNone,
})
```

### Raw GeoEvent Struct

For maximum control:

```go
event := types.GeoEvent{
    EntityID:    types.ID(),
    LatNano:     types.DegreesToNano(37.7749),
    LonNano:     types.DegreesToNano(-122.4194),
    GroupID:     1,
    AltitudeMM:  types.MetersToMM(10.5),
    VelocityMMS: uint32(15.0 * 1000),
    HeadingCdeg: types.HeadingToCentidegrees(90.0),
    TTLSeconds:  86400,
}
```

## Insert Operations

### Single Insert

```go
errors, err := client.InsertEvents([]types.GeoEvent{event})
if err != nil {
    // Network or system error
    log.Fatal(err)
}
for _, e := range errors {
    log.Printf("Event %d failed: code=%d", e.Index, e.Result)
}
```

### Batch Insert

```go
// Create up to 10,000 events per batch
events := make([]types.GeoEvent, 0, 1000)
for _, data := range locations {
    event, err := types.NewGeoEvent(types.GeoEventOptions{
        EntityID:  data.ID,
        Latitude:  data.Lat,
        Longitude: data.Lon,
    })
    if err != nil {
        continue // Skip invalid
    }
    events = append(events, event)
}

errors, err := client.InsertEvents(events)
```

### Using Batch Builder

For accumulated inserts with automatic size management:

```go
batch := client.CreateBatch()
for _, data := range locations {
    err := batch.AddFromOptions(types.GeoEventOptions{
        EntityID:  data.ID,
        Latitude:  data.Lat,
        Longitude: data.Lon,
    })
    if err != nil {
        log.Printf("Invalid event: %v", err)
        continue
    }

    if batch.IsFull() {
        errors, err := batch.Commit()
        if err != nil {
            log.Printf("Batch failed: %v", err)
        }
    }
}
// Commit remaining events
errors, err := batch.Commit()
```

### Upsert (Insert or Update)

```go
// Update if exists, insert otherwise
errors, err := client.UpsertEvents(events)
```

## Query Operations

### Query by Radius

Find events within a circular area:

```go
// Using helper function (degrees and meters)
filter, err := types.NewRadiusQuery(37.7749, -122.4194, 1000, 100)
results, err := client.QueryRadius(filter)

// With time and group filters
filter := types.QueryRadiusFilter{
    CenterLatNano: types.DegreesToNano(37.7749),
    CenterLonNano: types.DegreesToNano(-122.4194),
    RadiusMM:      1000000,  // 1 km
    Limit:         100,
    TimestampMin:  uint64(time.Now().Add(-1*time.Hour).UnixNano()),
    TimestampMax:  uint64(time.Now().UnixNano()),
    GroupID:       types.ToUint128(fleetID),
}
results, err := client.QueryRadius(filter)

for _, event := range results.Events {
    fmt.Printf("Entity %s at (%.6f, %.6f)\n",
        event.EntityID.String(), event.Latitude(), event.Longitude())
}
```

### Query by Polygon

Find events within a polygon boundary:

```go
// Define polygon vertices (counter-clockwise order)
vertices := [][]float64{
    {37.78, -122.42},  // NW corner
    {37.78, -122.40},  // NE corner
    {37.76, -122.40},  // SE corner
    {37.76, -122.42},  // SW corner
}

filter, err := types.NewPolygonQuery(vertices, 100)
results, err := client.QueryPolygon(filter)
```

### Query with Polygon Holes

Exclude areas within the polygon:

```go
// Outer boundary (counter-clockwise)
outer := [][]float64{
    {37.80, -122.45},
    {37.80, -122.38},
    {37.74, -122.38},
    {37.74, -122.45},
}

// Hole (clockwise) - exclude this area
hole := [][]float64{
    {37.78, -122.43},
    {37.76, -122.43},
    {37.76, -122.41},
    {37.78, -122.41},
}

filter, err := types.NewPolygonQuery(outer, 100, hole)
results, err := client.QueryPolygon(filter)
```

### Query Latest Events

Get the most recent events globally or by group:

```go
results, err := client.QueryLatest(types.QueryLatestFilter{
    Limit:   100,
    GroupID: fleetID,  // 0 for all groups
})

for _, event := range results.Events {
    fmt.Printf("Entity %s: last seen at %v\n",
        event.EntityID.String(),
        time.Unix(0, int64(event.Timestamp)))
}
```

### Get Event by Entity UUID

Look up the latest event for a specific entity:

```go
event, err := client.GetLatestByUUID(entityID)
if err != nil {
    if errors.Is(err, archerdb.ErrEntityExpired) {
        log.Printf("Entity has expired (TTL elapsed)")
    }
    return
}
if event == nil {
    log.Printf("Entity not found")
    return
}
log.Printf("Last seen: (%.6f, %.6f)", event.Latitude(), event.Longitude())
```

### Batch UUID Lookup

Look up multiple entities efficiently:

```go
entityIDs := []types.Uint128{id1, id2, id3}
result, err := client.QueryUUIDBatch(entityIDs)

fmt.Printf("Found %d, not found %d\n", result.FoundCount, result.NotFoundCount)
for _, event := range result.Events {
    // Process found events
}
for _, idx := range result.NotFoundIndices {
    // Handle not found entities
    log.Printf("Entity %s not found", entityIDs[idx].String())
}
```

### Pagination

Handle large result sets with cursor-based pagination:

```go
var allEvents []types.GeoEvent
var cursor uint64

for {
    filter := types.QueryRadiusFilter{
        CenterLatNano: types.DegreesToNano(37.7749),
        CenterLonNano: types.DegreesToNano(-122.4194),
        RadiusMM:      10000000,  // 10 km
        Limit:         1000,
        TimestampMax:  cursor,  // Use cursor for pagination
    }

    results, err := client.QueryRadius(filter)
    if err != nil {
        break
    }

    allEvents = append(allEvents, results.Events...)

    if !results.HasMore {
        break
    }
    cursor = results.Cursor
}
```

## Delete Operations

GDPR-compliant deletion of all events for an entity:

```go
entityIDs := []types.Uint128{entityID1, entityID2}
result, err := client.DeleteEntities(entityIDs)

fmt.Printf("Deleted: %d, Not found: %d\n",
    result.DeletedCount, result.NotFoundCount)
```

Using batch builder:

```go
batch := client.CreateDeleteBatch()
for _, id := range idsToDelete {
    batch.Add(id)
}
result, err := batch.Commit()
```

## TTL Operations

Manage entity time-to-live for automatic expiration.

### Set Absolute TTL

```go
// Entity expires in 24 hours
resp, err := client.SetTTL(entityID, 86400)
if err != nil {
    log.Fatal(err)
}
log.Printf("Previous TTL: %d, New TTL: %d",
    resp.PreviousTTLSeconds, resp.NewTTLSeconds)
```

### Extend TTL

Keep active entities from expiring:

```go
// Add 1 hour to existing TTL
resp, err := client.ExtendTTL(entityID, 3600)
```

### Clear TTL

Make an entity permanent (never expire):

```go
resp, err := client.ClearTTL(entityID)
```

## Context Support

Operations support Go context for cancellation and timeouts through the client configuration:

```go
// Set per-request timeout via config
client, err := archerdb.NewGeoClient(archerdb.GeoClientConfig{
    ClusterID:      types.ToUint128(0),
    Addresses:      []string{"127.0.0.1:3001"},
    RequestTimeout: 5 * time.Second,
})

// Operations will respect the timeout
results, err := client.QueryRadius(filter)
if err != nil {
    if errors.Is(err, archerdb.ErrOperationTimeout) {
        log.Printf("Query timed out")
    }
}
```

For per-operation timeouts, use a channel-based pattern:

```go
done := make(chan struct{})
var results types.QueryResult
var queryErr error

go func() {
    results, queryErr = client.QueryRadius(filter)
    close(done)
}()

select {
case <-done:
    // Query completed
case <-time.After(5 * time.Second):
    log.Printf("Query timed out")
    return
}
```

## Error Handling

All errors implement the `GeoError` interface and support `errors.Is` for type checking.

### Using errors.Is

```go
import (
    archerdb "github.com/archerdb/archerdb-go"
    "github.com/archerdb/archerdb-go/pkg/errors"
)

result, err := client.QueryRadius(filter)
if err != nil {
    // Check specific error type
    if errors.Is(err, archerdb.ErrInvalidCoordinates) {
        log.Printf("Invalid coordinates: %v", err)
        return
    }
    if errors.Is(err, archerdb.ErrClientClosed) {
        log.Printf("Client was closed")
        return
    }

    // Check error categories
    if archerdb.IsNetworkError(err) {
        log.Printf("Network error (retryable): %v", err)
    }
    if archerdb.IsValidationError(err) {
        log.Printf("Validation error (fix input): %v", err)
    }

    // Check if retryable
    if geoErr, ok := err.(archerdb.GeoError); ok {
        if geoErr.Retryable() {
            log.Printf("Error is retryable, code: %d", geoErr.Code())
        }
    }
}
```

### Error Categories

| Category | Error Types | Action |
|----------|-------------|--------|
| **Network** | `ConnectionFailedError`, `ConnectionTimeoutError`, `ClusterUnavailableError`, `OperationTimeoutError` | Retry with backoff |
| **Validation** | `InvalidCoordinatesError`, `BatchTooLargeError`, `InvalidEntityIDError`, `QueryResultTooLargeError` | Fix input |
| **State** | `ClientClosedError`, `EntityExpiredError` | Handle appropriately |
| **Retry** | `RetryExhaustedError` | Check `LastError`, increase timeout |

### Error Codes

```go
if geoErr, ok := err.(archerdb.GeoError); ok {
    switch geoErr.Code() {
    case 1001:  // ConnectionFailed
    case 1002:  // ConnectionTimeout
    case 2001:  // ClusterUnavailable
    case 3001:  // InvalidCoordinates
    case 3003:  // BatchTooLarge
    case 3004:  // InvalidEntityID
    case 4001:  // OperationTimeout
    case 4002:  // QueryResultTooLarge
    case 5001:  // ClientClosed
    case 5002:  // RetryExhausted
    }
}
```

## Retry Configuration

Configure automatic retry behavior for transient failures:

```go
config := archerdb.GeoClientConfig{
    ClusterID: types.ToUint128(0),
    Addresses: []string{"127.0.0.1:3001"},
    Retry: &archerdb.RetryConfig{
        Enabled:      true,                     // Enable automatic retry
        MaxRetries:   5,                        // Retry up to 5 times after initial failure
        BaseBackoff:  100 * time.Millisecond,   // Initial backoff delay
        MaxBackoff:   1600 * time.Millisecond,  // Maximum backoff delay
        TotalTimeout: 30 * time.Second,         // Total time budget for all retries
        Jitter:       true,                     // Add randomness to prevent thundering herd
    },
}
```

### Backoff Behavior

With default settings, the retry sequence (without jitter) is:
- Attempt 1: Immediate
- Attempt 2: 100ms delay
- Attempt 3: 200ms delay
- Attempt 4: 400ms delay
- Attempt 5: 800ms delay
- Attempt 6: 1600ms delay

With jitter enabled, each delay is randomized by adding `random(0, delay/2)`.

### Handling Retry Exhaustion

```go
results, err := client.InsertEvents(events)
if err != nil {
    if retryErr, ok := err.(archerdb.RetryExhaustedError); ok {
        log.Printf("All %d retries failed. Last error: %v",
            retryErr.Attempts, retryErr.LastError)
    }
}
```

## Thread Safety

The client is goroutine-safe. Create one instance and share it:

```go
var client archerdb.GeoClient

func init() {
    var err error
    client, err = archerdb.NewGeoClient(config)
    if err != nil {
        log.Fatal(err)
    }
}

func HandleRequest(entityID types.Uint128, lat, lon float64) {
    event, _ := types.NewGeoEvent(types.GeoEventOptions{
        EntityID:  entityID,
        Latitude:  lat,
        Longitude: lon,
    })
    client.InsertEvents([]types.GeoEvent{event})
}
```

Concurrent usage example:

```go
var wg sync.WaitGroup
for i := 0; i < 10; i++ {
    wg.Add(1)
    go func() {
        defer wg.Done()
        for j := 0; j < 1000; j++ {
            client.InsertEvents(events[j:j+1])
        }
    }()
}
wg.Wait()
```

## Cluster Topology

The client automatically discovers and caches cluster topology.

### Get Topology

```go
topology, err := client.GetTopology()
if err != nil {
    log.Fatal(err)
}

fmt.Printf("Cluster: %s, Shards: %d\n",
    topology.ClusterID.String(), topology.NumShards)

for _, shard := range topology.Shards {
    fmt.Printf("  Shard %d: primary=%s, status=%s\n",
        shard.ID, shard.Primary, shard.Status.String())
}
```

### Force Topology Refresh

```go
err := client.RefreshTopology()
```

### Access Topology Cache

```go
cache := client.GetTopologyCache()
if cache.IsResharding() {
    log.Printf("Cluster is resharding")
}
```

## Performance Tips

1. **Reuse the client**: Create once, share across goroutines
2. **Batch operations**: Use batches up to 8,000-10,000 events
3. **Use pagination**: Query with limits and cursors for large result sets
4. **Filter early**: Use GroupID and time filters to reduce result size
5. **Set appropriate TTLs**: Let expired data be cleaned up automatically

### Efficient Batching

```go
const batchSize = 8000

chunks := archerdb.SplitBatch(events, batchSize)
for _, chunk := range chunks {
    errors, err := client.InsertEvents(chunk)
    if err != nil {
        log.Printf("Batch failed: %v", err)
        continue
    }
    if len(errors) > 0 {
        log.Printf("%d events in batch failed validation", len(errors))
    }
}
```

## Links

- [ArcherDB Documentation](https://github.com/ArcherDB-io/archerdb)
- [API Reference](https://pkg.go.dev/github.com/archerdb/archerdb-go)
