# Phase 12: Zig SDK & Protocol Documentation - Research

**Researched:** 2026-02-01
**Domain:** Zig native SDK, HTTP protocol documentation, REST API reference
**Confidence:** HIGH

## Summary

This phase creates the sixth and final ArcherDB SDK (Zig) and comprehensive protocol documentation including curl examples. Research focused on three domains: (1) idiomatic Zig SDK patterns using the standard library's `std.http.Client`, (2) existing SDK patterns already established in Python/Node/Go/Java/C clients for consistency, and (3) protocol documentation best practices.

The Zig SDK differs from other SDKs: while Python/Node/Go/Java/C use CGO bindings to the native client library (`arch_client`), the Zig SDK will be a pure Zig HTTP client communicating directly with ArcherDB's REST API. This is the natural choice since ArcherDB itself is written in Zig. The SDK provides struct-based API design per user decisions, with Zig error unions (`!T`) for error handling.

Protocol documentation already has a strong foundation in `docs/api-reference.md` with curl examples for major operations. This phase extends coverage to all 14 operations with error scenarios and creates dedicated protocol documentation for custom client implementers.

**Primary recommendation:** Build the Zig SDK as a native HTTP client using `std.http.Client`, following established SDK patterns from Go/Python clients, and extend existing protocol documentation to cover all 14 operations with comprehensive curl examples.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `std.http.Client` | Zig 0.15+ | HTTP client | Standard library, no dependencies, TLS 1.3 support |
| `std.json` | Zig 0.15+ | JSON serialization | Built-in, comptime type reflection |
| `std.heap` | Zig 0.15+ | Memory allocation | Required for allocator-passing pattern |
| `std.ArrayList` | Zig 0.15+ | Dynamic arrays | Result ownership model |
| `std.testing` | Zig 0.15+ | Unit testing | Built-in test framework |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `std.Uri` | Zig 0.15+ | URL parsing | Connection initialization |
| `std.crypto.tls` | Zig 0.15+ | TLS support | HTTPS connections |
| `std.debug` | Zig 0.15+ | Assertions | Development/debugging |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `std.http.Client` | httpx.zig | More features (HTTP/2, HTTP/3) but external dependency |
| `std.http.Client` | CGO bindings | Matches other SDKs but unnecessary for Zig-to-Zig |
| `std.json` | Manual parsing | More control but more code |

**Installation:**
```bash
# No external dependencies - pure Zig standard library
# Place SDK in src/clients/zig/
```

## Architecture Patterns

### Recommended Project Structure

```
src/clients/zig/
  client.zig           # Main Client struct and public API
  types.zig            # GeoEvent, QueryFilter, Response types
  http.zig             # HTTP request/response handling
  json.zig             # JSON serialization helpers
  errors.zig           # Error types and error set
  tests/
    unit/
      client_test.zig    # Unit tests (mocked HTTP)
      types_test.zig     # Type conversion tests
      json_test.zig      # JSON round-trip tests
    integration/
      roundtrip_test.zig # Integration tests (real server)
  README.md            # SDK documentation
  build.zig            # Build configuration
```

### Pattern 1: Struct with Methods (User Decision)

**What:** Client as non-opaque struct with methods
**When to use:** All SDK operations

```zig
// Source: User decision from CONTEXT.md
pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    base_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !Client {
        return Client{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .base_url = base_url,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    // Operations pass allocator explicitly (user decision)
    pub fn queryRadius(
        self: *Client,
        allocator: std.mem.Allocator,
        filter: QueryRadiusFilter,
    ) !QueryResult {
        // Implementation
    }
};
```

### Pattern 2: Error Union Returns (User Decision)

**What:** Use Zig error unions with try/catch
**When to use:** All fallible operations

```zig
// Source: User decision from CONTEXT.md
pub const ClientError = error{
    ConnectionFailed,
    ConnectionTimeout,
    ClusterUnavailable,
    InvalidCoordinates,
    BatchTooLarge,
    InvalidEntityId,
    EntityExpired,
    OperationTimeout,
    QueryResultTooLarge,
    ClientClosed,
    InvalidResponse,
    JsonParseError,
};

// Return error union
pub fn insertEvents(
    self: *Client,
    allocator: std.mem.Allocator,
    events: []const GeoEvent,
) ClientError![]InsertResult {
    // ...
    return error.InvalidCoordinates;
}

// Usage with try
const results = try client.insertEvents(allocator, events);
defer allocator.free(results);
```

### Pattern 3: Caller-Owned Results (User Decision)

**What:** ArrayList owned by caller with explicit deallocation
**When to use:** All query operations returning collections

```zig
// Source: User decision from CONTEXT.md
pub fn queryRadius(
    self: *Client,
    allocator: std.mem.Allocator,
    filter: QueryRadiusFilter,
) !QueryResult {
    // Allocate result using caller's allocator
    var events = std.ArrayList(GeoEvent).init(allocator);
    errdefer events.deinit();

    // Parse response, populate events
    // ...

    return QueryResult{
        .events = events,  // Caller owns this
        .has_more = response.has_more,
        .cursor = cursor,
    };
}

// Usage
const result = try client.queryRadius(allocator, filter);
defer result.events.deinit();  // Caller responsibility

for (result.events.items) |event| {
    // Process event
}
```

### Pattern 4: HTTP Request Flow

**What:** std.http.Client POST with JSON body
**When to use:** All server communication

```zig
// Source: https://github.com/tr1ckydev/zig_guides
pub fn doPost(
    self: *Client,
    allocator: std.mem.Allocator,
    path: []const u8,
    body: []const u8,
) ![]u8 {
    var buf: [4096]u8 = undefined;
    const uri = try std.Uri.parse(self.base_url);

    var request = try self.http_client.open(.POST, uri, .{
        .server_header_buffer = &buf,
    });
    defer request.deinit();

    // Set headers
    request.transfer_encoding = .chunked;
    try request.send();
    try request.writeAll(body);
    try request.finish();
    try request.wait();

    // Read response
    const response_body = try request.reader().readAllAlloc(allocator, 1024 * 1024);
    return response_body;
}
```

### Anti-Patterns to Avoid

- **Global allocator:** Always pass allocator explicitly (Zig idiom)
- **Opaque pointers:** User decided struct with methods, not opaque handles
- **C-style error codes:** User decided Zig error unions, not integer codes
- **Memory leaks:** Use `defer` and `errdefer` consistently
- **Blocking without timeout:** Always set request timeouts

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HTTP client | Raw TCP sockets | `std.http.Client` | TLS, connection pooling, headers |
| JSON parsing | Manual string parsing | `std.json` | Type-safe, comptime reflection |
| URL encoding | Custom encoder | `std.Uri` | RFC compliant, edge cases |
| UUID generation | rand() + formatting | Port existing types.ID() | Consistency with other SDKs |
| Nanodegree conversion | Inline math | Helper functions | Precision, reuse |

**Key insight:** Zig's standard library is comprehensive for HTTP client needs. The SDK should focus on ArcherDB-specific logic, not reinventing networking primitives.

## Common Pitfalls

### Pitfall 1: Memory Ownership Confusion

**What goes wrong:** Caller doesn't know who owns returned memory
**Why it happens:** Zig requires explicit memory management
**How to avoid:**
- Document ownership in function signatures
- Use ArrayList returned to caller pattern consistently
- Match Go SDK pattern where caller owns results
**Warning signs:** Double-free errors, memory leaks in tests

### Pitfall 2: Forgetting errdefer

**What goes wrong:** Resources leak on error paths
**Why it happens:** Early returns from try expressions
**How to avoid:**
```zig
var result = std.ArrayList(GeoEvent).init(allocator);
errdefer result.deinit();  // Clean up if later operations fail

try parseResponse(&result, response);  // May fail
return result;  // Success - caller owns
```
**Warning signs:** Memory grows over time in error scenarios

### Pitfall 3: Blocking HTTP without Timeout

**What goes wrong:** Client hangs on unresponsive server
**Why it happens:** std.http.Client defaults may not have timeouts
**How to avoid:** Configure explicit timeouts in client init
**Warning signs:** Test hangs, unresponsive applications

### Pitfall 4: JSON Float Precision Loss

**What goes wrong:** Coordinate precision lost in JSON round-trip
**Why it happens:** Float to string conversion artifacts
**How to avoid:** Use integer nanodegrees in wire format (already standard)
**Warning signs:** Events appear at wrong locations

### Pitfall 5: Not Matching Other SDKs

**What goes wrong:** Inconsistent behavior across language SDKs
**Why it happens:** Different interpretations of operations
**How to avoid:**
- Mirror test structure from Go/Python SDKs
- Load same fixtures from Phase 11
- Verify same inputs produce same outputs
**Warning signs:** Tests pass in Zig but fail fixture comparison

## Code Examples

### Client Initialization

```zig
// Source: User decisions + std.http.Client pattern
const std = @import("std");
const Client = @import("client.zig").Client;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try Client.init(allocator, "http://127.0.0.1:3001");
    defer client.deinit();

    // Use client...
}
```

### Insert Events

```zig
// Source: Go SDK pattern adapted for Zig
const events = [_]GeoEvent{
    .{
        .entity_id = generateId(),
        .lat_nano = degreesToNano(37.7749),
        .lon_nano = degreesToNano(-122.4194),
        .group_id = 1,
        .ttl_seconds = 86400,
    },
};

const results = try client.insertEvents(allocator, &events);
defer allocator.free(results);

for (results) |result| {
    if (result.code != 0) {
        std.debug.print("Event {d} failed: {d}\n", .{ result.index, result.code });
    }
}
```

### Query Radius

```zig
// Source: Go SDK pattern adapted for Zig
const filter = QueryRadiusFilter{
    .center_lat_nano = degreesToNano(37.7749),
    .center_lon_nano = degreesToNano(-122.4194),
    .radius_mm = 1000 * 1000,  // 1km in mm
    .limit = 100,
};

const result = try client.queryRadius(allocator, filter);
defer result.events.deinit();

std.debug.print("Found {d} events\n", .{result.events.items.len});

for (result.events.items) |event| {
    std.debug.print("Entity at ({d}, {d})\n", .{
        @as(f64, @floatFromInt(event.lat_nano)) / 1e9,
        @as(f64, @floatFromInt(event.lon_nano)) / 1e9,
    });
}
```

### Error Handling

```zig
// Source: User decision + Zig error union pattern
const result = client.queryRadius(allocator, filter) catch |err| switch (err) {
    error.ConnectionFailed => {
        std.debug.print("Connection failed, retrying...\n", .{});
        // Retry logic
        return error.ConnectionFailed;
    },
    error.InvalidCoordinates => {
        std.debug.print("Invalid coordinates in filter\n", .{});
        return error.InvalidCoordinates;
    },
    else => |e| return e,
};
```

### JSON Serialization

```zig
// Source: std.json + zig_guides pattern
pub fn serializeGeoEvent(allocator: std.mem.Allocator, event: GeoEvent) ![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    try std.json.stringify(event, .{}, json_string.writer());
    return json_string.toOwnedSlice();
}
```

## The 14 Operations

Based on test fixtures and existing SDK implementations:

| # | Operation | Opcode | Description |
|---|-----------|--------|-------------|
| 1 | insert | 146 | Insert geo events |
| 2 | upsert | 147 | Insert or update geo events |
| 3 | delete | 148 | Delete entities |
| 4 | query-uuid | 149 | Get latest by entity ID |
| 5 | query-uuid-batch | 156 | Batch get by entity IDs |
| 6 | query-radius | 150 | Find events in radius |
| 7 | query-polygon | 151 | Find events in polygon |
| 8 | query-latest | 154 | Get most recent events |
| 9 | ping | 152 | Health check |
| 10 | status | 153 | Server status |
| 11 | ttl-set | 158 | Set entity TTL |
| 12 | ttl-extend | 159 | Extend entity TTL |
| 13 | ttl-clear | 160 | Remove entity TTL |
| 14 | topology | 157 | Get cluster topology |

## curl Examples Scope (User Decision)

Per user decisions:
- **All 14 operations** with working examples
- **Minified JSON** on one line (copy-paste ready)
- **Error demonstrations** for each operation (success + 1-2 errors)
- **Quickstart** showing how to start local server

Example pattern:
```bash
# Success case
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":1001,"lat_nano":37774900000,"lon_nano":-122419400000}]}'

# Error case: invalid latitude
curl -X POST http://localhost:3001/events -H "Content-Type: application/json" -d '{"events":[{"entity_id":1001,"lat_nano":100000000000,"lon_nano":0}]}'
# Returns: {"results":[{"index":0,"code":9}]}  # LAT_OUT_OF_RANGE
```

## Test Strategy (User Decision)

Per user decisions:
- **Mirror other SDKs** (same test structure as Go/Python)
- **Fixture reuse** from Phase 11 (`test_infrastructure/fixtures/`)
- **Unit + Integration tests**
  - Unit: Mock HTTP layer, test SDK logic
  - Integration: Real server via Phase 11 cluster harness
- **All 14 operations** with success/error cases

Test file structure matching Go SDK:
```
tests/
  unit/
    client_test.zig      # Matches go/geo_test.go
    types_test.zig       # Type conversion tests
  integration/
    roundtrip_test.zig   # Matches go/integration_test.go
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| CGO bindings for all SDKs | Pure Zig HTTP for Zig SDK | This phase | Simpler, no FFI overhead |
| TLS 1.2 + 1.3 | TLS 1.3 only (std.crypto.tls) | Zig 0.13+ | Simplified, modern-only |
| Manual HTTP parsing | std.http.Client | Zig 0.12+ | Standard library support |

**Note:** Zig's TLS only supports 1.3. This is fine for modern deployments but may limit legacy compatibility.

## Open Questions

1. **HTTP/2 Support**
   - What we know: std.http.Client is HTTP/1.1 only
   - What's unclear: Whether ArcherDB server supports HTTP/2
   - Recommendation: Use HTTP/1.1 (sufficient for SDK use case)

2. **Connection Pooling**
   - What we know: std.http.Client has connection reuse
   - What's unclear: Optimal pool configuration for SDK
   - Recommendation: Use defaults, document configuration options

3. **Authentication**
   - What we know: User decided "document what's implemented"
   - What's unclear: Current auth implementation status
   - Recommendation: Check server implementation, document accordingly

## Protocol Documentation Existing Resources

The following resources exist and inform protocol docs:

| Resource | Location | Content |
|----------|----------|---------|
| API Reference | `docs/api-reference.md` | Operations, types, curl examples |
| Error Codes | `docs/error-codes.md` | Complete error reference |
| Wire Format | `src/clients/test-data/` | Binary protocol test cases |
| C Header | `src/clients/c/arch_client.h` | Authoritative type definitions |
| Test Fixtures | `test_infrastructure/fixtures/v1/` | JSON format for all 14 ops |

## Sources

### Primary (HIGH confidence)

- Zig Standard Library `std.http.Client` - HTTP client API
- ArcherDB source code (`src/clients/go/geo_client.go`) - SDK patterns
- ArcherDB test fixtures (`test_infrastructure/fixtures/v1/`) - Operation definitions
- `docs/api-reference.md` - Existing protocol documentation
- `docs/error-codes.md` - Error code reference
- `src/clients/c/arch_client.h` - Wire format type definitions

### Secondary (MEDIUM confidence)

- [Zig HTTP Guide](https://github.com/tr1ckydev/zig_guides) - POST request patterns
- [Zig.guide JSON](https://zig.guide/standard-library/json/) - JSON serialization
- [Zig Error Handling](https://zig.guide/language-basics/errors/) - Error union patterns

### Tertiary (LOW confidence)

- WebSearch results for Zig HTTP patterns - Verified against std docs
- curl documentation best practices - Verified with existing api-reference.md

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Zig standard library is well-documented, verified
- Architecture: HIGH - Patterns derived from existing SDKs and user decisions
- Pitfalls: MEDIUM - Based on Zig idioms and SDK development experience
- Protocol docs: HIGH - Building on existing comprehensive documentation

**Research date:** 2026-02-01
**Valid until:** 2026-03-01 (30 days - Zig stdlib is stable)
