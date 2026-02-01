# SDK Limitations

Known limitations across ArcherDB client SDKs with workarounds.

Per CONTEXT.md: All SDKs must achieve 100% parity before release.

## Overview

| SDK | Limitations | Status |
|-----|-------------|--------|
| Python | None known | Full parity |
| Node.js | None known | Full parity |
| Go | None known | Full parity |
| Java | None known | Full parity |
| C | None known | Full parity |
| Zig | None known | Full parity |

## Python SDK

**Known Limitations:** None

**Workarounds:** N/A

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

## Zig SDK

**Known Limitations:** None

**Workarounds:** N/A

**Notes:**
- Comptime type safety
- Error unions for comprehensive error handling
- Allocator-aware design

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
