# ArcherDB Zig SDK

Official Zig client library for ArcherDB, a high-performance geospatial database optimized for real-time location tracking.

## Features

- **Native Zig Implementation**: Pure Zig using `std.http.Client`, no CGO or FFI
- **All 14 Operations**: Complete coverage of ArcherDB API
- **Idiomatic Zig Patterns**: Error unions, explicit allocators, struct methods
- **Type Safe**: Compile-time type checking with Zig's strong type system
- **Zero Allocations in Hot Paths**: Explicit allocator passing for memory control

## Quick Start

```zig
const std = @import("std");
const archerdb = @import("archerdb-zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = try archerdb.Client.init(allocator, "http://127.0.0.1:3001");
    defer client.deinit();

    // Insert event
    const events = [_]archerdb.GeoEvent{
        .{
            .entity_id = 12345,
            .lat_nano = archerdb.degreesToNano(37.7749),
            .lon_nano = archerdb.degreesToNano(-122.4194),
            .group_id = 1,
        },
    };

    var results = try client.insertEvents(allocator, &events);
    defer results.deinit();

    for (results.items) |result| {
        if (result.code != .ok) {
            std.debug.print("Event {d} failed: {}\n", .{ result.index, result.code });
        }
    }
}
```

## Installation

### Using Zig Package Manager (build.zig.zon)

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .archerdb = .{
            .path = "path/to/archerdb/src/clients/zig",
        },
    },
}
```

### Manual Integration

Copy the `src/clients/zig/` directory to your project and import:

```zig
const archerdb = @import("path/to/archerdb/client.zig");
```

## API Reference

### Client Lifecycle

```zig
// Initialize client
var client = try archerdb.Client.init(allocator, "http://127.0.0.1:3001");
defer client.deinit();
```

### All 14 Operations

#### 1. Insert Events

```zig
const events = [_]archerdb.GeoEvent{
    .{
        .entity_id = 12345,
        .lat_nano = archerdb.degreesToNano(37.7749),
        .lon_nano = archerdb.degreesToNano(-122.4194),
        .group_id = 1,
        .ttl_seconds = 86400, // 24 hours
    },
};

var results = try client.insertEvents(allocator, &events);
defer results.deinit();
```

#### 2. Upsert Events

```zig
// Insert or update (idempotent, recommended)
var results = try client.upsertEvents(allocator, &events);
defer results.deinit();
```

#### 3. Delete Entities

```zig
const entity_ids = [_]u128{ 12345, 12346 };
const result = try client.deleteEntities(allocator, &entity_ids);
std.debug.print("Deleted: {d}, Not found: {d}\n", .{ result.deleted_count, result.not_found_count });
```

#### 4. Get Latest by UUID

```zig
if (try client.getLatestByUUID(allocator, entity_id)) |event| {
    std.debug.print("Last seen at: {d}, {d}\n", .{
        archerdb.nanoToDegrees(event.lat_nano),
        archerdb.nanoToDegrees(event.lon_nano),
    });
} else {
    std.debug.print("Entity not found\n", .{});
}
```

#### 5. Query UUID Batch

```zig
const entity_ids = [_]u128{ 12345, 12346, 12347 };
var result = try client.queryUUIDBatch(allocator, &entity_ids);
defer result.deinit();

std.debug.print("Found {d} of {d} entities\n", .{ result.found_count, entity_ids.len });
```

#### 6. Query Radius

```zig
const filter = archerdb.QueryRadiusFilter{
    .center_lat_nano = archerdb.degreesToNano(37.7749),
    .center_lon_nano = archerdb.degreesToNano(-122.4194),
    .radius_mm = 1000 * 1000, // 1km in millimeters
    .limit = 100,
    .group_id = 1, // Optional: filter by group
};

var result = try client.queryRadius(allocator, filter);
defer result.deinit();

for (result.events.items) |event| {
    std.debug.print("Entity {d} at ({d}, {d})\n", .{
        event.entity_id,
        archerdb.nanoToDegrees(event.lat_nano),
        archerdb.nanoToDegrees(event.lon_nano),
    });
}

if (result.has_more) {
    // Use result.cursor for next page
}
```

#### 7. Query Polygon

```zig
const vertices = [_]archerdb.Vertex{
    .{ .lat_nano = archerdb.degreesToNano(37.79), .lon_nano = archerdb.degreesToNano(-122.42) },
    .{ .lat_nano = archerdb.degreesToNano(37.79), .lon_nano = archerdb.degreesToNano(-122.39) },
    .{ .lat_nano = archerdb.degreesToNano(37.76), .lon_nano = archerdb.degreesToNano(-122.39) },
    .{ .lat_nano = archerdb.degreesToNano(37.76), .lon_nano = archerdb.degreesToNano(-122.42) },
};

const filter = archerdb.QueryPolygonFilter{
    .vertices = &vertices,
    .limit = 1000,
};

var result = try client.queryPolygon(allocator, filter);
defer result.deinit();
```

#### 8. Query Latest

```zig
const filter = archerdb.QueryLatestFilter{
    .limit = 100,
    .group_id = 1, // Optional
};

var result = try client.queryLatest(allocator, filter);
defer result.deinit();
```

#### 9. Ping

```zig
const pong = try client.ping();
if (pong) {
    std.debug.print("Server is healthy\n", .{});
}
```

#### 10. Get Status

```zig
const status = try client.getStatus(allocator);
std.debug.print("Entity count: {d}, RAM: {d} bytes\n", .{
    status.entity_count,
    status.ram_bytes,
});
```

#### 11. Get Topology

```zig
var topology = try client.getTopology(allocator);
defer topology.deinit(allocator);

std.debug.print("Cluster has {d} shards\n", .{ topology.num_shards });
```

#### 12. Set TTL

```zig
// Set entity to expire in 1 hour
const result = try client.setTTL(allocator, entity_id, 3600);
if (result.success) {
    std.debug.print("TTL set, expires at: {d}\n", .{ result.expiry_ns });
}
```

#### 13. Extend TTL

```zig
// Extend TTL by 30 minutes
const result = try client.extendTTL(allocator, entity_id, 1800);
```

#### 14. Clear TTL

```zig
// Make entity permanent (never expires)
const result = try client.clearTTL(allocator, entity_id);
```

## Error Handling

The SDK uses Zig error unions for all fallible operations:

```zig
const result = client.queryRadius(allocator, filter) catch |err| switch (err) {
    error.ConnectionFailed => {
        std.debug.print("Connection failed, retrying...\n", .{});
        // Retry logic
        return err;
    },
    error.InvalidCoordinates => {
        std.debug.print("Invalid filter coordinates\n", .{});
        return err;
    },
    error.OperationTimeout => {
        std.debug.print("Query timed out\n", .{});
        return err;
    },
    else => |e| return e,
};
```

### Error Categories

```zig
const archerdb = @import("archerdb-zig");

if (archerdb.isRetryable(err)) {
    // Safe to retry: ConnectionFailed, Timeout, ClusterUnavailable
}

if (archerdb.isNetworkError(err)) {
    // Network-related: ConnectionFailed, Timeout, HttpError
}

if (archerdb.isValidationError(err)) {
    // Fix input: InvalidCoordinates, BatchTooLarge, InvalidEntityId
}
```

### All Error Types

| Error | Retryable | Description |
|-------|-----------|-------------|
| `ConnectionFailed` | Yes | Cannot connect to server |
| `ConnectionTimeout` | Yes | Connection attempt timed out |
| `ClusterUnavailable` | Yes | Cluster not accepting requests |
| `OperationTimeout` | Yes | Operation timed out |
| `InvalidCoordinates` | No | Coordinates out of valid range |
| `BatchTooLarge` | No | Batch exceeds 10,000 events |
| `InvalidEntityId` | No | Entity ID is zero |
| `EntityExpired` | No | Entity TTL has expired |
| `QueryResultTooLarge` | No | Limit exceeds 81,000 |
| `ClientClosed` | No | Client has been closed |
| `InvalidResponse` | No | Server returned invalid response |
| `JsonParseError` | No | Failed to parse JSON |

## Memory Management

The SDK uses Zig's explicit allocator pattern. All operations that return heap-allocated data require you to pass an allocator:

```zig
// Allocator passed to each operation
var results = try client.insertEvents(allocator, &events);

// Caller is responsible for cleanup
defer results.deinit();
```

### Ownership Rules

1. **Results**: Caller owns returned ArrayList/QueryResult and must call `deinit()`
2. **Events**: Caller owns input event arrays, SDK does not copy them
3. **Filters**: Caller owns filter structs, SDK does not copy vertices

### Memory-Safe Patterns

```zig
// Use defer immediately after allocation
var result = try client.queryRadius(allocator, filter);
defer result.deinit();

// errdefer for cleanup on error paths
var events = std.ArrayList(archerdb.GeoEvent).init(allocator);
errdefer events.deinit();

// ... populate events ...

var results = try client.insertEvents(allocator, events.items);
defer results.deinit();
```

## Coordinate Helpers

```zig
// Degrees to nanodegrees
const lat_nano = archerdb.degreesToNano(37.7749);  // 37774900000

// Nanodegrees to degrees
const lat_deg = archerdb.nanoToDegrees(37774900000);  // 37.7749

// Meters to millimeters
const alt_mm = archerdb.metersToMm(100.5);  // 100500

// Millimeters to meters
const alt_m = archerdb.mmToMeters(100500);  // 100.5

// Meters/second to millimeters/second
const vel_mms = archerdb.mpsToMms(15.0);  // 15000

// Heading degrees to centidegrees
const heading_cdeg = archerdb.degreesToCdeg(90.0);  // 9000
```

## Testing

### Unit Tests (no server required)

```bash
cd src/clients/zig
zig build test:unit
```

### Integration Tests (requires running server)

Start the server using Phase 11 cluster harness:

```bash
# Start server
python -m test_infrastructure.harness.cluster start

# Run integration tests
cd src/clients/zig
zig build test:integration

# Stop server
python -m test_infrastructure.harness.cluster stop
```

Or with a custom server URL:

```bash
ARCHERDB_URL=http://localhost:3002 zig build test:integration
```

### All Tests

```bash
zig build test
```

## Type Reference

### GeoEvent

```zig
pub const GeoEvent = struct {
    id: u128 = 0,              // Auto-generated composite key
    entity_id: u128,           // Required: unique entity identifier
    correlation_id: u128 = 0,  // Optional: trip/session ID
    user_data: u128 = 0,       // Optional: application metadata
    lat_nano: i64,             // Required: latitude in nanodegrees
    lon_nano: i64,             // Required: longitude in nanodegrees
    group_id: u64 = 0,         // Optional: fleet/tenant ID
    timestamp: u64 = 0,        // Auto-generated
    altitude_mm: i32 = 0,      // Optional: altitude in millimeters
    velocity_mms: u32 = 0,     // Optional: speed in mm/s
    ttl_seconds: u32 = 0,      // Optional: TTL (0 = never expire)
    accuracy_mm: u32 = 0,      // Optional: GPS accuracy
    heading_cdeg: u16 = 0,     // Optional: heading in centidegrees
    flags: u16 = 0,            // Optional: application flags
};
```

### Query Filters

```zig
pub const QueryRadiusFilter = struct {
    center_lat_nano: i64,
    center_lon_nano: i64,
    radius_mm: u64,
    limit: u32 = 1000,
    timestamp_min: u64 = 0,
    timestamp_max: u64 = 0,
    group_id: u64 = 0,
    cursor: u64 = 0,
};

pub const QueryPolygonFilter = struct {
    vertices: []const Vertex,
    holes: []const Hole = &[_]Hole{},
    limit: u32 = 1000,
    timestamp_min: u64 = 0,
    timestamp_max: u64 = 0,
    group_id: u64 = 0,
    cursor: u64 = 0,
};

pub const QueryLatestFilter = struct {
    limit: u32 = 1000,
    group_id: u64 = 0,
    cursor: u64 = 0,
};
```

## Limits

| Limit | Value |
|-------|-------|
| Max batch size | 10,000 events |
| Max query limit | 81,000 results |
| Max polygon vertices | 10,000 |
| Max polygon holes | 100 |
| Latitude range | -90 to +90 degrees |
| Longitude range | -180 to +180 degrees |

## Related Documentation

- [ArcherDB API Reference](../../../docs/api-reference.md)
- [Error Codes](../../../docs/error-codes.md)
- [Getting Started](../../../docs/getting-started.md)
