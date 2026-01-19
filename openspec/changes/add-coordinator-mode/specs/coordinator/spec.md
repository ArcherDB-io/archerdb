# Coordinator - Optional Proxy Node

## ADDED Requirements

### Requirement: Coordinator Mode

The system SHALL support running ArcherDB as a dedicated coordinator/proxy node for multi-shard deployments.

#### Scenario: Start coordinator via CLI

- **WHEN** starting ArcherDB in coordinator mode
- **THEN** the operator SHALL run:
  ```
  archerdb coordinator start --bind=<address> --seed-nodes=<nodes>
  ```
- **AND** the coordinator SHALL:
  - Discover topology from seed nodes
  - Connect to all shard primaries
  - Start health monitoring
  - Accept client connections on bind address

#### Scenario: Coordinator with explicit shard list

- **WHEN** starting coordinator with explicit shards
- **THEN** the operator MAY specify:
  ```
  archerdb coordinator start --shards=shard-0:5001,shard-1:5001,...
  ```
- **AND** the coordinator SHALL use provided addresses directly
- **AND** no topology discovery SHALL be required

#### Scenario: Coordinator startup validation

- **WHEN** coordinator starts
- **THEN** the system SHALL validate:
  - At least one seed node or explicit shard is reachable
  - Topology can be retrieved (if using seeds)
  - At least one shard is healthy
- **AND** if validation fails, SHALL exit with clear error message

#### Scenario: Coordinator running state

- **WHEN** coordinator is running
- **THEN** the system SHALL:
  - Accept client connections on bind address
  - Route queries to appropriate shards
  - Monitor shard health periodically
  - Refresh topology periodically (every 60 seconds)
- **AND** coordinator SHALL be stateless (no persistent data)

### Requirement: Query Routing

The coordinator SHALL route client queries to appropriate shard(s) based on query type.

#### Scenario: Single-shard query routing

- **WHEN** coordinator receives a single-entity query (query_uuid, query_by_entity)
- **THEN** the coordinator SHALL:
  1. Compute shard: `shard = hash(entity_id) % num_shards`
  2. Select replica using round-robin (if read-from-replicas enabled)
  3. Forward request to selected replica
  4. Return response to client
- **AND** latency overhead SHALL be <1ms

#### Scenario: Fan-out query routing

- **WHEN** coordinator receives a spatial query (query_radius, query_polygon)
- **THEN** the coordinator SHALL:
  1. Send query to all active shards in parallel
  2. Wait for responses (up to query timeout)
  3. Aggregate results from all shards
  4. Apply LIMIT and ORDER BY
  5. Return final result to client

#### Scenario: Batched write routing

- **WHEN** coordinator receives insert_events with multiple entities
- **THEN** the coordinator SHALL:
  1. Group events by target shard
  2. Send batched requests to each affected shard in parallel
  3. Collect responses
  4. Return aggregated result to client

### Requirement: Fan-Out Query Handling

The coordinator SHALL support configurable behavior for partial shard failures during fan-out.

#### Scenario: Strict fan-out policy

- **WHEN** fan-out policy is `strict`
- **AND** any shard fails to respond
- **THEN** the coordinator SHALL fail the entire query
- **AND** return error with list of failed shards

#### Scenario: Partial fan-out policy

- **WHEN** fan-out policy is `partial` (default)
- **AND** some shards fail to respond
- **THEN** the coordinator SHALL:
  - Return results from successful shards
  - Include `partial: true` in response metadata
  - Include list of failed shards in metadata
- **AND** client can decide how to handle partial results

#### Scenario: Best-effort fan-out policy

- **WHEN** fan-out policy is `best_effort`
- **THEN** the coordinator SHALL:
  - Wait up to query timeout
  - Return whatever results are available
  - Not retry failed shards

#### Scenario: Fan-out result aggregation

- **WHEN** aggregating fan-out results
- **THEN** the coordinator SHALL:
  - Collect results from all responding shards
  - Sort by timestamp (if ORDER BY specified)
  - Apply LIMIT to merged results
  - Return final result set
- **AND** aggregation SHALL use k-way merge for efficiency

### Requirement: Load Balancing

The coordinator SHALL distribute read queries across available replicas.

#### Scenario: Round-robin replica selection

- **WHEN** routing a read query with read-from-replicas enabled
- **THEN** the coordinator SHALL:
  - Select replica using round-robin
  - Skip unhealthy replicas
  - Fall back to primary if all replicas unhealthy

#### Scenario: Write routing to primary

- **WHEN** routing a write query (insert, delete)
- **THEN** the coordinator SHALL always route to shard primary
- **AND** replicas SHALL NOT receive writes

#### Scenario: Health-aware routing

- **WHEN** a shard or replica is marked unhealthy
- **THEN** the coordinator SHALL:
  - Exclude it from routing decisions
  - Continue checking health periodically
  - Re-include when health check succeeds

### Requirement: Health Monitoring

The coordinator SHALL monitor shard health and adapt routing accordingly.

#### Scenario: Periodic health checks

- **WHEN** coordinator is running
- **THEN** the system SHALL:
  - Ping each shard primary every `health_check_interval_ms` (default: 5000)
  - Ping replicas if read-from-replicas enabled
  - Track consecutive failure count per node

#### Scenario: Mark shard unhealthy

- **WHEN** a shard fails `max_failures` consecutive health checks (default: 3)
- **THEN** the coordinator SHALL:
  - Mark the shard as `unavailable`
  - Log warning with shard details
  - Increment `coordinator_shard_failures_total` metric
- **AND** continue checking until shard recovers

#### Scenario: Shard recovery

- **WHEN** a previously unhealthy shard responds to health check
- **THEN** the coordinator SHALL:
  - Mark the shard as `active`
  - Reset failure count to 0
  - Log info about recovery
  - Resume routing to that shard

### Requirement: Topology Management

The coordinator SHALL manage shard topology discovery and updates.

#### Scenario: Initial topology discovery

- **WHEN** coordinator starts with seed nodes
- **THEN** the system SHALL:
  1. Connect to first available seed node
  2. Request topology via `GET /topology`
  3. Cache topology with version number
  4. Establish connections to all shards

#### Scenario: Periodic topology refresh

- **WHEN** coordinator is running
- **THEN** topology SHALL be refreshed:
  - Every `topology_refresh_interval_ms` (default: 60000)
  - When a shard returns "SHARD_MOVED" error
  - When topology version in response > cached version

#### Scenario: Topology version tracking

- **WHEN** topology is updated
- **THEN** the coordinator SHALL:
  - Compare new version with cached version
  - Only apply if new version > cached version
  - Log topology changes (shards added/removed)
  - Increment `coordinator_topology_updates_total` metric

### Requirement: Connection Management

The coordinator SHALL manage connections to shards efficiently.

#### Scenario: Connection pool per shard

- **WHEN** connecting to shards
- **THEN** the coordinator SHALL:
  - Maintain `connections_per_shard` connections per shard (default: 4)
  - Use connection pool for request multiplexing
  - Reconnect on connection failure with exponential backoff

#### Scenario: Connection timeout

- **WHEN** connecting to a shard
- **THEN** connection SHALL timeout after `connect_timeout_ms` (default: 5000)
- **AND** failed connection SHALL mark shard as potentially unhealthy
- **AND** retry with backoff

#### Scenario: Keepalive

- **WHEN** connection is idle
- **THEN** the coordinator SHALL:
  - Send keepalive every `keepalive_interval_ms` (default: 30000)
  - Close connection if keepalive fails
  - Re-establish connection on next request

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Coordinator Mode | IMPLEMENTED | Coordinator mode implementation |
| Query Routing | IMPLEMENTED | Coordinator mode implementation |
| Fan-Out Query Handling | IMPLEMENTED | Coordinator mode implementation |
| Load Balancing | IMPLEMENTED | Coordinator mode implementation |
| Health Monitoring | IMPLEMENTED | Coordinator mode implementation |
| Topology Management | IMPLEMENTED | Coordinator mode implementation |
| Connection Management | IMPLEMENTED | Coordinator mode implementation |

## Related Specifications

- See `configuration/spec.md` (this change) for CLI arguments
- See `observability/spec.md` (this change) for coordinator metrics
- See `index-sharding/query-routing.md` for routing algorithm details
