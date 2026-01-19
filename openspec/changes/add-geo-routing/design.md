# Design: Geo-Routing Based on Client Location

## Context

ArcherDB deployments may span multiple geographic regions for latency and compliance reasons. Clients need to connect to the optimal region automatically.

## Goals / Non-Goals

### Goals

1. **Automatic region selection**: Clients find nearest region
2. **Latency-based routing**: Use measured RTT, not just geography
3. **Failover support**: Automatic switch on region failure

### Non-Goals

1. **DNS infrastructure**: Use existing geo-DNS services
2. **Cross-region replication**: Separate specification
3. **Client migration during request**: Commit to region per connection

## Decisions

### Decision 1: Two-Phase Region Discovery

**Choice**: Geo-DNS for initial routing, latency probing for refinement.

**Rationale**:
- Geo-DNS provides good initial estimate
- Latency probing handles edge cases (VPNs, misconfigured DNS)
- Combination gives best results

**Implementation**:
```
Phase 1: Geo-DNS Resolution
  client → archerdb.example.com → nearest region IP

Phase 2: Region Discovery (optional)
  client → GET /regions → [{name: "us-east", endpoint: "...", ...}]
  client → probe each region RTT
  client → select lowest RTT region
```

### Decision 2: Region Discovery Protocol

**Choice**: JSON endpoint returning available regions with metadata.

**Rationale**:
- Simple HTTP/JSON for maximum compatibility
- Includes health status for failover
- Signed response for security

**Implementation**:
```json
GET /regions

Response:
{
  "regions": [
    {
      "name": "us-east-1",
      "endpoint": "archerdb-use1.example.com:5000",
      "location": {"lat": 39.04, "lon": -77.49},
      "healthy": true,
      "primary": true
    },
    {
      "name": "eu-west-1",
      "endpoint": "archerdb-euw1.example.com:5000",
      "location": {"lat": 53.35, "lon": -6.26},
      "healthy": true,
      "primary": false
    }
  ],
  "signature": "...",
  "expires": "2024-01-15T12:00:00Z"
}
```

### Decision 3: SDK Latency Probing

**Choice**: Background RTT measurement to available regions.

**Rationale**:
- Geo-DNS can be inaccurate (VPNs, corporate networks)
- Actual latency matters more than geographic distance
- Can detect regional degradation

**Implementation**:
```python
class GeoRouter:
    def __init__(self, discovery_endpoint: str):
        self.regions = self._discover_regions(discovery_endpoint)
        self._probe_latencies()  # Background thread

    def get_preferred_region(self) -> Region:
        healthy = [r for r in self.regions if r.healthy]
        return min(healthy, key=lambda r: r.measured_latency_ms)

    def _probe_latencies(self):
        for region in self.regions:
            start = time.monotonic()
            self._ping(region.endpoint)
            region.measured_latency_ms = (time.monotonic() - start) * 1000
```

### Decision 4: Failover Strategy

**Choice**: Automatic failover to next-lowest-latency healthy region.

**Rationale**:
- No manual intervention required
- Latency-based selection remains optimal
- Gradual recovery when region heals

**Implementation**:
```python
class GeoAwareClient:
    def execute(self, query):
        for attempt in range(3):
            region = self.router.get_preferred_region()
            try:
                return self._execute_on(region, query)
            except RegionUnavailableError:
                self.router.mark_unhealthy(region)
                continue
        raise AllRegionsUnavailableError()
```

## Architecture

### Global Deployment

```
                    ┌─────────────────────────────────────┐
                    │         Geo-DNS Service             │
                    │  (Route53, Cloudflare, etc.)        │
                    └─────────────────┬───────────────────┘
                                      │
           ┌──────────────────────────┼──────────────────────────┐
           │                          │                          │
           ▼                          ▼                          ▼
    ┌─────────────┐           ┌─────────────┐           ┌─────────────┐
    │  US-East    │           │  EU-West    │           │  AP-South   │
    │  Cluster    │           │  Cluster    │           │  Cluster    │
    └─────────────┘           └─────────────┘           └─────────────┘
```

### Client Connection Flow

```
    Client                    Geo-DNS                Region Cluster
       │                         │                         │
       │ 1. Resolve endpoint     │                         │
       │─────────────────────────>│                         │
       │                         │                         │
       │ 2. Nearest region IP    │                         │
       │<─────────────────────────│                         │
       │                         │                         │
       │ 3. Connect & get regions│                         │
       │────────────────────────────────────────────────────>│
       │                         │                         │
       │ 4. Region list          │                         │
       │<────────────────────────────────────────────────────│
       │                         │                         │
       │ 5. Probe latencies (background)                   │
       │────────────────────────────────────────────────────>│
       │                         │                         │
       │ 6. Use lowest-latency region                      │
       │════════════════════════════════════════════════════>│
```

### Failover Flow

```
    Client             Region A (failing)    Region B (healthy)
       │                      │                      │
       │ 1. Query             │                      │
       │─────────────────────>│ (timeout)            │
       │                      │                      │
       │ 2. Mark A unhealthy  │                      │
       │                      │                      │
       │ 3. Retry to B        │                      │
       │──────────────────────────────────────────────>│
       │                      │                      │
       │ 4. Success           │                      │
       │<──────────────────────────────────────────────│
```

## Configuration

### SDK Configuration

```python
# Minimal configuration - automatic region discovery
client = ArcherDBClient(
    discovery_endpoint="https://archerdb.example.com/regions"
)

# With region preference
client = ArcherDBClient(
    discovery_endpoint="https://archerdb.example.com/regions",
    preferred_region="us-east-1",  # Hint, not mandatory
    failover_enabled=True
)

# Direct connection (skip geo-routing)
client = ArcherDBClient(
    endpoint="archerdb-use1.example.com:5000"
)
```

### Server Configuration

```yaml
# archerdb.yaml
geo_routing:
  enabled: true
  region_name: "us-east-1"
  region_location:
    lat: 39.04
    lon: -77.49
  advertise_endpoint: "archerdb-use1.example.com:5000"
  peer_regions:
    - name: "eu-west-1"
      endpoint: "archerdb-euw1.example.com:5000"
```

## Trade-Offs

### Geo-DNS Only vs Latency Probing

| Aspect | Geo-DNS Only | With Latency Probing |
|--------|--------------|----------------------|
| Initial latency | Lower | Higher (probe time) |
| Accuracy | Good for most | Better for edge cases |
| Complexity | Simple | More complex |
| VPN handling | Poor | Good |

**Chose both**: Geo-DNS for fast initial, probing for accuracy.

## Validation Plan

### Unit Tests

1. **Region discovery**: Parse region response correctly
2. **Latency sorting**: Select lowest-latency region
3. **Failover logic**: Switch regions on failure

### Integration Tests

1. **End-to-end routing**: Client connects to nearest region
2. **Failover scenario**: Simulate region failure
3. **Recovery scenario**: Healed region rejoins rotation

### Performance Tests

1. **Discovery overhead**: Measure connection time increase
2. **Failover speed**: Time to detect and switch regions
