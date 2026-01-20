# SDK Error Code Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix critical and important SDK issues identified in code review to ensure Python and Go SDKs match Zig core definitions.

**Architecture:** Direct fixes to Python types.py, Python errors.py, and Go distributed_errors.go to align with Zig core error_codes.zig and geo_state_machine.zig definitions.

**Tech Stack:** Python, Go, Zig (reference only)

---

## Summary of Issues

| Priority | Issue | File | Problem |
|----------|-------|------|---------|
| Critical | TTL_SET missing | types.py:82 | Comment syntax error |
| Critical | Missing enum value | types.py:119 | InsertGeoEventResult missing value 16 |
| Critical | Missing enum value | types.py:131 | DeleteEntityResult missing value 4 |
| Important | Error code 217 mismatch | Go/Python | SDKs say RegionConfigMismatch, Zig says conflict_detected |
| Important | Error code 218 mismatch | Go/Python | SDKs say UnknownRegion, Zig says geo_shard_mismatch |

---

### Task 1: Fix Python TTL_SET Operation Code

**Files:**
- Modify: `src/clients/python/src/archerdb/types.py:82`

**Step 1: Fix the comment syntax error**

The line currently reads:
```python
    # Manual TTL Operations     TTL_SET = 158          # vsr_operations_reserved (128) + 30
```

Change to:
```python
    # Manual TTL Operations
    TTL_SET = 158          # vsr_operations_reserved (128) + 30
```

**Step 2: Verify the fix**

Run: `python3 -c "from archerdb.types import GeoOperation; print(GeoOperation.TTL_SET)"`
Expected: `GeoOperation.TTL_SET: 158`

**Step 3: Commit**

```bash
git add src/clients/python/src/archerdb/types.py
git commit -m "fix(python): restore TTL_SET operation code definition"
```

---

### Task 2: Add Missing InsertGeoEventResult Enum Value

**Files:**
- Modify: `src/clients/python/src/archerdb/types.py:119`

**Step 1: Add ENTITY_ID_MUST_NOT_BE_INT_MAX = 16**

After line 119 (`TTL_INVALID = 15`), add:
```python
    ENTITY_ID_MUST_NOT_BE_INT_MAX = 16
```

**Step 2: Verify the fix**

Run: `python3 -c "from archerdb.types import InsertGeoEventResult; print(InsertGeoEventResult.ENTITY_ID_MUST_NOT_BE_INT_MAX)"`
Expected: `InsertGeoEventResult.ENTITY_ID_MUST_NOT_BE_INT_MAX: 16`

**Step 3: Commit**

```bash
git add src/clients/python/src/archerdb/types.py
git commit -m "fix(python): add missing ENTITY_ID_MUST_NOT_BE_INT_MAX to InsertGeoEventResult"
```

---

### Task 3: Add Missing DeleteEntityResult Enum Value

**Files:**
- Modify: `src/clients/python/src/archerdb/types.py:131`

**Step 1: Add ENTITY_ID_MUST_NOT_BE_INT_MAX = 4**

After line 130 (`ENTITY_NOT_FOUND = 3`), add:
```python
    ENTITY_ID_MUST_NOT_BE_INT_MAX = 4
```

**Step 2: Verify the fix**

Run: `python3 -c "from archerdb.types import DeleteEntityResult; print(DeleteEntityResult.ENTITY_ID_MUST_NOT_BE_INT_MAX)"`
Expected: `DeleteEntityResult.ENTITY_ID_MUST_NOT_BE_INT_MAX: 4`

**Step 3: Commit**

```bash
git add src/clients/python/src/archerdb/types.py
git commit -m "fix(python): add missing ENTITY_ID_MUST_NOT_BE_INT_MAX to DeleteEntityResult"
```

---

### Task 4: Fix Go SDK Error Code 217/218 Naming

**Files:**
- Modify: `src/clients/go/pkg/errors/distributed_errors.go:29-32`

**Step 1: Rename constants to match Zig core**

Change:
```go
	// RegionConfigMismatch indicates region configuration does not match cluster topology.
	RegionConfigMismatch ErrorCode = 217

	// UnknownRegion indicates unknown region specified in request.
	UnknownRegion ErrorCode = 218
```

To:
```go
	// ConflictDetected indicates write conflict detected in active-active replication.
	ConflictDetected ErrorCode = 217

	// GeoShardMismatch indicates entity geo-shard does not match target region.
	GeoShardMismatch ErrorCode = 218
```

**Step 2: Update error messages map**

Change:
```go
	RegionConfigMismatch: "Region configuration does not match cluster topology",
	UnknownRegion:        "Unknown region specified in request",
```

To:
```go
	ConflictDetected:  "Write conflict detected in active-active replication",
	GeoShardMismatch:  "Entity geo-shard does not match target region",
```

**Step 3: Update retryable map**

Change:
```go
	RegionConfigMismatch: false,
	UnknownRegion:        false,
```

To:
```go
	ConflictDetected:  false,
	GeoShardMismatch:  false,
```

**Step 4: Run Go tests**

Run: `cd src/clients/go && go test ./pkg/errors/...`
Expected: PASS

**Step 5: Commit**

```bash
git add src/clients/go/pkg/errors/distributed_errors.go
git commit -m "fix(go): align error codes 217/218 with Zig core naming"
```

---

### Task 5: Fix Python SDK Error Code 217/218 Naming

**Files:**
- Modify: `src/clients/python/src/archerdb/errors.py:90-94`

**Step 1: Rename constants to match Zig core**

Change:
```python
    REGION_CONFIG_MISMATCH = 217
    """Region configuration does not match cluster topology."""

    UNKNOWN_REGION = 218
    """Unknown region specified in request."""
```

To:
```python
    CONFLICT_DETECTED = 217
    """Write conflict detected in active-active replication."""

    GEO_SHARD_MISMATCH = 218
    """Entity geo-shard does not match target region."""
```

**Step 2: Update error messages dictionary**

Change:
```python
    MultiRegionError.REGION_CONFIG_MISMATCH: "Region configuration does not match cluster topology",
    MultiRegionError.UNKNOWN_REGION: "Unknown region specified in request",
```

To:
```python
    MultiRegionError.CONFLICT_DETECTED: "Write conflict detected in active-active replication",
    MultiRegionError.GEO_SHARD_MISMATCH: "Entity geo-shard does not match target region",
```

**Step 3: Update retryable dictionary**

Change:
```python
    MultiRegionError.REGION_CONFIG_MISMATCH: False,
    MultiRegionError.UNKNOWN_REGION: False,
```

To:
```python
    MultiRegionError.CONFLICT_DETECTED: False,
    MultiRegionError.GEO_SHARD_MISMATCH: False,
```

**Step 4: Run Python tests**

Run: `cd src/clients/python && python3 -m pytest tests/test_distributed_errors.py -v`
Expected: PASS (or update tests if they reference old names)

**Step 5: Commit**

```bash
git add src/clients/python/src/archerdb/errors.py
git commit -m "fix(python): align error codes 217/218 with Zig core naming"
```

---

### Task 6: Update Python Distributed Errors Test

**Files:**
- Modify: `src/clients/python/tests/test_distributed_errors.py`

**Step 1: Update test assertions for renamed error codes**

Find and replace any references to:
- `REGION_CONFIG_MISMATCH` → `CONFLICT_DETECTED`
- `UNKNOWN_REGION` → `GEO_SHARD_MISMATCH`

**Step 2: Run tests**

Run: `cd src/clients/python && python3 -m pytest tests/test_distributed_errors.py -v`
Expected: PASS

**Step 3: Commit**

```bash
git add src/clients/python/tests/test_distributed_errors.py
git commit -m "test(python): update tests for renamed error codes 217/218"
```

---

### Task 7: Update Go Distributed Errors Test

**Files:**
- Modify: `src/clients/go/pkg/errors/distributed_errors_test.go`

**Step 1: Update test assertions for renamed error codes**

Find and replace any references to:
- `RegionConfigMismatch` → `ConflictDetected`
- `UnknownRegion` → `GeoShardMismatch`

**Step 2: Run tests**

Run: `cd src/clients/go && go test ./pkg/errors/... -v`
Expected: PASS

**Step 3: Commit**

```bash
git add src/clients/go/pkg/errors/distributed_errors_test.go
git commit -m "test(go): update tests for renamed error codes 217/218"
```

---

### Task 8: Run Full Test Suite and Verify

**Step 1: Run Zig unit tests for error codes**

Run: `./zig/zig build test:unit -- --test-filter "error_codes"`
Expected: PASS

**Step 2: Run Python SDK tests**

Run: `cd src/clients/python && python3 -m pytest tests/ -v`
Expected: PASS

**Step 3: Run Go SDK tests**

Run: `cd src/clients/go && go test ./... -v`
Expected: PASS

**Step 4: Run build check**

Run: `./zig/zig build`
Expected: Build succeeds

---

## Verification Checklist

- [ ] Python GeoOperation.TTL_SET = 158 is defined
- [ ] Python InsertGeoEventResult has ENTITY_ID_MUST_NOT_BE_INT_MAX = 16
- [ ] Python DeleteEntityResult has ENTITY_ID_MUST_NOT_BE_INT_MAX = 4
- [ ] Go error 217 is named ConflictDetected (matches Zig conflict_detected)
- [ ] Go error 218 is named GeoShardMismatch (matches Zig geo_shard_mismatch)
- [ ] Python error 217 is named CONFLICT_DETECTED
- [ ] Python error 218 is named GEO_SHARD_MISMATCH
- [ ] All tests pass
- [ ] Build succeeds
