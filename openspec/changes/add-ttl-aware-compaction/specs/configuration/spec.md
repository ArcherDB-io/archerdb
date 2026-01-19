# Configuration - TTL-Aware Compaction

## ADDED Requirements

### Requirement: TTL Priority Threshold Configuration

The system SHALL support configuring the expired data ratio threshold for TTL-based compaction prioritization.

#### Scenario: CLI flag for threshold

- **WHEN** starting ArcherDB with TTL prioritization
- **THEN** the operator MAY specify:
  ```
  --ttl-priority-threshold=<value>
  ```
- **AND** `<value>` SHALL be a decimal in range [0.0, 1.0]
- **AND** the value represents the expired ratio threshold (e.g., 0.30 = 30%)
- **AND** percentage notation (e.g., "30%") SHALL NOT be accepted

#### Scenario: Default threshold value

- **WHEN** `--ttl-priority-threshold` is not specified
- **THEN** the system SHALL use default value: **0.30** (30% expired)
- **AND** this default SHALL handle typical TTL workloads without tuning
- **AND** the default SHALL be documented in CLI help text

#### Scenario: Validate threshold range

- **WHEN** parsing `--ttl-priority-threshold` value
- **THEN** the system SHALL validate:
  - Value is numeric and parseable as f64
  - `0.0 ≤ value ≤ 1.0`
- **AND** if validation fails, SHALL return error:
  ```
  Error: Invalid --ttl-priority-threshold value '{value}'
  Expected: decimal in range [0.0, 1.0]
  Example: --ttl-priority-threshold=0.30
  ```
- **AND** the process SHALL exit with non-zero status code

#### Scenario: Disable TTL prioritization

- **WHEN** the operator wants to disable TTL prioritization
- **THEN** they MAY set `--ttl-priority-threshold=1.0`
- **AND** no level can have `expired_ratio > 1.0`
- **AND** compaction SHALL use normal scheduling only
- **AND** expired ratio metrics SHALL still be tracked and exposed

#### Scenario: Very aggressive prioritization

- **WHEN** the operator sets `--ttl-priority-threshold=0.10` (10%)
- **THEN** levels with even low expired ratios SHALL be prioritized
- **AND** this MAY improve space reclamation speed
- **AND** this MAY impact read performance (more frequent compaction I/O)
- **AND** operators SHALL monitor query latency when using aggressive thresholds

#### Scenario: All levels exceed threshold

- **WHEN** all levels (1-6) have `expired_ratio > ttl_priority_threshold`
- **THEN** prioritization SHALL be a no-op (all levels equally prioritized)
- **AND** level iteration order SHALL remain ascending (1, 2, 3, 4, 5, 6)
- **AND** this is expected behavior for workloads with uniform TTL patterns
- **AND** space reclamation SHALL still occur at normal compaction rate

#### Scenario: Configuration persistence

- **WHEN** `--ttl-priority-threshold` is specified
- **THEN** the value SHALL apply for the lifetime of the process
- **AND** changing the threshold requires process restart
- **AND** the value SHALL NOT be persisted to superblock (runtime-only config)

#### Scenario: Display configuration in startup logs

- **WHEN** ArcherDB starts with TTL prioritization
- **THEN** the system SHALL log:
  ```
  info: TTL-aware compaction enabled (threshold={threshold:.2})
  ```
- **AND** if threshold is non-default, log SHALL note:
  ```
  info: Using custom TTL priority threshold: {threshold:.2} (default: 0.30)
  ```

## Implementation Status

| Requirement | Status | Notes |
|-------------|--------|-------|
| TTL Priority Threshold Configuration | IMPLEMENTED | `src/archerdb/cli.zig` - `--ttl-priority-threshold` flag with validation |

## Related Specifications

- See `storage-engine/spec.md` (this change) for prioritization behavior
- See base `configuration/spec.md` for CLI argument parsing
