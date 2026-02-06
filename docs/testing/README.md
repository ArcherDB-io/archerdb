# ArcherDB Testing Guide

Comprehensive guide for running ArcherDB tests locally across all 5 SDKs.

## Overview

ArcherDB's test suite covers:

- **Unit tests**: Per-SDK operation validation
- **Integration tests**: Multi-node cluster behavior
- **Parity tests**: Cross-SDK result consistency
- **Edge case tests**: Geographic boundary conditions
- **Performance tests**: Latency and throughput benchmarks

## Prerequisites

### Required Software

| Dependency | Version | Purpose |
|------------|---------|---------|
| Python | 3.11+ | Test infrastructure, Python SDK |
| Node.js | 20+ | Node.js SDK tests |
| Go | 1.21+ | Go SDK tests |
| Java | 21+ | Java SDK tests (Maven included) |
| GCC/Clang | Recent | C SDK tests |
| Zig | Bundled | Core build and server tests |

### Installation

```bash
# Python test infrastructure
pip install -r test_infrastructure/requirements.txt

# Node.js SDK dependencies
cd src/clients/node && npm install

# Go SDK dependencies
cd src/clients/go && go mod download

# Java SDK dependencies
cd src/clients/java && mvn dependency:resolve

# C SDK - no external dependencies (header-only)
# Zig - bundled in repo at ./zig/zig (for server build/tests)
```

## Quick Start

### 1. Build the Server

```bash
# Constrained build (recommended for most machines)
./zig/zig build -j4 -Dconfig=lite

# Full build (CI or dedicated machine)
./zig/zig build
```

### 2. Start a Local Server

```bash
# Single node for development
./zig/zig build run -- --port 3001

# Or run the pre-built binary
./zig-out/bin/archerdb --port 3001
```

### 3. Run SDK Tests

Each SDK has its own test suite. Run from the repository root:

**Python:**
```bash
cd src/clients/python
pip install pytest
pytest tests/ -v
```

**Node.js:**
```bash
cd src/clients/node
npm install
npm test
```

**Go:**
```bash
cd src/clients/go
go test ./... -v
```

**Java:**
```bash
cd src/clients/java
mvn test
```

**C:**
```bash
cd src/clients/c
make test
```

**Server (Zig unit tests):**
```bash
./zig/zig build -j4 -Dconfig=lite test:unit
```

### 4. Run Specific Test Filter

Most test frameworks support filtering:

```bash
# Python
pytest tests/ -v -k "insert"

# Go
go test ./... -v -run TestInsert

# Server (Zig)
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "insert"
```

## Test Infrastructure

The `test_infrastructure/` directory provides Python utilities for cluster management and test data generation.

### Cluster Harness

Start and manage multi-node ArcherDB clusters programmatically:

```python
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig

# Start a 3-node cluster
config = ClusterConfig(node_count=3)
with ArcherDBCluster(config) as cluster:
    cluster.wait_for_ready(timeout=60)
    leader_addr = cluster.get_leader_address()
    # Run tests against leader_addr...
```

### Data Generators

Generate test datasets with various distribution patterns:

```python
from test_infrastructure.generators import generate_events, DatasetConfig

# Generate 1000 events concentrated around cities
events = generate_events(DatasetConfig(
    size=1000,
    pattern='city_concentrated',
    cities=['san_francisco', 'tokyo'],
    seed=42,  # Reproducible
))
```

See [test_infrastructure/README.md](../test_infrastructure/README.md) for complete documentation.

### Fixtures

Pre-defined test fixtures are in `test_infrastructure/fixtures/v1/`:

| Fixture | Size | Use Case |
|---------|------|----------|
| `smoke.json` | 10 events | Quick connectivity tests |
| `pr.json` | 100 events | PR validation |
| `nightly.json` | 1000 events | Comprehensive testing |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ARCHERDB_HOST` | Server hostname | `127.0.0.1` |
| `ARCHERDB_PORT` | Server port | `3001` |
| `ARCHERDB_INTEGRATION` | Enable integration tests | `""` (disabled) |
| `PRESERVE_ON_FAILURE` | Keep cluster data after failures | `""` (cleanup) |
| `ARCHERDB_BIN` | Path to archerdb binary | Auto-detect |

### Running Integration Tests

Integration tests require a running cluster and are gated by environment variable:

```bash
# Start cluster first
./zig/zig build run -- --port 3001

# Enable integration tests
export ARCHERDB_INTEGRATION=1
pytest tests/ -v -m integration
```

## Parity Testing

Verify that all SDKs produce identical results:

```bash
# Run full parity suite
python tests/parity_tests/parity_runner.py

# Run specific operations
python tests/parity_tests/parity_runner.py --ops insert query-radius

# Run specific SDKs
python tests/parity_tests/parity_runner.py --sdks python node go

# Verbose output
python tests/parity_tests/parity_runner.py -v
```

Results are written to:
- `reports/parity.json` - Machine-readable
- `docs/PARITY.md` - Human-readable matrix

See [docs/PARITY.md](PARITY.md) for methodology and current status.

## Edge Case Testing

Geographic edge cases (poles, antimeridian, equator) are tested separately:

```bash
# Run edge case tests
pytest tests/edge_case_tests/ -v

# Run specific category
pytest tests/edge_case_tests/ -v -k "polar"
pytest tests/edge_case_tests/ -v -k "antimeridian"
```

## Troubleshooting

### Server Won't Start

1. Check if binary exists:
   ```bash
   ls zig-out/bin/archerdb
   ```

2. Build if missing:
   ```bash
   ./zig/zig build -j4 -Dconfig=lite
   ```

3. Check for port conflicts:
   ```bash
   lsof -i :3001
   ```

### Tests Fail with Connection Errors

1. Verify server is running:
   ```bash
   curl http://127.0.0.1:3001/ping
   # Should return: {"pong":true}
   ```

2. Check environment variables:
   ```bash
   echo $ARCHERDB_HOST $ARCHERDB_PORT
   ```

### Python Import Errors

Ensure test infrastructure is in path:

```bash
export PYTHONPATH="${PYTHONPATH}:${PWD}/test_infrastructure"
```

Or install in development mode:

```bash
pip install -e test_infrastructure/
```

### Out of Memory During Tests

Use constrained build configuration:

```bash
# Instead of full build
./zig/zig build -j4 -Dconfig=lite test:unit

# Or minimal for low-memory systems
./zig/zig build -j2 -Dconfig=lite test:unit
```

### Preserving Test Data for Debugging

```bash
export PRESERVE_ON_FAILURE=1
pytest tests/
# Data preserved in /tmp/archerdb-test-*
```

## Resource-Constrained Testing

For machines with limited resources (24GB RAM, 8 cores):

| Profile | Command | RAM | Use Case |
|---------|---------|-----|----------|
| Minimal | `-j2 -Dconfig=lite` | ~2GB | Heavy server load |
| Constrained | `-j4 -Dconfig=lite` | ~4GB | Normal development |
| Full | (default) | ~8GB+ | CI or dedicated machine |

Use the helper script:

```bash
./scripts/test-constrained.sh unit              # Default: -j4, lite
./scripts/test-constrained.sh --minimal unit    # Minimal: -j2, lite
./scripts/test-constrained.sh --full unit       # Full resources
./scripts/test-constrained.sh check             # Quick compile check
```

## CI Integration

Tests are run automatically in CI with tiered execution:

- **Smoke** (<5 min): Every push, basic connectivity
- **PR** (<15 min): Pull requests, full SDK suite
- **Nightly** (2h): Comprehensive multi-node testing
- **Weekly** (3h): Full benchmark suite

See [docs/testing/ci-tiers.md](ci-tiers.md) for tier details.

## See Also

- [CI Tier Structure](ci-tiers.md) - CI pipeline organization
- [Benchmark Guide](../benchmarks/README.md) - Performance testing
- [SDK Comparison Matrix](../sdk/comparison-matrix.md) - SDK feature parity
- [SDK Limitations](../SDK_LIMITATIONS.md) - Known issues and workarounds
- [Parity Matrix](../PARITY.md) - Cross-SDK verification status

---

*Last updated: 2026-02-01*
