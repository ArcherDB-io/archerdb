# Index Sharding v2 Spec Deltas

## ADDED Requirements

### Requirement: Stop-the-World Resharding (v2.0)

The system SHALL support resharding with planned downtime for capacity expansion.

#### Scenario: Resharding procedure initiation

- **WHEN** an operator initiates resharding
- **THEN** the system SHALL:
  1. Validate target shard count is valid (power of 2, or divisible by current)
  2. Create pre-resharding backup automatically
  3. Enter read-only mode (reject all writes)
  4. Log resharding start to audit log
- **AND** resharding SHALL require explicit operator confirmation

#### Scenario: Data redistribution

- **WHEN** resharding from N shards to M shards
- **THEN** the system SHALL:
  - Compute new shard assignment: `new_shard = hash(entity_id) % M`
  - Export entities from each source shard
  - Import entities to target shards
  - Verify entity counts match before and after
- **AND** redistribution SHALL preserve all entity data and metadata

#### Scenario: Resharding completion

- **WHEN** data redistribution completes successfully
- **THEN** the system SHALL:
  - Update cluster metadata with new shard count
  - Broadcast new topology to all clients
  - Exit read-only mode (accept writes)
  - Log resharding completion with duration and entity counts
- **AND** clients SHALL automatically discover new topology

#### Scenario: Resharding failure recovery

- **WHEN** resharding fails mid-process
- **THEN** the system SHALL:
  - Restore from pre-resharding backup
  - Return to original shard configuration
  - Log failure reason and recovery steps
  - Alert operators via configured channels
- **AND** no data loss SHALL occur

### Requirement: Online Resharding (v2.1+)

The system SHALL support resharding with minimal downtime using dual-write migration.

#### Scenario: Online resharding initiation

- **WHEN** online resharding is initiated
- **THEN** the system SHALL:
  1. Deploy new shard topology alongside existing
  2. Enable dual-write mode (writes go to both old and new shards)
  3. Begin background data migration
  4. Continue serving reads from old shards
- **AND** write throughput MAY be reduced during migration (documented)

#### Scenario: Background data migration

- **WHEN** migrating data to new shards
- **THEN** the system SHALL:
  - Migrate entities in batches (configurable batch size)
  - Rate-limit migration to avoid impacting production traffic
  - Track migration progress per source shard
  - Expose `archerdb_resharding_progress` metric (0.0 to 1.0)
- **AND** migration SHALL be resumable after failures

#### Scenario: Cutover to new topology

- **WHEN** migration reaches 100% and lag is minimal
- **THEN** the system SHALL:
  - Brief write pause (<1 second) for final sync
  - Switch reads to new topology
  - Disable dual-write mode
  - Mark old shards for decommissioning
- **AND** cutover SHALL be triggered manually or automatically

#### Scenario: Online resharding rollback

- **WHEN** online resharding is rolled back
- **THEN** the system SHALL:
  - Disable dual-write mode
  - Discard new shard data
  - Continue serving from original shards
  - Log rollback reason
- **AND** rollback SHALL NOT cause data loss

### Requirement: Shard Management CLI

The system SHALL provide CLI commands for shard management operations.

#### Scenario: List shards command

- **WHEN** operator runs `archerdb shard list`
- **THEN** the system SHALL display:
  ```
  SHARD   REPLICAS   ENTITIES    SIZE      LEADER    STATUS
  0       3/3        250000000   32GB      replica-0  healthy
  1       3/3        250000001   32GB      replica-1  healthy
  2       3/3        249999999   31GB      replica-2  healthy
  3       3/3        250000000   32GB      replica-0  healthy
  ```
- **AND** output SHALL support `--json` format

#### Scenario: Shard status command

- **WHEN** operator runs `archerdb shard status <shard_id>`
- **THEN** the system SHALL display:
  - Entity count and size
  - Replica status and locations
  - Replication lag per replica
  - Recent operations throughput
  - Health check results

#### Scenario: Reshard command

- **WHEN** operator runs `archerdb shard reshard --to <count>`
- **THEN** the system SHALL:
  - Validate target count
  - Show estimated downtime/migration time
  - Prompt for confirmation
  - Execute resharding procedure
  - Report progress and completion
- **AND** `--mode=online|offline` SHALL select resharding strategy

#### Scenario: Shard rebalance command

- **WHEN** operator runs `archerdb shard rebalance`
- **THEN** the system SHALL:
  - Identify shards with uneven entity distribution
  - Propose migration plan to balance within 5% variance
  - Execute approved migrations
- **AND** rebalancing SHALL use online migration when available

### Requirement: Smart Client Topology Discovery

Client SDKs SHALL automatically discover and route to appropriate shards.

#### Scenario: Initial topology discovery

- **WHEN** a client connects to the cluster
- **THEN** the client SHALL:
  - Connect to any known node (seed addresses)
  - Request current topology via `get_topology` operation
  - Cache shard-to-node mapping locally
  - Subscribe to topology change notifications
- **AND** topology refresh SHALL occur on connection errors

#### Scenario: Shard-aware routing

- **WHEN** a client submits a write operation
- **THEN** the client SHALL:
  - Compute target shard: `shard = hash(entity_id) % shard_count`
  - Route request directly to shard leader
  - Handle `not_shard_leader` error by refreshing topology
- **AND** routing SHALL NOT require application code changes

#### Scenario: Scatter-gather for spatial queries

- **WHEN** a client submits a spatial query (radius, polygon)
- **THEN** the client SHALL:
  - Send query to all shards in parallel
  - Collect results from each shard
  - Merge and deduplicate results
  - Apply result limit after merge
- **AND** partial failures SHALL return partial results with warning

#### Scenario: Topology change notification

- **WHEN** cluster topology changes (resharding, failover)
- **THEN** clients SHALL:
  - Receive push notification via existing connection
  - Update local topology cache
  - Retry in-flight requests if routing changed
- **AND** notification delivery SHALL be best-effort (clients also poll)

### Requirement: Shard Health Monitoring

The system SHALL expose metrics for shard health and balance.

#### Scenario: Shard metrics

- **WHEN** exposing shard metrics
- **THEN** the system SHALL provide:
  ```
  archerdb_shard_entity_count{shard="0"} 250000000
  archerdb_shard_size_bytes{shard="0"} 34359738368
  archerdb_shard_write_rate{shard="0"} 25000
  archerdb_shard_read_rate{shard="0"} 100000
  archerdb_shard_leader{shard="0",replica="replica-0"} 1
  ```

#### Scenario: Balance metrics

- **WHEN** monitoring shard balance
- **THEN** the system SHALL provide:
  ```
  archerdb_shard_balance_variance 0.02
  archerdb_shard_hottest{shard="2"} 1
  archerdb_shard_coldest{shard="0"} 1
  ```
- **AND** variance >10% SHALL trigger warning alerts

## ADDED Error Codes

### Requirement: Sharding Error Codes

The system SHALL define error codes for sharding operations.

#### Scenario: New sharding error codes

- **WHEN** sharding errors occur
- **THEN** the following error codes SHALL be used:
  | Code | Name | Message | Retry |
  |------|------|---------|-------|
  | 220 | not_shard_leader | This node is not the leader for target shard | Yes |
  | 221 | shard_unavailable | Target shard has no available replicas | Yes |
  | 222 | resharding_in_progress | Cluster is currently resharding | Yes |
  | 223 | invalid_shard_count | Target shard count is invalid | No |
  | 224 | shard_migration_failed | Data migration to new shard failed | No |

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Stop-the-World Resharding | ✓ Complete | `sharding.zig` drain/migrate/restart |
| Online Resharding (v2.1) | ✓ Complete | Background migration |
| Shard Management CLI | ✓ Complete | `archerdb shard` commands |
| Topology Discovery | ✓ Complete | `topology.zig`, get_topology op |
| Shard Health Monitoring | ✓ Complete | Per-shard metrics |
| Sharding Error Codes (220-224) | ✓ Complete | `error_codes.zig` |
