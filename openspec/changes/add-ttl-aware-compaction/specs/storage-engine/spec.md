# Storage Engine - TTL-Aware Compaction

## ADDED Requirements

### Requirement: Expired Data Ratio Tracking

The system SHALL track the estimated expired data ratio for each LSM level via sampling during normal compaction.

#### Scenario: Sample expired ratio during compaction

- **WHEN** a compaction bar processes values from level A to level B
- **THEN** the system SHALL:
  - Count total values processed: `values_total`
  - Count expired values discarded: `values_expired`
  - Calculate sample ratio: `sample_ratio = values_expired / values_total`
- **AND** the sample SHALL be recorded for level B (target level)

#### Scenario: Update level expired ratio with exponential moving average

- **WHEN** a compaction bar completes for level B
- **AND** `values_total > 0`
- **THEN** the system SHALL update the level's expired ratio:
  ```
  alpha = 0.2  # Weight for new samples (compile-time constant)
  level.expired_ratio = alpha × sample_ratio + (1 - alpha) × level.expired_ratio
  ```
- **AND** `level.expired_ratio_sampled_at_op` SHALL be set to current op
- **AND** the EMA SHALL converge to actual expired ratio over time

#### Scenario: Handle empty compaction bar

- **WHEN** a compaction bar completes for level B
- **AND** `values_total == 0` (no values processed)
- **THEN** the system SHALL NOT update `level.expired_ratio`
- **AND** the previous expired_ratio SHALL be retained
- **AND** this MAY occur for empty levels or during recovery

#### Scenario: Initial expired ratio

- **WHEN** a level has never been compacted
- **THEN** `expired_ratio` SHALL be 0.0
- **AND** `expired_ratio_sampled_at_op` SHALL be 0
- **AND** the level SHALL use normal compaction priority until first sampling

#### Scenario: Expired ratio on process restart

- **WHEN** the ArcherDB process restarts
- **THEN** all `expired_ratio` values SHALL reset to 0.0
- **AND** the values SHALL NOT be persisted to superblock or manifest
- **BECAUSE** runtime-only tracking avoids metadata complexity
- **AND** ratios will reconverge after 2-3 compaction cycles per level

#### Scenario: Expired ratio bounds

- **WHEN** storing or exposing expired_ratio
- **THEN** the value SHALL be clamped to range [0.0, 1.0]
- **AND** values SHALL be represented as f64 for metric compatibility

### Requirement: TTL-Aware Level Prioritization

The system SHALL prioritize compacting LSM levels with high expired data ratios to enable faster space reclamation.

#### Scenario: Identify high-expired levels

- **WHEN** starting a compaction half-bar
- **THEN** for each level, the system SHALL:
  - Check if `level.expired_ratio > ttl_priority_threshold`
  - Where `ttl_priority_threshold` defaults to 0.30 (30%)
- **AND** levels exceeding threshold SHALL be marked for prioritization

#### Scenario: Reorder level iteration for TTL priority

- **WHEN** determining compaction order for a half-bar
- **THEN** the system SHALL iterate levels in this order:
  1. **First**: Levels with `expired_ratio > ttl_priority_threshold` (ascending order)
  2. **Then**: Levels with `expired_ratio ≤ ttl_priority_threshold` (ascending order)
- **AND** within each priority group, maintain normal level ordering (1, 2, 3, ...)
- **AND** level activeness checks SHALL still apply (per existing half-bar alternation)

#### Scenario: Apply normal constraints to prioritized levels

- **WHEN** compacting a TTL-prioritized level
- **THEN** the system SHALL apply all existing constraints:
  - Beat input size quotas (prevent overload)
  - Least-overlap table selection (minimize write amplification)
  - Block reservation limits (prevent OOM)
  - Half-bar alternation (maintain rhythm)
- **AND** prioritization SHALL NOT bypass any safety limits

#### Scenario: Logging for TTL prioritization

- **WHEN** a level is prioritized due to high expired ratio
- **THEN** the system SHALL log:
  ```
  info: TTL-prioritized level {level} (expired_ratio={ratio:.2}, threshold={threshold:.2}, op={op})
  ```
- **AND** the op number SHALL enable correlation with other compaction events
- **AND** normal compaction logs SHALL indicate if prioritization occurred

#### Scenario: Level 0 exclusion from TTL prioritization

- **WHEN** evaluating levels for TTL prioritization
- **THEN** level 0 SHALL be excluded from expired_ratio tracking
- **AND** level 0 compaction SHALL follow normal scheduling
- **BECAUSE** level 0 contains immutable tables that flush directly from memory

### Requirement: TTL Priority Threshold Configuration

The system SHALL support configuring the TTL prioritization threshold for operational tuning.

#### Scenario: Default threshold

- **WHEN** no threshold is configured
- **THEN** `ttl_priority_threshold` SHALL default to 0.30 (30%)
- **AND** this default SHALL handle typical TTL workloads without tuning

#### Scenario: Operator-configured threshold

- **WHEN** the operator specifies `--ttl-priority-threshold=<value>`
- **THEN** the system SHALL validate:
  - `0.0 ≤ value ≤ 1.0`
- **AND** reject invalid values with error `invalid_configuration`
- **AND** the configured value SHALL apply to all levels uniformly

#### Scenario: Disable TTL prioritization

- **WHEN** the operator sets `--ttl-priority-threshold=1.0`
- **THEN** TTL prioritization SHALL be effectively disabled
  - (No level can have expired_ratio > 1.0)
- **AND** compaction SHALL use normal scheduling only

#### Scenario: Aggressive TTL prioritization

- **WHEN** the operator sets `--ttl-priority-threshold=0.10` (10%)
- **THEN** TTL prioritization SHALL be more aggressive
- **AND** levels with even moderate expired ratios SHALL be prioritized
- **AND** this MAY reduce write amplification but MAY also slow read queries

## MODIFIED Requirements

### Requirement: Compaction Bar Statistics (Modified)

Extends existing compaction statistics to include expired value tracking.

#### Scenario: Bar statistics include expired count

- **WHEN** a compaction bar completes
- **THEN** `BarStatistics` SHALL include:
  - `values_total: u64` (existing)
  - `values_expired: u64` (NEW - count of TTL-expired values discarded)
  - `values_dropped_tombstone: u64` (existing)
  - `values_output: u64` (existing)
- **AND** `values_expired` SHALL only count TTL expirations, not tombstone drops

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| Expired Data Ratio Tracking | IMPLEMENTED | `src/lsm/manifest_level.zig` - `expired_ratio`, `expired_ratio_sampled_at_op` fields |
| TTL-Aware Level Prioritization | IMPLEMENTED | `src/lsm/forest.zig` - TTL priority threshold and level reordering |
| TTL Priority Threshold Configuration | IMPLEMENTED | `src/archerdb/cli.zig` - `--ttl-priority-threshold` CLI option |
| Compaction Bar Statistics (Modified) | IMPLEMENTED | `src/lsm/compaction.zig` - `values_expired` tracking |

## Related Specifications

- See `ttl-retention/spec.md` for TTL expiration logic during compaction
- See `observability/spec.md` for `archerdb_ttl_expired_ratio_by_level` metric (NEW)
- See base `storage-engine/spec.md` for LSM compaction algorithm
- See `hybrid-memory/spec.md` for lazy TTL expiration in index
