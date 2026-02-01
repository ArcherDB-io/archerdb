# ArcherDB Test Infrastructure

Python test infrastructure for programmatic cluster management and test data generation.

## Overview

This package provides two main components:

1. **Cluster Harness** (`harness/`): Start/stop ArcherDB clusters programmatically with automatic port allocation, health check polling, and leader detection.

2. **Data Generators** (`generators/`): Generate test datasets with various distribution patterns (uniform, city-concentrated, hotspot) for comprehensive testing.

## Installation

```bash
pip install -r test_infrastructure/requirements.txt
```

## Quick Start

```python
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig
from test_infrastructure.generators import generate_events, DatasetConfig

# Start a 3-node cluster
config = ClusterConfig(node_count=3)
with ArcherDBCluster(config) as cluster:
    # Wait for cluster ready
    cluster.wait_for_ready()
    leader_addr = cluster.get_leader_address()

    # Generate test data
    events = generate_events(DatasetConfig(
        size=1000,
        pattern='city_concentrated',
        cities=['san_francisco', 'tokyo'],
        seed=42
    ))

    # Use with any SDK
    # client = GeoClientSync(GeoClientConfig(addresses=[leader_addr]))
    # client.insert_events(events)
```

## Cluster Harness

### Programmatic API

```python
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig

# Configuration options
config = ClusterConfig(
    node_count=3,           # 1, 3, 5, 7... (odd for consensus)
    base_port=0,            # 0 = auto-allocate ports
    data_dir=None,          # None = auto-create temp dir
    cluster_id=0,           # Cluster identifier
    cache_grid="512MiB",    # Small for testing
    startup_timeout=60.0,   # Seconds to wait for startup
)

# Context manager (recommended)
with ArcherDBCluster(config) as cluster:
    cluster.wait_for_ready(timeout=60)
    leader = cluster.wait_for_leader(timeout=30)
    print(f"Cluster addresses: {cluster.get_addresses()}")
    print(f"Leader port: {leader}")

    # Run tests...

# Cluster automatically cleaned up

# Manual lifecycle
cluster = ArcherDBCluster(config)
cluster.start()
try:
    cluster.wait_for_ready()
    # ... tests ...
finally:
    cluster.stop()
```

### CLI Usage

```bash
# Start cluster manually for debugging
python -m test_infrastructure.harness.cli start --nodes=3 --data-dir=/tmp/test-cluster

# Check status
python -m test_infrastructure.harness.cli status

# View logs
python -m test_infrastructure.harness.cli logs --replica=0

# Stop cluster
python -m test_infrastructure.harness.cli stop
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PRESERVE_ON_FAILURE` | Keep cluster data after test failures | `""` (cleanup) |
| `ARCHERDB_BIN` | Path to archerdb binary | Auto-detect |

## Data Generators

### Distribution Patterns

#### Uniform Distribution

Even distribution across the entire coordinate space. Good for testing query coverage.

```python
config = DatasetConfig(
    size=1000,
    pattern='uniform',
    seed=42,  # Reproducible
)
events = generate_events(config)
```

#### City-Concentrated Distribution

Realistic urban clustering with configurable concentration ratio. Events cluster around city centers with Gaussian distribution.

```python
config = DatasetConfig(
    size=1000,
    pattern='city_concentrated',
    cities=['san_francisco', 'tokyo', 'london'],
    concentration=0.8,  # 80% in cities, 20% scattered
    std_km=20.0,        # Spread in kilometers
    seed=42,
)
events = generate_events(config)
```

Available cities: `new_york`, `san_francisco`, `los_angeles`, `chicago`, `toronto`, `mexico_city`, `london`, `paris`, `berlin`, `amsterdam`, `moscow`, `tokyo`, `singapore`, `mumbai`, `beijing`, `shanghai`, `hong_kong`, `seoul`, `bangkok`, `sydney`, `melbourne`, `sao_paulo`, `buenos_aires`, `cape_town`, `johannesburg`, `nairobi`, `auckland`, `reykjavik`, `anchorage`

#### Hotspot Pattern

Extreme concentration for stress testing worst-case scenarios.

```python
config = DatasetConfig(
    size=1000,
    pattern='hotspot',
    hotspots=[
        (37.7749, -122.4194),  # San Francisco
        (35.6762, 139.6503),   # Tokyo
    ],
    hotspot_ratio=0.95,  # 95% at hotspots
    seed=42,
)
events = generate_events(config)
```

### Dataset Size Tiers

| Tier | Size | Use Case |
|------|------|----------|
| Small | 100-1K | Quick smoke tests, debugging |
| Medium | 10K-100K | Realistic workload simulation |
| Large | 1M+ | Stress testing, benchmark validation |

```python
# Convenience functions
from test_infrastructure.generators.data_generator import small_dataset, medium_dataset, large_dataset

# 100 events, uniform, seed=42
events = small_dataset()

# 10,000 events, city-concentrated
events = medium_dataset(
    pattern='city_concentrated',
    cities=['san_francisco', 'tokyo'],
)

# 100,000 events for stress testing
events = large_dataset(pattern='hotspot', hotspots=[(37.7749, -122.4194)])
```

### Randomness Options

#### Deterministic (Seeded)

Same seed always produces identical datasets. Essential for reproducible testing.

```python
config = DatasetConfig(size=100, pattern='uniform', seed=42)
events1 = generate_events(config)
events2 = generate_events(config)
assert events1 == events2  # Always true
```

#### Truly Random (seed=None)

Different results every run. Useful for catching edge cases.

```python
config = DatasetConfig(size=100, pattern='uniform', seed=None)
events1 = generate_events(config)
events2 = generate_events(config)
# Different every time
```

### Event Structure

Generated events match SDK expectations:

```python
{
    "entity_id": "a1b2c3d4...",  # 32-char hex string
    "latitude": 37.7749,
    "longitude": -122.4194,
    "ttl_seconds": 3600,
    "user_data": 42,  # Optional, 0-1000
}
```

### Edge Cases

For boundary testing:

```python
from test_infrastructure.generators import EDGE_CASES

# Geographic edge cases
print(EDGE_CASES)
# {
#     "north_pole": {"lat": 90.0, "lon": 0.0},
#     "south_pole": {"lat": -90.0, "lon": 0.0},
#     "antimeridian_east": {"lat": 0.0, "lon": 180.0},
#     "antimeridian_west": {"lat": 0.0, "lon": -180.0},
#     "null_island": {"lat": 0.0, "lon": 0.0},
#     ...
# }
```

## Integration with SDKs

### pytest Fixture Pattern

```python
import pytest
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig
from test_infrastructure.generators import generate_events, DatasetConfig

@pytest.fixture(scope="module")
def cluster():
    """Start a test cluster for the module."""
    config = ClusterConfig(node_count=3)
    with ArcherDBCluster(config) as c:
        c.wait_for_ready(timeout=60)
        c.wait_for_leader(timeout=30)
        yield c

@pytest.fixture
def test_events():
    """Generate reproducible test events."""
    return generate_events(DatasetConfig(
        size=100,
        pattern='city_concentrated',
        cities=['san_francisco'],
        seed=42,
    ))

def test_insert_query(cluster, test_events):
    addresses = cluster.get_addresses()
    # ... test implementation ...
```

### Direct SDK Usage

```python
import sys
sys.path.insert(0, 'src/clients/python/src')

from archerdb import GeoClientSync, GeoClientConfig, create_geo_event
from test_infrastructure.harness import ArcherDBCluster, ClusterConfig
from test_infrastructure.generators import generate_events, DatasetConfig

config = ClusterConfig(node_count=1)
with ArcherDBCluster(config) as cluster:
    cluster.wait_for_ready()

    # Generate test data
    events = generate_events(DatasetConfig(size=100, pattern='uniform', seed=42))

    # Convert to SDK events
    client = GeoClientSync(GeoClientConfig(
        cluster_id=0,
        addresses=[cluster.get_addresses()]
    ))

    try:
        archerdb_events = [
            create_geo_event(
                entity_id=int(e['entity_id'], 16) % (2**64),
                latitude=e['latitude'],
                longitude=e['longitude'],
                ttl_seconds=e['ttl_seconds']
            ) for e in events
        ]
        errors = client.insert_events(archerdb_events)
        assert errors == []
    finally:
        client.close()
```

## Troubleshooting

### Cluster Won't Start

1. Check archerdb binary exists: `ls zig-out/bin/archerdb`
2. Build if missing: `./zig/zig build -j4 -Dconfig=lite`
3. Check logs: `cluster.get_logs(replica=0)`

### Port Conflicts

Ports are auto-allocated from range 3100-4100. If conflicts occur:

```python
config = ClusterConfig(base_port=5000)  # Use different range
```

### Preserve Data for Debugging

```bash
export PRESERVE_ON_FAILURE=1
python -m pytest tests/
# Data preserved in /tmp/archerdb-test-*
```
