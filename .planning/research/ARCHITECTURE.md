# Architecture Research: SDK Testing and Benchmarking Infrastructure

**Domain:** Multi-SDK Testing Infrastructure for Database
**Researched:** 2026-02-01
**Confidence:** HIGH

## Executive Summary

This document defines the architecture for comprehensive SDK testing and benchmarking infrastructure for ArcherDB. The architecture builds upon the existing monorepo structure with SDK clients in `src/clients/{python,node,go,java,c}/` and the established CI/CD pipeline in GitHub Actions. The design prioritizes maintainability through clear separation of concerns, scalability through matrix-based parallel execution, and resource efficiency through tiered test execution.

## System Overview

```
+-------------------------------------------------------------------------+
|                           CI/CD Layer (GitHub Actions)                   |
|  +------------------+  +-------------------+  +------------------------+ |
|  |  PR Checks       |  |  Nightly Suite    |  |  Benchmark Pipeline    | |
|  |  (fast, focused) |  |  (comprehensive)  |  |  (isolated, accurate)  | |
|  +--------+---------+  +---------+---------+  +-----------+------------+ |
|           |                      |                        |              |
+-----------+----------------------+------------------------+--------------+
            |                      |                        |
            v                      v                        v
+-------------------------------------------------------------------------+
|                        Test Orchestration Layer                          |
|  +------------------------------------------------------------------+   |
|  |  tests/sdk/                                                       |   |
|  |  +------------------+  +------------------+  +------------------+ |   |
|  |  | shared/          |  | integration/     |  | compatibility/   | |   |
|  |  | - fixtures       |  | - cross-sdk      |  | - protocol       | |   |
|  |  | - data-gen       |  | - scenarios      |  | - wire-format    | |   |
|  |  | - assertions     |  | - cluster-ops    |  | - version-compat | |   |
|  |  +------------------+  +------------------+  +------------------+ |   |
|  +------------------------------------------------------------------+   |
+-----------+----------------------+------------------------+--------------+
            |                      |                        |
            v                      v                        v
+-------------------------------------------------------------------------+
|                        SDK-Specific Test Layer                           |
|  +------------+  +------------+  +------------+  +------------+  +---+  |
|  | python/    |  | node/      |  | go/        |  | java/      |  | c/|  |
|  | tests/     |  | src/       |  | *_test.go  |  | src/test/  |  |   |  |
|  +------------+  +------------+  +------------+  +------------+  +---+  |
+-----------+----------------------+------------------------+--------------+
            |                      |                        |
            v                      v                        v
+-------------------------------------------------------------------------+
|                        Test Infrastructure Layer                         |
|  +------------------+  +------------------+  +------------------+        |
|  | Server Harness   |  | Data Generation  |  | Results Storage  |        |
|  | - 1/3/6 node     |  | - canonical sets |  | - JSON artifacts |        |
|  | - topology mgmt  |  | - random gen     |  | - trend tracking |        |
|  | - health checks  |  | - edge cases     |  | - regression db  |        |
|  +------------------+  +------------------+  +------------------+        |
+-------------------------------------------------------------------------+
            |
            v
+-------------------------------------------------------------------------+
|                        ArcherDB Server(s)                                |
|  +------------+  +------------+  +------------+                         |
|  | Replica 0  |  | Replica 1  |  | Replica 2  | ... up to 6 nodes       |
|  +------------+  +------------+  +------------+                         |
+-------------------------------------------------------------------------+
```

## Recommended Project Structure

```
archerdb/
├── src/clients/
│   ├── python/
│   │   ├── src/                    # SDK source code
│   │   ├── tests/                  # Unit & integration tests (pytest)
│   │   │   ├── conftest.py         # Fixtures, server connection
│   │   │   ├── test_unit_*.py      # Pure unit tests (no server)
│   │   │   └── test_integration_*.py  # Server-required tests
│   │   ├── benchmark.py            # SDK-specific benchmarks
│   │   └── pyproject.toml
│   │
│   ├── node/
│   │   ├── src/                    # SDK source code
│   │   ├── __tests__/              # Jest tests (new directory)
│   │   │   ├── unit/               # Pure unit tests
│   │   │   └── integration/        # Server-required tests
│   │   ├── benchmark.ts            # SDK-specific benchmarks
│   │   └── package.json
│   │
│   ├── go/
│   │   ├── *.go                    # SDK source code
│   │   ├── *_unit_test.go          # Pure unit tests
│   │   ├── *_integration_test.go   # Server-required tests
│   │   └── benchmark_test.go       # SDK-specific benchmarks
│   │
│   ├── java/
│   │   ├── src/main/java/          # SDK source code
│   │   ├── src/test/java/          # JUnit tests (existing)
│   │   │   └── com/archerdb/
│   │   │       ├── unit/           # Pure unit tests
│   │   │       └── integration/    # Server-required tests
│   │   └── pom.xml
│   │
│   ├── c/
│   │   ├── arch_client.h           # SDK header
│   │   ├── test.zig                # Zig test harness (existing)
│   │   └── tests/                  # C test files (new)
│   │
│   └── test-data/
│       ├── wire-format-test-cases.json  # Cross-SDK protocol tests
│       ├── canonical-events.json        # Shared test fixtures
│       ├── edge-cases.json             # Boundary conditions
│       └── regression-data/            # Known bug reproduction
│
├── tests/
│   └── sdk/                        # Centralized integration tests (NEW)
│       ├── README.md               # Test suite documentation
│       ├── shared/
│       │   ├── fixtures/           # Language-agnostic test data
│       │   │   ├── small-dataset.json      # 100 events
│       │   │   ├── medium-dataset.json     # 10K events
│       │   │   └── large-dataset.json      # 1M events (generated)
│       │   ├── scenarios/          # Test scenario definitions
│       │   │   ├── basic-crud.yaml
│       │   │   ├── concurrent-access.yaml
│       │   │   ├── failure-recovery.yaml
│       │   │   └── cluster-operations.yaml
│       │   └── assertions/         # Expected result definitions
│       │       └── expected-results.json
│       │
│       ├── integration/            # Cross-SDK integration tests
│       │   ├── run-all.sh          # Master test runner
│       │   ├── python/             # Python harness for scenarios
│       │   ├── node/               # Node harness for scenarios
│       │   ├── go/                 # Go harness for scenarios
│       │   ├── java/               # Java harness for scenarios
│       │   └── curl/               # Raw protocol tests (HTTP API)
│       │
│       ├── compatibility/          # Wire format & version tests
│       │   ├── protocol-tests.sh   # Binary protocol verification
│       │   └── version-matrix.yaml # SDK version compatibility
│       │
│       └── harness/                # Test infrastructure
│           ├── server-manager.sh   # Start/stop/health check
│           ├── cluster-configs/    # 1/3/6 node configurations
│           │   ├── single-node.yaml
│           │   ├── three-node.yaml
│           │   └── six-node.yaml
│           └── data-generator.py   # Generate test datasets
│
├── benchmarks/                     # Centralized benchmark suite (NEW)
│   ├── README.md                   # Benchmark documentation
│   ├── config/
│   │   ├── quick.yaml              # CI mode (~30s)
│   │   ├── standard.yaml           # PR mode (~5min)
│   │   └── full.yaml               # Release mode (~30min)
│   │
│   ├── scenarios/
│   │   ├── insert-throughput/      # PERF-01 scenarios
│   │   ├── query-latency/          # PERF-02-05 scenarios
│   │   └── cluster-scaling/        # Multi-node benchmarks
│   │
│   ├── runners/
│   │   ├── python-bench.py         # Python SDK benchmarks
│   │   ├── node-bench.ts           # Node SDK benchmarks
│   │   ├── go-bench.go             # Go SDK benchmarks
│   │   └── java-bench/             # Java SDK benchmarks
│   │
│   ├── results/                    # Historical results (git-tracked)
│   │   └── baseline.json           # Current baseline
│   │
│   └── analysis/
│       ├── compare.py              # Regression detection
│       └── visualize.py            # Generate charts
│
├── scripts/
│   ├── test-clients.sh             # Existing SDK test runner
│   ├── benchmark-ci.sh             # Existing CI benchmark script
│   ├── e2e-test.sh                 # Existing E2E test script
│   └── run-sdk-tests.sh            # New: unified SDK test runner
│
└── .github/
    └── workflows/
        ├── ci.yml                  # Existing: PR checks + SDK tests
        ├── benchmark.yml           # Existing: Performance benchmarks
        ├── vopr.yml                # Existing: Nightly fuzzing
        └── sdk-nightly.yml         # New: Comprehensive SDK suite
```

### Structure Rationale

- **SDK-specific tests in `src/clients/*/`**: Each SDK maintains its own tests using idiomatic tooling (pytest, Jest, go test, JUnit). This allows SDK maintainers to work independently and use familiar patterns.

- **Centralized integration tests in `tests/sdk/`**: Cross-SDK scenarios, shared fixtures, and compatibility tests live together. This ensures consistency across SDKs and enables shared test data.

- **Benchmarks in `benchmarks/`**: Isolated from tests to enable different execution policies. Benchmarks are resource-intensive and run on dedicated hardware or scheduled times.

- **Shared test data in `src/clients/test-data/`**: Wire format definitions and canonical test cases shared across all SDKs. This is the source of truth for protocol compatibility.

## Architectural Patterns

### Pattern 1: Tiered Test Execution

**What:** Different test scopes run at different frequencies based on resource requirements and feedback needs.

**When to use:** Always. This is fundamental to balancing fast feedback with comprehensive coverage.

**Trade-offs:**
- Pro: Fast PR feedback (~5 min for smoke tests)
- Pro: Comprehensive nightly coverage catches edge cases
- Con: Bugs might slip through until nightly run
- Con: More complex CI configuration

**Implementation:**

| Tier | Trigger | Tests | Duration | Resources |
|------|---------|-------|----------|-----------|
| Smoke | Every push | Unit tests + basic integration | 5-10 min | 1 node |
| PR | PR created/updated | SDK tests (single node) | 15-20 min | 1 node |
| Nightly | Scheduled (2 AM UTC) | Full suite (3-6 nodes) | 1-2 hours | 6 nodes |
| Benchmark | Main merge + nightly | Performance regression | 30 min | Dedicated |

```yaml
# Example CI workflow structure
jobs:
  # Tier 1: Every push
  smoke:
    runs-on: ubuntu-latest
    steps:
      - run: ./zig/zig build -j4 -Dconfig=lite test:unit

  # Tier 2: PR checks (SDK tests run in parallel)
  sdk-tests:
    needs: smoke
    strategy:
      matrix:
        sdk: [python, node, go, java]
    runs-on: ubuntu-latest
    steps:
      - run: ./scripts/run-sdk-tests.sh ${{ matrix.sdk }}

  # Tier 3: Nightly (comprehensive)
  nightly-full:
    if: github.event_name == 'schedule'
    steps:
      - run: ./scripts/run-sdk-tests.sh --all --cluster-size=6
```

### Pattern 2: Matrix-Based SDK Testing

**What:** Use GitHub Actions matrix strategy to run SDK tests in parallel across languages, operating systems, and configurations.

**When to use:** For SDK tests that can run independently.

**Trade-offs:**
- Pro: Parallel execution reduces total CI time
- Pro: Easy to add new SDKs or configurations
- Con: More GitHub Actions minutes consumed
- Con: Debugging matrix failures can be confusing

**Implementation:**

```yaml
test-sdk:
  strategy:
    fail-fast: false  # Continue other SDKs on failure
    matrix:
      sdk: [python, node, go, java, c]
      include:
        - sdk: python
          setup: actions/setup-python@v5
          version: '3.11'
          test-cmd: pytest tests/ -v
        - sdk: node
          setup: actions/setup-node@v4
          version: '20'
          test-cmd: npm test
        - sdk: go
          setup: actions/setup-go@v5
          version: '1.21'
          test-cmd: go test ./... -v
        - sdk: java
          setup: actions/setup-java@v4
          version: '21'
          test-cmd: mvn test -q
```

### Pattern 3: Shared Test Fixture Pattern

**What:** Define test data once in a language-agnostic format (JSON/YAML), consume from all SDKs.

**When to use:** For cross-SDK compatibility testing and ensuring consistent behavior.

**Trade-offs:**
- Pro: Single source of truth for expected behavior
- Pro: Easy to add new test cases across all SDKs
- Con: SDKs need parsing code for fixture format
- Con: Complex scenarios may be awkward in JSON

**Implementation:**

```json
// src/clients/test-data/canonical-events.json
{
  "test_cases": [
    {
      "name": "insert_basic_event",
      "operation": "INSERT_EVENTS",
      "input": {
        "events": [{
          "entity_id": "12345678-1234-1234-1234-123456789abc",
          "latitude": 37.7749,
          "longitude": -122.4194,
          "ttl_seconds": 3600
        }]
      },
      "expected": {
        "success": true,
        "result_codes": [0]
      }
    }
  ]
}
```

### Pattern 4: Server Harness Abstraction

**What:** Abstract server lifecycle (start, stop, health check) into a reusable harness that all tests use.

**When to use:** For any integration test requiring a running server.

**Trade-offs:**
- Pro: Consistent server setup across all tests
- Pro: Easy to test different cluster topologies
- Con: Additional complexity layer
- Con: Harness bugs affect all tests

**Implementation:**

```bash
# tests/sdk/harness/server-manager.sh
#!/usr/bin/env bash

start_cluster() {
    local size="${1:-1}"  # Default to single node
    local config="tests/sdk/harness/cluster-configs/${size}-node.yaml"
    # ... start replicas based on config
}

wait_healthy() {
    local timeout="${1:-60}"
    for i in $(seq 1 $timeout); do
        if curl -sf "http://127.0.0.1:9100/health/ready" > /dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

stop_cluster() {
    # ... graceful shutdown
}
```

## Data Flow

### Test Execution Flow

```
Developer Push / PR
        |
        v
+-------------------+
| CI Trigger        |
| (GitHub Actions)  |
+--------+----------+
         |
         v
+-------------------+
| Smoke Tests       |-----> FAIL? --> Block merge
| (unit tests only) |
+--------+----------+
         | PASS
         v
+-------------------+     +-------------------+
| Build Server      |---->| Build SDK         |
| (zig build)       |     | (per-language)    |
+--------+----------+     +--------+----------+
         |                         |
         v                         v
+-------------------+     +-------------------+
| Start Test Server |     | SDK Unit Tests    |
| (single node)     |     | (no server)       |
+--------+----------+     +--------+----------+
         |                         |
         +------------+------------+
                      |
                      v
         +-------------------+
         | SDK Integration   |
         | Tests (per SDK)   |
         +--------+----------+
                  |
                  v
         +-------------------+
         | Cross-SDK Tests   |
         | (optional, nightly)|
         +--------+----------+
                  |
                  v
         +-------------------+
         | Results & Reports |
         | (artifacts)       |
         +-------------------+
```

### Benchmark Data Flow

```
Main Branch Merge / Nightly Schedule
        |
        v
+------------------------+
| Build Release Binary   |
| (zig build -Drelease)  |
+----------+-------------+
           |
           v
+------------------------+
| Start Benchmark Server |
| (dedicated resources)  |
+----------+-------------+
           |
           v
+------------------------+
| Run Benchmark Suite    |
| (configurable mode)    |
+----------+-------------+
           |
           v
+------------------------+
| Collect Results        |
| (JSON format)          |
+----------+-------------+
           |
           +---------+---------+
           |                   |
           v                   v
+------------------+  +------------------+
| Compare Baseline |  | Store as New     |
| (PRs)            |  | Baseline (main)  |
+--------+---------+  +------------------+
         |
    +----+----+
    |         |
  PASS      FAIL
    |         |
    v         v
  Merge    Block + Report
```

### Key Data Flows

1. **Test Fixture Flow**: `test-data/` -> SDK test runner -> assertions
2. **Result Flow**: Test execution -> JSON results -> GitHub artifacts -> trend analysis
3. **Baseline Flow**: Main branch benchmark -> baseline artifact -> PR comparison

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| 1-3 SDKs | Current structure works well. Single CI workflow. |
| 4-6 SDKs | Matrix builds essential. Consider dedicated runners for heavy SDKs (Java). |
| 7+ SDKs | Split into multiple workflows. Consider self-hosted runners for cost control. |
| 100K+ test cases | Parallelize within SDKs. Test sharding. Incremental test selection. |

### Scaling Priorities

1. **First bottleneck: CI time**
   - Add matrix parallelization (currently in place)
   - Use caching aggressively (dependency caches per SDK)
   - Implement test sharding for large test suites

2. **Second bottleneck: Resource contention**
   - Dedicated benchmark runners (avoid noisy neighbors)
   - Queue-based test scheduling for expensive multi-node tests
   - Consider self-hosted runners for predictable performance

3. **Third bottleneck: Maintenance burden**
   - Shared test fixtures reduce duplication
   - Unified reporting across SDKs
   - Automated dependency updates per SDK

## Anti-Patterns

### Anti-Pattern 1: Monolithic Test Suite

**What people do:** All tests for all SDKs in a single massive workflow that must pass entirely.

**Why it's wrong:**
- One flaky test blocks all SDKs
- No partial feedback (all-or-nothing)
- Hard to debug which SDK failed

**Do this instead:** Matrix-based parallel execution with independent pass/fail status per SDK.

### Anti-Pattern 2: Benchmark on Shared CI Runners

**What people do:** Run performance benchmarks on GitHub Actions default runners alongside other jobs.

**Why it's wrong:**
- Results are noisy and inconsistent
- Other jobs affect benchmark results
- Hard to establish reliable baseline

**Do this instead:**
- Use dedicated self-hosted runners for benchmarks
- Or use GitHub's larger runners with isolation
- Run benchmarks at off-peak times (nightly)
- Accept higher variance thresholds (5% throughput, 25% P99 latency)

### Anti-Pattern 3: SDK-Specific Test Data

**What people do:** Each SDK maintains its own test fixtures with subtly different values.

**Why it's wrong:**
- SDKs may pass tests but behave inconsistently
- Wire format bugs go undetected
- Maintenance nightmare keeping data in sync

**Do this instead:** Single source of truth in `test-data/` with JSON fixtures consumed by all SDKs.

### Anti-Pattern 4: Running 6-Node Tests on Every PR

**What people do:** Full cluster tests run on every push for "completeness."

**Why it's wrong:**
- Slow feedback (20+ minutes for cluster setup)
- Resource intensive (6x the compute)
- Diminishing returns vs single-node tests

**Do this instead:** Tiered execution. Single-node for PRs, multi-node for nightly.

### Anti-Pattern 5: Hard-Coded Server Addresses

**What people do:** Tests have `127.0.0.1:3001` hard-coded throughout.

**Why it's wrong:**
- Can't run parallel test suites (port conflicts)
- Can't test against remote servers
- Breaks when topology changes

**Do this instead:** Environment variables (`ARCHERDB_HOST`, `ARCHERDB_PORT`) with sensible defaults.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| GitHub Actions | Workflow YAML | Matrix builds, caching, artifacts |
| MinIO (S3-compatible) | Service container | Integration tests for replication |
| Codecov | Upload artifact | Test coverage reporting |
| benchmark-action | GitHub Action | Performance tracking, alerts |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| SDK tests <-> Server | TCP + Health HTTP | Use `wait_healthy` pattern |
| Test runner <-> Fixtures | File system | JSON/YAML parsing |
| CI <-> Results | Artifacts | JSON results uploaded |
| Benchmark <-> Baseline | Artifacts | 90-day retention |

## CI Integration Strategy

### What Runs When

| Event | Tests Executed | Duration Target |
|-------|---------------|-----------------|
| Push to branch | Smoke (build + unit) | < 5 min |
| PR opened/updated | Smoke + SDK tests (1 node) | < 15 min |
| PR labeled `full-test` | Complete suite (3 nodes) | < 30 min |
| Merge to main | Full suite + benchmark baseline | < 45 min |
| Nightly (2 AM UTC) | Everything (6 nodes) + VOPR | 2+ hours |
| Weekly | Competitor benchmarks + extended VOPR | 4+ hours |

### Parallel vs Sequential

**Parallel (independent):**
- SDK tests (Python, Node, Go, Java, C run simultaneously)
- Platform tests (Linux, macOS, Alpine)
- Unit tests across SDKs

**Sequential (dependencies):**
- Build server -> Start server -> Run SDK tests
- Smoke tests -> SDK tests -> E2E tests
- Benchmark -> Comparison -> Report

## Test Data Strategy

### Built-in vs External Datasets

| Dataset Type | Location | Size | Use Case |
|--------------|----------|------|----------|
| Canonical fixtures | `test-data/` | 100s of events | Protocol compatibility |
| Small dataset | `tests/sdk/shared/fixtures/` | 100 events | Unit tests, quick integration |
| Medium dataset | Generated at runtime | 10K events | Integration tests |
| Large dataset | Generated, not committed | 1M+ events | Benchmarks, stress tests |

### Data Generation Approach

```python
# tests/sdk/harness/data-generator.py
import json
import random
import uuid

def generate_events(count: int, seed: int = 42) -> list:
    """Generate deterministic test events for reproducibility."""
    random.seed(seed)
    events = []
    for i in range(count):
        events.append({
            "entity_id": str(uuid.UUID(int=random.getrandbits(128))),
            "latitude": random.uniform(-90, 90),
            "longitude": random.uniform(-180, 180),
            "ttl_seconds": random.randint(60, 86400)
        })
    return events
```

**Principles:**
1. Small fixtures committed to repo for reproducibility
2. Large datasets generated at runtime with fixed seeds
3. Edge cases explicitly enumerated in JSON fixtures
4. Random data used for fuzzing, not correctness tests

## Results Storage and Visualization

### Storage Strategy

| Data Type | Storage | Retention | Access |
|-----------|---------|-----------|--------|
| Test results | GitHub Artifacts | 30 days | CI workflow |
| Benchmark baseline | GitHub Artifacts | 90 days | Benchmark workflow |
| Historical trends | `benchmark-data/` branch | Permanent | github-action-benchmark |
| Coverage reports | Codecov | 1 year | codecov.io |

### Regression Detection

The existing benchmark.yml already implements regression detection:

```yaml
# From existing .github/workflows/benchmark.yml
- name: Store benchmark result
  uses: benchmark-action/github-action-benchmark@v1
  with:
    tool: 'customSmallerIsBetter'
    alert-threshold: '105%'  # 5% throughput regression
    fail-on-alert: true
```

**Thresholds (from docs/testing/performance-baselines.md):**
- Throughput: 5% degradation = fail
- Latency P99: 25% degradation = fail

## Suggested Build Order

Based on this architecture, the recommended implementation phases:

### Phase 1: Foundation (Week 1-2)
1. Create `tests/sdk/` directory structure
2. Implement server harness abstraction
3. Add `run-sdk-tests.sh` unified runner
4. Standardize environment variable configuration

### Phase 2: Consolidation (Week 2-3)
1. Migrate existing SDK tests to consistent structure
2. Implement shared fixture loading in each SDK
3. Add Node.js proper test framework (currently custom)
4. Create C SDK test infrastructure

### Phase 3: Integration (Week 3-4)
1. Cross-SDK compatibility test suite
2. Wire format verification tests
3. Scenario-based integration tests
4. Protocol-level curl tests

### Phase 4: Benchmarking (Week 4-5)
1. Formalize `benchmarks/` structure
2. Per-SDK benchmark runners
3. Unified result collection
4. Regression visualization

### Phase 5: Advanced (Week 5-6)
1. Multi-node test scenarios
2. Failure injection tests
3. Long-running stability tests
4. Competitor comparison automation

## Sources

- [GitHub Actions Matrix Builds](https://www.blacksmith.sh/blog/matrix-builds-with-github-actions) - Matrix strategy patterns
- [Advanced GitHub Actions Matrix Usage](https://devopsdirective.com/posts/2025/08/advanced-github-actions-matrix/) - Dynamic matrix configurations
- [CockroachDB Performance Testing Methodology](https://www.cockroachlabs.com/blog/database-testing-performance-under-adversity/) - Real-world database benchmarking
- [Aerospike Database Benchmarking Best Practices](https://aerospike.com/blog/best-practices-for-database-benchmarking/) - Synthetic vs real benchmarks
- [Continuous Testing Benchmark Report 2025](https://testgrid.io/blog/continuous-testing-trends-2025/) - Testing trends and patterns
- Existing ArcherDB documentation: `docs/benchmarks.md`, `docs/testing/performance-baselines.md`

---
*Architecture research for: Multi-SDK Testing Infrastructure for ArcherDB*
*Researched: 2026-02-01*
