# Phase 14: Error Handling & Cross-SDK Parity - Research

**Researched:** 2026-02-01
**Domain:** SDK Error Handling, Cross-Language Test Parity, Error Code Standardization
**Confidence:** HIGH

## Summary

This phase ensures all 6 ArcherDB SDKs (Python, Node.js, Go, Java, C, Zig) handle errors consistently and produce identical results for identical operations. Research focused on three areas: (1) existing error handling patterns across all SDKs, (2) cross-SDK parity verification strategies, and (3) edge case coverage for geographic extremes.

The foundation is solid:
- **All 6 SDKs have error types** with consistent error codes and retryability flags
- **Wire format test cases** exist in `src/clients/test-data/wire-format-test-cases.json`
- **Retry policies** are standardized: 5 max retries, 100ms base backoff, exponential with jitter
- **Error code ranges** are consistent: 200-210 (state), 213-218 (multi-region), 220-224 (sharding), 410-414 (encryption)

Key insight: Error handling infrastructure exists but needs verification testing. The SDKs implement similar patterns but have not been systematically tested for cross-SDK parity. Per CONTEXT.md, tests should verify error types/codes only, not exact message wording.

**Primary recommendation:** Create error injection tests using server responses, build a parity verification runner that executes identical operations across all 6 SDKs, and document any SDK limitations with workarounds. Target 100% parity before release.

## Standard Stack

### Core Infrastructure

| Tool/Library | Version | Purpose | Why Standard |
|--------------|---------|---------|--------------|
| Python | 3.11+ | Test orchestration, parity runner | Phase 11 established Python for harness |
| pytest | 8.x | Python test execution | Already used in SDK tests |
| deepdiff | 7.x | JSON comparison with semantic diff | Best for nested structure comparison |
| JSON Schema | draft-2020-12 | Parity report format validation | Machine-readable CI integration |

### Error Handling Libraries by SDK

| SDK | Error Module | Error Base Class | Retry Implementation |
|-----|--------------|------------------|---------------------|
| Python | `archerdb/client.py` | `ArcherDBError` | Built-in with `RetryPolicy` |
| Node.js | `src/errors.ts` | `ArcherDBError` | Built-in with async retry |
| Go | `pkg/errors/` | `GeoError` interface | `pkg/retry/retry.go` |
| Java | `com.archerdb.geo` | `ArcherDBException` | `RetryPolicy.java` |
| C | `arch_client_errors.h` | Integer codes | Manual retry |
| Zig | `errors.zig` | `ClientError` enum | Manual retry |

### Supporting Infrastructure

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `test_infrastructure/harness/` | Server lifecycle management | All error injection tests |
| `test_infrastructure/fixtures/v1/` | Existing operation fixtures | Base for error test cases |
| `src/clients/test-data/wire-format-test-cases.json` | Canonical constants | Error code verification |

## Architecture Patterns

### Recommended Project Structure

```
tests/
  error_tests/
    conftest.py                    # Shared fixtures for error tests
    test_connection_errors.py      # Connection failure tests (ERR-01)
    test_timeout_errors.py         # Timeout handling tests (ERR-02)
    test_validation_errors.py      # Input validation tests (ERR-03)
    test_empty_results.py          # Empty result handling tests (ERR-04)
    test_server_errors.py          # Server error code tests (ERR-05)
    test_retry_behavior.py         # Retry with backoff tests (ERR-06)
    test_batch_errors.py           # Batch size limit tests (ERR-07)
  parity_tests/
    parity_runner.py               # Main orchestration script
    parity_verifier.py             # Result comparison logic
    test_insert_parity.py          # Insert operation parity
    test_query_parity.py           # Query operations parity
    test_error_parity.py           # Error response parity
    fixtures/
      edge_cases/
        polar_coordinates.json     # North/South pole tests
        antimeridian.json          # Date line crossing tests
        equator_prime_meridian.json # 0-degree crossing tests
docs/
  SDK_LIMITATIONS.md               # Centralized limitation docs
  PARITY.md                        # Human-readable parity matrix
reports/
  parity.json                      # Machine-readable parity report
```

### Pattern 1: Error Code Verification (per CONTEXT.md)

**What:** Test error types/codes only, not exact message wording
**When to use:** All error handling tests

```python
# Source: CONTEXT.md decision - verify error types/codes only
import pytest
from archerdb import ArcherDBError, InvalidCoordinates, BatchTooLarge

def test_invalid_coordinates_error_code():
    """Verify error CODE, not message text."""
    with pytest.raises(ArcherDBError) as exc_info:
        client.insert_events([
            GeoEvent(entity_id=1, latitude=200, longitude=0)  # Invalid
        ])

    # Verify by error code (stable) not message (changeable)
    assert exc_info.value.code == 3001  # InvalidCoordinates
    assert exc_info.value.retryable == False

    # DO NOT assert exact message - allows message improvements
    # assert exc_info.value.message == "specific text"  # WRONG
```

### Pattern 2: Cross-SDK Parity Verification (per CONTEXT.md)

**What:** Layered verification: direct comparison, Python as golden reference, server as truth
**When to use:** All parity tests

```python
# Source: CONTEXT.md decisions on parity verification
from typing import Dict, Any, List
import subprocess
import json

class ParityVerifier:
    """Verify SDK results match across all 6 SDKs."""

    SDK_ORDER = ["python", "node", "go", "java", "c", "zig"]

    def __init__(self, server_url: str):
        self.server_url = server_url
        self.results: Dict[str, Any] = {}

    def run_operation(self, sdk: str, operation: str, input_data: dict) -> dict:
        """Run operation in specified SDK and capture result."""
        # Each SDK has a test runner that accepts JSON input
        cmd = self._get_sdk_command(sdk, operation)
        result = subprocess.run(
            cmd,
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            env={**os.environ, "ARCHERDB_URL": self.server_url}
        )
        return json.loads(result.stdout)

    def verify_parity(self, operation: str, input_data: dict) -> ParityResult:
        """Run operation across all SDKs and verify parity."""
        results = {}
        for sdk in self.SDK_ORDER:
            results[sdk] = self.run_operation(sdk, operation, input_data)

        # Layer 1: Direct comparison (all must match)
        reference = results["python"]  # Python as golden reference
        mismatches = []

        for sdk in self.SDK_ORDER[1:]:  # Skip Python (it's the reference)
            if not self._compare_results(reference, results[sdk]):
                mismatches.append({
                    "sdk": sdk,
                    "expected": reference,
                    "actual": results[sdk],
                    "diff": self._compute_diff(reference, results[sdk])
                })

        # Layer 2: If mismatch, check against server directly
        if mismatches:
            server_response = self._query_server_directly(operation, input_data)
            for mismatch in mismatches:
                mismatch["matches_server"] = self._compare_results(
                    server_response, results[mismatch["sdk"]]
                )

        return ParityResult(
            operation=operation,
            passed=len(mismatches) == 0,
            mismatches=mismatches,
            sdk_results=results
        )

    def _compare_results(self, expected: dict, actual: dict) -> bool:
        """Compare results per CONTEXT.md equality levels."""
        # Structural equality: same fields, types, values
        # Per CONTEXT.md: exact match for coordinates (nanodegrees)
        return self._deep_equals(expected, actual, float_tolerance=0)
```

### Pattern 3: Native Error Types (per CONTEXT.md)

**What:** Use native error types for each SDK
**When to use:** All SDK implementations

```python
# Python: Use built-in Exception subclasses
class ArcherDBError(Exception):
    code: int = 0
    retryable: bool = False
```

```typescript
// Node.js: Use Error subclasses
class ArcherDBError extends Error {
  code: number;
  retryable: boolean;
}
```

```go
// Go: Use error interface with helper functions
type GeoError interface {
    error
    Code() int
    Retryable() bool
}
```

```java
// Java: Use checked exceptions
public class ArcherDBException extends Exception {
    private final int errorCode;
    private final boolean retryable;
}
```

```c
// C: Use integer error codes with helper functions
int arch_error_is_retryable(int code);
const char* arch_error_name(int code);
```

```zig
// Zig: Use error union with error set
pub const ClientError = error{
    ConnectionFailed,
    InvalidCoordinates,
    // ...
};
pub fn isRetryable(err: ClientError) bool { ... }
```

### Pattern 4: Configurable Retry with Exponential Backoff (per CONTEXT.md)

**What:** Default 3 attempts, exponential backoff, user-configurable via client options
**When to use:** All transient error handling

```python
# Source: All SDKs implement consistent retry
# Default: 3 retries (spec says 5, CONTEXT.md says 3 default)
# Backoff: exponential with jitter

class RetryConfig:
    max_retries: int = 3          # CONTEXT.md: default 3 attempts
    base_backoff_ms: int = 100    # Existing SDK pattern
    max_backoff_ms: int = 1600    # Existing SDK pattern
    total_timeout_ms: int = 30000 # Existing SDK pattern
    jitter_enabled: bool = True   # Prevent thundering herd

def calculate_backoff(attempt: int, config: RetryConfig) -> int:
    """Exponential backoff: 100, 200, 400, 800, 1600ms + jitter."""
    if attempt == 0:
        return 0  # First attempt is immediate

    delay = config.base_backoff_ms * (2 ** (attempt - 1))
    delay = min(delay, config.max_backoff_ms)

    if config.jitter_enabled:
        import random
        jitter = random.randint(0, delay // 2)
        delay += jitter

    return delay
```

### Pattern 5: Parity Matrix Output (per CONTEXT.md)

**What:** Both JSON (CI) and Markdown (human review) formats
**When to use:** Parity test report generation

```python
# Source: CONTEXT.md decision on parity matrix format
def generate_parity_report(results: List[ParityResult]) -> tuple[str, dict]:
    """Generate both Markdown and JSON parity reports."""

    # JSON format for CI automation
    json_report = {
        "generated": datetime.utcnow().isoformat(),
        "summary": {
            "total_cells": len(results),
            "passed": sum(1 for r in results if r.passed),
            "failed": sum(1 for r in results if not r.passed)
        },
        "operations": {}
    }

    # Markdown format for human review
    md_lines = [
        "# SDK Parity Matrix",
        "",
        f"Generated: {datetime.utcnow().isoformat()}",
        "",
        "| Operation | Python | Node.js | Go | Java | C | Zig |",
        "|-----------|--------|---------|----|----|---|-----|"
    ]

    operations = defaultdict(dict)
    for result in results:
        operations[result.operation][result.sdk] = result

    for op_name, sdk_results in operations.items():
        row = f"| {op_name} |"
        json_report["operations"][op_name] = {}

        for sdk in ["python", "node", "go", "java", "c", "zig"]:
            if sdk in sdk_results:
                result = sdk_results[sdk]
                symbol = "\u2713" if result.passed else "\u2717"  # checkmark or X
                row += f" {symbol} |"
                json_report["operations"][op_name][sdk] = {
                    "passed": result.passed,
                    "diff": result.diff if not result.passed else None
                }
            else:
                row += " - |"
                json_report["operations"][op_name][sdk] = {"passed": None}

        md_lines.append(row)

    return "\n".join(md_lines), json_report
```

### Anti-Patterns to Avoid

- **Message text matching:** Never assert on error message text (per CONTEXT.md)
- **Floating-point epsilon tolerance:** Use exact nanodegree matching (per CONTEXT.md)
- **Custom error classes in C:** Use integer codes, not struct-based errors
- **Swallowing retry exhaustion:** Always propagate final error after retries exhausted
- **SDK-specific error codes:** All SDKs must use same numeric codes from spec

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON semantic diff | String comparison | deepdiff (Python) | Handles nested structures, ordering |
| Retry logic | Custom sleep loops | SDK's RetryPolicy | Consistent backoff algorithm |
| Error code lookup | Switch statements | Error code enums/maps | Defined in each SDK already |
| Server mocking | Custom mock server | Phase 11 test harness | Realistic responses |
| Coordinate conversion | Manual arithmetic | SDK's degreesToNano | Precision-tested |
| Polygon validation | Custom geometry | SDK's validation | Complex edge cases handled |

**Key insight:** Each SDK already has error handling infrastructure. Phase 14 validates consistency, not reimplements.

## Common Pitfalls

### Pitfall 1: Testing Error Messages Instead of Codes

**What goes wrong:** Tests break when error messages are improved
**Why it happens:** Natural to assert on the full error string
**How to avoid:** Per CONTEXT.md, verify error types/codes only

```python
# WRONG - will break if message changes
assert str(error) == "Invalid coordinates: latitude 200 is out of range"

# CORRECT - stable error code
assert error.code == 3001
assert error.retryable == False
```

**Warning signs:** Test failures after SDK message improvements

### Pitfall 2: Floating-Point Comparison in Parity

**What goes wrong:** Same coordinates show as "different" due to float representation
**Why it happens:** 37.7749 in Python != 37.7749 in Go at bit level
**How to avoid:** Per CONTEXT.md, compare as nanodegrees (integers), no epsilon tolerance

```python
# WRONG - epsilon tolerance
assert abs(python_lat - go_lat) < 0.0000001

# CORRECT - exact nanodegree match
assert python_lat_nano == go_lat_nano  # Both i64
```

**Warning signs:** Intermittent parity failures on identical data

### Pitfall 3: Missing Error Context in Tests

**What goes wrong:** Can't diagnose which SDK or operation failed
**Why it happens:** Generic assertions without context
**How to avoid:** Per CONTEXT.md, errors must include operation attempted, parameters, retry attempts

```python
# WRONG - no context
assert result.passed

# CORRECT - full context for debugging
assert result.passed, f"""
Parity failed for operation: {result.operation}
SDK: {result.sdk}
Input: {result.input}
Expected: {result.expected}
Actual: {result.actual}
Diff: {result.diff}
"""
```

**Warning signs:** Cryptic CI failures requiring reproduction

### Pitfall 4: Retrying Non-Retryable Errors

**What goes wrong:** Infinite loops or wasted time on permanent failures
**Why it happens:** Not checking `retryable` flag
**How to avoid:** All SDKs have `isRetryable()` or equivalent

```python
# WRONG - retry everything
for attempt in range(max_retries):
    try:
        return operation()
    except Exception:
        time.sleep(backoff)

# CORRECT - check retryable
for attempt in range(max_retries):
    try:
        return operation()
    except ArcherDBError as e:
        if not e.retryable:
            raise  # Don't retry permanent failures
        time.sleep(backoff)
```

**Warning signs:** Tests taking much longer than expected

### Pitfall 5: Geographic Edge Case Coverage Gaps

**What goes wrong:** Polar/antimeridian bugs only found in production
**Why it happens:** Test data concentrated around typical coordinates
**How to avoid:** Per CONTEXT.md, all geographic edge cases are high priority

```python
# Essential edge cases per CONTEXT.md:
EDGE_CASES = [
    # Polar regions - longitude ambiguous at poles
    {"lat": 90.0, "lon": 0.0, "name": "north_pole"},
    {"lat": 90.0, "lon": 180.0, "name": "north_pole_180"},  # Same point!
    {"lat": -90.0, "lon": -45.0, "name": "south_pole"},

    # Antimeridian - date line crossing
    {"lat": 0.0, "lon": 179.9999, "name": "before_antimeridian"},
    {"lat": 0.0, "lon": -179.9999, "name": "after_antimeridian"},

    # Zero crossings
    {"lat": 0.0, "lon": 0.0, "name": "equator_prime"},
    {"lat": 0.0, "lon": 180.0, "name": "equator_180"},
]
```

**Warning signs:** Users report issues with locations in Alaska, Russia, Antarctica

### Pitfall 6: Polygon Validation Mismatch

**What goes wrong:** SDK accepts polygon, server rejects (or vice versa)
**Why it happens:** Different validation implementations
**How to avoid:** Per CONTEXT.md, dual validation - SDK validates AND server validates

```python
# Both layers must reject invalid polygons
def test_concave_polygon_rejection():
    """Verify both SDK and server reject concave polygons."""
    concave_polygon = [
        (0, 0), (2, 0), (2, 2), (1, 1), (0, 2)  # Concave
    ]

    # SDK should catch early (preferred)
    with pytest.raises(InvalidPolygon):
        client.query_polygon(concave_polygon)

    # OR server catches if SDK doesn't validate
    # (defense in depth per CONTEXT.md)
```

**Warning signs:** Inconsistent error behavior across SDKs

## Code Examples

### Error Information Structure (per CONTEXT.md)

```python
# Source: CONTEXT.md - errors must include these fields
class ArcherDBError(Exception):
    """Base class with required error information."""

    code: int = 0           # Error code (identifying the error type)
    message: str = ""       # Human-readable message (descriptive, actionable)
    retryable: bool = False # Whether operation can be retried

    # Server response when available
    status_code: int = 0    # HTTP status code
    response_body: str = "" # Response body
    response_headers: dict = {}  # Response headers

    # Context details
    operation: str = ""     # Operation attempted (e.g., "insert", "query_radius")
    parameters: dict = {}   # Parameters used
    retry_attempts: int = 0 # Number of retry attempts made
```

### Connection Error Test (ERR-01)

```python
# Source: CONTEXT.md requirement ERR-01
import pytest
from archerdb import GeoClientSync, GeoClientConfig, ConnectionFailed

def test_connection_failure_graceful():
    """All SDKs handle connection failures gracefully."""
    config = GeoClientConfig(
        cluster_id=0,
        addresses=["127.0.0.1:9999"]  # Non-existent server
    )

    with pytest.raises(ConnectionFailed) as exc_info:
        with GeoClientSync(config) as client:
            client.ping()

    # Verify error properties per CONTEXT.md
    error = exc_info.value
    assert error.code == 1001
    assert error.retryable == True
    assert "127.0.0.1:9999" in error.message  # Context included
```

### Empty Result Handling Test (ERR-04)

```python
# Source: CONTEXT.md - verify structure AND metadata
def test_empty_radius_query_result():
    """Empty results have correct structure AND metadata."""
    # Query area with no entities
    result = client.query_radius(
        latitude=0.0,
        longitude=0.0,
        radius_m=1.0  # Tiny radius, likely empty
    )

    # Structure: correct empty array/list type
    assert isinstance(result.events, list)
    assert len(result.events) == 0

    # Metadata: count=0, success status
    assert result.count == 0
    assert result.success == True
    assert result.status_code == 0
```

### Retry with Exponential Backoff Test (ERR-06)

```python
# Source: CONTEXT.md - configurable retries, default 3, exponential backoff
import time
from unittest.mock import patch

def test_retry_with_exponential_backoff():
    """Verify retry behavior with exponential backoff."""
    attempt_times = []

    def failing_operation():
        attempt_times.append(time.monotonic())
        raise ConnectionFailed("Simulated failure")

    config = GeoClientConfig(
        retry_config=RetryConfig(max_retries=3)  # Default per CONTEXT.md
    )

    with pytest.raises(ConnectionFailed):
        client.with_retry(failing_operation, config)

    # Should have 4 attempts (1 initial + 3 retries)
    assert len(attempt_times) == 4

    # Verify exponential backoff (100, 200, 400ms base)
    delays = [attempt_times[i+1] - attempt_times[i] for i in range(3)]
    assert delays[0] >= 0.080  # ~100ms with jitter variance
    assert delays[1] >= 0.160  # ~200ms with jitter variance
    assert delays[2] >= 0.320  # ~400ms with jitter variance
```

### Parity Test for Insert Operation (PARITY-02)

```python
# Source: CONTEXT.md - all SDKs return identical results
def test_insert_parity_across_sdks():
    """All 6 SDKs return identical results for identical insert."""
    input_data = {
        "events": [{
            "entity_id": 12345,
            "latitude": 37.7749,
            "longitude": -122.4194
        }]
    }

    verifier = ParityVerifier(server_url)
    result = verifier.verify_parity("insert", input_data)

    assert result.passed, f"""
Insert parity failed!
Mismatches: {result.mismatches}
SDK Results: {result.sdk_results}
"""
```

### Geographic Edge Case Test (PARITY-03)

```python
# Source: CONTEXT.md - all geographic edge cases are high priority
@pytest.mark.parametrize("edge_case", [
    {"lat": 90.0, "lon": 0.0, "name": "north_pole"},
    {"lat": -90.0, "lon": 0.0, "name": "south_pole"},
    {"lat": 0.0, "lon": 180.0, "name": "antimeridian_east"},
    {"lat": 0.0, "lon": -180.0, "name": "antimeridian_west"},
    {"lat": 0.0, "lon": 0.0, "name": "equator_prime"},
])
def test_edge_case_parity(edge_case):
    """All SDKs handle geographic edge cases identically."""
    input_data = {
        "events": [{
            "entity_id": 1,
            "latitude": edge_case["lat"],
            "longitude": edge_case["lon"]
        }]
    }

    verifier = ParityVerifier(server_url)
    result = verifier.verify_parity("insert", input_data)

    assert result.passed, f"Edge case '{edge_case['name']}' failed parity"
```

## Error Code Reference

### Complete Error Code Ranges (from codebase analysis)

| Range | Category | Retryable | Examples |
|-------|----------|-----------|----------|
| 0 | Success | N/A | Operation completed |
| 1-99 | Protocol | Mixed | Invalid checksum, version mismatch |
| 100-199 | Validation | No | Invalid coordinates (102), polygon issues (103) |
| 200-210 | State | No | Entity not found (200), expired (210) |
| 213-218 | Multi-region | Mixed | Follower read-only (213), stale follower (214) |
| 220-224 | Sharding | Mixed | Not shard leader (220), resharding (222) |
| 300-399 | Resource | Mixed | Batch too large (301), disk full (306) |
| 410-414 | Encryption | Mixed | Key unavailable (410), decryption failed (411) |
| 1000-1002 | Internal | Mixed | Unexpected (1000), OOM (1001) |
| 2001 | Network | Yes | Network subsystem error |
| 3001-3004 | Config | No | Invalid address, concurrency |
| 4001-4004 | Client State | Mixed | Evicted (yes), closed (no) |
| 5001-5002 | Operation | No | Invalid operation, batch too large |

### Retryable Error Summary

**Always Retryable:**
- 1001 (OOM), 1002 (system resources)
- 2001 (network subsystem)
- 4001 (client evicted)
- 214 (stale follower), 215 (primary unreachable), 216 (replication timeout)
- 220 (not shard leader), 221 (shard unavailable), 222 (resharding)
- 410 (encryption key unavailable), 413 (key rotation)

**Never Retryable:**
- 200 (entity not found), 210 (entity expired)
- 213 (follower read-only), 217 (conflict), 218 (geo-shard mismatch)
- 223 (invalid shard count), 224 (migration failed)
- 411 (decryption failed), 412 (encryption not enabled), 414 (unsupported version)
- 3001-3004 (configuration errors)
- 4004 (client closed)
- 5001-5002 (operation errors)

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SDK-specific error codes | Unified error code ranges | Phase 12 | All SDKs use same codes |
| Manual retry loops | RetryPolicy classes | Phase 12 | Consistent backoff |
| String error comparison | Code-based comparison | Phase 14 (CONTEXT.md) | Stable tests |
| Epsilon float tolerance | Exact nanodegree match | Phase 14 (CONTEXT.md) | Precise parity |
| Individual SDK testing | Cross-SDK parity runner | Phase 14 | Unified verification |

**Current SDK Error Handling State:**
- Python: Full error hierarchy, RetryPolicy, circuit breaker
- Node.js: Full TypeScript error classes, type guards, retry
- Go: Interface-based errors, error wrapping, retry package
- Java: Exception hierarchy, RetryPolicy builder pattern
- C: Integer codes with inline helper functions
- Zig: Error union with error set, helper functions

## Open Questions

1. **Retry Count Discrepancy**
   - What we know: Existing SDKs default to 5 retries, CONTEXT.md says 3
   - What's unclear: Which value should be the new standard
   - Recommendation: Use CONTEXT.md value (3) for new tests, document as configurable

2. **Server Response Headers in Error**
   - What we know: CONTEXT.md says include headers in errors
   - What's unclear: Which headers are meaningful (rate limit, retry-after?)
   - Recommendation: Include all headers, let users filter

3. **Limitation Tracking Mechanism**
   - What we know: Per CONTEXT.md, Claude's discretion
   - Options: GitHub issues, roadmap file, limitation dashboard
   - Recommendation: GitHub issues with "sdk-limitation" label for visibility

## Sources

### Primary (HIGH confidence)

- `src/clients/go/pkg/errors/main.go` - Go error types and helper functions
- `src/clients/go/pkg/errors/distributed_errors.go` - Complete error code definitions
- `src/clients/go/pkg/retry/retry.go` - Retry implementation reference
- `src/clients/node/src/errors.ts` - Node.js error types and type guards
- `src/clients/java/src/main/java/com/archerdb/geo/RetryPolicy.java` - Java retry
- `src/clients/java/src/main/java/com/archerdb/geo/OperationException.java` - Java errors
- `src/clients/zig/errors.zig` - Zig error types
- `src/clients/c/arch_client_errors.h` - C error codes and helpers
- `src/clients/python/src/archerdb/client.py` - Python error classes (first 200 lines)
- `src/clients/test-data/wire-format-test-cases.json` - Canonical error codes

### Secondary (MEDIUM confidence)

- `.planning/phases/13-sdk-operation-test-suite/13-RESEARCH.md` - SDK test patterns
- `test_infrastructure/fixtures/v1/*.json` - Operation fixture structure
- `src/clients/zig/tests/integration/all_operations_test.zig` - Cross-operation test pattern

### Tertiary (LOW confidence)

- General cross-language testing best practices
- Exponential backoff algorithm variations

## Metadata

**Confidence breakdown:**
- Error code standardization: HIGH - Verified in all 6 SDK source files
- Retry policy consistency: HIGH - All SDKs implement same backoff schedule
- Parity testing patterns: MEDIUM - Based on CONTEXT.md decisions + standard practices
- Edge case coverage: MEDIUM - Curated list from CONTEXT.md, may need expansion

**Research date:** 2026-02-01
**Valid until:** 2026-03-01 (30 days - stable domain)

---

## SDK Error Handling Summary

| SDK | Error Base | Code Access | Retryable Access | Message Access | Category Helpers |
|-----|------------|-------------|------------------|----------------|------------------|
| Python | `ArcherDBError` | `.code` | `.retryable` | `str(e)` | `isinstance()` |
| Node.js | `ArcherDBError` | `.code` | `.retryable` | `.message` | `isNetworkError()` etc |
| Go | `GeoError` | `.Code()` | `.Retryable()` | `.Error()` | `IsRetryableError()` etc |
| Java | `ArcherDBException` | `.getErrorCode()` | `.isRetryable()` | `.getMessage()` | `instanceof` |
| C | `int` | Direct | `arch_error_is_retryable()` | `arch_error_message()` | `arch_error_is_*()` |
| Zig | `ClientError` | `errorCode()` | `isRetryable()` | `errorMessage()` | `isNetworkError()` etc |

**Parity Verification Matrix Dimensions:**
- 14 operations x 6 SDKs = 84 cells
- Error categories: Connection (2), Validation (4), State (2), Resource (10+), Sharding (5), Encryption (5)
- Geographic edge cases: Polar (2), Antimeridian (2), Zero crossings (2) = 6 minimum
