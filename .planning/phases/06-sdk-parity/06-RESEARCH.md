# Phase 6: SDK Parity - Research

**Researched:** 2026-01-23
**Domain:** Multi-language SDK development (C, Go, Java, Node.js, Python)
**Confidence:** HIGH

## Summary

This research investigates how to achieve feature and quality parity across all five ArcherDB SDKs. The codebase already has substantial SDK implementations in place:

- **Python**: Most complete - full sync/async clients, comprehensive error handling, retry logic, topology support, batch operations, TTL operations
- **Go**: Nearly complete - full GeoClient with CGO bindings, retry logic, topology support, batch operations, TTL operations
- **Java**: Interface-complete - GeoClient interface with all operations defined, exception hierarchy, but needs async (CompletableFuture) support
- **Node.js**: Good foundation - binding infrastructure, error types, topology support, needs documentation completion
- **C**: Lowest-level - header file with all types defined, sample code exists, needs documentation and higher-level wrappers

The primary work involves: (1) filling documentation gaps across all SDKs, (2) adding CompletableFuture async support to Java, (3) completing test coverage, (4) creating cross-SDK test fixtures, and (5) ensuring error codes are consistently mapped.

**Primary recommendation:** Use Python SDK as the reference implementation for API surface, documentation patterns, and test scenarios. Systematically port each feature to other SDKs with language-idiomatic adaptations.

## Standard Stack

The established libraries/tools for this domain:

### Core (Per Language)

| Language | SDK Pattern | Async Mechanism | Doc Generator | Test Framework |
|----------|-------------|-----------------|---------------|----------------|
| C | Header + static library | N/A (sync only) | Doxygen | Custom + Zig tests |
| Go | CGO binding | Context for cancellation | godoc | go test |
| Java | JNI/native + pure Java | CompletableFuture | Javadoc | JUnit 5 |
| Node.js | N-API binding | Promise/async-await | TSDoc | Jest/Vitest |
| Python | ctypes/cffi binding | asyncio | Sphinx (Google style) | pytest |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| JUnit 5 | 5.10+ | Java testing | All Java tests |
| pytest | 8.0+ | Python testing | All Python tests |
| Jest | 29.x | Node.js testing | Node.js unit tests |
| Vitest | 1.x | Node.js testing | Alternative to Jest |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Doxygen (C) | Manual docs | Doxygen generates from inline comments |
| CompletableFuture | Reactor/RxJava | CompletableFuture is standard Java, no extra dependency |
| asyncio | Trio/AnyIO | asyncio is standard library, no extra dependency |

**Installation:** (existing in codebase - no new dependencies needed)

## Architecture Patterns

### Recommended Project Structure

All SDKs follow this structure pattern:

```
src/clients/{language}/
  src/                    # Source code
    {language}_client.*   # Main client implementation
    types.*               # Data types and enums
    errors.*              # Error types/exceptions
    topology.*            # Topology cache/routing
  tests/                  # Test files
  samples/                # Sample code
  README.md               # Quick start guide
```

### Pattern 1: Unified Error Code Mapping

**What:** All SDKs map the same numeric error codes to language-idiomatic error types
**When to use:** Every SDK operation that can fail

**Error Code Ranges (from docs/error-codes.md):**
- 0: Success
- 1-99: Protocol errors
- 100-199: Validation errors
- 200-299: State errors (including 213-218 multi-region, 220-224 sharding)
- 300-399: Resource errors
- 400-499: Security errors (including 410-414 encryption)
- 500-599: Internal errors

**Example (Python - reference implementation):**
```python
# From src/clients/python/src/archerdb/client.py
class ArcherDBError(Exception):
    """Base class for ArcherDB errors."""
    code: int = 0
    retryable: bool = False

class ConnectionFailed(ArcherDBError):
    code = 1001
    retryable = True

class InvalidCoordinates(ArcherDBError):
    code = 3001
    retryable = False
```

**Example (Go - idiomatic Go errors):**
```go
// From src/clients/go/geo_client.go
type GeoError interface {
    error
    Code() int
    Retryable() bool
}

type InvalidCoordinatesError struct{ Msg string }
func (e InvalidCoordinatesError) Error() string   { return e.Msg }
func (e InvalidCoordinatesError) Code() int       { return 3001 }
func (e InvalidCoordinatesError) Retryable() bool { return false }
```

**Example (Java - exception hierarchy):**
```java
// From src/clients/java/.../ArcherDBException.java
public class ArcherDBException extends RuntimeException {
    private final int errorCode;
    private final boolean retryable;
    public int getErrorCode() { return errorCode; }
    public boolean isRetryable() { return retryable; }
}
```

### Pattern 2: Language-Idiomatic Async Support

**What:** Each SDK provides async support using the language's standard mechanism
**When to use:** All I/O operations

| Language | Async Pattern | Example |
|----------|---------------|---------|
| C | N/A (callback-based, user wraps) | `arch_client_submit(client, packet)` |
| Go | Context for cancellation | `ctx, cancel := context.WithTimeout(ctx, 5*time.Second)` |
| Java | CompletableFuture | `CompletableFuture<QueryResult> future = client.queryRadiusAsync(filter)` |
| Node.js | Promise/async-await | `const result = await client.queryRadius(filter)` |
| Python | asyncio | `result = await client.query_radius(...)` |

**Example (Python async):**
```python
# From src/clients/python/src/archerdb/client.py
class GeoClientAsync:
    async def query_radius(self, latitude, longitude, radius_m, **kwargs) -> QueryResult:
        filter = create_radius_query(latitude, longitude, radius_m, **kwargs)
        events = await self._submit_query(GeoOperation.QUERY_RADIUS, filter)
        return QueryResult(events=events, has_more=len(events) == filter.limit)
```

### Pattern 3: Retry with Exponential Backoff

**What:** All SDKs implement consistent retry logic per docs/sdk-retry-semantics.md
**When to use:** All network operations

**Configuration (same across all SDKs):**
```
enabled: true
max_retries: 5
base_backoff_ms: 100
max_backoff_ms: 1600
total_timeout_ms: 30000
jitter: true
```

**Backoff Schedule:**
| Attempt | Base Delay | With Jitter (typical) |
|---------|------------|----------------------|
| 1 | 0ms | 0ms (immediate) |
| 2 | 100ms | 100-150ms |
| 3 | 200ms | 200-300ms |
| 4 | 400ms | 400-600ms |
| 5 | 800ms | 800-1200ms |
| 6 | 1600ms | 1600-2400ms |

### Pattern 4: Batch Builder Pattern

**What:** All SDKs use batch builders for bulk operations
**When to use:** Insert, upsert, delete operations

**Example (consistent across SDKs):**
```python
# Python
batch = client.create_batch()
batch.add(event)
batch.commit()

# Go
batch := client.CreateBatch()
batch.Add(event)
batch.Commit()

# Java
GeoEventBatch batch = client.createBatch();
batch.add(event);
batch.commit();
```

### Anti-Patterns to Avoid

- **Mixed sync/async in same client:** Don't provide both sync and async methods on same client class (Python does this correctly with separate GeoClientSync and GeoClientAsync)
- **Uncategorized errors:** All errors must have a code, message, and retryable flag
- **Inconsistent operation names:** Use same operation names across SDKs (query_radius, queryRadius, QueryRadius - same operation)
- **Missing context in errors:** Always include entity_id, request_id, etc. when available

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Retry logic | Custom retry loops | Existing RetryConfig pattern | Already implemented consistently in all SDKs |
| Error codes | Custom error numbers | Unified error code table | Must match server-side error codes |
| Topology discovery | Manual shard mapping | TopologyCache + ShardRouter | Already implemented with proper caching |
| ID generation | Random UUID | id() function | ULIDs are monotonic and sortable |
| Coordinate validation | Ad-hoc range checks | validateGeoEvent pattern | Consistent validation across SDKs |

**Key insight:** The Python and Go SDKs already implement these patterns correctly. Copy the patterns, adapt to language idioms.

## Common Pitfalls

### Pitfall 1: Error Code Mismatch

**What goes wrong:** SDK returns different error code than server sends
**Why it happens:** Manual error code mapping without reference to server source
**How to avoid:** Use src/error_codes.zig as source of truth for all error codes
**Warning signs:** Tests passing with wrong error codes, inconsistent error handling across SDKs

### Pitfall 2: Async/Sync Confusion

**What goes wrong:** Blocking calls in async context, async calls without awaiting
**Why it happens:** Mixing patterns, not understanding language's async model
**How to avoid:**
- Python: Separate GeoClientSync and GeoClientAsync classes
- Go: Use Context for cancellation, not async/await
- Java: Use CompletableFuture consistently
- Node.js: All public APIs return Promise
**Warning signs:** Deadlocks, unhandled promise rejections, blocked event loops

### Pitfall 3: Missing Documentation on Shared Patterns

**What goes wrong:** Each SDK documents operations differently, users confused
**Why it happens:** Each SDK developed independently
**How to avoid:** Use shared doc templates, cross-reference between SDKs
**Warning signs:** Stack Overflow questions showing confusion, support tickets

### Pitfall 4: Incomplete Test Coverage

**What goes wrong:** Operations work in one SDK but fail in another
**Why it happens:** Tests written for one SDK, not ported
**How to avoid:** Shared golden test data (JSON fixtures), cross-SDK test matrix
**Warning signs:** Bug reports only for specific SDKs

### Pitfall 5: Retry Exhaustion Without Metrics

**What goes wrong:** Silent failures after retries, hard to debug production issues
**Why it happens:** Retry logic doesn't emit observability data
**How to avoid:** All SDKs emit retry_count, retry_exhausted metrics
**Warning signs:** Production issues without retry visibility

## Code Examples

Verified patterns from existing implementations:

### Creating a Client (All Languages)

**Python:**
```python
# From src/clients/python/src/archerdb/client.py
config = GeoClientConfig(
    cluster_id=0,
    addresses=["127.0.0.1:3001"],
    retry=RetryConfig(max_retries=5),
)
with GeoClientSync(config) as client:
    # Use client
```

**Go:**
```go
// From src/clients/go/geo_client.go
config := GeoClientConfig{
    ClusterID: types.ToUint128(0),
    Addresses: []string{"127.0.0.1:3001"},
    Retry:     &RetryConfig{MaxRetries: 5},
}
client, err := NewGeoClient(config)
defer client.Close()
```

**Java:**
```java
// From src/clients/java/.../GeoClient.java
try (GeoClient client = GeoClient.create(0L, "127.0.0.1:3001")) {
    // Use client
}
```

**Node.js:**
```typescript
// From src/clients/node/src/geo_client.ts
const client = new GeoClient({
    clusterId: 0n,
    addresses: ['127.0.0.1:3001'],
});
```

**C:**
```c
// From src/clients/c/samples/main.c
arch_client_t client;
arch_client_init(&client, cluster_id, "127.0.0.1:3001", strlen(address),
                 (uintptr_t)NULL, &on_completion);
// Use client
arch_client_deinit(&client);
```

### Query Radius (All Languages)

**Python:**
```python
result = client.query_radius(
    latitude=37.7749,
    longitude=-122.4194,
    radius_m=1000,
    limit=100,
)
for event in result.events:
    print(f"Entity at ({event.latitude}, {event.longitude})")
```

**Go:**
```go
filter := types.QueryRadiusFilter{
    CenterLatNano: 37774900000,
    CenterLonNano: -122419400000,
    RadiusMM:      1000000,
    Limit:         100,
}
result, err := client.QueryRadius(filter)
```

**Java:**
```java
QueryResult result = client.queryRadius(
    QueryRadiusFilter.create(37.7749, -122.4194, 1000, 100)
);
```

### Error Handling (All Languages)

**Python:**
```python
try:
    result = client.query_radius(...)
except InvalidCoordinates as e:
    print(f"Invalid input: {e}")
except OperationTimeout as e:
    print(f"Timeout: {e}")
except RetryExhausted as e:
    print(f"All retries failed: {e.last_error}")
```

**Go:**
```go
result, err := client.QueryRadius(filter)
if err != nil {
    var coordErr InvalidCoordinatesError
    if errors.As(err, &coordErr) {
        // Handle invalid coordinates
    }
    var retryErr RetryExhaustedError
    if errors.As(err, &retryErr) {
        // Handle retry exhaustion
    }
}
```

**Java:**
```java
try {
    QueryResult result = client.queryRadius(filter);
} catch (ValidationException e) {
    // Invalid input
} catch (OperationException e) {
    // Timeout or other operation error
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Separate error files | Unified error codes from error_codes.zig | Phase 5 | Single source of truth |
| Manual topology | TopologyCache + ShardRouter | Phase 5 (05-01) | Automatic shard routing |
| Random UUIDs | ULID-based id() function | Phase 3 | Sortable, monotonic IDs |

**Deprecated/outdated:**
- **--aof flag**: Removed in 05-02, only --aof-file remains
- **Windows support**: Removed in Phase 1

## Open Questions

Things that couldn't be fully resolved:

1. **Java async implementation depth**
   - What we know: GeoClient interface exists, CompletableFuture mentioned in README
   - What's unclear: Exact implementation status of async methods in GeoClientImpl
   - Recommendation: Audit GeoClientImpl.java for async methods, implement if missing

2. **Maven Central / PyPI / npm publishing readiness**
   - What we know: Requirements listed (SDKJ-09, SDKP-09, SDKN-09)
   - What's unclear: Current state of package.json, pom.xml, setup.py for publishing
   - Recommendation: Verify each package's publishing configuration in planning phase

3. **Cross-SDK test data format**
   - What we know: `src/clients/test-data/wire-format-test-cases.json` exists
   - What's unclear: Whether this is used by all SDKs consistently
   - Recommendation: Audit each SDK's test setup for shared fixture usage

## Sources

### Primary (HIGH confidence)

- `/home/g/archerdb/src/clients/python/src/archerdb/client.py` - Reference implementation
- `/home/g/archerdb/src/clients/go/geo_client.go` - Go implementation
- `/home/g/archerdb/src/clients/java/src/main/java/com/archerdb/geo/GeoClient.java` - Java interface
- `/home/g/archerdb/src/clients/node/src/index.ts` - Node.js entry point
- `/home/g/archerdb/src/clients/c/arch_client.h` - C header (auto-generated)
- `/home/g/archerdb/docs/sdk-retry-semantics.md` - Retry specification
- `/home/g/archerdb/docs/error-codes.md` - Error code reference

### Secondary (MEDIUM confidence)

- `/home/g/archerdb/.planning/phases/06-sdk-parity/06-CONTEXT.md` - Phase decisions
- `/home/g/archerdb/.planning/STATE.md` - Project state and decisions

### Tertiary (LOW confidence)

- None - all sources are from codebase

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All patterns exist in codebase
- Architecture: HIGH - Patterns extracted from working implementations
- Pitfalls: HIGH - Based on actual code and docs/error-codes.md
- Open questions: MEDIUM - Need implementation audit

**Research date:** 2026-01-23
**Valid until:** 60 days (stable SDK patterns, not rapidly changing)
