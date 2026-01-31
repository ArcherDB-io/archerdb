# SDK Documentation

ArcherDB provides official SDKs for five languages, each designed to follow that language's idioms and best practices while providing consistent functionality across all platforms.

## Quick Start

| Language | Install | Documentation |
|----------|---------|---------------|
| Python | `pip install archerdb` | [Full Guide](../../src/clients/python/README.md) |
| Node.js | `npm install archerdb-node` | [Full Guide](../../src/clients/node/README.md) |
| Go | `go get github.com/archerdb/archerdb-go` | [Full Guide](../../src/clients/go/README.md) |
| Java | Maven/Gradle dependency | [Full Guide](../../src/clients/java/README.md) |
| C | Build from source | [Full Guide](../../src/clients/c/README.md) |

## Choosing an SDK

### Python

**Best for:** Data science, scripting, prototyping, analytics pipelines

- Sync and async APIs (asyncio support)
- Connection pooling and automatic retry
- Type hints for IDE support
- Ideal for Jupyter notebooks and data exploration

```python
from archerdb import GeoClientSync, GeoClientConfig

config = GeoClientConfig(cluster_id=0, addresses=['127.0.0.1:3001'])
with GeoClientSync(config) as client:
    results = client.query_radius(latitude=37.7749, longitude=-122.4194, radius_m=1000)
```

### Node.js

**Best for:** Web applications, real-time systems, serverless functions

- Fully async/await API (no sync blocking calls)
- Connection pooling with automatic retry
- Full TypeScript type definitions
- Native BigInt support for 128-bit IDs

```typescript
import { createGeoClient } from 'archerdb-node'

const client = createGeoClient({
  cluster_id: 0n,
  addresses: ['127.0.0.1:3001'],
})
const results = await client.queryRadius({ latitude: 37.7749, longitude: -122.4194, radius_m: 1000 })
```

### Go

**Best for:** Microservices, high-performance backends, infrastructure

- Idiomatic Go with goroutine-safe client
- Context support for cancellation and timeouts
- Strong typing with Uint128 for IDs
- Minimal dependencies

```go
client, _ := archerdb.NewGeoClient(archerdb.GeoClientConfig{
    ClusterID: types.ToUint128(0),
    Addresses: []string{"127.0.0.1:3001"},
})
filter, _ := types.NewRadiusQuery(37.7749, -122.4194, 1000, 100)
results, _ := client.QueryRadius(filter)
```

### Java

**Best for:** Enterprise applications, Android, Spring ecosystem

- Thread-safe client with connection pooling
- Sync and async APIs (CompletableFuture)
- Builder pattern for event construction
- AutoCloseable for resource management

```java
try (GeoClient client = GeoClient.create(0L, "127.0.0.1:3001")) {
    QueryResult result = client.queryRadius(
        QueryRadiusFilter.create(37.7749, -122.4194, 1000, 100)
    );
}
```

### C

**Best for:** Embedded systems, FFI bindings, performance-critical paths

- Direct access to ArcherDB protocol
- Callback-based async API
- No runtime dependencies beyond libc
- Foundation for other language bindings

```c
arch_client_t client;
arch_client_init(&client, cluster_id, address, strlen(address), ctx, &on_completion);
// ... submit operations
arch_client_deinit(&client);
```

## Feature Matrix

| Feature | Python | Node.js | Go | Java | C |
|---------|--------|---------|-----|------|---|
| Sync API | Yes | No | Yes | Yes | Yes |
| Async API | Yes | Yes | Yes | Yes | Yes* |
| Connection Pool | Yes | Yes | Yes | Yes | No |
| Auto-retry | Yes | Yes | Yes | Yes | No |
| TypeScript Types | - | Yes | - | - | - |
| Thread-safe | Yes | Yes** | Yes | Yes | No |

\* C async API is callback-based, not coroutine-based
\*\* Node.js is single-threaded; client is safe for concurrent async operations

## Common Patterns

### Connection Configuration

All SDKs accept similar configuration:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cluster_id` | Cluster identifier (128-bit) | Required |
| `addresses` | List of replica addresses | Required |
| `connect_timeout` | Connection timeout | 5s |
| `request_timeout` | Per-request timeout | 30s |

Address formats supported:
- `3001` - Interpreted as `127.0.0.1:3001`
- `127.0.0.1:3001` - Full address
- `127.0.0.1` - Uses default port 3001

### Error Handling

All SDKs provide:
- **Typed exceptions/errors** with error codes
- **Retryable flag** indicating if the error is transient
- **Error categories**: validation, connection, cluster, operation

```python
# Python example
try:
    client.insert_events(events)
except ArcherDBError as e:
    if e.retryable:
        # Transient error - safe to retry with backoff
        pass
    else:
        # Permanent error - fix request before retrying
        pass
```

See [SDK Retry Semantics](../sdk-retry-semantics.md) for detailed retry behavior.

### Batch Operations

For high throughput, batch multiple events:

| SDK | Max Batch Size | Method |
|-----|----------------|--------|
| Python | 10,000 | `client.create_batch()` |
| Node.js | 10,000 | `client.createBatch()` |
| Go | 10,000 | `client.CreateBatch()` |
| Java | 10,000 | `client.createBatch()` |
| C | 10,000 | Direct in `packet.data` |

**Recommendation:** Use batch sizes of 1,000-8,000 for optimal throughput.

### ID Generation

All SDKs provide ID generation utilities:

```python
# Python
from archerdb import id
entity_id = id()  # ULID-based, sortable, unique

# Node.js
import { generateId } from 'archerdb-node'
const entityId = generateId()

# Go
entityID := types.ID()

# Java
UInt128 entityId = UInt128.random()
```

IDs are:
- 128-bit ULIDs (Universally Unique Lexicographically Sortable Identifier)
- Time-sortable (IDs generated later are greater)
- Collision-resistant (safe for distributed generation)

### Coordinate Units

ArcherDB uses integer coordinates internally for precision:

| User-facing | Internal | Conversion |
|-------------|----------|------------|
| Degrees (float) | Nanodegrees (int64) | 37.7749 deg = 37,774,900,000 nano |
| Meters (float) | Millimeters (int32) | 1000 m = 1,000,000 mm |
| Degrees heading | Centidegrees | 90 deg = 9000 cdeg |

SDKs handle conversion automatically when using builder methods. Raw struct access uses internal units.

## SDK Installation Details

### Python

```bash
pip install archerdb

# Or with version pinning
pip install archerdb==0.1.0
```

Requires Python 3.7+.

### Node.js

```bash
npm install --save-exact archerdb-node

# Or with yarn
yarn add archerdb-node
```

Requires Node.js 18+.

### Go

```bash
go get github.com/archerdb/archerdb-go
```

Requires Go 1.21+.

### Java

Maven:
```xml
<dependency>
    <groupId>com.archerdb</groupId>
    <artifactId>archerdb-java</artifactId>
    <version>0.1.0</version>
</dependency>
```

Gradle:
```groovy
implementation 'com.archerdb:archerdb-java:0.1.0'
```

Requires Java 11+.

### C

Build from ArcherDB source:
```bash
./zig/zig build clients:c

# Output:
# - Library: zig-out/lib/libarch_client_*.a
# - Header: src/clients/c/arch_client.h
```

Link against the platform-specific library.

## Related Documentation

- [API Reference](../api-reference.md) - Complete API documentation
- [Error Codes](../error-codes.md) - Error code reference
- [SDK Retry Semantics](../sdk-retry-semantics.md) - Retry behavior details
- [Getting Started](../getting-started.md) - End-to-end setup guide
