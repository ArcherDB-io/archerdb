---
phase: 13-sdk-operation-test-suite
plan: 01
subsystem: testing
tags: [python-sdk, node-sdk, integration-testing, fixtures, pytest, jest]

dependency-graph:
  requires:
    - "11-01": "Test fixtures for all 14 operations"
    - "11-02": "Test infrastructure harness (ArcherDBCluster)"
  provides:
    - "SDK test runner infrastructure"
    - "Python SDK operation tests (24 tests, 14 operations)"
    - "Node.js SDK operation tests (24 tests, 14 operations)"
  affects:
    - "13-02": "Go SDK tests (pattern established)"
    - "13-03": "Java SDK tests (pattern established)"
    - "13-04": "C SDK tests (pattern established)"
    - "14-xx": "Error handling tests (extends this infrastructure)"

tech-stack:
  added:
    - "deepdiff (Python, optional for verbose diff)"
    - "jest 29.x (Node.js test runner)"
    - "ts-jest 29.x (TypeScript support)"
  patterns:
    - "Fixture-driven testing via shared JSON"
    - "Fresh database per test for isolation"
    - "Python harness for cluster lifecycle"

key-files:
  created:
    - "tests/sdk_tests/run_sdk_tests.sh"
    - "tests/sdk_tests/common/__init__.py"
    - "tests/sdk_tests/common/fixture_adapter.py"
    - "tests/sdk_tests/python/__init__.py"
    - "tests/sdk_tests/python/conftest.py"
    - "tests/sdk_tests/python/test_all_operations.py"
    - "tests/sdk_tests/node/package.json"
    - "tests/sdk_tests/node/tsconfig.json"
    - "tests/sdk_tests/node/jest.config.js"
    - "tests/sdk_tests/node/fixture_adapter.ts"
    - "tests/sdk_tests/node/test_all_operations.ts"
  modified: []

decisions:
  - id: "fixture-adapter-pattern"
    choice: "Wrap Phase 11 fixture_loader rather than duplicate"
    rationale: "Single source of truth, consistent loading across SDKs"
  - id: "python-harness-for-node"
    choice: "Node.js tests spawn Python subprocess for cluster management"
    rationale: "Reuses existing harness, avoids duplicating cluster code in JS"
  - id: "test-organization"
    choice: "One test class per operation with multiple test cases"
    rationale: "Clear organization, easy CI reporting, matches fixture structure"

metrics:
  duration: "5 min"
  completed: "2026-02-01"
---

# Phase 13 Plan 01: Python/Node SDK Tests Summary

SDK test infrastructure and comprehensive operation tests for Python and Node.js SDKs.

## One-liner

Unified test runner with fixture adapter plus 48 tests (24 Python, 24 Node.js) covering all 14 operations.

## What Was Built

### 1. Test Infrastructure (Task 1)

**Unified Test Runner (`tests/sdk_tests/run_sdk_tests.sh`):**
- Executable bash script orchestrating tests for all 5 SDKs
- Builds ArcherDB with `-j4 -Dconfig=lite` before tests
- Sequential SDK execution (Python, Node, Go, Java, C)
- Color-coded output with pass/fail/skip counts
- Fail-fast behavior per CONTEXT.md decision
- Supports `--filter=sdk1,sdk2` for selective testing

**Fixture Adapter (`tests/sdk_tests/common/fixture_adapter.py`):**
- Wraps Phase 11 `test_infrastructure.fixtures.fixture_loader`
- `load_operation_fixture(operation)` - load any of 14 fixtures
- `convert_fixture_events()` - fixture format to SDK format
- `setup_test_data()` - handles `insert_first`, `insert_first_range`
- `assert_json_match()` - verbose diff output via deepdiff
- `verify_events_contain()`, `verify_count_in_range()` - result helpers

### 2. Python SDK Tests (Task 2)

**pytest Configuration (`conftest.py`):**
- Module-scoped `cluster` fixture - starts single-node ArcherDB
- Function-scoped `client` fixture - GeoClientSync connection
- Autouse `clean_database` fixture - fresh DB per test
- Skip handling when `ARCHERDB_INTEGRATION != "1"`

**Operation Tests (`test_all_operations.py`):**
14 test classes, 24 test cases total:

| Operation | Test Class | Test Cases |
|-----------|-----------|------------|
| insert | TestInsertOperation | 3 |
| upsert | TestUpsertOperation | 2 |
| delete | TestDeleteOperation | 2 |
| query-uuid | TestQueryUuidOperation | 2 |
| query-uuid-batch | TestQueryUuidBatchOperation | 2 |
| query-radius | TestQueryRadiusOperation | 3 |
| query-polygon | TestQueryPolygonOperation | 2 |
| query-latest | TestQueryLatestOperation | 2 |
| ping | TestPingOperation | 1 |
| status | TestStatusOperation | 1 |
| ttl-set | TestTtlSetOperation | 1 |
| ttl-extend | TestTtlExtendOperation | 1 |
| ttl-clear | TestTtlClearOperation | 1 |
| topology | TestTopologyOperation | 1 |

### 3. Node.js SDK Tests (Task 3)

**Jest/TypeScript Configuration:**
- `package.json` - jest 29.x, ts-jest, typescript 5.x
- `tsconfig.json` - ES2022 target, NodeNext module
- `jest.config.js` - ts-jest preset, 2min timeout

**TypeScript Fixture Adapter (`fixture_adapter.ts`):**
- Same interface as Python adapter
- `loadFixture()`, `getCaseByName()`, `filterCasesByTag()`
- `convertEvents()` - handles BigInt entity_id conversion
- `generateEntityId()` - crypto-based unique ID generation

**Operation Tests (`test_all_operations.ts`):**
14 describe blocks, 24 test cases total, matching Python structure.

Cluster management via Python harness subprocess:
```typescript
const proc = spawn('python3', ['-c', `
  from test_infrastructure.harness import ArcherDBCluster...
`]);
```

## Test Execution

**Python tests:**
```bash
cd /home/g/archerdb
ARCHERDB_INTEGRATION=1 pytest tests/sdk_tests/python/test_all_operations.py -v
```

**Node.js tests:**
```bash
cd tests/sdk_tests/node
npm install
ARCHERDB_INTEGRATION=1 npm test
```

**Both via runner:**
```bash
./tests/sdk_tests/run_sdk_tests.sh --filter=python,node
```

## Deviations from Plan

### Auto-fixed Issues

None - plan executed exactly as written.

## Verification Results

| Check | Status |
|-------|--------|
| run_sdk_tests.sh executable | PASS |
| fixture_adapter loads insert.json | PASS |
| Python test collection (24 tests) | PASS |
| Node.js test file found by Jest | PASS |
| Both SDKs cover all 14 operations | PASS |

## Commits

| Hash | Type | Description |
|------|------|-------------|
| 5f08ef0 | feat | Add SDK test infrastructure and fixture adapter |
| 61d67fa | feat | Add Python SDK tests for all 14 operations |
| 0bbe71f | feat | Add Node.js SDK tests for all 14 operations |

## Key Patterns Established

1. **Fixture-driven testing:** All tests load from `test_infrastructure/fixtures/v1/*.json`
2. **Fresh database per test:** Autouse fixture deletes all entities before each test
3. **Server per SDK:** Cluster started once per test module (Python) or test suite (Node.js)
4. **Cross-SDK fixture adapter:** Language-specific adapter wraps common fixture loader
5. **Verbose diff output:** `deepdiff` integration for clear failure messages

## Next Steps

- 13-02: Apply same pattern to Go SDK tests
- 13-03: Apply same pattern to Java SDK tests
- 13-04: Apply same pattern to C SDK tests
- Run full integration test once server is running:
  ```bash
  ARCHERDB_INTEGRATION=1 ./tests/sdk_tests/run_sdk_tests.sh --filter=python,node
  ```
