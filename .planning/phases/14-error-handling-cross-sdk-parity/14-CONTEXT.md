# Phase 14: Error Handling & Cross-SDK Parity - Context

**Gathered:** 2026-02-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Ensuring all 6 SDKs (Python, Node.js, Go, Java, C, Zig) handle errors consistently and produce identical results for identical operations. This phase validates robustness (error handling) and compatibility (cross-SDK parity) after establishing operation correctness in Phase 13.

Scope includes:
- Error handling tests for connection failures, timeouts, server errors
- Cross-SDK parity verification (14 ops × 6 SDKs = 84 combinations)
- Edge case testing (geographic extremes, empty results, boundary conditions)
- Limitation documentation with workarounds

</domain>

<decisions>
## Implementation Decisions

### Error Handling Strategy
- **Error exposure:** Use native error types for each SDK (exceptions in Python/Java, Result types where applicable, error codes in C) — not custom ArcherDB error classes
- **Error information:** Errors must include:
  - Error code (identifying the error type)
  - Human-readable message (descriptive, actionable)
  - Server response when available (status code, body, headers)
  - Context details (operation attempted, parameters, retry attempts)
- **Retry behavior:** Configurable retries with default 3 attempts and exponential backoff — users can configure via client options
- **Test validation:** Verify error types/codes only, not exact message wording — allows message improvements without breaking tests

### Parity Verification Approach
- **Verification strategy:** Layered approach:
  1. Direct comparison between all SDKs
  2. Python SDK as golden reference for tie-breaking
  3. Server responses as ultimate truth
- **Equality definition:** Multiple levels:
  - Structural equality (same fields, types, values)
  - Semantic equality (same meaning across representations)
  - Exact byte equality (strictest validation)
  - Field presence (all required fields present)
- **Floating-point handling:** Exact match required — coordinates must match at nanodegree precision, no epsilon tolerance
- **Parity matrix format:** Both JSON (for CI automation) and Markdown (for human review) formats
  - JSON: parity.json with detailed pass/fail, diffs, machine-readable
  - Markdown: docs/PARITY.md with ✓/✗ per cell (14 ops × 6 SDKs)

### Edge Case Coverage
- **Geographic edge cases (all high priority):**
  - Polar regions (latitude ±90°) where longitude is ambiguous
  - Anti-meridian (longitude ±180°) date line crossing
  - Equator/Prime meridian (0° crossings)
  - Extreme distances (globe-spanning queries, radius > Earth)
- **Empty result scenarios:** Verify both structure (correct empty array/list type) AND metadata (count=0, success status)
- **Test data approach:** Both curated fixtures AND generated data
  - Curated: Hand-crafted for known critical edge cases (explicit, readable)
  - Generated: Programmatic generation for broader coverage and fuzzing
- **Polygon edge cases:** Dual validation — SDKs validate and reject invalid polygons (concave, self-intersecting) upfront, AND server validates if requests get through (defense in depth)

### Limitation Documentation
- **Documentation locations (all four):**
  - SDK README files: "Known Limitations" section per SDK
  - Centralized docs: docs/SDK_LIMITATIONS.md comparing all 6 SDKs
  - Inline code comments: Docstrings on affected methods
  - Parity matrix: Notes on why cells fail or have exceptions
- **Detail level:** Full explanation — why limitation exists (language constraints, design trade-offs) plus workarounds
- **Release policy:** Block release until 100% parity — all SDKs must achieve full parity before any can ship (uniform quality)

### Claude's Discretion
- Tracking mechanism for eliminating limitations (GitHub issues vs roadmap vs dashboard)
- Specific exponential backoff algorithm parameters
- JSON schema for machine-readable parity report
- Exact structure of markdown parity table

</decisions>

<specifics>
## Specific Ideas

No specific product references mentioned — open to standard approaches for error handling and testing patterns.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 14-error-handling-cross-sdk-parity*
*Context gathered: 2026-02-01*
