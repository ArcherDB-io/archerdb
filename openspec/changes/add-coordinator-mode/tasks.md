# Implementation Tasks: Optional Coordinator Node

## Phase 1: CLI Framework

### Task 1.1: Add coordinator subcommand to CLI
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Add `coordinator` subcommand
  - Support `start`, `stop`, `status` subcommands
  - Parse coordinator-specific arguments
- **Validation**: `archerdb coordinator --help` shows correct output
- **Estimated effort**: 1 hour

### Task 1.2: Add coordinator configuration struct
- **File**: `src/coordinator.zig`
- **Changes**:
  - Update `CoordinatorConfig` with all CLI-configurable options
  - Add validation for configuration values
  - Add defaults per spec
- **Validation**: Config validation test
- **Estimated effort**: 30 minutes

### Task 1.3: Parse coordinator CLI arguments
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Parse `--bind`, `--shards`, `--seed-nodes`
  - Parse `--max-connections`, `--query-timeout-ms`
  - Parse `--health-check-ms`, `--connections-per-shard`
  - Parse `--read-from-replicas`, `--fan-out-policy`
  - Validate mutually exclusive options (--shards vs --seed-nodes)
- **Validation**: CLI parsing tests
- **Estimated effort**: 1 hour

### Task 1.4: Implement coordinator start command
- **File**: `src/archerdb/main.zig`
- **Changes**:
  - Wire CLI parsing to Coordinator.init()
  - Call Coordinator.start() to begin accepting connections
  - Set up signal handling for graceful shutdown
- **Validation**: Coordinator starts and accepts connections
- **Estimated effort**: 1 hour

## Phase 2: Topology Management

### Task 2.1: Implement seed node discovery
- **File**: `src/coordinator.zig`
- **Changes**:
  - Connect to seed nodes
  - Request topology via GET /topology
  - Parse topology response
  - Store topology with version
- **Validation**: Topology discovery test
- **Estimated effort**: 2 hours

### Task 2.2: Implement explicit shard list parsing
- **File**: `src/coordinator.zig`
- **Changes**:
  - Parse comma-separated shard addresses
  - Create topology from explicit list
  - Assign shard IDs in order
- **Validation**: Explicit shard test
- **Estimated effort**: 30 minutes

### Task 2.3: Implement topology refresh
- **File**: `src/coordinator.zig`
- **Changes**:
  - Background thread/task for periodic refresh
  - Compare versions before updating
  - Handle SHARD_MOVED responses
  - Log topology changes
- **Validation**: Topology refresh test
- **Estimated effort**: 1 hour

### Task 2.4: Implement connection pool per shard
- **File**: `src/coordinator.zig`
- **Changes**:
  - Create `connections_per_shard` connections to each shard
  - Implement connection borrowing/returning
  - Handle connection failures with reconnect
  - Implement keepalive
- **Validation**: Connection pool test
- **Estimated effort**: 2 hours

## Phase 3: Query Routing

### Task 3.1: Implement single-shard query routing
- **File**: `src/coordinator.zig`
- **Changes**:
  - Hash entity_id to determine shard
  - Select replica using round-robin (if enabled)
  - Forward request, return response
  - Handle errors with retry
- **Validation**: Single-shard routing test
- **Estimated effort**: 1 hour

### Task 3.2: Implement fan-out query execution
- **File**: `src/coordinator.zig`
- **Changes**:
  - Send query to all shards in parallel
  - Collect responses with timeout
  - Track per-shard success/failure
  - Support configurable fan-out policy
- **Validation**: Fan-out test with various policies
- **Estimated effort**: 2 hours

### Task 3.3: Implement result aggregation
- **File**: `src/coordinator.zig`
- **Changes**:
  - Merge results from multiple shards
  - Sort by timestamp (k-way merge)
  - Apply LIMIT to merged results
  - Include partial result metadata
- **Validation**: Aggregation correctness test
- **Estimated effort**: 1.5 hours

### Task 3.4: Implement batched write routing
- **File**: `src/coordinator.zig`
- **Changes**:
  - Group events by target shard
  - Send batched requests in parallel
  - Collect and merge responses
- **Validation**: Batch routing test
- **Estimated effort**: 1 hour

## Phase 4: Health Monitoring

### Task 4.1: Implement health check loop
- **File**: `src/coordinator.zig`
- **Changes**:
  - Background task for periodic health checks
  - Ping each shard primary and replicas
  - Track consecutive failure count
  - Mark shards healthy/unhealthy
- **Validation**: Health check test
- **Estimated effort**: 1.5 hours

### Task 4.2: Implement health-aware routing
- **File**: `src/coordinator.zig`
- **Changes**:
  - Update `selectReplica` to skip unhealthy nodes
  - Update `getFanOutShards` to mark unhealthy shards
  - Log routing around unhealthy shards
- **Validation**: Health-aware routing test
- **Estimated effort**: 1 hour

### Task 4.3: Implement shard recovery detection
- **File**: `src/coordinator.zig`
- **Changes**:
  - Continue checking unhealthy shards
  - Mark healthy when check succeeds
  - Reset failure counter
  - Log recovery events
- **Validation**: Recovery detection test
- **Estimated effort**: 30 minutes

## Phase 5: Observability

### Task 5.1: Add connection metrics
- **File**: `src/coordinator.zig`, `src/archerdb/metrics.zig`
- **Changes**:
  - Add `coordinator_connections_active` gauge
  - Add `coordinator_connections_total` counter
  - Add `coordinator_connections_rejected_total` counter
- **Validation**: Metrics visible in /metrics
- **Estimated effort**: 30 minutes

### Task 5.2: Add query metrics
- **File**: `src/coordinator.zig`, `src/archerdb/metrics.zig`
- **Changes**:
  - Add `coordinator_queries_total` counter with type label
  - Add `coordinator_query_duration_seconds` histogram
  - Add `coordinator_query_errors_total` counter with reason label
- **Validation**: Metrics visible in /metrics
- **Estimated effort**: 1 hour

### Task 5.3: Add shard metrics
- **File**: `src/coordinator.zig`, `src/archerdb/metrics.zig`
- **Changes**:
  - Add `coordinator_shards_total` gauge
  - Add `coordinator_shards_healthy` gauge
  - Add `coordinator_shard_status` gauge with shard label
  - Add `coordinator_shard_failures_total` counter
- **Validation**: Metrics visible in /metrics
- **Estimated effort**: 30 minutes

### Task 5.4: Add topology metrics
- **File**: `src/coordinator.zig`, `src/archerdb/metrics.zig`
- **Changes**:
  - Add `coordinator_topology_version` gauge
  - Add `coordinator_topology_updates_total` counter
  - Add `coordinator_topology_refresh_errors_total` counter
- **Validation**: Metrics visible in /metrics
- **Estimated effort**: 30 minutes

### Task 5.5: Add fan-out metrics
- **File**: `src/coordinator.zig`, `src/archerdb/metrics.zig`
- **Changes**:
  - Add `coordinator_fanout_shards_queried` histogram
  - Add `coordinator_fanout_partial_total` counter
- **Validation**: Metrics visible in /metrics
- **Estimated effort**: 30 minutes

## Phase 6: Testing

### Task 6.1: Unit tests for routing
- **File**: `src/coordinator.zig` (test section)
- **Tests**:
  - Single-shard routing correctness
  - Fan-out to all shards
  - Round-robin replica selection
  - Health-aware routing
- **Validation**: All tests pass
- **Estimated effort**: 2 hours

### Task 6.2: Unit tests for aggregation
- **File**: `src/coordinator.zig` (test section)
- **Tests**:
  - Result merging from multiple shards
  - Sort by timestamp
  - LIMIT application
  - Partial result handling
- **Validation**: All tests pass
- **Estimated effort**: 1.5 hours

### Task 6.3: Integration test for coordinator mode
- **File**: `src/integration_tests.zig` or new test
- **Tests**:
  - Start coordinator with seed nodes
  - Route single-shard query
  - Route fan-out query
  - Handle shard failure
- **Validation**: Integration tests pass
- **Estimated effort**: 3 hours

### Task 6.4: Performance benchmark
- **File**: Benchmark script
- **Tests**:
  - Single-shard latency (target: <1ms overhead)
  - Fan-out latency vs direct
  - Throughput at saturation
- **Validation**: Performance targets met
- **Estimated effort**: 2 hours

## Phase 7: Documentation

### Task 7.1: Update CLI help text
- **File**: `src/archerdb/cli.zig`
- **Changes**:
  - Comprehensive help for coordinator commands
  - Examples for common use cases
- **Validation**: `archerdb coordinator --help` is complete
- **Estimated effort**: 30 minutes

### Task 7.2: Add coordinator deployment guide
- **File**: Documentation (docs/ or wiki)
- **Changes**:
  - When to use coordinator vs smart client
  - HA deployment with load balancer
  - Configuration tuning guide
  - Monitoring recommendations
- **Validation**: Documentation review
- **Estimated effort**: 2 hours

### Task 7.3: Update CHANGELOG
- **File**: `CHANGELOG.md`
- **Changes**:
  - Add coordinator mode feature
  - Note CLI commands
  - List new metrics
- **Validation**: Changelog entry accurate
- **Estimated effort**: 15 minutes

## Dependencies & Parallelization

### Sequential Dependencies

- Phase 1 must complete before Phase 2 (CLI needed first)
- Phase 2 must complete before Phase 3 (topology needed for routing)
- Phase 3 must complete before Phase 4 (routing needed for health-aware routing)
- Phase 5 depends on Phases 1-4
- Phase 6 depends on Phases 1-5

### Parallelizable Work

- Task 1.1 and 1.2 can be done in parallel
- Task 2.1 and 2.2 can be done in parallel
- Task 3.1, 3.2, 3.3, 3.4 can be done in parallel (different query types)
- All Phase 5 metrics tasks can be done in parallel
- All Phase 7 documentation tasks can be done in parallel

## Verification Checklist

- [x] `archerdb coordinator start` works with --shards (CLI integrated, start stub implemented)
- [x] `archerdb coordinator start` works with --seed-nodes (CLI integrated, start stub implemented)
- [x] `archerdb coordinator status` shows correct info (CLI integrated, status stub implemented)
- [x] Single-shard queries route correctly (unit tests: 8 tests pass)
- [x] Fan-out query support implemented (getFanOutShards, requiresFanOut)
- [x] Result aggregation framework in place (PendingQuery, mergeFanOutResults)
- [x] Health monitoring detects failures (markShardUnhealthy, failure threshold)
- [x] Health-aware routing skips unhealthy shards (shard.status check in routeQuery)
- [x] All metrics exposed on /metrics (metrics.zig: connections, queries, shards, topology, fan-out)
- [ ] Integration tests pass (require running cluster)
- [ ] Performance overhead <1ms (benchmark needed)
- [ ] Documentation complete (pending)

## Estimated Total Effort

- **CLI & Configuration**: 3-4 hours
- **Topology Management**: 5-6 hours
- **Query Routing**: 5-6 hours
- **Health Monitoring**: 3-4 hours
- **Observability**: 3-4 hours
- **Testing**: 8-10 hours
- **Documentation**: 3-4 hours
- **Total**: 30-38 hours (~4-5 working days)

## Rollout Strategy

1. **Merge to main** after all tests pass
2. **Optional deployment**: Coordinator is opt-in, smart client remains default
3. **Document tradeoffs**: Clear guidance on when to use each mode
4. **Monitor adoption**: Track coordinator usage in production
5. **Iterate**: Refine based on feedback
