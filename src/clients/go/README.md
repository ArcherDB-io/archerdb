# archerdb-go

The ArcherDB Go client for high-performance geospatial data storage and queries.

## Prerequisites

Linux >= 5.6 is the only production environment we support. For development, macOS and Windows are also supported.

* Go >= 1.21

## Installation

```bash
go get github.com/archerdb/archerdb-go
```

## Quick Start

```go
package main

import (
    "fmt"
    "time"

    archerdb "github.com/archerdb/archerdb-go"
    "github.com/archerdb/archerdb-go/pkg/types"
)

func main() {
    // Connect to ArcherDB cluster
    client, err := archerdb.NewGeoClient(0, []string{"127.0.0.1:3001"})
    if err != nil {
        panic(err)
    }
    defer client.Close()

    // Insert a geo event
    event := types.GeoEvent{
        EntityID:    types.Uint128{Lo: 0x12345678},
        LatNano:     37774900000, // 37.7749 degrees in nanodegrees
        LonNano:     -122419400000,
        Timestamp:   uint64(time.Now().UnixNano()),
        GroupID:     1,
    }

    errors := client.InsertEvents([]types.GeoEvent{event})
    if len(errors) == 0 {
        fmt.Println("Event inserted successfully!")
    }

    // Query events within 1km radius
    results, err := client.QueryRadius(archerdb.QueryRadiusFilter{
        CenterLatNano: 37774900000,
        CenterLonNano: -122419400000,
        RadiusMm:      1000000, // 1km in millimeters
        Limit:         100,
    })
    if err != nil {
        panic(err)
    }

    fmt.Printf("Found %d events within 1km\n", len(results.Events))
}
```

## API Reference

### Creating a Client

```go
import (
    archerdb "github.com/archerdb/archerdb-go"
)

// Single-node cluster
client, err := archerdb.NewGeoClient(0, []string{"127.0.0.1:3001"})

// Multi-node cluster
client, err := archerdb.NewGeoClient(0, []string{
    "127.0.0.1:3001",
    "127.0.0.1:3002",
    "127.0.0.1:3003",
})

// Always close when done
defer client.Close()
```

### GeoEvent Structure

```go
import "github.com/archerdb/archerdb-go/pkg/types"

event := types.GeoEvent{
    ID:            types.Uint128{},     // Composite key (auto-generated if zero)
    EntityID:      types.Uint128{},     // UUID of tracked entity
    CorrelationID: types.Uint128{},     // Trip/session correlation
    UserData:      types.Uint128{},     // Application metadata
    LatNano:       37774900000,         // Latitude in nanodegrees
    LonNano:       -122419400000,       // Longitude in nanodegrees
    GroupID:       1,                   // Fleet/region grouping
    Timestamp:     uint64(time.Now().UnixNano()),
    AltitudeMm:    0,                   // Altitude in millimeters
    SpeedMmps:     0,                   // Speed in mm/s
    HeadingMicro:  0,                   // Heading in microdegrees
    AccuracyMm:    0,                   // GPS accuracy in mm
    Status:        0,                   // Application status flags
    EventType:     0,                   // Event type code
    Reserved:      0,
}
```

### Insert Events

```go
events := []types.GeoEvent{event1, event2, event3}

errors := client.InsertEvents(events)
for _, err := range errors {
    fmt.Printf("Event %d failed: %v\n", err.Index, err.Result)
}
```

### Upsert Events

```go
errors := client.UpsertEvents(events)
```

### Query by Radius

```go
results, err := client.QueryRadius(archerdb.QueryRadiusFilter{
    CenterLatNano: 37774900000,    // Center latitude (nanodegrees)
    CenterLonNano: -122419400000,  // Center longitude (nanodegrees)
    RadiusMm:      5000000,        // 5km in millimeters
    Limit:         1000,
    TimestampMin:  0,              // Optional: filter by time range
    TimestampMax:  0,
    GroupID:       0,              // Optional: filter by group
})

for _, event := range results.Events {
    lat := float64(event.LatNano) / 1e9
    lon := float64(event.LonNano) / 1e9
    fmt.Printf("Entity at (%.6f, %.6f)\n", lat, lon)
}

// Pagination
if results.HasMore {
    nextResults, _ := client.QueryRadius(archerdb.QueryRadiusFilter{
        CenterLatNano: 37774900000,
        CenterLonNano: -122419400000,
        RadiusMm:      5000000,
        Limit:         1000,
        Cursor:        results.Cursor,
    })
}
```

### Query by Polygon

```go
vertices := []archerdb.LatLon{
    {LatNano: 37780000000, LonNano: -122420000000},
    {LatNano: 37780000000, LonNano: -122400000000},
    {LatNano: 37760000000, LonNano: -122400000000},
    {LatNano: 37760000000, LonNano: -122420000000},
}

results, err := client.QueryPolygon(archerdb.QueryPolygonFilter{
    Vertices:     vertices,
    Limit:        1000,
    TimestampMin: 0,
    TimestampMax: 0,
})
```

### Query Latest by Entity UUID

```go
event, err := client.GetLatestByUUID(types.Uint128{Lo: 0x12345678})
if err == nil && event != nil {
    fmt.Printf("Last seen at (%d, %d)\n", event.LatNano, event.LonNano)
}
```

### Query Latest Events

```go
results, err := client.QueryLatest(archerdb.QueryLatestFilter{
    Limit:        100,
    TimestampMin: 0,
    GroupID:      1,
})

for _, event := range results.Events {
    fmt.Printf("Entity %v: %d, %d\n", event.EntityID, event.LatNano, event.LonNano)
}
```

### Delete Entities

GDPR-compliant deletion of all events for specified entities.

```go
result, err := client.DeleteEntities([]types.Uint128{entityID1, entityID2})
fmt.Printf("Deleted %d entities\n", result.DeletedCount)
```

## Error Handling

```go
import "github.com/archerdb/archerdb-go/pkg/errors"

results, err := client.QueryRadius(filter)
if err != nil {
    switch e := err.(type) {
    case *errors.ConnectionError:
        fmt.Printf("Connection failed: %v\n", e)
    case *errors.ValidationError:
        fmt.Printf("Invalid input: %v\n", e)
    default:
        fmt.Printf("ArcherDB error: %v\n", e)
    }
}
```

## Performance Tips

1. **Batch operations**: Always batch inserts (up to 10,000 events per call).
2. **Reuse client**: Create one client and reuse across goroutines (thread-safe).
3. **Use pagination**: For large result sets, use cursor-based pagination.
4. **Filter early**: Use `GroupID` and time filters to reduce result size.

```go
// Efficient batching
const batchSize = 8000
for i := 0; i < len(events); i += batchSize {
    end := i + batchSize
    if end > len(events) {
        end = len(events)
    }
    errors := client.InsertEvents(events[i:end])
    // handle errors
}
```

## Thread Safety

The client is goroutine-safe. A single instance should be shared:

```go
var wg sync.WaitGroup
for i := 0; i < 10; i++ {
    wg.Add(1)
    go func() {
        defer wg.Done()
        client.InsertEvents(events)
    }()
}
wg.Wait()
```

## Links

* [ArcherDB Documentation](https://github.com/ArcherDB-io/archerdb)
