# Phase 11: Test Infrastructure Foundation - Research

**Researched:** 2026-02-01
**Domain:** Test Infrastructure, CI/CD, Test Data Generation, Cross-SDK Validation
**Confidence:** HIGH (based on existing codebase patterns and official documentation)

## Summary

This research covers the infrastructure needed to build reliable test infrastructure for ArcherDB's 6 SDKs (Python, Node.js, Java, Go, C, Zig) across 14 operations with tiered CI execution (smoke/PR/nightly). The codebase already has substantial foundations:

- **Existing cluster management**: `scripts/dev-cluster.sh` provides shell-based cluster orchestration
- **Existing test fixtures**: `src/clients/test-data/wire-format-test-cases.json` with wire format test cases
- **Existing CI**: `.github/workflows/ci.yml` with SDK tests and multi-platform matrix
- **Existing VOPR**: Deterministic simulation testing infrastructure in `src/testing/`

**Primary recommendation:** Extend existing `dev-cluster.sh` into a cross-language library interface (Python primary, CLI wrapper for shell), add comprehensive JSON fixtures for all 14 operations, and refactor CI into explicit smoke/PR/nightly tiers with consistent timeout enforcement.

## Standard Stack

The established libraries/tools for this domain:

### Core Infrastructure

| Tool/Library | Version | Purpose | Why Standard |
|--------------|---------|---------|--------------|
| Python | 3.11+ | Test harness implementation | User decision (CONTEXT.md): Python for primary harness |
| subprocess | stdlib | Process management | Standard for spawning ArcherDB processes |
| socket | stdlib | Port allocation | Built-in port availability checking |
| pytest | 8.x | Test framework for Python SDK | Already used in Python SDK tests |
| GitHub Actions | v4 actions | CI/CD platform | Already configured in repository |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| google/python_portpicker | latest | Port allocation | Finding available ports for parallel test safety |
| pytest-server-fixtures | latest | Server lifecycle | Alternative pattern for server management |
| testfixtures | latest | Mocking subprocess | Unit testing harness itself |
| jq | system | JSON manipulation | Fixture validation and transformation |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Python harness | Shell script only | Shell exists (`dev-cluster.sh`) but lacks programmatic SDK integration |
| Python harness | Zig harness | Zig would be more performant but harder to consume from Python/Node/Java |
| pytest-server-fixtures | Custom implementation | Custom gives more control over ArcherDB-specific lifecycle |

**Installation:**
```bash
# For Python harness development
pip install portpicker pytest pytest-timeout

# For fixture validation
sudo apt-get install jq
```

## Architecture Patterns

### Recommended Project Structure
```
test-infrastructure/
├── harness/
│   ├── __init__.py           # Python package
│   ├── cluster.py            # Cluster class (start/stop/health)
│   ├── port_allocator.py     # Port allocation utilities
│   ├── log_capture.py        # Log capture and rotation
│   └── cli.py                # CLI wrapper using click/argparse
├── fixtures/
│   └── v1/                   # Protocol version subdirectory
│       ├── insert.json       # Insert operation fixtures
│       ├── upsert.json       # Upsert operation fixtures
│       ├── delete.json       # Delete operation fixtures
│       ├── query-uuid.json   # Query UUID fixtures
│       ├── query-uuid-batch.json
│       ├── query-radius.json # Radius query fixtures
│       ├── query-polygon.json
│       ├── query-latest.json
│       ├── ping.json         # Admin operations
│       ├── status.json
│       ├── ttl-set.json      # TTL operations
│       ├── ttl-extend.json
│       ├── ttl-clear.json
│       └── topology.json     # Topology discovery
├── generators/
│   ├── data_generator.py     # Test data generation
│   ├── city_coordinates.py   # City coordinate database
│   └── distributions.py      # Distribution patterns (uniform, gaussian, hotspot)
└── ci/
    ├── smoke.yml             # <5 min tier
    ├── pr.yml                # <15 min tier
    └── nightly.yml           # Full suite
```

### Pattern 1: Cluster Harness Interface

**What:** Python class wrapping ArcherDB process lifecycle with health checks
**When to use:** All SDK integration tests, benchmarks, E2E tests

```python
# Source: Based on existing dev-cluster.sh and CockroachDB testserver patterns
from dataclasses import dataclass
from typing import List, Optional
import subprocess
import socket
import time
import os

@dataclass
class ClusterConfig:
    node_count: int = 1
    base_port: int = 0  # 0 = auto-allocate
    data_dir: Optional[str] = None  # None = temp dir
    cluster_id: int = 0
    cache_grid: str = "512MiB"  # Small for testing
    preserve_on_failure: bool = False

class ArcherDBCluster:
    """Programmatic cluster management for testing."""

    def __init__(self, config: ClusterConfig):
        self.config = config
        self.processes: List[subprocess.Popen] = []
        self.ports: List[int] = []
        self.data_dir: str = ""
        self.leader_port: Optional[int] = None

    def start(self) -> None:
        """Start cluster, wait for ready."""
        self._allocate_ports()
        self._format_replicas()
        self._start_replicas()
        self._wait_for_ready()
        self._detect_leader()

    def stop(self) -> None:
        """Stop cluster, cleanup unless preserve_on_failure."""
        for proc in self.processes:
            proc.terminate()
            proc.wait(timeout=10)
        if not (self.config.preserve_on_failure and self._has_failures):
            self._cleanup_data()

    def wait_for_ready(self, timeout: float = 60) -> bool:
        """Wait for all nodes to be healthy."""
        # Health check via metrics endpoint
        pass

    def get_addresses(self) -> str:
        """Return comma-separated address list for SDK connection."""
        return ",".join(f"127.0.0.1:{p}" for p in self.ports)

    def get_logs(self, replica: int = 0) -> str:
        """Return captured logs for debugging."""
        pass
```

### Pattern 2: Port Allocation for Parallel Safety

**What:** Dynamic port allocation to enable parallel test execution
**When to use:** All cluster starts to avoid port conflicts

```python
# Source: Google's python_portpicker and pytest-server-fixtures patterns
import socket

def find_available_port(start: int = 3100, end: int = 3200) -> int:
    """Find an available port in range."""
    for port in range(start, end):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(('127.0.0.1', port))
            sock.close()
            return port
        except OSError:
            continue
    raise RuntimeError(f"No available ports in range {start}-{end}")

def allocate_ports(count: int, base_port: int = 0) -> List[int]:
    """Allocate multiple consecutive-ish ports."""
    ports = []
    search_start = base_port if base_port > 0 else 3100
    for _ in range(count):
        port = find_available_port(search_start, search_start + 1000)
        ports.append(port)
        search_start = port + 1
    return ports
```

### Pattern 3: Golden File Test Fixtures

**What:** JSON input/output pairs for contract testing across SDKs
**When to use:** Cross-SDK parity validation, regression testing

```json
// Source: Based on existing wire-format-test-cases.json and Pact contract testing
{
  "operation": "insert_events",
  "version": "1.0.0",
  "cases": [
    {
      "name": "single_event_valid",
      "description": "Insert a single valid event",
      "input": {
        "events": [{
          "entity_id": "550e8400-e29b-41d4-a716-446655440000",
          "latitude": 37.7749,
          "longitude": -122.4194,
          "ttl_seconds": 3600
        }]
      },
      "expected_output": {
        "errors": [],
        "inserted_count": 1
      },
      "tags": ["smoke", "pr", "nightly"]
    },
    {
      "name": "boundary_north_pole",
      "description": "Insert event at north pole (90°N)",
      "input": {
        "events": [{
          "entity_id": "550e8400-e29b-41d4-a716-446655440001",
          "latitude": 90.0,
          "longitude": 0.0,
          "ttl_seconds": 3600
        }]
      },
      "expected_output": {
        "errors": [],
        "inserted_count": 1
      },
      "tags": ["nightly"]
    }
  ]
}
```

### Pattern 4: CI Tier Configuration

**What:** Tiered CI with explicit time budgets and test selection
**When to use:** GitHub Actions workflow organization

```yaml
# Source: GitHub Actions best practices and existing ci.yml patterns
# Smoke tier (<5 min)
jobs:
  smoke:
    timeout-minutes: 5
    steps:
      - name: Build
        run: ./zig/zig build -j4 -Dconfig=lite
      - name: Unit tests
        run: ./zig/zig build -j4 -Dconfig=lite test:unit
      - name: Single SDK connectivity
        run: |
          # Start single-node, run one insert test per SDK
          python test-infrastructure/ci/smoke_sdk.py

# PR tier (<15 min)
  pr:
    needs: smoke
    timeout-minutes: 15
    strategy:
      matrix:
        sdk: [python, node, java, go, c]
    steps:
      - name: Full suite in primary SDK
        if: matrix.sdk == 'python'
        run: pytest src/clients/python/tests/ -v
      - name: Critical ops in all SDKs
        run: |
          # insert/query/delete across all SDKs
          ./test-infrastructure/ci/pr_critical.sh ${{ matrix.sdk }}

# Nightly (full suite)
  nightly:
    timeout-minutes: 120
    schedule:
      - cron: '0 2 * * *'  # 2 AM UTC
    strategy:
      matrix:
        node_count: [1, 3, 5]
        sdk: [python, node, java, go, c, zig]
```

### Anti-Patterns to Avoid

- **Hardcoded ports**: Never use fixed ports (3000, 3001) - causes parallel test failures
- **Sleep-based waits**: Always use health check polling, not `time.sleep(5)`
- **Retries masking flaky tests**: Per CONTEXT.md decision, fail fast on flaky tests
- **Shared state between tests**: Each test gets fresh cluster, no shared data
- **Ignoring cleanup**: Always cleanup in `finally` block or pytest fixture teardown

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Port allocation | Custom random port picker | google/python_portpicker or socket-based | Handles edge cases (race conditions, reserved ports) |
| JSON schema validation | String comparison | jsonschema library | Handles optional fields, type coercion |
| Process cleanup | Manual kill loops | subprocess context managers | Handles zombie processes, signal handling |
| Log rotation | Custom file rotation | logging.handlers.RotatingFileHandler | Thread-safe, size limits built-in |
| S2 cell computation | Custom implementation | Existing `compute_s2_cell_id` in benchmark_geo.py | Already validated against server |
| UUID generation | Custom random | uuid.uuid4() or archerdb.id() | Correct v4 UUID format |

**Key insight:** Test infrastructure itself should be simple and boring - complexity belongs in the system under test, not the test harness. Use standard libraries for infrastructure concerns.

## Common Pitfalls

### Pitfall 1: Cluster Start Timing
**What goes wrong:** Tests fail intermittently because cluster isn't ready
**Why it happens:** Starting processes doesn't mean they're accepting connections
**How to avoid:** Always poll health endpoint before running tests
**Warning signs:** Flaky connection refused errors, intermittent test failures

```python
# WRONG: Sleep-based waiting
subprocess.Popen([...])
time.sleep(5)  # Might not be enough!

# RIGHT: Health check polling
subprocess.Popen([...])
for attempt in range(60):
    try:
        response = requests.get(f"http://127.0.0.1:{port}/health/ready")
        if response.status_code == 200:
            break
    except requests.ConnectionError:
        time.sleep(1)
else:
    raise RuntimeError("Cluster failed to start")
```

### Pitfall 2: Leader Election Timing
**What goes wrong:** Multi-node tests fail because leader not elected
**Why it happens:** Raft/VSR consensus takes time to elect leader
**How to avoid:** Wait for leader election via status endpoint or log parsing
**Warning signs:** "no leader" errors, intermittent write failures on multi-node

### Pitfall 3: Data Directory Cleanup Race
**What goes wrong:** Tests fail on CI with "file in use" errors
**Why it happens:** Process still running when trying to delete data
**How to avoid:** Always wait for process termination before cleanup
**Warning signs:** Random CI failures, works locally but fails in CI

### Pitfall 4: Fixture Drift
**What goes wrong:** SDKs pass tests but produce different results
**Why it happens:** Fixtures updated for one SDK but not validated against server
**How to avoid:** Generate fixtures from actual server responses, version fixtures
**Warning signs:** SDK tests pass but integration fails, parity issues between SDKs

### Pitfall 5: CI Timeout Creep
**What goes wrong:** CI jobs exceed time limits, block PRs
**Why it happens:** Tests accumulate, no time budget enforcement
**How to avoid:** Explicit timeout-minutes on every job, test selection by tier
**Warning signs:** PR feedback taking >20 minutes, developers bypassing CI

## Code Examples

Verified patterns from existing codebase:

### Starting ArcherDB (from dev-cluster.sh)
```bash
# Source: scripts/dev-cluster.sh lines 162-210
# Format data file
"$ARCHERDB_BIN" format \
    --cluster="$CLUSTER_ID" \
    --replica="$i" \
    --replica-count="$NODES" \
    "$datafile"

# Start with small cache for testing
"$ARCHERDB_BIN" start \
    --addresses="$addresses" \
    --cache-grid=512MiB \
    "$datafile" \
    >"$logfile" 2>&1 &
```

### Health Check Polling (from ci.yml)
```bash
# Source: .github/workflows/ci.yml lines 152-159
# Wait for server to be ready
for i in {1..60}; do
  if curl -sf http://127.0.0.1:9100/health/ready > /dev/null 2>&1; then
    echo "Server ready after ${i}s"
    break
  fi
  sleep 1
done
```

### SDK Test Pattern (from test_integration.py)
```python
# Source: src/clients/python/tests/test_integration.py
from archerdb import GeoClientSync, GeoClientConfig, create_geo_event, id as archerdb_id

def test_insert_query_delete_roundtrip() -> None:
    client = GeoClientSync(GeoClientConfig(cluster_id=0, addresses=[SERVER_ADDR]))
    try:
        entity_id = archerdb_id()
        event = create_geo_event(
            entity_id=entity_id,
            latitude=37.7749,
            longitude=-122.4194,
            ttl_seconds=60,
        )
        errors = client.insert_events([event])
        assert errors == []
        # ... query and verify
    finally:
        client.close()
```

### Geospatial Test Data Generation (from geo_workload.zig)
```zig
// Source: src/testing/geo_workload.zig lines 96-110
/// Edge-case coordinates for adversarial testing (F4.1.3)
pub const EdgeCaseCoordinates = struct {
    /// North pole (90°N)
    pub const NORTH_POLE_LAT: i64 = 90_000_000_000;
    /// South pole (-90°S)
    pub const SOUTH_POLE_LAT: i64 = -90_000_000_000;
    /// Antimeridian positive (+180°)
    pub const ANTIMERIDIAN_POS: i64 = 180_000_000_000;
    /// Antimeridian negative (-180°)
    pub const ANTIMERIDIAN_NEG: i64 = -180_000_000_000;
};
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual cluster start | `dev-cluster.sh` | Already exists | Use as foundation |
| Hardcoded test data | Wire format JSON | Already exists | Extend to all 14 ops |
| Single CI job | Tiered (smoke/test/integration) | ci.yml current | Refactor into explicit tiers |
| Port 3000 hardcoded | Dynamic allocation | Need to implement | Enables parallel tests |
| Shell-only harness | Python library + CLI | Need to implement | SDK integration |

**Deprecated/outdated:**
- Direct process spawning without health checks: Use health endpoint polling
- Fixed port allocation: Use dynamic port finding for parallel safety

## Open Questions

Things that couldn't be fully resolved:

1. **Warmup Protocol Specifics**
   - What we know: Benchmarks need warmup iterations for stable results
   - What's unclear: Exact iteration counts per SDK (JVM needs more warmup than Python)
   - Recommendation: Start with 100 iterations for all, tune based on variance measurements

2. **Log Capture Storage**
   - What we know: Need to capture logs for debugging failed tests
   - What's unclear: Storage limits in CI, rotation strategy
   - Recommendation: Keep last 1MB per replica, rotate on size, preserve full logs on failure

3. **Multi-Node Timing Constants**
   - What we know: 3-node clusters need time for leader election
   - What's unclear: Exact timeout values for 5/6 node clusters
   - Recommendation: Start with 60s timeout, increase if seeing election failures

## Sources

### Primary (HIGH confidence)
- `/home/g/archerdb/scripts/dev-cluster.sh` - Existing cluster management script
- `/home/g/archerdb/.github/workflows/ci.yml` - Existing CI configuration
- `/home/g/archerdb/src/clients/test-data/wire-format-test-cases.json` - Existing fixture format
- `/home/g/archerdb/src/testing/geo_workload.zig` - Existing test data generation
- `/home/g/archerdb/src/testing/fixtures.zig` - Existing Zig test fixtures

### Secondary (MEDIUM confidence)
- [CockroachDB testserver](https://pkg.go.dev/github.com/cockroachdb/cockroach-go/v2/testserver) - Go test server pattern
- [GitHub Actions workflow syntax](https://docs.github.com/actions/using-workflows/workflow-syntax-for-github-actions) - CI configuration
- [Google python_portpicker](https://github.com/google/python_portpicker) - Port allocation
- [pytest-server-fixtures](https://pypi.org/project/pytest-server-fixtures/) - Server lifecycle patterns

### Tertiary (LOW confidence - patterns only)
- [CircleCI smoke testing guide](https://circleci.com/blog/smoke-tests-in-cicd-pipelines/) - Tiered testing concepts
- [TigerBeetle VOPR blog](https://tigerbeetle.com/blog/2025-02-13-a-descent-into-the-vortex/) - DST patterns (already implemented in ArcherDB)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Based on existing codebase patterns
- Architecture: HIGH - Extends existing dev-cluster.sh design
- Pitfalls: HIGH - Derived from existing CI failures and patterns
- Test fixtures: MEDIUM - Need to validate 14-operation coverage

**Research date:** 2026-02-01
**Valid until:** 2026-03-01 (30 days - stable infrastructure domain)

---

## Operations Reference

The 14 operations requiring fixtures (from `src/archerdb.zig`):

| # | Operation | Op Code | Category |
|---|-----------|---------|----------|
| 1 | insert_events | 146 | Geospatial |
| 2 | upsert_events | 147 | Geospatial |
| 3 | delete_entities | 148 | Geospatial |
| 4 | query_uuid | 149 | Geospatial |
| 5 | query_radius | 150 | Geospatial |
| 6 | query_polygon | 151 | Geospatial |
| 7 | query_latest | 154 | Geospatial |
| 8 | query_uuid_batch | 156 | Geospatial |
| 9 | archerdb_ping | 152 | Admin |
| 10 | archerdb_get_status | 153 | Admin |
| 11 | get_topology | 157 | Admin |
| 12 | ttl_set | 158 | TTL |
| 13 | ttl_extend | 159 | TTL |
| 14 | ttl_clear | 160 | TTL |

## City Coordinates Reference

Per CONTEXT.md decision for geographic diversity:

| City | Latitude | Longitude | Coverage |
|------|----------|-----------|----------|
| New York | 40.7128 | -74.0060 | North America East |
| San Francisco | 37.7749 | -122.4194 | North America West |
| London | 51.5074 | -0.1278 | Europe |
| Paris | 48.8566 | 2.3522 | Europe |
| Tokyo | 35.6762 | 139.6503 | Asia Pacific |
| Sydney | -33.8688 | 151.2093 | Southern Hemisphere |
| São Paulo | -23.5505 | -46.6333 | South America |
| Cape Town | -33.9249 | 18.4241 | Africa |
| Mumbai | 19.0760 | 72.8777 | South Asia |
| Singapore | 1.3521 | 103.8198 | Equatorial |
| Auckland | -36.8485 | 174.7633 | Pacific / Date Line |
| Reykjavik | 64.1466 | -21.9426 | High Latitude |

Plus edge cases:
- North Pole: 90.0, 0.0
- South Pole: -90.0, 0.0
- Antimeridian: 0.0, 180.0 and 0.0, -180.0
- Null Island: 0.0, 0.0
