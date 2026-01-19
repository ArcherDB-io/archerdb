# Client SDK - Geo-Routing Based on Client Location

## ADDED Requirements

### Requirement: Region Discovery

Client SDKs SHALL support automatic discovery of available regions.

#### Scenario: Discovery endpoint

- **WHEN** client is configured with discovery endpoint
- **THEN** client SHALL fetch region list:
  ```
  GET https://archerdb.example.com/regions

  Response:
  {
    "regions": [
      {
        "name": "us-east-1",
        "endpoint": "archerdb-use1.example.com:5000",
        "location": {"lat": 39.04, "lon": -77.49},
        "healthy": true
      },
      ...
    ],
    "expires": "2024-01-15T12:00:00Z"
  }
  ```
- **AND** client SHALL cache response until expiry

#### Scenario: Discovery failure

- **WHEN** discovery endpoint is unreachable
- **THEN** client SHALL:
  - Use cached region list if available
  - Fall back to direct endpoint if configured
  - Raise error if no fallback available

### Requirement: Latency Probing

Client SDKs SHALL measure latency to available regions.

#### Scenario: Background probing

- **WHEN** client has discovered regions
- **THEN** client SHALL:
  - Probe each region's RTT in background
  - Update latency measurements periodically
  - Default probe interval: 30 seconds
- **AND** probing SHALL NOT block client operations

#### Scenario: Probe method

- **WHEN** probing region latency
- **THEN** client SHALL:
  - Send lightweight ping request
  - Measure round-trip time
  - Track rolling average (last 5 measurements)

### Requirement: Region Selection

Client SDKs SHALL select optimal region based on latency and health.

#### Scenario: Selection algorithm

- **WHEN** selecting region for connection
- **THEN** client SHALL:
  1. Filter to healthy regions only
  2. Apply region preference if configured
  3. Select lowest-latency region
  4. If no measurements yet, use geographic distance

#### Scenario: Region preference

- **WHEN** client is configured with `preferred_region`
- **THEN** client SHALL:
  - Prefer that region if healthy
  - Fall back to latency-based selection if unhealthy
  - Log when using non-preferred region

### Requirement: Automatic Failover

Client SDKs SHALL failover to backup regions on failure.

#### Scenario: Failover trigger

- **WHEN** current region becomes unavailable
- **THEN** client SHALL:
  - Mark region as unhealthy
  - Select next-best region
  - Retry operation on new region
  - Log failover event

#### Scenario: Unhealthy detection

- **WHEN** connection fails or times out
- **THEN** client SHALL mark region unhealthy after:
  - 3 consecutive failures, OR
  - Connection timeout, OR
  - Explicit health check failure

#### Scenario: Recovery detection

- **WHEN** previously unhealthy region recovers
- **THEN** client SHALL:
  - Detect via background probing
  - Mark region as healthy
  - Optionally switch back if preferred or lower latency

### Requirement: Geo-Routing Configuration

Client SDKs SHALL support geo-routing configuration options.

#### Scenario: Configuration options

- **WHEN** configuring geo-routing
- **THEN** client SHALL accept:
  ```python
  client = ArcherDBClient(
      discovery_endpoint="https://archerdb.example.com/regions",
      preferred_region="us-east-1",       # Optional
      failover_enabled=True,               # Default: true
      probe_interval_ms=30000,             # Default: 30000
      failover_timeout_ms=5000             # Default: 5000
  )
  ```

#### Scenario: Direct connection fallback

- **WHEN** geo-routing is disabled
- **THEN** client SHALL connect directly to endpoint:
  ```python
  client = ArcherDBClient(
      endpoint="archerdb-use1.example.com:5000"
  )
  ```
- **AND** no discovery or probing SHALL occur

### Requirement: Geo-Routing Metrics

Client SDKs SHALL expose metrics for geo-routing.

#### Scenario: Region connection metric

- **WHEN** exposing client metrics
- **THEN** SDKs SHALL include region label:
  ```
  archerdb_client_queries_total{region="us-east-1"} 1000
  ```

#### Scenario: Region switch metric

- **WHEN** failover occurs
- **THEN** SDKs SHALL expose:
  ```
  archerdb_client_region_switches_total{from="us-east-1",to="eu-west-1"} 5
  ```

#### Scenario: Region latency metric

- **WHEN** probing regions
- **THEN** SDKs SHALL expose:
  ```
  archerdb_client_region_latency_ms{region="us-east-1"} 25
  archerdb_client_region_latency_ms{region="eu-west-1"} 85
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Region Discovery | IMPLEMENTED | All 6 SDKs (Python, Node, Rust, Go, Java, .NET) support discovery endpoint with caching |
| Latency Probing | IMPLEMENTED | Background probing with rolling average (5 samples), configurable interval |
| Region Selection | IMPLEMENTED | Health filtering, region preference, latency-based and geographic distance selection |
| Automatic Failover | IMPLEMENTED | Consecutive failure threshold (3), automatic region switching, recovery detection |
| Geo-Routing Configuration | IMPLEMENTED | Full configuration support with direct connection fallback |
| Geo-Routing Metrics | IMPLEMENTED | Prometheus-format metrics: queries_total, region_switches_total, latency_ms |

**Test Coverage:**
- Python: 41 tests passing (`pytest src/clients/python/tests/test_geo_routing.py`)
- Rust: 15 tests passing (`cargo test --manifest-path src/clients/rust/Cargo.toml geo_routing`)
- Go: 31 tests passing (`go test ./src/clients/go/pkg/georouting/...`)
- Java: 35 tests passing (`mvn test -f src/clients/java/pom.xml -Dtest=GeoRoutingTest`)
- .NET: 40+ tests passing (`dotnet test src/clients/dotnet/ArcherDB.Tests/`)
- Node: Type-checked and compiles (`tsc -p src/clients/node/tsconfig.json`)

## Related Specifications

- See base `client-sdk/spec.md` for SDK requirements
- See `replication/spec.md` for multi-region replication
- See `observability/spec.md` for metrics format
