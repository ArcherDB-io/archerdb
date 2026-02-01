# Phase 12: Zig SDK & Protocol Documentation - Context

**Gathered:** 2026-02-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Create the Zig SDK as a native client library and comprehensive protocol documentation that enables both idiomatic Zig usage and raw HTTP API access. The SDK provides all 14 operations following patterns from existing SDKs. Protocol docs explain wire format, enabling custom client implementation. curl examples demonstrate raw API usage.

</domain>

<decisions>
## Implementation Decisions

### Zig SDK API Design
- **Connection representation**: Struct with methods (idiomatic Zig style)
  - `var client = try Client.init(allocator, "http://...");`
  - `defer client.deinit();`
  - Not opaque pointers - more testable and Zig-like
- **Error handling**: Zig error unions with try/catch
  - `try client.insertEvent(...)` - standard Zig error propagation
  - Not C-style error codes
- **Allocator passing**: Always pass allocator explicitly to methods
  - `try client.queryRadius(allocator, lat, lon, radius)`
  - User controls memory allocation, more testable
- **Result ownership**: ArrayList owned by caller
  - `const results = try client.queryRadius(allocator, ...);`
  - `defer results.deinit();`
  - Clear ownership model

### Protocol Documentation Depth
- **Wire format**: Request/response examples for all 14 operations
  - Complete reference - every operation documented with HTTP details
- **Authentication**: Claude's discretion
  - Document what's actually implemented in the server
  - If no auth exists, note it; if auth exists, document the flow
- **Error responses**: Show all error codes with examples
  - Document every error code, HTTP status, JSON format, example scenarios
- **Versioning**: Skip versioning for now
  - Single version exists, no need to complicate docs until v2

### curl Examples Scope
- **Operations covered**: All 14 operations
  - Complete curl cookbook - working example for every operation
- **JSON formatting**: Minified JSON on one line
  - `curl -X POST ... -d '{"lat":37.7,"lon":-122.4}'`
  - Copy-paste ready, compact
- **Error demonstrations**: Show both success and error examples
  - For each operation: successful case + 1-2 error scenarios
- **Setup instructions**: Include quickstart
  - Show how to start local server before jumping into curl commands

### SDK Testing Strategy
- **Test organization**: Mirror other SDKs (same test structure)
  - Match Python/Node/Go/Java/C for consistency across all 6 SDKs
- **Fixture reuse**: Yes, load JSON fixtures from Phase 11
  - Use `test_infrastructure/fixtures/*.json` for consistency
- **Coverage**: All 14 operations with success/error cases
  - Match Phase 13 expectations - exhaustive testing in Phase 12
- **Test approach**: Both unit and integration tests
  - Unit tests: Mock HTTP layer, test SDK logic in isolation
  - Integration tests: Use Phase 11 cluster harness, test real HTTP

### Claude's Discretion
- Exact struct field names and type definitions
- Internal HTTP client implementation details
- Test data cleanup strategies
- Documentation formatting and organization
- Example data choices (city names, coordinates)

</decisions>

<specifics>
## Specific Ideas

No specific requirements - open to standard approaches for:
- Zig SDK follows established patterns from other 5 SDKs
- Protocol docs follow typical REST API documentation style
- curl examples follow common curl documentation conventions

</specifics>

<deferred>
## Deferred Ideas

None - discussion stayed within phase scope

</deferred>

---

*Phase: 12-zig-sdk-&-protocol-documentation*
*Context gathered: 2026-02-01*
