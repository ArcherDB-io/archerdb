# archerdb-c

The ArcherDB C client for high-performance geospatial data storage and queries.

ArcherDB is designed for applications that need to track millions of moving entities
(vehicles, devices, people) with sub-millisecond query latency.

## Prerequisites

- **Linux >= 5.6** (production), macOS (development)
- C compiler (gcc, clang) with C11 support
- POSIX threads (pthread) for synchronization in multi-threaded applications

> **Note**: The `arch_client.h` header is auto-generated from `arch_client_header.zig`.
> Do not modify the header directly.

## Installation

1. Copy `arch_client.h` to your project's include directory
2. Link against the appropriate static library for your platform:

### Linux (x86_64)

```bash
gcc -o myapp myapp.c -I/path/to/include -L/path/to/lib \
    -larch_client_x86_64-linux -lpthread
```

### Linux (aarch64)

```bash
gcc -o myapp myapp.c -I/path/to/include -L/path/to/lib \
    -larch_client_aarch64-linux -lpthread
```

### macOS (arm64)

```bash
clang -o myapp myapp.c -I/path/to/include -L/path/to/lib \
    -larch_client_aarch64-macos -lpthread
```

### macOS (x86_64)

```bash
clang -o myapp myapp.c -I/path/to/include -L/path/to/lib \
    -larch_client_x86_64-macos -lpthread
```

## Quick Start

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include "arch_client.h"

// Synchronization context for blocking calls
typedef struct {
    uint8_t reply[1024 * 1024];
    int size;
    bool completed;
    pthread_mutex_t lock;
    pthread_cond_t cv;
} completion_context_t;

// Completion callback - called when a request completes
void on_completion(
    uintptr_t context,
    arch_packet_t *packet,
    uint64_t timestamp,
    const uint8_t *data,
    uint32_t size
) {
    completion_context_t *ctx = (completion_context_t*)packet->user_data;

    pthread_mutex_lock(&ctx->lock);
    memcpy(ctx->reply, data, size);
    ctx->size = size;
    ctx->completed = true;
    pthread_cond_signal(&ctx->cv);
    pthread_mutex_unlock(&ctx->lock);
}

// Helper: Convert degrees to nanodegrees
static int64_t degrees_to_nano(double degrees) {
    return (int64_t)(degrees * 1e9);
}

int main(void) {
    // Initialize client
    arch_client_t client;
    uint8_t cluster_id[16] = {0};  // All zeros for default cluster
    const char *address = "127.0.0.1:3001";

    ARCH_INIT_STATUS init_status = arch_client_init(
        &client,
        cluster_id,
        address,
        strlen(address),
        (uintptr_t)NULL,
        &on_completion
    );

    if (init_status != ARCH_INIT_SUCCESS) {
        fprintf(stderr, "Failed to initialize client: %d\n", init_status);
        return 1;
    }

    // Initialize synchronization context
    completion_context_t ctx = {0};
    pthread_mutex_init(&ctx.lock, NULL);
    pthread_cond_init(&ctx.cv, NULL);

    // Create a geo event
    geo_event_t event = {0};
    event.id = 1;                                    // Unique event ID (must be non-zero)
    event.entity_id = 1001;                          // Entity being tracked
    event.lat_nano = degrees_to_nano(37.7749);       // San Francisco latitude
    event.lon_nano = degrees_to_nano(-122.4194);     // San Francisco longitude
    event.group_id = 1;                              // Logical tenant grouping
    event.altitude_mm = 10000;                       // 10 meters altitude
    event.velocity_mms = 5000;                       // 5 m/s speed
    event.accuracy_mm = 3000;                        // 3 meters accuracy
    event.heading_cdeg = 9000;                       // 90 degrees (East)
    // timestamp is set by server, leave as 0

    // Insert the event
    arch_packet_t packet = {0};
    packet.operation = ARCH_OPERATION_INSERT_EVENTS;
    packet.data = &event;
    packet.data_size = sizeof(geo_event_t);
    packet.user_data = &ctx;

    pthread_mutex_lock(&ctx.lock);
    ctx.completed = false;
    arch_client_submit(&client, &packet);
    while (!ctx.completed) {
        pthread_cond_wait(&ctx.cv, &ctx.lock);
    }
    pthread_mutex_unlock(&ctx.lock);

    if (packet.status != ARCH_PACKET_OK) {
        fprintf(stderr, "Insert failed: %d\n", packet.status);
    } else if (ctx.size > 0) {
        // Non-empty response means some events failed validation
        insert_geo_events_result_t *results = (insert_geo_events_result_t*)ctx.reply;
        fprintf(stderr, "Event validation error: index=%d, result=%d\n",
                results[0].index, results[0].result);
    } else {
        printf("Event inserted successfully!\n");
    }

    // Query by radius
    query_radius_filter_t filter = {0};
    filter.center_lat_nano = degrees_to_nano(37.7749);
    filter.center_lon_nano = degrees_to_nano(-122.4194);
    filter.radius_mm = 5000000;  // 5 km radius
    filter.limit = 100;
    filter.group_id = 1;

    packet.operation = ARCH_OPERATION_QUERY_RADIUS;
    packet.data = &filter;
    packet.data_size = sizeof(query_radius_filter_t);

    pthread_mutex_lock(&ctx.lock);
    ctx.completed = false;
    arch_client_submit(&client, &packet);
    while (!ctx.completed) {
        pthread_cond_wait(&ctx.cv, &ctx.lock);
    }
    pthread_mutex_unlock(&ctx.lock);

    if (packet.status == ARCH_PACKET_OK && ctx.size > 0) {
        query_response_t *response = (query_response_t*)ctx.reply;
        printf("Found %d events in radius\n", response->count);

        geo_event_t *events = (geo_event_t*)(ctx.reply + sizeof(query_response_t));
        for (uint32_t i = 0; i < response->count && i < 5; i++) {
            printf("  entity_id=%llu, lat=%.6f, lon=%.6f\n",
                   (unsigned long long)events[i].entity_id,
                   events[i].lat_nano / 1e9,
                   events[i].lon_nano / 1e9);
        }
    }

    // Cleanup
    pthread_cond_destroy(&ctx.cv);
    pthread_mutex_destroy(&ctx.lock);
    arch_client_deinit(&client);

    return 0;
}
```

## API Reference

### Client Lifecycle

```c
// Initialize a client connection
ARCH_INIT_STATUS arch_client_init(
    arch_client_t *client_out,           // Output: client handle
    const uint8_t cluster_id[16],        // 128-bit cluster ID (little-endian)
    const char *address_ptr,             // Comma-separated addresses
    uint32_t address_len,                // Length of address string
    uintptr_t completion_ctx,            // Context passed to callback
    void (*completion_callback)(...)     // Called on request completion
);

// Close client and release resources
ARCH_CLIENT_STATUS arch_client_deinit(arch_client_t *client);
```

### Request Submission

```c
// Submit a request packet
ARCH_CLIENT_STATUS arch_client_submit(
    arch_client_t *client,
    arch_packet_t *packet
);
```

### Completion Callback Signature

```c
void completion_callback(
    uintptr_t context,           // Context from arch_client_init
    arch_packet_t *packet,       // The completed packet
    uint64_t timestamp,          // Server timestamp
    const uint8_t *data,         // Response data (library-owned)
    uint32_t size                // Size of response data
);
```

### Operations

| Operation | Description | Request Data | Response Data |
|-----------|-------------|--------------|---------------|
| `ARCH_OPERATION_INSERT_EVENTS` | Insert geo events | `geo_event_t[]` | `insert_geo_events_result_t[]` (errors only) |
| `ARCH_OPERATION_UPSERT_EVENTS` | Insert or update geo events | `geo_event_t[]` | `insert_geo_events_result_t[]` (errors only) |
| `ARCH_OPERATION_DELETE_ENTITIES` | Delete entities | `arch_uint128_t[]` (entity IDs) | `delete_entities_result_t[]` |
| `ARCH_OPERATION_QUERY_UUID` | Query by entity ID | `query_uuid_filter_t` | `query_uuid_response_t` + `geo_event_t` |
| `ARCH_OPERATION_QUERY_UUID_BATCH` | Query multiple entity IDs | `query_uuid_batch_filter_t` + `arch_uint128_t[]` | `query_uuid_batch_result_t` + `geo_event_t[]` |
| `ARCH_OPERATION_QUERY_RADIUS` | Query by radius | `query_radius_filter_t` | `query_response_t` + `geo_event_t[]` |
| `ARCH_OPERATION_QUERY_POLYGON` | Query by polygon | `query_polygon_filter_t` + `polygon_vertex_t[]` | `query_response_t` + `geo_event_t[]` |
| `ARCH_OPERATION_QUERY_LATEST` | Query latest events | `query_latest_filter_t` | `query_response_t` + `geo_event_t[]` |

## Memory Management

### Ownership Rules

| Resource | Owner | When to Free |
|----------|-------|--------------|
| `arch_client_t` | Library | Call `arch_client_deinit()` |
| `arch_packet_t` | Caller | After completion callback |
| Request data (`geo_event_t[]`, filters) | Caller | After completion callback |
| Response data in callback | Library | Copy before callback returns |
| `completion_ctx` | Caller | After `arch_client_deinit()` |

### Important Notes

1. **Pinned Memory**: Both `arch_client_t` and `arch_packet_t` must remain at stable
   addresses (not moved in memory) for their entire lifetime.

2. **Request Data Lifetime**: Data passed in `packet.data` must remain valid until
   the completion callback is invoked.

3. **Response Data**: The `data` pointer in the completion callback is library-owned.
   Copy any data you need before returning from the callback.

4. **Example - Copying Response Data**:
   ```c
   void on_completion(..., const uint8_t *data, uint32_t size) {
       completion_context_t *ctx = (completion_context_t*)packet->user_data;

       // Copy response data before callback returns
       memcpy(ctx->reply, data, size);
       ctx->size = size;

       // Signal completion
       ctx->completed = true;
   }
   ```

## Thread Safety

The ArcherDB C client is **NOT thread-safe**.

### Single-Threaded Usage (Recommended)

Create one client per thread. This avoids synchronization overhead:

```c
// Thread 1
arch_client_t client1;
arch_client_init(&client1, ...);
// Use client1 exclusively in thread 1

// Thread 2
arch_client_t client2;
arch_client_init(&client2, ...);
// Use client2 exclusively in thread 2
```

### Multi-Threaded with Synchronization

If you must share a client across threads, use external synchronization:

```c
pthread_mutex_t client_lock = PTHREAD_MUTEX_INITIALIZER;
arch_client_t shared_client;

void submit_from_any_thread(arch_packet_t *packet) {
    pthread_mutex_lock(&client_lock);
    arch_client_submit(&shared_client, packet);
    pthread_mutex_unlock(&client_lock);
}
```

### Callback Threading

The completion callback may be invoked from a different thread than `arch_client_submit()`.
Use proper synchronization when updating shared state from callbacks.

## Error Handling

### Initialization Errors

```c
ARCH_INIT_STATUS status = arch_client_init(&client, ...);
switch (status) {
    case ARCH_INIT_SUCCESS:
        // Client ready
        break;
    case ARCH_INIT_ADDRESS_INVALID:
        fprintf(stderr, "Invalid address format\n");
        break;
    case ARCH_INIT_NETWORK_SUBSYSTEM:
        fprintf(stderr, "Network subsystem error\n");
        break;
    case ARCH_INIT_OUT_OF_MEMORY:
        fprintf(stderr, "Out of memory\n");
        break;
    default:
        fprintf(stderr, "Init failed: %d\n", status);
}
```

### Packet Status Errors

```c
if (packet.status != ARCH_PACKET_OK) {
    switch (packet.status) {
        case ARCH_PACKET_TOO_MUCH_DATA:
            fprintf(stderr, "Request data too large\n");
            break;
        case ARCH_PACKET_CLIENT_SHUTDOWN:
            fprintf(stderr, "Client was shut down\n");
            break;
        case ARCH_PACKET_INVALID_OPERATION:
            fprintf(stderr, "Unknown operation\n");
            break;
        default:
            fprintf(stderr, "Packet error: %d\n", packet.status);
    }
}
```

### Insert Validation Errors

```c
// Non-empty response on insert means validation errors
if (ctx.size > 0) {
    insert_geo_events_result_t *results = (insert_geo_events_result_t*)ctx.reply;
    int count = ctx.size / sizeof(insert_geo_events_result_t);

    for (int i = 0; i < count; i++) {
        printf("Event %d failed: ", results[i].index);
        switch (results[i].result) {
            case INSERT_GEO_EVENT_ID_MUST_NOT_BE_ZERO:
                printf("Event ID cannot be zero\n");
                break;
            case INSERT_GEO_EVENT_ENTITY_ID_MUST_NOT_BE_ZERO:
                printf("Entity ID cannot be zero\n");
                break;
            case INSERT_GEO_EVENT_LAT_OUT_OF_RANGE:
                printf("Latitude out of range\n");
                break;
            case INSERT_GEO_EVENT_LON_OUT_OF_RANGE:
                printf("Longitude out of range\n");
                break;
            // ... handle other error codes
            default:
                printf("Error code %d\n", results[i].result);
        }
    }
}
```

### Error Code Reference

See [error-codes.md](../../../docs/error-codes.md) for complete error code documentation.

**Error Code Ranges:**

| Range | Category | Description |
|-------|----------|-------------|
| 0 | Success | Operation completed successfully |
| 1-99 | Protocol | Message format, checksums, versioning |
| 100-199 | Validation | Invalid inputs, constraint violations |
| 200-299 | State | Entity/cluster state errors |
| 300-399 | Resource | Limits exceeded, capacity constraints |
| 400-499 | Security | Authentication, authorization |
| 500-599 | Internal | Server bugs (contact support) |

## Sample Projects

See the [samples/](samples/) directory for complete working examples:

- `main.c` - Comprehensive example with all operations
- Insert events (single and batch)
- Query by radius
- Query by polygon
- Query by UUID
- Delete entities
- Error handling patterns
- Performance benchmarking

### Building Samples

```bash
# From the archerdb root directory
./zig/zig build clients:c:sample
```

## Coordinate System

ArcherDB uses integer coordinates for precision:

| Field | Unit | Example | Notes |
|-------|------|---------|-------|
| `lat_nano` | nanodegrees (1e-9 deg) | `37774900000` = 37.7749 | Range: [-90e9, 90e9] |
| `lon_nano` | nanodegrees (1e-9 deg) | `-122419400000` = -122.4194 | Range: [-180e9, 180e9] |
| `altitude_mm` | millimeters | `10000` = 10m | Altitude above sea level |
| `velocity_mms` | mm/second | `5000` = 5 m/s | Speed of movement |
| `accuracy_mm` | millimeters | `3000` = 3m | Location accuracy |
| `heading_cdeg` | centidegrees | `9000` = 90 | 0=North, 9000=East, 18000=South |

### Conversion Helpers

```c
// Degrees to nanodegrees
static int64_t degrees_to_nano(double degrees) {
    return (int64_t)(degrees * 1e9);
}

// Nanodegrees to degrees
static double nano_to_degrees(int64_t nano) {
    return nano / 1e9;
}

// Meters to millimeters
static int32_t meters_to_mm(double meters) {
    return (int32_t)(meters * 1000);
}

// Degrees heading to centidegrees (0-359.99)
static uint16_t heading_to_cdeg(double degrees) {
    return (uint16_t)(degrees * 100);
}
```

## Building from Source

The C client library is built as part of the ArcherDB build:

```bash
# Build C client library
./zig/zig build clients:c

# Build C client sample
./zig/zig build clients:c:sample

# Output locations:
# - Library: zig-out/lib/libarch_client_*.a
# - Header: src/clients/c/arch_client.h
```
