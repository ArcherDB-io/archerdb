# Index Sharding - Jump Consistent Hash

## ADDED Requirements

### Requirement: Jump Consistent Hash Algorithm

The system SHALL support Jump Consistent Hash as a sharding strategy for optimal data movement during resharding.

#### Scenario: Jump hash computation

- **WHEN** computing shard for an entity using jump hash strategy
- **THEN** the system SHALL use the Jump Consistent Hash algorithm:
  ```
  jumpHash(key: u64, num_buckets: u32) -> u32

  b = -1, j = 0
  while j < num_buckets:
      b = j
      key = key * 2862933555777941757 + 1
      j = floor((b + 1) * 2^31 / ((key >> 33) + 1))
  return b
  ```
- **AND** the algorithm SHALL be deterministic (same key → same bucket)
- **AND** memory usage SHALL be O(1) (no ring storage)

#### Scenario: Jump hash uniformity

- **WHEN** distributing entities across shards using jump hash
- **THEN** each shard SHALL receive exactly 1/N of entities (perfect uniformity)
- **AND** there SHALL be zero variance in distribution (mathematical guarantee)
- **AND** no tuning parameters required (unlike virtual node count)

#### Scenario: Jump hash resharding movement

- **WHEN** adding one shard (N → N+1)
- **THEN** exactly 1/(N+1) of entities SHALL move to the new shard
- **AND** no entities SHALL move between existing shards
- **AND** this is mathematically optimal (no algorithm can do better)

#### Scenario: Jump hash time complexity

- **WHEN** computing shard bucket
- **THEN** average iterations SHALL be O(log num_buckets)
- **AND** for 256 shards, average iterations SHALL be ~8
- **AND** worst case is bounded by num_buckets iterations

### Requirement: Sharding Strategy Selection

The system SHALL support multiple sharding strategies with explicit selection.

#### Scenario: Available sharding strategies

- **WHEN** configuring sharding
- **THEN** the following strategies SHALL be available:
  | Strategy | Description | Use Case |
  |----------|-------------|----------|
  | `modulo` | `hash % num_shards` | Legacy, power-of-2 only |
  | `virtual_ring` | Binary search on vnode ring | Weighted shards, complex topologies |
  | `jump_hash` | Jump consistent hash | General purpose, optimal movement |

#### Scenario: Default strategy

- **WHEN** no sharding strategy is specified
- **THEN** the system SHALL use `jump_hash` as the default
- **AND** this SHALL apply to new cluster initialization only
- **AND** existing clusters SHALL retain their configured strategy

#### Scenario: Strategy validation

- **WHEN** configuring `modulo` strategy
- **THEN** the system SHALL validate shard count is power of 2
- **AND** if not power of 2, SHALL return error:
  ```
  Error: Modulo sharding requires power-of-2 shard count
  Got: 24, Expected: 8, 16, 32, 64, 128, or 256
  ```

#### Scenario: Strategy persistence

- **WHEN** a cluster is initialized with a sharding strategy
- **THEN** the strategy SHALL be persisted in cluster metadata
- **AND** the strategy SHALL NOT change without explicit migration
- **AND** strategy SHALL be included in cluster info output

### Requirement: CLI Configuration for Sharding Strategy

The system SHALL support configuring sharding strategy via CLI.

#### Scenario: CLI flag for strategy

- **WHEN** initializing a new cluster
- **THEN** the operator MAY specify:
  ```
  archerdb init --sharding-strategy=<strategy> --shards=<count>
  ```
- **AND** `<strategy>` SHALL be one of: `modulo`, `virtual_ring`, `jump_hash`
- **AND** default SHALL be `jump_hash`

#### Scenario: Strategy in cluster info

- **WHEN** displaying cluster information
- **THEN** the output SHALL include:
  ```
  Cluster Configuration:
    Shards: 16
    Sharding Strategy: jump_hash
    Virtual Nodes: N/A (not applicable for jump_hash)
  ```

#### Scenario: Strategy help text

- **WHEN** displaying `archerdb init --help`
- **THEN** the help SHALL document:
  ```
  --sharding-strategy=<strategy>
      Sharding algorithm for entity distribution (default: jump_hash)
      Strategies:
        modulo       - Simple hash % shards (power-of-2 only, 50% movement)
        virtual_ring - Virtual node ring (~1/N movement, configurable vnodes)
        jump_hash    - Jump consistent hash (1/N movement, zero memory) [RECOMMENDED]
  ```

### Requirement: Unified Shard Lookup

The system SHALL provide unified shard lookup across all strategies.

#### Scenario: Strategy-aware shard lookup

- **WHEN** determining shard for an entity
- **THEN** the system SHALL route based on configured strategy:
  ```
  getShardForEntity(entity_id, num_shards, strategy):
      key = computeShardKey(entity_id)
      switch strategy:
          modulo      → key & (num_shards - 1)
          virtual_ring → ring.binarySearch(key)
          jump_hash   → jumpHash(key, num_shards)
  ```
- **AND** all strategies SHALL produce values in range [0, num_shards)

#### Scenario: Consistent routing

- **WHEN** routing entity operations
- **THEN** the same entity_id SHALL always route to the same shard
- **AND** this SHALL hold across process restarts
- **AND** this SHALL hold across cluster nodes

## MODIFIED Requirements

### Requirement: Shard Count Constraints (Modified)

Updates shard count constraints to support non-power-of-2 counts with jump hash.

#### Scenario: Shard count validation by strategy

- **WHEN** validating shard count
- **THEN** constraints SHALL depend on strategy:
  | Strategy | Min | Max | Power-of-2 Required |
  |----------|-----|-----|---------------------|
  | `modulo` | 8 | 256 | Yes |
  | `virtual_ring` | 8 | 256 | No |
  | `jump_hash` | 8 | 256 | No |
- **AND** all strategies require minimum 8 shards
- **AND** all strategies require maximum 256 shards

#### Scenario: Non-power-of-2 shard counts

- **WHEN** using `jump_hash` or `virtual_ring` strategy
- **THEN** shard counts like 12, 24, 48, 100 SHALL be valid
- **AND** distribution SHALL remain uniform
- **AND** this enables more granular capacity scaling

### Requirement: Resharding Data Movement (Modified)

Updates data movement expectations based on strategy.

#### Scenario: Movement comparison by strategy

- **WHEN** resharding from N to M shards
- **THEN** expected data movement SHALL be:
  | Strategy | N→N+1 | N→2N | Arbitrary N→M |
  |----------|-------|------|---------------|
  | `modulo` | ~50% | 50% | ~(M-gcd(N,M))/M |
  | `virtual_ring` | ~1/N | ~50% | Depends on vnode overlap |
  | `jump_hash` | 1/(N+1) | ~50% | ~|M-N|/max(N,M) |
- **AND** jump hash provides mathematically optimal movement for growth

#### Scenario: Log resharding movement

- **WHEN** resharding is initiated
- **THEN** the system SHALL log expected movement:
  ```
  info: Resharding 16 → 24 shards (strategy: jump_hash)
  info: Expected entity movement: ~33% (8/24 of entities)
  info: Estimated time: 15 minutes at 100K entities/sec
  ```

## ADDED Metrics

### Requirement: Sharding Strategy Metrics

The system SHALL expose metrics about the sharding configuration.

#### Scenario: Strategy metric

- **WHEN** exposing sharding metrics
- **THEN** the system SHALL provide:
  ```
  # HELP archerdb_sharding_strategy Configured sharding strategy (0=modulo, 1=virtual_ring, 2=jump_hash)
  # TYPE archerdb_sharding_strategy gauge
  archerdb_sharding_strategy 2
  ```

#### Scenario: Shard lookup latency metric

- **WHEN** performing shard lookups
- **THEN** the system MAY track:
  ```
  # HELP archerdb_shard_lookup_duration_seconds Shard lookup latency histogram
  # TYPE archerdb_shard_lookup_duration_seconds histogram
  archerdb_shard_lookup_duration_seconds_bucket{strategy="jump_hash",le="0.00001"} 999000
  archerdb_shard_lookup_duration_seconds_bucket{strategy="jump_hash",le="0.0001"} 1000000
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Jump Consistent Hash Algorithm | IMPLEMENTED | `src/sharding.zig` - jumpHash function with O(log n) iterations |
| Sharding Strategy Selection | IMPLEMENTED | `src/sharding.zig` - modulo, virtual_ring, jump_hash strategies |
| CLI Configuration for Sharding Strategy | IMPLEMENTED | `src/archerdb/cli.zig` - `--sharding-strategy` flag |
| Unified Shard Lookup | IMPLEMENTED | `src/sharding.zig` - Strategy-aware routing |
| Shard Count Constraints (Modified) | IMPLEMENTED | Strategy-dependent validation |
| Resharding Data Movement (Modified) | IMPLEMENTED | Movement estimation logging |
| Sharding Strategy Metrics | IMPLEMENTED | `src/archerdb/metrics.zig` - strategy and lookup metrics |

## Related Specifications

- See `consistent-hashing.md` for virtual ring implementation details
- See `failover-resharding.md` for resharding procedures
- See base `index-sharding/spec.md` for shard configuration
