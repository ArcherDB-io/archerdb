# Configuration - Coordinator Mode

## ADDED Requirements

### Requirement: Coordinator CLI Command

The system SHALL support a `coordinator` subcommand for running dedicated proxy nodes.

#### Scenario: Coordinator start command

- **WHEN** starting a coordinator
- **THEN** the CLI SHALL support:
  ```
  archerdb coordinator start [options]
  ```
- **AND** the command SHALL start the coordinator process

#### Scenario: Coordinator stop command

- **WHEN** stopping a coordinator
- **THEN** the CLI SHALL support:
  ```
  archerdb coordinator stop
  ```
- **AND** the coordinator SHALL:
  - Stop accepting new connections
  - Drain in-flight requests (up to 30 seconds)
  - Close shard connections
  - Exit cleanly

#### Scenario: Coordinator status command

- **WHEN** checking coordinator status
- **THEN** the CLI SHALL support:
  ```
  archerdb coordinator status
  ```
- **AND** output SHALL include:
  ```
  Coordinator Status: RUNNING
  Bind Address: 0.0.0.0:5000
  Active Connections: 1234
  Shards: 16 (16 healthy, 0 unhealthy)
  Topology Version: 42
  Uptime: 2d 4h 32m
  ```

### Requirement: Coordinator Network Configuration

The system SHALL support configuring coordinator network settings.

#### Scenario: Bind address configuration

- **WHEN** configuring coordinator bind address
- **THEN** the operator MAY specify:
  ```
  --bind=<host>:<port>
  ```
- **AND** default SHALL be `0.0.0.0:5000`
- **AND** coordinator SHALL listen on specified address for client connections

#### Scenario: Maximum connections configuration

- **WHEN** configuring maximum client connections
- **THEN** the operator MAY specify:
  ```
  --max-connections=<count>
  ```
- **AND** default SHALL be 10000
- **AND** new connections beyond limit SHALL be rejected with error

### Requirement: Shard Discovery Configuration

The system SHALL support configuring how coordinator discovers shards.

#### Scenario: Explicit shard list

- **WHEN** providing explicit shard addresses
- **THEN** the operator MAY specify:
  ```
  --shards=host1:port1,host2:port2,...
  ```
- **AND** coordinator SHALL connect directly to specified addresses
- **AND** shard IDs SHALL be assigned in order (0, 1, 2, ...)

#### Scenario: Seed node discovery

- **WHEN** using seed-based discovery
- **THEN** the operator MAY specify:
  ```
  --seed-nodes=host1:port1,host2:port2
  ```
- **AND** coordinator SHALL query seed nodes for topology
- **AND** at least one seed node MUST be reachable

#### Scenario: Discovery conflict

- **WHEN** both `--shards` and `--seed-nodes` are specified
- **THEN** the system SHALL return error:
  ```
  Error: Cannot specify both --shards and --seed-nodes
  Use --shards for explicit configuration or --seed-nodes for discovery
  ```

### Requirement: Query Behavior Configuration

The system SHALL support configuring coordinator query behavior.

#### Scenario: Query timeout configuration

- **WHEN** configuring query timeout
- **THEN** the operator MAY specify:
  ```
  --query-timeout-ms=<milliseconds>
  ```
- **AND** default SHALL be 30000 (30 seconds)
- **AND** queries exceeding timeout SHALL return error

#### Scenario: Fan-out policy configuration

- **WHEN** configuring fan-out behavior
- **THEN** the operator MAY specify:
  ```
  --fan-out-policy=<policy>
  ```
- **AND** valid policies SHALL be:
  - `strict`: Fail if any shard fails
  - `partial` (default): Return partial results
  - `best_effort`: Return whatever is available

#### Scenario: Read-from-replicas configuration

- **WHEN** configuring replica reads
- **THEN** the operator MAY specify:
  ```
  --read-from-replicas=<bool>
  ```
- **AND** default SHALL be `true`
- **AND** when true, read queries SHALL be load-balanced across replicas

### Requirement: Health Monitoring Configuration

The system SHALL support configuring coordinator health monitoring.

#### Scenario: Health check interval configuration

- **WHEN** configuring health check frequency
- **THEN** the operator MAY specify:
  ```
  --health-check-ms=<milliseconds>
  ```
- **AND** default SHALL be 5000 (5 seconds)

#### Scenario: Connections per shard configuration

- **WHEN** configuring shard connection pool
- **THEN** the operator MAY specify:
  ```
  --connections-per-shard=<count>
  ```
- **AND** default SHALL be 4
- **AND** connections SHALL be distributed across primary and replicas

#### Scenario: Topology refresh configuration

- **WHEN** configuring topology refresh
- **THEN** the operator MAY specify:
  ```
  --topology-refresh-ms=<milliseconds>
  ```
- **AND** default SHALL be 60000 (60 seconds)

### Requirement: Coordinator Help Text

The system SHALL provide comprehensive help for coordinator commands.

#### Scenario: Coordinator help output

- **WHEN** running `archerdb coordinator --help`
- **THEN** output SHALL include:
  ```
  archerdb coordinator - Run ArcherDB as a query coordinator/proxy

  USAGE:
      archerdb coordinator <command> [options]

  COMMANDS:
      start     Start the coordinator
      stop      Stop a running coordinator
      status    Show coordinator status

  START OPTIONS:
      --bind=<host:port>           Bind address for clients (default: 0.0.0.0:5000)
      --shards=<list>              Explicit shard list (host:port,host:port,...)
      --seed-nodes=<list>          Seed nodes for discovery (alternative to --shards)
      --max-connections=<n>        Max client connections (default: 10000)
      --query-timeout-ms=<n>       Query timeout in ms (default: 30000)
      --health-check-ms=<n>        Health check interval in ms (default: 5000)
      --topology-refresh-ms=<n>    Topology refresh interval in ms (default: 60000)
      --connections-per-shard=<n>  Connections per shard (default: 4)
      --read-from-replicas=<bool>  Load balance across replicas (default: true)
      --fan-out-policy=<policy>    strict|partial|best_effort (default: partial)

  EXAMPLES:
      # Start with explicit shards
      archerdb coordinator start --shards=shard-0:5001,shard-1:5001

      # Start with seed discovery
      archerdb coordinator start --seed-nodes=node-0:5001,node-5:5001

      # Start with custom settings
      archerdb coordinator start \
        --seed-nodes=node-0:5001 \
        --max-connections=50000 \
        --query-timeout-ms=60000
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Coordinator CLI Command | IMPLEMENTED | Coordinator mode implementation |
| Coordinator Network Configuration | IMPLEMENTED | Coordinator mode implementation |
| Shard Discovery Configuration | IMPLEMENTED | Coordinator mode implementation |
| Query Behavior Configuration | IMPLEMENTED | Coordinator mode implementation |
| Health Monitoring Configuration | IMPLEMENTED | Coordinator mode implementation |
| Coordinator Help Text | IMPLEMENTED | Coordinator mode implementation |

## Related Specifications

- See `coordinator/spec.md` (this change) for coordinator behavior
- See `observability/spec.md` (this change) for metrics
- See base `configuration/spec.md` for CLI framework
