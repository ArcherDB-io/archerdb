# Phase 6: SDK Parity - Context

**Gathered:** 2026-01-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Complete all 5 SDKs (C, Go, Java, Node.js, Python) to feature and quality parity. Same operations available, same error handling patterns (adapted to language idioms), same documentation depth, same test coverage. Every SDK is first-class.

</domain>

<decisions>
## Implementation Decisions

### Error Handling Strategy
- Language-idiomatic error surfacing: exceptions (Java/Python), Result/error return (Go), error codes (C), etc.
- Unified error codes across all SDKs — same ArcherDB error codes (e.g., ERR_NOT_FOUND, ERR_TIMEOUT) regardless of mechanism
- Full error details: code + human message + context (entity ID, request ID, etc.)
- Separate error hierarchies: NetworkError vs DataError vs ValidationError as distinct types/categories

### Documentation Approach
- Full documentation: inline docstrings/comments that generate API reference (godoc, javadoc, TSDoc, pydoc, Doxygen)
- Working code examples for every public operation
- Per-SDK quickstarts in each SDK's README
- Plus shared comparison guide showing same operations across all 5 languages
- Central docs site as source of truth, SDK READMEs link there

### Async/Sync API Design
- Async where idiomatic: Java (CompletableFuture), Node.js (Promise), Python (asyncio), Go (Context for cancellation). C stays synchronous.
- No sync fallback for async SDKs — force modern patterns where async exists
- Connection pooling managed internally by default, but user can configure pool size, timeouts, etc.
- Request cancellation supported via language mechanisms (Go Context, Java interrupt, Python asyncio.CancelledError, etc.)

### Testing & Validation
- Cross-SDK test suite: same test scenarios executed across all 5 SDKs
- Integration tests required against real ArcherDB instance (Docker/local)
- All public APIs tested (100% public method coverage, not line coverage %)
- Shared golden test data (JSON/YAML fixtures) across all SDKs for consistent validation

### Claude's Discretion
- Specific error code names and numeric values
- Generated docs tooling choice per language
- Exact connection pool defaults
- Test fixture file format and organization

</decisions>

<specifics>
## Specific Ideas

- Connection pooling: "SDK manages pool internally by default, but let the user modify configs if they decide so"
- Error hierarchies should make it easy to catch "all network errors" vs "all validation errors" in one handler

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 06-sdk-parity*
*Context gathered: 2026-01-23*
