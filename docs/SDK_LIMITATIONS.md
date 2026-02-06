# SDK Limitations

Known limitations across ArcherDB client SDKs with workarounds.

Per CONTEXT.md: All SDKs must achieve 100% parity before release.

## Overview

| SDK | Limitations | Status |
|-----|-------------|--------|
| Python | 1 (connection error propagation) | 94% parity (91/97 tests) |
| Node.js | None known | Not yet verified |
| Go | None known | Not yet verified |
| Java | None known | Not yet verified |
| C | None known | Not yet verified |

## Python SDK

**Known Limitations:**

### 1. Connection/Timeout Errors Not Raised as Exceptions (Category C: Implementation Gap)

**Issue:** Native client library logs connection errors (`error.ConnectionResetByPeer`) as warnings but doesn't propagate them to Python as `ArcherDBError` exceptions.

**Impact:**
- Tests expecting `pytest.raises(ArcherDBError)` fail for connection refused and timeout scenarios
- 6 tests fail in test_connection_errors.py and test_timeout_errors.py
- ERR-01 (connection failures) and ERR-02 (timeouts) partially covered

**Why it exists:**
- Native binding layer (ctypes) doesn't convert all native errors to Python exceptions
- Connection/timeout errors happen in message_bus layer but don't bubble up
- Error handling focused on distributed errors (multi-region, sharding, encryption)

**Workarounds:**
1. Use explicit connectivity checks before operations (e.g., ping with timeout)
2. Set shorter timeouts to fail faster and detect silent failures
3. Monitor for operations that don't return or raise (hung state)
4. Check return values where possible rather than relying solely on exceptions
5. For production: Implement application-level timeout watchdogs

**Test Results:** 91/97 tests pass (94% pass rate)
- ✓ Validation errors (ERR-03)
- ✓ Empty results (ERR-04)
- ✓ Server errors (ERR-05)
- ✓ Retry behavior (ERR-06)
- ✓ Batch limits (ERR-07)
- ✗ Connection failures (ERR-01) - 4 tests fail
- ✗ Timeout errors (ERR-02) - 2 tests fail

**Status:** Tracked for fix - requires native binding refactor

**Notes:**
- Used as golden reference for parity testing
- Sync and async clients available
- Full type hints support

## Node.js SDK

**Known Limitations:** None

**Workarounds:** N/A

**Notes:**
- Promise-based API
- TypeScript definitions included
- ES modules and CommonJS support

## Go SDK

**Known Limitations:** None

**Workarounds:** N/A

**Notes:**
- Context support for cancellation
- Connection pooling built-in
- Generics-based API (Go 1.18+)

## Java SDK

**Known Limitations:** None

**Workarounds:** N/A

**Notes:**
- CompletableFuture async API
- Maven/Gradle compatible
- Java 11+ required

## C SDK

**Known Limitations:** None

**Workarounds:** N/A

**Notes:**
- Header-only library option
- Memory management is caller's responsibility
- Callbacks for async operations

## Limitation Tracking

Per CONTEXT.md, limitations are tracked in:
1. This file (`docs/SDK_LIMITATIONS.md`) - centralized overview
2. Per-SDK README files - "Known Limitations" section
3. Inline code comments - docstrings on affected methods
4. Parity matrix (`docs/PARITY.md`) - notes on failing cells

## Reporting New Limitations

If you discover an SDK limitation:

1. File GitHub issue with label `sdk-limitation`
2. Document workaround if available
3. Update this file and per-SDK README
4. Add test case to `tests/parity_tests/fixtures/`
5. Update parity matrix with failure notes

## Limitation Categories

### Category A: Language Constraints
Limitations due to language features or runtime behavior:
- Floating-point precision differences
- Integer overflow handling
- Null/nil/undefined semantics

### Category B: Design Decisions
Intentional differences for SDK ergonomics:
- Sync vs async API availability
- Error handling patterns
- Configuration options

### Category C: Implementation Gaps
Features not yet implemented:
- Missing operations
- Partial functionality
- Performance optimizations pending

## Release Policy

Per CONTEXT.md: **Block release until 100% parity.**

All SDKs must achieve full parity before any can ship:
- Same operations available
- Same results for same inputs
- Same error behavior
- Same edge case handling

This ensures uniform quality across the SDK ecosystem.

## Parity Verification

Run parity tests to verify all SDKs match:

```bash
# Full parity test suite
python tests/parity_tests/parity_runner.py

# Check specific SDK
python tests/parity_tests/parity_runner.py --sdks python node

# Verbose output showing mismatches
python tests/parity_tests/parity_runner.py -v
```

Results are written to:
- `reports/parity.json` - machine-readable
- `docs/PARITY.md` - human-readable matrix

---
*Last updated: Phase 14 initial creation*
