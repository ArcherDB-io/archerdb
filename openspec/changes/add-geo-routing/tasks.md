# Implementation Tasks: Geo-Routing Based on Client Location

## Phase 1: Server-Side

### Task 1.1: Add region configuration
- **File**: `src/archerdb/config.zig` or config module
- **Changes**:
  - Add `GeoRoutingConfig` struct
  - Region name, location, endpoint
  - Peer regions list
- **Validation**: Config parses correctly
- **Estimated effort**: 1 hour

### Task 1.2: Implement /regions endpoint
- **File**: HTTP handler
- **Changes**:
  - Add `/regions` endpoint
  - Return JSON with all known regions
  - Include health status
  - Sign response for security
- **Validation**: Endpoint returns valid JSON
- **Estimated effort**: 2 hours

### Task 1.3: Region health aggregation
- **File**: Health monitoring
- **Changes**:
  - Aggregate health from peer regions
  - Include in /regions response
  - Update periodically
- **Validation**: Health status accurate
- **Estimated effort**: 1.5 hours

## Phase 2: Client SDK - Core

### Task 2.1: Region discovery client
- **Files**: All SDKs
- **Changes**:
  - Add `RegionDiscovery` class/module
  - Fetch and parse /regions
  - Cache with TTL
- **Validation**: Discovery works
- **Estimated effort**: 3 hours (all SDKs)

### Task 2.2: Latency probing
- **Files**: All SDKs
- **Changes**:
  - Background thread for RTT measurement
  - Ping each region periodically
  - Track latency history
- **Validation**: Latencies measured
- **Estimated effort**: 4 hours (all SDKs)

### Task 2.3: Region selection logic
- **Files**: All SDKs
- **Changes**:
  - Select lowest-latency healthy region
  - Apply region preference if configured
  - Handle all-regions-down case
- **Validation**: Correct region selected
- **Estimated effort**: 2 hours (all SDKs)

## Phase 3: Client SDK - Connection

### Task 3.1: Geo-aware connection
- **Files**: All SDKs
- **Changes**:
  - Integrate region selection with connection
  - Re-select on connection failure
  - Log region switches
- **Validation**: Connects to best region
- **Estimated effort**: 3 hours (all SDKs)

### Task 3.2: Failover handling
- **Files**: All SDKs
- **Changes**:
  - Detect region failure
  - Mark unhealthy, retry with next region
  - Configurable retry policy
- **Validation**: Failover works
- **Estimated effort**: 3 hours (all SDKs)

### Task 3.3: Region recovery
- **Files**: All SDKs
- **Changes**:
  - Continue probing unhealthy regions
  - Restore when healthy
  - Optionally switch back to preferred
- **Validation**: Recovery works
- **Estimated effort**: 2 hours (all SDKs)

## Phase 4: Configuration

### Task 4.1: SDK configuration options
- **Files**: All SDKs
- **Changes**:
  - `discovery_endpoint` option
  - `preferred_region` option
  - `failover_enabled` option
  - `probe_interval_ms` option
- **Validation**: Options work
- **Estimated effort**: 2 hours (all SDKs)

### Task 4.2: Server configuration
- **File**: Config documentation
- **Changes**:
  - Document geo_routing config
  - Example multi-region setup
  - Peer region configuration
- **Validation**: Config documented
- **Estimated effort**: 1 hour

## Phase 5: Metrics & Observability

### Task 5.1: Client metrics
- **Files**: All SDKs
- **Changes**:
  - `archerdb_client_region` label on all metrics
  - `archerdb_client_region_switches_total` counter
  - `archerdb_client_region_latency_ms` gauge per region
- **Validation**: Metrics exposed
- **Estimated effort**: 2 hours (all SDKs)

### Task 5.2: Server metrics
- **File**: `src/archerdb/metrics.zig`
- **Changes**:
  - `archerdb_region_discovery_requests_total` counter
  - `archerdb_region_peer_health` gauge per peer
- **Validation**: Metrics visible
- **Estimated effort**: 30 minutes

## Phase 6: Testing

### Task 6.1: Unit tests
- **Files**: All SDKs
- **Tests**:
  - Region discovery parsing
  - Latency-based selection
  - Failover logic
- **Validation**: All tests pass
- **Estimated effort**: 4 hours (all SDKs)

### Task 6.2: Integration tests
- **File**: Integration test suite
- **Tests**:
  - Multi-region setup
  - Client connects to nearest
  - Failover on region down
- **Validation**: All tests pass
- **Estimated effort**: 3 hours

### Task 6.3: Chaos testing
- **File**: Chaos test suite
- **Tests**:
  - Kill region, verify failover
  - Network partition scenarios
  - Recovery behavior
- **Validation**: System resilient
- **Estimated effort**: 2 hours

## Phase 7: Documentation

### Task 7.1: Deployment guide
- **File**: Documentation
- **Changes**:
  - Multi-region setup guide
  - Geo-DNS configuration examples
  - Failover behavior documentation
- **Validation**: Guide is complete
- **Estimated effort**: 2 hours

### Task 7.2: SDK documentation
- **Files**: SDK documentation
- **Changes**:
  - Geo-routing configuration
  - Best practices
  - Troubleshooting
- **Validation**: Docs accurate
- **Estimated effort**: 1.5 hours

## Dependencies

- Phase 2 depends on Phase 1
- Phase 3 depends on Phase 2
- Phases 4-7 can proceed after Phase 3

## Estimated Total Effort

- **Server-Side**: 4.5 hours
- **Client SDK Core**: 9 hours
- **Client SDK Connection**: 8 hours
- **Configuration**: 3 hours
- **Metrics**: 2.5 hours
- **Testing**: 9 hours
- **Documentation**: 3.5 hours
- **Total**: ~40 hours (~5 working days)

## Verification Checklist

- [x] `/regions` endpoint returns valid region list (src/archerdb/metrics_server.zig:379-615)
- [x] SDKs discover and cache regions (all SDKs: geo_routing.py, geo_routing.ts, GeoRouter.java, GeoRouting.cs, geo_routing.rs, georouting.go)
- [x] Latency probing measures RTT accurately (background probe threads in all SDKs)
- [x] Clients connect to lowest-latency region (region selection logic in all SDKs)
- [x] Failover switches to next-best region (failover handling in all SDKs)
- [x] Recovery restores preferred region (health recovery logic in all SDKs)
- [x] Metrics track region usage (GeoRoutingMetrics in all SDKs)
- [ ] Documentation covers multi-region setup (deferred per project policy)
